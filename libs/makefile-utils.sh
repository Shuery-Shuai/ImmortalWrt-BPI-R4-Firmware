#!/bin/bash
#######################################
# Makefile 修改函数库
#
# 提供：
#   - modify_luci_collection   对 LuCI 集合 Makefile 应用 sed 表达式
#   - set_makefile_vars        修改 Makefile 中的变量值（键值对）
#
# 依赖：若未 source logger.sh，将启用后备日志函数。
# 用法：source common/scripts/libs/makefile-utils.sh
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 修改 LuCI 集合 Makefile
#
# 对 LuCI 集合软件包的 Makefile 应用 sed 表达式，用于调整依赖关系。
# 典型用途: 移除 uhttpd 依赖、替换默认主题、删除不需要的应用。
#
# 参数：
#   $1 - Makefile 文件路径
#   $2... - sed 表达式参数（直接传递给 sed -i）
#
# 全局变量：
#   None
#
# Outputs:
#   操作提示到 stdout
#   错误信息到 stderr
#
# Returns:
#   0 - 总是成功（即使文件不存在）
#
# Examples:
#   modify_luci_collection 'feeds/luci/collections/luci/Makefile' \
#     -e '/LUCI_DEPENDS/,/^$/ { /uhttpd/d; }'
#######################################
modify_luci_collection() {
    local makefile="$1"
    shift
    local sed_exprs=("$@")

    if [[ -f "${makefile}" ]]; then
        log 'INFO' "Modifying ${makefile}……"
        sed -i "${sed_exprs[@]}" "${makefile}"
    else
        log 'ERROR' "File ${makefile} does not exist."
    fi
}

#######################################
# 修改软件包 Makefile 中的指定变量值（键值对）
#
# 使用 nameref 接收关联数组名，遍历键并替换 Makefile 中的对应行。
# 若数组未声明或目标文件不存在，则输出错误/警告并安全返回。
#
# 参数：
#   $1 - Makefile 路径
#   $2 - 关联数组变量名（必须预先声明）
#
# Returns:
#   0 - 成功修改
#   1 - 数组不存在
#######################################
set_makefile_vars() {
    local makefile="$1"
    local array_name="$2"

    # 使用 declare -p 检测变量是否已声明（比 -v 更可靠）
    if ! declare -p "${array_name}" &>/dev/null; then
        log ERROR "Array '${array_name}' does not exist."
        return 1
    fi

    if [[ ! -f "${makefile}" ]]; then
        log WARN "Makefile ${makefile} not found, skipping var update."
        return 0
    fi

    # 创建 nameref 引用调用者的数组
    local -n _ref="${array_name}"

    for key in "${!_ref[@]}"; do
        sed -i "s|^${key}:=.*|${key}:=${_ref[$key]}|" "${makefile}"
    done

    log INFO "Updated ${#_ref[@]} variables in ${makefile}"
}
