#!/bin/bash
#
# Generates immortalwrt/files/etc/uci-defaults/99-release-info and RELEASE_TAG,
# mirroring the workflow step 'ImmortalWrt AutoUpdate'.
#

# Save original directory.
ORIGINAL_DIR="$(pwd)"
readonly ORIGINAL_DIR
trap 'cd "$ORIGINAL_DIR"' EXIT

# 所有 source 与下面的 cd 都按 SCRIPT_DIR 定位，因此必须在第一个 source 之前确定它。
# 本文件位于 scripts/ci/，CI 是按仓库根下的 `bash scripts/ci/xxx.sh` 调起的（也可从任意 CWD 直接执行），
# 用 $PWD 或相对路径去解析 ../libs/ 必然失败。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# 加载顺序即依赖顺序：logger 最先（唯一 log 实现），strictness 次之（调用 log_error）。
# shellcheck source=scripts/libs/01-shell-logger.sh
source "${SCRIPT_DIR}/../libs/01-shell-logger.sh"
# shellcheck source=scripts/build/common/strictness.sh
source "${SCRIPT_DIR}/../build/common/strictness.sh"
# shellcheck source=scripts/build/steps/install-deps.sh
source "${SCRIPT_DIR}/../build/steps/install-deps.sh"
# shellcheck source=scripts/build/steps/compile.sh
source "${SCRIPT_DIR}/../build/steps/compile.sh"
# shellcheck source=scripts/build/pipeline.sh
source "${SCRIPT_DIR}/../build/pipeline.sh"

# Fix to repository root (scripts/build/build.sh anchors everything there).
# 本文件位于 scripts/ci/，故需上溯两级才到仓库根。
cd "${SCRIPT_DIR}/../.." || exit 1

readonly TARGET_DIR="immortalwrt/files/etc/uci-defaults"
readonly TARGET_FILE="${TARGET_DIR}/99-release-info"

# owner/repo, from CI env first, then the origin remote (best effort).
resolve_repository() {
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    echo "${GITHUB_REPOSITORY}"
    return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null)" || url=""
  [[ -n "${url}" ]] || {
    echo "unknown/unknown"
    return 0
  }
  url="${url%.git}"
  if [[ "${url}" == *github.com* ]]; then
    url="${url##*github.com[:/]}"
  else
    url="${url#*://}"
    url="${url#*/}"
  fi
  echo "${url:-unknown/unknown}"
}

# actor, from CI env first, then the git identity.
resolve_actor() {
  if [[ -n "${GITHUB_ACTOR:-}" ]]; then
    echo "${GITHUB_ACTOR}"
    return 0
  fi
  local name
  name="$(git config user.name 2>/dev/null)" || name=""
  echo "${name:-unknown}"
}

# Main function.
main() {
  if [[ ! -d "immortalwrt" ]]; then
    log_error "immortalwrt directory not found in $(pwd); run scripts/build/build.sh prepare first."
    return 1
  fi

  local head_short
  head_short="$(git rev-parse --short HEAD 2>/dev/null)" || head_short=""
  if [[ -z "${head_short}" ]]; then
    log_error "Failed to resolve git HEAD in $(pwd)."
    return 1
  fi

  local tag
  tag="$(date +"ImmortalWrt_%Y%m%d_%H%M%S_")${head_short}"
  local tag_suffix="${tag:12}"
  local repository actor
  repository="$(resolve_repository)"
  actor="$(resolve_actor)"

  mkdir -p "${TARGET_DIR}" || {
    log_error "Failed to create ${TARGET_DIR}"
    return 1
  }

  cat > "${TARGET_FILE}" <<EOF
#!/bin/sh
sed -i '/DISTRIB_GITHUB/d; /DISTRIB_VERSIONS/d' /etc/openwrt_release
echo "DISTRIB_GITHUB='https://github.com/${repository}'" >> /etc/openwrt_release
echo "DISTRIB_VERSIONS='${tag_suffix}'" >> /etc/openwrt_release
sed -i "/^DISTRIB_DESCRIPTION=/s/=ImmortalWrt/=${actor} compiled (${tag_suffix}) \\/ ImmortalWrt/g" /etc/openwrt_release
EOF

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "RELEASE_TAG=${tag}" >> "${GITHUB_ENV}" || {
      log_error "Failed to append RELEASE_TAG to ${GITHUB_ENV}"
      return 1
    }
    log_success "Wrote ${TARGET_FILE}; RELEASE_TAG=${tag} exported via GITHUB_ENV"
  else
    log_success "Wrote ${TARGET_FILE}"
    echo "RELEASE_TAG=${tag}"
  fi
  return 0
}

main "$@"
