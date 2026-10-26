#!/bin/bash
#
# 准备阶段编排（scripts/build/pipeline.sh，下称 pipeline）：进入仓库目录、克隆/更新、私钥、feeds、自定义文件、
# .config、DIY、defconfig 与备份等辅助函数；函数名与实现与迁移前的单体实现完全一致。
#
# 依赖 scripts/libs/01-shell-logger.sh 的日志包装与 scripts/build/common/strictness.sh 的 require_or_warn。
# 所有涉及目录切换的地方都在子 shell 内完成，调用者 cwd 不受影响，函数一律以仓库根为基准。
#
# 失败语义：本文件是被 build.sh source 的库。失败一律用 fail（记录错误 + return 1）上交返回码，
# 由 build.sh 的 `run_stage || exit 1` 决定是否终止整个进程——本文件的函数【绝不】exit，
# 否则 build.sh 的收尾（日志、后续清理）会被跳过，只剩最后一行日志能看。
# shellcheck source=scripts/libs/02-error-handler.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../libs/02-error-handler.sh"

# Checks and enters the immortalwrt directory.
enter_immortalwrt_dir() {
  if [[ -d "immortalwrt" ]]; then
    log_info "Entering 'immortalwrt' directory..."
    cd immortalwrt || {
      fail "Failed to enter 'immortalwrt' directory!"
      return 1
    }
    return 0
  elif [[ "$(basename "$(pwd)")" == "immortalwrt" ]]; then
    return 0
  else
    fail "Current directory is not or does not contain 'immortalwrt'. Please enter the correct directory."
    return 1
  fi
}

# Backs up a file with a timestamp.
backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup="${file}.${timestamp}.bak"
    cp "$file" "$backup"
    log_info "Backed up $file to $backup"
  fi
}

# Safely sets a config option in the .config file.
safe_set_config() {
  local key="$1"
  local value="$2"
  local comment="$3"
  local config_file="${4:-.config}"

  # Escape special characters in key.
  local escaped_key
  escaped_key=$(printf '%s\n' "$key" | sed "s/[][\.|\$(){}?+*^]/\\\\&/g")

  if grep -q "^${escaped_key}=" "$config_file"; then
    sed -i "s/^${escaped_key}=.*/${key}=${value}/" "$config_file"
    log_info "Enabled: ${key}=${value} ${comment}"
  elif grep -q "^# ${escaped_key} is not set" "$config_file"; then
    sed -i "s/^# ${escaped_key} is not set/${key}=${value}/" "$config_file"
    log_info "Set: ${key}=${value} ${comment}"
  else
    echo "${key}=${value}" >>"$config_file"
    log_info "Added: ${key}=${value} ${comment}"
  fi
}

# Prepares the immortalwrt repository.
# 对齐 workflow：Clone source code（git clone --depth 1 $REPO_URL -b $REPO_BRANCH immortalwrt）。
# 所有 git 操作都必须在 immortalwrt/ 内进行——此前这些命令跑在仓库根目录，
# 会清除未跟踪文件并朝固件仓库自身的 remote（SSH 地址）发起 pull，必然失败。
prepare_immortalwrt_repo() {
  local repo_url="${REPO_URL:-https://github.com/immortalwrt/immortalwrt}"
  local repo_branch="${REPO_BRANCH:-master}"

  if [[ ! -d "immortalwrt" ]]; then
    log_info "Cloning immortalwrt repository (branch: ${repo_branch})..."
    git clone --depth 1 -b "${repo_branch}" "${repo_url}" immortalwrt || {
      fail "Failed to clone 'immortalwrt' repository. Please check network connection or repository URL."
      return 1
    }
    return 0
  fi

  log_info "Updating immortalwrt repository..."
  (
    # 子 shell 内刻意保留 exit：exit 只结束这个子 shell，不会杀掉 build.sh；
    # 换成 fail 反而不行——fail 的 return 只从 fail 自身返回，子 shell 会继续往下跑，
    # 于是 cd 失败后后续 git 命令会落在错误的目录里。
    cd immortalwrt || {
      log_error "Failed to enter 'immortalwrt' directory."
      exit 1
    }
    # shallow clone 不支持裸 git pull 的某些场景，统一走 fetch + reset，语义与"更新到上游最新"一致。
    git fetch --depth 1 origin "${repo_branch}" || {
      log_error "Failed to fetch immortalwrt updates."
      exit 1
    }
    # 只回滚已跟踪文件的改动；不用 git clean -fdx。
    # 那会连 build_dir/ staging_dir/ dl/ 一起删掉——它们是数小时的编译产物，
    # 且 dl/ 被 .gitignore 忽略，本就不该在"更新仓库"这个动作里被清除。
    # 工作区确实需要彻底清理时，由 compile_firmware 在失败后按需调用 clean_immortalwrt_changes。
    git reset --hard FETCH_HEAD || {
      log_error "Failed to reset immortalwrt to upstream."
      exit 1
    }
  ) || return 1
}

