#!/bin/bash
#######################################
# Feed 路径解析与批量符号链接创建
#
# 提供：
#   - extract_pkg_name      从 Makefile 提取包名
#   - resolve_target_path   智能解析包的目标 feed 路径
#   - create_symlinks       扫描自定义包目录并批量创建符号链接（带缓存）
#
# 依赖：log 由 logger.sh 提供（index.sh 已保证其最先加载，本文件不再自带后备实现）。
#       内部使用 relpath / create_relative_symlink（定义于 01-symlink-utils.sh），
#       请确保在调用 create_symlinks 前已加载相关函数。
# 用法：source scripts/inputs/utils/06-feed-utils.sh
#######################################

#######################################
# 从 Makefile 提取软件包名称
#
# 尝试从软件包的 Makefile 中提取 PKG_NAME 变量值。
# 如果未找到或 Makefile 不存在，则使用目录名作为回退。
#
# 参数：
#   $1 - 软件包目录的绝对路径
#
# 全局变量：
#   None
#
# 输出：
#   软件包名称到 stdout
#
# 返回：
#   0 - 成功提取或使用回退值
#   1 - Makefile 不存在
#
# 示例：
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
# 参数：
#   $1 - 软件包目录的绝对路径
#   $2 - 软件包名称 (PKG_NAME)
#
# 输出：
#   目标符号链接路径到 stdout (如 "feeds/luci/applications/luci-app-xxx")
#   解析过程日志到 stderr (通过 log)
#
# 返回：
#   0 - 总是成功
#######################################
resolve_target_path() {
    local abs_dir="$1"
    local pkg_name="$2"
    local target_path

    target_path="$(_feed_resolve_by_name_prefix "${pkg_name}")"
    if [[ -z "${target_path}" ]]; then
        local section
        section="$(_feed_extract_section "${abs_dir}")"
        log 'INFO' "  Extracted SECTION from Makefile: '${section}'"
        target_path="$(_feed_resolve_by_section "${pkg_name}" "${section}")"
    fi

    if [[ -z "${target_path}" ]]; then
        target_path="$(_feed_resolve_by_name_heuristic "${pkg_name}")"
    fi

    printf '%s' "${target_path}"
}

#######################################
# 策略 1：按软件包名称前缀映射到 LuCI feed 的分类目录
#
# 参数：
#   $1 - 软件包名称 (PKG_NAME)
#
# 输出：
#   目标路径到 stdout；不是 LuCI 类别前缀时输出空串
#######################################
_feed_resolve_by_name_prefix() {
    local pkg_name="$1"

    case "${pkg_name}" in
    luci-app-*)
        log 'INFO' '  Fast path: luci-app-* -> applications'
        printf '%s' "feeds/luci/applications/${pkg_name}"
        ;;
    luci-theme-*)
        log 'INFO' '  Fast path: luci-theme-* -> themes'
        printf '%s' "feeds/luci/themes/${pkg_name}"
        ;;
    luci-lib-*)
        log 'INFO' '  Fast path: luci-lib-* -> libs'
        printf '%s' "feeds/luci/libs/${pkg_name}"
        ;;
    luci-proto-*)
        log 'INFO' '  Fast path: luci-proto-* -> protocols'
        printf '%s' "feeds/luci/protocols/${pkg_name}"
        ;;
    esac
}

#######################################
# 策略 2a：从 Makefile 提取 SECTION 变量
#
# 参数：
#   $1 - 软件包目录的绝对路径
#
# 输出：
#   SECTION 的值到 stdout；无 Makefile 或未定义时输出空串
#######################################
_feed_extract_section() {
    local abs_dir="$1"
    local makefile="${abs_dir}/Makefile"

    if [[ -f "${makefile}" ]]; then
        grep -E '^\s*SECTION\s*:?=' "${makefile}" | head -1 | sed -E 's/^\s*SECTION\s*:?=\s*([^[:space:]]+).*$/\1/'
    fi
}

