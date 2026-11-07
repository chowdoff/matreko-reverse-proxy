// 防火墙地图服务端：定时从 DigitalOcean API 读取服务器、云防火墙、VPC，经 Cloudflare Access 校验身份后提供给前端。
// 只用 Node.js 内置模块，无第三方依赖。配置全部来自环境变量（见 services/fwmap/compose.yaml）。
"use strict";

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const env = process.env;

function parseMap(s) {
  // "a=b, c=d" → { a: "b", c: "d" }；值里可以有空格，键值两端空白会去掉
  const out = {};
  for (const part of String(s || "").split(",")) {
    const i = part.indexOf("=");
    if (i <= 0) continue;
    const k = part.slice(0, i).trim(), v = part.slice(i + 1).trim();
    if (k && v) out[k] = v;
  }
  return out;
}
// 单个 IP 补成 /32 或 /128，与规则里的写法统一
const normCidr = (a) => (a.includes("/") ? a : a + (a.includes(":") ? "/128" : "/32"));
// 团队域名可以写成 myteam、myteam.cloudflareaccess.com 或 https://myteam.cloudflareaccess.com/
function normTeam(s) {
  s = String(s || "").trim().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  if (!s) return "";
  return s.includes(".") ? s : `${s}.cloudflareaccess.com`;
}

const CONFIG = {
  port: Number(env.PORT || 8080),
  doToken: (env.FWMAP_DO_TOKEN || "").trim(),
  // 仅供本地测试指向模拟 API；compose 不传这个变量，容器里始终是官方地址
  doApi: (env.FWMAP_DO_API || "https://api.digitalocean.com").replace(/\/+$/, ""),
  refreshSec: Math.min(Math.max(Number(env.FWMAP_REFRESH) || 300, 60), 86400),
  accessTeam: normTeam(env.FWMAP_ACCESS_TEAM),
  accessAud: (env.FWMAP_ACCESS_AUD || "").trim(),
  devMode: env.CADDY_TLS_MODE === "internal",
  labels: Object.fromEntries(Object.entries(parseMap(env.FWMAP_LABELS)).map(([k, v]) => [normCidr(k), v])),
  ports: parseMap(env.FWMAP_PORTS),
  publicPorts: String(env.FWMAP_PUBLIC_PORTS || "80,443").split(",").map((s) => s.trim()).filter(Boolean),
};

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ---------------- DigitalOcean API ----------------

const DO_HINT = {
  401: "Token 无效或已过期，请在 DigitalOcean 控制台重新生成",
  403: "Token 缺少读取权限（需要 droplet:read、firewall:read、vpc:read）",
  429: "请求过于频繁，被 DigitalOcean 限流",
};

async function doGetAll(resource) {
  const out = [];
  let url = `${CONFIG.doApi}/v2/${resource}?per_page=200`;
  for (let page = 0; url && page < 50; page++) {
    const r = await fetch(url, {
      headers: { Authorization: `Bearer ${CONFIG.doToken}`, Accept: "application/json" },
      signal: AbortSignal.timeout(20000),
    });
    if (!r.ok) {
      const body = await r.json().catch(() => ({}));
      throw new Error(`读取 ${resource} 失败（HTTP ${r.status}）：${DO_HINT[r.status] || body.message || "未知错误"}`);
    }
    const j = await r.json();
    out.push(...(j[resource] || []));
    const next = j.links?.pages?.next;
    // 下一页只沿用路径和参数，Token 永远只发给 CONFIG.doApi
    url = next ? CONFIG.doApi + new URL(next).pathname + new URL(next).search : null;
  }
  return out;
}

async function fetchCloudflareIps(previous) {
  try {
    const r = await fetch("https://api.cloudflare.com/client/v4/ips", { signal: AbortSignal.timeout(10000) });
    const j = await r.json();
    if (!j.success) throw new Error("响应 success=false");
    return { ipv4: j.result.ipv4_cidrs || [], ipv6: j.result.ipv6_cidrs || [] };
  } catch (e) {
    log("获取 Cloudflare IP 段失败，沿用上次结果：", e.message);
    return previous || { ipv4: [], ipv6: [] };
  }
}

const ipOf = (d, ver, type) => (d.networks?.[ver] || []).find((n) => n.type === type)?.ip_address || null;
const trimRule = (r, key) => ({ protocol: r.protocol, ports: r.ports ?? "", [key]: r[key] || {} });

