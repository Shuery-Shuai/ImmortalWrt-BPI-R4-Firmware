#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
# echo 'src-git sundaqiang https://github.com/sundaqiang/openwrt-packages-backup' >>feeds.conf.default
# echo 'src-git fancontrol https://github.com/rockjake/luci-app-fancontrol.git' >>feeds.conf.default

# Modify filogic partition
# PARTITION_FILE="target/linux/mediatek/image/filogic.mk"
# printf "Modifying $PARTITION_FILE...\n"
# SCOPE_BUILD_START='^define\sBuild\/mt798x-gpt'
# SCOPE_BUILD_END='^endef'
# SCOPE_DEVICE_START='^define\sDevice\/bananapi_bpi-r4-common'
# SCOPE_DEVICE_END='^endef'
# sed -i -E \
#   -e "/$SCOPE_BUILD_START/,/$SCOPE_BUILD_END/ {
#        # 修改分区表
#        /recovery/s/32M@/82M@/
#        /install/s/@44M/@94M/
#        /production/s/@64M/@114M/
#      }" \
#   -e "/$SCOPE_DEVICE_START/,/$SCOPE_DEVICE_END/ {
#        # 修改分区大小
#        /append-image-stage\s+initramfs-recovery\.itb/s/44m/94m/
#        /mt7988-bl2\s+spim-nand-ubi-comb/s/44M/94M/
#        /mt7988-bl31-uboot\s+.*-snand/s/45M/95M/
#        /mt7988-bl2\s+emmc-comb/s/51M/101M/
#        /mt7988-bl31-uboot\s+.*-emmc/s/52M/102M/
#        /mt798x-gpt\s+emmc/s/56M/106M/
#        /append-image\s+squashfs-sysupgrade\.itb/s/64M/114M/
#        /IMAGE_SIZE/s/64/114/
#      }" \
#   "$PARTITION_FILE"
# printf "Done. Result:\n"
# scope_grep() {
#   local file=$1
#   local start=$2
#   local end=$3
#   local patterns=$4
#   echo "━━━━━━━━━━━━━━━━━━━━ Partition info from $start to $end ━━━━━━━━━━━━━━━━━━━━"
#   sed -n -e "/$start/,/$end/p" "$file" | grep -E --color=always "$patterns"
#   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# }
# scope_grep "$PARTITION_FILE" "$SCOPE_BUILD_START" "$SCOPE_BUILD_END" \
#   'recovery|install|production'
# scope_grep "$PARTITION_FILE" "$SCOPE_DEVICE_START" "$SCOPE_DEVICE_END" \
#   'append-image-stage\s+initramfs-recovery\.itb|mt7988-bl2\s+spim-nand-ubi-comb|mt7988-bl31-uboot\s+.*-snand|mt7988-bl2\s+emmc-comb|mt7988-bl31-uboot\s+.*-emmc|mt798x-gpt\s+emmc|append-image\s+squashfs-sysupgrade\.itb|IMAGE_SIZE'

# Add xdp-sockets-diag
# Refer: https://github.com/coolsnowwolf/lede/discussions/11799#discussioncomment-8626809
echo '
define KernelPackage/xdp-sockets-diag
  SUBMENU:=$(NETWORK_SUPPORT_MENU)
  TITLE:=PF_XDP sockets monitoring interface support for ss utility
  KCONFIG:= \
    CONFIG_XDP_SOCKETS=y \
    CONFIG_XDP_SOCKETS_DIAG
  FILES:=$(LINUX_DIR)/net/xdp/xsk_diag.ko
  AUTOLOAD:=$(call AutoLoad,31,xsk_diag)
endef

define KernelPackage/xdp-sockets-diag/description
  Support for PF_XDP sockets monitoring interface used by the ss tool
endef

$(eval $(call KernelPackage,xdp-sockets-diag))
' >>package/kernel/linux/modules/netsupport.mk

# Add tx power patch
# rm package/firmware/wireless-regdb/patches/500-*.patch
# rm package/firmware/wireless-regdb/patches/600-*.patch
# wget https://raw.githubusercontent.com/Rahzadan/openwrt_bpi-r4_mtk_builder/main/files/500-tx_power.patch \
#   -O package/firmware/wireless-regdb/patches/500-tx_power.patch
# Support BE14000
# cd ..
# if [ -d "openwrt_bpi-r4_mtk_builder" ]; then
#   cd openwrt_bpi-r4_mtk_builder
#   git restore .
#   git pull
#   cd ..
# else
#   git clone --depth 1 https://github.com/Rahzadan/openwrt_bpi-r4_mtk_builder.git
# fi
# chmod 776 -R openwrt_bpi-r4_mtk_builder
# cd openwrt_bpi-r4_mtk_builder
# sed -i -E \
#   -e '/^\s*rm\s+-rf\s+openwrt\s*$/s/^/#/' \
#   -e '\|^\s*git\s+clone.*openwrt\.git|s/^/#/' \
#   -e '\|^\s*cd\s+openwrt\s*[;&]|s/^/#/' \
#   -e '\|^\s*git\s+clone\s+http|s|clone|clone --depth 1|' \
#   -e '\|^\s*rm\s+-rf\s+openwrt/package|s|openwrt|immortalwrt|' \
#   -e '\|^\s*\\cp\s+-r\s+files/regdb\.Makefile|s|openwrt|immortalwrt|' \
#   -e '\|^\s*-O\s+openwrt/package|s|openwrt|immortalwrt|' \
#   -e '\|^\s*cd\s+openwrt\s*$|s|openwrt|immortalwrt|' \
#   build1.sh
# sed -i -E \
#   -e '\|^\s*cd\s+openwrt\s*$|s|openwrt|immortalwrt|' \
#   -e '\|^\s*git\s+clone\s+http|s|clone|clone --depth 1|' \
#   -e '\|^\s*./scripts/feeds|s/^/#/' \
#   -e '\|^\s*\\cp.*config|s/^/#/' \
#   -e '\|^\s*make|s/^/#/' \
#   build2.sh
# bash ./build1.sh
# bash ./build2.sh
