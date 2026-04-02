#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# 仓库信息配置
# 判断是否为 CI 构建还是本地构建
if [[ -n "${GITHUB_REPOSITORY}" ]]; then
  # CI 构建
  BUILD_SOURCE="Github CI"
  REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
  REPO_DISPLAY="${GITHUB_REPOSITORY}"
else
  # 本地构建
  BUILD_SOURCE="Local Builder"
  # 使用环境变量或默认值
  REPO_DISPLAY="${CUSTOM_REPOSITORY_URL:-LetsShareAll/OpenWrtPackages}"
  # 根据地址格式确定完整 URL
  if [[ "${REPO_DISPLAY}" == http* ]]; then
    REPO_URL="${REPO_DISPLAY}"
  else
    REPO_URL="https://github.com/${REPO_DISPLAY}"
  fi
fi

# 全局数组存储所有文件条目（现在包含路径列）
declare -a all_items=()

# ---------- HTML 转义函数（使用 sed，安全处理多行） ----------
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# 将日期格式化为中文格式
# 参数:
#   $1: 文件路径
# 返回: 中文格式的日期字符串
format_date_cn() {
  local file="${1}"
  local en_date
  local weekday
  local month
  local day
  local time
  local year
  local cn_weekday
  local cn_month

  # 获取英文日期
  en_date="$(LC_TIME=C date -r "${file}" '+%a %b %d %H:%M:%S %Y')"

  # 星期映射表
  declare -Ar weekdays=(
    ["Mon"]="星期一"
    ["Tue"]="星期二"
    ["Wed"]="星期三"
    ["Thu"]="星期四"
    ["Fri"]="星期五"
    ["Sat"]="星期六"
    ["Sun"]="星期日"
  )

  # 月份映射表
  declare -Ar months=(
    ["Jan"]="01 月"
    ["Feb"]="02 月"
    ["Mar"]="03 月"
    ["Apr"]="04 月"
    ["May"]="05 月"
    ["Jun"]="06 月"
    ["Jul"]="07 月"
    ["Aug"]="08 月"
    ["Sep"]="09 月"
    ["Oct"]="10 月"
    ["Nov"]="11 月"
    ["Dec"]="12 月"
  )

  # 解析英文日期
  read -r weekday month day time year <<<"${en_date}"

  # 转换为中文格式
  cn_weekday="${weekdays[${weekday}]}"
  cn_month="${months[${month}]}"

  # 格式化日期
  echo "${year} 年 ${cn_month} ${day} 日 ${time}"
}

# 将当前日期格式化为中文格式
# 返回: 中文格式的日期字符串
format_current_date_cn() {
  local en_date
  local weekday
  local month
  local day
  local time
  local year
  local cn_weekday
  local cn_month

  # 获取当前英文日期
  en_date="$(LC_TIME=C date '+%a %b %d %H:%M:%S %Y')"

  # 星期映射表
  declare -Ar weekdays=(
    ["Mon"]="星期一"
    ["Tue"]="星期二"
    ["Wed"]="星期三"
    ["Thu"]="星期四"
    ["Fri"]="星期五"
    ["Sat"]="星期六"
    ["Sun"]="星期日"
  )

  # 月份映射表
  declare -Ar months=(
    ["Jan"]="01 月"
    ["Feb"]="02 月"
    ["Mar"]="03 月"
    ["Apr"]="04 月"
    ["May"]="05 月"
    ["Jun"]="06 月"
    ["Jul"]="07 月"
    ["Aug"]="08 月"
    ["Sep"]="09 月"
    ["Oct"]="10 月"
    ["Nov"]="11 月"
    ["Dec"]="12 月"
  )

  # 解析英文日期
  read -r weekday month day time year <<<"${en_date}"

  # 转换为中文格式
  cn_weekday="${weekdays[${weekday}]}"
  cn_month="${months[${month}]}"

  # 格式化日期
  echo "${year} 年 ${cn_month} ${day} 日 ${time}"
}

# 计算文件的SHA256值
# 参数:
#   $1: 文件路径
# 返回: SHA256哈希值或"-"（如果文件不存在）
calculate_sha256() {
  local file="${1}"
  if [[ -f "${file}" ]]; then
    # 计算SHA256并提取哈希值部分
    sha256sum "${file}" | awk '{print $1}'
  else
    echo "-"
  fi
}

