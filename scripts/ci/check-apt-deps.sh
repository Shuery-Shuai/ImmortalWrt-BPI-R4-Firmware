#!/bin/bash
#######################################
# 主机 apt 包名存活校验（scripts/ci/check-apt-deps.sh）
#
# 为什么需要它：scripts/build/dependencies.txt 是主机依赖的唯一事实源，里面 85 个包名
# 只按 Ubuntu 24.04 (noble) 的真实存在性成立。Dependabot 没有 apt/deb 生态，
# 拿不到包名变更的自动 PR；noble 一旦改包名（历史上 gnutls-dev -> libgnutls28-dev、
# mkisofs -> xorriso），这里校验失败就是最早能拿到的信号。
#
# 本脚本只【报告】不改文件：改名映射无法从索引里自动获得，猜一个近似包名只会把清单改坏，
# 因此失效包名交给 .github/workflows/dependency-auditor.yml 开/更新 issue 由人确认。
#
# 解析规则必须与 scripts/build/steps/install-deps.sh 的 install_dependencies 完全一致
# （grep -vE '^[[:space:]]*(#|$)' 过滤后每行切词），否则"脚本认为存在的包"与
# "apt 实际要装的包"会分叉，巡检就失去意义。
#
# 用法：
#   scripts/ci/check-apt-deps.sh [--file <path>]
#
# 输出（stdout，workflow 依赖这个格式解析）：
#   MISSING <包名>           每个在 noble 四个索引里查不到的包名各占一行
#   all <N> packages present  全部存在时的唯一一行
# 日志一律走 stderr（log_info / log_warning / log_error），不污染 stdout。
#
# 退出码（常量来自 scripts/libs/02-error-handler.sh）：
#   E_SUCCESS(0)      全部包名存在
#   E_DATAERR(65)     有包名查不到（依赖问题，需要人改清单）
#   E_UNAVAILABLE(69) 索引下载或压缩流校验失败（网络问题，不是依赖问题）
#   另有 E_USAGE(64) 与 E_NOINPUT(66) 用于参数/输入错误：契约里的三种结果不变，
#   这两种是"脚本自己被调错了"，与依赖是否失效无关，分开报便于定位。
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 加载顺序即依赖顺序：logger 最先（全仓库唯一 log 实现），error-handler 次之（退出码常量）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# shellcheck source=scripts/libs/02-error-handler.sh
source "${SCRIPT_DIR}/../libs/02-error-handler.sh"

# 与 generate-index.sh 同一做法：先把 CWD 锚到仓库根，默认路径与 --file 的相对路径都以仓库根解析，
# 否则从任意目录调用都会读错文件。
cd "${SCRIPT_DIR}/../.." || {
    log_error "无法进入仓库根目录：${SCRIPT_DIR}/../.."
    exit "${E_UNAVAILABLE}"
}

# 排序与集合差一律走 C 语系：comm 要求两侧使用同一排序规则，
# 中文/其它 locale 的字典序会让结果错位，出现"其实存在却被报缺失"的假警报。
export LC_ALL=C

readonly DEFAULT_DEPS_FILE="scripts/build/dependencies.txt"
# noble 的索引集合：main + universe 是包名存在的全集；noble-updates 只带修补版本，
# 但用户在 updates 里能装到的包也必须算"存在"，所以四个索引一起查。
readonly UBUNTU_ARCHIVE_BASE="http://archive.ubuntu.com/ubuntu/dists"
readonly -a INDEX_DISTS=(noble/main noble/universe noble-updates/main noble-updates/universe)

# 临时目录用脚本级变量：EXIT trap 在 main 返回之后、全局作用域里执行，
# main 的 local 变量那时已离开作用域，trap 里展开会得到空路径（清理悄悄失效）。
TMP_DIR_APT=""

# shellcheck disable=SC2329  # 只由下面的 EXIT trap 调用，静态分析看不到这层引用
cleanup_apt_check() {
    if [[ -n "${TMP_DIR_APT}" ]] && [[ -d "${TMP_DIR_APT}" ]]; then
        rm -rf -- "${TMP_DIR_APT}"
    fi
    TMP_DIR_APT=""
}
trap cleanup_apt_check EXIT

usage() {
    cat <<'EOF'
用法：scripts/ci/check-apt-deps.sh [--file <path>]

  --file <path>  要校验的依赖清单（默认 scripts/build/dependencies.txt；相对路径按仓库根解析）
  -h, --help     显示本帮助
EOF
}

