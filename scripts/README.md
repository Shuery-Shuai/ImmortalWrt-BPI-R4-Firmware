# scripts/ —— 构建脚本说明

> 本目录是本地与 CI 共用的构建脚本。固件本身的功能、刷机、签名密钥等说明见[仓库根 README](../README.md)。

## 本地构建

CI 与本地走同一套脚本，唯一入口是 `scripts/build/build.sh`。CI 只是把下面几个 stage 拆成几个步骤。

```sh
scripts/build/build.sh <stage>
```

| stage      | 做什么                                                                             |
| ---------- | ---------------------------------------------------------------------------------- |
| `deps`     | 按 `scripts/build/dependencies.txt` 安装主机依赖（目标 ubuntu-24.04），再补装 upx/padjffs2/po2lmo |
| `prepare`  | 克隆 immortalwrt → 还原 APK 私钥 → feeds → 放置 `.config` → DIY → `make defconfig`     |
| `download` | `prepare` + `make download`                                                        |
| `compile`  | `download` + 编译（并行 → 单线程 → 单线程 V=s，失败后按需清理重试）                   |
| `check`    | 只统计 `bin/targets` 产物体积，**不改动工作区**                                     |
| `all`      | `compile` + `check`                                                                |

阶段是累进的：`compile` 隐含 `download` 与 `prepare`，所以一条 `scripts/build/build.sh compile` 就能从零到编译完成。

> [!NOTE]
>
> - `deps` 不会被任何阶段自动触发（本地通常已装好依赖，自动跑 apt 既重复又慢）。
> - `prepare` 是幂等的：它按输入指纹（上游 commit、`.config`、DIY 脚本、`files/`、`feeds.conf`、`libs/`、`mods/`）判断，输入没变就跳过。
>   因此 CI 里「`prepare` 步骤 + `compile` 内含的 prepare」不会重复工作，也不会删掉期间生成的 `99-release-info`。
>   需要强制重跑时设 `FORCE_PREPARE=1`。
> - `REQUIRED=1` 启用严格模式：缺 APK 私钥、缺依赖清单、装依赖失败都直接失败。CI 使用该模式，本地缺省为降级告警。
> - 早期 4 个薄转发入口（旧 `make.sh` / `prepare-workdir.sh` / `set-config.sh` / `initialize-environment.sh`）已删除，
>   一律用 `scripts/build/build.sh <stage>` 代替：compile / prepare / prepare / deps 一一对应。

### scripts/ 目录结构

```text
scripts/
├── build/                   构建逻辑：本地与 CI 共用
│   ├── build.sh             【入口】命令行入口：usage + 6 个 stage 分派
│   ├── load.sh              【入口】目录聚合加载器：按固定顺序 source 各模块，不含业务逻辑
│   ├── pipeline.sh          【编排】prepare 编排：克隆、私钥、feeds、自定义文件、.config、幂等指纹
│   ├── steps/               【阶段】单个 stage 的实现（有副作用）
│   │   ├── install-deps.sh  依赖安装 / upx、padjffs2、po2lmo 补装（deps 阶段）
│   │   └── compile.sh       下载、编译、失败兜底清理（download / compile 阶段）
│   ├── common/strictness.sh 【策略】REQUIRED 严格度（项目专属，换项目不适用）
│   ├── utils/01-check-size-utils.sh 【工具】固件体积统计函数（无状态，仅被 build.sh check 调用）
│   └── dependencies.txt     主机依赖唯一事实源
├── libs/                    共享函数库：所有脚本都可调用，编号即加载序
│   ├── 01-shell-logger.sh   日志唯一实现（log + log_info/log_success/log_warning/log_error）
│   ├── 02-error-handler.sh  失败处理：退出码常量、fail/die、require_* 断言、run/try 命令包装
│   ├── 03-argument-parser.sh 参数解析：parse_args / validate_required_args / validate_enum
│   └── load.sh              目录聚合加载器：按 01→02→03 依赖顺序加载后再加载 utils/
├── ci/                      仅 CI 用的产物生成脚本，本地日常构建无需关心
│   ├── generate-release-info.sh   生成 99-release-info 与 RELEASE_TAG
│   ├── generate-release-notes.sh  生成 release.txt
│   ├── generate-summary.sh        运行总结 → $GITHUB_STEP_SUMMARY
│   └── generate-index.sh    生成 Pages 索引页
└── inputs/                  构建输入：被复制进 immortalwrt/ 后在上游源码树内执行
    ├── diy-part1.sh
    ├── diy-part2.sh
    ├── utils/               工具函数库：仅 DIY 脚本调用（无状态纯函数）
    └── mods/                针对上游源码的具体修改
```

