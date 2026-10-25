#!/bin/bash
#######################################
# 文件下载与 SHA256 哈希计算（增强版）
#
# 提供带重试、超时和完整性验证的下载功能。
#
# 依赖：log 由 logger.sh 提供（index.sh 已保证其最先加载，本文件不再自带后备实现）。
# 用法：source scripts/inputs/utils/03-download-utils.sh
#######################################

#######################################
# 从 URL 推导保存用的文件名
#
# 参数：
#   $1 - 下载 URL
#
# 输出：
#   去掉查询串与片段后的末段文件名；末段为空时回退为 download.$$ 到 stdout
#######################################
_download_derive_filename() {
    local url="$1"
    local filename
    filename=$(basename "${url}" | sed 's/\?.*//;s/#.*//')
    [[ -z "${filename}" ]] && filename="download.$$"
    printf '%s' "${filename}"
}

#######################################
# 检测可用的下载工具
#
# 输出：
#   "curl" 或 "wget" 到 stdout
#
# 返回：
#   0 - 找到可用工具
#   1 - 两者都缺失（已通过 log 报错）
#######################################
_download_detect_tool() {
    if command -v curl &>/dev/null; then
        echo "curl"
    elif command -v wget &>/dev/null; then
        echo "wget"
    else
        log ERROR "Neither curl nor wget is available"
        return 1
    fi
}

#######################################
# 单次下载尝试（不做重试，不做空文件校验）
#
# 参数：
#   $1 - 下载 URL
#   $2 - 输出文件路径
#   $3 - 下载工具（curl 或 wget）
#
# 返回：
#   0 - 本次下载成功
#   1 - 本次下载失败
#######################################
_download_once() {
    local url="$1"
    local outfile="$2"
    local downloader="$3"

    if [[ "${downloader}" == "curl" ]]; then
        # --connect-timeout 10s, 总下载时间 60s, 跟随重定向, 显示进度但不污染 stdout
        if curl -sS -L --connect-timeout 10 --max-time 60 -o "${outfile}" --fail "${url}"; then
            log DEBUG "curl download succeeded"
            return 0
        else
            log WARN "curl download failed (exit code $?)"
            return 1
        fi
    elif [[ "${downloader}" == "wget" ]]; then
        # --timeout=10 连接超时, 读取超时 60s, 重试 0 次（本层循环控制）
        if wget -nv --timeout=10 --read-timeout=60 -O "${outfile}" "${url}"; then
            log DEBUG "wget download succeeded"
            return 0
        else
            log WARN "wget download failed (exit code $?)"
            return 1
        fi
    fi
    return 1
}

#######################################
# 带重试的下载循环（失败等待递增间隔）
#
# 参数：
#   $1 - 下载 URL
#   $2 - 输出文件路径
#   $3 - 下载工具（curl 或 wget）
#   $4 - 重试次数
#
# 返回：
#   0 - 下载成功，或重试次数为 0 时未做任何尝试（空文件校验交由调用方）
#   1 - 重试次数耗尽仍然失败
#######################################
_download_with_retries() {
    local url="$1"
    local outfile="$2"
    local downloader="$3"
    local retries="$4"
    local attempt=0

    while ((attempt < retries)); do
        ((attempt++))
        log INFO "Downloading ${url} (attempt ${attempt}/${retries})..."

        if _download_once "${url}" "${outfile}" "${downloader}"; then
            return 0
        fi

        # 下载失败但还有重试机会，等待递增间隔
        if ((attempt < retries)); then
            sleep $((attempt * 2))
        else
            log ERROR "Failed to download ${url} after ${retries} attempts"
            return 1
        fi
    done
    return 0
}

#######################################
# 计算文件的 SHA256 并校验长度
#
# 参数：
#   $1 - 文件路径
#
# 输出：
#   64 位十六进制哈希到 stdout
#
# 返回：
#   0 - 计算成功且长度合法
#   1 - 无可用哈希工具，或哈希长度不是 64
#######################################
_download_compute_sha256() {
    local file="$1"
    local hash=""

    if command -v sha256sum &>/dev/null; then
        hash=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        hash=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        log ERROR "No sha256sum or shasum found"
        return 1
    fi

    # 哈希合法性校验（长度应为 64）
    if [[ ${#hash} -ne 64 ]]; then
        log ERROR "Computed hash length is ${#hash}, expected 64"
        return 1
    fi

    printf '%s' "${hash}"
}

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
# 输出：
#   SHA256 哈希值（64 位十六进制字符串）到 stdout
#   状态信息与错误到 stderr（通过 log 函数）
#
# 返回：
#   0 - 成功下载并计算哈希
#   1 - 多次重试后仍然失败，或工具缺失
#
# 示例：
#   hash=$(download_and_hash "https://example.com/archive.zip")
#   hash=$(download_and_hash "https://example.com/archive.tar.gz" "source.tar.gz" 5)
#######################################
download_and_hash() {
    local url="$1"
    local filename="${2:-}"
    local retries="${3:-3}"

    # 创建临时目录（退出时自动清理）
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    if [[ -z "${filename}" ]]; then
        filename=$(_download_derive_filename "${url}")
    fi
    local outfile="${tmpdir}/${filename}"

    local downloader
    downloader=$(_download_detect_tool) || return 1

    _download_with_retries "${url}" "${outfile}" "${downloader}" "${retries}" || return 1

    # 验证下载文件大小 > 0
    if [[ ! -s "${outfile}" ]]; then
        log ERROR "Downloaded file is empty: ${outfile}"
        return 1
    fi

    local hash
    hash=$(_download_compute_sha256 "${outfile}") || return 1

    log INFO "Downloaded and computed hash: ${hash}"
    printf '%s' "${hash}"
}
