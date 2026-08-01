#!/bin/bash
# 文件: common/scripts/mods/patch-easyupdate.sh
# 用途: 对 easyupdate.sh 进行固件适配（OpenWrt / ImmortalWrt）
#       1. 强制保留配置（-k 参数）         —— 所有固件
#       2. 替换固件品牌名称（仅 ImmortalWrt）
#       3. 调整文件名截取偏移（仅 ImmortalWrt）
#       4. 修改固件后缀为 squashfs-sysupgrade.itb（所有固件）
#       5. 修正校验文件扩展名（所有固件）
# 依赖: 需要预先 source common/scripts/libs/index.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/patch-easyupdate.sh
#   patch_easyupdate <firmware_type> [target_file]
#
# 参数:
#   firmware_type : 固件类型 ("openwrt" 或 "immortalwrt")
#   target_file   : easyupdate.sh 的路径（可选，默认为已知路径）
#######################################

# 后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 应用 easyupdate 补丁
#
# 功能:
#   对 easyupdate.sh 应用一系列 sed 修改，使其适用于 ImmortalWrt 固件。
#   包括替换固件名称、强制保留配置、调整文件名截取长度、修改固件后缀等。
#   根据固件类型执行不同修改：
#     - openwrt    : 仅添加 -k 参数、修改后缀和校验扩展名
#     - immortalwrt: 额外进行固件名称替换和文件名偏移调整
#
# 参数：
#   $1 - 固件类型 ("openwrt" 或 "immortalwrt")
#   $2 - (可选) easyupdate.sh 路径，默认值为
#        custom-packages/sundaqiang/luci/applications/luci-app-easyupdate/root/usr/bin/easyupdate.sh
#
# Outputs:
#   操作日志到 stderr (通过 log)
#
# Returns:
#   0 - 修改成功
#   0 - 文件不存在时仅输出警告，不视为错误
#
# Examples:
#   patch_easyupdate 'immortalwrt'
#   patch_easyupdate 'immortalwrt' 'custom-packages/myapp/easyupdate.sh'
#######################################
patch_easyupdate() {
    local firmware_type="$1"
    local target_file="${2:-custom-packages/sundaqiang/luci/applications/luci-app-easyupdate/root/usr/bin/easyupdate.sh}"

    if [[ "${firmware_type}" != "openwrt" && "${firmware_type}" != "immortalwrt" ]]; then
        log ERROR "Invalid firmware type: ${firmware_type}. Must be 'openwrt' or 'immortalwrt'."
        return 1
    fi

    if [[ ! -f "${target_file}" ]]; then
        log WARN "Easyupdate file not found: ${target_file}, skipping ${firmware_type} patch."
        return 0
    fi

    log INFO "Applying ${firmware_type} easyupdate patch to ${target_file}..."

    # 使用 sed 进行多项修改
    # 1. 将 OpenWrt / openwrt / Openwrt 替换为 ImmortalWrt / immortalwrt / Immortalwrt
    #    （仅作用于包含 curl 或 filename 的行，确保只修改与固件下载相关的部分）
    # 2. 强制保留配置：sysupgrade 命令添加 -k
    # 3. 调整文件名截取：bash 子串偏移从 0:7 改为 0:11（适配 immortawrt 更长的前缀）
    # 4. 将固件下载路径中的 /${checkShaRet} 改为 /tmp/${checkShaRet}
    # 5. 将 EFI 固件检测块注释掉，并添加后缀设置 suffix='squashfs-sysupgrade.itb'
    # 6. 将 checkSha 函数中的 img.gz 替换为 itb
    sed -i -E \
        -e "/sysupgrade\s+\\\$keepconfig\s*\\\$file/s/sysupgrade/sysupgrade -k/g" \
        -e "/^\s*file/s/\\\$\{checkShaRet/\/tmp\/\\\$\{checkShaRet/g" \
        -e "/Check\s+whether\s+EFI\s+firmware/,/^\s*fi/ {
        /^\s+fi/a\    suffix='squashfs-sysupgrade.itb'
        s/^/#/
      }" \
        -e "/^\s*function\s+checkSha/,/^\s*\}/ {
        s/img\.gz/\itb/
      }" \
        "${target_file}"

    # ----- ImmortalWrt 专属修改 -----
    if [[ "${firmware_type}" == "immortalwrt" ]]; then
        sed -i -E \
            -e "/curl|filename/s/OpenWrt/ImmortalWrt/g" \
            -e "/curl|filename/s/openwrt/immortalwrt/g" \
            -e "/curl|filename/s/Openwrt/Immortalwrt/g" \
            -e "/file[Nn]ame/s/0:7/0:11/g" \
            "${target_file}"
        log INFO "ImmortalWrt and filename adjustment applied."
    fi

    log INFO "${firmware_type} easyupdate patch applied."
}

# 若直接运行脚本，则执行默认补丁
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    patch_easyupdate "${1:-immortalwrt}" "${2}"
fi
