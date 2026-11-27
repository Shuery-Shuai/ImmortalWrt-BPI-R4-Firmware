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
#   RESTORE_NOTICE_FILE   提醒记录 NDJSON [默认: /etc/backup/restore_pkg_notices.ndjson]
#                         与失败记录分开存：这里只放"不需要重试"的信息（如包已更名），
#                         混进失败记录会让状态机误判成"二次失败"而锁死，且全量成功时会被一并删除。
#   REBOOT_CMD            重启命令 [默认: reboot -f]
#
# 返回值：
#   0   成功（备份文件不存在、全部安装成功、或处于「已二次失败」的终态）
#   1   发生错误（网络不可达、索引不可用、需要人工介入等）
#
# 状态机（详见仓库 .tmp-design/DESIGN.md）：
#   attempt=0                 → 全量安装
#   第一次有失败（attempt=1） → 写失败记录后重启（仅当本轮装上了包）
#   attempt=1                 → 只重试失败记录里的包
#   二次仍有失败（attempt=2） → 写失败记录，不重启，退出并等 LuCI 提示
#   attempt=2 且失败记录还在  → 直接退出，防止重启循环
#   重启判据                  → 本轮真实安装数 > 0；全部"已安装跳过"时不重启
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

# 提醒记录 schema 版本
readonly NOTICE_SCHEMA="openwrt-apk-notice/1"

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

# 提醒记录（扁平 NDJSON，overlay，重启后保留）
#
# 与失败记录刻意分开存：这里记的是「不需要重试、也不该让用户以为恢复失败」的信息
# （例如包已更名）。若混进失败记录，会同时踩两个坑：
#   1) failure_count > 0 会让状态机进入「二次失败终态保护」，把正常恢复锁死；
#   2) 全部成功时 state_clear 会整份删除失败记录，提醒随之消失。
RESTORE_NOTICE_FILE="${RESTORE_NOTICE_FILE:-/etc/backup/restore_pkg_notices.ndjson}"

# 重启命令（测试时可用环境变量替换，避免真的重启）
REBOOT_CMD="${REBOOT_CMD:-reboot -f}"

# ── 即时重试策略 ──
#
# 背景：状态机的第二轮要等整机重启才发生，一次网络抖动就可能白白浪费
# 整整一次重启（BPI-R4 这类设备一次开机要几分钟）。因此在**单轮之内**补一层
# 廉价重试：把瞬时故障（下载中断、镜像临时 5xx）就地消化掉，避免升级成"失败"。
#
# 只对 fetch 类失败重试。package_not_found 是索引/包名的确定性问题，
# 同一轮内重试必然得到同样结果，重试只会拖长流程。
#
# 默认 1 次：足以覆盖绝大多数瞬时抖动，同时把最坏耗时限制在可控范围。
# 调大 APK_ADD_RETRIES 会成倍拉长最坏情况（每个失败包多花 retries × backoff）。
APK_ADD_RETRIES="${APK_ADD_RETRIES:-1}"
APK_ADD_RETRY_BACKOFF="${APK_ADD_RETRY_BACKOFF:-3}"
APK_UPDATE_RETRIES="${APK_UPDATE_RETRIES:-2}"
APK_UPDATE_RETRY_BACKOFF="${APK_UPDATE_RETRY_BACKOFF:-5}"

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
  第一次运行：全量 best-effort 安装。只要本轮装上了包就重启一次让它生效；
              一个包都没装上则不重启（重启不会改变结果）。
  重启后    ：只重试上次失败的包。
  二次仍失败：不再重启，保留失败记录，登录 LuCI 时弹窗提示。
  包名变动  ：安装前按内置对照表改写清单（改动只作用于本轮清单，不动原备份）——
              改名（如 noto-fonts-cjk）自动换成新名继续装，拆分出的包全部装齐；
              合并（如 luci-app-argon-config）功能已并入现有包，直接丢弃该项；
              移除（_removed_package 表，默认空）旧名已不存在且无替代包，直接跳过。
              三类都记入提醒记录，不算失败、不触发重启。

相关文件:
  状态文件   $RESTORE_STATE_FILE
  失败记录   $RESTORE_FAILURE_FILE
  提醒记录   $RESTORE_NOTICE_FILE

即时重试:
  单轮内对瞬时故障就地重试，避免一次网络抖动就浪费掉整机重启：
    apk update 失败     → 重试 APK_UPDATE_RETRIES 次（默认 2），间隔 APK_UPDATE_RETRY_BACKOFF 秒
    apk add 下载类失败  → 重试 APK_ADD_RETRIES 次（默认 1），间隔 APK_ADD_RETRY_BACKOFF 秒
  包不存在（package_not_found）是确定性失败，不重试。

环境变量:
  LOG_LEVEL, LOG_TO_CONSOLE, MAX_LOG_FILES,
  RESTORE_STATE_FILE, RESTORE_FAILURE_FILE, RESTORE_NOTICE_FILE, REBOOT_CMD,
  APK_ADD_RETRIES, APK_ADD_RETRY_BACKOFF, APK_UPDATE_RETRIES, APK_UPDATE_RETRY_BACKOFF
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
#-----------------------------------------------------------------------
# 函数：_clamp_retry_config
# 描述：把重试相关变量收敛成合法整数；非整数/负数一律回落到调用方给的默认值
#       重试次数写错不该让脚本在 [ -gt ] 处崩掉——那会把一次可恢复的失败
#       变成"环境不可用"，用户更难判断。
# 参数：$1 变量名（按名字读取全局）  $2 默认值  $3 允许的最大值
# 返回：无（就地改写全局变量）
#-----------------------------------------------------------------------
_clamp_retry_config() {
    local name="$1"
    local def="$2"
    local max="$3"
    local val="${!name:-}"

    case "${val}" in
    '' | *[!0-9]*) val="${def}" ;;
    esac

    # 上限保护：重试次数写成 100 会让一次失败卡住几十分钟
    if [ "${val}" -gt "${max}" ]; then
        val="${max}"
    fi

    printf -v "${name}" '%s' "${val}"
}

