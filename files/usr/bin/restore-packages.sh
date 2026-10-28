#!/bin/bash
#===============================================================================
# 软件包恢复脚本（两阶段 + 结构化失败记录）
# 功能：从备份文件批量恢复用户安装的软件包。
#       首次是全量 best-effort 安装；若有失败包则重启一次，
#       重启后只重试上次失败的包；二次仍失败则不再重启，转为 LuCI 登录提示。
# 用法：restore-packages.sh [选项] [备份文件路径]
#
# 选项：
#   -h, --help      显示帮助信息并退出
#   -d, --debug     启用调试日志，记录所有 apk 命令详细输出
#   -q, --quiet     静默模式，仅记录警告和错误
#   -c, --console   将 INFO 及以上级别消息同时输出到控制台
#   -f, --force     忽略状态机（当作首次全量恢复），但仍会写状态与失败记录
#
# 参数：
#   备份文件路径   要恢复的包列表文件，默认为 /etc/backup/installed_packages.txt
#
# 环境变量：
#   LOG_LEVEL             日志级别 (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR) [默认: 1]
#   LOG_TO_CONSOLE        是否输出到终端 (1=是, 0=否) [默认: 0]
#   MAX_LOG_FILES         保留的历史日志文件数量 [默认: 5]
#   RESTORE_STATE_FILE    尝试状态文件 [默认: /etc/backup/restore_pkg.state]
#   RESTORE_FAILURE_FILE  失败记录 NDJSON [默认: /etc/backup/restore_pkg_failures.ndjson]
#   REBOOT_CMD            重启命令 [默认: reboot -f]
#
# 返回值：
#   0   成功（备份文件不存在、全部安装成功、或处于「已二次失败」的终态）
#   1   发生错误（网络不可达、索引不可用、需要人工介入等）
#
# 状态机（详见仓库 .tmp-design/DESIGN.md）：
#   attempt=0                 → 全量安装
#   第一次有失败（attempt=1） → 写失败记录后重启
#   attempt=1                 → 只重试失败记录里的包
#   二次仍有失败（attempt=2） → 写失败记录，不重启，退出并等 LuCI 提示
#   attempt=2 且失败记录还在  → 直接退出，防止重启循环
#
# 说明：
#   该脚本专为 OpenWrt/ImmortalWrt 环境设计，使用 apk 包管理器。
#   恢复过程仅处理标记为 overlay 的用户安装包，跳过固件自带的 ROM 包。
#   若网络不通，会自动修改 DNS 和临时放行防火墙以尝试连接软件源，
#   脚本退出时（无论成功或失败）均会恢复原始配置。
#   失败记录为扁平 NDJSON（每行一个对象），不依赖 jq。
#
# 作者：Shuery-Shuai
# 日期：2026-10-28
# 版本：2.0.0
#===============================================================================

# 严格模式：使用未定义变量、管道命令失败均会导致脚本退出
set -euo pipefail

# 必须使用 Bash 运行
if [ -z "${BASH_VERSION:-}" ]; then
    echo "此脚本需要 bash 运行" >&2
    exit 1
fi

#######################################
# 全局常量与可配置变量
#######################################

# 日志级别定义（只读）
readonly LOG_DEBUG=0 LOG_INFO=1 LOG_WARN=2 LOG_ERROR=3

# 失败记录 schema 版本
readonly FAILURE_SCHEMA="openwrt-apk-failure/1"

# 可通过环境变量覆盖默认配置
LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}
LOG_TO_CONSOLE=${LOG_TO_CONSOLE:-0}
MAX_LOG_FILES=${MAX_LOG_FILES:-5}
LOCKFILE="${LOCKFILE:-/var/lock/restore-packages.lock}"

# 默认备份文件路径
readonly DEFAULT_BACKUP_FILE="/etc/backup/installed_packages.txt"

# 尝试状态文件（overlay，重启后保留）
RESTORE_STATE_FILE="${RESTORE_STATE_FILE:-/etc/backup/restore_pkg.state}"

# 失败记录（扁平 NDJSON，overlay，重启后保留）
RESTORE_FAILURE_FILE="${RESTORE_FAILURE_FILE:-/etc/backup/restore_pkg_failures.ndjson}"

# 重启命令（测试时可用环境变量替换，避免真的重启）
REBOOT_CMD="${REBOOT_CMD:-reboot -f}"

# ================================================================
# 全局状态变量（必须为全局，因为 trap 函数中需要访问）
# ================================================================
backup_resolv_flag=0 # 是否已修改 DNS 配置（0=未修改, 1=已修改）
firewall_type=""     # 临时修改的防火墙类型（iptables/nftables/空）
log_file=""          # 日志文件路径

# ================================================================
# 命令行选项变量
# ================================================================
opt_backup_file=""
opt_debug=0
opt_quiet=0
opt_console=0
opt_force=0

# ================================================================
# 可用网络检测工具（脚本运行时自动探测）
# ================================================================
NET_TOOL=""
NET_TOOL_OPTS=()

#===============================================================================
# 函数：show_help
#===============================================================================
show_help() {
    cat <<EOF
软件包恢复脚本 v2.0.0

用法: $(basename "$0") [选项] [备份文件路径]

选项:
  -h, --help      显示此帮助信息并退出
  -d, --debug     启用调试日志，记录所有 apk 命令详细输出
  -q, --quiet     静默模式，仅记录警告和错误
  -c, --console   将 INFO 及以上消息同时输出到控制台
  -f, --force     忽略两阶段状态机，强制按首次全量恢复执行

参数:
  备份文件路径   要恢复的包列表文件，默认为:
                 $DEFAULT_BACKUP_FILE

行为说明:
  第一次运行：全量 best-effort 安装，有失败包则写入失败记录并重启。
  重启后    ：只重试上次失败的包。
  二次仍失败：不再重启，保留失败记录，登录 LuCI 时弹窗提示。

相关文件:
  状态文件   $RESTORE_STATE_FILE
  失败记录   $RESTORE_FAILURE_FILE

环境变量:
  LOG_LEVEL, LOG_TO_CONSOLE, MAX_LOG_FILES,
  RESTORE_STATE_FILE, RESTORE_FAILURE_FILE, REBOOT_CMD
EOF
}

