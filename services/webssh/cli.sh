#!/usr/bin/env bash
# webssh 服务命令：通过 ./rpctl webssh <子命令> 调用（已加载 .env 和 scripts/lib/common.sh）
#   add-user [用户名]   创建 Termix 账号（第一个账号自动成为管理员）
set -euo pipefail

termix_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' termix 2>/dev/null)" == true ]] ||
    die "termix 容器未运行，请先 ./rpctl up webssh"
}

add_user() {
  termix_running
  local user="${1:-}" pass pass2
  [[ -n "$user" ]] || read -rp "用户名：" user
  [[ -n "$user" ]] || die "用户名不能为空"
  read -rsp "密码：" pass; echo
  read -rsp "确认密码：" pass2; echo
  [[ "$pass" == "$pass2" ]] || die "两次输入的密码不一致"
  [[ ${#pass} -ge 8 ]] || die "密码至少 8 位"

  # 在容器内直接请求后端（不经过 Caddy，因此不受公网注册屏蔽影响）
  # 用户名和密码经 stdin 传入，不出现在进程参数中
  local result
  result="$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u, password:$p}' |
    docker exec -i termix node -e '
      let b = "";
      process.stdin.on("data", (c) => (b += c)).on("end", async () => {
        try {
          const r = await fetch("http://127.0.0.1:8080/users/create", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: b,
          });
          const j = await r.json().catch(() => ({}));
          console.log(JSON.stringify({ status: r.status, body: j }));
        } catch (e) {
          console.log(JSON.stringify({ status: 0, body: { error: String(e) } }));
        }
      });
    ')"

  local status
  status="$(jq -r .status <<<"$result")"
  case "$status" in
    200 | 201)
      if [[ "$(jq -r '.body.is_admin' <<<"$result")" == true ]]; then
        ok "已创建管理员账号：$user"
      else
        ok "已创建普通账号：$user"
      fi
      ;;
    409) die "用户名已存在：$user" ;;
    *) die "创建失败（HTTP $status）：$(jq -c .body <<<"$result")" ;;
  esac
}

case "${1:-}" in
  add-user) shift; add_user "$@" ;;
  *)
    echo "用法：./rpctl webssh add-user [用户名]   创建 Termix 账号（第一个账号为管理员）"
    exit 1
    ;;
esac
