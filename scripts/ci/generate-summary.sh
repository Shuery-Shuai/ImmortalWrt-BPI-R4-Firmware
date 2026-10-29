#!/bin/bash
#
# 生成 GitHub Actions 运行摘要，并在失败时摘录构建错误：
#   - 设置了 $GITHUB_STEP_SUMMARY 时追加写入该文件（Actions 运行页可见）；
#   - 未设置时打印到 stdout，便于本地预览；
#   - 失败路径下，同一段错误行还会打到 stderr，让本地终端与 CI 页面看到同一份证据。
#
# 用法：bash scripts/ci/generate-summary.sh [build|update-checker|dependency-auditor|syntax-linter|verify]
#
# 为什么退出码恒为 0：本脚本挂在 workflow 收尾步骤（if: always()）上，它只负责“汇报”。
# 若它自己非零退出，就会覆盖掉真正的构建结论，所以任何输入缺失、命令不存在，
# 一律降级为跳过对应小节；同理这里不用 set -e。
#
# verify 是上面这条契约的唯一例外：它是**门禁**而不是汇报，判定不通过就以非 0 退出，
# 好让排在它后面的 release / deploy 被跳过；因此它必须放在发布之前，不能挂在收尾步骤上。
#

# 本文件位于 scripts/ci/，目录必须自己解析：调用方可能从任意 cwd 调用。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# log_* 全仓库只有这一份实现，不在这里另造（重复定义会撞上 logger 的 readonly 常量）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# 摘要只读日志、不写日志：它一写就会在 logs/ 里多出一份"最新"的文件，
# 而它正是挑"哪份日志属于本次构建"的那个读者——自己制造候选、再去匹配自己，是上一轮的 bug 根源。
LOG_TO_FILE=false

# 溯源块的唯一实现在 scripts/ci/summary-provenance.sh：同一份数据还要被校验脚本读取，
# 在这里再算一遍就必然出现"块里 3 个文件、校验脚本算出 4 个"的分歧——分歧的后果是
# 校验误报而不是功能故障，最难排查，所以计算与渲染都只放在那一处。
# source 失败只降级：摘要照常输出，只是少了溯源小节；本脚本"退出码恒为 0"的契约优先。
SUMMARY_PROVENANCE_SH="${SCRIPT_DIR}/summary-provenance.sh"
PROVENANCE_AVAILABLE=false
# shellcheck source=scripts/ci/summary-provenance.sh
if source "${SUMMARY_PROVENANCE_SH}" 2>/dev/null; then
  PROVENANCE_AVAILABLE=true
else
  log_warning "无法加载 ${SUMMARY_PROVENANCE_SH}，本次摘要不含溯源块"
fi

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
# 摘录出自哪一步：文件名（ERROR_LOG_NAME）只说得出"哪份"，说不出"哪步"，
# 两者都进摘要，读者才不用回 artifact 里猜。
ERROR_LOG_SOURCE=""
ERROR_EXCERPT=""
ERROR_NOTE=""

# Markdown 表格里的 "|" 会提前断列、换行会拆行：统一压平再转义。
md_cell() {
  printf '%s' "${1}" | tr '\n' ' ' | sed 's/|/\\|/g'
}

# 步骤结果的可读映射；空值代表该步骤因前序失败/取消而根本没执行。
step_badge() {
  case "${1}" in
    success) printf '✅ 成功' ;;
    failure) printf '❌ 失败' ;;
    cancelled) printf '✖ 已取消' ;;
    skipped) printf '⏭ 跳过' ;;
    "") printf '⚪ 未执行' ;;
    *) printf '❔ %s' "${1}" ;;
  esac
}

# 通用取值：把 <PREFIX><KEY> 解析成值。KEY 是给人看的（hw / env_setup / release_info），
# 但环境变量名大小写并不统一：STEP_hw 与 STEP_HW 都出现过，而 bash 变量名大小写敏感。
# 故三个候选依次试（原样 / 全大写 / 全小写），取第一个非空值；用间接取值读，不 eval。
env_value() {
  local prefix="${1}" key="${2}" cand
  for cand in "${prefix}${key}" "${prefix}${key^^}" "${prefix}${key,,}"; do
    if [[ -n "${!cand:-}" ]]; then
      printf '%s' "${!cand}"
      return 0
    fi
  done
  return 0
}

step_value() {
  env_value "STEP_" "${1}"
}

metric_value() {
  env_value "METRIC_" "${1}"
}

# shellcheck disable=SC2329  # 仅在 render_details 的命令替换里调用，静态分析看不到这层引用
detail_value() {
  env_value "DETAIL_" "${1}"
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
  case "${1}" in
    update-checker) printf '### 🔄 上游更新检查总结\n\n' ;;
    dependency-auditor) printf '### 🔍 依赖巡检总结\n\n' ;;
    syntax-linter) printf '### 🧹 语法与规范门禁总结\n\n' ;;
    *) printf '### 🏗️ ImmortalWrt BPI-R4 构建总结\n\n' ;;
  esac
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
    meta_row "工作流" "${GITHUB_WORKFLOW:-}"
    meta_row "任务" "${GITHUB_JOB:-}"
    meta_row "事件" "${GITHUB_EVENT_NAME:-}"
    meta_row "分支" "${GITHUB_REF_NAME:-}"
    meta_row "提交" "${commit}"
    meta_row "触发人" "${GITHUB_ACTOR:-}"
    meta_row "运行器" "${RUNNER_OS:-}"
    meta_row "运行次数" "${GITHUB_RUN_ATTEMPT:-}"
  )"
  [[ -n "${rows}" ]] || return 0
  printf '#### 运行信息\n\n| 项 | 值 |\n| --- | --- |\n%s\n\n' "${rows}"
}

render_steps() {
  # 本地跑（build.sh all -> 自动生成摘要）没有 CI 注入的 STEP_SEQUENCE，但"步骤状态"是
  # 正文必备小节（校验脚本 P11 靠它判断摘要是否完整）。整节不输出，就等于本地产出的摘要
  # 永远过不了 CI 门禁，所以这里改成【诚实的占位】：标题与表头照出，正文只留一行"未执行"。
  #
  # 为什么不写成"成功"或干脆省略整行：摘要的用途是给判断提供依据，占位行必须让读者
  # 一眼看出"这台机器上没有 CI 步骤可报"，而不是"这些步骤都跑过了"。
  # 结果列复用 step_badge 的空值映射（⚪ 未执行），语义与"因前序失败而没跑"的步骤同一套，
  # 不再另造一个词，读者不必学第二套记号。
  if [[ -z "${STEP_SEQUENCE:-}" ]]; then
    printf '#### 步骤状态\n\n| 步骤 | 结果 |\n| --- | --- |\n'
    printf '| %s | %s |\n\n' '（本地运行，无 CI 步骤信息）' "$(step_badge "")"
    return 0
  fi
  printf '#### 步骤状态\n\n| 步骤 | 结果 |\n| --- | --- |\n'
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

# 日志文件名里能出现的步骤段 → 它能再往上对应到的 workflow 步骤。
# 为什么需要这一跳：workflow 步骤叫 "Build firmware"，而日志文件叫 build-compile.log，
# 名字是脚本名而不是步骤名，词面对不上，读者只能靠猜。
log_step_source() {
  # 入参是完整日志文件名（build-compile-verbose.log）：前缀与扩展名在这层剥掉，
  # 调用方不必各自记着该切哪一段。
  local step="${1:-}"
  step="${step%.log}"
  case "${step}" in
    build-compile-verbose) printf 'Workflow 步骤 Build firmware（V=s 重试）' ;;
    build-compile-single) printf 'Workflow 步骤 Build firmware（单线程重试）' ;;
    build-compile-parallel) printf 'Workflow 步骤 Build firmware（并行）' ;;
    build-deps) printf 'Workflow 步骤 Install build dependencies' ;;
    build-prepare) printf 'Workflow 步骤 Prepare build workspace' ;;
    build-download) printf 'Workflow 步骤 Build firmware（下载阶段）' ;;
    build-check) printf 'Workflow 步骤 Report firmware size' ;;
    build-compile) printf 'Workflow 步骤 Build firmware' ;;
    build-all) printf 'Workflow 步骤 Build firmware（含体积统计）' ;;
    build-generate-release-info) printf 'Workflow 步骤 ImmortalWrt AutoUpdate' ;;
    build-generate-release-notes) printf 'Workflow 步骤 Generate release tag' ;;
    *) printf '未登记命名的日志（%s）' "${1:-}" ;;
  esac
}

