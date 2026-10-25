#!/bin/bash
# 文件: scripts/inputs/mods/set-default-ip.sh
# 用途: 修改 OpenWrt/ImmortalWrt 的默认 LAN IP 地址
# 依赖: 需要预先 source scripts/libs/load.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source scripts/inputs/mods/set-default-ip.sh
#   set_default_ip [ip_address]
#
# 参数:
#   ip_address : 要设置的默认 LAN IP，默认为 192.168.0.1
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 修改默认 IP 地址
#
# 将 192.168.1.1 替换为指定 IP，避免与常见路由冲突。
#
# 参数：
#   $1 - 新 IP 地址，默认 192.168.0.1
#
# 返回：
#   0 - 始终成功（文件不存在时仅警告）
#######################################
set_default_ip() {
    # 规格：ip:i:value；同时兼容原位置参数（ip 优先，其次 _POSITIONAL_0）。
    # 有 parse_args（load.sh 已加载）时按规格解析，命名参数与位置参数都支持；
    # 直接执行本文件（未加载 load.sh）时 parse_args 不存在，回退为纯位置参数，行为与改造前一致。
    if type -t parse_args >/dev/null 2>&1; then
        parse_args "ip:i:value" -- "$@" || return 1
    fi
    local new_ip="${PARSED_ARGS[ip]:-${PARSED_ARGS[_POSITIONAL_0]:-192.168.0.1}}"
    local config_file="package/base-files/files/bin/config_generate"

    if [[ -f "${config_file}" ]]; then
        log INFO "Setting default LAN IP to ${new_ip}..."
        sed -i "s/192.168.1.1/${new_ip}/g" "${config_file}"
        log INFO "Default IP updated."
    else
        log WARN "${config_file} not found, skipping."
    fi
}

# 直接执行时应用默认 IP
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set_default_ip "$@"
fi
