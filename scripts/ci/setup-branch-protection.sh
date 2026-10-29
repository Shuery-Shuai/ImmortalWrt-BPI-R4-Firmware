#!/bin/bash
#######################################
# main 分支保护与合并后自动删分支（scripts/ci/setup-branch-protection.sh）
#
# 为什么需要这个脚本：
#   main 是【编译分支】——immortalwrt-builder 在 main 上产出固件与 Release，
#   因此一条直推 main 的提交会绕过 pr-guard 直接进入发布链路。
#   手工在网页上点分支保护有三个问题：无法评审、无法复现、重建仓库时全靠记忆。
#   本脚本把"应该是什么样"写成代码，幂等执行，任何克隆里跑一次都得到同一状态。
#
# 为什么先 GET 再决定 PUT：
#   PUT /branches/<branch>/protection 是【整体覆盖】语义，无条件执行会静默清掉别处新增的
#   保护项，也让"跑一次"与"跑十次"的日志无法区分。先读现状、只在有差异时写入，
#   既满足幂等，也让人看得懂这次到底改了什么（输出逐条给出「当前 → 期望」）。
#
# 为什么 required_status_checks.contexts 取【并集】而不是覆盖成固定值：
#   同样是整体覆盖语义的直接后果——若把 contexts 写死成 pr-guard，第一次运行就会把
#   syntax-linter 的 shellcheck / actionlint / markdownlint 从"必需检查"里摘掉，
#   门禁悄悄变弱而没有任何报错。因此这里的天条是：
#   任何 PUT 都不得让既有必需检查消失。做法是 GET 现状后取
#   「现状 contexts ∪ REQUIRED_CONTEXTS」，并把结果逐条标成「保留 / 新增」打印出来。
#   已知取舍：并集意味着网页上手工删掉的旧 context 会被本脚本恢复（这是有意为之），
#   而脚本自己永远不会替人删除任何 context。
#
# 为什么 --dry-run 不要求 gh 已登录：
#   预览不发出任何写请求，也就不需要凭据；把登录检查移出预览路径，
#   才能让没装 gh / 没登录的人先看清脚本会做什么。实跑仍然硬性要求 gh 与登录态。
#
# 用法：
#   bash scripts/ci/setup-branch-protection.sh [--dry-run] [--repo OWNER/REPO] [--branch main]
#
# 参数：
#   --dry-run          只打印将要发出的 gh api 调用，不写入任何远端状态
#   --repo OWNER/REPO  目标仓库；缺省依次取 $GH_REPO、gh repo view、origin 远端地址
#   --branch 名称       目标分支，缺省 main
#   -h, --help         打印用法
#
# 退出码（常量来自 scripts/libs/02-error-handler.sh）：
#   E_SUCCESS(0)      成功（含"已经是目标状态、无变更"）
#   E_USAGE(64)       参数错误，或仓库/分支无法确定
#   E_UNAVAILABLE(69) 缺 gh、gh 未登录，或 GitHub API 调用失败
#
# 安全边界：本脚本只【新增/收紧】保护规则，不删除分支、不改默认分支，也不会从 contexts
# 里删除任何既有项；唯一两类写操作（PUT protection 与 PATCH 仓库开关）都是幂等的目标状态声明。
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 本脚本由维护者在本地执行，产物是远端仓库设置而不是日志文件；
# 落一份 logs/ 反而会让人误以为那是某次构建留下的记录。
LOG_TO_FILE=false
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# shellcheck source=scripts/libs/02-error-handler.sh
source "${SCRIPT_DIR}/../libs/02-error-handler.sh"

# git remote 回落解析必须基于仓库根，因此先把 CWD 锚定到仓库根（与 check-apt-deps.sh 同一做法）。
cd "${SCRIPT_DIR}/../.." || {
    log_error "无法进入仓库根目录：${SCRIPT_DIR}/../.."
    exit "${E_UNAVAILABLE}"
}

