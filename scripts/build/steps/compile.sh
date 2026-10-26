#!/bin/bash
#
# 下载与编译（scripts/build/steps/compile.sh）：download_packages / compile_firmware / _make_once /
# compilation_failure_is_workspace_related / clean_immortalwrt_changes /
# immortalwrt_is_dirty / immortalwrt_has_stale_artifacts；实现与迁移前的单体实现一致。
#
# 依赖 scripts/libs/01-shell-logger.sh 提供的日志包装函数：compile_firmware 与 clean_immortalwrt_changes 会打日志；
# 失败收敛用 scripts/libs/02-error-handler.sh 的 fail（记录错误 + return 1）。
#
# 失败语义：本文件是被 build.sh source 的库，函数【绝不】exit——退出与否由 build.sh 的
# `run_stage || exit 1` 决定。清理（clean_immortalwrt_changes）只是编译失败且失败特征被判为工作区相关时的最后手段。
# shellcheck source=scripts/libs/02-error-handler.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../libs/02-error-handler.sh"

# Reports whether the immortalwrt work tree has modifications relative to upstream
# (tracked edits or untracked files). 只报告，不做任何修改。
# 注意用 --porcelain 全量输出：DIY 脚本会写入未跟踪文件，只查 tracked 会漏判。
immortalwrt_is_dirty() {
  [[ -d "immortalwrt" ]] || return 1
  [[ -n "$( cd immortalwrt && git status --porcelain 2>/dev/null )" ]]
}

# Reports whether a previous build left intermediate artifacts behind.
immortalwrt_has_stale_artifacts() {
  [[ -d "immortalwrt" ]] || return 1
  local d
  for d in build_dir staging_dir tmp; do
    [[ -e "immortalwrt/${d}" ]] && return 0
  done
  return 1
}

# Last-resort cleanup of the immortalwrt work tree.
#
# 调用契约（刻意如此）：
#   1. 只由 compile_firmware 在**编译确实失败**、且失败特征被判为工作区相关问题之后调用。
#      准备阶段（prepare/download）永不调用：build_dir/ staging_dir/ 是数小时的编译产物，
#      在正常路径上清理它们等于把用户进度丢掉。
#   2. 必须保留 copy_custom_files 放进来的自定义文件（diy-part*.sh / libs / mods / files /
#      custom-packages）：它们是构建输入而不是污染。此前用裸 git clean -fd 会把它们删光，
#      导致清理后的重试必然再次失败。
#   3. 只删编译产物目录；已跟踪文件的改动用 git restore 覆盖。
# 全程子 shell，避免 cd 污染调用者工作目录。
clean_immortalwrt_changes() {
  [[ -d "immortalwrt" ]] || return 0
  log_info "Cleaning immortalwrt work tree (removing build artifacts, keeping custom files)..."
  (
    # 子 shell 内刻意保留 exit：它只结束这个子 shell，外层的 `|| fail` 接得住返回码；
    # 若在这里写 `|| fail`，fail 的 return 只从 fail 自身返回、rc 被 || 吃掉，
    # 子 shell 会继续执行下面的 rm -rf 与 git clean——那正是删除动作，失败时更不能跑。
    if ! cd immortalwrt; then
      log_error "Failed to enter 'immortalwrt' directory."
      exit 1
    fi
    # 编译产物：只删这些，避免误伤 dl/ 缓存与自定义输入。
    rm -rf build_dir staging_dir tmp
    # 已跟踪文件的改动（DIY 脚本对上游源码的修改）回滚到上游状态。
    if ! git restore . 2>/dev/null; then
      log_warning "git restore failed; tracked modifications may remain."
    fi
    # 清掉未跟踪的垃圾文件，但明确排除构建输入。
    git clean -fd \
      -e custom-packages -e files -e libs -e mods \
      -e diy-part1.sh -e diy-part2.sh -e .config \
      >/dev/null 2>&1 || true
  ) || fail "Failed to clean immortalwrt directory."
}