> [!NOTE]
>
> 目录按**消费方**划分而非按文件类型：`build/` 是本地与 CI 共用的构建逻辑，`ci/` 只放「CI 专属且本地无意义」的产物生成脚本，
> `inputs/` 是会被复制进 `immortalwrt/` 在上游源码树内执行的构建输入（位置与文件名保持不变）。
>
> `build/` 内部按**职责**分四类，改文件时先认清它属于哪一类：
>
> | 类别 | 文件 | 判据 |
> | ---- | ---- | ---- |
> | 入口 | `build.sh`、`load.sh` | 只做分派 / source，不含业务逻辑 |
> | 编排 | `pipeline.sh` | 串起多个步骤、决定顺序与幂等 |
> | 阶段 | `steps/*.sh` | 实现单个 stage（deps / download / compile） |
> | 策略 | `build/common/strictness.sh` | REQUIRED 严格度（项目专属语义，换项目不适用） |
>
> `build.sh` 与 `load.sh` **职责不同，不可合并**：`build.sh` 是**命令行入口**（解析 stage、打印 usage、`cd` 到仓库根）；
> `load.sh` 是**目录聚合加载器**（被 `build.sh` 与 `scripts/ci/*.sh` 共同 source，按顺序加载全部函数）。
> 只保留一个会让「拿库函数的 CI 脚本」被迫继承 stage 分派逻辑。
>
> `build/steps/`、`build/common/`、`scripts/libs/` 与 `inputs/utils/` **刻意不合并**，因为性质不同：前者是**编排**——`prepare_all`、
> `copy_custom_files`、`compile_firmware`、`install_dependencies` 这类有副作用、驱动整条流水线的函数；
> 后者是**纯工具**——`download_and_hash`、`clone_repo`、`set_makefile_vars`、
> `normalize_pkg_version` 这类无状态函数。
>
> `build/build.sh` 保持原名：它是多 stage 的分派器（deps / prepare / download / compile / check / all），
> 名字表达的是「构建唯一入口」，改成动宾反而失真。

> [!IMPORTANT]
>
> 复制到 `immortalwrt/` 后，`libs/`、`utils/`、`mods/` 与 `diy-part*.sh` 必须**保持同层**：DIY 脚本用 `${SCRIPT_DIR}/libs/load.sh` 定位依赖。
> 它们会被复制到 `immortalwrt/` 根的同一层，因此迁移目录时只能改仓库侧位置，不能改变复制后的相对布局。

### CI 运行总结（`ci/generate-summary.sh`）

一次运行的结论散落在各步骤日志里，想知道为什么红要逐个点开。`generate-summary.sh` 把它压成一段 Markdown 写进
`$GITHUB_STEP_SUMMARY`，运行页顶部直接能看到步骤状态、产物和关键错误行。

```sh
bash scripts/ci/generate-summary.sh [build|update-checker]   # 缺省 build
```

| 项 | 约定 |
| ---- | ---- |
| 输出 | 设了 `GITHUB_STEP_SUMMARY` 就追加写入该文件，否则打印到 stdout（本地预览用） |
| 退出码 | 恒为 `0`——摘要自身绝不能让流水线变红 |
| 参数 | `build` / `update-checker`，决定标题与适用章节；缺省 `build` |

