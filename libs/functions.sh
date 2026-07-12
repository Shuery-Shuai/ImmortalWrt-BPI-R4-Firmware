#!/bin/bash
#######################################
# OpenWrt/ImmortalWrt 构建通用函数库
#
# 提供所有 diy 脚本需要的辅助函数，包括：
#   - 日志输出
#   - Git 仓库克隆/更新（带重试）
#   - MediaTek 分区修改（通用 sed 作用域替换）
#   - 作用域 grep 调试辅助
#   - 相对路径计算与符号链接创建
#   - 从 Makefile 提取包名
#   - 智能解析包的目标 feed 路径
#   - 批量创建符号链接（带缓存）
#   - 修改 LuCI 集合 Makefile
#
# 用法：在 diy 脚本中 source 本文件
#######################################

#######################################
# 日志级别常量
#
# 用于设置和比较日志级别，数值越小级别越低。
#
# Globals:
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
# Globals:
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
# Globals:
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
# Arguments:
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
# Arguments:
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
# Arguments:
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

#######################################
# 分区调整（通用作用域 sed 替换）
# 根据作用域起始/结束正则，对文件内匹配行进行替换。
# 参数：
#   $1 - 文件路径
#   $2 - 追加大小 (MB)
#   $3 - 作用域起始正则
#   $4 - 作用域结束正则
#   $5 - sed 替换表达式（可包含 & 引用追加大小）
# 注意：为了灵活性，将具体的 sed 脚本作为参数传入。
#######################################
modify_within_scope() {
    local file="$1"
    local append_size="$2"
    local start_re="$3"
    local end_re="$4"
    local sed_script="$5"

    if [[ ! -f "${file}" ]]; then
        log ERROR "File ${file} does not exist."
        return 1
    fi

    log INFO "Modifying ${file} with append_size=${append_size} within scope \"${start_re}\" to \"${end_re}\"..."
    if ! sed -i -E -e "/${start_re}/,/${end_re}/ { ${sed_script} }" "${file}"; then
        log ERROR "Failed to modify ${file}."
        return 1
    fi
    log INFO "Done modifying ${file} within scope \"${start_re}\" to \"${end_re}\"."
}

#######################################
# 在文件的作用域内将匹配模式中的数字增加指定值
#
# 使用 awk 读取文件，定位作用域，对匹配正则的行中的数字做加法。
# 注意：awk 中的正则需兼容，此处模式捕获数字并替换为 num+offset。
#
# Arguments:
#   $1 - 文件路径
#   $2 - 作用域起始正则（awk 格式，如 /^define Build\/mt798x-gpt/）
#   $3 - 作用域结束正则（如 /^endef/）
#   $4 - 匹配行正则（用于识别哪些行需修改）
#   $5 - 数字捕获的正则（如 /[0-9]+/，可使用 awk match 定位）
#   $6 - 增加的数值（整数）
#
# 由于复杂性，此函数依赖 awk 并且假设行内数字出现在特定位置，
# 我们针对分区文件定制专用版本。
# 但为了保持通用，我们提供基于 awk 的模板。
# 实际调用时可根据需求调整。
#######################################
add_values_in_scope() {
    local file="$1"
    local start_re="$2"
    local end_re="$3"
    local line_match="$4"
    local num_pos="$5" # 例如 "M@", "M ", "m" 等上下文
    local offset="$6"

    awk -v start_re="${start_re}" -v end_re="${end_re}" \
        -v line_match="${line_match}" -v num_pos="${num_pos}" -v offset="${offset}" '
        $0 ~ start_re { in_scope=1 }
        in_scope && $0 ~ end_re { in_scope=0; print; next }
        in_scope && $0 ~ line_match {
            # 将行中匹配 num_pos 前数字的部分提取并加 offset
            # 简单实现：查找第一个数字串在 num_pos 前
            if (match($0, /[0-9]+/)) {
                num = substr($0, RSTART, RLENGTH)
                newnum = num + offset
                $0 = substr($0, 1, RSTART-1) newnum substr($0, RSTART+RLENGTH)
            }
        }
        { print }
    ' "${file}" >"${file}.tmp" && mv "${file}.tmp" "${file}"
}