#-----------------------------------------------------------------------
# 函数：apply_retry_options
# 描述：在参数解析后统一收敛重试配置
#-----------------------------------------------------------------------
apply_retry_options() {
    _clamp_retry_config APK_ADD_RETRIES 1 5
    _clamp_retry_config APK_ADD_RETRY_BACKOFF 3 60
    _clamp_retry_config APK_UPDATE_RETRIES 2 5
    _clamp_retry_config APK_UPDATE_RETRY_BACKOFF 5 60

    log_info "$log_file" "重试策略: apk add 重试 ${APK_ADD_RETRIES} 次(间隔 ${APK_ADD_RETRY_BACKOFF}s)，apk update 重试 ${APK_UPDATE_RETRIES} 次(间隔 ${APK_UPDATE_RETRY_BACKOFF}s)"
    return 0
}

apply_log_options() {
    log_header "$log_file" "应用日志配置" "调试: $opt_debug, 静默: $opt_quiet, 控制台输出: $opt_console"
    [ "$opt_debug" -eq 1 ] && LOG_LEVEL=$LOG_DEBUG
    [ "$opt_quiet" -eq 1 ] && LOG_LEVEL=$LOG_WARN
    [ "$opt_console" -eq 1 ] && LOG_TO_CONSOLE=1
    # 上面的条件在「不成立」时返回非 0，配合 set -e 会直接终止脚本。
    # 这里显式成功，保证任意选项组合下都不会半途退出。
    return 0
}

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
# 包名变动（移除 / 改名 / 合并）的提醒
#===============================================================================

#-----------------------------------------------------------------------
# 函数：_renamed_replacement
# 描述：查「旧包名 → 新包名」的对照表。只登记**上游确实改了名**的包，不靠猜。
#
#       为什么需要它：用户备份里留着旧包名，而旧名已随原第三方仓库失效，
#       恢复时必然报「no such package」——先白重启一轮，再弹一句「包可能已更名」。
#       这里提前识别，把旧名换成确切的新包名继续安装，用户无需手动处理。
#
#       为什么敢自动替换：新名在 feed 里确实能装到，替用户装好等于还原他备份时
#       的状态，比丢下一句提示让他自己再来一次更有用。一个旧目录拆成多个包时
#       （noto-fonts-cjk -> sans / sans-mono / serif）**全部列出**，少装一个就
#       少一种字形，等于悄悄削减了他原本拥有的能力。
#       唯一的代价是体积，这也是这些包在 .config 里保持 =m 而非 =y 的原因。
#
# 参数：$1 包名
# 返回：0 = 已更名，stdout 输出新包名（**空格分隔，可能多个**）；1 = 不在表中
#-----------------------------------------------------------------------
_renamed_replacement() {
    case "$1" in
    # 一个旧目录可能拆成多个独立包：fonts/noto-fonts-cjk 产出下面三个，
    # 三者的 install 段各自装不同字体文件，缺一个就少一种字形。
    # 因此这里必须全部列出、全部安装，不能只挑最常用的那个。
    noto-fonts-cjk)
        printf '%s' 'noto-fonts-cjk-sans noto-fonts-cjk-sans-mono noto-fonts-cjk-serif'
        ;;
    noto-fonts-emoji) printf '%s' 'noto-fonts-color-emoji' ;;
    luci-app-argon-config) printf '%s' 'luci-theme-argon' ;;
    *) return 1 ;;
    esac
}

#-----------------------------------------------------------------------
# 函数：_removed_package
# 描述：查「上游已彻底移除、没有替代包」的对照表。
#
#       为什么需要第三类：改名与合并都能落到某个现存的新包上，而有些包是真的
#       被上游删掉了（依赖组件消失、维护者退出）。这类包照常安装必然走
#       package_not_found → 白重启一轮 → 弹窗说"包可能已更名"，而它其实
#       根本没得换。直接丢弃并说明，比让用户去找一个不存在的替代品好。
#
#       为什么表默认是空的：网上流传的"移除清单"里混着改名与临时下架，
#       照着抄会把本该能装的包当成移除丢掉（少装 = 悄悄削减用户能力）。
#       只登记**亲眼确认过**的移除项，一次一个，附上依据。
#       宁可留空表让它走正常的失败提示，也不猜。
#
# 参数：$1 包名
# 返回：0 = 已移除，stdout 输出一句移除原因（可为空）；1 = 不在表中
#-----------------------------------------------------------------------
_removed_package() {
    case "$1" in
    # 登记格式（去掉行首 # 即生效，原因必填，会展示给用户）：
    #   some-old-pkg) printf '%s' '上游已移除该包，功能不再提供' ;;
    *) return 1 ;;
    esac
}

