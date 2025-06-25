#!/bin/bash
if [ -d "immortalwrt" ]; then
    echo "进入 'immortalwrt' 目录..."
    cd immortalwrt
elif [ "$(basename "$(pwd)")" != "immortalwrt" ]; then
    git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git
    cd immortalwrt
fi
git restore .
git pull
bash ./diy-part1.sh
./scripts/feeds update -a -f
bash ./diy-part2.sh
./scripts/feeds install -a -f
make defconfig
find dl -size -1024c -exec ls -l {} \;
find dl -size -1024c -exec rm -f {} \;
make download
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    make -j$(($(nproc) + 1)) ||
    make -j1 V=sc ||
    echo "编译失败，请检查错误日志。"