#######################################
# 策略 2b：把 SECTION 映射到对应的 packages feed 分类目录
#
# 参数：
#   $1 - 软件包名称 (PKG_NAME)
#   $2 - SECTION 值
#
# 输出：
#   目标路径到 stdout；未知 SECTION 时输出空串
#######################################
_feed_resolve_by_section() {
    local pkg_name="$1"
    local section="$2"

    case "${section}" in
    luci)
        log 'INFO' "  Mapped SECTION=luci -> feeds/luci/applications"
        printf '%s' "feeds/luci/applications/${pkg_name}"
        ;;
    net | network)
        log 'INFO' "  Mapped SECTION=net -> feeds/packages/net"
        printf '%s' "feeds/packages/net/${pkg_name}"
        ;;
    utils | utilities)
        log 'INFO' "  Mapped SECTION=utils -> feeds/packages/utils"
        printf '%s' "feeds/packages/utils/${pkg_name}"
        ;;
    lang | languages)
        log 'INFO' "  Mapped SECTION=lang -> feeds/packages/lang"
        printf '%s' "feeds/packages/lang/${pkg_name}"
        ;;
    libs | libraries)
        log 'INFO' "  Mapped SECTION=libs -> feeds/packages/libs"
        printf '%s' "feeds/packages/libs/${pkg_name}"
        ;;
    admin | administration)
        log 'INFO' "  Mapped SECTION=admin -> feeds/packages/admin"
        printf '%s' "feeds/packages/admin/${pkg_name}"
        ;;
    devel | development)
        log 'INFO' "  Mapped SECTION=devel -> feeds/packages/devel"
        printf '%s' "feeds/packages/devel/${pkg_name}"
        ;;
    multimedia)
        log 'INFO' "  Mapped SECTION=multimedia -> feeds/packages/multimedia"
        printf '%s' "feeds/packages/multimedia/${pkg_name}"
        ;;
    kernel)
        log 'INFO' "  Mapped SECTION=kernel -> feeds/packages/kernel"
        printf '%s' "feeds/packages/kernel/${pkg_name}"
        ;;
    base)
        log 'INFO' "  Mapped SECTION=base -> feeds/packages/base"
        printf '%s' "feeds/packages/base/${pkg_name}"
        ;;
    fonts)
        log 'INFO' "  Mapped SECTION=fonts -> feeds/packages/fonts"
        printf '%s' "feeds/packages/fonts/${pkg_name}"
        ;;
    "") ;;
    *)
        log 'WARN' "  Unknown SECTION '${section}', falling back to name heuristics"
        ;;
    esac
}

