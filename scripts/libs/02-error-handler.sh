#!/bin/bash
#######################################
# 错误收敛辅助库（scripts/libs/02-error-handler.sh）
#
# 职责边界（与 scripts/libs/01-shell-logger.sh 的分工，不要越界）：
#   · 01-shell-logger.sh —— 只负责【日志格式】：log / log_info / log_success / log_warning /
#     log_error、级别过滤、颜色、emoji、落文件。全仓库唯一实现。
#   · 02-error-handler.sh（本文件）—— 只负责【控制流与退出码】：何时记录失败、何时返回、
#     退出码取什么值、命令包装的成败判定。本文件不定义任何 log / COLOR_* / LOG_LEVEL_*，
#     只调用 log_error / log_warning。
#
# 本仓库有两类失败现场，失败语义相反，混用就是缺陷：
#   · 被 source 的库与函数（scripts/libs/*、scripts/build/*、scripts/inputs/utils/*）——调用者的
#     shell 必须在失败后活下来，否则清理、重试、错误上报全部被跳过，构建"中途消失"只留最后一行日志。
#   · 顶层可执行脚本（scripts/build/build.sh、scripts/ci/*.sh）——没有调用者，"整段终止"才是对的。
# 因此这里只提供一个"整段终止"的动作，函数名即语义：
#
#   fail <message...>   记录错误（log_error）后 return 1。【库与函数一律用它，这是默认】
#   die  <message...>   记录错误（log_error）后 exit 1。【只给顶层可执行脚本用】
#
# 硬约束：本文件被 source，自身【绝不 exit】。除 die 之外，所有函数（含命令包装与断言）
# 一律 return 1，把"要不要终止"的决定权交还调用者。
#
# 输出形态：fail / die 都只是 log_error 的透传（fail 用 "$@" 原样转交，因此 log_error 的
# 「log_error 消息」与「log_error 分类 消息」两种调用形态照旧可用），消息文本、级别、颜色、
# emoji、是否落文件全部不变。只有一处必然不同：log_error 从调用栈取【第一个非 01-shell-logger.sh 的层级】
# 作脚本名标签，多一层 fail 后该标签由调用方文件变为 "02-error-handler"——这与同一仓库里其他库内包装
# （如 strictness.sh 的 require_or_warn 打 "[strictness]"）属同一既有形态，不是新格式。
#
# 依赖：scripts/libs/01-shell-logger.sh —— 本文件只调用 log_error / log_warning。
#
# 用法：
#   source scripts/libs/01-shell-logger.sh
#   source scripts/libs/02-error-handler.sh
#
#   require_cmd git curl || return 1        # 前置检查：缺一个就 fail 到具体那个
#   require_file "${CONFIG}" || return 1
#   run make -j"${JOBS}" || return 1        # 失败=记录命令原文+退出码，输出保留
#   if try grep -q foo file; then ...; fi   # 只取退出码，不报错
#   with_retry 3 git fetch || return 1      # 三次尝试，最终失败才 fail
#   cmd || fail "Failed to ..."             # 库或函数内：调用者存活，自行决定要不要继续/终止
#   cmd || die  "Failed to ..."             # 可执行脚本顶层：整个进程以 1 退出
#   exit_code_to_name "$?"                  # 64 -> USAGE（sysexits 正式名，不带 E_ 前缀）
#
# ── 退出码常量（沿用 sysexits.h，只读；定义在下方哨兵块内，重复 source 不会二次赋值）───
#   变量名     值   含义
#   E_SUCCESS   0   成功
#   E_GENERAL   1   未归类的通用失败（存量 23 处 exit 1 的含义，本轮不迁移、保持原样）
#   E_USAGE    64   命令行用法错误（参数缺失/非法）
#   E_DATAERR  65   输入数据格式错误
#   E_NOINPUT  66   输入文件/资源不存在或不可读
#   E_UNAVAILABLE 69 依赖的外部服务/命令不可用
#   E_SOFTWARE 70   内部软件错误
#   E_OSERR    71   操作系统错误
#   E_CANTCREAT 73  无法创建输出文件
#   E_IOERR    74   输入输出错误
#
#   命名约定（与任务书字面略有出入，理由在此）：
#   · 常量一律带 E_ 前缀（E_USAGE）—— 这是"退出码取值"这一命名空间，避免与普通变量撞名。
#   · exit_code_to_name 返回的显示名【不带】E_ 前缀（64 -> USAGE）：它用于拼进错误信息，
#     保持与 sysexits.h 的正式名可对照；带上前缀后同一行日志里会出现
#     "退出码 64，E_USAGE" 这种"常量名当人类可读名"的混用。若调用方确实需要带前缀的形态，
#     拼一个即可：E_$(exit_code_to_name "$rc")。
#   ★ 本轮只定义常量与名字映射，【不迁移】任何既有 exit 1 调用点；存量仍是 0/1 两码。
#
# ── trap 的三条实测限制（本轮不实现 trap / cleanup 栈，仅记录，留给后续专门任务）───
#   1) trap ERR 在【无 set -e】时也会触发 —— 与"ERR 只在 set -e 下生效"的常见说法相反。
#   2) trap ERR 在 if / && / || 的失败分支中【不触发】—— 即"被检查过的失败"不会走到 trap，
#      真正被漏掉的失败恰恰是被 condition 化处理的那一类。
#   3) 连续两次 trap X EXIT，【只有最后一个执行】，前一个被静默覆盖。
#   因此：cleanup 栈与 trap 封装【本轮未实现】。在它们落地前，清理必须显式写在调用点，
#   不要指望 trap 兜底；也不要在同一脚本里重复装 EXIT trap 还指望两个都跑。
#######################################

