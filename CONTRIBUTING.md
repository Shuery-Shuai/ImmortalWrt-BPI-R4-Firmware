# 🤝 贡献指南

本文件规定「改动怎么进 main」。它不是礼仪，而是这个仓库的运行前提：main 同时是编译分支、Release 分支和 Pages 索引的来源，一条直推的提交会立刻变成下一次要刷进路由器的固件。

读完本文件你应该能回答三个问题：我的改动该放在哪条分支、PR 里必须有什么、CI 红了之后我自己怎么修。

## 📖 目录

- [为什么 main 不能直推](#-为什么-main-不能直推)
- [分支模型](#-分支模型)
- [PR 流程](#-pr-流程)
- [摘要与溯源](#-摘要与溯源)
- [CI 门禁](#-ci-门禁pr-guard)
- [变更范围限制](#-变更范围限制)
- [合并后自动删除分支](#-合并后自动删除分支)
- [常见失败与自助修复](#-常见失败与自助修复)
- [直接推送被拒之后](#-直接推送被拒之后)
- [维护者：分支保护本身也是代码](#-维护者分支保护本身也是代码)
- [相关文档](#-相关文档)

## 🚦 为什么 main 不能直推

`main` 不是"开发主线"，而是**编译产物线**：`.github/workflows/immortalwrt-builder.yml`在 main 上跑完整构建，产物直接进 Release 与 Pages
索引。一次直推会同时造成三件事：

1. 绕过 `pr-guard`——没人检查这次改动是否附带摘要、是否在允许的变更范围内；
2. 绕过语法门禁——shellcheck / actionlint / markdownlint 还没来得及跑，提交已经在 main 上；
3. 直接成为下一次构建的输入——写坏一个镜像源或一处包名，代价是"下一次要刷进路由器的固件"。

PR 的价值不在于仪式，而在于它把这三件事变成**可检查、可回溯、可回滚**的记录：这次合入改了什么、门禁结论是什么、失败时回退哪一个合并。

由此得到三条硬规则（它们由分支保护强制执行，不是约定）：

1. 任何修改一律新建分支；
2. 禁止直接 push 到 main，且管理员同样受限（`enforce_admins=true`）；
3. 只通过 PR 合入，不允许 force push 覆盖历史。

## 🌿 分支模型

只维护一条长期分支：main。其余分支都是短生命周期的改动分支，合并后由仓库自动删除（见[合并后自动删除分支](#-合并后自动删除分支)）。

### 分支命名约定

`<type>/<简短描述>`，全部小写，描述部分只用字母、数字、`.`、`_`、`-`，用 `-` 分词，不要空格、中文或斜杠。CI 的 C1 就用这条规则校验 PR 的 head 分支名。

| type       | 用途                               | 例子                           |
| ---------- | ---------------------------------- | ------------------------------ |
| `feat`     | 新功能或新能力                     | `feat/luci-restore-pkg-notice` |
| `fix`      | 修缺陷                             | `fix/summary-trailing-space`   |
| `chore`    | 杂务：依赖、版本钉、无关构建的整理 | `chore/bump-upx`               |
| `docs`     | 只改文档                           | `docs/contributing`            |
| `refactor` | 不改行为的重构                     | `refactor/logger-capture`      |
| `perf`     | 性能、体积、构建时长               | `perf/parallel-compile`        |
| `test`     | 测试与校验脚本                     | `test/pinned-tools`            |
| `build`    | 构建脚本与流水线                   | `build/ccache-default`         |
| `ci`       | workflow 与 CI 脚本                | `ci/pr-guard`                  |
| `revert`   | 回退某次合入                       | `revert/ccache-default`        |

为什么限定这十个前缀：分类数量有限才能用于统计、自动打标签和"这次改动该谁看"；放任 `bugfix/`、`hotfix/`、`feature/` 与 `fix`、`feat` 并存，一周之后就没人能说清两个词的区别，规则也就失效了。

### 分支从哪来、活多久

- 从最新的 `origin/main` 切出，不要从别人未合并的分支切；
- 一条分支只做一件事，不要"顺手带上"另一个改动；
- 合并后分支由 GitHub 自动删除，本地用 `git branch -d` 清掉即可。

## 🔁 PR 流程

下面七步是完整流程，其中第 6 步是最容易漏掉的一步——它决定 PR 能不能通过门禁。

### 第 1 步：同步 main

```bash
git switch main
git pull --ff-only
```

### 第 2 步：新建分支

```bash
git switch -c feat/my-change
```

### 第 3 步：改动

只改你的改动需要改的文件。注意 `.config`、`.gitignore`、`.github/**` 这些"会被所有人共用"的文件，改动它们需要在 PR 描述里单独说明理由。

### 第 4 步：本地自查

```bash
# shell 脚本：语法 + 静态检查（两条都要过）
bash -n scripts/ci/your-script.sh
shellcheck -x scripts/ci/your-script.sh

# workflow 语法（有改动 .github/** 时）
actionlint

# markdown（规则集见 .markdownlint-cli2.yaml）
# 文件清单必须与 .github/workflows/syntax-linter.yml 里 markdownlint job 的 docs 数组一字不差，
# 否则「本地绿」不代表「CI 绿」——漏掉的文件只会在 CI 上红。
npx markdownlint-cli2 "README.md" "README-workflow.md" "scripts/README.md" "CONTRIBUTING.md" ".github/pull_request_template.md"
# markdown 格式（prettier 只做格式归一，不改语义；CI 也跑同一条）
npx prettier --check "README.md" "README-workflow.md" "scripts/README.md" "CONTRIBUTING.md" ".github/pull_request_template.md"
```

本地自查不是形式：CI 跑的是同一组工具，先跑一遍能把"等十分钟看红叉"变成"立刻改掉"。

### 第 5 步：提交并推送

```bash
git add -A
git commit -m "✨ feat(scope): 一句话说明这次改动"
git push -u origin feat/my-change
```

#### 提交信息格式（C7 强制校验）

提交信息的**标题行**沿用仓库既有形态，格式固定：

```text
<EMOJI> <type>(<scope>): <说明>
```

| 部分        | 是什么                             | C7 怎么校验                                   |
| ----------- | ---------------------------------- | --------------------------------------------- |
| `<EMOJI>`   | 一眼分辨提交性质的可读性标记       | 任意 emoji 即可，**不设白名单**               |
| `<type>`    | 改动性质，与分支前缀共用同一套取值 | 必须取下列十种之一                            |
| `(<scope>)` | 改动落在哪个模块                   | 必填非空，只允许小写字母、数字、`.`、`_`、`-` |
| `<说明>`    | 一句话说清做了什么                 | 冒号后必须有一个空格，说明非空                |

`<type>` 的十种取值：`feat`、`fix`、`chore`、`docs`、`refactor`、`perf`、`test`、`build`、`ci`、`revert`。

##### emoji 怎么选（推荐，不强制）

| type       | 本仓库历史里常用的 | 备注                               |
| ---------- | ------------------ | ---------------------------------- |
| `feat`     | ✨                 | 新功能，历史提交里占绝大多数       |
| `fix`      | 🐞                 | 修缺陷                             |
| `docs`     | 📃                 | 只改文档                           |
| `refactor` | 🔥 / 🚚 / 🦄       | 同一个 type 历史上换过多次，都合法 |
| `perf`     | 🎈                 | 性能相关；换成 📊 之类同样不会红   |
| `chore`    | 🐳                 | 杂务、依赖与元数据                 |
| `test`     | ✅                 | 新增或调整测试                     |
| `build`    | 🔧                 | 构建脚本与产物参数                 |
| `ci`       | 🐎                 | workflow 与门禁脚本                |
| `revert`   | ↩                  | 回滚某个提交                       |

emoji 只是可读性标记，**C7 不校验具体 emoji**：同一个 type 用不同 emoji 不会被拦下，选哪个只影响 `git log --oneline` 好不好扫。

##### scope 怎么写

- 必填且非空：`✨ feat: 说明` 这种没有 scope 的写法会被 C7 拦下。
- 只允许小写字母、数字、`.`、`_`、`-`；出现大写、空格、中文都会被判不合规。
- 写模块名，不要拿它写流水账：`weekly`、`misc`、`tmp`、`batch2` 这类词让日志失去检索价值。
  一次改多个模块时选最主要的那个，其余放在 PR 描述里说。
- 本仓库的常见取值：`ci`（门禁与 workflow）、`summary`（摘要生成）、`logger`、
  `deps`（依赖同步）、`diy`（diy 脚本）、`compile`（编译）、`readme`、`cache`（缓存与产物）。

##### 长度与标点

- 标题里 `<type>(<scope>): <说明>` 这一段不超过 72 字符，按**字符**计（不是字节），开头的 emoji 不计入。
- 说明末尾不加句末标点。`git log --oneline` 与 GitHub 的提交列表都会把单行截断，
  一个句号就少一个字的信息，截断点也更容易落在标点后面显得突兀。

##### 好 / 坏对照

| 写法                                                                                                                                          | 判定        | 原因                              |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------- |
| `✨ feat(ci): 给 pr-guard 增加 C7`                                                                                                            | ✅ 合规     | 四部分齐全，scope 小写，总长合规  |
| `✨ feat: 给 pr-guard 增加 C7`                                                                                                                | ❌ C7 拦下  | 缺 scope（scope 必填非空）        |
| `✨ feat(CI): 给 pr-guard 增加 C7`                                                                                                            | ❌ C7 拦下  | scope 含大写字母                  |
| `✨ feat(编译): 调整编译参数`                                                                                                                 | ❌ C7 拦下  | scope 含中文                      |
| `🐞 fix(summary): 修正生成时间新鲜度判断在跨时区与夏令时切换时给出错误结论的边界情况并补上对应的回归测试用例、注释说明与失败时的自助修复提示` | ❌ C7 拦下  | 标题正文 75 字符，超过 72 上限    |
| `📃 docs(readme): 更新安装步骤。`                                                                                                             | ⚠️ 不合约定 | 结尾带句号；C7 不拦，但不要这么写 |

##### C7 不合规会挡住 PR

C7 是硬性门禁：标题不合规 `pr-guard` 就是红的，PR 合不进去。自助修复：

```bash
git commit --amend              # 只修最后一条：改标题，保存退出
git log -1 --format=%B          # 确认改对了再推
git push --force-with-lease     # 同一条分支上用它，不要用 -f
```

```bash
git rebase -i origin/main       # 批量改写：把要改的提交标成 reword
```

> **改完标题必须回头补摘要。** 改写提交会改变 head SHA，而摘要里记录的「提交」
> 必须等于 PR 的 head SHA（P8，见[摘要与溯源](#-摘要与溯源)）。只改提交不更新摘要，
> 结果就是 C7 刚绿、P8 立刻红。

所以修复的完整顺序是：改标题 → `--force-with-lease` 推上去 → `bash scripts/ci/generate-summary.sh` → 把新摘要**整段替换**进 PR 描述。最后一步只改 PR
描述，不产生新提交，顺序见[第 6 步](#第-6-步生成运行摘要logssummarymd)。

##### 哪些提交不看 C7（豁免）

- GitHub 生成的 `Merge pull request ...` / `Merge branch ...`：标题由平台生成，作者无从改写；
- `Revert "..."`：`git revert` 自动生成的标题，格式固定且带引号；
- `fixup!` / `squash!`：`git commit --fixup` 的中间产物，最终会被 autosquash 折叠掉；
- `Initial commit`：仓库第一个提交，早于任何约定；
- 作者或提交者邮箱含 `dependabot` 的提交：机器人按上游版本号生成标题，改不了也不该改。

豁免覆盖的只是「不由人手写」的那几类；它们照样进 `git log`，所以自己手写的提交请照格式来。

### 第 6 步：生成运行摘要（`logs/summary.md`）

**顺序很关键：摘要必须在【最后一次提交之后】生成。**摘要里记录的是当时的 HEAD，而门禁要求它与 PR 的 head SHA 一致（P8，见[摘要与溯源](#-摘要与溯源)）。

正确顺序：

1. 先把所有代码改动提交并推送（上一步），之后不再产生任何新提交；
2. 再运行下面的命令生成摘要；
3. 只改 PR 描述，把摘要粘进托管块；
4. 粘完不要再提交。

```bash
bash scripts/ci/generate-summary.sh
```

不带参数按 `build` 生成；也可以显式指定 `build` / `update-checker` / `dependency-auditor` / `syntax-linter`
场景名（脚本的第一个参数）。脚本会打印到终端并**覆盖写**一份 `logs/summary.md`，这份文件就是要复制的源文本。

跑一次完整构建同样会自动产出这份摘要，不需要手工再补：

```bash
bash scripts/build/build.sh all
```

**P8 红了怎么办**：重新运行 `bash scripts/ci/generate-summary.sh`，把新摘要**整段替换**进 PR 描述，**不要再提交**。先写摘要再提交、或者粘完摘要又提交了一次，head SHA
就变了，P8 必红——这是新门禁最容易踩的坑。

注意：**不要** `git add` 这个文件。`logs/` 被整目录忽略，摘要也不该入库——门禁读的是 PR 描述，不是仓库里的文件，强行加进来会被 C5 拦下。

### 第 7 步：开 PR、粘贴摘要并等门禁

PR 必须指向 `main`。仓库带了 PR 模板（`.github/pull_request_template.md`），新建 PR 时描述初稿里**已经写好** `build-summary` 托管块的 begin/end 标记：把第
6 步生成的 `logs/summary.md` 全文粘在两个标记之间——标记之间原本就是空白的，直接粘贴即可，不需要删任何东西。

描述里同时写清三件事：改了什么、为什么、怎么验证。Draft PR 也会跑检查，但只有非 Draft 才会被真正合并。

门禁全绿后由维护者合并（当前合并方式为 merge commit，保留 PR 边界）。合并后 GitHub 会自动删除 head 分支。

## 🔒 摘要与溯源

运行摘要**不提交进仓库**：它留在本地 `logs/`（整目录被 `.gitignore` 忽略），贡献者把生成好的全文粘贴到 **PR 描述**的托管块里，流水线校验的也是 PR 描述。

为什么这样设计：CI 无法在你的机器上重跑一次完整构建，它拿到的只有这段文字。把摘要放进 PR 描述，它就和这次 PR 一起归档、可搜索、可评审，而不必为了"让门禁读到文件"往仓库里塞一份构建产物。

### PR 描述里的托管块

首尾各一行标记，中间放 `logs/summary.md` 的全文。标记之间**保持空白**：模板里那一段就是两个相邻的标记，粘贴时直接把全文贴进去，不需要删除任何东西。

```text
<!-- 把本地生成的 logs/summary.md 全文粘在下面两个标记之间 -->

<!-- build-summary:begin -->

<!-- build-summary:end -->
```

五条规则：

1. **恰好一组** begin/end 标记：出现第二组即判失败；
2. 块内容上限 **60000 字符**：只贴摘要本身，不要把整份构建日志塞进来；
3. 块内必须含 `### 🔒 摘要溯源` 小节：十个字段齐全，并带变更文件清单围栏块；
4. 空白块是正常的初始状态：还没粘贴时门禁会直接告诉你"块里没有内容"，
   而不是把它当成已填好再报一串"缺少某键"；
5. 标记之外的文字不影响判定——提示写在标记之外，贴摘要时不会碰到，也就不存在漏删。

### 溯源块的十个字段

摘要的**最后一个章节**必须是溯源块，形如（下面是结构示意，实际值由脚本填写）：

```text
### 🔒 摘要溯源

<!-- dsh-provenance:begin -->

| 项 | 值 |
| --- | --- |
| 格式版本 | 2 |
| 仓库 | OWNER/REPO |
| 分支 | feat/my-change |
| 提交 | 40 位十六进制 HEAD sha |
| 生成时间 | 2026-01-01T00:00:00Z |
| 变更基准 | origin/main |
| 变更文件数 | 3 |
| 变更文件指纹 | sha256:<64 位小写十六进制> |
| 应编产物数 | 398 |
| 未产出数 | 0 |

<!-- dsh-provenance:end -->
```

十个字段的含义与约束：

| 字段         | 含义                                                          | 约束                                                                                 |
| ------------ | ------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 格式版本     | 溯源块的结构版本                                              | 固定为 `2`                                                                           |
| 仓库         | `OWNER/REPO`                                                  | 必须与本 PR 的检出仓库一致（`PR_HEAD_REPO_FULL_NAME`，为空时用 `PR_REPO_FULL_NAME`） |
| 分支         | 摘要生成时所在分支                                            | 必须等于 PR 的 head 分支名（`PR_HEAD_REF`）                                          |
| 提交         | HEAD 的完整 sha                                               | 40 位小写十六进制，不能写短 sha、不能写分支名；且必须等于本 PR 的 head SHA           |
| 生成时间     | UTC 时间戳                                                    | 形如 `YYYY-MM-DDTHH:MM:SSZ`                                                          |
| 变更基准     | 比较用的基准引用                                              | `origin/main` 或 `main`；解析不到时写 `none`                                         |
| 变更文件数   | 清单里的路径条数                                              | 必须与下面清单的行数一致                                                             |
| 变更文件指纹 | 清单的 sha256                                                 | `sha256:` 加 64 位小写十六进制                                                       |
| 应编产物数   | 本次 `.config` 里取值为 `y` 或 `m` 的 `CONFIG_PACKAGE_*` 项数 | 整数或小写 `unknown`；非 build 模式、或没读到 `.config` 时写 `unknown`               |
| 未产出数     | 上述项里没有产出对应产物的数量（含引导固件）                  | 整数或小写 `unknown`，情形同上；C8 要求必须为 `0`                                    |

标记之后的 `text` 代码块里是**变更路径清单**：一行一个路径，`LC_ALL=C` 排序，**排除 `logs/summary.md` 自身**（否则摘要会把自己算进指纹，每次重写都变）。

### 指纹怎么算

两侧必须完全一致，逐字节可复现：

```text
输入 = 变更路径清单（LC_ALL=C 排序，排除 logs/summary.md）
字节 = 每条路径后接一个换行符（清单为空时为空字节串）
输出 = "sha256:" + sha256(字节)
```

本地复算（基准从 `origin/main` 起算）：

```bash
base=$(git merge-base HEAD origin/main)
git diff --name-only "$base" HEAD | LC_ALL=C sort | grep -vx 'logs/summary.md' | sha256sum
```

### 三条要求

1. **摘要必须由本 PR 产出**：块内「提交」必须等于**本 PR 的 head SHA**（40 位完整 sha）。
   因此在**最后一次**提交之后重新生成摘要，再复制粘贴进 PR 描述；
2. **不要复制别的分支的摘要**：块内「变更文件指纹」必须与本 PR 的真实变更相符，
   「仓库」「分支」「提交」三个字段也会各自与 PR 对账——复制的摘要一定对不上；
3. **摘要不入库**：`logs/` 被 `.gitignore` 整目录忽略，这是刻意的，
   不需要为 `logs/summary.md` 开任何例外。`git add logs/summary.md` 报"被忽略"是正常现象， 不要去 `-f` 强行加进来。

## ✅ CI 门禁：pr-guard

`pr-guard` 是分支保护里的核心必需检查（与语法门禁的三条并列）。它的输出协议是固定的：逐条打印 `PASS <编号> <说明>` 或 `FAIL <编号> <说明>`，最后一行是`RESULT PASS` 或
`RESULT FAIL`，只有 `RESULT PASS` 时退出码为 0；设了 `GITHUB_STEP_SUMMARY` 时还会追加一张检查结果表，失败项同时以`::error title=<编号>::` 形式发 GitHub
annotation。

下表的编号是**稳定 ID**，你在日志和 annotation 里看到的就是它们。本表与实现侧的编号集合完全一致：C1 / C2 / C3 / C4 / C5 / C6 / C7 / C8 + P1 ~
P8、P10、P11。**P9 已被删除**，所以编号从 P8 直接跳到 P10——这是刻意的「删除而非占用」，不要据顺序推断其它编号。

| 编号 | 检查什么                                                                                                             | 失败那行长什么样 |
| ---- | -------------------------------------------------------------------------------------------------------------------- | ---------------- |
| C1   | 分支来源与命名：head 不能是 main，名字必须匹配 `<type>/<简短描述>`，type 取上文十种之一                              | `FAIL C1 ...`    |
| C2   | 来源仓库：PR 的头仓库必须与目标仓库相同（默认不接受 fork PR，`ALLOW_FORK_PR=1` 才放行；本地运行读不到仓库名时跳过）  | `FAIL C2 ...`    |
| C3   | PR 描述含托管块：必须有一组 `build-summary` 标记，且块内不是空的                                                     | `FAIL C3 ...`    |
| C4   | 变更范围：文件数不超过上限，且与摘要记录的「变更文件数」一致                                                         | `FAIL C4 ...`    |
| C5   | 禁改路径：私钥与证书等不得出现在变更里；`logs/` 下任何路径一律禁止入库（含 `logs/summary.md`）。`.config` 允许改动   | `FAIL C5 ...`    |
| C6   | 摘要与变更一致：不能是"只换一份旧摘要"的空 PR                                                                        | `FAIL C6 ...`    |
| C7   | 提交信息格式：`<emoji> <type>(<scope>): <说明>`，scope 小写、emoji 之后那段不超过 72 字符（merge/dependabot 等豁免） | `FAIL C7 ...`    |
| C8   | 编译完整性：溯源块「未产出数」必须为 0；`unknown` / 缺失 / 应编为 0 一律失败——没有证据不等于合格                     | `FAIL C8 ...`    |
| P1   | 托管块非空：块内确实是摘要内容（模板里的块是空白的，未粘贴就会被拦下）                                               | `FAIL P1 ...`    |
| P2   | 标记结构：begin/end 各恰好一次、顺序正确                                                                             | `FAIL P2 ...`    |
| P3   | 十个字段齐全且值非空；格式版本为 2、应编产物数/未产出数为整数或 unknown、提交是 40 位小写 hex、生成时间可解析        | `FAIL P3 ...`    |
| P4   | 「仓库」字段 == 本 PR 的检出仓库（`PR_HEAD_REPO_FULL_NAME`，为空时用 `PR_REPO_FULL_NAME`）                           | `FAIL P4 ...`    |
| P5   | 「分支」字段 == PR 的 head 分支名（`PR_HEAD_REF`）                                                                   | `FAIL P5 ...`    |
| P6   | 块内自洽：变更文件数 == 清单行数，重算指纹 == 「变更文件指纹」                                                       | `FAIL P6 ...`    |
| P7   | 指纹与本 PR 的真实变更相符                                                                                           | `FAIL P7 ...`    |
| P8   | 块内「提交」== 本 PR 的 head SHA                                                                                     | `FAIL P8 ...`    |
| P10  | 生成时间新鲜：不来自未来、不在 30 天前、不早于 HEAD 提交时间 6 小时                                                  | `FAIL P10 ...`   |
| P11  | 摘要正文含「结论 / 运行信息 / 步骤状态」三节                                                                         | `FAIL P11 ...`   |

### 编译证据豁免（不产固件的 PR）

C3 / C6 / C8 与 P1 ~ P11 断言的是「产物内容可追溯」。当一次改动根本不进入固件时，这句话没有对象，
门禁不该因此变红——否则 Dependabot 的 action 升级、以及一切只改 CI/文档的 PR 都会被永久挡住。
判据有两条，任一成立即免掉上述检查；**C1 / C2 / C4 的规模阈值 / C5 / C7 在任何豁免下都照常判定**：

| 通道     | 触发条件                                                                                                                           | 人工成本       |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| 产物无关 | 全部变更落在 `.github/`、`scripts/ci/`、`.devcontainer/`、根目录文档，以及 `.markdownlint-cli2.yaml` / `.prettierrc.json` 等配置内 | 零             |
| 显式放行 | PR 带 `skip-compile` 标签                                                                                                          | 每个 PR 贴一次 |

**判据是「改了哪些路径」而不是「谁开的 PR」**：路径是变更本身的事实，而分支名与作者字段都可以近似伪造。
`dependabot/` 前缀的分支只豁免 C1（分支名由机器人决定，人改不了），不豁免编译证据。

放行留痕：带 `skip-compile` 的 PR 会在日志与 step summary 里打印「PR 带标签 skip-compile，由维护者显式放行编译证据」，
事后可查是谁在哪个 PR 上放了行。反过来，改了 `scripts/build/`、`scripts/inputs/`、`files/`、
`immortalwrt/` 等产物路径的 PR 不在豁免范围内——这些改动必须附带构建摘要。

#### 哪些 PR 会自动带 skip-compile

`dependency-auditor` 每周巡检后自动开的版本 bump PR（`chore/upx-bump-*`、`chore/dae-bump-*`、
`chore/fan2go-bump-*`）改的是 `scripts/build/`、`scripts/inputs/` 里的版本常量，**属于产物路径**，
但它们由机器人创建、PR 描述无人可改，产不出构建摘要。因此该 workflow 在 `gh pr create` 时就带上
`skip-compile`（标签由同一个 job 里的 Ensure 步骤幂等创建，缺标签会让 job 直接红在创建那一步）。

这是一笔明账：**这些版本 bump 合入时不经过构建验证**，只过 C1/C2/C4/C5/C7 与三条语法门禁。
要收回这条通道，删掉 `dependency-auditor.yml` 里的 `--label` 与 Ensure 步骤即可——代价是这些 PR
从此需要人工跑构建并贴摘要。

`dependabot` 的 action 升级 PR **不需要**这个标签：它只改 `.github/`，走「产物无关」通道自动豁免。

### 并行运行的语法门禁

`syntax-linter` 的 `shellcheck` / `actionlint` / `markdownlint` 三条与`pr-guard` 并列，都挂在分支保护的必需检查里（strict 模式为
false，即不要求你在合并前把分支 rebase 到最新 main）。任一失败都说明这次改动不该合入。

## 📏 变更范围限制

默认上限（C4 校验）：

| 项             | 上限     | 为什么                                                                           |
| -------------- | -------- | -------------------------------------------------------------------------------- |
| 变更文件数     | 60 个    | 超过这个规模，评审只能"看着像对的就点通过"                                       |
| 单文件新增行数 | 1500 行  | 一次塞进上千行的改动必然缺少上下文，回滚代价也最高                               |
| `.config`      | 允许改动 | 它是所有人的固件输入，改一行就改变所有构建产物，因此必须带编译证据并在 PR 里说明 |
| 私钥、证书     | 禁止提交 | `keys/*.pem` 已被 `.gitignore` 忽略，但 CI 仍会拦下"看起来像私钥"的新增内容      |

确实需要超限时，不要想办法绕过门禁：拆成多条 PR，或在 PR 描述里说明为什么必须一次合入，由维护者决定。门禁的存在是为了让例外变成一次显式的决定，而不是没人注意到的默认。

另有一条不属于"上限"的硬规则，由 C5 校验：**不要把 `logs/` 下的任何文件提交进 PR（含 `logs/summary.md`）。** 仓库整目录忽略 `logs/`，强行`git add -f` 会被 C5 拦下；门禁读的是
PR 描述，不是仓库里的文件。若已经误提交，用下面这条命令把它从变更里移除（本地文件保留）：

```bash
git rm --cached logs/summary.md
```

## 🧹 合并后自动删除分支

仓库开启了 `delete_branch_on_merge`：PR 合并后，它的 head 分支由 GitHub 自动删除。为什么开：合入后那条分支就是 main 的重复内容，留着只会让`git fetch`
后面挂一串"不知道还有没有用"的远端分支，久而久之没人敢清理。

验证方式（两种，任选）：

```bash
# 方式一：读仓库开关，应输出 true
gh api repos/OWNER/REPO --jq '.delete_branch_on_merge'
```

方式二：打开仓库 Settings → General → Pull Requests，确认 "Automatically delete head branches" 已勾选。

注意两点：

- 来自 fork 的 PR，删除的是 **fork 里**的分支，不是本仓库的分支；
- 合并后才发现还想继续用那条分支时，从合并点重新切一条即可，历史不会丢。

## 🧯 常见失败与自助修复

以下按编号给出"你会看到什么 → 为什么 → 怎么修"。改代码类的失败按提示 push 到同一条分支即可；摘要类的失败只需编辑 **PR 描述**（不产生新提交）。两者保存后 CI 都会自动重跑，不需要关掉 PR 重开。

### C1 分支名或来源不合规

**看到**：`FAIL C1`，说明里提到分支名不匹配或不允许从 main 发起。

**为什么**：C1 校验 PR 的 head 分支。用 main 当 head 等于"自己的改动自己批准"，而命名不规范会让分支列表在几十条之后彻底不可读。

**怎么修**：把分支改名后推送，并在 PR 里把 base/head 换成新名字：

```bash
git branch -m feat/my-change            # 本地改名
git push -u origin feat/my-change       # 推送新名字
git push origin --delete old-name       # 删除远端旧名字
```

### C3 PR 描述里没有托管块

**看到**：`FAIL C3`，说明里提到找不到 `build-summary:begin` 标记，或块内为空。

**为什么**：门禁读的是 **PR 描述**，不是仓库里的文件。摘要只留在本地 `logs/` 里、没粘进描述，等于没有提供。

**怎么修**：先在**最后一次**提交之后重新生成，再把全文粘进描述：

```bash
bash scripts/ci/generate-summary.sh
# 复制 logs/summary.md 全文 → PR 页面点 Edit → 粘到 build-summary 标记之间 → 保存
```

保存描述即触发门禁重跑，不需要新提交。

### C4 变更范围超限

**看到**：`FAIL C4`，说明里给出实际文件数或与摘要记录的数字不一致。

**为什么**：见[变更范围限制](#-变更范围限制)。

**怎么修**：优先拆分 PR；若确实必须一次合入（例如批量改名、上游大版本同步），在 PR 描述里写明原因，请维护者确认后处理。不要用"把文件挪到子目录"之类的方式躲开计数。

### C5 变更里出现禁改路径

**看到**：`FAIL C5`，说明里点名了某个路径，例如 `logs/` 下的文件、`*.pem`、私钥。

**为什么**：`logs/` 被整目录忽略，强行 `git add -f` 会让摘要进历史，而门禁读的是 PR 描述，两边必然脱节；私钥与证书一旦进了历史，把文件移除也不等于没泄露。

**怎么修**：把这类文件移出 PR。

> **`.config` 不在这一条里**。它是被 git 跟踪的固件输入，换包只能靠改它，所以 `C5` 放行。
> 但它也不在「产物无关路径」白名单里，**改它会改变构建产物**，因此照样要带编译证据
> （`C3`/`C6`/`C8` 正常判定），并按下文要求在第 3 步于 PR 描述里单独说明理由。

### C6 只改了摘要本身

**看到**：`FAIL C6`，说明里提到这个 PR 的变更几乎只有摘要。

**为什么**：门禁要防的是"拿一份旧摘要配一个空 PR"——那样摘要证明不了任何一次真实改动。

**怎么修**：把真正的代码或文档改动一起推上来；若这次确实只该改摘要，在描述里说明理由，由维护者处理。

### C7 提交信息格式不合规

**看到**：`FAIL C7`，说明里点名了标题哪一部分不合规（缺 emoji、缺 scope、scope 含大写、`type(scope): 说明` 那段超过 72 字符等）。

**为什么**：提交信息是唯一不进评审视野的信息渠道——`git log --oneline` 扫历史、Release 变更日志、二分定位都只靠这一行。格式不统一，检索就失效，"这次改动是什么性质"只能点开 diff 才知道。

**怎么修**：改标题，不用改代码。本地改完用 `--force-with-lease` 推回同一条分支：

```bash
git commit --amend              # 只改最后一条
git log -1 --format=%B          # 先确认标题对了
git push --force-with-lease
```

要改的是更早的提交，用交互式 rebase 把它们标成 `reword`：

```bash
git rebase -i origin/main
```

**别忘 P8**：改写提交会改变 head SHA，摘要里的「提交」字段必须等于 PR 的 head SHA。只删改标题而不重新生成摘要，C7 过了 P8 必红。完整顺序是：

```bash
bash scripts/ci/generate-summary.sh    # 在最后一次提交之后再跑
# 复制 logs/summary.md 全文 → PR 描述 Edit → 整段替换旧摘要 → 保存
```

**不用管的情况**：`Merge pull request ...` / `Merge branch ...`、`Revert "..."`、`fixup!` /
`squash!`、`Initial commit`，以及作者或提交者邮箱含 `dependabot` 的提交——这些标题不由人手写，C7 直接跳过。范围与理由见[提交信息格式](#提交信息格式c7-强制校验)。

### C8 未产出数不为 0 或缺少编译数据

**看到**：`FAIL C8`，说明里给出「应编产物数 / 未产出数」的实际取值，或指出摘要缺少编译完整性数据。

**为什么**：「未产出数」是这次选中的项里有几个没被编出产物。`unknown`、键缺失、应编产物数为
0，三者和"确实漏编"同判失败——没有证据不等于合格，否则一次没编译过的流水线就能靠默认值拿到满分。这条门禁的意图是：**缺包在固件里表现为功能缺失，用户装不上也定位不到根因，比构建直接失败更难发现，所以必须在合入前拦住。**

**怎么修**，看说明里的取值分三种：

- **未产出 > 0**：摘要里有「选中但未产出产物的项」折叠块（引导固件会额外标注），
  照着它定位缺哪些包，修掉后重新构建并重新生成摘要；
- **unknown**：本地摘要没有完整的构建数据（非 build 模式、没读到 `.config`，
  或缺少 target 包索引进快照），要在**有完整构建产物的环境**里重新生成， 例如下载该 PR 的构建 artifact 后在 head 提交上生成；
- **应编产物数为 0**：等于一次编译都没被证明过，同样按缺数据修，不要当成"全部产出"。

> [!WARNING]
>
> 本地直接跑 `bash scripts/ci/generate-summary.sh` 时，
> `immortalwrt/bin/targets/*/*/packages/index.json` 往往不存在——
> CI 的 Organize files 步骤会 `rm -rf packages`，本地也没设 `TARGET_PACKAGE_INDEX_FILE` 快照。
> 少了这份索引，target 专属包（kmod 等）会被一律算成未产出，
> 摘要里就会带一个很大的未产出数，贴到 PR 上必然被 C8 拦下。
> **以 CI 构建产出的摘要为准，或下载构建 artifact 后在本分支重新生成。**

### P2 标记结构不对

**看到**：`FAIL P2`，说明里提到标记缺失、顺序颠倒，或出现了第二组。

**为什么**：CI 取第一组 `begin` … `end` 之间的内容；第二组会让它无法判断哪一段才是摘要。

**怎么修**：只保留一组标记，中间只放一次摘要全文。

### P3 十个字段缺失或格式不对

**看到**：`FAIL P3`，说明里点名某个字段缺失、为空，或格式不合要求。

**为什么**：字段由脚本生成，"提交"必须是 40 位小写 hex、"生成时间"必须是`YYYY-MM-DDTHH:MM:SSZ`——手改最容易改坏的就是这两个。另两键「应编产物数 / 未产出数」只接受整数或小写
`unknown`：写成非整数会让这一条报错，写 `unknown` 则 P3 放过、交给 [C8](#c8-未产出数不为-0-或缺少编译数据) 判"无法证明"。

**怎么修**：重新生成后**整段替换**，不要逐字修补：

```bash
bash scripts/ci/generate-summary.sh
```

### P6 清单与指纹不自洽

**看到**：`FAIL P6`，说明里提到「变更文件数」与清单行数不同，或按清单重算的指纹与「变更文件指纹」不同。

**为什么**：清单与指纹是同一次计算的产物，只改其中一项就会不自洽。

**怎么修**：重新生成后整段替换，别只改数字。

### P7 指纹与本 PR 真实变更不符

**看到**：`FAIL P7`，说明里同时给出「块里的指纹」与「按本 PR 真实变更算出的指纹」。

**为什么**：典型是"复制了别的分支的摘要"，或者"生成摘要之后又加了文件"。

**怎么修**：在**最后一次**提交之后重新生成摘要，重新粘贴。本地复算：

```bash
base=$(git merge-base HEAD origin/main)
git diff --name-only "$base" HEAD | LC_ALL=C sort | grep -vx 'logs/summary.md' | sha256sum
```

### P8 块内提交与 PR head 不一致

**看到**：`FAIL P8`，块内「提交」不是本 PR 的 head SHA。

**为什么**：这是"这份摘要属于本 PR"的唯一硬证明。最常见的两个原因：摘要在提交之前生成（记录的是旧提交），或者复制了别处的摘要。

**怎么修**：在最后一次提交之后重新生成，再把新内容整段替换进 PR 描述：

```bash
bash scripts/ci/generate-summary.sh
# 整段替换 PR 描述托管块内的内容
```

### P10 生成时间不新鲜

**看到**：`FAIL P10`，说明里提到时间在未来、超过 30 天，或早于 HEAD 提交时间 6 小时以上。

**为什么**：这类失败基本都是"从别处复制来的摘要"——时间戳暴露了它不是这次生成的。

**怎么修**：在本分支重新生成摘要后重新粘贴。不要手工改时间戳，改了也过不了 P3 的格式校验。

### 语法门禁红

**看到**：`shellcheck` / `actionlint` / `markdownlint` 之一失败。

**怎么修**：按第 4 步在同一台机器上跑同一组命令，输出可逐条定位到行列。注意 shellcheck 是 `-x`（跟随 `source`），本仓库脚本大多会 source `scripts/libs/` 下的库，不加 `-x`
会报出一堆假问题。

## 🆘 直接推送被拒之后

`git push origin main` 被拒，通常长这样：

```text
! [remote rejected] main -> main (protected branch hook declined)
error: failed to push some refs to 'github.com:OWNER/REPO.git'
```

这不是故障，是分支保护在按设计工作。**不要**用 `--force` 试第二次：强推同样被 `allow_force_pushes=false` 拦下，而且会让人误以为"多试几次就能过"。

按情况二选一：

情况一：提交还在本地，没推上去（上面的报错就属于这种）——把提交挪到新分支再推：

```bash
git switch -c feat/my-change     # 带着刚做好的提交一起切过去
git push -u origin feat/my-change
git switch main
git reset --keep origin/main     # 让本地 main 回到远端状态；--keep 会保留未提交的改动
```

`--keep` 而不是 `--hard`：前者在遇到冲突时会中止而不是丢弃内容，未提交的工作不会凭空消失。

情况二：已经误推到 main 了（例如保护规则当时还没生效）——不要自己 revert 了事，先开 issue 说明情况，由维护者决定是回退这次合并还是补一个修复 PR。main 上的历史是可复现构建的唯一依据，改法必须是显式的决定。

## 🛠 维护者：分支保护本身也是代码

分支保护不靠记忆、不靠在网页上点，而是由脚本声明并幂等执行：

```bash
bash scripts/ci/setup-branch-protection.sh --dry-run   # 先看会改什么，不发写请求
bash scripts/ci/setup-branch-protection.sh             # 真正应用
```

脚本的两条设计原则值得知道：

1. **先 GET 再决定 PUT**：PUT 是整体覆盖语义，无条件执行会静默清掉别处新增的保护项；
2. **contexts 取并集**：任何 PUT 都不得让既有必需检查消失——把 `pr-guard`
   写死成唯一 context，第一次运行就会把三条语法门禁从必需列表里摘掉，而没有任何报错。

**改必需检查的名字时，顺序不能颠倒**：并集语义意味着脚本只会加不会减，所以先把改名后的 workflow
合进 main，再运行本脚本。反过来做（先跑脚本让远端要求 `pr-guard`，而 main 上还没有这个 job）会让
所有 PR 等一个永不上报的 context：每个 PR 都停在 "Expected — Waiting for status to be reported"，
连修复用的那个 PR 也合并不了，只能手工 `gh api` 改写 contexts 或临时降级保护。

它同样解释了两个容易被误解的设置：`enforce_admins=true` 封死的是"绕过 PR 直推"，不是"仓库再也改不了"（修 CI 的 PR 用修复后的 workflow
版本运行，能自己把自己救回来）；`required_approving_review_count=0` 则是因为单维护者仓库里"要求批准 + 强制管理员"会形成死锁——GitHub 不允许批准自己的 PR。

## 📚 相关文档

- [README.md](README.md)：固件能力、快速开始、构建系统概览
- [scripts/README.md](scripts/README.md)：构建脚本与 CI 脚本的逐个说明
- [LICENSE](LICENSE)：许可证条款
- [.github/pull_request_template.md](.github/pull_request_template.md)：新建 PR 时的描述初稿与托管块
- `.markdownlint-cli2.yaml`：markdown 规则集与每条调整的理由
- `.github/workflows/syntax-linter.yml`：语法门禁的三条检查与工具版本钉法
