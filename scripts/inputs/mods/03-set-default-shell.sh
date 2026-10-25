#!/bin/bash
# 文件: scripts/inputs/mods/set-default-shell.sh
# 用途: 修改 OpenWrt/ImmortalWrt 的默认 Shell (ash -> bash)
# 依赖: 需要预先 source scripts/libs/load.sh 以使用 log 函数
# 用法:
#   source scripts/inputs/mods/set-default-shell.sh
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
# 参数：
#   $1 - 新 Shell 路径，默认 /bin/bash
#
# 返回：
#   0 - 始终成功（文件不存在时仅警告）
#######################################
set_default_shell() {
    # 规格：shell:s:value；同时兼容原位置参数（shell 优先，其次 _POSITIONAL_0）。
    # 有 parse_args（load.sh 已加载）时按规格解析，命名参数与位置参数都支持；
    # 直接执行本文件（未加载 load.sh）时 parse_args 不存在，回退为纯位置参数，行为与改造前一致。
    if type -t parse_args >/dev/null 2>&1; then
        parse_args "shell:s:value" -- "$@" || return 1
    fi
    local new_shell="${PARSED_ARGS[shell]:-${PARSED_ARGS[_POSITIONAL_0]:-/bin/bash}}"
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
