#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Clone custom packages
git clone --depth 1 https://github.com/zhanghua000/luci-app-nginx package/luci-app-nginx 

# Modify filogic partition
PARTITION_FILE="target/linux/mediatek/image/filogic.mk"
printf "Modifying $PARTITION_FILE...\n"
SCOPE_BUILD_START='^define\sBuild\/mt798x-gpt'
SCOPE_BUILD_END='^endef'
SCOPE_DEVICE_START='^define\sDevice\/bananapi_bpi-r4-common'
SCOPE_DEVICE_END='^endef'
sed -i -E \
  -e "/$SCOPE_BUILD_START/,/$SCOPE_BUILD_END/ {
       # 修改分区表
       /recovery/s/32M@/102M@/
       /install/s/@44M/@114M/
       /production/s/@64M/@134M/
     }" \
  -e "/$SCOPE_DEVICE_START/,/$SCOPE_DEVICE_END/ {
       # 修改分区大小
       /append-image-stage\s+initramfs-recovery\.itb/s/44m/114m/
       /mt7988-bl2\s+spim-nand-ubi-comb/s/44M/114M/
       /mt7988-bl31-uboot\s+.*-snand/s/45M/115M/
       /mt7988-bl2\s+emmc-comb/s/51M/121M/
       /mt7988-bl31-uboot\s+.*-emmc/s/52M/122M/
       /mt798x-gpt\s+emmc/s/56M/106M/
       /append-image\s+squashfs-sysupgrade\.itb/s/64M/134M/
       /IMAGE_SIZE/s/64/134/
     }" \
  "$PARTITION_FILE"
