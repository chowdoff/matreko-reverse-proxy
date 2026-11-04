#!/usr/bin/env bash
# 公共函数库：被 rpctl 及其它脚本 source
# 依赖：调用方已设置 ROOT（项目根目录）

if [[ -t 1 ]]; then
  _c_red=$'\e[31m' _c_grn=$'\e[32m' _c_ylw=$'\e[33m' _c_blu=$'\e[34m' _c_rst=$'\e[0m'
else
  _c_red='' _c_grn='' _c_ylw='' _c_blu='' _c_rst=''
fi

info() { printf '%s[INFO]%s %s\n' "$_c_blu" "$_c_rst" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$_c_grn" "$_c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_c_ylw" "$_c_rst" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$_c_red" "$_c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 相对项目根目录的路径，便于输出
relpath() { printf '%s' "${1#"$ROOT"/}"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c，请先安装"
  done
}

# 生成 URL 安全的随机字符串
gen_secret() {
  local len="${1:-32}" s=''
  # 先读取定长随机字节再过滤，避免 tr|head 在 pipefail 下触发 SIGPIPE
  while [[ ${#s} -lt $len ]]; do
    s+="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${s:0:$len}"
}

# 加载 .env 到当前 shell 并导出
load_env() {
  local f="$ROOT/.env"
  [[ -f "$f" ]] || die "未找到 .env，请先运行 ./rpctl init"
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  # 供 compose 中 user: "${PUID}:${PGID}" 使用
  export PUID="${PUID:-$(id -u)}" PGID="${PGID:-$(id -g)}"

  # 配置了 Tunnel Token 时启用 proxy/compose.yaml 中的 cloudflared 服务
  if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then export COMPOSE_PROFILES=tunnel; fi
}

# env_set KEY VALUE —— 修改 .env 中的一项（不存在则追加），保持 600 权限
env_set() {
  local f="$ROOT/.env" tmp
  tmp="$(mktemp "$f.XXXXXX")"
  if grep -q "^$1=" "$f"; then
    awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$f" >"$tmp"
  else
    # 原文件末尾没有换行时先补一个，避免与最后一行粘连
    { cat "$f"; [[ -z "$(tail -c 1 "$f")" ]] || echo; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$f"
}

# env_unset KEY —— 删除 .env 中的一项，保持 600 权限
env_unset() {
  local f="$ROOT/.env" tmp
  tmp="$(mktemp "$f.XXXXXX")"
  awk -v k="$1" 'index($0, k "=") != 1' "$f" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$f"
}

# 列出 .env 中所有 *_DOMAIN 变量名
domain_vars() {
  grep -oE '^[A-Z0-9_]+_DOMAIN=' "$ROOT/.env" | tr -d '=' || true
}

# 列出所有站点文件：仓库跟踪的 proxy/sites/*.caddy，以及服务器本地的 proxy/sites/local/*.caddy（不入库）
site_files() {
  local f
  for f in "$ROOT"/proxy/sites/*.caddy "$ROOT"/proxy/sites/local/*.caddy; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# 列出走 Cloudflare Tunnel 的域名变量名：站点地址写成 {$XXX_DOMAIN}:8443 的
tunnel_domain_vars() {
  site_files | while read -r f; do cat "$f"; done |
    sed -nE 's/^\{\$([A-Z0-9_]+_DOMAIN)\}:8443([[:space:],{].*)?$/\1/p' | sort -u
}

# 列出站点文件用到、但 .env 中为空的域名变量，每行「变量名 站点文件」（需先 load_env）
missing_site_vars() {
  local f v
  while read -r f; do
    for v in $(grep -oE '\{\$[A-Z0-9_]+_DOMAIN\}' "$f" | tr -d '{}$' | sort -u); do
      [[ -n "${!v:-}" ]] || printf '%s %s\n' "$v" "$(relpath "$f")"
    done
  done < <(site_files)
}

# is_tunnel_var VAR —— 该域名变量是否走 Tunnel
is_tunnel_var() { tunnel_domain_vars | grep -qx "$1"; }

# 服务目录：仓库跟踪的 services/<name>，或服务器本地的 services/local/<name>（不入库）
service_dir() {
  local d
  for d in "$ROOT/services/$1" "$ROOT/services/local/$1"; do
    if [[ -f "$d/compose.yaml" ]]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

# 列出所有服务（含 compose.yaml 的服务目录）
list_services() {
  local d
  for d in "$ROOT"/services/*/ "$ROOT"/services/local/*/; do
    [[ -f "$d/compose.yaml" ]] && basename "$d"
  done
  return 0
}

# 目标名 -> compose 目录；proxy 为 Caddy 核心，其余为服务目录
target_dir() {
  case "$1" in
    proxy) printf '%s' "$ROOT/proxy" ;;
    *) service_dir "$1" || die "未知服务：$1（可用：proxy $(list_services | tr '\n' ' ')）" ;;
  esac
}

# 对某个目标执行 docker compose
dc() {
  local target="$1"; shift
  local dir
  dir="$(target_dir "$target")"
  docker compose --project-directory "$dir" -f "$dir/compose.yaml" --env-file "$ROOT/.env" "$@"
}

ensure_network() {
  if ! docker network inspect proxy >/dev/null 2>&1; then
    docker network create proxy >/dev/null
    ok "已创建 Docker 网络 proxy"
  fi
}
