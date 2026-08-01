#!/bin/bash
#######################################
# OpenWrt/ImmortalWrt 构建日志函数库
#
# 提供统一的日志输出、级别过滤、颜色支持和文件记录。
#
# 全局变量：
#   LOG_LEVEL              - 当前日志级别 (默认 INFO)
#   LOG_TO_FILE            - 是否写入日志文件 (默认 false)
#   LOG_FILE_PATH          - 日志文件路径
#   LOG_LEVEL_TRACE..FATAL - 日志级别常量
#   COLOR_*                - ANSI 颜色常量
#
# 用法：source common/scripts/libs/logger.sh
#######################################

#######################################
# 日志级别常量
#
# 用于设置和比较日志级别，数值越小级别越低。
#
# 全局变量：
#   LOG_LEVEL_TRACE  - 追踪级别 (0)
#   LOG_LEVEL_DEBUG  - 调试级别 (1)
#   LOG_LEVEL_INFO   - 信息级别 (2)
#   LOG_LEVEL_WARN   - 警告级别 (3)
#   LOG_LEVEL_ERROR  - 错误级别 (4)
#   LOG_LEVEL_FATAL  - 致命级别 (5)
#######################################
# shellcheck disable=SC2034
readonly LOG_LEVEL_TRACE=0 LOG_LEVEL_DEBUG=1 LOG_LEVEL_INFO=2
# shellcheck disable=SC2034
readonly LOG_LEVEL_WARN=3 LOG_LEVEL_ERROR=4 LOG_LEVEL_FATAL=5

#######################################
# ANSI 颜色代码常量
#
# 根据输出目标是否为终端自动启用或禁用颜色。
# 仅当 stderr 连接到 TTY 时启用彩色输出。
#
# 全局变量：
#   COLOR_RESET  - 重置所有样式
#   COLOR_GRAY   - 灰色（用于 TRACE）
#   COLOR_CYAN   - 青色（用于 DEBUG）
#   COLOR_BLUE   - 蓝色（用于 INFO）
#   COLOR_YELLOW - 黄色（用于 WARN）
#   COLOR_RED    - 红色（用于 ERROR/FATAL）
#   COLOR_GREEN  - 绿色（用于 SUCCESS）
#######################################
if [[ -t 2 ]]; then
    readonly COLOR_RESET='\033[0m'
    readonly COLOR_GRAY='\033[0;37m'
    readonly COLOR_CYAN='\033[0;36m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_YELLOW='\033[1;33m'
    readonly COLOR_RED='\033[1;31m'
    readonly COLOR_GREEN='\033[1;32m'
else
    readonly COLOR_RESET='' COLOR_GRAY='' COLOR_CYAN=''
    readonly COLOR_BLUE='' COLOR_YELLOW='' COLOR_RED='' COLOR_GREEN=''
fi

#######################################
# 可配置的全局变量
#
# 全局变量：
#   LOG_LEVEL      - 当前日志级别，低于此级别的日志将被过滤
#   LOG_TO_FILE    - 是否同时写入日志文件
#   LOG_FILE_PATH  - 日志文件的存储路径
#######################################
: "${LOG_LEVEL:=INFO}"
: "${LOG_TO_FILE:=false}"
: "${LOG_FILE_PATH:=/tmp/openwrt_build_$(date +%Y%m%d_%H%M%S).log}"

#######################################
# 获取日志级别的显示样式（内部函数）
#
# 根据日志级别返回对应的颜色代码和 emoji 图标。
#
# 参数：
#   $1 - 日志级别名称 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|SUCCESS)
#
# Outputs:
#   输出格式: "颜色代码|emoji"
#   示例: "\033[0;34m|💡"
#
# Returns:
#   0 - 总是成功
#######################################
_get_log_style() {
    local level="$1"
    case "${level}" in
    TRACE) echo "${COLOR_GRAY}|🔬" ;;
    DEBUG) echo "${COLOR_CYAN}|🐛" ;;
    INFO) echo "${COLOR_BLUE}|💡" ;;
    WARN) echo "${COLOR_YELLOW}|🚨" ;;
    ERROR) echo "${COLOR_RED}|🚫" ;;
    FATAL) echo "${COLOR_RED}|💀" ;;
    SUCCESS) echo "${COLOR_GREEN}|✅" ;;
    *) echo "${COLOR_GRAY}|📌" ;;
    esac
}

#######################################
# 将日志级别名称转换为数值（内部函数）
#
# 用于比较日志级别的优先级。
#
# 参数：
#   $1 - 日志级别名称
#
# Outputs:
#   日志级别对应的数值 (0-5)，未知级别返回 -1
#
# Returns:
#   0 - 总是成功
#######################################
_normalize_log_level() {
    case "$1" in
    TRACE) echo 0 ;;
    DEBUG) echo 1 ;;
    INFO) echo 2 ;;
    WARN) echo 3 ;;
    ERROR) echo 4 ;;
    FATAL) echo 5 ;;
    *) echo -1 ;;
    esac
}

#######################################
# 输出格式化的日志消息
#
# 支持多种调用方式：
#   - log LEVEL MESSAGE
#   - log LEVEL CATEGORY MESSAGE
#   - log LEVEL CATEGORY MESSAGE TO_FILE
#
# 日志格式: [时间戳] [级别] [脚本名][分类] 消息
#
# 参数：
#   $1 - 日志级别 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|SUCCESS)
#   $2 - 消息内容 或 分类名称
#   $3 - 消息内容（当 $2 是分类时）
#   $4 - 是否写入文件 (true|false，覆盖 LOG_TO_FILE 变量)
#
# Outputs:
#   格式化的日志输出到 stderr
#   如果启用文件记录，同时追加到 LOG_FILE_PATH
#
# Returns:
#   0 - 成功
#   1 - 参数错误
#
# Examples:
#   log INFO "服务已启动"
#   log WARN "网络" "连接超时，正在重试..."
#   log ERROR "数据库" "连接失败" true
#######################################
log() {
    local level="$1"
    local category=""
    local message=""
    local to_file="${LOG_TO_FILE}"

    case $# in
    2) message="$2" ;;
    3)
        category="$2"
        message="$3"
        ;;
    4)
        category="$2"
        message="$3"
        to_file="$4"
        ;;
    *)
        printf 'Usage: log LEVEL [CATEGORY] MESSAGE [TO_FILE]\n' >&2
        return 1
        ;;
    esac

    # 级别过滤：如果当前消息级别低于设定级别，直接返回
    local level_num current_level_num
    level_num=$(_normalize_log_level "${level}")
    current_level_num=$(_normalize_log_level "${LOG_LEVEL}")
    [[ ${level_num} -lt ${current_level_num} ]] && return 0

    # 获取样式
    local style color emoji
    style=$(_get_log_style "${level}")
    color="${style%|*}"
    emoji="${style#*|}"

    # 获取调用脚本名称（去除路径和扩展名）
    local script_name
    script_name=$(basename "${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-unknown}}" .sh)

    # 构建分类标签
    local cat_tag=""
    [[ -n "${category}" ]] && cat_tag=" [${category}]"

    # 输出到 stderr（带颜色）
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%b\n' "[${timestamp}] ${color}[${emoji} ${level}]${COLOR_RESET} [${script_name}]${cat_tag} ${message}" >&2

    # 输出到文件（不带颜色代码）
    if [[ "${to_file}" == "true" ]]; then
        echo "[${timestamp}] [${emoji} ${level}] [${script_name}]${cat_tag} ${message}" >>"${LOG_FILE_PATH}"
    fi
}