# 加载 feeds.conf 覆盖文件（对齐 workflow: Load custom feeds）。
# workflow 的 $FEEDS_CONF 来自仓库根，存在时覆盖 immortalwrt/feeds.conf.default。
load_custom_feeds() {
  local feeds_conf="${FEEDS_CONF:-feeds.conf.default}"
  if [[ -f "${feeds_conf}" ]]; then
    log_info "Loading custom feeds config: ${feeds_conf}"
    cp "${feeds_conf}" "immortalwrt/feeds.conf.default" || {
      fail "Failed to copy feeds config into immortalwrt."
      return 1
    }
  else
    log_info "No custom feeds config found (${feeds_conf}), using upstream default."
  fi
}

# 还原 APK 签名私钥并校验公钥指纹（对齐 workflow: Restore APK signing key）。
# 私钥在 CI 来自 secret APK_PRIVATE_KEY_B64，本地从 keys/private-key.pem 读取。
# 缺少私钥时构建会用一次性密钥，已刷机设备将无法信任新仓库，因此这里只报警不中断，
# 以保证本地首次构建可用；CI 侧由 workflow 的 set -euo pipefail 负责强制。
#
# 门禁形态（相对迁移前的"与入库公钥逐字节比对"）：仓库不再入库公钥——keys/public-key.pem
# 已随"公钥出库"删除，逐字节比对失去了比对对象，也无法在 CI 里凭空恢复该文件。
# 现在改用环境变量指纹：私钥派生公钥 → 公钥 sha256 与仓库 Variable APK_PUBLIC_KEY_SHA256 比对，
# 基准随代码仓库一起走版本管理，不再依赖任何入库密钥文件。比对逻辑只由
# scripts/ci/check-apk-signing-key.sh 实现，CI 并行调用同一个脚本，两处不会分叉。
restore_apk_signing_key() {
  local dest="immortalwrt/private-key.pem"
  local local_key="${APK_PRIVATE_KEY:-keys/private-key.pem}"

  if [[ -n "${APK_PRIVATE_KEY_B64:-}" ]]; then
    log_info "Restoring APK signing key from APK_PRIVATE_KEY_B64..."
    ( umask 077 && printf '%s' "${APK_PRIVATE_KEY_B64}" | base64 -d > "${dest}" ) || {
      fail "Failed to decode APK_PRIVATE_KEY_B64."
      return 1
    }
  elif [[ -f "${local_key}" ]]; then
    log_info "Restoring APK signing key from ${local_key}..."
    ( umask 077 && cp "${local_key}" "${dest}" ) || {
      fail "Failed to copy ${local_key}."
      return 1
    }
  else
    require_or_warn \
      "APK signing key not found (${local_key}); build will use a one-off key and flashed devices will not trust the new repo." \
      || return 1
    return 0
  fi

  # 门禁：私钥派生公钥 → 与 APK_PUBLIC_KEY_SHA256 指纹比对（不再是入库公钥逐字节比对：
  # 公钥已出库，本就无文件可对齐）。派生结果先落临时文件再由门禁脚本读它算指纹，
  # 这样 openssl 的失败不会被管道/命令替换吞掉——旧实现用 2>/dev/null 且外层套 `if [[ -f ]]` 守卫，
  # 派生失败时会静默跳过整段校验。
  local pub_tmp check_script="scripts/ci/check-apk-signing-key.sh"
  pub_tmp="$(mktemp "${TMPDIR:-/tmp}/apk-pubkey.XXXXXX")" || {
    fail "Failed to create a temporary file for the derived APK public key."
    return 1
  }
  # 临时文件按绝对路径删除：本函数的调用方会 cd 进 immortalwrt/，相对路径会在错误的目录里 rm。
  if ! openssl ec -in "${dest}" -pubout -out "${pub_tmp}"; then
    rm -f -- "${pub_tmp}"
    fail "Failed to derive the public key from ${dest}."
    return 1
  fi
  # 调用路径相对【仓库根】：pipeline 的运行基准一直是仓库根（上面的 keys/private-key.pem 同理）。
  # || rc=$? 而非裸调用 + ${?}：裸调用在调用方开了 set -e 时会直接终止进程，
  # rm 就永远走不到，临时文件（公钥）会留在 /tmp。放进 || 列表后不再触发 set -e。
  local rc=0
  "${check_script}" key "${pub_tmp}" || rc=$?
  rm -f -- "${pub_tmp}"
  if [[ ${rc} -ne 0 ]]; then
    fail "The signing key does not match APK_PUBLIC_KEY_SHA256; aborting."
    return 1
  fi
}

