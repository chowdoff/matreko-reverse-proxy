# Cloudflare API 公共函数：被 cf-dns.sh、cf-tunnel.sh source
# 依赖：已 source common.sh 并执行 load_env

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
    if jq -e '.errors[]? | select(.code == 10000)' <<<"$resp" >/dev/null; then
      case "$path" in
        *dns_records*)
          err "提示：Token 缺少 DNS 权限。请在 Cloudflare 编辑该 Token，添加 Zone → DNS → Edit（注意不是“DNS Settings”），"
          err "      并确认 Zone Resources 包含 $CF_ZONE，见 docs/cloudflare.md"
          ;;
        *cfd_tunnel*)
          err "提示：Token 缺少 Tunnel 权限。请在 Cloudflare 编辑该 Token，添加 Account → Cloudflare Tunnel → Edit，"
          err "      并确认 Account Resources 包含域名所在账号，见 docs/cloudflare.md"
          ;;
      esac
    fi
    exit 1
  fi
  printf '%s' "$resp"
}

# zone_json —— CF_ZONE 对应的 Zone 信息（含 id、account.id）
zone_json() {
  : "${CF_ZONE:?请在 .env 中设置 CF_ZONE}"
  local z
  z="$(cf_api GET "/zones?name=$CF_ZONE" | jq -c '.result[0] // empty')"
  [[ -n "$z" ]] || die "找不到 Zone：$CF_ZONE（检查域名是否托管在该账号下、Token 是否有 Zone:Read 权限）"
  printf '%s' "$z"
}

zone_id() { zone_json | jq -r '.id'; }

# 只处理属于 CF_ZONE 的域名
in_zone() { [[ "$1" == "$CF_ZONE" || "$1" == *".$CF_ZONE" ]]; }

# 列出走 Tunnel 且属于 CF_ZONE 的域名（每行一个）
tunnel_zone_domains() {
  local var name
  for var in $(tunnel_domain_vars); do
    name="${!var:-}"
    [[ -n "$name" ]] && in_zone "$name" && printf '%s\n' "$name"
  done
  return 0
}

# ---------- Tunnel ----------

# tunnel_token_field a|t —— 从 CF_TUNNEL_TOKEN 解出账号 ID（a）或 Tunnel ID（t）
# Token 是 base64 编码的 JSON：{"a":账号ID,"t":TunnelID,"s":密钥}
tunnel_token_field() {
  [[ -n "${CF_TUNNEL_TOKEN:-}" ]] || die "CF_TUNNEL_TOKEN 为空，请先执行 ./rpctl tunnel create（见 docs/cloudflare.md）"
  local v
  v="$(printf '%s' "$CF_TUNNEL_TOKEN" | base64 -d 2>/dev/null | jq -er ".$1" 2>/dev/null)" ||
    die "CF_TUNNEL_TOKEN 格式不正确（应为 base64 编码的 JSON），请检查是否复制完整"
  printf '%s' "$v"
}

tunnel_path() { printf '/accounts/%s/cfd_tunnel/%s' "$(tunnel_token_field a)" "$(tunnel_token_field t)"; }

# 各域名 DNS 记录应指向的 CNAME 目标
tunnel_cname() { printf '%s.cfargotunnel.com' "$(tunnel_token_field t)"; }

# tunnel_ingress_sync DRY_RUN —— 把 Tunnel 站点的路由推送到 Tunnel（远程配置，cloudflared 自动生效，无需重启）
# 每个域名都转给 Caddy 的 8443，并以域名作为 TLS SNI（cloudflared 校验 Caddy 的证书）；其余请求返回 404
tunnel_ingress_sync() {
  local dry="$1" path want cur
  path="$(tunnel_path)"
  want="$(tunnel_zone_domains | jq -Rnc '
    [inputs | {hostname: ., service: "https://caddy:8443", originRequest: {originServerName: .}}]
    + [{service: "http_status:404"}]')"
  cur="$(cf_api GET "$path/configurations" | jq -c '.result.config.ingress // []')"
  # 只比较本项目关心的字段，忽略 Cloudflare 返回时补上的默认值
  local norm='[.[] | [.hostname, .service, .originRequest.originServerName]]'
  if [[ "$(jq -c "$norm" <<<"$want")" == "$(jq -c "$norm" <<<"$cur")" ]]; then
    ok "Tunnel 路由无需变更（$(jq -r '[.[].hostname // empty] | join(", ") | if . == "" then "无" else . end' <<<"$want")）"
    return
  fi
  if [[ "$dry" == 1 ]]; then
    info "[dry-run] 将更新 Tunnel 路由为："
    jq -r '.[] | "  \(.hostname // "其他") -> \(.service)"' <<<"$want"
    return
  fi
  cf_api PUT "$path/configurations" "$(jq -c '{config: {ingress: .}}' <<<"$want")" >/dev/null
  ok "已更新 Tunnel 路由："
  jq -r '.[] | "  \(.hostname // "其他") -> \(.service)"' <<<"$want"
}