function trim({ droplets, firewalls, vpcs }) {
  return {
    droplets: droplets.map((d) => ({
      id: d.id, name: d.name, tags: d.tags || [], vpc_uuid: d.vpc_uuid || null,
      region: d.region?.slug || "", status: d.status,
      public_ipv4: ipOf(d, "v4", "public"), private_ipv4: ipOf(d, "v4", "private"), public_ipv6: ipOf(d, "v6", "public"),
    })),
    firewalls: firewalls.map((f) => ({
      id: f.id, name: f.name, status: f.status, pending: (f.pending_changes || []).length > 0,
      tags: f.tags || [], droplet_ids: f.droplet_ids || [],
      inbound_rules: (f.inbound_rules || []).map((r) => trimRule(r, "sources")),
      outbound_rules: (f.outbound_rules || []).map((r) => trimRule(r, "destinations")),
    })),
    vpcs: vpcs.map((v) => ({ id: v.id, name: v.name, ip_range: v.ip_range, region: v.region, default: !!v.default })),
  };
}

const snap = { data: null, syncedAt: null, attemptedAt: null, error: null, inflight: null };

function sync() {
  if (snap.inflight) return snap.inflight;
  snap.inflight = (async () => {
    snap.attemptedAt = new Date();
    try {
      if (!CONFIG.doToken) throw new Error("没有设置 FWMAP_DO_TOKEN：在 DigitalOcean 控制台创建只读 Token 后写入 .env，见 services/fwmap/README.md");
      const [droplets, firewalls, vpcs] = await Promise.all(["droplets", "firewalls", "vpcs"].map(doGetAll));
      const cloudflare = await fetchCloudflareIps(snap.data?.cloudflare);
      snap.data = { ...trim({ droplets, firewalls, vpcs }), cloudflare };
      snap.syncedAt = new Date();
      if (snap.error) log("同步恢复正常");
      snap.error = null;
      log(`同步完成：${droplets.length} 台服务器，${firewalls.length} 个防火墙，${vpcs.length} 个 VPC`);
    } catch (e) {
      snap.error = e.name === "TimeoutError" ? "连接 DigitalOcean API 超时" : e.message;
      log("同步失败：", snap.error);
    } finally {
      snap.inflight = null;
    }
  })();
  return snap.inflight;
}

// ---------------- Cloudflare Access ----------------

const jwks = { keys: new Map(), fetchedAt: 0 };

async function loadCerts(force) {
  const age = Date.now() - jwks.fetchedAt;
  if (!force && jwks.keys.size && age < 3600e3) return;
  if (force && age < 60e3) return; // 遇到未知 kid 时最多每分钟重新拉一次
  const r = await fetch(`https://${CONFIG.accessTeam}/cdn-cgi/access/certs`, { signal: AbortSignal.timeout(10000) });
  if (!r.ok) throw new Error(`获取 Access 公钥失败（HTTP ${r.status}）`);
  const j = await r.json();
  const keys = new Map();
  for (const k of j.keys || []) {
    try { keys.set(k.kid, crypto.createPublicKey({ key: k, format: "jwk" })); } catch { /* 跳过无法解析的公钥 */ }
  }
  jwks.keys = keys;
  jwks.fetchedAt = Date.now();
}

