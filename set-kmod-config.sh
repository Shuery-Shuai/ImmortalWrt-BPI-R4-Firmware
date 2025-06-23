#!/bin/bash

declare -r KMOD_CONFIG_FILE=kmod.config

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
"

declare -r KMOD_CONFIG_PACKAGE_SNIPPET="
# luci-app-alist
CONFIG_PACKAGE_kmod-fuse=m
# luci-app-dae
CONFIG_PACKAGE_kmod-sched-bpf=m
CONFIG_PACKAGE_kmod-sched-core=m
CONFIG_PACKAGE_kmod-veth=m
CONFIG_PACKAGE_kmod-xdp-sockets-diag=m
# luci-app-openclash
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
"

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
