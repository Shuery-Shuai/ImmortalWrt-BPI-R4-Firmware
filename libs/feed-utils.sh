#!/bin/bash
#######################################
# Feed 路径解析与批量符号链接创建
#
# 提供：
#   - extract_pkg_name      从 Makefile 提取包名
#   - resolve_target_path   智能解析包的目标 feed 路径
#   - create_symlinks       扫描自定义包目录并批量创建符号链接（带缓存）
#
# 依赖：若未 source logger.sh，将启用后备日志函数。
#       内部使用 relpath / create_relative_symlink（定义于 symlink-utils.sh），
#       请确保在调用 create_symlinks 前已加载相关函数。
# 用法：source common/scripts/libs/feed-utils.sh
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

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
# 参数：
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
            fonts)
                target_path="feeds/packages/fonts/${pkg_name}"
                log 'INFO' "  Mapped SECTION=fonts -> feeds/packages/fonts"
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
# 参数：
#   $1 - 自定义软件包根目录路径
#
# 全局变量：
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
