#!/bin/bash
#######################################
# 手钉工具常量巡检（scripts/ci/check-pinned-tools.sh）
#
# 为什么需要它：Dependabot 覆盖不了这个仓库的五个手钉常量，来源分两类——
#   scripts/build/steps/install-deps.sh：
#   · EXTRAS_UPX_VERSION                钉版本号。上游发新版就该跟进，所以 workflow 会开 PR；
#   · EXTRAS_PADJFFS2_COMMIT / EXTRAS_PO2LMO_COMMIT
#     钉的是 commit，钉死本身就是为了防上游 main 漂移，因此只报告不升级（workflow 只开 issue）。
#   scripts/inputs/diy-part2.sh：
#   · set_dae_version "<版本>" "<sha256>"  版本号与源码包 sha256 一起钉死，两个 token 必须同步改；
#   · set_fan2go_version "<版本>" auto     hash 交给构建时现算（字面量 auto），只钉版本号。
#
# 两处 inputs 项的 hash 处理方式不同，是因为上游给的线索不同：
#   · dae 的上游 release 除 dae-full-src.zip 外还提供 dae-full-src.zip.dgst
#     （md5 / sha1 / sha256 / sha512 四行）。dgst 只有几百字节，所以优先读它取 sha256 行；
#     但上游并非每个 tag 都发 dgst（实测 v2.1.0 是 404），因此必须留回退：
#     下载 dae-full-src.zip 现算 sha256。源码包体积不定（v2.1.1 是 8.5 MiB；
#     v2.0.0 因为内嵌 go-mod/cache/download 是 145 MiB），所以不假设大小，算完立刻清理临时目录。
#   · fan2go 的固定写法本来就是 auto，构建时按上游源码包现算，仓库里不留确定 hash，
#     因此本脚本只巡检它的版本号，不维护它的 hash。
#
# 本脚本只读：不修改 install-deps.sh / diy-part2.sh、不改任何文件，只把"钉住的 vs 上游的"打出来，
# 由 .github/workflows/dependency-auditor.yml 决定开 issue 还是开 PR。
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
#   dae_pinned=<diy-part2.sh 里的当前版本>
#   dae_latest=<上游最新 release 版本，去 v 前缀>
#   dae_outdated=true|false
#   dae_new_hash=<新版本源码包 sha256；仅 dae_outdated=true 时有值，未漂移留空>
#   fan2go_pinned=<diy-part2.sh 里的当前版本>
#   fan2go_latest=<上游最新 release 版本>
#   fan2go_outdated=true|false
#
# 退出码：E_SUCCESS(0) 正常跑完（有漂移也是 0，本脚本只报告不改文件）；
#         E_UNAVAILABLE(69) 任一网络请求失败或上游响应无法解析。
#
# 约束：版本号【不硬编码】，一律从 install-deps.sh 的常量与 diy-part2.sh 的调用行解析；
#       唯一硬编码的是下面几个上游 API / 下载地址。
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

# 上游查询与下载地址（本脚本唯一允许硬编码的内容）。
readonly URL_UPX_LATEST="https://api.github.com/repos/upx/upx/releases/latest"
readonly URL_PADJFFS2_HEAD="https://api.github.com/repos/openwrt/openwrt/commits?path=tools/padjffs2/src/padjffs2.c&per_page=1"
readonly URL_PO2LMO_HEAD="https://api.github.com/repos/openwrt/luci/commits?path=modules/luci-base/src/Makefile&per_page=1"
readonly URL_DAE_LATEST="https://api.github.com/repos/daeuniverse/dae/releases/latest"
readonly URL_FAN2GO_LATEST="https://api.github.com/repos/markusressel/fan2go/releases/latest"
# 这是路径前缀而不是完整地址：版本号由函数拼进去，dgst 与源码包共用。
readonly URL_DAE_RELEASE_BASE="https://github.com/daeuniverse/dae/releases/download"
# 两个 inputs 项的钉住值所在文件（相对仓库根目录，下面已 cd 到根）。
readonly DIY_PART2_FILE="scripts/inputs/diy-part2.sh"
# 回退下载源码包用的临时目录；由装上来的 EXIT trap 清理，留空表示尚未创建。
DAE_TMP_DIR=""

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
        -H 'User-Agent: dependency-auditor')

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
# 把版本串拆成「数字部分」与「预发布后缀」两段并归一（内部函数）
#
# 参数：
#   $1 - 版本串（形如 5.2.1 / 2.0.0rc1 / 1.0.0-rc1）
#
# 全局输出（两个都写，调用方自行取用；用全局是因为 02-error-handler 的分工约定里
# 本文件不引入 main，且返回字符串会与「返回码表达比较结果」的语义冲突）：
#   _VER_CORE - 纯数字段（点分隔），已剥掉后缀前的 -/_ 分隔符
#   _VER_PRE  - 归一后的后缀（小写、无前导分隔符），无后缀时为空串
#
# 返回：恒为 0（形状校验由 _require_version_shape 负责，这里不做判定）
#######################################
_VER_CORE=""
_VER_PRE=""

