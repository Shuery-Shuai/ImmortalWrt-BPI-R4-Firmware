#!/bin/bash
#===============================================================================
# 智能 PWM 风扇控制守护脚本
# 功能：根据 CPU 温度，使用三次贝塞尔曲线平滑调节 PWM 风扇转速，
#       实现散热与静音的平衡。自动发现 sysfs 接口，支持多种硬件。
# 用法：fan-control.sh
#       （由 init 系统调用，后台持续运行）
#
# 配置：
#   所有可调参数均位于脚本头部“可配置区”，无需修改主体逻辑。
#   也可通过环境变量临时覆盖。
#
# 环境变量：
#   LOG_LEVEL       日志详细程度 (0-3) [默认: 1]
#                     0 = 只记录错误/警告
#                     1 = 增加 PWM 变化和定期状态报告
#                     2 = 增加设备发现信息、启动详情
#                     3 = 增加调试信息
#   TEMP_PATH_CFG   强制指定温度传感器路径（例如 /sys/class/hwmon/hwmon0/temp1）
#   PWM_PATH_CFG    强制指定风扇 PWM 控制器路径（例如 /sys/class/hwmon/hwmon1/pwm1）
#   STATUS_FILE     状态文件路径，设为空可禁用 [默认: /var/run/fan_control.status]
#
# 返回值：
#   0   收到信号正常退出
#   1   设备初始化失败
#
# 说明：
#   - 必须以 root 权限运行，需要访问 /sys/class/hwmon 下的文件。
#   - 启动后会将风扇设为手动模式，退出时自动恢复自动模式。
#   - 支持毫摄氏度和摄氏度自动识别。
#   - 日志通过 logger 工具写入系统 syslog，标识为 FAN_CONTROL。
#
# 作者：Shuery-Shuai
# 日期：2026-07-24
# 版本：1.2.0
#===============================================================================

#===============================================================================
# 可配置区（可根据实际硬件修改）
#===============================================================================

LOGGER="/usr/bin/logger"
TAG="FAN_CONTROL"

# PWM 硬件范围
PWM_MIN=0
PWM_MAX=255

# 温度-风扇转速控制点（摄氏度）
TEMP_MIN=35  # 最低温度阈值，低于此温度保持 PWM_START
TEMP_MAX=75  # 最高温度阈值，高于此温度保持 PWM_END
PWM_START=30 # 最低转速百分比 (0-100)
PWM_END=100  # 最高转速百分比

# 温度单位设置
# 1000 = 毫摄氏度（多数 x86 平台），1 = 摄氏度（部分 ARM 平台）
# 0 表示自动检测（推荐）
TEMP_SCALE=1000
AUTO_SCALE=1 # 1=允许自动检测，0=强制使用 TEMP_SCALE

# 用户强制指定设备路径（取消注释并填写实际路径可跳过自动查找）
# TEMP_PATH_CFG="/sys/class/hwmon/hwmon0/temp1"
# PWM_PATH_CFG="/sys/class/hwmon/hwmon1/pwm1"

# 动态步进参数
STEP_SMALL=2      # 小步进值（温差小时平滑调节）
STEP_LARGE=5      # 大步进值（温差大时快速跟随）
STEP_THRESHOLD=20 # 目标 PWM 差距大于此值时使用大步进

# 日志与状态
LOG_LEVEL=${LOG_LEVEL:-1}                                 # 从环境变量读取，默认 1
LOG_INTERVAL=300                                          # 定期状态报告间隔（秒）
STATUS_FILE="${STATUS_FILE:-/var/run/fan_control.status}" # 状态文件路径

# 温度合理性校验范围（摄氏度）
TEMP_VALID_MIN=1
TEMP_VALID_MAX=120

#===============================================================================
# 全局变量（由脚本自动赋值，无需修改）
#===============================================================================
TEMP_PATH=""     # 温度传感器路径前缀（如 /sys/class/hwmon/hwmon0/temp1）
PWM_PATH=""      # PWM 控制器路径前缀（如 /sys/class/hwmon/hwmon1/pwm1）
current_pwm=0    # 当前 PWM 值
last_temp_err="" # 上次温度错误类型（用于错误去重）
last_pwm_err=""  # 上次 PWM 写入错误类型（用于错误去重）
last_log_time=0  # 上次完整状态报告的时间戳

