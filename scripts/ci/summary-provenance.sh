#!/bin/bash
#
# 摘要溯源块（唯一实现）：把「这份摘要对应哪份代码」写成一段机器可读的 Markdown，
# 交给 CI 端脚本解析，并与 git 事实逐项比对。
#
# 为什么单独成文件：同一份数据有两个读者——generate-summary.sh 生成的摘要本身，
# 以及校验脚本。算法若复制两份，迟早出现"块里 3 个文件、校验脚本算出 4 个"的分歧；
# 分歧的后果是校验误报而不是功能故障，属于最难排查的一类问题。故计算与渲染只此一处。
#
# 用法（被 source，不单独执行）：
#   source scripts/ci/summary-provenance.sh
#   render_provenance_block      # 输出整段 Markdown（含 "#### 🔒 摘要溯源" 标题）
#                                标题层级为四级：整份摘要贴进 PR 描述后是「## 🔒 构建摘要」的子节
#
# 契约（格式版本 2）：块内固定 10 个键，**顺序即契约**——
#   格式版本 / 仓库 / 分支 / 提交 / 生成时间 / 变更基准 / 变更文件数 / 变更文件指纹 /
#   应编产物数 / 未产出数
# 末两键不是 git 事实：数值由 generate-summary.sh 的全局 _PKG_*_COUNT 提供（它先算好），
# 取不到时写 unknown 而不是 0，理由见 _prov_package_counts 上方注释。
#
# 环境变量：
#   SUMMARY_BASE_REF  变更基准 ref；缺省按 origin/main、main 依次尝试，都取不到则写 none
#
# 三条约束：
#   1) 不写日志文件：本文件被 generate-summary.sh source，而那支脚本的契约是 LOG_TO_FILE=false
#      （摘要自己写日志会污染 logs/ 的候选集，理由见 generate-summary.sh 顶部说明）。
#   2) 任何 git 失败都降级、不中断：build.sh 的 all 阶段会自动调用它，
#      构建结论不该被"算不出溯源"带跑。
#   3) 不使用 set -e：降级路径远多于硬失败路径，-e 只会让降级变成崩溃。

# 全局缓存：provenance_gather 只算一次，溯源块与"自动校验要点"表共用同一份数据。
# 初始值直接取降级值，某一步取不到东西时不必补写，保持原样即可。
# 格式版本 2：在版本 1 的 8 个键之后追加「应编产物数 / 未产出数」两个键。
# 旧摘要不存在（每次构建重新生成），故不做版本兼容，只改数字。
PROV_FORMAT_VERSION="2"
PROV_REPO="none"
PROV_BRANCH="detached"
PROV_COMMIT="none"
PROV_GENERATED_AT="none"
PROV_BASE_REF="none"
PROV_CHANGED_COUNT="0"
PROV_FINGERPRINT="sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
PROV_PATHS=()
_PROVENANCE_READY="false"

# 空清单的占位文案：变更文件数为 0 时围栏里只写这一行。
# 为什么需要它：围栏本身不能省——省了之后读者（和审阅者）无法区分"本次没有变更"
# 与"清单被裁剪/贴漏了"，而后者正是溯源块要防的事。占位行是给人看的说明文字，
# 不是路径，也【不参与指纹计算】：0 个变更的指纹仍是空字节串的 sha256（e3b0c442…）。
# 文案刻意不含反引号、括号、斜杠与空格，明显不是合法路径，避免被误读成文件名。
# 校验侧 scripts/ci/verify-summary-provenance.sh 有逐字相同的同名常量，改动时两处一起改。
PROV_EMPTY_LIST_NOTE="本次无变更文件"

# 告警走仓库统一的 logger；但本文件也可能被独立脚本 source（例如自检），
# 那时 logger 不一定在，故降级为直接写 stderr —— 不能因为少了日志函数就静默。
_prov_warn() {
  if declare -F log_warning >/dev/null 2>&1; then
    log_warning "$@"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
  return 0
}

