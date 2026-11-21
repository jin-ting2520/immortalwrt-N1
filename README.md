# ImmortalWrt N1

面向斐讯 N1 的 ARM64 旁路由固件项目。默认地址为 `192.168.123.2`，主路由网关和 DNS 为 `192.168.123.1`，DHCP 默认关闭。

## 主要内容

- ImmortalWrt `openwrt-24.10`、`openwrt-25.12` 双版本构建
- N1 Amlogic 支持、zram、irqbalance、USB 存储和常用管理工具
- 24.10 使用原生 Go 和兼容该工具链的 OpenList 4.1.10，25.12 使用 Go 27.x 并在每次构建时跟随 OpenList 最新 Release
- Nginx HTTPS 反向代理与 LuCI 管理器
- OpenList、HomeProxy、EasyTier、DDNS-Go 等可选服务
- 不包含 Docker、dockerd、containerd 和 Dockerman

HomeProxy、EasyTier、OpenList WAN 访问默认不会自动启用或写入业务参数。它们必须按实际域名、证书、节点和网段配置。N1 没有内置无线网卡，固件不编译 Broadcom/mac80211 驱动和 wpad。

## 默认端口

| 服务 | 端口 | 说明 |
| --- | --- | --- |
| LuCI | `8080` / `8443` | 管理页面 |
| Nginx | `80` / `443` | 反向代理入口 |
| OpenList | `5244` | 默认不允许 WAN 访问 |

LuCI 已启用 `rfc1918_filter`，非内网来源会被拒绝；首次登录后请立即设置 root 密码，不要把 `8080/8443` 转发到公网。

## 构建

在 **Actions → Build ImmortalWrt for N1 → Run workflow** 手动运行，会同时构建两个源码分支。固件发布到 GitHub Releases。

- Release 标签格式：`OpenWrt_24.10_YYYY.MM.DD-HHMM` 或 `OpenWrt_25.12_YYYY.MM.DD-HHMM`
- 每个 Release 附 `SHA256SUMS`，可用 `sha256sum -c SHA256SUMS` 校验
- 每个 Release 含 7 个内核变体（5.4 / 5.10 / 5.15 / 6.1 / 6.6 / 6.12 / 6.18），N1 建议优先尝试 6.6 或 6.12
- 每个版本只保留最近 2 个 Release，历史遗留标签会被自动清理

`.github/workflows/update-checker.yml` 每 7 天检查一次 25.12 上游提交，有更新时通过 `repository_dispatch` 触发构建。需要在仓库 Secrets 中配置 `TOKEN`（具备 `contents: write` 的 PAT）；未配置时只输出警告并跳过自动触发。

## 升级与安全默认值

- 所有构建和发布都在私有仓库 `jin-ting2520/immortalwrt-N1` 进行。
- 固件内置 Amlogic Service，在线更新标签已按源码版本隔离（`OpenWrt_24.10_` / `OpenWrt_25.12_`），不会跨版本拉取固件。
- 私有仓库的 Release 无法被固件匿名读取；在线更新需要手动从仓库下载，或把仓库设为公开后再使用。
- `amlogic_write_bootloader` 默认为 `0`，不要在不了解风险时开启。
- LuCI 只应在内网访问；公网只暴露 Nginx 的 `80/443`。
- 第三方插件不预置节点、证书、密钥和网段。

更完整的模块说明、服务配置和默认值见 [`docs/配置说明.md`](docs/配置说明.md)。
