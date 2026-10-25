#!/bin/bash
#######################################
# 版本号规范化工具
#
# 将包含预发布标识的版本号转换为 OpenWrt 兼容格式。
#
# 用法：source scripts/inputs/utils/02-version-utils.sh
#######################################

#######################################
# 将版本号转换为 OpenWrt 兼容格式
#
# 对于包含预发布标识（rc、beta、alpha 等）的版本号，
# 在标识前插入下划线，例如：
#   1.1.0rc1  ->  1.1.0_rc1
#   2.0.0beta2 -> 2.0.0_beta2
#
# 参数：
#   $1 - 原始版本号
#
# 输出：
#   转换后的版本号到 stdout
#
# 示例：
#   normalize_pkg_version "1.1.0rc1"    # 输出: 1.1.0_rc1
#######################################
normalize_pkg_version() {
    local version="$1"
    if [[ "${version}" =~ ^([0-9.]+)(rc|beta|alpha|pre|preview)(.*)$ ]]; then
        printf '%s_%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${version}"
    fi
}

#######################################
# 把一个版本号解析成「数字段 / 预发布前缀 / 预发布序号」
#
# 参数：
#   $1 - 原始版本号（可带 v 前缀、- 或 _ 分隔的预发布后缀）
#   $2 - 接收结果的数组名（nameref，回填 [0]=数字段 [1]=小写前缀 [2]=序号）
#
# 返回：
#   0 - 解析成功；1 - 形状不认识（调用方负责决定怎么兜底）
#
# 说明：用 nameref 回填而不是打印出来再切分。历史上这里靠 IFS 切分返回值，
#       一旦分隔符落在 IFS 空白类（如制表符）里，read 会把连续分隔符折叠成一个，
#       空字段（正式版没有预发布后缀时正是这种情形）就被吞掉，导致数组错位、
#       后续算术把空串喂给 10# 而报错。回填数组从根上没有这个问题。
#######################################
_version_parse() {
    local raw="$1"
    local -n _version_out="$2"
    local body="${raw#[vV]}"

    # _ 与 - 两种写法上游都用过（1.1.0rc1 / 1.0.0-rc1），统一成 - 再解析。
    body="${body//_/-}"

    # 数字段只收数字与点；后缀只收字母加可选序号，前面的 - 可有可无。
    if [[ "${body}" =~ ^([0-9]+(\.[0-9]+)*)(-?([A-Za-z]+)([0-9]*))?$ ]]; then
        _version_out[0]="${BASH_REMATCH[1]}"
        # 前缀统一转小写，让 1.0.0RC1 与 1.0.0rc1 判为同一预发布。
        _version_out[1]="${BASH_REMATCH[4],,}"
        _version_out[2]="${BASH_REMATCH[5]:-0}"
        return 0
    fi
    return 1
}

#######################################
# 比较两个版本号（去除 v 前缀）
#
# 参数：
#   $1 - 版本号 1
#   $2 - 版本号 2
#
# 返回：
#   -1  v1 < v2
#    0  v1 == v2
#    1  v1 > v2
#
# 规则：
#   先比较数字部分，再比较预发布后缀。
#   正式版 > rc > beta > alpha > pre
#   同后缀按数字比较
#
# 示例：
#   compare_versions "1.1.0" "1.1.0rc1"   # 返回 1
#   compare_versions "1.0.0" "2.0.0"      # 返回 -1
#
# 说明：无法解析的版本号按「相等」处理（返回 0）并在 stderr 留一行 WARN。
#       这样 _package_is_newer 会判「不需要更新」，即宁可不动也不误升级。
#######################################
compare_versions() {
    local v1="$1"
    local v2="$2"
    local -a parts1=() parts2=() seg1=() seg2=()
    local max_len=0 i=0 a="" b="" rank1=0 rank2=0

    if ! _version_parse "${v1}" parts1; then
        printf "WARN compare_versions: 无法解析版本 1：%s\n" "${v1}" >&2
        echo 0
        return
    fi
    if ! _version_parse "${v2}" parts2; then
        printf "WARN compare_versions: 无法解析版本 2：%s\n" "${v2}" >&2
        echo 0
        return
    fi

    # 数字段逐段按十进制比较：10# 前缀强制十进制，避免 0 开头的段（如 08）
    # 被算术上下文按八进制解析而报错。缺段按 0 补齐，因此 1.0 == 1.0.0。
    IFS=. read -r -a seg1 <<<"${parts1[0]}"
    IFS=. read -r -a seg2 <<<"${parts2[0]}"
    max_len=${#seg1[@]}
    if [[ ${#seg2[@]} -gt ${max_len} ]]; then max_len=${#seg2[@]}; fi
    for ((i = 0; i < max_len; i++)); do
        a="${seg1[i]:-0}"
        b="${seg2[i]:-0}"
        if ((10#${a} > 10#${b})); then echo 1; return; fi
        if ((10#${a} < 10#${b})); then echo -1; return; fi
    done

    # 数字部分打平才轮到预发布后缀：正式版高于同号的任何预发布。
    if [[ -z "${parts1[1]:-}" && -z "${parts2[1]:-}" ]]; then echo 0; return; fi
    if [[ -z "${parts1[1]:-}" && -n "${parts2[1]:-}" ]]; then echo 1; return; fi
    if [[ -n "${parts1[1]:-}" && -z "${parts2[1]:-}" ]]; then echo -1; return; fi

    declare -A pre_rank=([alpha]=1 [beta]=2 [pre]=3 [preview]=3 [rc]=4)
    # 未登记的预发布前缀排在 rc 之后：上游换命名时仍按「预发布」处理，
    # 不会因为查不到 rank 就退化成正式版而与同号正式版判为相等。
    rank1="${pre_rank[${parts1[1]}]:-5}"
    rank2="${pre_rank[${parts2[1]}]:-5}"
    if ((rank1 > rank2)); then echo 1; return; fi
    if ((rank1 < rank2)); then echo -1; return; fi

    if ((10#${parts1[2]} > 10#${parts2[2]})); then echo 1; return; fi
    if ((10#${parts1[2]} < 10#${parts2[2]})); then echo -1; return; fi

    echo 0
}