**入参全是环境变量，缺哪个就跳过对应小节**，所以本地不设任何变量也能跑出可用的一段 Markdown。

| 变量 | 用途 |
| ---- | ---- |
| `JOB_STATUS` | job 总状态（`${{ job.status }}`），表头成败的依据 |
| `STEP_SEQUENCE` | 多行，按显示顺序每行 `KEY\|显示名称`，决定步骤状态表的行序与显示名 |
| `STEP_<KEY>` | 该步骤的 outcome（`success` / `failure` / `cancelled` / `skipped` / 空） |
| `DEVICE_NAME` / `FILE_DATE` / `RELEASE_TAG` | 元信息：机型、文件日期、发布 tag |
| `ARTIFACT_BIN_NAME` / `ARTIFACT_FIRMWARE_NAME` / `ARTIFACT_LOGS_NAME` | 产物名 |
| `CACHE_HIT` | ccache / 构建缓存是否命中（`true` / `false`） |
| `LOG_DIR` | 日志目录，相对仓库根，缺省 `logs` |
| `COMMIT_HASH` / `BUILD_TRIGGERED` | `update-checker` 专用：检出的上游 commit、是否触发了构建 |
| 标准 `GITHUB_*` | `GITHUB_REPOSITORY` / `_SERVER_URL` / `_RUN_ID` / `_RUN_ATTEMPT` / `_WORKFLOW` / `_REF_NAME` / `_EVENT_NAME` / `_ACTOR` / `_JOB`、`RUNNER_OS`：链接、run 号、触发方式等 |

摘要按下面几块拼装，每一块都只在自己的输入存在时才出现：

| 小节 | 内容 | 依据 |
| ---- | ---- | ---- |
| 结论 + 运行链接 | 成功 / 失败、`server/repo/actions/runs/<id>` | `JOB_STATUS`、`GITHUB_REPOSITORY`、`GITHUB_RUN_ID` |
| 运行信息 | workflow、job、事件、分支、提交、触发人、Runner OS、run attempt | 标准 `GITHUB_*` + `git rev-parse` |
| 上游更新 | 检出的上游 commit、是否触发构建（仅 `update-checker`） | `COMMIT_HASH`、`BUILD_TRIGGERED` |
| 步骤状态 | 按 `STEP_SEQUENCE` 逐行列出 outcome，带结果徽标 | `STEP_SEQUENCE` + `STEP_<KEY>` |
| 构建产物（仅 `build`） | 设备、文件日期、Release tag、缓存命中、artifact 名、固件体积 | `DEVICE_NAME` / `FILE_DATE` / `RELEASE_TAG` / `CACHE_HIT` / `ARTIFACT_*_NAME` |
| 耗时与缓存 | 取 `LOG_DIR` 最新一份日志的首尾时间戳，算时长；有 ccache 时附命中率 | `LOG_DIR` |
| 失败详情 | 从最新日志末尾筛出关键错误行，折叠在 `<details>` 里 | job 失败时的 `LOG_DIR` |

失败摘录是「诊断辅助」而非「原因判定」：它扫描的是最新一份日志的末尾若干行并按关键字过滤，
真正的原因仍以该日志为准，摘要只负责把人带到那一行。

两种模式各有取舍：`update-checker` 那个 job 拿不到固件，所以不渲染产物与体积小节（渲染了只会骗人）；
反过来「上游更新」小节只在 `update-checker` 出现。

> [!IMPORTANT]
>
> 两个 workflow 都以 `if: always()` + `continue-on-error: true` 调它：摘要是「事后报告」，编译失败或被取消时它更要跑到，
> 而它自己挂掉也绝不能给已经失败的 job 再补一刀。脚本内置的「恒 0」是第二道保险，两道都在。

> [!NOTE]
>
> `STEP_SEQUENCE` 给顺序和显示名，`STEP_<KEY>` 给状态值，是同一份数据的两种视图——新增步骤时两处都要登记。
> 本地预览：`bash scripts/ci/generate-summary.sh`（不设 `GITHUB_STEP_SUMMARY` 即打印到终端）。

