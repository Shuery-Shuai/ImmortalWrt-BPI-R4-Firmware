#!/bin/bash

declare -r FIRMWARE_CONFIG_FILE=firmware.config

declare -r FIRMWARE_CONFIG_TARGET_SNIPPET="
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y
CONFIG_TARGET_BOARD=\"mediatek\"
CONFIG_TARGET_SUBTARGET=\"filogic\"
CONFIG_TARGET_PROFILE=\"DEVICE_bananapi_bpi-r4\"
CONFIG_TARGET_ROOTFS_PARTSIZE=796
"

declare -r FIRMWARE_CONFIG_SNIPPET="
# CONFIG_TESTING_KERNEL=y
"

declare -r FIRMWARE_CONFIG_PACKAGES=(
    ##############################################
    #                   稳定版                   #
    ##############################################
    # === 系统核心组件 ===
    "autocore" # 自动显示CPU负载/温度等硬件状态信息（系统监控核心）
    # "base-files"     # 基础文件系统结构和设备配置文件（/etc目录必需文件）
    # "libc"           # C标准库（所有程序运行的基础依赖）
    # "libgcc"         # GCC运行时库（低级CPU操作和异常处理支持）
    # "procd-ujail"    # 进程管理守护程序（支持容器化隔离，提高安全性）
    # "urandom-seed"   # 系统启动时生成高质量随机数种子
    # "urngd"          # 用户态随机数生成守护程序（补充系统熵源）
    # "logd"           # 系统日志守护进程（日志持久化存储）
    # "uboot-envtools" # U-Boot环境变量管理工具（修改启动参数）

    # === 网络基础服务 ===
    # "bridger"         # 用户态网络桥接工具（替代传统内核桥接）
    # "dnsmasq-full"    # 完整版DNS/DHCP服务器（支持DoT/DoH等高级功能）
    # "firewall4"       # 基于nftables的下一代防火墙
    # "nftables"        # nftables命令行工具（防火墙规则管理）
    # "odhcp6c"         # IPv6 DHCP客户端（获取运营商IPv6地址）
    # "odhcpd-ipv6only" # 精简版IPv6 DHCP服务器（为局域网分配IPv6地址）
    # "ppp"             # PPP拨号协议核心
    # "ppp-mod-pppoe"   # PPPoE拨号插件（用于ADSL/光纤认证）
    # "wpad-openssl"    # WPA3无线认证守护程序（使用OpenSSL后端）
    # "dropbear"        # 轻量级SSH服务器（远程管理）

    # === 存储管理系统 ===
    # "block-mount" # 存储设备分区挂载管理（支持USB/SD卡等外部存储）
    # "fstools"     # 存储设备管理工具集（格式化/分区等操作）
    # "e2fsprogs"   # EXT2/3/4文件系统工具（mkfs/ext2resize等）
    # "f2fsck"      # F2FS文件系统检查修复工具
    # "mkf2fs"      # F2FS文件系统创建工具（为eMMC/SD卡优化）
    # "fitblk"      # FIT映像解析器（U-Boot固件加载支持）

    # === 硬件支持模块 ===
    # "kmod-crypto-hw-safexcel"  # 硬件加密引擎驱动（提升VPN/IPsec性能）
    # "kmod-gpio-button-hotplug" # GPIO按键事件处理（复位键/WPS键支持）
    # "kmod-leds-gpio"           # GPIO控制的LED指示灯驱动
    "kmod-nf-nathelper"       # IPv4 NAT辅助模块（支持VPN/流量重定向）
    "kmod-nf-nathelper-extra" # 扩展NAT支持（FTP/SIP等复杂协议穿透）
    # "kmod-nft-offload"         # 防火墙规则硬件卸载（MT7988 NPU加速）
    # "kmod-phy-aquantia"        # Aquantia万兆网卡PHY驱动（10Gbps支持）
    # "kmod-hwmon-pwmfan"        # PWM风扇控制驱动（温控散热）
    # "kmod-i2c-mux-pca954x"     # I2C多路复用器驱动（扩展硬件管理总线）
    # "kmod-eeprom-at24"         # AT24系列EEPROM存储支持（保存设备配置）
    # "kmod-rtc-pcf8563"         # PCF8563实时时钟驱动（硬件时间同步）
    # "kmod-sfp"                 # SFP光模块热插拔支持
    # "kmod-usb3"                # USB 3.0主机控制器驱动

    # === 无线网络支持 ===
    # "kmod-mt7996-firmware"     # MT7996 WiFi 7基础固件（2.4G/5G频段）
    # "kmod-mt7996-233-firmware" # MT7996 6GHz频段固件（WiFi 7三频支持）
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
    "fstools"   # 存储设备管理工具
    "e2fsprogs" # EXT4文件系统工具
    "f2fsck"    # F2FS文件系统检查
    "mkf2fs"    # F2FS文件系统创建
    "fitblk"    # FIT映像解析器
    "automount" # 自动挂载热插拔设备

    # === 硬件支持模块 ===
    "kmod-crypto-hw-safexcel"  # 硬件加密加速
    "kmod-gpio-button-hotplug" # 物理按键支持
    "kmod-leds-gpio"           # LED指示灯控制
    "kmod-nft-offload"         # 防火墙硬件卸载
    "kmod-phy-aquantia"        # 10G网卡PHY驱动
    "kmod-hwmon-pwmfan"        # PWM风扇控制
    "kmod-i2c-mux-pca954x"     # I2C总线复用
    "kmod-eeprom-at24"         # EEPROM存储支持
    "kmod-mt7996-firmware"     # MT7996基础固件
    "kmod-mt7996-233-firmware" # MT7996 6GHz固件
    "kmod-rtc-pcf8563"         # 硬件时钟驱动
    "kmod-sfp"                 # SFP光模块支持
    "kmod-usb3"                # USB 3.0控制器驱动

    # === 系统工具 ===
    "ca-bundle"          # CA根证书集
    "libustream-openssl" # 加密HTTP客户端
    "dropbear"           # SSH服务器
    "uboot-envtools"     # U-Boot环境管理
    "uci"                # 统一配置接口
    "uclient-fetch"      # 轻量下载工具
    "logd"               # 系统日志服务
    "mtd"                # Flash操作工具
    "netifd"             # 网络接口管理
    "mt7988-wo-firmware" # MT7988无线优化固件

    ##############################################
    #                   自定义                   #
    ##############################################
    "luci-theme-argon"      # Argon 主题
    "luci-app-argon-config" # Argon 主题配置
    "luci-app-diskman"      # 磁盘管理
    "luci-app-fancontrol"   # 风扇控制
    "luci-nginx"            # Nginx 前端引擎
    "luci-app-nginx"        # Nginx 前端管理
    "luci-app-easyupdate"   # 简易系统更新
    # "luci-app-zerotier"     # ZeroTier 虚拟网络
    # "luci-app-lucky"        # 内网穿透工具包
    # "luci-app-acme"         # ACME 证书管理
    # "luci-app-alist"        # Alist 文档
    # "luci-app-dae"          # 大鹅
    # "luci-app-ddns-go"      # DDNS-Go 动态域名服务
    # "luci-app-samba4"       # Samba 4 共享文件系统
    # "luci-app-openclash"    # OpenClash 代理
    # "luci-app-qbittorrent"  # 丘比特下载器
    # "luci-app-ttyd"         # TTYd 终端
)

