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
#
# 这里**刻意不做任何"清理小文件"的收尾动作**（历史上曾有一条
# `find dl -size -1024c -exec rm -f {} \;`，已移除）。理由：
#
#   1) 它要解决的问题不存在。OpenWrt 的 scripts/download.pl 是**原子写**：
#      先落到 $filename.dl，校验通过才 move 成正式文件名，失败走 cleanup 删掉
#      （download.pl 的 cleanup 子程序 unlink 的就是 .dl 与 .hash）。配合
#      include/download.mk 的 check_hash（哈希不符即 cleanup 并失败），
#      dl/ 里不会留下"404 生成的极小占位"这种东西。
#   2) 判据不成立。"小于 1 KiB 即占位"与真实数据相反：本机 dl/ 顶层 210 个下载包
#      **最小也有 5061 字节**，一个都不命中；而 <1024c 的 2332 个文件**全部**位于
#      dl/go-mod-cache 内——那是 Go 模块解包后的源码树。
#   3) 代价极大。误删模块源码后，报错完全不指向这里：
#        no required module provides package .../utls/internal/helper
#        build constraints exclude all Go files in .../go-isatty
#      极易被误判成缓存损坏 / go 版本不匹配 / 代理问题，排查代价远超收益。
#
# 网络失败的正确处理是让 make download 自己失败（见下方 || fail），而不是事后补救。
download_packages() {
  local jobs="${DOWNLOAD_JOBS:-$(nproc)}"
  log_info "Downloading package sources (jobs: ${jobs})..."
  ( cd immortalwrt && make download -j"${jobs}" ) || {
    fail "Package download failed."
    return 1
  }
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

# 带日志编译一次：输出同时进「本变体日志」与「统一采集层（终端 + 主日志）」。
#
# 旧实现是 `( ... ) >"${logfile}" 2>&1`：make 的全量输出被独占进变体日志，
# 终端与主日志【都】拿不到。于是编译两分半，build-all.log 里只有 4 行进度日志，
# 终端则整段静默——这正是"终端和日志文件不同步"的第二个来源。
# 现在改为 `| tee -a`：tee 的 stdout 接到采集层（logger 已把 fd 1/2 双写到终端与文件），
# 变体日志仍照旧保留，供失败分析与摘要引用。
#
# 退出码必须取 PIPESTATUS[0]：管道末端的 tee 会把 make 的失败改写成 0。
# 变体日志先清空再追加，与旧实现的 `>` 语义一致；失败时仍回放最后 40 行（现在这两行
# 也会进主日志，因为 >&2 走的正是采集层）。
_make_once() {
  local logfile="${1}"; shift
  : >"${logfile}" 2>/dev/null || true
  ( cd immortalwrt && make "${@}" ) 2>&1 | tee -a "${logfile}"
  local -a pipe_status=("${PIPESTATUS[@]}")
  local rc="${pipe_status[0]}"
  local tee_rc="${pipe_status[1]:-0}"

  if ((tee_rc != 0)); then
    # tee 失败 = 变体日志没写成，但构建本身可能成功。必须说出来，否则失败分析与摘要
    # 会引用一份不完整的日志而毫无提示。
    log_warning "无法完整写入 ${logfile}（tee 退出码 ${tee_rc}）"
  fi
  if ((rc != 0)); then
    tail -n 40 "${logfile}" 2>/dev/null >&2
    return 1
  fi
  return 0
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