# logs/ 里实际有哪些日志、各自属于哪一步：整包上传的 artifact 交给人之前，
# 先在这里把"文件名 → 步骤"的对照摊开，省得逐个下载再翻。
render_logs() {
  # 与耗时同理：update-checker 的 job 不产出构建日志，本地预览时若渲染，
  # 就会把仓库里残留的上一次构建日志当成这次的事实。
  [[ "${1}" == "build" ]] || return 0
  local dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
  [[ -d "${dir}" ]] || return 0
  # artifact 是整包上传的 logs/，所以这里按目录实际内容列，而不是照抄候选全集：
  # 读者要的是"这次运行真的产出了哪几个文件"，不是"理论上能有哪几个"。
  local base tick listed=0
  # 反引号用 \x60 生成：直接写会被 shellcheck 当成命令替换（SC2006）。
  tick="$(printf '\x60')"
  local -a rows=()
  # 用数组收集再一次性 join，不要 loop 里写 "x+=\"${base} \""：
  # 那样每个文件名都带一个尾随空格，最后一个的会留在行尾——
  # 写进 Markdown 就是一个真实的 MD009（尾随空格），下游 markdownlint 会直接报错。
  local -a unexpected_names=()
  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    if is_catalog_log "${base}"; then
      rows+=("| ${tick}${base}${tick} | $(md_cell "$(log_step_source "${base}" | sed 's/^Workflow 步骤 //')") |")
      listed=1
    else
      unexpected_names+=("${base}")
    fi
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.log' -printf '%f\n' 2>/dev/null | sort)
  local unexpected=""
  ((${#unexpected_names[@]} > 0)) && unexpected="${unexpected_names[*]}"
  [[ "${listed}" == "1" || -n "${unexpected}" ]] || return 0
  printf '#### 日志文件\n\n'
  if [[ "${listed}" == "1" ]]; then
    printf '| 日志文件 | 所属步骤 |\n| --- | --- |\n'
    printf '%s\n' "${rows[@]}"
  fi
  if [[ -n "${unexpected}" ]]; then
    [[ "${listed}" == "1" ]] && printf '\n'
    printf '未按约定命名、因此不会被摘要引用：%s\n' "$(md_cell "${unexpected}")"
  fi
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

# 软件包清单：回答「这次到底编了哪些包、装进固件的又是哪些」。
#
# 两个数据源刻意分开，语义不同，混成一个清单会误导读者：
#   · immortalwrt/bin/targets/<board>/<sub>/<device>.manifest
#       装进**固件镜像内**的包（运行时就有的）。格式是 `包名 - 版本`，每行一条。
#   · immortalwrt/bin/packages/<arch>/*/index.json 与
#     immortalwrt/bin/targets/<board>/<sub>/packages/index.json
#       **本次编译产出**的 .apk 包（=m 的包在这里但不在 manifest 里，需按需安装）。
#       两处都要收：前者是 target 无关的 feed（base / packages / luci / routing…），
#       后者是 target 专属包（kmod-*、target 特化的内核模块与库）。只扫前者会漏掉
#       上百个 kmod 并误报「未编译」——实测本机 225 vs 155。
#       格式是 {"packages": {包名: 版本}}，比解析 `包名-版本-rN.apk` 文件名可靠——
#       包名本身含连字符、版本含 ~ 与 -rN，靠正则拆分必然出错（如 dae-geosite-2.0.0-r1）。
#
# 全部只读 bin/ 下已有的元数据，不需要 apk/opkg 命令，因此本地与 CI 行为一致。
readonly MANIFEST_GLOB_PATTERN="immortalwrt/bin/targets/*/*/*.manifest"
readonly PACKAGE_INDEX_GLOB_PATTERN="immortalwrt/bin/packages/*/*/index.json"
readonly TARGET_PACKAGE_INDEX_GLOB_PATTERN="immortalwrt/bin/targets/*/*/packages/index.json"
# target 专属包的索引在 CI 里会**先被删掉再被统计**：Organize files 为缩小 firmware artifact
# 执行 rm -rf packages，而 Run summary 排在它之后。那个目录里的 index.json 是「154 个
# kmod / target 包确实产出过」的唯一证据，删掉即等同一律判成未产出（实测 153 条假报）。
# 因此 workflow 的 organize 步骤在删除前把它快照到 $RUNNER_TEMP，用这个变量把路径传进来。
# 本地跑没有该变量、目录也还在，此时照旧走 glob —— 两种情形都只有一份真相来源。
TARGET_PACKAGE_INDEX_FILE="${TARGET_PACKAGE_INDEX_FILE:-}"
# 编译前的包选择：.config 里 CONFIG_PACKAGE_<名>=y|m 的才算「本应编译」。
readonly CONFIG_FILE="immortalwrt/.config"
# 仓库根 .config：作者手写的输入配置（构建时被 cp 进 immortalwrt/.config 再 defconfig 展开）。
# verify 模式的「静默丢弃」校验以它为基准——只有它能回答“作者本来要什么”。
readonly REPO_CONFIG_FILE=".config"

# 从 manifest 取「装进固件」的包名（只取名字，版本不参与去重）。
manifest_packages() {
  local -a files=()
  local file
  # shellcheck disable=SC2207  # manifest 路径由只读 glob 展开，含空格的可能性不成立
  files=($(compgen -G "${MANIFEST_GLOB_PATTERN}" 2>/dev/null || true))
  [[ ${#files[@]} -gt 0 ]] || return 0
  for file in "${files[@]}"; do
    # 行格式 `包名 - 版本`：取第一个字段即包名；空行与不含 " - " 的异常行跳过。
    awk 'NF >= 3 && $2 == "-" { print $1 }' "${file}" 2>/dev/null
  done | sort -u
}

# 从各 feed 的 index.json 取「本次编译产出」的包名。
# 用 python3 解析 JSON 而不是正则：index.json 是机器格式，正则会在转义与嵌套上出错。
# python3 是上游构建的硬依赖（prereq-build.mk 要求 >= 3.8），构建机上必然存在。
package_index_available() {
  command -v python3 >/dev/null 2>&1
}

# 把一个索引 glob 解析成实际文件列表，并补上 target 索引的快照文件。
#
# 为什么单独一层：target 专属索引有两份可能的存在形态——
#   · 目录还在       -> glob 命中 immortalwrt/bin/targets/*/*/packages/index.json
#   · 目录已被删除   -> 只剩 workflow 提前快照的 $TARGET_PACKAGE_INDEX_FILE（CI 的常态）
# 二者对「编译产出」是同一份事实，谁在就用谁；CI 里 glob 必然落空，只有快照可用。
#
# 只在模式等于 target glob 时并入快照：否则 feed 那一列也会把 target 的包算进来，
# 表格里「bin feed / bin target」分列展示就失去意义（两列会变成同一个并集）。
index_files_for() {
  local pattern="${1:-}"
  [[ -n "${pattern}" ]] || return 0
  compgen -G "${pattern}" 2>/dev/null || true
  if [[ "${pattern}" == "${TARGET_PACKAGE_INDEX_GLOB_PATTERN}" && -n "${TARGET_PACKAGE_INDEX_FILE}" ]]; then
    [[ -f "${TARGET_PACKAGE_INDEX_FILE}" ]] && printf '%s\n' "${TARGET_PACKAGE_INDEX_FILE}"
  fi
  return 0
}

# 按来源统计编译产出。
#   无参数  -> feed + target 并集，即"这次到底编出了多少 .apk"（编译验证用的分母）
#   带参数  -> 只统计指定 glob 的来源，供表格分开展示
built_packages() {
  package_index_available || return 0
  local -a files=()
  local file
  if [[ $# -gt 0 ]]; then
    # shellcheck disable=SC2207  # 路径由只读 glob 展开，含空格的可能性不成立
    files=($(index_files_for "${1}"))
  else
    # 两处索引都要收：feed（target 无关）与 targets/*/*/packages（target 专属 kmod）。
    # shellcheck disable=SC2207
    files=($(index_files_for "${PACKAGE_INDEX_GLOB_PATTERN}")
           $(index_files_for "${TARGET_PACKAGE_INDEX_GLOB_PATTERN}"))
  fi
  [[ ${#files[@]} -gt 0 ]] || return 0
  python3 - "${files[@]}" <<'PY' 2>/dev/null
import json
import sys

names = set()
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        # 单个 feed 的索引坏了不该让整张小节消失：其余 feed 照常统计。
        continue
    pkgs = data.get("packages")
    if isinstance(pkgs, dict):
        names.update(pkgs)
    elif isinstance(pkgs, list):
        # 兼容旧格式：[{"name": ...}, ...]
        for item in pkgs:
            if isinstance(item, dict) and item.get("name"):
                names.add(item["name"])
for name in sorted(names):
    print(name)
PY
}

# 编译验证的核心：把「本应编译的包」与「真的产出 .apk 的包」做集合差。
#
# 三条关键判定（每一条都有实测依据，改之前先看注释）：
#
# 1) 只有 CONFIG_PACKAGE_<名>=y|m 才算「本应编译」的软件包。.config 里同一个前缀下还混着
#    两类**非独立包**的选择项，把它们算进去会让「未编译」永远不为 0：
#      · 变体开关 *_INCLUDE_*（luci-app-passwall_INCLUDE_Xray）——决定主包编不编某个功能；
#      · 全大写符号（MAC80211_MESH / TAR_GZIP / dnsmasq_full_dnssec）——kconfig 的 bool 子选项，
#        产物并进主包（dnsmasq_full_* 全部并入 dnsmasq-full）。
#
# 2) 「编译产出」必须同时收 feed 索引与 target 索引。只收 feed 会把上百个 kmod 误判成未编译
#    （实测本机 feed 225、target 155，kmod-ipt-core 只在 targets/.../packages 下）。
#
# 3) u-boot / trusted-firmware 的产物是 .bin/.fip 而非 .apk，但它们确实是编译产物。
#    判据改成「该名出现在 targets 目录的文件名里」即可，不强行套 .apk 口径。
#
# 只统计不判定成败：本脚本的职责是「报告」，未编译的包可能是有意精简配置的结果，
# 让摘要红掉等于把配置决策当成构建故障。真正的构建成败由上一步的 make 决定。
selection_packages() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  # 行格式 CONFIG_PACKAGE_<名>=y|m；只取 =y/=m，排除 "is not set" 与 =n。
  sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_.+-]*\)=[ym]$/\1/p' "${CONFIG_FILE}" | sort -u
}

# 未生效的变体开关：形如 <基包>_<开关>，但**宿主包本身没被选中**的项。
#
# 这是配置层面的现象，不是编译问题，所以单独报而不是混进「未产出」：
# 典型例子 knot-resolver_dnstap=y —— 它是 knot-resolver 的编译开关
# （feeds/packages/net/knot-resolver/Config.in 里 config PACKAGE_knot-resolver_dnstap），
# 而 .config 里**连宿主包一行都没有**（连 "is not set" 都没留下），宿主没参与构建，
# 开关即便为 y 也不会产生任何效果。
#
# 成因已实测确认，**不要写成"配置残留"**：
# 该 Config.in 写的是 `default y` 且无 depends 约束，因此从干净的根 .config 跑
# `make defconfig` 就会自动生成这一行（实测复现）；手工置为 n 后 defconfig 也保持 n，
# 说明它并非"被反复拉回 y"。结论：它不是残留，defconfig 也清不掉，无需建议用户清理。
#
# 判定必须收敛，否则误报一大片（实测全量扫会捞出 25 条，其中真正有问题的只有 1 条）：
#   · 纯大写符号（TAR_GZIP / MAC80211_MESH）——kconfig bool 子选项，产物并进主包，不是变体开关；
#   · *_INCLUDE_*（luci-app-passwall_INCLUDE_Xray）——包内功能开关，基包另有其名；
#   · u-boot-* / trusted-firmware-a-*——名字里的下划线是板名分隔符，不是「基包_开关」结构。
# 只用「基包确实在 package 树里有定义、而它自己没被选中」这一条来收口。
# 基包在 package 树里是否有 `define Package/<名>`。
# 用一个「首次调用时建」的缓存文件，避免对上千个 Makefile 反复 grep：
#   每个候选都 grep 一遍全树的话，孤立检测会从毫秒级变成几十秒。
_PKG_DEF_CACHE=""
_pkg_defined() {
  local name="${1:-}"
  [[ -n "${name}" ]] || return 1
  if [[ -z "${_PKG_DEF_CACHE}" || ! -f "${_PKG_DEF_CACHE}" ]]; then
    _PKG_DEF_CACHE="$(mktemp 2>/dev/null)" || { _PKG_DEF_CACHE=""; return 1; }
    # 一次扫全树，把所有 define Package/<名> 的名字摊进缓存。
    # 目录不存在时留空文件，后续查询一律判否，不会重复扫。
    grep -rhoE 'define[[:space:]]+Package/[A-Za-z0-9_.+-]+' \
      immortalwrt/package immortalwrt/feeds 2>/dev/null |
      sed 's|.*Package/||' | sort -u >"${_PKG_DEF_CACHE}"
  fi
  grep -qxF -- "${name}" "${_PKG_DEF_CACHE}" 2>/dev/null
}

orphan_variants() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  local sel
  sel="$(selection_packages)"
  [[ -n "${sel}" ]] || return 0
  printf '%s\n' "${sel}" | while IFS= read -r name; do
    case "${name}" in
      u-boot-* | trusted-firmware-a-* | *_INCLUDE_*) continue ;;
    esac
    [[ "${name}" == *_* ]] || continue
    # 纯大写符号（TAR_GZIP / MAC80211_MESH）是 kconfig bool 子选项，产物并进主包，
    # 不是「基包_开关」结构。与 planned_packages 的排除规则保持一致。
    [[ "${name}" == *[a-z]* ]] || continue
    # 基包候选：去掉最后一段，并把剩余下划线换成连字符（与变体归一化同规则）。
    local base="${name%_*}"
    local base_dash="${base//_/-}"
    # 基包未被选中才算孤立；已被选中的变体会在计划集合里归一化掉，这里不重复报。
    grep -qxF -- "${base}" <<<"${sel}" && continue
    grep -qxF -- "${base_dash}" <<<"${sel}" && continue
    # 基包必须在 package 树里确有 `define Package/<基包>`，否则只是个恰好带下划线的
    # 普通包名（如 foo_bar），不该被当成「变体开关丢了宿主」。
    # 用缓存文件避免对上千个 Makefile 反复 grep；没有匹配就不报。
    _pkg_defined "${base}" || _pkg_defined "${base_dash}" || continue
    printf '%s\n' "${name}"
  done | sort -u
}

# 计划编译的「独立软件包」= 选中项 - 变体开关 - 纯大写子选项。
# 变体开关（dnsmasq_full_auth / luci-lib-nixio_openssl）归一化到主包名后再参与比对：
# 去掉最后一个下划线段，并把剩下的下划线换回连字符——这是 OpenWrt 的
# PKG_CONFIG_DEPENDS 变体命名约定（实测 dnsmasq_full_auth -> dnsmasq-full、
# luci-lib-nixio_openssl -> luci-lib-nixio 均能对上产物）。
planned_packages() {
  local sel
  sel="$(selection_packages)"
  [[ -n "${sel}" ]] || return 0
  printf '%s\n' "${sel}" | grep -vE '_INCLUDE_|^[A-Z0-9_]+$' |
    while IFS= read -r name; do
      # 引导固件名里天然含下划线（u-boot-mt7988_bananapi_bpi-r4-emmc），
      # 它们**不是**变体开关，必须原样保留，否则会被误砍成 u-boot-mt7988-bananapi。
      case "${name}" in
        u-boot-* | trusted-firmware-a-*)
          printf '%s\n' "${name}"
          continue
          ;;
      esac
      # 其余含下划线的是变体开关（dnsmasq_full_auth / luci-lib-nixio_openssl）：
      # 只保留归一化后的主包名。不能把变体原名也留下——那样每个变体都会变成
      # 一条「未产出」的假报。
      if [[ "${name}" == *_* ]]; then
        printf '%s\n' "${name%_*}" | sed 's/_/-/g'
      else
        printf '%s\n' "${name}"
      fi
    done | sort -u
}

# 引导固件（u-boot-* / trusted-firmware-a-*）的产物不是 .apk，而是 .bin/.fip/.img。
#
# **两处目录都要扫**，这是本函数存在的唯一理由（实测漏掉会报 7 条假故障）：
#   · bin/targets/<board>/<sub>/       最终打包进镜像的那份（<device>-bl31-uboot.fip 等）
#   · staging_dir/*/image/             包自己 install 到 STAGING_DIR_IMAGE 的那份
# 看 arm-trusted-firmware-mediatek/Makefile 的 Package/trusted-firmware-a/install：
#     $(INSTALL_DATA) .../bl2.img  $(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-bl2.img
#     $(INSTALL_DATA) .../bl31.bin $(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-bl31.bin
# 也就是说 emmc-comb / sdmmc-comb / spim-nand-ubi-comb 这些变体的产物**只**落在 staging，
# 不进 bin/targets（那是最终镜像才有资格进的地方）。只扫 bin/ 会把它们全判成未编译。
# 引导固件产物按**来源目录**分别收集，不合并成一个集合。
#
# 两处的语义不同，合并后读者看不出产物落在哪：
#   · bin/targets/<board>/<sub>/ —— 最终打包进镜像目录的那份，会随 artifact 发布
#   · staging_dir/.../image/    —— 包 install 到 STAGING_DIR_IMAGE 的暂存中间态
# 实测本机两处各 17 个且**交集为 0**：bin 下是 <device>-bl31-uboot.fip 这类成品，
# staging 下是 <变体>-bl2.img / <变体>-bl31.bin 这类中间件。合并会让"编译验证"
# 无法回答"这个产物最终进了发布目录没有"。
boot_artifact_names_from() {
  local root="${1:-}"
  [[ -n "${root}" && -d "${root}" ]] || return 0
  find "${root}" -maxdepth 3 -type f \
    \( -name '*.bin' -o -name '*.fip' -o -name '*.itb' -o -name '*-bl2.img' \) \
    -printf '%f\n' 2>/dev/null | sort -u
}

# 发布目录（bin/targets）里的引导固件产物。
boot_artifacts_in_bin() {
  boot_artifact_names_from "immortalwrt/bin/targets"
}

# 暂存目录（staging_dir/*/image）里的引导固件产物。
boot_artifacts_in_staging() {
  local -a roots=()
  # shellcheck disable=SC2207  # 只读 glob 展开，含空格的可能性不成立
  roots=($(compgen -G "immortalwrt/staging_dir/*/image" 2>/dev/null || true))
  [[ ${#roots[@]} -gt 0 ]] || return 0
  local d
  for d in "${roots[@]}"; do
    boot_artifact_names_from "${d}"
  done | sort -u
}

# 引导固件的配置名 -> 产物名里可匹配的词干。两类的命名习惯不同，不能共用一条规则：
#
#   trusted-firmware-a-mt7988-ram-comb  -> mt7988-ram-comb
#     产物 mt7988-ram-comb-bl2.bin：剥掉类目前缀即可，SoC 型号要留着。
#
#   u-boot-mt7988_bananapi_bpi-r4-emmc   -> bananapi_bpi-r4-emmc
#     产物 ...-bananapi_bpi-r4-emmc-bl31-uboot.fip：**不含 SoC**，只有板名。
#     配置名形如 <类目>-<SoC>_<板名>，SoC 段以第一个下划线结束，板名保留下划线写法。
#
# 分隔符一律不做替换：产物里下划线与连字符是并存且各有用意的（bananapi_bpi-r4）。
boot_stem() {
  local name="${1}"
  case "${name}" in
    trusted-firmware-a-*)
      name="${name#trusted-firmware-a-}"
      ;;
    u-boot-*)
      name="${name#u-boot-}"
      # 去掉开头的 SoC 段（到第一个下划线为止），保留板名。
      name="${name#*_}"
      ;;
  esac
  printf '%s\n' "${name}"
}

# 长清单折叠进 <details>：几百个包铺开会把摘要正文淹掉，默认收起、按需展开。
# 反引号用 \x60 生成，避免围栏字面量在 shell 里被当成命令替换。
# 三连与单个分开两个函数，是因为调用点的字面量形式不同，而返回值必须是纯数据。
_fence_triple() {
  printf '\x60\x60\x60'
}

_fence_single() {
  printf '\x60'
}

# 统计一段以换行分隔的清单有多少个非空行。
_count_lines() {
  local text="${1}"
  [[ -n "${text}" ]] || {
    printf '0'
    return 0
  }
  printf '%s\n' "${text}" | grep -c .
}

# 渲染一个 <details> 折叠块（Markdown 围栏内含一段纯文本清单）。
# 只输出有内容的那一块：契约里所有输入都是可选的，缺失即整块跳过。
_render_details_block() {
  local summary="${1}"
  local count="${2}"
  local body="${3}"
  local fence
  fence="$(_fence_triple)"
  [[ -n "${body}" ]] || return 0
  printf '<details><summary>%s（%s 个）</summary>\n\n%stext\n%s\n%s\n\n</details>\n\n' \
    "${summary}" "${count}" "${fence}" "${body}" "${fence}"
}

# 统计各来源的产物数量。
# 编译产出按落盘位置分列，不合并成一个数字：两处的语义不同，合并后读者无法回答
# "最终发布目录里到底有什么"——
#   bin/...            最终产物，会随 artifact 发布
#   staging_dir/...    构建暂存中间态，不进发布包
# 实测本机 feed 227 + target 154 = bin 并集 381，而 staging 也是 381 但内容不同源。
#
# 暂存目录里的 *.apk **全是符号链接**，指向 bin/ 下的真实文件（实测 381 个链接：
# 227 -> bin/packages/<arch>/<feed>/，154 -> bin/targets/<board>/<sub>/packages/）。
# 因此 staging 必须用 -type l 统计，用 -type f 会得到 0——
# 而这恰好也说明 staging 不是"独立产物"，它只是 bin 的镜像视图。
#
# 结果写入全局（调用方在命令替换里渲染，global 才能跨过子 shell 边界）：
#   _PKG_INSTALLED_COUNT _PKG_BUILT_COUNT _PKG_PLANNED_COUNT
#   _PKG_FEED_COUNT _PKG_TARGET_COUNT _PKG_STAGING_COUNT
#   _PKG_ORPHAN_COUNT _PKG_BOOT_BIN_COUNT _PKG_BOOT_STAGING_COUNT
#   _PKG_INSTALLED _PKG_BUILT _PKG_PLANNED _PKG_ORPHANS
_PKG_INSTALLED=""
_PKG_BUILT=""
_PKG_PLANNED=""
_PKG_ORPHANS=""
_PKG_INSTALLED_COUNT=0
_PKG_BUILT_COUNT=0
_PKG_PLANNED_COUNT=0
_PKG_FEED_COUNT=0
_PKG_TARGET_COUNT=0
_PKG_STAGING_COUNT=0
_PKG_ORPHAN_COUNT=0
_PKG_BOOT_BIN_COUNT=0
_PKG_BOOT_STAGING_COUNT=0

# 收集各来源的清单与数量，供表格与折叠块共用（只算一次）。
_collect_package_counts() {
  local feed_pkgs target_pkgs

  _PKG_INSTALLED="$(manifest_packages)"
  _PKG_BUILT="$(built_packages)"
  _PKG_PLANNED="$(planned_packages)"
  _PKG_ORPHANS="$(orphan_variants)"

  _PKG_INSTALLED_COUNT="$(_count_lines "${_PKG_INSTALLED}")"
  _PKG_BUILT_COUNT="$(_count_lines "${_PKG_BUILT}")"
  _PKG_PLANNED_COUNT="$(_count_lines "${_PKG_PLANNED}")"
  _PKG_ORPHAN_COUNT="$(_count_lines "${_PKG_ORPHANS}")"

  feed_pkgs="$(built_packages "${PACKAGE_INDEX_GLOB_PATTERN}")"
  target_pkgs="$(built_packages "${TARGET_PACKAGE_INDEX_GLOB_PATTERN}")"
  _PKG_FEED_COUNT="$(_count_lines "${feed_pkgs}")"
  _PKG_TARGET_COUNT="$(_count_lines "${target_pkgs}")"

  # staging 是构建中间态，没有 index.json，按 .apk 文件数统计（见上方 -type l 说明）。
  _PKG_STAGING_COUNT="$(find immortalwrt/staging_dir/packages -maxdepth 2 -name '*.apk' -type l 2>/dev/null | wc -l)"

  # 引导固件单独成行：它不走 .apk 口径，且两处目录里的内容**并不相同**
  # （实测本机各 17 个、交集为 0），合并显示会让人误以为是同一批被数了两遍。
  _PKG_BOOT_BIN_COUNT="$(boot_artifacts_in_bin | grep -c . || true)"
  _PKG_BOOT_STAGING_COUNT="$(boot_artifacts_in_staging | grep -c . || true)"
}

# 渲染「软件包」小节的表格部分。
_render_package_table() {
  printf '#### 软件包\n\n'
  # 表格后必须空一行，否则紧跟的段落会被 Markdown 当成表格续行。
  printf '| 类别 | 数量 | 说明 |\n| --- | --- | --- |\n'
  printf '| 装进固件 | %s | 镜像内自带，开机即有 |\n' "${_PKG_INSTALLED_COUNT}"
  # 编译产出按目录分列：三行各自独立，不做加减关系，读者一眼看出产物落在哪。
  # 尖括号占位符会被 shellcheck 判成重定向（SC2016/SC2086），改用 [-]- 风格。
  printf '| 编译产出 · bin feed | %s | bin/packages/ 下按架构与 feed 分组，最终发布产物 |\n' "${_PKG_FEED_COUNT}"
  printf '| 编译产出 · bin target | %s | bin/targets/ 下 target 专属包（kmod 等），同为发布产物 |\n' "${_PKG_TARGET_COUNT}"
  printf '| 暂存 · staging_dir | %s | 均为指向 bin/ 的符号链接，不是独立产物 |\n' "${_PKG_STAGING_COUNT}"
  if [[ ${_PKG_BOOT_BIN_COUNT} -gt 0 || ${_PKG_BOOT_STAGING_COUNT} -gt 0 ]]; then
    printf '| 引导固件 · bin | %s | 已进发布目录的 .bin/.fip（成品） |\n' "${_PKG_BOOT_BIN_COUNT}"
    printf '| 引导固件 · staging | %s | 暂存目录里的 .bin/.fip（中间件，与上者内容不同） |\n' "${_PKG_BOOT_STAGING_COUNT}"
  fi
  if [[ ${_PKG_ORPHAN_COUNT} -gt 0 ]]; then
    printf '| 未生效的变体开关 | %s | 开关自身有值，但宿主包未被选中，合入固件后不会生效 |\n' "${_PKG_ORPHAN_COUNT}"
  fi
}

# 把「计划清单」切成「普通包」与「引导固件」两组，结果写入调用方传入的两个数组名。
#   $1 计划清单文本  $2 普通包数组名  $3 引导固件数组名
_split_planned_by_kind() {
  local planned="${1}"
  local -n pkg_out="$2"
  local -n boot_out="$3"
  local name

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    case "${name}" in
      u-boot-* | trusted-firmware-a-*) boot_out+=("${name}") ;;
      *) pkg_out+=("${name}") ;;
    esac
  done <<<"${planned}"
}

# 把未生效变体开关归一化成可能对应的宿主包名（原名 + 下划线换连字符两种写法）。
# 未生效开关的宿主包要先从「未产出」里剔掉：它已经在「未生效的变体开关」那一行
# 单独报过，若这里再报一次，同一件事会在摘要里出现两遍（归一化后的基包名 + 原始开关名），
# 读者会误以为有两个问题。
_orphan_base_names() {
  local orphans="${1}"
  local ov

  while IFS= read -r ov; do
    [[ -n "${ov}" ]] || continue
    printf '%s\n' "${ov%_*}"
    printf '%s' "${ov%_*}" | sed 's/_/-/g'
    printf '\n'
  done <<<"${orphans}"
}

# 计算「选中但未产出 .apk」的普通包清单。
# comm 的两侧必须是**已排序的集合流**。这里把「已产出」与「孤立基包」并成一个排除集合，
# 再一次性做差——注意不能写成 sort -u "${built}" file：built 是字符串不是文件名，
# sort 会把它当路径读并失败，结果整列被当成「未产出」（实测 380 条假报）。
_missing_plain_packages() {
  local -a pkg_planned=("$@")
  local -a orphan_bases=()
  local orphans="${_PKG_ORPHANS}"

  if [[ -n "${orphans}" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "${line}" ]] && orphan_bases+=("${line}")
    done < <(_orphan_base_names "${orphans}")
  fi

  if [[ ${#orphan_bases[@]} -gt 0 ]]; then
    comm -23 <(printf '%s\n' "${pkg_planned[@]}" | sort -u) \
      <(printf '%s\n' "${_PKG_BUILT}" "${orphan_bases[@]}" | sort -u) 2>/dev/null
  else
    comm -23 <(printf '%s\n' "${pkg_planned[@]}" | sort -u) \
      <(printf '%s\n' "${_PKG_BUILT}" | sort -u) 2>/dev/null
  fi
}

# 引导固件：产物文件名里是否含该配置名的词干。
# 分别判定落入 bin（发布目录）与 staging（暂存目录），不合并——
# 只落在 staging 的产物说明它还没进发布目录，这是读者需要知道的事实。
# 返回：0 至少一处命中；1 两处都没有（该变体未产出）
_boot_variant_present() {
  local boot="${1}"
  local stem art
  stem="$(boot_stem "${boot}")"

  if [[ ${#BOOT_ARTS_BIN[@]} -gt 0 ]]; then
    for art in "${BOOT_ARTS_BIN[@]}"; do
      [[ "${art}" == *"${stem}"* ]] && return 0
    done
  fi
  if [[ ${#BOOT_ARTS_STAGING[@]} -gt 0 ]]; then
    for art in "${BOOT_ARTS_STAGING[@]}"; do
      [[ "${art}" == *"${stem}"* ]] && return 0
    done
  fi
  return 1
}

# 编译验证的核心：把「本应编译的包」与「真的产出产物的包」做集合差。
#
# 三条关键判定（每一条都有实测依据，改之前先看注释）：
#
# 1) 只有 CONFIG_PACKAGE_<名>=y|m 才算「本应编译」的软件包（见 selection_packages）。
# 2) 「编译产出」必须同时收 feed 索引与 target 索引。只收 feed 会把上百个 kmod 误判成未编译
#    （实测本机 feed 225、target 155，kmod-ipt-core 只在 targets/.../packages 下）。
# 3) u-boot / trusted-firmware 的产物是 .bin/.fip 而非 .apk，但它们确实是编译产物。
#    判据改成「该名出现在 targets 目录的文件名里」即可，不强行套 .apk 口径。
#    把引导固件硬塞进 .apk 口径会永远报「未产出」——实测 16 条假报全部来自这里。
#
# 只统计不判定成败：本脚本的职责是「报告」，未编译的包可能是有意精简配置的结果，
# 让摘要红掉等于把配置决策当成构建故障。真正的构建成败由上一步的 make 决定。
#
# 结果写入全局：_PKG_MISSING_TEXT（含引导固件的完整未产出清单，供折叠块用）
#               _PKG_MISSING_COUNT _PKG_VERDICT
_PKG_MISSING_TEXT=""
_PKG_MISSING_COUNT=0
_PKG_VERDICT=""

# 引导固件产物清单：两处分别收集，引导固件可能只落在其中一处，位置本身就是信息。
BOOT_ARTS_BIN=()
BOOT_ARTS_STAGING=()

# 计算编译验证的结果行与未产出清单（写入 _PKG_VERDICT / _PKG_MISSING_TEXT）。
_compute_verification() {
  local -a pkg_planned=() boot_planned=()
  local missing_text="" boot_text=""
  local missing_count=0 boot_count=0

  _PKG_MISSING_TEXT=""
  _PKG_MISSING_COUNT=0
  _PKG_VERDICT=""

  # 没有真的读到 .config 时就谈不上「应编多少」，否则不臆造分母。
  [[ ${_PKG_PLANNED_COUNT} -gt 0 ]] || return 0

  # shellcheck disable=SC2207
  BOOT_ARTS_BIN=($(boot_artifacts_in_bin))
  # shellcheck disable=SC2207
  BOOT_ARTS_STAGING=($(boot_artifacts_in_staging))

  _split_planned_by_kind "${_PKG_PLANNED}" pkg_planned boot_planned

  if [[ ${#pkg_planned[@]} -gt 0 ]]; then
    missing_text="$(_missing_plain_packages "${pkg_planned[@]}")"
    missing_count="$(_count_lines "${missing_text}")"
  fi

  local boot
  for boot in "${boot_planned[@]}"; do
    if ! _boot_variant_present "${boot}"; then
      boot_text+="${boot}"$'\n'
      boot_count=$((boot_count + 1))
    fi
  done

  local total=${_PKG_PLANNED_COUNT}
  if [[ $((missing_count + boot_count)) -eq 0 ]]; then
    _PKG_VERDICT="✅ 全部成功（${total} 个均产出产物）"
  else
    _PKG_VERDICT="⚠️ $((missing_count + boot_count)) 个未产出（详见下方折叠块）"
  fi

  # 两类未产出合成一份清单，供下方折叠块使用；引导固件标注出来以免与包混淆。
  if [[ -n "${boot_text}" ]]; then
    local boot_ok_text
    boot_ok_text="$(printf '%s' "${boot_text}" | sed '/^$/d; s/$/（引导固件，产物为 .bin\/.fip）/')"
    if [[ -n "${missing_text}" ]]; then
      missing_text="${missing_text}"$'\n'"${boot_ok_text}"
    else
      missing_text="${boot_ok_text}"
    fi
    missing_count=$((missing_count + boot_count))
  fi

  _PKG_MISSING_TEXT="${missing_text}"
  _PKG_MISSING_COUNT="${missing_count}"
}

# 渲染「编译验证」那一行。
_render_verification_row() {
  [[ -n "${_PKG_VERDICT}" ]] || return 0
  local checked=$((_PKG_PLANNED_COUNT - _PKG_MISSING_COUNT))
  printf '| 编译验证 | %s / %s | %s |\n' "${checked}" "${_PKG_PLANNED_COUNT}" "${_PKG_VERDICT}"
}

# 未生效变体开关的说明文字。
# 这类项不是编译失败，也不是"配置残留"——实测从干净的根 .config 跑 make defconfig
# 就会**自动生成**它们，因为对应的 Config.in 写了 default y（且无 depends 约束）。
# 因此不能给"重新 defconfig 即可消失"这种错误建议：defconfig 只会把它再生成一遍。
_render_orphan_note() {
  local tick
  tick="$(_fence_single)"
  printf '%s\n' "以上开关的宿主包未被选中，因此开关虽然为 y，合入固件后并不生效。"
  printf '%s\n' "它们由对应的 ${tick}Config.in${tick} 里 ${tick}default y${tick} 自动生成，${tick}make defconfig${tick} 会再次产生，不是残留、无需清理。"
  printf '%s\n\n' "若确实要启用，选中宿主包即可；若要彻底消除该行，只能在 ${tick}Config.in${tick} 里去掉默认值。"
}

# 渲染「软件包」小节的折叠清单。
_render_package_details() {
  _render_details_block "装进固件的包" "${_PKG_INSTALLED_COUNT}" "${_PKG_INSTALLED}"
  _render_details_block "编译产出的包" "${_PKG_BUILT_COUNT}" "${_PKG_BUILT}"
  _render_details_block "选中但未产出产物的项" "${_PKG_MISSING_COUNT}" "${_PKG_MISSING_TEXT}"
  if [[ ${_PKG_ORPHAN_COUNT} -gt 0 ]]; then
    _render_details_block "未生效的变体开关" "${_PKG_ORPHAN_COUNT}" "${_PKG_ORPHANS}"
    _render_orphan_note
  fi
}

# 渲染「软件包」小节：表格 + 编译验证 + 折叠清单。
# 三者都空说明这次没跑编译（或产物已清理），不是故障，静默跳过。
render_package_section() {
  _collect_package_counts

  if [[ -z "${_PKG_INSTALLED}" && -z "${_PKG_BUILT}" && -z "${_PKG_PLANNED}" ]]; then
    return 0
  fi

  _render_package_table
  _compute_verification
  _render_verification_row
  printf '\n'
  _render_package_details
}

# ===== verify 模式：编译产出的门禁（唯一会判失败的模式）=====
#
# 为什么单独开一个模式，而不是让 build 模式非零退出：
#   build 挂在 workflow 收尾（if: always() + continue-on-error: true），契约是「汇报」，
#   非零退出一旦生效就只会盖掉真正的构建结论；而门禁必须排在 Generate release tag
#   **之前**独立执行，才有机会拦住一次不完整的发布。判定与渲染因此分开：
#   build 只渲染，verify 只判定。
#
# 判定三项，任一不过即非零退出。前两项用自己的 == 应编 - 产出 == 口径，后两项是两份配置的比对：
#   1) 编译验证：immortalwrt/.config 里 =y|=m 的包减去实际产物（复用 _compute_verification）。
#   2) 静默丢弃：仓库根 .config 选中的符号，在 immortalwrt/.config 里连「is not set」都没有。
#      那不是「配置有意精简」，而是符号/feed 缺失导致的选择被无声丢掉，必须拦住。
#   3) 明确关闭被打开：仓库根 .config 用 "is not set" 关掉的符号，在 immortalwrt/.config 里变成
#      =y|=m。关掉往往是有理由的（dropbear / uhttpd 这类必须不留的组件），被 defconfig 悄悄打开
#      必须拦住——它与第 2 项方向相反，所以只能分开算，不能并进同一个集合。
#
# 三项都 fail-closed：读不到配置、产物索引不可用一律判失败——
# 「无法证明零漏编」与「确实漏编」在门禁上必须同结论，否则没验证过的一轮就能靠 0 蒙过去。

# 静默丢弃校验的开关；缺省开。要关掉得显式写 false，默认值不给逃避空间。
VERIFY_CONFIG_SYMBOLS="${VERIFY_CONFIG_SYMBOLS:-true}"

# 按 kconfig 语义解析 .config 的包符号。三种写法的口径必须分开，混起来必然误判：
#   CONFIG_PACKAGE_x=y|m             -> 选中
#   "# CONFIG_PACKAGE_x is not set"  -> 显式关闭（# 后**有**空格）
#   "#CONFIG_PACKAGE_x=y"            -> 普通注释（# 后无空格）：kconfig 完全忽略这一行，
#                                       既不算选中也不算关闭，门禁不得因此报错或漏报
# 「最后写者胜」也是 kconfig 的真实规则：同一符号只认最后一次赋值，所以顺序扫描、同名覆盖即可，
# 不能按「出现即算」——同一符号先 =y 后 "is not set" 时，结论必须是不选。
#   $1 配置文件  $2 selected=取 =y|=m；disabled=取显式关闭；all=出现过的全部符号
_kconfig_scan() {
  local file="${1:-}"
  local want="${2:-all}"
  [[ -f "${file}" ]] || return 0
  awk -v want="${want}" '
    /^CONFIG_PACKAGE_[A-Za-z0-9_.+-]+=/ {
      name = $0
      sub(/^CONFIG_PACKAGE_/, "", name)
      sub(/=.*$/, "", name)
      value[name] = substr($0, index($0, "=") + 1)
      next
    }
    /^# CONFIG_PACKAGE_[A-Za-z0-9_.+-]+ is not set$/ {
      name = $0
      sub(/^# CONFIG_PACKAGE_/, "", name)
      sub(/ is not set$/, "", name)
      value[name] = "n"
      next
    }
    END {
      for (name in value) {
        if (want == "selected") {
          if (value[name] == "y" || value[name] == "m") print name
        } else if (want == "disabled") {
          if (value[name] == "n") print name
        } else {
          print name
        }
      }
    }
  ' "${file}" | sort -u
}

# 应编符号（=y|=m，同名后写者胜）。
kconfig_selected_packages() {
  _kconfig_scan "${1:-}" selected
}

# 显式关闭的符号（"# CONFIG_PACKAGE_x is not set"，同样后写者胜）。
# 用户把它关掉往往是有理由的（dropbear / uhttpd 这类必须不留的组件），
# 所以「关掉的又被 defconfig 打开」必须单独成一项判定，不能并进选中集去看。
kconfig_disabled_packages() {
  _kconfig_scan "${1:-}" disabled
}

# 出现过的全部符号：连「is not set」也算「符号在场」——它证明 kconfig 认得这个符号，
# 只是没选；与「符号根本不存在」是两件事，后者才是要拦的静默丢弃。
kconfig_mentioned_symbols() {
  _kconfig_scan "${1:-}" all
}

# 写 $GITHUB_OUTPUT 供 workflow 使用。值是单行契约，清单用逗号压平；
# 没有该变量时静默跳过，本地跑不产生副作用。
# 三个分项各出一个键，好让读的人一眼看出「两份配置都查了」，而不是只拿到一个总数；
# missing_count 仍是三项之和，保持与既有消费方一致。
_verify_emit_output() {
  local ok="${1}" artifact="${2}" silent="${3}" reopened="${4}" list="${5}"
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  {
    printf 'packages_ok=%s\n' "${ok}"
    printf 'missing_count=%s\n' "$((artifact + silent + reopened))"
    printf 'missing_packages=%s\n' "${list}"
    printf 'artifact_missing_count=%s\n' "${artifact}"
    printf 'silent_drop_count=%s\n' "${silent}"
    printf 'reopened_count=%s\n' "${reopened}"
  } >>"${GITHUB_OUTPUT}" 2>/dev/null || log_warning "无法写入 GITHUB_OUTPUT，门禁结论仅在日志里"
  return 0
}

# 门禁结论同时写进运行页：失败信息只留在日志里，读者要先点开才知道红在哪。
_verify_emit_step_summary() {
  local body="${1}"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '#### 📦 软件包编译门禁\n\n%s\n\n' "${body}" \
    >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || log_warning "无法写入 GITHUB_STEP_SUMMARY"
  return 0
}

# 门禁主体：返回 0 = 通过，非 0 = 拦住发布。
run_verify() {
  # 一、fail-closed 前置条件：缺任何一份输入都判失败，理由见本节开头。
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    printf '❌ 编译门禁无法执行：%s 不存在，无从判定哪些软件包应当编译（fail-closed）。\n' "${CONFIG_FILE}"
    _verify_emit_output false 0 0 0 ""
    return 1
  fi
  if ! package_index_available; then
    printf '❌ 编译门禁无法执行：找不到 python3，读不了产物索引 index.json（fail-closed）。\n'
    _verify_emit_output false 0 0 0 ""
    return 1
  fi

  # 二、编译验证：分母 = immortalwrt/.config，与 build 模式同一口径。
  _collect_package_counts
  _compute_verification

  local missing_count="${_PKG_MISSING_COUNT}"
  local missing_pkgs
  # 折叠块里的清单带「（引导固件，产物为 .bin/.fip）」后缀，交给下游的是纯名字。
  missing_pkgs="$(printf '%s\n' "${_PKG_MISSING_TEXT}" | sed 's/（引导固件.*$//' | grep . || true)"

  # 三、两份配置的比对。开关只管这两项（编译验证是硬性口径，不受开关控制）：
  #     · 静默丢弃      根 .config 选中  -> imm 连符号都没有
  #     · 明确关闭被打开 根 .config is-not-set -> imm 里 =y|=m
  local silent_count=0
  local silent_pkgs=""
  local reopened_count=0
  local reopened_pkgs=""
  if [[ "${VERIFY_CONFIG_SYMBOLS}" == "false" ]]; then
    printf '· 静默丢弃 / 明确关闭被打开 两项校验已按 VERIFY_CONFIG_SYMBOLS=false 跳过\n'
  elif [[ ! -f "${REPO_CONFIG_FILE}" ]]; then
    printf '❌ 编译门禁无法执行：%s 不存在（两份配置比对的基准，fail-closed）。\n' "${REPO_CONFIG_FILE}"
    _verify_emit_output false "${missing_count}" 0 0 "$(printf '%s' "${missing_pkgs}" | tr '\n' ',')"
    return 1
  else
    local repo_selected repo_disabled mentioned imm_selected
    repo_selected="$(kconfig_selected_packages "${REPO_CONFIG_FILE}")"
    repo_disabled="$(kconfig_disabled_packages "${REPO_CONFIG_FILE}")"
    mentioned="$(kconfig_mentioned_symbols "${CONFIG_FILE}")"
    imm_selected="$(kconfig_selected_packages "${CONFIG_FILE}")"
    # comm 两侧必须是已排序集合流；grep . 去掉空行，否则空输入会退化成"一个空元素"。
    silent_pkgs="$(comm -23 \
      <(printf '%s\n' "${repo_selected}" | grep . | sort -u) \
      <(printf '%s\n' "${mentioned}" | grep . | sort -u) || true)"
    silent_count="$(_count_lines "${silent_pkgs}")"
    # 方向相反的一项：根 .config 关掉、imm 却打开 —— 取交集。
    reopened_pkgs="$(comm -12 \
      <(printf '%s\n' "${repo_disabled}" | grep . | sort -u) \
      <(printf '%s\n' "${imm_selected}" | grep . | sort -u) || true)"
    reopened_count="$(_count_lines "${reopened_pkgs}")"
  fi

  # 四、结论与输出。三行计数先把「两份都查了」摆出来，再逐项列名单。
  local total_count=$((missing_count + silent_count + reopened_count))
  local ok=true
  if [[ ${total_count} -gt 0 ]]; then
    ok=false
  fi

  printf '\n[verify] 比对两份配置：%s（作者手写） × %s（defconfig 实况）\n' \
    "${REPO_CONFIG_FILE}" "${CONFIG_FILE}"
  printf '[verify] 应编 %s 项 / 未产出 %s 项 / 静默丢弃 %s 项 / 明确关闭被打开 %s 项\n' \
    "${_PKG_PLANNED_COUNT}" "${missing_count}" "${silent_count}" "${reopened_count}"
  if [[ -n "${missing_pkgs}" ]]; then
    printf '未产出产物（选中但没编出来）：\n%s\n' "${missing_pkgs}"
  fi
  if [[ -n "${silent_pkgs}" ]]; then
    printf '静默丢弃（仓库根 .config 选中，但 immortalwrt/.config 里连符号都不存在）：\n%s\n' "${silent_pkgs}"
  fi
  if [[ -n "${reopened_pkgs}" ]]; then
    printf '明确关闭被打开（仓库根 .config 用 is not set 关掉，immortalwrt/.config 里却是 =y|=m）：\n%s\n' "${reopened_pkgs}"
  fi

  # 扁平清单去重：同一符号可能同时命中两项（既在 imm 里被打开、产物又没出），
  # 但它是给人看的清单，重复一遍只会让人以为有两个问题；分项计数才是权威口径。
  local flat_missing
  flat_missing="$(printf '%s\n%s\n%s\n' "${missing_pkgs}" "${silent_pkgs}" "${reopened_pkgs}" \
    | grep . | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
  _verify_emit_output "${ok}" "${missing_count}" "${silent_count}" "${reopened_count}" "${flat_missing}"

  if [[ "${ok}" == "true" ]]; then
    printf '✅ 编译门禁通过：选中的软件包全部有产物，没有静默丢弃，也没有关掉的被重新打开。\n'
    _verify_emit_step_summary "✅ 通过：应编 ${_PKG_PLANNED_COUNT} 项；未产出 0、静默丢弃 0、明确关闭被打开 0。"
    return 0
  fi

  printf '❌ 编译门禁未通过：共 %s 项有问题（未产出 %s、静默丢弃 %s、明确关闭被打开 %s），本次不发布。\n' \
    "${total_count}" "${missing_count}" "${silent_count}" "${reopened_count}"
  _verify_emit_step_summary "$(printf '❌ 未通过：应编 %s 项；未产出 %s、静默丢弃 %s、明确关闭被打开 %s。详见本步骤日志。' \
    "${_PKG_PLANNED_COUNT}" "${missing_count}" "${silent_count}" "${reopened_count}")"
  return 1
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
  # 前导下划线是流水线的拼接分隔符（artifact 名要拼成 xxx_<设备>_<日期>），
  # 在这里读的却是列值，留着就是纯噪音；只在这一层去掉，不做成"值也改了"。
  # CACHE_HIT 是 cachewrtbuild 的 true/false，直接照抄等于往中文摘要里塞英文。
  local cache_text
  case "${CACHE_HIT:-}" in
    true) cache_text="命中" ;;
    false) cache_text="未命中" ;;
    "") cache_text="" ;;
    *) cache_text="${CACHE_HIT}" ;;
  esac
  rows="$(
    meta_row "设备" "${DEVICE_NAME#_}"
    meta_row "文件日期" "${FILE_DATE#_}"
    meta_row "发布标签" "${RELEASE_TAG:-}"
    meta_row "构建缓存" "${cache_text}"
  )"
  artifacts="$(artifact_rows)"
  size_line="$(firmware_size_line)"
  if [[ -z "${rows}" && -z "${size_line}" && -z "${artifacts}" ]]; then
    return 0
  fi
  printf '#### 构建产物\n\n'
  if [[ -n "${rows}" ]]; then
    # 表格后必须空一行，否则紧跟的普通段落会被 Markdown 解析成表格的续行。
    printf '| 项 | 值 |\n| --- | --- |\n%s\n' "${rows}"
  fi
  if [[ -n "${artifacts}" ]]; then
    [[ -n "${rows}" ]] && printf '\n'
    # 末尾补一个换行终止表格：命令替换已吞掉 artifact_rows 的行尾换行，
    # 否则后面的「固件体积」会被 Markdown 当成表格的续行。
    printf '| 产物类型 | 产物名 |\n| --- | --- |\n%s\n' "${artifacts}"
  fi
  if [[ -n "${size_line}" ]]; then
    [[ -n "${rows}" || -n "${artifacts}" ]] && printf '\n'
    printf '%s\n' "${size_line}"
  fi
  printf '\n'
}

newest_log_file() {
  local dir="${1:-}"
  [[ -d "${dir}" ]] || return 1
  local found
  found="$(find "${dir}" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -n | tail -n 1 | cut -d' ' -f2-)" || found=""
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}

# 候选全集：只有这里列出的文件名才会被选源。顺序即优先级，
# 让"哪份日志更该被引用"变成一份可 review 的列表，而不是一个 mtime 排序的输出。
#
# build-compile.log 是 compile 阶段的 logger 日志：download/prepare 进度、私钥门禁的失败原因、
# make 失败时那句 "Compilation failed" 都只写在这里；三个 make 变体（-parallel/-single/-verbose）
# 只装 make 原始输出。因此主日志排最前——摘录要先给人话结论，再给编译器原始错误行。
readonly LOG_NAME_CATALOG=(
  build-compile.log
  build-compile-verbose.log
  build-compile-single.log
  build-compile-parallel.log
  build-generate-release-info.log
  build-deps.log
  build-prepare.log
  build-download.log
  build-check.log
  build-all.log
  build-verbose.log
  build-single.log
  build-parallel.log
)

# 每份候选日志能"自证"到什么程度，决定它能否直接被引用：
#   时间戳 - 首末行时间戳成对，说明它覆盖了一次完整的步骤运行（也就能算耗时）；
#   内容   - 该步骤只写一句话，被写过本身就说明它属于本次运行（算不出耗时）；
#   None   - 认不出来源，永不参与选源。
# 这里只回答"能怎么自证"；步骤名由 log_step_source 从文件名推出，
# 是否含 make 原行由 log_kind_label 推出——三处各管一件事，不互相抄。
log_name_rule() {
  case "${1:-}" in
    build-compile.log | build-compile-verbose.log | build-compile-single.log | build-compile-parallel.log | \
      build-verbose.log | build-single.log | build-parallel.log | \
      build-deps.log | build-prepare.log | build-download.log | build-check.log | build-all.log)
      printf '时间戳'
      ;;
    build-generate-release-info.log) printf '内容' ;;
    *) printf 'None' ;;
  esac
}

# 文件名是否在候选全集里（"日志文件"小节与 resolve_log 共用同一份清单，不另造白名单）。
is_catalog_log() {
  local base="${1:-}" name
  for name in "${LOG_NAME_CATALOG[@]}"; do
    [[ "${base}" == "${name}" ]] && return 0
  done
  return 1
}

# 输出 "<kind>|<路径>|<起始时间戳>|<结束时间戳>"；解析不出候选就返回非零。
# 只认规则命名且能自证的日志，因此这里不需要 mtime 猜测。
resolve_log() {
  local dir="${1:-}"
  local mode="${2:-error}"
  [[ -d "${dir}" ]] || return 1
  local base path kind start end
  for base in "${LOG_NAME_CATALOG[@]}"; do
    path="${dir}/${base}"
    [[ -f "${path}" ]] || continue
    kind="$(log_name_rule "${base}")"
    case "${kind}" in
      None) continue ;;
      时间戳)
        start="$(first_ts "${path}")"
        end="$(last_ts "${path}")"
        [[ -n "${start}" && -n "${end}" ]] || continue
        ;;
    esac
    printf '%s|%s|%s|%s\n' "${kind}" "${path}" "${start:-}" "${end:-}"
    return 0
  done
  # 没有任何规则候选时，只在需要错误摘录的场景退回 mtime 兜底；
  # 耗时不给兜底——宁可不报时长，也不拿一份读不懂的日志编一个数出来。
  [[ "${mode}" == "error" ]] || return 1
  path="$(newest_log_file "${dir}")" || return 1
  printf '时间戳|%s||\n' "${path}"
}

# 时间戳可能带 UTC 偏移（[2026-10-26 11:45:21 +0800]），也可能不带（旧日志/阶段日志）。
# 偏移必须原样传给 date -d：丢掉它就把"装 tzdata 前 UTC、装后 +08:00"当成了同一时钟，
# 首末相减会算出几小时的假耗时（本地实测 6m54s 被算成 8h6m54s）。
first_ts() {
  head -n 200 -- "${1}" 2>/dev/null |
    grep -m1 -oE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}( ?[+-][0-9]{4})?\]' | tr -d '[]'
}

last_ts() {
  tail -n 200 -- "${1}" 2>/dev/null |
    grep -oE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}( ?[+-][0-9]{4})?\]' | tail -n 1 | tr -d '[]'
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
    printf '编译缓存命中率：%s' "${rate}"
    return 0
  fi
  # ccache 4 的摘要形如 "Hits: 123 / 456 (26.97%)"，括号里就是命中率。
  hits_line="$(printf '%s\n' "${out}" | grep -iE '^[[:space:]]*hits[[:space:]]*:' | head -n 1)"
  [[ -n "${hits_line}" ]] || return 0
  pct="$(printf '%s' "${hits_line}" | grep -oE '\([0-9.]+%\)' | tr -d '()')"
  if [[ -n "${pct}" ]]; then
    printf '编译缓存命中率：%s' "${pct}"
    return 0
  fi
  hits="$(printf '%s' "${hits_line}" | grep -oE '[0-9]+' | head -n 1)"
  misses="$(printf '%s\n' "${out}" | grep -iE '^[[:space:]]*misses[[:space:]]*:' | head -n 1 |
    grep -oE '[0-9]+' | head -n 1)"
  if [[ -n "${hits}" && -n "${misses}" ]] && ((hits + misses > 0)); then
    pct="$(awk -v h="${hits}" -v m="${misses}" 'BEGIN { printf "%.1f%%", 100 * h / (h + m) }')"
    printf '编译缓存命中率：%s（命中 %s 次 / 未命中 %s 次）' "${pct}" "${hits}" "${misses}"
  fi
  return 0
}

# 耗时只认规则命名日志的首末行时间戳。没有时间戳就不报时长——
# 用错来源算出来的假时长（例如摘要步骤自己那份只有一句话的日志）比"没有时长"更误导人。
render_duration() {
  # 耗时靠构建日志首末行、命中率靠 ccache，两者都只属于 build job；
  # update-checker 若渲染它们，本地预览就会把仓库里残留的旧 build 日志当成事实。
  [[ "${1}" == "build" ]] || return 0
  local dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
  local line="" selected kind log start end s e
  # 候选来自固定规则全集（resolve_log）：第一个既在清单里、又能自证的赢。
  # 不再按 mtime 猜"哪份最新"——那只会挑到摘要步骤自己写的那份。
  selected="$(resolve_log "${dir}" duration)" || selected=""
  if [[ -n "${selected}" ]]; then
    kind="${selected%%|*}"
    selected="${selected#*|}"
    log="${selected%%|*}"
    selected="${selected#*|}"
    start="${selected%%|*}"
    end="${selected#*|}"
    if [[ "${kind}" == "时间戳" ]]; then
      s="$(date -d "${start}" +%s 2>/dev/null)" || s=""
      e="$(date -d "${end}" +%s 2>/dev/null)" || e=""
      if [[ -n "${s}" && -n "${e}" ]] && ((e >= s)); then
        # 来源写两步：日志文件名（能对回 artifact）与它所属的 workflow 步骤（能对回运行页）。
        # 步骤名走 log_step_source，"日志文件"小节与这里才对同一份文件说同一句话。
        line="构建耗时：约 $(human_duration "$((e - s))")（${start} → ${end}，来源 $(basename -- "${log}")，$(log_step_source "$(basename -- "${log}")")）"
      fi
    fi
  fi
  local cache
  cache="$(ccache_line)"
  if [[ -z "${line}" && -z "${cache}" ]]; then
    return 0
  fi
  printf '#### 耗时与缓存\n\n'
  [[ -n "${line}" ]] && printf -- '- %s\n' "${line}"
  [[ -n "${cache}" ]] && printf -- '- %s\n' "${cache}"
  printf '\n'
}

# 失败摘录只算一次并存进全局：摘要与 stderr 用的是同一段文本，避免两处口径不一。
collect_error_excerpt() {
  local dir="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
  local selected log
  selected="$(resolve_log "${dir}" error)" || selected=""
  if [[ -z "${selected}" ]]; then
    ERROR_NOTE="未找到构建日志：${dir} 不存在或不含规则命名的 *.log"
    return 0
  fi
  # resolve_log 输出 kind|路径|起始|结束：摘录要写清出自哪一步的哪份日志，
  # 步骤名从文件名反推（log_step_source），读者不用回 artifact 里逐个猜。
  selected="${selected#*|}"
  log="${selected%%|*}"
  ERROR_LOG_NAME="$(basename -- "${log}")"
  ERROR_LOG_SOURCE="$(log_step_source "${ERROR_LOG_NAME}")"
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

# 日志类型要写进摘要：只有 make 原始输出才会有编译器 error 原行，
# 脚本日志通常只有「Compilation failed. Logs: ...」这类汇总行。
log_kind_label() {
  local raw=""
  case "${ERROR_LOG_NAME}" in
    build-compile-verbose.log | build-compile-single.log | build-compile-parallel.log)
      raw=1
      ;;
    build-verbose.log | build-single.log | build-parallel.log) raw=1 ;;
    *) raw=0 ;;
  esac
  if [[ "${raw}" == "1" ]]; then
    printf 'make 原始输出'
  else
    printf '脚本日志，可能不含编译错误原行'
  fi
}

