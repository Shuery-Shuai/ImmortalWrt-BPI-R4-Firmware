#!/bin/bash
# BPI‑R4 专用 - MediaTek Filogic 分区布局调整

# 需要 source common/scripts/functions.sh

#######################################
# 修改 MediaTek Filogic 分区布局
#
# 扩展 BPI-R4 的固件分区大小，以容纳更多软件包和功能。
# 修改包括:
#   - 调整 recovery、install、production 分区偏移量
#   - 扩展各类启动镜像(initramfs、bl2、bl31)的大小限制
#   - 增加最终固件镜像(sysupgrade.itb)的容量
#
# Arguments:
#   $1 - 追加的分区大小（单位: MB）
#
# Globals:
#   None
#
# Outputs:
#   修改进度信息到 stdout
#   错误信息到 stderr
#
# Returns:
#   0 - 修改成功
#   1 - 文件不存在或 sed 操作失败
#
# Examples:
#   modify_bpi_r4_partition 50  # 扩展 50MB
#######################################
modify_bpi_r4_partition() {
    local append_size="$1"
    local partition_file="target/linux/mediatek/image/filogic.mk"
    local scope_build_start='^define\sBuild\/mt798x-gpt'
    local scope_build_end='^endef'
    local scope_device_start='^define\sDevice\/bananapi_bpi-r4-common'
    local scope_device_end='^endef'

    # 计算新大小
    local new_32=$((32 + append_size))
    local new_44=$((44 + append_size))
    local new_45=$((45 + append_size))
    local new_51=$((51 + append_size))
    local new_52=$((52 + append_size))
    local new_56=$((56 + append_size))
    local new_64=$((64 + append_size))

    # 获取当前分区文件内容以便调试
    if type -t show_scope_content &>/dev/null; then
        log INFO "Current partition definitions before modification:"
        show_scope_content "${partition_file}" "${scope_build_start}" "${scope_build_end}" 'recovery|install|production' "Build Definitions"
        show_scope_content "${partition_file}" "${scope_device_start}" "${scope_device_end}" \
            'append-image-stage\s+initramfs-recovery\.itb|mt7988-bl2\s+spim-nand-ubi-comb|mt7988-bl31-uboot\s+.*-snand|mt7988-bl2\s+emmc-comb|mt7988-bl31-uboot\s+.*-emmc|mt798x-gpt\s+emmc|append-image\s+squashfs-sysupgrade\.itb|IMAGE_SIZE' \
            "Device Definitions"
    fi

    # 调用通用作用域替换函数
    modify_within_scope "${partition_file}" "${append_size}" "${scope_build_start}" "${scope_build_end}" \
        "/recovery/s/32M@/${new_32}M@/
         /install/s/@44M/@${new_44}M/
         /production/s/@64M/@${new_64}M/"

    modify_within_scope "${partition_file}" "${append_size}" "${scope_device_start}" "${scope_device_end}" \
        "/append-image-stage\s+initramfs-recovery\.itb/s/44m/${new_44}m/
         /mt7988-bl2\s+spim-nand-ubi-comb/s/44M/${new_44}M/
         /mt7988-bl31-uboot\s+.*-snand/s/45M/${new_45}M/
         /mt7988-bl2\s+emmc-comb/s/51M/${new_51}M/
         /mt7988-bl31-uboot\s+.*-emmc/s/52M/${new_52}M/
         /mt798x-gpt\s+emmc/s/56M/${new_56}M/
         /append-image\s+squashfs-sysupgrade\.itb/s/64M/${new_64}M/
         /IMAGE_SIZE/s/64/${new_64}/"

    # 验证修改结果（可选，但建议保留）
    if type -t show_scope_content &>/dev/null; then
        log INFO "Partition definitions after modification:"
        show_scope_content "${partition_file}" "${scope_build_start}" "${scope_build_end}" 'recovery|install|production' "Build Definitions"
        show_scope_content "${partition_file}" "${scope_device_start}" "${scope_device_end}" \
            'append-image-stage\s+initramfs-recovery\.itb|mt7988-bl2\s+spim-nand-ubi-comb|mt7988-bl31-uboot\s+.*-snand|mt7988-bl2\s+emmc-comb|mt7988-bl31-uboot\s+.*-emmc|mt798x-gpt\s+emmc|append-image\s+squashfs-sysupgrade\.itb|IMAGE_SIZE' \
            "Device Definitions"
    fi
}
