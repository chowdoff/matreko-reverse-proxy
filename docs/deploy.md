# 服务器部署

## 前置条件

- Linux 服务器，有公网 IP，可开放 80/443 端口
  - 若服务器在中国大陆，使用 80/443 的域名需要 ICP 备案
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

./rpctl dns verify  # 校验 Token
./rpctl dns sync    # 创建 DNS 记录（或在 CF 控制台手动添加）

./rpctl init        # 生成各服务配置（会打印 Web SSH 口令，请妥善保存）
./rpctl build       # 构建 Caddy 镜像
./rpctl check
./rpctl up
./rpctl logs proxy -f   # 观察证书申请，出现 "certificate obtained successfully" 即成功
```

> 国内服务器构建镜像拉取 Go 模块慢时，可在 `.env` 中加 `GOPROXY=https://goproxy.cn,direct`。

然后按 [cloudflare.md](cloudflare.md#3-ssltls-设置开启代理时) 把 SSL 模式设为 Full (strict)。

## 防火墙

需要放行：`80/tcp`（HTTP→HTTPS 跳转）、`443/tcp`、`443/udp`（HTTP/3），以及管理用的 SSH 端口。

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
./rpctl reload        # 仅改了 Caddyfile / sites 时
./rpctl up            # 改了 compose 时（只会重建有变化的容器）
```

升级镜像：

```bash
./rpctl build && ./rpctl up proxy     # Caddy（修改 proxy/Dockerfile 中 CADDY_VERSION）
./rpctl pull webssh && ./rpctl up webssh
```

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
| 502 Bad Gateway | 后端容器未运行或未加入 `proxy` 网络：`./rpctl ps` |
| Web SSH 页面 403 | `sshwifty.conf.json` 中 `HostName` 与访问域名不一致 |
| Web SSH 连不上本机 | 宿主机防火墙拦截 Docker 网段到 22 端口，见上文 |
