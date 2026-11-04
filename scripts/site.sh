#!/usr/bin/env bash
# 服务器本地的公网 443 站点，经由 ./rpctl site <子命令> 调用
#   site add [名称]      交互式添加站点，写入后可以立即部署
#   site remove [名称]   删除 site add 添加的站点
#
# 这些配置只保存在本机，不进入仓库（已在 .gitignore 中忽略），由 ./rpctl backup 备份：
#   proxy/sites/local/<名称>.caddy          站点文件
#   services/local/<名称>/compose.yaml      新建 Docker 服务时的后端
#   .env 中的 <名称>_DOMAIN                 域名
#
# add 的部署步骤：rpctl check → dns sync → 启动后端并重建 Caddy（读取新的 .env）→ 在本机验证 HTTPS
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

SITE_DIR="$ROOT/proxy/sites/local"
SVC_DIR="$ROOT/services/local"

NAME="" VAR="" DOMAIN="" DESC=""
BACKEND="" IMAGE="" PORT="" DATA_PATH="" UPSTREAM="" SKIP_VERIFY=0

# ---------- 输入 ----------

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# ask 提示 [默认值] —— 结果在 REPLY
ask() {
  local p="$1" d="${2:-}" a
  [[ -z "$d" ]] || p+=" [$d]"
  read -r -p "$p：" a || { echo; die "已取消"; }
  a="$(trim "$a")"
  REPLY="${a:-$d}"
}

# confirm 问题 [y|n] —— 第二个参数为直接回车时的默认值
confirm() {
  local d="${2:-y}" hint="[Y/n]" a
  [[ "$d" == y ]] || hint="[y/N]"
  read -r -p "$1 $hint " a || { echo; die "已取消"; }
  a="$(trim "${a:-$d}")"
  [[ "$a" == [Yy]* ]]
}

valid_name() {
  local n="$1" v
  if [[ ! "$n" =~ ^[a-z][a-z0-9-]{0,29}$ || "$n" == *- ]]; then
    err "名称只能包含小写字母、数字和 -，以字母开头，最长 30 个字符"
    return 1
  fi
  case "$n" in
    proxy | local | caddy | cloudflared) err "$n 是保留名称"; return 1 ;;
  esac
  if [[ -e "$ROOT/proxy/sites/$n.caddy" || -e "$SITE_DIR/$n.caddy" ]]; then
    err "站点 $n 已存在"; return 1
  fi
  if [[ -e "$ROOT/services/$n" || -e "$SVC_DIR/$n" ]]; then
    err "服务 $n 已存在"; return 1
  fi
  v="$(printf '%s' "$n" | tr 'a-z-' 'A-Z_')_DOMAIN"
  if grep -q "^$v=" "$ROOT/.env"; then
    err ".env 中已有 $v"; return 1
  fi
}

valid_port() {
  if [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); then return 0; fi
  err "端口应为 1-65535 之间的数字"
  return 1
}

ask_name() {
  if [[ -n "${1:-}" ]]; then
    valid_name "$1" || exit 1
    NAME="$1"
  else
    while true; do
      ask "站点名称（用作站点文件名、服务名和容器名，如 blog）"
      valid_name "$REPLY" && break
    done
    NAME="$REPLY"
  fi
  VAR="$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')_DOMAIN"
}

default_domain() {
  if [[ "${CADDY_TLS_MODE:-cloudflare}" == internal ]]; then
    echo "$NAME.localhost"
  elif [[ -n "${CF_ZONE:-}" && "$CF_ZONE" != example.com ]]; then
    echo "$NAME.$CF_ZONE"
  fi
}

valid_domain() {
  local d="$1" v
  if [[ ! "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    err "域名格式不对：$d"
    return 1
  fi
  for v in $(domain_vars); do
    if [[ "${!v:-}" == "$d" ]]; then
      err "$d 已被 $v 使用"
      return 1
    fi
  done
  if [[ "${CADDY_TLS_MODE:-cloudflare}" == cloudflare && "$d" != "$CF_ZONE" && "$d" != *".$CF_ZONE" ]]; then
    warn "$d 不属于 CF_ZONE（$CF_ZONE）：dns sync 不会为它创建 DNS 记录，Caddy 也无法为它申请证书"
    confirm "仍然使用？" n || return 1
  fi
}

ask_domain() {
  while true; do
    ask "域名" "$(default_domain)"
    REPLY="${REPLY,,}"
    if [[ -z "$REPLY" ]]; then err "域名不能为空"; continue; fi
    valid_domain "$REPLY" && break
  done
  DOMAIN="$REPLY"
}

ask_backend() {
  echo
  echo "后端类型："
  echo "  1) 新建 Docker 服务：生成 services/local/$NAME/compose.yaml，容器只加入 proxy 网络"
  echo "  2) 已有的服务：proxy 网络中的其他容器，或本机、VPC 内其他服务器上的端口"
  while true; do
    ask "选择" 1
    case "$REPLY" in
      1) BACKEND=docker; ask_docker; return ;;
      2) BACKEND=upstream; ask_upstream; return ;;
      *) err "请输入 1 或 2" ;;
    esac
  done
}

