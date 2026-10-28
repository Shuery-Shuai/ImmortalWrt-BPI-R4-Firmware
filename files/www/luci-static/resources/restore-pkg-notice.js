/*
 * 文件: files/www/luci-static/resources/restore-pkg-notice.js
 * 用途: 在 LuCI 页面（含未登录的登录页）弹出「备份软件包恢复失败」提示。
 *
 * 数据来源:
 *   服务端在页面里内联一段 script，把失败记录挂到 window.__RESTORE_PKG_NOTICE__，
 *   形如 { fingerprint, total, packages: [..], entries: [{class,stage,message,cause,target,tool,exit,count}] }。
 *   该对象由构建期注入到 LuCI 模板的那一行 ucode 生成（见
 *   scripts/inputs/mods/14-luci-restore-pkg-notice.sh），本文件只负责渲染。
 *   没有失败记录时服务端【不输出】这个对象，本脚本随即什么也不做。
 *
 * 为什么必须是纯 vanilla JS（不 L.require / 不用 LuCI 的 ui.js）:
 *   登录页是未登录状态，不保证 LuCI 的 JS 模块已加载（argon 登录页虽引入 luci.js，
 *   但这属于主题实现细节，不能依赖）。因此这里只用原生 DOM API 自建浮层。
 *
 * 去重:
 *   用 localStorage 保存「已展示过的内容指纹」。指纹相同 => 不再弹；
 *   内容变化（新失败、包名或原因变了）=> 指纹变化 => 重新弹。
 *   刻意不写服务端 ack 文件：多浏览器/多设备各自独立，也不污染 overlay。
 *
 * 注意: 本文件在页面 footer 处同步加载，此时 document.body 已存在；
 *       仍按 DOMContentLoaded 兜底，避免将来被移到 <head> 时静默失效。
 */
