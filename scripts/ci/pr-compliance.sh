#!/bin/bash
#######################################
# PR 合规门禁（scripts/ci/pr-compliance.sh）
#
# 为什么需要它：分支保护只能引用一个“必需检查”，而 PR 的合规性散落在很多处（分支命名、
# 来源仓库、摘要溯源、变更范围、禁改路径）。拆成多个 job 会让分支保护配置随重构漂移，
# 因此这里收成一个 job / 一个脚本：任何一条不合规 => 整体 RESULT FAIL => 必需检查项变红。
#
# 校验项（id 稳定）：
#   P1..P8、P10、P11 摘要溯源（委托 scripts/ci/verify-summary-provenance.sh，结论并入本脚本；
#           溯源失败即整体 FAIL，一份“✅ 成功”的摘要不再能自证）
#           摘要正文来自【PR 描述】里的 build-summary 托管块（logs/summary.md 仍被 .gitignore
#           忽略、不入库），由 workflow 用 env 把 PR 描述原文传成 PR_BODY。
#   PX      溯源校验脚本没给出结论（异常退出），按失败处理，不静默放过
#   C1  分支来源合法：不得是受保护名，必须匹配约定前缀（BRANCH_PATTERN / BRANCH_ALLOWLIST 可覆盖）
#   C2  来源仓库与目标仓库相同（ALLOW_FORK_PR=1 才允许 fork）
#   C3  PR 描述含 build-summary 托管块（摘要正文由 PR 描述承载，logs/ 不入库）
#   C4  变更范围：文件数、单文件新增行数、与摘要“变更文件数”一致
#   C5  禁改路径：logs/ 下任何路径（摘要只用 PR 描述承载，不入库）、明文 .config、keys/ 下私钥、
#       immortalwrt/ 子模块内容、.git 内部路径
#   C6  托管块里的变更文件数与变更文件指纹都必须与本 PR 真实变更一致
#   C7  本 PR 每条提交信息符合 <emoji> <type>(<scope>): <说明>（merge/dependabot 等
#       非人写提交豁免；type/scope/长度阈值可覆盖）
#   C8  编译完整性：溯源块「未产出数」必须为 0。应编产物数为 0、两键为 unknown、键缺失或读不到溯源块，一律 FAIL —— 没有证据不等于合格，默认放行会让这条门禁形同虚设
#
# 可变阈值一律走环境变量，默认值集中定义在下面的常量里（改默认值只改一处）：
#   MAX_CHANGED_FILES=60   变更文件数上限（契约 A 口径：排除 logs/summary.md）
#   MAX_FILE_LINES=1500    单个文件新增行数上限
#   BRANCH_PATTERN         C1 的允许前缀正则，默认 ^(feat|fix|chore|docs|refactor|perf|test|build|ci|revert)/
#   BRANCH_ALLOWLIST       C1 额外放行的分支名（空格分隔），优先级高于受保护名与正则
#   ALLOW_FORK_PR=1        C2 允许来自 fork 的 PR（默认要求同仓库）
#   MAX_COMMIT_SUBJECT_LEN=72  C7 标题正文长度上限（按字符计，口径见 C7 常量处的注释）
#   COMMIT_TYPE_PATTERN    C7 允许的 type 清单正则（默认与 BRANCH_PATTERN 同一套词表）
#   COMMIT_SCOPE_PATTERN   C7 允许的 scope 正则，默认 ^[a-z0-9._-]+$
#   MAX_MISSING_PACKAGES=0 C8 允许的未产出项数上限。**C8 没有可调阈值**：0 是硬编码的语义，
#       不是规模问题 —— 部分软件包没被编译出来会让固件缺功能、且用户排查不到根因，这不是
#       “改动太大所以放宽”能解释的。保留这个变量只为确需排查时临时覆盖：放宽等于关掉这条
#       门禁，在 PR 里这么做必须在描述里写明理由。
#   dsh 任务的验收要求“阈值写进注释说明默认值来源”，来源即 R0 任务书：60/1500 是
#   审阅者在单次 PR 里能真正读完的规模上限，超出的改动应拆 PR 而不是调大阈值。
#
# 输出格式（契约 D）：每条检查一行 PASS/FAIL/SKIP，最后一行 RESULT PASS|FAIL，仅 PASS 退出 0；
# 每个 FAIL 额外发布 ::error 注解；$GITHUB_STEP_SUMMARY 已设置时追加一张 Markdown 表。
#
# 约定：变更清单统一走“merge-base..HEAD 的已提交差异”，基准解析顺序与
# scripts/ci/verify-summary-provenance.sh 完全一致（SUMMARY_BASE_REF -> PR_BASE_REF ->
# origin/main -> main）。两处各写一份的原因：本仓库规定 CI 脚本互不 source，
# 改基准解析逻辑时【必须同步两处】，否则 C4/C6 与 P7/P8 会用不同基准得出矛盾结论。
#
# 依赖：bash、git、GNU date（仅追溯脚本用到 sha256sum）。不用 jq / python。
# 临时文件：仅一个导出 facts 的 mktemp 文件，EXIT 时删除。
#######################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly SUMMARY_PATH="logs/summary.md"
readonly VERIFIER="${SCRIPT_DIR}/verify-summary-provenance.sh"

