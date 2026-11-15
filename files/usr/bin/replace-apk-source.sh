#!/bin/bash
# uci-defaults 脚本：根据官方源可用性，决定使用官方源或镜像源
# 如果官方源网络状况良好，确保使用官方源；否则替换为镜像源
#
# 另外会逐个探测 feeds 中的源行：
#   · 返回 404 的源 = 该路径在服务器上已不存在（rsync 未同步、软件包被移除等），
#     属于永久性失效，保留它只会让 apk/opkg 每次 update 都重试并报错，因此注释掉；
#   · 仅注释 404，其他状态（超时/000/5xx/403）一律视为临时故障原样保留，
#     避免一次网络抖动就永久废掉一个本来可用的源；
#   · 被注释的行统一加 "# 404: " 前缀，原始 URL 完整保留，可随时手工还原；
#   · 本脚本此前注释掉、如今又能正常访问的源会自动恢复（只认这个前缀，
#     不会动用户自己写的注释）。
#
# 环境变量：
#   LOG_TO_SYSLOG  1=同时写入 syslog（默认 0）
#   COMMENT_404    1=启用 404 源注释逻辑，0=完全关闭（默认 1）
#   DRY_RUN        1=只记录将要修改的内容，不写回文件（默认 0）
#   STATUS_TIMEOUT 单个源行的状态探测超时秒数（默认 8）
#   FEEDS_FILES    覆盖待处理的 feeds 文件列表（默认由包管理器决定，便于测试）

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

# 404 探测相关配置
# DEAD_PREFIX 会被同时用作 sed 的「替换串」和「正则」，因此不能包含 | & \ 等元字符。
DEAD_STATUS="404"
DEAD_PREFIX="# 404: "
STATUS_TIMEOUT="${STATUS_TIMEOUT:-8}"
COMMENT_404="${COMMENT_404:-1}"
DRY_RUN="${DRY_RUN:-0}"

# 自动检测包管理器并设置配置文件列表
# 显式传入 FEEDS_FILES 时不再要求系统装有 apk/opkg：这台机器只负责改写这些文件，
# 生产路径（不传该变量）的行为与之前完全一致。
if [ -n "${FEEDS_FILES:-}" ]; then
    log INFO "Using FEEDS_FILES from environment: $FEEDS_FILES"
else
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

# 探测单个 URL 的 HTTP 状态码
# 输出：三位状态码；无法判定时输出 000（000 永远不会被当作 404 处理）
check_url_status() {
    local url="$1"
    local status=""

    if command -v curl >/dev/null 2>&1; then
        status=$(curl -L -I -o /dev/null -s -w "%{http_code}" --max-time "$STATUS_TIMEOUT" "$url" 2>/dev/null) || status=""
        case "$status" in
        400 | 405 | 501)
            # 部分服务器不支持 HEAD，退回「只取首字节」的 GET 再判一次
            status=$(curl -L -r 0-0 -o /dev/null -s -w "%{http_code}" --max-time "$STATUS_TIMEOUT" "$url" 2>/dev/null) || status=""
            ;;
        esac
    elif command -v wget >/dev/null 2>&1; then
        # busybox wget 没有 -w %{http_code}，只能从 -S 打印的响应头里取状态码
        status=$(wget --spider -S -O /dev/null --timeout="$STATUS_TIMEOUT" --tries=1 "$url" 2>&1 |
            awk '/^[[:space:]]*HTTP\// { code = $2 } END { if (code != "") print code }') || status=""
    fi

    case "$status" in
    [0-9][0-9][0-9]) printf '%s' "$status" ;;
    *) printf '000' ;;
    esac
}

# 列出文件中「生效中」的源行（跳过注释与空行）
# 输出：每行 "<行号> <URL>"
collect_source_lines() {
    local feed="$1"

    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*https?:\/\// {
            url = $0
            sub(/[[:space:]]+$/, "", url)
            printf "%d %s\n", NR, url
        }
    ' "$feed" 2>/dev/null || true
}