#######################################
# 把依赖清单解析成"待校验包名"清单（排序去重后落盘）
#
# 参数：
#   $1 - 依赖清单路径
#   $2 - 输出文件路径
#
# 输出：
#   包名总数（整数）
#
# 返回：
#   0 - 解析完成
#   1 - 无法写出输出文件
#######################################
_collect_wanted_names() {
    local file="$1"
    local dest="$2"
    local line
    local -a words=()

    : >"${dest}" || return 1
    # 过滤规则与 install-deps.sh 逐字一致；一行写多个包名时同样切词后逐个入列。
    while IFS= read -r line; do
        words=()
        read -r -a words <<<"${line}"
        if [[ ${#words[@]} -eq 0 ]]; then
            continue
        fi
        printf '%s\n' "${words[@]}" >>"${dest}"
    done < <(grep -vE '^[[:space:]]*(#|$)' "${file}" || true)

    sort -u -o "${dest}" "${dest}" || return 1
    wc -l <"${dest}" | tr -d '[:space:]'
}

#######################################
# 下载单个 Packages.gz 索引到临时目录
#
# 参数：
#   $1 - dist 路径（形如 noble/main）
#   $2 - 落地文件路径（.gz）
#
# 返回：
#   0 - 下载且压缩流完整
#   1 - 下载失败或压缩流损坏（调用方按 E_UNAVAILABLE 处理）
#######################################
_download_index() {
    local dist="$1"
    local dest="$2"
    local url="${UBUNTU_ARCHIVE_BASE}/${dist}/binary-amd64/Packages.gz"

    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 180 -o "${dest}" "${url}"; then
        log_error "索引下载失败：${url}"
        return 1
    fi
    # 先单独校验压缩流完整性：否则"下载到半个文件"的 gzip 解压错误会被后面
    # grep 的退出码掩盖，看起来就像"包名全都不存在"，把人引到错误方向。
    if ! gzip -t "${dest}" 2>/dev/null; then
        log_error "索引压缩流损坏：${url}"
        return 1
    fi
    return 0
}

#######################################
# 从索引里筛出"目标包名中确实存在"的那些（追加写入）
#
# 参数：
#   $1 - 索引 .gz 路径
#   $2 - 待校验包名文件（每行一个，已排序）
#   $3 - 命中结果输出路径（追加）
#
# 返回：
#   恒为 0：本函数里的退出码 1 只代表"本索引里没有目标包名"（完全合法），
#   不能据此判定下载失败，否则 noble-updates 缺某个包时会误报成网络故障。
#######################################
_collect_present_names() {
    local index_gz="$1"
    local wanted="$2"
    local dest="$3"

    # 全程流式：gzip -dc 之后立刻用 sed 只留包名，绝不把上百 MB 的 Packages 文本落盘。
    # grep -x -F -f 以固定串整行匹配这几十个目标包名，一趟扫完，也不需要中间排序文件。
    gzip -dc "${index_gz}" | sed -n 's/^Package: //p' | grep -x -F -f "${wanted}" >>"${dest}" || true
    return 0
}

main() {
    local deps_file="${DEFAULT_DEPS_FILE}"
    local wanted=""
    local present=""
    local wanted_count=""
    local missing=""
    local missing_count=0
    local dist=""
    local index_gz=""
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --file)
            if [[ $# -lt 2 ]]; then
                log_error "--file 缺少路径参数"
                usage >&2
                return "${E_USAGE}"
            fi
            deps_file="$2"
            shift 2
            ;;
        --file=*)
            deps_file="${1#--file=}"
            shift
            ;;
        -h | --help)
            usage
            return "${E_SUCCESS}"
            ;;
        *)
            log_error "未知参数：$1"
            usage >&2
            return "${E_USAGE}"
            ;;
        esac
    done

    if [[ ! -f "${deps_file}" ]] || [[ ! -r "${deps_file}" ]]; then
        log_error "依赖清单不存在或不可读：${deps_file}"
        return "${E_NOINPUT}"
    fi

    TMP_DIR_APT="$(mktemp -d)" || {
        log_error "无法创建临时目录"
        return "${E_UNAVAILABLE}"
    }
    wanted="${TMP_DIR_APT}/wanted.txt"
    present="${TMP_DIR_APT}/present.txt"

    if ! wanted_count="$(_collect_wanted_names "${deps_file}" "${wanted}")"; then
        log_error "解析依赖清单失败：${deps_file}"
        return "${E_NOINPUT}"
    fi
    if [[ "${wanted_count}" == "0" ]]; then
        # 空清单在 install-deps.sh 里也只是警告，不算依赖失效，因此不给失败退出码。
        log_warning "依赖清单里没有包名：${deps_file}"
        printf 'all 0 packages present\n'
        return "${E_SUCCESS}"
    fi

    log_info "校验 ${wanted_count} 个包名是否存在于 noble 索引：${deps_file}"
    for dist in "${INDEX_DISTS[@]}"; do
        index_gz="${TMP_DIR_APT}/${dist//\//_}.Packages.gz"
        _download_index "${dist}" "${index_gz}" || return "${E_UNAVAILABLE}"
        log_info "已下载 noble 索引：${dist}"
        _collect_present_names "${index_gz}" "${wanted}" "${present}"
    done

    sort -u -o "${present}" "${present}" || return "${E_UNAVAILABLE}"
    # comm -23 取"只在 wanted 里、不在索引里"的行，正好是失效包名。
    missing="$(comm -23 "${wanted}" "${present}")"

    if [[ -n "${missing}" ]]; then
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            printf 'MISSING %s\n' "${name}"
            missing_count=$((missing_count + 1))
        done <<<"${missing}"
        log_error "${missing_count} 个包名在 noble 索引中不存在（${deps_file}）"
        return "${E_DATAERR}"
    fi

    printf 'all %s packages present\n' "${wanted_count}"
    log_success "全部 ${wanted_count} 个包名在 noble 索引中存在。"
    return "${E_SUCCESS}"
}

main "$@"
exit "$?"
