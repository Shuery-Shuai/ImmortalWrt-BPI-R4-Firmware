#!/bin/bash
#######################################
# OpenWrt/ImmortalWrt 构建日志函数库
#
# 提供统一的日志输出、级别过滤、颜色支持和文件记录。
#
# 全局变量：
#   LOG_LEVEL              - 当前日志级别 (默认 INFO)
#   LOG_TO_FILE            - 是否写入日志文件 (默认 true)
#   LOG_FILE_PATH          - 日志文件完整路径（显式给出时原样使用，优先级最高）
#   LOG_FILE_BASENAME      - 日志文件名主干，缺省取主脚本文件名（不含目录与 .sh）
#   LOG_LEVEL_TRACE..FATAL - 日志级别常量
#   COLOR_*                - ANSI 颜色常量
#
# 本文件是全仓库 log / COLOR_* / LOG_LEVEL_* 的唯一实现：其他脚本只允许调用，
# 不允许再定义同名函数或同名只读常量（二次 readonly 会按加载顺序报"只读变量"）。
#
# 用法：source scripts/libs/01-shell-logger.sh
#       （常规路径由 scripts/libs/load.sh 最先加载，scripts/libs/01-shell-logger.sh 亦指向此处）
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
# 同一进程里重复 source 本文件（scripts/libs/load.sh 与 scripts/libs/01-shell-logger.sh 都会加载）时，
# 这些 readonly 常量不可能再被赋值一次，因此用哨兵跳过定义块；不变量：值只在首次加载时确定。
if [[ -z "${_SHELL_LOGGER_SH_LOADED:-}" ]]; then
    # shellcheck disable=SC2034
    readonly _SHELL_LOGGER_SH_LOADED=1
    # shellcheck disable=SC2034
    readonly LOG_LEVEL_TRACE=0 LOG_LEVEL_DEBUG=1 LOG_LEVEL_INFO=2
    # shellcheck disable=SC2034
    readonly LOG_LEVEL_WARN=3 LOG_LEVEL_ERROR=4 LOG_LEVEL_FATAL=5
fi

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
if [[ -z "${_SHELL_SHELL_LOGGER_SH_LOADED_COLORS:-}" ]]; then
    if [[ -t 2 ]]; then
        readonly COLOR_RESET='\033[0m'
        readonly COLOR_GRAY='\033[0;37m'
        readonly COLOR_CYAN='\033[0;36m'
        readonly COLOR_BLUE='\033[0;34m'
        # 以下四个沿用迁移前的高亮色：编排层（scripts/build/）的日志包装
        # 与 libs 共用同一套调色板，合成一份后 WARN/ERROR/SUCCESS 的色值与改造前一致。
        readonly COLOR_YELLOW='\033[1;33m'
        readonly COLOR_RED='\033[1;31m'
        readonly COLOR_GREEN='\033[1;32m'
        readonly COLOR_MAGENTA='\033[0;35m'
    else
        readonly COLOR_RESET='' COLOR_GRAY='' COLOR_CYAN=''
        readonly COLOR_BLUE='' COLOR_YELLOW='' COLOR_RED='' COLOR_GREEN='' COLOR_MAGENTA=''
    fi
    # shellcheck disable=SC2034
    readonly _SHELL_SHELL_LOGGER_SH_LOADED_COLORS=1
fi

# 调色板由 scripts/build 与 scripts/libs 共用，显式导出才能跨子 shell 生效（重复 export 幂等）。
export COLOR_RESET COLOR_GRAY COLOR_CYAN COLOR_BLUE COLOR_YELLOW COLOR_RED COLOR_GREEN COLOR_MAGENTA

#######################################
# 可配置的全局变量
#
# 全局变量：
#   LOG_LEVEL      - 当前日志级别，低于此级别的日志将被过滤
#   LOG_TO_FILE    - 是否同时写入日志文件（默认 true，便于本地与 CI 事后排查）
#   LOG_FILE_PATH     - 日志文件完整路径（显式给出时优先，不再拼接）
#   LOG_DIR           - 日志目录（未显式给 LOG_FILE_PATH 时用它拼文件名）
#   LOG_FILE_BASENAME - 日志文件名主干，缺省取主脚本文件名；命名约定由调用方决定
#######################################
: "${LOG_LEVEL:=INFO}"
: "${LOG_TO_FILE:=true}"
: "${LOG_DIR:=logs}"
# 关键：必须用【绝对路径】。各脚本会 cd 到 immortalwrt/ 等子目录，
# 相对路径 logs/ 会解析到 <当前目录>/logs，造成日志散落各处、甚至目录不存在时写入失败。
# 项目根 = 本文件所在目录上溯两级（scripts/libs/ -> scripts/ -> 仓库根）。
_LOG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"

