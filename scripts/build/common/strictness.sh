#!/bin/bash
#
# 项目严格度策略（scripts/build/common/strictness.sh）。
#
# REQUIRED=1 是 CI 用的严格模式：缺私钥、缺依赖清单、装依赖失败都必须中断；
# 本地缺省 REQUIRED=0，同一条件降级为警告并继续，保证首次构建能跑起来。
#
# 这是**项目策略**而不是日志能力，因此不放在 lib/log.sh 里：日志库应当只做格式化与转发，
# 换一个项目仍可原样使用；"什么时候该硬失败"只对本仓库成立。
#
# 依赖：必须在 scripts/libs/01-shell-logger.sh 之后加载（本文件调用 log_error / log_warning）。

# REQUIRED=1 是 CI 用的严格模式：缺私钥、缺依赖清单、装依赖失败都必须中断。
required_mode() {
  [[ "${REQUIRED:-0}" == "1" ]]
}

# 统一"严格模式硬失败 / 否则降级为警告"的分支，避免每处再写一遍判断。
require_or_warn() {
  local message="$1"
  if required_mode; then
    log_error "${message} (REQUIRED=1)"
    return 1
  fi
  log_warning "${message}"
  return 0
}
