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

# 加载通用函数库。
#
# libs/ 的位置在两种布局下**不同**，必须探测而不能写死（此前写死 ../libs，复制后必然失败）：
#   · 仓库内原始位置 scripts/inputs/diy-part1.sh：libs 在 scripts/libs  -> ../libs
#   · copy_custom_files 复制到 immortalwrt/ 根后：libs 被一并复制成 immortalwrt/libs -> ./libs
# 写死 ../libs 时，复制后的 ${SCRIPT_DIR}/.. 是仓库根，那里没有 libs，source 静默失败，
# 后果是 clone_repo 等所有函数都不存在（报 "clone_repo: command not found"），
# 而脚本没有 set -e，于是 DIY 阶段「跑完了但什么也没做」，缺陷一路拖到编译 dae 时才炸。
if [[ -f "${SCRIPT_DIR}/libs/load.sh" ]]; then
  _DIY_LIBS_DIR="${SCRIPT_DIR}/libs"
elif [[ -f "${SCRIPT_DIR}/../libs/load.sh" ]]; then
  _DIY_LIBS_DIR="${SCRIPT_DIR}/../libs"
else
  printf 'ERROR: 无法定位 libs/load.sh（已尝试 %s 与 %s）\n' \
    "${SCRIPT_DIR}/libs" "${SCRIPT_DIR}/../libs" >&2
  exit 1
fi
# shellcheck source=scripts/libs/load.sh
source "${_DIY_LIBS_DIR}/load.sh"
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
