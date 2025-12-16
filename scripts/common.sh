#!/bin/bash

# 通用配置和函数库

# 颜色输出
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 检查并进入 immortalwrt 目录
enter_immortalwrt_dir() {
    if [ -d "immortalwrt" ]; then
        log_info "进入 'immortalwrt' 目录..."
        cd immortalwrt || {
            log_error "无法进入 'immortalwrt' 目录！"
            exit 1
        }
        return 0
    elif [ "$(basename "$(pwd)")" = "immortalwrt" ]; then
        return 0
    else
        log_error "当前目录不是或不存在 'immortalwrt'，请先进入正确的目录。"
        exit 1
    fi
}

# 备份文件
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        local backup="${file}.${timestamp}.bak"
        cp "$file" "$backup"
        log_info "已备份 $file 到 $backup"
    fi
}

# 安全设置配置项
safe_set_config() {
    local key="$1"
    local value="$2"
    local comment="$3"
    local config_file="${4:-.config}"

    # 转义特殊字符
    local escaped_key
    escaped_key=$(printf '%s\n' "$key" | sed "s/[][\.|$(){}?+*^]/\\&/g")

    if grep -q "^${escaped_key}=" "$config_file"; then
        sed -i "s/^${escaped_key}=.*/${key}=${value}/" "$config_file"
        log_info "已启用: ${key}=${value} ${comment}"
    elif grep -q "^# ${escaped_key} is not set" "$config_file"; then
        sed -i "s/^# ${escaped_key} is not set/${key}=${value}/" "$config_file"
        log_info "已设置: ${key}=${value} ${comment}"
    else
        echo "${key}=${value}" >>"$config_file"
        log_info "已添加: ${key}=${value} ${comment}"
    fi
}

# 准备 immortalwrt 仓库
prepare_immortalwrt_repo() {
    if [ ! -d "immortalwrt" ]; then
        log_info "正在克隆 immortalwrt 仓库..."
        git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git || {
            log_error "克隆 'immortalwrt' 仓库失败，请检查网络连接或仓库地址。"
            exit 1
        }
    else
        log_info "正在更新 immortalwrt 仓库..."
        git clean -fdx
        git restore .
        git pull
    fi
}

clean_feeds() {
    log_info "清理 feeds..."
    ./scripts/feeds clean -a -f
}

copy_custom_files() {
    log_info "复制自定义文件到 immortalwrt 目录..."
    if [[ $(pwd) != immortalwrt ]]; then
        cd immortalwrt || {
            log_error "无法进入 'immortalwrt' 目录！"
            exit 1
        }
    fi
    if [ -d "files" ]; then
        rm -rf files
    fi
    cp -r ../files ./ || {
        log_error "复制自定义文件失败！"
        exit 1
    }
    cp ../diy-part* ./ || {
        log_error "复制 diypart 脚本失败！"
        exit 1
    }
}

run_diypart1() {
    log_info "执行 DIY PART1 脚本..."
    if [ -f "diy-part1.sh" ]; then
        bash "./diy-part1.sh"
    fi
}

update_feeds() {
    log_info "更新 feeds..."
    ./scripts/feeds update -a -f
}

install_feeds() {
    log_info "安装所有 feeds..."
    ./scripts/feeds install -a -f
}

run_diypart2() {
    log_info "执行 DIY PART2 脚本..."
    if [ -f "diy-part2.sh" ]; then
        bash "./diy-part2.sh"
    fi
}

# 执行diy脚本并更新feeds
setup_feeds() {
    log_info "执行DIY脚本并更新feeds..."

    # 执行 DIY PART1 脚本
    if [ -f "diy-part1.sh" ]; then
        bash "./diy-part1.sh"
    fi

    # 更新并安装feeds
    ./scripts/feeds update -a -f

    # 执行 DIY PART2 脚本
    if [ -f "diy-part2.sh" ]; then
        bash "./diy-part2.sh"
    fi
    ./scripts/feeds install -a -f
}
