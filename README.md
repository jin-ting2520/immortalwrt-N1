# ImmortalWrt N1

面向斐讯 N1 的 ARM64 旁路由固件项目。默认地址为 `192.168.123.2`，主路由网关和 DNS 为 `192.168.123.1`，固件不运行 DHCP 服务。

## 主要内容

- ImmortalWrt `openwrt-24.10`、`openwrt-25.12` 双版本构建
- N1 Amlogic 支持、zram 512 MB、irqbalance、USB 存储和常用管理工具
- 系统工具：CPU 调频（`luci-app-cpufreq`）、断网自动重启（`watchcat`）、ACME 证书管理（`luci-app-acme`）
- 24.10 使用原生 Go 和兼容该工具链的 OpenList 4.1.10，25.12 使用 Go 27.x 并在每次构建时跟随 OpenList 最新 Release
- Nginx HTTPS 反向代理与 LuCI 管理器
- 代理与文件服务：OpenClash、HomeProxy、OpenList、EasyTier、DDNS-Go
- 应用与远程访问：iStore（仅 24.10）、Cloudflared
- Argon 主题与配置页（24.10 为独立插件，25.12 已并入主题）
- 不包含 Docker、dockerd、containerd、Dockerman，也不包含无线驱动和 wpad

OpenClash、HomeProxy、EasyTier、OpenList WAN 访问和 Cloudflared 默认不会自动启用或写入业务参数。OpenClash 与 HomeProxy 都是代理平台，同时启用会争用防火墙和 DNS，建议只启用其中一个。

## 默认端口

| 服务 | 端口 | 说明 |
| --- | --- | --- |
| LuCI | `8080` / `8443` | 管理页面 |
| Nginx | `80` / `443` | 反向代理入口 |
| OpenList | `5244` | 默认不允许 WAN 访问 |
| OpenClash | `9090` | 控制面板默认端口 |

LuCI 已启用 `rfc1918_filter`，非内网来源会被拒绝；首次登录后请立即设置 root 密码，不要把 `8080/8443` 转发到公网。

## 构建

构建只在两种情况下触发：

- 推送到 `master`（合并 PR 后自动构建），只有文档变更时不构建
- 在 **Actions → Build ImmortalWrt for N1 → Run workflow** 手动运行

推送到其他分支不会构建；新的 master 推送会取消尚未完成的旧构建。固件发布到 GitHub Releases。

- Release 标签格式：`OpenWrt_24.10_YYYY.MM.DD-HHMM` 或 `OpenWrt_25.12_YYYY.MM.DD-HHMM`
- 每个 Release 附 `SHA256SUMS` 和 `*.manifest` 软件包清单
- 默认只打包 `6.12` 和 `6.18` 两个内核；手动运行时可选择全部 7 个变体（5.4 / 5.10 / 5.15 / 6.1 / 6.6 / 6.12 / 6.18）
- 构建前会校验 rootfs：默认地址、无 DHCP 段、无无线配置、关键插件存在、Docker/无线包不存在
- 根分区 2 GB，给 OpenClash、iStore 等插件留出空间
- 每个版本只保留最近 2 个 Release，历史遗留标签会被自动清理

上游源码有更新时，手动合并或触发一次构建即可，不再定时自动构建。

## 升级与安全默认值

- 所有构建和发布都在公开仓库 `jin-ting2520/immortalwrt-N1` 进行。
- 固件内置 Amlogic Service，在线更新标签已按源码版本隔离（`OpenWrt_24.10_` / `OpenWrt_25.12_`），不会跨版本拉取固件。
- 仓库公开后，Amlogic 页面可以直接列出并下载本仓库的 Release，在线更新不依赖其他仓库。
- `amlogic_write_bootloader` 默认为 `0`，不要在不了解风险时开启。
- 固件不提供 DHCP 服务，也不包含无线支持。
- LuCI 只应在内网访问；公网只暴露 Nginx 的 `80/443`。
- OpenClash 和 iStore 会在运行时从网络下载组件或软件包，安装前确认来源；第三方插件不预置节点、证书、密钥和网段。

更完整的模块说明、服务配置和默认值见 [`docs/配置说明.md`](docs/配置说明.md)。

## 许可证

本仓库的原创脚本和配置以 MIT 发布，见 [`LICENSE`](LICENSE)；第三方组件和构建产物的许可证见 [`NOTICE`](NOTICE)。