# Downloads all package sources (aligns with workflow "Download package").
download_packages() {
  local jobs="${DOWNLOAD_JOBS:-$(nproc)}"
  log_info "Downloading package sources (jobs: ${jobs})..."
  # fail 只报错，返回码不会自动终止函数；后面还有两条 find，不显式 return 会以 0 结束。
  ( cd immortalwrt && make download -j"${jobs}" ) || {
    fail "Package download failed."
    return 1
  }
  # 对齐 workflow：清理下不到内容的小文件（多为 404 占位），避免它们污染后续编译。
  ( cd immortalwrt && find dl -size -1024c -exec ls -l {} \; ) 2>/dev/null || true
  ( cd immortalwrt && find dl -size -1024c -exec rm -f {} \; ) 2>/dev/null || true
}

# 判定一次编译失败是否属于"工作区被污染 / 有未完成产物"这类可由清理修复的情形。
# 只有命中时才允许触发最后手段的清理；其余失败（真实的编译错误、缺依赖、网络问题）
# 一律原样上报，清理无法解决，反而会毁掉已有产物。
compilation_failure_is_workspace_related() {
  local logfile="${1:-}"
  [[ -n "${logfile}" && -f "${logfile}" ]] || return 1
  # 典型可清理型失败：stale/缺失的中间产物、并发构建留下的损坏状态、
  # 被 DIY 脚本或旧配置污染的构建目录。
  grep -qiE 'No rule to make target|No such file or directory.*(staging_dir|build_dir)|cannot find the directory|File exists.*staging|corrupted|was interrupted' "${logfile}"
}

# 带日志编译一次：失败时把输出落到文件，便于判断失败类型。
_make_once() {
  local logfile="${1}"; shift
  if ( cd immortalwrt && make "${@}" ) >"${logfile}" 2>&1; then
    return 0
  fi
  tail -n 40 "${logfile}" >&2
  return 1
}

# Compiles the firmware (aligns with workflow "Compile the firmware").
# 先并行、再单线程、最后单线程带详细输出——与 workflow 的三段式一致。
# 清理（最后手段）只在三段全失败、且日志显示是工作区/产物问题后才发生一次。
compile_firmware() {
  local jobs="${COMPILE_JOBS:-$(nproc)}"
  # 优先用 logger 导出的绝对目录：本函数可能在任何 CWD 下被调用，相对路径会散落。
  local logdir="${LOG_DIR_ABS:-${LOG_DIR:-logs}}"
  mkdir -p "${logdir}" || true
  # 与 logger 日志同一命名形状 build-<步骤>-<变体>.log：只读文件名就要能答"哪一步、哪种跑法"。
  local log1="${logdir}/build-compile-parallel.log"
  local log2="${logdir}/build-compile-single.log"
  local log3="${logdir}/build-compile-verbose.log"

  log_info "Compiling firmware (jobs: ${jobs})..."
  if _make_once "${log1}" -j"${jobs}"; then
    log_success "Parallel compilation completed."
    return 0
  fi
  log_warning "Parallel compilation failed (log: ${log1}); retrying single-threaded..."
  if _make_once "${log2}" -j1; then
    log_success "Single-threaded compilation completed."
    return 0
  fi
  log_warning "Single-threaded build failed (log: ${log2}); retrying with verbose output..."
  if _make_once "${log3}" -j1 V=s; then
    log_success "Verbose compilation completed."
    return 0
  fi

  log_error "Compilation failed. Logs: ${log1}, ${log2}, ${log3}"

  # 最后手段：仅当失败呈现为工作区污染/未完成产物特征时才清理并重试一次。
  if ! compilation_failure_is_workspace_related "${log3}"; then
    fail "Failure does not look workspace-related; not cleaning. Fix the real cause."
    return 1
  fi

  log_warning "Failure looks workspace-related; cleaning is warranted (last resort)."
  # 同样必须显式 return：失败后是"重试编译"，继续跑就与 "giving up" 自相矛盾。
  clean_immortalwrt_changes || {
    fail "Cleanup failed; giving up."
    return 1
  }
  log_info "Retrying compilation after a clean rebuild..."
  if _make_once "${log1}" -j"${jobs}"; then
    log_success "Compilation completed after clean rebuild."
    return 0
  fi
  fail "Compilation still fails after clean rebuild; see ${log1}"
}
