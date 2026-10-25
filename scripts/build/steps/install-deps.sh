#!/bin/bash
#
# 主机依赖与额外工具链（scripts/build/steps/install-deps.sh）：install_dependencies 与
# install_extra_toolchains（含 _upx_is_current / _install_upx / _install_padjffs2 / _install_po2lmo）。
#
# 只定义函数：install_extra_toolchains 依赖 install_dependencies 装好的 curl/gcc/git/make/strip。
# EXTRAS_* 常量必须在本文件第一次被 source 时就生效，因此保持 readonly；
# scripts/build/build.sh 内联的加载顺序保证只 source 本文件一次，其余模块与 libs 均不定义同名常量。

# 安装主机编译依赖（对齐 workflow: Initialization environment）。
# 只在显式的 deps 阶段调用：本地依赖通常已装好，自动跑 apt 既重复又慢，还需要 sudo。
install_dependencies() {
  local depends_file="${DEPENDS_FILE:-scripts/build/dependencies.txt}"
  if [[ ! -f "${depends_file}" ]]; then
    require_or_warn "Dependency list not found: ${depends_file}" || return 1
    return 0
  fi

  # 包名必须逐个作为独立参数传给 apt-get：整串加引号会变成一个不存在的包名。
  local -a packages=()
  local -a words=()
  local line
  while IFS= read -r line; do
    read -r -a words <<<"${line}"
    packages+=("${words[@]}")
  done < <(grep -vE '^[[:space:]]*(#|$)' "${depends_file}")

  if [[ ${#packages[@]} -eq 0 ]]; then
    log_warning "No packages listed in ${depends_file}; nothing to install."
    return 0
  fi

  log_info "Installing ${#packages[@]} build dependencies from ${depends_file}..."
  if ! sudo apt-get update; then
    require_or_warn "apt-get update failed." || return 1
  fi
  if ! sudo apt-get install -y "${packages[@]}"; then
    require_or_warn "Failed to install build dependencies." || return 1
  fi
  log_success "Build dependencies installed."
}

# ---------- 额外工具链：upx / padjffs2 / po2lmo ----------
# 这三样在 noble 的软件源里没有可用版本（upx-ucl 落后于上游要求），上游的做法是
# 从官方 release 与源码现装。这里沿用同样的来源，但把 padjffs2 与 po2lmo 的
# commit 钉死，避免上游 main 分支漂移导致同一个脚本编出不同的工具。
# readonly 常量只能赋值一次：重复 source 本文件时用哨兵跳过，保证幂等且不报"只读变量"。
if [[ -z "${_ORCH_DEPS_SH_LOADED:-}" ]]; then
  readonly _ORCH_DEPS_SH_LOADED=1
  readonly EXTRAS_UPX_VERSION="5.2.1"
  readonly EXTRAS_PADJFFS2_COMMIT="d06b68fe83ebb969baa64335779045d80bc41f89"
  readonly EXTRAS_PO2LMO_COMMIT="aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f"
fi

# 版本号必须真的对得上，否则按未安装处理并重装。
_upx_is_current() {
  command -v upx >/dev/null 2>&1 || return 1
  upx --version 2>/dev/null | grep -qF "${EXTRAS_UPX_VERSION}"
}

_install_upx() {
  local workdir="$1"
  local version="${EXTRAS_UPX_VERSION}"
  local archive="upx-${version}-amd64_linux.tar.xz"
  local url="https://github.com/upx/upx/releases/download/v${version}/${archive}"
  local src="${workdir}/upx-${version}-amd64_linux/upx"

  curl -fsSL -o "${workdir}/${archive}" "${url}" || {
    log_error "Failed to download ${url}"
    return 1
  }
  tar -xJf "${workdir}/${archive}" -C "${workdir}" || {
    log_error "Failed to extract ${archive}"
    return 1
  }
  sudo install -m 0755 "${src}" /usr/bin/upx-ucl || {
    log_error "Failed to install /usr/bin/upx-ucl"
    return 1
  }
  sudo ln -sf /usr/bin/upx-ucl /usr/bin/upx || {
    log_error "Failed to link /usr/bin/upx"
    return 1
  }

  log_success "upx ${version} installed to /usr/bin/upx."
}

_install_padjffs2() {
  local workdir="$1"
  local commit="${EXTRAS_PADJFFS2_COMMIT}"
  local url="https://raw.githubusercontent.com/openwrt/openwrt/${commit}/tools/padjffs2/src/padjffs2.c"

  curl -fsSL -o "${workdir}/padjffs2.c" "${url}" || {
    log_error "Failed to download padjffs2.c at ${commit}"
    return 1
  }
  gcc -Wall -Werror -o "${workdir}/padjffs2" "${workdir}/padjffs2.c" || {
    log_error "Failed to compile padjffs2.c at ${commit}"
    return 1
  }
  strip "${workdir}/padjffs2"
  sudo install -m 0755 "${workdir}/padjffs2" /usr/bin/padjffs2 || {
    log_error "Failed to install /usr/bin/padjffs2"
    return 1
  }

  log_success "padjffs2 installed to /usr/bin/padjffs2 (openwrt@${commit:0:12})."
}

_install_po2lmo() {
  local workdir="$1"
  local commit="${EXTRAS_PO2LMO_COMMIT}"
  local repo="${workdir}/luci"
  local src="${repo}/modules/luci-base/src"

  git clone --filter=blob:none --no-checkout https://github.com/openwrt/luci.git "${repo}" || {
    log_error "Failed to clone https://github.com/openwrt/luci.git"
    return 1
  }
  # 只让 po2lmo 所在目录落盘，luci 的其余模块不下载。
  git -C "${repo}" sparse-checkout set modules/luci-base/src || {
    log_error "Failed to enable sparse-checkout for modules/luci-base/src"
    return 1
  }
  git -C "${repo}" fetch --depth 1 origin "${commit}" || {
    log_error "Failed to fetch openwrt/luci at ${commit}"
    return 1
  }
  git -C "${repo}" checkout --detach "${commit}" || {
    log_error "Failed to check out openwrt/luci at ${commit}"
    return 1
  }
  make -C "${src}" po2lmo || {
    log_error "Failed to build po2lmo at ${commit}"
    return 1
  }
  strip "${src}/po2lmo"
  sudo install -m 0755 "${src}/po2lmo" /usr/bin/po2lmo || {
    log_error "Failed to install /usr/bin/po2lmo"
    return 1
  }

  log_success "po2lmo installed to /usr/bin/po2lmo (luci@${commit:0:12})."
}

# 安装 scripts/build/dependencies.txt 覆盖不到的三个主机工具（deps 阶段在 install_dependencies 之后调用）。
# 幂等：工具已存在且版本正确就跳过；全程在临时目录里工作，结束即清理。
# 单个工具失败不中断其余步骤，但会汇总成非零返回码交给调用方判定。
install_extra_toolchains() {
  local workdir=""
  local rc=0
  local tmp=""

  tmp="$(mktemp -d)" || {
    require_or_warn "Failed to create a temporary directory for extra toolchains." || return 1
    return 0
  }
  workdir="${tmp}"

  log_info "Installing extra toolchains (upx, padjffs2, po2lmo) in ${workdir}..."

  if _upx_is_current; then
    log_info "upx ${EXTRAS_UPX_VERSION} already installed; skipping."
  elif ! _install_upx "${workdir}"; then
    require_or_warn "Failed to install upx ${EXTRAS_UPX_VERSION}." || rc=1
  fi

  if command -v padjffs2 >/dev/null 2>&1; then
    log_info "padjffs2 already installed; skipping."
  elif ! _install_padjffs2 "${workdir}"; then
    require_or_warn "Failed to install padjffs2." || rc=1
  fi

  if command -v po2lmo >/dev/null 2>&1; then
    log_info "po2lmo already installed; skipping."
  elif ! _install_po2lmo "${workdir}"; then
    require_or_warn "Failed to install po2lmo." || rc=1
  fi

  rm -rf "${workdir}"
  return "${rc}"
}
