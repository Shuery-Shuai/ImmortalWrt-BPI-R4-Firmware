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

# 模块配置文件
readonly KMOD_CONFIG_FILE="module.config"

# 目标配置片段
declare KMOD_CONFIG_TARGET_SNIPPET
KMOD_CONFIG_TARGET_SNIPPET=$(
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

# 内核配置片段
declare KMOD_CONFIG_SNIPPET
KMOD_CONFIG_SNIPPET=$(
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

# 包配置片段
declare KMOD_CONFIG_PACKAGE_SNIPPET
KMOD_CONFIG_PACKAGE_SNIPPET=$(
    cat <<'EOF'
# bpi-r4-pwm-fan
CONFIG_PACKAGE_bpi-r4-pwm-fan=m
# dae
CONFIG_PACKAGE_kmod-sched-bpf=m
CONFIG_PACKAGE_kmod-sched-core=m
CONFIG_PACKAGE_kmod-veth=m
CONFIG_PACKAGE_kmod-xdp-sockets-diag=m
# docker
CONFIG_PACKAGE_kmod-fs-btrfs=m
CONFIG_PACKAGE_kmod-crypto-blake2b=m
CONFIG_PACKAGE_kmod-crypto-hash=m
CONFIG_PACKAGE_kmod-crypto-xxhash=m
CONFIG_PACKAGE_kmod-lib-xxhash=m
CONFIG_PACKAGE_kmod-lib-crc32c=m
CONFIG_PACKAGE_kmod-crypto-crc32c=m
CONFIG_PACKAGE_kmod-lib-lzo=m
CONFIG_PACKAGE_kmod-crypto-acompress=m
CONFIG_PACKAGE_kmod-lib-raid6=m
CONFIG_PACKAGE_kmod-lib-xor=m
CONFIG_PACKAGE_kmod-lib-zlib-deflate=m
CONFIG_PACKAGE_kmod-lib-zlib-inflate=m
CONFIG_PACKAGE_kmod-lib-zstd=m
CONFIG_PACKAGE_kmod-ip6tables=m
CONFIG_PACKAGE_kmod-nft-compat=m
CONFIG_PACKAGE_kmod-ipt-core=m
CONFIG_PACKAGE_kmod-ipt-extra=m
CONFIG_PACKAGE_kmod-ipt-nat=m
CONFIG_PACKAGE_kmod-ipt-nat6=m
CONFIG_PACKAGE_kmod-ipt-physdev=m
CONFIG_PACKAGE_kmod-nf-ipvs=m
CONFIG_PACKAGE_kmod-veth=m
CONFIG_PACKAGE_kmod-nft-core=m
CONFIG_PACKAGE_kmod-nf-conntrack6=m
CONFIG_PACKAGE_kmod-nf-conntrack=m
CONFIG_PACKAGE_kmod-nf-log=m
CONFIG_PACKAGE_kmod-nf-log6=m
CONFIG_PACKAGE_kmod-nf-nat=m
CONFIG_PACKAGE_kmod-nf-reject=m
CONFIG_PACKAGE_kmod-nf-reject6=m
CONFIG_PACKAGE_kmod-nfnetlink=m
CONFIG_PACKAGE_kmod-nft-fib=m
CONFIG_PACKAGE_kmod-nft-fullcone=m
CONFIG_PACKAGE_kmod-nft-nat=m
CONFIG_PACKAGE_kmod-nft-offload=m
CONFIG_PACKAGE_kmod-nf-flow=m
CONFIG_PACKAGE_kmod-ipt-fullconenat=m
CONFIG_PACKAGE_kmod-ipt-conntrack=m
# fancontrol
CONFIG_PACKAGE_luci-app-fancontrol=m
# lucky
CONFIG_PACKAGE_luci-app-lucky=m
# openclash
CONFIG_PACKAGE_kmod-nf-conntrack-netlink=m
CONFIG_PACKAGE_kmod-nf-conntrack=m
CONFIG_PACKAGE_kmod-nfnetlink=m
CONFIG_PACKAGE_kmod-nft-core=m
CONFIG_PACKAGE_kmod-lib-crc32c=m
CONFIG_PACKAGE_kmod-crypto-crc32c=m
CONFIG_PACKAGE_kmod-crypto-hash=m
CONFIG_PACKAGE_kmod-nf-conntrack6=m
CONFIG_PACKAGE_kmod-nf-log=m
CONFIG_PACKAGE_kmod-nf-log6=m
CONFIG_PACKAGE_kmod-nf-nat=m
CONFIG_PACKAGE_kmod-nf-reject=m
CONFIG_PACKAGE_kmod-nf-reject6=m
CONFIG_PACKAGE_kmod-inet-diag=m
CONFIG_PACKAGE_kmod-nft-tproxy=m
CONFIG_PACKAGE_kmod-nf-tproxy=m
CONFIG_PACKAGE_kmod-tun=m
# openlist
CONFIG_PACKAGE_kmod-fuse=m
# qbittorrent
CONFIG_PACKAGE_luci-app-qbittorrent-original=m
# samba4
CONFIG_PACKAGE_samba4-admin=m
CONFIG_PACKAGE_samba4-client=m
CONFIG_PACKAGE_samba4-libs=m
CONFIG_PACKAGE_samba4-server=m
CONFIG_PACKAGE_samba4-utils=m
EOF
)

# 主函数
main() {
    log_info "开始设置内核模块配置..."

    # 检查是否已经准备好，如果没有则执行准备操作
    # if [ "$IMMORTALWRT_PREPARED" != "1" ]; then
    #     clean_immortalwrt_changes
    #     prepare_immortalwrt
    #     copy_custom_files
    # fi

    # 设置feeds
    # setup_feeds

    # 备份现有配置文件
    # backup_file "$KMOD_CONFIG_FILE"
    # backup_file ".config"

    # 创建新的配置文件
    log_info "创建模块配置文件..."
    {
        echo "$KMOD_CONFIG_TARGET_SNIPPET"
        echo "$KMOD_CONFIG_SNIPPET"
        echo "$KMOD_CONFIG_PACKAGE_SNIPPET"
    } >"$KMOD_CONFIG_FILE"

    # 应用配置
    cp "$KMOD_CONFIG_FILE" .config
    make defconfig
    cp .config "$KMOD_CONFIG_FILE"

    log_success "内核模块配置完成"
}

# 执行主函数
main "$@"
