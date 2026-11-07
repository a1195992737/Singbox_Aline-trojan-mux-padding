# sing-box-lite

只有一个协议的 sing-box 安装脚本：**Trojan + TLS + h2mux + padding**。
为 Alpine / 128M、256M 这类小内存 VPS 重写，专治「跑一段时间 sing-box 就消失」。

```
原版 fscarmen/sing-box   7000+ 行，14 个模块，nginx + Argo + 订阅服务 + clash_api + cache_file
本脚本                    ~900 行，1 个 config.json，跑一个 Trojan 就完事
```

## 为什么原版会把 sing-box 杀掉

不是脚本主动 kill，是小内存机器被 **OOM** 选中。原版在 Alpine 上同时常驻：

| 组件 | 常驻内存 | 说明 |
| --- | --- | --- |
| sing-box | 40–60 MB | Go 堆无上限，长跑持续增长 |
| cloudflared (Argo) | 25–40 MB | 即使不用 Argo 也装着 |
| nginx | 10–20 MB | 只为订阅页 / WS 反代 |
| 订阅 HTTP 服务 | 少量 | 模板下载 + 页面 |

这些进程争抢仅剩的几百 MB 内存，Go 运行时默认又不设堆上限，堆涨到把内存吃干净后，内核直接 OOM kill 掉占用最大的那个进程——通常就是 sing-box。

本脚本的处理方式：

1. **只跑一个进程**：砍掉 nginx、cloudflared、订阅服务、jq、qrencode、bash 依赖，配置合并成单个 `config.json`。
2. **`GOMEMLIMIT` 给 Go 堆设软上限**，按物理内存自动分档（≤192M → 48MiB，≤256M → 64MiB，≤512M → 128MiB，更高 → 256MiB），让 GC 提前动手，而不是等内核来杀。
3. **OpenRC `supervise-daemon` 托管**，崩了 10 秒后自动拉起（`respawn_max=0` 无限重试）；没有 supervise-daemon 时自动降级为 `command_background`。
4. **日志超过 1MB 在 start_pre 自动截断**，小硬盘不会被写满。

## 一键安装

```bash
curl -Ls https://raw.githubusercontent.com/a1195992737/Singbox_Aline-trojan-mux-padding/main/sb.sh | sh
```

GitHub 直连慢时换镜像（内容相同）：

```bash
# jsDelivr
curl -Ls https://cdn.jsdelivr.net/gh/a1195992737/Singbox_Aline-trojan-mux-padding@main/sb.sh | sh

# gh-proxy
curl -Ls https://gh-proxy.com/https://raw.githubusercontent.com/a1195992737/Singbox_Aline-trojan-mux-padding/main/sb.sh | sh
```

需要 root，脚本会依次询问：监听端口、证书伪装域名（SNI）、密码、节点名。装完自动打印**节点链接 + 客户端配置 + 证书指纹**，并写好 `sb` 命令。

## 日常使用

```bash
sb                 # 信息面板 + 菜单
sb info            # 节点信息、内存占用、客户端配置
sb clients         # 只输出客户端配置片段
sb restart         # 重启
sb log 100         # 最近 100 行日志
sb update          # 升级 sing-box 内核
sb upgrade         # 更新脚本自身（从本仓库重新拉取）
sb renew           # 重签自签证书
sb uninstall       # 卸载
sb clean           # 清掉旧版迁移时留下的 *.bak
```

## 非交互安装（自动化）

```bash
curl -Ls <上面的链接> | SB_PORT=8443 SB_PASS=yourpassword SB_SNI=www.bing.com \
  SB_NAME='HK-01' SB_NONINTERACTIVE=1 sh
```

| 变量 | 说明 |
| --- | --- |
| `SB_PORT` | 监听端口，默认 443 |
| `SB_PASS` | 密码，只允许字母数字，默认随机生成 |
| `SB_SNI` | 伪装域名，默认 `addons.mozilla.org` |
| `SB_NAME` | 节点名称 |
| `SB_PADDING` | `0` = 关闭 padding，默认开启 |
| `SB_MEMLIMIT` | Go 堆上限，默认按物理内存推算 |
| `SB_MUX_MAXCONN` / `SB_MUX_MINSTR` | 客户端 mux 建议值，默认 8 / 16，只影响输出的配置片段 |
| `SB_VERSION` | 固定内核版本，默认取最新 |
| `SB_FORCE_CORE` | `1` = 重新安装时强制重下内核 |
| `SB_SCRIPT_URL` | 覆盖脚本自更新地址（换分支/镜像时用） |

