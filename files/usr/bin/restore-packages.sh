#!/bin/bash
# 软件包恢复脚本：包含预安装检查与状态标记
# 功能：根据备份文件恢复软件包，验证安装状态，并在成功后重启系统
# 用法: restore-packages [备份文件路径]
# 作者：Shuery-Shuai
# 日期：2025-06-27
# 版本：1.0.0

# 严格模式：未定义变量使脚本退出，管道错误退出
set -euo pipefail

#######################################
# 主函数
# Globals:
#   backup_resolv_flag, backup_firewall_flag, firewall_type, firewall_backup
# Arguments:
#   $1: 备份文件路径 (默认: /etc/backup/installed_packages.txt)
# Outputs:
#   写入日志文件，创建状态标记
# Returns:
#   0: 成功, 1: 失败
#######################################
main() {
    # 配置恢复标记
    local backup_resolv_flag=0
    local backup_firewall_flag=0
    local firewall_type=""
    local firewall_backup=""

    # 初始化路径
    local backup_file="${1:-/etc/backup/installed_packages.txt}"
    local test_url="https://immortalwrt.shuery.lssa.fun"
    local log_file="/var/log/package-restore-$(date +'%Y%m%d%H%M%S').log"
    local installed_flag="/tmp/packages-has-installed"

    # 设置退出时自动恢复配置
    trap 'restore_original_config "$backup_resolv_flag" "$backup_firewall_flag" "$firewall_type" "$firewall_backup" "$log_file"' EXIT

    # 初始化日志
    log_header "$log_file" "开始恢复软件包" "backup_file=$backup_file"

    # 检查是否已安装
    if [ -f "$installed_flag" ] || check_all_packages_installed "$backup_file" "$log_file"; then
        log_info "$log_file" "所有软件包已安装，无需操作"
        return 0
    fi

    # 验证备份文件
    if [ ! -f "$backup_file" ]; then
        log_error "$log_file" "备份文件不存在: $backup_file"
        return 1
    fi

    # 网络状态检测
    if ! check_network "$test_url" "$log_file"; then
        # 第一次检测失败时备份并修改设置
        backup_resolv_flag=1
        backup_resolv_config "$log_file"

        firewall_type=$(detect_firewall_type)
        if [ -n "$firewall_type" ]; then
            backup_firewall_flag=1
            firewall_backup="/tmp/firewall-backup-$(date +'%s').rules"
            backup_firewall "$firewall_type" "$firewall_backup" "$log_file"
            set_temp_firewall_rules "$firewall_type" "$log_file"
        fi

        # 第二次检测
        if ! check_network "$test_url" "$log_file"; then
            log_error "$log_file" "无法连接软件源，恢复中止"
            return 1
        fi
    fi

    # 更新软件源
    if ! update_package_lists "$log_file"; then
        log_error "$log_file" "软件源更新失败"
        return 1
    fi

    # 安装并验证软件包
    if ! install_and_verify_packages "$backup_file" "$log_file"; then
        log_error "$log_file" "软件包安装验证失败"
        return 1
    fi

    # 删除备份文件（安装验证成功后）
    rm -f "$backup_file" && log_info "$log_file" "已删除备份文件: $backup_file"

    # 创建安装完成标记
    touch "$installed_flag"
    log_info "$log_file" "已创建安装完成标记: $installed_flag"

    # 最终系统重启
    log_info "$log_file" "===== 所有软件包验证成功 ====="
    log_info "$log_file" "系统将在10秒后重启..."

    # 安全重启
    sleep 10
    reboot
}

#=== 功能函数 ===#

#######################################
# 记录日志头信息
# Globals:
#   None
# Arguments:
#   $1: 日志文件路径
#   $2: 标题
#   $3: 附加信息
# Outputs:
#   写入日志文件
#######################################
log_header() {
    local log_file="$1"
    local title="$2"
    local info="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z')

    {
        echo "===== $timestamp - $title ====="
        [ -n "$info" ] && echo "信息: $info"
        echo
    } >>"$log_file"
}

#######################################
# 记录信息日志
# Globals:
#   None
# Arguments:
#   $1: 日志文件路径
#   $2: 消息内容
# Outputs:
#   写入日志文件
#######################################
log_info() {
    local log_file="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z')

    echo "[$timestamp] $message" >>"$log_file"
}

#######################################
# 记录错误信息
# Globals:
#   None
# Arguments:
#   $1: 日志文件路径
#   $2: 错误消息
# Outputs:
#   写入日志文件和STDERR
# Returns:
#   1
#######################################
log_error() {
    local log_file="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%dT%H:%M:%S%z')

    echo "[$timestamp][错误] $message" | tee -a "$log_file" >&2
    return 1
}