#-----------------------------------------------------------------------
# 函数：_rename_is_alias
# 描述：判断某个旧包名是否只是 PROVIDES 别名（旧名仍能被 apk 解析）。
#
#       两类变动的处理必须不同，混为一谈会出错：
#         · 真·改名（如 noto-fonts-cjk）：旧名已失效，安装必然失败。
#           换成新名继续装，提到的那几个包一个都不能少。
#         · 别名合并（如 luci-app-argon-config）：主题包用 PKG_PROVIDES 声明了
#           这个名字，apk add 旧名能成功解析并装出 luci-theme-argon。而
#           luci-theme-argon 本就在 .config 里以 =y 内置，功能已经在了——
#           再装一遍没有意义，应当直接丢弃该项。
#       因此别名类丢弃、真改名类换名安装。
#
# 参数：$1 旧包名
# 返回：0 = 是别名（应丢弃）；1 = 真改名（应换名安装）
#-----------------------------------------------------------------------
_rename_is_alias() {
    case "$1" in
    luci-app-argon-config) return 0 ;;
    *) return 1 ;;
    esac
}

#-----------------------------------------------------------------------
# 函数：record_notice
# 描述：向提醒记录追加一条事件（扁平 NDJSON，风格同失败记录，但独立文件）
#       同类别同包已记录过则跳过，重复执行不会堆叠重复条目。
# 参数：$1 category  $2 package  $3 replacement  $4 message
# 返回：0 已记录或已存在；1 写入失败
#-----------------------------------------------------------------------
record_notice() {
    local category="$1"
    local pkg="$2"
    local replacement="$3"
    local message="$4"
    local dir needle

    dir=$(dirname "$RESTORE_NOTICE_FILE")
    mkdir -p "$dir" 2>/dev/null || true

    # 去重：本函数写出的行没有空格，字段顺序固定为 category 前、package 后，
    # 因此固定子串即可定位，不必上正则（包名里的 . + - 会被当元字符）。
    needle="\"category\":\"$category\",\"package\":\"$pkg\""
    if [ -f "$RESTORE_NOTICE_FILE" ] && grep -qF -- "$needle" "$RESTORE_NOTICE_FILE" 2>/dev/null; then
        return 0
    fi

    local line
    line=$(printf '{"schema":"%s","ts":"%s","host":"%s","arch":"%s","category":"%s","package":"%s","replacement":"%s","message":"%s"}' \
        "$NOTICE_SCHEMA" \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
        "$(json_escape "$(get_apk_arch)")" \
        "$category" \
        "$(json_escape "$pkg")" \
        "$(json_escape "$replacement")" \
        "$(json_escape "$message")")

    if printf '%s\n' "$line" >>"$RESTORE_NOTICE_FILE" 2>/dev/null; then
        log_debug "$log_file" "已记录提醒事件: $line"
        return 0
    fi
    log_error "$log_file" "无法写入提醒记录: $RESTORE_NOTICE_FILE"
    return 1
}

