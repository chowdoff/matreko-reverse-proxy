// 防火墙地图前端：从 /api/snapshot 读取 DigitalOcean 数据，计算每台服务器实际生效的规则，画成拓扑图、矩阵和列表
"use strict";
(() => {
  const ANY = ["0.0.0.0/0", "::/0"];
  // 常用端口 → 协议名（按惯例推断）；FWMAP_PORTS 中的配置优先
  const SVC_TCP = { 21: "FTP", 22: "SSH", 25: "SMTP", 53: "DNS", 80: "HTTP", 110: "POP3", 143: "IMAP", 443: "HTTPS", 465: "SMTPS", 587: "SMTP", 993: "IMAPS", 995: "POP3S",
    1433: "SQL Server", 2375: "Docker", 2376: "Docker TLS", 2379: "etcd", 3306: "MySQL", 3389: "RDP", 5432: "PostgreSQL", 5672: "RabbitMQ", 6379: "Redis", 6443: "K8s API",
    8080: "HTTP 备用", 8443: "HTTPS 备用", 9090: "Prometheus", 9100: "Node Exporter", 9200: "Elasticsearch", 11211: "Memcached", 27017: "MongoDB" };
  const SVC_UDP = { 53: "DNS", 123: "NTP", 443: "QUIC", 500: "IPsec", 1194: "OpenVPN", 51820: "WireGuard" };
  const SEV = { critical: "严重", warning: "警告", info: "提示" };
  const sevRank = { critical: 0, warning: 1, info: 2 };

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const normCidr = (a) => (a.includes("/") ? a : a + (a.includes(":") ? "/128" : "/32"));
  const allPorts = (p) => !p || p === "0" || p === "all" || p === "1-65535";

  let SNAP = null; // 最近一次接口返回
  let M = null;    // 由 SNAP.data 计算出的模型

  // ---------------- 端口 ----------------
  function portText(proto, ports) {
    proto = String(proto).toLowerCase();
    if (proto === "all") return "全部";
    if (proto === "icmp") return "ICMP";
    if (allPorts(ports)) return proto === "tcp" ? "全部 TCP" : "全部 UDP";
    return proto === "tcp" ? String(ports) : ports + "/udp";
  }
  function svc(label) {
    if (label === "全部") return { name: "全部端口", port: "" };
    if (label.startsWith("全部") || label === "ICMP") return { name: label, port: "" };
    const udp = label.endsWith("/udp"), n = label.replace("/udp", "");
    const custom = SNAP?.ports || {};
    const name = custom[label] || (udp ? SVC_UDP : SVC_TCP)[n] || "";
    return { name, port: label };
  }
  const svcText = (l) => { const s = svc(l); return [s.name, s.port].filter(Boolean).join(" "); };
  function portHtml(l, cls = "") {
    const s = svc(l);
    return `<span class="port ${cls}">${s.name ? `<b>${esc(s.name)}</b>` : ""}${s.port ? `<code>${esc(s.port)}</code>` : ""}</span>`;
  }
  function mergeLabels(list) {
    const s = [...new Set(list)];
    if (s.includes("全部") || (s.includes("全部 TCP") && s.includes("全部 UDP") && s.includes("ICMP"))) return ["全部"];
    return s.sort((a, b) => (parseInt(a) || 1e9) - (parseInt(b) || 1e9) || a.localeCompare(b));
  }

  // ---------------- 模型：每台服务器实际生效的规则 ----------------
  function buildModel(snap) {
    const d = snap.data;
    const m = {
      droplets: d.droplets, firewalls: d.firewalls, vpcs: d.vpcs,
      byId: new Map(d.droplets.map((x) => [x.id, x])),
      vpcById: new Map(d.vpcs.map((v) => [v.id, v])),
      cf: new Set([...(d.cloudflare?.ipv4 || []), ...(d.cloudflare?.ipv6 || [])]),
      labels: snap.labels || {},
      publicOk: new Set(snap.public_ports || ["80", "443"]),
      danglingTags: new Map(), eff: new Map(), risks: [],
    };
    M = m;

    const expand = (spec, fwName) => {
      const out = [];
      for (const a of spec.addresses || []) out.push(ANY.includes(a) ? "internet" : m.cf.has(a) ? "cloudflare" : "cidr:" + normCidr(a));
      for (const t of spec.tags || []) {
        const ds = m.droplets.filter((x) => x.tags.includes(t));
        if (!ds.length) m.danglingTags.set(t, fwName);
        ds.forEach((x) => out.push("d:" + x.id));
      }
      for (const id of spec.droplet_ids || []) if (m.byId.has(id)) out.push("d:" + id);
      for (const id of spec.load_balancer_uids || []) out.push("lb:" + id);
      for (const id of spec.kubernetes_ids || []) out.push("k8s:" + id);
      return [...new Set(out)];
    };
    const describe = (spec) => {
      const parts = [], addrs = spec.addresses || [];
      if (addrs.some((a) => ANY.includes(a))) parts.push("公网");
      const cfn = addrs.filter((a) => m.cf.has(a)).length;
      if (cfn) parts.push(`Cloudflare（${cfn} 个 IP 段）`);
      addrs.filter((a) => !ANY.includes(a) && !m.cf.has(a)).forEach((a) => {
        const c = normCidr(a);
        parts.push(m.labels[c] ? `${m.labels[c]}（${a}）` : a);
      });
      (spec.tags || []).forEach((t) => {
        const names = m.droplets.filter((x) => x.tags.includes(t)).map((x) => x.name);
        parts.push(`标签 ${t}（${names.length ? names.join("、") : "没有服务器"}）`);
      });
      (spec.droplet_ids || []).forEach((id) => parts.push(m.byId.get(id)?.name ?? `Droplet ${id}（已不存在）`));
      (spec.load_balancer_uids || []).forEach((id) => parts.push(`负载均衡 ${id.slice(0, 8)}`));
      (spec.kubernetes_ids || []).forEach((id) => parts.push(`Kubernetes 集群 ${id.slice(0, 8)}`));
      return parts.join("，") || "（空）";
    };
    m.describe = describe;

    for (const dr of m.droplets) {
      const fws = [];
      for (const fw of m.firewalls) {
        const via = [];
        if (fw.droplet_ids.includes(dr.id)) via.push("直接绑定");
        fw.tags.filter((t) => dr.tags.includes(t)).forEach((t) => via.push("标签 " + t));
        if (via.length) fws.push({ fw, via: via.join("、") });
      }
      if (!fws.length) {
        const open = { proto: "all", port: "全部", endpoints: ["internet"], spec: "任何来源", fw: "（没有防火墙）", risk: true };
        m.eff.set(dr.id, { fws, none: true, inbound: [open], outbound: [{ ...open, spec: "任何目标" }] });
        continue;
      }
      const mk = (dir) => fws.flatMap(({ fw }) => fw[dir === "in" ? "inbound_rules" : "outbound_rules"].map((r) => {
        const spec = (dir === "in" ? r.sources : r.destinations) || {};
        return { proto: r.protocol, port: portText(r.protocol, r.ports), endpoints: expand(spec, fw.name), spec: describe(spec), fw: fw.name, risk: false };
      }));
      m.eff.set(dr.id, { fws, none: false, inbound: mk("in"), outbound: mk("out") });
    }

    // ---- 风险 ----
    const R = m.risks;
    for (const dr of m.droplets) {
      const e = m.eff.get(dr.id);
      if (e.none) {
        R.push({ sev: "critical", title: `${dr.name} 没有绑定任何防火墙`, detail: "所有端口都对公网开放，出站也不受限制。给它绑定防火墙，或者打上已有防火墙使用的标签。", target: { type: "node", key: "d:" + dr.id } });
        continue;
      }
      for (const r of e.inbound) {
        if (!r.endpoints.includes("internet") || r.proto === "icmp" || m.publicOk.has(r.port)) continue;
        r.risk = true;
        const ssh = r.port === "22";
        R.push({
          sev: ssh ? "critical" : "warning",
          title: `${dr.name} 的 ${svcText(r.port)} 对公网开放`,
          detail: ssh ? `来自 ${r.fw}。建议只允许跳板机或固定 IP 访问。` : `来自 ${r.fw}。如果这是反代后面的服务，别人可以用服务器 IP 绕过反代直接访问。`,
          target: { type: "edge", id: `internet|d:${dr.id}` },
        });
      }
    }
    for (const fw of m.firewalls) {
      if (fw.status !== "succeeded" || fw.pending) {
        R.push({ sev: "warning", title: `${fw.name} 的规则尚未完全生效`, detail: `状态为 ${fw.status}${fw.pending ? "，还有待应用的变更" : ""}。稍后刷新，或到 DigitalOcean 控制台查看。`, target: { type: "fw", id: fw.id } });
      }
      const n = m.droplets.filter((x) => fw.droplet_ids.includes(x.id) || fw.tags.some((t) => x.tags.includes(t))).length;
      if (!n) R.push({ sev: "info", title: `${fw.name} 没有作用于任何服务器`, detail: fw.tags.length ? `它绑定的标签 ${fw.tags.join("、")} 上没有服务器。` : "它没有绑定标签，也没有直接绑定服务器。", target: { type: "fw", id: fw.id } });
    }
    for (const [t, fwName] of m.danglingTags) {
      const fw = m.firewalls.find((f) => f.name === fwName);
      if (R.some((r) => r.target.type === "fw" && r.target.id === fw.id && r.sev === "info")) continue;
      R.push({ sev: "info", title: `${fwName} 的规则引用了空标签 ${t}`, detail: "这条规则目前不放行任何来源或目标。", target: { type: "fw", id: fw.id } });
    }
    const openOut = m.droplets.filter((x) => { const e = m.eff.get(x.id); return !e.none && mergeLabels(e.outbound.filter((r) => r.endpoints.includes("internet")).map((r) => r.port))[0] === "全部"; });
    if (openOut.length) R.push({ sev: "info", title: `${openOut.length} 台服务器的出站全部放行`, detail: `${openOut.map((x) => x.name).join("、")}。这是常见配置，想收紧的话，可以只放行 DNS 53/udp、HTTP 80、HTTPS 443 等必要端口。`, target: { type: "dir", dir: "out" } });
    R.sort((a, b) => sevRank[a.sev] - sevRank[b.sev]);
    return m;
  }

  function nodeRisk(key) {
    let best = null;
    for (const r of M.risks) {
      const hit = (r.target.type === "node" && r.target.key === key) || (r.target.type === "edge" && r.target.id.split("|")[1] === key);
      if (hit && (!best || sevRank[r.sev] < sevRank[best])) best = r.sev;
    }
    return best;
  }

  // ---------------- 图 ----------------
  function extInfo(key) {
    if (key === "internet") return { name: "公网", sub: "0.0.0.0/0 · ::/0" };
    if (key === "cloudflare") return { name: "Cloudflare", sub: "官方 IP 段" };
    if (key.startsWith("cidr:")) { const c = key.slice(5); return { name: M.labels[c] || "外部地址", sub: c }; }
    if (key.startsWith("lb:")) return { name: "负载均衡", sub: key.slice(3, 11) };
    if (key.startsWith("k8s:")) return { name: "Kubernetes 集群", sub: key.slice(4, 12) };
    return { name: key, sub: "" };
  }
  function nodeInfo(key) {
    if (key.startsWith("d:")) {
      const d = M.byId.get(+key.slice(2));
      return { name: d.name, sub: d.private_ipv4 || d.public_ipv4 || "", tag: d.tags.length ? "标签 " + d.tags.join(" ") : "无标签", d };
    }
    return extInfo(key);
  }
  const extOrder = (k) => (k === "internet" ? 0 : k === "cloudflare" ? 1 : k.startsWith("cidr:") ? (M.labels[k.slice(5)] ? 2 : 3) : 4);

  function buildGraph(dir) {
    const edges = new Map();
    const add = (from, to, r) => {
      if (from === to) return;
      const id = from + "|" + to;
      if (!edges.has(id)) edges.set(id, { id, from, to, rules: [] });
      edges.get(id).rules.push(r);
    };
    for (const d of M.droplets) {
      const e = M.eff.get(d.id), me = "d:" + d.id;
      for (const r of (dir === "in" ? e.inbound : e.outbound)) for (const k of r.endpoints) (dir === "in" ? add(k, me, r) : add(me, k, r));
    }
    for (const e of edges.values()) {
      e.labels = mergeLabels(e.rules.map((r) => r.port));
      const ext = ["internet", "cloudflare"].includes(e.from) || e.to === "internet";
      e.kind = e.rules.some((r) => r.risk) ? "risk" : (ext && dir === "in") ? "public" : e.labels.every((l) => l === "22") ? "ops" : "internal";
    }
    const extKeys = [...new Set([...edges.values()].flatMap((e) => [e.from, e.to]).filter((k) => !k.startsWith("d:")))]
      .sort((a, b) => extOrder(a) - extOrder(b) || extInfo(a).name.localeCompare(extInfo(b).name) || a.localeCompare(b));
    const dKeys = M.droplets.map((d) => "d:" + d.id);
    const col = new Map();
    if (dir === "in") {
      // 外部来源在第 0 列；服务器按“最长访问链”分层：能被公网访问的在第 1 列，只能被第 k 列访问的在第 k+1 列
      extKeys.forEach((k) => col.set(k, 0));
      dKeys.forEach((k) => col.set(k, 1));
      for (let i = 0; i < dKeys.length; i++) {
        for (const e of edges.values()) {
          if (e.from.startsWith("d:") && col.get(e.from) + 1 > col.get(e.to)) col.set(e.to, Math.min(col.get(e.from) + 1, dKeys.length));
        }
      }
    } else {
      dKeys.forEach((k) => col.set(k, 0));
      extKeys.forEach((k) => col.set(k, 1));
    }
    return { dir, edges: [...edges.values()], extKeys, dKeys, col };
  }

  const NW = 214, NH = 80, GX = 190, GY = 64, PADX = 40, PADY = 30, VPC_HEAD = 46, VPC_FOOT = 24, BAND_GAP = 28;
  // 布局：按 VPC 分成上下排列的横带，每条横带内各列居中；外部来源在整幅图的垂直方向居中
  function layout(g) {
    const ncol = Math.max(...[...g.col.values()], 0) + 1;
    const pos = new Map(), bands = [];
    const groups = new Map();
    for (const k of g.dKeys) {
      const v = M.byId.get(+k.slice(2)).vpc_uuid || "";
      (groups.get(v) || groups.set(v, []).get(v)).push(k);
    }
    const order = [...groups.keys()].sort((a, b) => (M.vpcById.get(a)?.name || "~").localeCompare(M.vpcById.get(b)?.name || "~"));
    let y = PADY;
    for (const v of order) {
      const keys = groups.get(v), percol = new Map();
      for (const k of keys) { const c = g.col.get(k); (percol.get(c) || percol.set(c, []).get(c)).push(k); }
      const rows = Math.max(...[...percol.values()].map((a) => a.length));
      const top = y + VPC_HEAD, h = rows * NH + (rows - 1) * GY;
      for (const [c, ks] of percol) {
        const off = ((rows - ks.length) * (NH + GY)) / 2;
        ks.forEach((k, i) => pos.set(k, { x: PADX + c * (NW + GX), y: top + off + i * (NH + GY) }));
      }
      bands.push({ v, keys, y0: y, y1: top + h + VPC_FOOT });
      y = top + h + VPC_FOOT + BAND_GAP;
    }
    const dropH = Math.max(y - BAND_GAP - PADY, 0);
    const extCols = new Map();
    for (const k of g.extKeys) { const c = g.col.get(k); (extCols.get(c) || extCols.set(c, []).get(c)).push(k); }
    let extH = 0;
    for (const [c, ks] of extCols) {
      const h = ks.length * NH + (ks.length - 1) * GY;
      extH = Math.max(extH, h);
      const top = PADY + Math.max((dropH - h) / 2, 0);
      ks.forEach((k, i) => pos.set(k, { x: PADX + c * (NW + GX), y: top + i * (NH + GY) }));
    }
    const H = PADY * 2 + Math.max(dropH, extH);
    const W = PADX * 2 + ncol * NW + (ncol - 1) * GX + 60;
    return { pos, W, H, bands };
  }
  function bez(p0, p1, p2, p3, t) {
    const u = 1 - t;
    return [u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0], u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]];
  }
  const textW = (s, mono) => [...s].reduce((w, ch) => w + (ch.charCodeAt(0) > 255 ? 12.5 : mono ? 7.6 : 7.4), 0);
  const clip = (s, n) => ([...s].length > n ? [...s].slice(0, n - 1).join("") + "…" : s);

  function renderGraph() {
    const g = state.graph;
    if (!g.dKeys.length) {
      stage.innerHTML = `<div class="empty"><b>这个账号下没有服务器</b>DigitalOcean API 没有返回任何 Droplet。</div>`;
      state.size = null;
      return;
    }
    const { pos, W, H, bands } = layout(g);
    state.size = { W, H };
    const outs = new Map(), ins = new Map();
    for (const e of g.edges) { (outs.get(e.from) || outs.set(e.from, []).get(e.from)).push(e); (ins.get(e.to) || ins.set(e.to, []).get(e.to)).push(e); }
    const anchor = new Map();
    const at = (id) => anchor.get(id) || anchor.set(id, {}).get(id);
    for (const [k, list] of outs) { list.sort((a, b) => pos.get(a.to).y - pos.get(b.to).y); list.forEach((e, i) => (at(e.id).s = pos.get(k).y + (NH * (i + 1)) / (list.length + 1))); }
    for (const [k, list] of ins) { list.sort((a, b) => pos.get(a.from).y - pos.get(b.from).y); list.forEach((e, i) => (at(e.id).t = pos.get(k).y + (NH * (i + 1)) / (list.length + 1))); }

    const boxes = [...pos.values()].map((p) => [p.x - 6, p.y - 6, p.x + NW + 6, p.y + NH + 6]);
    // 与已放置的节点、标签的重叠面积；标签沿连线找重叠最少的位置
    const overlap = (b) => boxes.reduce((sum, o) => sum + Math.max(0, Math.min(b[2], o[2]) - Math.max(b[0], o[0])) * Math.max(0, Math.min(b[3], o[3]) - Math.max(b[1], o[1])), 0);
    const SPOTS = [0.5, ...Array.from({ length: 22 }, (_, i) => 0.5 + (i % 2 ? -1 : 1) * 0.04 * Math.ceil((i + 1) / 2))];
    let vpcSvg = "";
    for (const band of bands) {
      const ps = band.keys.map((k) => pos.get(k));
      const x0 = Math.min(...ps.map((p) => p.x)) - 24, x1 = Math.max(...ps.map((p) => p.x)) + NW + 24;
      const v = M.vpcById.get(band.v);
      const title = v ? `VPC ${v.name} · ${v.ip_range} · ${v.region}` : "不在 VPC 中";
      boxes.push([x0, band.y0, x0 + 16 + textW(title, true) + 8, band.y0 + 38]);
      vpcSvg += `<g class="vpc"><rect x="${x0}" y="${band.y0}" width="${x1 - x0}" height="${band.y1 - band.y0}" rx="12"/><text x="${x0 + 16}" y="${band.y0 + 26}">${esc(title)}</text></g>`;
    }
    let edgeSvg = "", labelSvg = "";
    for (const e of g.edges) {
      const a = pos.get(e.from), b = pos.get(e.to), an = anchor.get(e.id);
      let p0, p1, p2, p3;
      if (g.col.get(e.to) > g.col.get(e.from)) {
        p0 = [a.x + NW, an.s]; p3 = [b.x - 2, an.t];
        const dx = Math.max(60, (p3[0] - p0[0]) * 0.45);
        p1 = [p0[0] + dx, p0[1]]; p2 = [p3[0] - dx, p3[1]];
      } else {
        // 同列或回指的连线绕到节点右侧
        p0 = [a.x + NW, an.s]; p3 = [b.x + NW + 2, an.t];
        p1 = [p0[0] + 80, p0[1]]; p2 = [p3[0] + 80, p3[1]];
      }
      const d = `M${p0[0]},${p0[1]} C${p1[0]},${p1[1]} ${p2[0]},${p2[1]} ${p3[0]},${p3[1]}`;
      edgeSvg += `<g class="edge ${e.kind}" data-edge="${esc(e.id)}"><path class="ln" d="${d}" marker-end="url(#m-${e.kind === "public" || e.kind === "risk" ? e.kind : "base"})"/><path class="hit" d="${d}"/></g>`;
      // 标签：每个端口一行，“协议名 端口号”
      const lines = e.labels.map(svc);
      const lh = 18, h = lines.length * lh + 8;
      const w = Math.max(...lines.map((s) => textW(s.name) + (s.name && s.port ? 6 : 0) + textW(s.port, true))) + 16;
      let best = null;
      for (const t of SPOTS) {
        const c = bez(p0, p1, p2, p3, t), box = [c[0] - w / 2 - 4, c[1] - h / 2 - 4, c[0] + w / 2 + 4, c[1] + h / 2 + 4];
        const ov = overlap(box);
        if (!best || ov < best.ov) best = { ov, c, box };
        if (!ov) break;
      }
      boxes.push(best.box);
      const pt = best.c;
      const tl = lines.map((s, i) => `<text x="${-w / 2 + 8}" y="${-h / 2 + 4 + lh * i + 13}">${s.name ? `<tspan class="pn">${esc(s.name)}</tspan>` : ""}${s.port ? `<tspan class="pp" dx="${s.name ? 6 : 0}">${esc(s.port)}</tspan>` : ""}</text>`).join("");
      labelSvg += `<g class="elabel ${e.kind}" data-edge="${esc(e.id)}" transform="translate(${pt[0].toFixed(1)},${pt[1].toFixed(1)})"><rect x="${-w / 2}" y="${-h / 2}" width="${w}" height="${h}" rx="4"/>${tl}</g>`;
    }
    let nodeSvg = "";
    for (const [k, p] of pos) {
      const n = nodeInfo(k), ext = !k.startsWith("d:"), risk = ext ? null : nodeRisk(k);
      const tx = ext ? 24 : 16;
      nodeSvg += `<g class="node ${ext ? "ext" : "drop"} ${k === "internet" ? "internet" : ""}" data-key="${esc(k)}" transform="translate(${p.x},${p.y})" tabindex="0" role="button" aria-label="${esc(n.name)}">
        <title>${esc(n.name)}</title>
        <rect width="${NW}" height="${NH}" rx="${ext ? NH / 2 : 8}"/>
        ${ext ? `<text x="${tx}" y="35" class="n-name">${esc(clip(n.name, 14))}</text><text x="${tx}" y="56" class="n-sub">${esc(clip(n.sub, 22))}</text>`
              : `<text x="${tx}" y="28" class="n-name">${esc(clip(n.name, 18))}</text><text x="${tx}" y="49" class="n-sub">${esc(n.sub)}</text><text x="${tx}" y="68" class="n-tag">${esc(clip(n.tag, 24))}</text>`}
        ${risk ? `<circle cx="${NW - 18}" cy="18" r="5.5" class="n-risk ${risk}"/>` : ""}</g>`;
    }
    const markers = ["base", "public", "risk"].map((k) => `<marker id="m-${k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="mk ${k === "base" ? "" : k}"/></marker>`).join("");
    const caption = g.dir === "in" ? "箭头：谁可以连进来 → 哪台服务器的哪些端口" : "箭头：哪台服务器 → 可以连出去的目标和端口";
    stage.innerHTML = `<div class="stage-scroll" id="scroll"><svg class="g" id="graph" viewBox="0 0 ${W} ${H}" role="img" aria-label="防火墙拓扑图"><defs>${markers}</defs>${vpcSvg}${edgeSvg}${nodeSvg}${labelSvg}</svg></div>
      <div class="stage-note"><span>${caption}</span><span class="lg"><i class="public"></i>公网访问 ${esc([...M.publicOk].map(svcText).join(" / "))}</span><span class="lg"><i class="risk"></i>需要关注</span><span class="lg"><i></i>内网或指定地址</span><span class="lg"><i class="ops"></i>仅 SSH</span><span class="lg"><em></em>服务器有问题</span></div>`;
    applyZoom();
    applyFocus();
  }

  // ---------------- 缩放 ----------------
  function applyZoom() {
    const svg = $("graph");
    if (!svg || !state.size) return;
    if (state.zoomFit) {
      const sc = $("scroll");
      const z = Math.min((sc.clientWidth - 24) / state.size.W, 1.25);
      state.zoom = Math.max(0.6, Math.round(z * 100) / 100);
    }
    svg.setAttribute("width", Math.round(state.size.W * state.zoom));
    svg.setAttribute("height", Math.round(state.size.H * state.zoom));
    $("zoom-val").textContent = Math.round(state.zoom * 100) + "%";
  }

  function applyFocus() {
    const svg = $("graph");
    if (!svg) return;
    const g = state.graph;
    const focusKey = state.hover || (state.sel?.type === "node" ? state.sel.key : null);
    const focusEdge = !state.hover && state.sel?.type === "edge" ? g.edges.find((e) => e.id === state.sel.id) : null;
    svg.classList.toggle("has-focus", !!(focusKey || focusEdge));
    const onNodes = new Set();
    svg.querySelectorAll("[data-edge]").forEach((el) => {
      const e = g.edges.find((x) => x.id === el.dataset.edge);
      const on = focusEdge ? e === focusEdge : e.from === focusKey || e.to === focusKey;
      el.classList.toggle("on", on);
      el.classList.toggle("sel", !!focusEdge && e === focusEdge);
      if (on) { onNodes.add(e.from); onNodes.add(e.to); }
    });
    if (focusKey) onNodes.add(focusKey);
    svg.querySelectorAll(".node").forEach((el) => {
      el.classList.toggle("on", onNodes.has(el.dataset.key));
      el.classList.toggle("sel", state.sel?.type === "node" && state.sel.key === el.dataset.key);
    });
  }

  // ---------------- 矩阵 ----------------
  function portCls(e, l) {
    if (e.kind === "risk" && e.rules.some((r) => r.risk && (r.port === l || l === "全部"))) return "risk";
    return e.kind === "public" ? "public" : "";
  }
  function renderMatrix() {
    const g = state.graph;
    const rows = g.dir === "in" ? [...g.extKeys, ...g.dKeys.filter((k) => g.edges.some((e) => e.from === k))] : g.dKeys;
    const cols = g.dir === "in" ? g.dKeys : [...g.extKeys, ...g.dKeys.filter((k) => g.edges.some((e) => e.to === k))];
    if (!rows.length || !cols.length) { stage.innerHTML = `<div class="empty"><b>没有可显示的规则</b></div>`; return; }
    const head = cols.map((k) => { const n = nodeInfo(k); return `<th><b>${esc(n.name)}</b>${esc(n.sub)}</th>`; }).join("");
    const body = rows.map((r) => {
      const n = nodeInfo(r);
      const cells = cols.map((c) => {
        const e = g.edges.find((x) => x.from === r && x.to === c);
        if (!e) return `<td><span class="nil">—</span></td>`;
        const sel = state.sel?.type === "edge" && state.sel.id === e.id ? " sel" : "";
        return `<td><button type="button" class="cell${sel}" data-edge="${esc(e.id)}">${e.labels.map((l) => portHtml(l, portCls(e, l))).join("")}</button></td>`;
      }).join("");
      return `<tr><th>${esc(n.name)}<span>${esc(n.sub)}</span></th>${cells}</tr>`;
    }).join("");
    const corner = g.dir === "in" ? "来源 ＼ 目标服务器" : "服务器 ＼ 出站目标";
    stage.innerHTML = `<div class="mx-wrap"><table class="mx"><thead><tr><th class="corner">${corner}</th>${head}</tr></thead><tbody>${body}</tbody></table></div>
      <div class="stage-note"><span>格子里是放行的端口，点击查看由哪些规则组成。“—”表示不放行。</span></div>`;
  }

  // ---------------- 防火墙列表 ----------------
  function ruleLines(rules, dir) {
    if (!rules.length) return `<div><span class="arr">没有规则</span></div>`;
    return rules.map((r) => {
      const spec = (dir === "in" ? r.sources : r.destinations) || {};
      const p = portText(r.protocol, r.ports);
      const risky = dir === "in" && (spec.addresses || []).some((a) => ANY.includes(a)) && !M.publicOk.has(p) && r.protocol !== "icmp";
      return `<div>${portHtml(p, risky ? "risk" : "")}<span class="arr">${dir === "in" ? "←" : "→"}</span><span>${esc(M.describe(spec))}</span></div>`;
    }).join("");
  }
  function renderFw() {
    if (!M.firewalls.length) { stage.innerHTML = `<div class="empty"><b>这个账号下没有云防火墙</b>所有服务器的端口都对公网开放。</div>`; return; }
    stage.innerHTML = `<div class="fw-list">${M.firewalls.map((fw) => {
      const targets = M.droplets.map((d) => {
        const via = [];
        if (fw.droplet_ids.includes(d.id)) via.push("直接");
        fw.tags.filter((t) => d.tags.includes(t)).forEach((t) => via.push("标签 " + t));
        return via.length ? `<span class="chip">${esc(d.name)} · ${esc(via.join("、"))}</span>` : "";
      }).join("");
      const okStatus = fw.status === "succeeded" && !fw.pending;
      const flash = state.flashFw === fw.id ? " flash" : "";
      return `<article class="fw${flash}" id="fw-${esc(fw.id)}">
        <div class="fw-h"><b>${esc(fw.name)}</b><span class="${okStatus ? "" : "bad"}">${okStatus ? "已生效" : esc(fw.pending ? "变更待应用" : fw.status)}</span></div>
        <div><div class="lbl">作用于</div><div class="targets">${targets}</div>${targets ? "" : `<div class="warn">没有作用于任何服务器${fw.tags.length ? `（标签 ${esc(fw.tags.join("、"))} 上没有服务器）` : ""}</div>`}</div>
        <div><div class="lbl">入站</div><div class="rl">${ruleLines(fw.inbound_rules, "in")}</div></div>
        <div><div class="lbl">出站</div><div class="rl">${ruleLines(fw.outbound_rules, "out")}</div></div>
      </article>`;
    }).join("")}</div>
    <div class="stage-note"><span>一台服务器同时被多个防火墙覆盖时，生效规则是它们的并集。DigitalOcean 防火墙只有放行规则；绑定了防火墙但没有出站规则时，出站全部被拦截。</span></div>`;
    if (state.flashFw) document.getElementById("fw-" + state.flashFw)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  // ---------------- 详情栏 ----------------
  function rulesTable(rules, dir) {
    if (!rules.length) return `<p>没有${dir === "in" ? "入站" : "出站"}规则，${dir === "in" ? "外部连不进来" : "所有出站连接都会被拦截"}。</p>`;
    return `<table class="rules"><thead><tr><th>端口</th><th>${dir === "in" ? "来源" : "目标"}</th><th>防火墙</th></tr></thead><tbody>${rules.map((r) =>
      `<tr><td>${portHtml(r.port, r.risk ? "risk" : r.endpoints.includes("internet") && dir === "in" ? "public" : "")}</td><td>${esc(r.spec)}</td><td class="fwc">${esc(r.fw)}</td></tr>`).join("")}</tbody></table>`;
  }
  const risksFor = (pred) => M.risks.filter(pred).map((r) => `<div class="callout ${r.sev}"><b>${SEV[r.sev]} · ${esc(r.title)}</b><span>${esc(r.detail)}</span></div>`).join("");
  const closeBtn = `<button type="button" class="close" data-close aria-label="关闭详情">×</button>`;

  function renderDetail() {
    const g = state.graph, sel = state.sel;
    const valid = !!M && !!sel && (sel.type === "node" ? (sel.key.startsWith("d:") ? M.byId.has(+sel.key.slice(2)) : g.extKeys.includes(sel.key)) : g.edges.some((e) => e.id === sel.id));
    if (sel && !valid) state.sel = null;
    const show = state.tab !== "fw" && valid;
    detail.hidden = !show;
    layoutEl.classList.toggle("has-detail", show);
    if (!show) return;
    if (sel.type === "node" && sel.key.startsWith("d:")) {
      const d = M.byId.get(+sel.key.slice(2)), e = M.eff.get(d.id), v = M.vpcById.get(d.vpc_uuid);
      detail.innerHTML = `
        <div class="d-top"><div><div class="eyebrow">服务器</div><h2>${esc(d.name)}</h2>
          <div class="chips">${d.tags.length ? d.tags.map((t) => `<span class="chip">标签 ${esc(t)}</span>`).join("") : `<span class="chip">无标签</span>`}</div></div>${closeBtn}</div>
        <dl class="kv">
          <dt>公网 IPv4</dt><dd>${esc(d.public_ipv4 || "—")}</dd>
          ${d.public_ipv6 ? `<dt>公网 IPv6</dt><dd>${esc(d.public_ipv6)}</dd>` : ""}
          <dt>内网 IPv4</dt><dd>${esc(d.private_ipv4 || "—")}</dd>
          <dt>VPC</dt><dd>${esc(v ? `${v.name}（${v.ip_range}）` : "—")}</dd>
          <dt>区域</dt><dd>${esc(d.region)}</dd>
          <dt>状态</dt><dd>${esc(d.status)}</dd>
        </dl>
        ${risksFor((r) => (r.target.type === "node" && r.target.key === sel.key) || (r.target.type === "edge" && r.target.id.endsWith("|" + sel.key)))}
        <div><h3>绑定的防火墙</h3>${e.fws.length ? `<ul class="fwrefs">${e.fws.map((f) => `<li><b>${esc(f.fw.name)}</b><span>${esc(f.via)}</span></li>`).join("")}</ul>` : `<p>没有</p>`}</div>
        <div><h3>入站规则<span>${e.inbound.length} 条</span></h3>${rulesTable(e.inbound, "in")}</div>
        <div><h3>出站规则<span>${e.outbound.length} 条</span></h3>${rulesTable(e.outbound, "out")}</div>`;
    } else if (sel.type === "node") {
      const n = extInfo(sel.key);
      const list = g.edges.filter((e) => e.from === sel.key || e.to === sel.key);
      const other = (e) => nodeInfo(e.from === sel.key ? e.to : e.from).name;
      detail.innerHTML = `
        <div class="d-top"><div><div class="eyebrow">${g.dir === "in" ? "外部来源" : "出站目标"}</div><h2>${esc(n.name)}</h2><div class="chips"><span class="chip">${esc(n.sub)}</span></div></div>${closeBtn}</div>
        <div><h3>${g.dir === "in" ? "可以访问" : "可以被这些服务器访问"}</h3>${list.length ? `<ul class="reach">${list.map((e) => `<li><button type="button" class="linkish" data-edge="${esc(e.id)}">${esc(other(e))}</button><span class="chips">${e.labels.map((l) => portHtml(l, portCls(e, l))).join("")}</span></li>`).join("")}</ul>` : "<p>没有</p>"}</div>
        ${sel.key.startsWith("cidr:") && !M.labels[sel.key.slice(5)] ? `<p>这个网段还没有名称，可以在 .env 的 FWMAP_LABELS 里给它起个名字。</p>` : ""}`;
    } else {
      const e = g.edges.find((x) => x.id === sel.id);
      const f = nodeInfo(e.from), t = nodeInfo(e.to);
      detail.innerHTML = `
        <div class="d-top"><div><div class="eyebrow">${g.dir === "in" ? "入站" : "出站"}连线</div><h2>${esc(f.name)} → ${esc(t.name)}</h2></div>${closeBtn}</div>
        <p>${esc(f.name)} 可以连接 ${esc(t.name)} 的这些端口：</p>
        <div class="chips">${e.labels.map((l) => portHtml(l, portCls(e, l))).join("")}</div>
        ${risksFor((r) => r.target.type === "edge" && r.target.id === e.id && g.dir === "in")}
        <div><h3>组成这条连线的规则<span>${e.rules.length} 条</span></h3>
        <table class="rules"><thead><tr><th>端口</th><th>规则里的写法</th><th>防火墙</th></tr></thead><tbody>${e.rules.map((r) => `<tr><td>${portHtml(r.port, r.risk ? "risk" : "")}</td><td>${esc(r.spec)}</td><td class="fwc">${esc(r.fw)}</td></tr>`).join("")}</tbody></table></div>`;
    }
  }

  // ---------------- 页头、同步状态 ----------------
  const fmtTime = (iso) => new Date(iso).toLocaleString("zh-CN", { hour12: false, month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  function ago(iso) {
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    return s < 60 ? "刚刚" : s < 3600 ? `${Math.floor(s / 60)} 分钟前` : s < 86400 ? `${Math.floor(s / 3600)} 小时前` : `${Math.floor(s / 86400)} 天前`;
  }
  function renderStatus() {
    const s = SNAP;
    const v = s.viewer || {};
    const viewer = $("viewer");
    viewer.hidden = !(v.email || v.dev);
    viewer.className = "viewer" + (v.dev ? " dev" : "");
    viewer.textContent = v.dev ? "开发模式 · 未启用 Access" : v.email;
    const every = s.refresh_seconds >= 60 ? `每 ${Math.round(s.refresh_seconds / 60)} 分钟自动同步` : "";
    $("sync-dot").className = "dot " + (s.error ? "bad" : s.synced_at ? "ok" : "");
    $("sync-text").textContent = s.synced_at ? `${ago(s.synced_at)}同步（${fmtTime(s.synced_at)}）· ${every}` : s.error ? "同步失败" : "正在同步…";
    $("sync-text").title = s.synced_at ? `上次成功同步：${s.synced_at}（UTC）` : "";
    const banner = $("banner");
    banner.hidden = !s.error;
    if (s.error) banner.innerHTML = `<b>同步失败：</b>${esc(s.error)}${s.synced_at ? `。下面显示的是 ${esc(fmtTime(s.synced_at))} 的数据。` : ""}`;
    $("counts").innerHTML = M ? `<b>${M.droplets.length}</b> 台服务器 · <b>${M.firewalls.length}</b> 个防火墙 · <b>${M.vpcs.length}</b> 个 VPC` : "";
    const alerts = $("alerts");
    alerts.hidden = !M;
    if (M) {
      alerts.innerHTML = `<span class="alerts-label">需要关注</span>` + (M.risks.length
        ? M.risks.map((r, i) => `<button type="button" class="alert sev-${r.sev}" data-i="${i}" title="${esc(r.detail)}"><i></i>${esc(r.title)}</button>`).join("")
        : `<span class="all-good">没有发现问题</span>`);
    }
  }

  // ---------------- 状态与交互 ----------------
  const stage = $("stage"), detail = $("detail"), layoutEl = $("layout");
  const state = { tab: "graph", dir: "in", sel: null, hover: null, flashFw: null, graph: null, zoom: 1, zoomFit: true, size: null };

  function render() {
    document.querySelectorAll("[data-tab]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.tab === state.tab)));
    document.querySelectorAll("[data-dir]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.dir === state.dir)));
    $("dir-seg").hidden = state.tab === "fw";
    $("zoom").hidden = state.tab !== "graph";
    if (!M) {
      detail.hidden = true;
      layoutEl.classList.remove("has-detail");
      stage.innerHTML = SNAP?.error
        ? `<div class="empty"><b>还没有拿到数据</b>${esc(SNAP.error)}</div>`
        : `<div class="empty">正在从 DigitalOcean 读取数据…</div>`;
      return;
    }
    state.graph = buildGraph(state.dir);
    renderDetail();
    if (state.tab === "graph") renderGraph(); else if (state.tab === "matrix") renderMatrix(); else renderFw();
  }
  function select(sel) {
    state.sel = sel; state.hover = null;
    renderDetail();
    if (state.tab === "graph") { applyZoom(); applyFocus(); } else if (state.tab === "matrix") renderMatrix();
  }

  function applySnapshot(s) {
    const changed = JSON.stringify(s.data) !== JSON.stringify(SNAP?.data) || JSON.stringify([s.labels, s.ports, s.public_ports]) !== JSON.stringify([SNAP?.labels, SNAP?.ports, SNAP?.public_ports]);
    SNAP = s;
    if (changed) { M = s.data ? buildModel(s) : null; render(); }
    renderStatus();
  }

  const toast = $("toast");
  function showToast(msg) {
    toast.textContent = msg;
    toast.hidden = false;
    clearTimeout(toast._t);
    toast._t = setTimeout(() => (toast.hidden = true), 3500);
  }
  async function load(refresh) {
    try {
      const r = await fetch(refresh ? "/api/refresh" : "/api/snapshot", refresh ? { method: "POST", headers: { "X-Fwmap": "1" } } : { cache: "no-store" });
      if (!r.ok) throw new Error((await r.text()) || `HTTP ${r.status}`);
      applySnapshot(await r.json());
      return true;
    } catch (e) {
      // Access 登录过期时，请求会被重定向到登录页（跨域），fetch 直接失败
      showToast(e instanceof TypeError ? "无法连接服务，登录可能已过期，请刷新页面" : `加载失败：${e.message}`);
      return false;
    }
  }

  document.querySelectorAll("[data-tab]").forEach((b) => b.addEventListener("click", () => { state.tab = b.dataset.tab; state.flashFw = null; render(); }));
  document.querySelectorAll("[data-dir]").forEach((b) => b.addEventListener("click", () => { state.dir = b.dataset.dir; state.sel = null; render(); }));
  $("zoom-in").addEventListener("click", () => { state.zoomFit = false; state.zoom = Math.min(2, +(state.zoom + 0.1).toFixed(2)); applyZoom(); });
  $("zoom-out").addEventListener("click", () => { state.zoomFit = false; state.zoom = Math.max(0.4, +(state.zoom - 0.1).toFixed(2)); applyZoom(); });
  $("zoom-fit").addEventListener("click", () => { state.zoomFit = true; applyZoom(); });
  stage.addEventListener("click", (ev) => {
    const n = ev.target.closest(".node"), e = ev.target.closest("[data-edge]");
    if (n) select({ type: "node", key: n.dataset.key });
    else if (e) select({ type: "edge", id: e.dataset.edge });
    else if (ev.target.closest("svg")) select(null);
  });
  stage.addEventListener("keydown", (ev) => {
    const n = ev.target.closest(".node");
    if (n && (ev.key === "Enter" || ev.key === " ")) { ev.preventDefault(); select({ type: "node", key: n.dataset.key }); }
  });
  stage.addEventListener("mouseover", (ev) => {
    if (state.tab !== "graph") return;
    const n = ev.target.closest(".node"), k = n ? n.dataset.key : null;
    if (k !== state.hover) { state.hover = k; applyFocus(); }
  });
  stage.addEventListener("mouseleave", () => { if (state.hover) { state.hover = null; applyFocus(); } });
  detail.addEventListener("click", (ev) => {
    if (ev.target.closest("[data-close]")) return select(null);
    const e = ev.target.closest("[data-edge]");
    if (e) select({ type: "edge", id: e.dataset.edge });
  });
  document.addEventListener("keydown", (ev) => { if (ev.key === "Escape" && state.sel) select(null); });
  new ResizeObserver(() => { if (state.zoomFit && state.tab === "graph") applyZoom(); }).observe(stage);
  $("alerts").addEventListener("click", (ev) => {
    const b = ev.target.closest(".alert");
    if (!b || !M) return;
    const t = M.risks[+b.dataset.i].target;
    if (t.type === "fw") { state.tab = "fw"; state.flashFw = t.id; state.sel = null; }
    else if (t.type === "dir") { state.tab = "graph"; state.dir = t.dir; state.sel = null; }
    else { if (state.tab === "fw") state.tab = "graph"; state.dir = "in"; state.flashFw = null; state.sel = t.type === "node" ? { type: "node", key: t.key } : { type: "edge", id: t.id }; }
    render();
  });
  $("refresh").addEventListener("click", async (ev) => {
    const btn = ev.currentTarget;
    btn.classList.add("spin"); btn.disabled = true;
    const ok = await load(true);
    btn.classList.remove("spin"); btn.disabled = false;
    if (ok) showToast(SNAP.error ? "刷新失败，详见页面顶部的提示" : "已刷新");
  });

  load(false);
  setInterval(() => { if (!document.hidden) load(false); }, 60e3);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) load(false); });
})();
