#!/usr/bin/env node
/* D.A.M VPN for LG — фоновая часть (root). HTTP только на 127.0.0.1:8098 для интерфейса приложения.
   Подписка и настройки — в /media/developer/damvpn (700/600). VPN включают проверенные скрипты этапа 2
   (start.sh / stop.sh рядом): TUN damvpn0, таблица 100, правила 8991–9004, DNS ConnMan → Xray, IPv6 закрыт. */
"use strict";
const http = require("http"), https = require("https"), fs = require("fs"), path = require("path");
const cp = require("child_process"), crypto = require("crypto"), net = require("net"), os = require("os");

const SVC = __dirname;
const APP = path.dirname(SVC);
const DATA = process.env.DAMVPN_DATA || "/media/developer/damvpn";
const RUN = process.env.DAMVPN_RUN || "/tmp/damvpn";
const PORT = 8098;
const INITD = "/var/lib/webosbrew/init.d/70-damvpn";

fs.mkdirSync(DATA, { recursive: true, mode: 0o700 });
const load = (f, d) => { try { return JSON.parse(fs.readFileSync(path.join(DATA, f), "utf8")); } catch (e) { return d; } };
const save = (f, o) => { const p = path.join(DATA, f); fs.writeFileSync(p + ".tmp", JSON.stringify(o), { mode: 0o600 }); fs.renameSync(p + ".tmp", p); };

let sub = load("subscription.json", null);          // { name, url, updated, servers: [ссылки] }
let servers = sub ? parseAll(sub.links) : [];
let settings = Object.assign({ autostart: false, autoServer: false, update: "раз в день", dns: true, ipv6: true, lan: true }, load("settings.json", {}));
let state = Object.assign({ serverId: null }, load("state.json", {}));
let pings = {}, pingedAt = 0, busy = false, lastError = null;

// ---------- подписка ----------
function split1(s, c) { const i = s.indexOf(c); return i < 0 ? [s, ""] : [s.slice(0, i), s.slice(i + 1)]; }
function dec(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }
function linksFrom(text) {
  text = String(text || "").trim();
  if (!/:\/\//.test(text)) text = Buffer.from(text.replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");
  return text.split(/\r?\n/).map((s) => s.trim()).filter((s) => /^vless:\/\//i.test(s));
}
// Поддержаны те же связки, что проверены на ТВ: gRPC + TLS (с pcs) и TCP + REALITY + Vision. Остальное пропускаем.
function parseLink(link) {
  const [rest, label] = split1(link.slice(8), "#");
  const [hp, q] = split1(rest, "?");
  const at = hp.lastIndexOf("@");
  if (at < 0) return null;
  const uuid = dec(hp.slice(0, at));
  const hostport = hp.slice(at + 1).replace(/\/+$/, "");
  let host, port;
  if (hostport[0] === "[") { const e = hostport.indexOf("]"); host = hostport.slice(1, e); port = hostport.slice(e + 2); }
  else { const c = hostport.lastIndexOf(":"); host = hostport.slice(0, c); port = hostport.slice(c + 1); }
  const p = {};
  for (const kv of q.split("&")) { if (!kv) continue; const [k, v] = split1(kv, "="); p[dec(k)] = dec(v); }
  if (p.fm || p.fragment || /^(1|true)$/i.test(p.allowInsecure || p.insecure || "")) return null;
  if (p.pcs && !p.pcs.split(",").every((v) => /^[0-9a-f]{64}$/i.test(v.trim().replace(/:/g, "")))) return null;
  const type = p.type || "tcp", sec = p.security || "none";
  let kind = null;
  if (type === "grpc" && sec === "tls" && !p.flow) kind = "gRPC";
  else if ((type === "tcp" || type === "raw") && sec === "reality" && (!p.flow || p.flow === "xtls-rprx-vision") && /^[A-Za-z0-9_-]{43}$/.test(p.pbk || "") && p.sni) kind = "REALITY";
  if (!kind || !uuid || !host || !/^\d{1,5}$/.test(port) || (p.encryption && p.encryption !== "none")) return null;
  const id = crypto.createHash("sha1").update(link).digest("hex").slice(0, 12);
  return { id, label: dec(label).trim() || host, kind, uuid, host, port: +port, p };
}
function parseAll(links) { const seen = {}; return (links || []).map(parseLink).filter((s) => s && !seen[s.id] && (seen[s.id] = 1)); }
function fetchText(url, hops) {
  return new Promise((ok, no) => {
    const req = https.get(url, { headers: { "User-Agent": "DAM-VPN-for-LG/0.1" }, timeout: 20000 }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && (hops || 0) < 5) { res.resume(); return ok(fetchText(new URL(res.headers.location, url).href, (hops || 0) + 1)); }
      if (res.statusCode !== 200) { res.resume(); return no(new Error("подписка ответила " + res.statusCode)); }
      let d = ""; res.setEncoding("utf8"); res.on("data", (c) => { d += c; if (d.length > 5e6) req.destroy(); }); res.on("end", () => ok(d));
    });
    req.on("timeout", () => req.destroy(new Error("подписка не отвечает"))); req.on("error", no);
  });
}
async function setSubscription(text) {
  text = String(text || "").trim();
  let url = null, body = text;
  if (/^https?:\/\/\S+$/i.test(text)) { url = text; body = await fetchText(url); }
  const links = linksFrom(body), list = parseAll(links);
  if (!list.length) throw new Error(links.length ? "в подписке нет серверов, которые поддерживает программа" : "это не подписка VPN");
  const name = url ? (new URL(url).hostname.split(".").slice(-2, -1)[0] || "Подписка") : "Подписка";
  sub = { name: name.charAt(0).toUpperCase() + name.slice(1), url, updated: Date.now(), links };
  servers = list; save("subscription.json", sub); pings = {}; pingedAt = 0;
  if (!servers.some((s) => s.id === state.serverId)) { state.serverId = servers[0].id; save("state.json", state); }
  return { name: sub.name, count: servers.length };
}

