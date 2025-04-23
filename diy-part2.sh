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

# Modify filogic partition
FILE="target/linux/mediatek/image/filogic.mk"
SCOPE_BUILD='/define Build\/mt798x-gpt/,/endef/'
SCOPE_DEVICE='/define Device\/bananapi_bpi-r4-common/,/endef/'
sed -i -E \
  -e "$SCOPE_BUILD { /-N recovery[[:space:]]+-r[[:space:]]+-p /s/32M@12M/72M@12M/ }" \
  -e "$SCOPE_BUILD { /-N install[[:space:]]+-r[[:space:]]+-p /s/44M/84M/ }" \
  -e "$SCOPE_BUILD { /-N production[[:space:]]+-p /s/@64M/@104M/g }" \
  -e "$SCOPE_DEVICE { /append-image-stage initramfs-recovery\.itb \| check-size /s/44m/84m/ }" \
  -e "$SCOPE_DEVICE { s/pad-to 44M/pad-to 84M/g }" \
  -e "$SCOPE_DEVICE { s/pad-to 45M/pad-to 85M/g }" \
  -e "$SCOPE_DEVICE { s/pad-to 51M/pad-to 91M/g }" \
  -e "$SCOPE_DEVICE { s/pad-to 52M/pad-to 92M/g }" \
  -e "$SCOPE_DEVICE { s/pad-to 56M/pad-to 96M/g }" \
  -e "$SCOPE_DEVICE { s/pad-to 64M/pad-to 104M/g }" \
  -e "$SCOPE_DEVICE { /IMAGE_SIZE := \$\$\(shell expr /s/64/104/ }" \
  "$FILE"


# Modify default IP
# sed -i 's/192.168.1.1/192.168.0.1/g' package/base-files/files/bin/config_generate   # 修改默认ip
sed -i 's/\/bin\/ash/\/bin\/bash/' package/base-files/files/etc/passwd    # 替换终端为bash

sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile   # 选择argon为默认主题
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-light/Makefile   # 选择argon为默认主题
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-nginx/Makefile   # 选择argon为默认主题
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-ssl-nginx/Makefile   # 选择argon为默认主题
sed -i 's/+uhttpd +uhttpd-mod-ubus //g' feeds/luci/collections/luci/Makefile    # 删除uhttpd
sed -i '/CYXluq4wUazHjmCDBCqXF/d' package/lean/default-settings/files/zzz-default-settings    # 设置密码为空
# sed -i 's/PATCHVER:=5.10/PATCHVER:=5.15/g' target/linux/x86/Makefile   # x86机型,默认内核5.10，修改内核为5.15
# rm -rf feeds/packages/utils/runc/Makefile   # 临时删除run1.0.3
# svn export https://github.com/openwrt/packages/trunk/utils/runc/Makefile feeds/packages/utils/runc/Makefile   # 添加runc1.0.2
git clone --depth 1 https://github.com/vernesong/OpenClash package/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon    # 删除自带argon
git clone -b master https://github.com/jerrykuku/luci-theme-argon.git feeds/luci/themes/luci-theme-argon    # 替换新版argon
# 调整argon登录框为居中
sed -i "/.login-page {/i\\
.login-container {\n\
  margin: auto;\n\
  height: 420px\!important;\n\
  min-height: 420px\!important;\n\
  left: 0;\n\
  right: 0;\n\
  bottom: 0;\n\
  margin-left: auto\!important;\n\
  border-radius: 15px;\n\
  width: 350px\!important;\n\
}\n\
.login-form {\n\
  background-color: rgba(255, 255, 255, 0)\!important;\n\
  border-radius: 15px;\n\
}\n\
.login-form .brand {\n\
  margin: 15px auto\!important;\n\
}\n\
.login-form .form-login {\n\
    padding: 10px 50px\!important;\n\
}\n\
.login-form .errorbox {\n\
  padding: 10px\!important;\n\
}\n\
.login-form .cbi-button-apply {\n\
  margin: 15px auto\!important;\n\
}\n\
.input-group {\n\
  margin-bottom: 1rem\!important;\n\
}\n\
.input-group input {\n\
  margin-bottom: 0\!important;\n\
}\n\
.ftc {\n\
  bottom: 0\!important;\n\
}" feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/css/cascade.css
sed -i "s/margin-left: 0rem \!important;/margin-left: auto\!important;/g" feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/css/cascade.css
