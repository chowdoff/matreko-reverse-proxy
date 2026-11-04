# 服务器部署

## 前置条件

- Linux 服务器（x86_64），有公网 IP，可访问外网
  - 公网 443 站点：需要开放入站 80/443；服务器在中国大陆时，域名需要 ICP 备案
  - Tunnel 站点（Web SSH）：只需允许出站 7844（UDP/TCP），不需要入站端口
- Docker Engine + Docker Compose v2（`docker compose version` 可用）
- `git`、`jq`、`curl`
- 域名已托管在 Cloudflare

```bash
# Ubuntu/Debian 安装依赖示例
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # 重新登录生效
sudo apt install -y git jq curl
```

## 部署步骤

```bash
git clone <本仓库地址> /opt/matreko-reverse-proxy
cd /opt/matreko-reverse-proxy

./rpctl init        # 生成 .env
vim .env            # 填写 ACME_EMAIL、CF_API_TOKEN、CF_ZONE、SERVER_IPV4、各 *_DOMAIN
                    # 确认 CADDY_TLS_MODE=cloudflare

./rpctl dns verify      # 校验 Token（Token 权限见 cloudflare.md）
./rpctl tunnel create   # 创建 Cloudflare Tunnel（Web SSH 使用），Token 自动写入 .env

./rpctl init        # 创建 proxy 网络、执行各服务初始化
./rpctl image load  # 从仓库导入预构建的 Caddy 镜像（无需在服务器上构建）
./rpctl check
./rpctl up
./rpctl logs proxy -f   # 观察证书申请，出现 "certificate obtained successfully" 即成功
./rpctl tunnel status   # 确认 Tunnel 为 healthy
./rpctl dns sync --dry-run   # 预览
./rpctl dns sync        # 推送 Tunnel 路由，并创建各域名的 DNS 记录
./rpctl webssh add-user admin   # 创建 Web SSH 管理员账号（公网注册已屏蔽）
```

