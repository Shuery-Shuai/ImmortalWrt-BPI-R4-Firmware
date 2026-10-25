#!/bin/bash
#
# 生成 GitHub Actions 运行摘要，并在失败时摘录构建错误：
#   - 设置了 $GITHUB_STEP_SUMMARY 时追加写入该文件（Actions 运行页可见）；
#   - 未设置时打印到 stdout，便于本地预览；
#   - 失败路径下，同一段错误行还会打到 stderr，让本地终端与 CI 页面看到同一份证据。
#
# 用法：bash scripts/ci/generate-summary.sh [build|update-checker]
#
# 为什么退出码恒为 0：本脚本挂在 workflow 收尾步骤（if: always()）上，它只负责“汇报”。
# 若它自己非零退出，就会覆盖掉真正的构建结论，所以任何输入缺失、命令不存在，
# 一律降级为跳过对应小节；同理这里不用 set -e。
#

# 本文件位于 scripts/ci/，目录必须自己解析：调用方可能从任意 cwd 调用。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# log_* 全仓库只有这一份实现，不在这里另造（重复定义会撞上 logger 的 readonly 常量）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"

# 摘要要按仓库根找 logs/ 与 immortalwrt/bin/targets，因此先记住调用者 cwd，
# 退出时还原，免得把“改了 cwd”这个副作用留给调用它的 shell。
ORIGINAL_DIR="$(pwd)"
readonly ORIGINAL_DIR
trap 'cd "$ORIGINAL_DIR"' EXIT

# 本文件位于 scripts/ci/，故需上溯两级才到仓库根。
cd "${SCRIPT_DIR}/../.." || log_warning "无法进入仓库根 ${SCRIPT_DIR}/../..；路径相关小节可能为空"

readonly DEFAULT_LOG_DIR="logs"
# 先 tail 限流再 grep：CI 构建日志动辄数十 MB，全量扫描会拖住收尾步骤本身。
readonly ERROR_SOURCE_LINES=20000
# 摘要里只保留最有代表性的尾部错误：去重后最多 30 行。
readonly ERROR_SHOW_LINES=30
# 单行截断，避免一条巨长的编译命令把摘要撑爆。
readonly ERROR_LINE_MAX=300
# 关键错误行模式（编译器 / 链接器 / make / 命令缺失等最常见的失败形态）。
readonly ERROR_PATTERN='error:|Error:|ERROR|Error [0-9]+|fatal error|undefined reference|No rule to make target|make[0-9]*: [*][*][*]|command not found|[Ff]ailed'
readonly FIRMWARE_NAMES=(-name '*.bin' -o -name '*.itb' -o -name '*.img.gz' -o -name '*.fip')

# 跨函数共享：摘要正文是在命令替换（子 shell）里渲染的，只有全局变量能跨过那道边界，
# 因此失败摘录与它的定位说明存成全局，保证摘要与 stderr 用的是同一份文本。
FAILURE_DETECTED=false
CANCELLED_DETECTED=false
ERROR_LOG_NAME=""
# stage = make 原始输出（含编译器错误原行）；logger = 构建脚本日志（可能只有汇总提示）。
ERROR_SOURCE_KIND=""
ERROR_EXCERPT=""
ERROR_NOTE=""

# Markdown 表格里的 "|" 会提前断列、换行会拆行：统一压平再转义。
md_cell() {
  printf '%s' "${1}" | tr '\n' ' ' | sed 's/|/\\|/g'
}

# 步骤结果的可读映射；空值代表该步骤因前序失败/取消而根本没执行。
step_badge() {
  case "${1}" in
    success) printf '✅ success' ;;
    failure) printf '❌ failure' ;;
    cancelled) printf '✖ cancelled' ;;
    skipped) printf '⏭ skipped' ;;
    "") printf '⚪ 未执行' ;;
    *) printf '❔ %s' "${1}" ;;
  esac
}

# STEP_SEQUENCE 的 KEY 是给人看的（hw / env_setup / release_info），但环境变量名
# 大小写并不统一：STEP_hw 与 STEP_HW 都出现过，而 bash 变量名大小写敏感。
# 故三个候选依次试（原样 / 全大写 / 全小写），取第一个非空值；用间接取值读，不 eval。
step_value() {
  local key="${1}"
  local cand
  for cand in "STEP_${key}" "STEP_${key^^}" "STEP_${key,,}"; do
    if [[ -n "${!cand:-}" ]]; then
      printf '%s' "${!cand}"
      return 0
    fi
  done
  return 0
}

