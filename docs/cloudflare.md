# Cloudflare 配置

## 1. 创建 API Token

Cloudflare 控制台 → 右上角头像 → **My Profile** → **API Tokens** → **Create Token** → 选择 **Create Custom Token**：

| 项目 | 设置 |
| --- | --- |
| Permissions | `Zone` / `Zone` / `Read` |
|  | `Zone` / `DNS` / `Edit` |
|  | `Account` / `Cloudflare Tunnel` / `Edit`（有站点走 Tunnel 时需要） |
| Account Resources | `Include` / 域名所在的账号 |
| Zone Resources | `Include` / `Specific zone` / 你的域名 |
| Client IP Address Filtering | （可选）填服务器公网 IP，进一步限制 Token 使用来源 |

> 不要使用 Global API Key。该 Token 同时用于 Caddy 申请证书、`rpctl dns sync` 和 `rpctl tunnel`。
>
> 注意权限列表里有两个名字很像的项：要选 **`DNS`**，不是 `DNS Settings`。选错时 `dns verify` 前两步能通过，但读取 DNS 记录会报 `10000 Authentication error`。
>
> 已有 Token 缺少权限时，在 API Tokens 页面编辑该 Token 补上即可。Token 值不变，无需改 `.env`。

把生成的 Token 写入 `.env`：

```ini
CF_API_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
CF_ZONE=example.com
```

## 2. 接入方式

每个站点在 `proxy/sites/<服务>.caddy` 中通过站点地址选择接入方式：

| | 公网 443（默认） | Cloudflare Tunnel |
| --- | --- | --- |
| 站点地址 | `{$XXX_DOMAIN}` | `{$XXX_DOMAIN}:8443` |
| 访问路径 | 浏览器 → Cloudflare → 服务器 :443 → Caddy | 浏览器 → Cloudflare → Tunnel → cloudflared → Caddy :8443 |
| DNS 记录 | A/AAAA → 服务器 IP（`CF_PROXIED` 控制橙色云朵） | CNAME → `<Tunnel ID>.cfargotunnel.com`（必为橙色云朵） |
| 能否绕过 Cloudflare 直连 | 知道服务器 IP 就能直连 443 | 不能：8443 不对公网发布，公网 80/443 也不提供该域名 |
| WebSocket 长连接 | ⚠️ 实测每 1~2 分钟断线一次 | ✅ 稳定（实测） |
| 适用 | 普通网页、API | Web SSH 等长连接服务，或不希望在公网端口上提供的服务 |