## 客户端必须开 mux

服务端启用了 `multiplex` 且 `padding: true`，按 sing-box 文档：

> If enabled, non-padded connections will be rejected.

也就是说**没开填充的连接会被直接拒绝**。而 `trojan://` 链接没有 mux 字段的标准定义，任何客户端都不会从链接里读 smux——所以**只导入链接是一定连不上的**，需要手动补 mux，或者直接用 `sb clients` 输出的配置：

Mihomo / Clash Meta：

```yaml
- name: "HK-01"
  type: trojan
  server: 1.2.3.4
  port: 443
  password: "yourpassword"
  sni: addons.mozilla.org
  skip-cert-verify: true
  udp: true
  smux:
    enabled: true
    protocol: h2mux      # 必须是 h2mux，填 smux / yamux 都连不上
    max-connections: 8
    min-streams: 16
    padding: true
```

sing-box 客户端 outbound：

```json
{
  "type": "trojan",
  "tag": "proxy",
  "server": "1.2.3.4",
  "server_port": 443,
  "password": "yourpassword",
  "tls": { "enabled": true, "server_name": "addons.mozilla.org", "insecure": true },
  "multiplex": { "enabled": true, "protocol": "h2mux", "max_connections": 8, "min_streams": 16, "padding": true }
}
```

注意：**h2mux + padding 是 sing-box 的扩展**，Xray 系客户端（v2rayN / v2rayNG / Shadowrocket 等）不支持，只能用 sing-box 内核（SFA / SFI / Hiddify / NekoBox）或较新版本的 Mihomo。

如果非要用不支持 padding 的客户端，重装时关掉：

```bash
SB_PADDING=0 <安装命令>
```

## 自签证书与安全

脚本自签一张 CN = SNI 的证书，面板会给出两个指纹：

- `SHA256(证书)`：完整证书指纹
- `SHA256(公钥b64)`：公钥指纹（pin），客户端支持时优先用这个，比 `allowInsecure=1` 安全得多

换域名时 `sb renew` 即可重签（`sb install` 检测到 SNI 变化也会自动重签）。

## 从原版脚本迁移

在已经装了 fscarmen/sing-box 的机器上直接运行本脚本，它会：

1. 停掉并 `rc-update del` / `systemctl disable` argo、nginx、订阅服务；
2. 把 `conf/`、`subscribe/`、`cloudflared`、`nginx.conf` 改名成 `*.bak`（**不删除**，可回退）；
3. 写入新的单文件 `config.json` 与守护脚本。

确认没问题后 `sb clean` 清掉备份；想回退就把 `*.bak` 改回来。

## 文件结构

```
/etc/sing-box/
├── sing-box          # 内核
├── config.json       # 唯一配置（Trojan + TLS + multiplex）
├── cert.pem / key.pem
├── sing-box.log
├── sb.sh             # 脚本副本，供 sb 命令调用
└── .node             # 端口/密码/SNI 等元数据（600）
```

## 常见问题

**导入链接就连不上**
没开 mux。按上文补 `smux` / `multiplex`，`protocol` 必须是 `h2mux`。

**`sb` 命令找不到**
`/usr/local/bin/sb` 是指向 `$WORK_DIR/sb.sh` 的软链，确认 `/usr/local/bin` 在 PATH 里；或重新执行一次安装命令。

**内存还是被吃满**
先 `sb info` 看 RSS，再 `SB_MEMLIMIT=32MiB` 重装收紧堆上限；确认机器上没有别的 Go/Java 进程。

**端口连不上**
云厂商安全组 / 防火墙要放行 TCP 端口；Alpine 上 `apk add iproute2` 后用 `ss -lntp` 确认监听。

## 致谢

思路与大量取舍参考 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)，原项目 GPL-3.0。
本脚本是完全重写的精简实现，仅保留 Trojan + mux + padding 一条链路。

## License

GPL-3.0，见 [LICENSE](LICENSE)。
