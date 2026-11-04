#!/usr/bin/env bash
# Cloudflare Tunnel 管理
#   cf-tunnel.sh create [名称]  创建 Tunnel（远程配置模式），并把运行 Token 写入 .env 的 CF_TUNNEL_TOKEN
#   cf-tunnel.sh status         查看 Tunnel 状态、连接、路由
# Tunnel 的路由（哪些域名转给 Caddy）由 ./rpctl dns sync 根据 proxy/sites/*.caddy 推送
# 通常经由 ./rpctl tunnel <子命令> 调用
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_cmd curl jq base64
load_env
# shellcheck source=lib/cf.sh
source "$ROOT/scripts/lib/cf.sh"

cmd_create() {
  local name="${1:-matreko-reverse-proxy}"
  if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    local tid
    tid="$(tunnel_token_field t)"
    warn ".env 中已有 CF_TUNNEL_TOKEN（Tunnel ID：$tid），无需重复创建"
    cmd_status
    return
  fi

  local acc tunnel id
  acc="$(zone_json | jq -r '.account.id')"
  tunnel="$(cf_api GET "/accounts/$acc/cfd_tunnel?name=$name&is_deleted=false" | jq -c '.result[0] // empty')"
  if [[ -n "$tunnel" ]]; then
    id="$(jq -r '.id' <<<"$tunnel")"
    # 本地配置模式的 Tunnel 无法通过 API 推送路由
    [[ "$(jq -r '.remote_config' <<<"$tunnel")" != false ]] ||
      die "已存在同名 Tunnel $name，但它是本地配置模式（cloudflared tunnel create 创建），请换一个名称：./rpctl tunnel create <名称>"
    info "已存在同名 Tunnel $name（$id），直接复用"
  else
    local body
    body="$(jq -nc --arg n "$name" --arg s "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
      '{name: $n, config_src: "cloudflare", tunnel_secret: $s}')"
    id="$(cf_api POST "/accounts/$acc/cfd_tunnel" "$body" | jq -r '.result.id')"
    ok "已创建 Tunnel $name（$id）"
  fi

  env_set CF_TUNNEL_TOKEN "$(cf_api GET "/accounts/$acc/cfd_tunnel/$id/token" | jq -r '.result')"
  ok "已把运行 Token 写入 .env 的 CF_TUNNEL_TOKEN"
  info "下一步：./rpctl up && ./rpctl tunnel status && ./rpctl dns sync"
}

cmd_status() {
  local path tunnel
  path="$(tunnel_path)"
  tunnel="$(cf_api GET "$path" | jq -c '.result')"
  jq -r '"名称：\(.name)\nID：  \(.id)\n状态：\(.status)"' <<<"$tunnel"
  echo "连接："
  jq -r 'if (.connections // []) == [] then "  （无，确认 cloudflared 已启动：./rpctl logs proxy）"
    else .connections[] | "  \(.colo_name)  \(.origin_ip // "")  cloudflared \(.client_version // "")  since \(.opened_at // "")" end' <<<"$tunnel"
  echo "路由："
  cf_api GET "$path/configurations" |
    jq -r 'if (.result.config.ingress // []) == [] then "  （无，执行 ./rpctl dns sync 推送）"
      else .result.config.ingress[] | "  \(.hostname // "其他") -> \(.service)" end'
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  status) cmd_status ;;
  *) echo "用法：$0 {create [名称]|status}"; exit 1 ;;
esac
