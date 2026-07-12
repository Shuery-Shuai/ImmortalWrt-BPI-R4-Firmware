#!/bin/bash
# 文件: common/scripts/mods/add-xdp-sockets-diag.sh
# 用途: 向内核网络支持模块中添加 XDP sockets 诊断接口
#       使 `ss` 工具能够监控 PF_XDP sockets，用于 eBPF XDP 程序调试
# 依赖: 需要预先 source common/scripts/libs/functions.sh 以使用 log 函数
#       若单独使用，脚本内置了日志后备
# 用法:
#   source common/scripts/mods/add-xdp-sockets-diag.sh
#   add_xdp_sockets_diag
#
# 说明:
#   本函数向 package/kernel/linux/modules/netsupport.mk 追加一段内核模块定义，
#   启用 CONFIG_XDP_SOCKETS 和 CONFIG_XDP_SOCKETS_DIAG，并安装 xsk_diag.ko。
#   适用于需要 eBPF XDP 功能的 OpenWrt 构建，ImmortalWrt 通常已内置，可按需调用。
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
# 添加 XDP sockets 诊断内核模块支持
#
# 功能:
#   检查 netsupport.mk 是否存在，然后追加 XDP sockets 诊断模块的定义。
#   该模块提供 `ss` 工具对 PF_XDP sockets 的监控能力。
#
# Globals:
#   None
#
# Arguments:
#   None
#
# Outputs:
#   操作日志到 stderr (通过 log)
#
# Returns:
#   0 - 添加成功
#   1 - 目标文件不存在
#
# Examples:
#   add_xdp_sockets_diag
#######################################
add_xdp_sockets_diag() {
  local target_file="package/kernel/linux/modules/netsupport.mk"

  if [[ ! -f "${target_file}" ]]; then
    log ERROR "netsupport.mk not found at ${target_file}."
    return 1
  fi

  # 这里使用双引号以便嵌入 $() 等字符，但需要保持 Makefile 语法正确。
  # 注意：变量引用如 $(NETWORK_SUPPORT_MENU) 必须原样写入，因此不能使用
  # 单引号，因为我们需要在 Shell 中展开整个字符串，同时保留 Makefile 变量。
  # 我们直接在字符串中写入 Makefile 所需的字面内容，Shell 的双引号会保留
  # 美元符号和反斜杠，除非被转义。此处不需要转义，因为 Makefile 的 $( ) 和
  # Shell 不冲突（Shell 不会在双引号中执行命令替换，除非是 ${} 形式）。
  local content="
define KernelPackage/xdp-sockets-diag
  SUBMENU:=\$(NETWORK_SUPPORT_MENU)
  TITLE:=PF_XDP sockets monitoring interface support for ss utility
  KCONFIG:= \\
    CONFIG_XDP_SOCKETS=y \\
    CONFIG_XDP_SOCKETS_DIAG
  FILES:=\$(LINUX_DIR)/net/xdp/xsk_diag.ko
  AUTOLOAD:=\$(call AutoLoad,31,xsk_diag)
endef

define KernelPackage/xdp-sockets-diag/description
  Support for PF_XDP sockets monitoring interface used by the ss tool
endef

\$(eval \$(call KernelPackage,xdp-sockets-diag))
"

  echo "${content}" >>"${target_file}"
  log INFO "Added xdp-sockets-diag to ${target_file}"
}

# 若直接运行脚本，则执行默认添加操作
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  add_xdp_sockets_diag
fi