# 递归为目录生成索引
# 参数:
#   $1: 要处理的目录路径
#   $2: 父路径
#   $3: 基础URL
generate_index() {
  local handle_path="${1}"
  local parent_path="${2}"
  local base_url="${3}"
  local dir_name
  local breadcrumb
  local -a parts
  local current_path=""
  local part
  local -a items
  local -a directories
  local -a files
  local -a sorted_directories
  local -a sorted_files
  local -a sorted_items
  local -a filtered_items
  local item
  local item_path
  local item_date
  local item_type
  local size
  local suffix
  local icon
  local sha_full
  local sha_short
  local sha_display
  local -a subdirs
  local child_dir
  local new_parent_path

  log "INFO" "📁 [PHASE: 处理目录] 开始处理目录: ${handle_path} (父路径: ${parent_path}, 基础URL: ${base_url})"

  # 获取当前目录名称
  dir_name="$(basename "${handle_path}")"
  log "DEBUG" "🔍 [STEP: 获取目录名] 当前目录名称: ${dir_name}"

  # 创建面包屑导航路径
  log "DEBUG" "🔧 [STEP: 构建导航] 开始构建面包屑导航"
  breadcrumb="<a href='/'><em>根目录</em></a>"

  # 拆分父路径
  IFS='/' read -r -a parts <<<"${parent_path}"
  log "DEBUG" "🔍 [STEP: 路径拆分] 路径拆分: ${parts[*]}"

  for part in "${parts[@]}"; do
    log "DEBUG" "🔄 [STEP: 处理路径] 处理父路径部分: ${part}"
    [[ -z "${part}" ]] && continue
    [[ "${part}" == "." ]] && continue
    [[ "${part}" == ".." ]] && continue

    current_path="${current_path}${part}/"
    log "DEBUG" "📍 [STEP: 当前路径] 当前路径: ${current_path}"
    breadcrumb="${breadcrumb} / <a href='/${current_path}'>${part}</a>"
  done

  log "DEBUG" "✅ [STEP: 导航完成] 面包屑导航构建完成"

  # 创建当前目录的索引文件
  log "INFO" "📝 [PHASE: 生成HTML] 开始生成HTML索引文件"
  {
    echo "<!DOCTYPE html>"
    echo "<html lang='zh-CN'>"
    echo "<head>"
    echo "  <meta charset='utf-8'/>"
    echo "  <meta name='viewport' content='width=device-width, initial-scale=1.0' />"
    echo "  <link rel='icon' href='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text x=%2250%%22 y=%2250%%22 style=%22dominant-baseline:central;text-anchor:middle;font-size:90px;%22>⚙️</text></svg>' />"
    echo "  <link rel='stylesheet' href='https://downloads.immortalwrt.org/openwrt.css' />"
    echo "  <link rel='stylesheet' href='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/atom-one-dark.min.css'>"
    echo "  <script src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'></script>"
    echo "  <script src='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js'></script>"
    echo "  <script src='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/languages/go.min.js'></script>"
    echo "  <script>hljs.highlightAll();</script>"
    if [[ "${base_url}" == "" ]]; then
      echo "  <title>自编译的路由器软件包仓库</title>"
    else
      echo "  <title>${base_url} 的索引</title>"
    fi
    echo "  <style>"
    echo "    .copy-btn {"
    echo "      cursor: pointer;"
    echo "      margin-left: 5px;"
    echo "      display: inline-block;"
    echo "      transition: all 0.2s ease;"
    echo "    }"
    echo "    .copy-btn:active {"
    echo "      transform: scale(0.9);"
    echo "      opacity: 0.7;"
    echo "    }"
    echo "    .copy-btn.success {"
    echo "      color: #4CAF50;"
    echo "      transform: scale(1.2);"
    echo "      animation: pop 0.3s ease-in-out;"
    echo "    }"
    echo "    @keyframes pop {"
    echo "      0% { transform: scale(1); }"
    echo "      50% { transform: scale(1.3); }"
    echo "      100% { transform: scale(1); }"
    echo "    }"
    echo "    .search-input {"
    echo "      width: 100%;"
    echo "      padding: 5px 15px;"
    echo "      margin-bottom: 5px;"
    echo "      box-sizing: border-box;"
    echo "      border: 1px solid #ccc;"
    echo "      box-shadow: 0 0 0.5em #999;"
    echo "      font-size: 16px;"
    echo "      outline: none;"
    echo "      transition: border-color 0.3s ease, box-shadow 0.3s ease;"
    echo "    }"
    echo "    .search-input:focus {"
    echo "      border-color: #007bff;"
    echo "      box-shadow: 0 0 0.5em rgba(0, 123, 255, 0.5);"
    echo "    }"
    echo "    /* README 区块样式 */"
    echo "    .readme-wrapper {"
    echo "      margin-top: 16px;"
    echo "      padding: 12px !important;"
    echo "      background: #f5f5f5;"
    echo "      border-top: 1px solid #e1e4e8;"
    echo "      box-shadow: 0 0 0.5em #999 !important;"
    echo "    }"
    echo "    .readme-wrapper h2 {"
    echo "      margin-top: 0;"
    echo "    }"
    echo "    .markdown-body {"
    echo "      box-sizing: border-box;"
    echo "      margin: 0 auto;"
    echo "      padding: 12px;"
    echo "      border-radius: 4px;"
    echo "      background-color: #fff;"
    echo "    }"
    echo "    .readme-content {"
    echo "      background: #fafafa;"
    echo "      padding: 10px;"
    echo "      overflow-x: auto;"
    echo "      white-space: pre-wrap;"
    echo "      font-family: monospace;"
    echo "    }"
    echo "    .hljs {"
    echo "      border-radius: 4px;"
    echo "    }"
    echo "    /* 代码块复制按钮样式 */"
    echo "    .code-block-wrapper {"
    echo "      position: relative;"
    echo "    }"
    echo "    .copy-code-btn {"
    echo "      position: absolute;"
    echo "      top: 8px;"
    echo "      right: 8px;"
    echo "      padding: 4px 8px;"
    echo "      background-color: #4CAF50;"
    echo "      color: white;"
    echo "      border: none;"
    echo "      border-radius: 4px;"
    echo "      cursor: pointer;"
    echo "      font-size: 12px;"
    echo "      z-index: 10;"
    echo "      transition: background-color 0.2s;"
    echo "    }"
    echo "    .copy-code-btn:hover {"
    echo "      background-color: #45a049;"
    echo "    }"
    echo "    .copy-code-btn.copied {"
    echo "      background-color: #2196F3;"
    echo "    }"
    echo "  </style>"
    echo "  <script>"
    echo "    function copyToClipboard(sha, btnElement) {"
    echo "      if (navigator.clipboard) {"
    echo "        navigator.clipboard.writeText(sha)"
    echo "          .then(() => {"
    echo "            btnElement.textContent = '✅';"
    echo "            btnElement.classList.add('success');"
    echo "            setTimeout(() => {"
    echo "              btnElement.textContent = '📋';"
    echo "              btnElement.classList.remove('success');"
    echo "            }, 1000);"
    echo "          })"
    echo "          .catch(() => showTooltip('复制失败', event));"
    echo "      } else {"
    echo "        prompt('请手动复制完整 SHA256：', sha);"
    echo "      }"
    echo "    }"
    echo "    function showTooltip(text, e) {"
    echo "      const tooltip = document.getElementById('tooltip');"
    echo "      tooltip.textContent = text;"
    echo "      tooltip.style.display = 'block';"
    echo "      tooltip.style.left = (e.clientX + 10) + 'px';"
    echo "      tooltip.style.top = (e.clientY + 10) + 'px';"
    echo "      setTimeout(() => tooltip.style.display = 'none', 1000);"
    echo "    }"
    echo "  </script>"
    echo "</head>"
    echo "<body>"
    echo "<div class='container'>"
    echo "<input type='text' id='globalSearch' placeholder='全局搜索...' class='search-input' onkeyup=\"if(event.key==='Enter' && this.value.trim()){window.location.href='/search.html?q='+encodeURIComponent(this.value.trim());}\">"

    # 面包屑导航
    if [[ "${dir_name}" == "." ]]; then
      # 如果是根目录，直接显示根目录链接
      echo "<h1>索引：${breadcrumb} /</h1>"
    else
      # 否则显示完整的面包屑导航
      echo "<h1>索引：${breadcrumb} / <a href=\"${base_url}/\">${dir_name}</a> /</h1>"
    fi
    echo "<hr>"

    # 文件表格
    echo "<table>"
    echo "  <thead>"
    echo "    <tr>"
    echo "      <th class='n'>文件名</th>"
    echo "      <th class='m'>类型</th>"
    echo "      <th class='s'>大小</th>"
    echo "      <th class='h'>SHA256</th>"
    echo "      <th class='d'>修改日期</th>"
    echo "    </tr>"
    echo "  </thead>"
    echo "  <tbody>"

    # 添加父目录链接（如果不是根目录）
    if [[ -n "${parent_path}" ]] || [[ -n "${base_url}" ]]; then
      echo "  <tr>"
      echo "    <td class='n'>↩️ <a href='../'>上级目录</a>/</td>"
      echo "    <td class='m'>目录</td>"
      echo "    <td class='s'>-</td>"
      echo "    <td class='sh'>-</td>"
      echo "    <td class='d'>-</td>"
      echo "  </tr>"
    fi

    # 获取目录内容并排序（目录在前，文件在后）
    log "INFO" "🔍 [PHASE: 读取内容] 开始读取目录内容: ${handle_path}"
    items=()
    while IFS= read -r item; do
      # 跳过 index.html 和 README.md
      [[ "${item}" == ".git" ]] && log "DEBUG" "⏭️ [STEP: 过滤] 跳过 .git" && continue
      [[ "${item}" == "index.html" ]] && log "DEBUG" "⏭️ [STEP: 过滤] 跳过 index.html" && continue
      [[ "${item}" == "search.html" ]] && log "DEBUG" "⏭️ [STEP: 过滤] 跳过 search.html（将在下方单独显示）" && continue
      [[ "${item}" == "README.md" ]] && log "DEBUG" "⏭️ [STEP: 过滤] 跳过 README.md（将在下方单独显示）" && continue
      [[ -z "${item}" ]] && log "DEBUG" "⏭️ [STEP: 过滤] 跳过空项" && continue
      items+=("${item}")
    done < <(find "${handle_path}" -maxdepth 1 \( -type f -o -type d \) -printf '%P\n' | sort)

    log "INFO" "SUCCESS" "[PHASE: 读取内容] 读取完成，共 ${#items[@]} 个项目"

    # 分离目录和文件
    log "DEBUG" "🔄 [STEP: 分离类型] 开始分离目录和文件"
    directories=()
    files=()

    for item in "${items[@]}"; do
      if [[ -d "${handle_path}/${item}" ]]; then
        directories+=("${item}")
      else
        files+=("${item}")
      fi
    done

    log "DEBUG" "📊 [STEP: 分离完成] 发现 ${#directories[@]} 个目录, ${#files[@]} 个文件"

    # 排序：目录按名称排序，文件按名称排序
    log "DEBUG" "🔄 [STEP: 排序] 开始排序目录和文件"
    mapfile -t sorted_directories < <(printf "%s\n" "${directories[@]}" | sort)
    mapfile -t sorted_files < <(printf "%s\n" "${files[@]}" | sort)
    sorted_items=("${sorted_directories[@]}" "${sorted_files[@]}")

    # 过滤掉空字符串
    filtered_items=()
    for item in "${sorted_items[@]}"; do
      [[ -n "${item}" ]] && filtered_items+=("${item}")
    done
    sorted_items=("${filtered_items[@]}")

    log "DEBUG" "✅ [STEP: 排序完成] 排序完成，共 ${#sorted_items[@]} 个排序项"

    # 检查是否为空目录
    if [[ "${#sorted_items[@]}" -eq 0 ]]; then
      log "WARN" "WARNING" "📭 [SITUATION: 空目录] 目录为空: ${handle_path}"
      echo "  <tr><td colspan='5' class='n'>╮(╯▽╰)╭ 此处空空如也~</td></tr>"
    fi

    # 遍历目录内容（目录在前）
    for item in "${sorted_items[@]}"; do
      [[ -z "${item}" ]] && continue
      item_path="${handle_path}/${item}"

      # 获取中文格式日期
      item_date="$(format_date_cn "${item_path}")"

      if [[ -d "${item_path}" ]]; then
        item_type="目录"
        size="-"
        suffix="/"
        icon="📁"
        sha_full="-"
        sha_display="-"
      else
        item_type="$(file -b --mime-type "${item_path}" | awk -F'/' '{print $2}')"
        size="$(du -h "${item_path}" | awk '{print $1}')"
        sha_full="$(calculate_sha256 "${item_path}")"
        if [[ "${sha_full}" != "-" ]]; then
          sha_short="${sha_full:0:7}..."
          sha_display="${sha_short}<span class='copy-btn' title='点击复制完整 SHA256' onclick='copyToClipboard(\"${sha_full}\", this)'>📋</span>"
        else
          sha_display="-"
        fi
        suffix=""
        case "${item}" in
        *.apk) icon="📦" ;;
        *.adb) icon="💾" ;;
        *.bin | *.img) icon="💿" ;;
        *.gz | *.bz2 | *.xz | *.zip) icon="🗄️" ;;
        *.manifest | *.txt | *.log) icon="📝" ;;
        *) icon="📄" ;;
        esac
      fi

      log "DEBUG" "📄 [STEP: 添加项] 添加表格项: ${item} (类型: ${item_type}, 大小: ${size})"

      # 计算完整路径用于全局搜索（相对根目录的路径）
      local full_path
      if [[ "${base_url}" == "" ]]; then
        full_path="${item}${suffix}"
      else
        full_path="${base_url}/${item}${suffix}"
      fi

      # 计算目录路径（不包含自身文件名/目录名）
      local dir_path
      local clean_path="${full_path}"
      # 去掉末尾的 /（如果有）
      clean_path="${clean_path%/}"
      # 获取目录部分
      dir_path="$(dirname "${clean_path}")"
      # 如果结果为 . 或空，则显示 /
      if [[ "${dir_path}" == "." ]] || [[ -z "${dir_path}" ]]; then
        dir_path="/"
      fi

      # 输出当前目录的表格行（5列）
      echo "  <tr>"
      echo "    <td class='n'>${icon} <a href='${item}${suffix}'>${item}${suffix}</a></td>"
      echo "    <td class='m'>${item_type}</td>"
      echo "    <td class='s'>${size}</td>"
      echo "    <td class='sh'>${sha_display}</td>"
      echo "    <td class='d'>${item_date}</td>"
      echo "  </tr>"

      # 添加到全局搜索列表（6列，路径列使用 dir_path，且用 data-full 保存完整路径供 JS 截断）
      all_items+=("  <tr>    <td class='n'>${icon} <a href='${full_path}'>${item}${suffix}</a></td>    <td class='m'>${item_type}</td>    <td class='s'>${size}</td>    <td class='sh'>${sha_display}</td>    <td class='d'>${item_date}</td>    <td class='p' data-full='${dir_path}'>${dir_path}</td>  </tr>")
    done

    echo "  </tbody>"
    echo "</table>"

    # ---------- 显示 README.md（如果存在） ----------
    if [[ -f "${handle_path}/README.md" ]]; then
      log "INFO" "📖 [README] 发现 README.md，将渲染为 Markdown 格式"
      echo "<div class='readme-wrapper'>"
      echo "<h2>📖 自述</h2>"
      echo "<div id='readme-content' class='markdown-body'></div>"
      echo "</div>"
      echo "<script>"
      echo "  (function() {"
      # 使用 python 进行 JSON 转义，避免破坏脚本
      local readme_json
      readme_json="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' < "${handle_path}/README.md")"
      echo "    const markdownText = ${readme_json};"
      echo "    const html = marked.parse(markdownText);"
      echo "    document.getElementById('readme-content').innerHTML = html;"
      echo "    if (typeof hljs !== 'undefined') {"
      echo "      document.querySelectorAll('#readme-content pre code').forEach((block) => {"
      echo "        hljs.highlightElement(block);"
      echo "      });"
      echo "    }"
      echo "    // 为每个代码块添加复制按钮"
      echo "    document.querySelectorAll('#readme-content pre').forEach((pre) => {"
      echo "      if (pre.querySelector('.copy-code-btn')) return;"
      echo "      const btn = document.createElement('button');"
      echo "      btn.className = 'copy-code-btn';"
      echo "      btn.textContent = '复制';"
      echo "      btn.onclick = function(e) {"
      echo "        e.stopPropagation();"
      echo "        const code = pre.querySelector('code');"
      echo "        const text = code ? code.innerText : '';"
      echo "        navigator.clipboard.writeText(text).then(() => {"
      echo "          btn.textContent = '已复制!';"
      echo "          btn.classList.add('copied');"
      echo "          setTimeout(() => {"
      echo "            btn.textContent = '复制';"
      echo "            btn.classList.remove('copied');"
      echo "          }, 2000);"
      echo "        }).catch(() => {"
      echo "          btn.textContent = '失败';"
      echo "          setTimeout(() => { btn.textContent = '复制'; }, 2000);"
      echo "        });"
      echo "      };"
      echo "      pre.style.position = 'relative';"
      echo "      pre.appendChild(btn);"
      echo "    });"
      echo "  })();"
      echo "</script>"
    fi

    # 添加页脚信息
    echo "<footer>"
    echo "  <p>由 ${BUILD_SOURCE} 生成于 $(format_date_cn "${handle_path}")</p>"
    echo "  <p>仓库地址: <a href='${REPO_URL}'>${REPO_DISPLAY}</a></p>"
    echo "</footer>"

    echo "</div>"
    echo "</body></html>"
  } >"${handle_path}/index.html"

  log "INFO" "SUCCESS" "[PHASE: 索引完成] 索引文件生成成功: ${handle_path}/index.html"

  # 递归处理子目录
  log "INFO" "🔄 [PHASE: 递归处理] 开始递归处理子目录: ${handle_path}"
  subdirs=()
  while IFS= read -r child_dir; do
    # 提取目录名并跳过隐藏目录
    local dir_basename
    dir_basename="$(basename "${child_dir}")"
    [[ "${dir_basename}" == .* ]] && continue
    subdirs+=("${child_dir}")
  done < <(find "${handle_path}" -mindepth 1 -maxdepth 1 -type d)

  log "INFO" "📂 [STEP: 子目录发现] 发现 ${#subdirs[@]} 个子目录"

  for child_dir in "${subdirs[@]}"; do
    log "DEBUG" "🔄 [STEP: 处理子目录] 处理子目录: ${child_dir}"

    # 计算新的父路径
    if [[ -z "${parent_path}" ]]; then
      new_parent_path="${dir_name}"
    else
      new_parent_path="${parent_path}/${dir_name}"
    fi

    generate_index "${child_dir}" "${new_parent_path}" "${base_url}/$(basename "${child_dir}")"
  done

  log "INFO" "SUCCESS" "[PHASE: 完成] 完成处理目录: ${handle_path}"
}

