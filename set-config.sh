#!/bin/bash

# 启用指定软件包的配置脚本
# 用法：./set-config.sh [配置文件路径，默认为当前目录下的.config]

# ========================
# 用户可配置区域 - 按需修改
# ========================

# 设备型号设置
TARGET_DEVICE="bananapi_bpi-r4" # 修改为您需要的设备
# KERNEL_VERSION="6.6"             # 内核版本

# 要启用的内核选项
KERNEL_OPTIONS=(
    # "TESTING_KERNEL" # 启用测试内核
    # "KERNEL_PERF_EVENTS" # 性能监控支持
    # "KERNEL_PROFILING"   # 性能分析工具
)

# 要启用的软件包列表
PACKAGES=(
    ##############################################
    #                   稳定版                   #
    ##############################################
    # # === 系统核心组件 ===
    "autocore" # 自动显示CPU负载/温度等硬件状态信息（系统监控核心）
    # "base-files"     # 基础文件系统结构和设备配置文件（/etc目录必需文件）
    # "libc"           # C标准库（所有程序运行的基础依赖）
    # "libgcc"         # GCC运行时库（低级CPU操作和异常处理支持）
    # "procd-ujail"    # 进程管理守护程序（支持容器化隔离，提高安全性）
    # "urandom-seed"   # 系统启动时生成高质量随机数种子
    # "urngd"          # 用户态随机数生成守护程序（补充系统熵源）
    # "logd"           # 系统日志守护进程（日志持久化存储）
    # "uboot-envtools" # U-Boot环境变量管理工具（修改启动参数）

    # # === 网络基础服务 ===
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

    # # === 存储管理系统 ===
    # "block-mount" # 存储设备分区挂载管理（支持USB/SD卡等外部存储）
    # "fstools"     # 存储设备管理工具集（格式化/分区等操作）
    # "e2fsprogs"   # EXT2/3/4文件系统工具（mkfs/ext2resize等）
    # "f2fsck"      # F2FS文件系统检查修复工具
    # "mkf2fs"      # F2FS文件系统创建工具（为eMMC/SD卡优化）
    # "fitblk"      # FIT映像解析器（U-Boot固件加载支持）

    # # === 硬件支持模块 ===
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

    # # === 无线网络支持 ===
    # "kmod-mt7996-firmware"     # MT7996 WiFi 7基础固件（2.4G/5G频段）
    # "kmod-mt7996-233-firmware" # MT7996 6GHz频段固件（WiFi 7三频支持）
    # "mt7988-wo-firmware"       # MT7988无线优化固件（信号增强）

    # # === 安全与加密  ===
    # "ca-bundle"          # CA根证书集合（HTTPS/SSL通信必备）
    # "libustream-openssl" # 基于OpenSSL的HTTP客户端（安全更新源访问）

    # #            系统管理与配置工具              #
    # "uci"           # 统一配置接口（命令行系统配置）
    # "uclient-fetch" # 轻量级网络下载工具（脚本自动化依赖）
    # "opkg"          # OpenWrt包管理系统（软件安装/更新）
    # "mtd"           # Flash存储操作工具（固件刷写/备份）
    # "netifd"        # 网络接口管理守护进程（核心网络服务）

    # # === LuCI Web界面 ===
    "luci-app-package-manager" # 图形化软件包管理界面
    "luci-compat"              # LuCI兼容层（支持旧版插件）
    "luci-lib-base"            # LuCI基础库（Web界面核心）
    "luci-lib-ipkg"            # LuCI包管理接口（opkg集成）
    "luci-light"               # 轻量级LuCI核心（基础Web界面）

    # # === 本地化优化  ===
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
    "luci-app-nginx"        # Nginx 前端引擎
    # "luci-app-acme"         # ACME 证书管理
    # "luci-app-ddns-go"      # DDNS-Go 动态域名服务
    "luci-app-easyupdate" # 简易系统更新
    # "luci-app-zerotier"     # ZeroTier 虚拟网络
    # "luci-app-samba4"       # Samba 4 共享文件系统
    # "luci-app-ttyd"         # TTYd 终端
    # "luci-app-openclash"    # OpenClash 代理
    # "luci-app-alist"        # Alist 文档
    # "luci-app-qbittorrent"  # 丘比特下载器
)

# 其他系统级配置
declare -A SYSTEM_CONFIGS=(
    # 存储设置
    ["TARGET_ROOTFS_PARTSIZE"]="405" # 根分区大小(MB)
    # ["TARGET_IMAGES_GZIP"]="y"       # 压缩固件镜像

    # 网络优化
    # ["DEFAULT_br-lan_IGMP_SNOOPING"]="y"
    # ["DEFAULT_br-lan_MLD_SNOOPING"]="y"

    # 本地化设置
    # ["DEFAULT_TIMEZONE"]="CST-8"
    # ["DEFAULT_LANGUAGE"]="zh_CN"
)

CONFIG_FILE="${1:-.config}"

# ========================
# 脚本核心逻辑
# ========================

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件 $CONFIG_FILE 不存在，请先运行 make menuconfig 生成配置文件。"
    exit 1
fi

# 备份原始配置文件
BACKUP_FILE="${CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "已创建备份: $BACKUP_FILE"

# 更新仓库
git restore .
git pull
bash ./diy-part1.sh
./scripts/feeds update -a -f
bash ./diy-part2.sh
./scripts/feeds install -a -f

