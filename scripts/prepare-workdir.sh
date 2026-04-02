#!/bin/bash
#
# Script to prepare the immortalwrt working directory.
#

# Save original directory.
readonly ORIGINAL_DIR="$(pwd)"
trap "cd '$ORIGINAL_DIR'" EXIT

# Import common functions.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
  # shellcheck source=scripts/common.sh
  source "${SCRIPT_DIR}/common.sh"
else
  echo "Error: common.sh file not found" >&2
  exit 1
fi

# Main function.
main() {
  log_info "Starting immortalwrt workspace setup..."

  # Clean immortalwrt directory changes.
  clean_immortalwrt_changes

  # Prepare immortalwrt repository.
  prepare_immortalwrt

  # Copy custom files.
  copy_custom_files

  log_success "Immortalwrt workspace preparation completed"
}

# Execute main function.
main "$@"
