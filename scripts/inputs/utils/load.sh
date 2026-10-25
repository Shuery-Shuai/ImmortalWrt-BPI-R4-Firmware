# scripts/inputs/utils/load.sh —— 目录聚合加载器（被 source，不直接执行）
# 用法: source scripts/inputs/utils/load.sh
# shellcheck shell=bash
#
# 职责：加载本目录下的工具函数库（仅定义函数，无状态、无副作用）。
#
# 加载顺序是硬约束，编号即加载序（01 起，00 保留不用）：
#   01 symlink   relpath / create_relative_symlink —— create_symlinks 内部调用
#   02 version   normalize_pkg_version / compare_versions —— auto_update_package 内部调用
#   03 download  download_and_hash
#   04 makefile  set_makefile_vars / modify_luci_collection
#   05 partition modify_within_scope / add_values_in_scope / show_scope_content
#   06 feed      extract_pkg_name / resolve_target_path / create_symlinks（依赖 01/03）
#   07 git       clone_repo
#   08 pkgupd    auto_update_package（依赖 02 version-utils）
# 新增文件插入请留空隙（如 15-xxx.sh），不要重排已有编号。
#
# 失败语义：本文件被 source，因此【一律 return 1】而不是 exit。
# 错误信息走后备 log（见下），避免 logger 尚未加载时把真实原因掩盖成『log: command not found』。

if [[ -n "${_INPUTS_UTILS_LOADED:-}" ]]; then
    return 0
fi
readonly _INPUTS_UTILS_LOADED=1

# 后备日志函数：logger 加载后会覆盖本定义，因此它只在最早期生效。
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

_INPUTS_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _iu_file in "${_INPUTS_UTILS_DIR}"/*.sh; do
    [[ -f "${_iu_file}" ]] || continue
    [[ "$(basename "${_iu_file}")" == "load.sh" ]] && continue

    if [[ ! -r "${_iu_file}" ]]; then
        log ERROR "cannot read ${_iu_file}"
        unset _INPUTS_UTILS_DIR _iu_file
        return 1
    fi

    # shellcheck source=/dev/null
    if ! source "${_iu_file}"; then
        log ERROR "failed to source ${_iu_file}"
        unset _INPUTS_UTILS_DIR _iu_file
        return 1
    fi
done

unset _INPUTS_UTILS_DIR _iu_file
