# 架构说明

## 总览

```
                ┌────────────────────────── Cloudflare ──────────────────────────┐
  浏览器 ─HTTPS─▶│ 普通站点：A/AAAA → 服务器 IP（橙色云朵）                       │
                │ Tunnel 站点：CNAME → <Tunnel ID>.cfargotunnel.com              │
                │             Tunnel 路由 → https://caddy:8443（SNI = 域名）     │
                └───────────┬───────────────────────────────▲────────────────────┘
                            │ 回源 443                       │ cloudflared 主动建立的出站长连接（7844）
                    ┌───────▼──────────────── 服务器 ────────┴──────────────────┐
                    │  Caddy :80 :443（公网）           cloudflared              │
                    │        :8443（仅 Docker 网络） ◀───────┘                   │
                    │   ├─ 证书：ACME DNS-01（Cloudflare API Token）             │
                    │   ├─ 按端口信任上游，取 CF-Connecting-IP 作为客户端 IP     │
                    │   └─ sites/*.caddy 按域名路由                              │
                    │        │ Docker 网络 proxy（外部网络，各项目共享）          │
                    │        ▼                                                   │
                    │   termix:8080  fwmap:8080（Tunnel 站点）  <后续服务>:port  │
                    └───────────────────────────────────────────────────────────┘
```

## 关键设计决策

### 为什么选 Caddy

| 需求 | Caddy 的做法 |
| --- | --- |
| 配置要进 git、可审查 | 纯文本 Caddyfile，每个站点一个文件 |
| 自动证书 | 内置 ACME，自动申请与续期，无需 certbot/cron |
| 对接 Cloudflare | `caddy-dns/cloudflare` 插件走 DNS-01，不依赖 80 端口可达，支持通配符证书 |
| WebSocket（Web SSH 必需） | `reverse_proxy` 自动处理，无需额外配置 |

Nginx Proxy Manager 的配置存放在 SQLite 中，只能在 UI 操作，不利于版本管理与脚本化，因此未采用。

### 为什么用 Cloudflare Tunnel 接入

| 方案 | 问题 |
| --- | --- |
| DNS 仅解析（灰色云朵） | 服务器 IP 公开，80/443 直接暴露在公网 |
| 橙色云朵代理回源 443 | 实测 WebSocket 长连接（Web SSH 终端）每 1~2 分钟被静默切断；源站 IP 仍可能被扫描发现 |
| **Tunnel** | 服务器主动连出，不开放入站端口、DNS 中没有 IP；长连接稳定 |

但不是所有服务都需要 Tunnel，因此按站点选择：站点地址 `{$XXX_DOMAIN}` 走公网 443（默认），`{$XXX_DOMAIN}:8443` 走 Tunnel。

- **端口隔离**：Caddy 的 8443 只在 Docker 网络内可达，Tunnel 站点不出现在公网 80/443 上，即使知道服务器 IP 也无法绕过 Cloudflare 访问
- **Caddy 统一处理**：cloudflared 只负责把流量送到 Caddy，证书、路由、安全头仍由 Caddy 处理，切换接入方式只需改站点地址
- **单一配置来源**：Tunnel 路由使用远程配置（保存在 Cloudflare），由 `rpctl dns sync` 根据站点文件生成并推送。新增 Tunnel 站点时不需要改 cloudflared 配置，也不需要重启

### 为什么用 DNS-01 而不是 HTTP-01

- Tunnel 站点不在公网端口上提供服务，HTTP-01/TLS-ALPN-01 都无法使用；DNS-01 与端口、代理开关、防火墙都无关，最稳
- 后续可直接签发通配符证书（`*.example.com`）
- Token 只需对单个 Zone 的 DNS 编辑权限，泄露影响面可控

### 两种 TLS 模式

`CADDY_TLS_MODE` 在 Caddyfile 中通过 `import tls_{$CADDY_TLS_MODE}` 选择片段：

- `cloudflare`：生产，正式证书
- `internal`：开发，Caddy 本地 CA 自签，可配合 `*.localhost` 域名离线调试

### 网络隔离

- 所有服务加入外部 Docker 网络 `proxy`（由 `rpctl init/up` 自动创建）
- 后台服务**不映射任何端口**，只能经由 Caddy 访问
- 每个服务是一个独立 compose 项目（`rp-proxy`、`rp-webssh` …），可单独启停、升级

### 真实客户端 IP

Cloudflare 会把真实用户 IP 写入 `CF-Connecting-IP` 头。Caddy 只采信可信上游传来的这个头，Caddyfile 中按监听端口分别配置信任范围：

- **`:443`**：请求来自 Cloudflare 回源节点。`caddy-cloudflare-ip` 插件定期拉取 Cloudflare IP 段作为可信来源，直连源站的请求无法伪造
- **`:8443`**：请求都来自同一 Docker 网络中的 cloudflared，信任内网地址（`private_ranges`）。该端口不对公网发布，公网无法伪造

日志中的 `client_ip` 即为真实用户 IP。

### 时区

所有容器统一使用 **UTC**，排查问题时各组件的日志时间可以直接对照：

- **cloudflared**：日志固定为 UTC，无法修改，因此以它为准
- **Caddy**：日志时间格式为 ISO 8601，例如 `2026-11-03T16:32:17.611Z`
- **各服务容器**：在 compose 中设置 `TZ: UTC`，新服务模板已包含

换算成北京时间（UTC+8）时加 8 小时。`docker logs -t` 打印的时间戳也是 UTC。

## 配置流向

```
.env ──(compose env_file)──▶ Caddy 容器环境变量 ──▶ Caddyfile 中 {$VAR} / {env.VAR}
  │
  ├──(rpctl --env-file)──▶ 各 compose.yaml 中 ${VAR} 插值
  │
  └──(rpctl init → services/*/init.sh)──▶ 各服务本地配置（如有）
```

## 数据与备份

| 数据 | 位置 | 说明 |
| --- | --- | --- |
| 证书、ACME 账户 | 卷 `rp-proxy_caddy_data` | 丢失后会自动重新申请，但要注意 Let's Encrypt 频率限制 |
| 全局配置与密钥 | `.env` | 含 API Token、Tunnel Token；不入库，需单独备份 |
| 服务数据 | 卷 `rp-<服务>_*` | 如 `rp-webssh_termix_data`（Termix 数据库与加密密钥）；防火墙地图没有数据卷 |

`./rpctl backup` 会打包以上内容到 `backups/<时间戳>/`。
