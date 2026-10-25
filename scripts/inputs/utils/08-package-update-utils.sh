#!/bin/bash
#######################################
# 软件包自动更新工具
#
# 提供通用的“检查 GitHub 最新 release 并更新 Makefile”逻辑。
# 需要调用方提供：
#   - 仓库 owner/repo
#   - Makefile 路径
#   - 设置版本的回调函数（如 set_dae_version / set_fan2go_version）
#   - 可选的标签版本提取函数（默认为去除 v 前缀）
#
# 依赖：需要 log / compare_versions 等函数，
#       通过 index.sh 加载。
#
# 用法：
#   source scripts/inputs/utils/package-auto-update.sh
#   auto_update_package "daeuniverse/dae" "feeds/packages/net/dae/Makefile" set_dae_version
#######################################

#######################################
# 自动更新一个 OpenWrt 软件包到最新 GitHub release
#
# 参数：
#   $1 - GitHub 仓库标识（owner/repo）
#   $2 - 当前 Makefile 路径
#   $3 - 设置版本的函数名（必须接受 version 和 makefile 参数，如 set_dae_version）
#   $4 - 标签处理函数名（可选，接收原始 tag 并返回版本号，默认为去除首字符 v）
#   $5 - 是否包含预发布版本（可选，默认 false）
#        为 true 时会从最近 20 个 release 中选取版本号最高的一个，无论其是否为预发布。
#
# 示例：
#   auto_update_package "daeuniverse/dae" "feeds/packages/net/dae/Makefile" set_dae_version
#######################################
auto_update_package() {
    local repo="$1"
    local makefile="$2"
    local set_version_func="$3"
    local tag_parser="${4:-_strip_leading_v}"
    local include_pre_release="${5:-false}"

    if [[ -z "${repo}" || -z "${makefile}" || -z "${set_version_func}" ]]; then
        log ERROR "Usage: auto_update_package <owner/repo> <makefile> <set_func> [tag_parser]"
        return 1
    fi

    if ! type -t "${set_version_func}" &>/dev/null; then
        log ERROR "Version setter function '${set_version_func}' not found."
        return 1
    fi

    if [[ ! -f "${makefile}" ]]; then
        log WARN "Makefile not found: ${makefile}, skipping auto-update."
        return 0
    fi

    local current_pkg_version
    current_pkg_version="$(_package_read_pkg_version "${makefile}")" || return 1

    local current_raw
    current_raw="$(_package_restore_raw_version "${current_pkg_version}")"
    log INFO "Current ${repo} version: ${current_raw} (PKG_VERSION=${current_pkg_version})"

    log INFO "Checking latest release of ${repo} on GitHub..."
    local latest_raw
    latest_raw="$(_package_fetch_latest_release "${repo}" "${tag_parser}" "${include_pre_release}")" || return 1

    if ! _package_is_newer "${current_raw}" "${latest_raw}"; then
        log INFO "Current version is already the latest or higher."
        return 0
    fi

    log INFO "Newer version found, updating ${repo} to ${latest_raw}..."
    "${set_version_func}" "${latest_raw}" "${makefile}"
}

#######################################
# 从 Makefile 读取 PKG_VERSION 的值
#
# 参数：
#   $1 - Makefile 路径
#
# 输出：
#   PKG_VERSION 的值到 stdout
#
# 返回：
#   0 - 读取成功
#   1 - 无法解析
#######################################
_package_read_pkg_version() {
    local makefile="$1"
    local pkg_version
    pkg_version=$(grep -E '^\s*PKG_VERSION\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*PKG_VERSION\s*:?=\s*(.+)\s*$/\1/')
    if [[ -z "${pkg_version}" ]]; then
        log ERROR "Cannot parse PKG_VERSION from ${makefile}"
        return 1
    fi
    printf '%s' "${pkg_version}"
}

#######################################
# 把 PKG_VERSION 还原成原始版本号（包内下划线换回预发布标识）
#
# 参数：
#   $1 - PKG_VERSION 的值
#
# 输出：
#   还原后的原始版本号到 stdout
#######################################
_package_restore_raw_version() {
    local pkg_version="$1"
    printf '%s' "${pkg_version}" | sed -E 's/_rc/rc/g; s/_beta/beta/g; s/_alpha/alpha/g; s/_pre/pre/g'
}

