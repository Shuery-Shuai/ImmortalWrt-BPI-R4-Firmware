#!/bin/bash
#######################################
# OpenWrt/ImmortalWrt 规格驱动的命令行参数解析库
#
# 调用方声明"参数规格"，本库按表解析 argv，并归一化到全局关联数组 PARSED_ARGS：
#   长选项等号   --Distro=x        -> PARSED_ARGS[Distro]=x
#   长选项空格   --Distro x        -> PARSED_ARGS[Distro]=x
#   短选项带值   -d x              -> PARSED_ARGS[Distro]=x   （归一化到长名）
#   短选项等号   -d=x              -> PARSED_ARGS[Distro]=x   （归一化到长名）
#   布尔开关     --verbose / -V    -> PARSED_ARGS[verbose]=true（绝不消费下一个参数）
#   位置参数     val1 val2         -> PARSED_ARGS[_POSITIONAL_0]=val1 …
#   -- 分隔符    第一个 -- 分隔"规格表"与"待解析参数"；参数区里再出现的 --
#                终止选项解析，其后的一切（含以 - 开头的）都按位置参数处理
#
# 规格格式：长名:短名:类型   类型 ∈ value | flag ；短名可留空（如 "Distro::value"）。
#
# 依赖：scripts/libs/01-shell-logger.sh —— 本文件只调用 log_* / log，不定义任何
#       log / COLOR_* / LOG_LEVEL_*（全仓库唯一的实现在 01-shell-logger.sh）。
# 失败语义：本文件被 source，因此一律 return 1，绝不用 exit（exit 会杀掉调用者的整个 shell）。
#
# 用法：
#   source scripts/libs/01-shell-logger.sh
#   source scripts/libs/03-argument-parser.sh
#   parse_args "Distro:d:value" "Path:p:value" "verbose:V:flag" -- "$@"
#   validate_required_args Distro Path
#   validate_enum Distro Distro1 Distro2
#
# 注意：parse_args 内部用 declare -gA 建立 PARSED_ARGS，调用方无需（也不应）预先 declare -A。
#######################################

