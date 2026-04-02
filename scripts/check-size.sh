#!/bin/bash
#
# Script to check the size of firmware files.
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

# File type configurations.
readonly SEARCH_DIR="bin/targets"
readonly FILE_TYPES=("*.bin" "*.itb" "*.img.gz" "*.fip")

# Main function.
main() {
  log_info "Starting firmware file size check..."

  # Clean immortalwrt directory changes.
  clean_immortalwrt_changes

  # Enter immortalwrt directory.
  enter_immortalwrt_dir

  local total_count=0
  local total_size=0
  declare -A type_count

  echo "----------------------------------------"

  # Traverse all file types.
  for type in "${FILE_TYPES[@]}"; do
    local count=0
    echo "【${type} files】"

    # Find and process files.
    while IFS= read -r -d '' file; do
      if [[ -f "$file" ]]; then
        local size
        size=$(stat -c %s "$file" 2>/dev/null || echo 0)
        local human_size
        human_size=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "0B")
        printf "%-10s %s\n" "$human_size" "$(realpath --relative-to=. "$file")"

        ((total_count++))
        total_size=$((total_size + size))
        ((count++))
        type_count["$type"]=$((type_count["$type"] + 1))
      fi
    done < <(find "$SEARCH_DIR" -type f -iname "$type" -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
      echo "    (No files found)"
    fi
    echo ""
  done

  # Output statistics.
  echo "----------------------------------------"
  echo "Total files: $total_count"

  if command -v numfmt >/dev/null 2>&1; then
    echo "Total size: $(numfmt --to=iec-i --suffix=B "$total_size") ($total_size bytes)"
  else
    echo "Total size: $total_size bytes"
  fi

  if [[ $total_count -gt 0 ]]; then
    echo "Distribution by type:"
    for type in "${FILE_TYPES[@]}"; do
      local count=${type_count["$type"]:-0}
      if [[ $count -gt 0 ]]; then
        echo "  $type: $count files"
      fi
    done
  fi

  echo "----------------------------------------"
  log_success "Firmware file check completed"
}

# Execute main function.
main "$@"