# 只输出有值的那一行：契约里所有输入都是可选的，缺失即跳过。
meta_row() {
  local label="${1}"
  local value="${2:-}"
  [[ -n "${value}" ]] || return 0
  printf '| %s | %s |\n' "$(md_cell "${label}")" "$(md_cell "${value}")"
}

# 环境里实际存在的 STEP_* 变量名全集（compgen 覆盖导出变量，故 STEP_hw 也可见）。
env_step_vars() {
  compgen -v 2>/dev/null | grep -E '^STEP_[A-Za-z0-9_]+$' | grep -vx 'STEP_SEQUENCE'
}

# 判定失败状态：job 级或任一 step 级出现 failure/cancelled 都算。
# 比对按小写做，避免大小写写法差异让失败被漏判。
detect_failure() {
  local var value
  if [[ -n "${JOB_STATUS:-}" && "${JOB_STATUS}" != "success" ]]; then
    FAILURE_DETECTED=true
    [[ "${JOB_STATUS,,}" == "cancelled" ]] && CANCELLED_DETECTED=true
  fi
  while IFS= read -r var; do
    [[ -n "${var}" ]] || continue
    value="${!var:-}"
    case "${value,,}" in
      failure) FAILURE_DETECTED=true ;;
      cancelled)
        FAILURE_DETECTED=true
        CANCELLED_DETECTED=true
        ;;
    esac
  done < <(env_step_vars)
  return 0
}

resolve_verdict() {
  local status="${JOB_STATUS:-}"
  if [[ "${FAILURE_DETECTED}" != "true" ]]; then
    if [[ -z "${status}" || "${status}" == "success" ]]; then
      printf '✅ 成功'
    else
      printf '✅ %s（未发现失败步骤）' "${status}"
    fi
    return 0
  fi
  if [[ "${CANCELLED_DETECTED}" == "true" ]]; then
    printf '✖ 已取消'
  elif [[ "${status}" == "failure" ]]; then
    printf '❌ 失败'
  else
    printf '⚠️ 部分失败'
  fi
  return 0
}

render_header() {
  local mode="${1}"
  if [[ "${mode}" == "update-checker" ]]; then
    printf '## 🔄 上游更新检查总结\n\n'
  else
    printf '## 🏗️ ImmortalWrt BPI-R4 构建总结\n\n'
  fi
  printf '**结论：** %s\n\n' "$(resolve_verdict)"
  if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '运行链接：%s/%s/actions/runs/%s\n\n' \
      "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}"
  fi
}

render_meta() {
  local commit rows
  # git 取不到（浅克隆无 HEAD、或不在仓库内）就留空，不报错。
  commit="$(git rev-parse --short HEAD 2>/dev/null)" || commit=""
  rows="$(
    meta_row "Workflow" "${GITHUB_WORKFLOW:-}"
    meta_row "Job" "${GITHUB_JOB:-}"
    meta_row "事件" "${GITHUB_EVENT_NAME:-}"
    meta_row "分支" "${GITHUB_REF_NAME:-}"
    meta_row "提交" "${commit}"
    meta_row "触发人" "${GITHUB_ACTOR:-}"
    meta_row "Runner" "${RUNNER_OS:-}"
    meta_row "Run attempt" "${GITHUB_RUN_ATTEMPT:-}"
  )"
  [[ -n "${rows}" ]] || return 0
  printf '### 运行信息\n\n| 项 | 值 |\n| --- | --- |\n%s\n\n' "${rows}"
}

render_steps() {
  [[ -n "${STEP_SEQUENCE:-}" ]] || return 0
  printf '### 步骤状态\n\n| 步骤 | 结果 |\n| --- | --- |\n'
  local line key name value
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%|*}"
    if [[ "${line}" == *"|"* ]]; then
      name="${line#*|}"
    else
      name="${key}"
    fi
    [[ -n "${name}" ]] || name="${key}"
    value="$(step_value "${key}")"
    printf '| %s | %s |\n' "$(md_cell "${name}")" "$(step_badge "${value}")"
  done <<<"${STEP_SEQUENCE}"
  printf '\n'
}

