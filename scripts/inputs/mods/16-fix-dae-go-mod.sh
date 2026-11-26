#!/bin/bash
# 文件: scripts/inputs/mods/16-fix-dae-go-mod.sh
# 用途: 修复 dae 在 OpenWrt 下的编译失败（go-mod 目录与 go list 冲突）
#
# 背景（现象与真因）:
#   dae 的上游源码包 dae-full-src.zip 自带 go-mod/ 目录（离线依赖，含两万余项，
#   形如 go-mod/github.com/pkg@v1.2.3/）。这个目录**位于源码树内部**。
#   OpenWrt 的 Go 打包流程会执行 go list ./...，而 Go 会递归扫描源码树，
#   把 go-mod/ 里那些 `@version` 目录当成包路径去解析，于是报错：
#     directory go-mod/github.com/.../spew outside main module or its selected dependencies
#     can only use path@version syntax with 'go get' and 'go install' in module-aware mode
#   最终表现为 "no Go files in ....go_work/build" 而编译失败。
#
#   报错文案指向 Go modules 语义，极易误导成「Go 版本不对」或「module cache 路径错」，
#   实际是**目录布局**问题：依赖目录不能放在 main module 的扫描范围里。
#   实测：把 go-mod 移到源码树外，go list ./... 与 go build 立刻全部成功。
#
# 修复动作（改 dae 的 Makefile，共三处）:
#   1. 编译前把 $(PKG_BUILD_DIR)/go-mod 移到 $(PKG_BUILD_DIR).modcache/go-mod
#      （兄弟目录，不在 main module 内）；
#   2. export GOMODCACHE 指向移出后的位置，并设 GOFLAGS=-mod=mod；
#   3. go generate 改用相对路径（在源码目录内执行），绝对路径会被当成包导入路径。
#
# 幂等: 已含标记串则跳过，重复执行安全。
# 依赖: 需要预先 source scripts/libs/load.sh 以使用 log 函数；单独运行时内置后备
# 用法:
#   source scripts/inputs/mods/16-fix-dae-go-mod.sh
#   fix_dae_go_mod [makefile_path]
#
# 参数:
#   $1 : 可选，dae Makefile 路径，默认 feeds/packages/net/dae/Makefile
#######################################

# 后备日志函数（与仓库其它 mod 保持同一形态）
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s
' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 修复 dae 的 go-mod 布局问题
#
# 参数：
#   $1 - (可选) dae Makefile 路径，默认 feeds/packages/net/dae/Makefile
#
# 返回：
#   0 - 修改成功，或已修过（幂等）
#   0 - 目标文件不存在时仅告警（该包可能未启用）
#   1 - 找到了 Makefile 但结构与预期不符（上游改版），需要人工检查
#######################################
fix_dae_go_mod() {
    local makefile="${1:-feeds/packages/net/dae/Makefile}"
    local marker='Moved out of the source tree'

    if [[ ! -f "${makefile}" ]]; then
        log WARN "dae Makefile 不存在：${makefile}（未启用 dae？跳过）"
        return 0
    fi

    # 幂等：已注入标记串则跳过
    if grep -qF "${marker}" "${makefile}" 2>/dev/null; then
        log INFO "dae go-mod 修复已存在，跳过（幂等）"
        return 0
    fi

    # 断言锚点：原 Makefile 必须有这两行，否则说明上游已改版，不能盲目替换。
    # 锚点是 Makefile 源码里的**字面文本**，$ 必须保持原样，不能被 shell 展开。
    # shellcheck disable=SC2016
    local anchor_gen='go generate $(PKG_BUILD_DIR)/control/control.go'
    if ! grep -qF "${anchor_gen}" "${makefile}"; then
        log ERROR "dae Makefile 结构已变：找不到 go generate 行（${makefile}）"
        log ERROR "上游可能已修复该问题，请复查后移除本 mod"
        return 1
    fi

    # 备份后原地改写。用临时文件 + mv，避免中途失败留下半截 Makefile。
    local tmp
    tmp="$(mktemp)" || {
        log ERROR "无法创建临时文件"
        return 1
    }

    # 处理逻辑放在 awk 里：按行替换，不依赖 sed 的多行语法差异。
    awk -v marker="${marker}" '
        BEGIN { injected = 0 }
        # 1) define Build/Compile 之后立即插入「移出 go-mod」的三行
        /^define Build\/Compile$/ && !injected {
            print
            print "\t# " marker ": go-mod 在源码树内会被 go list ./... 误当成包路径。"
            print "\t# 先移到兄弟目录，再用 GOMODCACHE 指回，避开扫描范围。"
            print "\tmkdir -p $(PKG_BUILD_DIR).modcache"
            print "\trm -rf $(PKG_BUILD_DIR).modcache/go-mod"
            print "\tmv $(PKG_BUILD_DIR)/go-mod $(PKG_BUILD_DIR).modcache/go-mod"
            injected = 1
            next
        }
        # 2) BPF_TRACE_TARGET 行追加 GOMODCACHE / GOFLAGS（去掉行尾的 ; 以延续 export）
        /BPF_TRACE_TARGET="\$\(GO_ARCH\)" ; \\$/ {
            sub(/ ; \\$/, " \\")
            print
            print "\t\tGOMODCACHE=\"$(PKG_BUILD_DIR).modcache/go-mod\" \\"
            print "\t\tGOFLAGS=\"-mod=mod\" ; \\"
            next
        }
        # 3) go generate 改相对路径（绝对路径会被 Go 当成包导入路径）
        /go generate \$\(PKG_BUILD_DIR\)\/control\/control\.go/ {
            sub(/go generate \$\(PKG_BUILD_DIR\)\/control\/control\.go/, \
                "cd $(PKG_BUILD_DIR) ; go generate ./control/control.go")
            print
            next
        }
        /go generate \$\(PKG_BUILD_DIR\)\/trace\/trace\.go/ {
            sub(/go generate \$\(PKG_BUILD_DIR\)\/trace\/trace\.go/, \
                "go generate ./trace/trace.go ; cd - >/dev/null")
            print
            next
        }
        { print }
    ' "${makefile}" >"${tmp}" || {
        rm -f "${tmp}"
        log ERROR "改写 dae Makefile 失败"
        return 1
    }

    # 复核：三处修改都必须出现，否则判失败并保留原文件。
    # 这里的 $ 是 Makefile 字面量，故意不展开（SC2016 正是想要的行为）。
    # shellcheck disable=SC2016
    if ! grep -qF "${marker}" "${tmp}" ||
        ! grep -qF 'GOMODCACHE="$(PKG_BUILD_DIR).modcache/go-mod"' "${tmp}" ||
        ! grep -qF 'go generate ./control/control.go' "${tmp}"; then
        rm -f "${tmp}"
        log ERROR "dae Makefile 改写结果校验失败，已放弃（原文件未动）"
        return 1
    fi

    cp -f "${tmp}" "${makefile}" || {
        rm -f "${tmp}"
        log ERROR "写回 ${makefile} 失败"
        return 1
    }
    rm -f "${tmp}"

    log INFO "已修复 dae 的 go-mod 布局（go-mod 移出源码树 + GOMODCACHE 指向 + 相对路径 generate）"
    return 0
}
