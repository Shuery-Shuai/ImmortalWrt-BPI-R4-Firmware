#!/bin/bash
#######################################
# 相对路径计算与符号链接创建
#
# 提供纯 Bash 实现的相对路径计算，并基于此创建可移植的符号链接。
#
# 依赖：若未 source logger.sh，将启用后备日志函数。
# 用法：source common/scripts/libs/symlink-utils.sh
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 计算相对路径（纯 Bash 实现）
#
# 从源目录计算到目标路径的相对路径，无需外部工具依赖。
# 用于创建可移植的符号链接。
#
# 参数：
#   $1 - 源目录 (from)
#   $2 - 目标路径 (to)
#
# 输出：
#   相对路径字符串到 stdout (如 "../../target/dir")
#
# 返回：
#   0 - 成功
#   1 - 目录切换失败
#
# 示例：
#   relpath "/a/b/c" "/a/d/e"  # 输出: ../../d/e
#   relpath "/home/user/project" "/opt/lib"  # 输出: ../../../opt/lib
#######################################
relpath() {
    local from_dir="$1"
    local to_path="$2"
    local abs_from abs_to

    # 获取绝对路径
    abs_from="$(cd "${from_dir}" && pwd)" || return 1
    abs_to="$(cd "${to_path}" && pwd)" || return 1

    # 将路径拆分为数组
    local from_parts to_parts
    IFS='/' read -ra from_parts <<<"${abs_from}"
    IFS='/' read -ra to_parts <<<"${abs_to}"

    # 找到公共前缀的结束位置
    local i=0
    while [[ ${i} -lt ${#from_parts[@]} &&
        ${i} -lt ${#to_parts[@]} &&
        "${from_parts[${i}]}" == "${to_parts[${i}]}" ]]; do
        ((i++))
    done

    # 计算需要向上的层数 (../)
    local up_count=$((${#from_parts[@]} - i))
    local rel_path=''
    local j

    for ((j = 0; j < up_count; j++)); do
        rel_path+='../'
    done

    # 添加从公共祖先到目标的路径
    for ((j = i; j < ${#to_parts[@]}; j++)); do
        rel_path+="${to_parts[${j}]}"
        if [[ ${j} -lt $((${#to_parts[@]} - 1)) ]]; then
            rel_path+='/'
        fi
    done

    # 输出最终相对路径（关键修复）
    printf '%s' "${rel_path}"
}

#######################################
# 创建相对路径符号链接
#
# 使用相对路径创建符号链接，避免绝对路径导致的可移植性问题。
# 如果目标位置已存在符号链接或目录，则先删除。
#
# 参数：
#   $1 - 源路径（绝对路径）
#   $2 - 符号链接路径（要创建的链接位置）
#
# 全局变量：
#   None
#
# 输出：
#   操作日志到 stderr (通过 log)
#
# 返回：
#   0 - 符号链接创建成功
#   1 - 相对路径计算失败或 ln 命令失败
#
# 示例：
#   create_relative_symlink "/path/to/source" "feeds/luci/applications/app"
#######################################
create_relative_symlink() {
    local source_abs="$1"
    local target_link="$2"
    local target_dir

    target_dir="$(dirname "${target_link}")"
    mkdir -p "${target_dir}"

    # 删除已存在的链接或目录
    if [[ -L "${target_link}" ]] || [[ -d "${target_link}" ]]; then
        log 'WARN' "Removing existing symlink/directory at ${target_link}"
        rm -rf "${target_link}"
    fi

    # 计算相对路径
    local rel_target
    rel_target="$(relpath "${target_dir}" "${source_abs}")"
    if [[ -z "${rel_target}" ]]; then
        log 'ERROR' "Failed to compute relative path from ${target_dir} to ${source_abs}"
        return 1
    fi

    # 创建符号链接
    if ln -s "${rel_target}" "${target_link}"; then
        log 'INFO' "SUCCESS: Created symlink ${target_link} -> ${rel_target}"
        return 0
    else
        log 'ERROR' "FAILED: Could not create symlink ${target_link}"
        return 1
    fi
}