render_failure() {
  printf '#### 失败详情\n\n'
  if [[ -n "${ERROR_EXCERPT}" ]]; then
    local count
    count="$(printf '%s\n' "${ERROR_EXCERPT}" | grep -c '')"
    printf '<details><summary>关键错误摘录（%s 行，来自 %s 的 <code>%s</code> — %s）</summary>\n\n' \
      "${count}" "$(md_cell "${ERROR_LOG_SOURCE:-未登记命名的日志}")" \
      "$(md_cell "${ERROR_LOG_NAME}")" "$(log_kind_label)"
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
    printf '#### 上游更新\n\n未提供上游 commit 信息。\n\n'
    return 0
  fi
  printf '#### 上游更新\n\n| 项 | 值 |\n| --- | --- |\n'
  printf '%s\n' "${rows[@]}"
  printf '\n'
}

# 只有 build / update-checker 这两个 job 会真的产出 logs/，
# 其余流水线在没有日志的 runner 上扫描，只会把"没找到日志"写成一条假故障。
uses_build_logs() {
  case "${1}" in
    build | update-checker) return 0 ;;
    *) return 1 ;;
  esac
}

# 指标表：回答"这次运行到底查了什么、查出什么"。KEY|显示名称 的写法与 STEP_SEQUENCE 一致，
# 取值同样走 <PREFIX><KEY> 的三候选大小写规则——两条通道只差一个前缀，不另立规则。
render_metrics() {
  case "${1}" in
    dependency-auditor | syntax-linter) ;;
    *) return 0 ;;
  esac
  [[ -n "${METRIC_SEQUENCE:-}" ]] || return 0
  printf '#### 本次结果\n\n| 项 | 值 |\n| --- | --- |\n'
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
    value="$(metric_value "${key}")"
    # 空值是"这一步没跑到"，不是"结果是 0"；留空单元格会被读成后者，所以显式标出来。
    [[ -n "${value}" ]] || value="⚪ 未提供"
    printf '| %s | %s |\n' "$(md_cell "${name}")" "$(md_cell "${value}")"
  done <<<"${METRIC_SEQUENCE}"
  printf '\n'
}

