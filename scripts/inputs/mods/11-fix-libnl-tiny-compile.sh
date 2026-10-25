#!/bin/bash
# 文件: scripts/inputs/mods/fix-libnl-tiny-compile.sh
# 用途: 修复 libnl-tiny 在 GCC 14 下的编译警告（-Wparentheses）
#       通过在 Makefile 中添加 -Wno-parentheses 选项压制错误
# 依赖: 需要预先 source scripts/libs/load.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source scripts/inputs/mods/fix-libnl-tiny-compile.sh
#   fix_libnl_tiny_compile [makefile_path]
#
# 参数:
#   makefile_path : libnl-tiny 的 Makefile 路径，默认值为 package/libs/libnl-tiny/Makefile
#######################################

# 后备日志函数
if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 修复 libnl-tiny 的 GCC 14 编译错误
#
# 功能:
#   检查 libnl-tiny 的 Makefile，在 include $(TOPDIR)/rules.mk 之后
#   插入 TARGET_CFLAGS += -Wno-parentheses，以压制 GCC 14 的括号警告。
#   如果找不到 include 行，则在文件开头插入。
#
# 参数：
#   $1 - (可选) libnl-tiny Makefile 的路径，默认为 package/libs/libnl-tiny/Makefile
#
# 输出：
#   操作日志到 stderr (通过 log)
#
# 返回：
#   0 - 修改成功
#   0 - 文件不存在时仅输出警告，不视为错误
#
# 示例：
#   fix_libnl_tiny_compile
#   fix_libnl_tiny_compile 'package/libs/libnl-tiny/Makefile'
#######################################
fix_libnl_tiny_compile() {
    # 规格：makefile:m:value；同时兼容原位置参数（makefile 优先，其次 _POSITIONAL_0）。
    # 有 parse_args（load.sh 已加载）时按规格解析，命名参数与位置参数都支持；
    # 直接执行本文件（未加载 load.sh）时 parse_args 不存在，回退为纯位置参数，行为与改造前一致。
    if type -t parse_args >/dev/null 2>&1; then
        parse_args "makefile:m:value" -- "$@" || return 1
    fi
    local makefile="${PARSED_ARGS[makefile]:-${PARSED_ARGS[_POSITIONAL_0]:-package/libs/libnl-tiny/Makefile}}"

    if [[ ! -f "${makefile}" ]]; then
        log WARN "File ${makefile} does not exist, skipping libnl-tiny fix."
        return 0
    fi

    log INFO "Modifying ${makefile} to add -Wno-parentheses..."

    # 使用双引号并转义特殊字符，确保 sed 收到字面的 $(TOPDIR)
    # 说明：
    #   \\\$  →  shell 处理后变为 \$
    #   \\/   →  shell 处理后变为 \/
    #   最终 sed 看到的模式是: /include \$(TOPDIR)\/rules.mk/
    if grep -q "include \\\$(TOPDIR)/rules.mk" "${makefile}"; then
        sed -i "/include \\\$(TOPDIR)\\/rules.mk/a TARGET_CFLAGS += -Wno-parentheses" "${makefile}"
        log INFO "Added -Wno-parentheses after include \$(TOPDIR)/rules.mk"
    else
        # 找不到 include 行时，在文件开头插入
        sed -i '1iTARGET_CFLAGS += -Wno-parentheses' "${makefile}"
        log WARN "Could not find include line, inserted at beginning"
    fi

    log INFO "Successfully fixed ${makefile}"
}

# 若直接运行脚本，则执行默认修复
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fix_libnl_tiny_compile "$@"
fi