readonly MAX_CHANGED_FILES_DEFAULT=60
readonly MAX_FILE_LINES_DEFAULT=1500
readonly BRANCH_PATTERN_DEFAULT='^(feat|fix|chore|docs|refactor|perf|test|build|ci|revert)/'
# C8 的默认值：0 个未产出。见文件头阈值区说明，放宽等于关掉这条门禁。
readonly MAX_MISSING_PACKAGES_DEFAULT=0

# C7 标题长度上限：按「字符」计而不是按字节 —— 按字节计的话 4 字节 emoji 和 3 字节汉字会被
# 算成多个字符，同样长度的中文标题无处不超；72 取的是审阅者在 diff 列表里能一眼读完一行标题
# 的长度（也是 git 社区通行口径）。
# 口径细节：只算「正文」（去掉开头 emoji 与其后的一个空格）。理由是 emoji 前缀的码位个数本身
# 就不一致（🔥 是 1 个，带变体选择符/ZWJ 的 emoji 是 2 到 3 个），把它算进长度会让同一段正文
# 换个 emoji 就时超时超；72 约束的是人真正读的那段字。实测本仓库历史最长的一条正文为 71 字符。
readonly MAX_COMMIT_SUBJECT_LEN_DEFAULT=72
# type 词表与分支前缀（BRANCH_PATTERN）故意保持同一套：读者只需要记一份词表。
readonly COMMIT_TYPE_PATTERN_DEFAULT='^(feat|fix|chore|docs|refactor|perf|test|build|ci|revert)$'
# scope 只允许小写 ASCII：大写/空格/中文会让 scope 变成自由文本，git log --grep 与
# 自动生成变更日志时都无法按 scope 归并。
readonly COMMIT_SCOPE_PATTERN_DEFAULT='^[a-z0-9._-]+$'
# 受保护名：这些分支上的提交只应通过 PR 汇入，PR 头分支叫这些名字说明是在直接改主干；
# release/ 前缀同理（发布分支由维护者直接推送补丁）。
readonly PROTECTED_BRANCHES="main master gh-pages release develop"
readonly PROTECTED_PREFIXES="release/"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a REPORT_ROWS=()
declare -a FAIL_IDS=()

single_line() {
    printf '%s' "$1" | tr '\n\r' '  '
}

md_cell() {
    printf '%s' "$1" | tr '\n\r' '  ' | sed 's/|/\\|/g'
}

report_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    local note
    note="$(single_line "$2")"
    printf 'PASS %s %s\n' "$1" "$note"
    REPORT_ROWS+=("| $1 | ✅ 通过 | $(md_cell "$note") |")
}

publish_annotation() {
    printf '::error title=%s::%s\n' "$1" "$(single_line "$2")"
}

report_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAIL_IDS+=("$1")
    local note
    note="$(single_line "$2")"
    printf 'FAIL %s %s\n' "$1" "$note"
    REPORT_ROWS+=("| $1 | ❌ 失败 | $(md_cell "$note") |")
    publish_annotation "$1" "$note"
}

report_skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    local note
    note="$(single_line "$2")"
    printf 'SKIP %s %s\n' "$1" "$note"
    REPORT_ROWS+=("| $1 | ⏭️ 跳过 | $(md_cell "$note") |")
}

join_notes() {
    local sep="$1"
    shift
    local out="" item
    for item in "$@"; do
        out="${out:+${out}${sep}}${item}"
    done
    printf '%s' "$out"
}

# 与 verify-summary-provenance.sh 同一指纹规则（契约 A）：C6 要拿真实变更算一次。
fingerprint_of_stdin() {
    local hex
    hex="$(sha256sum | cut -d' ' -f1)"
    printf 'sha256:%s\n' "$hex"
}

