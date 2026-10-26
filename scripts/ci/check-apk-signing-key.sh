#!/bin/bash
#######################################
# APK 签名公钥指纹门禁（scripts/ci/check-apk-signing-key.sh）
#
# 为什么需要它：仓库不再入库公钥（keys/public-key.pem 已删除），"派生公钥与入库公钥逐字节比对"
# 这条门禁失去了比对对象。现在唯一基准是仓库 Variable APK_PUBLIC_KEY_SHA256：由私钥派生的
# 公钥，其 sha256 必须等于该指纹，否则说明私钥已漂移——新固件用的就不再是已发布设备信任的公钥。
#
# 基准从哪里来：取值链与私钥完全对齐，两块地方都读。
#   1. 环境变量 APK_PUBLIC_KEY_SHA256 —— CI 的 Repository Variable，权威来源；
#   2. 本地文件 keys/public-key.pem（可由 APK_PUBLIC_KEY 覆盖）—— 本地构建的回退，
#      直接对该文件求 sha256 作为基准，与本地直接读 keys/private-key.pem 同一思路；
#   3. 两者都没有：严格模式硬失败，本地降级为警告并打印指引。
# 公钥的职责是证明私钥没有漂移，因此它与私钥一样属于既可本地读、也可环境变量给的两栖输入，
# 而不是只有 CI 才配拥有的单一来源。
#
# 本脚本是这条比对的【唯一实现】：pipeline.sh 的 restore_apk_signing_key 与 CI 都只调用它，
# 避免两处各写一份指纹逻辑后分叉。
#
# 严格度：沿用 scripts/build/common/strictness.sh —— REQUIRED=1（CI）下缺变量即中断；
# 本地缺省 REQUIRED=0 时同一条件降级为警告，保证首次构建能跑起来。
# 例外：格式非法与指纹不一致【永远】硬失败——那是真实漂移，不是"还没配"。
#
# 用法：
#   scripts/ci/check-apk-signing-key.sh env
#       校验环境变量 APK_PUBLIC_KEY_SHA256 的存在性与格式（64 位小写 hex）。
#       允许输入含大写与前后空白，先规范化再判。
#   scripts/ci/check-apk-signing-key.sh key <public-key-file>
#       计算该公钥文件的 sha256，与 APK_PUBLIC_KEY_SHA256 比对。
#
# 退出码：
#   0  通过；或缺变量但 REQUIRED!=1（已降级为警告并打印处置指引）
#   1  缺变量且 REQUIRED=1 / 格式非法 / 公钥文件不存在或为空 / 指纹不一致
#   2  用法错误（无参数、未知子命令、key 少给文件参数）：usage 打到 stderr
#
# 依赖：scripts/libs/01-shell-logger.sh（log_*）、scripts/build/common/strictness.sh（required_mode）。
# 临时文件：本脚本不创建任何临时文件。
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 本脚本在 CI 里是一个独立的 workflow 步骤，日志会随 logs/ artifact 一起上传，
# 因此必须遵守仓库的 build-<步骤> 命名（库只管格式，命名约定由调用方给）。
# 名字要在 source 之前定：logger 在 source 那一刻就拼好路径了。
# 被 pipeline.sh 间接调用时，pipeline 已导出 LOG_FILE_BASENAME，这里不会覆盖它。
LOG_FILE_BASENAME="${LOG_FILE_BASENAME:-build-check-apk-signing-key}"
export LOG_FILE_BASENAME

# 加载顺序即依赖顺序：logger 最先（strictness.sh 自身调用 log_error / log_warning）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# shellcheck source=scripts/build/common/strictness.sh
source "${SCRIPT_DIR}/../build/common/strictness.sh"

# 退出码写成常量：调用方（workflow / pipeline.sh）按数字判断，改名会静默改变契约。
readonly EXIT_CHECK_PASS=0
readonly EXIT_CHECK_FAIL=1
readonly EXIT_CHECK_USAGE=2

usage() {
    cat >&2 <<'EOF'
用法：
  scripts/ci/check-apk-signing-key.sh env
      确认基准指纹存在且格式合法（64 位小写 hex）。
      基准优先取环境变量 APK_PUBLIC_KEY_SHA256；缺失时回退到本地 keys/public-key.pem 的 sha256。
  scripts/ci/check-apk-signing-key.sh key <public-key-file>
      计算 <public-key-file> 的 sha256，与同一份基准指纹比对。
EOF
}