#===============================================================================
# 函数：parse_args
#===============================================================================
parse_args() {
    log_header "$log_file" "解析命令行参数" "原始参数: $*"
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            show_help
            exit 0
            ;;
        -d | --debug)
            opt_debug=1
            shift
            ;;
        -q | --quiet)
            opt_quiet=1
            shift
            ;;
        -c | --console)
            opt_console=1
            shift
            ;;
        -f | --force)
            opt_force=1
            shift
            ;;
        --)
            shift
            opt_backup_file="${1:-}"
            break
            ;;
        -*)
            echo "未知选项: $1" >&2
            echo "使用 -h 或 --help 查看帮助" >&2
            exit 1
            ;;
        *)
            opt_backup_file="$1"
            shift
            ;;
        esac
    done
    opt_backup_file="${opt_backup_file:-$DEFAULT_BACKUP_FILE}"
    log_header "$log_file" "命令行参数解析完成" "备份文件: $opt_backup_file, 调试: $opt_debug, 静默: $opt_quiet, 强制: $opt_force"
}

#===============================================================================
# 函数：apply_log_options
#===============================================================================
apply_log_options() {
    log_header "$log_file" "应用日志配置" "调试: $opt_debug, 静默: $opt_quiet, 控制台输出: $opt_console"
    [ "$opt_debug" -eq 1 ] && LOG_LEVEL=$LOG_DEBUG
    [ "$opt_quiet" -eq 1 ] && LOG_LEVEL=$LOG_WARN
    [ "$opt_console" -eq 1 ] && LOG_TO_CONSOLE=1
    # 上面的条件在「不成立」时返回非 0，配合 set -e 会直接终止脚本。
    # 这里显式成功，保证任意选项组合下都不会半途退出。
    return 0
}

#===============================================================================
# 函数：detect_net_tool
#===============================================================================
detect_net_tool() {
    log_header "$log_file" "探测可用的网络检测工具"
    if command -v curl >/dev/null 2>&1; then
        NET_TOOL="curl"
        NET_TOOL_OPTS=(--connect-timeout 5 -kIs)
    elif command -v wget >/dev/null 2>&1; then
        NET_TOOL="wget"
        NET_TOOL_OPTS=(--timeout=5 --no-check-certificate -q --spider)
    elif command -v ping >/dev/null 2>&1; then
        NET_TOOL="ping"
        NET_TOOL_OPTS=(-c 1 -W 5)
    else
        NET_TOOL=""
    fi
    log_header "$log_file" "网络检测工具探测结果" "使用工具: ${NET_TOOL:-无}"
}

#===============================================================================
# 状态文件读写（扁平 key=value，便于无 jq 解析）
#===============================================================================

#-----------------------------------------------------------------------
# 函数：state_get
# 描述：从状态文件读取一个键的值
# 参数：$1 键名  $2 默认值（可选）
# 返回：stdout 输出值
#-----------------------------------------------------------------------
state_get() {
    local key="$1"
    local default="${2:-}"
    local value=""

    if [ -f "$RESTORE_STATE_FILE" ]; then
        value=$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' \
            "$RESTORE_STATE_FILE" 2>/dev/null || true)
    fi
    printf '%s' "${value:-$default}"
}

#-----------------------------------------------------------------------
# 函数：state_write
# 描述：原子写入状态文件
# 参数：$1 attempt 值  $2 stage 值
#-----------------------------------------------------------------------
state_write() {
    local attempt="$1"
    local stage="$2"
    local dir
    dir=$(dirname "$RESTORE_STATE_FILE")

    mkdir -p "$dir" 2>/dev/null || true

    if {
        printf 'attempt=%s\n' "$attempt"
        printf 'stage=%s\n' "$stage"
        printf 'last_run=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } >"${RESTORE_STATE_FILE}.tmp" 2>/dev/null; then
        mv -f "${RESTORE_STATE_FILE}.tmp" "$RESTORE_STATE_FILE" 2>/dev/null ||
            log_warn "$log_file" "无法写入状态文件: $RESTORE_STATE_FILE"
    else
        log_warn "$log_file" "无法写入状态文件: $RESTORE_STATE_FILE"
        rm -f "${RESTORE_STATE_FILE}.tmp" 2>/dev/null || true
    fi
}

#-----------------------------------------------------------------------
# 函数：state_clear
# 描述：删除状态文件与失败记录（恢复成功后调用）
#-----------------------------------------------------------------------
state_clear() {
    rm -f "$RESTORE_STATE_FILE" 2>/dev/null || true
    rm -f "$RESTORE_FAILURE_FILE" 2>/dev/null || true
    log_info "$log_file" "已清理状态文件与失败记录"
}

#-----------------------------------------------------------------------
# 函数：failure_count
# 描述：统计失败记录行数（空文件返回 0）
# 返回：stdout 输出行数
#-----------------------------------------------------------------------
failure_count() {
    if [ -f "$RESTORE_FAILURE_FILE" ] && [ -s "$RESTORE_FAILURE_FILE" ]; then
        wc -l <"$RESTORE_FAILURE_FILE" 2>/dev/null | tr -d ' ' || echo 0
    else
        echo 0
    fi
}

#-----------------------------------------------------------------------
# 函数：failure_packages
# 描述：从失败记录 NDJSON 中提取需要重试的包名（每行一个）
#       只依赖 sed/awk，不依赖 jq
# 参数：$1 输出文件路径
# 返回：0 成功；1 没有任何可用包名
#-----------------------------------------------------------------------
failure_packages() {
    local out_file="$1"

    : >"$out_file"
    if [ ! -s "$RESTORE_FAILURE_FILE" ]; then
        return 1
    fi

    # "package":"name" —— 取本轮实际尝试过的包，去重但保持顺序
    sed -n 's/.*"package":"\([^"]*\)".*/\1/p' "$RESTORE_FAILURE_FILE" |
        awk 'NF && !seen[$0]++' >"$out_file" 2>/dev/null || true

    [ -s "$out_file" ]
}

#===============================================================================
# JSON 与 NDJSON 写入
#===============================================================================

#-----------------------------------------------------------------------
# 函数：json_escape
# 描述：把任意字符串压成单行、合法 JSON 的字符串内容（不含外层引号）
#       顺序很重要：先转反斜杠，再转双引号，最后处理控制字符
# 参数：$1 原始字符串
# 返回：stdout 输出转义后的内容
#-----------------------------------------------------------------------
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037' 2>/dev/null || printf '%s' "$s")
    printf '%s' "$s"
}

#-----------------------------------------------------------------------
# 函数：get_apk_arch
# 描述：获取当前设备架构，用于失败记录
# 返回：stdout 输出架构字符串
#-----------------------------------------------------------------------
get_apk_arch() {
    local arch=""

    if command -v apk >/dev/null 2>&1; then
        arch=$(apk --print-arch 2>/dev/null | head -n 1 || true)
    fi
    if [ -z "$arch" ] && [ -f /etc/apk/arch ]; then
        arch=$(head -n 1 /etc/apk/arch 2>/dev/null || true)
    fi
    printf '%s' "${arch:-unknown}"
}