哪些站点走 Tunnel 由站点文件决定，见 [cloudflare.md](cloudflare.md#2-接入方式)。

### Caddy 镜像的分发方式

自定义 Caddy 镜像需要编译 Go 代码，在国内服务器上拉取基础镜像和 Go 依赖可能要半小时以上。因此镜像在**开发机上构建**，导出为 `images/caddy-cloudflare.tar.gz`（约 40MB）随仓库分发，服务器 `git pull` 后导入即可：

| 文件 | 说明 |
| --- | --- |
| `images/caddy-cloudflare.tar.gz` | `docker save` 导出的镜像（linux/amd64） |
| `images/caddy-cloudflare.info` | Caddy 版本、插件版本、构建时间、sha256，`image load` 时会校验 |

- 服务器上 `./rpctl up` 发现本地没有镜像时，会自动执行 `image load`
- 仓库只保留最新一份镜像文件，但每次更新都会在 git 历史中增加约 40MB，只在升级 Caddy / 插件时更新
- 服务器若不是 x86_64，需在服务器上 `./rpctl build`（国内可在 `.env` 中加 `GOPROXY=https://goproxy.cn,direct` 加速）

然后按 [cloudflare.md](cloudflare.md#3-ssltls-设置) 检查 SSL/TLS 设置。

## 把 Web SSH 迁移到 Tunnel

适用于之前 Web SSH 走公网 443（仅 DNS 或橙色云朵）的服务器：

1. **补 Token 权限**：在 Cloudflare 编辑现有 API Token，添加 `Account / Cloudflare Tunnel / Edit`，Account Resources 包含域名所在账号。Token 值不变
2. **更新代码**：`git pull`
3. **创建并启动 Tunnel，再切换 DNS**：

   ```bash
   cd /opt/matreko-reverse-proxy
   ./rpctl dns verify                # 最后一行应为「Token 有 Cloudflare Tunnel 权限」
   ./rpctl tunnel create             # 写入 CF_TUNNEL_TOKEN
   ./rpctl check
   ./rpctl up                        # 启动 cloudflared；Caddy 重建后 Web SSH 只在 8443 上提供
   ./rpctl tunnel status             # 等待状态变为 healthy
   ./rpctl dns sync --dry-run        # 应显示：删除 ssh 的 A 记录，创建 CNAME
   ./rpctl dns sync
   ```

   执行 `up` 到 `dns sync` 之间，旧的 A 记录已无法访问 Web SSH，属于正常现象。

4. **（可选）关闭入站端口**：目前还没有走公网 443 的站点，可以在 `.env` 中设置 `LISTEN_ADDR=127.0.0.1`，执行 `./rpctl up proxy`，并在云厂商安全组关闭 80/443；以后新增公网站点时再打开
5. **（可选）处理已暴露的 IP**：服务器 IP 以前出现在 ssh 域名的 DNS 中，可能已被 DNS 历史记录网站收录。Web SSH 在公网端口上已不可访问，风险不大；如果要彻底消除，可以更换服务器公网 IP（在云厂商重新分配，或换一个弹性 IP），此操作不影响 Tunnel。更换后记得更新 `.env` 中的 `SERVER_IPV4`

## 防火墙

推荐用云厂商的防火墙限制入站，不用宿主机的 ufw，原因是 **Docker 发布的端口会绕过 ufw**：Docker 直接写 iptables 的 nat 表，用 ufw 限制 80/443 不起作用。

各类站点对端口的要求：

- **公网 443 站点**：Cloudflare 回源用 `443/tcp`
- **Tunnel 站点**：不需要入站端口；cloudflared 主动出站连接 7844（UDP/TCP）
- **8443**：只发布在 127.0.0.1 上，不需要也不应放行
- **SSH**：可以不对公网开放，管理走 Web SSH，见下文

### DigitalOcean Cloud Firewall

在控制台 **Networking → Firewalls → Create Firewall** 中创建。

**工作方式**（摘自[官方文档](https://docs.digitalocean.com/products/networking/firewalls/)）：

- **有状态**：出站连接的回包自动放行
- **默认拒绝**：只放行规则里列出的流量，入站、出站都是如此
- **也作用于 VPC 内网流量**：DigitalOcean 的云防火墙不是只拦公网，VPC 内网流量同样要规则放行。本项目的内部通信都在本机 Docker 网络内，不经过云防火墙，所以不需要 VPC 规则：
  - cloudflared → Caddy → 各服务
  - Termix → 宿主机 sshd

  以后如果同一 VPC 里有其他 Droplet 要访问本机，再按私网网段添加规则。

**入站规则**（只有这一条）：

| Type | Protocol | Port | Sources | 用途 |
| --- | --- | --- | --- | --- |
| HTTPS | TCP | 443 | All IPv4、All IPv6 | 公网 443 站点 |

还没有公网 443 站点时，Caddy 不会在 443 上监听，外部连接会被立即拒绝，属于正常现象。规则可以先留着，以后加站点时不用再改。

有仅 DNS（`CF_PROXIED=false`）的站点时，再加两条，来源都是 All IPv4、All IPv6：

- **80/tcp**：HTTP→HTTPS 跳转
- **443/udp**：HTTP/3

橙色云朵站点不需要这两条：开启 *Always Use HTTPS*（见 [cloudflare.md](cloudflare.md#3-ssltls-设置)）后，Cloudflare 在边缘直接跳转 HTTPS，不会回源到 80；Cloudflare 回源也不使用 HTTP/3。

**不要放行的端口：**

- **22（SSH）**：见下方「SSH 不对公网开放」
- **8443**：只在本机回环上
- **7844**：cloudflared 是出站连接
- **ICMP**：需要 ping 排障时再临时放行

> **为什么 443 不只对 Cloudflare 开放**：只放行 Cloudflare IP 段确实能挡住直连源站，但 Cloudflare 的 IP 段变化时，云防火墙不会自动更新，维护成本高，忘了更新还会导致站点 522。对所有 IP 开放 443 的风险是可控的：
>
> - 直连服务器 IP 只能访问到公网 443 站点本身，与经过 Cloudflare 访问没有区别，只是少了 Cloudflare 的防护
> - Tunnel 站点（Web SSH）在 443 上不提供服务
> - 伪造 `CF-Connecting-IP` 头无效：Caddy 只信任来自 Cloudflare IP 段的该请求头，这份 IP 段由插件自动刷新
>
> 需要更强的防护时，可以只把 443 的来源改为 Cloudflare IP 段（`curl -s https://www.cloudflare.com/ips-v4; echo; curl -s https://www.cloudflare.com/ips-v6`），代价是 IP 段变化时要手动同步，且所有公网 443 站点都必须开启橙色云朵。

**出站规则**：保留创建时默认的「全部 ICMP / TCP / UDP 到所有 IPv4、IPv6」。服务需要访问的出站目标很多：

- cloudflared：7844（UDP/TCP）
- Caddy 申请证书、调用 Cloudflare API：443
- 检查 DNS 传播：1.1.1.1:53
- `git pull`：GitHub 的 22 端口
- 拉取镜像、apt、NTP
- Droplet Agent：169.254.169.254

收紧出站规则的收益很小，却容易让上述某项悄悄失效。

最后在 **Apply to Droplets** 中选中这台服务器（或给它打个标签再按标签应用），然后点 **Create Firewall**。

**SSH 不对公网开放：**

不放行 22 时，Web SSH 仍然可以登录服务器。原因是 Termix 和 sshd 在同一台机器上，Termix 连接本机 sshd 时，无论填 `host.docker.internal` 还是本机的内网 IP，目标都是本机地址，流量不离开 Droplet，云防火墙拦不到。用 Termix 连同一 VPC 的其他 Droplet 则会经过云防火墙，需要在对方的防火墙放行来自本机内网 IP 的 22。登录服务器要先经过 Cloudflare Tunnel，再通过 Termix 的账号登录，攻击面比公网 22 小得多。

代价是日常只剩 Web SSH 这一个管理入口，要提前准备好备用方式：

- **Recovery Console**（控制台 → Droplet → Access）：带外访问，不受网络和防火墙影响，但需要 root 密码登录。用 SSH 密钥创建的 Droplet 默认没有 root 密码，**请提前在服务器上执行 `sudo passwd root` 设置一个强密码**。临时也可以用控制台的 *Reset Root Password* 重置，但会让服务器关机重启一次
- **临时放行 SSH**：在云防火墙中加一条 SSH / TCP / 22，来源只填你当前的公网 IP，用完删除
- **Droplet Console**（网页控制台）也走 SSH，22 不放行时无法使用，这种情况用 Recovery Console

**注意事项：**

- **宿主机 ufw 可以保持 inactive**：入站已由云防火墙控制

**验证**：在开发机（不是服务器本身）上运行检查脚本：

```bash
scripts/firewall-check.sh <服务器 IP> -t ssh.example.com
```

脚本会检查以下几项：

- **应开放的端口**：443 已放行
  - 有程序监听时能连上
  - 还没有公网 443 站点时，连接会被立即拒绝，也算通过
- **SSH**：被拦截，或只对当前 IP 开放，都算正常
- **应拦截的端口**：80、8443、7844 以及常见的数据库、Docker API 等端口都被拦截
  - 被拦截时连接会超时
  - 如果立即被拒绝，说明防火墙没有拦截这个端口，只是恰好没有程序在监听
- **Tunnel 站点**（`-t` 指定的域名）：直连服务器 IP 时，80/443 上拿不到该站点

几点说明：

- **独立脚本**：不依赖 `.env`，也可以单独拷到其他机器上使用
- **常用选项**：
  - 有仅 DNS 站点时加 `--dns-only`，此时 80 应开放
  - SSH 不在 22 端口时用 `--ssh-port` 指定
- **不能在服务器上运行**：服务器访问自己的公网 IP 不经过云防火墙
- **本机有透明代理时无法检查**：例如开着 Clash 的 TUN 模式，任何端口都会显示为开放，脚本会识别出来并提示
- **另外两项要手动确认**：
  - 443/udp：UDP 无法可靠探测
  - 临时放行 SSH 时，来源是否只有你的 IP：从一个 IP 看不出其他 IP 是否被拦截

### 开启 ufw 时

Web SSH 容器通过 Docker 网关（`host.docker.internal`）连接宿主机 sshd。如果开启了 ufw 且默认拒绝入站，需要放行 Docker 网段访问 22：

```bash
sudo ufw allow from 172.16.0.0/12 to any port 22 proto tcp
```

## 更新

```bash
cd /opt/matreko-reverse-proxy
git pull
./rpctl init          # 新服务可能需要初始化
./rpctl check
./rpctl up            # 只重建有变化的容器，并自动热加载 Caddy 配置
                      # （仅改了 Caddyfile / sites 时也可只执行 ./rpctl reload）
```

新增 / 删除公网 443 站点：在服务器上执行 `./rpctl site add` / `./rpctl site remove`，配置只保存在本机，见 [adding-a-service.md](adding-a-service.md#快速方式在服务器上-rpctl-site-add)。

升级 Caddy（修改 `proxy/Dockerfile` 中的 `CADDY_VERSION`）：

```bash
# 开发机
./rpctl build && ./rpctl image save
git add proxy/Dockerfile images/ && git commit -m "升级 Caddy 到 vX.Y.Z" && git push

# 服务器
git pull && ./rpctl image load && ./rpctl up proxy
```

升级其他服务镜像：

```bash
./rpctl pull webssh && ./rpctl up webssh
```

升级 cloudflared：修改 `proxy/compose.yaml` 中的版本号（或在 `.env` 中设置 `CLOUDFLARED_IMAGE` 覆盖），然后执行 `./rpctl pull proxy && ./rpctl up proxy`。

## 备份与迁移

```bash
./rpctl backup        # 生成 backups/<时间戳>/：各数据卷 *.tgz，以及 config.tgz（.env、site add 添加的本地站点等）
```

迁移到新服务器：克隆仓库 → 解压 `config.tgz` 到项目根目录 → 执行一次 `./rpctl up proxy` 创建数据卷后 `./rpctl down proxy` → 恢复证书卷：

```bash
docker run --rm -v rp-proxy_caddy_data:/data -v $PWD/backups/<时间戳>:/backup \
  --entrypoint sh matreko/caddy-cloudflare:local -c 'tar xzf /backup/caddy_data.tgz -C /data'
./rpctl up
```

不恢复证书卷也可以，Caddy 会自动重新申请。

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 证书申请失败 | `./rpctl logs proxy`，参见 [cloudflare.md 常见问题](cloudflare.md#常见问题) |
| Tunnel 不在线 / 502 / Error 1033 | `./rpctl tunnel status`、`./rpctl logs proxy`，参见 [cloudflare.md 常见问题](cloudflare.md#常见问题) |
| 公网 443 站点 522 / 超时 | 在开发机上运行 `scripts/firewall-check.sh <服务器 IP>`；若 443 只对 Cloudflare 开放，检查 IP 段是否已过期，见上文 |
| 502 Bad Gateway | 后端容器未运行或未加入 `proxy` 网络：`./rpctl ps` |
| Web SSH 注册返回 403 | 正常，账号用 `./rpctl webssh add-user` 在服务器上创建，见 [webssh README](../services/webssh/README.md) |
| Web SSH 连不上本机 | 宿主机防火墙拦截 Docker 网段到 22 端口，见上文 |