# 防重复加载：与 01-shell-logger.sh 同一哨兵写法。重复定义函数本身无害，
# 但重复赋值 readonly 哨兵与 readonly 退出码常量会按加载顺序报"只读变量"并中断调用者，
# 因此整块定义（含常量与映射表）都要跳过。
if [[ -z "${_ERROR_HANDLER_SH_LOADED:-}" ]]; then
    readonly _ERROR_HANDLER_SH_LOADED=1

    # 退出码常量：sysexits.h 约定，全仓库统一取值。只读，任何调用点都不应改写。
    readonly E_SUCCESS=0 E_GENERAL=1
    readonly E_USAGE=64 E_DATAERR=65 E_NOINPUT=66
    readonly E_UNAVAILABLE=69 E_SOFTWARE=70 E_OSERR=71
    readonly E_CANTCREAT=73 E_IOERR=74

    #######################################
    # 记录错误并返回 1（绝不 exit）
    #
    # 参数：
    #   $@ - 原样交给 log_error（"消息" 或 "分类" "消息"）
    #
    # 返回：
    #   恒为 1
    #######################################
    fail() {
        log_error "$@"
        return 1
    }

    #######################################
    # 记录错误并退出 1（仅供顶层可执行脚本）
    #
    # 参数：
    #   $@ - 原样交给 log_error
    #
    # 返回：
    #   不返回：进程以状态 1 结束
    #######################################
    die() {
        log_error "$@"
        exit 1
    }

    #######################################
    # 把数字退出码翻译成显示名（内部函数，供错误信息拼接）
    #
    # 参数：
    #   $1 - 退出码
    #
    # 输出：
    #   sysexits 名（64 -> USAGE）；未知码或非数字输出 UNKNOWN
    #
    # 返回：
    #   恒为 0（未知码不是错误，调用方通常只是拼日志）
    #######################################
    exit_code_to_name() {
        # 映射表是函数内 local readonly 数组，不进全局：它只是本函数的实现细节，
        # 全部代号（含 E_ 常量本身）也在这里被引用，因此库里没有"只赋值不使用"的变量。
        local -ar _code_names=(
            ["${E_SUCCESS}"]=SUCCESS ["${E_GENERAL}"]=GENERAL
            ["${E_USAGE}"]=USAGE ["${E_DATAERR}"]=DATAERR ["${E_NOINPUT}"]=NOINPUT
            ["${E_UNAVAILABLE}"]=UNAVAILABLE ["${E_SOFTWARE}"]=SOFTWARE ["${E_OSERR}"]=OSERR
            ["${E_CANTCREAT}"]=CANTCREAT ["${E_IOERR}"]=IOERR
        )
        local _code="${1:-}"
        local BASH_REMATCH
        # 先挡非数字：数组下标会做算术求值，传入 "abc" 会被求值成 0 而误报成 SUCCESS。
        # BASH_REMATCH 必须显式 local，否则 =~ 会把匹配结果写进调用者的 shell。
        if ! [[ "${_code}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' UNKNOWN
            return 0
        fi
        # 越界下标取到空串，靠 :- 兜底成 UNKNOWN（set -u 下也安全）。
        printf '%s\n' "${_code_names[_code]:-UNKNOWN}"
    }

    #######################################
    # 把 argv 还原成可读命令行（内部函数）
    #
    # 用 %q 逐参数转义，而不是 $*：$* 会把一个含空格的参数 "a b" 与两个参数 a b
    # 显示成同一串，排查时会看错失败现场。
    #
    # 参数：
    #   $@ - 命令及其参数
    #
    # 输出：
    #   单行命令行字符串（无末尾空格）
    #
    # 返回：
    #   恒为 0
    #######################################
    _render_cmd() {
        local _joined
        _joined=$(printf '%q ' "$@")
        printf '%s' "${_joined% }"
    }

    #######################################
    # 断言：命令存在（command -v）
    #
    # 多参数时【在第一个缺失处就返回】—— 与 run/try 的 fail-fast 语义一致，
    # 错误信息永远指向一个具体的命令，而不是一串待猜的清单。
    #
    # 参数：
    #   $@ - 一个或多个命令名
    #
    # 返回：
    #   0 - 全部存在
    #   1 - 任一缺失（已 fail，指明具体是哪个命令）
    #######################################
    require_cmd() {
        if [[ $# -eq 0 ]]; then
            fail "require_cmd" "未提供命令名"
            return 1
        fi
        local _cmd
        for _cmd in "$@"; do
            if ! command -v -- "${_cmd}" >/dev/null 2>&1; then
                fail "require_cmd" "缺少命令：${_cmd}"
                return 1
            fi
        done
        return 0
    }

    #######################################
    # 断言：变量已设置且非空（用 ${!var} 间接取值）
    #
    # 参数：
    #   $@ - 一个或多个变量名（不是值）
    #
    # 返回：
    #   0 - 全部非空
    #   1 - 第一个为空/未设置的变量（已 fail，指明具体变量名）
    #######################################
    require_var() {
        if [[ $# -eq 0 ]]; then
            fail "require_var" "未提供变量名"
            return 1
        fi
        local _name
        for _name in "$@"; do
            # ${!name:-} = 先间接展开再取默认值，因此变量未设置时也不会被 set -u 打断。
            if [[ -z "${!_name:-}" ]]; then
                fail "require_var" "变量未设置或为空：${_name}"
                return 1
            fi
        done
        return 0
    }

    #######################################
    # 断言：普通文件存在且可读（-f 且 -r）
    #
    # 参数：
    #   $@ - 一个或多个路径
    #
    # 返回：
    #   0 - 全部存在且可读
    #   1 - 第一个不满足的路径（已 fail，指明具体路径与原因）
    #######################################
    require_file() {
        if [[ $# -eq 0 ]]; then
            fail "require_file" "未提供文件路径"
            return 1
        fi
        local _path
        for _path in "$@"; do
            if [[ ! -f "${_path}" ]]; then
                fail "require_file" "文件不存在或不是普通文件：${_path}"
                return 1
            fi
            if [[ ! -r "${_path}" ]]; then
                fail "require_file" "文件不可读：${_path}"
                return 1
            fi
        done
        return 0
    }

    #######################################
    # 断言：目录存在（-d）
    #
    # 参数：
    #   $@ - 一个或多个路径
    #
    # 返回：
    #   0 - 全部是目录
    #   1 - 第一个不是目录的路径（已 fail，指明具体路径）
    #######################################
    require_dir() {
        if [[ $# -eq 0 ]]; then
            fail "require_dir" "未提供目录路径"
            return 1
        fi
        local _path
        for _path in "$@"; do
            if [[ ! -d "${_path}" ]]; then
                fail "require_dir" "目录不存在：${_path}"
                return 1
            fi
        done
        return 0
    }

    #######################################
    # 断言：路径存在且可执行（-x）
    #
    # 参数：
    #   $@ - 一个或多个路径
    #
    # 返回：
    #   0 - 全部可执行
    #   1 - 第一个不可执行的路径（已 fail，指明具体路径）
    #######################################
    require_exec() {
        if [[ $# -eq 0 ]]; then
            fail "require_exec" "未提供路径"
            return 1
        fi
        local _path
        for _path in "$@"; do
            if [[ ! -x "${_path}" ]]; then
                fail "require_exec" "路径不存在或不可执行：${_path}"
                return 1
            fi
        done
        return 0
    }

    #######################################
    # 执行命令；成功返回 0，失败时 fail 并返回 1
    #
    # 输出：命令自身的 stdout / stderr 原样流出（不重定向、不捕获），
    #       失败信息只是【追加】在原有输出之后，绝不替换或吞掉它。
    #
    # 参数：
    #   $@ - 命令及其参数（直接 exec，不经 shell 解析，因此不要传管道/重定向）
    #
    # 返回：
    #   0 - 命令退出码为 0
    #   1 - 命令退出码非 0（已 fail，含命令原文与退出码）
    #######################################
    run() {
        if [[ $# -eq 0 ]]; then
            fail "run" "未提供命令"
            return 1
        fi
        local _rc=0
        # 用 || 承接状态：既拿到真实退出码，又让 set -e 的调用者不会在包装层提前退出。
        "$@" || _rc=$?
        if ((_rc != 0)); then
            fail "run" "命令执行失败（退出码 ${_rc}，$(exit_code_to_name "${_rc}")）：$(_render_cmd "$@")"
            return 1
        fi
        return 0
    }

    #######################################
    # 执行命令并【只】返回其退出码：不打印任何错误日志，供调用方 if 判断
    #
    # 参数：
    #   $@ - 命令及其参数
    #
    # 返回：
    #   命令自身的退出码（0..255）；无参数时返回 1
    #######################################
    try() {
        if [[ $# -eq 0 ]]; then
            return 1
        fi
        local _rc=0
        "$@" || _rc=$?
        return "${_rc}"
    }

    #######################################
    # 执行命令；失败时用自定义消息 fail
    #
    # 参数：
    #   $1 - 失败时要打印的消息（业务语义）
    #   $2.. - 命令及其参数
    #
    # 返回：
    #   0 - 命令成功
    #   1 - 命令失败（已 fail：自定义消息 + 命令原文 + 退出码）
    #######################################
    run_or_fail() {
        if [[ $# -lt 2 ]]; then
            fail "run_or_fail" "用法：run_or_fail <消息> <命令...>"
            return 1
        fi
        local _msg="$1"
        shift
        local _rc=0
        "$@" || _rc=$?
        if ((_rc == 0)); then
            return 0
        fi
        fail "run_or_fail" "${_msg}（命令退出码 ${_rc}，$(exit_code_to_name "${_rc}")）：$(_render_cmd "$@")"
        return 1
    }

    #######################################
    # 执行命令，失败最多重试到第 N 次；最终仍失败则 fail
    #
    # 重试之间【不加 sleep】：库内的重试用于吸收偶发竞态（锁文件刚释放、git 索引瞬时忙），
    # 即时重试足够；固定 sleep 会给所有调用点强加延迟，并让测试变慢、变不稳定。
    # 需要指数退避时由调用方自行包一层 sleep，语义更明确，也不会拖慢只重试一次的调用点。
    #
    # 参数：
    #   $1 - 最大尝试次数（正整数；1 等于不重试）
    #   $2.. - 命令及其参数
    #
    # 返回：
    #   0 - 某次尝试成功
    #   1 - N 次尝试全失败（已 fail，含尝试次数、命令原文与最后一次退出码）
    #######################################
    with_retry() {
        if [[ $# -lt 2 ]]; then
            fail "with_retry" "用法：with_retry <尝试次数> <命令...>"
            return 1
        fi
        local _max="$1"
        shift
        # 不用 =~ 判数字：=~ 会把匹配结果写进 BASH_REMATCH，污染调用者 shell。
        if [[ "${_max}" == *[!0-9]* ]] || [[ -z "${_max}" ]] || ((10#${_max} < 1)); then
            fail "with_retry" "尝试次数必须为正整数，实际为 '${_max}'"
            return 1
        fi
        # 归一化成十进制：以 0 开头的串（如 "08"）在算术上下文里会被当成八进制而报错，
        # 这里先折算成 10# 再进循环，避免"次数写对了却跑不起来"。
        _max=$((10#${_max}))
        local _attempt=1
        local _rc=0
        while ((_attempt <= _max)); do
            _rc=0
            "$@" || _rc=$?
            if ((_rc == 0)); then
                return 0
            fi
            if ((_attempt < _max)); then
                log_warning "with_retry" "第 ${_attempt}/${_max} 次尝试失败（退出码 ${_rc}），重试：$(_render_cmd "$@")"
            fi
            # 不用 (( _attempt++ ))：当结果为 0 时它返回 1，set -e 的调用者会被提前打断。
            _attempt=$((_attempt + 1))
        done
        fail "with_retry" "命令重试 ${_max} 次仍失败（最后一次退出码 ${_rc}，$(exit_code_to_name "${_rc}")）：$(_render_cmd "$@")"
        return 1
    }

    # ── 刻意未实现：assert ────────────────────────────────────────────────────
    # 通用 assert <表达式> 需要 eval 才能把表达式当代码求值，会把调用方的引号/词分割问题
    # 搬进库，shellcheck 也必然报 SC2294；而"跑一条命令、失败就带消息报错"这一真正会被
    # 复用的场景已由 run_or_fail 覆盖。为一个薄封装引入 eval 不值得，故略过。
fi
