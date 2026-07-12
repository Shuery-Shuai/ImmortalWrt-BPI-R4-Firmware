#!/bin/bash
# 文件: common/scripts/mods/set-dae-version.sh
# 用途: 修改 dae 软件包的版本、源地址和哈希值，用于固定特定版本或升级
#       自动处理版本号中的 rc/beta 后缀，生成符合 OpenWrt 规范的 PKG_VERSION
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/set-dae-version.sh
#   set_dae_version <version> <hash> [makefile_path]
#
# 参数:
#   version       : 目标版本号，如 1.1.0rc1, 2.0.0rc1, 1.1.0 (不含 v 前缀)
#   hash          : 对应的源代码包 SHA256 哈希值 (必需)
#   makefile_path : dae 的 Makefile 路径，默认为 feeds/packages/net/dae/Makefile
#
# 示例:
#   set_dae_version "1.1.0rc1" "726a049813a4d5b800c441ea76ff0ce1846596c180fba0e8ec920a129b3b6e0a"
#   set_dae_version "2.0.0rc1" "abc123..." "custom-packages/packages/net/dae/Makefile"
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 设置 dae 版本
#
# 功能:
#   修改指定 Makefile 中的 PKG_VERSION, PKG_SOURCE, PKG_SOURCE_URL, PKG_HASH，
#   将 dae 锁定到指定的版本，并自动处理版本号后缀（rc -> _rc）。
#   URL 根据版本号自动生成，遵循官方下载链接格式。
#
# Arguments:
#   $1 - 版本号（如 "1.1.0rc1"）
#   $2 - 源代码包的 SHA256 哈希值
#   $3 - Makefile 路径（可选，默认 feeds/packages/net/dae/Makefile）
#
# Outputs:
#   操作日志到 stderr
#
# Returns:
#   0 - 修改成功
#   0 - 文件不存在时仅输出警告
#   1 - 缺少必需参数或哈希值为空
#######################################
set_dae_version() {
    local raw_version="$1"
    local hash="$2"
    local makefile="${3:-feeds/packages/net/dae/Makefile}"

    if [[ -z "${raw_version}" || -z "${hash}" ]]; then
        log ERROR "Usage: set_dae_version <version> [hash|auto] [makefile_path]"
        return 1
    fi

    # 自动计算哈希（如果未提供或为 "auto"）
    if [[ -z "${hash}" || "${hash}" == "auto" ]]; then
        log INFO "Auto-computing SHA256 for dae ${raw_version}..."
        local url="https://github.com/daeuniverse/dae/releases/download/v${raw_version}/dae-full-src.zip"
        hash=$(download_and_hash "${url}") || return 1
        log INFO "Computed hash: ${hash}"
    fi

    if [[ ! -f "${makefile}" ]]; then
        log WARN "dae Makefile not found: ${makefile}, skipping."
        return 0
    fi

    # 计算 PKG_VERSION：将 "rc" 替换为 "_rc"，其他如 "beta" 同理可按需扩展
    # 简单规则：在非数字结尾前插入下划线（如 1.1.0rc1 -> 1.1.0_rc1）
    # 注意：只处理最后出现的非数字段
    local pkg_version
    pkg_version=$(normalize_pkg_version "${raw_version}")

    # 生成 PKG_SOURCE: dae-{raw_version}.zip
    local pkg_source="dae-full-src.zip"

    # 生成 PKG_SOURCE_URL
    local pkg_source_url="https://github.com/daeuniverse/dae/releases/download/v${raw_version}/"

    log INFO "Setting dae version to ${raw_version} (PKG_VERSION=${pkg_version}) in ${makefile}..."
    log INFO "  PKG_SOURCE: ${pkg_source}"
    log INFO "  PKG_SOURCE_URL: ${pkg_source_url}"
    log INFO "  PKG_HASH: ${hash}"

    # 执行替换
    # shellcheck disable=SC2034  # vars is used indirectly via nameref in set_makefile_vars
    declare -A vars=(
        ["PKG_VERSION"]="${pkg_version}"
        ["PKG_SOURCE"]="${pkg_source}"
        ["PKG_SOURCE_URL"]="${pkg_source_url}"
        ["PKG_HASH"]="${hash}"
    )

    set_makefile_vars "${makefile}" vars

    log INFO "dae version set successfully."
}

# 直接执行时需提供参数（否则报错）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set_dae_version "$@"
fi
