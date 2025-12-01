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

# Modify IP
BASE_FILE_CONFIG="package/base-files/files/bin/config_generate"
if [[ -f "${BASE_FILE_CONFIG}" ]]; then
  sed -i "s/192.168.1.1/192.168.0.1/g" "${BASE_FILE_CONFIG}"
else
  echo "File ${BASE_FILE_CONFIG} does not exist." >&2
fi

# Modify shell to bash
PASSWD_FILE="package/base-files/files/etc/passwd"
if [[ -f "${PASSWD_FILE}" ]]; then
  sed -i "s/\/bin\/ash/\/bin\/bash/" "${PASSWD_FILE}"
else
  echo "File ${PASSWD_FILE} does not exist." >&2
fi

# Modify password to empty
# sed -i "/CYXluq4wUazHjmCDBCqXF/d" package/lean/default-settings/files/zzz-default-setting

clone_repo() {
  local repo="$1"
  local branch="$2"
  local target="$3"
  local attempt

  if [[ -d "${target}" ]]; then
    printf "Pulling %s at %s...\n" "${repo}" "${target}"
    for attempt in {1..3}; do
      if git -C "${target}" clean -f . && git -C "${target}" pull; then
        break
      else
        echo "Pull attempt ${attempt} failed, retrying..."
        sleep $((attempt * 2))
      fi
    done
  else
    printf "Cloning %s %s to %s...\n" "${repo}" "${branch}" "${target}"
    for attempt in {1..3}; do
      echo "Clone attempt ${attempt}..."
      if git clone --depth 1 -b "${branch}" "${repo}" "${target}"; then
        break
      else
        echo "Clone attempt ${attempt} failed!"
        sleep $((attempt * 2))
        rm -rf "${target}"
        if [[ "${attempt}" -eq 3 ]]; then
          echo "Failed to clone ${repo} after ${attempt} attempts." >&2
          exit 1
        fi
      fi
    done
  fi
}

# Change to official custom branch source of applications including luci-app-openclash and luci-theme-argon
# rm -rf feeds/luci/applications/luci-app-openclash
ARGON_THEME_DIR="feeds/luci/themes/luci-theme-argon"
if [[ -d "${ARGON_THEME_DIR}" ]]; then
  rm -rf "${ARGON_THEME_DIR}"
fi
# clone_repo https://github.com/vernesong/OpenClash dev \
#   feeds/luci/applications/luci-app-openclash
clone_repo https://github.com/jerrykuku/luci-theme-argon.git master \
  feeds/luci/themes/luci-theme-argon

# Clone custom packages
clone_repo https://github.com/zhanghua000/luci-app-nginx master \
  package/luci-app-nginx
clone_repo https://github.com/sundaqiang/openwrt-packages-backup main \
  package/sundaqiang
clone_repo https://github.com/rockjake/luci-app-fancontrol.git main \
  package/fancontrol
clone_repo https://github.com/gdy666/luci-app-lucky.git main \
  package/lucky
clone_repo https://github.com/anoixa/bpi-r4-pwm-fan main \
  package/bpi-r4-pwm-fan
clone_repo https://github.com/sbwml/openwrt-qBittorrent master \
  package/qbittorrent

