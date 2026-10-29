#!/bin/bash
#######################################
# 摘要溯源校验（scripts/ci/verify-summary-provenance.sh）
#
# 为什么需要它：构建摘要（原来写在 logs/summary.md）现在由贡献者贴进【PR 描述】——logs/ 继续
# 被 .gitignore 整目录忽略，摘要文件不入库。既然摘要不进 diff，审阅者无法从仓库历史判断它是不是
# 本次运行产出的：一个 PR 可以把上一轮构建的摘要原样贴进描述，或从别的分支复制一份，读者看到
# “✅ 成功”就以为这次 PR 真的构建过。本脚本把“这段摘要确由本 PR 产出”变成可机械判定的结论。
#
# 数据源（二选一，PR_BODY 优先）：
#   PR_BODY         PR 描述的原文（CI 由 workflow 用 env 传入）
#   PR_BODY_FILE    指向一个含 PR 描述原文的文件（本地测试用，免去在命令行里塞多行文本）
#   两者都未设置  => 本地没有可校验的输入：P1..P11 全部 SKIP，RESULT PASS
#                    （与 C1/C2 的“缺 CI 变量降级 SKIP”同一口径：没有输入不等于违规）
#   设置了但为空  => FAIL P1（CI 里 PR_BODY 恒有值，空即“贡献者没写摘要”）
#
# 摘要托管块契约（取代旧版“插在文件末尾”）：
#   build-summary 的 begin/end 标记各占一行，中间是本地 logs/summary.md 全文。
#   - 标记允许缩进与行尾空白，大小写敏感；区间外内容一律忽略（PR 模板说明文字不影响判定）。
#   - build-summary 的 begin/end 各只允许出现一次：出现第二组即判 FAIL（防“两段摘要取哪段”）。
#   - 区间内必须有溯源小节：dsh-provenance 的 begin/end + 10 行中文标签表（格式版本 2）
#     + 紧随「变更文件指纹」键之后的围栏文本块（围栏【永远】存在，变更文件数为 0 时
#     里面只有一行占位文案「本次无变更文件」，见 PROV_EMPTY_LIST_NOTE）。
#   - 区间长度上限 60000 字符（防有人把整份构建日志贴进来）。按【字符】而非字节计：
#     摘要含大量中文，按字符更直观；这是刻意的选择，不是疏漏。
#
# 指纹规则（契约 A，与生成侧必须逐字节一致）：
#   bytes = 依次拼接 “路径 + 换行”；路径来自本 PR 的变更清单（merge-base..HEAD，
#   LC_ALL=C 排序，排除 logs/summary.md —— 它已不入库，排除只是保持字节规则不变）；
#   output = "sha256:" + 64 位小写 hex；空清单 => 空字节串的 sha256。
#
# 变更基准前提：本仓库默认目标是 main；若 PR 目标是其它分支，生成侧与校验侧【都必须】显式设置
#   SUMMARY_BASE_REF，否则两边算出的变更清单不同，指纹必然对不上（这一条不新增代码，只作前提声明）。
#
# 检查项（id 稳定：分支保护只看整体 RESULT，人按 id 定位问题）：
#   P1  PR 描述含 build-summary 托管块、块非空、且不超过 60000 字符
#   P2  托管块唯一（begin/end 各一次）；溯源块唯一；溯源小节是托管块内最后一节
#   P3  10 个键齐全且值非空；格式版本 == 2（只认 2，不兼容 1）；应编产物数 / 未产出数
#      只能是整数或小写 unknown；提交 == 40 位小写 hex；生成时间可解析
#   P4  仓库 == PR_HEAD_REPO_FULL_NAME（为空时回退 PR_REPO_FULL_NAME）
#   P5  分支 == PR_HEAD_REF
#   P6  块内自洽：变更文件数 == 清单行数（占位行「本次无变更文件」不计入清单），
#      重算清单指纹 == 变更文件指纹；清单围栏必须存在，缺失即 FAIL
#   P7  指纹与本 PR 真实变更一致（按 merge-base..HEAD 重算）
#   P8  块内「提交」== PR_HEAD_SHA（“由本 PR 产出”的最强证据）；缺失 PR_HEAD_SHA 时降级为
#      “提交可从 HEAD 到达且距 HEAD <= 5 个提交”
#   P10 生成时间新鲜：不来自未来、不在 30 天前、不早于 HEAD 提交时间 6 小时
#   P11 摘要正文含「结论 / 运行信息 / 步骤状态」三节
#   PX  校验脚本自身异常（只在无法执行契约时出现，由 pr-guard.sh 判定）
#
# 环境变量（全部可选）：
#   PR_BODY / PR_BODY_FILE  数据源，见上。
#   PR_HEAD_SHA             P8 的比对基准。
#   PR_HEAD_REPO_FULL_NAME / PR_REPO_FULL_NAME   P4 的比对基准（头仓库优先）。
#   PR_HEAD_REF             P5 的比对基准。
#   PR_BASE_REF / SUMMARY_BASE_REF   变更基准，解析顺序：SUMMARY_BASE_REF -> PR_BASE_REF -> origin/main -> main。
#   PROVENANCE_FACTS_FILE   被 pr-guard.sh 调用时导出 key=value，避免第二个脚本再实现一份解析。
#   CI_VERIFIER_CHILD=1     同上：关闭本脚本的 GitHub 注解与 step summary，由父脚本统一发布。
#
# 退出码：0 通过（允许 SKIP）；1 存在 FAIL；2 脚本自身无法执行。
# 依赖：bash、git、sha256sum、GNU date。不依赖 jq / python。
# 临时文件：本脚本不创建任何临时文件（全部在内存数组里）。
#######################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly SUMMARY_BEGIN_MARK='<!-- build-summary:begin -->'
readonly SUMMARY_END_MARK='<!-- build-summary:end -->'
readonly PROV_BEGIN_MARK='<!-- dsh-provenance:begin -->'
readonly PROV_END_MARK='<!-- dsh-provenance:end -->'

