#!/bin/bash
#######################################
# Git 仓库克隆/更新（带重试）
#
# 依赖：log 由 logger.sh 提供（index.sh 已保证其最先加载，本文件不再自带后备实现）。
#       fail 由 scripts/libs/02-error-handler.sh 提供（记录错误 + return 1）。
# 失败语义：本文件是被 source 的工具库，失败一律 return 1，绝不 exit——
#           clone_repo 的调用者是 diy-part1.sh，exit 会连同它一起杀掉，
#           后续的 sparse-checkout 与其它仓库克隆全部丢失。
# 用法：source scripts/inputs/utils/07-git-utils.sh
#
# 定位 02-error-handler.sh：本文件在两种布局下都会被 source，同一段相对路径不可能同时成立——
#   · 仓库内：scripts/inputs/utils/ → ../../libs/02-error-handler.sh
#   · 构建时：copy_custom_files 把它复制成 immortalwrt/utils/，libs 是同级兄弟 → ../libs/02-error-handler.sh
# 因此按序探测（与 scripts/libs/load.sh 探测 utils 目录同一手法），两种布局都命中。
# shellcheck source=/dev/null
_GIT_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "${_GIT_UTILS_DIR}/../../libs/02-error-handler.sh" ]]; then
    source "${_GIT_UTILS_DIR}/../../libs/02-error-handler.sh"
elif [[ -r "${_GIT_UTILS_DIR}/../libs/02-error-handler.sh" ]]; then
    source "${_GIT_UTILS_DIR}/../libs/02-error-handler.sh"
fi
unset _GIT_UTILS_DIR
#######################################

#######################################
# 克隆或更新 Git 仓库（带重试机制）
#
# 智能处理仓库下载：如果目录已存在则执行 pull 更新，否则执行 clone。
# 支持失败重试（最多 3 次），每次重试前等待递增的时间。
#
# 参数：
#   $1 - Git 仓库 URL
#   $2 - 分支名称
#   $3 - git clone 的额外参数 (如 "--depth=1" 或 "--filter=blob:none --sparse")
#   $4 - 目标目录路径 (相对或绝对路径)
#
# 全局变量：
#   None
#
# 输出：
#   操作进度信息到 stdout
#   错误信息到 stderr (通过 log)
#
# 返回：
#   0 - 成功克隆或更新
#   1 - 重试 3 次后仍失败（已 log_error 说明，由调用者决定是否中止）
#
# 示例：
#   clone_repo 'https://github.com/user/repo' 'main' '--depth=1' 'packages/repo'
#   clone_repo 'https://github.com/user/repo' 'master' '--filter=blob:none --sparse' 'custom-packages/repo'
#######################################
clone_repo() {
    local repo="$1"
    local branch="$2"
    local args="$3"
    local target="$4"
    local attempt

    if [[ -d "${target}" ]]; then
        # 目录已存在，尝试更新
        log 'INFO' "Pulling ${repo} at ${target}..."
        for attempt in {1..3}; do
            # 清理工作区 -> 恢复修改 -> 拉取更新
            if git -C "${target}" clean -fdx &&
                git -C "${target}" restore . &&
                git -C "${target}" pull; then
                break
            else
                log 'WARN' "Pull attempt ${attempt} failed, retrying..."
                sleep $((attempt * 2)) # 递增等待时间：2s, 4s, 6s
            fi
        done
    else
        # 目录不存在，克隆新仓库
        log 'INFO' "Cloning ${repo} ${branch} to ${target}, using args: ${args}"
        for attempt in {1..3}; do
            log 'INFO' "Clone attempt ${attempt}..."
            # 将参数字符串拆分并传递给 git clone
            if eval "git clone -b '${branch}' ${args} '${repo}' '${target}'"; then
                break
            else
                log 'ERROR' "Clone attempt ${attempt} failed!"
                sleep $((attempt * 2))
                rm -rf "${target}" # 清理失败的半成品
                if [[ "${attempt}" -eq 3 ]]; then
                    fail "Failed to clone ${repo} after 3 attempts."
                    return 1
                fi
            fi
        done
    fi
}
