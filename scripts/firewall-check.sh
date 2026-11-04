#!/usr/bin/env bash
# 从外部检查云服务器防火墙（在服务器以外的机器上运行，例如开发机）
#   scripts/firewall-check.sh <服务器 IP> [选项]      选项见 --help
# 独立脚本，不依赖本项目的其他文件和 .env，可以单独拷贝使用；依赖 bash、curl、timeout
#
# 判断依据：云防火墙拦截时直接丢包，连接会超时（filtered）；
# 端口放行但没有程序监听时，会立即收到 RST（refused），说明防火墙并没有拦截这个端口
set -euo pipefail

if [[ -t 1 ]]; then
  _c_red=$'\e[31m' _c_grn=$'\e[32m' _c_ylw=$'\e[33m' _c_blu=$'\e[34m' _c_rst=$'\e[0m'
else
  _c_red='' _c_grn='' _c_ylw='' _c_blu='' _c_rst=''
fi
info() { printf '%s[INFO]%s %s\n' "$_c_blu" "$_c_rst" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$_c_grn" "$_c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_c_ylw" "$_c_rst" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$_c_red" "$_c_rst" "$*"; }
die()  { err "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法：$0 <服务器 IP> [选项]

在服务器以外的机器（如开发机）上运行，从外部检查云服务器防火墙是否符合
docs/deploy.md「防火墙」一节的规则。

选项：
  -t, --tunnel-domain 域名  检查该 Tunnel 站点没有在公网 80/443 上提供（可多次指定）
  --dns-only                有仅 DNS 的站点：80/tcp 应开放
  --ssh-port 端口           SSH 端口（默认 22）；不对公网开放或只对你的 IP 开放都算正常
  --timeout 秒              每个端口的连接超时（默认 3）
EOF
}

# 应当被防火墙拦截的端口：本项目内部端口 + 常见的不应暴露的服务
BLOCKED_PORTS=(
  8443  # Caddy Tunnel 端口（只发布在 127.0.0.1）
  7844  # cloudflared（只出站）
  8080  # Termix 等后端
  2375 2376  # Docker API
  21 23 25 111 445 3000 3306 3389 5432 5900 6379 8000 8888 9000 9090 9200 11211 27017
)

HOST="" SSH_PORT=22 TIMEOUT=3 DNS_ONLY=0
TUNNEL_DOMAINS=()
FAILS=0 WARNS=0

fail() { err "$*"; FAILS=$((FAILS + 1)); }
warn_() { warn "$*"; WARNS=$((WARNS + 1)); }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t | --tunnel-domain) [[ $# -ge 2 ]] || die "$1 需要参数"; TUNNEL_DOMAINS+=("$2"); shift 2 ;;
      --dns-only) DNS_ONLY=1; shift ;;
      --ssh-port) [[ $# -ge 2 ]] || die "$1 需要参数"; SSH_PORT="$2"; shift 2 ;;
      --timeout) [[ $# -ge 2 ]] || die "$1 需要参数"; TIMEOUT="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      -*) usage; die "未知选项：$1" ;;
      *) [[ -z "$HOST" ]] || die "只能指定一个服务器"; HOST="$1"; shift ;;
    esac
  done
  [[ -n "$HOST" ]] || { usage; exit 1; }
  HOST="${HOST#[}" HOST="${HOST%]}"
}

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"; done
}

# 不能在服务器自己身上检查：访问自己的公网 IP 不经过云防火墙，结果没有意义
check_not_self() {
  command -v ip >/dev/null 2>&1 || return 0
  if ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$HOST"; then
    die "$HOST 是本机地址。访问自己不经过云防火墙，请在服务器以外的机器（如开发机）上运行"
  fi
}

