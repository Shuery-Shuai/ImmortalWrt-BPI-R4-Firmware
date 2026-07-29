#!/bin/bash
#===============================================================================
# 软件包恢复脚本
# 功能：从备份文件批量恢复用户安装的软件包，并在成功后重启系统
# 用法：restore-packages.sh [选项] [备份文件路径]
#
# 选项：
#   -h, --help      显示帮助信息并退出
#   -d, --debug     启用调试日志，记录所有 apk 命令详细输出
#   -q, --quiet     静默模式，仅记录警告和错误
#   -c, --console   将 INFO 及以上级别消息同时输出到控制台
#
# 参数：
#   备份文件路径   要恢复的包列表文件，默认为 /etc/backup/installed_packages.txt
#
# 环境变量：
#   LOG_LEVEL       日志级别 (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR) [默认: 1]
#   LOG_TO_CONSOLE  是否输出到终端 (1=是, 0=否) [默认: 0]
#   MAX_LOG_FILES   保留的历史日志文件数量 [默认: 5]
#
# 返回值：
#   0   成功（备份文件不存在或恢复完成）
#   1   发生错误（网络不可达、安装失败等）
#
# 说明：
#   该脚本专为 OpenWrt/ImmortalWrt 环境设计，使用 apk 包管理器。
#   恢复过程仅处理标记为 overlay 的用户安装包，跳过固件自带的 ROM 包。
#   若网络不通，会自动修改 DNS 和临时放行防火墙以尝试连接软件源，
#   脚本退出时（无论成功或失败）均会恢复原始配置。
#   安装成功后删除备份文件，因此下次启动检测到备份文件缺失会自动跳过。
#
# 作者：Shuery-Shuai
# 日期：2025-06-27
# 版本：1.2.1
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

# 可通过环境变量覆盖默认配置
LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}                       # 默认 INFO 级别
LOG_TO_CONSOLE=${LOG_TO_CONSOLE:-0}                     # 默认不输出到控制台
MAX_LOG_FILES=${MAX_LOG_FILES:-5}                       # 最多保留的日志文件数
LOCKFILE="${LOCKFILE:-/var/lock/restore-packages.lock}" # 锁文件路径，防止多实例并发

# 默认备份文件路径
readonly DEFAULT_BACKUP_FILE="/etc/backup/installed_packages.txt"

# 记录安装失败的包列表文件路径（用于调试和后续处理）
FAILED_FILE="/etc/backup/failed-pkgs.list"

# ================================================================
# 全局状态变量（必须为全局，因为 trap 函数中需要访问）
# ================================================================
backup_resolv_flag=0 # 是否已修改 DNS 配置（0=未修改, 1=已修改）
firewall_type=""     # 临时修改的防火墙类型（iptables/nftables/空）
log_file=""          # 日志文件路径

# ================================================================
# 命令行选项变量
# ================================================================
opt_backup_file="" # 指定的备份文件路径
opt_debug=0        # 调试模式标志
opt_quiet=0        # 静默模式标志
opt_console=0      # 控制台输出标志

# ================================================================
# 可用网络检测工具（脚本运行时自动探测）
# ================================================================
NET_TOOL=""      # 使用的工具名（curl/wget/ping）
NET_TOOL_OPTS=() # 工具对应的参数（数组）

#===============================================================================
# 函数：show_help
# 描述：打印帮助信息并退出
#===============================================================================
show_help() {
    cat <<EOF
软件包恢复脚本 v1.5.0

用法: $(basename "$0") [选项] [备份文件路径]

选项:
  -h, --help      显示此帮助信息并退出
  -d, --debug     启用调试日志，记录所有 apk 命令详细输出
  -q, --quiet     静默模式，仅记录警告和错误
  -c, --console   将 INFO 及以上消息同时输出到控制台

参数:
  备份文件路径   要恢复的包列表文件，默认为:
                 $DEFAULT_BACKUP_FILE

环境变量:
  LOG_LEVEL       日志级别 (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR)
  LOG_TO_CONSOLE  是否输出到终端 (1=是, 0=否)
  MAX_LOG_FILES   保留的历史日志文件数量

注意:
  成功恢复后备份文件会被删除，下次执行时会因备份文件缺失而自动跳过，
  不再需要手动创建标记文件。若需再次恢复，请重新放置备份文件。
EOF
}

