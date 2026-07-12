#!/bin/bash
# 文件: common/scripts/mods/ensure-execute-permission.sh
# 用途: 通用地为指定文件添加可执行权限（+x）
#       常用于自定义脚本（如 restore-packages.sh）在构建过程中需要被执行
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/ensure-execute-permission.sh
#   ensure_exec_permission [file_path]
#
# 参数:
#   file_path : 需要添加可执行权限的文件路径，默认值为 files/usr/bin/restore-packages.sh
#
# 返回值:
#   0 - 成功
#   0 - 文件不存在时仅输出警告，不视为错误
#######################################

# 后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 确保文件具有可执行权限
#
# 功能:
#   检查指定文件是否存在，如果存在则为其添加可执行权限（chmod +x）。
#   如果文件不存在，仅记录警告，不中断流程。
#
# Arguments:
#   $1 - 文件路径（可选），默认值为 'files/usr/bin/restore-packages.sh'
#
# Outputs:
#   操作日志到 stderr (通过 log)
#
# Returns:
#   0 - 成功或文件不存在（非致命）
#
# Examples:
#   ensure_exec_permission
#   ensure_exec_permission 'files/usr/bin/my-custom-script.sh'
#######################################
ensure_exec_permission() {
    local target="${1:-files/usr/bin/restore-packages.sh}"

    if [[ -f "${target}" ]]; then
        log INFO "Setting execute permission on ${target}..."
        chmod +x "${target}"
        log INFO "Execute permission set for ${target}."
    else
        log WARN "File ${target} not found, skipping permission change."
    fi
}

# 若直接运行脚本，则执行默认文件
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_exec_permission "$@"
fi
