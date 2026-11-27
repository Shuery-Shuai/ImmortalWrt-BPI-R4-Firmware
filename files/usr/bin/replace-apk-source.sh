#!/bin/bash
# 软件源体检脚本：注释掉取不到索引的源，并测量当前源的下载速率。
#
# 处理范围：**只处理 distfeeds.list**（发行版分发的官方源）。
#   customfeeds.list 属于用户（本仓库的 Pages 自建源写在那里），本脚本从不读写它——
#   它的地址对不对、要不要换，用户自己说了算，脚本无从判断。
#
# 触发时机：重启后首次接通 WAN 网络时执行一次（见 hotplug iface/88-replace-apk-source）。
#
# 三件事，按顺序：
#   1. 测速：删缓存 → 计时 apk update → 用缓存增量算当前源的真实速率；
#   2. 换源：在**同一套**镜像池里挑最快的，且需比当前快 SWITCH_GAIN_RATIO 倍以上（默认 1.5）；
#      OpenWrt 与 ImmortalWrt 的仓库内容不同，绝不跨套替换；
#   3. 注释：换完之后再判定哪些源取不到索引，注释作用在**最终地址**上。
#
# 顺序不能颠倒：
#   · 先注释再换源，被注释行里的旧 URL 会被 sed 一起改掉，
#     "# 404: https://旧源/..." 变成 "# 404: https://新源/..."，
#     那行失效记录就指向了一个其实可用的地址，下次无法正确恢复；
#   · 测速必须在换源之前，否则没有比较基准。
#
# 换源门槛（默认 1.5 倍）是刻意的：两个镜像都能用时来回换，
# 每次改动都触发索引重下，比一直用慢的那个更糟。
#
# 每个镜像每次运行只实测一次，单次样本噪声很大（实测同一对镜像的比值在
# 1.48~1.56 之间波动）。因此镜像池刻意保持精简：池子越大，"挑最快的"
# 越接近掷骰子。只保留少量可靠镜像，而不是把知道的都堆进来。
#
# 用 apk update 实测 feeds 中的源：
#   · 判定依据是 apk 自己的失败输出，而不是脚本另发的 HTTP 请求——
#     固件不一定带 curl/wget，HEAD 探测与 apk 取索引的真实行为也不等价；
#   · apk 报 "updating and opening <URL>" 的源即无法取到索引，注释掉；
#   · 被注释的行统一加 "# 404: " 前缀，原始 URL 完整保留，可随时手工还原；
#   · 本脚本此前注释掉、如今又能取到索引的源会自动恢复（只认这个前缀，
#     不会动用户自己写的注释）。
#
# 依赖：需要可执行的 apk（opkg 系统上本段逻辑不生效，只做镜像替换）。
#
# 环境变量：
#   LOG_TO_SYSLOG  1=同时写入 syslog（默认 0）
#   COMMENT_404    1=启用失效源注释逻辑，0=完全关闭（默认 1）
#   DRY_RUN        1=只记录将要修改的内容，不写回文件（默认 0）
#   SKIP_SPEED_TEST 1=跳过测速（默认 0；测速会清空索引缓存并重新下载）
#   MIN_SPEED      速率阈值（字节/秒，默认 50000）；低于它只记 WARN
#   SWITCH_GAIN_RATIO 候选需比当前快多少倍才换（默认 1.5）
#   SKIP_MIRROR_SWITCH 1=只测速不换源（默认 0）
#   FEEDS_FILES    覆盖待处理的 feeds 文件（默认 distfeeds，便于测试）

# 与 restore-packages.sh 保持一致：
#   -e 任何命令失败即退出（避免半途而废留下半改的 feeds）
#   -u 引用未定义变量即退出（本脚本曾因 $status_file 拼错而静默跳过清理）
#   -o pipefail 管道中任一环失败即失败（如 apk | awk，不能只看末段状态）
set -euo pipefail

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

# 速率阈值（字节/秒）：低于它时只记 WARN，不自动换源
#   50 KB/s ≈ 索引 1.5MB 需要 30 秒，是"能装但慢"的分界。
#   按需用环境变量覆盖：MIN_SPEED=200000 ./replace-apk-source.sh
MIN_SPEED="${MIN_SPEED:-50000}"

# 404 探测相关配置
# DEAD_PREFIX 会被同时用作 sed 的「替换串」和「正则」，因此不能包含 | & \ 等元字符。
# 前缀里的 "404" 只是历史沿用：现在判据是 apk 能否取到索引，
# 不再区分 404/连接失败，但保留这个易识别的标记，便于用户手工 grep 与还原。
DEAD_PREFIX="# 404: "