# Cleans feeds.
clean_feeds() {
  log_info "Cleaning feeds..."
  ./scripts/feeds clean -a -f
}

# Copies custom files to the immortalwrt directory.
# 对齐 workflow: Load custom configuration（cp -r files immortalwrt/）。
# 额外复制 diy-part*.sh / libs/ / mods/：diy 脚本以 SCRIPT_DIR 定位同级 libs/ 与 mods/，
# 只有把它们放进 immortalwrt/，source "${SCRIPT_DIR}/libs/load.sh" 才能解析成功。
# 这几项的**仓库内**位置是 scripts/inputs/（2025 迁移），复制**目标**仍是 immortalwrt/ 根：
# 迁移只改源路径，改不了"复制后必须同层"这条契约。
copy_custom_files() {
  log_info "Copying custom files to immortalwrt directory..."
  # 全程在子 shell 中 cd：调用者的工作目录保持不变。
  # 此前这里直接 cd 且不返回，导致调用方后续的相对路径（再次 cd immortalwrt）全部错位。
  (
    # 子 shell 内的每个失败点都必须让【子 shell】以非 0 结束，外层的 `|| fail` 才接得住。
    # 这里不能写 `|| fail`：fail 的 return 从 fail 自身返回，rc=1 会被 || 吃掉，子 shell 继续执行，
    # 后续 cp/rm 就落在错误的目录里。所以先用 log_error 交代是哪一步失败，再 exit 1 结束子 shell。
    if ! cd immortalwrt; then
      log_error "Failed to enter 'immortalwrt' directory."
      exit 1
    fi
    if [[ -d "files" ]]; then
      rm -rf files
    fi
    if ! cp -r ../files ./; then
      log_error "Failed to copy 'files' into immortalwrt."
      exit 1
    fi
    # 输入源在仓库的 scripts/inputs/（已 cd 进 immortalwrt/，故相对路径是 ../scripts/inputs）。
    # 显式列出两个文件名而不沿用 ../diy-part*：通配在新布局下匹配不到任何东西，
    # 而 cp 的失败又会因 set -e 之外的语义被静默吞掉，留下"复制成功但没有 diy 脚本"的假象。
    if ! cp ../scripts/inputs/diy-part1.sh ../scripts/inputs/diy-part2.sh ./; then
      log_error "Failed to copy diy-part1.sh / diy-part2.sh into immortalwrt."
      exit 1
    fi
    # diy 脚本的依赖目录，缺任一个都会让 diy-part1/2 在 source 阶段失败。
    # 与 diy 脚本一并落在 immortalwrt/ 根，维持同级兄弟关系。
    # libs 是所有脚本共用的库（src: scripts/libs），utils 与 mods 仅 DIY 脚本调用（src: scripts/inputs）。
    if ! { rm -rf libs && cp -r ../scripts/libs ./; }; then
      log_error "Failed to copy scripts/libs into immortalwrt."
      exit 1
    fi
    for dir in utils mods; do
      [[ -d "../scripts/inputs/${dir}" ]] || continue
      rm -rf "${dir}"
      if ! cp -r "../scripts/inputs/${dir}" ./; then
        log_error "Failed to copy scripts/inputs/${dir} into immortalwrt."
        exit 1
      fi
    done
  ) || fail "Failed to copy custom files into immortalwrt."
}

# Runs diy-part1.sh.
# diy 脚本内含相对路径（如 package/base-files/...），必须在 immortalwrt/ 内执行。
run_diypart1() {
  log_info "Running DIY PART1 script..."
  if [[ -f "immortalwrt/diy-part1.sh" ]]; then
    ( cd immortalwrt && bash ./diy-part1.sh ) || {
      fail "DIY PART1 script failed."
      return 1
    }
  fi
}

# Updates feeds.
update_feeds() {
  log_info "Updating feeds..."
  ./scripts/feeds update -a -f
}

# Installs feeds.
install_feeds() {
  log_info "Installing all feeds..."
  ./scripts/feeds install -a -f
}

# Runs diy-part2.sh.
# diy 脚本内含相对路径，必须在 immortalwrt/ 内执行。
run_diypart2() {
  log_info "Running DIY PART2 script..."
  if [[ -f "immortalwrt/diy-part2.sh" ]]; then
    ( cd immortalwrt && bash ./diy-part2.sh ) || {
      fail "DIY PART2 script failed."
      return 1
    }
  fi
}

