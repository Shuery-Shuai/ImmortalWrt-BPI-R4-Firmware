#!/bin/bash
# 文件: scripts/inputs/mods/14-luci-restore-pkg-notice.sh
# 用途: 构建期向 LuCI 的上游模板注入「备份软件包恢复失败」提示脚本。
#
# 背景（为什么必须打补丁而不是放一份整文件覆盖）:
#   LuCI 页面渲染链路是 luci-base 的 footer.ut 再 include 主题自己的 footer。
#   常规页面走 modules/luci-base/ucode/template/view.ut -> include('footer')；
#   而本固件用的 argon 主题自带 themes/argon/sysauth.ut，
#   dispatcher.uc 选登录页模板时优先用主题的 sysauth（只有主题没提供时才回退到 luci-base 的），
#   所以登录页根本不经过 luci-base 的 footer.ut，而是
#     themes/argon/sysauth.ut -> include('themes/argon/footer_login') -> page_scripts。
#   => 想同时覆盖「已登录页面」与「未登录的登录页」，必须注入两个锚点。
#
#   为什么不往 files/ 放一份完整的 footer.ut：那是整文件覆盖，上游一升级
#   （新主题、新的 media_error / rollback 逻辑、模板语法调整）就会被我们这份旧副本
#   静默替换掉，缺陷只在运行时才暴露。注入一行则可以与上游的其余改动共存。
#
# 注入内容:
#   一个单行的 ucode 模板块（{% ... %}），职责：
#     1. 用 fs 模块的 readfile 读 /etc/backup/restore_pkg_failures.ndjson；
#     2. 逐行 json() 解析（纯 ucode 内建，不调 jq、不起子进程）；
#     3. 把失败包名、按类去重后的失败原因内联成
#        window.__RESTORE_PKG_NOTICE__ = {...}，并附内容指纹（FUSE 哈希 + 字节数）；
#     4. 文件不存在 / 为空 / 没有可用记录时【不输出任何内容】。
#   真正的界面逻辑在 scripts/inputs/mods/assets/restore-pkg-notice.js，
#   注入的这一行只负责把数据送到前端（登录页不保证加载得到 LuCI 的 JS 模块）。
#
# 前端资源由本 mod 自己投放（不再放仓库 files/）:
#   资源随 mod 一起放在 assets/ 下，注入成功后才复制到 immortalwrt/files/
#   www/luci-static/resources/。这样「注入」与「前端资源」同生共死：
#     · 注入失败 => 返回非 0，且不投放 JS，固件里不会留下永不执行的死文件；
#     · 取消本功能 => 删掉本 mod 与 assets/ 即可，不必再去 files/ 里找一个
#       容易被遗忘的 js（旧做法就是这么埋下残留风险的）。
#   时机上必须由 mod 投放而不是放 files/：files/ 在 copy_custom_files 阶段就被整体
#   复制进 immortalwrt/，早于 DIY PART2；mod 此时往 immortalwrt/files/ 写，仍在
#   打包 rootfs 之前，因此会正常进固件。这与 generate-release-info.sh 写
#   immortalwrt/files/etc/uci-defaults/99-release-info 的模式一致。
#
# 幂等与断言（本脚本的硬约束）:
#   · 注入前先用 grep -F 断言锚点原文存在；锚点不命中一律 log ERROR 并返回非 0，
#     绝不静默跳过——静默跳过的后果是用户永远收不到提示且没人知道。
#   · 已注入过（能 grep 到 script 资源路径）就跳过，重复执行不会重复插入。
#   · 注入后用「下一行逐字节等于 payload」+「标记串恰好出现 1 次」做双重复核。
#
# 上游升级时的维护动作:
#   若 LuCI 改了 footer.ut / argon footer_login.ut 的 include 写法，本脚本会在构建期
#   以 ERROR 中止（而不是产出没有提示的固件）。届时只需更新下方
#   _restore_pkg_notice_patch_targets 里对应条目的锚点原文即可，注入逻辑无需改动。
#
# 依赖: 需要预先 source scripts/libs/load.sh 以使用 log 函数
#       若单独运行，脚本内置后备日志函数
# 用法:
#   source scripts/inputs/mods/14-luci-restore-pkg-notice.sh
#   apply_restore_pkg_notice_patch
#
# 约定: 调用方的工作目录必须是 immortalwrt 根（与 diy-part2.sh 中其它 mod 一致），
#       因为下面的 feeds/ 路径都是相对 immortalwrt 根的。
#######################################