#===============================================================================
# 函数：parse_args
# 描述：解析命令行参数
# 全局变量：opt_backup_file, opt_debug, opt_quiet, opt_console
# 参数：$@ 命令行参数
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
        --)
            shift
            opt_backup_file="$1"
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
    # 若未指定备份文件则使用默认值
    opt_backup_file="${opt_backup_file:-$DEFAULT_BACKUP_FILE}"
    log_header "$log_file" "命令行参数解析完成" "备份文件: $opt_backup_file, 调试: $opt_debug, 静默: $opt_quiet, 控制台输出: $opt_console"
}

#===============================================================================
# 函数：apply_log_options
# 描述：将命令行选项应用到全局日志配置
# 全局变量：LOG_LEVEL, LOG_TO_CONSOLE, opt_debug, opt_quiet, opt_console
#===============================================================================
apply_log_options() {
    log_header "$log_file" "应用日志配置" "调试: $opt_debug, 静默: $opt_quiet, 控制台输出: $opt_console"
    [ "$opt_debug" -eq 1 ] && LOG_LEVEL=$LOG_DEBUG
    [ "$opt_quiet" -eq 1 ] && LOG_LEVEL=$LOG_WARN
    [ "$opt_console" -eq 1 ] && LOG_TO_CONSOLE=1
    log_header "$log_file" "日志配置应用完成" "日志级别: $LOG_LEVEL, 控制台输出: $LOG_TO_CONSOLE"
}

#===============================================================================
# 函数：detect_net_tool
# 描述：探测系统中可用的网络检测工具，按优先级：curl > wget > ping
# 全局变量：NET_TOOL, NET_TOOL_OPTS
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
# 函数：main
# 描述：主控制流程
#===============================================================================
main() {
    log_file=$(init_log_file) # 初始化日志文件路径

    # 解析命令行参数并应用配置
    parse_args "$@"
    apply_log_options
    detect_net_tool

    #-----------------------------------------------------------------------
    # 尝试获取独占文件锁。若已有实例持有该锁，flock -n 会立即失败，
    # 此时输出提示并退出，避免并发执行恢复脚本。
    # 9 是文件描述符，由重定向自动关联到 LOCKFILE。
    #-----------------------------------------------------------------------
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        # 锁获取失败意味着已有实例在运行
        log_error "$log_file" "另一个恢复实例正在运行，退出"
        exit 1
    fi

    local script_start_time
    script_start_time=$(date +%s) # 记录脚本启动时间戳（用于计算总耗时）
    local backup_file="$opt_backup_file"
    local test_url
    test_url=$(get_apk_repo_url) # 从系统源获取测试 URL

    # 设置退出时的清理陷阱（恢复 DNS 和防火墙）
    # 注意：backup_resolv_flag 与 firewall_type 必须为全局变量
    trap 'restore_original_config "$backup_resolv_flag" "$firewall_type" "$log_file"' EXIT

    log_header "$log_file" "脚本启动" "备份文件=$backup_file"
    log_info "$log_file" "日志级别: $LOG_LEVEL, 控制台输出: $LOG_TO_CONSOLE"
    [ -n "$NET_TOOL" ] && log_info "$log_file" "网络检测工具: $NET_TOOL"

    #-------- 第一阶段：预检查与备份文件存在性判断 --------
    log_header "$log_file" "预检查阶段开始"
    if [ ! -f "$backup_file" ]; then
        log_info "$log_file" "备份文件不存在: $backup_file，视为已恢复或无需恢复"
        log_exit_summary "$log_file" 0 "$script_start_time"
        return 0
    fi

    # 预检查包是否都已安装，若全部存在则无需网络操作，直接退出
    if check_all_packages_installed "$backup_file" "$log_file"; then
        log_info "$log_file" "所有软件包已安装，无需操作"
        log_exit_summary "$log_file" 0 "$script_start_time"
        return 0
    fi

    #-------- 第二阶段：确保网络可达 --------
    log_header "$log_file" "网络连通性检测阶段开始"
    if ! check_network "$test_url" "$log_file"; then
        # 第一次失败，修改 DNS 和防火墙再试
        log_info "$log_file" "第一次网络检测失败，尝试修改 DNS 和防火墙"
        backup_resolv_flag=1
        backup_resolv_config "$log_file"

        firewall_type=$(detect_firewall_type)
        log_info "$log_file" "检测到防火墙类型: ${firewall_type:-无}"
        if [ -n "$firewall_type" ]; then
            set_temp_firewall_rules "$firewall_type" "$log_file"
        fi

        if ! check_network "$test_url" "$log_file"; then
            log_error "$log_file" "无法连接软件源，恢复中止"
            log_exit_summary "$log_file" 1 "$script_start_time"
            return 1
        fi
    fi

    #-------- 第三阶段：更新软件源 --------
    log_header "$log_file" "软件源更新阶段开始"
    if ! update_package_lists "$log_file"; then
        log_error "$log_file" "软件源索引不可用，恢复中止"
        log_exit_summary "$log_file" 1 "$script_start_time"
        return 1
    fi

    #-------- 第四阶段：安装包并验证 --------
    log_header "$log_file" "软件包安装与验证阶段开始"
    if ! install_and_verify_packages "$backup_file" "$log_file"; then
        log_error "$log_file" "软件包安装验证失败"
        log_exit_summary "$log_file" 1 "$script_start_time"
        return 1
    fi

    # 安装成功，删除备份文件（以此作为下次启动的完成信号）
    rm -f "$backup_file" && log_info "$log_file" "已删除备份文件: $backup_file"

    log_header "$log_file" "恢复完成" "所有软件包验证成功"
    log_info "$log_file" "系统将在10秒后重启..."
    log_exit_summary "$log_file" 0 "$script_start_time"
    sync
    sleep 10
    reboot -f
}

