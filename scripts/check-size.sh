#!/bin/bash

# 保存原始目录
ORIGINAL_DIR="$(pwd)"
trap "cd '$ORIGINAL_DIR'" EXIT

# 导入通用函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    # shellcheck source=scripts/common.sh
    source "${SCRIPT_DIR}/common.sh"
else
    echo "错误: 找不到 common.sh 文件" >&2
    exit 1
fi

# 文件类型配置
readonly SEARCH_DIR="bin/targets"
readonly FILE_TYPES=("*.bin" "*.itb" "*.img.gz" "*.fip")

# 主函数
main() {
    log_info "开始检测固件文件大小..."

    # 清除immortalwrt文件夹下的所有更改
    clean_immortalwrt_changes

    # 进入immortalwrt目录
    enter_immortalwrt_dir

    local total_count=0
    local total_size=0
    declare -A type_count

    echo "----------------------------------------"

    # 遍历所有文件类型
    for type in "${FILE_TYPES[@]}"; do
        local count=0
        echo "【${type} 文件】"

        # 查找并处理文件
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                local size
                size=$(stat -c %s "$file" 2>/dev/null || echo 0)
                local human_size
                human_size=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "0B")
                printf "%-10s %s\n" "$human_size" "$(realpath --relative-to=. "$file")"

                ((total_count++))
                total_size=$((total_size + size))
                ((count++))
                type_count["$type"]=$((type_count["$type"] + 1))
            fi
        done < <(find "$SEARCH_DIR" -type f -iname "$type" -print0 2>/dev/null)

        if [ "$count" -eq 0 ]; then
            echo "    (未找到文件)"
        fi
        echo ""
    done

    # 输出统计信息
    echo "----------------------------------------"
    echo "文件总数: $total_count"

    if command -v numfmt >/dev/null 2>&1; then
        echo "总大小: $(numfmt --to=iec-i --suffix=B "$total_size") ($total_size 字节)"
    else
        echo "总大小: $total_size 字节"
    fi

    if [ "$total_count" -gt 0 ]; then
        echo "按类型分布:"
        for type in "${FILE_TYPES[@]}"; do
            local count=${type_count["$type"]:-0}
            if [ "$count" -gt 0 ]; then
                echo "  $type: $count 个"
            fi
        done
    fi

    echo "----------------------------------------"
    log_success "固件文件检测完成"
}

# 执行主函数
main "$@"