// ---------- пинг серверов (TCP-соединение напрямую, по 16 сразу) ----------
function tcpPing(s) {
  return new Promise((ok) => {
    const t = Date.now(), so = net.connect({ host: s.host, port: s.port, timeout: 1500 });
    const done = (v) => { so.destroy(); ok(v); };
    so.on("connect", () => done(Date.now() - t)); so.on("timeout", () => done(null)); so.on("error", () => done(null));
  });
}
async function pingAll() {
  if (Date.now() - pingedAt < 600000) return; pingedAt = Date.now();
  const queue = servers.slice();
  await Promise.all(Array.from({ length: 16 }, async () => { while (queue.length) { const s = queue.shift(); pings[s.id] = await tcpPing(s); } }));
}

// ---------- VPN ----------
function sh(cmd, env) {
  return new Promise((ok) => cp.execFile("/bin/sh", ["-c", cmd], { env: Object.assign({}, process.env, env || {}), timeout: 180000, maxBuffer: 4e6 },
    (e, out, err) => ok({ code: e ? e.code || 1 : 0, out: String(out) + String(err) })));
}
function isUp() {
  try {
    if (fs.existsSync(path.join(RUN, "rolled_back"))) return false;
    const pid = +fs.readFileSync(path.join(RUN, "xray.pid"), "utf8"); process.kill(pid, 0); return true;
  } catch (e) { return false; }
}
function ipv4Of(dev) { const a = (os.networkInterfaces()[dev] || []).find((x) => x.family === "IPv4" || x.family === 4); return a && a.address; }
function sedEsc(t) { return t.replace(/[\\/.*^$]/g, "\\$&").replace(/[[\]]/g, "."); }
function buildConfig(s, wan, tvip) {
  const user = { id: s.uuid, encryption: "none", flow: s.kind === "REALITY" ? s.p.flow || "" : "" };
  let stream;
  if (s.kind === "REALITY") {
    const r = { serverName: s.p.sni, password: s.p.pbk, shortId: s.p.sid || "" };
    if (s.p.fp) r.fingerprint = s.p.fp; if (s.p.spx) r.spiderX = s.p.spx; if (s.p.pqv) r.mldsa65Verify = s.p.pqv;
    stream = { network: "raw", security: "reality", realitySettings: r };
  } else {
    const t = { allowInsecure: false }, g = { serviceName: s.p.serviceName || "", multiMode: s.p.mode === "multi" };
    if (s.p.sni) t.serverName = s.p.sni; if (s.p.alpn) t.alpn = s.p.alpn.split(",").filter(Boolean);
    if (s.p.fp) t.fingerprint = s.p.fp; if (s.p.pcs) t.pinnedPeerCertSha256 = s.p.pcs; if (s.p.authority) g.authority = s.p.authority;
    stream = { network: "grpc", security: "tls", tlsSettings: t, grpcSettings: g };
  }
  return {
    log: { loglevel: "warning", access: "none", maskAddress: "full" },
    inbounds: [
      { tag: "socks-in", listen: "127.0.0.1", port: 10808, protocol: "socks", settings: { auth: "noauth", udp: false } },
      { tag: "tun-in", protocol: "tun", settings: { name: "damvpn0", mtu: 1500, gateway: ["10.233.0.1/30"], autoOutboundsInterface: wan } },
      { tag: "dns-in", listen: tvip, port: 53, protocol: "tunnel", settings: { address: "8.8.8.8", port: 53, network: "tcp,udp" } }
    ],
    outbounds: [
      { tag: "quattro", protocol: "vless", settings: { vnext: [{ address: s.host, port: s.port, users: [user] }] }, streamSettings: stream },
      { tag: "dns-out", protocol: "dns" }, { tag: "block", protocol: "blackhole" }
    ],
    dns: { servers: ["8.8.8.8", "1.1.1.1"], queryStrategy: "UseIPv4" },
    routing: { rules: [
      { inboundTag: ["dns-in"], source: [tvip, "127.0.0.1"], outboundTag: "dns-out" },
      { inboundTag: ["dns-in"], outboundTag: "block" },
      { inboundTag: ["tun-in"], port: "53", outboundTag: "dns-out" }
    ] }
  };
}
async function disconnect() { await sh(`sh "${SVC}/stop.sh"`, { TVVPN_DIR: RUN }); }
async function connect(id) {
  if (!id && settings.autoServer) id = servers.filter((s) => pings[s.id]).sort((a, b) => pings[a.id] - pings[b.id]).map((s) => s.id)[0];
  const s = servers.find((x) => x.id === (id || state.serverId)) || servers[0];
  if (!s) throw new Error("сначала добавьте подписку");
  if (fs.existsSync(RUN)) await disconnect();
  const wan = (/ dev (\S+)/.exec((await sh("ip route show default")).out) || [])[1];
  const tvip = wan && ipv4Of(wan);
  if (!tvip) throw new Error("нет сети: не найден Wi-Fi или кабель");
  fs.mkdirSync(RUN, { recursive: true, mode: 0o700 });
  const arch = os.arch() === "arm64" || /aarch64/.test((await sh("uname -m")).out) ? "arm64" : "arm32";
  fs.copyFileSync(path.join(APP, "bin", "xray-" + arch), path.join(RUN, "xray")); fs.chmodSync(path.join(RUN, "xray"), 0o700);
  const w = (f, t) => fs.writeFileSync(path.join(RUN, f), t, { mode: 0o600 });
  w("config-tun.json", JSON.stringify(buildConfig(s, wan, tvip), null, 2) + "\n");
  const sni = s.p.sni || s.host, br = (h) => (h.includes(":") ? `[${h}]` : h);
  w("probe.env", `SOCKS_PORT='10808'\nSERVER='${s.host}'\nSERVER_CONNECT='${br(s.host)}'\nPORT='${s.port}'\nPROBE_HOST='${br(sni)}'\nPINNED='${s.p.pcs ? 1 : 0}'\n`);
  w("mask.sed", [s.uuid, s.host, s.p.sni, s.p.serviceName, s.p.pbk].filter((v) => v && v.length > 5).map((v) => `s/${sedEsc(v)}/<СКРЫТО>/g`).join("\n") + "\n");
  // damstudio.tech (подписка с телефона) и сервер подписки — мимо VPN: российские сайты часто не пускают адреса VPN
  const direct = [];
  for (const h of ["damstudio.tech", sub && sub.url ? new URL(sub.url).hostname : null].filter(Boolean)) {
    try { (await require("dns").promises.lookup(h, { all: true, family: 4 })).forEach((a) => direct.includes(a.address) || direct.push(a.address)); } catch (e) { /* нет DNS — без исключений */ }
  }
  const r = await sh(`sh "${SVC}/start.sh"`, { TVVPN_DIR: RUN, DEADMAN: "60", MAXTTL: "315360000", DIRECT_IPS: direct.slice(0, 4).join(" "),
    IPV6_BLOCK: settings.ipv6 ? "1" : "0", DNS_VIA: settings.dns ? "1" : "0", LAN_DIRECT: settings.lan ? "1" : "0" });
  if (!/трафик ТВ идёт через VPN/.test(r.out)) {
    const bad = r.out.split("\n").filter((l) => /✘|Стоп/.test(l)).pop();
    await disconnect();
    throw new Error(bad ? bad.replace(/^.*?(✘|Стоп:)\s*/, "") : "VPN не поднялся");
  }
  fs.writeFileSync(path.join(RUN, "confirmed"), "app");
  state.serverId = s.id; save("state.json", state);
}
function applyAutostart() {
  try {
    if (settings.autostart) { if (!fs.existsSync(INITD)) fs.symlinkSync(path.join(SVC, "autostart.sh"), INITD); }
    else if (fs.existsSync(INITD) || fs.lstatSync(INITD)) fs.unlinkSync(INITD);
  } catch (e) { /* нет папки init.d — значит не Homebrew Channel */ }
}