#######################################
# 获取仓库的最新版本号（稳定版或含预发布的最高版）
#
# 参数：
#   $1 - GitHub 仓库标识（owner/repo）
#   $2 - 标签处理函数名
#   $3 - 是否包含预发布版本
#
# 输出：
#   最新版本号到 stdout
#
# 返回：
#   0 - 成功
#   1 - 拉取或解析失败
#######################################
_package_fetch_latest_release() {
    local repo="$1"
    local tag_parser="$2"
    local include_pre_release="$3"
    local latest_tag=''
    local latest_raw

    if [[ "${include_pre_release}" == "true" ]]; then
        log INFO "Checking latest release (including pre-releases) of ${repo}..."
        latest_raw="$(_package_select_highest_release "${repo}" "${tag_parser}")" || return 1
        log INFO "Highest release (including pre-releases): ${latest_raw}"
    else
        latest_tag="$(_package_fetch_latest_stable_tag "${repo}")" || return 1
        latest_raw="$("${tag_parser}" "${latest_tag}")"
        log INFO "Latest stable release: ${latest_raw}"
    fi

    # 预发布分支不回填 latest_tag，下面的 tag_parser 作用于空 tag —— 与原实现逐字面保持一致。
    latest_raw="$("${tag_parser}" "${latest_tag}")"
    log INFO "Latest ${repo} release: ${latest_raw} (tag: ${latest_tag})"
    printf '%s' "${latest_raw}"
}

#######################################
# 从最近 20 个 release 中选出最高版本（含预发布）
#
# 取最近 20 个 release，避免遗漏只发布过预发布的项目。
#
# 参数：
#   $1 - GitHub 仓库标识（owner/repo）
#   $2 - 标签处理函数名
#
# 输出：
#   最高版本号到 stdout
#
# 返回：
#   0 - 成功
#   1 - 拉取或解析失败
#######################################
_package_select_highest_release() {
    local repo="$1"
    local tag_parser="$2"
    local releases_json
    releases_json=$(curl -sS "https://api.github.com/repos/${repo}/releases?per_page=20")
    if [[ -z "${releases_json}" ]]; then
        log ERROR "Failed to fetch releases for ${repo}"
        return 1
    fi

    local tags max_raw=''
    local tag raw_ver
    tags=$(echo "${releases_json}" | grep -oP '"tag_name":\s*"\K[^"]+')
    for tag in ${tags}; do
        raw_ver="$("${tag_parser}" "${tag}")"
        if [[ -z "${max_raw}" ]]; then
            max_raw="${raw_ver}"
        elif [[ $(compare_versions "${raw_ver}" "${max_raw}") -gt 0 ]]; then
            max_raw="${raw_ver}"
        fi
    done

    if [[ -z "${max_raw}" ]]; then
        log ERROR "Could not find any release for ${repo}"
        return 1
    fi

    printf '%s' "${max_raw}"
}

#######################################
# 获取最新稳定版的原始 tag
#
# 参数：
#   $1 - GitHub 仓库标识（owner/repo）
#
# 输出：
#   原始 tag_name 到 stdout
#
# 返回：
#   0 - 成功
#   1 - 拉取或解析失败
#######################################
_package_fetch_latest_stable_tag() {
    local repo="$1"
    local latest_tag
    latest_tag=$(curl -sS "https://api.github.com/repos/${repo}/releases/latest" |
        grep -oP '"tag_name":\s*"\K[^"]+') || {
        log ERROR "Failed to fetch latest stable release for ${repo}"
        return 1
    }
    if [[ -z "${latest_tag}" ]]; then
        log ERROR "Could not parse tag_name from GitHub API for ${repo}"
        return 1
    fi
    printf '%s' "${latest_tag}"
}

#######################################
# 判断最新版本是否高于当前版本
#
# 参数：
#   $1 - 当前版本号
#   $2 - 最新版本号
#
# 返回：
#   0 - 需要更新
#   1 - 当前版本已是最新或更高
#######################################
_package_is_newer() {
    local current_raw="$1"
    local latest_raw="$2"
    local cmp
    cmp=$(compare_versions "${current_raw}" "${latest_raw}")
    [[ "${cmp}" -ge 0 ]] && return 1
    return 0
}

#######################################
# 默认标签解析器：去除开头的 'v'
#######################################
_strip_leading_v() {
    local tag="$1"
    printf '%s' "${tag#v}"
}