# prepare 输入指纹的标记文件。
# 路径选在 immortalwrt/ 根下，同时满足三个约束：
#   · 不在 immortalwrt/files/ 内，因此 copy_custom_files 的 rm -rf files 碰不到它；
#   · 整个 immortalwrt/ 已被仓库根 .gitignore 忽略，不会污染上游 git 跟踪；
#   · 同属被忽略文件，clean_immortalwrt_changes 里的 git clean -fd 也不会删它。
# 用 ${VAR:-default} 而不是 readonly：本模块被重复 source 时不会报"只读变量"。
PREPARE_STAMP_FILE="${PREPARE_STAMP_FILE:-immortalwrt/.prepare-stamp}"

# 计算 prepare 的全部输入指纹。
#
# 覆盖项：上游 commit、仓库根 .config、scripts/inputs/diy-part1.sh 与 diy-part2.sh、
# files/、feeds.conf（若存在）、scripts/inputs/{libs,utils,mods}/。
# 路径必须与 copy_custom_files 的**源**一致：抄错一处，指纹就永远算 absent，
# 于是每次 prepare 都被判为"输入已变"，幂等静默失效（不报错，只是每次都重跑）。
# 做法是每项先各自 sha256，再把「标签:摘要」行合并后整体再 sha256：
# 直接把多个目录顺序拼进同一个哈希会因拼接顺序与内容边界产生歧义，分层摘要不会。
# immortalwrt/ 不存在（首次）或不是 git 仓库时安全返回，不会因 git/路径缺失中断。
prepare_inputs_fingerprint() {
  local -a inputs=()
  local head=""
  local item
  local digest

  # 上游 commit：准备阶段会 fetch + reset 到它，因此它是最核心的输入。
  if [[ -d "immortalwrt" ]]; then
    head="$(git -C immortalwrt rev-parse HEAD 2>/dev/null || true)"
  fi
  inputs+=("immortalwrt-head:${head:-absent}")

  # 单文件输入：缺失时记 absent，保证"首次没有"与"存在但内容变了"可区分。
  for item in .config scripts/inputs/diy-part1.sh scripts/inputs/diy-part2.sh feeds.conf; do
    if [[ -f "${item}" ]]; then
      digest="$(sha256sum "${item}" 2>/dev/null | cut -d' ' -f1)"
      inputs+=("${item}:${digest:-unreadable}")
    else
      inputs+=("${item}:absent")
    fi
  done

  # 目录输入：目录内每个文件的路径与内容都参与摘要，汇总后再摘一次。
  for item in files scripts/libs scripts/inputs/utils scripts/inputs/mods; do
    if [[ -d "${item}" ]]; then
      digest="$(find "${item}" -type f -print0 | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)"
      inputs+=("${item}:${digest:-unreadable}")
    else
      inputs+=("${item}:absent")
    fi
  done

  printf '%s\n' "${inputs[@]}" | sha256sum | cut -d' ' -f1
}

# 判断上次成功 prepare 的输入是否与当前一致（一致即可整段跳过）。
# 三个前置条件缺一不可：immortalwrt/ 存在、标记文件存在、指纹相等。
# immortalwrt/ 不存在一律返回 1（必须完整执行）。
prepare_is_current() {
  [[ -d "immortalwrt" ]] || return 1
  [[ -f "${PREPARE_STAMP_FILE}" ]] || return 1

  local current recorded
  current="$(prepare_inputs_fingerprint)" || return 1
  [[ -n "${current}" ]] || return 1
  recorded="$(cat "${PREPARE_STAMP_FILE}" 2>/dev/null)" || return 1
  [[ "${current}" == "${recorded}" ]]
}

# 记录当前输入指纹。只允许在 prepare_all 全部成功之后调用：
# 失败被写进标记会让坏状态永久命中跳过，等于把缺陷固化。
record_prepare_stamp() {
  prepare_inputs_fingerprint >"${PREPARE_STAMP_FILE}" ||
    fail "Failed to write prepare stamp: ${PREPARE_STAMP_FILE}"
}

