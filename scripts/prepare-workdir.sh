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

# 主函数
main() {
    log_info "开始设置immortalwrt工作空间..."

    # 清除immortalwrt文件夹下的所有更改
    clean_immortalwrt_changes

    # 准备immortalwrt仓库
    prepare_immortalwrt

    # 复制自定义文件
    copy_custom_files

    log_success "immortalwrt工作空间准备完成"
}

# 执行主函数
main "$@"