# 本机网络有透明代理（如 Clash TUN 模式、公司网关）时，任何地址的任何端口都能"连上"，结果不可信
# 192.0.2.1 是文档保留地址（TEST-NET-1），正常情况下不可能连上
check_no_transparent_proxy() {
  if [[ "$(probe_tcp 192.0.2.1 9)" == open ]]; then
    die "本机网络会接管所有 TCP 连接（连保留地址 192.0.2.1 都能连上），可能开着透明代理（如 Clash TUN 模式）。请关闭后再检查，或换一台机器"
  fi
}

# probe_tcp HOST PORT —— 输出 open / refused / filtered / error:<原因>
probe_tcp() {
  local out rc=0
  out="$(LC_ALL=C timeout "$TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>&1)" || rc=$?
  if [[ $rc == 0 ]]; then echo open
  elif [[ $rc == 124 ]]; then echo filtered
  elif [[ "$out" == *"refused"* ]]; then echo refused
  else echo "error:${out##*: }"
  fi
}

# 并行探测全部端口，结果写入 RESULT[端口]
declare -A RESULT
probe_all() {
  local tmp p
  tmp="$(mktemp -d)"
  for p in "$@"; do probe_tcp "$HOST" "$p" >"$tmp/$p" & done
  wait
  for p in "$@"; do RESULT[$p]="$(<"$tmp/$p")"; done
  rm -rf "$tmp"
}

# expect_open PORT 说明
expect_open() {
  local p="$1" what="$2"
  case "${RESULT[$p]}" in
    open) ok "$p/tcp 开放（$what）" ;;
    filtered) fail "$p/tcp 被拦截，但它应开放（$what）" ;;
    # 防火墙已放行即可；Caddy 只在有站点的端口上监听，还没有对应站点时连接会被拒绝
    refused) ok "$p/tcp 防火墙已放行，目前没有程序监听（$what）：还没有这类站点时属正常，有的话检查 Caddy 是否运行" ;;
    *) fail "$p/tcp 检查出错：${RESULT[$p]#error:}" ;;
  esac
}

# expect_blocked PORT 说明
expect_blocked() {
  local p="$1" what="$2"
  case "${RESULT[$p]}" in
    filtered) ok "$p/tcp 被拦截（$what）" ;;
    refused) warn_ "$p/tcp 未被防火墙拦截，只是没有程序监听（$what）" ;;
    open) fail "$p/tcp 对外开放，它应被拦截（$what）" ;;
    *) warn_ "$p/tcp 检查出错：${RESULT[$p]#error:}" ;;
  esac
}

# curl --resolve 的地址部分，IPv6 需要加方括号
resolve_addr() { if [[ "$HOST" == *:* ]]; then printf '[%s]' "$HOST"; else printf '%s' "$HOST"; fi; }

# 绕过 DNS 直连服务器访问 Tunnel 站点：不应得到该站点的内容
check_tunnel_domain() {
  local d="$1" out rc
  info "Tunnel 站点 $d 直连服务器 IP："

  if [[ "${RESULT[443]}" == open ]]; then
    rc=0
    out="$(curl -sk -o /dev/null -m 8 -w '%{http_code} %{size_download}' \
      --resolve "$d:443:$(resolve_addr)" "https://$d/")" || rc=$?
    if [[ $rc != 0 ]]; then
      ok "  443：未提供该站点（连接失败，curl 退出码 $rc）"
    elif [[ "$out" == "200 0" ]]; then
      ok "  443：未提供该站点（Caddy 返回空响应）"
    else
      fail "  443：返回了内容（状态码与字节数：$out），该站点可能在公网 443 上提供"
    fi
  else
    ok "  443：端口不可达"
  fi

  if [[ "${RESULT[80]}" == open ]]; then
    rc=0
    out="$(curl -s -o /dev/null -m 8 -w '%{http_code} %{redirect_url}' \
      --resolve "$d:80:$(resolve_addr)" "http://$d/")" || rc=$?
    if [[ $rc == 52 ]]; then
      ok "  80：连接被直接断开"
    elif [[ $rc != 0 ]]; then
      ok "  80：未提供该站点（curl 退出码 $rc）"
    else
      fail "  80：返回了响应（$out），会暴露本机托管了该域名"
    fi
  else
    ok "  80：端口不可达"
  fi
}