# numfmt 在精简镜像里可能不存在：退回原始字节数，摘要可读性下降但不失败。
human_bytes() {
  local bytes="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    if numfmt --to=iec --suffix=B "${bytes}" 2>/dev/null; then
      return 0
    fi
  fi
  printf '%s 字节（numfmt 不可用）' "${bytes}"
}

firmware_size_line() {
  local root="immortalwrt/bin/targets"
  [[ -d "${root}" ]] || return 0
  local sizes
  local -a find_args=(-type f '(' "${FIRMWARE_NAMES[@]}" ')')
  sizes="$(find "${root}" "${find_args[@]}" -print0 2>/dev/null |
    xargs -0 -r stat -c '%s' 2>/dev/null)" || sizes=""
  if [[ -z "${sizes}" ]]; then
    printf '固件体积：未找到匹配文件（*.bin *.itb *.img.gz *.fip）'
    return 0
  fi
  local count total
  count="$(printf '%s\n' "${sizes}" | grep -c '[0-9]')"
  total="$(printf '%s\n' "${sizes}" | awk '{ s += $1 } END { printf "%.0f", s }')"
  printf '固件体积：%s 个文件，共 %s' "${count}" "$(human_bytes "${total}")"
}

# artifact 表格是接线的核心价值：读的人要先知道去哪个 artifact 取固件，
# 所以即使 DEVICE_NAME 之类的元信息全空，只要有 artifact 名就要渲染。
artifact_rows() {
  local -a rows=()
  local line
  line="$(artifact_row "BIN" "${ARTIFACT_BIN_NAME:-}")"
  [[ -n "${line}" ]] && rows+=("${line}")
  line="$(artifact_row "FIRMWARE" "${ARTIFACT_FIRMWARE_NAME:-}")"
  [[ -n "${line}" ]] && rows+=("${line}")
  line="$(artifact_row "LOGS" "${ARTIFACT_LOGS_NAME:-}")"
  [[ -n "${line}" ]] && rows+=("${line}")
  [[ ${#rows[@]} -gt 0 ]] || return 0
  printf '%s\n' "${rows[@]}"
}

artifact_row() {
  local kind="${1}"
  local name="${2:-}"
  [[ -n "${name}" ]] || return 0
  # 反引号用 \x60 生成：字面反引号在单引号串里会被 shellcheck 当成笔误（SC2016）。
  local tick
  tick="$(printf '\x60')"
  printf '| %s | %s%s%s |\n' "${kind}" "${tick}" "${name}" "${tick}"
}

render_build_info() {
  # update-checker 的 job 拿不到固件，渲染体积/产物只会骗人；模式隔离在这里收口。
  [[ "${1}" == "build" ]] || return 0
  local rows size_line artifacts
  rows="$(
    meta_row "设备" "${DEVICE_NAME:-}"
    meta_row "文件日期" "${FILE_DATE:-}"
    meta_row "Release tag" "${RELEASE_TAG:-}"
    meta_row "构建缓存命中" "${CACHE_HIT:-}"
  )"
  artifacts="$(artifact_rows)"
  size_line="$(firmware_size_line)"
  if [[ -z "${rows}" && -z "${size_line}" && -z "${artifacts}" ]]; then
    return 0
  fi
  printf '### 构建产物\n\n'
  if [[ -n "${rows}" ]]; then
    # 表格后必须空一行，否则紧跟的普通段落会被 Markdown 解析成表格的续行。
    printf '| 项 | 值 |\n| --- | --- |\n%s\n' "${rows}"
  fi
  if [[ -n "${artifacts}" ]]; then
    [[ -n "${rows}" ]] && printf '\n'
    # 末尾补一个换行终止表格：命令替换已吞掉 artifact_rows 的行尾换行，
    # 否则后面的「固件体积」会被 Markdown 当成表格的续行。
    printf '| 产物类型 | artifact 名 |\n| --- | --- |\n%s\n' "${artifacts}"
  fi
  if [[ -n "${size_line}" ]]; then
    [[ -n "${rows}" || -n "${artifacts}" ]] && printf '\n'
    printf '%s\n' "${size_line}"
  fi
  printf '\n'
}

# 最新日志用 mtime 排序而非文件名排序：并发构建的日志名不含时间语义。
newest_log_file() {
  local dir="${1:-}"
  [[ -d "${dir}" ]] || return 1
  local found
  found="$(find "${dir}" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -n | tail -n 1 | cut -d' ' -f2-)" || found=""
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}

# 阶段日志 = make 的原始输出（compile.sh 的三段重定向目标），真正的 "error:" / "Error N"
# 只写在这里；logger 自己那份只记 log_* 行，从不含编译器原始错误行。
# 所以错误源不能只看 mtime——logger 日志全程追加、结束时必然最新，会盖掉真正有用的那份。
readonly STAGE_LOG_NAMES=(build-verbose.log build-single.log build-parallel.log)

stage_log_file() {
  local dir="${1:-}"
  local name
  for name in "${STAGE_LOG_NAMES[@]}"; do
    if [[ -f "${dir}/${name}" ]]; then
      printf '%s\n' "${dir}/${name}"
      return 0
    fi
  done
  return 1
}

is_stage_log() {
  local base name
  base="$(basename -- "${1}")"
  for name in "${STAGE_LOG_NAMES[@]}"; do
    [[ "${base}" == "${name}" ]] && return 0
  done
  return 1
}

# 只找 logger 日志（排除阶段日志）：同一秒内多文件 mtime 相同时，newest_log_file
# 会按路径字典序挑到阶段日志，回退逻辑若不复用它就会原地打转、永远试不到 logger 日志。
newest_logger_log_file() {
  local dir="${1:-}"
  [[ -d "${dir}" ]] || return 1
  local found
  found="$(find "${dir}" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -n | cut -d' ' -f2- | tac | while IFS= read -r p; do
      is_stage_log "${p}" || {
        printf '%s\n' "${p}"
        break
      }
    done)" || found=""
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}

# 输出 "<kind>|<path>"：kind=stage 表示 make 原始输出，kind=logger 表示构建脚本日志。
# 先按固定优先级找阶段日志（verbose 最后跑、信息最全，故排最前），没有才回退 mtime 最新的 logger 日志。
select_log_file() {
  local dir="${1:-}"
  local stage newest
  if stage="$(stage_log_file "${dir}")"; then
    printf 'stage|%s\n' "${stage}"
    return 0
  fi
  newest="$(newest_logger_log_file "${dir}")" || newest=""
  [[ -n "${newest}" ]] || newest="$(newest_log_file "${dir}")" || return 1
  printf 'logger|%s\n' "${newest}"
}

# 耗时候选：阶段日志没有 [时间] 前缀，取不到时间戳时由调用方继续试下一个，
# 所以阶段日志在前、logger 日志在后兜底；两者都无时才回落所有 *.log。
duration_log_candidates() {
  local dir="${1:-}"
  local name logger
  for name in "${STAGE_LOG_NAMES[@]}"; do
    [[ -f "${dir}/${name}" ]] && printf '%s\n' "${dir}/${name}"
  done
  logger="$(newest_logger_log_file "${dir}")" || logger=""
  if [[ -n "${logger}" ]]; then
    printf '%s\n' "${logger}"
    return 0
  fi
  newest_log_file "${dir}" 2>/dev/null || true
}

first_ts() {
  head -n 200 -- "${1}" 2>/dev/null |
    grep -m1 -oE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' | tr -d '[]'
}

last_ts() {
  tail -n 200 -- "${1}" 2>/dev/null |
    grep -oE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' | tail -n 1 | tr -d '[]'
}

human_duration() {
  local secs="${1:-0}"
  printf '%dh %dm %ds' "$((secs / 3600))" "$(((secs % 3600) / 60))" "$((secs % 60))"
}

# ccache 缺失、版本输出格式不认识都只是静默跳过——命中率是锦上添花，不能拖累收尾步骤。
ccache_line() {
  command -v ccache >/dev/null 2>&1 || return 0
  local out
  out="$(ccache -s 2>/dev/null)" || out=""
  [[ -n "${out}" ]] || return 0
  local rate hits_line hits pct misses
  rate="$(printf '%s\n' "${out}" | grep -iE 'hit rate' | head -n 1 | sed 's/.*:[[:space:]]*//')"
  if [[ -n "${rate}" ]]; then
    printf 'ccache 命中率：%s' "${rate}"
    return 0
  fi
  # ccache 4 的摘要形如 "Hits: 123 / 456 (26.97%)"，括号里就是命中率。
  hits_line="$(printf '%s\n' "${out}" | grep -iE '^[[:space:]]*hits[[:space:]]*:' | head -n 1)"
  [[ -n "${hits_line}" ]] || return 0
  pct="$(printf '%s' "${hits_line}" | grep -oE '\([0-9.]+%\)' | tr -d '()')"
  if [[ -n "${pct}" ]]; then
    printf 'ccache 命中率：%s' "${pct}"
    return 0
  fi
  hits="$(printf '%s' "${hits_line}" | grep -oE '[0-9]+' | head -n 1)"
  misses="$(printf '%s\n' "${out}" | grep -iE '^[[:space:]]*misses[[:space:]]*:' | head -n 1 |
    grep -oE '[0-9]+' | head -n 1)"
  if [[ -n "${hits}" && -n "${misses}" ]] && ((hits + misses > 0)); then
    pct="$(awk -v h="${hits}" -v m="${misses}" 'BEGIN { printf "%.1f%%", 100 * h / (h + m) }')"
    printf 'ccache 命中率：%s（%s hits / %s misses）' "${pct}" "${hits}" "${misses}"
  fi
  return 0
}

