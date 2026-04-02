#!/bin/bash
#
# Script to build the firmware.
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

# Cleans small files in the download directory.
clean_small_files() {
  log_info "Cleaning small files in download directory..."
  local count=0
  while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
      log_info "Deleting: $(basename "$file")"
      rm -f "$file"
      ((count++))
    fi
  done < <(find dl -size -1024c -print0 2>/dev/null)

  if [[ $count -eq 0 ]]; then
    log_info "No small files found to clean"
  else
    log_info "Cleaned $count small files"
  fi
}

# Compiles the firmware.
compile_firmware() {
  local cpu_count
  cpu_count=$(nproc)
  local make_jobs=$((cpu_count + 1))

  log_info "Starting firmware compilation (using $make_jobs parallel jobs)..."

  # Set PATH environment variable.
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  # Try to compile, if failed, downgrade to single thread with detailed output.
  if make -j"$make_jobs"; then
    log_success "Compilation completed"
  else
    log_warning "Parallel compilation failed, trying single-thread detailed compilation..."
    if make -j1 V=sc; then
      log_success "Single-thread compilation completed"
    else
      log_error "Compilation failed. Please check error logs."
      return 1
    fi
  fi
}

# Main function.
main() {
  log_info "Starting firmware compilation process..."

  # Clean immortalwrt directory changes.
  clean_immortalwrt_changes

  # Set configuration.
  bash "${SCRIPT_DIR}/set-config.sh"

  # Clean small files.
  clean_small_files

  # Download dependencies.
  log_info "Starting dependency download..."
  if make download; then
    log_success "Dependency download completed"
  else
    log_error "Dependency download failed"
    exit 1
  fi

  # Compile firmware.
  compile_firmware
}

# Execute main function.
main "$@"