#-----------------------------------------------------------------------
# 函数：_prune_resolved_notices
# 描述：删掉「用户已经把新包装上」的提醒条目，避免提示永远挂着。
#
#       提醒的目的是引导用户换包。一旦 replacement 已经装好，这条提醒就过期了——
#       留着它只会让用户每次登录都看到一条待办，而事情其实早已办完。
#       因此每次运行先自清理一次，不需要用户手动删文件。
#
#       只在 apk 可用时判定；apk 不可用就原样保留（宁可多提醒，不可误删）。
# 参数：无（读 $RESTORE_NOTICE_FILE）
# 返回：0 总是成功（清理失败不影响主流程）
#-----------------------------------------------------------------------
_prune_resolved_notices() {
    [ -f "$RESTORE_NOTICE_FILE" ] || return 0
    [ -s "$RESTORE_NOTICE_FILE" ] || return 0
    command -v apk >/dev/null 2>&1 || return 0

    local tmp="${RESTORE_NOTICE_FILE}.prune"
    : >"$tmp" || return 0

    local line pkg replacement removed=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue

        # 取 package / replacement 两个字段；取不到就原样保留，不做猜测。
        pkg=$(printf '%s' "$line" | sed -n 's/.*"package":"\([^"]*\)".*/\1/p')
        replacement=$(printf '%s' "$line" | sed -n 's/.*"replacement":"\([^"]*\)".*/\1/p')

        # replacement 可能是空格分隔的多个包名（一个旧目录拆成多个包）。
        # 判据必须是「全部装好」才算过期：只看第一个会在其余几个还没装时就误删提醒，
        # 用户于是失去"当初那个包该换成什么"的唯一线索。
        if [ -n "$replacement" ]; then
            _rp_all_done=1
            for _rp_one in $replacement; do
                [ -n "$_rp_one" ] || continue
                if ! apk info --installed "$_rp_one" >/dev/null 2>&1; then
                    _rp_all_done=0
                    break
                fi
            done
            if [ "$_rp_all_done" -eq 1 ]; then
                removed=$((removed + 1))
                continue
            fi
        fi
        printf '%s\n' "$line" >>"$tmp" || true
    done <"$RESTORE_NOTICE_FILE"

    mv -f "$tmp" "$RESTORE_NOTICE_FILE" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        return 0
    }

    # 全部过期时删掉空文件：前端读到空文件同样不弹，但空文件留着没有意义。
    if [ ! -s "$RESTORE_NOTICE_FILE" ]; then
        rm -f "$RESTORE_NOTICE_FILE" 2>/dev/null || true
    fi

    if [ "$removed" -gt 0 ]; then
        log_info "$log_file" "已清理 ${removed} 条过期提醒（对应的新包已安装）"
    fi
    return 0
}
#-----------------------------------------------------------------------
# 函数：_apply_rename_table
# 描述：按对照表就地改写安装清单。名字取 apply 而非 demote：两种策略里只有
#       「合并」是丢弃，「改名」是换名后继续安装，用 demote（降级/摘除）会误导。
#       分三种策略（见 _removed_package / _renamed_replacement / _rename_is_alias）：
#         · 已移除         → 直接跳过。旧名已不存在且没有替代包，
#           照常安装只会失败并白白消耗一次整机重启。
#         · 已合并（别名）→ 直接丢弃。功能已并入另一个包，旧名只是别名，
#           再装一遍没有意义；合并后的包本就由 .config 内置。
#         · 已改名         → 就地换成新包名继续安装。新名在 feed 里能装到，
#           用户不必再手动装一次。
#       在清单生成后、安装前调用，覆盖「首次全量」与「二次重试」两个入口。
# 参数：$1 包列表文件（就地改写）  $2 日志文件
# 返回：0 成功；1 改写失败
# 副作用：_rp_demoted_count（丢弃数）、_rp_replaced_count（改名替换数）
#-----------------------------------------------------------------------
# 函数：_classify_package
# 描述：判定单个包在对照表里属于哪一类，并给出应当写入清单的替换项
#
# 三类互斥，判定顺序即优先级：
#   移除 → 没有替代包，直接跳过（不装、不重试、不算失败）
#   合并 → 旧名只是 PROVIDES 别名，功能已在合并后的包里，丢弃该项
#   改名 → 旧名失效但新名能装，用新名继续
#
# 参数：$1 包名  $2 日志文件
# 输出：stdout 每行一个应写入清单的包名（空表示跳过该项）
# 返回：恒为 0；计数器通过全局 _rp_*_count 累加
#-----------------------------------------------------------------------
_classify_package() {
    local pkg="$1"
    local log_file="$2"
    local replacement="" remove_reason=""

    # 变量必须先清空再取：查表函数未命中时返回 1 且不输出，
    # 若直接 if assignment=$(...)，未命中会让变量保留上一次的旧值，
    # 后续拼接日志时就会引用到错的包名。
    if remove_reason=$(_removed_package "$pkg"); then
        # 被上游移除：不装、不重试、不算失败，只留一条说明。
        # 若当作失败处理，会先消耗一次整机重启去重试一个不可能装上的包。
        record_notice "removed_package" "$pkg" "" \
            "旧包名 ${pkg} 已被上游移除${remove_reason:+（${remove_reason}）}，恢复时已自动跳过。" || true
        log_info "$log_file" "包已被上游移除，跳过该项: ${pkg}${remove_reason:+（${remove_reason}）}"
        _rp_removed_count=$((_rp_removed_count + 1))
        return 0
    fi

    replacement=""
    if replacement=$(_renamed_replacement "$pkg") && [ -n "$replacement" ]; then
        if _rename_is_alias "$pkg"; then
            # 合并类：功能已并入另一个包，旧名只是别名。直接丢弃——
            # 再装一遍旧名只会把合并后的包重复声明一次，没有意义；
            # 而合并后的包本就在固件里（例如 luci-theme-argon 由 .config 内置）。
            record_notice "merged_package" "$pkg" "$replacement" \
                "旧包名 ${pkg} 已并入 ${replacement}，功能由合并后的包提供，无需单独安装。" || true
            log_info "$log_file" "包名已合并，丢弃该项: ${pkg}（功能由 ${replacement} 提供）"
            _rp_demoted_count=$((_rp_demoted_count + 1))
            return 0
        fi

        # 改名类：旧名在 feed 里已不存在，但新名可以直接装。
        # replacement 可能含多个包名（一个旧目录拆成多个包），逐个输出——
        # 少装一个就等于少一种字形，而这正是用户当初装这个包的目的。
        #
        # 文案只说「旧名已不存在、已改用新名」，不在这里拼新包名：
        #   · 新包名清单由 replacement 字段逐词给出，前端按数组渲染成等宽标签；
        #   · 曾经用 tr 把空格换成「、」拼进文案，但 tr 按字节映射——
        #     一个 3 字节的中文字符会连续吃掉后面 3 个字节，实际产出是乱码。
        # 文案统一以「旧包名 」开头，前端据此切出旧包名（见 renameOldName）。
        record_notice "renamed_package" "$pkg" "$replacement" \
            "旧包名 ${pkg} 在上游已不存在，恢复时已自动改用下列新包名安装。" || true
        log_info "$log_file" "包名已变更，改用新名安装: ${pkg} -> ${replacement}"
        _rp_replaced_count=$((_rp_replaced_count + 1))
        for _rp_new in $replacement; do
            [ -n "$_rp_new" ] || continue
            printf '%s\n' "$_rp_new"
        done
        return 0
    fi

    # 不在对照表里：原样保留
    printf '%s\n' "$pkg"
    return 0
}

#-----------------------------------------------------------------------
# 函数：_rewrite_list_dedup
# 描述：把去重后的清单原子写回原文件（保持首次出现的顺序）
# 参数：$1 目标清单文件  $2 待写入的中间文件  $3 日志文件
# 返回：0 成功；1 去重或写回失败（已清理临时文件）
#-----------------------------------------------------------------------
_rewrite_list_dedup() {
    local src_list="$1"
    local kept="$2"
    local log_file="$3"

    if ! awk 'NF && !seen[$0]++' "$kept" >"${kept}.dedup" 2>/dev/null; then
        rm -f "$kept" "${kept}.dedup" 2>/dev/null || true
        log_error "$log_file" "无法去重安装清单"
        return 1
    fi

    if ! mv -f "${kept}.dedup" "$src_list" 2>/dev/null; then
        rm -f "$kept" "${kept}.dedup" 2>/dev/null || true
        log_error "$log_file" "无法写回安装清单: $src_list"
        return 1
    fi
    rm -f "$kept" 2>/dev/null || true
    return 0
}

