#!/bin/bash
#######################################
# 手钉工具常量巡检（scripts/ci/check-pinned-tools.sh）
#
# 为什么需要它：Dependabot 覆盖不了 scripts/build/steps/install-deps.sh 里三个手钉常量——
#   · EXTRAS_UPX_VERSION                钉版本号。上游发新版就该跟进，所以 workflow 会开 PR；
#   · EXTRAS_PADJFFS2_COMMIT / EXTRAS_PO2LMO_COMMIT
#     钉的是 commit，钉死本身就是为了防上游 main 漂移，因此只报告不升级（workflow 只开 issue）。
#
# 本脚本只读：不修改 install-deps.sh、不改任何文件，只把"钉住的 vs 上游的"打出来，
# 由 .github/workflows/dependency-audit.yml 决定开 issue 还是开 PR。
#
# 用法：
#   scripts/ci/check-pinned-tools.sh
#
# 输出（stdout 每行一个 key=value，顺序固定；若设置了 GITHUB_OUTPUT 则同时追加写入同名 key）：
#   upx_pinned=<值>
#   upx_latest=<值>
#   upx_outdated=true|false
#   padjffs2_pinned=<sha 前 12 位>
#   padjffs2_upstream=<sha 前 12 位>
#   padjffs2_outdated=true|false
#   po2lmo_pinned=<sha 前 12 位>
#   po2lmo_upstream=<sha 前 12 位>
#   po2lmo_outdated=true|false
#
# 退出码：E_SUCCESS(0) 正常跑完（有漂移也是 0，本脚本只报告不改文件）；
#         E_UNAVAILABLE(69) 任一网络请求失败或上游响应无法解析。
#
# 约束：版本号【不硬编码】，一律从 install-deps.sh 的常量读；唯一硬编码的是下面三个 API URL。
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 加载顺序即依赖顺序：logger（唯一 log 实现）-> error-handler（退出码常量）-> install-deps（EXTRAS_* 常量）。
# install-deps.sh 的 readonly 赋值块带哨兵保护，重复 source 安全，不会报"只读变量"。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# shellcheck source=scripts/libs/02-error-handler.sh
source "${SCRIPT_DIR}/../libs/02-error-handler.sh"
# shellcheck source=scripts/build/steps/install-deps.sh
source "${SCRIPT_DIR}/../build/steps/install-deps.sh"

cd "${SCRIPT_DIR}/../.." || {
    log_error "无法进入仓库根目录：${SCRIPT_DIR}/../.."
    exit "${E_UNAVAILABLE}"
}

# 三个上游查询地址（本脚本唯一允许硬编码的内容）。
readonly URL_UPX_LATEST="https://api.github.com/repos/upx/upx/releases/latest"
readonly URL_PADJFFS2_HEAD="https://api.github.com/repos/openwrt/openwrt/commits?path=tools/padjffs2/src/padjffs2.c&per_page=1"
readonly URL_PO2LMO_HEAD="https://api.github.com/repos/openwrt/luci/commits?path=modules/luci-base/src/Makefile&per_page=1"

#######################################
# 调 GitHub REST API 取 JSON 原文
#
# 参数：
#   $1 - 完整 URL
#
# 输出：
#   JSON 原文（stdout）
#
# 返回：
#   curl 的退出码（非 0 即网络/HTTP 错误）
#######################################
_github_api_get() {
    local url="$1"
    local -a args=(-fsSL --retry 3 --retry-delay 2 --max-time 60
        -H 'Accept: application/vnd.github+json'
        -H 'User-Agent: dependency-audit')

    # 公开仓库匿名也能读，但匿名额度只有 60 次/小时；环境里给了 token 就带上，
    # 免得批量调试或频繁重跑把额度打满后误报成网络故障。
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    curl "${args[@]}" "${url}"
}

