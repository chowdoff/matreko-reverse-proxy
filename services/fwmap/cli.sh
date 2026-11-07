#!/usr/bin/env bash
# fwmap 服务命令：通过 ./rpctl fwmap <子命令> 调用（已加载 .env 和 scripts/lib/common.sh）
#   check   检查 DigitalOcean Token 权限、Cloudflare Access 配置和容器状态
set -euo pipefail

check_do_token() {
  local failed=0 ep code
  if [[ -z "${FWMAP_DO_TOKEN:-}" ]]; then
    err "FWMAP_DO_TOKEN 为空：在 DigitalOcean 控制台创建只读 Token，见 services/fwmap/README.md"
    return 1
  fi
  for ep in droplets firewalls vpcs; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
      -H "Authorization: Bearer $FWMAP_DO_TOKEN" "https://api.digitalocean.com/v2/$ep?per_page=1")" || code=000
    case "$code" in
      200) ok "DigitalOcean：可以读取 $ep" ;;
      401) err "DigitalOcean：Token 无效或已过期"; return 1 ;;
      403) err "DigitalOcean：Token 没有 ${ep%s}:read 权限"; failed=1 ;;
      000) err "DigitalOcean：连接 api.digitalocean.com 失败"; return 1 ;;
      *) err "DigitalOcean：读取 $ep 失败（HTTP $code）"; failed=1 ;;
    esac
  done
  # 只需要读取权限；能读账号信息的 Token 多半是 Full Access，泄露后可以改动防火墙
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
    -H "Authorization: Bearer $FWMAP_DO_TOKEN" "https://api.digitalocean.com/v2/account")" || code=000
  if [[ "$code" == 200 ]]; then
    warn "DigitalOcean：这个 Token 还能读取账号信息，可能是 Full Access Token；建议换成只有 droplet:read、firewall:read、vpc:read 的自定义 Token"
  fi
  return "$failed"
}

check_access() {
  if [[ -z "${FWMAP_ACCESS_TEAM:-}" || -z "${FWMAP_ACCESS_AUD:-}" ]]; then
    if [[ "${CADDY_TLS_MODE:-cloudflare}" == internal ]]; then
      warn "Cloudflare Access：没有配置（开发模式下允许，不校验访问者身份）"
      return 0
    fi
    err "Cloudflare Access：FWMAP_ACCESS_TEAM 或 FWMAP_ACCESS_AUD 为空，页面会拒绝所有访问"
    return 1
  fi
  local team="${FWMAP_ACCESS_TEAM#http*://}" n
  team="${team%%/*}"
  [[ "$team" == *.* ]] || team="$team.cloudflareaccess.com"
  n="$(curl -fsS -m 15 "https://$team/cdn-cgi/access/certs" 2>/dev/null | jq '.keys | length' 2>/dev/null)" || n=0
  if [[ "${n:-0}" -gt 0 ]]; then
    ok "Cloudflare Access：团队域名 $team 可用（$n 个签名公钥）"
  else
    err "Cloudflare Access：读取 https://$team/cdn-cgi/access/certs 失败，检查 FWMAP_ACCESS_TEAM"
    return 1
  fi
}

check_container() {
  local st
  st="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' fwmap 2>/dev/null)" || {
    warn "容器：fwmap 没有运行，执行 ./rpctl up fwmap"
    return 0
  }
  case "$st" in
    "running healthy") ok "容器：fwmap 运行中" ;;
    running*) warn "容器：fwmap 状态 $st" ;;
    *) err "容器：fwmap 状态 $st，查看 ./rpctl logs fwmap"; return 1 ;;
  esac
  # 最近一次同步结果（容器日志里最后一条同步记录）
  docker logs fwmap 2>&1 | grep -E '同步(完成|失败)' | tail -1 | sed 's/^/       /' || true
}

cmd_check() {
  local failed=0
  check_do_token || failed=1
  check_access || failed=1
  check_container || failed=1
  [[ $failed -eq 0 ]] && ok "检查通过" || die "检查未通过"
}

case "${1:-}" in
  check) cmd_check ;;
  *)
    echo "用法：./rpctl fwmap check   检查 DigitalOcean Token 权限、Cloudflare Access 配置和容器状态"
    exit 1
    ;;
esac
