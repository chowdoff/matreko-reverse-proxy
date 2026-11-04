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
   ./rpctl dns verify                # 确认可访问 Tunnel
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

- **公网 443 站点**：需要放行 `80/tcp`（HTTP→HTTPS 跳转）、`443/tcp`、`443/udp`（HTTP/3）
- **Tunnel 站点**：不需要入站端口，出站需允许 7844（UDP/TCP）
- **8443**：不需要也不应放行，它只发布在 127.0.0.1 上
- **管理用的 SSH 端口**：按需放行

**注意：Docker 发布的端口会绕过 ufw**（Docker 直接写 iptables 的 nat 表）。用 ufw 限制 80/443 是无效的，若要限制来源（例如只允许 Cloudflare IP），需要写在 `DOCKER-USER` 链中，或使用云厂商的安全组。

Web SSH 容器通过 Docker 网关（`host.docker.internal`）连接宿主机 sshd。如果宿主机 ufw 默认拒绝入站，需要放行 Docker 网段访问 22：

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
./rpctl backup        # 生成 backups/<时间戳>/{caddy_data.tgz,config.tgz}
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
| 502 Bad Gateway | 后端容器未运行或未加入 `proxy` 网络：`./rpctl ps` |
| Web SSH 注册返回 403 | 正常，账号用 `./rpctl webssh add-user` 在服务器上创建，见 [webssh README](../services/webssh/README.md) |
| Web SSH 连不上本机 | 宿主机防火墙拦截 Docker 网段到 22 端口，见上文 |