# 后备日志函数（与仓库其它 mod 保持同一形态）
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 输出要注入的 ucode 模板块（单行）
#
# 用带引号的 heredoc 原样输出：里面的 $ / ` / \ 都不做 shell 展开，
# 因此这段 ucode 可以直接按字面维护，不必为 shell 转义再套一层。
#
# 变量统一以 rp 前缀命名，避免与模板作用域里的 theme / version / dispatcher 撞名。
#
# 输出:
#   stdout: 恰好一行 {% ... %}（heredoc 自带的行尾换行）
#######################################
_restore_pkg_notice_emit_payload() {
    cat <<'RESTORE_PKG_NOTICE_PAYLOAD_EOF'
{% import { readfile } from 'fs'; try { const rpFF = '/etc/backup/restore_pkg_failures.ndjson'; const rpNF = '/etc/backup/restore_pkg_notices.ndjson'; let rpRaw = ''; try { const rpA = readfile(rpFF); if (type(rpA) == 'string') rpRaw += rpA; } catch (rpEA) { } let rpNote = ''; try { const rpB = readfile(rpNF); if (type(rpB) == 'string') rpNote += rpB; } catch (rpEB) { } rpRaw += rpNote; if (length(trim(rpRaw))) { let rpHash = 2166136261; for (let rpI = 0; rpI < length(rpRaw); rpI++) rpHash = ((rpHash ^ ord(rpRaw, rpI)) * 16777619) % 4294967296; let rpSeen = {}; let rpPkgs = []; let rpIdx = {}; let rpEnts = []; for (let rpLine in split(rpRaw, '\n')) { rpLine = trim(rpLine); if (!length(rpLine)) continue; let rpRec = null; try { rpRec = json(rpLine); } catch (rpE) { rpRec = null; } if (type(rpRec) != 'object') continue; let rpNames = []; if (type(rpRec.package) == 'string' && length(rpRec.package)) push(rpNames, rpRec.package); if (type(rpRec.missing_packages) == 'array') for (let rpN in rpRec.missing_packages) if (type(rpN) == 'string' && length(rpN)) push(rpNames, rpN); for (let rpN in rpNames) if (!(rpN in rpSeen)) { rpSeen[rpN] = true; if (length(rpPkgs) < 50) push(rpPkgs, rpN); } let rpClass = (type(rpRec.error_class) == 'string') ? rpRec.error_class : ''; let rpStage = (type(rpRec.stage) == 'string') ? rpRec.stage : ''; let rpMsg = (type(rpRec.message) == 'string') ? rpRec.message : ''; let rpCause = (type(rpRec.likely_cause) == 'string') ? rpRec.likely_cause : ''; let rpKey = rpClass + '\t' + rpStage + '\t' + rpMsg + '\t' + rpCause; if (rpKey in rpIdx) { rpIdx[rpKey].count++; continue; } if (length(rpEnts) >= 20) continue; let rpEnt = { class: rpClass, stage: rpStage, message: rpMsg, cause: rpCause, target: (type(rpRec.target) == 'string') ? rpRec.target : '', tool: (type(rpRec.tool) == 'string') ? rpRec.tool : '', exit: (type(rpRec.exit_code) == 'int') ? rpRec.exit_code : null, count: 1 }; rpIdx[rpKey] = rpEnt; push(rpEnts, rpEnt); } for (let rpL2 in split(rpNote, '\n')) { rpL2 = trim(rpL2); if (!length(rpL2)) continue; let rpR2 = null; try { rpR2 = json(rpL2); } catch (rpE2) { rpR2 = null; } if (type(rpR2) != 'object') continue; let rpOld = (type(rpR2.package) == 'string') ? rpR2.package : ''; let rpNew = (type(rpR2.replacement) == 'string') ? rpR2.replacement : ''; let rpMsg2 = (type(rpR2.message) == 'string') ? rpR2.message : ''; let rpCat = (type(rpR2.category) == 'string' && length(rpR2.category)) ? rpR2.category : 'renamed_package'; if (!length(rpOld)) continue; if (!(rpOld in rpSeen)) { rpSeen[rpOld] = true; if (length(rpPkgs) < 50) push(rpPkgs, rpOld); } let rpK2 = rpCat + '\t' + rpOld + '\t' + rpNew; if (rpK2 in rpIdx) { rpIdx[rpK2].count++; continue; } if (length(rpEnts) >= 20) continue; let rpE2 = { class: rpCat, stage: '', message: rpMsg2, cause: '', target: rpNew, tool: '', exit: null, count: 1 }; rpIdx[rpK2] = rpE2; push(rpEnts, rpE2); } if (length(rpEnts)) { let rpOut = { fingerprint: sprintf('%08x', rpHash) + '-' + sprintf('%x', length(rpRaw)), total: length(rpEnts), packages: rpPkgs, entries: rpEnts }; print('\n<script>window.__RESTORE_PKG_NOTICE__='); print(replace(replace(replace(sprintf('%J', rpOut), /</g, '\\u003c'), /\u2028/g, '\\u2028'), /\u2029/g, '\\u2029')); print(';</script><script src="/luci-static/resources/restore-pkg-notice.js"></script>\n'); } } } catch (rpTop) { } %}
RESTORE_PKG_NOTICE_PAYLOAD_EOF
}

