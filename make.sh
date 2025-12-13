#!/bin/bash
bash ./set-config.sh
find dl -size -1024c -exec ls -l {} \;
find dl -size -1024c -exec rm -f {} \;
make download
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    make -j$(($(nproc) + 1)) ||
    make -j1 V=sc ||
    echo "编译失败，请检查错误日志。"
