# ImmortalWrt BPI-R4 固件构建项目

本项目用于构建香蕉派 BPI-R4 路由器的 ImmortalWrt 固件。

## 项目特点

- 基于 ImmortalWrt 最新源码构建
- 使用测试版内核
- 极简固件设计，仅包含基础组件
- 支持固件更新时自动恢复已安装软件包
- 支持自动更新
- 针对 BPI-R4 硬件优化的内核配置

> [!WARNING]
>
> - 手动更新固件时，请在更新选项中勾选"备份已安装软件包"
> - 更新完成后系统将自动恢复之前安装的软件包
> - 软件包恢复过程中请勿断电或重启

> [!IMPORTANT]
>
> - 使用 qbittorrent-original 时，需要将 `/etc/qbittorrent` 目录添加至系统升级保存列表：
>
>   编辑 `/etc/sysupgrade.conf` 添加以下内容：
>
>   ```
>   /etc/qbittorrent/
>   ```

> [!TIP]
>
> - 首次安装后建议修改默认密码
> - 建议定期备份配置文件
> - 如遇网络问题，可尝试重置防火墙设置

## 固件内置组件

| 分类     | 软件包                | 说明           |
| -------- | --------------------- | -------------- |
| 界面相关 | luci-theme-argon      | Argon 主题     |
|          | luci-app-argon-config | Argon 主题配置 |
| 网络组件 | luci-nginx            | Nginx 前端引擎 |
|          | luci-app-nginx        | Nginx 前端管理 |
| 系统管理 | luci-app-diskman      | 磁盘管理       |
|          | luci-app-easyupdate   | 系统简易更新   |

## 支持安装的扩展包

下表列出已预编译或支持从官方仓库安装的软件包：

| 分类     | 软件包                        | 说明                |
| -------- | ----------------------------- | ------------------- |
| 系统工具 | bpi-r4-pwm-fan                | 风扇控制            |
|          | luci-app-fancontrol           | 简易风扇控制        |
| 网络应用 | luci-app-dae                  | 大鹅网络工具        |
|          | luci-app-docker               | Docker 容器管理     |
|          | luci-app-lucky                | 大吉内网穿透工具    |
|          | luci-app-openclash            | OpenClash 代理工具  |
| 存储共享 | luci-app-openlist             | OpenList 文件服务器 |
|          | luci-app-samba4               | 网络共享存储        |
| 下载工具 | luci-app-qbittorrent-original | 原版丘比特下载器    |

> [!NOTE]
>
> 大部分软件包都不需要另外支持，如果有需要另外支持的软件包，请在 Issues 中提出。

## 许可证

本项目采用 GPL-3.0 许可证。

## 致谢

- 感谢 ImmortalWrt 项目团队的持续贡献。
- 感谢 Banana Pi 社区对 BPI-R4 硬件的支持。
