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
        # 必须是【真 ESC 字节】而不是 '\033[...' 这样的字面反斜杠串。
        # 旧实现靠 printf '%b' 在输出时把 \033 解释成 ESC，一旦改写为 %s（为了不吞消息里的
        # 反斜杠，见 log() 的说明）颜色就会退化成明文 \033[0;34m。调色板本来就该是字节，
        # 解释动作不该由每一条消息的格式化承担，因此在这里一次性定死。
        readonly COLOR_RESET=$'\033[0m'
        readonly COLOR_GRAY=$'\033[0;37m'
        readonly COLOR_CYAN=$'\033[0;36m'
        readonly COLOR_BLUE=$'\033[0;34m'
        # 以下四个沿用迁移前的高亮色：编排层（scripts/build/）的日志包装
        # 与 libs 共用同一套调色板，合成一份后 WARN/ERROR/SUCCESS 的色值与改造前一致。
        readonly COLOR_YELLOW=$'\033[1;33m'
        readonly COLOR_RED=$'\033[1;31m'
        readonly COLOR_GREEN=$'\033[1;32m'
        readonly COLOR_MAGENTA=$'\033[0;35m'
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
# 输出目标：both（终端+文件，默认）/ file（只进文件，静默）/ console（只终端）。
# 这是"终端与文件同源"的开关 —— 此前只有 LOG_TO_FILE 一个维度，想要安静只能 `2>/dev/null`，
# 而那会连文件和终端一起掐掉，正是"没有静默模式"的由来。
# 非法值一律按 both 处理：宁可多输出，不要因为拼错一个单词就丢日志。
: "${LOG_CAPTURE:=both}"
case "${LOG_CAPTURE}" in
both | file | console) ;;
*)
    printf 'log: LOG_CAPTURE=%s 非法（应为 both|file|console），按 both 处理\n' "${LOG_CAPTURE}" >&2
    LOG_CAPTURE=both
    ;;
esac
export LOG_CAPTURE
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

# 文件名主干来自调用方（build.sh 用的是未校验的 $1），必须净化：
# 不去掉路径分隔符的话，`build.sh ../escape` 会把日志写到 logs/ 之外，而 `build.sh /etc/x`
# 更会拼出 logs//etc/x.log。这里与调用方是否校验无关 —— 日志库不能假设调用方都守规矩。
# 同时挡掉前导点和空串：`.` / `..` 会解析成目录，空串会退化成 `${LOG_DIR}/.log`。
_log_sanitize_basename() {
    local name="${1:-}"
    # 先把所有非 [A-Za-z0-9._-] 的字符替换成 _，路径分隔符因此一并消失。
    name="${name//[^A-Za-z0-9._-]/_}"
    # 剥掉前导点：避免 . / .. / 隐藏文件语义。
    while [[ "${name}" == .* ]]; do
        name="${name#.}"
    done
    # 全被剥光（原值就是 "." / ".." / 纯非法字符）时用固定名兜底。
    printf '%s' "${name:-log}"
}

