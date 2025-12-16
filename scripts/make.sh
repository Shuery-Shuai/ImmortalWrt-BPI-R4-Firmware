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

# 清理小文件
clean_small_files() {
    log_info "清理下载目录中的小文件..."
    local count=0
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            log_info "删除: $(basename "$file")"
            rm -f "$file"
            ((count++))
        fi
    done < <(find dl -size -1024c -print0 2>/dev/null)

    if [ $count -eq 0 ]; then
        log_info "未找到需要清理的小文件"
    else
        log_info "已清理 $count 个小文件"
    fi
}

# 编译固件
compile_firmware() {
    local cpu_count
    cpu_count=$(nproc)
    local make_jobs=$((cpu_count + 1))

    log_info "开始编译固件 (使用 $make_jobs 个并行任务)..."

    # 设置PATH环境变量
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # 尝试编译，如果失败则降级到单线程并输出详细信息
    if make -j"$make_jobs"; then
        log_success "编译完成"
    else
        log_warning "并行编译失败，尝试单线程详细编译..."
        if make -j1 V=sc; then
            log_success "单线程编译完成"
        else
            log_error "编译失败，请检查错误日志。"
            return 1
        fi
    fi
}

# 主函数
main() {
    log_info "开始固件编译流程..."

    # 清除immortalwrt文件夹下的所有更改
    clean_immortalwrt_changes

    # 设置配置
    bash "${SCRIPT_DIR}/set-config.sh"

    # 清理小文件
    clean_small_files

    # 下载依赖
    log_info "开始下载依赖包..."
    if make download; then
        log_success "依赖包下载完成"
    else
        log_error "依赖包下载失败"
        exit 1
    fi

    # 编译固件
    compile_firmware
}

# 执行主函数
main "$@"
