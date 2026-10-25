# scripts/inputs/mods/load.sh —— 目录聚合加载器（被 source，不直接执行）
# 用法: source scripts/inputs/mods/load.sh
# shellcheck shell=bash
#
# 职责：加载本目录下所有 mod 脚本（仅定义函数，不执行动作）。
#
# 加载顺序：文件名统一用 NN- 数字前缀（00-、01-…），glob 字母序因此就是加载序。
# 新增文件插入请留空隙（如 15-xxx.sh），不要重排已有编号。
#
# 失败语义：本文件被 source，因此【一律 return 1】而不是 exit —— exit 会终止调用者的整个 shell。
# 注意 log 可能尚未定义（本文件不负责加载日志库，调用方应先 source scripts/libs/load.sh），
# 故错误信息走下方后备 log 定义，避免真实原因被『log: command not found』掩盖。
#
# 关于 source 的返回值：约定这些文件『只定义函数』时应返回 0，但若某文件末尾恰好是 false 或
# 未匹配的 grep，返回码就会误导。因此这里不依赖 source 的返回码判断成败，
# 只先检查 [[ -r ]]，再 source；source 失败只由语法/执行错误触发。

# 防重复加载：函数重复定义通常无害，但若某 mod 含顶层变量赋值或副作用，重复 source 会重复执行。
if [[ -n "${_MODS_LOADED:-}" ]]; then
    return 0
fi
readonly _MODS_LOADED=1

# 后备日志函数：本文件被 source 时调用方的 log 可能尚未定义（logger.sh 还未加载），
# 此处的兜底保证错误信息走统一的 [时间戳] [级别] 格式，而不是直接 echo，
# 也不会因为 log 不存在而把真实原因掩盖成『log: command not found』。
# logger.sh 加载后会覆盖本定义，因此它只在最早期生效。
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

_MODS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _mod_file in "${_MODS_DIR}"/*.sh; do
    [[ -f "${_mod_file}" ]] || continue
    # 跳过本文件自身，避免递归 source。
    [[ "$(basename "${_mod_file}")" == "load.sh" ]] && continue

    if [[ ! -r "${_mod_file}" ]]; then
        log ERROR "cannot read ${_mod_file}"
        unset _MODS_DIR _mod_file
        return 1
    fi

    # shellcheck source=/dev/null
    if ! source "${_mod_file}"; then
        log ERROR "failed to source ${_mod_file}"
        unset _MODS_DIR _mod_file
        return 1
    fi
done

unset _MODS_DIR _mod_file