#===============================================================================
# 函数：get_apk_repo_url
# 描述：从系统 apk 配置中获取第一个可用的软件源 URL
#       扫描 /etc/apk/repositories 及 /etc/apk/repositories.d/*.list
# 返回：输出一个 URL 字符串
#===============================================================================
get_apk_repo_url() {
    local url files=()

    # 收集所有可能的源配置文件
    [ -f /etc/apk/repositories ] && files+=("/etc/apk/repositories")
    if [ -d /etc/apk/repositories.d ]; then
        while IFS= read -r f; do
            files+=("$f")
        done < <(find /etc/apk/repositories.d -name '*.list' -type f 2>/dev/null)
    fi

    # 遍历文件，取第一个以 http/https 开头的行
    for f in "${files[@]}"; do
        url=$(awk '/^https?:\/\// {print; exit}' "$f" 2>/dev/null)
        [ -n "$url" ] && break
    done

    # 如果都没找到，回退到 Alpine CDN（一般不会用到）
    echo "${url:-https://dl-cdn.alpinelinux.org}"
}

#===============================================================================
# 函数：init_log_file
# 描述：初始化日志文件路径，若 /var/log 不可写则使用 /tmp
#       同时执行日志轮转，保留最近 MAX_LOG_FILES 个文件。
#       优先使用 find + stat 以安全处理特殊文件名，不可用时回退到 ls -t。
# 全局变量：MAX_LOG_FILES
# 返回：输出日志文件完整路径
#===============================================================================
init_log_file() {
    local log_dir="/var/log"
    local log_name
    log_name="package-restore-$(date +'%Y%m%d%H%M%S').log"
    local log_path

    echo "初始化日志文件: $log_name" >&2 # 输出到 stderr，避免污染 stdout
    if [ -d "$log_dir" ] && [ -w "$log_dir" ]; then
        log_path="$log_dir/$log_name"

        # ---- 日志轮转：保留最近的 MAX_LOG_FILES 个日志文件 ----
        local pattern="package-restore-*.log"
        if command -v stat >/dev/null 2>&1; then
            # 使用 find + stat：输出 "修改时间戳 文件名"，按时间戳逆序排序后，
            # 跳过前 MAX_LOG_FILES 个文件，删除剩余旧文件。
            # cut -d' ' -f2- 可正确保留文件名中的空格。
            find "$log_dir" -maxdepth 1 -name "$pattern" -type f \
                -exec stat -c '%Y %n' {} \; |
                sort -rn |
                tail -n +$((MAX_LOG_FILES + 1)) |
                cut -d' ' -f2- |
                xargs rm -f --
        else
            # 回退到 ls -t：简单但可能被特殊文件名干扰
            local files_to_delete
            # shellcheck disable=SC2012
            files_to_delete=$(ls -t "$log_dir"/"$pattern" 2>/dev/null |
                tail -n +$((MAX_LOG_FILES + 1)))
            if [ -n "$files_to_delete" ]; then
                echo "$files_to_delete" | xargs rm -f --
            fi
        fi
    else
        log_path="/tmp/$log_name"
    fi
    echo "日志文件初始化完成。日志文件路径: $log_path" >&2

    echo "$log_path"
}

