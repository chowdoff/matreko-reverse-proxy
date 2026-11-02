# matreko-reverse-proxy

统一管理反向代理及相关运维的项目：配置、脚本、文档都放在这里，用 git 做版本管理。

- **对外**：对接 Cloudflare，通过 DNS-01 自动申请/续期 SSL 证书，脚本化管理 DNS 记录
- **对内**：Caddy 统一反代到各个后台服务（Docker 容器），后台服务不直接暴露端口
- **已接入服务**：Web SSH（[Termix](https://github.com/Termix-SSH/Termix)）

```
浏览器 ──HTTPS──▶ Cloudflare（可选橙色云代理）──▶ 服务器 :443 Caddy ──proxy 网络──▶ termix:8080 ──SSH──▶ 目标主机
                                                       │
                                                       └─ 证书：Let's Encrypt DNS-01（Cloudflare API）
```

## 目录结构

```
.
├── rpctl                       # 管理入口（./rpctl help）
├── .env.example                # 全局配置模板（复制为 .env，含密钥，不入库）
├── proxy/                      # Caddy 反向代理核心
│   ├── Dockerfile              #   官方 Caddy + cloudflare DNS 插件 + cloudflare IP 插件
│   ├── compose.yaml
│   ├── Caddyfile               #   全局配置、TLS 片段、通用 header/日志
│   └── sites/*.caddy           #   每个站点一个文件（路由表）
├── services/                   # 各后台服务，一个目录一个服务
│   └── webssh/
│       ├── compose.yaml
│       ├── cli.sh              #   服务命令：./rpctl webssh add-user
│       └── README.md
├── scripts/
│   ├── cf-dns.sh               # Cloudflare DNS 记录同步
│   └── lib/common.sh           # 公共函数
├── images/                     # 预构建的 Caddy 镜像（开发机 image save，服务器 image load）
├── templates/service/          # 新服务模板
└── docs/                       # 文档
```

## 快速开始

### 开发机本地试跑（无需域名和 Token）

```bash
./rpctl init                    # 首次运行生成 .env
# 编辑 .env：
#   CADDY_TLS_MODE=internal
#   WEBSSH_DOMAIN=ssh.localhost
./rpctl init                    # 创建 proxy 网络等
./rpctl image load              # 导入仓库中预构建的 Caddy 镜像（或 ./rpctl build 自行构建）
./rpctl check
./rpctl up
```

创建 Web SSH 管理员账号：

```bash
./rpctl webssh add-user admin
```

浏览器打开 <https://ssh.localhost>（自签证书，需手动信任）登录即可。

### 生产服务器部署

见 [docs/deploy.md](docs/deploy.md)，Cloudflare 侧配置见 [docs/cloudflare.md](docs/cloudflare.md)。

## 常用命令

| 命令 | 说明 |
| --- | --- |
| `./rpctl init` | 生成 .env、创建 `proxy` 网络、执行各服务 `init.sh`（可重复执行） |
| `./rpctl check` | 检查 .env 必填项、compose 文件、Caddyfile 语法 |
| `./rpctl build` | 构建自定义 Caddy 镜像（较慢，一般只在开发机执行） |
| `./rpctl image save` / `image load` | 导出 Caddy 镜像到 `images/` / 从 `images/` 导入 |
| `./rpctl up [目标...]` | 启动（默认全部） |
| `./rpctl down [目标...]` | 停止（数据卷保留） |
| `./rpctl restart [目标...]` | 重启 |
| `./rpctl reload` | 热加载 Caddy 配置 |
| `./rpctl ps` | 查看容器状态 |
| `./rpctl logs <目标> [-f]` | 查看日志 |
| `./rpctl dns verify / list / sync [--dry-run]` | Cloudflare Token 校验 / 查看 / 同步 DNS 记录 |
| `./rpctl backup` | 备份证书数据卷与本地配置到 `backups/` |
| `./rpctl compose <目标> ...` | 透传任意 docker compose 命令 |

目标为 `proxy` 或 `services/` 下的目录名（如 `webssh`）。

## 约定

- **密钥不入库**：`.env` 等含密钥的文件已在 `.gitignore` 中忽略，仓库里只放 `*.example*` 模板；服务数据放在 Docker 数据卷中
- **后台服务不映射端口**：只加入外部网络 `proxy`，由 Caddy 通过容器名访问
- **域名变量统一命名为 `XXX_DOMAIN`**：Caddy 通过 `{$XXX_DOMAIN}` 引用，`rpctl dns sync` 会自动同步所有这类变量
- **一个服务 = `services/<name>/` + `proxy/sites/<name>.caddy`**，详见 [docs/adding-a-service.md](docs/adding-a-service.md)

## 文档

- [架构说明](docs/architecture.md)
- [Cloudflare 配置](docs/cloudflare.md)
- [服务器部署](docs/deploy.md)
- [新增服务](docs/adding-a-service.md)
- [Web SSH 服务](services/webssh/README.md)
