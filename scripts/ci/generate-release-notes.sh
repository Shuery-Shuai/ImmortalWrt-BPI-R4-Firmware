#!/bin/bash
#
# Generates release.txt, mirroring the workflow step 'Generate release tag'.
#

# Save original directory.
ORIGINAL_DIR="$(pwd)"
readonly ORIGINAL_DIR
trap 'cd "$ORIGINAL_DIR"' EXIT

# 加载顺序即依赖顺序：logger 最先（唯一 log 实现），strictness 次之（调用 log_error）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
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
