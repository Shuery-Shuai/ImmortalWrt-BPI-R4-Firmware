#!/bin/bash
#
# ImmortalWrt 构建的唯一编排入口，把 .github/workflows/immortalwrt-builder.yml 的
# 步骤收敛成可复用的 stage，保证本地与 CI 走同一套逻辑。
#
# 用法:
#   scripts/build/build.sh deps      # 只装主机编译依赖 + upx/padjffs2/po2lmo（唯一会调用 apt 的阶段）
#   scripts/build/build.sh prepare   # 只做准备：克隆/私钥/feeds/自定义文件/.config/DIY/defconfig
#   scripts/build/build.sh download  # prepare + 下载源码包
#   scripts/build/build.sh compile   # download + 编译固件
#   scripts/build/build.sh check     # 只统计固件体积（scripts/build/utils/01-check-size-utils.sh 的 check_firmware_size），不删任何文件
#   scripts/build/build.sh all       # compile + check
#
# 阶段累进：download = prepare + 下载；compile = download + 编译；all = compile + check。
# deps 刻意是独立阶段，任何阶段都不会自动触发它：本地依赖通常已装好，
# 自动跑 apt 只会重复且慢，且需要 sudo。
#
# REQUIRED=1 为严格模式（CI 用）：缺 APK 私钥、缺依赖清单、装依赖失败都硬失败；
# 默认 0 降级为警告并继续，保证本地首次构建能跑起来。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 日志文件名由【本入口】定，不能等 main() —— logger 在 source 的那一刻就把路径拼好了。
# 库只管格式（缺省名取主脚本名，对这里就是 "build"）；build-<stage> 这套前缀是流水线的命名约定，
# 属于调用方：六个 stage 若都用缺省名就会全挤进 build.log，事后分不出哪份是编译、哪份是装依赖。
# 非法 stage 由 main() 的 case 拒绝；文件名净化由库的 _log_sanitize_basename 负责，这里不重复实现。
LOG_FILE_BASENAME="build-${1:-build}"
export LOG_FILE_BASENAME

# 加载顺序即依赖顺序，不可调换：logger 最先（唯一 log 实现），strictness 次之（它调用 log_error），
# 然后是两个阶段模块，最后是编排。
_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${_REPO_ROOT}/scripts/libs/01-shell-logger.sh"
# error-handler 必须在 logger 之后（fail/die 调用 log_error），提供 E_* 退出码常量。
# shellcheck source=scripts/libs/02-error-handler.sh
source "${_REPO_ROOT}/scripts/libs/02-error-handler.sh"
# shellcheck source=scripts/build/common/strictness.sh
source "${SCRIPT_DIR}/common/strictness.sh"
# shellcheck source=scripts/build/steps/install-deps.sh
source "${SCRIPT_DIR}/steps/install-deps.sh"
# shellcheck source=scripts/build/steps/compile.sh
source "${SCRIPT_DIR}/steps/compile.sh"
# shellcheck source=scripts/build/pipeline.sh
source "${SCRIPT_DIR}/pipeline.sh"
# shellcheck source=scripts/build/utils/load.sh
source "${SCRIPT_DIR}/utils/load.sh"
unset _REPO_ROOT

# 必须从仓库根执行：所有函数都以仓库根为基准（immortalwrt/ 为其子目录）。
cd "${SCRIPT_DIR}/../.." || exit 1

# 【输出采集层】——在整个流水线开始前就把 fd 1/2 接到「终端 + 文件」双写上。
# 这是 build.sh 唯一需要做的日志接线：此后 make / apt / git / feeds 等外部命令的输出
# 全部自动进日志文件，调用点不需要改动。机制实现在 libs/01-shell-logger.sh（全仓唯一实现），
# 这里只负责在正确的时机调用它。
#
# 顺序约束（三条都不能调换）：
#   1. 在 logger source 之后 —— 采集/归档函数由它定义；
#   2. 在 cd 之后 —— 日志相对路径的基准已确定；
#   3. 归档必须在 _log_start_capture【之前】—— tee 在 exec 那一刻就把 fd 绑到当时那个 inode，
#      之后再改名，tee 仍追着旧 inode 写。先归档再接管，本次才会落在干净的新文件上。
# LOG_CAPTURE=file 时终端保持安静，这就是一直缺失的"静默模式"；console 则回到旧的只输出终端行为。
LOG_RUN_ID="$(printf '%(%Y%m%d-%H%M%S)T' -1)-$$"
LOG_RUN_CMD="build.sh $*"
export LOG_RUN_ID LOG_RUN_CMD
_log_archive_previous
if _log_start_capture; then
  _log_session_begin
  # 无论正常结束还是中途 exit，都补一条 END 标记：缺了它，事后无法判断日志是被截断
  # 还是正常收尾（编译被打断时最容易出现这种"看不出来"的日志）。
  # trap 只覆盖 EXIT；02-error-handler.sh 里已记录"重复装 EXIT trap 只有最后一个生效"，
  # 本文件是顶层入口、不再装第二个 trap，因此这里安装是安全的。
  trap '_log_session_end' EXIT
fi

usage() {
  cat >&2 <<'EOF'
用法: scripts/build/build.sh <stage>

stage:
  deps      安装主机编译依赖（scripts/build/dependencies.txt），再补装 upx/padjffs2/po2lmo
            这三个 apt 覆盖不到的工具；唯一会调用 apt 的阶段
  prepare   准备 immortalwrt/：克隆 -> 私钥 -> feeds.conf -> 自定义文件 -> .config
            -> DIY1 -> feeds update -a -> DIY2 -> feeds update -i -> feeds install -a -> defconfig
  download  prepare + 下载源码包
  compile   download + 编译固件
  check     只统计固件体积（scripts/build/utils/01-check-size-utils.sh 的 check_firmware_size），不删除任何文件
  all       compile + check

阶段累进：download 含 prepare；compile 含 download；all 含 compile。
deps 不会被任何阶段自动触发，需要时显式执行。
环境变量 REQUIRED=1 启用严格模式：缺 APK 私钥、缺依赖清单、装依赖失败都硬失败。
EOF
}

# 只统计体积：工具函数自身不改动工作区。
run_size_check() {
  check_firmware_size
}

run_stage() {
  case "$1" in
    # 顺序不可颠倒：install_extra_toolchains 依赖 apt 装好的 curl/gcc/git/make/strip。
    deps) install_dependencies && install_extra_toolchains ;;
    prepare) prepare_all ;;
    download) prepare_all && download_packages ;;
    compile) prepare_all && download_packages && compile_firmware ;;
    check) run_size_check ;;
    all) prepare_all && download_packages && compile_firmware && run_size_check ;;
  esac
}

main() {
  local stage="${1:-}"

  # 不带参数时打印用法而不是默认跑全流程：完整构建耗时数小时，不该被误触发。
  case "${stage}" in
    deps | prepare | download | compile | check | all) ;;
    *)
      usage
      # 用法错误：sysexits 的 E_USAGE=64，便于调用方区分『敲错命令』与『构建失败』。
      exit "${E_USAGE}"
      ;;
  esac

  run_stage "${stage}" || exit 1

  log_success "Build stage completed: ${stage}"
}

main "$@"
