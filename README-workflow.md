> 🛠 本文件说明工作流本身；固件功能、刷机、签名密钥等面向使用者的说明见 [仓库根 README](README.md)。

# 工作流说明

本仓库的 GitHub Actions 工作流：构建 ImmortalWrt（`mediatek/filogic`，BPI-R4）固件、跑发布前的
包校验门禁，并把产物发布到 Releases 与 Pages。

## 用法

- 本仓库已是可直接使用的构建仓库，不需要「使用模板」生成副本；fork 后要先自建签名密钥，
  见根 README 的「软件包签名密钥 → 移植（fork 本仓库）」。
- 源码为 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)，目标机型与包选择由仓库根的 `.config`、
  `files/`、`libs/` 决定，不需要另行生成 `.config` 文件。
- 在 Actions 页面选择 `ImmortalWrt Builder`，点 `Run workflow` 手动触发；日常由 `Update Checker`
  每 3 天探测上游新提交后经 `repository_dispatch` 自动触发。
- 构建完成后在该次运行页面右上角的 `Artifacts` 下载归档，固件整包同时发布到
  [Releases](https://github.com/Shuery-Shuai/ImmortalWrt-BPI-R4-Firmware/releases)。

## 提示

- 生成 `.config` 与编译固件都很耗时。
- 决定自建之前，可以先[在 GitHub 搜索 `Actions-Openwrt`](https://github.com/search?q=Actions-openwrt)，看看是否已有人构建出满足需求的固件。
- 在仓库简介里写清固件的架构与已装软件包，能省下别人核实的时间。

## 包校验门禁

The build job runs `bash scripts/ci/generate-summary.sh verify` after the firmware artifact is
uploaded and **before** the release tag is generated. It compares both config files — the
hand-written repository root `.config` and the expanded `immortalwrt/.config` — and fails when any
of the three checks fails:

- **Compilation check** — every package selected in the expanded `immortalwrt/.config` (after the
  variant-switch normalisation) must have produced an artifact: an `index.json` entry under
  `bin/packages/*/*/` or `bin/targets/*/*/packages/`, or a bootloader artifact for
  `u-boot-*` / `trusted-firmware-a-*`.
- **Silently-dropped check** — every symbol selected in the repository root `.config` must still be
  present in `immortalwrt/.config`, even as `# ... is not set`. A symbol that disappears entirely
  was dropped by `make defconfig` rather than honoured, which is exactly how a custom package
  silently never gets built.
- **Reopened check** — a symbol you explicitly switched off in the root `.config`
  (`# CONFIG_PACKAGE_x is not set`) must stay off in `immortalwrt/.config`; if it comes back as
  `=y` or `=m` (dropbear and uhttpd are the ones that matter here) the step fails. Note that a
  plain comment (`#CONFIG_PACKAGE_x=y`, no space after `#`) is ignored by kconfig and therefore
  by the gate — it is neither "selected" nor "disabled".

Because the gate runs before the release tag, a failure fails the job and both the GitHub release
and the GitHub Pages deployment are skipped — while the already-uploaded firmware artifact stays
downloadable for inspection. `$GITHUB_OUTPUT` carries one count per check
(`artifact_missing_count`, `silent_drop_count`, `reopened_count`) plus their sum `missing_count`.
Set `VERIFY_CONFIG_SYMBOLS=false` in the step environment to disable the two config-comparison
checks; the compilation check always runs.

## 致谢

- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [Lean's OpenWrt](https://github.com/coolsnowwolf/lede)
- [tmate](https://github.com/tmate-io/tmate)
- [mxschmitt/action-tmate](https://github.com/mxschmitt/action-tmate)
- [csexton/debugger-action](https://github.com/csexton/debugger-action)
- [Cowtransfer](https://cowtransfer.com)
- [WeTransfer](https://wetransfer.com/)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [ActionsRML/delete-workflow-runs](https://github.com/ActionsRML/delete-workflow-runs)
- [dev-drprasad/delete-older-releases](https://github.com/dev-drprasad/delete-older-releases)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)

## 许可证

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