# 主函数
main() {
  log "INFO" "🚀 [PHASE: 初始化] 开始生成索引脚本，从 bin 目录开始"
  cd bin || cd docs || {
    log "ERROR" "❌ [PHASE: 初始化] 无法进入 'bin' 或 'docs' 目录！"
    exit 1
  }
  log "INFO" "SUCCESS" "[PHASE: 初始化] 成功进入 bin 目录"
  generate_index "." "" ""
  log "INFO" "📝 [PHASE: 生成全局搜索] 开始生成全局搜索页面"
  {
    echo "<!DOCTYPE html>"
    echo "<html lang='zh-CN'>"
    echo "<head>"
    echo "  <meta charset='utf-8'/>"
    echo "  <meta name='viewport' content='width=device-width, initial-scale=1.0' />"
    echo "  <link rel='icon' href='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text x=%2250%%22 y=%2250%%22 style=%22dominant-baseline:central;text-anchor:middle;font-size:90px;%22>⚙️</text></svg>' />"
    echo "  <link rel='stylesheet' href='https://downloads.immortalwrt.org/openwrt.css' />"
    echo "  <link rel='stylesheet' href='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/atom-dark-mode.min.css'>"
    echo "  <script src='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/languages/go.min.js'></script>"
    echo "  <script src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'></script>"
    echo "  <script>hljs.highlightAll();</script>"
    echo "  <title>全局搜索 - 自编译的 ImmortalWrt 固件</title>"
    echo "  <style>"
    echo "    .copy-btn {"
    echo "      cursor: pointer;"
    echo "      margin-left: 5px;"
    echo "      display: inline-block;"
    echo "      transition: all 0.2s ease;"
    echo "    }"
    echo "    .copy-btn:active {"
    echo "      transform: scale(0.9);"
    echo "      opacity: 0.7;"
    echo "    }"
    echo "    .copy-btn.success {"
    echo "      color: #4CAF50;"
    echo "      transform: scale(1.2);"
    echo "      animation: pop 0.3s ease-in-out;"
    echo "    }"
    echo "    @keyframes pop {"
    echo "      0% { transform: scale(1); }"
    echo "      50% { transform: scale(1.3); }"
    echo "      100% { transform: scale(1); }"
    echo "    }"
    echo "    .search-input {"
    echo "      width: 100%;"
    echo "      padding: 5px 15px;"
    echo "      margin-bottom: 5px;"
    echo "      box-sizing: border-box;"
    echo "      border: 1px solid #ccc;"
    echo "      font-size: 16px;"
    echo "      outline: none;"
    echo "      transition: border-color 0.3s ease, box-shadow 0.3s ease;"
    echo "    }"
    echo "    .search-input:focus {"
    echo "      border-color: #007bff;"
    echo "      box-shadow: 0 0 5px rgba(0, 123, 255, 0.5);"
    echo "    }"
    echo "    /* 路径列样式：允许换行，避免表格过宽，并支持悬浮查看完整路径 */"
    echo "    .p {"
    echo "      word-break: break-all;"
    # echo "      max-width: 300px;"
    echo "      cursor: help;"
    echo "    }"
    echo "  </style>"
    echo "  <script>"
    echo "    function copyToClipboard(sha, btnElement) {"
    echo "      if (navigator.clipboard) {"
    echo "        navigator.clipboard.writeText(sha)"
    echo "          .then(() => {"
    echo "            btnElement.textContent = '✅';"
    echo "            btnElement.classList.add('success');"
    echo "            setTimeout(() => {"
    echo "              btnElement.textContent = '📋';"
    echo "              btnElement.classList.remove('success');"
    echo "            }, 1000);"
    echo "          })"
    echo "          .catch(() => showTooltip('复制失败', event));"
    echo "      } else {"
    echo "        prompt('请手动复制完整 SHA256：', sha);"
    echo "      }"
    echo "    }"
    echo "    function showTooltip(text, e) {"
    echo "      const tooltip = document.getElementById('tooltip');"
    echo "      tooltip.textContent = text;"
    echo "      tooltip.style.display = 'block';"
    echo "      tooltip.style.left = (e.clientX + 10) + 'px';"
    echo "      tooltip.style.top = (e.clientY + 10) + 'px';"
    echo "      setTimeout(() => tooltip.style.display = 'none', 1000);"
    echo "    }"
    echo "    function searchTable() {"
    echo "      const input = document.getElementById('searchInput');"
    echo "      const filter = input.value.toLowerCase();"
    echo "      const table = document.querySelector('table');"
    echo "      const rows = table.querySelectorAll('tbody tr');"
    echo "      rows.forEach(row => {"
    echo "        const cells = row.querySelectorAll('td');"
    echo "        let match = false;"
    echo "        cells.forEach(cell => {"
    echo "          if (cell.textContent.toLowerCase().includes(filter)) {"
    echo "            match = true;"
    echo "          }"
    echo "        });"
    echo "        row.style.display = match ? '' : 'none';"
    echo "      });"
    echo "      applyPathTruncation();  // 新增：动态调整路径截断"
    echo "    }"
    echo "    // 智能截断路径：保留开头和结尾，中间用 … 替代"
    echo "    function truncatePath(path, maxLen, keyword) {"
    echo "      if (path.length <= maxLen) return path;"
    echo "      // 有搜索关键词时，优先保证关键词完整显示"
    echo "      if (keyword && keyword.length > 0) {"
    echo "        const idx = path.toLowerCase().indexOf(keyword.toLowerCase());"
    echo "        if (idx !== -1) {"
    echo "          const kwLen = keyword.length;"
    echo "          const context = 10; // 关键词前后保留的字符数"
    echo "          const need = kwLen + context * 2;"
    echo "          if (need <= maxLen) {"
    echo "            let start = Math.max(0, idx - context);"
    echo "            let end = Math.min(path.length, idx + kwLen + context);"
    echo "            let result = path.substring(start, end);"
    echo "            if (start > 0) result = '…' + result;"
    echo "            if (end < path.length) result = result + '…';"
    echo "            return result;"
    echo "          } else {"
    echo "            // 空间不够时，只保留关键词前后各 2 个字符"
    echo "            let start = Math.max(0, idx - 2);"
    echo "            let end = Math.min(path.length, idx + kwLen + 2);"
    echo "            let result = path.substring(start, end);"
    echo "            if (start > 0) result = '…' + result;"
    echo "            if (end < path.length) result = result + '…';"
    echo "            return result;"
    echo "          }"
    echo "        }"
    echo "      }"
    echo "      // 无关键词时的默认截断：保留第一段 + 最后两段"
    echo "      const parts = path.split('/').filter(p => p.length > 0);"
    echo "      if (parts.length <= 3) return path; // 短路径不截断"
    echo "      // 保留第一段和最后两段"
    echo "      const first = parts[0];"
    echo "      const lastTwo = parts.slice(-2).join('/');"
    echo "      let result = '/' + first + '/…/' + lastTwo;"
    echo "      if (result.length <= maxLen) return result;"
    echo "      // 如果仍然过长，逐步缩短最后两段"
    echo "      let shortLastTwo = lastTwo;"
    echo "      while (result.length > maxLen && shortLastTwo.length > 3) {"
    echo "        shortLastTwo = shortLastTwo.substring(0, shortLastTwo.length - 1);"
    echo "        result = '/' + first + '/…/' + shortLastTwo;"
    echo "      }"
    echo "      // 极端情况：只保留第一段和最后一段"
    echo "      if (result.length > maxLen) {"
    echo "        const last = parts[parts.length - 1];"
    echo "        result = '/' + first + '/…/' + last;"
    echo "      }"
    echo "      return result;"
    echo "    }"
    echo "    function applyPathTruncation() {"
    echo "      const searchInput = document.getElementById('searchInput');"
    echo "      const keyword = searchInput ? searchInput.value : '';"
    echo "      const cells = document.querySelectorAll('td.p');"
    echo "      cells.forEach(cell => {"
    echo "        const fullPath = cell.getAttribute('data-full') || cell.textContent;"
    echo "        cell.setAttribute('title', fullPath);"
    echo "        const maxWidth = cell.clientWidth;"
    echo "        // 更保守的字符宽度估算：英文字符 7px，中文字符 12px，平均按 9px"
    echo "        const avgCharWidth = 9;"
    echo "        let maxChars = Math.floor(maxWidth / avgCharWidth);"
    echo "        maxChars = Math.max(25, maxChars); // 至少显示 25 个字符，避免过度截断"
    echo "        const truncated = truncatePath(fullPath, maxChars, keyword);"
    echo "        cell.textContent = truncated;"
    echo "      });"
    echo "    }"
    echo "    window.onload = function() {"
    echo "      const urlParams = new URLSearchParams(window.location.search);"
    echo "      const query = urlParams.get('q');"
    echo "      if (query) {"
    echo "        document.getElementById('searchInput').value = query;"
    echo "        searchTable();"
    echo "      }"
    echo "      applyPathTruncation();"
    echo "      window.addEventListener('resize', function() {"
    echo "        applyPathTruncation();"
    echo "      });"
    echo "    }"
    echo "  </script>"
    echo "</head>"
    echo "<body>"
    echo "<div class='container'>"
    echo "<div id='tooltip' style='position: absolute; display: none; background: #333; color: #fff; padding: 5px; border-radius: 3px;'></div>"
    echo "<h1>全局搜索</h1>"
    echo "<input type='text' id='searchInput' placeholder='搜索文件名或路径...' class='search-input' onkeyup='searchTable()'>"
    echo "<hr>"
    echo "<table>"
    echo "  <thead>"
    echo "    <tr>"
    echo "      <th class='n'>文件名</th>"
    echo "      <th class='m'>类型</th>"
    echo "      <th class='s'>大小</th>"
    echo "      <th class='h'>SHA256</th>"
    echo "      <th class='d'>修改日期</th>"
    echo "      <th class='p'>路径</th>"
    echo "    </tr>"
    echo "  </thead>"
    echo "  <tbody>"
    for item in "${all_items[@]}"; do
      echo "${item}"
    done
    echo "  </tbody>"
    echo "</table>"
    echo "<footer>"
    echo "  <p>由 ${BUILD_SOURCE} 生成于 $(format_current_date_cn)</p>"
    echo "  <p>仓库地址: <a href='${REPO_URL}'>${REPO_DISPLAY}</a></p>"
    echo "</footer>"
    echo "</div>"
    echo "</body></html>"
  } >"search.html"
  log "INFO" "SUCCESS" "[PHASE: 全局搜索完成] 全局搜索页面生成成功: search.html"
  log "INFO" "🎉 [PHASE: 完成] 索引生成完成"
}

# 脚本入口点
main "${@}"