#!/bin/bash

# 保存原始目录
ORIGINAL_DIR="$(pwd)"
trap "cd '$ORIGINAL_DIR'" EXIT

# 导入通用函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    # shellcheck source=scripts/common.sh
    source "${SCRIPT_DIR}/common.sh"
else
    echo "错误: 找不到 common.sh 文件" >&2
    exit 1
fi

# 固件配置文件
readonly FIRMWARE_CONFIG_FILE="firmware.config"

# 目标配置片段
readonly FIRMWARE_CONFIG_TARGET_SNIPPET
FIRMWARE_CONFIG_TARGET_SNIPPET=$(
    cat <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y
CONFIG_TARGET_BOARD="mediatek"
CONFIG_TARGET_SUBTARGET="filogic"
CONFIG_TARGET_PROFILE="DEVICE_bananapi_bpi-r4"
CONFIG_TARGET_ROOTFS_PARTSIZE=796
EOF
)

# 固件配置片段
readonly FIRMWARE_CONFIG_SNIPPET
FIRMWARE_CONFIG_SNIPPET=$(
    cat <<'EOF'
CONFIG_TESTING_KERNEL=y
CONFIG_KERNEL_PERF_EVENTS=y
CONFIG_KERNEL_FTRACE=y
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y
CONFIG_KERNEL_MODULE_ALLOW_BTF_MISMATCH=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_KPROBES=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_KERNEL_XDP_SOCKETS=y
CONFIG_DEVEL=y
CONFIG_BPF_TOOLCHAIN_HOST=y
CONFIG_USE_LLVM_HOST=y
# CONFIG_PACKAGE_luci-app-attendedsysupgrade is not set
EOF
)