# git 只读包装：吞掉 stderr，失败由调用方用"取到空值"表达。
# -c core.quotepath=false 是必需的：默认 core.quotepath=true 会把非 ASCII 路径
# 转义成 "\346\226\207" 这种八进制形态，那样算出的指纹与文件真实路径对不上。
_prov_git() {
  git -c core.quotepath=false "$@" 2>/dev/null
}

# 表格单元格：Markdown 里的 "|" 会提前断列、换行会拆行，统一压平再转义。
_prov_cell() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed 's/|/\\|/g'
}

# 仓库名：把 origin 的 url 归一化成 OWNER/REPO，同时兼容 ssh 与 https 两种写法。
#   git@github.com:Owner/Repo.git        -> Owner/Repo
#   https://github.com/Owner/Repo.git    -> Owner/Repo
#   ssh://git@host:2222/Owner/Repo.git   -> Owner/Repo
# 做法是"剥 .git -> 冒号当斜杠 -> 取最后两段"，不解析协议，因此带端口的怪异写法也能取到。
_prov_repo_from_url() {
  local url="${1:-}" path last owner
  [[ -n "${url}" ]] || return 0
  path="${url%.git}"
  path="${path//:/\/}"
  path="${path%/}"
  last="${path##*/}"
  owner="${path%/*}"
  owner="${owner##*/}"
  if [[ -n "${last}" && -n "${owner}" ]]; then
    printf '%s/%s' "${owner}" "${last}"
  fi
}

# 分支：detached HEAD 时 rev-parse 原样吐 "HEAD"，那不是分支名，按契约写 detached。
_prov_branch() {
  local branch
  branch="$(_prov_git rev-parse --abbrev-ref HEAD)" || branch=""
  if [[ -z "${branch}" || "${branch}" == "HEAD" ]]; then
    printf 'detached'
    return 0
  fi
  printf '%s' "${branch}"
}

