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

./rpctl init        # 创建 proxy 网络、执行各服务初始化
./rpctl image load  # 从仓库导入预构建的 Caddy 镜像（无需在服务器上构建）
./rpctl check
./rpctl up
./rpctl logs proxy -f   # 观察证书申请，出现 "certificate obtained successfully" 即成功
./rpctl webssh add-user admin   # 创建 Web SSH 管理员账号（公网注册已屏蔽）
```

### Caddy 镜像的分发方式

自定义 Caddy 镜像需要编译 Go 代码，在国内服务器上拉取基础镜像和 Go 依赖可能要半小时以上。因此镜像在**开发机上构建**，导出为 `images/caddy-cloudflare.tar.gz`（约 40MB）随仓库分发，服务器 `git pull` 后导入即可：

| 文件 | 说明 |
| --- | --- |
| `images/caddy-cloudflare.tar.gz` | `docker save` 导出的镜像（linux/amd64） |
| `images/caddy-cloudflare.info` | Caddy 版本、插件版本、构建时间、sha256，`image load` 时会校验 |

- 服务器上 `./rpctl up` 发现本地没有镜像时，会自动执行 `image load`
- 仓库只保留最新一份镜像文件，但每次更新都会在 git 历史中增加约 40MB，只在升级 Caddy / 插件时更新
- 服务器若不是 x86_64，需在服务器上 `./rpctl build`（国内可在 `.env` 中加 `GOPROXY=https://goproxy.cn,direct` 加速）

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
| Web SSH 注册返回 403 | 正常，账号用 `./rpctl webssh add-user` 在服务器上创建，见 [webssh README](../services/webssh/README.md) |
| Web SSH 连不上本机 | 宿主机防火墙拦截 Docker 网段到 22 端口，见上文 |