#-----------------------------------------------------------------------
# 函数：json_string_array
# 描述：把若干字符串编码成紧凑 JSON 数组（逗号后无空格，便于 tr 提取）
# 参数：$@ 字符串列表
# 返回：stdout 输出形如 ["a","b"] 的内容
#-----------------------------------------------------------------------
json_string_array() {
    local first=1
    local item escaped

    printf '['
    for item in "$@"; do
        [ -n "$item" ] || continue
        escaped=$(json_escape "$item")
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '"%s"' "$escaped"
    done
    printf ']'
}

#-----------------------------------------------------------------------
# 函数：record_failure
# 描述：向 NDJSON 追加一条失败事件（扁平，每行一个对象）
# 参数：
#   $1 stage         fetch|resolve
#   $2 error_class   fetch_error|package_not_found
#   $3 package       失败的包名
#   $4 message       错误摘要（可以是多行，会被压成单行）
#   $5 attempt       本轮 attempt
#   $6..             额外 "key=value" 形式的字段，其中 value 若以 "@" 开头
#                    则按 JSON 数组编码（逗号分隔的列表）
# 返回：0 成功，1 写入失败
#-----------------------------------------------------------------------
#-----------------------------------------------------------------------
# 函数：_failure_base_line
# 描述：拼出一条失败事件的固定字段部分（不含结尾的 "}"，也不含额外字段）
# 返回：stdout 输出 JSON 对象的前半段
#-----------------------------------------------------------------------
_failure_base_line() {
    local stage="$1"
    local error_class="$2"
    local pkg="$3"
    local message="$4"
    local attempt="$5"

    printf '{"schema":"%s","ts":"%s","host":"%s","arch":"%s","stage":"%s","error_class":"%s","package":"%s","message":"%s","attempt":%s' \
        "$FAILURE_SCHEMA" \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
        "$(json_escape "$(get_apk_arch)")" \
        "$stage" \
        "$error_class" \
        "$(json_escape "$pkg")" \
        "$(json_escape "$message")" \
        "$attempt"
}

#-----------------------------------------------------------------------
# 函数：_failure_extra_field
# 描述：把一个 "key=value" 额外字段编码成 JSON 片段（含前导逗号）
# 参数：$1 键名  $2 值；值以 "@" 开头时按逗号分隔的字符串数组编码
# 返回：stdout 输出形如 ,"key":value 的片段
#-----------------------------------------------------------------------
_failure_extra_field() {
    local key="$1"
    local value="$2"
    local fragment=""

    if [ "${value#@}" != "$value" ]; then
        # "@a,b,c" → 字符串数组
        local raw="${value#@}"
        local -a arr_items=()
        if [ -n "$raw" ]; then
            local IFS_SAVE="$IFS"
            IFS=','
            # shellcheck disable=SC2206
            arr_items=($raw)
            IFS="$IFS_SAVE"
        fi
        fragment=",\"$key\":$(json_string_array "${arr_items[@]:-}")"
    elif [ "$key" = "exit_code" ] && [[ "$value" =~ ^-?[0-9]+$ ]]; then
        # 数字字段不要加引号
        fragment=",\"$key\":$value"
    else
        fragment=",\"$key\":\"$(json_escape "$value")\""
    fi

    printf '%s' "$fragment"
}

#-----------------------------------------------------------------------
# 函数：record_failure
# 描述：向 NDJSON 追加一条失败事件（扁平，每行一个对象）
# 参数：
#   $1 stage         fetch|resolve
#   $2 error_class   fetch_error|package_not_found
#   $3 package       失败的包名
#   $4 message       错误摘要（可以是多行，会被压成单行）
#   $5 attempt       本轮 attempt
#   $6..             额外 "key=value" 形式的字段，其中 value 若以 "@" 开头
#                    则按 JSON 数组编码（逗号分隔的列表）
# 返回：0 成功，1 写入失败
#-----------------------------------------------------------------------
record_failure() {
    local stage="$1"
    local error_class="$2"
    local pkg="$3"
    local message="$4"
    local attempt="$5"
    shift 5

    local dir
    dir=$(dirname "$RESTORE_FAILURE_FILE")
    mkdir -p "$dir" 2>/dev/null || true

    local line
    line=$(_failure_base_line "$stage" "$error_class" "$pkg" "$message" "$attempt")

    local field
    for field in "$@"; do
        line="$line$(_failure_extra_field "${field%%=*}" "${field#*=}")"
    done
    line="$line}"

    if printf '%s\n' "$line" >>"$RESTORE_FAILURE_FILE" 2>/dev/null; then
        log_debug "$log_file" "已记录失败事件: $line"
        return 0
    fi
    log_error "$log_file" "无法写入失败记录: $RESTORE_FAILURE_FILE"
    return 1
}

#===============================================================================
# 日志系统
#===============================================================================

log_write() {
    local level="$1"
    local log_file="$2"
    local message="$3"
    local timestamp
    timestamp=$(date '+%F %T')
    local level_str

    case "$level" in
    "$LOG_DEBUG") level_str="DEBUG" ;;
    "$LOG_INFO") level_str="INFO " ;;
    "$LOG_WARN") level_str="WARN " ;;
    "$LOG_ERROR") level_str="ERROR" ;;
    *) level_str="UNKN " ;;
    esac

    local line="[$timestamp] [$level_str] $message"
    local current_level="${LOG_LEVEL:-$LOG_INFO}"

    if [ "$level" -lt "$current_level" ]; then
        return 0
    fi

    echo "$line" >>"$log_file"

    if [ "${LOG_TO_CONSOLE:-0}" -eq 1 ]; then
        if [ "$level" -ge "$LOG_WARN" ]; then
            echo "$line" >&2
        else
            echo "$line"
        fi
    fi
}

log_debug() {
    log_write "$LOG_DEBUG" "$1" "$2"
}

log_info() {
    log_write "$LOG_INFO" "$1" "$2"
}

log_warn() {
    log_write "$LOG_WARN" "$1" "$2"
}

log_error() {
    log_write "$LOG_ERROR" "$1" "$2"
}

log_header() {
    local log_file="${1:-}"
    local title="${2:-}"
    local info="${3:-}"

    [ "${LOG_LEVEL:-$LOG_INFO}" -gt "$LOG_INFO" ] && return 0

    local timestamp
    timestamp=$(date '+%F %T')
    local header_line="===== $timestamp - $title ====="
    local info_line=""
    [ -n "$info" ] && info_line="信息: $info"

    {
        echo "$header_line"
        [ -n "$info_line" ] && echo "$info_line"
        echo
    } >>"$log_file"

    if [ "${LOG_TO_CONSOLE:-0}" -eq 1 ]; then
        echo "$header_line"
        [ -n "$info_line" ] && echo "$info_line"
        echo
    fi
}

