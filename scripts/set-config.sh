#!/bin/bash
#
# Script to set the configuration for the build.
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
  log_info "Starting configuration setup..."

  # Enter immortalwrt directory.
  enter_immortalwrt_dir

  # Copy configuration file.
  if [[ -f ".config" ]]; then
    log_info "Using existing configuration file"
    make defconfig
    log_success "Configuration file loaded"
  elif [[ -f "../targets/mediatek/filogic/config.buildinfo" ]]; then
    log_info "Copying configuration file from target directory"
    cp "../targets/mediatek/filogic/config.buildinfo" ".config"
    log_success "Configuration file copied"
  else
    log_error "Configuration file not found!"
  fi

  # Run DIY scripts and update feeds.
  setup_feeds

  log_success "Configuration setup completed"
}

# Execute main function.
main "$@"