#######################################
# 策略 3：按软件包名称模式推测分类
#
# 参数：
#   $1 - 软件包名称 (PKG_NAME)
#
# 输出：
#   目标路径到 stdout；无法推测时输出 feeds/base 回退路径
#######################################
_feed_resolve_by_name_heuristic() {
    local pkg_name="$1"

    if [[ "${pkg_name}" == net-* ]] || [[ "${pkg_name}" == network-* ]]; then
        log 'INFO' "  Name heuristic: net-* -> feeds/packages/net"
        printf '%s' "feeds/packages/net/${pkg_name}"
    elif [[ "${pkg_name}" == *-utils ]] || [[ "${pkg_name}" == *-tools ]]; then
        log 'INFO' "  Name heuristic: *-utils/tools -> feeds/packages/utils"
        printf '%s' "feeds/packages/utils/${pkg_name}"
    elif [[ "${pkg_name}" == lang-* ]]; then
        log 'INFO' "  Name heuristic: lang-* -> feeds/packages/lang"
        printf '%s' "feeds/packages/lang/${pkg_name}"
    elif [[ "${pkg_name}" == lib* ]] || [[ "${pkg_name}" == *-lib ]]; then
        log 'INFO' "  Name heuristic: lib* -> feeds/packages/libs"
        printf '%s' "feeds/packages/libs/${pkg_name}"
    else
        log 'INFO' "  Default fallback -> feeds/base"
        printf '%s' "feeds/base/${pkg_name}"
    fi
}

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
# 参数：
#   $1 - 自定义软件包根目录路径
#
# 全局变量：
#   TOPDIR - OpenWrt 源码根目录（自动检测或使用已设置的值）
#
# 输出：
#   处理进度和统计信息到 stderr (通过 log)
#
# 返回：
#   0 - 成功
#   1 - 目录不存在或无法检测 TOPDIR
#
# 文件修改：
#   ${custom_dir}/.symlink_cache - 缓存文件
#   feeds/*/.../* - 创建的符号链接
#
# 示例：
#   create_symlinks 'custom-packages'
#######################################
create_symlinks() {
    local custom_dir="$1"

    if [[ ! -d "${custom_dir}" ]]; then
        log 'ERROR' "Custom directory ${custom_dir} does not exist."
        return 1
    fi

    log 'INFO' "Starting symlink creation for packages in ${custom_dir}"

    _feed_ensure_topdir || return 1

    local cache_file="${custom_dir}/.symlink_cache"
    # 缓存表与统计计数器由本函数持有；下面的 _feed_* 辅助函数通过 bash 的动态作用域
    # 读写这些局部变量（调用者作用域即被调者可见作用域），因此签名里不传表名。
    local -A cache_map=()
    local -A manual_map=()
    local -A manual_skip=()
    local total_packages=0
    local successful_links=0
    local failed_links=0
    local cache_hits=0
    local cache_misses=0

    _feed_load_symlink_cache "${custom_dir}" "${cache_file}"

    log 'INFO' "Scanning for package directories (containing Makefile) under ${custom_dir}..."
    local dir
    while IFS= read -r dir; do
        _feed_process_scanned_package "${custom_dir}" "${dir}"
    done < <(_feed_scan_package_dirs "${custom_dir}")

    _feed_link_manual_only_entries "${custom_dir}"
    _feed_save_symlink_cache "${cache_file}"
    _feed_log_symlink_summary
}

#######################################
# 自动检测 OpenWrt 源码根目录并导出 TOPDIR
#
# 已设置 TOPDIR 时直接返回；否则依次尝试 ./rules.mk 与 ../rules.mk。
#
# 返回：
#   0 - TOPDIR 已可用
#   1 - 找不到 rules.mk
#######################################
_feed_ensure_topdir() {
    [[ -n "${TOPDIR}" ]] && return 0

    if [[ -f './rules.mk' ]]; then
        export TOPDIR="${PWD}"
        log 'INFO' "Auto-detected TOPDIR: ${TOPDIR}"
        return 0
    fi

    if [[ -f '../rules.mk' ]]; then
        export TOPDIR="${PWD%/*}"
        log 'INFO' "Auto-detected TOPDIR: ${TOPDIR}"
        return 0
    fi

    log 'ERROR' 'Cannot find OpenWrt TOPDIR (rules.mk not found).'
    return 1
}

#######################################
# 列出需要处理的自定义软件包目录
#
# 只输出包含 Makefile 的目录，并剪枝 .git 与 files。
#
# 参数：
#   $1 - 自定义软件包根目录路径
#
# 输出：
#   目录路径（每行一个，已排序）到 stdout
#######################################
_feed_scan_package_dirs() {
    local custom_dir="$1"

    find "${custom_dir}" -type d \( -name '.git' -o -name 'files' \) -prune -o \
        -type d -exec test -f {}/Makefile \; -print -prune | sort
}