#######################################
# 向单个模板文件注入 payload（幂等 + 断言锚点）
#
# 参数：
#   $1 - 目标模板路径（相对 immortalwrt 根）
#   $2 - 锚点原文（必须逐字节匹配；用 grep -F 固定串匹配，不做正则）
#   $3 - payload 文件路径（内容恰好一行）
#   $4 - 幂等标记串（注入后应恰好出现 1 次）
#
# 返回：
#   0 - 已注入成功，或此前已经注入过（幂等）
#   1 - 目标不存在 / 锚点不命中 / 锚点重复 / 注入结果校验失败
#######################################
_restore_pkg_notice_patch_one() {
    local target="$1"
    local anchor="$2"
    local payload_file="$3"
    local marker="$4"

    local hits=0
    local anchor_hits=0
    local lineno=''
    local inserted=''
    local expected=''

    if [[ ! -f "${target}" ]]; then
        log ERROR "restore-pkg-notice: 目标模板不存在：${target}（feeds 是否已 update？）"
        return 1
    fi

    # 幂等：能 grep 到资源路径就说明本脚本此前已经注入过。
    # grep -c 在 0 命中时返回 1，用 || true 只抑制退出码，仍保留它打印的 "0"。
    hits="$(grep -cF -- "${marker}" "${target}" 2>/dev/null || true)"
    hits="${hits:-0}"
    if [[ "${hits}" -gt 1 ]]; then
        log ERROR "restore-pkg-notice: ${target} 中已有 ${hits} 处注入（应恰好 1 处），请人工检查"
        return 1
    fi
    if [[ "${hits}" -eq 1 ]]; then
        log INFO "restore-pkg-notice: ${target} 已注入，跳过（幂等）"
        return 0
    fi

    # 断言锚点：命中 0 次视为上游模板已改版，必须让构建失败而不是静默跳过。
    anchor_hits="$(grep -cF -- "${anchor}" "${target}" 2>/dev/null || true)"
    anchor_hits="${anchor_hits:-0}"
    if [[ "${anchor_hits}" -eq 0 ]]; then
        log ERROR "restore-pkg-notice: 锚点未命中 ${target}"
        log ERROR "restore-pkg-notice: 期望的锚点原文：${anchor}"
        log ERROR "restore-pkg-notice: 上游模板可能已改版，请更新本 mod 的锚点"
        return 1
    fi
    if [[ "${anchor_hits}" -gt 1 ]]; then
        log ERROR "restore-pkg-notice: 锚点在 ${target} 中出现 ${anchor_hits} 次，无法确定唯一注入位置"
        log ERROR "restore-pkg-notice: 锚点原文：${anchor}"
        return 1
    fi

    lineno="$(grep -nF -- "${anchor}" "${target}" | head -n 1 | cut -d: -f1)"
    if [[ -z "${lineno}" ]]; then
        log ERROR "restore-pkg-notice: 无法取得锚点行号：${target}"
        return 1
    fi

    # 用 sed 的 r 命令「在指定行之后插入文件内容」：
    # payload 从文件读入，因此其内部的 / \ $ ` " 等字符完全不需要再做 sed 转义，
    # 比把长行拼进 sed 的 a\ 命令要稳得多。
    if ! sed -i "${lineno}r ${payload_file}" "${target}"; then
        log ERROR "restore-pkg-notice: sed 注入失败：${target}"
        return 1
    fi

    # 复核 1：锚点的下一行必须逐字节等于 payload（证明插在了正确位置、且只插了一行）。
    inserted="$(sed -n "$((lineno + 1))p" "${target}")"
    expected="$(cat "${payload_file}")"
    if [[ "${inserted}" != "${expected}" ]]; then
        log ERROR "restore-pkg-notice: 注入结果校验失败（锚点下一行与 payload 不一致）：${target}"
        return 1
    fi

    # 复核 2：标记串恰好出现 1 次。
    hits="$(grep -cF -- "${marker}" "${target}" 2>/dev/null || true)"
    hits="${hits:-0}"
    if [[ "${hits}" -ne 1 ]]; then
        log ERROR "restore-pkg-notice: 注入后标记串出现 ${hits} 次（应为 1 次）：${target}"
        return 1
    fi

    log INFO "restore-pkg-notice: 已向 ${target} 注入提示脚本（锚点在第 ${lineno} 行之后）"
    return 0
}

