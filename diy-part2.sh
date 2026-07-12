#!/bin/bash
# 文件: bananapi_bpi-r4/scripts/diy-part2.immortalwrt.sh
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
# 依赖: 通用库 + 各 mods 脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../common/scripts/libs/functions.sh
source "${SCRIPT_DIR}/libs/functions.sh"
# shellcheck source=../../common/scripts/mods/index.sh
source "${SCRIPT_DIR}/mods/index.sh"

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
set_dae_version "2.0.0"

# 修复 qbittorrent 依赖
fix_qbittorrent_deps

# 固定 fan2go 版本
set_fan2go_version "0.15.0" "0bf10cd608c0a2fa55b9237267a7ff2c835697b77110a8d53a1711c07a067c0c"

# 修复 libnl-tiny 编译警告
fix_libnl_tiny_compile

log INFO "Part 2 for ImmortalWrt completed."
