#!/bin/bash
# 文件: common/scripts/mods/rename-qbittorrent.sh
# 用途: 在 ImmortalWrt 构建中，将第三方 luci-app-qbittorrent 重命名为 luci-app-qbittorrent-original，
#       以避免与官方自带的同名包冲突。
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/rename-qbittorrent.sh
#   rename_qbittorrent [base_path]
#
# 参数:
#   base_path : qbittorrent 自定义软件包的基础路径，默认为 'custom-packages/qbittorrent'
#######################################

# 后备日志
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 重命名第三方 luci-app-qbittorrent 以避免冲突
#
# 功能:
#   若目标路径下存在 luci-app-qbittorrent 目录，则将其重命名为 luci-app-qbittorrent-original，
#   并修改其 Makefile 中的包名引用，确保一致性。
#   如果目录不存在（可能已被重命名或本就使用官方包），则静默跳过。
#
# Arguments:
#   $1 - (可选) qbittorrent 软件包的基础路径，默认为 'custom-packages/qbittorrent'
#
# Examples:
#   rename_qbittorrent
#   rename_qbittorrent 'custom-packages/qbittorrent'
#######################################
rename_qbittorrent() {
    local base_path="${1:-custom-packages/qbittorrent}"

    if [[ ! -d "${base_path}" ]]; then
        log WARN "qBittorrent directory not found: ${base_path}, skipping rename."
        return 0
    fi

    log INFO "Checking for luci-app-qbittorrent in ${base_path}..."

    local luci_original="${base_path}/luci-app-qbittorrent"
    local luci_renamed="${base_path}/luci-app-qbittorrent-original"

    if [[ -d "${luci_original}" ]]; then
        log INFO "Renaming ${luci_original} -> ${luci_renamed}"
        mv "${luci_original}" "${luci_renamed}"

        local renamed_makefile="${luci_renamed}/Makefile"
        if [[ -f "${renamed_makefile}" ]]; then
            sed -i 's/luci-app-qbittorrent/luci-app-qbittorrent-original/g' "${renamed_makefile}"
            log INFO "Updated Makefile references in ${renamed_makefile}"
        else
            log WARN "Makefile not found in renamed directory, manual check may be needed."
        fi
    else
        log INFO "No luci-app-qbittorrent directory found; already renamed or using original package."
    fi

    log INFO "Rename step completed."
}

# 直接运行脚本时执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    rename_qbittorrent "$@"
fi
