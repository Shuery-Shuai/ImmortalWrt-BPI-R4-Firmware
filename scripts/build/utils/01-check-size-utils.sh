# scripts/build/utils/01-check-size-utils.sh —— 固件体积统计工具函数（被 source，不直接执行）
# shellcheck shell=bash
#
# 只定义函数，不含 main、不调用任何动作：作为 utils 里的纯函数，符合『无状态、通用、小粒度』的要求。
# 调用方是 scripts/build/build.sh 的 check 阶段，以及任何 source 了本文件的脚本。
# 前提：调用方需先加载 scripts/libs/01-shell-logger.sh 与 scripts/build/pipeline.sh（本文件用 log_info/log_success
# 与 enter_immortalwrt_dir）。

# 统计 bin/targets 下固件产物的体积，不修改工作区。
# 输出：按类型分组的文件清单 + 总计。
check_firmware_size() {
    local search_dir="bin/targets"
    local -a file_types=("*.bin" "*.itb" "*.img.gz" "*.fip")

    log_info "Starting firmware file size check..."

    enter_immortalwrt_dir

    local total_count=0
    local total_size=0
    declare -A type_count=()

    echo "----------------------------------------"

    local type count file size human_size
    for type in "${file_types[@]}"; do
        count=0
        echo "【${type} files】"

        while IFS= read -r -d '' file; do
            size=$(stat -c %s "${file}" 2>/dev/null || echo 0)
            human_size=$(numfmt --to=iec-i --suffix=B "${size}" 2>/dev/null || echo "0B")
            printf '%-10s %s\n' "${human_size}" "$(realpath --relative-to=. "${file}")"

            ((total_count++))
            total_size=$((total_size + size))
            ((count++))
            type_count["${type}"]=$(( ${type_count["${type}"]:-0} + 1 ))
        done < <(find "${search_dir}" -type f -iname "${type}" -print0 2>/dev/null)

        [[ ${count} -eq 0 ]] && echo "    (No files found)"
        echo ""
    done

    echo "----------------------------------------"
    echo "Total files: ${total_count}"

    if command -v numfmt >/dev/null 2>&1; then
        echo "Total size: $(numfmt --to=iec-i --suffix=B "${total_size}") (${total_size} bytes)"
    else
        echo "Total size: ${total_size} bytes"
    fi

    if [[ ${total_count} -gt 0 ]]; then
        echo "Distribution by type:"
        for type in "${file_types[@]}"; do
            count=${type_count["${type}"]:-0}
            [[ ${count} -gt 0 ]] && echo "  ${type}: ${count} files"
        done
    fi

    echo "----------------------------------------"
    log_success "Firmware file check completed"
}
