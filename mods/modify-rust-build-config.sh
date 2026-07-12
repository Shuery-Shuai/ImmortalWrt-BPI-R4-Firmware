#!/bin/bash
# 文件: common/scripts/mods/modify-rust-build-config.sh
# 用途: 修改 Rust 的构建配置，禁用 CI LLVM 下载，改用系统 LLVM
#       以加速编译过程，避免下载预编译 LLVM 二进制文件
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/modify-rust-build-config.sh
#   modify_rust_build_config [makefile_path]
#
# 参数:
#   makefile_path : Rust Makefile 的路径，默认值为 feeds/packages/lang/rust/Makefile
#
# 说明:
#   若指定文件不存在，仅输出警告，不视为错误。
#######################################

# 后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 修改 Rust 构建配置
#
# 功能:
#   在 Rust 的 Makefile 中，将 LLVM 的 CI 下载选项设为 false，
#   强制使用系统已安装的 LLVM，从而节省带宽和编译时间。
#
# Arguments:
#   $1 - Rust Makefile 的路径（可选），默认值为 feeds/packages/lang/rust/Makefile
#
# Outputs:
#   操作日志到 stderr (通过 log)
#
# Returns:
#   0 - 修改成功
#   0 - 文件不存在时仅输出警告，不视为错误
#
# Examples:
#   modify_rust_build_config
#   modify_rust_build_config 'feeds/custom/lang/rust/Makefile'
#######################################
modify_rust_build_config() {
    local makefile="${1:-feeds/packages/lang/rust/Makefile}"

    if [[ ! -f "${makefile}" ]]; then
        log WARN "Rust Makefile not found: ${makefile}, skipping."
        return 0
    fi

    log INFO "Modifying Rust build config in ${makefile}..."
    sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' "${makefile}"
    log INFO "Rust build config updated: CI LLVM download disabled."
}

# 若直接运行脚本，则执行默认修改
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    modify_rust_build_config "$@"
fi