#######################################
# 投放前端资源到 immortalwrt/files/（供打包进 rootfs）
#
# 资源随 mod 放在自身目录下的 assets/，不预先存在于仓库 files/。
# 这样「注入模板」与「投放 js」是同一件事的两半：注入没成功就不会有 js。
#
# 源路径以本文件所在目录解析，因此无论调用方 cwd 在哪都能找到 assets/。
#
# 参数：
#   $1 - 目标根（immortalwrt 根，即 files/ 的父目录）
#
# 返回：
#   0 - 已投放（或目标内容已是最新）
#   1 - 源文件缺失 / 目录创建或复制失败
#######################################
_restore_pkg_notice_install_asset() {
    local root="$1"
    local src_dir=''
    local src=''
    local dst_dir=''
    local dst=''

    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assets" || return 1
    src="${src_dir}/restore-pkg-notice.js"
    dst_dir="${root}/files/www/luci-static/resources"
    dst="${dst_dir}/restore-pkg-notice.js"

    if [[ ! -f "${src}" ]]; then
        log ERROR "restore-pkg-notice: 前端资源缺失：${src}"
        return 1
    fi

    if ! mkdir -p "${dst_dir}"; then
        log ERROR "restore-pkg-notice: 无法创建目标目录：${dst_dir}"
        return 1
    fi

    # 用 cp -f 而不是软链：rootfs 打包只收实体文件，软链在目标树里会断。
    if ! cp -f -- "${src}" "${dst}"; then
        log ERROR "restore-pkg-notice: 复制前端资源失败：${src} -> ${dst}"
        return 1
    fi

    # 复核：目标必须存在且与源逐字节一致（防止 cp 半途失败留下截断文件）。
    if ! cmp -s -- "${src}" "${dst}"; then
        log ERROR "restore-pkg-notice: 前端资源复制后不一致：${dst}"
        return 1
    fi

    log INFO "restore-pkg-notice: 已投放前端资源 ${dst}"
    return 0
}

