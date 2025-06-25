#!/bin/bash
bash ./set-module-config.sh
bash ./set-firmware-config.sh
if [ -d "immortalwrt" ]; then
    cp ./immortalwrt/.config ./
fi
