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
}

# 列出 .env 中所有 *_DOMAIN 变量名
domain_vars() {
  grep -oE '^[A-Z0-9_]+_DOMAIN=' "$ROOT/.env" | tr -d '=' || true
}

# 列出所有服务（services/ 下含 compose.yaml 的目录）
list_services() {
  local d
  for d in "$ROOT"/services/*/; do
    [[ -f "$d/compose.yaml" ]] && basename "$d"
  done
}

# 目标名 -> compose 目录；proxy 为 Caddy 核心，其余为 services/<name>
target_dir() {
  case "$1" in
    proxy) printf '%s' "$ROOT/proxy" ;;
    *)
      [[ -f "$ROOT/services/$1/compose.yaml" ]] || die "未知服务：$1（可用：proxy $(list_services | tr '\n' ' ')）"
      printf '%s' "$ROOT/services/$1"
      ;;
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
