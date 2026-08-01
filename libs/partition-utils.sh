#!/bin/bash
#######################################
# 分区文件作用域修改与调试工具
#
# 提供：
#   - 在文件中指定作用域内执行 sed 替换
#   - 在作用域内对匹配行中的数字进行加减
#   - 显示作用域内容用于调试
#
# 依赖：若未 source logger.sh，将启用后备日志函数。
# 用法：source common/scripts/libs/partition-utils.sh
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 分区调整（通用作用域 sed 替换）
# 根据作用域起始/结束正则，对文件内匹配行进行替换。
# 参数：
#   $1 - 文件路径
#   $2 - 追加大小 (MB)
#   $3 - 作用域起始正则
#   $4 - 作用域结束正则
#   $5 - sed 替换表达式（可包含 & 引用追加大小）
# 注意：为了灵活性，将具体的 sed 脚本作为参数传入。
#######################################
modify_within_scope() {
    local file="$1"
    local append_size="$2"
    local start_re="$3"
    local end_re="$4"
    local sed_script="$5"

    if [[ ! -f "${file}" ]]; then
        log ERROR "File ${file} does not exist."
        return 1
    fi

    log INFO "Modifying ${file} with append_size=${append_size} within scope \"${start_re}\" to \"${end_re}\"..."
    if ! sed -i -E -e "/${start_re}/,/${end_re}/ { ${sed_script} }" "${file}"; then
        log ERROR "Failed to modify ${file}."
        return 1
    fi
    log INFO "Done modifying ${file} within scope \"${start_re}\" to \"${end_re}\"."
}

#######################################
# 在文件的作用域内将匹配模式中的数字增加指定值
#
# 使用 awk 读取文件，定位作用域，对匹配正则的行中的数字做加法。
# 注意：awk 中的正则需兼容，此处模式捕获数字并替换为 num+offset。
#
# 参数：
#   $1 - 文件路径
#   $2 - 作用域起始正则（awk 格式，如 /^define Build\/mt798x-gpt/）
#   $3 - 作用域结束正则（如 /^endef/）
#   $4 - 匹配行正则（用于识别哪些行需修改）
#   $5 - 数字捕获的正则（如 /[0-9]+/，可使用 awk match 定位）
#   $6 - 增加的数值（整数）
#
# 由于复杂性，此函数依赖 awk 并且假设行内数字出现在特定位置，
# 我们针对分区文件定制专用版本。
# 但为了保持通用，我们提供基于 awk 的模板。
# 实际调用时可根据需求调整。
#######################################
add_values_in_scope() {
    local file="$1"
    local start_re="$2"
    local end_re="$3"
    local line_match="$4"
    local num_pos="$5" # 例如 "M@", "M ", "m" 等上下文
    local offset="$6"

    awk -v start_re="${start_re}" -v end_re="${end_re}" \
        -v line_match="${line_match}" -v num_pos="${num_pos}" -v offset="${offset}" '
        $0 ~ start_re { in_scope=1 }
        in_scope && $0 ~ end_re { in_scope=0; print; next }
        in_scope && $0 ~ line_match {
            # 将行中匹配 num_pos 前数字的部分提取并加 offset
            # 简单实现：查找第一个数字串在 num_pos 前
            if (match($0, /[0-9]+/)) {
                num = substr($0, RSTART, RLENGTH)
                newnum = num + offset
                $0 = substr($0, 1, RSTART-1) newnum substr($0, RSTART+RLENGTH)
            }
        }
        { print }
    ' "${file}" >"${file}.tmp" && mv "${file}.tmp" "${file}"
}

#######################################
# 展示文件中指定作用域内匹配的行（通用调试工具）
#
# 从文件中提取由起始/结束正则划定的内容块，
# 并可选择性地用 grep 高亮特定模式。
#
# 参数：
#   $1 - 文件路径
#   $2 - 作用域起始正则
#   $3 - 作用域结束正则
#   $4 - grep 匹配模式（可选，为空则输出所有行）
#   $5 - 自定义标题前缀（可选，默认为 "Content"）
#
# 输出：
#   带分隔线的作用域内容到 stdout
#   分隔线和统计信息到 stderr（通过 log）
#
# 返回：
#   0 - 总是成功（即使内容为空）
#
# 示例：
#   show_scope_content "Makefile" "^define Package/mypkg" "^endef" "PKG_VERSION|PKG_RELEASE" "Package mypkg"
#   show_scope_content "config.txt" "# 网络配置" "# 结束" "" "网络配置段"
#######################################
show_scope_content() {
    local file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    local grep_patterns="${4:-}"
    local title="${5:-Content}"

    if [[ ! -f "${file}" ]]; then
        log WARN "File ${file} does not exist, cannot show scope content."
        return 0
    fi

    log INFO "━━━━━━━━━━━━━━━━━━━━ ${title} (${start_pattern} → ${end_pattern}) ━━━━━━━━━━━━━━━━━━━━"
    if [[ -n "${grep_patterns}" ]]; then
        sed -n -e "/${start_pattern}/,/${end_pattern}/p" "${file}" | grep -E --color=always "${grep_patterns}"
    else
        sed -n -e "/${start_pattern}/,/${end_pattern}/p" "${file}"
    fi
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