log_exit_summary() {
    local log_file="$1"
    local exit_code="$2"
    local start_time="$3"
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    if [ "$exit_code" -eq 0 ]; then
        log_info "$log_file" "脚本成功完成，总耗时 ${elapsed} 秒"
    else
        log_error "$log_file" "脚本异常退出 (退出码 $exit_code)，总耗时 ${elapsed} 秒"
    fi
}

#===============================================================================
# 主流程
#
# 结构：main 只做「接线」——按顺序调用各阶段函数，并把阶段返回码翻译成进程退出码。
# 每个阶段函数只做一件事，失败原因由它自己记录（日志格式不变），main 不重复判定。
#
# 阶段返回码约定（阶段函数 → main）：
#   0   该阶段完成，继续下一阶段
#   10  应当以「成功」结束本轮（终态保护 / 无包可装），阶段内已写好退出摘要
#   1   该阶段判定为失败，main 直接以 1 结束（阶段内已写好摘要）
# 之所以用非 0/1 的 10 表示「成功结束」，是因为 0 已被「继续」占用，
# 而 1 必须唯一对应失败——否则 main 无法区分「继续」与「成功收尾」。
#===============================================================================

# 本轮的运行上下文。声明为全局而非 main 的 local：阶段函数需要读写它们，
# 而 main 拆成多个函数后 local 变量无法跨函数边界传递。
# 名字统一带 _rp_ 前缀，避免与已有全局（backup_resolv_flag / firewall_type / log_file）混淆。
_rp_start_time=0   # 脚本启动时间（epoch 秒），用于耗时统计
_rp_backup_file="" # 备份包列表文件路径
_rp_test_url=""    # 用于连通性检测与失败记录的软件源 URL
_rp_work_list=""   # 本轮待安装包清单（临时文件）
_rp_attempt_prev=0 # 进入本轮前的 attempt 值
_rp_is_retry=0     # 本轮是否为「只重试失败包」
_rp_failed_count=0 # 本轮安装失败的包数

#-----------------------------------------------------------------------
# 函数：_acquire_lock
# 描述：用 flock 保证同一时刻只有一个恢复实例在跑（fd 9 随进程存活）
# 返回：0 拿到锁；1 已有实例在运行（已记录错误）
#-----------------------------------------------------------------------
_acquire_lock() {
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        log_error "$log_file" "另一个恢复实例正在运行，退出"
        return 1
    fi
    return 0
}

#-----------------------------------------------------------------------
# 函数：_resolve_run_plan
# 描述：第零阶段——读取两阶段状态，决定本轮要装哪些包（写入 _rp_work_list）
# 返回：0 继续；10 以成功结束本轮；1 无（本阶段不产生失败）
#
# 终态保护与「无包可装」都在这里收口：它们都不是故障，而是「本轮无事可做」，
# 因此统一返回 10 并以退出码 0 结束，与既有行为一致。
#-----------------------------------------------------------------------
_resolve_run_plan() {
    log_header "$log_file" "状态判定阶段开始"

    _rp_attempt_prev=$(state_get attempt 0)
    [[ "$_rp_attempt_prev" =~ ^[0-9]+$ ]] || _rp_attempt_prev=0

    if [ "$opt_force" -eq 1 ]; then
        log_info "$log_file" "启用了 --force，忽略既有状态，按首次全量恢复执行"
        _rp_attempt_prev=0
        rm -f "$RESTORE_FAILURE_FILE" 2>/dev/null || true
    fi

    # 终态保护：已二次失败且失败记录仍在 → 不再安装、不再重启
    if [ "$_rp_attempt_prev" -ge 2 ] && [ "$(failure_count)" -gt 0 ]; then
        log_warn "$log_file" "已完成两次尝试且仍有失败包，进入终态保护：不安装、不重启，等待 LuCI 提示"
        log_info "$log_file" "如需重试，请删除 $RESTORE_STATE_FILE 与 $RESTORE_FAILURE_FILE 后手动执行，或使用 --force"
        log_exit_summary "$log_file" 0 "$_rp_start_time"
        return 10
    fi

    # 决定本轮的安装清单
    _rp_work_list="/tmp/restore-pkg-work.$$"
    _rp_is_retry=0

    if [ "$_rp_attempt_prev" -eq 1 ] && failure_packages "$_rp_work_list"; then
        _rp_is_retry=1
        log_info "$log_file" "检测到上次尝试失败，第二轮只重试失败包：$(wc -l <"$_rp_work_list" | tr -d ' ') 个"
    else
        # 首次执行；或第二轮但失败记录缺失/为空 → 回退全量
        if [ "$_rp_attempt_prev" -eq 1 ]; then
            log_warn "$log_file" "处于第二轮但失败记录缺失或为空，回退到全量列表"
        fi
        if [ ! -f "$_rp_backup_file" ]; then
            log_info "$log_file" "备份文件不存在: $_rp_backup_file，视为已恢复或无需恢复"
            rm -f "$_rp_work_list"
            log_exit_summary "$log_file" 0 "$_rp_start_time"
            return 10
        fi
        if ! extract_user_packages "$_rp_backup_file" "$_rp_work_list" "$log_file"; then
            log_info "$log_file" "无 overlay 用户包需要恢复"
            rm -f "$_rp_work_list"
            log_exit_summary "$log_file" 0 "$_rp_start_time"
            return 10
        fi
    fi

    if [ ! -s "$_rp_work_list" ]; then
        log_info "$log_file" "本轮没有需要安装的包"
        rm -f "$_rp_work_list"
        log_exit_summary "$log_file" 0 "$_rp_start_time"
        return 10
    fi

    return 0
}

#-----------------------------------------------------------------------
# 函数：_ensure_network
# 描述：第一阶段——确保软件源可达；首次失败则临时改 DNS 与放行防火墙后重试一次
# 返回：0 可达；1 不可达（已记录错误与退出摘要，且本轮不推进状态）
# 副作用：置 backup_resolv_flag / firewall_type 供 EXIT trap 复原
#-----------------------------------------------------------------------
_ensure_network() {
    log_header "$log_file" "网络连通性检测阶段开始"
    if check_network "$_rp_test_url" "$log_file"; then
        return 0
    fi

    log_info "$log_file" "第一次网络检测失败，尝试修改 DNS 和防火墙"
    backup_resolv_flag=1
    backup_resolv_config "$log_file"

    firewall_type=$(detect_firewall_type)
    log_info "$log_file" "检测到防火墙类型: ${firewall_type:-无}"
    if [ -n "$firewall_type" ]; then
        set_temp_firewall_rules "$firewall_type" "$log_file"
    fi

    if ! check_network "$_rp_test_url" "$log_file"; then
        log_error "$log_file" "无法连接软件源，恢复中止（状态未推进，下次启动会重来）"
        rm -f "$_rp_work_list"
        log_exit_summary "$log_file" 1 "$_rp_start_time"
        return 1
    fi
    return 0
}