# 「上次确认仍不可用」的 URL 缓存。
#
# 为什么需要它：恢复判定要跑一轮完整的 apk update（约 25-30 秒，因为每个
# 失效源都要等超时）。而失效源往往长期失效——同一个 video 源 404 了几周，
# 每次开机都白等 30 秒毫无意义。
# 这里记住上次的结论，下次开机先用它判断，只有缓存缺失时才真去试。
#
# 放在 /tmp（tmpfs）：重启即失效，因此"跳过"最多跨一次运行，
# 不会让一个其实是临时故障的源被永久忽略。
DEAD_CACHE="/tmp/.apk-source-dead-urls"
COMMENT_404="${COMMENT_404:-1}"
DRY_RUN="${DRY_RUN:-0}"

# 自动检测包管理器并设置配置文件列表
# 显式传入 FEEDS_FILES 时不再要求系统装有 apk/opkg：这台机器只负责改写这些文件，
# 生产路径（不传该变量）的行为与之前完全一致。
if [ -n "${FEEDS_FILES:-}" ]; then
    log INFO "Using FEEDS_FILES from environment: $FEEDS_FILES"
else
    if command -v apk >/dev/null 2>&1; then
        # 只处理 distfeeds.list（发行版分发的官方源）。
        #
        # customfeeds.list 是**用户自己的**源（本仓库的 Pages 自建源就写在那里），
        # 本脚本既不注释它也不改写它：
        #   · 它的地址与可用性由用户负责，脚本无从判断"什么才是正确地址"；
        #   · 一旦误改，用户失去的是唯一的手工配置入口，而且改坏了没法自动恢复。
        # 因此这里刻意不列 customfeeds.list，也别"顺手"加回来。
        FEEDS_FILES="${APK_DISTFEEDS:-/etc/apk/repositories.d/distfeeds.list}"
        log INFO "Detected APK package manager (distfeeds only: $FEEDS_FILES)"
    elif command -v opkg >/dev/null 2>&1; then
        # 同上：opkg 的 customfeeds.conf 同样属于用户，不碰。
        FEEDS_FILES="${APK_DISTFEEDS:-/etc/opkg/distfeeds.conf}"
        log INFO "Detected opkg package manager"
    else
        log ERROR "No known package manager found"
        exit 1
    fi
fi

# 候选镜像：distfeeds 里出现这些域名时，可用另一个替换。
#
# ── 镜像池 ──
#
# 两套镜像分开登记：OpenWrt 与 ImmortalWrt 的仓库内容不同，
# 混用会装到错误的软件包（同一个包在两边的版本、依赖都可能不一样）。
# 因此脚本只会在**同一套**里找替代，绝不跨套替换。
#
# 数组元素是**到 snapshots 那一层为止**的完整前缀，不含 targets/ 与 packages/：
#   少了这一层（只写域名），拼出的 URL 会少一截、全部 404，
#   候选被误判成"不可用"——本脚本最初就是这么误报的。
#
# ⚠ 不要凭印象往里加：所有条目都必须在设备上实测过能拉取整套索引。
#   行尾注释是 2026-11 的三次平均实测（整套 7 个索引共 4.2MB）。
#   注释只为说明速度量级，不参与运行；数组里只有 URL。
# 每个镜像每次运行只实测一次，单次样本噪声很大（实测同一对镜像的比值
# 在 1.48~1.56 之间波动）。镜像多了会让"比谁快"变成掷骰子，因此只保留
# 少量、地理上分散的可靠镜像，而不是把知道的都堆进来。
OPENWRT_MIRRORS=(
    "https://downloads.openwrt.org/snapshots"          # 157 KB/s
    "https://mirrors.ustc.edu.cn/openwrt/snapshots"    # 130 KB/s
)

IMMORTALWRT_MIRRORS=(
    "https://downloads.immortalwrt.org/snapshots"      # 105 KB/s
    "https://mirrors.vsean.net/openwrt/snapshots"      # 442 KB/s（mesa）
    "https://immortalwrt.kyarucloud.moe/snapshots"     #  84 KB/s
)

# 从 distfeeds 反推当前正在使用的镜像前缀（必须是镜像池里的某一个）
# 输出：匹配到的前缀；没有匹配输出空串
current_mirror_prefix() {
    local feed entry
    for feed in $FEEDS_FILES; do
        [ -f "$feed" ] || continue
        for entry in "${OPENWRT_MIRRORS[@]}" "${IMMORTALWRT_MIRRORS[@]}"; do
            [ -n "$entry" ] || continue
            if grep -qF -- "$entry" "$feed" 2>/dev/null; then
                printf '%s' "$entry"
                return 0
            fi
        done
    done
    printf ''
    return 0
}