#-----------------------------------------------------------------------
# 函数：_log_rename_summary
# 描述：输出本轮包名变动的汇总（只在对应计数 > 0 时各记一条）
# 参数：$1 日志文件
# 返回：恒为 0
#-----------------------------------------------------------------------
_log_rename_summary() {
    local log_file="$1"

    if [ "$_rp_removed_count" -gt 0 ]; then
        log_info "$log_file" "已跳过 $_rp_removed_count 个被上游移除的包（无替代包）"
    fi
    if [ "$_rp_demoted_count" -gt 0 ]; then
        log_info "$log_file" "已丢弃 $_rp_demoted_count 个已合并项（功能由合并后的包提供）"
    fi
    if [ "$_rp_replaced_count" -gt 0 ]; then
        log_info "$log_file" "已改用新包名 $_rp_replaced_count 个（无需手动处理）"
    fi
    return 0
}

#-----------------------------------------------------------------------
_apply_rename_table() {
    local src_list="$1"
    local log_file="$2"
    local kept pkg

    _rp_demoted_count=0
    _rp_replaced_count=0
    _rp_removed_count=0
    [ -s "$src_list" ] || return 0

    kept="${src_list}.kept"
    : >"$kept" || return 1

    # 逐行分类后写入 kept；具体判定与文案都在 _classify_package 里
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        _classify_package "$pkg" "$log_file" >>"$kept" || true
    done <"$src_list"

    # 同一个新包名可能被多个旧名映射到（或列表里本来就有），去重保序后写回
    _rewrite_list_dedup "$src_list" "$kept" "$log_file" || return 1

    _log_rename_summary "$log_file"
    return 0
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
            # 局部名用小写：Google 风格里大写只留给全局常量，
            # 而且这里存的是"旧分隔符"而不是常量，名字也要如实反映语义。
            local saved_ifs="$IFS"
            IFS=','
            # shellcheck disable=SC2206
            arr_items=($raw)
            IFS="$saved_ifs"
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
_rp_test_url=""    # 首个软件源 URL（仅用于日志与失败记录的 target 字段）
_rp_work_list=""   # 本轮待安装包清单（临时文件）
_rp_attempt_prev=0 # 进入本轮前的 attempt 值
_rp_is_retry=0     # 本轮是否为「只重试失败包」
_rp_failed_count=0 # 本轮安装失败的包数
_rp_index_fresh=0  # 连通性检测阶段是否已经成功刷新过索引（1=是，可跳过重复刷新）
_rp_installed_count=0 # 本轮真正装上的包数（已安装而跳过的不算）
_rp_attempted_count=0 # 本轮实际尝试过的包数（用于区分「没装」与「没跑」）

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

    # 先清掉已经过期的提醒（对应新包已装好），再在下面登记本轮新发现的。
    _prune_resolved_notices || true

    # 清单已定：把「已更名」的包摘出去，只记提醒、不安装。
    # 必须在清单生成后、网络检测前执行：这一步纯本地判断，不依赖网络；
    # 若拖到安装阶段，那两个包会先失败一次、再触发一次无意义的重启。
    if ! _apply_rename_table "$_rp_work_list" "$log_file"; then
        rm -f "$_rp_work_list"
        log_error "$log_file" "摘除更名包时失败，中止本轮以暴露问题"
        log_exit_summary "$log_file" 1 "$_rp_start_time"
        return 1
    fi

    if [ ! -s "$_rp_work_list" ]; then
        # 清单里全是已更名包：没有要装的东西，但提醒已经写好了，按成功结束。
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
#       判定方式见 check_network：用 apk update 的真实结果，
#       只要还有源能取到索引就继续，全部取不到才中止。
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
    INSTALL_OK_COUNT=0
    INSTALL_ATTEMPTED_COUNT=0
    INSTALL_RETRIED_COUNT=0
    install_packages_one_by_one "$_rp_work_list" "$((_rp_attempt_prev + 1))" "$log_file" || true
    _rp_failed_count="${INSTALL_FAILED_COUNT:-0}"
    [[ "$_rp_failed_count" =~ ^[0-9]+$ ]] || _rp_failed_count=0
    _rp_installed_count="${INSTALL_OK_COUNT:-0}"
    [[ "$_rp_installed_count" =~ ^[0-9]+$ ]] || _rp_installed_count=0
    _rp_attempted_count="${INSTALL_ATTEMPTED_COUNT:-0}"
    [[ "$_rp_attempted_count" =~ ^[0-9]+$ ]] || _rp_attempted_count=0

    rm -f "$_rp_work_list"

    # 「靠重试救回来」是镜像健康度的直接指标：
    # 这个数字持续大于 0，说明镜像不稳；一直为 0 而失败数很高，说明是包本身的问题。
    if [ "${INSTALL_RETRIED_COUNT:-0}" -gt 0 ]; then
        log_info "$log_file" "其中 ${INSTALL_RETRIED_COUNT} 个包在第 2 次尝试才装成功（镜像可能不稳定）"
    fi

    log_info "$log_file" "本轮安装完成：实际安装 $_rp_installed_count 个，失败 $_rp_failed_count 个（共尝试 $_rp_attempted_count 个）"

    # 清理单次的 apk 输出。必须放在这里而不是安装循环里：
    # _record_* 系列函数要在失败当场读 APK_LAST_OUTPUT 做分类与摘录，
    # 提前删掉会让失败记录失去 message / related_warning。
    # 每轮只留最后一份（同名覆盖），一次运行最多 2 个文件，
    # 但恢复进程会在开机早期反复触发，不留就会在 tmpfs 里累积到重启。
    rm -f /tmp/apk-add-*.log /tmp/apk-update-*.log 2>/dev/null || true

    return 0
}

