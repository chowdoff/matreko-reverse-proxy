#!/usr/bin/env bash
# Cloudflare DNS 管理
#   cf-dns.sh verify            校验 API Token 权限（有 Tunnel 站点或 Tunnel Token 时同时检查 Tunnel）
#   cf-dns.sh list              列出 .env 中各 *_DOMAIN 当前的 DNS 记录
#   cf-dns.sh sync [--dry-run]  把各 *_DOMAIN 发布到 Cloudflare，接入方式由站点文件决定（见 proxy/Caddyfile）：
#     Tunnel 站点（{$XXX_DOMAIN}:8443）  推送 Tunnel 路由，DNS 为指向 Tunnel 的 CNAME（必然开启代理）
#     其他站点                          DNS 为指向 SERVER_IPV4/SERVER_IPV6 的 A/AAAA，代理开关由 CF_PROXIED 决定
#   *_DOMAIN 对应的域名归本项目管理：同名的其他 A/AAAA/CNAME 记录会被删除（切换接入方式时自动替换）
# 通常经由 ./rpctl dns <子命令> 调用
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_cmd curl jq
load_env
# shellcheck source=lib/cf.sh
source "$ROOT/scripts/lib/cf.sh"

COMMENT="managed by matreko-reverse-proxy"

cmd_verify() {
  local status zid
  status="$(cf_api GET "/user/tokens/verify" | jq -r '.result.status')"
  ok "Token 有效，状态：$status"
  zid="$(zone_id)"
  ok "Zone $CF_ZONE 的 ID：$zid"
  cf_api GET "/zones/$zid/dns_records?per_page=1" >/dev/null
  ok "Token 可读取 $CF_ZONE 的 DNS 记录（编辑权限会在 dns sync / 申请证书时验证）"
  if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    local path t
    path="$(tunnel_path)"
    t="$(cf_api GET "$path" | jq -r '.result | "\(.name)（状态：\(.status)）"')"
    ok "Token 可访问 Tunnel：$t"
  elif [[ -n "$(tunnel_domain_vars)" ]]; then
    # 还没创建 Tunnel：检查 Token 能否列出账号下的 Tunnel（即是否有 Cloudflare Tunnel 权限）
    local acc
    acc="$(zone_json | jq -r '.account.id')"
    cf_api GET "/accounts/$acc/cfd_tunnel?per_page=1&is_deleted=false" >/dev/null
    ok "Token 有 Cloudflare Tunnel 权限（尚未创建 Tunnel，下一步：./rpctl tunnel create）"
  fi
}

cmd_list() {
  local zid var name
  zid="$(zone_id)"
  printf '%-10s %-7s %-32s %-6s %-48s %s\n' VAR INGRESS NAME TYPE CONTENT PROXIED
  local mode
  for var in $(domain_vars); do
    name="${!var:-}"
    [[ -n "$name" ]] || continue
    if is_tunnel_var "$var"; then mode=tunnel; else mode=direct; fi
    if ! in_zone "$name"; then
      printf '%-10s %-7s %-32s %s\n' "${var%_DOMAIN}" "$mode" "$name" "(不属于 $CF_ZONE，跳过)"
      continue
    fi
    cf_api GET "/zones/$zid/dns_records?name=$name" |
      jq -r --arg v "${var%_DOMAIN}" --arg m "$mode" '.result[] | [$v, $m, .name, .type, .content, .proxied] | @tsv' |
      while IFS=$'\t' read -r v m n t c p; do printf '%-10s %-7s %-32s %-6s %-48s %s\n' "$v" "$m" "$n" "$t" "$c" "$p"; done
  done
}