# 判定某个前缀属于哪一套：输出 "openwrt" / "immortalwrt" / 空（认不出）
#
# 为什么用显式分组而不是猜域名：vsean 的路径里带 openwrt，但它提供的是
# ImmortalWrt 的快照（仓库内容由 ImmortalWrt 构建产出），按关键字归类会分错。
mirror_set_of() {
    local want="$1" entry
    for entry in "${OPENWRT_MIRRORS[@]}"; do
        [ "$entry" = "$want" ] && { printf 'openwrt'; return 0; }
    done
    for entry in "${IMMORTALWRT_MIRRORS[@]}"; do
        [ "$entry" = "$want" ] && { printf 'immortalwrt'; return 0; }
    done
    printf ''
    return 0
}

# 列出某一套镜像的全部前缀
mirrors_of_set() {
    local pool="$1" entry
    case "$pool" in
    openwrt)
        for entry in "${OPENWRT_MIRRORS[@]}"; do printf '%s\n' "$entry"; done
        ;;
    immortalwrt)
        for entry in "${IMMORTALWRT_MIRRORS[@]}"; do printf '%s\n' "$entry"; done
        ;;
    esac
}

# 测量某个"源前缀"下整套 distfeeds 的下载速率
#
# 用 --cache-dir 指向独立目录：测候选源时不污染系统缓存，
# 测完删掉即可，不会让下一次 apk add 用到半个索引。
#
# 参数：$1 源前缀（如 https://downloads.immortalwrt.org/snapshots）
# 输出：stdout "<字节每秒> <耗时秒> <下载字节数>"；失败时 "0 0 0"
measure_prefix_speed() {
    local base="$1"
    local arch tgt cache t1 t2 kb list

    [ -r /proc/uptime ] || { printf '0 0 0'; return 0; }

    arch=$(get_apk_arch)
    # distfeeds 里的 target 路径随机型而变，从现有配置里取，
    # 而不是写死 mediatek/filogic——换个机型脚本就废了。
    tgt=$(current_target_path)
    [ -n "$tgt" ] || { printf '0 0 0'; return 0; }

    list=$(mktemp -t uci-cand.XXXXXX) || { printf '0 0 0'; return 0; }
    cache=$(mktemp -d -t uci-cache.XXXXXX) || { rm -f "$list"; printf '0 0 0'; return 0; }

    {
        printf '%s/%s\n' "$base" "$tgt"
        for p in base luci packages routing telephony video; do
            printf '%s/packages/%s/%s/packages.adb\n' "$base" "$arch" "$p"
        done
    } >"$list"

    t1=$(cut -d' ' -f1 /proc/uptime)
    apk update --repositories-file "$list" --cache-dir "$cache" --cache-max-age 0 >/dev/null 2>&1 || true
    t2=$(cut -d' ' -f1 /proc/uptime)

    kb=$(du -sk "$cache" 2>/dev/null | cut -f1)
    [ -n "$kb" ] || kb=0

    rm -rf "$cache" "$list"

    awk -v a="$t1" -v b="$t2" -v k="$kb" 'BEGIN {
        d = b - a
        bytes = k * 1024
        if (d <= 0 || bytes <= 0) { print "0 0 0"; exit }
        printf "%.0f %.2f %d", bytes / d, d, bytes
    }'
}

# 取当前设备架构，用于拼候选源的索引路径
# 取当前设备架构，用于拼候选源的索引路径
#
# 注意：apk --print-arch 给的是 CPU 架构（aarch64），而 distfeeds 的路径用的是
# 完整目标架构（aarch64_cortex-a53）。两者不能混用——用错就拼出 404 的 URL，
# 测速结果会变成"候选源全都不可用"，从而得出完全相反的结论。
# 因此优先从现有 distfeeds 的路径里反推真实架构，取不到才退回 apk。
get_apk_arch() {
    local arch="" feed

    for feed in $FEEDS_FILES; do
        [ -f "$feed" ] || continue
        arch=$(awk '
            /^[[:space:]]*#/ { next }
            /^https?:\/\// {
                if (index($0, "/targets/") > 0) next       # target 路径里没有架构段
                n = split($0, a, "/")
                if (n < 3) next
                if (a[n] != "packages.adb" || a[n-1] != "packages") next
                # .../packages/<arch>/<repo>/packages.adb
                print a[n-2]
                exit
            }
        ' "$feed" 2>/dev/null || true)
        [ -n "$arch" ] && break
    done

    if [ -z "$arch" ] && [ -f /etc/apk/arch ]; then
        arch=$(head -n 1 /etc/apk/arch 2>/dev/null || true)
    fi
    if [ -z "$arch" ] && command -v apk >/dev/null 2>&1; then
        arch=$(apk --print-arch 2>/dev/null | head -n 1 || true)
    fi
    printf '%s' "$arch"
}