#######################################
# 拆分并校验一条参数规格（内部函数）
#
# 参数：
#   $1 - 规格字符串，形如 长名:短名:类型
#
# 输出：
#   成功时向 stdout 输出 "长名<TAB>短名<TAB>类型"；失败时不输出
#
# 返回：
#   0 - 规格合法
#   1 - 规格非法（已 log_error 说明原因）
#######################################
_parser_split_spec() {
    local _spec="$1"
    local -a _fields=()
    local _long _short _type
    # '=~' 会把匹配结果写进 BASH_REMATCH；声明成局部变量让它随函数返回一起消失，
    # 不污染调用者 shell（本库不向调用环境泄漏任何非约定变量）。
    local BASH_REMATCH

    # 先判有没有 ':'：没有时 read -a 只能拆出 1 段，错误信息会更含糊。
    if [[ "$_spec" != *:* ]]; then
        log_error "参数解析" "规格格式非法：'${_spec}'（应为 长名:短名:类型）"
        return 1
    fi

    # IFS=':' 的 read -a 保留空字段（"Distro::value" 会拆成 3 段），短名留空因此可用。
    IFS=':' read -r -a _fields <<<"$_spec"
    if ((${#_fields[@]} != 3)); then
        log_error "参数解析" "规格字段数不对：'${_spec}'（应为 长名:短名:类型，共 3 段）"
        return 1
    fi
    _long="${_fields[0]}"
    _short="${_fields[1]}"
    _type="${_fields[2]}"

    # 长名同时是 PARSED_ARGS 的键：限制字符集既能挡住写错的名字，也能挡住把 ']' 之类
    # 塞进下标的写法（位置参数键以 '_' 开头，故长名不许以 '_' 起头）。
    if [[ ! "$_long" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
        log_error "参数解析" "规格中长名非法：'${_long}'（须字母开头，仅含字母/数字/下划线/连字符）"
        return 1
    fi
    if [[ ! "$_short" =~ ^[A-Za-z0-9]?$ ]]; then
        log_error "参数解析" "规格中短名非法：'${_short}'（留空，或单个字母/数字，不含 '-'）"
        return 1
    fi
    case "$_type" in
    value | flag) ;;
    *)
        log_error "参数解析" "规格中类型非法：'${_type}'（仅支持 value | flag）"
        return 1
        ;;
    esac

    printf '%s\t%s\t%s\n' "$_long" "$_short" "$_type"
}

#######################################
# 记录一个位置参数（内部函数）
#
# 参数：
#   $1 - 位置参数的值
#   $2 - 序号（从 0 起）
#
# 返回：
#   0 - 总是成功
#######################################
_parser_store_positional() {
    PARSED_ARGS["_POSITIONAL_$2"]="$1"
}

#######################################
# 按规格解析命令行参数
#
# 参数：
#   ...规格字符串（也可写成 --spec "长名:短名:类型"，两者等价），随后一个 '--'，
#   再之后是待解析的 argv（通常就是 "$@"）
#
# 全局输出：
#   PARSED_ARGS[长名]                - 命名参数（flag 类型恒为 "true"）
#   PARSED_ARGS[_POSITIONAL_N]       - 第 N 个位置参数（N 从 0 起）
#   PARSED_ARGS[_POSITIONAL_COUNT]   - 位置参数个数
#
# 返回：
#   0 - 解析成功
#   1 - 规格错误 / 缺少 '--' 分隔符 / 未知选项 / value 类型缺值（均已 log_error）
#######################################
parse_args() {
    local -a _specs=()
    local -A _spec_type=() _short_name=()
    local _tok _spec _parts _long _short _type
    local _name _value _body _cur_short _rest _pos=0
    local _has_value=false _terminated=false _has_sep=false _decl
    local BASH_REMATCH

    # ---- 1. 切分：'--' 之前是规格表，之后是 argv ----
    while (($#)); do
        _tok="$1"
        if [[ "$_tok" == "--" ]]; then
            _has_sep=true
            shift
            break
        fi
        # 允许显式写成 --spec "…"，与裸规格字符串等价
        if [[ "$_tok" == "--spec" ]]; then
            if (($# < 2)); then
                log_error "参数解析" "--spec 之后缺少规格字符串"
                return 1
            fi
            shift
            _tok="$1"
        fi
        _specs+=("$_tok")
        shift
    done
    # 没有 '--' 时规格表与 argv 无法区分；静默猜一边会把参数解析错，所以直接报错。
    if [[ "$_has_sep" == false ]]; then
        log_error "参数解析" "缺少 '--' 分隔符：规格表与待解析参数之间必须用 -- 分隔"
        return 1
    fi

    # ---- 2. 编译规格表：长名 -> 类型，短名 -> 长名 ----
    for _spec in "${_specs[@]}"; do
        _parts=$( _parser_split_spec "$_spec" ) || return 1
        IFS=$'\t' read -r _long _short _type <<<"$_parts"
        if [[ -n "${_spec_type[$_long]+set}" ]]; then
            log_error "参数解析" "规格中长名重复：--${_long}"
            return 1
        fi
        if [[ -n "$_short" && -n "${_short_name[$_short]+set}" ]]; then
            log_error "参数解析" "规格中短名重复：-${_short}"
            return 1
        fi
        _spec_type["$_long"]="$_type"
        [[ -n "$_short" ]] && _short_name["$_short"]="$_long"
    done

    # ---- 3. 建立 PARSED_ARGS：调用方不必记得 declare -A ----
    # 若同名变量已存在但不是关联数组（例如曾被赋成索引数组），declare -gA 会因
    # "无法将索引数组转换为关联数组" 失败，故先 unset 再建；unset 只读变量会失败，
    # 此时明确报错返回，而不是留下一个半坏的状态。
    _decl=$(declare -p PARSED_ARGS 2>/dev/null) || _decl=""
    if [[ "$_decl" == "declare -A"* ]]; then
        PARSED_ARGS=()
    else
        if [[ -n "$_decl" ]]; then
            unset PARSED_ARGS || {
                log_error "参数解析" "PARSED_ARGS 是只读变量，无法重建为关联数组"
                return 1
            }
        fi
        declare -gA PARSED_ARGS=() || {
            log_error "参数解析" "无法创建全局关联数组 PARSED_ARGS"
            return 1
        }
    fi

    # ---- 4. 逐项解析 argv ----
    while (($#)); do
        _tok="$1"
        if [[ "$_terminated" == true ]]; then
            _parser_store_positional "$_tok" "$_pos"
            _pos=$((_pos + 1))
            shift
            continue
        fi

        case "$_tok" in
        --)
            _terminated=true
            shift
            ;;
        --?*)
            _name="${_tok#--}"
            _value=""
            _has_value=false
            if [[ "$_name" == *=* ]]; then
                _value="${_name#*=}"
                _name="${_name%%=*}"
                _has_value=true
            fi
            # 输入侧的名字先做字符校验再查表：既给出"未知选项"，也避免把 ']' 等
            # 注入到下标表达式里。
            if [[ ! "$_name" =~ ^[A-Za-z0-9_-]+$ ]] || [[ -z "${_spec_type[$_name]+set}" ]]; then
                log_error "参数解析" "未知选项：--${_name}"
                return 1
            fi
            _long="$_name"
            _type="${_spec_type[$_long]}"
            if [[ "$_type" == "flag" ]]; then
                if [[ "$_has_value" == true ]]; then
                    log_error "参数解析" "选项 --${_long} 是布尔开关，不接受值：'${_value}'"
                    return 1
                fi
                PARSED_ARGS["$_long"]="true"
                shift
            elif [[ "$_has_value" == true ]]; then
                PARSED_ARGS["$_long"]="$_value"
                shift
            else
                if (($# < 2)); then
                    log_error "参数解析" "选项 --${_long} 缺少值"
                    return 1
                fi
                PARSED_ARGS["$_long"]="$2"
                shift 2
            fi
            ;;
        -?*)
            _body="${_tok#-}"
            _cur_short="${_body:0:1}"
            _rest="${_body:1}"
            _value=""
            _has_value=false
            if [[ "$_rest" == "="* ]]; then
                _value="${_rest#=}"
                _has_value=true
            elif [[ -n "$_rest" ]]; then
                # 短选项不拼接（-Vd 之类歧义太大）：带值只认 -x=v 与 -x v 两种写法。
                log_error "参数解析" "不支持的短选项写法：'-${_body}'（带值请用 -x=v 或 -x v）"
                return 1
            fi
            if [[ -z "${_short_name[$_cur_short]+set}" ]]; then
                log_error "参数解析" "未知选项：-${_cur_short}"
                return 1
            fi
            _long="${_short_name[$_cur_short]}"
            _type="${_spec_type[$_long]}"
            if [[ "$_type" == "flag" ]]; then
                if [[ "$_has_value" == true ]]; then
                    log_error "参数解析" "选项 -${_cur_short} 是布尔开关，不接受值：'${_value}'"
                    return 1
                fi
                PARSED_ARGS["$_long"]="true"
                shift
            elif [[ "$_has_value" == true ]]; then
                PARSED_ARGS["$_long"]="$_value"
                shift
            else
                if (($# < 2)); then
                    log_error "参数解析" "选项 -${_cur_short} 缺少值"
                    return 1
                fi
                PARSED_ARGS["$_long"]="$2"
                shift 2
            fi
            ;;
        *)
            _parser_store_positional "$_tok" "$_pos"
            _pos=$((_pos + 1))
            shift
            ;;
        esac
    done

    PARSED_ARGS["_POSITIONAL_COUNT"]="$_pos"
    return 0
}

#######################################
# 检查必填参数是否齐全
#
# 参数：
#   $@ - 必填项的长名列表（对应 PARSED_ARGS 的键）
#
# 返回：
#   0 - 全部齐全
#   1 - 有缺失（已 log_error 列出缺失项）
#######################################
validate_required_args() {
    local -a _missing=()
    local _key
    local BASH_REMATCH

    if (($# == 0)); then
        log_warning "参数校验" "validate_required_args 未指定必填项，跳过检查"
        return 0
    fi
    if ! declare -p PARSED_ARGS &>/dev/null; then
        log_error "参数校验" "PARSED_ARGS 不存在，请先调用 parse_args"
        return 1
    fi

    for _key in "$@"; do
        if [[ ! "$_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
            log_error "参数校验" "非法的必填项名称：'${_key}'"
            return 1
        fi
        # 先 -v 判存在再取值：直接写 ${PARSED_ARGS[$_key]-} 之外的形态在 set -u 下会因未定义元素报错。
        if [[ ! -v "PARSED_ARGS[$_key]" ]] || [[ -z "${PARSED_ARGS[$_key]}" ]]; then
            _missing+=("--$_key")
        fi
    done

    if ((${#_missing[@]})); then
        log_error "参数校验" "缺少必填参数：${_missing[*]}"
        return 1
    fi
    return 0
}

#######################################
# 检查参数值是否落在允许列表内
#
# 参数：
#   $1 - 键名（PARSED_ARGS 的长名）
#   $2… - 允许的取值
#
# 返回：
#   0 - 值合法，或该键未被提供（可选参数，缺失交由 validate_required_args 判）
#   1 - 值不在允许列表内（已 log_error 列出允许值）
#######################################
validate_enum() {
    local _key="$1"
    local _value _cand
    local -a _allowed=()
    local BASH_REMATCH

    if (($# < 2)); then
        log_error "参数校验" "用法：validate_enum <键名> <允许值> [允许值…]"
        return 1
    fi
    shift
    _allowed=("$@")

    if ! declare -p PARSED_ARGS &>/dev/null; then
        log_error "参数校验" "PARSED_ARGS 不存在，请先调用 parse_args"
        return 1
    fi
    if [[ ! "$_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log_error "参数校验" "非法的键名：'${_key}'"
        return 1
    fi
    if [[ ! -v "PARSED_ARGS[$_key]" ]]; then
        log DEBUG "参数校验" "PARSED_ARGS[${_key}] 未提供，跳过枚举校验"
        return 0
    fi

    _value="${PARSED_ARGS[$_key]}"
    for _cand in "${_allowed[@]}"; do
        if [[ "$_value" == "$_cand" ]]; then
            return 0
        fi
    done

    log_error "参数校验" "参数 --${_key} 的值 '${_value}' 无效，允许值：${_allowed[*]}"
    return 1
}

#######################################
# 按规格表输出选项说明（可选辅助）
#
# 参数：
#   $@ - 规格字符串，与 parse_args 同一格式
#
# 输出：
#   stdout 上每行一个选项说明
#
# 返回：
#   0 - 成功
#   1 - 规格非法（已 log_error）
#######################################
parse_args_help() {
    local _spec _parts _long _short _type _line

    for _spec in "$@"; do
        _parts=$( _parser_split_spec "$_spec" ) || return 1
        IFS=$'\t' read -r _long _short _type <<<"$_parts"
        if [[ "$_type" == "flag" ]]; then
            _line="    --${_long}"
            [[ -n "$_short" ]] && _line="    -${_short}, --${_long}"
        else
            _line="    --${_long} <值>"
            [[ -n "$_short" ]] && _line="    -${_short} <值>, --${_long} <值>"
        fi
        printf '%s\n' "$_line"
    done
    return 0
}