flush_step_summary() {
    local result="$1" row
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    {
        printf '### PR 合规门禁（pr-compliance）\n\n'
        printf '| 检查 | 结果 | 说明 |\n'
        printf '| --- | --- | --- |\n'
        for row in "${REPORT_ROWS[@]}"; do
            printf '%s\n' "$row"
        done
        printf '\n**结论：** RESULT %s（通过 %d / 失败 %d / 跳过 %d）\n' \
            "$result" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

resolve_base_ref() {
    local candidate
    for candidate in "${SUMMARY_BASE_REF:-}" "${PR_BASE_REF:-}" "origin/main" "main"; do
        [[ -n "$candidate" ]] || continue
        if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# 阈值只接受非负整数：环境变量写错时退回默认值，而不是让比较运算报错中断。
sanitize_int() {
    local value="$1" fallback="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

# C7 用的字符长度：UTF-8 字符数 = 非续字节的个数（去掉所有 0x80..0xBF 续字节后数字节）。
# 为什么不用 ${#s} 或 wc -m：两者都随 locale 变，CI 里 LANG 未设置时会退化成按字节计数，
# 同一个标题在本地和 CI 上会得出两个长度；这里的口径与 locale 无关。
subject_char_len() {
    printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d '[:space:]'
}

# 首个 token 里是否含非 ASCII 字节 —— 用它判断「开头是 emoji」。
# 为什么不枚举 emoji 白名单：历史里同一个 type 用过不同 emoji（refactor 既有 🔥 也有 🚚），
# 白名单会把既有习惯判红；而且 Unicode 每版都在加 emoji，白名单注定过期。
# 在 C locale 下 [\x80-\xff] 按字节比较，与终端 locale 无关。
has_non_ascii() {
    local LC_ALL=C
    [[ "$1" == *[$'\x80'-$'\xff']* ]]
}

# C7 豁免：这些提交不是人写的（或此刻不是人该管的），判红只会逼维护者放弃门禁。
#   Merge pull request #  GitHub 网页上点「合并」时自动生成，正文由 GitHub 拼装；
#   Merge branch / tag  git merge 的默认信息，格式由 git 决定；
#   Revert              git revert 的默认信息，同上；
#   fixup! / squash!    git rebase -i 中间态，最终会被 squash 掉，此刻它长什么样不重要；
#   Initial commit      新建仓库/首次提交的自动信息；
#   dependabot          作者或提交者邮箱含 dependabot —— 标题由机器人按自己的模板拼装，
#                       人改不了，要求它符合本仓库格式等于让自动升级永远红。
commit_is_exempt() {
    local subject="$1" author_email="$2" committer_email="$3"
    case "$subject" in
    "Merge pull request #"*) return 0 ;;
    "Merge branch "* | "Merge tag "*) return 0 ;;
    "Revert "*) return 0 ;;
    "fixup!"* | "squash!"*) return 0 ;;
    "Initial commit"*) return 0 ;;
    esac
    case "${author_email}${committer_email}" in
    *dependabot*) return 0 ;;
    esac
    return 1
}

# 返回空串表示合规，否则返回第一条不合规原因：一条提交对着一个改法，一次报全反而让人
# 不知道先改哪一处。
commit_subject_problem() {
    local subject="$1" first rest type scope desc len
    # 正则放进变量：未转义的 ( ) 直接写在 [[ ]] 右侧会被当成模式列表语法，bash 解析不了。
    local form_re='^([a-z]+)\(([^)]*)\): (.*)$'
    if [[ "$subject" != *" "* ]]; then
        printf '标题里没有空格，约定形如「✨ feat(ci): 说明」'
        return 0
    fi
    first="${subject%% *}"
    rest="${subject#* }"
    if ! has_non_ascii "$first"; then
        printf '开头缺少 emoji（首个 token「%s」全是 ASCII）' "$first"
        return 0
    fi
    if ! [[ "$rest" =~ $form_re ]]; then
        printf 'emoji 之后不是「<type>(<scope>): <说明>」（括号、冒号、冒号后那个空格缺一不可）'
        return 0
    fi
    type="${BASH_REMATCH[1]}"
    scope="${BASH_REMATCH[2]}"
    desc="${BASH_REMATCH[3]}"
    if ! [[ "$type" =~ $COMMIT_TYPE_PATTERN ]]; then
        printf 'type「%s」不在约定清单里' "$type"
        return 0
    fi
    if [[ -z "$scope" ]]; then
        printf '缺少 scope（括号里要有内容，如 feat(ci)）'
        return 0
    fi
    if ! [[ "$scope" =~ $COMMIT_SCOPE_PATTERN ]]; then
        printf 'scope「%s」有非法字符（只允许小写字母、数字、. _ -）' "$scope"
        return 0
    fi
    if [[ -z "$desc" ]]; then
        printf '冒号之后没有说明'
        return 0
    fi
    len="$(subject_char_len "$rest")"
    if [[ "$len" =~ ^[0-9]+$ ]] && ((len > MAX_COMMIT_SUBJECT_LEN)); then
        printf '标题正文 %s 字符，超过上限 %s 字符' "$len" "$MAX_COMMIT_SUBJECT_LEN"
        return 0
    fi
    return 0
}

FACTS_FILE=""
# shellcheck disable=SC2329  # 只由下面的 EXIT trap 调用，静态分析看不到这层引用
cleanup_facts() {
    if [[ -n "$FACTS_FILE" ]]; then
        rm -f "$FACTS_FILE" 2>/dev/null || true
    fi
}
trap cleanup_facts EXIT