#-----------------------------------------------------------------------
# 函数：_finalize_all_success
# 描述：全部成功的收尾。是否重启只看一件事：本轮**有没有真的装上新包**。
#
#       为什么不再看 attempt_prev / is_retry：
#         · 旧条件「attempt_prev=0 且 is_retry=0」把「首次全量」当成重启理由，
#           可第二轮若因失败记录缺失而回退成全量，is_retry 仍是 0，
#           于是第二轮成功也会被当成首次全量，白白多重启一次；
#         · 真正需要重启的唯一理由是「有包刚装进磁盘、需要重新初始化」。
#           一个包都没装（全部已安装而跳过、或清单本来就空）时重启毫无意义，
#           反而会让用户多等一次重启。
#       因此判据换成 _rp_installed_count > 0。
#
#       删备份必须先于 state_clear 之后再谈重启：
#       旧实现「先删备份再重启」，一旦重启命令失败或中途断电，备份已经没了，
#       下次开机只会看到「备份文件不存在」并永久跳过恢复。现在改为
#       重启成功返回后才删，重启失败则保留备份，下次开机仍可继续。
# 返回：main 的退出码（重启失败时为 1，其余 0）
#-----------------------------------------------------------------------
_finalize_all_success() {
    local rc=0

    state_clear

    if [ "$_rp_installed_count" -gt 0 ]; then
        # 判据只认"有没有装上新包"，不认"第几轮"：
        # 第二轮补装的包同样需要重新初始化才生效，跳过重启会让用户以为装好了其实没有。
        # 代价是重试轮成功后还会再重启一次；这是正确性优先的选择。
        if [ "$_rp_is_retry" -eq 1 ]; then
            log_info "$log_file" "重试轮补装 $_rp_installed_count 个包，同样需要重启才能生效"
        else
            log_info "$log_file" "本轮新安装 $_rp_installed_count 个包，重启以使其生效"
        fi

        # 先重启，成功返回后再消费备份：重启失败时备份必须留着，
        # 否则下一次开机将因「备份文件不存在」而永久跳过恢复。
        if do_reboot "$_rp_start_time" "$log_file"; then
            rm -f "$_rp_backup_file" 2>/dev/null || true
            log_info "$log_file" "已删除备份文件: $_rp_backup_file"
        else
            log_warn "$log_file" "重启未成功，保留备份文件以便下次开机继续: $_rp_backup_file"
            rc=1
        fi
        return "$rc"
    fi

    # 一个包都没装：不重启。备份仍然删掉——它已经完成使命，
    # 留着只会让下次开机重复解析一遍同样的清单。
    if [ "$_rp_attempted_count" -gt 0 ]; then
        log_header "$log_file" "恢复完成" "全部软件包已就绪，本轮无需安装，不重启"
    else
        log_header "$log_file" "恢复完成" "所有软件包验证成功"
    fi
    rm -f "$_rp_backup_file" 2>/dev/null || true
    log_info "$log_file" "已删除备份文件: $_rp_backup_file"
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
        if [ "$_rp_installed_count" -gt 0 ]; then
            # 第一次失败 → 重启重试。状态已写盘，重启后只重试失败包。
            # 备份绝不能在这里删：第二轮还要靠失败记录重试，备份是兜底清单。
            log_warn "$log_file" "第一次尝试：装好 $_rp_installed_count 个，仍有 $_rp_failed_count 个失败，记录后将重启重试"
            do_reboot "$_rp_start_time" "$log_file"
            return $?
        fi

        # 一个包都没装成功，重启也不会改变结果（下一轮同样是全失败），
        # 因此不重启，直接留失败记录等 LuCI 提示；把 attempt 落到 2，
        # 免得下次开机又白跑一遍注定失败的完整清单。
        state_write 2 "failed"
        log_error "$log_file" "第一次尝试 $_rp_failed_count 个包全部失败，无包可装，不重启"
        log_info "$log_file" "失败明细见: $RESTORE_FAILURE_FILE"
        log_exit_summary "$log_file" 1 "$_rp_start_time"
        return 1
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
    apply_retry_options

    _acquire_lock || exit 1

    _rp_start_time=$(date +%s)
    _rp_backup_file="$opt_backup_file"
    _rp_test_url=$(get_apk_repo_url)

    trap 'restore_original_config "$backup_resolv_flag" "$firewall_type" "$log_file"' EXIT

    log_header "$log_file" "脚本启动" "备份文件=$_rp_backup_file"
    log_info "$log_file" "日志级别: $LOG_LEVEL, 控制台输出: $LOG_TO_CONSOLE"

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
# 描述：从系统 apk 配置中获取第一个软件源 URL
#       仅用于日志与失败记录的 target 字段——连通性判断已改由 apk update 自己做，
#       不再用这个 URL 单独探测（探测方式与 apk 实际取索引不等价）。
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
# 描述：用 apk update 判断「软件源到底能不能取到索引」
#
#       为什么不再用 curl/wget/ping 探一个 URL：
#         · 固件不一定带 curl 或 wget（只带 uclient-fetch 时探测全部失效），
#           最终会回落到 ping；而 ping 只证明主机活着，证明不了索引可取——
#           一个 404 的 packages.adb 在 ping 看来完全正常。
#         · HEAD 请求和 apk 真实取索引的方式不等价（重定向/UA/Range 都可能不同）。
#       判据只有一条：apk 自己说不可用的源，是否已经等于源的总数。
#         · 全部不可用  → 真的是网络/源配置问题，本轮中止；
#         · 部分不可用  → 网络是通的，个别源失效由 replace-apk-source.sh 处理，
#                         不该在这里拦下整个恢复流程。
#
# 参数：$1 测试 URL（仅用于日志，实际探测走 repositories）  $2 日志文件
# 返回：0 = 至少有一个源可用；1 = 所有源都取不到（或 apk 不可用）
#-----------------------------------------------------------------------
check_network() {
    local test_url="$1"
    local log_file="$2"
    local retries=3
    local i=1

    if ! command -v apk >/dev/null 2>&1; then
        log_error "$log_file" "apk 不可用，无法判断软件源连通性"
        return 1
    fi

    while [ "$i" -le "$retries" ]; do
        local out rc unavail total

        # --cache-max-age 0 强制真正联网；命中缓存的话"网络已断"也会显示 OK。
        # 不指定 --repositories-file，就用系统真实配置——这才是要验证的对象。
        out=$(apk update --cache-max-age 0 2>&1) && rc=0 || rc=$?

        unavail=$(printf '%s\n' "$out" |
            sed -n 's/^\([0-9][0-9]*\) unavailable.*/\1/p' | head -n 1)
        [ -n "$unavail" ] || unavail=0

        total=$(count_configured_sources)

        if [ "$rc" -eq 0 ]; then
            log_info "$log_file" "软件源索引刷新成功（$test_url）"
            # 索引刚刚联网拉过，第二阶段的 apk update 可以直接跳过：
            # 同一轮里连续两次全量刷新既慢又没意义（第二次只是命中刚写的缓存）。
            _rp_index_fresh=1
            return 0
        fi

        # 部分源失效：网络是通的。把结论说清楚，但放行本轮恢复，
        # 别让一个社区仓库 404 卡住整台设备的软件包恢复。
        if [ "$total" -gt 0 ] && [ "$unavail" -lt "$total" ]; then
            log_warn "$log_file" "部分软件源不可用（$unavail/$total），网络本身正常，继续恢复"
            return 0
        fi

        log_warn "$log_file" "软件源全部不可用（$unavail/$total，退出码 $rc），第 $i/$retries 次"
        if [ "$i" -lt "$retries" ]; then
            sleep $((i * 2))
        fi
        i=$((i + 1))
    done

    log_error "$log_file" "所有软件源均无法访问，所有重试已用完"
    return 1
}

#-----------------------------------------------------------------------
# 函数：count_configured_sources
# 描述：统计系统当前生效的软件源条数（跳过注释与空行）
#       与 check_network 的分母：apk 只报"不可用数量"，不给总数，
#       因此总数必须自己数，才能区分"部分失效"与"全部失效"。
# 返回：stdout 输出条数（0 表示没有配置任何源）
#-----------------------------------------------------------------------
count_configured_sources() {
    local total=0 f n

    for f in /etc/apk/repositories; do
        [ -f "$f" ] || continue
        n=$(awk '/^[[:space:]]*#/ {next} /^https?:\/\// {c++} END {print c+0}' "$f" 2>/dev/null || echo 0)
        total=$((total + n))
    done

    if [ -d /etc/apk/repositories.d ]; then
        for f in /etc/apk/repositories.d/*.list; do
            [ -f "$f" ] || continue
            n=$(awk '/^[[:space:]]*#/ {next} /^https?:\/\// {c++} END {print c+0}' "$f" 2>/dev/null || echo 0)
            total=$((total + n))
        done
    fi

    printf '%s' "$total"
}

#-----------------------------------------------------------------------
# 函数：update_package_lists
# 描述：执行 apk update，把所有输出留档供失败分类使用
#       apk update 在「部分源不可用」时退出码可能非 0 但索引仍可用，
#       因此这里只返回退出码，由调用方决定是否继续
#-----------------------------------------------------------------------
update_package_lists() {
    local log_file="${1:-/dev/null}"
    local attempt=0
    local max_attempts=$((APK_UPDATE_RETRIES + 1))
    local ret=0

    # 连通性检测阶段刚刚联网刷新过索引：这一轮不必再全量刷一次。
    # 但 APK_LAST_OUTPUT 仍要准备一个文件，下游 extract_last_warning 可能读它。
    if [ "$_rp_index_fresh" -eq 1 ]; then
        log_info "$log_file" "索引刚在连通性检测阶段刷新过，跳过重复刷新"
        APK_LAST_OUTPUT="/tmp/apk-update-$$.log"
        : >"$APK_LAST_OUTPUT" 2>/dev/null || true
        return 0
    fi

    log_info "$log_file" "开始更新软件包列表..."

    APK_LAST_OUTPUT="/tmp/apk-update-$$.log"

    # 索引是后续逐包安装的前提：索引没下来，逐包 apk add 会成片失败，
    # 而那会直接消耗掉状态机仅有的一次重试机会（要整机重启才轮到第二轮）。
    # 因此这里就地重试，把镜像抖动挡在重启之前。
    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        ret=0
        apk update >"$APK_LAST_OUTPUT" 2>&1 || ret=$?

        if [ "$ret" -eq 0 ]; then
            if [ "$attempt" -gt 1 ]; then
                log_info "$log_file" "软件源更新在第 $attempt 次尝试成功"
            else
                log_info "$log_file" "软件源更新成功"
            fi
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            log_warn "$log_file" "软件源更新失败 (退出码 $ret)，第 $attempt/$max_attempts 次；${APK_UPDATE_RETRY_BACKOFF}s 后重试"
            sleep "$APK_UPDATE_RETRY_BACKOFF"
        fi
    done

    log_warn "$log_file" "软件源更新共尝试 $attempt 次仍失败 (退出码 $ret)，继续尝试逐包安装"
    {
        echo "--- apk update 输出开始 ---"
        cat "$APK_LAST_OUTPUT" 2>/dev/null || true
        echo "--- apk update 输出结束 ---"
    } >>"$log_file"
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

    # 单轮内的即时重试：只针对 fetch 类（下载中断、镜像临时不可用）。
    # package_not_found 是确定性的——同一轮里重试得到的是同一个结果，
    # 只会白白拖长流程，所以第一次就放弃。
    local try=0
    local max_tries=$((APK_ADD_RETRIES + 1))
    local cls stage error_class

    while [ "$try" -lt "$max_tries" ]; do
        try=$((try + 1))
        ret=0
        apk add --no-cache "$pkg" >"$APK_LAST_OUTPUT" 2>&1 || ret=$?

        if [ "$ret" -eq 0 ]; then
            if [ "$try" -gt 1 ]; then
                log_info "$log_file" "安装成功: $pkg（第 $try 次尝试）"
                INSTALL_RETRIED_COUNT=$((INSTALL_RETRIED_COUNT + 1))
            else
                log_info "$log_file" "安装成功: $pkg"
            fi
            INSTALLED_THIS_PKG=1
            return 0
        fi

        cls=$(classify_apk_failure "$APK_LAST_OUTPUT")
        stage="${cls%%|*}"
        error_class="${cls##*|}"

        # 确定性失败：不重试
        if [ "$error_class" != "fetch_error" ]; then
            break
        fi

        if [ "$try" -lt "$max_tries" ]; then
            log_warn "$log_file" "安装失败: $pkg (退出码 $ret，下载类问题)，${APK_ADD_RETRY_BACKOFF}s 后第 $try/$max_tries 次重试"
            sleep "$APK_ADD_RETRY_BACKOFF"
        fi
    done

    log_warn "$log_file" "安装失败: $pkg (退出码 $ret，已尝试 $try 次)"

    # ---- 失败分类与 NDJSON 记录 ----
    local message related_warning

    message=$(_failure_message_line "$APK_LAST_OUTPUT" "apk add failed with exit code $ret")
    related_warning=$(sed -n 's/^WARNING:[[:space:]]*//p' "$APK_LAST_OUTPUT" 2>/dev/null | head -n 1 || true)

    # 重试次数一并记进失败记录：事后能区分"一次就挂"与"重试过仍挂"，
    # 前者多半是真问题，后者更像持续性的镜像故障。
    if [ "$try" -gt 1 ]; then
        related_warning="${related_warning:+${related_warning}; }重试 $((try - 1)) 次后仍失败"
    fi

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
    local installed=0
    local attempted=0
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

        # 每次调用前清零，由 _install_one_package 在「apk add 真的成功」时置 1。
        # 已安装而跳过的不置位：那没有改变系统状态，不该让本轮被算成"装上了包"。
        INSTALLED_THIS_PKG=0
        if ! _install_one_package "$pkg" "$attempt" "$log_file"; then
            failed=$((failed + 1))
        fi
        attempted=$((attempted + 1))

        if [ "${INSTALLED_THIS_PKG:-0}" -eq 1 ]; then
            installed=$((installed + 1))
        fi
    done <"$pkg_list"

    [ "${LOG_TO_CONSOLE:-0}" -eq 1 ] && printf '\n' >&2

    INSTALL_FAILED_COUNT="$failed"
    INSTALL_OK_COUNT="$installed"
    INSTALL_ATTEMPTED_COUNT="$attempted"
    # INSTALL_RETRIED_COUNT 由 _install_one_package 直接累加，这里不覆盖：
    # 它是"跨包累计"的计数，重置只能发生在 _install_phase 开始时。
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

#-----------------------------------------------------------------------
# 函数：detect_firewall_type
# 描述：探测系统正在使用的防火墙实现
#
#       先试 nft 再试 iptables：OpenWrt 22.03+ 默认 nftables，
#       但老机型仍可能只有 iptables。两个都不可用时返回空串，
#       调用方据此跳过临时规则（而不是假装设置成功）。
# 返回：stdout "nftables" / "iptables" / ""
#-----------------------------------------------------------------------
detect_firewall_type() {
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
# 描述：临时放行出站 DNS/HTTP/HTTPS，让恢复流程能连上软件源
#
#       只放行出站四类流量，不碰入站、不改默认策略：
#       恢复只需要下载，多余的口子会在最不该出事的时刻扩大攻击面。
#       这些规则必须由 restore_original_config 清掉（EXIT trap 负责调用）。
# 参数：$1 防火墙类型（nftables/iptables）  $2 日志文件
# 返回：恒为 0（单条规则失败只记日志，不影响恢复主流程）
#-----------------------------------------------------------------------
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

#-----------------------------------------------------------------------
# 函数：restore_original_config
# 描述：还原 resolv.conf 与防火墙（由 main 的 EXIT trap 调用）
#
#       无论恢复流程成功、失败还是被中断，这段都必须执行——
#       否则设备会带着临时 DNS（8.8.8.8）和放行规则继续运行。
#       因此它挂在 trap 上而不是流程末尾，且每一步都容错（|| true），
#       保证"清理本身失败"不会阻塞后续清理步骤。
# 参数：$1 resolv 是否被改过（0/1）  $2 防火墙类型  $3 日志文件
# 返回：恒为 0
#-----------------------------------------------------------------------
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