# 从当前 distfeeds 里取出 target 路径（形如 targets/mediatek/filogic/packages/packages.adb）
current_target_path() {
    local feed
    for feed in $FEEDS_FILES; do
        [ -f "$feed" ] || continue
        # 用 awk 而不是 sed：busybox sed 不支持 \? / \+ 这类 GNU 扩展，
        # 写成 sed 的 BRE 版本会静默匹配不上（本脚本此前就栽在这上面）。
        awk '
            /^[[:space:]]*#/ { next }
            /^https?:\/\// {
                line = $0
                sub(/[[:space:]]+$/, "", line)
                # 用固定串 + 段数判断，不用 + 量词：
                # busybox awk 的 ERE 对 {n,}/+ 支持不完整，写成 /a+/ 会静默匹配不上。
                if (index(line, "/targets/") == 0) next
                n = split(line, seg, "/")
                if (n < 4) next
                if (seg[n] != "packages.adb" || seg[n-1] != "packages") next
                # 手工取 "targets/..." 起的部分，不用正则：
                # busybox awk 不接受 /^https?:\/\/[^/]+\// 这种带 [^/]+ 的写法
                # （报 "bad regex ... Missing ']'"），正则在这里不可移植。
                p = index(line, "targets/")
                print substr(line, p)
                exit
            }
        ' "$feed" 2>/dev/null || true
        return 0
    done
    return 0
}

# 在镜像池里挑出实测最快、且不是当前源的那个
#
# 每个镜像只测一次：单次样本噪声很大（实测同一对镜像的比值在 1.48~1.56 波动），
# 因此镜像池刻意精简，池子越大"挑最快的"越接近掷骰子。
# 参数：$1 池名（openwrt / immortalwrt）  $2 要排除的当前源前缀
# 输出：stdout 最快镜像前缀；没有可用候选时输出空
pick_fastest_mirror() {
    local pool="$1"
    local exclude="$2"
    local entry speed best_prefix="" best_speed=0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        [ "$entry" = "$exclude" ] && continue

        log INFO "Measuring candidate: $entry"
        speed=$(measure_prefix_speed "$entry" | awk '{print $1}')
        [ -n "$speed" ] || speed=0

        if [ "$speed" -le 0 ]; then
            log WARN "Candidate $entry unusable, skipping"
            continue
        fi

        if [ "$speed" -gt "$best_speed" ]; then
            best_speed="$speed"
            best_prefix="$entry"
        fi
    done <<EOF
$(mirrors_of_set "$pool")
EOF

    printf '%s' "$best_prefix"
}