render_duration() {
  # 耗时靠 build 日志首末行、命中率靠 ccache，两者都只属于 build job；
  # update-checker 若渲染它们，本地预览就会把仓库里残留的旧 build 日志当成事实。
  [[ "${1}" == "build" ]] || return 0
  local dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
  local log line="" start end
  # 阶段日志是 make 原始输出，没有 logger 的 [时间] 前缀，取不到首末行时间戳；
  # 所以按候选顺序逐个试，第一个能给出时间戳的赢，logger 日志天然兜底。
  while IFS= read -r log; do
    [[ -n "${log}" ]] || continue
    start="$(first_ts "${log}")"
    end="$(last_ts "${log}")"
    [[ -n "${start}" && -n "${end}" ]] || continue
    local s e
    s="$(date -d "${start}" +%s 2>/dev/null)" || s=""
    e="$(date -d "${end}" +%s 2>/dev/null)" || e=""
    [[ -n "${s}" && -n "${e}" ]] || continue
    ((e >= s)) || continue
    line="构建耗时：约 $(human_duration "$((e - s))")（${start} → ${end}，来源 $(basename -- "${log}")）"
    break
  done < <(duration_log_candidates "${dir}")
  local cache
  cache="$(ccache_line)"
  if [[ -z "${line}" && -z "${cache}" ]]; then
    return 0
  fi
  printf '### 耗时与缓存\n\n'
  [[ -n "${line}" ]] && printf -- '- %s\n' "${line}"
  [[ -n "${cache}" ]] && printf -- '- %s\n' "${cache}"
  printf '\n'
}