#===============================================================================
# 日志系统（已重构：级别过滤、终端输出、无污染返回）
#===============================================================================

#-----------------------------------------------------------------------
# 函数：log_write
# 描述：底层日志写入，根据级别决定是否写入文件及控制台
#       文件写入和终端输出均受 LOG_LEVEL 控制，WARN/ERROR 强制输出 stderr
# 全局变量：LOG_LEVEL, LOG_TO_CONSOLE
# 参数：
#   $1: 日志级别数值 (LOG_DEBUG/INFO/WARN/ERROR)
#   $2: 日志文件路径
#   $3: 日志消息
#-----------------------------------------------------------------------
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

    # 级别过滤：低于当前全局级别的日志不记录
    if [ "$level" -lt "$current_level" ]; then
        return 0
    fi

    # 写入日志文件
    echo "$line" >>"$log_file"

    # 控制台输出
    if [ "${LOG_TO_CONSOLE:-0}" -eq 1 ]; then
        if [ "$level" -ge "$LOG_WARN" ]; then
            echo "$line" >&2
        else
            echo "$line"
        fi
    fi
}

#-----------------------------------------------------------------------
# 函数：log_debug
# 描述：记录 DEBUG 日志，受全局 LOG_LEVEL 过滤
# 参数：
#   $1: 日志文件路径
#   $2: 消息
#-----------------------------------------------------------------------
log_debug() {
    log_write "$LOG_DEBUG" "$1" "$2"
}

#-----------------------------------------------------------------------
# 函数：log_info
# 描述：记录 INFO 日志，受全局 LOG_LEVEL 过滤
# 参数：
#   $1: 日志文件路径
#   $2: 消息
#-----------------------------------------------------------------------
log_info() {
    log_write "$LOG_INFO" "$1" "$2"
}

#-----------------------------------------------------------------------
# 函数：log_warn
# 描述：记录 WARN 日志，受全局 LOG_LEVEL 过滤
# 参数：
#   $1: 日志文件路径
#   $2: 消息
#-----------------------------------------------------------------------
log_warn() {
    log_write "$LOG_WARN" "$1" "$2"
}

#-----------------------------------------------------------------------
# 函数：log_error
# 描述：记录 ERROR 日志，始终生效（LEVEL=ERROR 最高）
# 参数：
#   $1: 日志文件路径
#   $2: 消息
#-----------------------------------------------------------------------
log_error() {
    log_write "$LOG_ERROR" "$1" "$2"
}

#-----------------------------------------------------------------------
# 函数：log_header
# 描述：输出阶段性标题，视为 INFO 级别日志，受 LOG_LEVEL 和 LOG_TO_CONSOLE 控制
# 参数：
#   $1: 日志文件路径
#   $2: 标题
#   $3: 附加信息（可选）
#-----------------------------------------------------------------------
log_header() {
    local log_file="${1:-}"
    local title="${2:-}"
    local info="${3:-}"

    # 级别过滤：高于 INFO 时不记录（标题属于流程信息）
    [ "${LOG_LEVEL:-$LOG_INFO}" -gt "$LOG_INFO" ] && return 0

    local timestamp
    timestamp=$(date '+%F %T')
    local header_line="===== $timestamp - $title ====="
    local info_line=""
    [ -n "$info" ] && info_line="信息: $info"

    # 写入日志文件
    {
        echo "$header_line"
        [ -n "$info_line" ] && echo "$info_line"
        echo
    } >>"$log_file"

    # 控制台输出（若开启）
    if [ "${LOG_TO_CONSOLE:-0}" -eq 1 ]; then
        echo "$header_line"
        [ -n "$info_line" ] && echo "$info_line"
        echo
    fi
}