#######################################
# 预安装检查：验证所有包是否已安装
# Globals:
#   None
# Arguments:
#   $1: 备份文件路径
#   $2: 日志文件路径
# Returns:
#   0: 全部已安装, 1: 未完全安装
#######################################
check_all_packages_installed() {
    local backup_file="$1"
    local log_file="$2"
    local user_pkgs="/tmp/user-pkgs-check.list"
    local all_installed=1

    # 检查备份文件是否存在
    [ ! -f "$backup_file" ] && {
        log_info "$log_file" "备份文件不存在，跳过预检查"
        return 1
    }

    # 提取所有用户安装包
    grep '\toverlay' "$backup_file" | awk '{print $1}' >"$user_pkgs"

    # 没有用户包时直接返回成功
    [ ! -s "$user_pkgs" ] && {
        log_info "$log_file" "无用户安装包需要检查"
        rm -f "$user_pkgs"
        return 0
    }

    # 检查每个包是否已安装
    while IFS= read -r pkg; do
        if ! apk info --installed "$pkg" >/dev/null 2>&1; then
            log_info "$log_file" "包未安装: $pkg"
            all_installed=0
        fi
    done <"$user_pkgs"

    # 清理临时文件
    rm -f "$user_pkgs"
    [ "$all_installed" -eq 1 ] && {
        log_info "$log_file" "所有用户安装包已存在"
        return 0
    }
    return 1
}

#######################################
# 网络检测
# Globals:
#   None
# Arguments:
#   $1: 测试URL
#   $2: 日志文件路径
# Returns:
#   0: 网络正常, 1: 网络异常
#######################################
check_network() {
    local test_url="$1"
    local log_file="$2"
    local retries=3
    local timeout=5
    local i=1

    while [ "$i" -le "$retries" ]; do
        if curl --connect-timeout "$timeout" -kIs "$test_url" >/dev/null 2>&1; then
            log_info "$log_file" "网络连接正常"
            return 0
        fi
        log_info "$log_file" "网络检查失败 (尝试 $i/$retries)"
        sleep $((i * 2))
        i=$((i + 1))
    done
    return 1
}

#######################################
# 备份DNS配置
# Globals:
#   None
# Arguments:
#   $1: 日志文件路径
#######################################
backup_resolv_config() {
    local log_file="$1"
    log_info "$log_file" "备份DNS配置..."
    cp /etc/resolv.conf /tmp/resolv.conf.backup
    {
        echo "nameserver 8.8.8.8"
        echo "nameserver 1.1.1.1"
    } >/etc/resolv.conf
}

#######################################
# 检测防火墙类型
# Globals:
#   None
# Returns:
#   nftables/iptables/空字符串
#######################################
detect_firewall_type() {
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1; then
        echo "iptables"
    else
        echo ""
    fi
}

#######################################
# 备份防火墙配置
# Globals:
#   None
# Arguments:
#   $1: 防火墙类型
#   $2: 备份文件路径
#   $3: 日志文件路径
#######################################
backup_firewall() {
    local fw_type="$1"
    local backup_file="$2"
    local log_file="$3"

    log_info "$log_file" "备份防火墙配置 ($fw_type)..."

    case "$fw_type" in
    iptables)
        iptables-save >"$backup_file"
        ip6tables-save >>"$backup_file"
        ;;
    nftables)
        nft list ruleset >"$backup_file"
        ;;
    esac
}

#######################################
# 设置临时防火墙规则
# Globals:
#   None
# Arguments:
#   $1: 防火墙类型
#   $2: 日志文件路径
#######################################
set_temp_firewall_rules() {
    local fw_type="$1"
    local log_file="$2"

    log_info "$log_file" "设置临时防火墙规则 ($fw_type)..."

    case "$fw_type" in
    iptables)
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
        ip6tables -P INPUT ACCEPT
        ip6tables -P OUTPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -F
        ;;
    nftables)
        nft flush ruleset
        nft add table inet temp_table
        nft add chain inet temp_table input \
            '{ type filter hook input priority 0; policy accept; }'
        nft add chain inet temp_table output \
            '{ type filter hook output priority 0; policy accept; }'
        nft add chain inet temp_table forward \
            '{ type filter hook forward priority 0; policy accept; }'
        ;;
    esac
}

#######################################
# 更新软件源
# Globals:
#   None
# Arguments:
#   $1: 日志文件路径
# Returns:
#   0: 成功, 1: 失败
#######################################
update_package_lists() {
    local log_file="$1"
    log_info "$log_file" "更新软件包列表..."
    apk update >>"$log_file" 2>&1
}