# 在同一套镜像池里找更快的替代，并执行替换
#
# 决策规则（四条都满足才换）：
#   1. distfeeds 里确实在用 $1 这个前缀；
#   2. 能判定它属于 OPENWRT_MIRRORS 还是 IMMORTALWRT_MIRRORS（认不出就不换，不猜）；
#   3. 同套里另有实测可用的镜像；
#   4. 最快的那个比当前快至少 SWITCH_GAIN_RATIO 倍（默认 1.5）。
#      只看"候选能用"不够——两个镜像都可用时来回换毫无意义，
#      必须有明确的收益门槛，否则每次开机都在镜像之间摇摆。
#
# 参数：$1 当前镜像前缀（必须来自镜像池）
# 返回：0 = 已换源；1 = 不换（原因写入日志）
maybe_switch_mirror() {
    local cur="$1"
    local cur_speed

    # 1. 当前配置里是否真的在用它
    if ! grep -qF -- "$cur" $FEEDS_FILES 2>/dev/null; then
        log INFO "Mirror $cur not in use, nothing to switch"
        return 1
    fi

    # 2. 只在**同一套**镜像里找替代。跨套替换会装到错误的软件包。
    #
    # 变量名不能叫 set：那会把 shell 内建的 set 遮蔽成局部变量，
    # 之后任何 set -- / set -e 的行为都变得不可预测（本脚本曾因此出现
    # "当前速度未知"的误判——MEASURED_SPEED 明明有值却读不到）。
    local pool
    pool=$(mirror_set_of "$cur")
    if [ -z "$pool" ]; then
        log WARN "Current mirror $cur is not in the known pools; refusing to switch (unknown origin)"
        return 1
    fi
    log INFO "Current mirror belongs to pool: $pool"

    cur_speed="${MEASURED_SPEED:-0}"
    if [ "${cur_speed:-0}" -le 0 ]; then
        log WARN "Current mirror speed unknown, refusing to switch blindly"
        return 1
    fi

    # 3. 逐个实测同套里的其它镜像，挑最快的那个
    local best_prefix="" best_speed=0
    best_prefix=$(pick_fastest_mirror "$pool" "$cur")
    if [ -z "$best_prefix" ]; then
        log INFO "No usable candidate in pool $pool, keeping current"
        return 1
    fi
    best_speed=$(measure_prefix_speed "$best_prefix" | awk '{print $1}')
    [ -n "$best_speed" ] || best_speed=0

    # 4. 收益门槛：不明显更快就不动
    gain=$(awk -v a="$best_speed" -v c="$cur_speed" 'BEGIN { printf "%.2f", a / c }')
    need="${SWITCH_GAIN_RATIO:-1.5}"

    if ! awk -v g="$gain" -v n="$need" 'BEGIN { exit (g >= n) ? 0 : 1 }'; then
        log INFO "Best candidate $best_prefix is not faster enough (ratio $gain < $need), keeping current"
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log INFO "[dry-run] would switch $cur -> $best_prefix (ratio $gain)"
        return 0
    fi

    # 5. 只在 distfeeds 里替换"当前前缀"这一种形态
    local feed
    for feed in $FEEDS_FILES; do
        [ -f "$feed" ] || continue
        log INFO "Switching mirror in $feed: $cur -> $best_prefix (ratio $gain)"
        sed -i "s#$cur#$best_prefix#g" "$feed" || {
            log ERROR "Failed to switch mirror in $feed"
            return 1
        }
    done

    log INFO "Mirror switched to $best_prefix"
    return 0
}

# 测量当前 distfeeds 的真实下载速率
#
# 为什么用"删索引 → 计时 apk update → 量缓存增量"：
#   · curl -I 只发 HEAD，拿不到正文，%{speed_download} 恒为 0——
#     旧实现里 MIN_SPEED 那一档从来没生效过；
#   · apk update 下载的就是真实索引包，速度即用户装包时能得到的带宽；
#   · 不依赖 curl/wget/任何外部工具，只要 apk 在。
#
# 参数：无（读当前的 distfeeds 配置）
# 输出：stdout 三个数："<字节每秒> <耗时秒> <下载字节数>"；无法测量时输出 "0 0 0"
# 副作用：清空 /var/cache/apk（这是有意的：命中缓存就测不到真实下载）
measure_mirror_speed() {
    local cache_dir="/var/cache/apk"
    local t1 t2 kb

    # busybox 的 date 没有 %N（纳秒），只能用 /proc/uptime：
    # 第一列是开机秒数，带两位小数，精度 10ms，足够测秒级的下载。
    [ -r /proc/uptime ] || {
        printf '0 0 0'
        return 0
    }

    # 必须先清缓存：apk 命中缓存就不会联网，测出来的"速度"是磁盘速度。
    # 这也意味着本函数会强制下一次 apk 调用重新下载——只在需要测速时调用。
    rm -rf "${cache_dir:?}"/* 2>/dev/null || true

    t1=$(cut -d' ' -f1 /proc/uptime)
    apk update --cache-max-age 0 >/dev/null 2>&1 || true
    t2=$(cut -d' ' -f1 /proc/uptime)

    kb=$(du -sk "$cache_dir" 2>/dev/null | cut -f1)
    [ -n "$kb" ] || kb=0

    awk -v a="$t1" -v b="$t2" -v k="$kb" 'BEGIN {
        d = b - a
        bytes = k * 1024
        # 耗时或字节数异常时不给结论，避免拿一个荒唐的数字去判定
        if (d <= 0 || bytes <= 0) { print "0 0 0"; exit }
        printf "%.0f %.2f %d", bytes / d, d, bytes
    }'
}

# 用 apk update 实测某个 feeds 文件里哪些源不可用
#
# 为什么不再自己发 HTTP 请求：
#   · 本脚本曾经用 curl/wget 取状态码，但固件未必带其中之一（只有 uclient-fetch 时
#     每个源都返回 000，而 000 被设计成"永不当作 404"，于是注释功能静默失效）；
#   · HEAD 请求与 apk 实际取索引的方式并不等价：重定向、Range、User-Agent
#     都可能让探测结果和 apk 的真实体验对不上。
#   apk update 的失败输出才是唯一权威——它说的就是"这个索引取不下来"。
#
# 参数：$1 feeds 文件（只读，不会被修改）
# 输出：每行一个不可用的 URL（原始形式，已去行尾空白）
# 返回：恒为 0
probe_with_apk_update() {
    local feed="$1"
    local out

    command -v apk >/dev/null 2>&1 || return 0

    # --cache-max-age 0 强制真正联网刷新，否则命中缓存就永远显示 OK。
    # 2>&1：apk 把 WARNING 写到 stderr，漏掉就看不出哪一行失效。
    out=$(apk update --repositories-file "$feed" --cache-max-age 0 2>&1) || true

    # 失效源的确切形态（apk-tools 3.x）：
    #   ERROR: wget: exited with error 8
    #   WARNING: updating and opening <URL>: unexpected end of file
    # URL 后面还可能跟别的说明，因此只取到 ":" 前为止。
    #
    # 用 awk 而不是 sed：目标固件是 busybox sed，它**不支持** \? 这种 GNU 扩展，
    # 写成 sed -n 's/...https\?://...' 会直接报 "bad option in substitution expression"，
    # 从而让整段探测静默失效——这正是本脚本此前踩过的同一类坑。
    printf '%s\n' "$out" | awk '
        /^WARNING:[[:space:]]*updating and opening[[:space:]]*https?:\/\// {
            url = $0
            sub(/^WARNING:[[:space:]]*updating and opening[[:space:]]*/, "", url)
            # 说明文字以 ": "（冒号+空格）开头；不能只找冒号——
            # URL 自身的 "https://" 里就有一个，写成 /:.*$/ 会把地址截成 "https"。
            sub(/:[[:space:]].*$/, "", url)
            sub(/[[:space:]]+$/, "", url)
            if (url != "" && !seen[url]++) print url
        }
    '
    return 0
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

