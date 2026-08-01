#!/bin/bash
# 文件: bananapi_bpi-r4/scripts/diy-part1.immortalwrt.sh
# 用途: ImmortalWrt 构建第一阶段 - 在 feeds update 前执行
#       1. 修改 BPI‑R4 分区布局
#       2. 添加 XDP sockets 内核模块支持（可选，ImmortalWrt 通常已内置）
#       3. 克隆第三方软件包仓库（ImmortalWrt 特有列表，已内置部分包）
# 依赖: 同 diy-part1.openwrt.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库（被复制到同级 libs/ 目录）
# shellcheck source=./libs/index.sh
source "${SCRIPT_DIR}/libs/index.sh"
# 加载通用修改索引（被复制到同级 mods/ 目录）
# shellcheck source=./mods/index.sh
source "${SCRIPT_DIR}/mods/index.sh"

# ===== 执行第一阶段修改 =====

# modify_bpi_r4_partition 50

# ImmortalWrt 通常已包含 XDP sockets 支持，可跳过或按需启用
# add_xdp_sockets_diag

log INFO "Cloning third-party packages for ImmortalWrt..."

clone_repo 'https://github.com/anoixa/bpi-r4-pwm-fan' \
    'main' \
    '--depth=1' \
    'custom-packages/bpi-r4-pwm-fan'

clone_repo 'https://github.com/brainiac19/openwrt-packages' \
    'main' \
    '--filter=blob:none --sparse --depth=1' \
    'custom-packages/brainiac19'
(
    cd 'custom-packages/brainiac19' || exit 1
    git sparse-checkout set fonts
)

clone_repo 'https://github.com/rockjake/luci-app-fancontrol' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-fancontrol'

clone_repo 'https://github.com/gdy666/luci-app-lucky' \
    'main' \
    '--depth=1' \
    'custom-packages/luci-app-lucky'

clone_repo 'https://github.com/zhanghua000/luci-app-nginx' \
    'master' \
    '--depth=1' \
    'custom-packages/luci-app-nginx'

clone_repo 'https://github.com/Shuery-Shuai/LuciFanXpert' \
    'main' \
    '--depth=1' \
    'custom-packages/LuciFanXpert'

clone_repo 'https://github.com/vernesong/OpenClash' \
    'dev' \
    '--depth=1' \
    'custom-packages/openclash'

clone_repo 'https://github.com/sbwml/openwrt-qBittorrent' \
    'master' \
    '--depth=1' \
    'custom-packages/qbittorrent'

clone_repo 'https://github.com/sundaqiang/openwrt-packages-backup' \
    'main' \
    '--filter=blob:none --sparse --depth=1' \
    'custom-packages/sundaqiang'
(
    cd 'custom-packages/sundaqiang' || exit 1
    git sparse-checkout set luci/applications/luci-app-easyupdate
)

log INFO "Part 1 for ImmortalWrt completed."