#######################################
# 安装并验证软件包
# Globals:
#   None
# Arguments:
#   $1: 备份文件路径
#   $2: 日志文件路径
# Returns:
#   0: 成功, 1: 失败
#######################################
install_and_verify_packages() {
    local backup_file="$1"
    local log_file="$2"
    local max_retries=3
    local user_pkgs="/tmp/user-pkgs.list"
    local kernel_pkgs="/tmp/kernel-pkgs.list"

    # 准备安装列表
    grep '\toverlay' "$backup_file" | awk '{print $1}' >"$user_pkgs"
    grep '^kmod-.*\trom' "$backup_file" | awk '{print $1}' >"$kernel_pkgs"

    # 安装用户包
    log_info "$log_file" "=== 安装用户软件包 ==="
    if ! install_pkgs_with_retry "$user_pkgs" "$max_retries" "$log_file"; then
        log_info "$log_file" "警告：部分用户软件包未正确安装"
    fi

    # 安装内核模块
    log_info "$log_file" "=== 安装内核模块 ==="
    if [ -s "$kernel_pkgs" ]; then
        xargs <"$kernel_pkgs" apk add --no-cache >>"$log_file" 2>&1
        if ! verify_packages "$kernel_pkgs" "$log_file"; then
            log_info "$log_file" "警告：部分内核模块未正确安装"
        fi
    else
        log_info "$log_file" "无内核模块需要安装"
    fi

    # 最终验证
    if ! verify_packages "$user_pkgs" "$log_file"; then
        return 1
    fi

    # 清理临时文件
    rm -f "$user_pkgs" "$kernel_pkgs"
    return 0
}

#######################################
# 带重试的安装
# Globals:
#   None
# Arguments:
#   $1: 包列表文件
#   $2: 最大重试次数
#   $3: 日志文件路径
# Returns:
#   0: 成功, 1: 失败
#######################################
install_pkgs_with_retry() {
    local pkg_list="$1"
    local max_retries="$2"
    local log_file="$3"
    local retry_count=0
    local failed_file="/tmp/failed-pkgs.list"

    while [ "$retry_count" -lt "$max_retries" ]; do
        : >"$failed_file"

        # 安装尝试
        xargs -n 1 <"$pkg_list" apk add --no-cache >>"$log_file" 2>&1 || true

        # 验证安装
        verify_packages "$pkg_list" "$log_file" "$failed_file"

        # 检查是否全部成功
        [ ! -s "$failed_file" ] && return 0

        # 准备重试
        retry_count=$((retry_count + 1))
        log_info "$log_file" "重试安装 (尝试 $retry_count/$max_retries)"
        cp "$failed_file" "$pkg_list"
        sleep 5
    done

    log_info "$log_file" "以下软件包安装失败:"
    cat "$failed_file" >>"$log_file"
    return 1
}

#######################################
# 验证软件包安装
# Globals:
#   None
# Arguments:
#   $1: 包列表文件
#   $2: 日志文件路径
#   $3: 失败包输出文件 (可选)
# Returns:
#   0: 全部成功, 1: 有失败
#######################################
verify_packages() {
    local pkg_list="$1"
    local log_file="$2"
    local failed_file="${3:-/dev/null}"
    local all_success=0

    while IFS= read -r pkg; do
        if ! apk info --installed "$pkg" >/dev/null 2>&1; then
            echo "$pkg" >>"$failed_file"
            all_success=1
        fi
    done <"$pkg_list"

    [ "$all_success" -eq 0 ] && {
        log_info "$log_file" "所有软件包验证成功"
        return 0
    }
    return 1
}

#######################################
# 恢复原始配置
# Globals:
#   None
# Arguments:
#   $1: 恢复DNS标志
#   $2: 恢复防火墙标志
#   $3: 防火墙类型
#   $4: 防火墙备份文件
#   $5: 日志文件路径
#######################################
restore_original_config() {
    local backup_resolv_flag="$1"
    local backup_firewall_flag="$2"
    local firewall_type="$3"
    local firewall_backup="$4"
    local log_file="$5"

    # 恢复DNS配置
    if [ "$backup_resolv_flag" -eq 1 ]; then
        [ -f "/tmp/resolv.conf.backup" ] && {
            log_info "$log_file" "恢复原始DNS配置..."
            mv -f "/tmp/resolv.conf.backup" "/etc/resolv.conf"
        }
    fi

    # 恢复防火墙配置
    if [ "$backup_firewall_flag" -eq 1 ] && [ -n "$firewall_backup" ]; then
        [ -f "$firewall_backup" ] && {
            log_info "$log_file" "恢复原始防火墙配置 ($firewall_type)..."

            case "$firewall_type" in
            iptables)
                iptables-restore <"$firewall_backup"
                ip6tables-restore <"$firewall_backup"
                ;;
            nftables)
                nft flush ruleset
                nft -f "$firewall_backup"
                ;;
            esac

            # 删除防火墙备份
            rm -f "$firewall_backup"
        }
    fi
}

# 执行主函数
main "$@"