if [[ -z "${LOG_FILE_PATH:-}" ]]; then
    LOG_FILE_BASENAME="$(_log_sanitize_basename "${LOG_FILE_BASENAME:-$(_log_main_script_name)}")"
    if [[ -n "${_LOG_ROOT}" ]]; then
        # LOG_DIR 支持绝对路径：此前无条件拼 ${_LOG_ROOT}/，传绝对路径会拼出
        # "/root//abs/path" 这种非法路径，_log_file_ready 建目录失败后把 LOG_TO_FILE 置 false，
        # 结果是【没有任何告警】地完全不写日志。绝对路径必须原样采用。
        case "${LOG_DIR}" in
        /*) LOG_DIR_ABS="${LOG_DIR}" ;;
        *) LOG_DIR_ABS="${_LOG_ROOT}/${LOG_DIR}" ;;
        esac
        LOG_FILE_PATH="${LOG_DIR_ABS}/${LOG_FILE_BASENAME}.log"
    else
        # 仓库根不可解析（极少见）时退化到 /tmp，保证仍能记录。
        LOG_DIR_ABS="/tmp"
        LOG_FILE_PATH="/tmp/${LOG_FILE_BASENAME}.log"
    fi
fi
# 必须 export：子 bash 重新 source 本文件时若拿不到路径，就会再拼一个，父子的日志就此分家。
# export 而非 readonly：readonly 在重复 source 时会报『只读变量』中断调用者。
export LOG_FILE_PATH
export LOG_FILE_BASENAME
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

# 建目录失败时必须告警。旧实现只把 LOG_TO_FILE 置 false 就返回，等于【静默地完全不写日志】：
# 用户以为在留证据，实际一个字都没落盘。告警走 fd 2（此时采集层可能已接管，仍会进文件）。
_log_dir_fail() {
    printf 'log: 无法创建日志目录或不写 %s，本次运行只输出到终端\n' "${LOG_FILE_PATH}" >&2
    LOG_TO_FILE=false
    return 1
}

#######################################
# 输出采集层（本库的唯一实现）
#
# 为什么必须做在这里：log() 只能记录【经过它自己】的消息，而 apt / make / git / curl
# 这些外部命令是 fork+exec 出来的新进程，它们继承的是本进程的 fd 表，永远不经过 log()。
# 因此"子进程输出进日志"是 fd 边界问题，只有把 fd 1/2 整体接到一个双写管道上才能解决，
# 任何函数级封装都做不到。**全仓库只允许本库建立这层**，其他脚本一律不得自行 tee/exec。
#
# 三个目标（LOG_CAPTURE）：
#   both    - 终端与文件都收到（默认，对应"终端和日志文件同源"）
#   file    - 只进文件，终端安静（对应静默模式；此前根本没有这个能力）
#   console - 只走终端，不建采集层（产物类脚本用，等价旧 LOG_TO_FILE=false）
#
# 关键设计（每条都是实测踩出来的，改动前务必验证）：
#  1) tee 的 stdout 继承的是【重定向之前】的原 stdout，所以 file 模式必须显式 >/dev/null，
#     否则照样刷屏。
#  2) 颜色必须在 exec 之前判定：重定向后 fd 2 变成管道，[[ -t 2 ]] 恒假，全仓彩色会静默消失。
#  3) 落文件要剥 ANSI：否则文件里全是 ESC 序列，grep 与摘要都会被打乱。
#     用 sed -u 逐行剥离（-u 不缓冲，长跑构建下 tee 能即时落盘）。
#  4) log() 在采集层生效时【不再自己写文件】，否则每行会重复两次 —— 文件由 tee 独占。
#######################################
_log_capture_sed_pat() {
    # 用 $'...' 生成真实 ESC：printf '%b' 会把 \033 解释成 ESC，但 sed 的模式里必须是真字节。
    printf 's/%s\\[[0-9;]*[mK]//g' "${_LOG_ESC:-$(printf '\033')}"
}

# 把 fd 1/2 接到「终端 + 文件」双写管道。只能调用一次（重复 exec 会套娃成多份日志）。
_log_start_capture() {
    [[ -n "${_LOG_CAPTURE_ACTIVE:-}" ]] && return 0
    # console = 不建采集层、也不写文件（等价旧 LOG_TO_FILE=false）。
    # 这里必须把 LOG_TO_FILE 一并置 false：否则 log() 的兜底分支仍会自己 append，
    # 出现"选了 console 却还是生成了日志文件"的矛盾行为。
    if [[ "${LOG_CAPTURE}" == "console" ]]; then
        export LOG_TO_FILE=false
        export _LOG_CAPTURE_SKIPPED=1
        return 1
    fi
    [[ "${LOG_TO_FILE}" == "true" ]] || return 1
    _log_file_ready || { _log_dir_fail; return 1; }

    local pat
    pat="$(_log_capture_sed_pat)"

    case "${LOG_CAPTURE}" in
    both)
        # tee 分叉：一路回终端（保留 ESC），一路经 sed 剥色后追加文件。
        exec > >(tee >(sed -u -e "${pat}" >>"${LOG_FILE_PATH}")) 2>&1
        ;;
    file)
        # 显式 >/dev/null：tee 的 stdout 是 exec 前的原 stdout，不丢掉就还是刷屏。
        exec > >(tee >(sed -u -e "${pat}" >>"${LOG_FILE_PATH}") >/dev/null) 2>&1
        ;;
    *)
        # 未知值已在配置校验时归一为 both，正常不会到这里；保守起见不建采集层。
        return 1
        ;;
    esac

    _LOG_CAPTURE_ACTIVE=1
    # 必须 export：子 bash 重新 source 本库时据此避免再套一层 tee。
    export _LOG_CAPTURE_ACTIVE
    return 0
}

# 运行会话的边界标记：没有它，同一份文件里两次运行的行会首尾相接、谁也说不清哪些属于这次。
# 起止各一行，带 run id（时间+PID，可跨文件对齐父子进程）与实际命令。
# 只由入口脚本在采集层启动【之后】调用，这样它自己也落在文件里。
# shellcheck disable=SC2329  # 由 _log_session_begin/_log_session_end 间接调用
_log_write_session() {
    local phase="$1"
    [[ "${LOG_TO_FILE}" == "true" ]] || return 0
    [[ -z "${_LOG_CAPTURE_SKIPPED:-}" ]] || return 0
    _log_file_ready || return 0
    local stamp
    printf -v stamp '%(%Y-%m-%d %H:%M:%S %z)T' -1
    printf '=== RUN %s %s | run=%s | cmd=%s | pid=%s ===\n' \
        "${phase}" "${stamp}" "${LOG_RUN_ID:-?}" "${LOG_RUN_CMD:-?}" "$$" >>"${LOG_FILE_PATH}"
}

_log_session_begin() {
    _log_write_session BEGIN
}
_log_session_end() { _log_write_session END; return 0; }

# 日志归档与轮转（D9）：采集层会把 make/apt/git 的全量输出都收进来，
# 单份日志从 KB 级涨到 MB 级；固定名 + 追加写意味着它只增不减（CI 还整包上传 artifact）。
#
# 策略：每次运行开始时，把上一轮的日志改名归档，再让本次从空文件开始。
#   build-check.log  →  build-check.20261027-224552-4.log
# 归档名带 run id，与主文件同一命名形状；保留最近 LOG_KEEP_RUNS 份（默认 10），多出的删最旧。
# 只删【本库自己归档】的文件（正则严格匹配 run id 形状），手工放的 *.log 一律不碰。
#
# 【时机是硬约束】必须在 _log_start_capture 之前调用：
# tee 在 exec 那一刻就把 fd 绑到了当时那个 inode，之后改名只是改目录项、
# tee 仍会追着旧 inode 写。先改名再开 tee，本次就落在一个干净的新文件上。
#
# 参数：
#   LOG_KEEP_RUNS - 保留归档份数，默认 10；0 或非数字 = 不轮转（仍归档，只是不删）。
_log_archive_previous() {
    [[ "${LOG_TO_FILE}" == "true" ]] || return 0
    [[ "${LOG_CAPTURE}" == "console" ]] && return 0
    local dir
    dir="$(dirname "${LOG_FILE_PATH}")"
    [[ -d "${dir}" ]] || return 0

    # 归档上一轮：文件存在且非空才动，避免把空文件变成一串空归档。
    # 归档名必须用【被归档日志自己的】run id（从首行 BEGIN 标记里读），
    # 而不是本次运行的 id —— 否则文件名说的是"这次"，内容却是"上次"，
    # 且同一秒内连续两次运行会因为 pid 复用而撞名、互相覆盖。
    # 读不到（旧格式日志、被手工截断）时退回文件 mtime，仍是唯一且可排序的。
    if [[ -s "${LOG_FILE_PATH}" ]]; then
        local base="${LOG_FILE_PATH%.log}" old_id stamp
        old_id="$(head -n 1 -- "${LOG_FILE_PATH}" 2>/dev/null |
            grep -oE 'run=[0-9]{8}-[0-9]{6}-[0-9]+' | head -n 1)" || old_id=""
        old_id="${old_id#run=}"
        if [[ -z "${old_id}" ]]; then
            stamp="$(printf '%(%Y%m%d-%H%M%S)T' "$(stat -c %Y -- "${LOG_FILE_PATH}" 2>/dev/null || printf '%s' -1)")"
            old_id="${stamp}-0"
        fi
        mv -f -- "${LOG_FILE_PATH}" "${base}.${old_id}.log" 2>/dev/null || true
    fi

    # 修剪归档：文件名形如 <base>.<8位>-<6位>-<pid>.log，按名字（即时间）排序保留最新 N 份。
    local -i keep="${LOG_KEEP_RUNS:-10}"
    [[ "${keep}" =~ ^[0-9]+$ ]] || keep=10
    ((keep > 0)) || return 0

    local stem="${LOG_FILE_BASENAME:-}"
    [[ -n "${stem}" ]] || return 0
    local -a archived=()
    local f
    while IFS= read -r f; do
        archived+=("${f}")
    done < <(find "${dir}" -maxdepth 1 -type f -name "${stem}.*.log" -printf '%f\n' 2>/dev/null |
        grep -E "^${stem//./\\.}\.[0-9]{8}-[0-9]{6}-[0-9]+\.log$" | sort)
    ((${#archived[@]} > keep)) || return 0

    local -i to_remove=$((${#archived[@]} - keep)) i
    for ((i = 0; i < to_remove; i++)); do
        rm -f -- "${dir}/${archived[i]}" 2>/dev/null || true
    done
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
    TRACE) printf '%s|🔬' "${COLOR_GRAY}" ;;
    DEBUG) printf '%s|🐛' "${COLOR_CYAN}" ;;
    INFO) printf '%s|ℹ️' "${COLOR_BLUE}" ;;
    WARN) printf '%s|⚠️' "${COLOR_YELLOW}" ;;
    ERROR) printf '%s|❌' "${COLOR_RED}" ;;
    FATAL) printf '%s|💀' "${COLOR_RED}" ;;
    SUCCESS) printf '%s|✅' "${COLOR_GREEN}" ;;
    # 以下四个是 scripts/build 惯用的"子类别"名（log INFO SUCCESS msg 形态）：
    # 合成一份样式表后它们仍得到原有的颜色与 emoji，无需在适配层再写第二份分支。
    FAILURE) printf '%s|❌' "${COLOR_RED}" ;;
    WARNING) printf '%s|⚠️' "${COLOR_YELLOW}" ;;
    NOTE) printf '%s|📝' "${COLOR_BLUE}" ;;
    IMPORTANT) printf '%s|⭐' "${COLOR_MAGENTA}" ;;
    *) printf '%s|📌' "${COLOR_GRAY}" ;;
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
    TRACE) printf '0' ;;
    DEBUG) printf '1' ;;
    INFO) printf '2' ;;
    WARN) printf '3' ;;
    ERROR) printf '4' ;;
    FATAL) printf '5' ;;
    *) printf '%s' '-1' ;;
    esac
}

# ---------- 免 fork 的查表变体（log() 热路径专用） ----------
# 与上面两个函数语义完全一致，但结果写进调用方可见的变量而不是 stdout，
# 从而省掉 $(...) 的子 shell。保留原来的 *_normalize_log_level / _get_log_style 是因为
# 它们是库的既有对外形态，删掉会破坏可能在别处直接调用的脚本；新代码一律用下面这组。
_log_level_num() {
    case "${1:-}" in
    TRACE) _LOG_LEVEL_NUM=0 ;;
    DEBUG) _LOG_LEVEL_NUM=1 ;;
    INFO) _LOG_LEVEL_NUM=2 ;;
    WARN) _LOG_LEVEL_NUM=3 ;;
    ERROR) _LOG_LEVEL_NUM=4 ;;
    FATAL) _LOG_LEVEL_NUM=5 ;;
    *) _LOG_LEVEL_NUM=-1 ;;
    esac
}

_log_style() {
    case "${1:-}" in
    TRACE) _LOG_STYLE_COLOR="${COLOR_GRAY}" _LOG_STYLE_EMOJI='🔬' ;;
    DEBUG) _LOG_STYLE_COLOR="${COLOR_CYAN}" _LOG_STYLE_EMOJI='🐛' ;;
    INFO) _LOG_STYLE_COLOR="${COLOR_BLUE}" _LOG_STYLE_EMOJI='ℹ️' ;;
    WARN) _LOG_STYLE_COLOR="${COLOR_YELLOW}" _LOG_STYLE_EMOJI='⚠️' ;;
    ERROR) _LOG_STYLE_COLOR="${COLOR_RED}" _LOG_STYLE_EMOJI='❌' ;;
    FATAL) _LOG_STYLE_COLOR="${COLOR_RED}" _LOG_STYLE_EMOJI='💀' ;;
    SUCCESS) _LOG_STYLE_COLOR="${COLOR_GREEN}" _LOG_STYLE_EMOJI='✅' ;;
    FAILURE) _LOG_STYLE_COLOR="${COLOR_RED}" _LOG_STYLE_EMOJI='❌' ;;
    WARNING) _LOG_STYLE_COLOR="${COLOR_YELLOW}" _LOG_STYLE_EMOJI='⚠️' ;;
    NOTE) _LOG_STYLE_COLOR="${COLOR_BLUE}" _LOG_STYLE_EMOJI='📝' ;;
    IMPORTANT) _LOG_STYLE_COLOR="${COLOR_MAGENTA}" _LOG_STYLE_EMOJI='⭐' ;;
    *) _LOG_STYLE_COLOR="${COLOR_GRAY}" _LOG_STYLE_EMOJI='📌' ;;
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
#######################################
# 把 log 的 2/3/4 参数形态归一成四个输出变量（内部函数）
#
# 参数：
#   $@ - log 收到的全部参数
#
# 全局输出：
#   _LOG_ARG_LEVEL / _LOG_ARG_CATEGORY / _LOG_ARG_MESSAGE / _LOG_ARG_TO_FILE
#
# 返回：
#   0 - 参数形态合法
#   1 - 参数个数不对（已往 stderr 打用法）
#
# 说明：结果走全局而不是 stdout —— 本文件是热路径，命令替换 $(...) 每行要 fork
#       一个子 shell（实测 500 行 4.3s → 内建后接近 0），因此内部函数一律用全局回传。
#######################################
_LOG_ARG_LEVEL=""
_LOG_ARG_CATEGORY=""
_LOG_ARG_MESSAGE=""
_LOG_ARG_TO_FILE=""

_log_parse_args() {
    # 故意写成不带 :- 的 "$1"：调用 log 时一个参数都不给，旧实现会在 set -u 下
    # 以「$1: 未绑定的变量」中止（整个调用方 shell 一起退出）。这是既有行为，
    # 重构不得顺手"修"成一条更友好的用法提示——那会改变调用方的退出码与日志。
    _LOG_ARG_LEVEL="$1"
    _LOG_ARG_CATEGORY=""
    _LOG_ARG_MESSAGE=""
    _LOG_ARG_TO_FILE="${LOG_TO_FILE}"

    case $# in
    2) _LOG_ARG_MESSAGE="$2" ;;
    3)
        _LOG_ARG_CATEGORY="$2"
        _LOG_ARG_MESSAGE="$3"
        ;;
    4)
        _LOG_ARG_CATEGORY="$2"
        _LOG_ARG_MESSAGE="$3"
        _LOG_ARG_TO_FILE="$4"
        ;;
    *)
        printf 'Usage: log LEVEL [CATEGORY] MESSAGE [TO_FILE]\n' >&2
        return 1
        ;;
    esac
    return 0
}

#######################################
# 确定行内标记用的脚本名（内部函数）
#
# 参数：
#   $@ - 调用栈的 BASH_SOURCE 快照（调用方传 "${BASH_SOURCE[@]:1}"，即跳过本文件自身）
#
# 全局输出：
#   _LOG_SCRIPT_NAME - 脚本名（去 .sh 后缀）；找不到时为 unknown
#
# 说明：行内标记取【调用方源文件名】（不是文件名主干）：一份日志里往往有多个模块在写，
#       标记只有落到具体模块才有辨识度（mods/07-git-utils.sh 与 diy-part2.sh 要分得开）。
#       不能简单取 BASH_SOURCE[1]：每多一层薄包装（log_info → log）层级就偏移一格，
#       会取到 'bash'，因此从前往后找第一个【非本文件、非 bash 自身】的层级。
#       basename 也换成内建截取：路径里没有斜杠时直接用原值，有则取最后一段。
#       结果走全局，理由同 _log_parse_args（不做命令替换）。
#######################################
_LOG_SCRIPT_NAME=""

_log_resolve_script_name() {
    local src base

    _LOG_SCRIPT_NAME="unknown"
    for src in "$@"; do
        [[ -z "${src}" ]] && continue
        base="${src##*/}"
        [[ "${base}" == "01-shell-logger.sh" ]] && continue
        [[ "${base}" == "bash" ]] && continue
        _LOG_SCRIPT_NAME="${base%.sh}"
        return 0
    done
    return 0
}