#######################################
# 从 release JSON 里取 tag_name 并去掉版本号前缀 v
#
# 参数：
#   $1 - release JSON 原文
#
# 输出：
#   纯版本号（5.2.1）
#
# 返回：
#   0 - 解析成功；1 - 没找到 tag_name
#######################################
_parse_release_tag() {
    local body="$1"
    local tag=""

    # 不依赖 jq：最小镜像与本机都不保证装。tag_name 在 release JSON 里只出现一次，
    # 用 grep -o 取出整对键值再切掉引号比引入 JSON 解析器更省事也更少依赖。
    tag="$(printf '%s' "${body}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 |
        sed -e 's/.*:[[:space:]]*"//' -e 's/"$//')"
    if [[ -z "${tag}" ]]; then
        return 1
    fi
    # 上游 tag 形如 v5.2.1，与常量（纯版本号）比较前去掉前导 v。
    printf '%s' "${tag#v}"
}

#######################################
# 从 commits 列表 JSON 里取第一条 .sha
#
# 参数：
#   $1 - commits JSON 原文（per_page=1）
#
# 输出：
#   40 位十六进制 sha
#
# 返回：
#   0 - 解析成功；1 - 没找到合法 sha
#######################################
_parse_first_commit_sha() {
    local body="$1"
    local sha=""

    # 同样不用 jq。GitHub 的提交对象把顶层 "sha" 放在最前面，且紧随其后的
    # tree/parents 里的 sha 也在同一对象内——第一条 40 位十六进制命中就是列表首项的 .sha。
    # 这里额外用 ^[0-9a-f]{40}$ 兜底，取到半截或非 sha 字段时宁可报错也不输出脏值。
    sha="$(printf '%s' "${body}" | grep -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]\{40\}"' | head -n1 |
        sed -e 's/.*"\([0-9a-f]\{40\}\)"$/\1/')"
    if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
        return 1
    fi
    printf '%s' "${sha}"
}

