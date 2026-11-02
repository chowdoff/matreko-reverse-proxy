# Cloudflare 配置

## 1. 创建 API Token

Cloudflare 控制台 → 右上角头像 → **My Profile** → **API Tokens** → **Create Token** → 选择 **Create Custom Token**：

| 项目 | 设置 |
| --- | --- |
| Permissions | `Zone` / `Zone` / `Read` |
|  | `Zone` / `DNS` / `Edit` |
| Zone Resources | `Include` / `Specific zone` / 你的域名 |
| Client IP Address Filtering | （可选）填服务器公网 IP，进一步限制 Token 使用来源 |

> 不要使用 Global API Key。该 Token 同时用于 Caddy 申请证书和 `rpctl dns sync`。
>
> 注意权限列表里有两个名字很像的项：要选 **`DNS`**，不是 `DNS Settings`。选错时 `dns verify` 前两步能通过，但读取 DNS 记录会报 `10000 Authentication error`。也可以直接用模板 **Edit zone DNS** 创建，再额外添加 `Zone / Zone / Read`。

把生成的 Token 写入 `.env`：

```ini
CF_API_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
CF_ZONE=example.com
```

校验：

```bash
./rpctl dns verify
```

## 2. DNS 记录

在 `.env` 中设置服务器地址和是否代理：

```ini
SERVER_IPV4=203.0.113.10
SERVER_IPV6=          # 有则填
CF_PROXIED=true       # 橙色云朵
```

先预览再同步：

```bash
./rpctl dns sync --dry-run
./rpctl dns sync
./rpctl dns list
```

脚本会为 `.env` 中每个 `*_DOMAIN` 创建或更新 A/AAAA 记录（带注释 `managed by matreko-reverse-proxy`），不会删除任何记录。也可以在 Cloudflare 控制台手动添加，效果相同。

### 是否开启代理（橙色云朵）

| | 开启代理 | 仅 DNS（灰色云朵） |
| --- | --- | --- |
| 隐藏源站 IP | ✅ | ❌ |
| DDoS 防护 / WAF / 访问规则 | ✅ | ❌ |
| WebSocket（Web SSH） | ✅ 支持（空闲超时约 100 秒，终端有心跳不受影响） | ✅ |
| 国内访问速度 | 视线路而定，可能变慢 | 直连 |
| 证书 | 边缘证书由 CF 提供；回源用 Caddy 的证书 | 浏览器直接看到 Caddy 的证书 |

两种方式 Caddy 侧配置相同，可随时切换。

## 3. SSL/TLS 设置（开启代理时）

Cloudflare 控制台 → 你的域名 → **SSL/TLS**：

- **加密模式：Full (strict)** —— 源站已有受信任证书，必须选 strict，否则存在中间人风险；切勿选 Flexible（会导致重定向循环）
- **Edge Certificates**：开启 *Always Use HTTPS*；*Minimum TLS Version* 建议 1.2
- **Network**：确认 *WebSockets* 已开启（默认开启）

## 4. （可选）源站只接受 Cloudflare 流量

开启代理后，可在服务器防火墙上只放行 [Cloudflare IP 段](https://www.cloudflare.com/ips/) 访问 443，避免绕过 Cloudflare 直连源站。注意 Docker 发布的端口会绕过 ufw，规则需写在 `DOCKER-USER` 链中，见 [deploy.md](deploy.md#防火墙)。

## 常见问题

- **证书申请失败 `timed out waiting for record to fully propagate`**：Caddyfile 已指定用 1.1.1.1 检查传播；若服务器访问 1.1.1.1 受限，改成服务器可用的公共 DNS
- **`API token ... appears invalid`**：Token 复制不完整，或 `.env` 中加了引号/空格
- **读取 `dns_records` 报 `10000 Authentication error`**：Token 缺少 `Zone / DNS / Edit` 权限，或 Zone Resources 没包含该域名。在 API Tokens 页面编辑该 Token 补上权限即可，Token 值不变，无需改 `.env`
- **`找不到 Zone`**：`CF_ZONE` 填写错误，或 Token 未授予 `Zone:Read`
- **浏览器 526 错误**：SSL 模式为 Full (strict) 但 Caddy 证书尚未签发成功，查看 `./rpctl logs proxy`