# 设备锁定功能 - 防止defconfig覆盖
lock_device_config() {
    local device="$1"

    # 禁用默认设备
    sed -i '/CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one/d' "$CONFIG_FILE"
    echo "# CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one is not set" >>"$CONFIG_FILE"

    # 启用目标设备
    echo "CONFIG_TARGET_mediatek_filogic_DEVICE_${device}=y" >>"$CONFIG_FILE"

    # 设置TARGET_PROFILE
    sed -i '/CONFIG_TARGET_PROFILE/d' "$CONFIG_FILE"
    echo "CONFIG_TARGET_PROFILE=\"DEVICE_${device}\"" >>"$CONFIG_FILE"

    # 添加保护注释
    echo "# !! DEVICE LOCKED BY SCRIPT - DO NOT MODIFY MANUALLY !!" >>"$CONFIG_FILE"
}

# 函数：安全设置配置项
safe_set_config() {
    local key="$1"
    local value="$2"
    local comment="$3"

    # 转义特殊字符
    local escaped_key=$(printf '%s\n' "$key" | sed 's/[]\.|$(){}?+*^]/\\&/g')

    if grep -q "^${escaped_key}=" "$CONFIG_FILE"; then
        # 更新现有配置
        sed -i "s|^${escaped_key}=.*|${key}=${value}|" "$CONFIG_FILE"
        echo "已启用: ${key}=${value} ${comment}"
    elif grep -q "^# ${escaped_key} is not set" "$CONFIG_FILE"; then
        # 替换禁用行
        sed -i "s|^# ${escaped_key} is not set|${key}=${value}|" "$CONFIG_FILE"
        echo "已设置: ${key}=${value} ${comment}"
    else
        # 添加新配置项
        echo "${key}=${value}" >>"$CONFIG_FILE"
        echo "已添加: ${key}=${value} ${comment}"
    fi
}

echo -e "\n===== 锁定设备配置 ====="
lock_device_config "$TARGET_DEVICE"
echo "已锁定设备: $TARGET_DEVICE"

# 处理内核选项
echo -e "\n===== 设置内核选项 ====="
for option in "${KERNEL_OPTIONS[@]}"; do
    safe_set_config "CONFIG_$option" "y" "// 内核功能"
done

# 处理系统级配置
echo -e "\n===== 设置系统配置 ====="
for key in "${!SYSTEM_CONFIGS[@]}"; do
    safe_set_config "CONFIG_$key" "${SYSTEM_CONFIGS[$key]}" "// 系统参数"
done

# 处理软件包
echo -e "\n===== 设置软件包 ====="
for pkg in "${PACKAGES[@]}"; do
    echo -e "\n处理软件包: $pkg"

    # 转义特殊字符
    escaped_pkg=$(printf '%s\n' "$pkg" | sed 's/[]\.|$(){}?+*^]/\\&/g')

    # 尝试自动检测格式
    detected_prefix=""
    if grep -q "^CONFIG_DEFAULT_${escaped_pkg}=" "$CONFIG_FILE" ||
        grep -q "^# CONFIG_DEFAULT_${escaped_pkg} is not set" "$CONFIG_FILE"; then
        detected_prefix="CONFIG_DEFAULT_"
    elif grep -q "^CONFIG_PACKAGE_${escaped_pkg}=" "$CONFIG_FILE" ||
        grep -q "^# CONFIG_PACKAGE_${escaped_pkg} is not set" "$CONFIG_FILE"; then
        detected_prefix="CONFIG_PACKAGE_"
    fi

    # 如果未检测到，让用户选择
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

    # 安全设置配置
    safe_set_config "$config_name" "y"
done

# 确保核心配置存在
# declare -A CORE_CONFIGS=(
#     ["CONFIG_HAS_SUBTARGETS"]="y"
#     ["CONFIG_HAS_DEVICES"]="y"
#     ["CONFIG_TARGET_BOARD"]="\"mediatek\""
#     ["CONFIG_TARGET_SUBTARGET"]="\"filogic\""
#     ["CONFIG_TARGET_ARCH_PACKAGES"]="\"aarch64_cortex-a53\""
#     ["CONFIG_DEFAULT_TARGET_OPTIMIZATION"]="\"-Os -pipe -mcpu=cortex-a53\""
#     ["CONFIG_CPU_TYPE"]="\"cortex-a53\""
#     ["CONFIG_LINUX_6_6"]="y"
# )

# echo -e "\n===== 设置核心配置 ====="
# for key in "${!CORE_CONFIGS[@]}"; do
#     safe_set_config "$key" "${CORE_CONFIGS[$key]}" "// 系统核心"
# done

# ========================
# 后续处理建议
# ========================
echo -e "\n配置完成! 已处理:"
echo " - 设备型号: 1 个"
echo " - 内核选项: ${#KERNEL_OPTIONS[@]} 个"
echo " - 系统配置: ${#SYSTEM_CONFIGS[@]} 个"
echo " - 软件包: ${#PACKAGES[@]} 个"

cat <<EOF

********************** 后续步骤 **********************
1. 运行依赖解析命令:
   make defconfig

2. 验证内核配置:
   make kernel_menuconfig

3. 开始编译:
   make -j\$(nproc) V=s

4. 检查测试内核功能:
   # 编译后运行
   grep CONFIG_TESTING_KERNEL build_dir/target-*/linux-*/.config
   
   # 在设备上验证
   uname -a
   cat /proc/config.gz | gunzip | grep TESTING
*****************************************************
EOF

# 可选：自动运行defconfig
read -p "是否立即运行 'make defconfig'? [y/N] " run_defconfig
if [[ "$run_defconfig" =~ [yY] ]]; then
    echo "运行 make defconfig..."
    make defconfig
    echo "defconfig 已完成！"
fi

echo "将使用 make menuconfig 验证配置……"
make menuconfig
echo "完成！"