# 失败摘录只算一次并存进全局：摘要与 stderr 用的是同一段文本，避免两处口径不一。
collect_error_excerpt() {
  local dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
  local selected log
  selected="$(select_log_file "${dir}")" || selected=""
  if [[ -z "${selected}" ]]; then
    ERROR_NOTE="未找到构建日志：${dir} 不存在或不含 *.log"
    return 0
  fi
  ERROR_SOURCE_KIND="${selected%%|*}"
  log="${selected#*|}"
  ERROR_LOG_NAME="$(basename -- "${log}")"
  ERROR_EXCERPT="$(tail -n "${ERROR_SOURCE_LINES}" -- "${log}" 2>/dev/null |
    grep -aE -- "${ERROR_PATTERN}" 2>/dev/null |
    awk -v max="${ERROR_SHOW_LINES}" -v len="${ERROR_LINE_MAX}" '
      {
        line = $0
        gsub(/[[:cntrl:]]/, "", line)          # 控制字符会破坏 fenced block 的排版
        if (line ~ /^[[:space:]]*$/) next
        if (length(line) > len) line = substr(line, 1, len) "..."
        if (seen[line]++) next                 # 同一错误在多 target 里重复出现，只留一行
        print line
        if (++n >= max) exit
      }')" || ERROR_EXCERPT=""
  if [[ -z "${ERROR_EXCERPT}" ]]; then
    ERROR_NOTE="日志 ${ERROR_LOG_NAME} 中未匹配到关键错误行（已扫描末尾 ${ERROR_SOURCE_LINES} 行）"
  fi
  return 0
}