# 明细通道：长正文（失效包名清单、lint 命中列表）折叠起来，默认不占版面、按需展开。
# DETAIL_SEQUENCE 每行 KEY|折叠标题，DETAIL_<KEY> 是正文；正文进围栏不转义，
# 因为它本身就是命令输出，转义后不能直接复制去排查。
# 折叠标题用 md_cell 压平：<summary> 里再嵌一层 Markdown 表格会撑坏折叠块。
render_details() {
  case "${1}" in
    dependency-auditor | syntax-linter) ;;
    *) return 0 ;;
  esac
  [[ -n "${DETAIL_SEQUENCE:-}" ]] || return 0
  local line key title body fence printed=0
  fence="$(printf '\x60\x60\x60')"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%|*}"
    if [[ "${line}" == *"|"* ]]; then
      title="${line#*|}"
    else
      title="${key}"
    fi
    [[ -n "${title}" ]] || title="${key}"
    body="$(detail_value "${key}")"
    # 没有正文就不出折叠块：一个空 <details> 比不渲染更让人困惑。
    [[ -n "${body}" ]] || continue
    if [[ "${printed}" == "0" ]]; then
      printf '#### 明细\n\n'
      printed=1
    fi
    printf '<details><summary>%s</summary>\n\n%stext\n%s\n%s\n\n</details>\n\n' \
      "$(md_cell "${title}")" "${fence}" "${body}" "${fence}"
  done <<<"${DETAIL_SEQUENCE}"
}