async function verifyAccessJwt(token, now = Date.now() / 1000) {
  const parts = String(token).split(".");
  if (parts.length !== 3) throw new Error("凭证格式错误");
  let header;
  try { header = JSON.parse(Buffer.from(parts[0], "base64url")); } catch { throw new Error("凭证格式错误"); }
  if (header.alg !== "RS256") throw new Error(`不支持的签名算法 ${header.alg}`);
  await loadCerts(false);
  let key = jwks.keys.get(header.kid);
  if (!key) { await loadCerts(true); key = jwks.keys.get(header.kid); }
  if (!key) throw new Error("未知的签名公钥");
  const valid = crypto.verify("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), key, Buffer.from(parts[2], "base64url"));
  if (!valid) throw new Error("签名无效");
  const p = JSON.parse(Buffer.from(parts[1], "base64url"));
  const aud = Array.isArray(p.aud) ? p.aud : [p.aud];
  if (!aud.includes(CONFIG.accessAud)) throw new Error("aud 与 FWMAP_ACCESS_AUD 不一致");
  if (p.iss !== `https://${CONFIG.accessTeam}`) throw new Error("iss 与 FWMAP_ACCESS_TEAM 不一致");
  if (typeof p.exp !== "number" || p.exp < now - 30) throw new Error("凭证已过期");
  if (typeof p.nbf === "number" && p.nbf > now + 30) throw new Error("凭证尚未生效");
  return { email: p.email || p.common_name || "" };
}

function cookie(req, name) {
  for (const c of String(req.headers.cookie || "").split(";")) {
    const i = c.indexOf("=");
    if (i > 0 && c.slice(0, i).trim() === name) return c.slice(i + 1).trim();
  }
  return "";
}

async function authenticate(req) {
  if (!CONFIG.accessTeam || !CONFIG.accessAud) {
    if (CONFIG.devMode) return { ok: true, viewer: { email: "", dev: true } };
    return { ok: false, status: 503, message: "没有配置 Cloudflare Access（FWMAP_ACCESS_TEAM、FWMAP_ACCESS_AUD），拒绝提供服务。配置方法见 services/fwmap/README.md" };
  }
  const token = req.headers["cf-access-jwt-assertion"] || cookie(req, "CF_Authorization");
  if (!token) return { ok: false, status: 403, message: "缺少 Cloudflare Access 凭证，请通过受 Access 保护的域名访问" };
  try {
    return { ok: true, viewer: { ...(await verifyAccessJwt(token)), dev: false } };
  } catch (e) {
    log("Access 校验失败：", e.message);
    return { ok: false, status: 403, message: `Cloudflare Access 凭证无效：${e.message}` };
  }
}

// ---------------- HTTP ----------------

const PUBLIC_DIR = path.join(__dirname, "public");
const STATIC = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/app.js": ["app.js", "text/javascript; charset=utf-8"],
  "/app.css": ["app.css", "text/css; charset=utf-8"],
  "/favicon.svg": ["favicon.svg", "image/svg+xml"],
};
const CSP = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

function send(res, status, body, type, extra = {}) {
  res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...extra });
  res.end(body);
}
const sendJson = (res, status, obj) => send(res, status, JSON.stringify(obj), "application/json; charset=utf-8");

function snapshotBody(viewer) {
  return {
    ready: !!snap.data,
    synced_at: snap.syncedAt?.toISOString() || null,
    attempted_at: snap.attemptedAt?.toISOString() || null,
    error: snap.error,
    refresh_seconds: CONFIG.refreshSec,
    viewer,
    public_ports: CONFIG.publicPorts,
    labels: CONFIG.labels,
    ports: CONFIG.ports,
    data: snap.data,
  };
}

async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname === "/healthz") return sendJson(res, 200, { ok: true });

  const auth = await authenticate(req);
  if (!auth.ok) return send(res, auth.status, auth.message, "text/plain; charset=utf-8");

  if (req.method === "GET" && STATIC[url.pathname]) {
    const [file, type] = STATIC[url.pathname];
    return send(res, 200, fs.readFileSync(path.join(PUBLIC_DIR, file)), type, { "Content-Security-Policy": CSP, "Cache-Control": "no-cache" });
  }
  if (req.method === "GET" && url.pathname === "/api/snapshot") return sendJson(res, 200, snapshotBody(auth.viewer));
  if (req.method === "POST" && url.pathname === "/api/refresh") {
    // 自定义请求头挡住跨站表单提交；15 秒内重复点击直接返回当前数据
    if (req.headers["x-fwmap"] !== "1") return send(res, 400, "缺少 X-Fwmap 请求头", "text/plain; charset=utf-8");
    if (!snap.attemptedAt || Date.now() - snap.attemptedAt.getTime() > 15e3) await sync();
    else if (snap.inflight) await snap.inflight;
    return sendJson(res, 200, snapshotBody(auth.viewer));
  }
  return send(res, 404, "Not Found", "text/plain; charset=utf-8");
}

function main() {
  if (!CONFIG.accessTeam || !CONFIG.accessAud) {
    if (CONFIG.devMode) log("警告：开发模式（CADDY_TLS_MODE=internal），没有配置 Cloudflare Access，不校验访问者身份");
    else log("警告：没有配置 FWMAP_ACCESS_TEAM / FWMAP_ACCESS_AUD，所有页面请求都会被拒绝");
  }
  http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      log("请求处理出错：", e);
      if (!res.headersSent) send(res, 500, "服务器内部错误", "text/plain; charset=utf-8");
    });
  }).listen(CONFIG.port, () => log(`监听 :${CONFIG.port}，每 ${CONFIG.refreshSec} 秒同步一次`));
  sync();
  setInterval(sync, CONFIG.refreshSec * 1000).unref();
}

if (require.main === module) main();
module.exports = { verifyAccessJwt, jwks, CONFIG, parseMap, normTeam, normCidr, trim };