cd "$REPO_ROOT" || {
    printf 'FAIL C0 无法进入仓库根目录 %s\nRESULT FAIL\n' "$REPO_ROOT"
    exit 2
}

MAX_CHANGED_FILES="$(sanitize_int "${MAX_CHANGED_FILES:-}" "$MAX_CHANGED_FILES_DEFAULT")"
MAX_FILE_LINES="$(sanitize_int "${MAX_FILE_LINES:-}" "$MAX_FILE_LINES_DEFAULT")"
BRANCH_PATTERN="${BRANCH_PATTERN:-$BRANCH_PATTERN_DEFAULT}"
BRANCH_ALLOWLIST="${BRANCH_ALLOWLIST:-}"
MAX_COMMIT_SUBJECT_LEN="$(sanitize_int "${MAX_COMMIT_SUBJECT_LEN:-}" "$MAX_COMMIT_SUBJECT_LEN_DEFAULT")"
COMMIT_TYPE_PATTERN="${COMMIT_TYPE_PATTERN:-$COMMIT_TYPE_PATTERN_DEFAULT}"
COMMIT_SCOPE_PATTERN="${COMMIT_SCOPE_PATTERN:-$COMMIT_SCOPE_PATTERN_DEFAULT}"
MAX_MISSING_PACKAGES="$(sanitize_int "${MAX_MISSING_PACKAGES:-}" "$MAX_MISSING_PACKAGES_DEFAULT")"

#######################################
# 第一步：跑摘要溯源校验，把它的结论并入本脚本
#######################################
BLOCK_PRESENT=""
CLAIMED_COUNT=""
CLAIMED_FINGERPRINT=""
# C8 的两个输入（溯源块版本 2 的两新键）；空串表示“缺数据”，与 unknown 一样判失败。
CLAIMED_PLANNED=""
CLAIMED_MISSING=""
VERIFIER_RESULT=""
VERIFIER_OUTPUT=""
VERIFIER_RC=0

FACTS_FILE="$(mktemp "${TMPDIR:-/tmp}/pr-compliance-facts.XXXXXX" 2>/dev/null || true)"

if [[ -f "$VERIFIER" ]]; then
    # CI_VERIFIER_CHILD=1：注解与 step summary 由本脚本统一发布，避免同一条失败出现两次。
    # 只捕获 stdout：子脚本的 stderr 直接进 CI 日志，便于定位它自身的问题。
    VERIFIER_OUTPUT="$(PROVENANCE_FACTS_FILE="$FACTS_FILE" CI_VERIFIER_CHILD=1 bash "$VERIFIER")" || VERIFIER_RC=$?
else
    VERIFIER_RC=127
fi

if [[ -n "$FACTS_FILE" && -f "$FACTS_FILE" ]]; then
    while IFS= read -r fact; do
        case "$fact" in
        result=*) VERIFIER_RESULT="${fact#result=}" ;;
        block_present=*) BLOCK_PRESENT="${fact#block_present=}" ;;
        changed_count=*) CLAIMED_COUNT="${fact#changed_count=}" ;;
        changed_fingerprint=*) CLAIMED_FINGERPRINT="${fact#changed_fingerprint=}" ;;
        planned_count=*) CLAIMED_PLANNED="${fact#planned_count=}" ;;
        missing_count=*) CLAIMED_MISSING="${fact#missing_count=}" ;;
        esac
    done <"$FACTS_FILE"
fi

# 把子脚本的 PASS/FAIL/SKIP 原样并入本脚本的结论：id 不变，读者可以按 P/C 前缀对应任务书。
child_fail_seen=false
while IFS= read -r line; do
    case "$line" in
    PASS\ * | FAIL\ * | SKIP\ *)
        status="${line%% *}"
        rest="${line#* }"
        if [[ "$rest" == *" "* ]]; then
            child_id="${rest%% *}"
            child_note="${rest#* }"
        else
            child_id="$rest"
            child_note=""
        fi
        # 原样转发：契约 D 要求每条检查在 stdout 都有一行，父脚本不能只统计不输出。
        printf '%s\n' "$line"
        case "$status" in
        PASS)
            PASS_COUNT=$((PASS_COUNT + 1))
            REPORT_ROWS+=("| $child_id | ✅ 通过 | $(md_cell "$child_note") |")
            ;;
        FAIL)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAIL_IDS+=("$child_id")
            child_fail_seen=true
            REPORT_ROWS+=("| $child_id | ❌ 失败 | $(md_cell "$child_note") |")
            # 子脚本在 CI_VERIFIER_CHILD=1 下已关闭注解，这里补发，保证每个 FAIL 都有注解。
            publish_annotation "$child_id" "$child_note"
            ;;
        SKIP)
            SKIP_COUNT=$((SKIP_COUNT + 1))
            REPORT_ROWS+=("| $child_id | ⏭️ 跳过 | $(md_cell "$child_note") |")
            ;;
        esac
        ;;
    *) ;;
    esac
