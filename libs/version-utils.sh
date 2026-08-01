#!/bin/bash
#######################################
# 版本号规范化工具
#
# 将包含预发布标识的版本号转换为 OpenWrt 兼容格式。
#
# 用法：source common/scripts/libs/version-utils.sh
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
#######################################
compare_versions() {
    local v1="$1"
    local v2="$2"
    local num1 num2 pre1 pre2 pre_num1 pre_num2

    # 分离数字和预发布
    if [[ "${v1}" =~ ^([0-9.]+)(rc|beta|alpha|pre|preview)?([0-9]*)$ ]]; then
        num1="${BASH_REMATCH[1]}"
        pre1="${BASH_REMATCH[2]}"
        pre_num1="${BASH_REMATCH[3]:-0}"
    else
        num1="$v1"
        pre1=""
        pre_num1="0"
    fi

    if [[ "${v2}" =~ ^([0-9.]+)(rc|beta|alpha|pre|preview)?([0-9]*)$ ]]; then
        num2="${BASH_REMATCH[1]}"
        pre2="${BASH_REMATCH[2]}"
        pre_num2="${BASH_REMATCH[3]:-0}"
    else
        num2="$v2"
        pre2=""
        pre_num2="0"
    fi

    # 比较数字部分
    local IFS=.
    local arr1=("${num1}") arr2=("${num2}")
    local max_len=$((${#arr1[@]} > ${#arr2[@]} ? ${#arr1[@]} : ${#arr2[@]}))
    for ((i = 0; i < max_len; i++)); do
        local a=${arr1[$i]:-0}
        local b=${arr2[$i]:-0}
        if ((a > b)); then
            echo 1
            return
        elif ((a < b)); then
            echo -1
            return
        fi
    done

    # 数字相同，比较预发布
    declare -A pre_rank=([alpha]=1 [beta]=2 [pre]=3 [preview]=3 [rc]=4)
    local rank1="${pre_rank[${pre1}]:-0}"
    local rank2="${pre_rank[${pre2}]:-0}"

    if [[ -z "${pre1}" && -z "${pre2}" ]]; then
        echo 0
        return
    elif [[ -z "${pre1}" && -n "${pre2}" ]]; then
        echo 1
        return # 正式 > 预发布
    elif [[ -n "${pre1}" && -z "${pre2}" ]]; then
        echo -1
        return
    fi

    if ((rank1 > rank2)); then
        echo 1
        return
    elif ((rank1 < rank2)); then
        echo -1
        return
    fi

    if ((pre_num1 > pre_num2)); then
        echo 1
        return
    elif ((pre_num1 < pre_num2)); then
        echo -1
        return
    fi

    echo 0
}
