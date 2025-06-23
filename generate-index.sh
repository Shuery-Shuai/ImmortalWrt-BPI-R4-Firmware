#!/bin/bash

# 将日期格式化为中文
format_date_cn() {
    local file="$1"
    # 获取英文日期
    local en_date=$(date -r "$file" '+%a %b %d %H:%M:%S %Y')

    # 星期映射表
    declare -A weekdays=(
        ["Mon"]="星期一"
        ["Tue"]="星期二"
        ["Wed"]="星期三"
        ["Thu"]="星期四"
        ["Fri"]="星期五"
        ["Sat"]="星期六"
        ["Sun"]="星期日"
    )

    # 月份映射表
    declare -A months=(
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
    read -r weekday month day time year <<<"$en_date"

    # 转换为中文格式
    local cn_weekday=${weekdays[$weekday]}
    local cn_month=${months[$month]}

    # 格式化日期
    echo "${year} 年 ${cn_month} ${day} 日 ${cn_weekday} ${time}"
}

# 递归为目录生成索引
generate_index() {
    local handle_path="$1"
    local parent_path="$2"
    local base_url="$3"
    echo "正在处理目录: $handle_path"
    echo "父路径: $parent_path"
    echo "基础 URL: $base_url"
    # 获取当前目录名称
    local dir_name=$(basename "$handle_path")
    echo "当前目录名称: $dir_name"

    # 创建面包屑导航路径
    local breadcrumb="<a href='/'><em>根目录</em></a>"
    # 拆分父路径
    IFS='/' read -ra parts <<<"$parent_path"
    echo "路径拆分: ${parts[*]}"
    current_path=""
    for part in "${parts[@]}"; do
        echo "处理父路径部分: $part"
        [ -z "$part" ] && continue
        [ "$part" = "." ] && continue
        [ "$part" = ".." ] && continue
        current_path="$current_path$part/"
        echo "当前路径: $current_path"
        breadcrumb="$breadcrumb / <a href='/$current_path'>$part</a>"
    done
    echo "面包屑导航: $breadcrumb"

    # 创建当前目录的索引文件
    {
        echo "<!DOCTYPE html>"
        echo "<html lang='zh-CN'>"
        echo "<head>"
        echo "<meta charset='utf-8'/>"
        echo "<meta name='viewport' content='width=device-width, initial-scale=1.0'>"
        echo "<link rel='stylesheet' href='https://downloads.immortalwrt.org/openwrt.css' />"
        if [ "$base_url" = "" ]; then
            echo "<title>自编译的 ImmortalWrt 固件</title>"
        else
            echo "<title>$base_url 的索引</title>"
        fi
        echo "</head>"
        echo "<body>"
        echo "<div class='container'>"

        # 面包屑导航
        if [ $dir_name = "." ]; then
            # 如果是根目录，直接显示根目录链接
            echo "<h1>索引：$breadcrumb /</h1>"
        else
            # 否则显示完整的面包屑导航
            echo "<h1>索引：$breadcrumb / <a href=\"$base_url/\">$dir_name</a> /</h1>"
        fi
        echo "<hr>"

        # 文件表格
        echo "<table>"
        echo "  <thead>"
        echo "    <tr><th class='n'>文件名</th><th class='m'>类型</th><th class='s'>大小</th><th class='d'>修改日期</th></tr>"
        echo "  </thead>"
        echo "  <tbody>"

        # 添加父目录链接（如果不是根目录）
        if [ -n "$parent_path" ] || [ -n "$base_url" ]; then
            echo "  <tr>"
            echo "    <td class='n'>↩️ <a href='../'>上级目录</a>/</td>"
            echo "    <td class='m'>目录</td>"
            echo "    <td class='s'>-</td>"
            echo "    <td class='d'>-</td>"
            echo "  </tr>"
        fi

        # 获取目录内容并排序（目录在前，文件在后）
        items=()
        while IFS= read -r item; do
            [ "$item" = "index.html" ] && continue
            items+=("$item")
        done < <(ls -1 "$handle_path" | sort)

        # 分离目录和文件
        directories=()
        files=()
        for item in "${items[@]}"; do
            if [ -d "$handle_path/$item" ]; then
                directories+=("$item")
            else
                files+=("$item")
            fi
        done

        # 排序：目录按名称排序，文件按名称排序
        sorted_directories=($(printf "%s\n" "${directories[@]}" | sort))
        sorted_files=($(printf "%s\n" "${files[@]}" | sort))
        sorted_items=("${sorted_directories[@]}" "${sorted_files[@]}")

        # 检查是否为空目录
        if [ ${#sorted_items[@]} -eq 0 ]; then
            echo "  <tr><td colspan='4' class='n'>╮(╯▽╰)╭ 此处空空如也~</td></tr>"
        fi

        # 遍历目录内容（目录在前）
        for item in "${sorted_items[@]}"; do
            item_path="$handle_path/$item"

            # 获取中文格式日期
            item_date=$(format_date_cn "$item_path")

            if [ -d "$item_path" ]; then
                item_type="目录"
                size="-"
                suffix="/"
                icon="📁"
            else
                item_type=$(file -b --mime-type "$item_path" | awk -F'/' '{print $2}')
                size=$(du -h "$item_path" | awk '{print $1}')
                suffix=""
                case "$item" in
                *.apk) icon="📦" ;;
                *.adb) icon="💾" ;;
                *.bin | *.img) icon="💿" ;;
                *.gz | *.bz2 | *.xz | *.zip) icon="🗄️" ;;
                *.manifest | *.txt | *.log) icon="📝" ;;
                *) icon="📄" ;;
                esac
            fi

            echo "  <tr>"
            echo "    <td class='n'>$icon <a href='$item$suffix'>$item$suffix</a></td>"
            echo "    <td class='m'>$item_type</td>"
            echo "    <td class='s'>$size</td>"
            echo "    <td class='d'>$item_date</td>"
            echo "  </tr>"
        done

        echo "  </tbody>"
        echo "</table>"

        # 添加页脚信息
        echo "<footer>"
        echo "  <p>由 Github CI 生成于 $(format_date_cn "$handle_path")</p>"
        echo "  <p>仓库地址: <a href='https://github.com/$GITHUB_REPOSITORY'>$GITHUB_REPOSITORY</a></p>"
        echo "</footer>"

        echo "</div>"
        echo "</body></html>"
    } >"$handle_path/index.html"

    # 递归处理子目录
    for child_dir in $(find "$handle_path" -maxdepth 1 -type d); do
        if [ "$child_dir" != "$handle_path" ]; then
            # 计算新的父路径
            local new_parent_path
            if [ -z "$parent_path" ]; then
                new_parent_path="$dir_name"
            else
                new_parent_path="$parent_path/$dir_name"
            fi

            generate_index "$child_dir" "$new_parent_path" "$base_url/$(basename "$child_dir")"
        fi
    done
}

# 从当前目录开始生成索引
generate_index "." "" ""
