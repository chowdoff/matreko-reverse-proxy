# 自定义 Caddy 镜像：官方镜像 + Cloudflare 相关插件
#   - caddy-dns/cloudflare      : DNS-01 方式申请证书（无需开放 80 端口验证，支持通配符）
#   - caddy-cloudflare-ip       : 自动拉取 Cloudflare 回源 IP 段，用于 trusted_proxies 获取真实客户端 IP
ARG CADDY_VERSION=2.11.7

FROM caddy:${CADDY_VERSION}-builder AS builder
# 国内网络构建可覆盖为 https://goproxy.cn,direct
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY}
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/WeidiDeng/caddy-cloudflare-ip

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