(function () {
    'use strict';

    /* localStorage 的键名。加版本后缀，方便将来调整去重语义时不与旧值混淆。 */
    var STORAGE_KEY = 'luci.restorePkgNotice.fingerprint.v1';

    /* 单次渲染的上限，避免失败记录异常多时把页面撑爆（服务端已各自截断，这里再兜一层）。 */
    var MAX_PACKAGES = 50;
    var MAX_ENTRIES = 20;

    /* 每类失败的说明与解决方案。key 与服务端 error_class 对齐。 */
    var GUIDANCE = {
        fetch_error: {
            title: '下载失败（网络或镜像不可达）',
            cause: '软件包或其索引下载不完整，通常是网络不通、镜像暂时不可用，或索引文件被截断。',
            fix: [
                '检查设备网络是否正常（能否访问外网）。',
                '确认软件源镜像当前可达；必要时在「系统 → 软件包 → 配置」里换一个镜像。',
                '在 SSH 里重新执行 apk update，确认索引能完整下载后再重试安装。'
            ]
        },
        package_not_found: {
            title: '软件包不存在（源索引里找不到）',
            cause: '当前软件源配置里没有这个包，可能是包名已更名/被移除，或源索引不完整。',
            fix: [
                '检查「系统 → 软件包 → 配置」里的软件源是否包含所需仓库。',
                '确认包名是否正确：该包可能已更名、合并进其它包，或已被上游移除。',
                '执行 apk update 重新拉取完整索引；若仍缺失，需要更换包含该包的源。'
            ]
        }
    };

    /* 未知 error_class 的兜底文案：宁可给通用建议，也不要显示空白。 */
    var FALLBACK_GUIDANCE = {
        title: '安装失败',
        cause: '安装该软件包时出错，具体原因见下方原始信息。',
        fix: [
            '检查设备网络与软件源配置。',
            '执行 apk update 后重试安装。',
            '若仍失败，可在 SSH 里手动执行 apk add <包名> 查看完整报错。'
        ]
    };

    /* ---------------------------------------------------------------- 工具函数 */

    /* 安全取字符串：服务端字段缺失或类型不对时统一成空串。 */
    function str(value) {
        return (typeof value === 'string') ? value : '';
    }

    /* 安全取数字：非有限数字返回 null（服务端用 null 表示"没有这个值"）。 */
    function num(value) {
        return (typeof value === 'number' && isFinite(value)) ? value : null;
    }

    /* 安全取数组：非数组一律当空数组，避免 forEach 抛异常。 */
    function arr(value) {
        return Array.isArray(value) ? value : [];
    }

    /* 去掉首尾空白；同时把内部连续空白压成单个空格，保证单行展示。 */
    function tidy(text, limit) {
        var out = str(text).replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
        if (limit && out.length > limit) {
            out = out.slice(0, limit - 1) + '…';
        }
        return out;
    }

    /* 读取 localStorage：隐私模式/被禁用时会抛异常，一律当作"没有存过"。 */
    function readStored() {
        try {
            return window.localStorage.getItem(STORAGE_KEY);
        } catch (e) {
            return null;
        }
    }

    /* 写入 localStorage：失败不影响本次提示展示，只是下次可能重复弹。 */
    function writeStored(value) {
        try {
            window.localStorage.setItem(STORAGE_KEY, value);
        } catch (e) {
            /* 忽略：无痕模式或配额不足时，退化为每次都提示。 */
        }
    }

    /* ------------------------------------------------------------ DOM 构造工具 */

    /* 简化的 createElement：cls 为 class 名，text 为文本内容（用 textContent 防注入）。 */
    function el(tag, cls, text) {
        var node = document.createElement(tag);

        if (cls) {
            node.className = cls;
        }
        if (text !== undefined && text !== null) {
            node.textContent = String(text);
        }

        return node;
    }

    /* -------------------------------------------------------------- 内容整理 */

    /*
     * 把服务端数据整理成「包名列表 + 按类分组的失败原因」。
     * 服务端已经做过按 (class,stage,message,cause) 去重并给出 count，
     * 这里只做展示层归并，不改变语义。
     */
    function normalize(data) {
        var out = {
            fingerprint: tidy(data.fingerprint, 200),
            packages: [],
            groups: []
        };
        var i, item, name;
        var seenPkg = {};
        var byClass = {};
        var groupList = [];

        /* 包名去重并截断。 */
        var pkgs = arr(data.packages);

        for (i = 0; i < pkgs.length && out.packages.length < MAX_PACKAGES; i++) {
            name = tidy(pkgs[i], 120);

            if (!name || Object.prototype.hasOwnProperty.call(seenPkg, name)) {
                continue;
            }

            seenPkg[name] = true;
            out.packages.push(name);
        }

        /* 按 error_class 归并条目，保留首次出现的顺序。 */
        var entries = arr(data.entries);

        for (i = 0; i < entries.length && i < MAX_ENTRIES; i++) {
            item = entries[i] || {};

            var cls = tidy(item.class, 60) || 'unknown';
            var group = byClass[cls];

            if (!group) {
                group = {
                    cls: cls,
                    entries: []
                };
                byClass[cls] = group;
                groupList.push(group);
            }

            group.entries.push({
                stage: tidy(item.stage, 40),
                message: tidy(item.message, 400),
                cause: tidy(item.cause, 400),
                target: tidy(item.target, 300),
                tool: tidy(item.tool, 40),
                exit: num(item.exit),
                count: num(item.count) || 1
            });
        }

        out.groups = groupList;

        return out;
    }

    /* 取某类的说明：已知类用专门文案，未知类用兜底文案。 */
    function guidanceFor(cls) {
        return Object.prototype.hasOwnProperty.call(GUIDANCE, cls) ? GUIDANCE[cls] : FALLBACK_GUIDANCE;
    }

    /* ---------------------------------------------------------------- 渲染 */

    /* 渲染一个类别的「原因 + 解决方案」小节。 */
    function renderGroup(group) {
        var guide = guidanceFor(group.cls);
        var section = el('div', 'rp-notice-group');

        section.appendChild(el('div', 'rp-notice-group-title', guide.title));

        /* 每类失败的原因取自 error_class / stage / message / likely_cause。 */
        section.appendChild(el('div', 'rp-notice-label', '失败原因'));

        var causeList = el('ul', 'rp-notice-list');

        causeList.appendChild(el('li', null, guide.cause));

        group.entries.forEach(function (entry) {
            var parts = [];
            var detail;

            if (entry.stage) {
                parts.push('阶段：' + entry.stage);
            }
            if (entry.tool) {
                parts.push('工具：' + entry.tool);
            }
            if (entry.exit !== null) {
                parts.push('退出码：' + entry.exit);
            }
            if (entry.count > 1) {
                parts.push('出现 ' + entry.count + ' 次');
            }

            detail = parts.join('，');

            if (entry.cause) {
                causeList.appendChild(el('li', null, entry.cause + (detail ? '（' + detail + '）' : '')));
            } else if (detail) {
                causeList.appendChild(el('li', null, detail));
            }

            if (entry.message) {
                causeList.appendChild(el('li', 'rp-notice-raw', '原始报错：' + entry.message));
            }

            if (entry.target) {
                causeList.appendChild(el('li', 'rp-notice-raw', '相关目标：' + entry.target));
            }
        });

        section.appendChild(causeList);

        /* 解决方案：每类固定的处置建议。 */
        section.appendChild(el('div', 'rp-notice-label', '解决方案'));

        var fixList = el('ul', 'rp-notice-list');

        guide.fix.forEach(function (line) {
            fixList.appendChild(el('li', null, line));
        });

        section.appendChild(fixList);

        return section;
    }

    /* 构建整块浮层。返回 { overlay, dismiss }，dismiss 供关闭按钮与 Esc 复用。 */
    function buildOverlay(model) {
        var overlay = el('div', 'rp-notice-overlay');
        var card = el('div', 'rp-notice-card');

        /* 角色/无障碍：这是模态提示，读屏应能识别。 */
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.setAttribute('aria-label', '备份软件包恢复失败提示');

        var header = el('div', 'rp-notice-header');

        header.appendChild(el('div', 'rp-notice-title', '备份软件包恢复失败'));

        var closeBtn = el('button', 'rp-notice-close', '×');

        closeBtn.setAttribute('type', 'button');
        closeBtn.setAttribute('aria-label', '关闭提示');
        header.appendChild(closeBtn);
        card.appendChild(header);

        var body = el('div', 'rp-notice-body');

        /* 概览：说明这次失败发生在第二次尝试之后，脚本已不再自动重启。 */
        var intro = el('p', 'rp-notice-intro');

        intro.appendChild(document.createTextNode(
            '设备启动时恢复备份软件包未完全成功（已重试一轮，共 '
            + model.packages.length + ' 个包受影响）。为避免反复重启，脚本已停止重试。'
            + '以下包需要你手动处理：'
        ));
        body.appendChild(intro);

        /* 一、失败包名列表。 */
        body.appendChild(el('div', 'rp-notice-label', '失败的软件包'));

        if (model.packages.length) {
            var pkgWrap = el('div', 'rp-notice-pkgs');

            model.packages.forEach(function (name) {
                pkgWrap.appendChild(el('code', 'rp-notice-pkg', name));
            });

            body.appendChild(pkgWrap);
        } else {
            body.appendChild(el('p', 'rp-notice-raw', '（未能解析出包名，详见下方原因）'));
        }

        /* 二、每类失败的原因；三、解决方案（与原因同段呈现，便于对照）。 */
        model.groups.forEach(function (group) {
            body.appendChild(renderGroup(group));
        });

        /* 提示用户：关闭后不会再次自动弹出，除非失败内容发生变化。 */
        body.appendChild(el('p', 'rp-notice-foot',
            '关闭后，同样的失败内容不会再次弹出；若之后出现新的失败，会再次提示。'));

        card.appendChild(body);

        var footer = el('div', 'rp-notice-actions');
        var okBtn = el('button', 'rp-notice-ok', '我知道了');

        okBtn.setAttribute('type', 'button');
        footer.appendChild(okBtn);
        card.appendChild(footer);

        overlay.appendChild(card);

        var dismissed = false;

        /* 关闭：移除浮层并把当前指纹写进 localStorage（下次同内容不再弹）。 */
        function dismiss() {
            if (dismissed) {
                return;
            }

            dismissed = true;

            writeStored(model.fingerprint);

            document.removeEventListener('keydown', onKeydown, true);

            if (overlay.parentNode) {
                overlay.parentNode.removeChild(overlay);
            }
        }

        /* Esc 关闭：捕获阶段监听，避免被页面其它快捷键处理抢先。 */
        function onKeydown(ev) {
            if (ev.key === 'Escape' || ev.keyCode === 27) {
                ev.preventDefault();
                dismiss();
            }
        }

        closeBtn.addEventListener('click', dismiss);
        okBtn.addEventListener('click', dismiss);

        /* 点遮罩空白处关闭；点卡片内部不关（避免误触丢失信息）。 */
        overlay.addEventListener('click', function (ev) {
            if (ev.target === overlay) {
                dismiss();
            }
        });

        document.addEventListener('keydown', onKeydown, true);

        return {
            overlay: overlay,
            dismiss: dismiss
        };
    }

    /* -------------------------------------------------------------- 样式注入 */

    /*
     * 样式内联注入：不新增 CSS 文件、不改主题，避免与主题样式/构建流程耦合。
     * 只注入一次（用 data 属性标记），即便本脚本被重复加载也不会重复插入。
     */
    function injectStyle() {
        if (document.getElementById('rp-notice-style')) {
            return;
        }

        var style = document.createElement('style');

        style.id = 'rp-notice-style';
        style.appendChild(document.createTextNode([
            /* 用 top/right/bottom/left 而不是 inset：后者需要较新的浏览器，
             * OpenWrt 用户可能用较旧的终端浏览器，显式四边兼容性更好。 */
            '.rp-notice-overlay{position:fixed;top:0;right:0;bottom:0;left:0;z-index:10000;',
            'background:rgba(0,0,0,.45);',
            'display:flex;align-items:center;justify-content:center;padding:16px;}',
            '.rp-notice-card{background:#fff;color:#222;width:100%;max-width:640px;max-height:85vh;',
            'display:flex;flex-direction:column;border-radius:8px;box-shadow:0 8px 32px rgba(0,0,0,.3);',
            'font-size:14px;line-height:1.55;overflow:hidden;}',
            '.rp-notice-header{display:flex;align-items:center;justify-content:space-between;',
            'padding:14px 18px;border-bottom:1px solid #e5e5e5;background:#fff4e5;}',
            '.rp-notice-title{font-size:16px;font-weight:700;color:#8a4b00;}',
            '.rp-notice-close{border:0;background:transparent;font-size:22px;line-height:1;',
            'cursor:pointer;color:#666;padding:0 4px;}',
            '.rp-notice-close:hover{color:#000;}',
            '.rp-notice-body{padding:14px 18px;overflow-y:auto;}',
            '.rp-notice-intro{margin:0 0 12px;}',
            '.rp-notice-label{margin:14px 0 6px;font-weight:700;}',
            '.rp-notice-pkgs{display:flex;flex-wrap:wrap;gap:6px;}',
            '.rp-notice-pkg{background:#f2f4f7;border:1px solid #d9dee5;border-radius:4px;',
            'padding:1px 6px;font-family:monospace;font-size:13px;}',
            '.rp-notice-group{border-top:1px dashed #ddd;margin-top:12px;padding-top:4px;}',
            '.rp-notice-group-title{font-weight:700;color:#8a4b00;}',
            '.rp-notice-list{margin:4px 0 0;padding-left:20px;}',
            '.rp-notice-list li{margin:2px 0;}',
            '.rp-notice-raw{color:#666;font-size:12.5px;word-break:break-word;}',
            '.rp-notice-foot{margin:14px 0 0;color:#666;font-size:12.5px;}',
            '.rp-notice-actions{padding:12px 18px;border-top:1px solid #e5e5e5;text-align:right;',
            'background:#fafafa;}',
            '.rp-notice-ok{border:0;border-radius:4px;background:#0d6efd;color:#fff;',
            'padding:7px 18px;font-size:14px;cursor:pointer;}',
            '.rp-notice-ok:hover{background:#0b5ed7;}',
            '@media (prefers-color-scheme:dark){',
            '.rp-notice-card{background:#1f2430;color:#e6e6e6;}',
            '.rp-notice-header{background:#3a2a12;border-bottom-color:#333a47;}',
            '.rp-notice-title{color:#ffcc80;}',
            '.rp-notice-group-title{color:#ffcc80;}',
            '.rp-notice-pkg{background:#2a3140;border-color:#3b4354;color:#e6e6e6;}',
            '.rp-notice-actions{background:#252b37;border-top-color:#333a47;}',
            '.rp-notice-close{color:#bbb;}}'
        ].join('')));

        (document.head || document.documentElement).appendChild(style);
    }

    /* ---------------------------------------------------------------- 主流程 */

    function main() {
        var data = window.__RESTORE_PKG_NOTICE__;

        /* 服务端没有注入（无失败记录）：什么都不做，绝不污染正常页面。 */
        if (!data || typeof data !== 'object') {
            return;
        }

        var model = normalize(data);

        /* 没有可用内容或没有指纹：不弹，避免"无法去重 => 每次刷新都弹"。 */
        if (!model.groups.length || !model.fingerprint) {
            return;
        }

        /* 同指纹已经展示并关闭过：不再打扰。内容变化时指纹不同，会重新弹。 */
        if (readStored() === model.fingerprint) {
            return;
        }

        injectStyle();

        var built = buildOverlay(model);

        document.body.appendChild(built.overlay);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', main);
    } else {
        main();
    }
})();