#-----------------------------------------------------------------------
# 函数：_refresh_package_index
# 描述：第二阶段——更新软件源索引；索引不可用属于 fetch 类问题，记录但继续
# 返回：恒为 0（逐包安装时仍可能成功：本地缓存 / 部分源可用）
#-----------------------------------------------------------------------
_refresh_package_index() {
    local update_rc=0

    log_header "$log_file" "软件源更新阶段开始"
    update_package_lists "$log_file" || update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
        log_warn "$log_file" "软件源索引更新有问题（退出码 $update_rc），继续尝试逐包安装"
        record_failure "fetch" "fetch_error" "__index__" \
            "apk update failed with exit code $update_rc" \
            "$((_rp_attempt_prev + 1))" \
            "tool=apk" "exit_code=$update_rc" "target=$_rp_test_url" \
            "related_warning=$(extract_last_warning)" || true
    fi
    return 0
}

#-----------------------------------------------------------------------
# 函数：_install_phase
# 描述：第三阶段——逐包 best-effort 安装，结果写入 _rp_failed_count
# 返回：恒为 0（失败包数量是数据而不是本阶段的成败）
#-----------------------------------------------------------------------
_install_phase() {
    log_header "$log_file" "软件包安装阶段开始"

    # 失败计数通过全局变量回传，不用 $(...) 捕获：
    # 控制台模式下日志函数会写 stdout，用命令替换取返回值会被日志污染。
    INSTALL_FAILED_COUNT=0
    install_packages_one_by_one "$_rp_work_list" "$((_rp_attempt_prev + 1))" "$log_file" || true
    _rp_failed_count="${INSTALL_FAILED_COUNT:-0}"
    [[ "$_rp_failed_count" =~ ^[0-9]+$ ]] || _rp_failed_count=0

    rm -f "$_rp_work_list"
    log_info "$log_file" "本轮安装完成，失败包数量: $_rp_failed_count"
    return 0
}

#-----------------------------------------------------------------------
# 函数：_finalize_all_success
# 描述：全部成功的收尾：清状态；首次全量成功则删备份并重启一次
# 返回：main 的退出码（重启失败时为 1，其余 0）
#-----------------------------------------------------------------------
_finalize_all_success() {
    state_clear

    if [ "$_rp_attempt_prev" -eq 0 ] && [ "$_rp_is_retry" -eq 0 ]; then
        # 首次全量成功：保持既有行为，删除备份文件并重启一次
        rm -f "$_rp_backup_file" 2>/dev/null || true
        log_info "$log_file" "已删除备份文件: $_rp_backup_file"
        do_reboot "$_rp_start_time" "$log_file"
        return $?
    fi

    # 第二轮成功（或首轮无失败）：按需求「结束」，不再重启
    log_header "$log_file" "恢复完成" "所有软件包验证成功"
    log_exit_summary "$log_file" 0 "$_rp_start_time"
    return 0
}

#-----------------------------------------------------------------------
# 函数：_finalize_with_failures
# 描述：有失败时的收尾：推进 attempt；第一次失败重启，第二次失败不再重启
# 返回：main 的退出码
#-----------------------------------------------------------------------
_finalize_with_failures() {
    local attempt_now=$((_rp_attempt_prev + 1))
    if [ "$attempt_now" -gt 2 ]; then
        attempt_now=2
    fi
    state_write "$attempt_now" "failed"

    if [ "$attempt_now" -eq 1 ]; then
        # 第一次失败 → 重启，重启后只重试失败包
        log_warn "$log_file" "第一次尝试仍有 $_rp_failed_count 个包失败，记录后将重启重试"
        do_reboot "$_rp_start_time" "$log_file"
        return $?
    fi

    # attempt=2：二次失败，不再重启
    log_error "$log_file" "第二次尝试后仍有 $_rp_failed_count 个包失败，不再重启，保留失败记录等待 LuCI 提示"
    log_info "$log_file" "失败明细见: $RESTORE_FAILURE_FILE"
    log_exit_summary "$log_file" 1 "$_rp_start_time"
    return 1
}

#-----------------------------------------------------------------------
# 函数：_finalize_run
# 描述：第四阶段——按决策表决定重启与状态推进
# 返回：main 的退出码
#-----------------------------------------------------------------------
_finalize_run() {
    log_header "$log_file" "结果处理阶段开始"
    if [ "$_rp_failed_count" -eq 0 ]; then
        _finalize_all_success
        return $?
    fi
    _finalize_with_failures
    return $?
}

#-----------------------------------------------------------------------
# 函数：main
# 描述：入口——初始化、拿锁、按阶段推进，把阶段返回码翻译成进程退出码
# 返回：0 成功（含「无事可做」的终态）；1 失败
#-----------------------------------------------------------------------
main() {
    local phase_rc=0

    log_file=$(init_log_file)

    parse_args "$@"
    apply_log_options
    detect_net_tool

    _acquire_lock || exit 1

    _rp_start_time=$(date +%s)
    _rp_backup_file="$opt_backup_file"
    _rp_test_url=$(get_apk_repo_url)

    trap 'restore_original_config "$backup_resolv_flag" "$firewall_type" "$log_file"' EXIT

    log_header "$log_file" "脚本启动" "备份文件=$_rp_backup_file"
    log_info "$log_file" "日志级别: $LOG_LEVEL, 控制台输出: $LOG_TO_CONSOLE"
    [ -n "$NET_TOOL" ] && log_info "$log_file" "网络检测工具: $NET_TOOL"

    # 第零阶段：状态判定（决定装哪些包）。10 = 本轮无事可做，按成功结束。
    _resolve_run_plan || phase_rc=$?
    if [ "$phase_rc" -eq 10 ]; then
        return 0
    fi

    local pkg_total
    pkg_total=$(wc -l <"$_rp_work_list" | tr -d ' ')
    log_info "$log_file" "本轮待处理包数量: $pkg_total"

    # 第一阶段：网络可达（不可达则中止，状态不推进）
    _ensure_network || return 1

    # 第二阶段：软件源索引（失败只记录，不中止）
    _refresh_package_index

    # 第三阶段：逐包安装
    _install_phase

    # 第四阶段：重启与状态决策
    _finalize_run
    return $?
}