# 本地落盘位置：与构建日志同目录，文件名固定。
#
# 放进 logs/ 是刻意的——摘要本就是这个目录里那批产物的「读后总结」，
# 归在一起比散落在仓库根更符合语义，也不必为它单列一条 gitignore 规则。
#
# 关于「摘要会不会把自己的产物当成源日志」：不会，有两道保险——
#   1) 选源扫描只取 `-name '*.log'`（见 render_logs / newest_log_file），.md 进不了候选；
#   2) 候选还受 LOG_NAME_CATALOG 白名单收口，清单外的文件名一律不引用。
# 因此同目录存放不会重蹈上一轮「按 mtime 挑到自己的空日志」的覆辙。
readonly SUMMARY_MD_FILE="logs/summary.md"

# 本地模式写一份 Markdown 文件，供人留存/分享；CI 模式由 GITHUB_STEP_SUMMARY 承担，不写。
# 写失败只告警不中断：摘要是「汇报」环节，终端那份必须照常打出来。
write_local_summary_file() {
  local text="${1}"
  local target="${SUMMARY_MD_FILE}"
  # logs/ 可能还不存在（本次没跑过任何写日志的阶段，例如只跑纯产物脚本）。
  # 先建目录再写，否则会因父目录缺失而失败——那时只落一条 WARN，用户就看不到文件了。
  mkdir -p -- "$(dirname -- "${target}")" 2>/dev/null || true
  # 覆盖写而非追加：每次运行生成的是「这一次」的完整快照，
  # 追加会让人分不清哪几行属于本次（与 GITHUB_STEP_SUMMARY 的追加语义刻意不同）。
  # 重定向顺序有意为之：2>/dev/null 必须写在 >"${target}" 之前。bash 从左到右处理重定向，
  # 若先写 >，目标不可写时 bash 会先把自己的诊断打到原 stderr，那条 2>/dev/null 根本来不及接管。
  if printf '%s\n' "${text}" 2>/dev/null >"${target}"; then
    log_info "本地摘要已写入 ${PWD}/${target}"
    return 0
  fi
  log_warning "无法写入 ${target}，仅保留终端输出"
  return 0
}

