#!/bin/bash
# 文件: common/scripts/mods/modify-luci-collections.sh
# 用途: 批量修改 LuCI 集合的 Makefile，以适应定制需求
#       1. 移除 luci-app-attendedsysupgrade（所有集合）
#       2. 移除 uhttpd 依赖（luci-light）
#       3. 替换默认主题为 luci-theme-argon（luci-light, luci-nginx）
#       4. 修复 package-manager 行尾的反斜杠续行符（luci, luci-ssl, luci-ssl-openssl）
# 依赖: 需要预先 source common/scripts/libs/functions.sh
#       （提供 modify_luci_collection 函数和 log 函数）
#       若未加载，脚本内置后备日志函数
# 用法:
#   source common/scripts/mods/modify-luci-collections.sh
#   apply_luci_collection_patches
#
# 说明:
#   所有修改通过调用公共函数 modify_luci_collection 完成，它接受 Makefile 路径和 sed 表达式。
#   本脚本仅封装调用逻辑，无其他参数。
#######################################

# 后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 应用所有 LuCI 集合的 Makefile 补丁
#
# 功能:
#   依次对以下五个 LuCI 集合的 Makefile 进行 sed 修改:
#     - luci
#     - luci-light
#     - luci-nginx
#     - luci-ssl
#     - luci-ssl-openssl
#   具体修改内容已硬编码，如需调整请编辑本函数中的对应块。
#
# Globals:
#   None
#
# Arguments:
#   None
#
# Outputs:
#   每个集合的修改状态输出到 stderr (通过 modify_luci_collection 内部调用 log)
#
# Returns:
#   0 总是成功（即使某个集合文件不存在，仅输出警告）
#
# Examples:
#   apply_luci_collection_patches
#######################################
apply_luci_collection_patches() {
    log INFO "Applying patches to LuCI collection Makefiles..."

    # LuCI 完整版：移除 attendedsysupgrade，修复 package-manager 行尾续行
    if type -t modify_luci_collection &>/dev/null; then
        modify_luci_collection 'feeds/luci/collections/luci/Makefile' \
            -e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'
    else
        log ERROR "modify_luci_collection function not found. Please source common/scripts/libs/functions.sh first."
        return 1
    fi

    # LuCI 轻量版：移除 uhttpd，替换主题为 argon，修复 rpcd-mod-rrdns 续行
    modify_luci_collection 'feeds/luci/collections/luci-light/Makefile' \
        -e '/LUCI_DEPENDS/,/^$/ { /uhttpd/d; s/luci-theme-bootstrap/luci-theme-argon/g; s/rpcd-mod-rrdns\s*\\/rpcd-mod-rrdns/g; }'

    # LuCI Nginx 版：移除 attendedsysupgrade，替换主题为 argon
    modify_luci_collection 'feeds/luci/collections/luci-nginx/Makefile' \
        -e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-theme-bootstrap/luci-theme-argon/g; }'

    # LuCI SSL 版：移除 attendedsysupgrade，修复 package-manager 续行
    modify_luci_collection 'feeds/luci/collections/luci-ssl/Makefile' \
        -e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

    # LuCI SSL-OpenSSL 版：移除 attendedsysupgrade，修复 package-manager 续行
    modify_luci_collection 'feeds/luci/collections/luci-ssl-openssl/Makefile' \
        -e '/LUCI_DEPENDS/,/^$/ { /luci-app-attendedsysupgrade/d; s/luci-app-package-manager\s*\\/luci-app-package-manager/g; }'

    log INFO "LuCI collection patches applied."
}

# 若直接运行脚本，则执行补丁（需要确保 functions.sh 已加载，否则会报错）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    apply_luci_collection_patches
fi