# 缺省文件名按【主脚本】而非【进程】决定：用 $(date) + $$ 拼，等于每个 bash 子进程各算一份，
# 一次运行能散出十几份谁也认不出的日志，而按 mtime 只能挑出"最后写的"、挑不出"这次运行的"。
# 固定名让同一次运行的父子 shell 追加进同一份；至于叫什么（前缀、阶段后缀）属于调用方约定，
# 本库不预设 —— 需要时由调用方设 LOG_FILE_PATH（完整路径）或 LOG_FILE_BASENAME（文件名主干）覆盖。
# 代价：同一目录里跑两次同名脚本，第二次追加在第一次之后（行内时间戳可区分先后）。
_log_main_script_name() {
    # 调用栈最底部的非本文件层级就是主脚本：它 source 本库时正处在栈底。
    local _i _src
    for ((_i = ${#BASH_SOURCE[@]} - 1; _i > 0; _i--)); do
        _src="${BASH_SOURCE[_i]}"
        [[ -n "${_src}" ]] || continue
        [[ "$(basename "${_src}")" == "01-shell-logger.sh" ]] && continue
        basename "${_src}" .sh
        return 0
    done
    printf 'shell'
}

if [[ -z "${LOG_FILE_PATH:-}" ]]; then
    LOG_FILE_BASENAME="${LOG_FILE_BASENAME:-$(_log_main_script_name)}"
    if [[ -n "${_LOG_ROOT}" ]]; then
        LOG_FILE_PATH="${_LOG_ROOT}/${LOG_DIR}/${LOG_FILE_BASENAME}.log"
    else
        # 仓库根不可解析（极少见）时退化到 /tmp，保证仍能记录。
        LOG_FILE_PATH="/tmp/${LOG_FILE_BASENAME}.log"
    fi
fi
# 必须 export：子 bash 重新 source 本文件时若拿不到路径，就会再拼一个，父子的日志就此分家。
# export 而非 readonly：readonly 在重复 source 时会报『只读变量』中断调用者。
export LOG_FILE_PATH
# 导出日志目录的【绝对路径】，供其它模块（如 compile 的阶段日志）复用，
# 避免它们各自写相对路径 ${LOG_DIR}/ 而依赖调用者的 CWD。
LOG_DIR_ABS="$(dirname "${LOG_FILE_PATH}")"
export LOG_DIR_ABS
unset _LOG_ROOT

# 目录不存在时追加会静默失败（>> 到一个不存在的目录什么都不写、也不报错），
# 因此首次写日志前必须先建目录；建不出来则退化为只写 stderr，不能让日志系统本身成为故障源。
# mkdir -p 幂等且开销极小，因此不做跨调用缓存 —— 缓存变量在子 shell 中赋值不会传回父 shell，
# 反而会让后续子 shell 误判『已就绪』而跳过建目录。
_log_file_ready() {
    mkdir -p "$(dirname "${LOG_FILE_PATH}")" 2>/dev/null || { LOG_TO_FILE=false; return 1; }
    [[ -e "${LOG_FILE_PATH}" ]] || : >"${LOG_FILE_PATH}" 2>/dev/null || { LOG_TO_FILE=false; return 1; }
    return 0
}

#######################################
# 获取日志级别的显示样式（内部函数）
#
# 根据日志级别返回对应的颜色代码和 emoji 图标。
#
# 参数：
#   $1 - 日志级别名称 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|SUCCESS)
#
# 输出：
#   输出格式: "颜色代码|emoji"
#   示例: "\033[0;34m|💡"
#
# 返回：
#   0 - 总是成功
#######################################
_get_log_style() {
    local level="$1"
    case "${level}" in
    TRACE) echo "${COLOR_GRAY}|🔬" ;;
    DEBUG) echo "${COLOR_CYAN}|🐛" ;;
    INFO) echo "${COLOR_BLUE}|ℹ️" ;;
    WARN) echo "${COLOR_YELLOW}|⚠️" ;;
    ERROR) echo "${COLOR_RED}|❌" ;;
    FATAL) echo "${COLOR_RED}|💀" ;;
    SUCCESS) echo "${COLOR_GREEN}|✅" ;;
    # 以下四个是 scripts/build 惯用的"子类别"名（log INFO SUCCESS msg 形态）：
    # 合成一份样式表后它们仍得到原有的颜色与 emoji，无需在适配层再写第二份分支。
    FAILURE) echo "${COLOR_RED}|❌" ;;
    WARNING) echo "${COLOR_YELLOW}|⚠️" ;;
    NOTE) echo "${COLOR_BLUE}|📝" ;;
    IMPORTANT) echo "${COLOR_MAGENTA}|⭐" ;;
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
# 输出：
#   日志级别对应的数值 (0-5)，未知级别返回 -1
#
# 返回：
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
# 日志格式: [时间戳+偏移] [级别] [脚本名][分类] 消息  （如 [2026-10-26 11:45:21 +0800]）
#
# 参数：
#   $1 - 日志级别 (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|SUCCESS)
#   $2 - 消息内容 或 分类名称
#   $3 - 消息内容（当 $2 是分类时）
#   $4 - 是否写入文件 (true|false，覆盖 LOG_TO_FILE 变量)
#
# 输出：
#   格式化的日志输出到 stderr
#   如果启用文件记录，同时追加到 LOG_FILE_PATH
#
# 返回：
#   0 - 成功
#   1 - 参数错误
#
# 示例：
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

    # 行内标记取【调用方源文件名】（不是文件名主干）：一份日志里往往有多个模块在写，
    # 标记只有落到具体模块才有辨识度（mods/07-git-utils.sh 与 diy-part2.sh 要分得开）。
    # 不能简单取 BASH_SOURCE[1]：每多一层薄包装（log_info → log）层级就偏移一格，会取到 'bash'，
    # 因此从 1 起向下找第一个【非本文件、非 bash 自身】的层级。
    local script_name="unknown"
    local _i _src
    for ((_i = 1; _i < ${#BASH_SOURCE[@]}; _i++)); do
        _src="${BASH_SOURCE[_i]}"
        [[ -z "${_src}" ]] && continue
        [[ "$(basename "${_src}")" == "01-shell-logger.sh" ]] && continue
        [[ "$(basename "${_src}")" == "bash" ]] && continue
        script_name="$(basename "${_src}" .sh)"
        break
    done
    unset _i _src

    # 构建分类标签：stderr 保留带色带 emoji 的形态（与 scripts/build 长期使用的
    # "[✅ SUCCESS]" 子标签一致），落文件仍是去掉颜色代码的纯文本。
    local cat_tag="" cat_tag_plain=""
    if [[ -n "${category}" ]]; then
        local cat_style cat_color cat_emoji
        cat_style=$(_get_log_style "${category}")
        cat_color="${cat_style%|*}"
        cat_emoji="${cat_style#*|}"
        cat_tag=" ${cat_color}[${cat_emoji} ${category}]${COLOR_RESET}"
        cat_tag_plain=" [${cat_emoji} ${category}]"
    fi

    # 输出到 stderr（带颜色）
    local timestamp
    # 时间戳必须带 UTC 偏移：容器/精简镜像在装 tzdata 之前 TZ 不生效（date 落回 UTC），
    # 装完才变成 +08:00。同一份日志里混有两种时钟而又不留偏移标记，首末行相减就会算出
    # 几个小时甚至更长的假耗时。带上 %z 后，任何时刻的行都能换算回绝对时间。
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %z')
    printf '%b\n' "[${timestamp}] ${color}[${emoji} ${level}]${COLOR_RESET} [${script_name}]${cat_tag} ${message}" >&2

    # 输出到文件（不带颜色代码）
    if [[ "${to_file}" == "true" ]] && _log_file_ready; then
        echo "[${timestamp}] [${emoji} ${level}] [${script_name}]${cat_tag_plain} ${message}" >>"${LOG_FILE_PATH}"
    fi
}

# ---------- 便捷包装（供 build 层与 inputs 层共用；纯格式化，无业务语义） ----------
# log_success 的 SUCCESS 走到分类标签位，仍是 "[✅ SUCCESS]"（绿 + ✅）。
log_info() {
    log INFO "$@"
}

log_success() {
    log INFO "SUCCESS" "$@"
}

log_warning() {
    log WARN "$@"
}

log_error() {
    log ERROR "$@"
}
