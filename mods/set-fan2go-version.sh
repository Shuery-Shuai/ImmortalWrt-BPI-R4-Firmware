#!/bin/bash
# 文件: common/scripts/mods/set-fan2go-version.sh
# 用途: 修改 fan2go 软件包的版本和哈希值，用于固定版本或升级
#       支持自动处理 rc/beta 等预发布后缀
#       支持自动检查 GitHub 最新 release 并更新
# 依赖: 需要预先 source common/scripts/libs/index.sh 以使用 log / normalize_pkg_version /
#       compare_versions / set_makefile_vars / download_and_hash 等函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/set-fan2go-version.sh
#   set_fan2go_version <version> <hash> [makefile_path]
#   set_fan2go_version --auto-update [makefile_path]
#   set_fan2go_version -u [makefile_path]
#
# 参数:
#   version       : 目标版本号，如 0.13.0, 0.14.0rc1 (不含 v 前缀)
#   hash          : 对应的源代码包 SHA256 哈希值 (必需；设为 auto 可自动计算)
#   makefile_path : fan2go 的 Makefile 路径，默认为 feeds/packages/utils/fan2go/Makefile
#   --auto-update / -u : 启用自动更新，检查 GitHub 最新 release，若有新版本则更新
#
# 示例:
#   set_fan2go_version "0.13.0" "d693bc3ed4c43c8f120433ff17cecca9b98def829e031759373e6ff1ed8def61"
#   set_fan2go_version "0.14.0rc1" "abc123..." "custom-packages/packages/utils/fan2go/Makefile"
#   set_fan2go_version --auto-update
#   set_fan2go_version -u feeds/packages/utils/fan2go/Makefile
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 设置 fan2go 版本
#
# 功能:
#   修改指定 Makefile 中的 PKG_VERSION 和 PKG_HASH，
#   将 fan2go 锁定到指定版本。版本号中的 rc/beta 后缀自动转换为下划线格式。
#
# 参数：
#   $1 - 版本号（如 "0.13.0"）
#   $2 - 源代码包的 SHA256 哈希值
#   $3 - Makefile 路径（可选，默认 feeds/packages/utils/fan2go/Makefile）
#
# 输出：
#   操作日志到 stderr
#
# 返回：
#   0 - 修改成功
#   0 - 文件不存在时仅输出警告
#   1 - 缺少必需参数
#######################################
set_fan2go_version() {
    local raw_version="$1"
    local hash="$2"
    local makefile="${3:-feeds/packages/utils/fan2go/Makefile}"

    if [[ -z "${raw_version}" || -z "${hash}" ]]; then
        log ERROR "Usage: set_fan2go_version <version> [hash|auto] [makefile_path]"
        return 1
    fi

    # 自动计算哈希（如果未提供或为 "auto"）
    if [[ -z "${hash}" || "${hash}" == "auto" ]]; then
        log INFO "Auto-computing SHA256 for fan2go ${raw_version}..."
        local url="https://github.com/markusressel/fan2go/archive/refs/tags/${raw_version}.tar.gz"
        hash=$(download_and_hash "${url}") || return 1
        log INFO "Computed hash: ${hash}"
    fi

    if [[ ! -f "${makefile}" ]]; then
        log WARN "fan2go Makefile not found: ${makefile}, skipping."
        return 0
    fi

    # 计算 PKG_VERSION：自动将 "rc" / "beta" 前插入下划线
    local pkg_version
    pkg_version=$(normalize_pkg_version "${raw_version}")

    log INFO "Setting fan2go version to ${raw_version} (PKG_VERSION=${pkg_version}) in ${makefile}..."
    log INFO "  PKG_HASH: ${hash}"

    # shellcheck disable=SC2034  # vars is used indirectly via nameref in set_makefile_vars
    declare -A vars=(
        ["PKG_VERSION"]="${pkg_version}"
        ["PKG_HASH"]="${hash}"
    )

    set_makefile_vars "${makefile}" vars

    log INFO "fan2go version set successfully."
}

auto_update_fan2go() {
    local makefile="${1:-feeds/packages/utils/fan2go/Makefile}"
    auto_update_package "markusressel/fan2go" "${makefile}" set_fan2go_version
}

# 脚本入口
if [[ "${1}" == "--auto-update" || "${1}" == "-u" ]]; then
    shift
    auto_update_fan2go "$@"
else
    set_fan2go_version "$@"
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set_fan2go_version "$@"
fi
