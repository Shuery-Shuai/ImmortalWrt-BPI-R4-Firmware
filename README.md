# ImmortalWrt BPI-R4 固件构建项目

本项目用于构建香蕉派 BPI-R4 路由器的 ImmortalWrt 固件。

## 项目特点

- 基于 ImmortalWrt 最新源码构建
- 使用测试版内核
- 极简固件设计，仅包含基础组件

> [!TIP]
>
> - 首次安装后建议修改默认密码
> - 建议定期备份配置文件
> - 如遇网络问题，可尝试重置防火墙设置

- 支持固件更新时自动恢复已安装软件包

> [!IMPORTANT]
>
> - 使用 qbittorrent-original 时，需要将 `/etc/qbittorrent` 目录添加至系统升级保存列表：
>
>   编辑 `/etc/sysupgrade.conf` 添加以下内容：
>
>   ```conf
>   /etc/qbittorrent/
>   ```

- 支持自动更新

> [!WARNING]
>
> - 手动更新固件时，请在更新选项中勾选"备份已安装软件包"
> - 更新完成后系统将自动恢复之前安装的软件包
> - 软件包恢复过程中请勿断电或重启

- 针对 BPI-R4 硬件优化的内核配置

## 固件内置组件

| 分类     | 软件包                | 说明           |
| -------- | --------------------- | -------------- |
| 界面相关 | luci-theme-argon      | Argon 主题     |
|          | luci-app-argon-config | Argon 主题配置 |
| 网络组件 | luci-nginx            | Nginx 前端引擎 |
|          | luci-app-nginx        | Nginx 前端管理 |
| 语言支持 | default-settings-chn  | 中文默认设置包 |

## 支持安装的扩展包

| 分类     | 软件包                        | 说明                    |
| -------- | ----------------------------- | ----------------------- |
| 系统管理 | luci-app-diskman              | 磁盘管理                |
|          | luci-app-easyupdate           | 系统简易更新            |
|          | luci-app-rtfwupgrade          | 路由器固件更新          |
| 系统工具 | fan2go                        | 风扇控制守护            |
|          | luci-app-fancontrol           | 简易风扇控制            |
|          | luci-app-fanxpert             | 风扇控制                |
|          | zram-swap                     | 内存压缩交换            |
| 网络应用 | luci-app-dae                  | 大鹅网络工具            |
|          | luci-app-lucky                | 大吉内网穿透工具        |
|          | luci-app-openclash            | OpenClash 代理工具      |
|          | dockerd                       | Docker 容器引擎         |
| 下载工具 | luci-app-qbittorrent-original | 原版 qBittorrent 下载器 |
| 多媒体   | ffmpeg                        | 多媒体处理工具          |
| 字体显示 | noto-fonts-cjk                | 中日韩字体              |
|          | noto-fonts-emoji              | Emoji 字体              |

> [!NOTE]
>
> 大部分软件包都不需要另外支持，如果有需要另外支持的软件包，请在 Issues 中提出。

## 软件包签名密钥

固件内置的软件包仓库使用固定的 EC P-256 密钥签名，保证设备在升级固件后仍信任新构建的仓库，不再出现 `UNTRUSTED signature`。

> [!CAUTION]
>
> `private-key.pem` 是包签名的信任根，持有者可以签出被本固件信任的 `.apk`。**切勿提交到仓库、粘贴到 Issue 或随产物分发**。如需轮换密钥，须同时更新 Secret 与 `keys/public-key.pem`，并通知用户重新导入公钥。

| 位置                                 | 说明                                                                                       |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| `keys/public-key.pem`                | 公钥，随仓库提交；构建时写入镜像 `/etc/apk/keys/public-key.pem`，并发布到 Pages 站点根目录 |
| Actions Secret `APK_PRIVATE_KEY_B64` | 私钥（base64），CI 构建时还原到构建目录并校验指纹                                          |
| `keys/private-key.pem`               | 私钥的本地副本，供本地 Docker 构建使用，已被 `.gitignore` 忽略                             |

> [!IMPORTANT]
>
> 在固定密钥启用之前刷入的固件，需要手动导入公钥后才能从本仓库安装软件包：
>
> ```sh
> wget -O /etc/apk/keys/public-key.pem https://pkgs.lssa.fun/immortalwrt/snapshots/public-key.pem
> apk update
> ```
>
> 或者直接刷写一次新固件（镜像内已自带该公钥）。apk 会信任 `/etc/apk/keys/` 下的所有密钥，因此新旧公钥可以共存。

## 许可证

- 本项目脚本采用 MIT 许可证。
- 本项目 Actions 更改自 P3TERX，采用 MIT 许可证。

## 致谢

- 感谢 ImmortalWrt 项目团队的持续贡献。
- 感谢 Banana Pi 社区对 BPI-R4 硬件的支持。
- 感谢 P3TERX 与 sundaqiang 提供的 Actions 工作流模板。
