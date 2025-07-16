#!/bin/bash

declare -r KMOD_CONFIG_FILE=module.config

declare -r KMOD_CONFIG_TARGET_SNIPPET="
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y
CONFIG_TARGET_BOARD=\"mediatek\"
CONFIG_TARGET_SUBTARGET=\"filogic\"
CONFIG_TARGET_PROFILE=\"DEVICE_bananapi_bpi-r4\"
CONFIG_TARGET_ROOTFS_PARTSIZE=796
"

declare -r KMOD_CONFIG_SNIPPET="
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
"

declare -r KMOD_CONFIG_PACKAGE_SNIPPET="
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
"

if [ -d "immortalwrt" ]; then
    cp ./diy-part*.sh ./immortalwrt/
    echo "进入 'immortalwrt' 目录..."
    cd immortalwrt
elif [ "$(basename "$(pwd)")" != "immortalwrt" ]; then
    echo "当前目录不是或不存在 'immortalwrt'，请先进入正确的目录。"
    exit 1
fi

git restore .
git pull
bash ./diy-part1.sh
./scripts/feeds update -a -f
bash ./diy-part2.sh
./scripts/feeds install -a -f

if [ -f $KMOD_CONFIG_FILE ]; then
    mv $KMOD_CONFIG_FILE $KMOD_CONFIG_FILE.bak
fi
if [ -f .config ]; then
    mv .config .config.bak
fi

touch $KMOD_CONFIG_FILE

cat <<EOF >$KMOD_CONFIG_FILE
$KMOD_CONFIG_TARGET_SNIPPET
$KMOD_CONFIG_SNIPPET
$KMOD_CONFIG_PACKAGE_SNIPPET
EOF

cp $KMOD_CONFIG_FILE .config
make defconfig
cp .config $KMOD_CONFIG_FILE
