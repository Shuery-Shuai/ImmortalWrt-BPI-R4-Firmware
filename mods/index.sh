#!/bin/bash
# 文件: common/scripts/mods/index.sh
# 用途: 加载 common/scripts/mods/ 下的所有独立修改脚本（定义函数，不执行）
# 用法: source common/scripts/mods/index.sh
#       在 diy-part 脚本中调用该目录下的任意修改函数

# 获取当前脚本所在目录
_COMMON_MODS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 遍历当前目录下所有 .sh 文件，排除自身
for script in "${_COMMON_MODS_DIR}"/*.sh; do
    # 跳过 index.sh 自身
    if [[ "$(basename "${script}")" == "index.sh" ]]; then
        continue
    fi

    if [[ -f "${script}" ]]; then
        # 安全加载，失败时输出警告并退出
        # shellcheck source=/dev/null
        if ! source "${script}"; then
            log "WARN" "Failed to source ${script}" >&2
            exit 1
        fi
    fi
done

# 清理变量
unset _COMMON_MODS_DIR