printf "Done. Result:\n"
scope_grep() {
  local file=$1
  local start=$2
  local end=$3
  local patterns=$4
  echo "━━━━━━━━━━━━━━━━━━━━ Partition info from $start to $end ━━━━━━━━━━━━━━━━━━━━"
  sed -n -e "/$start/,/$end/p" "$file" | grep -E --color=always "$patterns"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
scope_grep "$PARTITION_FILE" "$SCOPE_BUILD_START" "$SCOPE_BUILD_END" \
  'recovery|install|production'
scope_grep "$PARTITION_FILE" "$SCOPE_DEVICE_START" "$SCOPE_DEVICE_END" \
  'append-image-stage\s+initramfs-recovery\.itb|mt7988-bl2\s+spim-nand-ubi-comb|mt7988-bl31-uboot\s+.*-snand|mt7988-bl2\s+emmc-comb|mt7988-bl31-uboot\s+.*-emmc|mt798x-gpt\s+emmc|append-image\s+squashfs-sysupgrade\.itb|IMAGE_SIZE'

# Modify IP
sed -i 's/192.168.1.1/192.168.0.1/g' package/base-files/files/bin/config_generate

# Modify shell to bash
sed -i 's/\/bin\/ash/\/bin\/bash/' package/base-files/files/etc/passwd

# Modify password to empty
# sed -i '/CYXluq4wUazHjmCDBCqXF/d' package/lean/default-settings/files/zzz-default-setting

# Change to official master source of applications including luci-app-openclash and luci-theme-argon
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon
clone_repo() {
  local repo=$1 target=$2
  printf "Cloning $repo to $target...\n"
  for i in {1..3}; do
    git clone --depth 1 -b master "$repo" "$target" && break || {
      echo "Clone attempt $i failed, retrying..."
      sleep $((i * 2))
      rm -rf "$target"
    }
  done
}
clone_repo https://github.com/vernesong/OpenClash \
  feeds/luci/applications/luci-app-openclash
clone_repo https://github.com/jerrykuku/luci-theme-argon.git \
  feeds/luci/themes/luci-theme-argon

replace_collections() {
  local -n _replacements=$1
  local file pattern escaped_pattern escaped_replacement
  local -a sed_script
  for pattern in "${!_replacements[@]}"; do
    escaped_pattern=$(sed 's/[\/&]/\\&/g' <<<"$pattern")
    escaped_replacement=$(sed 's/[\/&]/\\&/g' <<<"${_replacements[$pattern]}")
    sed_script+=("-e" "s/${escaped_pattern}/${escaped_replacement}/g")
  done
  for file in feeds/luci/collections/*/Makefile; do
    [[ -e "$file" ]] || continue # 跳过不存在的文件
    printf "Modifying %s...\n" "$file"
    sed -i "${sed_script[@]}" "$file"
  done
}
declare -A replacements=(
  ["luci-theme-bootstrap"]="luci-theme-argon"
  ["+uhttpd +uhttpd-mod-ubus"]=""
)
replace_collections replacements

# Modify Argon login page from float left to center
THEME_CSS_FILE="feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/css/cascade.css"
printf "Modifying $THEME_CSS_FILE...\n"
awk -i inplace -v RS='}' '
  # 主容器样式修改
  $0 ~ /\.login-page\s+\.login-container\s*\{/ {
    # 替换属性
    gsub(/height:\s*100%;?/, "height:400px;");
    gsub(/margin-left:\s*4\.5rem;?/, "margin:auto;");
    gsub(/top:\s*0;?/, "top:0; bottom:0; left:0; right:0;");
    gsub(/min-height:\s*100%;?/, "min-height:400px;");
    gsub(/width:\s*420px;?/, "width:400px;");
    gsub(/box-shadow/, "border-radius:15px; box-shadow");
    gsub(/margin-left:\s*5%;?/, "margin-left:auto;");
  }
  # 登录表单背景和圆角
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s*\{/ {
    gsub(/background-color:\s*#fff;?/, "background-color:rgba(255,255,255,0);");
    if (!/border-radius/) {
      sub(/\{/, "{ border-radius:15px; ");
    }
  }
  # 品牌标志边距
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.brand\s*\{/ {
    gsub(/margin:\s*50px\s+auto\s+100px\s+50px;?/, "margin:15px auto;");
  }
  # 表单内边距
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s*\{/ {
    gsub(/padding:\s*20px\s+50px;?/, "padding:10px 50px;");
  }
  # 错误框样式
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s+\.errorbox\s*\{/ {
    gsub(/padding-bottom:\s*2rem;?/, "padding:10px;");
  }
  # 按钮边距
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.cbi-button-apply\s*\{/ {
    gsub(/margin:\s*30px\s+0px\s+100px;?/, "margin:15px auto;");
  }
  # 输入组边距
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s+\.input-group\s*\{/ {
    gsub(/margin-bottom:\s*1\.25rem;?/, "margin-bottom:1rem;");
  }
  # 输入框边距修正
  $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s+\.input-group input\s*\{/ {
    gsub(/margin:\s*[0|.]825rem\s+0;?/, "margin-bottom:0;");
  }
  # 页脚位置
  $0 ~ /\.login-page\s+\.login-container\s+footer\s+\.ftc\s*\{/ {
    gsub(/bottom:\s*30px;?/, "bottom:0;");
  }
  # 全局替换 margin-left:0rem
  {
    gsub(/margin-left:\s*0rem\s*!important/, "margin-left:auto !important");
  }
  # 输出修改后的内容并补回 }
  { print $0 RT }
' "$THEME_CSS_FILE"

# Modify easyupdate.sh to support ImmortalWrt
EASYUPDATE_FILE="feeds/sundaqiang/luci/applications/luci-app-easyupdate/root/usr/bin/easyupdate.sh"
printf "Modifying %s...\n" "$EASYUPDATE_FILE"
# 修改 OpenWrt 为 ImmortalWrt
# 修改 fileName 截取范围
# 修改 suffix 为 squashfs-sysupgrade.itb
sed -i -E \
  -e '/curl|filename/s/OpenWrt/ImmortalWrt/g' \
  -e '/curl|filename/s/openwrt/immortalwrt/g' \
  -e '/curl|filename/s/Openwrt/Immortalwrt/g' \
  -e '/file[Nn]ame/s/0:7/0:11/g' \
  -e '/^\s*file/s/\$\{checkShaRet/\/tmp\/\$\{checkShaRet/g' \
  -e '/Check\s+whether\s+EFI\s+firmware/,/^\s*fi/ {
      /^\s+fi/a\  suffix="squashfs-sysupgrade.itb"
      s/^/#/
    }' \
  -e '/^\s*function\s+checkSha/,/^\s*\}/ {
      s/img\.gz/\itb/
    }' \
  "$EASYUPDATE_FILE"
