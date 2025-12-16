#!/bin/bash
# Prepare System Requirements
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
    sudo bash \
    ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
    g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
    libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
    libreadline-dev libssl-dev libtool lib yaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
    ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
    python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs \
    upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd
sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'

# Fix Complie Link
# Search latest GCC version
LATEST_GCC=""
for gcc in /usr/bin/gcc-[0-9]*; do
    if [ -e "$gcc" ]; then
        if [ -z "$LATEST_GCC" ] || {
            # 比较版本，选择最新的
            [ "$(printf '%s\n' "$gcc" "$LATEST_GCC" | sort -V | tail -n1)" = "$gcc" ]
        }; then
            LATEST_GCC="$gcc"
        fi
    fi
done
# Get version number
GCC_VERSION=$(basename "$LATEST_GCC" | cut -d'-' -f2)
echo "Detected GCC version: $GCC_VERSION"
# Remove old links
sudo rm -f /usr/bin/gcc /usr/bin/g++ /usr/bin/cc /usr/bin/c++ \
    /usr/bin/gcc-ar /usr/bin/gcc-nm /usr/bin/gcc-ranlib
# Create new links
sudo ln -s "$LATEST_GCC" /usr/bin/gcc
sudo ln -s "/usr/bin/g++-$GCC_VERSION" /usr/bin/g++
sudo ln -s "/usr/bin/gcc-ar-$GCC_VERSION" /usr/bin/gcc-ar
sudo ln -s "/usr/bin/gcc-nm-$GCC_VERSION" /usr/bin/gcc-nm
sudo ln -s "/usr/bin/gcc-ranlib-$GCC_VERSION" /usr/bin/gcc-ranlib
sudo ln -s /usr/bin/gcc /usr/bin/cc
sudo ln -s /usr/bin/g++ /usr/bin/c++