# 写入 GITHUB_STEP_SUMMARY；路径不可写时退回 stdout，信息不丢。
# 本地（没有 GITHUB_STEP_SUMMARY）额外落一份 summary.md，免得终端一关就没了。
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
  # 只有本地（未设 GITHUB_STEP_SUMMARY）才落盘：CI 里运行页已有摘要，
  # 再往工作区写一份既无用、又会被 artifact 打包带走。
  if [[ -z "${target}" ]]; then
    write_local_summary_file "${text}"
  fi
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

# 「自动校验要点」：把 CI 端会逐项校验的东西摊开在摘要里，读者不必回去翻脚本。
# 数据全部取自 summary-provenance.sh 算好的同一份 PROV_*，这里绝不重算——
# 重算就会与溯源块出现"表里 N、块里 M"的分歧，而这正是本小节想消灭的问题。
render_auto_check_section() {
  [[ "${PROVENANCE_AVAILABLE}" == "true" ]] || return 0
  provenance_gather

  # 溯源块的 10 个键（格式版本 2 起）：任一为空，CI 侧解析就会拿到空值，所以这里数"实际填了几个"。
  # 末两键取自同一份 _PKG_* 计数（见 summary-provenance.sh 的 _prov_package_counts）：
  # 不重算，且缺值时是 unknown 而不是空串——unknown 表示"无法证明"（本例没跑过编译），
  # 它仍是"已填"的值，是否放过由 CI 侧判定，不在这里替它做判断。
  local planned_count missing_count filled=0 value
  read -r planned_count missing_count <<<"$(_prov_package_counts)"
  for value in \
    "${PROV_FORMAT_VERSION}" "${PROV_REPO}" "${PROV_BRANCH}" "${PROV_COMMIT}" \
    "${PROV_GENERATED_AT}" "${PROV_BASE_REF}" "${PROV_CHANGED_COUNT}" "${PROV_FINGERPRINT}" \
    "${planned_count}" "${missing_count}"; do
    [[ -n "${value}" ]] && filled=$((filled + 1))
  done

  # 必备文件：溯源实现、摘要脚本、构建入口三缺一，CI 的校验步骤就没有可跑的对象。
  local -a required_files=(
    "scripts/ci/summary-provenance.sh"
    "scripts/ci/generate-summary.sh"
    "scripts/build/build.sh"
  )
  local present=0 file
  for file in "${required_files[@]}"; do
    [[ -f "${file}" ]] && present=$((present + 1))
  done

  printf '#### 🔎 自动校验要点\n\n'
  printf '| 校验项 | CI 会校验什么 | 本摘要中的实际值 |\n| --- | --- | --- |\n'
  printf '| 摘要格式版本 | 溯源块「格式版本」必须是 2 | %s |\n' "$(md_cell "${PROV_FORMAT_VERSION}")"
  printf '| 溯源块完整性 | begin/end 标记之间 10 个键全部非空 | %s/10 键非空 |\n' "${filled}"
  printf '| 指纹一致性 | 按契约字节规则重算清单指纹，须与块内一致 | %s |\n' "$(md_cell "${PROV_FINGERPRINT}")"
  printf '| 必备文件 | 溯源实现、摘要脚本、构建入口都存在 | %s/%s 存在 |\n' \
    "${present}" "${#required_files[@]}"
  printf '| 变更范围 | 变更清单须落在允许修改的路径内 | %s 个文件（基准 %s） |\n' \
    "$(md_cell "${PROV_CHANGED_COUNT}")" "$(md_cell "${PROV_BASE_REF}")"
  # 这一行是本小节里唯一"会判失败"的门禁口径：未产出数不为 0 就说明本次改动让部分软件包
  # 不再被编译，稳定性无从谈起。unknown（非 build 流水线 / 没读到 .config）同等按失败处理——
  # 无法证明"零漏编"与"确实漏编"在门禁上必须同结论，否则没编译过的流水线就能靠 0 蒙过去。
  printf '| 编译验证 | 溯源块「未产出数」必须为 0（unknown 视为无法证明，同判失败） | 应编 %s，未产出 %s |\n' \
    "$(md_cell "${planned_count}")" "$(md_cell "${missing_count}")"
  printf '\n'
  return 0
}

