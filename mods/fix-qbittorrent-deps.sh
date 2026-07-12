#!/bin/bash
# 文件: common/scripts/mods/fix-qbittorrent-deps.sh
# 用途: 修复 qBittorrent 核心包的 libtorrent 依赖关系，
#       将过时的 +rblibtorrent 替换为正确的 +libtorrent-rasterbar。
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/fix-qbittorrent-deps.sh
#   fix_qbittorrent_deps [base_path]
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
# 修复 qBittorrent 的 libtorrent 依赖
#
# 功能:
#   检查 qbittorrent 核心包的 Makefile，确保其依赖中包含 +libtorrent-rasterbar。
#   - 如果已存在正确依赖，则跳过。
#   - 如果存在旧依赖 +rblibtorrent，则替换为 +libtorrent-rasterbar。
#   - 若都不存在，则在 DEPENDS 行末尾追加 +libtorrent-rasterbar。
#
# Arguments:
#   $1 - (可选) qbittorrent 软件包的基础路径，默认为 'custom-packages/qbittorrent'
#
# Examples:
#   fix_qbittorrent_deps
#   fix_qbittorrent_deps 'custom-packages/qbittorrent'
#######################################
fix_qbittorrent_deps() {
    local base_path="${1:-custom-packages/qbittorrent}"

    if [[ ! -d "${base_path}" ]]; then
        log WARN "qBittorrent directory not found: ${base_path}, skipping dependency fix."
        return 0
    fi

    local qbit_makefile="${base_path}/qbittorrent/Makefile"

    if [[ ! -f "${qbit_makefile}" ]]; then
        log WARN "qBittorrent core Makefile not found: ${qbit_makefile}, skipping dependency fix."
        return 0
    fi

    log INFO "Checking libtorrent dependency in ${qbit_makefile}..."

    if grep -q '+libtorrent-rasterbar' "${qbit_makefile}"; then
        log INFO "Dependency +libtorrent-rasterbar already present, nothing to do."
    elif grep -q '+rblibtorrent' "${qbit_makefile}"; then
        log INFO "Replacing legacy +rblibtorrent with +libtorrent-rasterbar..."
        sed -i 's/+rblibtorrent/+libtorrent-rasterbar/g' "${qbit_makefile}"
        log INFO "Replacement done."
    else
        if grep -q 'DEPENDS:=' "${qbit_makefile}"; then
            log INFO "Adding +libtorrent-rasterbar to DEPENDS line..."
            sed -i '/define Package\/qbittorrent/,/^endef/{
                /DEPENDS:=/ s/$/ +libtorrent-rasterbar/
            }' "${qbit_makefile}"
            log INFO "Added +libtorrent-rasterbar to DEPENDS."
        else
            log WARN "Cannot locate DEPENDS line in ${qbit_makefile}; you may need to manually add +libtorrent-rasterbar."
        fi
    fi

    log INFO "Dependency fix completed."
}

# 直接运行脚本时执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fix_qbittorrent_deps "$@"
fi