# 必需检查项：pr-guard 是本脚本存在的理由（它证明这次合入经过了流程校验），
# 其余三条来自 .github/workflows/syntax-linter.yml 的三个 job 名。
# 名字必须与 workflow 的 job 名逐字一致：required_status_checks 里写错一个字，
# 症状不是报错而是"PR 永远 pending"，只有列出真实上报的 check 名才能定位。
# 已知限制：job 改名后这里不会自动跟随，GitHub 也没有"这个 context 是否存在"的查询接口，
# 因此改名的那次 PR 必须同步改这个数组，否则门禁会等一个永不上报的名字。
readonly -a REQUIRED_CONTEXTS=(
    "pr-guard"
    "shellcheck"
    "actionlint"
    "markdownlint"
)
# 0 个必需批准：本仓库是单维护者项目，GitHub 不允许批准自己的 PR，
# 配合下面的 enforce_admins=true 会形成死锁——main 永远无法合并。
# 因此这里的门禁哲学是"不要求人审，但必须过检查"，把校验成本放在 CI 而不是人身上。
readonly REQUIRED_APPROVALS=0
readonly DEFAULT_BRANCH="main"

# 期望状态按固定顺序排列；比对时按下标一一对应，
# 因此 FIELD_LABELS / FIELD_DESIRED / JQ_FIELDS 三者的顺序必须保持一致，改动时一起改。
# contexts 不在这三张表里：它不是"覆盖成某个固定值"，而是"与现状取并集"，由 compute_contexts 处理。
readonly -a FIELD_LABELS=(
    "required_status_checks.strict"
    "enforce_admins"
    "required_pull_request_reviews.required_approving_review_count"
    "required_pull_request_reviews.dismiss_stale_reviews"
    "allow_force_pushes"
    "allow_deletions"
    "required_conversation_resolution"
    "required_linear_history"
)
# strict=false：合并前不强制把分支 rebase 到 main 最新。本仓库的 PR 多为文档/脚本小改，
#   强制 up-to-date 会让"刚通过 CI 又被别人的合并顶掉"变成反复重跑，收益不抵成本。
# enforce_admins=true：管理员也走 PR。这是本脚本的核心目的——单人仓库里，
#   enforce_admins=false 意味着唯一有权限的人随时可以绕过保护直推 main，等于没禁。
#   它不构成硬锁：修 pr-guard 的 PR 会用修复后的 workflow 版本运行并可通过（可自救）。
# required_approving_review_count=0：见 REQUIRED_APPROVALS 的注释（与 enforce_admins=true 同用会死锁）。
# dismiss_stale_reviews=false：批准数要求为 0 时"新提交作废旧批准"没有可作废的对象，
#   保留 true 只会让读规则的人以为这里有人审环节，如实写 false。
# allow_force_pushes=false / allow_deletions=false：main 是可复现构建的唯一入口，历史必须可追。
# required_conversation_resolution=true：未解决的评审会话必须收起才能合入，避免"提了意见但被静默合掉"。
# required_linear_history=false：允许 merge commit，保留 PR 边界，便于回溯"哪次合并带进了什么"。
readonly -a FIELD_DESIRED=(
    "false"
    "true"
    "0"
    "false"
    "false"
    "false"
    "true"
    "false"
)