# sync_name ZONE_ID NAME PROXIED DRY_RUN TYPE=CONTENT...
# 使 NAME 的 A/AAAA/CNAME 记录恰好为给定的若干条
sync_name() {
  local zid="$1" name="$2" proxied="$3" dry="$4"
  shift 4
  local existing types rec
  existing="$(cf_api GET "/zones/$zid/dns_records?name=$name&per_page=100" |
    jq -c '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")]')"
  types="$(printf '%s\n' "$@" | cut -d= -f1 | jq -Rnc '[inputs]')"

  # 先删除：类型不需要的记录（如切换到 Tunnel 后的 A 记录），以及同类型的多余记录
  # CNAME 不能与 A/AAAA 共存，必须先删后建
  jq -c --argjson t "$types" \
    'group_by(.type) | map(if (.[0].type | IN($t[])) then .[1:] else . end) | add // [] | .[]' <<<"$existing" |
    while read -r rec; do
      local d
      d="$(jq -r '"\(.type) \(.name) -> \(.content) (proxied=\(.proxied))"' <<<"$rec")"
      if [[ "$dry" == 1 ]]; then info "[dry-run] 将删除 $d"; continue; fi
      cf_api DELETE "/zones/$zid/dns_records/$(jq -r '.id' <<<"$rec")" >/dev/null
      ok "已删除 $d"
    done

  local item type content rid cur body
  for item in "$@"; do
    type="${item%%=*}" content="${item#*=}"
    rec="$(jq -c --arg t "$type" '[.[] | select(.type == $t)][0] // empty' <<<"$existing")"
    body="$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" --argjson p "$proxied" --arg m "$COMMENT" \
      '{type:$t, name:$n, content:$c, proxied:$p, ttl:1, comment:$m}')"
    if [[ -z "$rec" ]]; then
      if [[ "$dry" == 1 ]]; then info "[dry-run] 将创建 $type $name -> $content (proxied=$proxied)"; continue; fi
      cf_api POST "/zones/$zid/dns_records" "$body" >/dev/null
      ok "已创建 $type $name -> $content (proxied=$proxied)"
      continue
    fi
    rid="$(jq -r '.id' <<<"$rec")"
    cur="$(jq -r '"\(.content) (proxied=\(.proxied))"' <<<"$rec")"
    if [[ "$cur" == "$content (proxied=$proxied)" ]]; then
      ok "无需变更 $type $name -> $cur"
      continue
    fi
    if [[ "$dry" == 1 ]]; then info "[dry-run] 将更新 $type $name：$cur -> $content (proxied=$proxied)"; continue; fi
    cf_api PUT "/zones/$zid/dns_records/$rid" "$body" >/dev/null
    ok "已更新 $type $name：$cur -> $content (proxied=$proxied)"
  done
}

cmd_sync() {
  local dry=0
  [[ "${1:-}" == "--dry-run" ]] && dry=1

  local direct_records=() direct_proxied="${CF_PROXIED:-true}"
  [[ "$direct_proxied" == true || "$direct_proxied" == false ]] || die "CF_PROXIED 只能是 true 或 false（当前：$direct_proxied）"
  if [[ -n "${SERVER_IPV4:-}" ]]; then direct_records+=("A=$SERVER_IPV4"); fi
  if [[ -n "${SERVER_IPV6:-}" ]]; then direct_records+=("AAAA=$SERVER_IPV6"); fi

  # 有 Tunnel 站点时，先让 Tunnel 认识这些域名，再把 DNS 切过去，避免切换瞬间出现 404
  local has_tunnel=0
  if [[ -n "$(tunnel_domain_vars)" ]]; then
    has_tunnel=1
    [[ -n "${CF_TUNNEL_TOKEN:-}" ]] ||
      die "$(tunnel_domain_vars | tr '\n' ' ')走 Tunnel，但 CF_TUNNEL_TOKEN 为空，请先执行 ./rpctl tunnel create"
    tunnel_ingress_sync "$dry"
  elif [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    tunnel_ingress_sync "$dry" # 没有 Tunnel 站点了：清空路由
  fi

  local zid var name
  zid="$(zone_id)"
  for var in $(domain_vars); do
    name="${!var:-}"
    [[ -n "$name" ]] || { warn "$var 为空，跳过"; continue; }
    in_zone "$name" || { warn "$name 不属于 $CF_ZONE，跳过"; continue; }
    if [[ $has_tunnel == 1 ]] && is_tunnel_var "$var"; then
      info "$name：Tunnel"
      local cname
      cname="$(tunnel_cname)"
      sync_name "$zid" "$name" true "$dry" "CNAME=$cname" # Tunnel 的 CNAME 必须开启代理
    else
      [[ ${#direct_records[@]} -gt 0 ]] || die "$name 走公网 443，请在 .env 中设置 SERVER_IPV4 和/或 SERVER_IPV6"
      info "$name：公网 443（proxied=$direct_proxied）"
      sync_name "$zid" "$name" "$direct_proxied" "$dry" "${direct_records[@]}"
    fi
  done
}

case "${1:-}" in
  verify) cmd_verify ;;
  list) cmd_list ;;
  sync) shift; cmd_sync "$@" ;;
  *) echo "用法：$0 {verify|list|sync [--dry-run]}"; exit 1 ;;
esac