#######################################
# 读取现有缓存文件，填充调用者的 cache_map / manual_map / manual_skip
#
# 参数：
#   $1 - 自定义软件包根目录路径
#   $2 - 缓存文件路径
#
# 返回：
#   0 - 总是成功（缓存不存在时什么也不做）
#######################################
_feed_load_symlink_cache() {
    local custom_dir="$1"
    local cache_file="$2"

    [[ -f "${cache_file}" ]] || return 0

    log 'INFO' "Loading cache from ${cache_file}"
    local auto_count=0
    local manual_count=0
    local rel_path mtime target_path skip_flag
    while IFS='|' read -r rel_path mtime target_path skip_flag; do
        [[ -z "${rel_path}" || "${rel_path}" == \#* ]] && continue

        if [[ ! -d "${custom_dir}/${rel_path}" ]]; then
            log 'WARN' "Stale cache entry '${rel_path}' (source missing), skipping."
            continue
        fi

        if [[ "${mtime}" =~ ^[0-9]+$ ]]; then
            cache_map["${rel_path}"]="${mtime}|${target_path}"
            ((auto_count++))
        else
            manual_map["${rel_path}"]="${target_path}"
            [[ "${skip_flag}" == "skip" ]] && manual_skip["${rel_path}"]="skip"
            ((manual_count++))
        fi
    done <"${cache_file}"
    log 'INFO' "Loaded ${auto_count} auto + ${manual_count} manual cache entries"
}

#######################################
# 处理扫描到的一个软件包目录：解析目标路径（优先命中缓存）并建立符号链接
#
# 参数：
#   $1 - 自定义软件包根目录路径
#   $2 - 扫描到的软件包目录路径
#
# 返回：
#   0 - 总是成功（失败/跳过只记日志并累加调用者的计数器）
#######################################
_feed_process_scanned_package() {
    local custom_dir="$1"
    local dir="$2"

    [[ "${dir}" == "${custom_dir}" ]] && return 0

    ((total_packages++))
    local abs_dir
    abs_dir="$(cd "${dir}" && pwd)"

    local pkg_name
    pkg_name="$(extract_pkg_name "${abs_dir}")"
    if [[ -z "${pkg_name}" ]]; then
        pkg_name="$(basename "${dir}")"
    fi

    log 'INFO' '----------------------------------------'
    log 'INFO' "Processing package #${total_packages}: ${pkg_name} (directory: $(basename "${dir}"))"
    log 'INFO' "Source directory: ${abs_dir}"

    local abs_custom_dir
    abs_custom_dir="$(cd "${custom_dir}" && pwd)"
    local rel_path="${abs_dir#"${abs_custom_dir}"/}"

    local makefile_path="${abs_dir}/Makefile"
    local current_mtime
    current_mtime="$(stat -c %Y "${makefile_path}" 2>/dev/null || printf '0')"

    local target_path=''
    local used_cache=0
    local skip_this=0

    _feed_apply_manual_entry "${rel_path}"
    _feed_apply_auto_cache "${rel_path}" "${current_mtime}"

    if [[ ${used_cache} -eq 0 ]]; then
        _feed_resolve_and_cache "${abs_dir}" "${pkg_name}" "${rel_path}" "${current_mtime}"
    fi

    if [[ -z "${target_path}" ]]; then
        log 'ERROR' "  Could not determine target path for ${pkg_name}, skipping."
        ((failed_links++))
        return 0
    fi

    if [[ ${skip_this} -eq 1 ]]; then
        log 'INFO' "Skipping symlink creation due to manual skip flag."
        return 0
    fi

    log 'INFO' "Target symlink path: ${target_path}"

    if create_relative_symlink "${abs_dir}" "${target_path}"; then
        ((successful_links++))
    else
        ((failed_links++))
    fi
}

#######################################
# 命中手动缓存条目时填充目标路径与跳过标记（写入调用者的 target_path / skip_this / used_cache）
#
# 参数：
#   $1 - 相对 custom_dir 的包路径
#
# 返回：
#   0 - 总是成功（无手动条目时什么都不改）
#######################################
_feed_apply_manual_entry() {
    local rel_path="$1"

    [[ -n "${manual_map[${rel_path}]:-}" ]] || return 0

    target_path="${manual_map[${rel_path}]}"
    [[ "${manual_skip[${rel_path}]:-}" == "skip" ]] && skip_this=1
    log 'INFO' "Using manual entry: target='${target_path}', skip=${skip_this}"
    used_cache=1
    ((cache_hits++))
}

#######################################
# 手动条目未命中时尝试自动缓存；mtime 变化则判定失效并清除该条目
#
# 参数：
#   $1 - 相对 custom_dir 的包路径
#   $2 - Makefile 当前 mtime
#
# 返回：
#   0 - 总是成功
#######################################
_feed_apply_auto_cache() {
    local rel_path="$1"
    local current_mtime="$2"

    [[ ${used_cache} -eq 0 && -n "${cache_map[${rel_path}]:-}" ]] || return 0

    local cached_entry="${cache_map[${rel_path}]}"
    local cached_mtime="${cached_entry%%|*}"
    local cached_target="${cached_entry#*|}"

    if [[ "${cached_mtime}" == "${current_mtime}" ]]; then
        target_path="${cached_target}"
        used_cache=1
        ((cache_hits++))
        log 'INFO' "Cache hit (mtime ${current_mtime}) -> ${target_path}"
        return 0
    fi

    log 'INFO' "Cache stale (mtime changed: ${cached_mtime} -> ${current_mtime})"
    unset "cache_map[${rel_path}]"
}

#######################################
# 缓存未命中时解析目标路径，并把结果写入调用者的 cache_map
#
# 参数：
#   $1 - 软件包目录绝对路径
#   $2 - 软件包名称
#   $3 - 相对 custom_dir 的包路径
#   $4 - Makefile 当前 mtime
#
# 返回：
#   0 - 总是成功
#######################################
_feed_resolve_and_cache() {
    local abs_dir="$1"
    local pkg_name="$2"
    local rel_path="$3"
    local current_mtime="$4"

    ((cache_misses++))
    target_path="$(resolve_target_path "${abs_dir}" "${pkg_name}")"
    [[ -n "${target_path}" ]] || return 0

    [[ -z "${manual_map[${rel_path}]:-}" ]] || return 0

    cache_map["${rel_path}"]="${current_mtime}|${target_path}"
    log 'INFO' "Cached new entry: ${rel_path} -> ${target_path}"
}

#######################################
# 处理仅在缓存中登记、但扫描不到 Makefile 的手动条目
#
# 参数：
#   $1 - 自定义软件包根目录路径
#
# 返回：
#   0 - 总是成功
#######################################
_feed_link_manual_only_entries() {
    local custom_dir="$1"

    [[ ${#manual_map[@]} -gt 0 ]] || return 0

    log 'INFO' 'Processing manual-only symlink entries...'
    local rel_path
    for rel_path in "${!manual_map[@]}"; do
        [[ -f "${custom_dir}/${rel_path}/Makefile" ]] && continue

        local abs_dir="${custom_dir}/${rel_path}"
        local target_path="${manual_map[${rel_path}]}"
        local skip_this=0
        [[ "${manual_skip[${rel_path}]:-}" == "skip" ]] && skip_this=1

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
}

#######################################
# 把内存中的缓存表写回缓存文件
#
# 参数：
#   $1 - 缓存文件路径
#
# 返回：
#   0 - 写入成功
#######################################
_feed_save_symlink_cache() {
    local cache_file="$1"
    local rel_path skip_part

    {
        printf '# OpenWrt package symlink cache\n'
        printf '# Format: relative_path|mtime|target_path|skip_flag  (mtime=manual for user-defined entries)\n'
        for rel_path in "${!cache_map[@]}"; do
            printf '%s|%s\n' "${rel_path}" "${cache_map[${rel_path}]}"
        done
        for rel_path in "${!manual_map[@]}"; do
            skip_part=""
            [[ "${manual_skip[${rel_path}]:-}" == "skip" ]] && skip_part="|skip"
            printf '%s|manual|%s%s\n' "${rel_path}" "${manual_map[${rel_path}]}" "${skip_part}"
        done
    } >"${cache_file}.tmp" && mv "${cache_file}.tmp" "${cache_file}"
}

#######################################
# 输出本次符号链接创建的统计信息
#
# 返回：
#   0 - 总是成功
#######################################
_feed_log_symlink_summary() {
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

