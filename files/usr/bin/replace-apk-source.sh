#!/bin/sh
# uci-defaults 脚本：根据官方源可用性，决定使用官方源或镜像源
# 如果官方源网络状况良好，确保使用官方源；否则替换为镜像源

set -e

# 日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >&2
    if [ "${LOG_TO_SYSLOG:-0}" = "1" ]; then
        command -v logger >/dev/null 2>&1 && logger -t "uci-sources" "$level: $message"
    fi
    return 0
}

# 常量
OPENWRT_OFFICIAL="https://downloads.openwrt.org"
OPENWRT_OFFICIAL_PATTERN="https\?://downloads\.openwrt\.org"
OPENWRT_MIRROR="https://mirrors.ustc.edu.cn/openwrt"
OPENWRT_MIRROR_PATTERN="https\?://mirrors\.ustc\.edu\.cn/openwrt"

IMMORTALWRT_OFFICIAL="https://downloads.immortalwrt.org"
IMMORTALWRT_OFFICIAL_PATTERN="https\?://downloads\.immortalwrt\.org"
IMMORTALWRT_MIRROR="https://immortalwrt.kyarucloud.moe"
IMMORTALWRT_MIRROR_PATTERN="https\?://immortalwrt\.kyarucloud\.moe"

MAX_LATENCY=2.0
MIN_SPEED=50000

# 自动检测包管理器并设置配置文件列表
if command -v apk >/dev/null 2>&1; then
    FEEDS_FILES="/etc/apk/repositories.d/distfeeds.list /etc/apk/repositories"
    log INFO "Detected APK package manager"
elif command -v opkg >/dev/null 2>&1; then
    FEEDS_FILES="/etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf"
    log INFO "Detected opkg package manager"
else
    log ERROR "No known package manager found"
    exit 1
fi

# 检查 URL 延迟和速度
check_url() {
    local url="$1"
    local latency speed result ret
    local tmp_file

    if command -v curl >/dev/null 2>&1; then
        tmp_file=$(mktemp -t uci-check.XXXXXX)
        result=$(curl -L -I --max-time 10 -s -w "%{time_total} %{speed_download}" -o "$tmp_file" "$url" 2>/dev/null)
        ret=$?
        rm -f "$tmp_file"
        if [ $ret -eq 0 ]; then
            latency=$(printf "%s" "$result" | awk '{print $1}')
            speed=$(printf "%s" "$result" | awk '{print $2}')
            if [ -n "$latency" ] && [ "$latency" != "0" ]; then
                printf "%s %s\n" "$latency" "$speed"
                return 0
            fi
        fi
        return 1
    elif command -v wget >/dev/null 2>&1; then
        local start_ms end_ms
        start_ms=$(date +%s%3N)
        wget --spider --timeout=10 --tries=1 -q "$url" >/dev/null 2>&1
        ret=$?
        end_ms=$(date +%s%3N)
        if [ $ret -eq 0 ]; then
            latency=$(awk "BEGIN {printf \"%.3f\", ($end_ms - $start_ms) / 1000}")
            printf "%s 0\n" "$latency"
            return 0
        fi
        return 1
    else
        return 1
    fi
}

# 判断是否需要替换：返回 0=不需要替换（官方源可用），1=需要替换（官方源不可用或性能差）
should_replace() {
    local official_url="$1"
    local metrics latency speed

    log INFO "Testing connectivity to $official_url"
    metrics=$(check_url "$official_url") || {
        log WARN "Cannot reach $official_url, will replace"
        return 1
    }
    latency=$(printf "%s" "$metrics" | awk '{print $1}')
    speed=$(printf "%s" "$metrics" | awk '{print $2}')
    log INFO "Latency: ${latency}s, Speed: ${speed:-unknown} B/s"

    [ -z "$latency" ] || [ "$latency" = "0" ] && {
        log WARN "Invalid latency from $official_url, will replace"
        return 1
    }

    if awk "BEGIN {exit ($latency > $MAX_LATENCY) ? 0 : 1}"; then
        log INFO "Latency ${latency}s exceeds threshold ${MAX_LATENCY}s, will replace"
        return 1
    fi

    if [ -n "$speed" ] && [ "$speed" != "0" ] && awk "BEGIN {exit ($speed < $MIN_SPEED) ? 0 : 1}"; then
        log INFO "Speed ${speed}B/s below threshold ${MIN_SPEED}B/s, will replace"
        return 1
    fi

    log INFO "$official_url is acceptable (latency ${latency}s, speed ${speed}B/s)"
    return 0
}

# 替换源：将匹配 pattern 的 URL 替换为 target
replace_source() {
    local pattern="$1"
    local target="$2"
    local feed

    for feed in $FEEDS_FILES; do
        [ -f "$feed" ] || continue
        log INFO "Replacing $pattern with $target in $feed"
        sed -i "s#${pattern}#${target}#g" "$feed"
    done
    log INFO "Source replacement completed for pattern $pattern"
}

# 主流程
log INFO "Starting source optimization"

# 处理 OpenWrt 官方源
if should_replace "$OPENWRT_OFFICIAL"; then
    # 官方源可用：确保配置文件中的源是官方源（替换镜像源为官方源）
    log INFO "OpenWrt official source is acceptable, ensuring official source is used"
    replace_source "$OPENWRT_MIRROR_PATTERN" "$OPENWRT_OFFICIAL"
else
    # 官方源不可用：替换为镜像源
    log INFO "OpenWrt official source needs replacement, switching to mirror"
    replace_source "$OPENWRT_OFFICIAL_PATTERN" "$OPENWRT_MIRROR"
fi

# 处理 ImmortalWrt 官方源
if should_replace "$IMMORTALWRT_OFFICIAL"; then
    log INFO "ImmortalWrt official source is acceptable, ensuring official source is used"
    replace_source "$IMMORTALWRT_MIRROR_PATTERN" "$IMMORTALWRT_OFFICIAL"
else
    log INFO "ImmortalWrt official source needs replacement, switching to mirror"
    replace_source "$IMMORTALWRT_OFFICIAL_PATTERN" "$IMMORTALWRT_MIRROR"
fi

log INFO "Source optimization finished"
exit 0