main() {
  local mode="${1:-build}"
  case "${mode}" in
    build | update-checker | dependency-auditor | syntax-linter | verify) ;;
    *)
      log_warning "未知模式 '${mode}'，按 build 处理"
      mode="build"
      ;;
  esac

  # verify 是门禁而非汇报：不走摘要渲染，直接判定并由结果决定退出码。
  if [[ "${mode}" == "verify" ]]; then
    run_verify
    return $?
  fi

  detect_failure
  # 摘录来源于 logs/，只有 build / update-checker 才会产出这份日志。
  # 其余流水线的 runner 上没有 logs/，去扫描只会把"没找到日志"写成一条假故障。
  if [[ "${FAILURE_DETECTED}" == "true" ]] && uses_build_logs "${mode}"; then
    collect_error_excerpt
  fi

  local summary
  summary="$(
    render_header "${mode}"
    render_meta
    render_update_checker "${mode}"
    render_metrics "${mode}"
    render_steps
    render_details "${mode}"
    render_build_info "${mode}"
    # 软件包清单只在真的编译过时才有意义：读的是 bin/ 下的产物元数据，
    # 其余流水线（lint / 依赖巡检）既没有这些文件，也不该等一个空小节。
    if [[ "${mode}" == "build" ]]; then
      render_package_section
    fi
    render_logs "${mode}"
    render_duration "${mode}"
    # 失败摘录读的是 logs/，只有会产出构建日志的流水线才谈得上"从这里找原行"。
    if [[ "${FAILURE_DETECTED}" == "true" ]] && uses_build_logs "${mode}"; then
      render_failure
    fi
    # 溯源块是整份摘要的收尾（契约要求它是文件最后一段），校验要点是它的导读，
    # 因此两者按"要点 -> 溯源块"的顺序接在所有既有小节之后；
    # 既有小节的顺序一律不动，免得读者已经熟悉的版面被改写。
    if [[ "${PROVENANCE_AVAILABLE}" == "true" ]]; then
      # 两个渲染函数各自收尾带换行，这里不再补空行，否则小节之间会多出一行空白。
      render_auto_check_section
      render_provenance_block
    fi
  )"

  emit_summary "${summary}"
  uses_build_logs "${mode}" && flush_error_to_stderr
  return 0
}

main "$@"