#-----------------------------------------------------------------------
# 函数：do_reboot
# 描述：同步磁盘并执行重启（重启命令可通过 REBOOT_CMD 覆盖，便于测试）
# 参数：$1 脚本启动时间  $2 日志文件
# 返回：通常不返回（设备重启）；重启命令失败时返回 1
#-----------------------------------------------------------------------
do_reboot() {
    local script_start_time="$1"
    local log_file="$2"

    log_header "$log_file" "准备重启" "系统将在 10 秒后重启以完成剩余软件包恢复"
    log_exit_summary "$log_file" 0 "$script_start_time"
    sync
    sleep 10

    log_info "$log_file" "执行重启命令: $REBOOT_CMD"
    # shellcheck disable=SC2086
    if $REBOOT_CMD >>"$log_file" 2>&1; then
        return 0
    fi
    log_error "$log_file" "重启命令执行失败: $REBOOT_CMD"
    return 1
}

#-----------------------------------------------------------------------
# 函数：extract_last_warning
# 描述：从最近一次 apk 输出中取最后一条 WARNING 行（作为 related_warning）
#       这里不依赖任何外部临时文件的持久性，读不到就返回空串
# 返回：stdout 输出单行字符串
#-----------------------------------------------------------------------
extract_last_warning() {
    local src="${APK_LAST_OUTPUT:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        sed -n 's/^WARNING: *//p' "$src" 2>/dev/null | tail -n 1 || true
    fi
}

#===============================================================================
# 软件包列表处理
#===============================================================================

#-----------------------------------------------------------------------
# 函数：extract_user_packages
# 描述：从 installed_packages.txt 提取 overlay 用户包名
#       真实格式为 pkg-name<TAB>{rom,overlay,unknown}
#       注意：不能用 grep '\toverlay'，GNU grep 会把 \t 当字面量 t
# 参数：$1 备份文件  $2 输出文件  $3 日志文件
# 返回：0 提取到包；1 没有可用的包
#-----------------------------------------------------------------------
extract_user_packages() {
    local backup_file="$1"
    local out_file="$2"
    local log_file="$3"

    : >"$out_file"

    # 真实格式（见 sysupgrade）：pkg-name<TAB>{rom,overlay,unknown}，即 2 列。
    # 某些版本/工具的产物会在中间多一列版本号（name<TAB>ver<TAB>state），
    # 因此这里不写死列号，而是看「最后一列是不是状态标记」：
    #   · 最后一列 == overlay → 收下第 1 列
    #   · 只有 1 列（纯包名） → 交给下面的退化分支统一处理
    # 注意：不能用 grep '\toverlay'，GNU grep 会把 \t 当字面量 t 而匹配不到。
    awk -F'\t' 'NF >= 2 && $NF == "overlay" && $1 != "" { print $1 }' \
        "$backup_file" >>"$out_file" 2>/dev/null || true

    # 兼容退化格式：没有 rom/overlay 标记列时，把所有单列包名都收下
    if [ ! -s "$out_file" ]; then
        if awk -F'\t' 'NF == 1 && $1 != "" && $1 !~ /^#/ { found = 1 } END { exit !found }' \
            "$backup_file" 2>/dev/null; then
            log_warn "$log_file" "备份文件缺少 rom/overlay 标记列，按纯包名列表处理"
            awk -F'\t' 'NF == 1 && $1 != "" && $1 !~ /^#/ { print $1 }' \
                "$backup_file" >>"$out_file" 2>/dev/null || true
        fi
    fi

    # 去掉注释与空行，去重保序
    if [ -s "$out_file" ]; then
        awk 'NF && $0 !~ /^#/ && !seen[$0]++' "$out_file" >"${out_file}.dedup" 2>/dev/null || true
        if [ -s "${out_file}.dedup" ]; then
            mv -f "${out_file}.dedup" "$out_file"
        else
            rm -f "${out_file}.dedup"
        fi
    fi

    [ -s "$out_file" ]
}

#===============================================================================
# 网络与安装
#===============================================================================

#-----------------------------------------------------------------------
# 函数：get_apk_repo_url
# 描述：从系统 apk 配置中获取第一个可用的软件源 URL
#-----------------------------------------------------------------------
get_apk_repo_url() {
    local url=""
    local files=()

    [ -f /etc/apk/repositories ] && files+=("/etc/apk/repositories")
    if [ -d /etc/apk/repositories.d ]; then
        while IFS= read -r f; do
            files+=("$f")
        done < <(find /etc/apk/repositories.d -name '*.list' -type f 2>/dev/null)
    fi

    local f
    for f in "${files[@]}"; do
        url=$(awk '/^https?:\/\// {print; exit}' "$f" 2>/dev/null || true)
        [ -n "$url" ] && break
    done

    echo "${url:-https://downloads.immortalwrt.org}"
}

#-----------------------------------------------------------------------
# 函数：init_log_file
# 描述：初始化日志文件路径并做轮转
#-----------------------------------------------------------------------
init_log_file() {
    local log_dir="/var/log"
    local log_name
    log_name="package-restore-$(date +'%Y%m%d%H%M%S').log"
    local log_path

    echo "初始化日志文件: $log_name" >&2
    if [ -d "$log_dir" ] && [ -w "$log_dir" ]; then
        log_path="$log_dir/$log_name"

        local pattern="package-restore-*.log"
        if command -v stat >/dev/null 2>&1; then
            find "$log_dir" -maxdepth 1 -name "$pattern" -type f \
                -exec stat -c '%Y %n' {} \; 2>/dev/null |
                sort -rn |
                tail -n +$((MAX_LOG_FILES + 1)) |
                cut -d' ' -f2- |
                xargs rm -f -- 2>/dev/null || true
        else
            local files_to_delete
            # shellcheck disable=SC2012
            files_to_delete=$(ls -t "$log_dir"/"$pattern" 2>/dev/null |
                tail -n +$((MAX_LOG_FILES + 1)) || true)
            if [ -n "$files_to_delete" ]; then
                echo "$files_to_delete" | xargs rm -f -- 2>/dev/null || true
            fi
        fi
    else
        log_path="/tmp/$log_name"
    fi
    echo "日志文件初始化完成。日志文件路径: $log_path" >&2

    echo "$log_path"
}

