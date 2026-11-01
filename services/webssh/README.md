# Web SSH（Sshwifty）

基于 [Sshwifty](https://github.com/nirui/sshwifty) 的浏览器 SSH 客户端，访问地址为 `https://$WEBSSH_DOMAIN`。

## 文件

| 文件 | 入库 | 说明 |
| --- | --- | --- |
| `compose.yaml` | ✅ | 容器定义：只读根文件系统、去除全部 capability、不映射端口 |
| `sshwifty.conf.example.json` | ✅ | 配置模板 |
| `init.sh` | ✅ | `./rpctl init` 时从模板生成 `sshwifty.conf.json`，填入域名与随机口令 |
| `sshwifty.conf.json` | ❌ | 实际配置，含访问口令，权限 600 |

## 访问控制

当前只依赖 Sshwifty 自带的访问口令（`SharedKey`），因此默认做了以下收紧：

- **`OnlyAllowPresetRemotes: true`**：只能连接 `Presets` 中预设的主机，不能把它当作跳板连任意地址
- **`HostName`**：只响应 `WEBSSH_DOMAIN`，用 IP 或其他域名访问会返回 403
- 口令为 24 位随机字符串，由 `init.sh` 生成

即使拿到口令，也还需要目标主机的 SSH 凭据。建议：

- 目标主机 sshd 关闭密码登录，只用密钥（`PasswordAuthentication no`），配合 fail2ban
- 开启 Cloudflare 代理，可在 Cloudflare WAF 中按国家/IP 加访问规则
- 如果以后需要更强的保护，可以给该域名加 Cloudflare Access（Zero Trust），本服务无需改动

## 配置预设主机

编辑 `sshwifty.conf.json` 中的 `Presets`，然后 `./rpctl restart webssh`：

```json
{
  "Title": "生产 Web 服务器",
  "Type": "SSH",
  "Host": "10.0.0.12:22",
  "TabColor": "b5442a",
  "Meta": {
    "User": "deploy",
    "Authentication": "Private Key"
  }
}
```

- `Host: host.docker.internal:22` 表示部署 Web SSH 的宿主机本身
- `Meta` 中设定的字段会被锁定，用户不能修改
- **预设数据会明文下发给浏览器，不要在 `Meta` 里写密码或私钥**

## 常用操作

```bash
./rpctl logs webssh -f         # 查看连接日志
./rpctl restart webssh         # 修改配置后
./rpctl pull webssh && ./rpctl up webssh   # 升级
jq -r .SharedKey services/webssh/sshwifty.conf.json   # 查看口令
```

更换口令：修改 `sshwifty.conf.json` 中的 `SharedKey`（或删除该文件后重新 `./rpctl init` 生成，注意预设主机也会被重置），然后 `./rpctl restart webssh`。

## 注意事项

- Sshwifty 依赖浏览器 WebCrypto，**必须通过 HTTPS 访问**
- 客户端与服务器时钟需要同步（NTP），偏差过大会出现 `datetime difference ... is beyond tolerance`
- 不支持子路径部署（如 `example.com/ssh`），必须使用独立域名
