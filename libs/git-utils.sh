#!/bin/bash
#######################################
# Git 仓库克隆/更新（带重试）
#
# 依赖：若未 source logger.sh，将启用后备日志函数。
# 用法：source common/scripts/libs/git-utils.sh
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

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
# Outputs:
#   操作进度信息到 stdout
#   错误信息到 stderr (通过 log)
#
# Returns:
#   0 - 成功克隆或更新
#   1 - 重试 3 次后仍失败 (脚本直接退出)
#
# Examples:
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
                    log 'ERROR' "Failed to clone ${repo} after 3 attempts."
                    exit 1
                fi
            fi
        done
    fi
}