#-----------------------------------------------------------------------
# 函数：check_network
# 描述：使用探测到的网络工具测试与软件源的连通性
#-----------------------------------------------------------------------
check_network() {
    local test_url="$1"
    local log_file="$2"
    local retries=3
    local i=1

    if [ -z "$NET_TOOL" ]; then
        log_error "$log_file" "无可用的网络检测工具 (curl/wget/ping 均未找到)"
        return 1
    fi

    while [ "$i" -le "$retries" ]; do
        log_debug "$log_file" "尝试连接 $test_url (第 $i/$retries 次) 使用 $NET_TOOL..."
        local success=0
        local err_out=""

        case "$NET_TOOL" in
        curl)
            err_out=$(curl "${NET_TOOL_OPTS[@]}" "$test_url" 2>&1) && success=1 || true
            ;;
        wget)
            err_out=$(wget "${NET_TOOL_OPTS[@]}" "$test_url" 2>&1) && success=1 || true
            ;;
        ping)
            local host
            host=$(echo "$test_url" | awk -F/ '{print $3}')
            err_out=$(ping "${NET_TOOL_OPTS[@]}" "$host" 2>&1) && success=1 || true
            ;;
        esac

        if [ "$success" -eq 1 ]; then
            log_info "$log_file" "网络连接正常 (URL: $test_url)"
            return 0
        else
            log_warn "$log_file" "网络检查失败 (尝试 $i/$retries): URL=$test_url, 工具=$NET_TOOL"
            log_debug "$log_file" "错误输出: $err_out"
        fi
        sleep $((i * 2))
        i=$((i + 1))
    done
    log_error "$log_file" "网络不可达，所有重试已用完"
    return 1
}

#-----------------------------------------------------------------------
# 函数：update_package_lists
# 描述：执行 apk update，把所有输出留档供失败分类使用
#       apk update 在「部分源不可用」时退出码可能非 0 但索引仍可用，
#       因此这里只返回退出码，由调用方决定是否继续
#-----------------------------------------------------------------------
update_package_lists() {
    local log_file="${1:-/dev/null}"
    log_info "$log_file" "开始更新软件包列表..."

    APK_LAST_OUTPUT="/tmp/apk-update-$$.log"
    local ret=0
    apk update >"$APK_LAST_OUTPUT" 2>&1 || ret=$?

    if [ "$ret" -ne 0 ]; then
        log_warn "$log_file" "软件源更新部分失败 (退出码 $ret)"
        {
            echo "--- apk update 输出开始 ---"
            cat "$APK_LAST_OUTPUT" 2>/dev/null || true
            echo "--- apk update 输出结束 ---"
        } >>"$log_file"
    else
        log_info "$log_file" "软件源更新成功"
    fi
    return "$ret"
}

#-----------------------------------------------------------------------
# 函数：classify_apk_failure
# 描述：根据 apk 输出判定失败类别
#       判定顺序很重要：先查 fetch 特征，再查 resolve 特征。
#       索引没下载下来时 apk 也会打印 "unable to select packages"，
#       若先判 resolve 会把网络问题误报成「包不存在」。
# 参数：$1 apk 输出文件
# 返回：stdout 输出 "fetch|fetch_error" 或 "resolve|package_not_found"
#-----------------------------------------------------------------------
classify_apk_failure() {
    local out_file="$1"

    if grep -qE 'wget: exited with error|unexpected end of file|package mentioned in index not found|Operation not permitted|Connection (timed out|refused)|network is unreachable' \
        "$out_file" 2>/dev/null; then
        printf 'fetch|fetch_error'
        return 0
    fi

    if grep -qE 'unable to select packages|no such package|required by' "$out_file" 2>/dev/null; then
        printf 'resolve|package_not_found'
        return 0
    fi

    # 兜底：非 0 退出但不是已知形态，按 fetch 处理（多为下载/IO 问题）
    printf 'fetch|fetch_error'
}

#-----------------------------------------------------------------------
# 函数：collect_missing_packages
# 描述：从 apk 输出中提取 "xxx (no such package)" 形态的缺失包名
#       不把 "error: uninstallable" 那种架构不匹配条目算进来
# 参数：$1 apk 输出文件
# 返回：stdout 每行一个包名
#-----------------------------------------------------------------------
collect_missing_packages() {
    local out_file="$1"
    awk '
        /\(no such package\)/ {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]*\(no such package\).*$/, "", line)
            if (line != "") print line
        }
    ' "$out_file" 2>/dev/null || true
}

#-----------------------------------------------------------------------
# 函数：collect_required_by
# 描述：从 apk 输出中提取 "required by: ..." 的内容，去重保序
# 参数：$1 apk 输出文件
# 返回：stdout 每行一条
#-----------------------------------------------------------------------
collect_required_by() {
    local out_file="$1"
    sed -n 's/^[[:space:]]*required by:[[:space:]]*//p' "$out_file" 2>/dev/null |
        awk 'NF && !seen[$0]++' || true
}

#-----------------------------------------------------------------------
# 函数：_failure_message_line
# 描述：从 apk 输出里挑出作为 message 的那一行：ERROR 优先，其次 WARNING，再次首行
#       WARNING 只作为 related_warning 上下文，不单独算一条失败事件——这是需求明确要求的。
# 参数：$1 apk 输出文件  $2 兜底文本（都取不到时用）
# 返回：stdout 输出单行
#-----------------------------------------------------------------------
_failure_message_line() {
    local out_file="$1"
    local fallback="$2"
    local line

    line=$(grep -E '^ERROR' "$out_file" 2>/dev/null | head -n 1 || true)
    [ -n "$line" ] || line=$(grep -E '^WARNING' "$out_file" 2>/dev/null | head -n 1 || true)
    [ -n "$line" ] || line=$(head -n 1 "$out_file" 2>/dev/null || true)
    [ -n "$line" ] || line="$fallback"

    printf '%s' "$line"
}

#-----------------------------------------------------------------------
# 函数：_record_package_not_found
# 描述：把「包不存在」类失败按解析口径记录（带 missing_packages / required_by）
# 参数：$1 apk 输出文件  $2 包名  $3 attempt  $4 message  $5 related_warning
# 返回：恒为 0（记录失败不影响继续装下一个包）
#-----------------------------------------------------------------------
_record_package_not_found() {
    local out_file="$1"
    local pkg="$2"
    local attempt="$3"
    local message="$4"
    local related_warning="$5"
    local missing_list required_list

    missing_list=$(collect_missing_packages "$out_file" | paste -sd, - 2>/dev/null || true)
    required_list=$(collect_required_by "$out_file" | paste -sd, - 2>/dev/null || true)
    # 没有抓到具体缺失项时，至少把当前包名记进去
    if [ -z "$missing_list" ]; then
        missing_list="$pkg"
    fi
    record_failure "resolve" "package_not_found" "$pkg" "$message" "$attempt" \
        "missing_packages=@$missing_list" \
        "required_by=@$required_list" \
        "likely_cause=repository index is missing or incomplete, or the package was renamed or removed" \
        "related_warning=$related_warning" || true
    return 0
}

