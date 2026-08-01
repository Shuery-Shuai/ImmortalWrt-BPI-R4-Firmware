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
#   source common/scripts/libs/package-auto-update.sh
#   auto_update_package "daeuniverse/dae" "feeds/packages/net/dae/Makefile" set_dae_version
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

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

    # 检查回调函数是否存在
    if ! type -t "${set_version_func}" &>/dev/null; then
        log ERROR "Version setter function '${set_version_func}' not found."
        return 1
    fi

    if [[ ! -f "${makefile}" ]]; then
        log WARN "Makefile not found: ${makefile}, skipping auto-update."
        return 0
    fi

    # 读取当前版本
    local current_pkg_version
    current_pkg_version=$(grep -E '^\s*PKG_VERSION\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*PKG_VERSION\s*:?=\s*(.+)\s*$/\1/')
    if [[ -z "${current_pkg_version}" ]]; then
        log ERROR "Cannot parse PKG_VERSION from ${makefile}"
        return 1
    fi

    # 还原原始版本号
    local current_raw
    current_raw=$(echo "${current_pkg_version}" | sed -E 's/_rc/rc/g; s/_beta/beta/g; s/_alpha/alpha/g; s/_pre/pre/g')
    log INFO "Current ${repo} version: ${current_raw} (PKG_VERSION=${current_pkg_version})"

    # 获取最新 tag
    log INFO "Checking latest release of ${repo} on GitHub..."
    local latest_raw=""
    if [[ "${include_pre_release}" == "true" ]]; then
        log INFO "Checking latest release (including pre-releases) of ${repo}..."
        # 取最近 20 个 release，避免遗漏只发布过预发布的项目
        local releases_json
        releases_json=$(curl -sS "https://api.github.com/repos/${repo}/releases?per_page=20")
        if [[ -z "${releases_json}" ]]; then
            log ERROR "Failed to fetch releases for ${repo}"
            return 1
        fi
        # 提取所有 tag_name，解析版本号并比较出最大值
        local tags max_raw=""
        tags=$(echo "${releases_json}" | grep -oP '"tag_name":\s*"\K[^"]+')
        for tag in ${tags}; do
            local raw_ver
            raw_ver=$("${tag_parser}" "${tag}")
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
        latest_raw="${max_raw}"
        log INFO "Highest release (including pre-releases): ${latest_raw}"
    else
        # 仅获取稳定版
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
        latest_raw=$("${tag_parser}" "${latest_tag}")
        log INFO "Latest stable release: ${latest_raw}"
    fi

    # 从 tag 提取版本号（通过 $tag_parser 函数）
    local latest_raw
    latest_raw=$("${tag_parser}" "${latest_tag}")
    log INFO "Latest ${repo} release: ${latest_raw} (tag: ${latest_tag})"

    # 比较版本
    local cmp
    cmp=$(compare_versions "${current_raw}" "${latest_raw}")
    if [[ "${cmp}" -ge 0 ]]; then
        log INFO "Current version is already the latest or higher."
        return 0
    fi

    log INFO "Newer version found, updating ${repo} to ${latest_raw}..."
    # 调用设置版本的函数，传递版本号和 Makefile
    "${set_version_func}" "${latest_raw}" "${makefile}"
}

#######################################
# 默认标签解析器：去除开头的 'v'
#######################################
_strip_leading_v() {
    local tag="$1"
    printf '%s' "${tag#v}"
}