#===============================================================================
# 函数：log_message
# 描述：根据日志级别向 syslog 输出消息，统一格式。
# 参数：
#   $1 - 优先级（err/warning/info/debug）
#   $2 - 消息文本
# 全局变量：
#   LOG_LEVEL - 设定的日志级别
#   TAG       - logger 标签
#   LOGGER    - logger 命令路径
#===============================================================================
log_message() {
    local level_str="$1"
    local message="$2"
    local level_num
    local priority

    case "$level_str" in
    err)
        level_num=0
        priority="daemon.err"
        ;;
    warning)
        level_num=1
        priority="daemon.warning"
        ;;
    info)
        level_num=2
        priority="daemon.info"
        ;;
    debug)
        level_num=3
        priority="daemon.debug"
        ;;
    *)
        level_num=1
        priority="daemon.notice"
        ;;
    esac

    if [ "$LOG_LEVEL" -ge "$level_num" ]; then
        $LOGGER -t "$TAG" -p "$priority" -- "$message"
    fi
}

#===============================================================================
# 函数：write_status_file
# 描述：将当前工作状态写入 STATUS_FILE，供外部程序监控。
# 参数：
#   $1 - 当前温度 (°C)
#   $2 - 当前 PWM 值
#   $3 - 当前百分比 (%)
#   $4 - 目标 PWM 值
#   $5 - 目标百分比 (%)
#===============================================================================
write_status_file() {
    if [ -n "$STATUS_FILE" ]; then
        printf 'temp=%d pwm=%d pct=%d target_pwm=%d target_pct=%d\n' \
            "$1" "$2" "$3" "$4" "$5" >"$STATUS_FILE" 2>/dev/null
    fi
}

#===============================================================================
# 函数：percent_to_pwm
# 描述：将百分比（0-100）线性映射为 PWM 硬件值。
# 参数：$1 - 百分比
# 返回：输出 PWM 值（整数）
#===============================================================================
percent_to_pwm() {
    local percent=$1
    [ "$percent" -lt 0 ] && percent=0
    [ "$percent" -gt 100 ] && percent=100
    echo $(((PWM_MAX - PWM_MIN) * percent / 100 + PWM_MIN))
}

#===============================================================================
# 函数：pwm_to_percent
# 描述：将 PWM 值反向映射为百分比。
# 参数：$1 - PWM 值
# 返回：输出百分比（0-100）
#===============================================================================
pwm_to_percent() {
    local pwm=$1
    [ "$pwm" -lt "$PWM_MIN" ] && pwm=$PWM_MIN
    [ "$pwm" -gt "$PWM_MAX" ] && pwm=$PWM_MAX
    echo $(((pwm - PWM_MIN) * 100 / (PWM_MAX - PWM_MIN)))
}

#===============================================================================
# 函数：calculate_curve_pwm
# 描述：使用三次贝塞尔曲线计算目标 PWM 值。
#       控制点固定为 P0(0,30), P1(0.25,40), P2(0.75,90), P3(1,100)。
#       在 TEMP_MIN 以下返回 PWM_START，TEMP_MAX 以上返回 PWM_END。
# 参数：$1 - 当前温度 (°C)
# 返回：输出目标 PWM 值（整数）
#===============================================================================
calculate_curve_pwm() {
    local temp=$1
    local t

    if [ "$temp" -le "$TEMP_MIN" ]; then
        percent_to_pwm "$PWM_START"
        return
    fi
    if [ "$temp" -ge "$TEMP_MAX" ]; then
        percent_to_pwm "$PWM_END"
        return
    fi

    # 温度映射到 0-1000（整数提高精度）
    t=$(((temp - TEMP_MIN) * 1000 / (TEMP_MAX - TEMP_MIN)))

    # 贝塞尔曲线计算（整型实现）
    local t2=$((t * t / 1000))
    local t3=$((t2 * t / 1000))
    local mt=$((1000 - t))
    local mt2=$((mt * mt / 1000))
    local mt3=$((mt2 * mt / 1000))

    local p1=$((PWM_START * mt3))
    local p2=$(((PWM_START + 10) * 3 * mt2 * t / 1000))
    local p3=$(((PWM_END - 10) * 3 * mt * t2 / 1000))
    local p4=$((PWM_END * t3))

    local percent=$(((p1 + p2 + p3 + p4) / 1000))
    percent_to_pwm "$percent"
}

