#!/bin/bash 

SEARCH_DIR="bin/targets"
FILE_TYPES=("*.bin" "*.itb" "*.img.gz" "*.fip")

total_count=0
total_size=0
declare -A type_count

if [ -d "immortalwrt" ]; then
    echo "进入 'immortalwrt' 目录..."
    cd immortalwrt
elif [ "$(basename "$(pwd)")" != "immortalwrt" ]; then
    echo "当前目录不是或不存在 'immortalwrt'，请先进入正确的目录。"
    exit 1
fi

echo "检测固件文件大小:"
echo "----------------------------------------"

# 遍历所有文件类型
for type in "${FILE_TYPES[@]}"; do
    count=0
    echo "【${type} 文件】"
    
    # 使用数组存储结果
    mapfile -d '' files < <(find "$SEARCH_DIR" -type f -iname "$type" -print0 2>/dev/null)
    
    for file in "${files[@]}"; do
        size=$(stat -c %s "$file" 2>/dev/null)
        human_size=$(numfmt --to=iec-i --suffix=B $size 2>/dev/null)
        printf "%-10s %s\n" "$human_size" "$file"
        
        ((total_count++))
        ((total_size += size))
        ((count++))
        type_count["$type"]=$((type_count["$type"] + 1))
    done
    
    if [ $count -eq 0 ]; then
        echo "    (未找到文件)"
    fi
    echo ""
done

echo "----------------------------------------"
echo "文件总数: $total_count"
echo "总大小: $(numfmt --to=iec-i --suffix=B $total_size) ($total_size 字节)"
echo "按类型分布:"
for type in "${FILE_TYPES[@]}"; do
    count=${type_count["$type"]:-0}
    echo "  $type: $count 个"
done