# 空清单占位文案，与生成侧 scripts/ci/summary-provenance.sh 的 PROV_EMPTY_LIST_NOTE 逐字一致
# （同一行赋值文本，改动时两处一起改）。生成侧在变更文件数为 0 时把这一行写进清单围栏：
# 围栏不能省——省了之后无法区分"本次无变更"与"清单被裁剪/贴漏了"，而后者正是溯源块要防的事。
# 解析时它是【唯一】被特殊识别的非路径内容：语义是"清单为空"，故不进 CLAIM_PATHS；
# 0 个变更的指纹仍是空字节串的 sha256，两侧重算结果一致。
PROV_EMPTY_LIST_NOTE="本次无变更文件"

readonly KEY_VERSION='格式版本'
readonly KEY_REPO='仓库'
readonly KEY_BRANCH='分支'
readonly KEY_COMMIT='提交'
readonly KEY_TIME='生成时间'
readonly KEY_BASE='变更基准'
readonly KEY_COUNT='变更文件数'
readonly KEY_FINGERPRINT='变更文件指纹'
# 格式版本 2 新增的两键（顺序即契约：排在指纹之后）。语义分别见 P3 与 C8：
#   应编产物数  本次构建计划产出多少个包（分母）
#   未产出数    其中有多少个没被编译出来（分子）；取值整数或小写 unknown（无从证明）
readonly KEY_PLANNED='应编产物数'
readonly KEY_MISSING='未产出数'
readonly PROV_KEYS=("${KEY_VERSION}" "${KEY_REPO}" "${KEY_BRANCH}" "${KEY_COMMIT}" "${KEY_TIME}" "${KEY_BASE}" "${KEY_COUNT}" "${KEY_FINGERPRINT}" "${KEY_PLANNED}" "${KEY_MISSING}")

readonly MAX_BLOCK_CHARS=60000
readonly PROV_TRAILING_SLACK_LINES=10
readonly MAX_SUMMARY_COMMIT_DISTANCE=5
readonly CLOCK_SKEW_SECONDS=600
readonly MAX_AGE_SECONDS=$((30 * 24 * 3600))
readonly HEAD_TIME_TOLERANCE_SECONDS=$((6 * 3600))

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

report_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAIL_IDS+=("$1")
    local note
    note="$(single_line "$2")"
    printf 'FAIL %s %s\n' "$1" "$note"
    REPORT_ROWS+=("| $1 | ❌ 失败 | $(md_cell "$note") |")
    if [[ "${CI_VERIFIER_CHILD:-0}" != "1" ]]; then
        printf '::error title=%s::%s\n' "$1" "$note"
    fi
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

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

to_epoch() {
    date -u -d "$1" +%s 2>/dev/null
}