#-----------------------------------------------------------------------
# 函数：log_exit_summary
# 描述：脚本退出时记录总耗时及状态
# 参数：
#   $1: 日志文件路径
#   $2: 退出码 (0 成功, 非0 失败)
#   $3: 脚本启动时间戳
#-----------------------------------------------------------------------
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
# 软件包相关函数
#===============================================================================

#-----------------------------------------------------------------------
# 函数：check_all_packages_installed
# 描述：预检查备份文件中的所有 overlay 包是否已安装
# 参数：
#   $1: 备份文件路径
#   $2: 日志文件路径
# 返回：0 (全部已安装) 或 1 (存在未安装)
#-----------------------------------------------------------------------
check_all_packages_installed() {
    local backup_file="$1"
    local log_file="$2"
    local user_pkgs="/tmp/user-pkgs-check.list"
    local all_installed=1

    # 提取所有 overlay 包名
    grep '\toverlay' "$backup_file" | awk '{print $1}' >"$user_pkgs"

    if [ ! -s "$user_pkgs" ]; then
        log_info "$log_file" "无用户安装包需要检查"
        rm -f "$user_pkgs"
        return 0
    fi

    log_info "$log_file" "开始预检查 $(wc -l <"$user_pkgs") 个用户安装包..."

    # 逐一验证是否已安装
    while IFS= read -r pkg; do
        if ! apk info --installed "$pkg" >/dev/null 2>&1; then
            log_info "$log_file" "包未安装: $pkg"
            all_installed=0
        fi
    done <"$user_pkgs"

    rm -f "$user_pkgs"
    if [ "$all_installed" -eq 1 ]; then
        log_info "$log_file" "所有用户安装包已存在"
        return 0
    else
        log_info "$log_file" "存在未安装的用户包"
        return 1
    fi
}

#-----------------------------------------------------------------------
# 函数：check_network
# 描述：使用探测到的网络工具测试与软件源的连通性
# 全局变量：NET_TOOL, NET_TOOL_OPTS
# 参数：
#   $1: 测试 URL
#   $2: 日志文件路径
# 返回：0 (网络正常), 1 (不通)
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
            # ping 仅检测主机部分
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

#===============================================================================
# 配置修改与恢复函数
#===============================================================================

#-----------------------------------------------------------------------
# 函数：backup_resolv_config
# 描述：备份当前 DNS 配置并设置临时公共 DNS (8.8.8.8, 1.1.1.1)
#       同时停止 dnsmasq 防止覆盖
# 参数：
#   $1: 日志文件路径
#-----------------------------------------------------------------------
backup_resolv_config() {
    local log_file="$1"
    log_info "$log_file" "备份DNS配置并设置临时 DNS (8.8.8.8, 1.1.1.1)"
    cp /etc/resolv.conf /tmp/resolv.conf.backup
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    {
        echo "nameserver 8.8.8.8"
        echo "nameserver 1.1.1.1"
    } >/etc/resolv.conf
}

#-----------------------------------------------------------------------
# 函数：detect_firewall_type
# 描述：检测系统当前使用的防火墙类型（不输出任何日志，仅通过 stdout 返回结果）
# 返回："nftables", "iptables" 或空（无防火墙）
#-----------------------------------------------------------------------
detect_firewall_type() {
    # 注意：此函数不能输出除返回值以外的任何内容，否则污染调用处变量
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1; then
        echo "iptables"
    else
        echo ""
    fi
}