#-----------------------------------------------------------------------
# 函数：_record_fetch_failure
# 描述：把「抓取/下载」类失败按 fetch 口径记录（带 tool / exit_code / target）
# 参数：$1 stage  $2 包名  $3 attempt  $4 退出码  $5 message  $6 related_warning
# 返回：恒为 0
#-----------------------------------------------------------------------
_record_fetch_failure() {
    local stage="$1"
    local pkg="$2"
    local attempt="$3"
    local ret="$4"
    local message="$5"
    local related_warning="$6"

    record_failure "$stage" "fetch_error" "$pkg" "$message" "$attempt" \
        "tool=apk" \
        "exit_code=$ret" \
        "target=$pkg" \
        "related_warning=$related_warning" || true
    return 0
}

#-----------------------------------------------------------------------
# 函数：_install_one_package
# 描述：单包 best-effort 安装；已安装则跳过。失败时分类并记录一条失败事件。
# 参数：$1 包名  $2 attempt  $3 日志文件
# 返回：0 成功或已安装；1 安装失败（已记录）
#-----------------------------------------------------------------------
_install_one_package() {
    local pkg="$1"
    local attempt="$2"
    local log_file="$3"
    local ret=0

    # 已安装的包直接跳过，省一次网络往返
    if apk info --installed "$pkg" >/dev/null 2>&1; then
        log_debug "$log_file" "包已安装，跳过: $pkg"
        return 0
    fi

    APK_LAST_OUTPUT="/tmp/apk-add-$$.log"
    apk add --no-cache "$pkg" >"$APK_LAST_OUTPUT" 2>&1 || ret=$?

    if [ "$ret" -eq 0 ]; then
        log_info "$log_file" "安装成功: $pkg"
        return 0
    fi

    log_warn "$log_file" "安装失败: $pkg (退出码 $ret)"

    # ---- 失败分类与 NDJSON 记录 ----
    local cls stage error_class message related_warning
    cls=$(classify_apk_failure "$APK_LAST_OUTPUT")
    stage="${cls%%|*}"
    error_class="${cls##*|}"

    message=$(_failure_message_line "$APK_LAST_OUTPUT" "apk add failed with exit code $ret")
    related_warning=$(sed -n 's/^WARNING:[[:space:]]*//p' "$APK_LAST_OUTPUT" 2>/dev/null | head -n 1 || true)

    if [ "$error_class" = "package_not_found" ]; then
        _record_package_not_found "$APK_LAST_OUTPUT" "$pkg" "$attempt" "$message" "$related_warning"
    else
        _record_fetch_failure "$stage" "$pkg" "$attempt" "$ret" "$message" "$related_warning"
    fi
    return 1
}

#-----------------------------------------------------------------------
# 函数：install_packages_one_by_one
# 描述：逐包 best-effort 安装。
#       之所以必须逐包：实测 apk add 传多个包是「全有或全无」——
#       只要有一个包无法 select，其余包一个都不会装。
#       因此逐包调用，单包失败只记一条失败事件，继续下一个。
# 参数：$1 包列表文件  $2 本轮 attempt  $3 日志文件
# 返回：0；失败包数量写入全局变量 INSTALL_FAILED_COUNT
#       （不用 stdout 回传：控制台模式下日志会写 stdout，会污染命令替换的结果）
#-----------------------------------------------------------------------
install_packages_one_by_one() {
    local pkg_list="$1"
    local attempt="$2"
    local log_file="$3"
    local failed=0
    local idx=0
    local total
    total=$(wc -l <"$pkg_list" | tr -d ' ')

    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        idx=$((idx + 1))

        if [ "${LOG_TO_CONSOLE:-0}" -eq 1 ]; then
            printf '\r[%d/%d] 安装 %-40s' "$idx" "$total" "$pkg" >&2
        fi

        _install_one_package "$pkg" "$attempt" "$log_file" || failed=$((failed + 1))
    done <"$pkg_list"

    [ "${LOG_TO_CONSOLE:-0}" -eq 1 ] && printf '\n' >&2

    INSTALL_FAILED_COUNT="$failed"
    return 0
}

#===============================================================================
# 配置修改与恢复
#===============================================================================

backup_resolv_config() {
    local log_file="$1"
    log_info "$log_file" "备份DNS配置并设置临时 DNS (8.8.8.8, 1.1.1.1)"
    cp /etc/resolv.conf /tmp/resolv.conf.backup 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    {
        echo "nameserver 8.8.8.8"
        echo "nameserver 1.1.1.1"
    } >/etc/resolv.conf 2>/dev/null || true
}

detect_firewall_type() {
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1; then
        echo "iptables"
    else
        echo ""
    fi
}

set_temp_firewall_rules() {
    local fw_type="$1"
    local log_file="$2"

    log_info "$log_file" "设置临时防火墙规则 ($fw_type) - 仅放行 DNS/HTTP/HTTPS 出站"
    case "$fw_type" in
    iptables)
        iptables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -I OUTPUT 2 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I OUTPUT 3 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I OUTPUT 4 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 2 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 3 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 4 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        ;;
    nftables)
        nft add table inet temp_restore 2>/dev/null || true
        nft 'add chain inet temp_restore output { type filter hook output priority -1; }' 2>/dev/null || true
        nft 'add rule inet temp_restore output udp dport 53 accept' 2>/dev/null || true
        nft 'add rule inet temp_restore output tcp dport { 80, 443 } accept' 2>/dev/null || true
        nft 'add rule inet temp_restore output ct state established,related accept' 2>/dev/null || true
        ;;
    esac
}

restore_original_config() {
    local backup_resolv_flag="$1"
    local firewall_type="$2"
    local log_file="${3:-/dev/null}"

    if [ "$backup_resolv_flag" -eq 1 ] && [ -f /tmp/resolv.conf.backup ]; then
        log_info "$log_file" "恢复原始DNS配置"
        mv -f /tmp/resolv.conf.backup /etc/resolv.conf 2>/dev/null || true
        /etc/init.d/dnsmasq start 2>/dev/null || true
    fi

    if [ -n "$firewall_type" ]; then
        log_info "$log_file" "清理临时防火墙规则 ($firewall_type)..."
        case "$firewall_type" in
        iptables)
            iptables -D OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
            iptables -D OUTPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
            iptables -D OUTPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
            iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            ip6tables -D OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
            ip6tables -D OUTPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
            ip6tables -D OUTPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
            ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            ;;
        nftables)
            nft delete table inet temp_restore 2>/dev/null || true
            ;;
        esac
    fi
}

#===============================================================================
# 脚本入口
#===============================================================================
main "$@"
