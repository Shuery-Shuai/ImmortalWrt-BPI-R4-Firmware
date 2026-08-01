#!/bin/bash
#######################################
# 版本号规范化工具
#
# 将包含预发布标识的版本号转换为 OpenWrt 兼容格式。
#
# 用法：source common/scripts/libs/version-utils.sh
#######################################

#######################################
# 将版本号转换为 OpenWrt 兼容格式
#
# 对于包含预发布标识（rc、beta、alpha 等）的版本号，
# 在标识前插入下划线，例如：
#   1.1.0rc1  ->  1.1.0_rc1
#   2.0.0beta2 -> 2.0.0_beta2
#
# 参数：
#   $1 - 原始版本号
#
# Outputs:
#   转换后的版本号到 stdout
#
# Examples:
#   normalize_pkg_version "1.1.0rc1"    # 输出: 1.1.0_rc1
#######################################
normalize_pkg_version() {
    local version="$1"
    if [[ "${version}" =~ ^([0-9.]+)(rc|beta|alpha|pre|preview)(.*)$ ]]; then
        printf '%s_%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${version}"
    fi
}