# 日志类型要写进摘要：logger 日志通常只有「Compilation failed. Logs: ...」这类汇总行，
# 读者看到来源是它时，才知道原行仍需回到 stage artifact 里查。
log_kind_label() {
  case "${ERROR_SOURCE_KIND}" in
    stage) printf 'make 原始输出' ;;
    logger) printf '构建脚本日志，可能不含编译错误原行' ;;
    *) printf '未知来源' ;;
  esac
}

render_failure() {
  printf '### 失败详情\n\n'
  if [[ -n "${ERROR_EXCERPT}" ]]; then
    local count
    count="$(printf '%s\n' "${ERROR_EXCERPT}" | grep -c '')"
    printf '<details><summary>关键错误摘录（%s 行，来自 <code>%s</code> — %s）</summary>\n\n' \
      "${count}" "$(md_cell "${ERROR_LOG_NAME}")" "$(log_kind_label)"
    # 反引号用 \x60 生成，避免围栏字面量在 shell 里被当成命令替换。
    local fence
    fence="$(printf '\x60\x60\x60')"
    printf '%stext\n%s\n%s\n\n</details>\n\n' "${fence}" "${ERROR_EXCERPT}" "${fence}"
    return 0
  fi
  printf '未找到构建日志：%s\n\n' "$(md_cell "${ERROR_NOTE:-未找到构建日志}")"
  return 0
}

render_update_checker() {
  [[ "${1}" == "update-checker" ]] || return 0
  # 用数组攒行：命令替换会吞掉行尾换行，拼字符串容易丢掉表格的行分隔。
  local -a rows=()
  local trimmed
  trimmed="$(meta_row "上游 commit" "${COMMIT_HASH:-}")"
  [[ -n "${trimmed}" ]] && rows+=("${trimmed}")
  case "${BUILD_TRIGGERED:-}" in
    true) rows+=("| 构建 | 已触发构建 |") ;;
    false) rows+=("| 构建 | 未触发构建（上游无新提交） |") ;;
  esac
  if [[ ${#rows[@]} -eq 0 ]]; then
    printf '### 上游更新\n\n未提供上游 commit 信息。\n\n'
    return 0
  fi
  printf '### 上游更新\n\n| 项 | 值 |\n| --- | --- |\n'
  printf '%s\n' "${rows[@]}"
  printf '\n'
}

# 写入 GITHUB_STEP_SUMMARY；路径不可写时退回 stdout，信息不丢。
emit_summary() {
  local text="${1}"
  local target="${GITHUB_STEP_SUMMARY:-}"
  if [[ -n "${target}" ]]; then
    if printf '%s\n' "${text}" >>"${target}" 2>/dev/null; then
      return 0
    fi
    log_warning "写入 ${target} 失败，改为输出到 stdout"
  fi
  printf '%s\n' "${text}"
  return 0
}

# 本地跑也要看得见：与摘要一模一样的那段错误，加前缀打到 stderr。
flush_error_to_stderr() {
  [[ "${FAILURE_DETECTED}" == "true" ]] || return 0
  if [[ -n "${ERROR_EXCERPT}" ]]; then
    printf '\n[generate-summary] %s（%s）的关键错误，同一份内容已写入摘要：\n' \
      "${ERROR_LOG_NAME}" "$(log_kind_label)" >&2
    printf '%s\n\n' "${ERROR_EXCERPT}" >&2
  else
    printf '\n[generate-summary] %s\n\n' "${ERROR_NOTE:-未找到构建日志}" >&2
  fi
  return 0
}

main() {
  local mode="${1:-build}"
  case "${mode}" in
    build | update-checker) ;;
    *)
      log_warning "未知模式 '${mode}'，按 build 处理"
      mode="build"
      ;;
  esac

  detect_failure
  if [[ "${FAILURE_DETECTED}" == "true" ]]; then
    collect_error_excerpt
  fi

  local summary
  summary="$(
    render_header "${mode}"
    render_meta
    render_update_checker "${mode}"
    render_steps
    render_build_info "${mode}"
    render_duration "${mode}"
    if [[ "${FAILURE_DETECTED}" == "true" ]]; then
      render_failure
    fi
  )"

  emit_summary "${summary}"
  flush_error_to_stderr
  return 0
}

main "$@"
