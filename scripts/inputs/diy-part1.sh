#!/bin/bash
# 文件: scripts/inputs/diy-part1.sh
# 用途: ImmortalWrt 构建第一阶段 - 在 feeds update 前执行
#       1. 修改 BPI‑R4 分区布局
#       2. 添加 XDP sockets 内核模块支持（可选，ImmortalWrt 通常已内置）
#       3. 克隆第三方软件包仓库（ImmortalWrt 特有列表，已内置部分包）
# 依赖: scripts/libs/load.sh + scripts/inputs/mods/load.sh
#
# 定位约定：SCRIPT_DIR 取本文件所在目录，因此 libs/ 与 mods/ 必须与它同级。
# 仓库内三者都在 scripts/inputs/ 下；跑构建时 copy_custom_files 会把三者一并复制到
# immortalwrt/ 根，复制后的布局同样是同级兄弟，所以下面的 source 在两种位置都成立。
# 【不得】把本文件单独移到 scripts/ 或其它目录——那会让 ${SCRIPT_DIR}/libs 解析失败。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载通用函数库
# shellcheck source=scripts/libs/load.sh
source "${SCRIPT_DIR}/../libs/load.sh"
# 加载通用修改索引
# shellcheck source=scripts/inputs/mods/load.sh
source "${SCRIPT_DIR}/mods/load.sh"

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

clone_repo 'https://github.com/Shuery-Shuai/LuciRtfwUpgrade' \
    'main' \
    '--depth=1' \
    'custom-packages/LuciRtfwUpgrade'

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