# 软件包配置数组
readonly FIRMWARE_CONFIG_PACKAGES=(
    ##############################################
    #                   稳定版                   #
    ##############################################
    # === 系统核心组件 ===
    "autocore" # 自动显示CPU负载/温度等硬件状态信息（系统监控核心）
    # "base-files"     # 基础文件系统结构和设备配置文件（/etc目录必需文件）
    # "libc"           # C标准库（所有程序运行的基础依赖）
    # "libgcc"         # GCC运行时库（低级CPU操作和异常处理支持）
    # "logd"           # 系统日志守护进程（日志持久化存储）
    # "procd-ujail"    # 进程管理守护程序（支持容器化隔离，提高安全性）
    # "uboot-envtools" # U-Boot环境变量管理工具（修改启动参数）
    # "urandom-seed"   # 系统启动时生成高质量随机数种子
    # "urngd"          # 用户态随机数生成守护程序（补充系统熵源）

    # === 网络基础服务 ===
    # "bridger"         # 用户态网络桥接工具（替代传统内核桥接）
    # "dnsmasq-full"    # 完整版DNS/DHCP服务器（支持DoT/DoH等高级功能）
    # "dropbear"        # 轻量级SSH服务器（远程管理）
    # "firewall4"       # 基于nftables的下一代防火墙
    # "nftables"        # nftables命令行工具（防火墙规则管理）
    # "odhcp6c"         # IPv6 DHCP客户端（获取运营商IPv6地址）
    # "odhcpd-ipv6only" # 精简版IPv6 DHCP服务器（为局域网分配IPv6地址）
    # "ppp"             # PPP拨号协议核心
    # "ppp-mod-pppoe"   # PPPoE拨号插件（用于ADSL/光纤认证）
    # "wpad-openssl"    # WPA3无线认证守护程序（使用OpenSSL后端）

    # === 存储管理系统 ===
    # "block-mount" # 存储设备分区挂载管理（支持USB/SD卡等外部存储）
    # "e2fsprogs"   # EXT2/3/4文件系统工具（mkfs/ext2resize等）
    # "f2fsck"      # F2FS文件系统检查修复工具
    # "fitblk"      # FIT映像解析器（U-Boot固件加载支持）
    # "fstools"     # 存储设备管理工具集（格式化/分区等操作）
    # "mkf2fs"      # F2FS文件系统创建工具（为eMMC/SD卡优化）

    # === 硬件支持模块 ===
    "kmod-nf-nathelper"       # IPv4 NAT辅助模块（支持VPN/流量重定向）
    "kmod-nf-nathelper-extra" # 扩展NAT支持（FTP/SIP等复杂协议穿透）
    # "kmod-crypto-hw-safexcel"  # 硬件加密引擎驱动（提升VPN/IPsec性能）
    # "kmod-eeprom-at24"         # AT24系列EEPROM存储支持（保存设备配置）
    # "kmod-gpio-button-hotplug" # GPIO按键事件处理（复位键/WPS键支持）
    # "kmod-hwmon-pwmfan"        # PWM风扇控制驱动（温控散热）
    # "kmod-i2c-mux-pca954x"     # I2C多路复用器驱动（扩展硬件管理总线）
    # "kmod-leds-gpio"           # GPIO控制的LED指示灯驱动
    # "kmod-nft-offload"         # 防火墙规则硬件卸载（MT7988 NPU加速）
    # "kmod-phy-aquantia"        # Aquantia万兆网卡PHY驱动（10Gbps支持）
    # "kmod-rtc-pcf8563"         # PCF8563实时时钟驱动（硬件时间同步）
    # "kmod-sfp"                 # SFP光模块热插拔支持
    # "kmod-usb3"                # USB 3.0主机控制器驱动

    # === 无线网络支持 ===
    # "kmod-mt7996-233-firmware" # MT7996 6GHz频段固件（WiFi 7三频支持）
    # "kmod-mt7996-firmware"     # MT7996 WiFi 7基础固件（2.4G/5G频段）
    # "mt7988-wo-firmware"       # MT7988无线优化固件（信号增强）

    # === 安全与加密  ===
    # "ca-bundle"          # CA根证书集合（HTTPS/SSL通信必备）
    # "libustream-openssl" # 基于OpenSSL的HTTP客户端（安全更新源访问）

    # === 系统管理与配置工具 ===
    # "uci"           # 统一配置接口（命令行系统配置）
    # "uclient-fetch" # 轻量级网络下载工具（脚本自动化依赖）
    # "opkg"          # OpenWrt包管理系统（软件安装/更新）
    # "mtd"           # Flash存储操作工具（固件刷写/备份）
    # "netifd"        # 网络接口管理守护进程（核心网络服务）

    # === LuCI Web界面 ===
    "luci-app-package-manager" # 图形化软件包管理界面
    "luci-compat"              # LuCI兼容层（支持旧版插件）
    "luci-lib-base"            # LuCI基础库（Web界面核心）
    "luci-lib-ipkg"            # LuCI包管理接口（opkg集成）
    "luci-light"               # 轻量级LuCI核心（基础Web界面）

    # === 本地化优化  ===
    "default-settings-chn" # 中国用户优化预设（汉化+国内源）

    ##############################################
    #                   快照版                   #
    ##############################################
    # === 核心系统组件 ===
    "apk-openssl"  # OpenSSL加密的APK包管理（轻量替代opkg）
    "base-files"   # 基础文件系统结构和配置
    "procd-ujail"  # 带容器隔离的进程管理
    "urandom-seed" # 系统启动随机数生成
    "urngd"        # 用户态随机数守护（加密增强）
    "libc"         # C标准库（必须）
    "libgcc"       # GCC运行时库（必须）

    # === 网络基础服务 ===
    "bridger"         # 用户态网络桥接
    "dnsmasq-full"    # 全功能DNS/DHCP服务
    "firewall4"       # nftables防火墙
    "nftables"        # nftables命令行工具
    "odhcp6c"         # IPv6 DHCP客户端
    "odhcpd-ipv6only" # IPv6 DHCP服务器
    "ppp"             # PPP拨号核心
    "ppp-mod-pppoe"   # PPPoE认证插件
    "wpad-openssl"    # WPA3无线认证

    # === 文件系统与存储 ===
    "automount" # 自动挂载热插拔设备
    "e2fsprogs" # EXT4文件系统工具
    "f2fsck"    # F2FS文件系统检查
    "fitblk"    # FIT映像解析器
    "fstools"   # 存储设备管理工具
    "mkf2fs"    # F2FS文件系统创建

    # === 硬件支持模块 ===
    "kmod-crypto-hw-safexcel"  # 硬件加密加速
    "kmod-eeprom-at24"         # EEPROM存储支持
    "kmod-gpio-button-hotplug" # 物理按键支持
    "kmod-hwmon-pwmfan"        # PWM风扇控制
    "kmod-i2c-mux-pca954x"     # I2C总线复用
    "kmod-leds-gpio"           # LED指示灯控制
    "kmod-mt7996-233-firmware" # MT7996 6GHz固件
    "kmod-mt7996-firmware"     # MT7996基础固件
    "kmod-nft-offload"         # 防火墙硬件卸载
    "kmod-phy-aquantia"        # 10G网卡PHY驱动
    "kmod-rtc-pcf8563"         # 硬件时钟驱动
    "kmod-sfp"                 # SFP光模块支持
    "kmod-usb3"                # USB 3.0控制器驱动

    # === 系统工具 ===
    "ca-bundle"          # CA根证书集
    "dropbear"           # SSH服务器
    "libustream-openssl" # 加密HTTP客户端
    "logd"               # 系统日志服务
    "mt7988-wo-firmware" # MT7988无线优化固件
    "mtd"                # Flash操作工具
    "netifd"             # 网络接口管理
    "uboot-envtools"     # U-Boot环境管理
    "uci"                # 统一配置接口
    "uclient-fetch"      # 轻量下载工具

    ##############################################
    #                   自定义                   #
    ##############################################
    "luci-app-argon-config" # Argon 主题配置
    "luci-app-diskman"      # 磁盘管理
    "luci-app-easyupdate"   # 简易系统更新
    "luci-app-nginx"        # Nginx 前端管理
    "luci-theme-argon"      # Argon 主题
    "luci-nginx"            # Nginx 前端引擎
    # "luci-app-acme"         # ACME 证书管理
    # "luci-app-alist"        # Alist 文档
    # "luci-app-dae"          # 大鹅
    # "luci-app-ddns-go"      # DDNS-Go 动态域名服务
    # "luci-app-fancontrol"   # 风扇控制
    # "luci-app-lucky"        # 内网穿透工具包
    # "luci-app-openclash"    # OpenClash 代理
    # "luci-app-qbittorrent"  # 丘比特下载器
    # "luci-app-samba4"       # Samba 4 共享文件系统
    # "luci-app-ttyd"         # TTYd 终端
    # "luci-app-zerotier"     # ZeroTier 虚拟网络
)