# 变更基准解析：SUMMARY_BASE_REF 优先，其次 origin/main、main。
# 用 rev-parse --verify 判"这个 ref 在本仓库真能解析成提交"，而不是看名字猜——
# 浅克隆里 origin/main 这个名字存在、ref 却缺失，是很常见的形态。
_prov_resolve_base_ref() {
  local candidate
  local -a candidates=()
  if [[ -n "${SUMMARY_BASE_REF:-}" ]]; then
    candidates+=("${SUMMARY_BASE_REF}")
  fi
  candidates+=("origin/main" "main")
  for candidate in "${candidates[@]}"; do
    if _prov_git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

# 变更清单：共同祖先..HEAD 的【已提交】差异。
# 为什么从共同祖先起算而不是从 base 的头：分支落后时，base 上别人的改动会被算成"本次变更"。
# 为什么只取已提交部分（第二端写 HEAD）：契约 A 把变更源定义为 committed diff，
# 而校验脚本的 P7 正是用 "git diff <merge-base> HEAD" 重算的——两侧口径只要差一点点，
# 指纹就必然对不上，且报错信息指向的是"提交后没重算"，排查成本极高。
# 配套的生成时机也由同一条链决定：P10 要求生成时间不早于 HEAD 提交，也就是
# "先提交代码、再生成摘要、最后把摘要一起提交"。logs/summary.md 是本次生成的产物，
# 列进去就成了"摘要记录摘要自己"的自指，故按契约剔除。
_prov_changed_paths() {
  local base merge_base line
  # 变量名刻意带 _paths 后缀：本文件被 source 进 generate-summary.sh，那里已有一个
  # 同名标量 raw，同处一个作用域会被 lint 判成"一会儿数组一会儿字符串"（SC2178/SC2128）。
  local -a raw_paths=()
  PROV_BASE_REF="none"
  PROV_CHANGED_COUNT="0"
  PROV_PATHS=()

  base="$(_prov_resolve_base_ref)" || base=""
  [[ -n "${base}" ]] || return 0
  merge_base="$(_prov_git merge-base HEAD "${base}")" || merge_base=""
  # 两段历史无共同祖先（无关仓库拼在一起）时 merge-base 失败：
  # 既没有可信基准也没有可信清单，整体写 none，而不是留一个"有基准但 0 个文件"的怪状态。
  [[ -n "${merge_base}" ]] || return 0

  PROV_BASE_REF="${base}"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == "logs/summary.md" ]] && continue
    raw_paths+=("${line}")
  done < <(_prov_git diff --name-only "${merge_base}" HEAD --)

  # 契约要求按 LC_ALL=C 排序：字节序而非本地化序，才能与校验脚本逐字节对齐。
  if (( ${#raw_paths[@]} > 0 )); then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && PROV_PATHS+=("${line}")
    done < <(printf '%s\n' "${raw_paths[@]}" | LC_ALL=C sort)
  fi
  PROV_CHANGED_COUNT="${#PROV_PATHS[@]}"
  return 0
}

# 逐行吐出指纹输入字节流：每个路径 + 一个换行；空清单吐出零字节（契约的空字节串）。
_prov_emit_fingerprint_input() {
  local path
  if (( ${#PROV_PATHS[@]} > 0 )); then
    for path in "${PROV_PATHS[@]}"; do
      printf '%s\n' "${path}"
    done
  fi
  return 0
}

# 从 stdin 读字节流，输出 64 位小写 hex。
# 依次试 sha256sum / openssl / shasum / python3：CI 与本地发行版各不相同，
# 只要有一个在就能算出真指纹；全都没有才返回 1，由上层写 unavailable。
_prov_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + "\n")'
  else
    return 1
  fi
}

# 指纹 = sha256(每个路径 + 换行的字节串)，前缀 "sha256:"。
# 用 printf 逐行喂哈希工具，而不是先拼成一个大字符串再算：拼串会多出末尾换行、
# 也会在路径含空格/通配符时被 shell 二次解释，字节就不再是契约规定的那串。
_prov_fingerprint() {
  local hex
  hex="$(_prov_emit_fingerprint_input | _prov_sha256_hex)" || hex=""
  if [[ ! "${hex}" =~ ^[0-9a-f]{64}$ ]]; then
    PROV_FINGERPRINT="unavailable"
    _prov_warn "无法计算变更文件指纹（缺少 sha256sum/openssl/shasum/python3），本次写 unavailable"
    return 0
  fi
  PROV_FINGERPRINT="sha256:${hex}"
  return 0
}

# 采集一次并缓存。幂等：重复调用不会重复跑 git（摘要里两处要读同一份数据）。
provenance_gather() {
  if [[ "${_PROVENANCE_READY}" == "true" ]]; then
    return 0
  fi
  PROV_FORMAT_VERSION="2"
  # 生成时间取 UTC：摘要会被贴到 CI 页面与 issue 里，本地时区只会让读者自己换算。
  PROV_GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || PROV_GENERATED_AT=""
  [[ -n "${PROV_GENERATED_AT}" ]] || PROV_GENERATED_AT="none"
  PROV_REPO="$(_prov_repo_from_url "$(_prov_git remote get-url origin)")" || PROV_REPO=""
  [[ -n "${PROV_REPO}" ]] || PROV_REPO="none"
  PROV_BRANCH="$(_prov_branch)" || PROV_BRANCH=""
  [[ -n "${PROV_BRANCH}" ]] || PROV_BRANCH="detached"
  PROV_COMMIT="$(_prov_git rev-parse HEAD)" || PROV_COMMIT=""
  # 完整 40 位而非 --short：短 sha 跨仓库比对会撞，溯源要能唯一定位一个提交。
  if [[ ! "${PROV_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    PROV_COMMIT="none"
  fi
  _prov_changed_paths
  _prov_fingerprint
  _PROVENANCE_READY="true"
  return 0
}

# 溯源块最后两个键的取值：应编产物数 / 未产出数。
#
# 数据来源是 generate-summary.sh 的两个全局 _PKG_PLANNED_COUNT / _PKG_MISSING_COUNT：
# 它们由 render_package_section -> _compute_verification 算好，而 main() 里
# render_package_section 先于 render_provenance_block 执行，故此处只读、绝不重算——
# 重算就是第二份实现，迟早出现"块里 398、表里 397"的分歧（本文件存在的理由）。
#
# 为什么缺值写 unknown 而不是 0（CI 侧把 unknown 当"无法证明"，判失败而非放过）：
#   1) 非 build 模式（update-checker / dependency-auditor / syntax-linter）根本不调用
#      render_package_section，两个变量还停在初始值 0。照写 0 会被读成"应编 0 个、
#      未产出 0 个"，也就是"全部产出"——一次没编译过的流水线凭空拿到满分。
#   2) build 模式下没读到 immortalwrt/.config 时 _PKG_PLANNED_COUNT 同样是 0，
#      "应编 0 个"不是事实，只是无从证明。
#   3) 两个键必须同进同退：只给分母不给分子，读者仍会把未产出读成 0。
# 写法与块内其它键的降级值一致（none / unavailable）：小写、无空格、无单位。
_prov_package_counts() {
  local planned="${_PKG_PLANNED_COUNT:-}"
  local missing="${_PKG_MISSING_COUNT:-}"
  # 整数校验：上游若塞进空串或异常文本，这里宁可写 unknown，也不在块里留一个非数字怪值。
  if [[ "${planned}" =~ ^[0-9]+$ ]] && (( planned > 0 )) && [[ "${missing}" =~ ^[0-9]+$ ]]; then
    printf '%s %s' "${planned}" "${missing}"
    return 0
  fi
  printf 'unknown unknown'
  return 0
}

# 渲染整段溯源块。放在哪里由调用方决定：契约要求它是整份摘要的最后一段。
# 键的顺序是契约的一部分（10 个，见文件头）：CI 侧按位置或按中文标签解析，乱序即解析失败。
render_provenance_block() {
  provenance_gather
  local planned_count missing_count
  read -r planned_count missing_count <<<"$(_prov_package_counts)"
  printf '#### 🔒 摘要溯源\n\n'
  printf '<!-- dsh-provenance:begin -->\n\n'
  printf '| 项 | 值 |\n| --- | --- |\n'
  printf '| 格式版本 | %s |\n' "$(_prov_cell "${PROV_FORMAT_VERSION}")"
  printf '| 仓库 | %s |\n' "$(_prov_cell "${PROV_REPO}")"
  printf '| 分支 | %s |\n' "$(_prov_cell "${PROV_BRANCH}")"
  printf '| 提交 | %s |\n' "$(_prov_cell "${PROV_COMMIT}")"
  printf '| 生成时间 | %s |\n' "$(_prov_cell "${PROV_GENERATED_AT}")"
  printf '| 变更基准 | %s |\n' "$(_prov_cell "${PROV_BASE_REF}")"
  printf '| 变更文件数 | %s |\n' "$(_prov_cell "${PROV_CHANGED_COUNT}")"
  printf '| 变更文件指纹 | %s |\n' "$(_prov_cell "${PROV_FINGERPRINT}")"
  # 契约变更（版本 1 -> 2）：这两行必须排在指纹之后，顺序固定。
  printf '| 应编产物数 | %s |\n' "$(_prov_cell "${planned_count}")"
  printf '| 未产出数 | %s |\n\n' "$(_prov_cell "${missing_count}")"
  # 围栏【无条件】输出，包括清单为空时——省掉围栏就分不清"本次无变更"和"清单被裁剪"，
  # 而后者正是溯源块要发现的事。空清单时围栏里写一行占位文案（PROV_EMPTY_LIST_NOTE），
  # 它只是给读者的说明，不进指纹计算：0 个变更的指纹仍是空字节串的 sha256。
  printf '\x60\x60\x60text\n'
  if (( ${#PROV_PATHS[@]} > 0 )); then
    _prov_emit_fingerprint_input
  else
    printf '%s\n' "${PROV_EMPTY_LIST_NOTE}"
  fi
  printf '\x60\x60\x60\n\n'
  printf '<!-- dsh-provenance:end -->\n'
  return 0
}
