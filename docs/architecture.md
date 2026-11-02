# 架构说明

## 总览

```
                ┌─────────────────────── Cloudflare ───────────────────────┐
  浏览器 ─HTTPS─▶│ DNS：*_DOMAIN → 服务器 IP（可开启橙色云代理 / WAF / 缓存）│
                └──────────────────────────────┬────────────────────────────┘
                                               │ HTTPS（SSL 模式 Full (strict)）
                    ┌──────────────── 服务器 ──▼─────────────────────────────┐
                    │  Caddy  :80 :443（tcp+udp）                             │
                    │   ├─ 证书：ACME DNS-01（Cloudflare API Token）          │
                    │   ├─ 信任 Cloudflare 回源 IP，取 CF-Connecting-IP       │
                    │   └─ sites/*.caddy 按域名路由                           │
                    │        │ Docker 网络 proxy（外部网络，各项目共享）       │
                    │        ▼                                                │
                    │   termix:8080     <后续服务>:port   ...                 │
                    └────────────────────────────────────────────────────────┘
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

### 为什么用 DNS-01 而不是 HTTP-01

- 开启 Cloudflare 代理后 HTTP-01 也能用，但 DNS-01 与 80 端口、代理开关、防火墙都无关，最稳
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

开启 Cloudflare 代理时，Caddy 看到的来源是 Cloudflare 节点 IP。通过 `caddy-cloudflare-ip` 插件定期拉取 Cloudflare IP 段并设为 `trusted_proxies`，只有来自这些 IP 的 `CF-Connecting-IP` 头才会被采信，日志中的 `client_ip` 即为真实用户 IP，防止伪造。

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
| 全局配置与密钥 | `.env` | 不入库，需单独备份 |
| 服务数据 | 卷 `rp-<服务>_*` | 如 `rp-webssh_termix_data`（Termix 数据库与加密密钥） |

`./rpctl backup` 会打包以上内容到 `backups/<时间戳>/`。