#######################################
# 对全部目标模板应用注入
#
# 功能:
#   把单行 ucode payload 注入两个锚点，覆盖「已登录页面」与「未登录登录页」：
#     A. luci-base footer.ut —— 所有 include('footer') 的页面（view/sysauth/error404/csrftoken）
#        锚点是 include 主题 footer 的那一行，因此注入内容落在主题页脚之后。
#     B. argon footer_login.ut —— argon 登录页（主题自带 sysauth，不经过 luci-base footer.ut）
#        锚点是 include page_scripts 的那一行，位于 </body> 之前。
#
#   两个锚点都注入成功后，才投放前端资源（js）。顺序刻意如此：
#   注入失败时不应留下永远不会被引用的 js 死文件。
#
# 无参数。调用方 cwd 必须是 immortalwrt 根。
#
# 返回：
#   0 - 两个目标均已注入（或此前已注入）且前端资源已投放
#   1 - 任一目标失败，或前端资源投放失败
#
# 示例：
#   apply_restore_pkg_notice_patch
#######################################
apply_restore_pkg_notice_patch() {
    # 幂等标记：前端资源路径。注入后它恰好出现 1 次，且不依赖 payload 里的其它字符。
    local marker='/luci-static/resources/restore-pkg-notice.js'
    local payload_dir=''
    local payload_file=''
    local rc=0

    payload_dir="$(mktemp -d)" || {
        log ERROR "restore-pkg-notice: 无法创建临时目录"
        return 1
    }
    payload_file="${payload_dir}/payload.ut"

    if ! _restore_pkg_notice_emit_payload >"${payload_file}"; then
        log ERROR "restore-pkg-notice: 无法生成注入内容"
        rm -rf -- "${payload_dir}"
        return 1
    fi

    # 锚点 A：luci-base footer.ut 中「include 主题 footer」的原始行。
    # 必须用单引号：这段是上游模板源码里的**字面文本**，` 与 ${theme} 都要原样保留，
    # 一旦让 shell 展开就再也匹配不上（此处的 SC2016 正是我们想要的行为）。
    # shellcheck disable=SC2016  # 锚点需按字面匹配上游模板源码，不能展开
    if ! _restore_pkg_notice_patch_one \
        'feeds/luci/modules/luci-base/ucode/template/footer.ut' \
        '{% include(`themes/${theme}/footer`) %}' \
        "${payload_file}" "${marker}"; then
        rc=1
    fi

    # 锚点 B：argon 登录页 footer_login.ut 末尾 include page_scripts 的原始行。
    if ! _restore_pkg_notice_patch_one \
        'feeds/luci/themes/luci-theme-argon/ucode/template/themes/argon/footer_login.ut' \
        "{% include('themes/' + theme + '/page_scripts', { is_login: true }) %}" \
        "${payload_file}" "${marker}"; then
        rc=1
    fi

    rm -rf -- "${payload_dir}"

    # 只有注入全部成功才投放前端资源，避免留下无引用的死文件。
    if [[ "${rc}" -eq 0 ]]; then
        if ! _restore_pkg_notice_install_asset '.'; then
            rc=1
        fi
    fi

    if [[ "${rc}" -eq 0 ]]; then
        log INFO "restore-pkg-notice: LuCI 恢复失败提示注入完成"
    else
        log ERROR "restore-pkg-notice: LuCI 恢复失败提示注入未全部成功（未投放前端资源）"
    fi

    return "${rc}"
}

# 若直接运行脚本，则执行注入
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    apply_restore_pkg_notice_patch
fi