done <<<"$VERIFIER_OUTPUT"

if [[ "$VERIFIER_RESULT" != "PASS" && "$child_fail_seen" == false ]]; then
    report_fail PX "摘要溯源校验脚本未给出结论（rc=$VERIFIER_RC）：请确认 scripts/ci/verify-summary-provenance.sh 存在且可执行，勿在门禁失效时放行"
fi

#######################################
# 变更清单（C4/C5/C6 共用一份，口径：已提交差异，排除 logs/summary.md）
#######################################
BASE_REF=""
BASE_COMMIT=""
declare -a CHANGED_ALL=()
declare -a CHANGED=()
DIFF_OK=false

if git rev-parse --git-dir >/dev/null 2>&1; then
    if BASE_REF="$(resolve_base_ref)"; then
        BASE_COMMIT="$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
    else
        BASE_REF=""
        BASE_COMMIT=""
    fi
    if [[ -n "$BASE_COMMIT" ]]; then
        mapfile -t CHANGED_ALL < <(git -c core.quotePath=false diff --name-only "$BASE_COMMIT" HEAD -- 2>/dev/null || true)
        for path in "${CHANGED_ALL[@]}"; do
            if [[ "$path" != "$SUMMARY_PATH" ]]; then
                CHANGED+=("$path")
            fi
        done
        DIFF_OK=true
    fi
fi

#######################################
# C1 分支来源合法
#######################################
if [[ -z "${PR_HEAD_REF:-}" ]]; then
    report_skip C1 "未提供 PR_HEAD_REF（本地运行属正常情况）"