#######################################
# 展示文件中指定作用域内匹配的行（通用调试工具）
#
# 从文件中提取由起始/结束正则划定的内容块，
# 并可选择性地用 grep 高亮特定模式。
#
# Arguments:
#   $1 - 文件路径
#   $2 - 作用域起始正则
#   $3 - 作用域结束正则
#   $4 - grep 匹配模式（可选，为空则输出所有行）
#   $5 - 自定义标题前缀（可选，默认为 "Content"）
#
# Outputs:
#   带分隔线的作用域内容到 stdout
#   分隔线和统计信息到 stderr（通过 log）
#
# Returns:
#   0 - 总是成功（即使内容为空）
#
# Examples:
#   show_scope_content "Makefile" "^define Package/mypkg" "^endef" "PKG_VERSION|PKG_RELEASE" "Package mypkg"
#   show_scope_content "config.txt" "# 网络配置" "# 结束" "" "网络配置段"
#######################################
show_scope_content() {
    local file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    local grep_patterns="${4:-}"
    local title="${5:-Content}"

    if [[ ! -f "${file}" ]]; then
        log WARN "File ${file} does not exist, cannot show scope content."
        return 0
    fi

    log INFO "━━━━━━━━━━━━━━━━━━━━ ${title} (${start_pattern} → ${end_pattern}) ━━━━━━━━━━━━━━━━━━━━"
    if [[ -n "${grep_patterns}" ]]; then
        sed -n -e "/${start_pattern}/,/${end_pattern}/p" "${file}" | grep -E --color=always "${grep_patterns}"
    else
        sed -n -e "/${start_pattern}/,/${end_pattern}/p" "${file}"
    fi
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#######################################
# 克隆或更新 Git 仓库（带重试机制）
#
# 智能处理仓库下载：如果目录已存在则执行 pull 更新，否则执行 clone。
# 支持失败重试（最多 3 次），每次重试前等待递增的时间。
#
# Arguments:
#   $1 - Git 仓库 URL
#   $2 - 分支名称
#   $3 - git clone 的额外参数 (如 "--depth=1" 或 "--filter=blob:none --sparse")
#   $4 - 目标目录路径 (相对或绝对路径)
#
# Globals:
#   None
#
# Outputs:
#   操作进度信息到 stdout
#   错误信息到 stderr (通过 log)
#
# Returns:
#   0 - 成功克隆或更新
#   1 - 重试 3 次后仍失败 (脚本直接退出)
#
# Examples:
#   clone_repo 'https://github.com/user/repo' 'main' '--depth=1' 'packages/repo'
#   clone_repo 'https://github.com/user/repo' 'master' '--filter=blob:none --sparse' 'custom-packages/repo'
#######################################
clone_repo() {
    local repo="$1"
    local branch="$2"
    local args="$3"
    local target="$4"
    local attempt

    if [[ -d "${target}" ]]; then
        # 目录已存在，尝试更新
        log 'INFO' "Pulling ${repo} at ${target}..."
        for attempt in {1..3}; do
            # 清理工作区 -> 恢复修改 -> 拉取更新
            if git -C "${target}" clean -fdx &&
                git -C "${target}" restore . &&
                git -C "${target}" pull; then
                break
            else
                log 'WARN' "Pull attempt ${attempt} failed, retrying..."
                sleep $((attempt * 2)) # 递增等待时间：2s, 4s, 6s
            fi
        done
    else
        # 目录不存在，克隆新仓库
        log 'INFO' "Cloning ${repo} ${branch} to ${target}, using args: ${args}"
        for attempt in {1..3}; do
            log 'INFO' "Clone attempt ${attempt}..."
            # 将参数字符串拆分并传递给 git clone
            if eval "git clone -b '${branch}' ${args} '${repo}' '${target}'"; then
                break
            else
                log 'ERROR' "Clone attempt ${attempt} failed!"
                sleep $((attempt * 2))
                rm -rf "${target}" # 清理失败的半成品
                if [[ "${attempt}" -eq 3 ]]; then
                    log 'ERROR' "Failed to clone ${repo} after 3 attempts."
                    exit 1
                fi
            fi
        done
    fi
}

#######################################
# 计算相对路径（纯 Bash 实现）
#
# 从源目录计算到目标路径的相对路径，无需外部工具依赖。
# 用于创建可移植的符号链接。
#
# Arguments:
#   $1 - 源目录 (from)
#   $2 - 目标路径 (to)
#
# Outputs:
#   相对路径字符串到 stdout (如 "../../target/dir")
#
# Returns:
#   0 - 成功
#   1 - 目录切换失败
#
# Examples:
#   relpath "/a/b/c" "/a/d/e"  # 输出: ../../d/e
#   relpath "/home/user/project" "/opt/lib"  # 输出: ../../../opt/lib
#######################################
relpath() {
    local from_dir="$1"
    local to_path="$2"
    local abs_from abs_to

    # 获取绝对路径
    abs_from="$(cd "${from_dir}" && pwd)" || return 1
    abs_to="$(cd "${to_path}" && pwd)" || return 1

    # 将路径拆分为数组
    local from_parts to_parts
    IFS='/' read -ra from_parts <<<"${abs_from}"
    IFS='/' read -ra to_parts <<<"${abs_to}"

    # 找到公共前缀的结束位置
    local i=0
    while [[ ${i} -lt ${#from_parts[@]} &&
        ${i} -lt ${#to_parts[@]} &&
        "${from_parts[${i}]}" == "${to_parts[${i}]}" ]]; do
        ((i++))
    done

    # 计算需要向上的层数 (../)
    local up_count=$((${#from_parts[@]} - i))
    local rel_path=''
    local j

    for ((j = 0; j < up_count; j++)); do
        rel_path+='../'
    done

    # 添加从公共祖先到目标的路径
    for ((j = i; j < ${#to_parts[@]}; j++)); do
        rel_path+="${to_parts[${j}]}"
        if [[ ${j} -lt $((${#to_parts[@]} - 1)) ]]; then
            rel_path+='/'
        fi
    done

    # 输出最终相对路径（关键修复）
    printf '%s' "${rel_path}"
}

#######################################
# 创建相对路径符号链接
#
# 使用相对路径创建符号链接，避免绝对路径导致的可移植性问题。
# 如果目标位置已存在符号链接或目录，则先删除。
#
# Arguments:
#   $1 - 源路径（绝对路径）
#   $2 - 符号链接路径（要创建的链接位置）
#
# Globals:
#   None
#
# Outputs:
#   操作日志到 stderr (通过 log)
#
# Returns:
#   0 - 符号链接创建成功
#   1 - 相对路径计算失败或 ln 命令失败
#
# Examples:
#   create_relative_symlink "/path/to/source" "feeds/luci/applications/app"
#######################################
create_relative_symlink() {
    local source_abs="$1"
    local target_link="$2"
    local target_dir

    target_dir="$(dirname "${target_link}")"
    mkdir -p "${target_dir}"

    # 删除已存在的链接或目录
    if [[ -L "${target_link}" ]] || [[ -d "${target_link}" ]]; then
        log 'WARN' "Removing existing symlink/directory at ${target_link}"
        rm -rf "${target_link}"
    fi

    # 计算相对路径
    local rel_target
    rel_target="$(relpath "${target_dir}" "${source_abs}")"
    if [[ -z "${rel_target}" ]]; then
        log 'ERROR' "Failed to compute relative path from ${target_dir} to ${source_abs}"
        return 1
    fi

    # 创建符号链接
    if ln -s "${rel_target}" "${target_link}"; then
        log 'INFO' "SUCCESS: Created symlink ${target_link} -> ${rel_target}"
        return 0
    else
        log 'ERROR' "FAILED: Could not create symlink ${target_link}"
        return 1
    fi
}

#######################################
# 从 Makefile 提取软件包名称
#
# 尝试从软件包的 Makefile 中提取 PKG_NAME 变量值。
# 如果未找到或 Makefile 不存在，则使用目录名作为回退。
#
# Arguments:
#   $1 - 软件包目录的绝对路径
#
# Globals:
#   None
#
# Outputs:
#   软件包名称到 stdout
#
# Returns:
#   0 - 成功提取或使用回退值
#   1 - Makefile 不存在
#
# Examples:
#   extract_pkg_name "/path/to/luci-app-example"  # 输出: luci-app-example
#######################################
extract_pkg_name() {
    local abs_dir="$1"
    local makefile="${abs_dir}/Makefile"
    local pkg_name

    if [[ ! -f "${makefile}" ]]; then
        return 1
    fi

    # 提取 PKG_NAME 变量（支持 := 和 = 两种赋值方式）
    pkg_name="$(grep -E '^\s*PKG_NAME\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*PKG_NAME\s*:?=\s*(.+)\s*$/\1/')"

    if [[ -z "${pkg_name}" ]]; then
        # 回退：使用目录名
        pkg_name="$(basename "${abs_dir}")"
    fi

    log 'INFO' "Package name: ${pkg_name}"
}

#######################################
# 解析软件包的目标 feed 路径
#
# 根据软件包名称和 Makefile 中的 SECTION 变量，智能确定软件包应该链接到哪个 feed 目录。
# 解析策略（按优先级）:
#   1. 快速路径: 基于名称前缀的硬编码规则 (luci-app-* -> feeds/luci/applications)
#   2. SECTION 映射: 从 Makefile 提取 SECTION 变量并映射到对应 feed
#   3. 名称启发式: 基于名称模式推测分类 (net-* -> feeds/packages/net)
#   4. 默认回退: 无法识别时放入 feeds/base
#
# Arguments:
#   $1 - 软件包目录的绝对路径
#   $2 - 软件包名称 (PKG_NAME)
#
# Outputs:
#   目标符号链接路径到 stdout (如 "feeds/luci/applications/luci-app-xxx")
#   解析过程日志到 stderr (通过 log)
#
# Returns:
#   0 - 总是成功
#######################################
resolve_target_path() {
    local abs_dir="$1"
    local pkg_name="$2"
    local target_path=''

    # 策略 1: LuCI 软件包快速路径（基于命名约定）
    if [[ "${pkg_name}" == luci-app-* ]]; then
        target_path="feeds/luci/applications/${pkg_name}"
        log 'INFO' '  Fast path: luci-app-* -> applications'
    elif [[ "${pkg_name}" == luci-theme-* ]]; then
        target_path="feeds/luci/themes/${pkg_name}"
        log 'INFO' '  Fast path: luci-theme-* -> themes'
    elif [[ "${pkg_name}" == luci-lib-* ]]; then
        target_path="feeds/luci/libs/${pkg_name}"
        log 'INFO' '  Fast path: luci-lib-* -> libs'
    elif [[ "${pkg_name}" == luci-proto-* ]]; then
        target_path="feeds/luci/protocols/${pkg_name}"
        log 'INFO' '  Fast path: luci-proto-* -> protocols'
    else
        # 策略 2: 从 Makefile 提取 SECTION 变量
        local makefile="${abs_dir}/Makefile"
        local section=''
        if [[ -f "${makefile}" ]]; then
            section="$(grep -E '^\s*SECTION\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*SECTION\s*:?=\s*([^[:space:]]+).*$/\1/')"
        fi
        log 'INFO' "  Extracted SECTION from Makefile: '${section}'"

        if [[ -n "${section}" ]]; then
            case "${section}" in
            luci)
                target_path="feeds/luci/applications/${pkg_name}"
                log 'INFO' "  Mapped SECTION=luci -> feeds/luci/applications"
                ;;
            net | network)
                target_path="feeds/packages/net/${pkg_name}"
                log 'INFO' "  Mapped SECTION=net -> feeds/packages/net"
                ;;
            utils | utilities)
                target_path="feeds/packages/utils/${pkg_name}"
                log 'INFO' "  Mapped SECTION=utils -> feeds/packages/utils"
                ;;
            lang | languages)
                target_path="feeds/packages/lang/${pkg_name}"
                log 'INFO' "  Mapped SECTION=lang -> feeds/packages/lang"
                ;;
            libs | libraries)
                target_path="feeds/packages/libs/${pkg_name}"
                log 'INFO' "  Mapped SECTION=libs -> feeds/packages/libs"
                ;;
            admin | administration)
                target_path="feeds/packages/admin/${pkg_name}"
                log 'INFO' "  Mapped SECTION=admin -> feeds/packages/admin"
                ;;
            devel | development)
                target_path="feeds/packages/devel/${pkg_name}"
                log 'INFO' "  Mapped SECTION=devel -> feeds/packages/devel"
                ;;
            multimedia)
                target_path="feeds/packages/multimedia/${pkg_name}"
                log 'INFO' "  Mapped SECTION=multimedia -> feeds/packages/multimedia"
                ;;
            kernel)
                target_path="feeds/packages/kernel/${pkg_name}"
                log 'INFO' "  Mapped SECTION=kernel -> feeds/packages/kernel"
                ;;
            base)
                target_path="feeds/packages/base/${pkg_name}"
                log 'INFO' "  Mapped SECTION=base -> feeds/packages/base"
                ;;
            *)
                log 'WARN' "  Unknown SECTION '${section}', falling back to name heuristics"
                ;;
            esac
        fi

        # 策略 3: 名称启发式（SECTION 未知或为空时）
        if [[ -z "${target_path}" ]]; then
            if [[ "${pkg_name}" == net-* ]] || [[ "${pkg_name}" == network-* ]]; then
                target_path="feeds/packages/net/${pkg_name}"
                log 'INFO' "  Name heuristic: net-* -> feeds/packages/net"
            elif [[ "${pkg_name}" == *-utils ]] || [[ "${pkg_name}" == *-tools ]]; then
                target_path="feeds/packages/utils/${pkg_name}"
                log 'INFO' "  Name heuristic: *-utils/tools -> feeds/packages/utils"
            elif [[ "${pkg_name}" == lang-* ]]; then
                target_path="feeds/packages/lang/${pkg_name}"
                log 'INFO' "  Name heuristic: lang-* -> feeds/packages/lang"
            elif [[ "${pkg_name}" == lib* ]] || [[ "${pkg_name}" == *-lib ]]; then
                target_path="feeds/packages/libs/${pkg_name}"
                log 'INFO' "  Name heuristic: lib* -> feeds/packages/libs"
            else
                target_path="feeds/base/${pkg_name}"
                log 'INFO' "  Default fallback -> feeds/base"
            fi
        fi
    fi

    # 最终输出目标路径（关键！之前缺失了这一行）
    printf '%s' "${target_path}"
}

#######################################
# 为自定义软件包创建符号链接（带缓存优化）
#
# 扫描自定义软件包目录，为每个包创建指向 feeds 目录的符号链接。
# 核心特性:
#   1. 缓存机制: 通过 Makefile 修改时间判断是否需要重新解析
#   2. 手动覆盖: 支持在缓存文件中手动指定目标路径
#   3. 跳过选项: 支持标记某些包跳过链接创建
#   4. 智能扫描: 自动排除 .git 和 files 目录
#
# 缓存格式 (.symlink_cache):
#   自动条目: relative_path|mtime|target_path
#   手动条目: relative_path|manual|target_path|skip
#
# Arguments:
#   $1 - 自定义软件包根目录路径
#
# Globals:
#   TOPDIR - OpenWrt 源码根目录（自动检测或使用已设置的值）
#
# Outputs:
#   处理进度和统计信息到 stderr (通过 log)
#
# Returns:
#   0 - 成功
#   1 - 目录不存在或无法检测 TOPDIR
#
# Files Modified:
#   ${custom_dir}/.symlink_cache - 缓存文件
#   feeds/*/.../* - 创建的符号链接
#
# Examples:
#   create_symlinks 'custom-packages'
#######################################
create_symlinks() {
    local custom_dir="$1"

    if [[ ! -d "${custom_dir}" ]]; then
        log 'ERROR' "Custom directory ${custom_dir} does not exist."
        return 1
    fi

    log 'INFO' "Starting symlink creation for packages in ${custom_dir}"

    # 自动检测 OpenWrt 源码根目录
    if [[ -z "${TOPDIR}" ]]; then
        if [[ -f './rules.mk' ]]; then
            export TOPDIR="${PWD}"
            log 'INFO' "Auto-detected TOPDIR: ${TOPDIR}"
        elif [[ -f '../rules.mk' ]]; then
            export TOPDIR="${PWD%/*}"
            log 'INFO' "Auto-detected TOPDIR: ${TOPDIR}"
        else
            log 'ERROR' 'Cannot find OpenWrt TOPDIR (rules.mk not found).'
            return 1
        fi
    fi

    local cache_file="${custom_dir}/.symlink_cache"
    declare -A cache_map   # 自动缓存: rel_path -> "mtime|target"
    declare -A manual_map  # 手动条目: rel_path -> target_path
    declare -A manual_skip # 跳过标记: rel_path -> "skip"

    # 加载现有缓存（相对路径相对于 custom_dir）
    if [[ -f "${cache_file}" ]]; then
        log 'INFO' "Loading cache from ${cache_file}"
        local auto_count=0 manual_count=0
        while IFS='|' read -r rel_path mtime target_path skip_flag; do
            # 跳过注释行和空行
            [[ -z "${rel_path}" || "${rel_path}" == \#* ]] && continue

            # 验证源目录是否仍然存在
            if [[ ! -d "${custom_dir}/${rel_path}" ]]; then
                log 'WARN' "Stale cache entry '${rel_path}' (source missing), skipping."
                continue
            fi

            # 根据 mtime 字段判断条目类型
            if [[ "${mtime}" =~ ^[0-9]+$ ]]; then
                # 数字 mtime: 自动生成的条目
                cache_map["${rel_path}"]="${mtime}|${target_path}"
                ((auto_count++))
            else
                # "manual": 用户手动定义的条目
                manual_map["${rel_path}"]="${target_path}"
                [[ "${skip_flag}" == "skip" ]] && manual_skip["${rel_path}"]="skip"
                ((manual_count++))
            fi
        done <"${cache_file}"
        log 'INFO' "Loaded ${auto_count} auto + ${manual_count} manual cache entries"
    fi

    local total_packages=0 successful_links=0 failed_links=0
    local cache_hits=0 cache_misses=0

    log 'INFO' "Scanning for package directories (containing Makefile) under ${custom_dir}..."

    # 扫描所有包含 Makefile 的目录（排除 .git 和 files）
    while IFS= read -r dir; do
        [[ "${dir}" == "${custom_dir}" ]] && continue

        ((total_packages++))
        local abs_dir
        abs_dir="$(cd "${dir}" && pwd)"

        # 提取软件包名称
        local pkg_name
        pkg_name="$(extract_pkg_name "${abs_dir}")"
        if [[ -z "${pkg_name}" ]]; then
            pkg_name="$(basename "${dir}")"
        fi

        log 'INFO' '----------------------------------------'
        log 'INFO' "Processing package #${total_packages}: ${pkg_name} (directory: $(basename "${dir}"))"
        log 'INFO' "Source directory: ${abs_dir}"

        # 计算相对于 custom_dir 的路径
        local abs_custom_dir
        abs_custom_dir="$(cd "${custom_dir}" && pwd)"
        local rel_path="${abs_dir#"${abs_custom_dir}"/}"

        local makefile_path="${abs_dir}/Makefile"
        local current_mtime
        current_mtime="$(stat -c %Y "${makefile_path}" 2>/dev/null || printf '0')"

        local target_path=''
        local used_cache=0
        local skip_this=0

        # 优先检查手动定义条目
        if [[ -n "${manual_map[${rel_path}]}" ]]; then
            target_path="${manual_map[${rel_path}]}"
            [[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_this=1
            log 'INFO' "Using manual entry: target='${target_path}', skip=${skip_this}"
            used_cache=1
            ((cache_hits++))
        fi

        # 检查自动缓存（仅当没有手动定义时）
        if [[ ${used_cache} -eq 0 && -n "${cache_map[${rel_path}]}" ]]; then
            local cached_entry="${cache_map[${rel_path}]}"
            local cached_mtime="${cached_entry%%|*}"
            local cached_target="${cached_entry#*|}"

            if [[ "${cached_mtime}" == "${current_mtime}" ]]; then
                # 缓存有效（Makefile 未修改）
                target_path="${cached_target}"
                used_cache=1
                ((cache_hits++))
                log 'INFO' "Cache hit (mtime ${current_mtime}) -> ${target_path}"
            else
                # 缓存失效（Makefile 已修改）
                log 'INFO' "Cache stale (mtime changed: ${cached_mtime} -> ${current_mtime})"
                unset "cache_map[${rel_path}]"
            fi
        fi

        # 缓存未命中，重新解析
        if [[ ${used_cache} -eq 0 ]]; then
            ((cache_misses++))
            target_path="$(resolve_target_path "${abs_dir}" "${pkg_name}")"
            if [[ -n "${target_path}" ]]; then
                # 保存到缓存（不覆盖手动条目）
                if [[ -z "${manual_map[${rel_path}]}" ]]; then
                    cache_map["${rel_path}"]="${current_mtime}|${target_path}"
                    log 'INFO' "Cached new entry: ${rel_path} -> ${target_path}"
                fi
            fi
        fi

        if [[ -z "${target_path}" ]]; then
            log 'ERROR' "  Could not determine target path for ${pkg_name}, skipping."
            ((failed_links++))
            continue
        fi

        if [[ ${skip_this} -eq 1 ]]; then
            log 'INFO' "Skipping symlink creation due to manual skip flag."
            continue
        fi

        log 'INFO' "Target symlink path: ${target_path}"

        # 创建符号链接
        if create_relative_symlink "${abs_dir}" "${target_path}"; then
            ((successful_links++))
        else
            ((failed_links++))
        fi
    done < <(find "${custom_dir}" -type d \( -name '.git' -o -name 'files' \) -prune -o \
        -type d -exec test -f {}/Makefile \; -print -prune | sort)

    # 处理仅在缓存中存在的手动条目（没有 Makefile 的目录）
    if [[ ${#manual_map[@]} -gt 0 ]]; then
        log 'INFO' 'Processing manual-only symlink entries...'
        for rel_path in "${!manual_map[@]}"; do
            # 跳过已在扫描中处理的条目
            [[ -f "${custom_dir}/${rel_path}/Makefile" ]] && continue

            local abs_dir="${custom_dir}/${rel_path}"
            local target_path="${manual_map[${rel_path}]}"
            local skip_this=0
            [[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_this=1

            if [[ ! -d "${abs_dir}" ]]; then
                log 'WARN' "Manual entry source directory not found: ${abs_dir}, skipping."
                continue
            fi

            if [[ ${skip_this} -eq 1 ]]; then
                log 'INFO' "Manual entry (skip): ${rel_path} -> ${target_path} (skipped)"
                continue
            fi

            log 'INFO' "Manual entry: ${rel_path} -> ${target_path}"

            if create_relative_symlink "${abs_dir}" "${target_path}"; then
                ((successful_links++))
            else
                ((failed_links++))
            fi
        done
    fi

    # 保存更新后的缓存
    {
        printf '# OpenWrt package symlink cache\n'
        printf '# Format: relative_path|mtime|target_path|skip_flag  (mtime=manual for user-defined entries)\n'
        for rel_path in "${!cache_map[@]}"; do
            printf '%s|%s\n' "${rel_path}" "${cache_map[${rel_path}]}"
        done
        for rel_path in "${!manual_map[@]}"; do
            local skip_part=""
            [[ "${manual_skip[${rel_path}]}" == "skip" ]] && skip_part="|skip"
            printf '%s|manual|%s%s\n' "${rel_path}" "${manual_map[${rel_path}]}" "${skip_part}"
        done
    } >"${cache_file}.tmp" && mv "${cache_file}.tmp" "${cache_file}"

    # 输出统计信息
    log 'INFO' "Cache saved with ${#cache_map[@]} auto + ${#manual_map[@]} manual entries"
    log 'INFO' '========================================'
    log 'INFO' 'Symlink creation completed.'
    log 'INFO' "Total packages processed: ${total_packages}"
    log 'INFO' "Cache hits: ${cache_hits}"
    log 'INFO' "Cache misses: ${cache_misses}"
    log 'INFO' "Manual entries processed: ${#manual_map[@]}"
    log 'INFO' "Successful symlinks: ${successful_links}"
    log 'INFO' "Failed symlinks: ${failed_links}"
}

#######################################
# 修改 LuCI 集合 Makefile
#
# 对 LuCI 集合软件包的 Makefile 应用 sed 表达式，用于调整依赖关系。
# 典型用途: 移除 uhttpd 依赖、替换默认主题、删除不需要的应用。
#
# Arguments:
#   $1 - Makefile 文件路径
#   $2... - sed 表达式参数（直接传递给 sed -i）
#
# Globals:
#   None
#
# Outputs:
#   操作提示到 stdout
#   错误信息到 stderr
#
# Returns:
#   0 - 总是成功（即使文件不存在）
#
# Examples:
#   modify_luci_collection 'feeds/luci/collections/luci/Makefile' \
#     -e '/LUCI_DEPENDS/,/^$/ { /uhttpd/d; }'
#######################################
modify_luci_collection() {
    local makefile="$1"
    shift
    local sed_exprs=("$@")

    if [[ -f "${makefile}" ]]; then
        log 'INFO' 'Modifying ${makefile}……'
        sed -i "${sed_exprs[@]}" "${makefile}"
    else
        log 'ERROR' 'File ${makefile} does not exist.'
    fi
}

#######################################
# 修改软件包 Makefile 中的指定变量值（键值对）
#
# 使用 nameref 接收关联数组名，遍历键并替换 Makefile 中的对应行。
# 若数组未声明或目标文件不存在，则输出错误/警告并安全返回。
#
# Arguments:
#   $1 - Makefile 路径
#   $2 - 关联数组变量名（必须预先声明）
#
# Returns:
#   0 - 成功修改
#   1 - 数组不存在
#######################################
set_makefile_vars() {
    local makefile="$1"
    local array_name="$2"

    # 使用 declare -p 检测变量是否已声明（比 -v 更可靠）
    if ! declare -p "${array_name}" &>/dev/null; then
        log ERROR "Array '${array_name}' does not exist."
        return 1
    fi

    if [[ ! -f "${makefile}" ]]; then
        log WARN "Makefile ${makefile} not found, skipping var update."
        return 0
    fi

    # 创建 nameref 引用调用者的数组
    local -n _ref="${array_name}"

    for key in "${!_ref[@]}"; do
        sed -i "s|^${key}:=.*|${key}:=${_ref[$key]}|" "${makefile}"
    done

    log INFO "Updated ${#_ref[@]} variables in ${makefile}"
}

#######################################
# 将版本号转换为 OpenWrt 兼容格式
#
# 对于包含预发布标识（rc、beta、alpha 等）的版本号，
# 在标识前插入下划线，例如：
#   1.1.0rc1  ->  1.1.0_rc1
#   2.0.0beta2 -> 2.0.0_beta2
#
# Arguments:
#   $1 - 原始版本号
#
# Outputs:
#   转换后的版本号到 stdout
#
# Examples:
#   normalize_pkg_version "1.1.0rc1"    # 输出: 1.1.0_rc1
#######################################
normalize_pkg_version() {
    local version="$1"
    if [[ "${version}" =~ ^([0-9.]+)(rc|beta|alpha|pre|preview)(.*)$ ]]; then
        printf '%s_%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${version}"
    fi
}

#######################################
# 下载文件并计算其 SHA256 哈希值（增强版）
#
# 自动选择可用下载工具，支持重试、超时、下载验证，
# 适用于构建过程中获取源码包并校验完整性。
#
# Arguments:
#   $1 - 下载 URL（必需，建议 HTTPS）
#   $2 - 保存的文件名（可选，默认从 URL 提取）
#   $3 - 重试次数（可选，默认 3）
#
# Outputs:
#   SHA256 哈希值（64 位十六进制字符串）到 stdout
#   状态信息与错误到 stderr（通过 log 函数）
#
# Returns:
#   0 - 成功下载并计算哈希
#   1 - 多次重试后仍然失败，或工具缺失
#
# Examples:
#   hash=$(download_and_hash "https://example.com/archive.zip")
#   hash=$(download_and_hash "https://example.com/archive.tar.gz" "source.tar.gz" 5)
#######################################
download_and_hash() {
    local url="$1"
    local filename="${2:-}"
    local retries="${3:-3}"
    local attempt=0

    # 创建临时目录（退出时自动清理）
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    if [[ -z "${filename}" ]]; then
        filename=$(basename "${url}" | sed 's/\?.*//;s/#.*//')
        [[ -z "${filename}" ]] && filename="download.$$"
    fi
    local outfile="${tmpdir}/${filename}"

    # 检测可用下载工具
    local downloader=""
    if command -v curl &>/dev/null; then
        downloader="curl"
    elif command -v wget &>/dev/null; then
        downloader="wget"
    else
        log ERROR "Neither curl nor wget is available"
        return 1
    fi

    # 循环重试
    while ((attempt < retries)); do
        ((attempt++))
        log INFO "Downloading ${url} (attempt ${attempt}/${retries})..."

        # 使用 curl 下载
        if [[ "${downloader}" == "curl" ]]; then
            # --connect-timeout 10s, 总下载时间 60s, 跟随重定向, 显示进度但不污染 stdout
            if curl -sS -L --connect-timeout 10 --max-time 60 -o "${outfile}" --fail "${url}"; then
                log DEBUG "curl download succeeded"
                break
            else
                log WARN "curl download failed (exit code $?)"
            fi
        # 使用 wget 下载
        elif [[ "${downloader}" == "wget" ]]; then
            # --timeout=10 连接超时, 读取超时 60s, 重试 0 次（本层循环控制）
            if wget -nv --timeout=10 --read-timeout=60 -O "${outfile}" "${url}"; then
                log DEBUG "wget download succeeded"
                break
            else
                log WARN "wget download failed (exit code $?)"
            fi
        fi

        # 下载失败但还有重试机会，等待递增间隔
        if ((attempt < retries)); then
            sleep $((attempt * 2))
        else
            log ERROR "Failed to download ${url} after ${retries} attempts"
            return 1
        fi
    done

    # 验证下载文件大小 > 0
    if [[ ! -s "${outfile}" ]]; then
        log ERROR "Downloaded file is empty: ${outfile}"
        return 1
    fi

    # 计算 SHA256
    local hash=""
    if command -v sha256sum &>/dev/null; then
        hash=$(sha256sum "${outfile}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        hash=$(shasum -a 256 "${outfile}" | awk '{print $1}')
    else
        log ERROR "No sha256sum or shasum found"
        return 1
    fi

    # 哈希合法性校验（长度应为 64）
    if [[ ${#hash} -ne 64 ]]; then
        log ERROR "Computed hash length is ${#hash}, expected 64"
        return 1
    fi

    log INFO "Downloaded and computed hash: ${hash}"
    printf '%s' "${hash}"
}