_split_version() {
    local version="$1"
    local core=""

    # 先把"数字部分 + 预发布后缀"切开：后缀固定是结尾那串字母加可选序号，
    # 数字部分只有数字和点，两种字符集不相交，所以从尾部剥即可。
    # 不分这一步的话，2.1.1rc1 的末段会带着 rc1 进算术，10#1rc1 直接抛错，
    # 而算术错误会让比较的两个 if 都不成立、最终返回"不更新"——上游从 rc 转正
    # 这一最该报警的时机反而被静默漏报。
    core="${version%%[A-Za-z]*}"
    # 后缀前的分隔符（1.0.0-rc1 / 1.0.0_rc1）不能留在数字部分里：
    # 留着会拼成 10#0- 这种记号，算术照样炸。
    core="${core%[-_]}"

    # 统一小写再比后缀：上游标签大小写不统一时不至于让 RC 与 rc 判成两个不同前缀。
    # 这里同样把前导分隔符剥掉，1.0.0-rc1 才能与 1.0.0rc1 归一。
    local pre="${version#"${core}"}"
    pre="${pre#[-_]}"
    pre="${pre,,}"

    _VER_CORE="${core}"
    _VER_PRE="${pre}"
}

#######################################
# 逐段比较两个已拆好的数字部分（内部函数）
#
# 参数：
#   $1 - 候选的数字部分
#   $2 - 钉住的数字部分
#
# 返回：
#   0 - 候选更大
#   1 - 候选更小
#   2 - 打平（需要调用方继续比较后缀）
#######################################
_compare_numeric_core() {
    local cand_core="$1"
    local pinned_core="$2"
    local -a cand_parts=()
    local -a pinned_parts=()
    local ifs_saved="${IFS}"
    local width i a b

    # 只在取分段时临时把 IFS 设成 '.'，读完立刻还原，避免污染调用方的 word splitting。
    IFS='.'
    read -r -a cand_parts <<<"${cand_core}"
    read -r -a pinned_parts <<<"${pinned_core}"
    IFS="${ifs_saved}"

    width=${#cand_parts[@]}
    if [[ ${#pinned_parts[@]} -gt ${width} ]]; then
        width=${#pinned_parts[@]}
    fi
    for ((i = 0; i < width; i++)); do
        a="${cand_parts[i]:-0}"
        b="${pinned_parts[i]:-0}"
        # 10# 前缀强制十进制：0 开头的段（如 08）在算术上下文里会按八进制解析而报错。
        # 后缀已在上一步切走，这里拿到的必然是纯数字段。
        if ((10#${a} > 10#${b})); then
            return 0
        fi
        if ((10#${a} < 10#${b})); then
            return 1
        fi
    done
    return 2
}

#######################################
# 把预发布后缀映射成可比的大小（内部函数）
#
# 参数：
#   $1 - 后缀（小写、无前导分隔符；可为空）
#
# 输出：stdout 输出 "<rank> <num>"，rank 越大越新
#
# 说明：按 semver 惯例 alpha < beta < pre < rc；未列入的前缀（如 dev / snapshot）
#       排在 rc 之后，这样上游换了预发布命名时仍会按"预发布"处理，不会退化成正式版的判定。
#######################################
_version_suffix_rank() {
    local pre="$1"
    local tag num rank

    tag="${pre%%[0-9]*}"
    num="${pre#"${tag}"}"
    case "${tag}" in
        alpha) rank=1 ;;
        beta) rank=2 ;;
        pre | preview) rank=3 ;;
        rc) rank=4 ;;
        *) rank=5 ;;
    esac
    printf '%s %s' "${rank}" "${num:-0}"
}

#######################################
# 数字部分打平后，用预发布后缀决定谁更新（内部函数）
#
# 参数：
#   $1 - 候选后缀  $2 - 钉住后缀
#
# 返回：
#   0 - 候选更新；1 - 候选不更新
#######################################
_compare_version_suffix() {
    local cand_pre="$1"
    local pinned_pre="$2"
    local cand_rank cand_num pinned_rank pinned_num

    # 没后缀的一侧是正式版，正式版更高。
    if [[ -z "${cand_pre}" && -z "${pinned_pre}" ]]; then
        # 两侧都是正式版且数字部分相同 -> 版本相同，不算更新。
        return 1
    fi
    if [[ -z "${cand_pre}" ]]; then
        # 候选是正式版、钉住还停在预发布 -> 正是"上游从 rc 转正"那一刻，必须判更新。
        return 0
    fi
    if [[ -z "${pinned_pre}" ]]; then
        # 反过来：候选还是预发布、钉住已是正式版 -> 不该误报。
        return 1
    fi

    read -r cand_rank cand_num <<<"$(_version_suffix_rank "${cand_pre}")"
    read -r pinned_rank pinned_num <<<"$(_version_suffix_rank "${pinned_pre}")"
    if ((cand_rank > pinned_rank)); then
        return 0
    fi
    if ((cand_rank < pinned_rank)); then
        return 1
    fi
    # 前缀相同只差序号：rc2 > rc1，缺序号的当 0（rc > rc1 这种写法很少见，按 0 处理）。
    if ((10#${cand_num:-0} > 10#${pinned_num:-0})); then
        return 0
    fi
    return 1
}

#######################################
# 数值化比较版本号：candidate 是否比 pinned 新
#
# 参数：
#   $1 - 候选版本（上游最新，形如 5.2.1 / 2.1.1rc1）
#   $2 - 钉住的版本（形如 5.0.2 / 2.0.0rc1）
#
# 返回：
#   0 - candidate > pinned
#   1 - candidate <= pinned
#
# 说明：分两段比，数字部分优先，预发布后缀只在数字部分完全相同时才参与判定。
#       数字部分逐段按十进制比，因此 5.10 > 5.9（字符串比较会得到相反结论）；
#       缺段按 0 补齐（5.2 == 5.2.0）。
#       后缀按 semver 惯例：数字部分相同时 正式版 > 预发布版；预发布之间
#       alpha < beta < pre < rc；前缀相同再比序号（rc2 > rc1）。
#       后缀前的 -/_ 分隔符与大小写都做归一，2.0.0-rc1 与 2.0.0RC1 视为同一个预发布。
#       两侧先由调用方用 _require_version_shape 卡过形状，这里不再兜底解析失败。
#######################################
_version_is_newer() {
    local candidate="$1"
    local pinned="$2"
    local cand_core cand_pre pinned_core pinned_pre

    _split_version "${candidate}"
    cand_core="${_VER_CORE}"
    cand_pre="${_VER_PRE}"
    _split_version "${pinned}"
    pinned_core="${_VER_CORE}"
    pinned_pre="${_VER_PRE}"

    # 数字部分：0 更大 / 1 更小 / 2 打平（结果码直接沿用 _compare_numeric_core 的约定）
    _compare_numeric_core "${cand_core}" "${pinned_core}"
    case $? in
        0) return 0 ;;
        1) return 1 ;;
    esac

    _compare_version_suffix "${cand_pre}" "${pinned_pre}"
}

#######################################
# 从 diy-part2.sh 的调用行里取第一个引号内的版本号
#
# 参数：
#   $1 - 函数名（set_dae_version / set_fan2go_version）
#
# 输出：
#   纯版本号（2.0.0）
#
# 返回：
#   0 - 解析成功；1 - 没有生效的调用行，或引号内容不是纯版本号
#
# 说明：只认「行首没有注释符、整行以 <函数名> 开头」的那一行，避免把注释里的示例
#       （上游 mods 文件的示例里就写着旧版本）或被注释掉的旧调用当成现值。
#######################################
_parse_pinned_version_from_diy_part2() {
    local fn_name="$1"
    local line=""
    local version=""

    # 匹配式用 ^ 锚行首：注释行以 # 开头，连函数名都匹配不上，自然不会被选中。
    line="$(grep -E "^${fn_name} " "${DIY_PART2_FILE}" | head -n1)" || true
    if [[ -z "${line}" ]]; then
        return 1
    fi
    # 第一个 "..." 里就是版本号；第二个引号串是 hash（dae）或 auto（fan2go），与本函数无关。
    version="$(printf '%s' "${line}" | sed -e 's/^[^"]*"//' -e 's/".*//')"
    # 上游允许 2.0.0rc1 这种带后缀的版本，所以不强制纯数字段；但取不出来（空串、
    # 含空格、引号残留）时宁可报错，也不输出一个会被 workflow 写进文件的脏值。
    if ! [[ "${version}" =~ ^[0-9A-Za-z._-]+$ ]]; then
        return 1
    fi
    printf '%s' "${version}"
}

#######################################
# 从 .dgst 文本里取 sha256 行
#
# 参数：
#   $1 - dgst 内容（每行形如 "<hex>  dae-full-src.zip  sha256"）
#
# 输出：
#   64 位十六进制 sha256
#
# 返回：
#   0 - 解析成功；1 - 没有 sha256 行或值不是 64 位十六进制
#
# 说明：按行末的算法标记取，不按行号取：md5 / sha1 / sha256 / sha512 四条的顺序
#       由上游生成工具决定，写死行号会随上游换工具而静默取错算法。
#######################################
_parse_dgst_sha256() {
    local body="$1"
    local sha=""

    sha="$(printf '%s' "${body}" |
        sed -n -e 's/^\([0-9a-f]\{64\}\)[[:space:]][[:space:]]*.*[[:space:]]sha256[[:space:]]*$/\1/p' |
        head -n1)"
    if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
        return 1
    fi
    printf '%s' "${sha}"
}

#######################################
# 下载 dae 源码包并现算 sha256（dgst 缺失时的回退路径）
#
# 参数：
#   $1 - 版本号（纯版本号，不带 v）
#
# 输出：
#   64 位十六进制 sha256
#
# 返回：
#   0 - 成功；1 - 下载失败或算不出合法 sha256
#
# 说明：源码包体积不定（v2.1.1 是 8.5 MiB，v2.0.0 内嵌 go-mod 缓存是 145 MiB），
#       所以不设预期大小，只把超时放宽；文件与临时目录由 EXIT trap 兜底清理。
#######################################
_compute_dae_source_sha256() {
    local version="$1"
    local url="${URL_DAE_RELEASE_BASE}/v${version}/dae-full-src.zip"
    local zip_path=""
    local sha=""
    local sha_cmd=""

    if [[ -z "${DAE_TMP_DIR}" || ! -d "${DAE_TMP_DIR}" ]]; then
        log_error "回退计算 sha256 时临时目录不可用"
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        # 精简镜像 / macOS 上可能只有 perl 自带的 shasum，算法要显式给 -a 256。
        sha_cmd="shasum -a 256"
    else
        log_error "sha256sum 与 shasum 都不存在，无法回退计算 dae 源码包 hash"
        return 1
    fi

    zip_path="${DAE_TMP_DIR}/dae-full-src.zip"
    log_info "dgst 不可用，回退下载 dae 源码包现算 sha256：${url}"
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 1800 -o "${zip_path}" "${url}"; then
        log_error "下载 dae 源码包失败：${url}"
        return 1
    fi
    # shellcheck disable=SC2086  # sha_cmd 可能是 "shasum -a 256" 这种带参数的形式，这里必须故意分词
    sha="$(${sha_cmd} "${zip_path}" | sed -e 's/[[:space:]].*//')"
    rm -f "${zip_path}"
    # 回退路径拿到脏值会让 workflow 把错误的 hash 写进固定行，比直接失败更糟。
    if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "回退计算的 dae 源码包 sha256 不是 64 位十六进制：'${sha}'"
        return 1
    fi
    printf '%s' "${sha}"
}

#######################################
# 取 dae 指定版本源码包的 sha256：dgst 优先，缺失时回退下载计算
#
# 参数：
#   $1 - 版本号（纯版本号）
#
# 输出：
#   64 位十六进制 sha256
#
# 返回：
#   0 - 成功；1 - 两条路径都拿不到合法 sha256
#
# 说明：dgst 只有几十字节，命中就省掉一次几十上百 MiB 的下载，所以永远先试它；
#       但上游并非每个 tag 都发 dgst（实测 v2.1.0 是 404），回退路径不能省。
#######################################
_resolve_dae_source_sha256() {
    local version="$1"
    local dgst_url="${URL_DAE_RELEASE_BASE}/v${version}/dae-full-src.zip.dgst"
    local dgst_body=""

    if dgst_body="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "${dgst_url}" 2>/dev/null)"; then
        if _parse_dgst_sha256 "${dgst_body}"; then
            log_info "dae v${version} 的 sha256 取自 dgst：${dgst_url}"
            return 0
        fi
        log_warning "dae v${version} 的 dgst 里没有可用的 sha256 行，回退下载源码包现算"
    else
        log_warning "dae v${version} 的 dgst 不可用，回退下载源码包现算"
    fi
    _compute_dae_source_sha256 "${version}"
}

#######################################
# 校验版本串形状：<数字段>.[<数字段>...] + 可选预发布后缀 [+ 可选序号]
#
# 参数：
#   $1 - 版本号
#   $2 - 报错时用的名字（upx / dae / fan2go）
#
# 返回：
#   0 - 形状合法；1 - 不合法（已 log_error）
#
# 说明：_version_is_newer 的算术只吃纯数字段，形状不合法时必须在这里就拦下来。
#       让脏值漏进比较的后果不是"报个错"，而是算术失败后静默判成"不落后"——
#       上游从 rc 转正式版这种最该报警的时机反而什么都不做。
#######################################
_require_version_shape() {
    local value="$1"
    local name="$2"

    # 允许 2.1.1、2.0.0rc1、1.0.0-rc1、5.2.1：数字段只收数字与点，
    # 后缀只收字母加可选序号，前面的 -/_ 分隔符可有可无（上游两种写法都用过）。
    if ! [[ "${value}" =~ ^[0-9]+(\.[0-9]+)*([-_]?[A-Za-z]+[0-9]*)?$ ]]; then
        log_error "${name} 的版本串形状无法比较（期望 <数字>.<数字>[...][rc1] 之类）：'${value}'"
        return 1
    fi
    return 0
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

#######################################
# 取上游最新 release 的版本号（内部函数）
#
# 参数：
#   $1 - API URL
#   $2 - 失败时用于报错的工具名（upx / dae / fan2go）
#
# 输出：
#   stdout 输出纯版本号；失败时输出空串
#
# 返回：
#   0 - 取到且形状合法
#   $E_UNAVAILABLE - 网络失败 / 解析失败 / 形状非法（均已 log_error）
#######################################
_fetch_latest_release_version() {
    local url="$1"
    local tool="$2"
    local body=""
    local latest=""

    if ! body="$(_github_api_get "${url}")"; then
        log_error "请求 ${tool} 最新 release 失败：${url}"
        return "${E_UNAVAILABLE}"
    fi
    if ! latest="$(_parse_release_tag "${body}")"; then
        log_error "无法从 ${tool} release JSON 中解析 tag_name"
        return "${E_UNAVAILABLE}"
    fi
    _require_version_shape "${latest}" "${tool} 上游" || return "${E_UNAVAILABLE}"
    printf '%s' "${latest}"
}

#######################################
# 取某个仓库指定路径的上游 HEAD commit（内部函数）
#
# 参数：
#   $1 - API URL（per_page=1 的 commits 接口）
#   $2 - 失败时用于报错的工具名（padjffs2 / po2lmo）
#
# 输出：
#   stdout 输出 40 位 sha；失败时输出空串
#
# 返回：
#   0 - 取到合法 sha；$E_UNAVAILABLE - 网络或解析失败（均已 log_error）
#######################################
_fetch_upstream_head_sha() {
    local url="$1"
    local tool="$2"
    local body=""
    local sha=""

    if ! body="$(_github_api_get "${url}")"; then
        log_error "请求 ${tool} 上游 HEAD 失败：${url}"
        return "${E_UNAVAILABLE}"
    fi
    if ! sha="$(_parse_first_commit_sha "${body}")"; then
        log_error "无法取得 ${tool} 上游 HEAD 的 commit sha"
        return "${E_UNAVAILABLE}"
    fi
    printf '%s' "${sha}"
}

#######################################
# 从 diy-part2.sh 取两个 inputs 项的钉住版本号（内部函数）
#
# 全局输出：
#   _PIN_DAE     - set_dae_version 的版本号
#   _PIN_FAN2GO  - set_fan2go_version 的版本号
#
# 返回：
#   0 - 两个都取到且形状合法；$E_UNAVAILABLE - 解析或形状失败（均已 log_error）
#
# 说明：inputs 层两个固定项只能从 diy-part2.sh 的调用行解析：把版本号再硬编码到本脚本
#       就等于出现第二份真值来源，改了一处忘了另一处会让巡检结果与实际构建用的版本悄悄分叉。
#######################################
_PIN_DAE=""
_PIN_FAN2GO=""

_read_pinned_inputs_versions() {
    if ! _PIN_DAE="$(_parse_pinned_version_from_diy_part2 "set_dae_version")"; then
        log_error "无法从 ${DIY_PART2_FILE} 解析 set_dae_version 的版本号"
        return "${E_UNAVAILABLE}"
    fi
    if ! _PIN_FAN2GO="$(_parse_pinned_version_from_diy_part2 "set_fan2go_version")"; then
        log_error "无法从 ${DIY_PART2_FILE} 解析 set_fan2go_version 的版本号"
        return "${E_UNAVAILABLE}"
    fi
    # 钉住值同样要过形状校验：上游从 rc 转正式版时，钉住侧常留在 2.0.0rc1 这种写法上，
    # 而脏值一旦进了比较就会静默判成"不落后"，正好漏掉这个该报警的时机。
    _require_version_shape "${_PIN_DAE}" "dae 钉住" || return "${E_UNAVAILABLE}"
    _require_version_shape "${_PIN_FAN2GO}" "fan2go 钉住" || return "${E_UNAVAILABLE}"
}

#######################################
# 输出一行 key=value 并（可选）写 GITHUB_OUTPUT —— 见 emit_key_value
#
# 巡检结果分三批输出，顺序固定：先 upx，再两个 commit，再两个 inputs 项。
# 顺序固定是 workflow 与本地核对共同的契约，改动即破坏下游解析。
#######################################
_emit_upx_results() {
    emit_key_value "upx_pinned" "${EXTRAS_UPX_VERSION}"
    emit_key_value "upx_latest" "$1"
    emit_key_value "upx_outdated" "$2"
}

_emit_commit_results() {
    emit_key_value "padjffs2_pinned" "${EXTRAS_PADJFFS2_COMMIT:0:12}"
    emit_key_value "padjffs2_upstream" "${1:0:12}"
    emit_key_value "padjffs2_outdated" "$2"
    emit_key_value "po2lmo_pinned" "${EXTRAS_PO2LMO_COMMIT:0:12}"
    emit_key_value "po2lmo_upstream" "${3:0:12}"
    emit_key_value "po2lmo_outdated" "$4"
}

_emit_inputs_results() {
    emit_key_value "dae_pinned" "${_PIN_DAE}"
    emit_key_value "dae_latest" "$1"
    emit_key_value "dae_outdated" "$2"
    emit_key_value "dae_new_hash" "$3"
    emit_key_value "fan2go_pinned" "${_PIN_FAN2GO}"
    emit_key_value "fan2go_latest" "$4"
    emit_key_value "fan2go_outdated" "$5"
}

#######################################
# 逐项打印漂移告警（顺序与上面的输出顺序一致）
#######################################
_log_drift_warnings() {
    if [[ "$1" == "true" ]]; then
        log_warning "upx 有新版本：钉 ${EXTRAS_UPX_VERSION}，上游 $2（workflow 会开 PR）"
    fi
    # commit 钉死是为了防 main 漂移：判定标准只是"是否还是同一个 commit"，
    # 不看快慢、不看先进程度——上游 HEAD 一动就说明钉的位置已落后于它。
    if [[ "$3" == "true" ]]; then
        log_warning "padjffs2 commit 已漂移：钉 ${EXTRAS_PADJFFS2_COMMIT:0:12}，上游 ${4:0:12}（只报告，不自动升级）"
    fi
    if [[ "$5" == "true" ]]; then
        log_warning "po2lmo commit 已漂移：钉 ${EXTRAS_PO2LMO_COMMIT:0:12}，上游 ${6:0:12}（只报告，不自动升级）"
    fi
    if [[ "$7" == "true" ]]; then
        log_warning "dae 有新版本：钉 ${_PIN_DAE}，上游 $8（workflow 会开 PR，版本号与 sha256 一起改）"
    fi
    if [[ "$9" == "true" ]]; then
        log_warning "fan2go 有新版本：钉 ${_PIN_FAN2GO}，上游 ${10}（workflow 会开 PR，只改版本号，hash 保持 auto）"
    fi
}

#######################################
# 主流程
#
# 结构：main 只负责「取数 → 判定 → 输出」三段接线，每段都拆成独立函数。
# 取数失败一律以 E_UNAVAILABLE 结束（"无法完成巡检"），与"有漂移"（仍是 E_SUCCESS）区分开。
#######################################
main() {
    # 常量由 install-deps.sh 提供，取不到就没法巡检；这属于脚本环境问题。
    require_var EXTRAS_UPX_VERSION EXTRAS_PADJFFS2_COMMIT EXTRAS_PO2LMO_COMMIT || {
        log_error "未能从 install-deps.sh 取得 EXTRAS_* 常量"
        return "${E_UNAVAILABLE}"
    }

    _read_pinned_inputs_versions || return "${E_UNAVAILABLE}"

    # ---- 取数：五个上游项各自独立失败，任一失败即整体 E_UNAVAILABLE ----
    local upx_latest="" pad_upstream="" po2lmo_upstream=""
    local dae_latest="" fan2go_latest=""
    upx_latest="$(_fetch_latest_release_version "${URL_UPX_LATEST}" "upx")" || return "${E_UNAVAILABLE}"
    pad_upstream="$(_fetch_upstream_head_sha "${URL_PADJFFS2_HEAD}" "padjffs2")" || return "${E_UNAVAILABLE}"
    po2lmo_upstream="$(_fetch_upstream_head_sha "${URL_PO2LMO_HEAD}" "po2lmo")" || return "${E_UNAVAILABLE}"
    dae_latest="$(_fetch_latest_release_version "${URL_DAE_LATEST}" "dae")" || return "${E_UNAVAILABLE}"
    fan2go_latest="$(_fetch_latest_release_version "${URL_FAN2GO_LATEST}" "fan2go")" || return "${E_UNAVAILABLE}"

    # ---- 判定：版本号用数值比较；commit 只比"是否还是同一个" ----
    local upx_outdated="false" padjffs2_outdated="false" po2lmo_outdated="false"
    local dae_outdated="false" fan2go_outdated="false"
    if _version_is_newer "${upx_latest}" "${EXTRAS_UPX_VERSION}"; then
        upx_outdated="true"
    fi
    if [[ "${pad_upstream}" != "${EXTRAS_PADJFFS2_COMMIT}" ]]; then
        padjffs2_outdated="true"
    fi
    if [[ "${po2lmo_upstream}" != "${EXTRAS_PO2LMO_COMMIT}" ]]; then
        po2lmo_outdated="true"
    fi
    if _version_is_newer "${dae_latest}" "${_PIN_DAE}"; then
        dae_outdated="true"
    fi
    if _version_is_newer "${fan2go_latest}" "${_PIN_FAN2GO}"; then
        fan2go_outdated="true"
    fi

    # ---- 仅在 dae 漂移时取新 hash：未漂移时 workflow 不开 PR ----
    local dae_new_hash=""
    if [[ "${dae_outdated}" == "true" ]]; then
        DAE_TMP_DIR="$(mktemp -d)" || {
            log_error "无法创建回退下载源码包用的临时目录"
            return "${E_UNAVAILABLE}"
        }
        # trap 兜住正常与异常两种退出路径：几十上百 MiB 的源码包不能留在 runner 上。
        trap 'rm -rf "${DAE_TMP_DIR}"' EXIT
        if ! dae_new_hash="$(_resolve_dae_source_sha256 "${dae_latest}")"; then
            log_error "无法取得 dae v${dae_latest} 源码包的 sha256（dgst 与下载回退都没拿到）"
            return "${E_UNAVAILABLE}"
        fi
    fi

    # ---- 输出：key=value 与告警，顺序固定 ----
    _emit_upx_results "${upx_latest}" "${upx_outdated}"
    _emit_commit_results "${pad_upstream}" "${padjffs2_outdated}" "${po2lmo_upstream}" "${po2lmo_outdated}"
    _emit_inputs_results "${dae_latest}" "${dae_outdated}" "${dae_new_hash}" "${fan2go_latest}" "${fan2go_outdated}"

    _log_drift_warnings "${upx_outdated}" "${upx_latest}" \
        "${padjffs2_outdated}" "${pad_upstream}" \
        "${po2lmo_outdated}" "${po2lmo_upstream}" \
        "${dae_outdated}" "${dae_latest}" \
        "${fan2go_outdated}" "${fan2go_latest}"

    log_success "手钉常量巡检完成。"
    return "${E_SUCCESS}"
}

main "$@"
exit "$?"
