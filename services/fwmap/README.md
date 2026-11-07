# 防火墙地图（fwmap）

把 DigitalOcean 云防火墙的规则画成拓扑图，一眼看清每台服务器实际放行了哪些入站、出站流量。访问地址为 `https://$FWMAP_DOMAIN`。

- **拓扑图**：左边是外部来源（公网、Cloudflare、命名过的网段），右边是服务器，按 VPC 分组；箭头上标着「协议名 + 端口」，比如 `HTTPS 443`、`PostgreSQL 5432`
- **生效规则**：一台服务器可能同时被多个防火墙覆盖（直接绑定或通过标签），页面把它们合并成实际生效的规则，并注明每条规则来自哪个防火墙
- **风险提示**：没有绑定防火墙的服务器、对公网开放的非 80/443 端口（SSH 列为严重）、没有作用于任何服务器的防火墙、尚未生效的变更、出站全部放行等
- **规则矩阵 / 防火墙列表**：横向对比各服务器，或按防火墙查看规则和作用范围

数据每 5 分钟从 DigitalOcean API 同步一次，页面上也可以手动刷新。服务**只读**，不会修改任何防火墙。

## 文件

| 文件 | 说明 |
| --- | --- |
| `compose.yaml` | 容器定义：官方 Node.js 镜像直接运行 `app/`，不需要构建；只读文件系统、非 root、只加入 `proxy` 网络 |
| `app/server.js` | 服务端：定时拉取 DigitalOcean API、校验 Cloudflare Access 凭证、提供页面和 `/api/snapshot`。只用 Node.js 内置模块 |
| `app/public/` | 前端页面（无外部依赖，不加载任何第三方资源） |
| `cli.sh` | `./rpctl fwmap check`：检查 Token 权限、Access 配置和容器状态 |

服务没有数据卷，不需要备份。

## 安全设计

页面展示的是整个网络的防火墙布局，泄露后等于给攻击者一张地图，所以有三层保护：

1. **不在公网端口上提供**：站点走 Cloudflare Tunnel（`proxy/sites/fwmap.caddy` 监听 8443），公网 80/443 上没有这个域名
2. **Cloudflare Access 登录**：在 Cloudflare 边缘验证身份（例如只允许你的邮箱，用一次性验证码登录），没通过验证的请求到不了服务器
3. **后端再次校验**：服务端用 Access 的公钥校验每个请求携带的 JWT（签名、`aud`、`iss`、有效期）。**生产模式下没有配置 Access 时，服务拒绝所有请求**，所以即使 Access 应用被误删，页面也不会裸奔

另外，DigitalOcean Token 只给只读权限，泄露了也改不了防火墙。

## 首次使用

需要三样东西：DigitalOcean 只读 Token、Cloudflare Access 应用，以及 `.env` 中的配置：

```ini
FWMAP_DOMAIN=fw.example.com
# Token 的 Custom Scopes 只勾选 droplet / firewall / vpc 的 read
FWMAP_DO_TOKEN=dop_v1_xxxxxxxx
FWMAP_ACCESS_TEAM=<团队名>.cloudflareaccess.com
FWMAP_ACCESS_AUD=<Access 应用的 AUD Tag>
```

在服务器上的完整步骤（创建 Token 和 Access 应用、启动、发布域名、验证）见 [deploy.md 部署防火墙地图](../../docs/deploy.md#部署防火墙地图)。

## 可选配置

在 `.env` 中设置，修改后执行 `./rpctl up fwmap` 生效：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FWMAP_LABELS` | 空 | 给网段起名，图上显示名称而不是 IP。例如 `"198.51.100.24/32=办公室,203.0.113.0/24=家里"`，单个 IP 等同于 `/32` |
| `FWMAP_PORTS` | 空 | 给常用端口表里没有的端口起名，例如 `"7650=Blog,9443=Portainer,51821/udp=WG 备用"` |
| `FWMAP_PUBLIC_PORTS` | `80,443` | 对公网开放时不算风险的端口；UDP 端口写成 `443/udp` |
| `FWMAP_REFRESH` | `300` | 自动同步间隔（秒），最小 60 |
| `FWMAP_NODE_IMAGE` | `node:24.22.2-alpine` | 临时覆盖 Node.js 镜像版本 |

规则中出现的 [Cloudflare IP 段](https://www.cloudflare.com/ips/)会自动合并成一个「Cloudflare」来源，不需要逐个命名。

## 开发机本地试跑

```ini
CADDY_TLS_MODE=internal
FWMAP_DOMAIN=fw.localhost
FWMAP_DO_TOKEN=dop_v1_xxxxxxxx    # 可以用同一个只读 Token
```

```bash
./rpctl up fwmap proxy
```

浏览器打开 <https://fw.localhost:8443>。开发模式（`CADDY_TLS_MODE=internal`）下没有配置 Access 也允许访问，页头会显示「开发模式 · 未启用 Access」。

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 页面显示「没有配置 Cloudflare Access……拒绝提供服务」 | `.env` 中缺少 `FWMAP_ACCESS_TEAM` 或 `FWMAP_ACCESS_AUD`，补上后 `./rpctl up fwmap` |
| 「Cloudflare Access 凭证无效：aud 与 FWMAP_ACCESS_AUD 不一致」 | AUD Tag 填错，或 Access 应用重建过，重新复制 |
| 「缺少 Cloudflare Access 凭证」 | Access 应用没有覆盖这个域名，检查应用的 Public hostname |
| 页面顶部提示「同步失败：Token 无效或已过期」 | 重新生成 Token 写入 `FWMAP_DO_TOKEN`，然后 `./rpctl up fwmap` |
| 「Token 缺少读取权限」 | Token 的 Custom Scopes 少勾了某项，`./rpctl fwmap check` 会指出是哪一项 |
| 刷新时提示「登录可能已过期」 | Access 会话到期，刷新页面重新登录 |
| 打不开，Cloudflare 报 502 / 1033 | Tunnel 不在线：`./rpctl tunnel status`、`./rpctl logs proxy` |
| 图上某个网段显示为「外部地址」 | 在 `FWMAP_LABELS` 中给它起名 |

查看服务日志：`./rpctl logs fwmap`。
