# scripts/build/utils/load.sh —— 目录聚合加载器（被 source，不直接执行）
# 用法: source scripts/build/utils/load.sh
# shellcheck shell=bash
#
# 职责：加载本目录下的工具函数（仅定义函数，无 main、无副作用）。
# 命名 load 而非 entry/index：它就是加载；entry 像可执行入口，index 像目录索引。
#
# 加载顺序：文件名统一用 NN- 数字前缀（01 起，00 保留不用），glob 字母序因此就是加载序。
# 新增文件插入请留空隙（如 15-xxx.sh），不要重排已有编号。
#
# 失败语义：本文件被 source，因此【一律 return 1】而不是 exit —— exit 会终止调用者的整个 shell。
# 且 source 的返回码会被被加载文件最后一条命令影响，不能作为成败判据，故先检查可读性。

# 防重复加载：函数覆盖通常无害，但若某文件含顶层赋值或副作用，重复 source 会重复执行。
if [[ -n "${_BUILD_UTILS_LOADED:-}" ]]; then
    return 0
fi
readonly _BUILD_UTILS_LOADED=1

# 后备日志函数：调用方可能尚未加载 logger，此处保证错误信息格式统一，且不会掩盖真实原因。
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

_BUILD_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _bu_file in "${_BUILD_UTILS_DIR}"/*.sh; do
    [[ -f "${_bu_file}" ]] || continue
    [[ "$(basename "${_bu_file}")" == "load.sh" ]] && continue

    if [[ ! -r "${_bu_file}" ]]; then
        log ERROR "cannot read ${_bu_file}"
        unset _BUILD_UTILS_DIR _bu_file
        return 1
    fi

    # shellcheck source=/dev/null
    if ! source "${_bu_file}"; then
        log ERROR "failed to source ${_bu_file}"
        unset _BUILD_UTILS_DIR _bu_file
        return 1
    fi
done

unset _BUILD_UTILS_DIR _bu_file
