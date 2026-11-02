# Web SSH（Termix）

基于 [Termix](https://github.com/Termix-SSH/Termix) 的浏览器 SSH 管理平台，访问地址为 `https://$WEBSSH_DOMAIN`。

- 主机可命名，支持文件夹、标签分组，一眼分辨连接
- 密码 / 私钥加密保存在服务端，连接时无需重复输入；凭据可在多台主机间复用
- 独立账号体系，支持 TOTP 两步验证
- 附带 SFTP 文件管理、SSH 隧道、命令片段等功能

## 文件

| 文件 | 说明 |
| --- | --- |
| `compose.yaml` | 容器定义：镜像版本锁定、只加入 `proxy` 网络、不映射端口 |
| `cli.sh` | 服务命令，通过 `./rpctl webssh <子命令>` 调用 |
| 数据卷 `rp-webssh_termix_data` | 加密数据库、**加密密钥**（`/app/data/.env`）、上传文件 |

## 首次使用

### 1. 启动并创建管理员

```bash
./rpctl up webssh
./rpctl webssh add-user admin      # 交互输入密码；第一个账号自动成为管理员
```

> **注册接口已在 Caddy 层对公网屏蔽**（见 `proxy/sites/webssh.caddy`），网页上的注册按钮会返回 403，防止陌生人抢先注册成为管理员。需要更多账号时同样用 `./rpctl webssh add-user <用户名>` 在服务器上创建。

### 2. 登录并开启两步验证

打开 `https://$WEBSSH_DOMAIN` 用刚创建的账号登录，然后在个人设置的安全选项中**开启 TOTP 两步验证**（用 Google Authenticator、1Password 等扫码），并保存好备用码。

### 3. 添加主机

在主机管理（Host Manager）中添加主机：

| 字段 | 建议 |
| --- | --- |
| 名称 | 起好认的名字，如「生产 Web 服务器」 |
| 地址 / 端口 | 内网 IP 或域名；部署 Termix 的这台服务器本身填 `host.docker.internal` |
| 文件夹 / 标签 | 按环境、项目分组，如 `生产`、`测试` |
| 认证 | 选择密码或私钥并填写，保存后即被加密存储，之后点击即连 |

多台主机共用同一套账号密码或密钥时，可以先在凭据（Credentials）中创建一份，再在各主机中引用，修改时只需改一处。

## 安全说明

- **注册**：公网注册被屏蔽，账号只能在服务器上创建
- **凭据加密**：密码、私钥使用按用户的密钥加密，数据库文件本身也加密；加密密钥在数据卷中自动生成
- **备份即密钥**：`./rpctl backup` 生成的 `rp-webssh_termix_data.tgz` 同时包含加密数据和密钥，拿到它等于拿到所有保存的服务器凭据，务必妥善保管
- **真实 IP**：容器只信任 Docker 内网（`TRUSTED_PROXIES=172.16.0.0/12`）传来的 `X-Forwarded-For`，登录日志、审计日志中记录真实客户端 IP
- 建议目标主机 sshd 只允许密钥登录，并为 Termix 使用单独的低权限用户

## 常用操作

```bash
./rpctl webssh add-user <用户名>   # 创建账号
./rpctl logs webssh -f             # 查看日志
./rpctl restart webssh             # 重启
./rpctl backup                     # 备份（含 Termix 数据卷）
```

### 升级

镜像版本锁定在 `compose.yaml` 中（`ghcr.io/termix-ssh/termix:<版本>`）。升级时修改版本号并提交，服务器上：

```bash
git pull
./rpctl backup                     # 升级前先备份
./rpctl pull webssh && ./rpctl up webssh
```

也可以不改仓库，在服务器 `.env` 中设置 `TERMIX_IMAGE=ghcr.io/termix-ssh/termix:<版本>` 临时覆盖。

### 服务器拉取镜像太慢

镜像约 190MB，托管在 ghcr.io。服务器拉取过慢时可从开发机直接传过去：

```bash
# 开发机
docker pull ghcr.io/termix-ssh/termix:26.11.0
docker save ghcr.io/termix-ssh/termix:26.11.0 | gzip | ssh root@<服务器> 'gunzip | docker load'
```

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 网页注册返回 403 | 正常，用 `./rpctl webssh add-user` 创建账号 |
| 连接本机超时 | 宿主机防火墙拦截了 Docker 网段访问 22，见 [deploy.md 防火墙](../../docs/deploy.md#防火墙) |
| root 密码登录失败 | 默认 `PermitRootLogin prohibit-password`，改用普通用户或私钥 |
| 所有用户密码都失败 | 云镜像常设置 `PasswordAuthentication no`（见 `/etc/ssh/sshd_config.d/`），改用私钥 |
| 忘记管理员密码 / 丢失 TOTP | 用 `./rpctl webssh add-user` 无法提权，需从备份恢复，或停服后清空数据卷重建（会丢失全部保存的主机） |

查看 sshd 实际生效的配置：

```bash
sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|pubkeyauthentication'
```