# 列出本脚本此前注释掉的源行（带 DEAD_PREFIX 标记，用户自己的注释不会被选中）
# 输出：每行 "<行号> <URL>"
collect_marked_lines() {
    local feed="$1"

    awk -v prefix="$DEAD_PREFIX" '
        index($0, prefix) == 1 {
            url = substr($0, length(prefix) + 1)
            sub(/[[:space:]]+$/, "", url)
            if (url ~ /^https?:\/\//) printf "%d %s\n", NR, url
        }
    ' "$feed" 2>/dev/null || true
}

# 并行探测一组源行的状态，结果写入指定文件
# 参数：$1 源行清单（"<行号> <URL>"，每行一条）  $2 结果文件
# 输出：结果文件每行 "<行号> <状态码>"
probe_source_lines() {
    local list_file="$1"
    local result_file="$2"
    local line_no url

    : >"$result_file"
    while read -r line_no url; do
        [ -n "$line_no" ] || continue
        [ -n "$url" ] || continue
        # 每个源行一个后台任务：feeds 里常有十几行，串行探测会把启动时间拖到分钟级
        (
            printf '%s %s\n' "$line_no" "$(check_url_status "$url")" >>"$result_file"
        ) &
    done <"$list_file"
    wait || true
}

# 给指定行号加上 404 注释前缀
# 参数：$1 文件  $2 行号列表（空格分隔）
# 说明：只在本行行首插入前缀，不增删行，因此多条行号可一次性改完
comment_lines() {
    local feed="$1"
    local line_numbers="$2"
    local line_no
    local -a sed_args=()

    for line_no in $line_numbers; do
        sed_args+=(-e "${line_no}s|^|${DEAD_PREFIX}|")
    done

    if sed -i "${sed_args[@]}" "$feed" 2>/dev/null; then
        return 0
    fi
    log ERROR "Failed to comment out 404 sources in $feed"
    return 1
}

# 去掉指定行号上的 404 注释前缀（源恢复时使用）
# 参数：$1 文件  $2 行号列表（空格分隔）
uncomment_lines() {
    local feed="$1"
    local line_numbers="$2"
    local line_no
    local -a sed_args=()

    for line_no in $line_numbers; do
        sed_args+=(-e "${line_no}s|^${DEAD_PREFIX}||")
    done

    if sed -i "${sed_args[@]}" "$feed" 2>/dev/null; then
        return 0
    fi
    log ERROR "Failed to re-enable sources in $feed"
    return 1
}

# 处理单个 feeds 文件：注释掉返回 404 的源，恢复此前注释但已恢复的源
# 参数：$1 feeds 文件路径
# 返回：恒为 0（单个文件出问题不应影响其他文件）
process_feed_file() {
    local feed="$1"
    local lines_file status_file
    local line_no status url
    local dead_lines="" revive_lines=""
    local dead_count=0 revive_count=0

    [ -f "$feed" ] || return 0

    lines_file=$(mktemp -t uci-feeds.XXXXXX) || return 0
    status_file=$(mktemp -t uci-status.XXXXXX) || {
        rm -f "$lines_file"
        return 0
    }

    # ---- 1. 生效中的源：探测状态，收集 404 的行号 ----
    collect_source_lines "$feed" >"$lines_file"
    if [ -s "$lines_file" ]; then
        probe_source_lines "$lines_file" "$status_file"
        while read -r line_no status; do
            [ -n "$line_no" ] || continue
            [ "$status" = "$DEAD_STATUS" ] || continue
            url=$(sed -n "${line_no}p" "$feed" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            log WARN "Source returns $DEAD_STATUS, commenting out: $url"
            dead_lines="$dead_lines $line_no"
            dead_count=$((dead_count + 1))
        done <"$status_file"
    fi

    # ---- 2. 本脚本此前注释掉的源：探测是否已经恢复 ----
    collect_marked_lines "$feed" >"$lines_file"
    if [ -s "$lines_file" ]; then
        probe_source_lines "$lines_file" "$status_file"
        while read -r line_no status; do
            [ -n "$line_no" ] || continue
            case "$status" in
            2[0-9][0-9]) ;;
            *) continue ;;
            esac
            url=$(sed -n "${line_no}p" "$feed" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            log INFO "Source is reachable again (HTTP $status), re-enabling: $url"
            revive_lines="$revive_lines $line_no"
            revive_count=$((revive_count + 1))
        done <"$status_file"
    fi

    # ---- 3. 写回：先恢复、再注释（两组行号分属注释行与生效行，互不重叠）----
    if [ "$revive_count" -gt 0 ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log INFO "[dry-run] would re-enable $revive_count source(s) in $feed:$revive_lines"
        elif uncomment_lines "$feed" "$revive_lines"; then
            log INFO "Re-enabled $revive_count source(s) in $feed"
        fi
    fi

    if [ "$dead_count" -gt 0 ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log INFO "[dry-run] would comment out $dead_count source(s) in $feed:$dead_lines"
        elif comment_lines "$feed" "$dead_lines"; then
            log INFO "Commented out $dead_count dead source(s) in $feed"
        fi
    fi

    rm -f "$lines_file" "$status_file"

    # ---- 4. 兜底：一个可用源都不剩时必须大声警告 ----
    if [ "$(collect_source_lines "$feed" | wc -l | tr -d ' ')" = "0" ]; then
        log WARN "No active sources left in $feed, package installation will fail"
    fi
    return 0
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

# 处理 404 失效源（放在替换之后：此时探测到的才是最终会被使用的 URL）
if [ "$COMMENT_404" = "1" ]; then
    log INFO "Checking feeds for sources returning $DEAD_STATUS"
    for feed in $FEEDS_FILES; do
        process_feed_file "$feed"
    done
else
    log INFO "404 source check disabled (COMMENT_404=$COMMENT_404)"
fi

log INFO "Source optimization finished"
exit 0