// ---------- HTTP для интерфейса ----------
function status() {
  return { connected: isUp(), busy, serverId: state.serverId, speed: null, ping: pings[state.serverId] || null,
    subscription: sub ? { name: sub.name, count: servers.length } : null, error: lastError };
}
async function route(method, p, body) {
  if (p === "status") return status();
  if (p === "servers") { pingAll(); return servers.map((s) => ({ id: s.id, label: s.label, kind: s.kind, ping: pings[s.id] || null })); }
  if (p === "settings") { if (method === "POST") { settings = Object.assign(settings, body || {}); save("settings.json", settings); applyAutostart(); } return settings; }
  if (busy) throw new Error("подождите, идёт переключение");
  busy = true; lastError = null;
  try {
    if (p === "connect") { await connect(body && body.id); return status(); }
    if (p === "disconnect") { await disconnect(); return status(); }
    if (p === "subscription") return await setSubscription(body && body.text);
  } catch (e) { lastError = e.message; throw e; } finally { busy = false; }
  const e = new Error("нет такого действия"); e.code = 404; throw e;
}
const server = http.createServer((req, res) => {
  const send = (code, obj) => { res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type", "Cache-Control": "no-store" }); res.end(JSON.stringify(obj)); };
  if (req.method === "OPTIONS") return send(204, {});
  const p = (req.url || "").replace(/^\/api\//, "").replace(/\?.*$/, "");
  let raw = "";
  req.on("data", (c) => { raw += c; if (raw.length > 6e6) req.destroy(); });
  req.on("end", () => {
    let body = null; try { body = raw ? JSON.parse(raw) : null; } catch (e) { return send(400, { error: "bad json" }); }
    route(req.method, p, body).then((r) => send(200, r), (e) => send(e.code === 404 ? 404 : 500, { error: e.message }));
  });
});
server.on("error", (e) => { console.error(e.code === "EADDRINUSE" ? "уже запущен" : e.message); process.exit(e.code === "EADDRINUSE" ? 0 : 1); });
server.listen(PORT, "127.0.0.1", () => console.log("D.A.M VPN: фоновая часть на 127.0.0.1:" + PORT));

// автообновление подписки и автоподключение при старте ТВ
setInterval(() => {
  const day = settings.update === "раз в день" ? 864e5 : settings.update === "раз в неделю" ? 6048e5 : 0;
  if (day && sub && sub.url && Date.now() - sub.updated > day && !busy) setSubscription(sub.url).catch((e) => { lastError = "подписка не обновилась: " + e.message; });
}, 36e5);
if (process.argv.includes("--autoconnect") && settings.autostart && servers.length) {
  (async () => {
    for (let i = 0; i < 30 && !/ dev /.test((await sh("ip route show default")).out); i++) await new Promise((r) => setTimeout(r, 2000));
    if (!isUp()) { busy = true; try { await connect(state.serverId); } catch (e) { lastError = e.message; } finally { busy = false; } }
  })();
}
module.exports = { parseLink, parseAll, linksFrom, buildConfig };