#-----------------------------------------------------------------------
# 函数：set_temp_firewall_rules
# 描述：插入临时防火墙规则，仅放行 DNS/HTTP/HTTPS 出站，
#       不修改默认策略，避免破坏原有安全配置
# 参数：
#   $1: 防火墙类型 (iptables/nftables)
#   $2: 日志文件路径
#-----------------------------------------------------------------------
set_temp_firewall_rules() {
    local fw_type="$1"
    local log_file="$2"

    log_info "$log_file" "设置临时防火墙规则 ($fw_type) - 仅放行 DNS/HTTP/HTTPS 出站"
    case "$fw_type" in
    iptables)
        # 插入到 OUTPUT 链最前端
        iptables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT
        iptables -I OUTPUT 2 -p tcp --dport 80 -j ACCEPT
        iptables -I OUTPUT 3 -p tcp --dport 443 -j ACCEPT
        iptables -I OUTPUT 4 -m state --state ESTABLISHED,RELATED -j ACCEPT
        # IPv6 也放行（若存在）
        ip6tables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 2 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 3 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        ip6tables -I OUTPUT 4 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        ;;
    nftables)
        # 创建临时表，优先级高于常规规则
        nft add table inet temp_restore
        nft 'add chain inet temp_restore output { type filter hook output priority -1; }'
        nft 'add rule inet temp_restore output udp dport 53 accept'
        nft 'add rule inet temp_restore output tcp dport { 80, 443 } accept'
        nft 'add rule inet temp_restore output ct state established,related accept'
        ;;
    esac
}