#######################################
# 打印完整处置指引（缺变量时严格与降级两条路径共用同一份文本）
#
# 直接写 stderr 而不过 log_*：这些是"可整段复制执行"的命令，不能带时间戳/颜色前缀。
#######################################
print_apk_key_guide() {
    cat >&2 <<'EOF'
────────────────────────────────────────────────────────────────────
APK_PUBLIC_KEY_SHA256 未设置：签名公钥指纹门禁没有比对基准。

一、在【仓库根】生成密钥对并取得要写入仓库设置的两个值（只做一次；已有密钥对可跳过本步）
    生成物落在 keys/ 下，与本地构建缺省查找的 keys/private-key.pem 一致
    mkdir -p keys
    openssl ecparam -name prime256v1 -genkey -noout -out keys/private-key.pem
    openssl ec -in keys/private-key.pem -pubout -out keys/public-key.pem
    base64 -w0 keys/private-key.pem                  # → Secret   APK_PRIVATE_KEY_B64
    sha256sum keys/public-key.pem | awk '{print $1}' # → Variable APK_PUBLIC_KEY_SHA256

    注意：sha256sum 只取行首那 64 位十六进制，不要带后面的空格与文件名。
    本地构建还有更省事的一条路：把公钥留在 keys/public-key.pem 即可，
    脚本会直接对该文件求指纹当基准（与本地直接读 keys/private-key.pem 同一思路），
    Variable 因此只在 CI 上才必需。

二、GitHub 仓库 Settings → Secrets and variables → Actions
    Secret    APK_PRIVATE_KEY_B64       = 上面 base64 那一串（单行、无换行）
    Variable  APK_PUBLIC_KEY_SHA256     = 上面 sha256 那 64 位小写十六进制

三、keys/public-key.pem 与 keys/private-key.pem 都不得提交到仓库
    keys/ 下这两个文件都已被 .gitignore 忽略；公钥是一次性派生产物，用完即弃。
    两者只应留在本机或 CI Secret 中。
────────────────────────────────────────────────────────────────────
EOF
}

#######################################
# 规范化指纹输入：去前后空白，统一小写
#
# 参数：
#   $1 - 原始字符串（可能为空）
#
# 输出：
#   stdout 规范化后的字符串（可能为空）
#######################################
normalize_sha256() {
    local raw="$1"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    printf '%s' "${raw,,}"
}

#######################################
# 解析基准指纹：两块地方，优先级与私钥一致
#
# 输出：stdout 规范化后的基准指纹；一个来源都取不到时输出空串
# 返回：0 拿到基准；1 环境变量与本地公钥都没有
#
# 为什么允许本地文件：公钥的职责是证明私钥没漂移。本地开发者手里已有
# keys/private-key.pem（构建时会被直接读取），若还要求他配环境变量才能构建，
# 两者的待遇就不一致了。本地 keys/public-key.pem 同样是既成事实的输入。
#######################################
resolve_expected_fingerprint() {
    local raw expected local_pub local_fp
    raw="${APK_PUBLIC_KEY_SHA256:-}"
    expected="$(normalize_sha256 "${raw}")"
    local_pub="${APK_PUBLIC_KEY:-keys/public-key.pem}"
    if [[ -n "${expected}" ]]; then
        # 变量在就是权威；但本地另有公钥且指纹不同，说明本地密钥已漂移。
        # 不点出来的话，本地构建用的是一把、CI 校验的是另一把，问题会拖到发布才暴露。
        if [[ -s "${local_pub}" ]]; then
            local_fp="$(sha256sum -- "${local_pub}" | cut -d ' ' -f 1)" || local_fp=""
            if [[ -n "${local_fp}" && "${local_fp}" != "${expected}" ]]; then
                log_warning "本地 ${local_pub} 的指纹与 APK_PUBLIC_KEY_SHA256 不一致：以环境变量为准，但本地密钥已漂移。"
                log_warning "  变量：${expected}"
                log_warning "  本地：${local_fp}  （${local_pub}）"
            fi
        fi
        printf '%s' "${expected}"
        return 0
    fi
    # 与私钥同款回退：本地公钥文件存在，就直接用它算指纹当基准。
    if [[ -s "${local_pub}" ]]; then
        sha256sum -- "${local_pub}" | cut -d ' ' -f 1
        return 0
    fi
    return 1
}

#######################################
# 报告格式非法（无论 REQUIRED 取值都硬失败）
#
# 参数：
#   $1 - 规范化后的值
#######################################
report_invalid_format() {
    local value="$1"
    log_error "APK_PUBLIC_KEY_SHA256 格式非法：要求 64 位十六进制，实际长度 ${#value}。"
    log_error "实际值（截断到 80 字符）：${value:0:80}"
    log_error "取法：sha256sum keys/public-key.pem 只取行首 64 位十六进制，不要带文件名与空格。"
}

