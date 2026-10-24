#!/bin/bash
#
# Script to initialize the build environment.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prepare system requirements.
DEPENDS_FILE="${SCRIPT_DIR}/depends.txt"
[ -f "$DEPENDS_FILE" ] || { echo "Error: $DEPENDS_FILE not found"; exit 1; }
PACKAGES=$(grep -vE '^\s*(#|$)' "$DEPENDS_FILE" | tr '\n' ' ')
echo ">>> Installing $(echo "$PACKAGES" | wc -w) packages from depends.txt"
sudo apt update && sudo apt upgrade -y
sudo apt install -y "$PACKAGES"
sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'

# Fix compile links.
# Search for latest GCC version.
LATEST_GCC=""
for gcc in /usr/bin/gcc-[0-9]*; do
  if [[ -e "$gcc" ]]; then
    if [[ -z "$LATEST_GCC" ]] || {
      # Compare versions, select the latest.
      [[ "$(printf '%s\n' "$gcc" "$LATEST_GCC" | sort -V | tail -n1)" == "$gcc" ]]
    }; then
      LATEST_GCC="$gcc"
    fi
  fi
done
# Get version number.
GCC_VERSION=$(basename "$LATEST_GCC" | cut -d'-' -f2)
echo "Detected GCC version: $GCC_VERSION"
# Remove old links.
sudo rm -f /usr/bin/gcc /usr/bin/g++ /usr/bin/cc /usr/bin/c++ \
  /usr/bin/gcc-ar /usr/bin/gcc-nm /usr/bin/gcc-ranlib
# Create new links.
sudo ln -s "$LATEST_GCC" /usr/bin/gcc
sudo ln -s "/usr/bin/g++-$GCC_VERSION" /usr/bin/g++
sudo ln -s "/usr/bin/gcc-ar-$GCC_VERSION" /usr/bin/gcc-ar
sudo ln -s "/usr/bin/gcc-nm-$GCC_VERSION" /usr/bin/gcc-nm
sudo ln -s "/usr/bin/gcc-ranlib-$GCC_VERSION" /usr/bin/gcc-ranlib
sudo ln -s /usr/bin/gcc /usr/bin/cc
sudo ln -s /usr/bin/g++ /usr/bin/c++
