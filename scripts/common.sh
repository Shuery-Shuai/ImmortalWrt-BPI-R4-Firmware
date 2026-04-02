#!/bin/bash
#
# Common functions and configurations for ImmortalWrt build scripts.
#

# Color constants for output.
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'  # No Color

# 日志配置
readonly LOG_LEVEL=1 # 日志级别: debug-1, info-2, warn-3, error-4, always-5
readonly LOG_OPEN=1  # 日志开关: 1-开启, 0-关闭
readonly LOG_FILE="" # 日志文件路径，留空则不写入文件

# Logs a general message with level control.
log() {
  local level="${1}"
  local message="${2}"
  local level_num
  local content

  case "${level}" in
    DEBUG) level_num=1 ;;
    INFO) level_num=2 ;;
    WARN) level_num=3 ;;
    ERROR) level_num=4 ;;
    ALWAYS) level_num=5 ;;
    *) level_num=6 ;;
  esac

  if [[ "${LOG_OPEN}" -eq 1 ]] && [[ "${LOG_LEVEL}" -le "${level_num}" ]]; then
    content="$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${message}"
    echo "${content}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
      echo "${content}" >>"${LOG_FILE}"
    fi
  fi
}

# Logs an info message.
log_info() {
  log "INFO" "$1"
}

# Logs a success message.
log_success() {
  log "ALWAYS" "$1"
}

# Logs a warning message.
log_warning() {
  log "WARN" "$1"
}

# Logs an error message to stderr.
log_error() {
  log "ERROR" "$1"
}

# Checks and enters the immortalwrt directory.
enter_immortalwrt_dir() {
  if [[ -d "immortalwrt" ]]; then
    log_info "Entering 'immortalwrt' directory..."
    cd immortalwrt || {
      log_error "Failed to enter 'immortalwrt' directory!"
      exit 1
    }
    return 0
  elif [[ "$(basename "$(pwd)")" == "immortalwrt" ]]; then
    return 0
  else
    log_error "Current directory is not or does not contain 'immortalwrt'. Please enter the correct directory."
    exit 1
  fi
}

# Backs up a file with a timestamp.
backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup="${file}.${timestamp}.bak"
    cp "$file" "$backup"
    log_info "Backed up $file to $backup"
  fi
}

# Safely sets a config option in the .config file.
safe_set_config() {
  local key="$1"
  local value="$2"
  local comment="$3"
  local config_file="${4:-.config}"

  # Escape special characters in key.
  local escaped_key
  escaped_key=$(printf '%s\n' "$key" | sed 's/[][\.|$(){}?+*^]/\\&/g')

  if grep -q "^${escaped_key}=" "$config_file"; then
    sed -i "s/^${escaped_key}=.*/${key}=${value}/" "$config_file"
    log_info "Enabled: ${key}=${value} ${comment}"
  elif grep -q "^# ${escaped_key} is not set" "$config_file"; then
    sed -i "s/^# ${escaped_key} is not set/${key}=${value}/" "$config_file"
    log_info "Set: ${key}=${value} ${comment}"
  else
    echo "${key}=${value}" >>"$config_file"
    log_info "Added: ${key}=${value} ${comment}"
  fi
}

# Prepares the immortalwrt repository.
prepare_immortalwrt_repo() {
  if [[ ! -d "immortalwrt" ]]; then
    log_info "Cloning immortalwrt repository..."
    git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git || {
      log_error "Failed to clone 'immortalwrt' repository. Please check network connection or repository URL."
      exit 1
    }
  else
    log_info "Updating immortalwrt repository..."
    git clean -fdx
    git restore .
    git pull
  fi
}

# Cleans feeds.
clean_feeds() {
  log_info "Cleaning feeds..."
  ./scripts/feeds clean -a -f
}

# Copies custom files to the immortalwrt directory.
copy_custom_files() {
  log_info "Copying custom files to immortalwrt directory..."
  if [[ $(pwd) != immortalwrt ]]; then
    cd immortalwrt || {
      log_error "Failed to enter 'immortalwrt' directory!"
      exit 1
    }
  fi
  if [[ -d "files" ]]; then
    rm -rf files
  fi
  cp -r ../files ./ || {
    log_error "Failed to copy custom files!"
    exit 1
  }
  cp ../diy-part* ./ || {
    log_error "Failed to copy diy-part scripts!"
    exit 1
  }
}

# Runs diy-part1.sh.
run_diypart1() {
  log_info "Running DIY PART1 script..."
  if [[ -f "diy-part1.sh" ]]; then
    bash "./diy-part1.sh"
  fi
}

# Updates feeds.
update_feeds() {
  log_info "Updating feeds..."
  ./scripts/feeds update -a -f
}

# Installs feeds.
install_feeds() {
  log_info "Installing all feeds..."
  ./scripts/feeds install -a -f
}

# Runs diy-part2.sh.
run_diypart2() {
  log_info "Running DIY PART2 script..."
  if [[ -f "diy-part2.sh" ]]; then
    bash "./diy-part2.sh"
  fi
}

# Sets up feeds by running diy scripts and updating/installing feeds.
setup_feeds() {
  log_info "Running DIY scripts and updating feeds..."

  # Run DIY PART1 script.
  if [[ -f "diy-part1.sh" ]]; then
    bash "./diy-part1.sh"
  fi

  # Update and install feeds.
  ./scripts/feeds update -a -f

  # Run DIY PART2 script.
  if [[ -f "diy-part2.sh" ]]; then
    bash "./diy-part2.sh"
  fi
  ./scripts/feeds install -a -f
}

# Cleans changes in the immortalwrt directory.
clean_immortalwrt_changes() {
  if [[ -d "immortalwrt" ]]; then
    log_info "Cleaning changes in immortalwrt directory..."
    cd immortalwrt || return 1
    git clean -fdx
    git restore .
    cd ..
  fi
}

# Prepares the immortalwrt repository.
prepare_immortalwrt() {
  prepare_immortalwrt_repo
}