# contexts 固定排在最后一位：前 8 位与 FIELD_LABELS/FIELD_DESIRED 一一对应，
# 第 9 位（下标 8）单独取出来做并集运算，不参与逐项覆盖比对。
readonly JQ_FIELDS='
  [
    ((.required_status_checks.strict // false) | tostring),
    ((.enforce_admins.enabled // false) | tostring),
    ((.required_pull_request_reviews.required_approving_review_count // 0) | tostring),
    ((.required_pull_request_reviews.dismiss_stale_reviews // false) | tostring),
    ((.allow_force_pushes.enabled // false) | tostring),
    ((.allow_deletions.enabled // false) | tostring),
    ((.required_conversation_resolution.enabled // false) | tostring),
    ((.required_linear_history.enabled // false) | tostring),
    ((((.required_status_checks.contexts // []) + [(.required_status_checks.checks // [])[].context])
      | unique | sort | join(",")))
  ] | join("|")
'

# contexts 在 CURRENT_FIELDS 里的下标，与 JQ_FIELDS 的最后一项对应。
readonly IDX_CONTEXTS=8

DRY_RUN=false
REPO=""
BRANCH="${DEFAULT_BRANCH}"
# GH_READY 表示"能发出 gh api"：gh 存在且已登录。预览模式下它可能为 false，
# 此时无法读现状，脚本按"状态未知"处理，只打印将要发出的写调用。
GH_READY=false
PROTECTED=false
CURRENT_FIELDS=""
CURRENT_DBM=""        # delete_branch_on_merge 的当前值：true / false / unknown
CONTEXTS_FINAL=()     # 最终请求体里的 contexts（并集，已排序去重）
CONTEXTS_CSV=""       # CONTEXTS_FINAL 的逗号串，用于比较与展示
CONTEXT_KEPT=()       # 期望项里"现状已有"的（保留）
CONTEXT_ADDED=()      # 期望项里"现状没有"的（新增）
CONTEXT_EXTRA=()      # 现状里有、但不在期望项里的（同样必须保留）
CHANGES=()            # 逐条差异，人类可读
DBM_CHANGE=""         # delete_branch_on_merge 的差异说明；空串表示无差异

usage() {
    cat <<'USAGE'
用法：bash scripts/ci/setup-branch-protection.sh [--dry-run] [--repo OWNER/REPO] [--branch main]

  --dry-run          只打印将要发出的 gh api 调用，不写入任何远端状态
  --repo OWNER/REPO  目标仓库；缺省依次取 $GH_REPO、gh repo view、origin 远端地址
  --branch 名称       目标分支，缺省 main
  -h, --help         打印本用法

脚本把 main 的分支保护设为：
  · 必需检查 = 「现状 contexts ∪ pr-guard/shellcheck/actionlint/markdownlint」（strict=false）；
    并集是硬约束——任何 PUT 都不会让既有必需检查从列表里消失
  · enforce_admins=true（管理员也不能直推，但不构成死锁：修 CI 的 PR 用修复后的 workflow 运行）
  · 不要求人审（required_approving_review_count=0，单人仓库下要求批准会锁死合并）
  · 禁止强推、禁止删除分支、要求解决评审会话、允许 merge commit
同时打开仓库的 delete_branch_on_merge（合并后自动删除 head 分支）。可重复执行。
USAGE
}

#######################################
# 解析命令行
#
# 用显式 shift 而不套 03-argument-parser.sh：本脚本只有三个开关，
# 把那套通用解析器引进来会让"脚本会做什么"更难看懂，收益为负。
# 同时支持 --opt value 与 --opt=value 两种写法：前者是 README 里的示例形态，
# 后者是习惯 GNU 风格的人最常敲的形态，只支持一种就会在另一种上报"未知参数"。
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --repo)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    log_error "--repo 需要 OWNER/REPO 参数"
                    return "${E_USAGE}"
                fi
                REPO="$2"
                shift 2
                ;;
            --repo=*)
                REPO="${1#*=}"
                shift
                ;;
            --branch)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    log_error "--branch 需要分支名"
                    return "${E_USAGE}"
                fi
                BRANCH="$2"
                shift 2
                ;;
            --branch=*)
                BRANCH="${1#*=}"
                shift
                ;;
            -h | --help)
                usage
                exit "${E_SUCCESS}"
                ;;
            *)
                log_error "未知参数：$1"
                usage >&2
                return "${E_USAGE}"
                ;;
        esac
    done
    return 0
}

#######################################
# 检查 gh 可用性
#
# 实跑必须 gh + 登录；预览允许缺省，只提示"无法读现状"。
# 分开处理的理由见文件头：预览无凭据也能产出有用信息，实跑没有登录则必然失败，
# 两者用同一个硬性检查会让 --dry-run 在干净环境里直接不可用。
#######################################
check_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "未找到 gh CLI：预览仍会打印将要发出的调用，但无法读取远端现状"
            return 0
        fi
        log_error "未找到 gh CLI，请先安装：https://cli.github.com/"
        return "${E_UNAVAILABLE}"
    fi

    if ! gh auth status >/dev/null 2>&1; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "gh 未登录：预览仍会打印将要发出的调用，但无法读取远端现状"
            return 0
        fi
        log_error "gh 未登录，请先执行：gh auth login"
        return "${E_UNAVAILABLE}"
    fi

    GH_READY=true
    return 0
}

#######################################
# 确定目标仓库
#
# 优先级：--repo > $GH_REPO > gh repo view > origin 远端解析。
# 前三级都要问 gh 或环境变量，最后一级纯本地解析，因此没装 gh 时依然可用。
#######################################
resolve_repo() {
    if [[ -n "${REPO}" ]]; then
        return 0
    fi

    if [[ -n "${GH_REPO:-}" ]]; then
        REPO="${GH_REPO}"
        return 0
    fi

    if [[ "${GH_READY}" == "true" ]]; then
        local detected=""
        detected="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || detected=""
        if [[ -n "${detected}" ]]; then
            REPO="${detected}"
            return 0
        fi
    fi

    # 从 origin 地址反推 OWNER/REPO：git@host:owner/repo.git 与 https://host/owner/repo.git 都要认。
    local url=""
    url="$(git config --get remote.origin.url 2>/dev/null)" || url=""
    url="${url%.git}"
    if [[ "${url}" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/(.+)$ ]]; then
        REPO="${BASH_REMATCH[1]}"
    elif [[ "${url}" =~ ^[^@/]+@@[^:]+:(.+)$ ]]; then
        REPO="${BASH_REMATCH[1]}"
    else
        REPO=""
    fi

    if [[ ! "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        log_error "无法确定目标仓库，请用 --repo OWNER/REPO 显式指定"
        return "${E_USAGE}"
    fi
    return 0
}

#######################################
# 读取 branches/<branch>/protection 现状
#
# 未保护时 GitHub 返回 404 "Branch not protected"：这不是错误，而是"需要新建规则"的常态，
# 因此把它翻译成 PROTECTED=false 继续往下走，而不是当失败退出。
# 其它非零返回（权限不足、网络、仓库名写错）才是真错误——把 403 也当"未保护"处理，
# 会让人误以为一次成功的 PUT 已经把保护打开了。
#######################################
read_protection() {
    CURRENT_FIELDS=""
    PROTECTED=false
    if [[ "${GH_READY}" != "true" ]]; then
        return 0
    fi

    local output="" err_file=""
    err_file="$(mktemp)"
    if output="$(gh api -X GET "repos/${REPO}/branches/${BRANCH}/protection" --jq "${JQ_FIELDS}" 2>"${err_file}")"; then
        CURRENT_FIELDS="${output}"
        PROTECTED=true
        rm -f "${err_file}"
        return 0
    fi

    local err_text=""
    err_text="$(cat "${err_file}")"
    rm -f "${err_file}"
    if [[ "${err_text}" == *"Branch not protected"* || "${err_text}" == *"HTTP 404"* ]]; then
        PROTECTED=false
        return 0
    fi
    log_error "读取分支保护失败：${err_text}"
    return "${E_UNAVAILABLE}"
}

#######################################
# 读取仓库 delete_branch_on_merge 现状
#######################################
read_delete_branch_on_merge() {
    CURRENT_DBM="unknown"
    if [[ "${GH_READY}" != "true" ]]; then
        return 0
    fi
    local value=""
    if value="$(gh api "repos/${REPO}" --jq '.delete_branch_on_merge' 2>/dev/null)"; then
        CURRENT_DBM="${value}"
    fi
    return 0
}

#######################################
# 把参数拼成逗号串（空参数时输出空串）
#
# 单独抽出来是为了让"集合内容"只有一个渲染实现：差异输出与请求体若各拼一次，
# 迟早会出现"输出说 4 个、请求体里 3 个"这种只能靠肉眼发现的偏差。
#######################################
join_csv() {
    local out="" item=""
    for item in "$@"; do
        if [[ -z "${out}" ]]; then
            out="${item}"
        else
            out="${out},${item}"
        fi
    done
    printf '%s' "${out}"
}

#######################################
# 计算最终 contexts（并集）
#
# 参数：$1 = 现状 contexts 的逗号串（未受保护时为空）
# 输出（全局）：CONTEXTS_FINAL / CONTEXTS_CSV / CONTEXT_KEPT / CONTEXT_ADDED / CONTEXT_EXTRA
#
# 并集而不是覆盖的理由见文件头。这里额外记录三个分组，是为了让人在 --dry-run 输出里
# 一眼看清"哪些是本来就有的、哪些是这次新加的、哪些是不在期望里但被保留的"——
# 只说"contexts 有变更"会让人无法判断这次运行到底是加强还是削弱门禁。
#######################################
compute_contexts() {
    local existing_csv="$1"

    CONTEXTS_FINAL=()
    CONTEXT_KEPT=()
    CONTEXT_ADDED=()
    CONTEXT_EXTRA=()

    local -a existing=()
    if [[ -n "${existing_csv}" ]]; then
        IFS=',' read -r -a existing <<<"${existing_csv}"
    fi

    local candidate="" item="" keep=false
    for candidate in "${REQUIRED_CONTEXTS[@]}"; do
        keep=false
        for item in "${existing[@]}"; do
            if [[ "${item}" == "${candidate}" ]]; then
                keep=true
            fi
        done
        if [[ "${keep}" == "true" ]]; then
            CONTEXT_KEPT+=("${candidate}")
        else
            CONTEXT_ADDED+=("${candidate}")
        fi
        CONTEXTS_FINAL+=("${candidate}")
    done

    # 现状里还有、但不在期望项里的 context 一律保留：
    # 这不是"顺手加的"，而是 PUT 整体覆盖语义下的唯一安全做法。
    for item in "${existing[@]}"; do
        if [[ -z "${item}" ]]; then
            continue
        fi
        keep=false
        for candidate in "${REQUIRED_CONTEXTS[@]}"; do
            if [[ "${item}" == "${candidate}" ]]; then
                keep=true
            fi
        done
        if [[ "${keep}" != "true" ]]; then
            CONTEXT_EXTRA+=("${item}")
            CONTEXTS_FINAL+=("${item}")
        fi
    done

    # 排序去重必须与 jq 侧的 unique | sort 同序（ASCII 码点）。
    # 两边顺序不同会让"内容相同"被判成"有差异"，于是每次运行都白写一次 PUT，
    # 幂等性从此只能靠人眼确认。
    local -a normalized=()
    mapfile -t normalized < <(printf '%s\n' "${CONTEXTS_FINAL[@]}" | LC_ALL=C sort -u)
    CONTEXTS_FINAL=("${normalized[@]}")
    CONTEXTS_CSV="$(join_csv "${CONTEXTS_FINAL[@]}")"
    return 0
}

#######################################
# 计算差异（纯本地比较，不发请求）
#######################################
compute_diff() {
    CHANGES=()
    DBM_CHANGE=""

    local -a current=()
    if [[ "${PROTECTED}" == "true" ]]; then
        IFS='|' read -r -a current <<<"${CURRENT_FIELDS}"
    fi

    # 并集必须在生成请求体之前算好：payload 的 contexts 就是这里的 CONTEXTS_FINAL。
    compute_contexts "${current[IDX_CONTEXTS]:-}"

    local kept_csv="" added_csv="" extra_csv=""
    kept_csv="$(join_csv "${CONTEXT_KEPT[@]}")"
    added_csv="$(join_csv "${CONTEXT_ADDED[@]}")"
    extra_csv="$(join_csv "${CONTEXT_EXTRA[@]}")"

    local context_note="required_status_checks.contexts："
    if [[ -n "${kept_csv}" ]]; then
        context_note+="保留「${kept_csv}」"
    fi
    if [[ -n "${added_csv}" ]]; then
        if [[ -n "${kept_csv}" ]]; then
            context_note+="，"
        fi
        context_note+="新增「${added_csv}」"
    fi
    if [[ -n "${extra_csv}" ]]; then
        if [[ -n "${kept_csv}" || -n "${added_csv}" ]]; then
            context_note+="，"
        fi
        context_note+="既有的其它必需检查「${extra_csv}」一并保留"
    fi
    context_note+="；最终「${CONTEXTS_CSV}」"

    if [[ "${PROTECTED}" != "true" ]]; then
        if [[ "${GH_READY}" == "true" ]]; then
            CHANGES+=("分支 ${BRANCH} 当前【未受保护】：将新建整套保护规则")
        else
            CHANGES+=("分支 ${BRANCH} 的保护状态未知（gh 不可用）：将按目标状态写入")
        fi
        CHANGES+=("${context_note}")
    else
        local i=0
        for i in "${!FIELD_DESIRED[@]}"; do
            if [[ "${current[i]:-}" != "${FIELD_DESIRED[i]}" ]]; then
                CHANGES+=("${FIELD_LABELS[i]}：当前「${current[i]:-（缺省）}」→ 期望「${FIELD_DESIRED[i]}」")
            fi
        done
        # contexts 只有"内容真的不同"才算变更：并集的结果可能天然等于现状，
        # 此时不该触发一次无谓的 PUT。
        if [[ "${current[IDX_CONTEXTS]:-}" != "${CONTEXTS_CSV}" ]]; then
            CHANGES+=("${context_note}")
        fi
    fi

    if [[ "${CURRENT_DBM}" != "true" ]]; then
        DBM_CHANGE="delete_branch_on_merge：当前「${CURRENT_DBM}」→ 期望「true」"
    fi
    return 0
}

#######################################
# 保护规则请求体
#
# 用 --input - 传 JSON 而不是拼一串 -F：contexts 是数组，-F 只能表达标量，
# 且布尔值走 -F 的隐式类型转换要看 gh 版本，显式 JSON 让"发出去的到底是什么"可读可复制。
# contexts 取自 CONTEXTS_FINAL（并集），绝不在这里另写一份，否则两处会分叉。
#######################################
protection_payload() {
    local contexts_json="" item=""
    for item in "${CONTEXTS_FINAL[@]}"; do
        if [[ -z "${contexts_json}" ]]; then
            contexts_json="\"${item}\""
        else
            contexts_json="${contexts_json},\"${item}\""
        fi
    done

    cat <<JSON
{
  "required_status_checks": {
    "strict": false,
    "contexts": [${contexts_json}]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": ${REQUIRED_APPROVALS},
    "dismiss_stale_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "required_linear_history": false
}
JSON
}

#######################################
# 写入入口（无请求体）
#
# 干跑与实跑共用同一份参数构造，只在最后一步分叉：这样预览打印的命令与实跑发出的请求
# 必然一致，不会出现"预览里少了 -X PUT"这类只在真跑时才暴露的偏差。
#######################################
run_gh_write() {
    local display="$1"
    shift
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[干跑] 将执行：%s\n' "$display"
        return 0
    fi
    printf '[执行] %s\n' "$display"
    if ! gh api "$@"; then
        log_error "API 调用失败：$display"
        return "${E_UNAVAILABLE}"
    fi
    return 0
}

#######################################
# 写入入口（带 --input - 请求体）
#######################################
run_gh_write_stdin() {
    local display="$1"
    local payload="$2"
    shift 2
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[干跑] 将执行：%s\n' "$display"
        printf '[干跑] 请求体：\n%s\n' "$payload"
        return 0
    fi
    printf '[执行] %s\n' "$display"
    if ! printf '%s\n' "$payload" | gh api "$@"; then
        log_error "API 调用失败：$display"
        return "${E_UNAVAILABLE}"
    fi
    return 0
}

#######################################
# 应用保护规则与仓库开关
#######################################
apply_changes() {
    if [[ ${#CHANGES[@]} -gt 0 ]]; then
        local payload=""
        payload="$(protection_payload)"
        run_gh_write_stdin \
            "gh api -X PUT repos/${REPO}/branches/${BRANCH}/protection --input -" \
            "$payload" \
            -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input - || return $?
    fi

    if [[ -n "${DBM_CHANGE}" ]]; then
        # -F（而非 -f）让 gh 把 true 解析成 JSON 布尔值；用 -f 会发字符串 "true"，
        # GitHub 对 boolean 字段收到字符串会 422。
        run_gh_write \
            "gh api -X PATCH repos/${REPO} -F delete_branch_on_merge=true" \
            -X PATCH "repos/${REPO}" -F delete_branch_on_merge=true || return $?
    fi
    return 0
}

#######################################
# 打印验证方法
#
# 三条各自验证一件不同的事：保护规则细节、自动删分支开关、PR 上真正上报的检查名。
# 第三条必须有，因为 required_status_checks 里写错 context 名（大小写、job 名与 workflow 名之差）
# 的症状是"规则看起来配好了，PR 却永远 pending"，只有列出真实上报的 check 名才能定位。
#
# 另附一句关于 enforce_admins=true 的说明：它封死的是"绕过 PR 直推"，
# 不是"永远改不了 CI"——修复 pr-guard 的 PR 用的是修复后版本，能自己把自己救回来。
# 不写清楚这一点，读脚本的人会以为这是一个把人锁死的设置。
#######################################
print_verification() {
    cat <<EOF

如何验证（三条只读命令，随时可跑）：

  1. 读分支保护详情：
     gh api repos/${REPO}/branches/${BRANCH}/protection --jq '{checks: .required_status_checks.contexts, strict: .required_status_checks.strict, admins: .enforce_admins.enabled, reviews: .required_pull_request_reviews.required_approving_review_count, force_push: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled, conversation: .required_conversation_resolution.enabled}'

  2. 读合并后自动删分支开关：
     gh api repos/${REPO} --jq '.delete_branch_on_merge'

  3. 在某个 PR 上读实际上报的检查名（把 1 换成真实 PR 号）：
     gh pr view 1 --repo ${REPO} --json statusCheckRollup --jq '[.statusCheckRollup[].name]'

说明：enforce_admins=true 只封死"绕过 PR 直推 main"。修 pr-guard 的 PR 会用修复后的
workflow 版本运行并通过，因此不存在"改坏了 CI 就再也合不进修复"的死锁。
EOF
}

main() {
    parse_args "$@" || return $?

    check_gh || return $?
    resolve_repo || return $?

    local mode="实跑"
    if [[ "${DRY_RUN}" == "true" ]]; then
        mode="干跑（不写入远端）"
    fi
    log_info "目标仓库：${REPO}；目标分支：${BRANCH}；模式：${mode}"

    read_protection || return $?
    read_delete_branch_on_merge || return $?
    compute_diff

    if [[ "${PROTECTED}" == "true" ]]; then
        log_info "分支保护现状：已存在"
    elif [[ "${GH_READY}" == "true" ]]; then
        log_info "分支保护现状：未保护"
    else
        log_info "分支保护现状：未知（gh 不可用）"
    fi

    if [[ ${#CHANGES[@]} -gt 0 ]]; then
        printf '将变更（分支保护）：\n'
        local item=""
        for item in "${CHANGES[@]}"; do
            printf '  - %s\n' "$item"
        done
    else
        printf '无变更（分支保护）：已是目标状态\n'
    fi

    if [[ -n "${DBM_CHANGE}" ]]; then
        printf '将变更（仓库开关）：\n  - %s\n' "${DBM_CHANGE}"
    else
        printf '无变更（仓库开关）：delete_branch_on_merge 已是 true\n'
    fi

    apply_changes || return $?

    if [[ ${#CHANGES[@]} -gt 0 || -n "${DBM_CHANGE}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_success "干跑结束：以上命令未执行，远端未发生任何变化"
        else
            log_success "已应用变更；再次运行本脚本应输出「无变更」"
        fi
    else
        log_success "无需变更：目标状态已满足"
    fi

    print_verification
    return "${E_SUCCESS}"
}

main "$@"
exit $?