main() {
  require_cmd curl timeout
  parse_args "$@"
  check_not_self
  check_no_transparent_proxy

  local me
  me="$(curl -fsS -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' || true)"
  info "检查 $HOST（从 ${me:-未知 IP} 发起，连接超时 ${TIMEOUT}s）"

  local blocked=() p
  for p in "${BLOCKED_PORTS[@]}"; do [[ $p == "$SSH_PORT" ]] || blocked+=("$p"); done
  probe_all "$SSH_PORT" 443 80 "${blocked[@]}"

  echo
  info "应开放的端口："
  expect_open 443 "公网 443 站点"
  if [[ $DNS_ONLY == 1 ]]; then
    expect_open 80 "仅 DNS 站点的 HTTP→HTTPS 跳转"
  fi

  # SSH 可以不对公网开放：Web SSH（Termix）经 Docker 网关连本机 sshd，不经过云防火墙
  echo
  info "SSH："
  case "${RESULT[$SSH_PORT]}" in
    filtered) ok "$SSH_PORT/tcp 被拦截：SSH 不对公网开放（或不对当前 IP 开放），管理走 Web SSH" ;;
    open) ok "$SSH_PORT/tcp 对当前 IP ${me:-} 开放：请在云防火墙确认来源只有你自己的 IP，临时放行的用完记得删除" ;;
    refused) warn_ "$SSH_PORT/tcp 未被防火墙拦截，只是没有程序监听（SSH 不在该端口时用 --ssh-port 指定）" ;;
    *) warn_ "$SSH_PORT/tcp 检查出错：${RESULT[$SSH_PORT]#error:}" ;;
  esac

  echo
  info "应拦截的端口："
  if [[ $DNS_ONLY == 0 ]]; then
    expect_blocked 80 "橙色云朵站点不需要，有仅 DNS 站点时用 --dns-only"
  fi
  for p in "${blocked[@]}"; do expect_blocked "$p" "$(port_desc "$p")"; done

  # 应拦截的端口全部是 refused：很可能根本没有生效的云防火墙
  local refused=0
  for p in "${blocked[@]}"; do [[ "${RESULT[$p]}" == refused ]] && refused=$((refused + 1)); done
  if [[ $refused -eq ${#blocked[@]} ]]; then
    echo
    fail "所有应拦截的端口都没有被拦截：云防火墙可能没有应用到这台服务器（Apply to Droplets）"
  fi

  if [[ ${#TUNNEL_DOMAINS[@]} -gt 0 ]]; then
    echo
    local d
    for d in "${TUNNEL_DOMAINS[@]}"; do check_tunnel_domain "$d"; done
  else
    echo
    info "未检查 Tunnel 站点（用 -t <域名> 指定，例如 -t ssh.example.com）"
  fi

  echo
  info "443/udp 无法可靠探测（UDP 不回应不代表被拦截），请在云防火墙中确认"
  echo
  if [[ $FAILS -gt 0 ]]; then
    err "检查完成：$FAILS 项失败，$WARNS 项警告"
    exit 1
  fi
  if [[ $WARNS -gt 0 ]]; then warn "检查完成：$WARNS 项警告"; else ok "检查完成：全部通过"; fi
}

port_desc() {
  case "$1" in
    8443) echo "Caddy Tunnel 端口，只应在本机回环上" ;;
    7844) echo "cloudflared 只出站" ;;
    8080) echo "后端服务" ;;
    2375 | 2376) echo "Docker API" ;;
    3306 | 5432 | 6379 | 27017 | 9200 | 11211) echo "数据库 / 缓存" ;;
    *) echo "常见服务" ;;
  esac
}

main "$@"
