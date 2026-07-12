#!/bin/bash
# 文件: common/scripts/mods/set-default-shell.sh
# 用途: 修改 OpenWrt/ImmortalWrt 的默认 Shell (ash -> bash)
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
# 用法:
#   source common/scripts/mods/set-default-shell.sh
#   set_default_shell [shell_path]
#
# 参数:
#   shell_path : 要设置的 Shell 路径，默认 /bin/bash
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 修改默认 Shell
#
# 将 root 用户的登录 Shell 从 /bin/ash 改为指定路径（如 /bin/bash）。
# 提供更好的交互体验。
#
# Arguments:
#   $1 - 新 Shell 路径，默认 /bin/bash
#
# Returns:
#   0 - 始终成功（文件不存在时仅警告）
#######################################
set_default_shell() {
    local new_shell="${1:-/bin/bash}"
    local passwd_file="package/base-files/files/etc/passwd"

    if [[ -f "${passwd_file}" ]]; then
        log INFO "Setting default shell to ${new_shell}..."
        # 转义路径中的 /
        sed -i "s/\/bin\/ash/${new_shell//\//\\/}/" "${passwd_file}"
        log INFO "Default shell updated."
    else
        log WARN "${passwd_file} not found, skipping."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set_default_shell "$@"
fi