#===============================================================================
# 函数：find_hwmon_paths
# 描述：自动发现 sysfs 中的温度传感器和 PWM 控制器。
#       优先使用环境变量 TEMP_PATH_CFG 和 PWM_PATH_CFG 指定的路径。
#       否则遍历 /sys/class/hwmon/hwmon*，根据 name 文件匹配已知驱动名。
# 全局变量：
#   TEMP_PATH_CFG, PWM_PATH_CFG - 用户指定的设备路径
#   TEMP_PATH, PWM_PATH         - 输出：设备路径前缀
# 返回值：0 成功，1 未找到所需设备
#===============================================================================
find_hwmon_paths() {
    # 如果用户已指定有效路径，直接使用
    if [ -n "$TEMP_PATH_CFG" ] && [ -r "${TEMP_PATH_CFG}_input" ] &&
        [ -n "$PWM_PATH_CFG" ] && [ -w "$PWM_PATH_CFG" ]; then
        TEMP_PATH="$TEMP_PATH_CFG"
        PWM_PATH="$PWM_PATH_CFG"
        log_message info "使用用户指定的设备: 温度=${TEMP_PATH}, 风扇=${PWM_PATH}"
        return 0
    fi

    local found_temp=0
    local found_pwm=0
    local hwmon name

    for hwmon in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon" ] || continue

        # 查找温度传感器：优先匹配已知驱动名，否则使用第一个可用设备
        if [ "$found_temp" -eq 0 ] && [ -r "$hwmon/temp1_input" ]; then
            if [ -r "$hwmon/name" ]; then
                name=$(cat "$hwmon/name")
                case "$name" in
                # 按精确度从高到低排列，避免宽泛模式覆盖具体模式
                *coretemp* | *k10temp* | *soc* | *cpu_thermal* | *thermal* | *cpu*)
                    TEMP_PATH="$hwmon/temp1"
                    found_temp=1
                    log_message info "找到温度传感器: $TEMP_PATH (name: $name)"
                    ;;
                esac
            fi
            # 若未通过 name 匹配但设备可用，将其作为后备
            if [ "$found_temp" -eq 0 ]; then
                TEMP_PATH="$hwmon/temp1"
                found_temp=1
                log_message info "使用通用温度传感器: $TEMP_PATH (无名称匹配)"
            fi
        fi

        # 查找 PWM 控制器：类似逻辑
        if [ "$found_pwm" -eq 0 ] && [ -w "$hwmon/pwm1" ]; then
            if [ -r "$hwmon/name" ]; then
                name=$(cat "$hwmon/name")
                case "$name" in
                *pwm* | *fan* | *nct* | *it87*)
                    PWM_PATH="$hwmon/pwm1"
                    found_pwm=1
                    log_message info "找到风扇控制器: $PWM_PATH (name: $name)"
                    ;;
                esac
            fi
            if [ "$found_pwm" -eq 0 ]; then
                PWM_PATH="$hwmon/pwm1"
                found_pwm=1
                log_message info "使用通用风扇控制器: $PWM_PATH"
            fi
        fi

        [ "$found_temp" -eq 1 ] && [ "$found_pwm" -eq 1 ] && break
    done

    if [ "$found_temp" -eq 0 ] || [ "$found_pwm" -eq 0 ]; then
        log_message err "未找到必要的温度传感器或风扇控制器"
        return 1
    fi
    return 0
}

