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

# 主配置函数
main() {
    log_info "开始设置编译配置..."

    # 设置标志，避免子脚本重复执行准备操作
    export IMMORTALWRT_PREPARED=1

    # 清除immortalwrt文件夹下的所有更改
    clean_immortalwrt_changes

    # 执行各个配置脚本
    bash "${SCRIPT_DIR}/prepare-workdir.sh"
    bash "${SCRIPT_DIR}/set-module-config.sh"
    bash "${SCRIPT_DIR}/set-firmware-config.sh"

    # 复制最终的.config文件
    if [ -f "immortalwrt/.config" ]; then
        cp ./immortalwrt/.config ./
        log_success "配置已复制到当前目录"
    else
        log_warning "未找到immortalwrt/.config文件"
    fi

    log_success "配置设置完成"
}

# 执行主函数
main "$@"
