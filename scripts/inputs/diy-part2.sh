#!/bin/bash
# 文件: scripts/inputs/diy-part2.sh
# 用途: ImmortalWrt 构建第二阶段 - 在 feeds install 前执行
#       1. 修改系统默认配置
#       2. 创建符号链接
#       3. 修补 LuCI 集合
#       4. 修补 easyupdate.sh (ImmortalWrt 版，替换固件名称)
#       5. 修改 Rust 构建配置
#       6. 添加执行权限
#       7. 固定 dae 版本
#       8. 重命名 qBittorrent 并修复依赖（ImmortalWrt 专用）
#       9. 固定 fan2go 版本
#      10. 修复 libnl-tiny 编译错误
# 依赖: scripts/libs/ + scripts/inputs/mods/ 的各个修改函数
#
# 定位约定：SCRIPT_DIR 取本文件所在目录，因此 libs/ 与 mods/ 必须与它同级。
# 仓库内三者都在 scripts/inputs/ 下；跑构建时 copy_custom_files 会把三者一并复制到
# immortalwrt/ 根，复制后的布局同样是同级兄弟，所以下面的 source 在两种位置都成立。
# 【不得】把本文件单独移到 scripts/ 或其它目录——那会让 ${SCRIPT_DIR}/libs 解析失败。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=scripts/libs/load.sh
source "${SCRIPT_DIR}/../libs/load.sh"
# shellcheck source=scripts/inputs/mods/load.sh
source "${SCRIPT_DIR}/mods/load.sh"

# ===== 执行第二阶段修改 =====

# 先重命名以避免冲突
rename_qbittorrent

create_symlinks 'custom-packages'

set_default_ip
set_default_shell

apply_luci_collection_patches


# ImmortalWrt 版 easyupdate 补丁
patch_easyupdate 'immortalwrt'

modify_rust_build_config

ensure_exec_permission 'files/usr/bin/restore-packages.sh'

# 固定 dae 版本
set_dae_version "2.1.1" "880d56d2f4b80c009c29693a5ec1d6a44b4958aeba6323af879787934ee0e855"

# 修复 qbittorrent 依赖
fix_qbittorrent_deps

# 固定 fan2go 版本
set_fan2go_version "0.15.0" auto

# 修复 libnl-tiny 编译警告
fix_libnl_tiny_compile

log INFO "Part 2 for ImmortalWrt completed."
