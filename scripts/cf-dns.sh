#!/usr/bin/env bash
# Cloudflare DNS 管理
#   cf-dns.sh verify            校验 API Token 是否有效
#   cf-dns.sh list              列出 .env 中各 *_DOMAIN 当前的 DNS 记录
#   cf-dns.sh sync [--dry-run]  把各 *_DOMAIN 的 A/AAAA 记录指向 SERVER_IPV4/SERVER_IPV6（存在则更新，不存在则创建）
# 通常经由 ./rpctl dns <子命令> 调用
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_cmd curl jq
load_env

CF_API="https://api.cloudflare.com/client/v4"
: "${CF_API_TOKEN:?请在 .env 中设置 CF_API_TOKEN}"

# cf_api METHOD PATH [JSON_BODY]  —— 失败时打印 Cloudflare 返回的错误并退出
cf_api() {
  local method="$1" path="$2" body="${3:-}" resp
  local args=(-sS -X "$method" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  resp="$(curl "${args[@]}" "$CF_API$path")" || die "请求 Cloudflare API 失败：$method $path"
  if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
    err "Cloudflare API 错误（$method $path）：$(jq -c '.errors' <<<"$resp")"
    if [[ "$path" == *dns_records* ]] && jq -e '.errors[]? | select(.code == 10000)' <<<"$resp" >/dev/null; then
      err "提示：Token 缺少 DNS 权限。请在 Cloudflare 编辑该 Token，添加 Zone → DNS → Edit（注意不是“DNS Settings”），"
      err "      并确认 Zone Resources 包含 $CF_ZONE，见 docs/cloudflare.md"
    fi
    exit 1
  fi
  printf '%s' "$resp"
}

zone_id() {
  : "${CF_ZONE:?请在 .env 中设置 CF_ZONE}"
  local id
  id="$(cf_api GET "/zones?name=$CF_ZONE" | jq -r '.result[0].id // empty')"
  [[ -n "$id" ]] || die "找不到 Zone：$CF_ZONE（检查域名是否托管在该账号下、Token 是否有 Zone:Read 权限）"
  printf '%s' "$id"
}

# 只处理属于 CF_ZONE 的域名
in_zone() { [[ "$1" == "$CF_ZONE" || "$1" == *".$CF_ZONE" ]]; }

cmd_verify() {
  local status
  status="$(cf_api GET "/user/tokens/verify" | jq -r '.result.status')"
  ok "Token 有效，状态：$status"
  local zid
  zid="$(zone_id)"
  ok "Zone $CF_ZONE 的 ID：$zid"
  cf_api GET "/zones/$zid/dns_records?per_page=1" >/dev/null
  ok "Token 可读取 $CF_ZONE 的 DNS 记录（编辑权限会在 dns sync / 申请证书时验证）"
}

cmd_list() {
  local zid var name
  zid="$(zone_id)"
  printf '%-10s %-32s %-6s %-40s %s\n' VAR NAME TYPE CONTENT PROXIED
  for var in $(domain_vars); do
    name="${!var:-}"
    [[ -n "$name" ]] || continue
    if ! in_zone "$name"; then
      printf '%-10s %-32s %s\n' "${var%_DOMAIN}" "$name" "(不属于 $CF_ZONE，跳过)"
      continue
    fi
    cf_api GET "/zones/$zid/dns_records?name=$name" |
      jq -r --arg v "${var%_DOMAIN}" '.result[] | [$v, .name, .type, .content, .proxied] | @tsv' |
      while IFS=$'\t' read -r v n t c p; do printf '%-10s %-32s %-6s %-40s %s\n' "$v" "$n" "$t" "$c" "$p"; done
  done
}

# upsert ZONE_ID NAME TYPE CONTENT DRY_RUN
upsert() {
  local zid="$1" name="$2" type="$3" content="$4" dry="$5"
  local proxied="${CF_PROXIED:-true}" existing rid cur_content cur_proxied body
  existing="$(cf_api GET "/zones/$zid/dns_records?type=$type&name=$name")"
  rid="$(jq -r '.result[0].id // empty' <<<"$existing")"
  body="$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" --argjson p "$proxied" \
    '{type:$t, name:$n, content:$c, proxied:$p, ttl:1, comment:"managed by matreko-reverse-proxy"}')"

  if [[ -z "$rid" ]]; then
    if [[ "$dry" == 1 ]]; then info "[dry-run] 将创建 $type $name -> $content (proxied=$proxied)"; return; fi
    cf_api POST "/zones/$zid/dns_records" "$body" >/dev/null
    ok "已创建 $type $name -> $content (proxied=$proxied)"
    return
  fi

  cur_content="$(jq -r '.result[0].content' <<<"$existing")"
  cur_proxied="$(jq -r '.result[0].proxied' <<<"$existing")"
  if [[ "$cur_content" == "$content" && "$cur_proxied" == "$proxied" ]]; then
    ok "无需变更 $type $name -> $content (proxied=$proxied)"
    return
  fi
  if [[ "$dry" == 1 ]]; then
    info "[dry-run] 将更新 $type $name：$cur_content (proxied=$cur_proxied) -> $content (proxied=$proxied)"
    return
  fi
  cf_api PUT "/zones/$zid/dns_records/$rid" "$body" >/dev/null
  ok "已更新 $type $name：$cur_content -> $content (proxied=$proxied)"
}

cmd_sync() {
  local dry=0
  [[ "${1:-}" == "--dry-run" ]] && dry=1
  [[ -n "${SERVER_IPV4:-}${SERVER_IPV6:-}" ]] || die "请在 .env 中设置 SERVER_IPV4 和/或 SERVER_IPV6"

  local zid var name
  zid="$(zone_id)"
  for var in $(domain_vars); do
    name="${!var:-}"
    [[ -n "$name" ]] || { warn "$var 为空，跳过"; continue; }
    in_zone "$name" || { warn "$name 不属于 $CF_ZONE，跳过"; continue; }
    if [[ -n "${SERVER_IPV4:-}" ]]; then upsert "$zid" "$name" A "$SERVER_IPV4" "$dry"; fi
    if [[ -n "${SERVER_IPV6:-}" ]]; then upsert "$zid" "$name" AAAA "$SERVER_IPV6" "$dry"; fi
  done
}

case "${1:-}" in
  verify) cmd_verify ;;
  list) cmd_list ;;
  sync) shift; cmd_sync "$@" ;;
  *) echo "用法：$0 {verify|list|sync [--dry-run]}"; exit 1 ;;
esac
