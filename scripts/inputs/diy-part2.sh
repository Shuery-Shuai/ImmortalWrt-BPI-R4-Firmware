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
#      11. 刷新 firewall4 的 fullcone 补丁（适配上游 firewall4 >= 2026-11-08）
# 依赖: scripts/libs/ + scripts/inputs/mods/ 的各个修改函数
#
# 定位约定：SCRIPT_DIR 取本文件所在目录，因此 libs/ 与 mods/ 必须与它同级。
# 仓库内三者都在 scripts/inputs/ 下；跑构建时 copy_custom_files 会把三者一并复制到
# immortalwrt/ 根，复制后的布局同样是同级兄弟，所以下面的 source 在两种位置都成立。
# 【不得】把本文件单独移到 scripts/ 或其它目录——那会让 ${SCRIPT_DIR}/libs 解析失败。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# libs/ 的位置在两种布局下不同，必须探测（理由同 diy-part1.sh 的对应注释）：
#   · 仓库内原始位置 scripts/inputs/diy-part2.sh：libs 在 scripts/libs -> ../libs
#   · 复制到 immortalwrt/ 根后：libs 被复制成 immortalwrt/libs -> ./libs
# 写死 ../libs 时 source 静默失败，set_dae_version / create_symlinks 等全部不存在，
# 而本脚本没有 set -e，DIY 阶段「跑完但没做任何事」，缺陷拖到编译 dae 时才暴露。
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
# load.sh 失败会让 fail/die 未定义，后续所有 || die 都会变成 "command not found"，
# 真实原因被掩盖。这里必须在脚本最早期就硬失败。
source "${_DIY_LIBS_DIR}/load.sh" || {
  printf 'ERROR: 无法加载 libs/load.sh（%s）\n' "${_DIY_LIBS_DIR}" >&2
  exit 1
}
# shellcheck source=scripts/inputs/mods/load.sh
source "${SCRIPT_DIR}/mods/load.sh" || {
  printf 'ERROR: 无法加载 mods/load.sh（%s）\n' "${SCRIPT_DIR}/mods" >&2
  exit 1
}

# 切到 immortalwrt/ 根再干活（理由同 diy-part1.sh 的对应注释）：
# 本脚本现在 immortalwrt/diy/ 下，而 create_symlinks 'custom-packages'、
# ensure_exec_permission 'files/...'、feeds/packages/... 全部以**上一级**为基准。
_diy_repo_base() {
  if [[ "$(basename -- "$(dirname -- "${SCRIPT_DIR}")")" == "immortalwrt" ]]; then
    dirname -- "${SCRIPT_DIR}"
    return 0
  fi
  local repo_root
  repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)" || return 1
  printf '%s\n' "${repo_root}"
}
_DIY_BASE="$(_diy_repo_base)" || {
  printf 'ERROR: 无法定位 immortalwrt 根目录（SCRIPT_DIR=%s）\n' "${SCRIPT_DIR}" >&2
  exit 1
}
cd "${_DIY_BASE}" || {
  printf 'ERROR: 无法进入 %s\n' "${_DIY_BASE}" >&2
  exit 1
}

# ===== 执行第二阶段修改 =====
#
# 失败处理约定（本段所有步骤一致）：
#   DIY 阶段改的是固件运行时行为，任何一步静默失败都会产出一个"看起来正常、实则残缺"
#   的固件。因此除个别明确可降级的步骤外，一律 `|| die`：记录带步骤名的错误并以非 0
#   退出，让 pipeline.sh 的 `|| fail` 真正生效（此前本脚本裸调用 mod，结尾又是恒返回 0
#   的 log，导致 diy-part2 永远返回 0，上游那层 || fail 从未触发过）。
#
# 为什么用 die 而不是 set -e：
#   各 mod 的返回值是"业务语义"而非"命令是否成功"。例如 fix_libnl_tiny_compile 在目标
#   Makefile 不存在时主动 return 0（不存在属正常），ensure_exec_permission 同理；
#   而 set -e 只看退出码、无法区分"该做的没做成"与"没有该做的事"，会误伤这些合法路径。
#   逐个 `|| die` 让每个调用点显式声明语义，也让评审在 diff 里直接看出哪步是必须的。
#
# 为什么快速失败（第一个错误就停）而不是收集全部错误：
#   各步骤之间存在真实依赖（create_symlinks 失败后 fix_qbittorrent_deps 必然也失败），
#   收集式会把级联错误一并列出，反而干扰定位。

# 先重命名以避免冲突
rename_qbittorrent || die "rename_qbittorrent 失败（qBittorrent 改名未完成）"

create_symlinks 'custom-packages' || die "create_symlinks 失败（custom-packages 链接未建立）"

set_default_ip || die "set_default_ip 失败（默认 IP 未设置）"
set_default_shell || die "set_default_shell 失败（默认 shell 未设置）"

apply_luci_collection_patches || die "apply_luci_collection_patches 失败（LuCI 集合补丁未应用）"


# ImmortalWrt 版 easyupdate 补丁
patch_easyupdate 'immortalwrt' || die "patch_easyupdate 失败（easyupdate 补丁未应用）"

modify_rust_build_config || die "modify_rust_build_config 失败（Rust 构建配置未修改）"

ensure_exec_permission 'files/usr/bin/restore-packages.sh' ||
  die "ensure_exec_permission 失败（restore-packages.sh 可执行位未设置）"

# 固定 dae 版本
set_dae_version "2.1.2" "f03a6c66a2ce000e36310d66ccd270d05b3cf1dab293f084bcae5da9fa36c33e" ||
  die "set_dae_version 失败（dae 版本未固定，产出将不可复现）"

# 修复 qbittorrent 依赖
fix_qbittorrent_deps || die "fix_qbittorrent_deps 失败（qBittorrent 依赖未修复）"

# 固定 fan2go 版本
set_fan2go_version "0.15.0" auto || die "set_fan2go_version 失败（fan2go 版本未固定）"

# 修复 libnl-tiny 编译警告
fix_libnl_tiny_compile || die "fix_libnl_tiny_compile 失败（libnl-tiny 编译修复未生效）"

# 向 LuCI 模板注入「备份软件包恢复失败」提示（构建期补丁，不改 feeds 源文件）
apply_restore_pkg_notice_patch || die "apply_restore_pkg_notice_patch 失败（恢复失败提示未注入）"

# 刷新 firewall4 的 fullcone 补丁：上游把 firewall4 升到 2026-11-08 后，
# ImmortalWrt 自带的补丁因上下文失效而无法应用（issue #2526）。
# mod 只在检测到新版时替换补丁，旧版与上游修复后都会自动跳过。
refresh_firewall4_fullcone_patch || die "refresh_firewall4_fullcone_patch 失败（firewall4 补丁未适配，编译将失败）"

log INFO "Part 2 for ImmortalWrt completed."

# 显式以 0 结束：此前依赖最后一条 log 的返回值（恒为 0），语义含糊。
# 上面所有步骤都已 || die，能执行到这里即全部成功。
exit 0
