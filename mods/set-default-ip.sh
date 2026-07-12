#!/bin/bash
# 文件: common/scripts/mods/set-default-ip.sh
# 用途: 修改 OpenWrt/ImmortalWrt 的默认 LAN IP 地址
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/set-default-ip.sh
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
# Arguments:
#   $1 - 新 IP 地址，默认 192.168.0.1
#
# Returns:
#   0 - 始终成功（文件不存在时仅警告）
#######################################
set_default_ip() {
    local new_ip="${1:-192.168.0.1}"
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
