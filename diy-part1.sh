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
modify_partition() {
  local append_size="$1"
  local partition_file="target/linux/mediatek/image/filogic.mk"
  local scope_build_start='^define\sBuild\/mt798x-gpt'
  local scope_build_end='^endef'
  local scope_device_start='^define\sDevice\/bananapi_bpi-r4-common'
  local scope_device_end='^endef'

  # 检查文件是否存在
  if [[ ! -f "${partition_file}" ]]; then
    printf "Error: File %s does not exist.\n" "${partition_file}" >&2
    return 1
  fi

  printf "Modifying %s...\n" "${partition_file}"

  # 计算新的大小
  local new_32=$((32 + append_size))
  local new_44=$((44 + append_size))
  local new_45=$((45 + append_size))
  local new_51=$((51 + append_size))
  local new_52=$((52 + append_size))
  local new_56=$((56 + append_size))
  local new_64=$((64 + append_size))

  # 执行 sed 操作并检查结果
  if ! sed -i -E \
    -e "/${scope_build_start}/,/${scope_build_end}/ {
       # 修改分区表
       /recovery/s/32M@/${new_32}M@/
       /install/s/@44M/@${new_44}M/
       /production/s/@64M/@${new_64}M/
     }" \
    -e "/${scope_device_start}/,/${scope_device_end}/ {
       # 修改分区大小
       /append-image-stage\s+initramfs-recovery\.itb/s/44m/${new_44}m/
       /mt7988-bl2\s+spim-nand-ubi-comb/s/44M/${new_44}M/
       /mt7988-bl31-uboot\s+.*-snand/s/45M/${new_45}M/
       /mt7988-bl2\s+emmc-comb/s/51M/${new_51}M/
       /mt7988-bl31-uboot\s+.*-emmc/s/52M/${new_52}M/
       /mt798x-gpt\s+emmc/s/56M/${new_56}M/
       /append-image\s+squashfs-sysupgrade\.itb/s/64M/${new_64}M/
       /IMAGE_SIZE/s/64/${new_64}/
     }" \
    "${partition_file}"; then
    printf "Error: Failed to modify %s.\n" "${partition_file}" >&2
    return 1
  fi

  printf "Done. Result:\n"
  return 0
}

# Grep lines in scope
scope_grep() {
  local file="$1"
  local start_pattern="$2"
  local end_pattern="$3"
  local grep_patterns="$4"

  echo "━━━━━━━━━━━━━━━━━━━━ Partition info from ${start_pattern} to ${end_pattern} ━━━━━━━━━━━━━━━━━━━━"
  sed -n -e "/${start_pattern}/,/${end_pattern}/p" "${file}" | grep -E --color=always "${grep_patterns}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# local append_size=50
# modify_partition $append_size
# scope_grep "$PARTITION_FILE" "$SCOPE_BUILD_START" "$SCOPE_BUILD_END" \
#   'recovery|install|production'
# scope_grep "$PARTITION_FILE" "$SCOPE_DEVICE_START" "$SCOPE_DEVICE_END" \
#   'append-image-stage\s+initramfs-recovery\.itb|mt7988-bl2\s+spim-nand-ubi-comb|mt7988-bl31-uboot\s+.*-snand|mt7988-bl2\s+emmc-comb|mt7988-bl31-uboot\s+.*-emmc|mt798x-gpt\s+emmc|append-image\s+squashfs-sysupgrade\.itb|IMAGE_SIZE'

# Add xdp-sockets-diag
# Refer: https://github.com/coolsnowwolf/lede/discussions/11799#discussioncomment-8626809
xdp_sockets_diag_content='
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
'

echo "${xdp_sockets_diag_content}" >>package/kernel/linux/modules/netsupport.mk

# 添加 tx power patch
# Refer: https://github.com/Rahzadan/openwrt_bpi-r4_mtk_builder
wireless_regdb_makefile="package/firmware/wireless-regdb/Makefile"
wireless_regdb_patch_dir="package/firmware/wireless-regdb/patches"
tx_power_patch="${wireless_regdb_patch_dir}/500-tx_power.patch"

rm -f "${wireless_regdb_makefile}"
rm -f "${wireless_regdb_patch_dir}"/*.patch

wget https://raw.githubusercontent.com/Rahzadan/openwrt_bpi-r4_mtk_builder/main/files/regdb.Makefile \
  -O "${wireless_regdb_makefile}"
wget https://raw.githubusercontent.com/Rahzadan/openwrt_bpi-r4_mtk_builder/main/files/500-tx_power.patch \
  -O "${tx_power_patch}"
