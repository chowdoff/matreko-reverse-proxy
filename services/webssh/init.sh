#!/usr/bin/env bash
# webssh 初始化：由 ./rpctl init 调用（已加载 .env 和 scripts/lib/common.sh）
# 从示例生成 sshwifty.conf.json：填入域名和随机访问口令。已存在则只检查不覆盖。
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="$dir/sshwifty.conf.json"
example="$dir/sshwifty.conf.example.json"

if [[ -f "$conf" ]]; then
  info "webssh: 已存在 $(relpath "$conf")，跳过生成"
  current_host="$(jq -r '.HostName' "$conf")"
  if [[ "$current_host" != "${WEBSSH_DOMAIN:-}" ]]; then
    warn "webssh: 配置中 HostName=$current_host 与 .env 中 WEBSSH_DOMAIN=${WEBSSH_DOMAIN:-} 不一致，Sshwifty 会拒绝该域名的访问"
  fi
  exit 0
fi

: "${WEBSSH_DOMAIN:?请先在 .env 中设置 WEBSSH_DOMAIN}"
key="$(gen_secret 24)"

umask 077
jq --arg host "$WEBSSH_DOMAIN" --arg key "$key" \
  '.HostName = $host | .SharedKey = $key' "$example" >"$conf"
chmod 600 "$conf"

ok "webssh: 已生成 $(relpath "$conf")"
printf '\n  Web SSH 访问口令（SharedKey）：%s\n  可随时在 %s 中查看或修改，修改后执行 ./rpctl restart webssh\n\n' \
  "$key" "$(relpath "$conf")"