当前 Web SSH 和防火墙地图走 Tunnel，以后新增的服务默认走公网 443，见 [adding-a-service.md](adding-a-service.md#选择接入方式)。

> **为什么 Web SSH 不走橙色云朵**：实测终端每隔 1~2 分钟被静默切断。Termix 日志出现 `WebSocket pong timeout`，Caddy 记录的连接时长都是 30 秒的倍数。
>
> 这不是网上常说的 Cloudflare「WebSocket 空闲 100 秒超时」：Termix 两端每 30 秒互发心跳，连接从不空闲。问题出在 Cloudflare 回源到服务器 443 的这一段，改为仅 DNS 或 Tunnel 后都不再断线。Tunnel 回源走的是 cloudflared 主动建立的长连接，既稳定，又不在 DNS 中暴露 IP。
>
> 注意：只要还有站点走公网 443，服务器 IP 就会出现在这些站点的 DNS 记录中，只是被橙色云朵隐藏。这不影响 Tunnel 站点，它们在公网端口上不可访问。

### 公网 443 站点

```ini
SERVER_IPV4=203.0.113.10
SERVER_IPV6=          # 有则填
CF_PROXIED=true       # 橙色云朵；false 为仅 DNS
```

Caddy 在公网 443 上只信任 [Cloudflare IP 段](https://www.cloudflare.com/ips/)传来的 `CF-Connecting-IP`，IP 段由 `caddy-cloudflare-ip` 插件每 12 小时刷新一次。

### Tunnel 站点

首次使用时创建 Tunnel（完整部署流程见 [deploy.md](deploy.md#部署步骤)，已部署的服务器见 [deploy.md 迁移步骤](deploy.md#把-web-ssh-迁移到-tunnel)）：

```bash
./rpctl dns verify                # 校验 Token，包括是否有 Cloudflare Tunnel 权限
./rpctl tunnel create             # 创建 Tunnel，运行 Token 自动写入 .env 的 CF_TUNNEL_TOKEN
./rpctl check                     # 检查配置
./rpctl up                        # 设置了 CF_TUNNEL_TOKEN 后会同时启动 cloudflared
./rpctl tunnel status             # 确认状态为 healthy，且有连接
./rpctl dns sync --dry-run        # 预览
./rpctl dns sync                  # 推送 Tunnel 路由，并把 Tunnel 站点的 DNS 改为 CNAME
```

工作方式：

- **cloudflared**：`proxy/compose.yaml` 中的 `cloudflared` 容器主动连到 Cloudflare（出站 7844 端口，QUIC/HTTP2），自身不监听任何端口
- **Caddy 8443**：Tunnel 站点只在这个端口上提供服务。该端口只在 Docker 网络内可达，另外仅发布到本机 `127.0.0.1:8443` 供调试
- **路由**：保存在 Cloudflare 侧（远程配置），由 `dns sync` 根据站点文件生成：
  - 每个 Tunnel 站点都转给 `https://caddy:8443`，并以该域名作为 SNI，cloudflared 会校验 Caddy 的正式证书
  - 未登记的域名返回 404
  - 路由修改后 cloudflared 自动生效，无需重启
- **证书**：仍由 Caddy 通过 DNS-01 申请，不依赖入站端口
- **真实 IP**：Caddy 在 8443 上信任来自 Docker 内网（即 cloudflared）的 `CF-Connecting-IP`，日志中的 `client_ip` 就是真实用户 IP

也可以在控制台手动创建 Tunnel：**Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**，把安装命令中 `--token` 后面的值填入 `.env` 的 `CF_TUNNEL_TOKEN`，后续步骤相同。

> 路由以站点文件为准：在控制台 Tunnel 的 *Public Hostname* 中手动做的修改，会在下次 `dns sync` 时被覆盖。

### Cloudflare Access

Tunnel 站点还可以在 Cloudflare 边缘加一层登录验证（Zero Trust → Access controls → Applications，免费套餐支持 50 个用户），没通过验证的请求到不了服务器。Access 应用在控制台手动创建，不由本项目管理。

目前防火墙地图要求必须启用 Access，后端还会校验 Access 签发的 JWT，创建步骤见 [deploy.md 部署防火墙地图](deploy.md#2-创建-cloudflare-access-应用)。

### DNS 同步规则

- **记录归属**：`.env` 中每个属于 `CF_ZONE` 的 `*_DOMAIN` 都归本项目管理。`dns sync` 会把它的 A/AAAA/CNAME 记录调整为该站点接入方式所需的记录，**多余的会被删除**，因此站点可以随时切换接入方式
- **其他类型不受影响**：同名的 TXT、MX 等记录不会被改动
- **注释**：新建的记录带有注释 `managed by matreko-reverse-proxy`
- **查看**：`./rpctl dns list` 查看当前记录及每个域名的接入方式

## 3. SSL/TLS 设置

Cloudflare 控制台 → 你的域名 → **SSL/TLS**：

- **加密模式：Full (strict)**：源站已有受信任证书，必须选 strict；切勿选 Flexible，会导致重定向循环。Tunnel 站点由 cloudflared 校验回源证书，此项主要影响公网 443 站点
- **Edge Certificates**：开启 *Always Use HTTPS*；*Minimum TLS Version* 建议设为 1.2
- **Network**：确认 *WebSockets* 已开启（默认开启）

## 4. （可选）公网 443 只接受 Cloudflare 流量

开启代理后，可以在云厂商防火墙上只放行 [Cloudflare IP 段](https://www.cloudflare.com/ips/)访问 443，避免有人绕过 Cloudflare 直连源站。代价是 IP 段变化时要手动同步，本项目默认不这样做，权衡见 [deploy.md 防火墙](deploy.md#防火墙)。

注意 Docker 发布的端口会绕过 ufw，用 ufw 做不到这一点。这一步只影响公网 443 站点，Tunnel 站点不需要。

## 常见问题

- **证书申请失败 `timed out waiting for record to fully propagate`**：Caddyfile 已指定用 1.1.1.1 检查传播；若服务器访问 1.1.1.1 受限，改成服务器可用的公共 DNS
- **`API token ... appears invalid`**：Token 复制不完整，或 `.env` 中加了引号/空格
- **读取 `dns_records` 报 `10000 Authentication error`**：Token 缺少 `Zone / DNS / Edit` 权限，或 Zone Resources 没包含该域名
- **访问 `cfd_tunnel` 报 `10000 Authentication error`**：Token 缺少 `Account / Cloudflare Tunnel / Edit` 权限，或 Account Resources 没包含该账号
- **`找不到 Zone`**：`CF_ZONE` 填写错误，或 Token 未授予 `Zone:Read`
- **`tunnel status` 显示 inactive 或没有连接**：cloudflared 未运行或连不上 Cloudflare，查看 `./rpctl logs proxy`；服务器需允许出站 7844（UDP/TCP）
- **浏览器 502 / Error 1033**：Tunnel 不在线（排查同上），或 cloudflared 连不上 Caddy（用 `./rpctl ps` 确认 caddy 在运行）
- **浏览器 404（纯文本，没有 Caddy 的响应头）**：域名不在 Tunnel 路由中，执行 `./rpctl dns sync`
- **改了站点接入方式后访问异常**：站点文件、Caddy 配置和 Cloudflare 侧需要一起更新，执行 `./rpctl reload && ./rpctl dns sync`
- **浏览器 526 错误**（公网 443 站点）：SSL 模式为 Full (strict)，但 Caddy 证书尚未签发成功，查看 `./rpctl logs proxy`