else
    allowlisted=false
    # shellcheck disable=SC2086  # 故意不引号：BRANCH_ALLOWLIST 是空格分隔的清单
    for allowed in $BRANCH_ALLOWLIST; do
        if [[ "$allowed" == "$PR_HEAD_REF" ]]; then
            allowlisted=true
        fi
    done
    if [[ "$allowlisted" == true ]]; then
        report_pass C1 "分支 $PR_HEAD_REF 命中 BRANCH_ALLOWLIST，按显式放行处理"
    else
        c1_issues=()
        case " $PROTECTED_BRANCHES " in
        *" $PR_HEAD_REF "*)
            c1_issues+=("「$PR_HEAD_REF」是受保护分支名，PR 头分支不能直接叫这个名字")
            ;;
        esac
        # shellcheck disable=SC2086  # 故意不引号：PROTECTED_PREFIXES 是空格分隔的清单
        for prefix in $PROTECTED_PREFIXES; do
            case "$PR_HEAD_REF" in
            "$prefix"*)
                c1_issues+=("「$PR_HEAD_REF」落在受保护前缀 $prefix 下，发布分支不接受 PR")
                ;;
            esac
        done
        if ! [[ "$PR_HEAD_REF" =~ $BRANCH_PATTERN ]]; then
            c1_issues+=("「$PR_HEAD_REF」不匹配允许前缀 $BRANCH_PATTERN")
        fi
        if ((${#c1_issues[@]} == 0)); then
            report_pass C1 "分支 $PR_HEAD_REF 命名合规"
        else
            report_fail C1 "$(join_notes '；' "${c1_issues[@]}")：请把分支改名为 feat/xxx、fix/xxx 等约定前缀（dependabot/ 自动分支豁免；确需特例请用 BRANCH_ALLOWLIST 显式放行）"
        fi
    fi
fi

#######################################
# C2 来源仓库
#######################################
if [[ -z "${PR_HEAD_REPO_FULL_NAME:-}" || -z "${PR_REPO_FULL_NAME:-}" ]]; then
    report_skip C2 "未提供 PR_HEAD_REPO_FULL_NAME / PR_REPO_FULL_NAME（本地运行属正常情况）"
elif [[ "${PR_HEAD_REPO_FULL_NAME}" == "${PR_REPO_FULL_NAME}" ]]; then
    report_pass C2 "来源仓库与目标仓库一致：$PR_REPO_FULL_NAME"
elif [[ "${ALLOW_FORK_PR:-0}" == "1" ]]; then
    report_pass C2 "来源仓库 ${PR_HEAD_REPO_FULL_NAME} 与目标仓库 ${PR_REPO_FULL_NAME} 不同，但 ALLOW_FORK_PR=1 显式放行"
else
    report_fail C2 "来源仓库 ${PR_HEAD_REPO_FULL_NAME} 与目标仓库 ${PR_REPO_FULL_NAME} 不同：本仓库只接受同仓库分支的 PR；确需接受 fork 请设置 ALLOW_FORK_PR=1"
fi

#######################################
# C3 PR 描述里的摘要托管块
#######################################
if [[ "$BLOCK_PRESENT" == "yes" ]]; then
    report_pass C3 "PR 描述含 build-summary 托管块（摘要正文由 PR 描述承载，logs/ 不入库）"
elif [[ -z "$BLOCK_PRESENT" ]]; then
    report_skip C3 "无法从溯源校验结果里读到托管块状态（溯源脚本未给出结论，见 PX）"
else
    report_fail C3 "PR 描述缺少 build-summary 托管块：请用 build-summary 的 begin/end 标记各占一行，把本地生成的 logs/summary.md 全文粘在中间（logs/ 被 .gitignore 忽略，不要提交文件）"
fi

#######################################
# C4 变更范围
#######################################
if [[ "$DIFF_OK" != true ]]; then
    report_skip C4 "无法解析变更基准（试过 SUMMARY_BASE_REF、PR_BASE_REF、origin/main、main），跳过变更范围检查"
else
    c4_issues=()
    changed_total=${#CHANGED[@]}
    if ((changed_total > MAX_CHANGED_FILES)); then
        c4_issues+=("变更文件 $changed_total 个，超过上限 $MAX_CHANGED_FILES 个（拆成多个 PR 更易审）")
    fi
    if [[ -n "$CLAIMED_COUNT" && "$CLAIMED_COUNT" =~ ^[0-9]+$ && "$CLAIMED_COUNT" != "$changed_total" ]]; then
        c4_issues+=("摘要记录变更文件数 $CLAIMED_COUNT，真实为 $changed_total：摘要与真实变更脱节，请在最终提交前重新运行 bash scripts/ci/generate-summary.sh")
    fi

    added_total=0
    deleted_total=0
    big_files=()
    while IFS=$'\t' read -r added deleted path; do
        if [[ "$added" =~ ^[0-9]+$ ]]; then
            added_total=$((added_total + added))
        fi
        if [[ "$deleted" =~ ^[0-9]+$ ]]; then
            deleted_total=$((deleted_total + deleted))
        fi
        if [[ "$added" =~ ^[0-9]+$ ]] && ((added > MAX_FILE_LINES)); then
            big_files+=("$path（新增 $added 行）")
        fi
    done < <(git -c core.quotePath=false diff --numstat "$BASE_COMMIT" HEAD -- 2>/dev/null || true)

    if ((${#big_files[@]} > 0)); then
        c4_issues+=("$(join_notes '；' "${big_files[@]}") 超过单文件新增 $MAX_FILE_LINES 行上限（拆文件或拆 PR）")
    fi

    if ((${#c4_issues[@]} == 0)); then
        report_pass C4 "变更 $changed_total 个文件（阈值 $MAX_CHANGED_FILES），新增 $added_total 行 / 删除 $deleted_total 行，单文件新增均 <= $MAX_FILE_LINES，且与摘要一致"
    else
        report_fail C4 "$(join_notes '；' "${c4_issues[@]}")"
    fi
fi

#######################################
# C5 禁改路径（扫全量变更 CHANGED_ALL，含 logs/summary.md —— 正是这一条要拦的）
#
# 为什么单独拦 logs/：摘要现在只由 PR 描述承载，logs/ 被 .gitignore 整目录忽略；有人图省事
# git add -f 把 logs/summary.md（或构建日志）提交进来，门禁读的却是 PR 描述，两边必然脱节，
# 而且几百 KB 的日志会永久留在仓库历史里。C4/C6 继续用排除 logs/summary.md 的 CHANGED，
# 保持契约 A 的字节口径不变；这条规则只看“有没有入库”。
#######################################
if [[ "$DIFF_OK" != true ]]; then
    report_skip C5 "无法解析变更基准，跳过禁改路径检查"
else
    violations=()
    for path in "${CHANGED_ALL[@]}"; do
        base_name="$(basename "$path")"
        case "$path" in
        logs/*)
            violations+=("$path（摘要不该入库；logs/ 被 .gitignore 整目录忽略，强行 git add -f 会让摘要进入仓库历史，而门禁读的是 PR 描述 —— 请从变更中移除该文件（git rm --cached logs/summary.md））")
            ;;
        .config | */.config)
            violations+=("$path（明文 .config 会泄露设备配置）")
            ;;
        .git/* | */.git/*)
            violations+=("$path（.git 内部路径不允许入库）")
            ;;
        immortalwrt | immortalwrt/*)
            violations+=("$path（immortalwrt/ 是上游子模块目录，改动应由脚本或 DIY 机制完成）")
            ;;
        esac
        case "$base_name" in
        *.pem | id_rsa | id_ed25519)
            case "$path" in
            keys/* | */keys/*)
                violations+=("$path（keys/ 下的私钥/公钥材料不允许入库）")
                ;;
            esac
            ;;
        esac
    done
    if ((${#violations[@]} == 0)); then
        report_pass C5 "变更清单未命中禁改路径（logs/ 入库 / 明文 .config / keys 私钥 / immortalwrt 子模块内容 / .git 内部路径）"
    else
        report_fail C5 "命中禁改路径：$(join_notes '；' "${violations[@]}")：请按每条括号里的处置方式把路径从本次变更中移除后再提交"
    fi
fi

#######################################
# C6 托管块与本 PR 真实变更一致（文件数 + 指纹）
#######################################
if [[ "$DIFF_OK" != true ]]; then
    report_skip C6 "无法解析变更基准，跳过摘要与变更一致性检查"
else
    real_changed_count=${#CHANGED[@]}
    if ((real_changed_count == 0)); then
        report_skip C6 "当前分支与基准之间没有已提交差异（本地空跑属正常情况），跳过摘要一致性检查"
    else
        mapfile -t CHANGED_SORTED < <(printf '%s\n' "${CHANGED[@]}" | LC_ALL=C sort)
        real_fingerprint="$(printf '%s\n' "${CHANGED_SORTED[@]}" | fingerprint_of_stdin)"
        c6_issues=()
        if [[ -z "$CLAIMED_COUNT" ]]; then
            c6_issues+=("托管块里没有可用的「变更文件数」")
        elif [[ "$CLAIMED_COUNT" != "$real_changed_count" ]]; then
            c6_issues+=("托管块变更文件数 $CLAIMED_COUNT，真实 $real_changed_count")
        fi
        if [[ -z "$CLAIMED_FINGERPRINT" ]]; then
            c6_issues+=("托管块里没有可用的「变更文件指纹」")
        elif [[ "$CLAIMED_FINGERPRINT" != "$real_fingerprint" ]]; then
            c6_issues+=("指纹不一致（托管块 $CLAIMED_FINGERPRINT，真实 $real_fingerprint）")
        fi
        if ((${#c6_issues[@]} == 0)); then
            report_pass C6 "托管块的变更文件数与指纹均与真实变更一致（$real_changed_count 个文件，$real_fingerprint）"
        else
            report_fail C6 "$(join_notes '；' "${c6_issues[@]}")：摘要不是针对本 PR 当前变更生成的，请在本 PR 最后一个提交之后重新运行 bash scripts/ci/generate-summary.sh 并更新 PR 描述"
        fi
    fi
fi

#######################################
# C7 提交信息格式（<emoji> <type>(<scope>): <说明>）
#
# 为什么放进门禁：提交信息是 git log / blame / 变更日志生成器的唯一输入，格式一散
# （缺 scope、scope 大写、emoji 各写各的）就按 type 筛不了、也没法自动生成 release notes；
# 靠人自觉在十几个 PR 上维持不住，所以让必需检查替人记住。
# 判据只看本 PR 的提交（BASE_COMMIT..HEAD）：门禁只对本次变更负责，历史里已经不合规的
# 提交改不动（改它要 force-push 所有人的分支），所以不回头算旧账。
#######################################
if [[ -z "$BASE_COMMIT" ]]; then
    report_skip C7 "无法解析变更基准（试过 SUMMARY_BASE_REF、PR_BASE_REF、origin/main、main），跳过提交信息格式检查"
else
    commit_total=0
    c7_exempt=0
    c7_bad=()
    # 用 %x1f（单元分隔符）分隔字段：提交信息里可能有空格、竖线、中文标点，
    # 用空格或 --oneline 拼出来的字符串没法可靠拆分。
    while IFS=$'\x1f' read -r c7_sha c7_subject c7_ae c7_ce; do
        [[ -n "$c7_sha" ]] || continue
        commit_total=$((commit_total + 1))
        if commit_is_exempt "$c7_subject" "$c7_ae" "$c7_ce"; then
            c7_exempt=$((c7_exempt + 1))
            continue
        fi
        c7_problem="$(commit_subject_problem "$c7_subject")"
        if [[ -n "$c7_problem" ]]; then
            c7_bad+=("${c7_sha:0:7}「${c7_subject}」：${c7_problem}")
        fi
    done < <(git log --format='%H%x1f%s%x1f%ae%x1f%ce' "${BASE_COMMIT}..HEAD" 2>/dev/null || true)

    if ((commit_total == 0)); then
        report_skip C7 "当前分支与基准之间没有已提交差异（本地空跑属正常情况），跳过提交信息格式检查"
    elif ((${#c7_bad[@]} == 0)); then
        if ((c7_exempt == 0)); then
            report_pass C7 "本 PR 的 ${commit_total} 条提交信息均符合 <emoji> <type>(<scope>): <说明>（标题正文 <= $MAX_COMMIT_SUBJECT_LEN 字符）"
        else
            report_pass C7 "本 PR 的 ${commit_total} 条提交信息均符合 <emoji> <type>(<scope>): <说明>（其中 ${c7_exempt} 条是 merge / dependabot / fixup 等非人写提交，按约定豁免；标题正文 <= $MAX_COMMIT_SUBJECT_LEN 字符）"
        fi
    else
        c7_shown=("${c7_bad[@]:0:5}")
        c7_detail="$(join_notes '；' "${c7_shown[@]}")"
        if ((${#c7_bad[@]} > 5)); then
            c7_detail="${c7_detail}…等 ${#c7_bad[@]} 条"
        fi
        report_fail C7 "提交信息不符合 <emoji> <type>(<scope>): <说明>：${c7_detail}：用 git rebase -i 改写，或用 git commit --amend 修正最后一条（type 取 feat|fix|chore|docs|refactor|perf|test|build|ci|revert，scope 只用小写字母数字 . _ -，标题不超过 $MAX_COMMIT_SUBJECT_LEN 字符）"
    fi
fi

#######################################
# C8 编译完整性：未产出产物的项必须为 0
#
# 为什么单列一条门禁：P3 只保证“两键存在且格式合法”，一个合法的 153 仍能一路绿灯 ——
# 摘要写着“✅ 成功”，而 398 个选中包里 153 个根本没编出来。缺包在固件里表现为功能缺失，
# 用户装不上也定位不到根因，比构建直接失败更难发现，所以必须在合入前拦住。
#
# unknown / 缺失 / 应编为 0 一律判失败，且有别于“未产出 > 0”的另一套文案：
# generate-summary.sh 写 unknown 的语义是“无从证明”（非 build 模式、没读到 .config），
# 把“没有数据”当成“默认合格”就是给门禁留一个默认放行的洞。同理，读不到溯源块（P1 没过）
# 也不能 SKIP —— 没有完整性证据就不能合入。
#######################################
if [[ "$BLOCK_PRESENT" != "yes" ]]; then
    report_fail C8 "读不到溯源块（对应 P1 未通过），没有任何编译完整性证据：请先在 PR 描述里用 build-summary 的 begin/end 标记贴入完整的构建摘要，再重新运行本检查"
elif [[ -z "$CLAIMED_PLANNED" || -z "$CLAIMED_MISSING" ]]; then
    report_fail C8 "本次摘要缺少编译完整性数据，请下载该 PR 的构建产物后，在本 PR 的 head 提交上重新运行 bash scripts/ci/generate-summary.sh，把新摘要整段替换进 PR 描述（缺数据不等于通过）"
elif [[ "$CLAIMED_PLANNED" == "unknown" || "$CLAIMED_MISSING" == "unknown" ]]; then
    report_fail C8 "本次摘要缺少编译完整性数据，请下载该 PR 的构建产物后，在本 PR 的 head 提交上重新运行 bash scripts/ci/generate-summary.sh，把新摘要整段替换进 PR 描述（应编产物数「$CLAIMED_PLANNED」，未产出数「$CLAIMED_MISSING」；unknown 表示无从证明，不是 0）"
elif ! [[ "$CLAIMED_PLANNED" =~ ^[0-9]+$ && "$CLAIMED_MISSING" =~ ^[0-9]+$ ]]; then
    report_fail C8 "溯源块的「应编产物数 / 未产出数」不是整数（应编「$CLAIMED_PLANNED」，未产出「$CLAIMED_MISSING」）：块内取值只允许整数或小写 unknown，请重新生成摘要，不要手工编辑"
elif ((10#$CLAIMED_PLANNED == 0)); then
    report_fail C8 "本次摘要缺少编译完整性数据，请下载该 PR 的构建产物后，在本 PR 的 head 提交上重新运行 bash scripts/ci/generate-summary.sh，把新摘要整段替换进 PR 描述（应编产物数为 0，等于一次编译都没被证明过）"
elif ((10#$CLAIMED_MISSING > MAX_MISSING_PACKAGES)); then
    report_fail C8 "未产出 $CLAIMED_MISSING 项（应编 $CLAIMED_PLANNED）：部分选中的软件包没有被编译出来，固件会缺功能且难以定位，不能合入；请查看摘要里「选中但未产出产物的项」折叠块定位是哪些包，修掉后重新构建并重新生成摘要"
else
    report_pass C8 "未产出 0 项：应编的 $CLAIMED_PLANNED 个产物全部产出（编译完整性达标）"
fi

#######################################
# 结论
#######################################
if ((FAIL_COUNT == 0)); then
    FINAL_RESULT="PASS"
    EXIT_CODE=0
else
    FINAL_RESULT="FAIL"
    EXIT_CODE=1
fi

flush_step_summary "$FINAL_RESULT"
printf 'RESULT %s\n' "$FINAL_RESULT"
exit "$EXIT_CODE"
