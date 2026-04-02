#!/bin/bash
#
# Common functions and configurations for ImmortalWrt build scripts.
#

# ---------- 颜色定义（使用单引号，存储字面反斜杠）----------
if [[ -t 2 ]]; then
  readonly COLOR_RESET='\033[0m'
  readonly COLOR_RED='\033[0;31m'
  readonly COLOR_GREEN='\033[0;32m'
  readonly COLOR_YELLOW='\033[0;33m'
  readonly COLOR_BLUE='\033[0;34m'
  readonly COLOR_MAGENTA='\033[0;35m'
  readonly COLOR_CYAN='\033[0;36m'
  readonly COLOR_GRAY='\033[0;37m'
  readonly COLOR_BOLD_RED='\033[1;31m'
  readonly COLOR_BOLD_GREEN='\033[1;32m'
  readonly COLOR_BOLD_YELLOW='\033[1;33m'
else
  readonly COLOR_RESET=''
  readonly COLOR_RED=''
  readonly COLOR_GREEN=''
  readonly COLOR_YELLOW=''
  readonly COLOR_BLUE=''
  readonly COLOR_MAGENTA=''
  readonly COLOR_CYAN=''
  readonly COLOR_GRAY=''
  readonly COLOR_BOLD_RED=''
  readonly COLOR_BOLD_GREEN=''
  readonly COLOR_BOLD_YELLOW=''
fi

# ---------- 日志级别数值 ----------
readonly LOG_LEVEL_TRACE=0
readonly LOG_LEVEL_DEBUG=1
readonly LOG_LEVEL_INFO=2
readonly LOG_LEVEL_WARN=3
readonly LOG_LEVEL_ERROR=4
readonly LOG_LEVEL_FATAL=5

# 当前生效的日志级别（默认 INFO）
: "${LOG_LEVEL:=INFO}"

# ---------- 辅助函数：获取实体样式 ----------
_get_style() {
  local entity="$1"
  local color=""
  local emoji=""

  case "${entity}" in
    TRACE)   color="${COLOR_GRAY}";      emoji="🔬" ;;
    DEBUG)   color="${COLOR_CYAN}";      emoji="🐛" ;;
    INFO)    color="${COLOR_BLUE}";      emoji="ℹ️" ;;
    WARN)    color="${COLOR_BOLD_YELLOW}"; emoji="⚠️" ;;
    ERROR)   color="${COLOR_BOLD_RED}";  emoji="❌" ;;
    FATAL)   color="${COLOR_BOLD_RED}";  emoji="💀" ;;
    SUCCESS) color="${COLOR_BOLD_GREEN}"; emoji="✅" ;;
    FAILURE) color="${COLOR_BOLD_RED}";  emoji="❌" ;;
    WARNING) color="${COLOR_BOLD_YELLOW}"; emoji="⚠️" ;;
    NOTE)    color="${COLOR_BLUE}";      emoji="📝" ;;
    IMPORTANT) color="${COLOR_MAGENTA}"; emoji="⭐" ;;
    *)       color="${COLOR_GRAY}";      emoji="📌" ;;
  esac

  echo "${color}|${emoji}"
}

# ---------- 主日志函数 ----------
log() {
  local level=""
  local subcategory=""
  local message=""

  if [[ $# -eq 2 ]]; then
    level="$1"
    subcategory=""
    message="$2"
  elif [[ $# -eq 3 ]]; then
    level="$1"
    subcategory="$2"
    message="$3"
  else
    printf "Usage: log LEVEL [SUBCATEGORY] MESSAGE\n" >&2
    return 1
  fi

  # 级别有效性检查
  local level_num
  case "${level}" in
    TRACE) level_num=0 ;;
    DEBUG) level_num=1 ;;
    INFO)  level_num=2 ;;
    WARN)  level_num=3 ;;
    ERROR) level_num=4 ;;
    FATAL) level_num=5 ;;
    *)
      printf "Unknown log level: %s\n" "${level}" >&2
      return 1
      ;;
  esac

  # 当前日志级别数值
  local current_level_num
  case "${LOG_LEVEL}" in
    TRACE) current_level_num=0 ;;
    DEBUG) current_level_num=1 ;;
    INFO)  current_level_num=2 ;;
    WARN)  current_level_num=3 ;;
    ERROR) current_level_num=4 ;;
    FATAL) current_level_num=5 ;;
    *)     current_level_num=2 ;;
  esac

  # 级别过滤
  if [[ ${level_num} -lt ${current_level_num} ]]; then
    return 0
  fi

  # 获取级别样式
  local level_style
  level_style="$(_get_style "${level}")"
  local level_color="${level_style%|*}"
  local level_emoji="${level_style#*|}"

  # 获取子类别样式
  local sub_color=""
  local sub_emoji=""
  if [[ -n "${subcategory}" ]]; then
    local sub_style
    sub_style="$(_get_style "${subcategory}")"
    sub_color="${sub_style%|*}"
    sub_emoji="${sub_style#*|}"
  fi

  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  # 构建带颜色的标签（颜色变量包含字面 \033，但稍后 %b 会解释）
  local level_tag="${level_color}[${level_emoji} ${level}]${COLOR_RESET}"
  local sub_tag=""
  if [[ -n "${subcategory}" ]]; then
    sub_tag=" ${sub_color}[${sub_emoji} ${subcategory}]${COLOR_RESET}"
  fi

  # 关键：使用 printf '%b' 输出，使 \033 被解释为 ESC 字符
  printf '%b' "[${timestamp}] ${level_tag}${sub_tag} ${message}\n" >&2
}

# Logs an info message.
log_info() {
  log "INFO" "$1"
}

# Logs a success message.
log_success() {
  log "INFO" "SUCCESS" "$1"
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