#######################################
# 构建分类标签（内部函数）
#
# 参数：
#   $1 - 分类名（可为空）
#
# 全局输出：
#   _LOG_CAT_TAG       - stderr 形态（带色带 emoji）
#   _LOG_CAT_TAG_PLAIN - 落文件形态（纯文本）
#
# 说明：stderr 保留带色带 emoji 的形态（与 scripts/build 长期使用的
#       "[✅ SUCCESS]" 子标签一致），落文件仍是去掉颜色代码的纯文本。
#######################################
_LOG_CAT_TAG=""
_LOG_CAT_TAG_PLAIN=""

_log_build_category_tag() {
    local category="$1"
    local color emoji

    _LOG_CAT_TAG=""
    _LOG_CAT_TAG_PLAIN=""
    [[ -n "${category}" ]] || return 0

    _log_style "${category}"
    color="${_LOG_STYLE_COLOR}"
    emoji="${_LOG_STYLE_EMOJI}"
    _LOG_CAT_TAG=" ${color}[${emoji} ${category}]${COLOR_RESET}"
    _LOG_CAT_TAG_PLAIN=" [${emoji} ${category}]"
    return 0
}

#######################################
# 打印一条日志（唯一实现）
#
# 参数：
#   $1 - 级别（DEBUG/INFO/WARN/ERROR 等，由 LOG_LEVEL_* 映射）
#   $2 - 消息；或 $2 分类 / $3 消息；或 $2 分类 / $3 消息 / $4 TO_FILE
#
# 返回：
#   0 - 已输出，或该级别被过滤
#   1 - 参数错误（已往 stderr 打用法）
#
# 示例：
#   log INFO "服务已启动"
#   log WARN "网络" "连接超时，正在重试..."
#   log ERROR "数据库" "连接失败" true
#######################################
log() {
    _log_parse_args "$@" || return 1

    local level="${_LOG_ARG_LEVEL}"
    local category="${_LOG_ARG_CATEGORY}"
    local message="${_LOG_ARG_MESSAGE}"
    local to_file="${_LOG_ARG_TO_FILE}"

    # 级别过滤：如果当前消息级别低于设定级别，直接返回。
    # 用内建映射而不是命令替换：$(...) 每行 fork 一个子 shell，一个 log 行旧实现要 fork 4 次
    # （两级比较各一、样式一、时间戳一），实测 500 行耗时 4.3s。改成内建后接近 0 开销。
    local level_num current_level_num
    _log_level_num "${level}"
    level_num="${_LOG_LEVEL_NUM}"
    _log_level_num "${LOG_LEVEL}"
    current_level_num="${_LOG_LEVEL_NUM}"
    [[ ${level_num} -lt ${current_level_num} ]] && return 0

    # 获取样式（同上：走内建映射，不 fork）
    local color emoji
    _log_style "${level}"
    color="${_LOG_STYLE_COLOR}"
    emoji="${_LOG_STYLE_EMOJI}"

    # 行内标记取【调用方源文件名】，规则见 _log_resolve_script_name。
    _log_resolve_script_name "${BASH_SOURCE[@]:1}"
    local script_name="${_LOG_SCRIPT_NAME}"

    # 构建分类标签：见 _log_build_category_tag。
    _log_build_category_tag "${category}"
    local cat_tag="${_LOG_CAT_TAG}"
    local cat_tag_plain="${_LOG_CAT_TAG_PLAIN}"

    # 输出到 stderr（带颜色）
    local timestamp
    # 时间戳必须带 UTC 偏移：容器/精简镜像在装 tzdata 之前 TZ 不生效（date 落回 UTC），
    # 装完才变成 +08:00。同一份日志里混有两种时钟而又不留偏移标记，首末行相减就会算出
    # 几个小时甚至更长的假耗时。带上 %z 后，任何时刻的行都能换算回绝对时间。
    # 用 printf 内建 %()T 而非 $(date)：后者每行 fork 一个进程，实测 500 行要 445ms，
    # 换成内建格式后 4ms（同一台机器），loop 里打日志的调用点差距会放大上百倍。
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S %z)T' -1

    # 【关键】消息一律用 %s 输出，绝不用 %b：
    # %b 会把消息里的反斜杠当转义序列解释 —— "\t" 变成制表符、"\c" 直接截断整行、
    # "\n" 变成换行。而 fail/run 用 %q 渲染命令行（_render_cmd），产出的正是反斜杠，
    # 于是同一条错误在终端与文件里长得不一样（旧实现的终端分支就是 %b）。
    # %s 让两端逐字节一致，也让"终端与文件同源"真正成立。
    printf '%s\n' "[${timestamp}] ${color}[${emoji} ${level}]${COLOR_RESET} [${script_name}]${cat_tag} ${message}" >&2

    # 落文件：只在【采集层没接管】时自己写。
    # 采集层生效时 fd 2 已被 tee 复制到终端与文件，再写一次会让每行重复两次；
    # 且文件那份由 tee 侧的 sed 剥掉 ANSI，比这里手写 plain 形态更准（子进程输出也一并覆盖）。
    if [[ "${to_file}" == "true" ]] && [[ -z "${_LOG_CAPTURE_ACTIVE:-}" ]] && _log_file_ready; then
        printf '%s\n' "[${timestamp}] [${emoji} ${level}] [${script_name}]${cat_tag_plain} ${message}" >>"${LOG_FILE_PATH}"
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