# 在 feeds 文件里定位某个 URL 所在的行号
#
# apk 的报错只给 URL、不给行号，而注释必须按行做——同一个 URL 可能出现在
# 多行，也可能被用户手工注释成别的形态，按字符串替换会误伤。
# 参数：$1 文件  $2 目标 URL
# 输出：stdout 行号；找不到时输出空
locate_url_line() {
    local feed="$1"
    local want="$2"

    awk -v want="$want" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*https?:\/\// {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            if (line == want) { print NR; exit }
        }
    ' "$feed" 2>/dev/null || true
}

# 找出本次需要注释掉的源行
#
# 判据是 apk update 自己的失败输出，而不是另发 HTTP 请求：
# 固件不一定带 curl/wget，HEAD 探测与 apk 取索引的真实行为也不等价。
# 参数：$1 feeds 文件  $2 apk 失败 URL 清单文件
# 输出：stdout 行号列表（空格分隔）
find_dead_lines() {
    local feed="$1"
    local bad_file="$2"
    local url line_no
    local dead_lines=""

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        line_no=$(locate_url_line "$feed" "$url")
        if [ -n "$line_no" ]; then
            log WARN "apk cannot fetch index, commenting out: $url"
            dead_lines="$dead_lines $line_no"
        else
            # apk 报了但文件里找不到对应行：多半是重定向后的最终 URL。
            # 记一条便于排查，但绝不猜测着去改别的行。
            log WARN "apk reported a failure for a URL not found verbatim in $feed: $url"
        fi
    done <"$bad_file"

    printf '%s' "$dead_lines"
}

# 过滤掉「上次已确认不可用」的注释行，返回仍值得重新探测的行号
#
# 恢复判定要跑一整轮 apk update（每个失效源都要等超时，实测 25-30 秒）。
# 失效源往往长期失效，每次开机都白等毫无意义，因此用 DEAD_CACHE 记住上次结论。
# 参数：$1 注释行清单（"<行号> <URL>"，每行一条）
# 输出：stdout 待探测的行号列表（空格分隔）
filter_cached_dead_lines() {
    local lines_file="$1"
    local line_no url pending=""

    while read -r line_no url; do
        [ -n "$line_no" ] || continue
        if [ -f "$DEAD_CACHE" ] && grep -Fqx -- "$url" "$DEAD_CACHE" 2>/dev/null; then
            log INFO "Still disabled per last run, skipping re-test: $url"
        else
            pending="$pending $line_no"
        fi
    done <"$lines_file"

    printf '%s' "$pending"
}

