# scripts/libs/load.sh —— 目录聚合加载器（被 source，不直接执行）
# 用法: source scripts/libs/load.sh
# shellcheck shell=bash
#
# 职责：按依赖顺序加载 01-shell-logger → 02-error-handler → 03-argument-parser，再加载 utils/ 下的纯工具函数。本文件只做 source，无业务逻辑。
# 命名为 load 而非 entry/index：它就是加载；entry 像可执行入口，index 像目录索引。
#
# 加载顺序是硬约束：01-shell-logger 必须最先——它是全仓库 log / COLOR_* / LOG_LEVEL_* 的唯一实现；
# 其余文件只调用不定义。顺序写死在此，避免再次出现『日志格式取决于 glob 字母序』的缺陷。
#
# 位置兼容：本文件在仓库内是 scripts/libs/，被复制后是 immortalwrt/libs/；
# 两种位置下 utils/ 分别位于 scripts/inputs/utils/ 与 immortalwrt/utils/，故按序探测。
#
# 失败语义：本文件被 source，因此【一律 return 1】而不是 exit —— exit 会连带终止调用者的整个 shell。
# 错误信息走后备 log（见下方定义）：logger.sh 尚未加载成功时 log 可能不存在，后备定义保证格式统一，
# 且不会把真实原因掩盖成『log: command not found』。

# 防重复加载：函数被重复定义通常无害，但若某文件含顶层变量赋值或副作用，重复 source 会重复执行。
if [[ -n "${_LIBS_LOADED:-}" ]]; then
    return 0
fi
readonly _LIBS_LOADED=1

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

_LIBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 工具函数库位置随场景不同，按序探测；都找不到就明确报错，而不是静默漏加载。
if [[ -d "${_LIBS_DIR}/../utils" ]]; then
    _UTILS_DIR="$(cd "${_LIBS_DIR}/../utils" && pwd)"
elif [[ -d "${_LIBS_DIR}/../inputs/utils" ]]; then
    _UTILS_DIR="$(cd "${_LIBS_DIR}/../inputs/utils" && pwd)"
else
    log ERROR "utils directory not found relative to ${_LIBS_DIR}"
    unset _LIBS_DIR
    return 1
fi

# 按依赖顺序加载三个库，顺序不可调换：
#   01-shell-logger   日志唯一实现（无依赖，必须最先）
#   02-error-handler  fail / die，内部调用 log_error（故在 logger 之后）
#   03-argument-parser 参数解析，出错时用 log_error（故在 logger 之后）
_LIBS_UNITS=(
    01-shell-logger.sh
    02-error-handler.sh
    03-argument-parser.sh
)
for _lib_file in "${_LIBS_UNITS[@]}"; do
    _lib_path="${_LIBS_DIR}/${_lib_file}"
    if [[ ! -r "${_lib_path}" ]]; then
        # 首轮 logger 未加载时 log 尚不存在，用后备定义已在上方声明，故此处安全。
        log ERROR "cannot read ${_lib_path}"
        unset _LIBS_DIR _UTILS_DIR _LIBS_UNITS _lib_file _lib_path
        return 1
    fi
    # shellcheck source=/dev/null
    if ! source "${_lib_path}"; then
        log ERROR "failed to source ${_lib_path}"
        unset _LIBS_DIR _UTILS_DIR _LIBS_UNITS _lib_file _lib_path
        return 1
    fi
done

# 工具函数库由 inputs/utils/load.sh 统一加载：那边用 01 起的数字前缀保证
# 依赖在前（01 symlink → 02 version → …），顺序只需在那一处维护。
# shellcheck source=/dev/null
if ! source "${_UTILS_DIR}/load.sh"; then
    log ERROR "failed to source ${_UTILS_DIR}/load.sh"
    unset _LIBS_DIR _UTILS_DIR
    return 1
fi

unset _LIBS_DIR _UTILS_DIR
