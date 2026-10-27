#!/bin/bash
#
# 生成 GitHub Actions 运行摘要，并在失败时摘录构建错误：
#   - 设置了 $GITHUB_STEP_SUMMARY 时追加写入该文件（Actions 运行页可见）；
#   - 未设置时打印到 stdout，便于本地预览；
#   - 失败路径下，同一段错误行还会打到 stderr，让本地终端与 CI 页面看到同一份证据。
#
# 用法：bash scripts/ci/generate-summary.sh [build|update-checker|dependency-auditor|syntax-linter]
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
# 摘要只读日志、不写日志：它一写就会在 logs/ 里多出一份"最新"的文件，
# 而它正是挑"哪份日志属于本次构建"的那个读者——自己制造候选、再去匹配自己，是上一轮的 bug 根源。
LOG_TO_FILE=false

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
    update-checker) printf '## 🔄 上游更新检查总结\n\n' ;;
    dependency-auditor) printf '## 🔍 依赖巡检总结\n\n' ;;
    syntax-linter) printf '## 🧹 语法与规范门禁总结\n\n' ;;
    *) printf '## 🏗️ ImmortalWrt BPI-R4 构建总结\n\n' ;;
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
  printf '### 日志文件\n\n'
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
# 编译前的包选择：.config 里 CONFIG_PACKAGE_<名>=y|m 的才算「本应编译」。
readonly CONFIG_FILE="immortalwrt/.config"

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