#===============================================================================
# 函数：check_files
# 描述：等待硬件就绪，验证文件可访问，并自动检测温度单位。
#       最多等待 30 秒，首次读到有效温度后根据数值范围决定 TEMP_SCALE。
# 全局变量：
#   TEMP_PATH, PWM_PATH - 设备路径前缀
#   TEMP_SCALE          - 输入/输出：温度单位除数
#   AUTO_SCALE          - 是否进行自动检测
# 返回值：0 成功，1 超时或失败
#===============================================================================
check_files() {
    local waited=0
    local test_temp

    while [ "$waited" -lt 30 ]; do
        # 检查文件存在性与权限
        if [ ! -e "$PWM_PATH" ] || [ ! -w "$PWM_PATH" ]; then
            log_message info "PWM 文件不可写: $PWM_PATH，等待..."
            sleep 1
            waited=$((waited + 1))
            continue
        fi
        if [ ! -e "${TEMP_PATH}_input" ] || [ ! -r "${TEMP_PATH}_input" ]; then
            log_message info "温度文件不可读: ${TEMP_PATH}_input，等待..."
            sleep 1
            waited=$((waited + 1))
            continue
        fi

        # 读取温度
        test_temp=$(cat "${TEMP_PATH}_input" 2>/dev/null)
        if [ -z "$test_temp" ] || ! [ "$test_temp" -eq "$test_temp" ] 2>/dev/null; then
            log_message info "温度值无效，等待..."
            sleep 1
            waited=$((waited + 1))
            continue
        fi

        # 自动检测温度单位
        if [ "$AUTO_SCALE" -eq 1 ]; then
            # 毫摄氏度通常远大于 200，摄氏度通常小于 200
            if [ "$test_temp" -gt 0 ] && [ "$test_temp" -le 200 ]; then
                TEMP_SCALE=1
                log_message info "检测到温度单位为摄氏度 (读值: ${test_temp})"
            elif [ "$test_temp" -gt 200 ]; then
                TEMP_SCALE=1000
                log_message info "检测到温度单位为毫摄氏度 (读值: ${test_temp})"
            else
                log_message warning "温度单位无法自动判断，维持 TEMP_SCALE=${TEMP_SCALE}"
            fi
            AUTO_SCALE=0
        fi

        # 验证转换后的温度是否合理
        local temp_c=$((test_temp / TEMP_SCALE))
        if [ "$temp_c" -ge "$TEMP_VALID_MIN" ] && [ "$temp_c" -le "$TEMP_VALID_MAX" ]; then
            log_message info "设备就绪，当前温度: ${temp_c}°C"
            return 0
        fi

        log_message info "温度值不合理 (${temp_c}°C)，等待有效值..."
        sleep 1
        waited=$((waited + 1))
    done

    log_message err "设备准备超时，请检查硬件和驱动"
    return 1
}

#===============================================================================
# 函数：restore_fan_auto
# 描述：退出脚本时尝试将风扇控制恢复为自动模式，
#       并清空状态文件。由 trap 调用。
# 全局变量：PWM_PATH, STATUS_FILE
#===============================================================================
restore_fan_auto() {
    local mode
    for mode in 2 0; do
        echo $mode >"${PWM_PATH}_enable" 2>/dev/null && break
    done
    log_message info "脚本退出，已尝试恢复风扇自动控制"
    write_status_file 0 0 0 0 0
}

