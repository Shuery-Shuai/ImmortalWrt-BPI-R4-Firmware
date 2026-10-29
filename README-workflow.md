**English** | [中文](https://p3terx.com/archives/build-openwrt-with-github-actions.html)

# Actions-OpenWrt

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=LICENSE)](https://github.com/P3TERX/Actions-OpenWrt/blob/master/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Forks&logo=github)

A template for building OpenWrt with GitHub Actions

## Usage

- Click the [Use this template](https://github.com/P3TERX/Actions-OpenWrt/generate) button to create a new repository.
- Generate `.config` files using [Lean's OpenWrt](https://github.com/coolsnowwolf/lede) source code.
  ( You can change it through environment variables in the workflow file. )
- Push `.config` file to the GitHub repository.
- Select `Build OpenWrt` on the Actions page.
- Click the `Run workflow` button.
- When the build is complete, click the `Artifacts` button in the upper right corner of the Actions page
  to download the binaries.

## Tips

- It may take a long time to create a `.config` file and build the OpenWrt firmware.
  Thus, before create repository to build your own firmware, you may check out if others have
  already built it which meet your needs by simply
  [search `Actions-Openwrt` in GitHub](https://github.com/search?q=Actions-openwrt).
- Add some meta info of your built firmware (such as firmware architecture and installed packages)
  to your repository introduction, this will save others' time.

## Package verification gate

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

## Credits

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

## License

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