# 从 DEAD_CACHE 里移除一个已恢复的 URL
# 参数：$1 URL
forget_dead_url() {
    local url="$1"

    [ -f "$DEAD_CACHE" ] || return 0
    grep -Fvx -- "$url" "$DEAD_CACHE" >"${DEAD_CACHE}.tmp" 2>/dev/null || true
    mv -f "${DEAD_CACHE}.tmp" "$DEAD_CACHE" 2>/dev/null || true
    return 0
}

# 找出本次可以恢复的注释行
#
# 判断恢复不能只看单行：apk update 按仓库逐个取索引，只有把 DEAD_PREFIX 全部
# 去掉后整体再跑一次，才知道哪些源真的回来了。
# 参数：$1 feeds 文件  $2 apk 失败 URL 清单文件
# 输出：stdout 可恢复的行号列表（空格分隔）
find_revivable_lines() {
    local feed="$1"
    local bad_file="$2"
    local lines_file trial line_no url
    local pending revive_lines=""

    lines_file=$(mktemp -t uci-feeds.XXXXXX) || { printf ''; return 0; }
    collect_marked_lines "$feed" >"$lines_file"

    if [ ! -s "$lines_file" ]; then
        rm -f "$lines_file"
        printf ''
        return 0
    fi

    pending=$(filter_cached_dead_lines "$lines_file")
    if [ -z "$pending" ]; then
        log INFO "All disabled source(s) still unavailable per last run; skipping probe"
        rm -f "$lines_file"
        printf ''
        return 0
    fi

    trial=$(mktemp -t uci-trial.XXXXXX) || { rm -f "$lines_file"; printf ''; return 0; }
    # 只去掉本脚本自己的前缀，用户手写的注释原样保留
    sed "s|^${DEAD_PREFIX}||" "$feed" >"$trial" 2>/dev/null || true
    probe_with_apk_update "$trial" >"$bad_file"
    rm -f "$trial"

    while read -r line_no url; do
        [ -n "$line_no" ] || continue
        # 缓存命中的行这次没被重新探测，结论不变，直接跳过
        case " $pending " in
        *" $line_no "*) ;;
        *) continue ;;
        esac

        if grep -Fqx -- "$url" "$bad_file" 2>/dev/null; then
            log INFO "Source still unavailable, keeping disabled: $url"
            printf '%s\n' "$url" >>"$DEAD_CACHE" 2>/dev/null || true
            continue
        fi
        log INFO "Source is reachable again, re-enabling: $url"
        revive_lines="$revive_lines $line_no"
        forget_dead_url "$url"
    done <"$lines_file"

    rm -f "$lines_file"
    printf '%s' "$revive_lines"
}

# 把「恢复」与「注释」两组行号写回文件
#
# 顺序刻意是先恢复、再注释：两组行号分属注释行与生效行，互不重叠，
# 但先恢复能让失败的注释操作留下更干净的现场。
# 参数：$1 feeds 文件  $2 待恢复行号  $3 待注释行号
apply_feed_changes() {
    local feed="$1"
    local revive_lines="$2"
    local dead_lines="$3"
    local revive_count=0 dead_count=0

    if [ -n "$revive_lines" ]; then
        revive_count=$(printf '%s\n' "$revive_lines" | wc -w | tr -d ' ')
    fi
    if [ -n "$dead_lines" ]; then
        dead_count=$(printf '%s\n' "$dead_lines" | wc -w | tr -d ' ')
    fi

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
}

# 处理单个 feeds 文件：注释掉 apk 取不到索引的源，恢复此前注释但已恢复的源
#
# 只做编排：定位 → 过滤缓存 → 探测 → 写回 → 兜底告警，各步在独立函数里。
# 参数：$1 feeds 文件路径
# 返回：恒为 0（单个文件出问题不应影响其他文件）
process_feed_file() {
    local feed="$1"
    local bad_file dead_lines revive_lines

    [ -f "$feed" ] || return 0

    bad_file=$(mktemp -t uci-bad.XXXXXX) || return 0

    # ---- 1. 生效中的源：挑出 apk 认定取不到索引的行 ----
    probe_with_apk_update "$feed" >"$bad_file"
    dead_lines=$(find_dead_lines "$feed" "$bad_file")

    # ---- 2. 此前注释掉的源：整体试跑一次，看哪些已经恢复 ----
    revive_lines=$(find_revivable_lines "$feed" "$bad_file")

    # ---- 3. 写回：先恢复、再注释 ----
    apply_feed_changes "$feed" "$revive_lines" "$dead_lines"

    rm -f "$bad_file"

    # ---- 4. 兜底：一个可用源都不剩时必须大声警告 ----
    if [ "$(collect_source_lines "$feed" | wc -l | tr -d ' ')" = "0" ]; then
        log WARN "No active sources left in $feed, package installation will fail"
    fi
    return 0
}