if [ -d "immortalwrt" ]; then
    echo "进入 'immortalwrt' 目录..."
    cd immortalwrt
elif [ "$(basename "$(pwd)")" != "immortalwrt" ]; then
    echo "当前目录不是或不存在 'immortalwrt'，请先进入正确的目录。"
    exit 1
fi

if [ -f $FIRMWARE_CONFIG_FILE ]; then
    mv $FIRMWARE_CONFIG_FILE $FIRMWARE_CONFIG_FILE.bak
fi
if [ -f .config ]; then
    cp .config .config.bak
else
    git restore .
    git pull
    bash ./diy-part1.sh
    ./scripts/feeds update -a -f
    bash ./diy-part2.sh
    ./scripts/feeds install -a -f
    touch $FIRMWARE_CONFIG_FILE
    echo $FIRMWARE_CONFIG_TARGET_SNIPPET $FIRMWARE_CONFIG_SNIPPET >>$FIRMWARE_CONFIG_FILE
    cp $FIRMWARE_CONFIG_FILE .config
    make defconfig
fi

safe_set_config() {
    local key="$1"
    local value="$2"
    local comment="$3"

    local escaped_key=$(printf '%s\n' "$key" | sed 's/[]\.|$(){}?+*^]/\\&/g')

    if grep -q "^${escaped_key}=" ".config"; then
        sed -i "s|^${escaped_key}=.*|${key}=${value}|" ".config"
        echo "已启用: ${key}=${value} ${comment}"
    elif grep -q "^# ${escaped_key} is not set" ".config"; then
        sed -i "s|^# ${escaped_key} is not set|${key}=${value}|" ".config"
        echo "已设置: ${key}=${value} ${comment}"
    else
        echo "${key}=${value}" >>".config"
        echo "已添加: ${key}=${value} ${comment}"
    fi
}

for pkg in "${FIRMWARE_CONFIG_PACKAGES[@]}"; do
    echo -e "\n处理软件包: $pkg"

    escaped_pkg=$(printf '%s\n' "$pkg" | sed 's/[]\.|$(){}?+*^]/\\&/g')

    detected_prefix=""
    if grep -q "^CONFIG_DEFAULT_${escaped_pkg}=" ".config" ||
        grep -q "^# CONFIG_DEFAULT_${escaped_pkg} is not set" ".config"; then
        detected_prefix="CONFIG_DEFAULT_"
    elif grep -q "^CONFIG_PACKAGE_${escaped_pkg}=" ".config" ||
        grep -q "^# CONFIG_PACKAGE_${escaped_pkg} is not set" ".config"; then
        detected_prefix="CONFIG_PACKAGE_"
    fi

    if [ -z "$detected_prefix" ]; then
        echo "未找到 $pkg 的配置项，请选择格式:"
        echo "1) CONFIG_DEFAULT_${pkg}"
        echo "2) CONFIG_PACKAGE_${pkg}"
        echo "3) 自定义格式"
        echo "4) 跳过此包"
        read -p "请选择 (1-4): " choice

        case $choice in
        1) config_name="CONFIG_DEFAULT_${pkg}" ;;
        2) config_name="CONFIG_PACKAGE_${pkg}" ;;
        3)
            read -p "请输入完整配置项名称 (如 CONFIG_CUSTOM_${pkg}): " custom_name
            config_name="$custom_name"
            ;;
        4)
            echo "跳过 $pkg"
            continue
            ;;
        *)
            echo "无效选择，跳过 $pkg"
            continue
            ;;
        esac
    else
        config_name="${detected_prefix}${pkg}"
    fi

    safe_set_config "$config_name" "y"
done

make defconfig
cp .config $FIRMWARE_CONFIG_FILE