# 准备阶段的完整步骤，顺序与 workflow 逐行对齐：
#   clone -> 私钥 -> feeds.conf -> 自定义文件 -> .config -> DIY1 -> feeds update -a
#   -> DIY2 -> feeds update -i -> feeds install -a -> defconfig
# 其中两处顺序是硬约束，不能为了"看起来更顺"而调整：
#   · copy_custom_files 必须早于 run_diypart1：diy 脚本 source 同级的 libs/ 与 mods/，
#     这些目录只有被复制进 immortalwrt/ 才解析得到。
#   · place_custom_config 必须早于 run_diypart2：CI 同样是先 mv .config 再跑 DIY2。
# defconfig 放最后：它依赖 feeds install 后的包符号，提前跑会把未知符号丢掉。
# 任一步失败都中止，不再让缺陷推迟到编译期。
#
# 【幂等】compile 阶段隐含 prepare（见 scripts/build/build.sh），CI 会先后两次调用 prepare
# （Prepare build workspace 与 Build firmware）。因此本函数以输入指纹为单位幂等：
# 指纹未变时整段空操作，只打一行日志。这既保证本地"一条命令从零跑"，也让 CI 不重复
# clone/fetch、feeds update -a、feeds install -a、make defconfig；更关键的是避免第二次
# copy_custom_files 用 rm -rf immortalwrt/files 把 generate-release-info.sh 生成的 99-release-info
# 静默删掉——该文件就在 immortalwrt/files/ 内，正是被删除的范围。
# FORCE_PREPARE=1 强制重跑，用于排查。
prepare_all() {
  if [[ "${FORCE_PREPARE:-0}" != "1" ]] && prepare_is_current; then
    log_info "inputs unchanged; skipping prepare"
    return 0
  fi

  log_info "Preparing immortalwrt workspace..."

  # 刻意不在这里 clean：清理会把 build_dir/ staging_dir/ 等数小时的编译产物一起丢掉。
  # 清理只作为编译失败后的最后手段，见 compile_firmware。
  # 指纹刻意不含 build_dir/staging_dir/dl/tmp，也不含 clean_immortalwrt_changes 的效果：
  # 那是失败兜底，不应影响"这份输入是否已经准备过"的判断。
  prepare_immortalwrt || return 1
  restore_apk_signing_key || return 1
  load_custom_feeds || return 1
  copy_custom_files || return 1
  place_custom_config || return 1
  run_feeds_pipeline || return 1
  configure_defconfig || return 1

  # 只有全部成功才写标记：上面任一步失败都已提前 return。
  record_prepare_stamp
}

# DIY1 -> feeds update -a -> DIY2 -> feeds update -i -> feeds install -a。
# 抽成一层是为了让 prepare_all 与 setup_feeds 共用同一份顺序，不各写一边再慢慢跑偏。
run_feeds_pipeline() {
  run_diypart1 || return 1

  log_info "Updating feeds..."
  # 此处【不能】只写 `|| fail`：后续还有 DIY2 / update -i / install -a，fail 的返回不会终止函数，
  # 一步失败却继续往下跑会把缺陷藏起来。fail 负责报错，return 1 负责提前退出，两者都要。
  ( cd immortalwrt && ./scripts/feeds update -a ) || {
    fail "Failed to update feeds."
    return 1
  }

  run_diypart2 || return 1

  log_info "Refreshing feed index after DIY PART2..."
  ( cd immortalwrt && ./scripts/feeds update -i ) || {
    fail "Failed to refresh feed index."
    return 1
  }

  log_info "Installing all feeds..."
  ( cd immortalwrt && ./scripts/feeds install -a -f ) || fail "Failed to install feeds."
}

# 兼容既有调用方：feeds/DIY 部分（.config 与 defconfig 交给 prepare_config）。
setup_feeds() {
  place_custom_config || return 1
  run_feeds_pipeline || return 1
}

# 放置 .config（对齐 workflow: [ -e $CONFIG_FILE ] && mv $CONFIG_FILE immortalwrt/.config）。
# 必须在 run_diypart2 之前完成：DIY2 会按 .config 决定打哪些补丁、改哪些包。
place_custom_config() {
  local config_file="${CONFIG_FILE:-.config}"
  if [[ -f "${config_file}" ]]; then
    log_info "Installing configuration: ${config_file}"
    cp "${config_file}" immortalwrt/.config || fail "Failed to copy ${config_file}"
  elif [[ -f "immortalwrt/.config" ]]; then
    log_info "Using existing immortalwrt/.config"
  else
    fail "No configuration found (${config_file} missing)."
  fi
}

# make defconfig 归一化配置（对齐 workflow "Download package" 的第一步）。必须是准备阶段最后一步：
# 它依赖 feeds install 之后才存在的包符号，提前跑会把未知符号全部丢弃。
configure_defconfig() {
  ( cd immortalwrt && make defconfig ) || fail "make defconfig failed."
}

# 兼容既有调用方：放置 .config 再归一化。
prepare_config() {
  place_custom_config || return 1
  configure_defconfig || return 1
}

# Prepares the immortalwrt repository.
prepare_immortalwrt() {
  prepare_immortalwrt_repo
}
