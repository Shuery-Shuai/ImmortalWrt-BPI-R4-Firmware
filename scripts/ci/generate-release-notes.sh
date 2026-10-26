#!/bin/bash
#
# Generates release.txt, mirroring the workflow step 'Generate release tag'.
#

# Save original directory.
ORIGINAL_DIR="$(pwd)"
readonly ORIGINAL_DIR
trap 'cd "$ORIGINAL_DIR"' EXIT

# 所有 source 与下面的 cd 都按 SCRIPT_DIR 定位，因此必须在第一个 source 之前确定它。
# 本文件位于 scripts/ci/，CI 是按仓库根下的 `bash scripts/ci/xxx.sh` 调起的（也可从任意 CWD 直接执行），
# 用 $PWD 或相对路径去解析 ../libs/ 必然失败。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载顺序即依赖顺序：logger 最先（唯一 log 实现），strictness 次之（调用 log_error）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# 本脚本排在 Upload build logs 之后运行，写下的日志注定进不了 artifact，
# 只会在 logs/ 里冒充一次构建留下的记录；产物是 release.txt，日志不是它的交付物。
LOG_TO_FILE=false
# shellcheck source=scripts/build/common/strictness.sh
source "${SCRIPT_DIR}/../build/common/strictness.sh"
# shellcheck source=scripts/build/steps/install-deps.sh
source "${SCRIPT_DIR}/../build/steps/install-deps.sh"
# shellcheck source=scripts/build/steps/compile.sh
source "${SCRIPT_DIR}/../build/steps/compile.sh"
# shellcheck source=scripts/build/pipeline.sh
source "${SCRIPT_DIR}/../build/pipeline.sh"

# Fix to repository root (release.txt lands there).
# 本文件位于 scripts/ci/，故需上溯两级才到仓库根。
cd "${SCRIPT_DIR}/../.." || exit 1

readonly RELEASE_FILE="${PWD}/release.txt"

# Main function.
main() {
  : > "${RELEASE_FILE}" || {
    log_error "Failed to create ${RELEASE_FILE}"
    return 1
  }

  if [[ -n "${COWTRANSFER_URL:-}" ]]; then
    echo "🔗 [Cowtransfer](${COWTRANSFER_URL})" >> "${RELEASE_FILE}"
  else
    log_info "COWTRANSFER_URL not set; skipping Cowtransfer link."
  fi

  if [[ -n "${WETRANSFER_URL:-}" ]]; then
    echo "🔗 [WeTransfer](${WETRANSFER_URL})" >> "${RELEASE_FILE}"
  else
    log_info "WETRANSFER_URL not set; skipping WeTransfer link."
  fi

  log_success "Wrote ${RELEASE_FILE}"
  echo "${RELEASE_FILE}"
  return 0
}

main "$@"