#===============================================================================
# 主函数
#===============================================================================
main() {
    sleep 5 # 等待系统完全启动

    # 查找设备
    if ! find_hwmon_paths; then
        exit 1
    fi

    # 设置退出陷阱，确保恢复自动模式
    trap 'restore_fan_auto' EXIT

    # 等待设备就绪
    if ! check_files; then
        exit 1
    fi

    # 设置手动控制模式
    if [ -w "${PWM_PATH}_enable" ]; then
        echo 1 >"${PWM_PATH}_enable" 2>/dev/null
        log_message info "风扇控制已设为手动模式"
    else
        log_message warning "无法设置手动模式 (pwm1_enable 不可写)，某些驱动可能固定为手动模式"
    fi

    # 初始化 PWM 为起始值
    current_pwm=$(percent_to_pwm "$PWM_START")
    if ! printf '%d' "$current_pwm" >"$PWM_PATH" 2>/dev/null; then
        log_message err "无法设置初始 PWM 值，退出"
        exit 1
    fi
    log_message info "风扇控制启动成功 (PWM范围: ${PWM_MIN}-${PWM_MAX}, 温度区间: ${TEMP_MIN}°C-${TEMP_MAX}°C)"

    # 初始化日志去重变量
    last_temp_err=""
    last_pwm_err=""
    last_log_time=$(date +%s)

    # 主控制循环
    while true; do
        local current_time
        current_time=$(date +%s)

        # ---------- 读取温度 ----------
        local temp_raw
        temp_raw=$(cat "${TEMP_PATH}_input" 2>/dev/null)
        local temp_read_ok=$?

        if [ $temp_read_ok -ne 0 ] || [ -z "$temp_raw" ] || ! [ "$temp_raw" -eq "$temp_raw" ] 2>/dev/null; then
            if [ "$last_temp_err" != "read" ]; then
                log_message err "无法读取温度传感器数据"
                last_temp_err="read"
            fi
            sleep 5
            continue
        else
            if [ "$last_temp_err" = "read" ]; then
                log_message info "温度传感器读数恢复正常"
                last_temp_err=""
            fi
        fi

        local temp_c=$((temp_raw / TEMP_SCALE))

        # ---------- 温度合理性校验 ----------
        if [ "$temp_c" -lt "$TEMP_VALID_MIN" ] || [ "$temp_c" -gt "$TEMP_VALID_MAX" ]; then
            if [ "$last_temp_err" != "range" ]; then
                log_message warning "温度读数异常: ${temp_c}°C，忽略本次采样"
                last_temp_err="range"
            fi
            sleep 1
            continue
        else
            if [ "$last_temp_err" = "range" ]; then
                log_message info "温度读数回到正常范围"
                last_temp_err=""
            fi
        fi

        # ---------- 计算目标 PWM ----------
        local target_pwm
        target_pwm=$(calculate_curve_pwm "$temp_c")
        local target_percent
        target_percent=$(pwm_to_percent "$target_pwm")

        # ---------- 动态步进与平滑过渡 ----------
        local diff=$((target_pwm - current_pwm))
        [ $diff -lt 0 ] && diff=$((-diff))

        local step
        if [ $diff -ge $STEP_THRESHOLD ]; then
            step=$STEP_LARGE
        else
            step=$STEP_SMALL
        fi

        local last_pwm=$current_pwm
        if [ "$current_pwm" -lt "$target_pwm" ]; then
            current_pwm=$((current_pwm + step))
            [ "$current_pwm" -gt "$target_pwm" ] && current_pwm="$target_pwm"
        elif [ "$current_pwm" -gt "$target_pwm" ]; then
            current_pwm=$((current_pwm - step))
            [ "$current_pwm" -lt "$target_pwm" ] && current_pwm="$target_pwm"
        fi

        # 边界保护
        [ "$current_pwm" -lt $PWM_MIN ] && current_pwm=$PWM_MIN
        [ "$current_pwm" -gt $PWM_MAX ] && current_pwm=$PWM_MAX

        # ---------- 写入 PWM ----------
        if ! printf '%d' "$current_pwm" >"$PWM_PATH" 2>/dev/null; then
            if [ "$last_pwm_err" != "write" ]; then
                log_message err "写入 PWM 失败: ${current_pwm}"
                last_pwm_err="write"
            fi
            sleep 5
            continue
        else
            if [ "$last_pwm_err" = "write" ]; then
                log_message info "PWM 写入恢复正常"
                last_pwm_err=""
            fi
        fi

        local current_percent
        current_percent=$(pwm_to_percent "$current_pwm")

        # ---------- 日志输出 ----------
        if [ "$current_pwm" -ne "$last_pwm" ]; then
            log_message info "event=pwm_change temp=${temp_c} pwm=${current_pwm} pct=${current_percent} target=${target_pwm} target_pct=${target_percent}"
        fi

        if [ $((current_time - last_log_time)) -ge $LOG_INTERVAL ]; then
            log_message info "event=status_report temp=${temp_c} pwm=${current_pwm} pct=${current_percent} target=${target_pwm} target_pct=${target_percent}"
            last_log_time=$current_time
        fi

        # 更新状态文件
        write_status_file "$temp_c" "$current_pwm" "$current_percent" "$target_pwm" "$target_percent"

        sleep 1
    done
}

# 启动主函数
main "$@"
