#!/bin/bash
#######################################
# 文件下载与 SHA256 哈希计算（增强版）
#
# 提供带重试、超时和完整性验证的下载功能。
#
# 依赖：若未 source logger.sh，将启用后备日志函数。
# 用法：source common/scripts/libs/download-utils.sh
#######################################

if ! type -t log &>/dev/null; then
    log() {
        local level="$1"
        shift
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
    }
fi

#######################################
# 下载文件并计算其 SHA256 哈希值（增强版）
#
# 自动选择可用下载工具，支持重试、超时、下载验证，
# 适用于构建过程中获取源码包并校验完整性。
#
# 参数：
#   $1 - 下载 URL（必需，建议 HTTPS）
#   $2 - 保存的文件名（可选，默认从 URL 提取）
#   $3 - 重试次数（可选，默认 3）
#
# Outputs:
#   SHA256 哈希值（64 位十六进制字符串）到 stdout
#   状态信息与错误到 stderr（通过 log 函数）
#
# Returns:
#   0 - 成功下载并计算哈希
#   1 - 多次重试后仍然失败，或工具缺失
#
# Examples:
#   hash=$(download_and_hash "https://example.com/archive.zip")
#   hash=$(download_and_hash "https://example.com/archive.tar.gz" "source.tar.gz" 5)
#######################################
download_and_hash() {
    local url="$1"
    local filename="${2:-}"
    local retries="${3:-3}"
    local attempt=0

    # 创建临时目录（退出时自动清理）
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    if [[ -z "${filename}" ]]; then
        filename=$(basename "${url}" | sed 's/\?.*//;s/#.*//')
        [[ -z "${filename}" ]] && filename="download.$$"
    fi
    local outfile="${tmpdir}/${filename}"

    # 检测可用下载工具
    local downloader=""
    if command -v curl &>/dev/null; then
        downloader="curl"
    elif command -v wget &>/dev/null; then
        downloader="wget"
    else
        log ERROR "Neither curl nor wget is available"
        return 1
    fi

    # 循环重试
    while ((attempt < retries)); do
        ((attempt++))
        log INFO "Downloading ${url} (attempt ${attempt}/${retries})..."

        # 使用 curl 下载
        if [[ "${downloader}" == "curl" ]]; then
            # --connect-timeout 10s, 总下载时间 60s, 跟随重定向, 显示进度但不污染 stdout
            if curl -sS -L --connect-timeout 10 --max-time 60 -o "${outfile}" --fail "${url}"; then
                log DEBUG "curl download succeeded"
                break
            else
                log WARN "curl download failed (exit code $?)"
            fi
        # 使用 wget 下载
        elif [[ "${downloader}" == "wget" ]]; then
            # --timeout=10 连接超时, 读取超时 60s, 重试 0 次（本层循环控制）
            if wget -nv --timeout=10 --read-timeout=60 -O "${outfile}" "${url}"; then
                log DEBUG "wget download succeeded"
                break
            else
                log WARN "wget download failed (exit code $?)"
            fi
        fi

        # 下载失败但还有重试机会，等待递增间隔
        if ((attempt < retries)); then
            sleep $((attempt * 2))
        else
            log ERROR "Failed to download ${url} after ${retries} attempts"
            return 1
        fi
    done

    # 验证下载文件大小 > 0
    if [[ ! -s "${outfile}" ]]; then
        log ERROR "Downloaded file is empty: ${outfile}"
        return 1
    fi

    # 计算 SHA256
    local hash=""
    if command -v sha256sum &>/dev/null; then
        hash=$(sha256sum "${outfile}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        hash=$(shasum -a 256 "${outfile}" | awk '{print $1}')
    else
        log ERROR "No sha256sum or shasum found"
        return 1
    fi

    # 哈希合法性校验（长度应为 64）
    if [[ ${#hash} -ne 64 ]]; then
        log ERROR "Computed hash length is ${#hash}, expected 64"
        return 1
    fi

    log INFO "Downloaded and computed hash: ${hash}"
    printf '%s' "${hash}"
}
