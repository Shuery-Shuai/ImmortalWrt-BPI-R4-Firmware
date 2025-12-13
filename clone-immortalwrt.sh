#!/bin/bash
if [ -d "immortalwrt" ]; then
    echo "进入 'immortalwrt' 目录..."
    rm -rf immortalwrt/files
    cp -r files immortalwrt/
    cp diy-part*.sh immortalwrt/
    cp generate-index.sh immortalwrt/
    cd immortalwrt || {
        echo "无法进入 'immortalwrt' 目录！"
        exit 1
    }
    git restore .
    git pull
elif [ "$(basename "$(pwd)")" != "immortalwrt" ]; then
    git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git || {
        echo "克隆 'immortalwrt' 仓库失败，请检查网络连接或仓库地址。"
        exit 1
    }
    rm -rf immortalwrt/files
    cp -r files immortalwrt/
    cp diy-part*.sh immortalwrt/
    cp generate-index.sh immortalwrt/
    cd immortalwrt || {
        echo "无法进入 'immortalwrt' 目录！"
        exit 1
    }
fi