ask_docker() {
  if docker container inspect "$NAME" >/dev/null 2>&1; then
    die "已有名为 $NAME 的容器，请换一个名称"
  fi
  while true; do
    ask "镜像（如 nginx:1.27-alpine）"
    [[ "$REPLY" =~ ^[a-z0-9][A-Za-z0-9._/:@-]*$ ]] && break
    err "镜像名格式不对"
  done
  IMAGE="$REPLY"
  local last="${IMAGE##*/}"
  if [[ "$last" != *[:@]* || "$last" == *:latest ]]; then
    warn "建议写明版本号（如 nginx:1.27-alpine），避免 pull 时意外升级"
  fi
  while true; do
    ask "容器内监听的 HTTP 端口"
    valid_port "$REPLY" && break
  done
  PORT="$((10#$REPLY))"
  while true; do
    ask "需要持久化的容器内目录（如 /data；留空表示不挂载数据卷）"
    [[ -z "$REPLY" || "$REPLY" == /* ]] && break
    err "请填写绝对路径"
  done
  DATA_PATH="$REPLY"
}

ask_upstream() {
  echo "  填写 Caddy 访问后端的地址，格式为 [http(s)://]主机:端口，例如："
  echo "    app:3000                  proxy 网络中名为 app 的容器"
  echo "    10.104.0.5:8080           本机或 VPC 内其他服务器（填内网 IP，服务要监听该地址）"
  echo "    https://10.104.0.5:8443   后端本身是 HTTPS"
  local host
  while true; do
    ask "后端地址"
    if [[ ! "$REPLY" =~ ^(https?://)?(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then
      err "格式应为 [http(s)://]主机:端口"
      continue
    fi
    host="${BASH_REMATCH[2]}"
    valid_port "${BASH_REMATCH[3]}" || continue
    case "${host,,}" in
      localhost | 127.* | '[::1]' | 0.0.0.0)
        err "Caddy 运行在容器里，$host 指的是 Caddy 容器自己。本机上的服务请填本机内网 IP"
        continue
        ;;
      host.docker.internal)
        err "Caddy 容器没有配置 host.docker.internal，本机上的服务请填本机内网 IP"
        continue
        ;;
    esac
    break
  done
  UPSTREAM="$REPLY"

  # 不含点的主机名视为容器名，检查它是否在 proxy 网络中
  if [[ "$host" != *.* && "$host" != \[* ]] &&
    ! docker network inspect proxy -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null |
    tr ' ' '\n' | grep -qxF "$host"; then
    warn "proxy 网络中目前没有名为 $host 的容器，请确认它会加入 proxy 网络"
  fi
  if [[ "$UPSTREAM" == https://* ]]; then
    local d=n
    [[ "$host" =~ ^[0-9.]+$ || "$host" == \[* ]] && d=y
    if confirm "后端证书是自签的吗（跳过证书校验）？" "$d"; then SKIP_VERIFY=1; fi
  fi
}

# ---------- 生成文件 ----------

gen_site() {
  local target backend
  if [[ "$BACKEND" == docker ]]; then
    target="$NAME:$PORT"
    backend="services/local/$NAME，容器名 $NAME，监听 $PORT，仅加入 proxy 网络，不对外暴露端口"
  else
    target="$UPSTREAM"
    backend="$UPSTREAM"
  fi
  cat <<EOF
# $DESC
# 由 ./rpctl site add 生成，只保存在本机（不入库）；删除用 ./rpctl site remove $NAME
# 后端：$backend
# 接入方式：公网 443（Cloudflare 橙色云朵回源），见 docs/cloudflare.md
{\$$VAR} {
	import common

EOF
  if [[ $SKIP_VERIFY == 1 ]]; then
    cat <<EOF
	reverse_proxy $target {
		# 后端使用自签证书
		transport http {
			tls_insecure_skip_verify
		}
	}
}
EOF
  else
    printf '\treverse_proxy %s\n}\n' "$target"
  fi
}

gen_compose() {
  cat <<EOF
# $DESC
# 由 ./rpctl site add 生成，只保存在本机（不入库）
# 通过 ./rpctl up $NAME 启动，经 Caddy 以 https://\$$VAR 访问（proxy/sites/local/$NAME.caddy）
name: rp-$NAME

services:
  $NAME:
    image: $IMAGE
    container_name: $NAME # Caddy 通过此名称访问
    restart: unless-stopped
    environment:
      TZ: UTC # 所有容器统一用 UTC，与 Caddy、cloudflared 日志一致
EOF
  if [[ -n "$DATA_PATH" ]]; then
    cat <<EOF
    volumes:
      # 数据 —— 需要备份（./rpctl backup）
      - data:$DATA_PATH
EOF
  fi
  cat <<EOF
    networks:
      - proxy
    # 不要映射 ports：只经由 Caddy 访问
    security_opt:
      - no-new-privileges:true

EOF
  if [[ -n "$DATA_PATH" ]]; then printf 'volumes:\n  data:\n\n'; fi
  cat <<EOF
networks:
  proxy:
    name: proxy
    external: true
EOF
}

create_site() {
  ask_domain
  ask_backend
  echo
  ask "一句话说明（写进文件注释）" "$NAME"
  DESC="$REPLY"

  echo
  info "将写入以下内容（只保存在本机，不入库）："
  printf '\n──── proxy/sites/local/%s.caddy\n' "$NAME"
  gen_site
  if [[ "$BACKEND" == docker ]]; then
    printf '\n──── services/local/%s/compose.yaml\n' "$NAME"
    gen_compose
  fi
  printf '\n──── .env 末尾追加\n%s=%s\n\n' "$VAR" "$DOMAIN"
  confirm "确认写入？" y || die "已取消，没有做任何修改"

  mkdir -p "$SITE_DIR"
  gen_site >"$SITE_DIR/$NAME.caddy"
  if [[ "$BACKEND" == docker ]]; then
    mkdir -p "$SVC_DIR/$NAME"
    gen_compose >"$SVC_DIR/$NAME/compose.yaml"
  fi
  env_set "$VAR" "$DOMAIN"
  ok "已写入"
}

# ---------- 部署 ----------

# 在新会话中运行 rpctl up：重建 Caddy 会断开 Web SSH，即使当前终端随之断开，操作也会继续完成
up_detached() {
  local log pid rc=0
  log="$(mktemp "${TMPDIR:-/tmp}/rpctl-up.XXXXXX")"
  info "执行 ./rpctl up $*（在独立会话中运行，日志：$log）"
  setsid nohup "$ROOT/rpctl" up "$@" >"$log" 2>&1 </dev/null &
  pid=$!
  tail -n +1 -f --pid="$pid" "$log" 2>/dev/null || true
  wait "$pid" || rc=$?
  return $rc
}

# 在本机直连 Caddy 验证 HTTPS；证书刚开始申请时需要等一会儿
verify_https() {
  local addr="${LISTEN_ADDR:-0.0.0.0}" port="${HTTPS_PORT:-443}" code="" opts=()
  [[ "$addr" != 0.0.0.0 ]] || addr=127.0.0.1
  [[ "${CADDY_TLS_MODE:-cloudflare}" != internal ]] || opts+=(-k)
  info "在本机验证 https://$DOMAIN（等待证书签发，最长 2 分钟）"
  for _ in $(seq 1 24); do
    if code="$(curl -s "${opts[@]}" -o /dev/null -m 5 -w '%{http_code}' \
      --resolve "$DOMAIN:$port:$addr" "https://$DOMAIN:$port/")"; then
      break
    fi
    code=""
    sleep 5
  done
  case "$code" in
    "") warn "仍无法建立 HTTPS 连接：查看 ./rpctl logs proxy，确认证书是否申请成功" ;;
    502 | 503 | 504) warn "HTTPS 正常，但后端没有响应（$code）：确认后端在运行、地址和端口正确（./rpctl ps）" ;;
    *) ok "HTTPS 正常，状态码 $code" ;;
  esac
}

deploy() {
  load_env
  local dns=0 targets=()

  echo
  if [[ "${CADDY_TLS_MODE:-cloudflare}" == cloudflare ]]; then
    dns=1
    if [[ -z "${SERVER_IPV4:-}${SERVER_IPV6:-}" ]]; then
      warn "SERVER_IPV4 / SERVER_IPV6 为空，dns sync 无法创建 A/AAAA 记录，将跳过 DNS 同步"
      dns=0
    fi
    if [[ "${LISTEN_ADDR:-0.0.0.0}" == 127.0.0.1 ]]; then
      warn "LISTEN_ADDR=127.0.0.1：Caddy 不在公网监听，站点无法从外部访问。请从 .env 中删除 LISTEN_ADDR"
    fi
    if [[ "${CF_PROXIED:-true}" != true ]]; then
      info "CF_PROXIED=${CF_PROXIED}（仅 DNS）：云防火墙还需放行 80/tcp 和 443/udp，见 docs/deploy.md 防火墙"
    fi
  fi
  if [[ -f "$SVC_DIR/$NAME/compose.yaml" ]]; then targets+=("$NAME"); fi
  targets+=(proxy)

  local steps="check"
  [[ $dns == 0 ]] || steps+=" → dns sync"
  steps+=" → up ${targets[*]}"
  if ! confirm "现在部署吗（$steps）？" y; then
    info "稍后手动部署：./rpctl check && ./rpctl dns sync && ./rpctl up ${targets[*]}"
    return
  fi

  "$ROOT/rpctl" check

  if [[ $dns == 1 ]]; then
    "$ROOT/rpctl" dns sync --dry-run
    if confirm "按以上预览同步 DNS？" y; then
      "$ROOT/rpctl" dns sync
    else
      warn "跳过 DNS 同步，之后执行 ./rpctl dns sync"
    fi
  fi

  # Caddy 只在创建容器时读取 .env，新的域名变量需要重建容器才能生效
  if [[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" == true ]] &&
    ! docker inspect caddy -f '{{range .Config.Env}}{{println .}}{{end}}' | grep -qxF "$VAR=$DOMAIN"; then
    warn "接下来会重建 Caddy 容器以读取新的 .env：如果正通过 Web SSH 操作，终端会断开，几秒后重新连接即可，部署会在后台继续完成"
  fi
  up_detached "${targets[@]}"
  verify_https
  if [[ $dns == 1 ]]; then
    info "DNS 生效可能需要一两分钟，之后从浏览器访问 https://$DOMAIN"
  fi
}

cmd_add() {
  require_cmd docker curl setsid
  ask_name "${1:-}"
  create_site
  deploy
  echo
  info "本地站点不入库，./rpctl backup 会一并备份（config.tgz）。修改：编辑 proxy/sites/local/$NAME.caddy 后 ./rpctl reload"
}

# ---------- 删除 ----------

local_sites() {
  local f
  for f in "$SITE_DIR"/*.caddy; do
    [[ -f "$f" ]] && basename "$f" .caddy
  done
  return 0
}

# site_var 站点文件 —— 站点地址中的域名变量
site_var() {
  sed -nE 's/^\{\$([A-Z0-9_]+_DOMAIN)\}(:[0-9]+)?([[:space:],{].*)?$/\1/p' "$1" | head -1
}

ask_remove_name() {
  local sites=() s i=1 v
  mapfile -t sites < <(local_sites)
  if [[ -n "${1:-}" ]]; then
    NAME="$1"
    if [[ ! -f "$SITE_DIR/$NAME.caddy" ]]; then
      if [[ -f "$ROOT/proxy/sites/$NAME.caddy" ]]; then
        die "$NAME 是仓库中的站点，不能用本命令删除，见 docs/adding-a-service.md"
      fi
      die "没有名为 $NAME 的本地站点（现有：${sites[*]:-无}）"
    fi
    return
  fi
  [[ ${#sites[@]} -gt 0 ]] || die "没有用 site add 添加的本地站点"
  echo "本地站点："
  for s in "${sites[@]}"; do
    v="$(site_var "$SITE_DIR/$s.caddy")"
    printf '  %d) %-20s %s\n' "$i" "$s" "${v:+${!v:-（.env 中没有 $v）}}"
    i=$((i + 1))
  done
  while true; do
    ask "要删除的站点（序号或名称）"
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= ${#sites[@]})); then
      NAME="${sites[10#$REPLY - 1]}"
      break
    fi
    if [[ -n "$REPLY" && -f "$SITE_DIR/$REPLY.caddy" ]]; then NAME="$REPLY"; break; fi
    err "没有这个站点"
  done
}

# dns_records_of 域名 —— 该域名的 A/AAAA/CNAME 记录（JSON 数组，附带 zone_id），只读
dns_records_of() {
  (
    # shellcheck source=lib/cf.sh
    source "$ROOT/scripts/lib/cf.sh"
    zid="$(zone_id)"
    cf_api GET "/zones/$zid/dns_records?name=$1&per_page=100" |
      jq -c --arg z "$zid" '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME") | . + {zone_id: $z}]'
  )
}

# delete_dns_records JSON数组
delete_dns_records() {
  (
    # shellcheck source=lib/cf.sh
    source "$ROOT/scripts/lib/cf.sh"
    jq -c '.[]' <<<"$1" | while read -r rec; do
      cf_api DELETE "/zones/$(jq -r '.zone_id' <<<"$rec")/dns_records/$(jq -r '.id' <<<"$rec")" >/dev/null
      ok "已删除 DNS 记录 $(jq -r '"\(.type) \(.name) -> \(.content)"' <<<"$rec")"
    done
  )
}

cmd_remove() {
  require_cmd docker jq
  ask_remove_name "${1:-}"

  local site="$SITE_DIR/$NAME.caddy" svc="$SVC_DIR/$NAME" records="[]" volumes=()
  VAR="$(site_var "$site")"
  DOMAIN="${VAR:+${!VAR:-}}"
  if [[ -d "$svc" ]]; then
    mapfile -t volumes < <(docker volume ls -q --filter "label=com.docker.compose.project=rp-$NAME")
  fi
  if [[ -n "$DOMAIN" && "${CADDY_TLS_MODE:-cloudflare}" == cloudflare && -n "${CF_API_TOKEN:-}" ]] &&
    [[ "$DOMAIN" == "$CF_ZONE" || "$DOMAIN" == *".$CF_ZONE" ]]; then
    info "查询 $DOMAIN 的 DNS 记录"
    records="$(dns_records_of "$DOMAIN")" || { warn "查询 DNS 记录失败，将跳过删除 DNS 记录"; records="[]"; }
  fi

  echo
  info "将删除站点 $NAME${DOMAIN:+（$DOMAIN）}："
  if [[ -d "$svc" ]]; then echo "  - 停止并删除容器，删除 services/local/$NAME/"; fi
  echo "  - 删除 proxy/sites/local/$NAME.caddy，并热加载 Caddy"
  if [[ -n "$VAR" ]] && grep -q "^$VAR=" "$ROOT/.env"; then echo "  - 删除 .env 中的 $VAR=$DOMAIN"; fi
  if [[ "$records" != "[]" ]]; then
    echo "  - 删除 Cloudflare DNS 记录："
    jq -r '.[] | "      \(.type) \(.name) -> \(.content) (proxied=\(.proxied))"' <<<"$records"
  fi
  echo
  confirm "确认删除？" n || die "已取消，没有做任何修改"

  local purge=0
  if [[ ${#volumes[@]} -gt 0 ]]; then
    warn "数据卷：${volumes[*]}"
    if confirm "同时删除以上数据卷？删除后数据无法恢复（需要的话先执行 ./rpctl backup）" n; then purge=1; fi
  fi

  # 先摘掉路由，再停后端，避免停服期间访问者看到 502
  # 只需热加载、不必重建 Caddy：站点不再引用该变量，Web SSH 不会断开
  rm -f "$site"
  ok "已删除 proxy/sites/local/$NAME.caddy"
  if [[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" == true ]]; then
    "$ROOT/rpctl" reload || warn "热加载失败，请检查后执行 ./rpctl reload"
  fi

  if [[ -d "$svc" ]]; then
    if [[ -f "$svc/compose.yaml" ]]; then
      if [[ $purge == 1 ]]; then dc "$NAME" down -v; else dc "$NAME" down; fi
    fi
    rm -rf "$svc"
    ok "已删除 services/local/$NAME/"
    if [[ $purge == 0 && ${#volumes[@]} -gt 0 ]]; then
      info "数据卷已保留：${volumes[*]}（不需要时用 docker volume rm 删除）"
    fi
  fi

  if [[ -n "$VAR" ]] && grep -q "^$VAR=" "$ROOT/.env"; then
    env_unset "$VAR"
    ok "已从 .env 删除 $VAR"
  fi

  if [[ "$records" != "[]" ]]; then
    delete_dns_records "$records" || warn "删除 DNS 记录失败，请在 Cloudflare 控制台手动删除"
  fi
  ok "站点 $NAME 已删除"
}

usage() {
  cat <<EOF
用法：./rpctl site <子命令>
  add [名称]      交互式添加公网 443 站点并部署（配置只保存在本机，不入库）
  remove [名称]   删除 site add 添加的站点：后端容器、站点文件、.env 中的域名、DNS 记录
EOF
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    add | remove | rm) ;;
    -h | --help | help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  [[ -f "$ROOT/.env" ]] || die "未找到 .env，请先完成部署（docs/deploy.md）"
  load_env
  case "$cmd" in
    add) cmd_add "$@" ;;
    remove | rm) cmd_remove "$@" ;;
  esac
}

main "$@"