fingerprint_of_stdin() {
    local hex
    hex="$(sha256sum | cut -d' ' -f1)"
    printf 'sha256:%s\n' "$hex"
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

git_changed_paths() {
    local base_commit="$1"
    git -c core.quotePath=false diff --name-only "$base_commit" HEAD -- 2>/dev/null |
        grep -v -x -F -- "logs/summary.md" |
        LC_ALL=C sort
}

# 允许的标题层级是 2..4：整份摘要贴进 PR 描述后挂在「## 🔒 构建摘要」之下，
# 因此它自己的总标题是三级、各小节是四级。再深就该怀疑正文里嵌套了别的结构。
has_section() {
    local name="$1" line
    for line in "${BODY_REGION[@]}"; do
        if [[ "$line" =~ ^#{2,4}[[:space:]]+[^#] ]] && [[ "$line" == *"$name"* ]]; then
            return 0
        fi
        if [[ "$line" == "**$name"* ]]; then
            return 0
        fi
    done
    return 1
}

flush_step_summary() {
    local result="$1" row
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    [[ "${CI_VERIFIER_CHILD:-0}" != "1" ]] || return 0
    {
        printf '### 摘要溯源校验（verify-summary-provenance）\n\n'
        printf '| 检查 | 结果 | 说明 |\n'
        printf '| --- | --- | --- |\n'
        for row in "${REPORT_ROWS[@]}"; do
            printf '%s\n' "$row"
        done
        printf '\n**结论：** RESULT %s（通过 %d / 失败 %d / 跳过 %d）\n' "$result" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

flush_facts() {
    local result="$1"
    [[ -n "${PROVENANCE_FACTS_FILE:-}" ]] || return 0
    {
        printf 'result=%s\n' "$result"
        printf 'block_present=%s\n' "$BLOCK_PRESENT"
        printf 'changed_count=%s\n' "${PROV[${KEY_COUNT}]:-}"
        printf 'changed_fingerprint=%s\n' "${PROV[${KEY_FINGERPRINT}]:-}"
        # C8（编译完整性）只认这两个 fact：少导出一个，"没有数据"就会被读成"默认合格"。
        printf 'planned_count=%s\n' "${PROV[${KEY_PLANNED}]:-}"
        printf 'missing_count=%s\n' "${PROV[${KEY_MISSING}]:-}"
    } >>"$PROVENANCE_FACTS_FILE" 2>/dev/null || true
}

cd "$REPO_ROOT" || {
    printf 'FAIL P1 无法进入仓库根目录 %s\nRESULT FAIL\n' "$REPO_ROOT"
    exit 2
}

declare -A PROV=()
declare -a BODY_LINES=()
declare -a BODY_REGION=()
declare -a CLAIM_PATHS=()
declare -a CLAIM_SORTED=()
BLOCK_PRESENT="no"
# 清单围栏是否在指纹键之后被找到：P6 用它区分“清单为空”和“清单围栏缺失”。
CLAIM_FENCE_FOUND=false
# 围栏里是否真的出现了占位文案 PROV_EMPTY_LIST_NOTE：只影响 P6 的通过文案
# （"围栏内为占位行" vs "围栏为空"）。旧生成器写的是空围栏，契约上仍自洽，不该被说成有占位行。
CLAIM_EMPTY_NOTE_SEEN=false
BASE_REF=""
BASE_COMMIT=""

#######################################
# 数据来源：PR_BODY 优先，其次 PR_BODY_FILE；两者都没设置 => 本地无输入
#######################################
BODY_TEXT=""
BODY_INPUT="absent"
if [[ -v PR_BODY ]]; then
    BODY_INPUT="present"
    BODY_TEXT="$PR_BODY"
elif [[ -n "${PR_BODY_FILE:-}" ]]; then
    if [[ -f "$PR_BODY_FILE" ]]; then
        BODY_INPUT="present"
        BODY_TEXT="$(cat "$PR_BODY_FILE")"
    else
        BODY_INPUT="file-missing"
    fi
fi

if [[ "$BODY_INPUT" == "absent" ]]; then
    for id in P1 P2 P3 P4 P5 P6 P7 P8 P10 P11; do
        report_skip "$id" "本地未提供 PR_BODY / PR_BODY_FILE：没有可校验的 PR 描述（CI 里 PR_BODY 恒有值）"
    done
fi

if [[ "$BODY_INPUT" == "file-missing" ]]; then
    report_fail P1 "PR_BODY_FILE 指向的文件不存在：$PR_BODY_FILE（本地测试请把它指向一份含 PR 描述原文的文件）"
    for id in P2 P3 P4 P5 P6 P7 P8 P10 P11; do
        report_skip "$id" "没有 PR 描述原文，无法校验"
    done
fi

if [[ "$BODY_INPUT" == "present" ]]; then
    mapfile -t BODY_LINES < <(printf '%s\n' "$BODY_TEXT")
    for ((i = 0; i < ${#BODY_LINES[@]}; i++)); do
        BODY_LINES[i]="${BODY_LINES[i]%$'\r'}"
    done

    #######################################
    # P1 托管块存在、非空、不超过上限
    #######################################
    total_body_lines=${#BODY_LINES[@]}
    begin_count=0
    end_count=0
    begin_idx=-1
    end_idx=-1
    for ((i = 0; i < total_body_lines; i++)); do
        line="$(trim "${BODY_LINES[i]}")"
        if [[ "$line" == "$SUMMARY_BEGIN_MARK" ]]; then
            begin_count=$((begin_count + 1))
            if ((begin_idx < 0)); then
                begin_idx=$i
            fi
        elif [[ "$line" == "$SUMMARY_END_MARK" ]]; then
            end_count=$((end_count + 1))
            if ((end_idx < 0)); then
                end_idx=$i
            fi
        fi
    done

    p1_issues=()
    if ((begin_count == 0)); then
        p1_issues+=("PR 描述里没有 build-summary 托管块：请在 PR 描述里用 build-summary 的 begin/end 标记各占一行，把本地生成的 logs/summary.md 全文粘在中间")
    elif ((end_idx < 0 || end_idx < begin_idx)); then
        p1_issues+=("build-summary:begin 之后没有 build-summary:end：标记必须成对，且各占一行")
    fi

    block_chars=0
    if ((begin_idx >= 0 && end_idx > begin_idx)); then
        BODY_REGION=("${BODY_LINES[@]:begin_idx + 1:end_idx - begin_idx - 1}")
        for line in "${BODY_REGION[@]}"; do
            block_chars=$((block_chars + ${#line} + 1))
        done
        if ((${#BODY_REGION[@]} == 0)); then
            p1_issues+=("托管块是空的：标记之间必须有本地 logs/summary.md 的正文")
        fi
        if ((block_chars > MAX_BLOCK_CHARS)); then
            p1_issues+=("托管块 $block_chars 字符，超过上限 $MAX_BLOCK_CHARS：只贴摘要本身，不要连构建日志一起贴")
        fi
    fi

    # BLOCK_PRESENT 只表示“托管块能被抽取出来”，供 pr-guard.sh 的 C3 复用；
    # 它与 P1 是否通过无关：块超长时 P1 失败，但块本身确实存在，C3 不该误报“缺少托管块”。
    if ((begin_idx >= 0 && end_idx > begin_idx)) && ((${#BODY_REGION[@]} > 0)); then
        BLOCK_PRESENT="yes"
    fi
    if ((${#p1_issues[@]} == 0)); then
        report_pass P1 "PR 描述含托管块（第 $((begin_idx + 1))-$((end_idx + 1)) 行，$block_chars 字符，上限 $MAX_BLOCK_CHARS）"
    else
        report_fail P1 "$(join_notes '；' "${p1_issues[@]}")"
    fi

    #######################################
    # P2 托管块唯一 + 溯源块唯一 + 溯源小节在块末尾
    #######################################
    if [[ "$BLOCK_PRESENT" != "yes" ]]; then
        report_skip P2 "托管块不可用，无法校验结构"
    else
        p2_issues=()
        ((begin_count == 1)) || p2_issues+=("build-summary:begin 出现 $begin_count 次，应恰好 1 次（禁止第二组 begin/end）")
        ((end_count == 1)) || p2_issues+=("build-summary:end 出现 $end_count 次，应恰好 1 次（禁止第二组 begin/end）")

        region_total=${#BODY_REGION[@]}
        prov_begin_count=0
        prov_end_count=0
        prov_begin_idx=-1
        prov_end_idx=-1
        for ((i = 0; i < region_total; i++)); do
            line="$(trim "${BODY_REGION[i]}")"
            if [[ "$line" == "$PROV_BEGIN_MARK" ]]; then
                prov_begin_count=$((prov_begin_count + 1))
                if ((prov_begin_idx < 0)); then
                    prov_begin_idx=$i
                fi
            elif [[ "$line" == "$PROV_END_MARK" ]]; then
                prov_end_count=$((prov_end_count + 1))
                if ((prov_end_idx < 0)); then
                    prov_end_idx=$i
                fi
            fi
        done
        ((prov_begin_count == 1)) || p2_issues+=("溯源块的 dsh-provenance:begin 出现 $prov_begin_count 次，应恰好 1 次")
        ((prov_end_count == 1)) || p2_issues+=("溯源块的 dsh-provenance:end 出现 $prov_end_count 次，应恰好 1 次")
        if ((prov_begin_count >= 1 && prov_end_count >= 1)); then
            ((prov_begin_idx < prov_end_idx)) || p2_issues+=("溯源块 begin/end 顺序颠倒")
            if ((prov_end_idx >= 0 && prov_end_idx < region_total - PROV_TRAILING_SLACK_LINES)); then
                p2_issues+=("溯源小节距托管块末尾 $((region_total - 1 - prov_end_idx)) 行，超出允许的 $PROV_TRAILING_SLACK_LINES 行：它必须是块内最后一节")
            fi
            trailing_nonblank=0
            for ((i = prov_end_idx + 1; i < region_total; i++)); do
                if [[ -n "${BODY_REGION[i]//[[:space:]]/}" ]]; then
                    trailing_nonblank=$((trailing_nonblank + 1))
                fi
            done
            if ((trailing_nonblank > 0)); then
                p2_issues+=("溯源小节之后还有 $trailing_nonblank 行正文：它必须是块内最后一节")
            fi
        fi

        if ((${#p2_issues[@]} == 0)); then
            report_pass P2 "托管块唯一，溯源小节（第 $((prov_begin_idx + 1))-$((prov_end_idx + 1)) 行）是块内最后一节"
        else
            report_fail P2 "$(join_notes '；' "${p2_issues[@]}")：请只保留一组 build-summary 标记，并把完整摘要（含末尾的摘要溯源小节）整段贴入"
        fi
    fi

    #######################################
    # 块内解析：10 行中文标签表 + 【跟随指纹键】的变更文件清单围栏
    #
    # 围栏里唯一的非路径内容：占位文案 PROV_EMPTY_LIST_NOTE（生成侧在变更文件数为 0 时写入）。
    # 它逐字相等才算"清单为空"，故【不】进 CLAIM_PATHS —— 计入就会变成 1 行，与「变更文件数 0」
    # 冲突，一次合法生成会被判成自相矛盾。除此之外任何非空行都当路径：
    # 契约里不存在第二种"说明性文字"，多认一种就等于给改写溯源块的人留了后门。
    #
    # 为什么清单要“跟随指纹键”而不是“取托管块内第一个围栏”（实测过的安全缺陷，别改回去）：
    # 摘要正文本来就带围栏（<details> 折叠块里全是 ```text），所以“第一个围栏”根本不在溯源
    # 小节里。于是只要在摘要最前面放一个诱饵：
    #
    #     ```text
    #     scripts/ci/EVIL.sh
    #     ```
    #
    # P6 就会把诱饵当成清单，报“变更文件数为 0，但清单里有 1 行”并给出诱饵的指纹——同一份
    # 摘要里因此出现两个不同的真相源，攻击者可以让“清单”变成任意内容（P7 会按真实变更重算
    # 挡一道，但解析层不该有这种东西）。改为跟随指纹键之后，围栏的位置由契约钉死：诱饵只能
    # 落在指纹键之前，参与不了清单。
    #######################################
    if [[ "$BLOCK_PRESENT" == "yes" ]]; then
        fingerprint_line=-1
        for ((i = 0; i < ${#BODY_REGION[@]}; i++)); do
            line="${BODY_REGION[i]}"
            if [[ "$line" =~ ^\|[[:space:]]*([^|]*)[[:space:]]*\|[[:space:]]*(.*)[[:space:]]*\|[[:space:]]*$ ]]; then
                key="$(trim "${BASH_REMATCH[1]}")"
                value="$(trim "${BASH_REMATCH[2]}")"
                for known in "${PROV_KEYS[@]}"; do
                    if [[ "$key" == "$known" ]]; then
                        PROV["$key"]="$value"
                    fi
                done
                # 记【最后一次】见到指纹键的位置：溯源小节必须是托管块内最后一节（P2），
                # 诱饵表格只能落在它前面，所以最后一条才是契约里的那一条。
                if [[ "$key" == "$KEY_FINGERPRINT" ]]; then
                    fingerprint_line=$i
                fi
            fi
        done

        if ((fingerprint_line >= 0)); then
            fence_start=-1
            for ((i = fingerprint_line + 1; i < ${#BODY_REGION[@]}; i++)); do
                if [[ "$(trim "${BODY_REGION[i]}")" == '```'* ]]; then
                    fence_start=$i
                    break
                fi
            done
            if ((fence_start >= 0)); then
                CLAIM_FENCE_FOUND=true
                for ((i = fence_start + 1; i < ${#BODY_REGION[@]}; i++)); do
                    if [[ "$(trim "${BODY_REGION[i]}")" == '```'* ]]; then
                        break
                    fi
                    trimmed="$(trim "${BODY_REGION[i]}")"
                    [[ -n "$trimmed" ]] || continue
                    # 占位行 = 空清单的写法，不是路径：只跳过它，其余行一律当路径。
                    if [[ "$trimmed" == "$PROV_EMPTY_LIST_NOTE" ]]; then
                        CLAIM_EMPTY_NOTE_SEEN=true
                        continue
                    fi
                    CLAIM_PATHS+=("$trimmed")
                done
            fi
        fi

        if ((${#CLAIM_PATHS[@]} > 0)); then
            mapfile -t CLAIM_SORTED < <(printf '%s\n' "${CLAIM_PATHS[@]}" | LC_ALL=C sort)
        fi
    fi

    #######################################
    # P3 键齐全、值非空、格式合法
    #######################################
    time_epoch=""
    if [[ "$BLOCK_PRESENT" != "yes" ]]; then
        report_skip P3 "托管块不可用，无法解析键值"
    else
        p3_issues=()
        for key in "${PROV_KEYS[@]}"; do
            if [[ -z "${PROV[$key]:-}" ]]; then
                p3_issues+=("缺少键「$key」或其值为空")
            fi
        done
        if [[ -n "${PROV[$KEY_VERSION]:-}" && "${PROV[$KEY_VERSION]}" != "2" ]]; then
            p3_issues+=("格式版本为「${PROV[$KEY_VERSION]}」，本校验只认 2")
        fi
        # 两新键的取值校验放在 P3：P3 是“块本身的格式合法”这一层，C8 拿它当输入的信任基础。
        # 只允许【整数】或字面量 unknown（小写）：允许空/带单位/千分位就等于允许解析出错值，
        # 而 C8 会拿这个值判“编译完整性是否达标” —— 一个「398 个」永远不等于 0。
        # 空值不在这里重复报：上面“缺少键”那一轮已经报过了。
        for key in "$KEY_PLANNED" "$KEY_MISSING"; do
            value="${PROV[$key]:-}"
            [[ -n "$value" ]] || continue
            if [[ "$value" != "unknown" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
                p3_issues+=("「$key」的值为「$value」，只允许整数或小写 unknown")
            fi
        done
        if [[ -n "${PROV[$KEY_COMMIT]:-}" ]] && ! [[ "${PROV[$KEY_COMMIT]}" =~ ^[0-9a-f]{40}$ ]]; then
            p3_issues+=("提交「${PROV[$KEY_COMMIT]}」不是 40 位小写 hex")
        fi
        if [[ -n "${PROV[$KEY_TIME]:-}" ]]; then
            time_epoch="$(to_epoch "${PROV[$KEY_TIME]}")"
            if [[ -z "$time_epoch" ]]; then
                p3_issues+=("生成时间「${PROV[$KEY_TIME]}」无法解析，应形如 2025-01-01T00:00:00Z")
            fi
        fi
        if ((${#p3_issues[@]} == 0)); then
            report_pass P3 "10 个键齐全，格式版本 2，应编产物数 / 未产出数为整数或 unknown，提交为 40 位小写 hex，生成时间可解析"
        else
            report_fail P3 "$(join_notes '；' "${p3_issues[@]}")：请重新运行 bash scripts/ci/generate-summary.sh，把新生成的整段内容替换进 PR 描述"
        fi
    fi

    #######################################
    # P4 / P5 仓库、分支与本 PR 一致
    #######################################
    if [[ "$BLOCK_PRESENT" != "yes" ]]; then
        report_skip P4 "托管块不可用，无法比对仓库"
        report_skip P5 "托管块不可用，无法比对分支"
    else
        # 基准取【头仓库】而不是目标仓库：actions/checkout 之后 git remote origin 指向的是 PR 头仓库
        # （fork PR 时就是 fork 的那一份），而生成侧正是从 origin 解析出「仓库」字段；
        # 拿目标仓库当基准只会在同仓库 PR 上偶然相等，fork PR 上必然误报。
        expected_repo="${PR_HEAD_REPO_FULL_NAME:-}"
        [[ -n "$expected_repo" ]] || expected_repo="${PR_REPO_FULL_NAME:-}"
        if [[ -z "$expected_repo" ]]; then
            report_skip P4 "未提供 PR_HEAD_REPO_FULL_NAME / PR_REPO_FULL_NAME（本地运行属正常情况）"
        elif [[ "${PROV[$KEY_REPO]:-}" == "$expected_repo" ]]; then
            report_pass P4 "仓库与 PR 检出仓库一致：$expected_repo"
        else
            report_fail P4 "摘要记录的仓库是「${PROV[$KEY_REPO]:-<空>}」，本 PR 检出的是「$expected_repo」仓库：这份摘要不是在本 PR 的检出仓库里生成的，请重新生成并更新 PR 描述"
        fi

        if [[ -z "${PR_HEAD_REF:-}" ]]; then
            report_skip P5 "未提供 PR_HEAD_REF（本地运行属正常情况）"
        elif [[ "${PROV[$KEY_BRANCH]:-}" == "${PR_HEAD_REF}" ]]; then
            report_pass P5 "分支与 PR 头分支一致：$PR_HEAD_REF"
        else
            report_fail P5 "摘要记录的分支是「${PROV[$KEY_BRANCH]:-<空>}」，本 PR 头分支是「${PR_HEAD_REF}」：摘要来自别的分支（复制旧摘要），请在本分支重新生成"
        fi
    fi

    #######################################
    # P6 块内自洽：清单行数 == 变更文件数，重算指纹 == 变更文件指纹
    # 变更文件数为 0 时围栏里是占位行（解析层已排除），CLAIM_PATHS 因此为空，
    # 重算指纹天然是空字节串的 sha256 —— 0 个变更下"指纹不符"依然会被发现。
    #######################################
    claimed_fingerprint=""
    if [[ "$BLOCK_PRESENT" != "yes" ]]; then
        report_skip P6 "托管块不可用，无法重算指纹"
    else
        p6_issues=()
        claimed_count="${PROV[$KEY_COUNT]:-}"
        # 清单围栏必须在指纹键之后，且【永远】存在——变更文件数为 0 时里面是占位文案
        # PROV_EMPTY_LIST_NOTE（解析层已把它排除在 CLAIM_PATHS 之外，故这里的行数是"真实路径数"）。
        # 找不到就说明溯源块被裁剪/改写过：没有"空清单所以没围栏"这种解释，
        # 缺围栏的合法形态一个也没有，别为了方便把这条放宽成"可有可无"。
        if [[ "$CLAIM_FENCE_FOUND" != true ]]; then
            p6_issues+=("溯源块缺少变更文件清单围栏：清单必须紧跟在「变更文件指纹」键之后，形式是一个 text 围栏块，围栏里每行一个变更路径（变更文件数为 0 时写占位行「${PROV_EMPTY_LIST_NOTE}」，围栏本身不可省略）")
        fi
        if [[ -n "${PROV[$KEY_FINGERPRINT]:-}" ]] && ! [[ "${PROV[$KEY_FINGERPRINT]}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            p6_issues+=("变更文件指纹「${PROV[$KEY_FINGERPRINT]}」不是 sha256:<64 位小写 hex>")
        fi
        if [[ -n "$claimed_count" ]] && ! [[ "$claimed_count" =~ ^[0-9]+$ ]]; then
            p6_issues+=("变更文件数「$claimed_count」不是整数")
        elif [[ -n "$claimed_count" && "$claimed_count" != "${#CLAIM_PATHS[@]}" ]]; then
            p6_issues+=("变更文件数为 $claimed_count，但清单里有 ${#CLAIM_PATHS[@]} 行")
        fi
        for path in "${CLAIM_PATHS[@]}"; do
            if [[ "$path" == "logs/summary.md" ]]; then
                p6_issues+=("清单不得包含 logs/summary.md 本身（它不入库，也不该出现在指纹里）")
                break
            fi
        done

        if ((${#CLAIM_SORTED[@]} == 0)); then
            recomputed="$(printf '' | fingerprint_of_stdin)"
        else
            recomputed="$(printf '%s\n' "${CLAIM_SORTED[@]}" | fingerprint_of_stdin)"
        fi
        claimed_fingerprint="${PROV[$KEY_FINGERPRINT]:-}"
        if [[ -n "$claimed_fingerprint" && "$claimed_fingerprint" != "$recomputed" ]]; then
            p6_issues+=("重算指纹为 $recomputed，与记录的 $claimed_fingerprint 不一致")
        fi

        if ((${#p6_issues[@]} == 0)); then
            if ((${#CLAIM_PATHS[@]} == 0)) && [[ "${PROV[$KEY_COUNT]:-}" == "0" ]] && [[ "$CLAIM_EMPTY_NOTE_SEEN" == "true" ]]; then
                report_pass P6 "变更文件数为 0，围栏内为占位行「${PROV_EMPTY_LIST_NOTE}」（不计入清单），重算指纹 $recomputed"
            elif ((${#CLAIM_PATHS[@]} == 0)) && [[ "${PROV[$KEY_COUNT]:-}" == "0" ]]; then
                report_pass P6 "变更文件数为 0，围栏为空（旧形态，契约上仍自洽），重算指纹 $recomputed"
            else
                report_pass P6 "清单 ${#CLAIM_PATHS[@]} 行自洽，重算指纹 $recomputed"
            fi
        else
            report_fail P6 "$(join_notes '；' "${p6_issues[@]}")：清单与指纹由脚本一次生成，请勿手工改动任何一项；重新运行 bash scripts/ci/generate-summary.sh 后整段替换 PR 描述"
        fi
    fi

    #######################################
    # P7 指纹与本 PR 真实变更一致
    #######################################
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        report_skip P7 "当前目录不是 git 仓库，无法重算真实变更指纹"
    elif [[ "$BLOCK_PRESENT" != "yes" ]]; then
        report_skip P7 "托管块不可用，无法与真实变更比对"
    elif BASE_REF="$(resolve_base_ref)" && BASE_COMMIT="$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)" && [[ -n "$BASE_COMMIT" ]]; then
        declare -a REAL_PATHS=()
        mapfile -t REAL_PATHS < <(git_changed_paths "$BASE_COMMIT")
        if ((${#REAL_PATHS[@]} == 0)); then
            real_fingerprint="$(printf '' | fingerprint_of_stdin)"
        else
            real_fingerprint="$(printf '%s\n' "${REAL_PATHS[@]}" | fingerprint_of_stdin)"
        fi
        if [[ "$real_fingerprint" == "$claimed_fingerprint" ]]; then
            report_pass P7 "指纹与真实变更一致（基准 $BASE_REF，${#REAL_PATHS[@]} 个文件）：$real_fingerprint"
        else
            report_fail P7 "摘要指纹 ${claimed_fingerprint:-<空>} 与真实变更指纹 $real_fingerprint 不一致（基准 $BASE_REF，真实 ${#REAL_PATHS[@]} 个文件）：说明摘要不是针对本 PR 当前变更生成的，请重新运行 bash scripts/ci/generate-summary.sh 并更新 PR 描述"
        fi
    else
        report_skip P7 "无法解析变更基准（试过 SUMMARY_BASE_REF、PR_BASE_REF、origin/main、main），请确认 checkout 用了 fetch-depth: 0"
    fi

    #######################################
# P8 块内「提交」证明“由本 PR 产出”
#
# “提交可达性”原先是一个独立编号，现已折叠到这里：CI 里“提交 == PR_HEAD_SHA”成立时距离必然为 0，
# 独立编号是同义反复；而没有 PR_HEAD_SHA 的本地场景又确实需要可达性校验——所以它降级为本项的
# 分支，不再单列编号（门禁表与实现必须逐项对得上）。
#######################################
summary_commit="${PROV[$KEY_COMMIT]:-}"
if [[ "$BLOCK_PRESENT" != "yes" || -z "$summary_commit" ]]; then
    report_skip P8 "托管块不可用或提交字段为空，无法判定摘要提交"
elif [[ -n "${PR_HEAD_SHA:-}" ]]; then
    if [[ "$summary_commit" == "${PR_HEAD_SHA}" ]]; then
        report_pass P8 "摘要提交与 PR 头提交一致：$summary_commit"
    else
        report_fail P8 "摘要记录的提交是「$summary_commit」，本 PR 头提交是「${PR_HEAD_SHA}」：这不是本 PR 最新提交上的运行结果（常见于复用旧摘要）。修复：先在本地 git commit 完成最后一次提交，再运行 bash scripts/ci/generate-summary.sh 重新生成，然后把新摘要整段替换进 PR 描述（之后不要再产生新提交，否则摘要里的提交又会对不上）"
    fi
elif ! git rev-parse --git-dir >/dev/null 2>&1; then
    report_skip P8 "未提供 PR_HEAD_SHA 且当前目录不是 git 仓库，无法判定摘要提交"
else
    # 本地降级分支：没有 PR_HEAD_SHA 可比，退化为“提交真实存在于本分支历史里且不太久远”。
    if ! git cat-file -e "${summary_commit}^{commit}" 2>/dev/null; then
        report_fail P8 "摘要记录的提交 $summary_commit 在本地仓库里不存在：这是复用旧摘要或从别处复制的典型特征，请重新生成"
    elif ! git merge-base --is-ancestor "$summary_commit" HEAD 2>/dev/null; then
        report_fail P8 "摘要记录的提交 $summary_commit 不能从 HEAD 到达：摘要不是本分支历史的产物（复用旧摘要或从别处复制），请重新生成"
    else
        distance="$(git rev-list --count "${summary_commit}..HEAD" 2>/dev/null || printf 'unknown')"
        if [[ "$distance" =~ ^[0-9]+$ ]] && ((distance <= MAX_SUMMARY_COMMIT_DISTANCE)); then
            report_pass P8 "未提供 PR_HEAD_SHA，退化为可达性校验：摘要提交 $summary_commit 可从 HEAD 到达，距 HEAD $distance 个提交（上限 $MAX_SUMMARY_COMMIT_DISTANCE）"
        else
            report_fail P8 "未提供 PR_HEAD_SHA，退化为可达性校验：摘要提交 $summary_commit 距 HEAD $distance 个提交，超过上限 $MAX_SUMMARY_COMMIT_DISTANCE：摘要在若干次提交之前生成，请在最后一个提交之后重新生成"
        fi
    fi
fi

#######################################
    # P10 生成时间新鲜度
    #######################################
    if [[ -z "$time_epoch" ]]; then
        report_skip P10 "无法解析生成时间，跳过新鲜度判定"
    else
        now_epoch="$(date -u +%s)"
        head_time=""
        if git rev-parse --git-dir >/dev/null 2>&1; then
            head_time="$(git log -1 --format=%ct HEAD 2>/dev/null || true)"
        fi
        p10_issues=()
        if ((time_epoch > now_epoch + CLOCK_SKEW_SECONDS)); then
            p10_issues+=("生成时间比当前时间晚 $((time_epoch - now_epoch)) 秒（上限 $CLOCK_SKEW_SECONDS 秒）：先确认本机时钟与时区")
        fi
        if ((time_epoch < now_epoch - MAX_AGE_SECONDS)); then
            p10_issues+=("生成时间距现在超过 30 天：这是旧摘要，请重新生成")
        fi
        if [[ "$head_time" =~ ^[0-9]+$ ]] && ((time_epoch < head_time - HEAD_TIME_TOLERANCE_SECONDS)); then
            p10_issues+=("生成时间比 HEAD 提交时间早 $(((head_time - time_epoch) / 3600)) 小时，超过 6 小时：摘要在旧提交上生成，请重新生成")
        fi
        if ((${#p10_issues[@]} == 0)); then
            report_pass P10 "生成时间 ${PROV[$KEY_TIME]} 新鲜（不晚于 now，不超过 30 天，不早于 HEAD 提交 6 小时）"
        else
            report_fail P10 "$(join_notes '；' "${p10_issues[@]}")：请重新运行 bash scripts/ci/generate-summary.sh 并更新 PR 描述"
        fi
    fi

    #######################################
    # P11 结构合规：结论 / 运行信息 / 步骤状态
    #######################################
    if [[ "$BLOCK_PRESENT" != "yes" ]]; then
        report_skip P11 "托管块不可用，无法检查结构"
    else
        missing_sections=()
        for section in "结论" "运行信息" "步骤状态"; do
            has_section "$section" || missing_sections+=("$section")
        done
        if ((${#missing_sections[@]} == 0)); then
            report_pass P11 "摘要正文含「结论 / 运行信息 / 步骤状态」三节"
        else
            report_fail P11 "摘要正文缺少小节：$(join_notes '、' "${missing_sections[@]}")：请贴完整的 logs/summary.md 内容，不要手工裁剪"
        fi
    fi
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

flush_facts "$FINAL_RESULT"
flush_step_summary "$FINAL_RESULT"

printf 'RESULT %s\n' "$FINAL_RESULT"
exit "$EXIT_CODE"