#######################################
# 数值化比较版本号：candidate 是否比 pinned 新
#
# 参数：
#   $1 - 候选版本（上游最新，形如 5.2.1）
#   $2 - 钉住的版本（形如 5.0.2）
#
# 返回：
#   0 - candidate > pinned
#   1 - candidate <= pinned
#
# 说明：逐段按十进制比较，因此 5.10 > 5.9（字符串比较会得到相反结论）。
#       缺段按 0 补齐（5.2 == 5.2.0），调用方负责先用正则确认两串都是纯版本号。
#######################################
_version_is_newer() {
    local candidate="$1"
    local pinned="$2"
    local -a cand_parts=()
    local -a pinned_parts=()
    local width=0
    local i=0
    local a=""
    local b=""
    local ifs_saved="${IFS}"

    # 只在取分段时临时把 IFS 设成 '.'，读完立刻还原，避免污染调用方的 word splitting。
    IFS='.'
    read -r -a cand_parts <<<"${candidate}"
    read -r -a pinned_parts <<<"${pinned}"
    IFS="${ifs_saved}"

    width=${#cand_parts[@]}
    if [[ ${#pinned_parts[@]} -gt ${width} ]]; then
        width=${#pinned_parts[@]}
    fi
    for ((i = 0; i < width; i++)); do
        a="${cand_parts[i]:-0}"
        b="${pinned_parts[i]:-0}"
        # 10# 前缀强制十进制：0 开头的段（如 08）在算术上下文里会按八进制解析而报错。
        if ((10#${a} > 10#${b})); then
            return 0
        fi
        if ((10#${a} < 10#${b})); then
            return 1
        fi
    done
    return 1
}

#######################################
# 输出一行 key=value
#
# 参数：
#   $1 - key
#   $2 - value
#
# 说明：stdout 给 workflow 解析与本地肉眼核对；GITHUB_OUTPUT 存在时同时追加一份，
#       让 workflow 的后续 step 能直接读 steps.check.outputs。<key>。
#######################################
emit_key_value() {
    local key="$1"
    local value="$2"

    printf '%s=%s\n' "${key}" "${value}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_OUTPUT}"
    fi
}

main() {
    local upx_body=""
    local upx_latest=""
    local pad_body=""
    local pad_upstream=""
    local po_body=""
    local po2lmo_upstream=""
    local upx_outdated="false"
    local padjffs2_outdated="false"
    local po2lmo_outdated="false"

    # 常量由 install-deps.sh 提供，取不到就没法巡检；这属于脚本环境问题，
    # 用 E_UNAVAILABLE 统一表示"无法完成巡检"，与"有漂移"（仍是 0）区分开。
    require_var EXTRAS_UPX_VERSION EXTRAS_PADJFFS2_COMMIT EXTRAS_PO2LMO_COMMIT || {
        log_error "未能从 install-deps.sh 取得 EXTRAS_* 常量"
        return "${E_UNAVAILABLE}"
    }

    if ! upx_body="$(_github_api_get "${URL_UPX_LATEST}")"; then
        log_error "请求 upx 最新 release 失败：${URL_UPX_LATEST}"
        return "${E_UNAVAILABLE}"
    fi
    if ! upx_latest="$(_parse_release_tag "${upx_body}")"; then
        log_error "无法从 upx release JSON 中解析 tag_name"
        return "${E_UNAVAILABLE}"
    fi
    if ! [[ "${upx_latest}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        log_error "上游 tag 解析结果不是纯版本号，无法数值比较：'${upx_latest}'"
        return "${E_UNAVAILABLE}"
    fi

    if ! pad_body="$(_github_api_get "${URL_PADJFFS2_HEAD}")"; then
        log_error "请求 openwrt/openwrt 的 padjffs2 上游 HEAD 失败：${URL_PADJFFS2_HEAD}"
        return "${E_UNAVAILABLE}"
    fi
    if ! pad_upstream="$(_parse_first_commit_sha "${pad_body}")"; then
        log_error "无法从 openwrt/openwrt 的 commits JSON 中解析第一条 sha"
        return "${E_UNAVAILABLE}"
    fi

    if ! po_body="$(_github_api_get "${URL_PO2LMO_HEAD}")"; then
        log_error "请求 openwrt/luci 的 po2lmo 上游 HEAD 失败：${URL_PO2LMO_HEAD}"
        return "${E_UNAVAILABLE}"
    fi
    if ! po2lmo_upstream="$(_parse_first_commit_sha "${po_body}")"; then
        log_error "无法从 openwrt/luci 的 commits JSON 中解析第一条 sha"
        return "${E_UNAVAILABLE}"
    fi

    if _version_is_newer "${upx_latest}" "${EXTRAS_UPX_VERSION}"; then
        upx_outdated="true"
    fi
    # commit 钉死是为了防 main 漂移：判定标准只是"是否还是同一个 commit"，
    # 不看快慢、不看先进程度——上游 HEAD 一动就说明钉的位置已落后于它。
    if [[ "${pad_upstream}" != "${EXTRAS_PADJFFS2_COMMIT}" ]]; then
        padjffs2_outdated="true"
    fi
    if [[ "${po2lmo_upstream}" != "${EXTRAS_PO2LMO_COMMIT}" ]]; then
        po2lmo_outdated="true"
    fi

    emit_key_value "upx_pinned" "${EXTRAS_UPX_VERSION}"
    emit_key_value "upx_latest" "${upx_latest}"
    emit_key_value "upx_outdated" "${upx_outdated}"
    emit_key_value "padjffs2_pinned" "${EXTRAS_PADJFFS2_COMMIT:0:12}"
    emit_key_value "padjffs2_upstream" "${pad_upstream:0:12}"
    emit_key_value "padjffs2_outdated" "${padjffs2_outdated}"
    emit_key_value "po2lmo_pinned" "${EXTRAS_PO2LMO_COMMIT:0:12}"
    emit_key_value "po2lmo_upstream" "${po2lmo_upstream:0:12}"
    emit_key_value "po2lmo_outdated" "${po2lmo_outdated}"

    if [[ "${upx_outdated}" == "true" ]]; then
        log_warning "upx 有新版本：钉 ${EXTRAS_UPX_VERSION}，上游 ${upx_latest}（workflow 会开 PR）"
    fi
    if [[ "${padjffs2_outdated}" == "true" ]]; then
        log_warning "padjffs2 commit 已漂移：钉 ${EXTRAS_PADJFFS2_COMMIT:0:12}，上游 ${pad_upstream:0:12}（只报告，不自动升级）"
    fi
    if [[ "${po2lmo_outdated}" == "true" ]]; then
        log_warning "po2lmo commit 已漂移：钉 ${EXTRAS_PO2LMO_COMMIT:0:12}，上游 ${po2lmo_upstream:0:12}（只报告，不自动升级）"
    fi
    log_success "手钉常量巡检完成。"
    return "${E_SUCCESS}"
}

main "$@"
exit "$?"
