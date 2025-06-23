#!/bin/bash
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
    make package/kernel/linux/compile -j$(($(nproc) + 1)) V=sc