#######################################
# 缺变量分支：打印同一份指引，再按严格度决定退出码
#
# 返回：
#   1 - REQUIRED=1（严格模式，必须中断）
#   0 - 本地降级为警告
#######################################
handle_missing_variable() {
    print_apk_key_guide
    if required_mode; then
        log_error "基准指纹缺失（环境变量 APK_PUBLIC_KEY_SHA256 与本地 keys/public-key.pem 都没有），且 REQUIRED=1：请按上面的指引配置。"
        return "${EXIT_CHECK_FAIL}"
    fi
    log_warning "基准指纹缺失（REQUIRED!=1，降级为警告）：签名公钥指纹未校验，构建继续。"
    log_warning "配 Variable APK_PUBLIC_KEY_SHA256，或把公钥放到 keys/public-key.pem，二者其一即可；否则 CI 会中断、本地也发现不了私钥漂移。"
    return "${EXIT_CHECK_PASS}"
}

#######################################
# 子命令 env：只校验变量存在性与格式（门禁要在最开始时用得上）
#######################################
cmd_check_env() {
    local expected rc
    # 基准的两块来源由 resolver 统一收口：变量优先，本地公钥回退。
    expected="$(resolve_expected_fingerprint)" || expected=""

    if [[ -z "${expected}" ]]; then
        handle_missing_variable
        rc=$?
        return "${rc}"
    fi
    if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
        report_invalid_format "${expected}"
        return "${EXIT_CHECK_FAIL}"
    fi
    log_success "APK_PUBLIC_KEY_SHA256 格式合法：${expected}"
    return "${EXIT_CHECK_PASS}"
}

#######################################
# 子命令 key：公钥文件指纹与 APK_PUBLIC_KEY_SHA256 比对
#
# 参数：
#   $1 - 已派生的公钥文件路径（绝对路径或相对 CWD 的路径）
#######################################
cmd_check_key() {
    local key_file="$1" expected actual rc

    if [[ -z "${key_file}" ]]; then
        log_error "key 子命令缺少参数：<public-key-file>。"
        usage
        return "${EXIT_CHECK_USAGE}"
    fi

    # 与 env 子命令同一条取值链：变量优先，本地公钥回退。
    expected="$(resolve_expected_fingerprint)" || expected=""
    if [[ -z "${expected}" ]]; then
        # 没有基准就无从比对：严格度决定是中断还是跳过。
        handle_missing_variable
        rc=$?
        return "${rc}"
    fi
    if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
        report_invalid_format "${expected}"
        return "${EXIT_CHECK_FAIL}"
    fi

    if [[ ! -f "${key_file}" ]]; then
        log_error "公钥文件不存在或不是普通文件：${key_file}"
        return "${EXIT_CHECK_FAIL}"
    fi
    if [[ ! -s "${key_file}" ]]; then
        log_error "公钥文件为空：${key_file}"
        return "${EXIT_CHECK_FAIL}"
    fi

    # cut 掉 sha256sum 输出里的文件名：只比对指纹本身。
    actual="$(sha256sum -- "${key_file}" | cut -d ' ' -f 1)" || {
        log_error "无法计算公钥文件的 sha256：${key_file}"
        return "${EXIT_CHECK_FAIL}"
    }

    if [[ "${actual}" != "${expected}" ]]; then
        # 真实漂移一律硬失败，不受 REQUIRED 影响：放过它等于让新旧固件的信任链分叉。
        log_error "APK 签名公钥指纹不一致（真实漂移，不受 REQUIRED 影响）："
        log_error "  期望：${expected}"
        log_error "  实际：${actual}  （由 ${key_file} 计算）"
        return "${EXIT_CHECK_FAIL}"
    fi

    log_success "APK 签名公钥指纹匹配 APK_PUBLIC_KEY_SHA256：${actual}"
    return "${EXIT_CHECK_PASS}"
}

main() {
    local subcommand="${1:-}"
    case "${subcommand}" in
    env)
        cmd_check_env
        ;;
    key)
        cmd_check_key "${2:-}"
        ;;
    "")
        log_error "缺少子命令。"
        usage
        return "${EXIT_CHECK_USAGE}"
        ;;
    *)
        log_error "未知子命令：${subcommand}"
        usage
        return "${EXIT_CHECK_USAGE}"
        ;;
    esac
}

main "$@"
exit $?