### 错误处理（`libs/02-error-handler.sh`）

Shell 没有异常机制，错误处理围绕**退出码、`return`/`exit`、断言**展开。本库只做「控制流 + 退出码」，
日志格式归 `01-shell-logger.sh`，两者边界清晰。

**核心分工（不可混用）**

| 函数 | 行为 | 适用场景 |
| ---- | ---- | -------- |
| `fail <msg>` | `log_error` 后 **`return 1`** | 被 `source` 的库与函数——调用者必须能继续处理 |
| `die <msg>` | `log_error` 后 **`exit 1`** | 仅顶层可执行脚本（`build.sh`、`ci/*.sh`） |

> [!WARNING]
>
> 库函数里调 `die` 是反模式：它会杀掉调用者的整个 shell，导致清理、重试、错误上报全部被跳过。

**退出码常量**（沿用 `sysexits.h`，避免 `exit 1` 满天飞）

`E_SUCCESS=0`、`E_GENERAL=1`、`E_USAGE=64`、`E_DATAERR=65`、`E_NOINPUT=66`、
`E_UNAVAILABLE=69`、`E_SOFTWARE=70`、`E_OSERR=71`、`E_CANTCREAT=73`、`E_IOERR=74`。
`exit_code_to_name <code>` 把码转成可读名（`64` → `USAGE`，未知 → `UNKNOWN`）。

**当前退出码用法**


| 场景 | 退出码 | 说明 |
| ---- | ------ | ---- |
| 成功 | `E_SUCCESS` 0 | |
| 用法错误（stage 非法、缺必需参数） | `E_USAGE` 64 | `build.sh` 已迁移，便于区分「敲错命令」与「构建失败」 |
| 通用失败 | `E_GENERAL` 1 | 存量 `exit 1` 保持原样，未强制迁移 |

> [!NOTE]
>
> 子 shell 内部的 `exit`（如 `( cd immortalwrt || exit 1; ... )`）**不迁移**：那里的 `exit` 是控制流机制——
> 只结束子 shell、由外层 `|| return 1` 接住返回码，与「错误分类」无关。把 `exit 1` 改成 `exit $E_OSERR` 不会改变任何行为。
>
> CI 对任何非零退出码一视同仁（都判失败），因此 `64` 与 `1` 在流水线里没有区别；区分的价值在于**本地与人读**。

**断言与前置检查**（全部 `return 1`，不 `exit`）

`require_cmd` / `require_var` / `require_file` / `require_dir` / `require_exec`。
多参数时在第一个缺失项处返回，错误信息始终指向一个具体路径或命令名。

**命令执行包装**

| 函数 | 失败行为 |
| ---- | -------- |
| `run <cmd...>` | 保留原 stdout/stderr，追加「命令 + 退出码」后 `return 1` |
| `try <cmd...>` | **不报错不退出**，仅返回命令退出码，供 `if` 判断 |
| `run_or_fail <msg> <cmd...>` | 用自定义消息 `return 1` |
| `with_retry <N> <cmd...>` | 重试 N 次（无固定间隔，只为吸收瞬时竞态），最终失败 `return 1` |

`run` 与 `try` 的区别就是两种错误处理风格：**失败即终止** vs **失败可捕获**。

**`trap` 与清理：本轮未实现**，实现时必须先解决这三个实测限制（现已记入库文档）：

1. `trap ERR` **不依赖 `set -e`**——没有 `set -e` 也会触发（与常见说法相反）。
2. `trap ERR` 在 `if` / `&&` / `||` 的失败分支中**不触发**。
3. 连续两次 `trap X EXIT`，**只有最后一个执行**，前一个被静默覆盖。
   因此 `cleanup` 栈必须先做 trap 串联，否则会破坏 `generate-release-*.sh` 现有的 `EXIT` trap。