# 交互式选择包配置格式
select_package_format() {
    local pkg="$1"

    echo -e "\n处理软件包: $pkg"

    echo "未找到 $pkg 的配置项，请选择格式:"
    echo "1) CONFIG_DEFAULT_${pkg}"
    echo "2) CONFIG_PACKAGE_${pkg}"
    echo "3) 自定义格式"
    echo "4) 跳过此包"

    while true; do
        read -rp "请选择 (1-4): " choice
        case $choice in
        1)
            echo "CONFIG_DEFAULT_${pkg}"
            return 0
            ;;
        2)
            echo "CONFIG_PACKAGE_${pkg}"
            return 0
            ;;
        3)
            read -rp "请输入完整配置项名称 (如 CONFIG_CUSTOM_${pkg}): " custom_name
            echo "$custom_name"
            return 0
            ;;
        4) return 1 ;; # 跳过此包
        *) echo "无效选择，请重新输入" ;;
        esac
    done
}

# 处理包配置
process_package_config() {
    local pkg="$1"
    local config_file="$2"

    local escaped_pkg
    escaped_pkg=$(printf '%s\n' "$pkg" | sed "s/[][\.|$(){}?+*^]/\\&/g")

    local config_name=""

    # 尝试检测配置前缀
    for prefix in "CONFIG_DEFAULT_" "CONFIG_PACKAGE_"; do
        if grep -q "^${prefix}${escaped_pkg}=" "$config_file" ||
            grep -q "^# ${prefix}${escaped_pkg} is not set" "$config_file"; then
            config_name="${prefix}${pkg}"
            break
        fi
    done

    # 如果未找到，让用户选择
    if [ -z "$config_name" ]; then
        config_name=$(select_package_format "$pkg")
        local select_result=$?

        # 检查用户是否选择跳过
        if [ $select_result -ne 0 ]; then
            log_info "跳过软件包: $pkg"
            return 1
        fi
    fi

    # 设置配置
    if [ -n "$config_name" ]; then
        safe_set_config "$config_name" "y" "# $pkg" "$config_file"
        return 0
    else
        log_warning "无法确定 $pkg 的配置项名称，跳过"
        return 1
    fi
}

# 主函数
main() {
    log_info "开始设置固件配置..."

    # 检查是否已经准备好，如果没有则执行准备操作
    # if [ "$IMMORTALWRT_PREPARED" != "1" ]; then
    #     clean_immortalwrt_changes
    #     prepare_immortalwrt
    # fi

    # 进入immortalwrt目录
    # enter_immortalwrt_dir

    # 备份现有配置
    # backup_file "$FIRMWARE_CONFIG_FILE"

    # 如果.config不存在，进行初始设置
    if [ ! -f ".config" ]; then
        log_info "未找到.config文件，进行初始设置..."
        backup_file ".config"

        prepare_immortalwrt
        setup_feeds

        # 创建基础配置
        {
            echo "$FIRMWARE_CONFIG_TARGET_SNIPPET"
            echo "$FIRMWARE_CONFIG_SNIPPET"
        } >"$FIRMWARE_CONFIG_FILE"

        cp "$FIRMWARE_CONFIG_FILE" .config
        make defconfig
    # else
    #     # 备份现有配置
    #     backup_file ".config"
    fi

    # 处理包配置
    log_info "开始配置软件包..."
    for pkg in "${FIRMWARE_CONFIG_PACKAGES[@]}"; do
        process_package_config "$pkg" ".config"
    done

    # 生成最终配置
    make defconfig
    cp .config "$FIRMWARE_CONFIG_FILE"

    log_success "固件配置完成"
}

# 执行主函数
main "$@"