#-----------------------------------------------------------------------
# 函数：restore_original_config
# 描述：恢复临时修改的 DNS 和防火墙配置
# 全局变量：None (通过参数传入)
# 参数：
#   $1: 恢复 DNS 标志 (0/1)
#   $2: 防火墙类型 (iptables/nftables/空)
#   $3: 日志文件路径
#-----------------------------------------------------------------------
restore_original_config() {
    local backup_resolv_flag="$1"
    local firewall_type="$2"
    local log_file="${3:-/dev/null}"

    # 恢复 DNS
    if [ "$backup_resolv_flag" -eq 1 ] && [ -f /tmp/resolv.conf.backup ]; then
        log_info "$log_file" "恢复原始DNS配置"
        mv -f /tmp/resolv.conf.backup /etc/resolv.conf
        /etc/init.d/dnsmasq start 2>/dev/null || true
    fi

    # 清理临时防火墙规则
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
# APK 命令封装
#===============================================================================

#-----------------------------------------------------------------------
# 函数：run_apk
# 描述：执行 apk 命令并智能记录输出
#       成功时仅在 DEBUG 模式记录详细输出，失败时总是记录
# 参数：
#   $1: 日志文件路径
#   $2: 操作描述（用于日志）
#   $@: apk 命令及参数
# 返回：apk 命令的退出码
#-----------------------------------------------------------------------
run_apk() {
    local log_file="${1:-/dev/null}"
    local desc="$2"
    shift 2
    local tmp_out="/tmp/apk-$$.log"
    local ret=0

    log_debug "$log_file" "执行命令: apk $*"
    if [ "${LOG_TO_CONSOLE}" -eq 1 ]; then
        # 同时输出到终端和临时文件，让用户看到实时进度
        apk "$@" 2>&1 | tee "$tmp_out" || ret=${PIPESTATUS[0]}
    else
        apk "$@" >"$tmp_out" 2>&1 || ret=$?
    fi

    if [ "$ret" -ne 0 ]; then
        # 失败时记录错误并附加完整输出
        log_error "$log_file" "$desc 失败 (退出码 $ret)"
        {
            echo "--- 命令输出开始 ---"
            cat "$tmp_out"
            echo "--- 命令输出结束 ---"
        } >>"$log_file"
    elif [ "${LOG_LEVEL:-$LOG_INFO}" -le "$LOG_DEBUG" ]; then
        # DEBUG 模式下记录成功时的详细输出
        log_debug "$log_file" "$desc 成功"
        {
            echo "--- 命令输出开始 ---"
            cat "$tmp_out"
            echo "--- 命令输出结束 ---"
        } >>"$log_file"
    else
        log_info "$log_file" "$desc 成功"
    fi

    rm -f "$tmp_out"
    return "$ret"
}

#-----------------------------------------------------------------------
# 函数：update_package_lists
# 描述：更新软件包列表
# 参数：
#   $1: 日志文件路径
# 返回：apk update 的退出码
#-----------------------------------------------------------------------
update_package_lists() {
    local log_file="${1:-/dev/null}"
    log_info "$log_file" "开始更新软件包列表..."
    log_debug "$log_file" "执行命令: apk update"

    local ret=0
    apk update >>"$log_file" 2>&1 || ret=$?

    if [ "$ret" -ne 0 ]; then
        log_warn "$log_file" "软件源更新部分失败 (退出码 $ret)，验证索引可用性..."
        # 尝试搜索一个常见基础包，确认至少有一个源可用
        if apk search --quiet ca-certificates >/dev/null 2>&1; then
            log_warn "$log_file" "索引基本可用，继续尝试安装软件包"
        else
            log_error "$log_file" "软件源更新失败且索引完全不可用，无法继续恢复"
            return 1
        fi
    else
        log_info "$log_file" "软件源更新成功"
    fi
}

#-----------------------------------------------------------------------
# 函数：install_and_verify_packages
# 描述：从备份文件提取 overlay 包并执行安装验证
# 参数：
#   $1: 备份文件路径
#   $2: 日志文件路径
# 返回：0 成功, 1 失败
#-----------------------------------------------------------------------
install_and_verify_packages() {
    local backup_file="$1"
    local log_file="${2:-/dev/null}"
    local max_retries=3
    local user_pkgs="/tmp/user-pkgs.list"

    # 提取所有 overlay 包的完整行（包名 \t overlay）
    grep '\toverlay' "$backup_file" >"$user_pkgs"

    local pkg_count
    pkg_count=$(wc -l <"$user_pkgs")
    log_info "$log_file" "开始安装用户软件包（overlay），共计 $pkg_count 个"
    log_debug "$log_file" "包列表: $(awk '{print $1}' "$user_pkgs" | tr '\n' ' ')"

    if ! install_pkgs_with_retry "$user_pkgs" "$max_retries" "$log_file"; then
        log_warn "$log_file" "警告：部分用户软件包未正确安装"
        rm -f "$user_pkgs"
        return 1
    fi

    # 全部安装成功，清理失败列表
    rm -f "$FAILED_FILE"
    log_info "$log_file" "所有包安装成功，已删除临时失败列表"

    rm -f "$user_pkgs"
    return 0
}

#-----------------------------------------------------------------------
# 函数：install_pkgs_with_retry
# 描述：带重试机制的包安装，先批量安装，失败后逐个重试
# 参数：
#   $1: 包列表文件（每行一个包名）
#   $2: 最大重试次数
#   $3: 日志文件路径
# 返回：0 全部安装成功, 1 仍有失败
#-----------------------------------------------------------------------
install_pkgs_with_retry() {
    local pkg_list="$1"
    local max_retries="$2"
    local log_file="${3:-/dev/null}"
    local retry_count=0
    local failed_file="${FAILED_FILE:-/etc/backup/failed-pkgs.list}"
    local all_pkgs_arr=()

    # 从完整行中提取所有包名（用于批量安装）
    readarray -t all_pkgs_arr < <(awk '{print $1}' "$pkg_list")
    [ ${#all_pkgs_arr[@]} -eq 0 ] && {
        log_info "$log_file" "无包需要安装"
        return 0
    }

    # 确保失败列表文件所在目录存在
    mkdir -p "$(dirname "$failed_file")"

    while [ "$retry_count" -lt "$max_retries" ]; do
        local batch_ok=1
        if [ "${LOG_TO_CONSOLE}" -eq 1 ]; then
            log_info "$log_file" "正在批量安装所有软件包，请耐心等待..."
            if run_apk_with_progress "$log_file" "批量安装包" add --no-cache "${all_pkgs_arr[@]}"; then
                batch_ok=0
            fi
        else
            if run_apk "$log_file" "批量安装包" add --no-cache "${all_pkgs_arr[@]}"; then
                batch_ok=0
            fi
        fi
        if [ "$batch_ok" -eq 0 ]; then
            log_info "$log_file" "批量安装成功"
            return 0
        fi

        log_info "$log_file" "批量安装失败，开始逐个安装并收集失败包..."
        : >"$failed_file" # 清空失败列表

        # 逐个安装，失败则记录到 failed_file
        local total_pkgs pkg_name individual_index=0 line
        total_pkgs=$(wc -l <"$pkg_list")
        while IFS= read -r line; do
            pkg_name=$(echo "$line" | awk '{print $1}')
            individual_index=$((individual_index + 1))
            # 输出进度条（仅控制台）
            if [ "${LOG_TO_CONSOLE}" -eq 1 ]; then
                local percent=$((individual_index * 100 / total_pkgs))
                local filled=$((percent * 30 / 100))
                local empty=$((30 - filled))
                printf "\r[%s%s] %3d%% (%d/%d) %-30s" \
                    "$(printf '#%.0s' $(seq 1 $filled))" \
                    "$(printf ' %.0s' $(seq 1 $empty))" \
                    "$percent" "$individual_index" "$total_pkgs" "$pkg_name"
            fi
            if ! run_apk "$log_file" "安装 $pkg_name" add --no-cache "$pkg_name"; then
                # 失败时保留完整行
                echo "$line" >>"$failed_file"
            fi
        done <"$pkg_list"
        # 换行结束进度条
        [ "${LOG_TO_CONSOLE}" -eq 1 ] && echo ""

        # 若无失败包，成功返回
        if [ ! -s "$failed_file" ]; then
            log_info "$log_file" "逐个安装全部成功"
            return 0
        fi

        # 准备重试
        retry_count=$((retry_count + 1))
        local fail_count
        fail_count=$(wc -l <"$failed_file")
        log_info "$log_file" "第 $retry_count/$max_retries 次重试，剩余失败包: $fail_count"

        # 用失败列表更新 pkg_list 和 all_pkgs 以备下次循环
        cp "$failed_file" "$pkg_list"
        readarray -t all_pkgs_arr < <(awk '{print $1}' "$failed_file")
        sleep 5
    done

    # 重试耗尽，记录最终失败列表
    log_error "$log_file" "以下软件包安装失败:"
    cat "$failed_file" >>"$log_file"
    return 1
}

#-----------------------------------------------------------------------
# 函数：run_apk_with_progress
# 描述：执行 apk 命令，解析输出中的进度信息并显示动态进度条
#       进度条格式：[#########       ] 45% (32/71) v2ray-geoip
# 参数：
#   $1: 日志文件路径
#   $2: 操作描述（用于日志）
#   $@: apk 命令及参数
# 返回：apk 命令的退出码
#-----------------------------------------------------------------------
run_apk_with_progress() {
    local log_file="$1"
    local desc="$2"
    shift 2
    local tmp_out="/tmp/apk-$$.log"
    local ret=0
    local line

    log_debug "$log_file" "执行命令: apk $*"
    # 执行命令，逐行处理输出
    apk "$@" 2>&1 | tee "$tmp_out" | {
        local total=0 current=0 pkg_name=""
        while IFS= read -r line; do
            # 匹配格式：( 1/71) Installing package-name (version)
            if [[ $line =~ ^\([[:space:]]*([0-9]+)/([0-9]+)\)[[:space:]]+Installing[[:space:]]+([^[:space:]]+)[[:space:]]+\( ]]; then
                current=${BASH_REMATCH[1]}
                total=${BASH_REMATCH[2]}
                pkg_name=${BASH_REMATCH[3]}
                if [ "$total" -gt 0 ]; then
                    local percent=$((current * 100 / total))
                    local filled=$((percent * 30 / 100))
                    local empty=$((30 - filled))
                    printf "\r[%s%s] %3d%% (%d/%d) %-35s" \
                        "$(printf '#%.0s' $(seq 1 "$filled"))" \
                        "$(printf ' %.0s' $(seq 1 "$empty"))" \
                        "$percent" "$current" "$total" "$pkg_name"
                fi
            fi
        done
        echo # 换行结束进度条
    }
    ret=${PIPESTATUS[0]}

    # 成功/失败的日志记录沿用原有逻辑
    if [ "$ret" -ne 0 ]; then
        log_error "$log_file" "$desc 失败 (退出码 $ret)"
        {
            echo "--- 命令输出开始 ---"
            cat "$tmp_out"
            echo "--- 命令输出结束 ---"
        } >>"$log_file"
    elif [ "${LOG_LEVEL:-$LOG_INFO}" -le "$LOG_DEBUG" ]; then
        log_debug "$log_file" "$desc 成功"
        {
            echo "--- 命令输出开始 ---"
            cat "$tmp_out"
            echo "--- 命令输出结束 ---"
        } >>"$log_file"
    else
        log_info "$log_file" "$desc 成功"
    fi
    rm -f "$tmp_out"
    return "$ret"
}

#===============================================================================
# 脚本入口
#===============================================================================
main "$@"
