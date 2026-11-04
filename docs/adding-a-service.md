# 新增服务

以新增一个名为 `foo`、容器内监听 `3000` 端口的服务为例。

## 1. 创建服务目录

```bash
cp -r templates/service services/foo
mv services/foo/site.caddy proxy/sites/foo.caddy
```

编辑 `services/foo/compose.yaml`：

- `name: rp-foo`
- 镜像、容器名（容器名即 Caddy 中的上游主机名）
- **不要写 `ports:`**，只加入 `proxy` 网络
- 需要密钥的配置：在仓库里放 `*.example` 模板，用 `init.sh` 生成真实文件，并把真实文件加入 `.gitignore`

## 2. 添加路由

编辑 `proxy/sites/foo.caddy`：

```caddyfile
{$FOO_DOMAIN} {
	import common
	reverse_proxy foo:3000
}
```

### 选择接入方式

| 站点地址 | 接入方式 | 适用 |
| --- | --- | --- |
| `{$FOO_DOMAIN}` | 公网 443，DNS 指向服务器 IP（橙色云朵） | 默认，普通网页、API |
| `{$FOO_DOMAIN}:8443` | Cloudflare Tunnel | WebSocket 长连接等经橙色云朵不稳定的服务，或不希望在公网端口上提供的服务 |

走 Tunnel 时，再加一个站点，让公网 80 端口不为该域名跳转（否则会暴露本机托管了该域名）：

```caddyfile
{$FOO_DOMAIN}:8443 {
	import common
	reverse_proxy foo:3000
}

http://{$FOO_DOMAIN} {
	abort
}
```

`rpctl dns sync` 会识别地址写成 `{$XXX_DOMAIN}:8443` 的站点：为它们推送 Tunnel 路由并创建 CNAME，其余域名创建 A/AAAA 记录。站点地址需要单独占一行，且以 `{$XXX_DOMAIN}` 开头。两种方式可随时切换，改完执行 `./rpctl reload && ./rpctl dns sync` 即可。

## 3. 添加域名变量

在 `.env.example` 和 `.env` 中添加：

```ini
FOO_DOMAIN=foo.example.com
```

## 4. 上线

```bash
./rpctl init          # 如果有 init.sh
./rpctl check
./rpctl dns sync      # 新域名的 DNS 记录（Tunnel 站点同时推送 Tunnel 路由）
./rpctl up           # 启动 foo；.env 有变化时会自动重建 Caddy 容器以读取新变量
```

> Caddy 的环境变量来自 `.env`，只在容器创建时读取：改了 `.env` 要用 `./rpctl up`（会自动重建），`restart`/`reload` 读不到新变量。只改了 `sites/*.caddy` 时用 `./rpctl reload` 热加载即可。

## 5. 文档

- 在 `services/foo/README.md` 写明用途、配置项、注意事项
- 在根目录 `README.md` 的「已接入服务」中登记

## 常用 Caddy 片段

```caddyfile
# 后端是 HTTPS（自签证书）
reverse_proxy https://backend:8443 {
	transport http {
		tls_insecure_skip_verify
	}
}

# Basic Auth（密码哈希用 docker run --rm caddy caddy hash-password 生成）
basic_auth {
	admin $2a$14$...
}

# 只允许特定 IP（注意开启 CF 代理时 client_ip 已是真实 IP）
@denied not client_ip 1.2.3.4/32 10.0.0.0/8
respond @denied 403
```