# 主流程
log INFO "Starting source optimization (scope: $FEEDS_FILES)"
log INFO "Never touched by this script: /etc/apk/repositories.d/customfeeds.list (user-owned feeds)"

# ── 第一步：测量当前源的下载速率 ──
#
# 顺序刻意是「测速 → 换源 → 注释失效源」：
#   · 测速必须在换源之前，否则测到的是刚换上的新源，没有比较基准；
#   · 注释必须在换源之后，因为换源会改写 URL，注释要作用在最终地址上；
#     反过来先注释再换源，被注释的行前缀也会被 sed 一起改掉，
#     "# 404: https://旧源/..." 会变成 "# 404: https://新源/..."，
#     那行"已失效"的记录指向一个其实可用的地址，下次就无法正确恢复。
if [ -n "${SKIP_SPEED_TEST:-}" ]; then
    log INFO "Speed test skipped (SKIP_SPEED_TEST is set)"
else
    speed_bytes=0
    speed_secs=0
    speed_total=0

    speed_result=$(measure_mirror_speed)
    set -- $speed_result
    speed_bytes=${1:-0}
    speed_secs=${2:-0}
    speed_total=${3:-0}

    if [ "${speed_total:-0}" -gt 0 ] && [ "${speed_secs:-0}" != "0" ]; then
        # 人类可读的 KB/s，以及按当前索引总量估算的"完整下载需要多久"
        speed_kb=$(awk -v b="$speed_bytes" 'BEGIN {printf "%.0f", b/1024}')
        log INFO "Mirror speed: ${speed_kb} KB/s (downloaded ${speed_total} bytes in ${speed_secs}s)"

        if [ "${speed_bytes}" -lt "${MIN_SPEED:-50000}" ]; then
            log WARN "Mirror speed ${speed_kb} KB/s is below the ${MIN_SPEED:-50000} B/s threshold;" \
                "package installs on this device will be slow"
        fi

        # 供 maybe_switch_mirror 复用：已测得当前速度，不必再测一遍当前源
        MEASURED_SPEED="$speed_bytes"
        export MEASURED_SPEED
    else
        log WARN "Speed test inconclusive (no bytes downloaded or no measurable time); all indexes may already be cached"
    fi
fi

# ── 第二步：当前源明显偏慢时，换到候选镜像 ──
#
# 只在候选"实测可用且明显更快"时才换（阈值由 SWITCH_GAIN_RATIO 控制，默认 1.5 倍）。
# 不设这个门槛的话，两个都能用的镜像会让设备每次开机在它们之间来回改，
# 每次改动都触发一次索引重下——比一直用慢的那个更糟。
MIRROR_SWITCHED=0
if [ -n "${SKIP_MIRROR_SWITCH:-}" ]; then
    log INFO "Mirror switch disabled (SKIP_MIRROR_SWITCH is set)"
else
    # 当前配置用的是哪个前缀？从 distfeeds 的第一条 URL 反推。
    # 逐个拿已知镜像池的前缀去匹配，匹配上的那个就是"当前源"。
    cur_prefix=$(current_mirror_prefix)

    if [ -z "$cur_prefix" ]; then
        log INFO "Current source is not one of the known mirrors; nothing to compare against"
    elif maybe_switch_mirror "$cur_prefix"; then
        MIRROR_SWITCHED=1
        log INFO "Mirror switched; the following 404 check will run against the new addresses"
    fi
fi

# ── 第三步：注释掉取不到索引的源 ──
#
# 放在最后：此时 URL 已是最终地址，注释记录与用户下次看到的配置一致。
if [ "$COMMENT_404" = "1" ]; then
    log INFO "Checking feeds with apk update (authoritative: it is what actually fetches the indexes)"
    for feed in $FEEDS_FILES; do
        process_feed_file "$feed"
    done
else
    log INFO "404 source check disabled (COMMENT_404=$COMMENT_404)"
fi

log INFO "Source optimization finished (mirror_switched=$MIRROR_SWITCHED)"
exit 0