replace_collections() {
  local -n _replacements="$1"
  local file
  local pattern
  local escaped_pattern
  local escaped_replacement
  local -a sed_script

  for pattern in "${!_replacements[@]}"; do
    escaped_pattern=$(sed "s/[\/&]/\\&/g" <<<"${pattern}")
    escaped_replacement=$(sed "s/[\/&]/\\&/g" <<<"${_replacements[$pattern]}")
    sed_script+=("-e" "s/${escaped_pattern}/${escaped_replacement}/g")
  done

  for file in feeds/luci/collections/*/Makefile; do
    if [[ ! -e "${file}" ]]; then
      continue
    fi
    printf "Modifying %s...\n" "${file}"
    sed -i "${sed_script[@]}" "${file}"
  done
}

declare -A replacements=(
  ["luci-theme-bootstrap"]="luci-theme-argon"
  ["+uhttpd +uhttpd-mod-ubus"]=""
)
replace_collections replacements

# Modify Argon login page from float left to center
# THEME_CSS_FILE="feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/css/cascade.css"
# if [[ -f "${THEME_CSS_FILE}" ]]; then
#   printf "Modifying %s...\n" "${THEME_CSS_FILE}"
#   awk -i inplace -v RS="}" "
#     # 主容器样式修改
#     $0 ~ /\.login-page\s+\.login-container\s*\{/ {
#       # 替换属性
#       gsub(/height:\s*100%;?/, "height:400px;");
#       gsub(/margin-left:\s*4\.5rem;?/, "margin:auto;");
#       gsub(/top:\s*0;?/, "top:0; bottom:0; left:0; right:0;");
#       gsub(/min-height:\s*100%;?/, "min-height:400px;");
#       gsub(/width:\s*420px;?/, "width:400px;");
#       gsub(/box-shadow/, "border-radius:15px; box-shadow");
#       gsub(/margin-left:\s*5%;?/, "margin-left:auto;");
#     }
#     # 登录表单背景和圆角
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s*\{/ {
#       gsub(/background-color:\s*#fff;?/, "background-color:rgba(255,255,255,0);");
#       if (!/border-radius/) {
#         sub(/\{/, "{ border-radius:15px; ");
#       }
#     }
#     # 品牌标志边距
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.brand\s*\{/ {
#       gsub(/margin:\s*50px\s+auto\s+100px\s+50px;?/, "margin:15px auto;");
#     }
#     # 表单内边距
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s*\{/ {
#       gsub(/padding:\s*20px\s+50px;?/, "padding:10px 50px;");
#     }
#     # 错误框样式
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s+\.errorbox\s*\{/ {
#       gsub(/padding-bottom:\s*2rem;?/, "padding:10px;");
#     }
#     # 按钮边距
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.cbi-button-apply\s*\{/ {
#       gsub(/margin:\s*30px\s+0px\s+100px;?/, "margin:15px auto;");
#     }
#     # 输入组边距
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s+\.input-group\s*\{/ {
#       gsub(/margin-bottom:\s*1\.25rem;?/, "margin-bottom:1rem;");
#     }
#     # 输入框边距修正
#     $0 ~ /\.login-page\s+\.login-container\s+\.login-form\s+\.form-login\s+\.input-group input\s*\{/ {
#       gsub(/margin:\s*[0|.]825rem\s+0;?/, "margin-bottom:0;");
#     }
#     # 页脚位置
#     $0 ~ /\.login-page\s+\.login-container\s+footer\s+\.ftc\s*\{/ {
#       gsub(/bottom:\s*30px;?/, "bottom:0;");
#     }
#     # 全局替换 margin-left:0rem
#     {
#       gsub(/margin-left:\s*0rem\s*!important/, "margin-left:auto !important");
#     }
#     # 输出修改后的内容并补回 }
#     { print $0 RT }
#   " "${THEME_CSS_FILE}"
# else
#   echo "File ${THEME_CSS_FILE} does not exist." >&2
# fi

# Modify easyupdate.sh to support ImmortalWrt
EASYUPDATE_FILE="package/sundaqiang/luci/applications/luci-app-easyupdate/root/usr/bin/easyupdate.sh"
if [[ -f "${EASYUPDATE_FILE}" ]]; then
  printf "Modifying %s...\n" "${EASYUPDATE_FILE}"
  # 修改 OpenWrt 为 ImmortalWrt
  # 修改更新操作，更新是备份软件包列表
  # 修改 fileName 截取范围
  # 修改 suffix 为 squashfs-sysupgrade.itb
  sed -i -E \
    -e "/curl|filename/s/OpenWrt/ImmortalWrt/g" \
    -e "/curl|filename/s/openwrt/immortalwrt/g" \
    -e "/curl|filename/s/Openwrt/Immortalwrt/g" \
    -e "/sysupgrade \$keepconfig\$file/s/sysupgrade/sysupgrade -k/g" \
    -e "/file[Nn]ame/s/0:7/0:11/g" \
    -e "/^\s*file/s/\$\{checkShaRet/\/tmp\/\$\{checkShaRet/g" \
    -e "/Check\s+whether\s+EFI\s+firmware/,/^\s*fi/ {
        /^\s+fi/a\  suffix='squashfs-sysupgrade.itb'
        s/^/#/
      }" \
    -e "/^\s*function\s+checkSha/,/^\s*\}/ {
        s/img\.gz/\itb/
      }" \
    "${EASYUPDATE_FILE}"
else
  echo "File ${EASYUPDATE_FILE} does not exist." >&2
fi

# Set Rust build arg llvm.download-ci-llvm to false.
RUST_MAKEFILE="feeds/packages/lang/rust/Makefile"
if [[ -f "${RUST_MAKEFILE}" ]]; then
  printf "Modifying %s...\n" "${RUST_MAKEFILE}"
  sed -i "s/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/" "${RUST_MAKEFILE}"
else
  echo "File ${RUST_MAKEFILE} does not exist." >&2
fi

# Give restore-packages execution permissions
RESTORE_PACKAGES_FILE="files/usr/bin/restore-packages.sh"
if [[ -f "${RESTORE_PACKAGES_FILE}" ]]; then
  printf "Modifying %s...\n" "${RESTORE_PACKAGES_FILE}"
  chmod +x "${RESTORE_PACKAGES_FILE}"
else
  echo "File ${RESTORE_PACKAGES_FILE} does not exist." >&2
fi

# Change luci-app-qbittorrent name to luci-app-qbittorrent-original
QBIT_APP_PATH="package/qbittorrent"
if [[ -d "${QBIT_APP_PATH}" ]]; then
  printf "Modifying %s...\n" "${QBIT_APP_PATH}"
  mv ${QBIT_APP_PATH}/luci-app-qbittorrent ${QBIT_APP_PATH}/luci-app-qbittorrent-original
  sed -i "s/luci-app-qbittorrent/luci-app-qbittorrent-original/" "${QBIT_APP_PATH}/luci-app-qbittorrent-original/Makefile"
else
  echo "Dir ${QBIT_APP_PATH} does not exist." >&2
fi