# 按来源统计编译产出。
#   无参数  -> feed + target 并集，即"这次到底编出了多少 .apk"（编译验证用的分母）
#   带参数  -> 只统计指定 glob 的来源，供表格分开展示
built_packages() {
  package_index_available || return 0
  local -a files=()
  local file
  if [[ $# -gt 0 ]]; then
    # shellcheck disable=SC2207  # 路径由只读 glob 展开，含空格的可能性不成立
    files=($(compgen -G "${1}" 2>/dev/null || true))
  else
    # 两处索引都要收：feed（target 无关）与 targets/*/*/packages（target 专属 kmod）。
    # shellcheck disable=SC2207
    files=($(compgen -G "${PACKAGE_INDEX_GLOB_PATTERN}" 2>/dev/null || true)
           $(compgen -G "${TARGET_PACKAGE_INDEX_GLOB_PATTERN}" 2>/dev/null || true))
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
render_package_section() {
  local installed built planned
  installed="$(manifest_packages)"
  built="$(built_packages)"
  planned="$(planned_packages)"

  # 三者都空说明这次没跑编译（或产物已清理），不是故障，静默跳过。
  if [[ -z "${installed}" && -z "${built}" && -z "${planned}" ]]; then
    return 0
  fi

  local installed_count=0 built_count=0 planned_count=0
  [[ -n "${installed}" ]] && installed_count="$(printf '%s\n' "${installed}" | grep -c .)"
  [[ -n "${built}" ]] && built_count="$(printf '%s\n' "${built}" | grep -c .)"
  [[ -n "${planned}" ]] && planned_count="$(printf '%s\n' "${planned}" | grep -c .)"

  # 编译产出按落盘位置分列，不合并成一个数字。
  # 两处的语义不同，合并后读者无法回答"最终发布目录里到底有什么"：
  #   bin/...            最终产物，会随 artifact 发布
  #   staging_dir/...    构建暂存中间态，不进发布包
  # 实测本机 feed 227 + target 154 = bin 并集 381，而 staging 也是 381 但内容不同源。
  local feed_count=0 target_count=0 staging_count=0
  local feed_pkgs target_pkgs
  feed_pkgs="$(built_packages "${PACKAGE_INDEX_GLOB_PATTERN}")"
  target_pkgs="$(built_packages "${TARGET_PACKAGE_INDEX_GLOB_PATTERN}")"
  [[ -n "${feed_pkgs}" ]] && feed_count="$(printf '%s\n' "${feed_pkgs}" | grep -c .)"
  [[ -n "${target_pkgs}" ]] && target_count="$(printf '%s\n' "${target_pkgs}" | grep -c .)"
  # staging 是构建中间态，没有 index.json，按 .apk 文件数统计。
  # 暂存目录里的 *.apk **全是符号链接**，指向 bin/ 下的真实文件（实测 381 个链接：
  # 227 -> bin/packages/<arch>/<feed>/，154 -> bin/targets/<board>/<sub>/packages/）。
  # 因此这里必须用 -type l 统计，用 -type f 会得到 0——
  # 而这恰好也说明 staging 不是"独立产物"，它只是 bin 的镜像视图，
  # 表格里据此标注，避免读者把 381 重复算成另一份产出。
  staging_count="$(find immortalwrt/staging_dir/packages -maxdepth 2 -name '*.apk' -type l 2>/dev/null | wc -l)"

  # 未生效的变体开关（只有开关、宿主包没选）：配置现象，与「未产出」分开报。
  local orphans orphan_count=0
  orphans="$(orphan_variants)"
  [[ -n "${orphans}" ]] && orphan_count="$(printf '%s\n' "${orphans}" | grep -c .)"

  printf '### 软件包\n\n'
  # 表格后必须空一行，否则紧跟的段落会被 Markdown 当成表格续行。
  printf '| 类别 | 数量 | 说明 |\n| --- | --- | --- |\n'
  printf '| 装进固件 | %s | 镜像内自带，开机即有 |\n' "${installed_count}"
  # 编译产出按目录分列：三行各自独立，不做加减关系，读者一眼看出产物落在哪。
  # 尖括号占位符会被 shellcheck 判成重定向（SC2016/SC2086），改用 [-]- 风格。
  printf '| 编译产出 · bin feed | %s | bin/packages/ 下按架构与 feed 分组，最终发布产物 |\n' "${feed_count}"
  printf '| 编译产出 · bin target | %s | bin/targets/ 下 target 专属包（kmod 等），同为发布产物 |\n' "${target_count}"
  printf '| 暂存 · staging_dir | %s | 均为指向 bin/ 的符号链接，不是独立产物 |\n' "${staging_count}"
  # 引导固件单独成行：它不走 .apk 口径，且两处目录里的内容**并不相同**
  # （实测本机各 17 个、交集为 0），合并显示会让人误以为是同一批被数了两遍。
  local boot_bin_count=0 boot_staging_count=0
  boot_bin_count="$(boot_artifacts_in_bin | grep -c . || true)"
  boot_staging_count="$(boot_artifacts_in_staging | grep -c . || true)"
  if [[ ${boot_bin_count} -gt 0 || ${boot_staging_count} -gt 0 ]]; then
    printf '| 引导固件 · bin | %s | 已进发布目录的 .bin/.fip（成品） |\n' "${boot_bin_count}"
    printf '| 引导固件 · staging | %s | 暂存目录里的 .bin/.fip（中间件，与上者内容不同） |\n' "${boot_staging_count}"
  fi
  if [[ ${orphan_count} -gt 0 ]]; then
    printf '| 未生效的变体开关 | %s | 开关自身有值，但宿主包未被选中，合入固件后不会生效 |\n' "${orphan_count}"
  fi

  # 验证行：只有真的读到 .config 时才谈得上「应编多少」，否则不臆造分母。
  #
  # 比对分两路，因为两类产物的形态根本不同：
  #   · 普通包 -> 产出 .apk，与 built（两处 index.json 的并集）比集合差；
  #   · 引导固件（u-boot-* / trusted-firmware-a-*）-> 产出 .bin/.fip，与产物文件名比词干。
  # 把引导固件硬塞进 .apk 口径会永远报「未产出」——实测 16 条假报全部来自这里。
  local verdict
  if [[ ${planned_count} -gt 0 ]]; then
    local missing_text="" missing_count=0 boot_text="" boot_count=0
    local -a boot_arts_bin=() boot_arts_staging=()
    local boot_ok_text=""
    # 两处产物分别收集：引导固件可能只落在其中一处，位置本身就是信息。
    # shellcheck disable=SC2207
    boot_arts_bin=($(boot_artifacts_in_bin))
    # shellcheck disable=SC2207
    boot_arts_staging=($(boot_artifacts_in_staging))

    local -a pkg_planned=() boot_planned=()
    local name
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      case "${name}" in
        u-boot-* | trusted-firmware-a-*) boot_planned+=("${name}") ;;
        *) pkg_planned+=("${name}") ;;
      esac
    done <<<"${planned}"

    # 普通包：计划集合 - 已产出集合。
    # 未生效开关的宿主包要先剔掉：它已经在「未生效的变体开关」那一行单独报过，
    # 若这里再报一次，同一件事会在摘要里出现两遍（归一化后的基包名 + 原始开关名），
    # 读者会误以为有两个问题。
    if [[ ${#pkg_planned[@]} -gt 0 ]]; then
      local -a orphan_bases=()
      local ov
      while IFS= read -r ov; do
        [[ -n "${ov}" ]] || continue
        orphan_bases+=("${ov%_*}")
        orphan_bases+=("$(printf '%s' "${ov%_*}" | sed 's/_/-/g')")
      done <<<"${orphans}"
      if [[ ${#orphan_bases[@]} -gt 0 ]]; then
        # comm 的两侧必须是**已排序的集合流**。这里把「已产出」与「孤立基包」并成一个
        # 排除集合，再一次性做差——注意不能写成 sort -u "${built}" file：built 是字符串
        # 不是文件名，sort 会把它当路径读并失败，结果整列被当成「未产出」（实测 380 条假报）。
        missing_text="$(comm -23 <(printf '%s\n' "${pkg_planned[@]}" | sort -u) \
                                  <(printf '%s\n' "${built}" "${orphan_bases[@]}" | sort -u) 2>/dev/null)"
      else
        missing_text="$(comm -23 <(printf '%s\n' "${pkg_planned[@]}" | sort -u) \
                                  <(printf '%s\n' "${built}" | sort -u) 2>/dev/null)"
      fi
      [[ -n "${missing_text}" ]] && missing_count="$(printf '%s\n' "${missing_text}" | grep -c .)"
    fi

    # 引导固件：产物文件名里是否含该配置名的词干。
    # 分别判定落入 bin（发布目录）与 staging（暂存目录），不合并——
    # 只落在 staging 的产物说明它还没进发布目录，这是读者需要知道的事实。
    local boot
    local boot_in_bin=0 boot_in_staging=0 boot_in_none=0
    for boot in "${boot_planned[@]}"; do
      local stem
      stem="$(boot_stem "${boot}")"
      local hit_bin=0 hit_staging=0 art
      for art in "${boot_arts_bin[@]}"; do
        if [[ "${art}" == *"${stem}"* ]]; then
          hit_bin=1
          break
        fi
      done
      for art in "${boot_arts_staging[@]}"; do
        if [[ "${art}" == *"${stem}"* ]]; then
          hit_staging=1
          break
        fi
      done
      case "${hit_bin}${hit_staging}" in
        11) boot_in_bin=$((boot_in_bin + 1)); boot_in_staging=$((boot_in_staging + 1)) ;;
        10) boot_in_bin=$((boot_in_bin + 1)) ;;
        01) boot_in_staging=$((boot_in_staging + 1)) ;;
        *)
          boot_text+="${boot}"$'\n'
          boot_count=$((boot_count + 1))
          boot_in_none=$((boot_in_none + 1))
          ;;
      esac
    done

    local checked=$((planned_count - missing_count - boot_count))
    local total=${planned_count}
    if [[ $((missing_count + boot_count)) -eq 0 ]]; then
      verdict="✅ 全部成功（${total} 个均产出产物）"
    else
      verdict="⚠️ $((missing_count + boot_count)) 个未产出（详见下方折叠块）"
    fi
    printf '| 编译验证 | %s / %s | %s |\n' "${checked}" "${total}" "${verdict}"

    # 两类未产出合成一份清单，供下方折叠块使用；引导固件标注出来以免与包混淆。
    if [[ -n "${boot_text}" ]]; then
      boot_ok_text="$(printf '%s' "${boot_text}" | sed '/^$/d; s/$/（引导固件，产物为 .bin\/.fip）/')"
      if [[ -n "${missing_text}" ]]; then
        missing_text="${missing_text}"$'\n'"${boot_ok_text}"
      else
        missing_text="${boot_ok_text}"
      fi
      missing_count=$((missing_count + boot_count))
    fi
  fi
  printf '\n'

  local fence
  # 反引号用 \x60 生成，避免围栏字面量在 shell 里被当成命令替换。
  fence="$(printf '\x60\x60\x60')"

  if [[ ${installed_count} -gt 0 ]]; then
    printf '<details><summary>装进固件的包（%s 个）</summary>\n\n%stext\n%s\n%s\n\n</details>\n\n' \
      "${installed_count}" "${fence}" "${installed}" "${fence}"
  fi
  if [[ ${built_count} -gt 0 ]]; then
    printf '<details><summary>编译产出的包（%s 个）</summary>\n\n%stext\n%s\n%s\n\n</details>\n\n' \
      "${built_count}" "${fence}" "${built}" "${fence}"
  fi
  if [[ -n "${missing_text:-}" ]]; then
    printf '<details><summary>选中但未产出产物的项（%s 个）</summary>\n\n%stext\n%s\n%s\n\n</details>\n\n' \
      "${missing_count}" "${fence}" "${missing_text}" "${fence}"
  fi
  if [[ ${orphan_count} -gt 0 ]]; then
    printf '<details><summary>未生效的变体开关（%s 个）</summary>\n\n%stext\n%s\n%s\n\n</details>\n\n' \
      "${orphan_count}" "${fence}" "${orphans}" "${fence}"
    # 这类项不是编译失败，也不是"配置残留"——实测从干净的根 .config 跑 make defconfig
    # 就会**自动生成**它们，因为对应的 Config.in 写了 default y（且无 depends 约束）。
    # 因此不能给"重新 defconfig 即可消失"这种错误建议：defconfig 只会把它再生成一遍。
    # 反引号用 \x60 生成：字面反引号在单引号串里会被 shellcheck 判成笔误（SC2016），
    # 与仓库其他位置的处理一致。这里它是 Markdown 行内代码，不是命令替换。
    local tick
    tick="$(printf '\x60')"
    printf '%s\n' "以上开关的宿主包未被选中，因此开关虽然为 y，合入固件后并不生效。"
    printf '%s\n' "它们由对应的 ${tick}Config.in${tick} 里 ${tick}default y${tick} 自动生成，${tick}make defconfig${tick} 会再次产生，不是残留、无需清理。"
    printf '%s\n\n' "若确实要启用，选中宿主包即可；若要彻底消除该行，只能在 ${tick}Config.in${tick} 里去掉默认值。"
  fi
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
  printf '### 构建产物\n\n'
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
  printf '### 耗时与缓存\n\n'
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
  printf '### 失败详情\n\n'
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
    printf '### 上游更新\n\n未提供上游 commit 信息。\n\n'
    return 0
  fi
  printf '### 上游更新\n\n| 项 | 值 |\n| --- | --- |\n'
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
  printf '### 本次结果\n\n| 项 | 值 |\n| --- | --- |\n'
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
      printf '### 明细\n\n'
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

main() {
  local mode="${1:-build}"
  case "${mode}" in
    build | update-checker | dependency-auditor | syntax-linter) ;;
    *)
      log_warning "未知模式 '${mode}'，按 build 处理"
      mode="build"
      ;;
  esac

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
  )"

  emit_summary "${summary}"
  uses_build_logs "${mode}" && flush_error_to_stderr
  return 0
}

main "$@"
