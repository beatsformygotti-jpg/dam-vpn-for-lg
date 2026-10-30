#!/usr/bin/env python3
"""Этап 1: ссылка Quattro vless:// -> конфиг Xray, и фильтр секретов для любого вывода.

    python3 -I lgvpn.py config [--list] [--pick N] [--socks-port 10808]
    python3 -I lgvpn.py redact < сырой_вывод > вывод_без_секретов

Секреты лежат только в папке секретов (по умолчанию ~/.config/lg-tv-vpn: папка 700, файлы 600).
Значения UUID, адреса сервера, SNI, serviceName и authority скрипт не печатает никогда.
Коды выхода: 0 — готово; 2 — ссылка не найдена или повреждена; 3 — ссылка требует того,
что этап 1 запрещает или что не подтверждено (решает архитектор, а не скрипт).
"""

import argparse
import base64
import binascii
import ipaddress
import json
import os
import re
import stat
import sys
from urllib.parse import quote, unquote

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(os.path.dirname(HERE), "config.template.json")
TUN_TEMPLATE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "stage2", "tun.template.json")
DEFAULT_SECRETS = os.path.expanduser(os.environ.get("LGVPN_SECRETS") or "~/.config/lg-tv-vpn")

EXIT_INPUT = 2
EXIT_REFUSED = 3

# Параметры ссылки, которые относятся к VLESS + gRPC + TLS и переносятся в конфиг как есть.
USED = {"type", "security", "encryption", "flow", "serviceName", "mode", "authority", "sni", "alpn", "fp", "pcs"}
# REALITY + Vision (большинство серверов Quattro; разрешено 30.10.2026 ради скорости и «все серверы в приложении»)
REALITY_USED = {"pbk", "sid", "spx", "pqv"}
# Параметры других транспортов: допустимы только пустыми или «none», тогда просто не используются.
NEUTRAL = {"headerType", "host", "path", "seed", "quicSecurity", "key"}
# Отключение проверки сертификата: допустимо только в выключенном виде.
INSECURE = {"allowInsecure", "insecure", "allow_insecure"}

HOST_RE = re.compile(r"^[A-Za-z0-9.-]{1,253}$")
AUTHORITY_RE = re.compile(r"^[A-Za-z0-9.:\[\]-]{1,260}$")
SERVICE_RE = re.compile(r"^[A-Za-z0-9._~!$&()*+,;=:@%/-]{0,4096}$")  # у Quattro бывает 500–800 символов
ALPN_RE = re.compile(r"^[A-Za-z0-9./-]{1,32}$")
FP_RE = re.compile(r"^[a-z0-9_]{1,32}$")
PIN_RE = re.compile(r"^[0-9A-Fa-f]{64}$")  # SHA-256 сертификата; двоеточия (формат OpenSSL) убираются заранее
PBK_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")  # x25519, base64url без «=»
SID_RE = re.compile(r"^[0-9a-fA-F]{0,16}$")
SPX_RE = re.compile(r"^/[A-Za-z0-9._~!$&()*+,;=:@%/?-]{0,200}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# Короткие или «обычные» значения (например, serviceName «grpc») маскируются только в кавычках и путях,
# иначе фильтр испортит весь журнал Xray.
VOCAB = set(
    "transport internet grpc tls vless proxy socks tun tunmulti multi gun stream service name dial outbound "
    "inbound xray connection request response tcp udp app dispatcher router dns info debug warning error "
    "accepted tunneling quattro".split()
)


class LinkError(Exception):
    pass


def stop(message, code):
    print("Стоп: " + message, file=sys.stderr)
    sys.exit(code)


def ip_kind(value):
    try:
        return "IPv%d" % ipaddress.ip_address(value).version
    except ValueError:
        return None


# ---------- ссылки ----------

def load_links(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read().strip()
    except FileNotFoundError:
        raise LinkError(f"нет файла {path}: положите туда ссылку vless:// (RUNBOOK, шаг В)")
    except UnicodeDecodeError:
        raise LinkError(f"{path} не в UTF-8")
    if "://" not in text:  # подписка целиком, в base64
        compact = "".join(text.split())
        altchars = b"-_" if re.search(r"[-_]", compact) else None
        try:
            text = base64.b64decode(compact + "=" * (-len(compact) % 4), altchars=altchars).decode("utf-8")
        except (binascii.Error, ValueError, UnicodeDecodeError):
            text = ""
    links = [line.strip() for line in text.splitlines() if line.strip().lower().startswith("vless://")]
    if not links:
        raise LinkError(f"в {path} нет ссылок vless://")
    return links


def split_link(link):
    """vless://UUID@адрес:порт?параметры#метка -> части, без проверок."""
    body = link.strip()[len("vless://"):]
    body, _, label = body.partition("#")
    body, _, query = body.partition("?")
    userinfo, at, hostport = body.rpartition("@")
    hostport = hostport.rstrip("/")
    if hostport.startswith("["):
        host, _, rest = hostport[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    elif hostport.count(":") == 1:
        host, _, port = hostport.partition(":")
    else:
        host, port = hostport, ""
    params, dupes = {}, []
    for part in filter(None, query.split("&")):
        key, _, value = part.partition("=")
        key, value = unquote(key), unquote(value)
        if key in params:
            dupes.append(key)
        params[key] = value
    return {"uuid": unquote(userinfo) if at else "", "host": unquote(host), "port": port,
            "params": params, "dupes": dupes, "label": unquote(label)}


def check_link(parts):
    """Возвращает (spec, problems, notes). В problems и notes нет значений секретов."""
    p = parts["params"]
    problems, notes = [], []

    def broken(text):
        problems.append((EXIT_INPUT, text))

    def refuse(text):
        problems.append((EXIT_REFUSED, text))

    for key in parts["dupes"]:
        broken(f"параметр {key} указан дважды")
    uuid, host, port = parts["uuid"], parts["host"], parts["port"]
    if not uuid or len(uuid) > 64 or re.search(r"\s", uuid):
        broken("UUID пустой или повреждён")
    if not host or not (ip_kind(host) or HOST_RE.match(host)):
        broken("адрес сервера пустой или с недопустимыми символами")
    if not (port.isdigit() and 1 <= int(port) <= 65535):
        broken("нет порта сервера или он неверный")

    transport = p.get("type") or "tcp"
    security = p.get("security") or "none"
    reality = security == "reality"
    if reality:
        if transport not in ("tcp", "raw"):
            refuse(f"type={transport[:20]} с REALITY: поддержан только tcp")
    elif transport != "grpc":
        refuse(f"type={transport[:20]}: поддержаны gRPC + TLS и TCP + REALITY; XHTTP и другие — после подтверждения Quattro")
    if security not in ("tls", "reality"):
        refuse(f"security={security[:20]}: поддержаны только TLS и REALITY")
    if (p.get("encryption") or "none") != "none":
        refuse("encryption не none: шифрование VLESS не входит в подтверждённые параметры")
    flow = p.get("flow", "")
    if reality:
        if flow not in ("", "xtls-rprx-vision"):
            refuse(f"flow={flow[:30]}: с REALITY поддержан только xtls-rprx-vision")
    elif flow.startswith("xtls-rprx-vision"):
        refuse(f"flow={flow[:30]}: с gRPC Xray его не поддерживает («XTLS only supports TLS and REALITY directly»)"
               " — уточнить у Quattro")
    elif flow:
        refuse(f"flow={flow[:30]}: неизвестное значение")
    if reality:
        if not PBK_RE.match(p.get("pbk", "")):
            refuse("pbk (открытый ключ REALITY) пустой или не похож на ключ")
        if not SID_RE.match(p.get("sid", "")):
            refuse("sid (shortId REALITY) не hex или длиннее 16 символов")
        if p.get("spx") and not SPX_RE.match(p["spx"]):
            refuse("spx с недопустимыми символами")
        if p.get("pqv") and not re.fullmatch(r"[A-Za-z0-9_-]{2000,2700}", p["pqv"]):
            refuse("pqv не похож на ключ ML-DSA-65")
        if not p.get("sni"):
            refuse("для REALITY нужен sni")
    else:
        for key in sorted(REALITY_USED & p.keys()):
            refuse(f"{key} относится к REALITY, а security=tls")
    mode = p.get("mode") or "gun"
    if mode not in ("gun", "multi"):
        refuse(f"mode={mode[:20]}: для gRPC известны только gun и multi")
    service = p.get("serviceName", "")
    if not SERVICE_RE.match(service):
        refuse("serviceName с недопустимыми символами")
    elif not service and not reality:
        notes.append("⚠ serviceName в ссылке не задан — Xray возьмёт пустое имя; уточнить у Quattro")
    authority = p.get("authority", "")
    if authority and not AUTHORITY_RE.match(authority):
        refuse("authority с недопустимыми символами")
    sni = p.get("sni", "")
    if sni and not (ip_kind(sni) or HOST_RE.match(sni)):
        refuse("sni с недопустимыми символами")
    if not sni and ip_kind(host):
        notes.append("⚠ SNI не задан, а адрес — IP: сертификат будет сверяться с IP; уточнить у Quattro")
    alpn = [a for a in p.get("alpn", "").split(",") if a]
    if any(not ALPN_RE.match(a) for a in alpn):
        refuse("alpn с недопустимыми символами")
    elif alpn and "h2" not in alpn:
        notes.append(f"⚠ alpn={','.join(alpn)} без h2: gRPC идёт поверх HTTP/2 — не исправляю, уточнить у Quattro")
    fp = p.get("fp", "")
    if fp and not FP_RE.match(fp):
        refuse("fp с недопустимыми символами")
    if reality and p.get("pcs"):
        refuse("pcs с REALITY не используется")
    # pcs — закрепление сертификата: Xray примет только сертификат с этим отпечатком SHA-256
    pins = [v.strip() for v in p.get("pcs", "").split(",") if v.strip()]
    if any(not PIN_RE.match(v.replace(":", "")) for v in pins):
        refuse("pcs не похож на отпечаток SHA-256 (32 байта в hex)")
    for key in sorted(INSECURE & p.keys()):
        if p[key].lower() not in ("", "0", "false"):
            refuse(f"{key}={p[key][:10]}: ссылка просит отключить проверку сертификата — этап 1 так не работает")
    ignored = []
    for key in sorted(NEUTRAL & p.keys()):
        if p[key] in ("", "none"):
            ignored.append(f"{key}={p[key] or '(пусто)'}")
        else:
            refuse(f"{key} задан, но к gRPC+TLS не относится — уточнить у Quattro, что он значит")
    unknown = sorted(set(p) - USED - REALITY_USED - NEUTRAL - INSECURE)
    if unknown:
        refuse("параметры вне подтверждённого списка: " + ", ".join(k[:30] for k in unknown)
               + " (FinalMask, фрагментация, ECH, vcn и т. п. — только решением архитектора)")
    if ignored:
        notes.append("не относятся к этому транспорту и пустые — не используются: " + ", ".join(ignored))
    spec = {"uuid": uuid, "host": host, "port": int(port) if port.isdigit() else 0, "service": service,
            "mode": mode, "authority": authority, "sni": sni, "alpn": alpn, "fp": fp, "pins": pins,
            "security": security, "flow": flow, "pbk": p.get("pbk", ""), "sid": p.get("sid", ""),
            "spx": p.get("spx", ""), "pqv": p.get("pqv", ""), "label": parts["label"]}
    return spec, problems, notes


# ---------- конфиг ----------

def build_config(spec, socks_port):
    with open(TEMPLATE, encoding="utf-8") as f:
        cfg = json.load(f)
    cfg["inbounds"][0]["port"] = socks_port
    out = cfg["outbounds"][0]
    server = out["settings"]["vnext"][0]
    server["address"] = spec["host"]
    server["port"] = spec["port"]
    server["users"][0]["id"] = spec["uuid"]
    stream = out["streamSettings"]
    tls = stream["tlsSettings"]
    if tls.get("allowInsecure") is not False:
        stop("в шаблоне allowInsecure должен быть false", EXIT_REFUSED)
    if spec["sni"]:
        tls["serverName"] = spec["sni"]
    else:
        del tls["serverName"]
    if spec["alpn"]:
        tls["alpn"] = spec["alpn"]
    if spec["fp"]:
        tls["fingerprint"] = spec["fp"]
    if spec["pins"]:
        tls["pinnedPeerCertSha256"] = ",".join(spec["pins"])
    grpc = stream["grpcSettings"]
    grpc["serviceName"] = spec["service"]
    grpc["multiMode"] = spec["mode"] == "multi"
    if spec["authority"]:
        grpc["authority"] = spec["authority"]
    if spec["security"] == "reality":
        server["users"][0]["flow"] = spec["flow"]
        rs = {"serverName": spec["sni"], "password": spec["pbk"], "shortId": spec["sid"]}
        if spec["fp"]:
            rs["fingerprint"] = spec["fp"]
        if spec["spx"]:
            rs["spiderX"] = spec["spx"]
        if spec["pqv"]:
            rs["mldsa65Verify"] = spec["pqv"]
        out["streamSettings"] = {"network": "raw", "security": "reality", "realitySettings": rs}
    left = re.findall(r"__[A-Z_]+__", json.dumps(cfg))
    if left:
        stop("в шаблоне остались незаполненные поля: " + ", ".join(sorted(set(left))), EXIT_INPUT)
    return cfg


def probe_env(spec, socks_port):
    """Значения для проверок на ТВ. Все они уже прошли проверку символов, кавычек в них нет."""
    host = spec["host"]
    sni = spec["sni"] or host
    values = {
        "SOCKS_PORT": socks_port,
        "SERVER": host,
        "SERVER_CONNECT": f"[{host}]" if ip_kind(host) == "IPv6" else host,
        "PORT": spec["port"],
        "PROBE_HOST": f"[{sni}]" if ip_kind(sni) == "IPv6" else sni,
        "PINNED": 1 if spec["pins"] else 0,
    }
    return "".join(f"{key}='{value}'\n" for key, value in values.items())


# ---------- маскирование ----------

def secret_values(cfg):
    out = cfg["outbounds"][0]
    server = out["settings"]["vnext"][0]
    stream = out.get("streamSettings", {})
    return [("UUID", server["users"][0].get("id", "")),
            ("SERVER", server.get("address", "")),
            ("SNI", stream.get("tlsSettings", {}).get("serverName", "")),
            ("SERVICE", stream.get("grpcSettings", {}).get("serviceName", "")),
            ("AUTHORITY", stream.get("grpcSettings", {}).get("authority", "")),
            ("PIN", stream.get("tlsSettings", {}).get("pinnedPeerCertSha256", "")),
            ("SNI", stream.get("realitySettings", {}).get("serverName", "")),
            ("PBK", stream.get("realitySettings", {}).get("password", "")),
            ("SID", stream.get("realitySettings", {}).get("shortId", "")),
            ("SPX", stream.get("realitySettings", {}).get("spiderX", ""))]


def link_values(link):
    parts = split_link(link)
    p = parts["params"]
    return [("UUID", parts["uuid"]), ("SERVER", parts["host"]), ("SNI", p.get("sni", "")),
            ("SERVICE", p.get("serviceName", "")), ("AUTHORITY", p.get("authority", "")), ("PIN", p.get("pcs", "")),
            ("PBK", p.get("pbk", "")), ("SID", p.get("sid", "")), ("SPX", p.get("spx", ""))]


def mask_items(values):
    """[(метка, вариант значения, только_в_контексте)], от длинных к коротким."""
    items = {}
    for tag, value in values:
        if not value:
            continue
        weak = len(value) < 6 or value.lower() in VOCAB
        for variant in {value, value.lower(), quote(value, safe=""), quote(value, safe="/")}:
            items.setdefault(variant, (tag, weak))
    return sorted(((tag, v, weak) for v, (tag, weak) in items.items()), key=lambda item: -len(item[1]))


def sed_escape(text):
    return "".join("." if ch in "[]" else "\\" + ch if ch in "\\/.*^$" else ch for ch in text)


def sed_script(values):
    lines = []
    for tag, variant, weak in mask_items(values):
        e = sed_escape(variant)
        if weak:
            lines += [f"s/`{e}`/`<{tag}>`/g", f"s/\\/{e}\\//\\/<{tag}>\\//g", f's/"{e}"/"<{tag}>"/g']
        else:
            lines.append(f"s/{e}/<{tag}>/g")
    return "\n".join(lines) + "\n"


def _ipv4(m):
    try:
        ip = ipaddress.IPv4Address(m.group(0))
    except ValueError:
        return m.group(0)
    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved:
        return m.group(0)
    return "<IPv4>"


def _ipv6(m):
    try:
        ip = ipaddress.IPv6Address(m.group(0))
    except ValueError:
        return m.group(0)
    if ip.is_loopback or ip.is_unspecified or ip.is_multicast:
        return m.group(0)
    return "<IPv6>"


def _token(m):
    return m.group(0) if re.fullmatch(r"[0-9a-fA-F]+", m.group(0)) else "<TOKEN>"


GENERIC = [
    (re.compile(r"\b(vless|vmess|trojan|ss|hysteria2?|tuic)://\S+", re.I), r"\1://<СКРЫТО>"),
    (re.compile(r"\bhttps?://[^\s'\"<>]*(?:sub|token|uuid)[^\s'\"<>]*", re.I), "<URL>"),
    (re.compile(r"\b[\w.+-]+@(?:[\w-]+\.)+[A-Za-z]{2,}\b"), "<EMAIL>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<UUID>"),
    (re.compile(r"\b(wifi|ethernet)_[0-9A-Fa-f]{12}(?:_[0-9A-Za-z]+)*"), r"\1_<ID>"),
    (re.compile(r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])"), "<MAC>"),
    (re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?!\.?\d)"), _ipv4),
    (re.compile(r"(?<![0-9A-Za-z:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Za-z:])"), _ipv6),
    (re.compile(r"(?<![A-Za-z0-9+_=-])(?=[A-Za-z0-9+_-]*[A-Za-z])(?=[A-Za-z0-9+_-]*\d)[A-Za-z0-9+_-]{40,}={0,2}"
                r"(?![A-Za-z0-9+_=-])"), _token),
]


def known_rules(secrets_dir):
    values = []
    try:
        with open(os.path.join(secrets_dir, "xray-config.json"), encoding="utf-8") as f:
            values += secret_values(json.load(f))
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
        pass
    try:
        for link in load_links(os.path.join(secrets_dir, "quattro.uri")):
            values += link_values(link)
    except (LinkError, OSError):
        pass
    rules = []
    for tag, variant, weak in mask_items(values):
        e = re.escape(variant)
        pattern = r"(?<=[`/\"=])" + e + r"(?=[`/\"&\s]|$)" if weak else e
        rules.append((re.compile(pattern, re.IGNORECASE), f"<{tag}>"))
    return rules


def redact_text(text, rules):
    for pattern, repl in rules:
        text = pattern.sub(repl, text)
    return text


def clean_label(label):
    text = "".join(ch for ch in label if ch.isprintable())
    return redact_text(text, GENERIC)[:40] or "(без названия)"


# ---------- файлы ----------

def private_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, mode=0o700)
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        os.chmod(path, 0o700)
        print(f"Права папки секретов исправлены: {mode:o} → 700", file=sys.stderr)


def private_file(path):
    if os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)
        if mode & 0o077:
            os.chmod(path, 0o600)
            print(f"Права {os.path.basename(path)} исправлены: {mode:o} → 600", file=sys.stderr)


def outside_git(path):
    p = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            stop(f"папка секретов внутри Git-репозитория ({p}) — секреты должны лежать вне Git", EXIT_REFUSED)
        parent = os.path.dirname(p)
        if parent == p:
            return
        p = parent


def write_private(path, text):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# ---------- команды ----------

def print_list(links):
    for i, link in enumerate(links, 1):
        parts = split_link(link)
        p = parts["params"]
        kind = clean_label(f"type={p.get('type') or 'tcp'}, security={p.get('security') or 'none'}")
        print(f"  {i}. {clean_label(parts['label'])} — {kind}")


def print_summary(spec, notes, pick, total, socks_port, secrets):
    host, sni = spec["host"], spec["sni"]
    print(f"Ссылка {pick} из {total}: «{clean_label(spec['label'])}»")
    print(f"  Сервер: задан ({ip_kind(host) or 'домен'}, {len(host)} симв.), порт {spec['port']}")
    print("  UUID: задан, " + ("формат UUID" if UUID_RE.match(spec["uuid"]) else "не в формате UUID — Xray сам получит UUID из строки"))
    if spec["security"] == "reality":
        print(f"  Транспорт: TCP + REALITY, flow {spec['flow'] or 'пусто'}")
        print(f"  REALITY: ключ pbk задан, shortId {'задан' if spec['sid'] else 'пустой'}, spiderX {'задан' if spec['spx'] else 'не задан'}"
              + (", ML-DSA задан" if spec["pqv"] else ""))
    else:
        print(f"  Транспорт: gRPC, режим {spec['mode']} (multiMode={'true' if spec['mode'] == 'multi' else 'false'})")
        print("  serviceName: " + (f"задан ({len(spec['service'])} симв.)" if spec["service"] else "не задан"))
        print("  authority: " + ("задан" if spec["authority"] else "не задан → Xray возьмёт SNI или домен адреса"))
        print("  TLS: да, allowInsecure=false — сертификат проверяется всегда")
    if spec["pins"]:
        print(f"  pcs: задан ({len(spec['pins'])} отпечаток) — Xray примет только сертификат с этим отпечатком SHA-256")
    if sni:
        print(f"  SNI: задан ({ip_kind(sni) or 'домен'}), совпадает с адресом: {'да' if sni.lower() == host.lower() else 'нет'}")
    else:
        print("  SNI: не задан → Xray возьмёт адрес сервера")
    if spec["security"] != "reality":
        print("  ALPN: " + (",".join(spec["alpn"]) if spec["alpn"] else "не задан → Xray предложит h2 и http/1.1"))
    print("  fingerprint: " + (spec["fp"] or "не задан → Xray по умолчанию Chrome"))
    if spec["security"] != "reality":
        print("  flow: пусто, encryption: none")
    for note in notes:
        print("  " + note)
    print(f"  Локальный SOCKS5: 127.0.0.1:{socks_port}, без пароля, без UDP")
    print(f"Записано (права 600): {secrets}/xray-config.json, probe.env, mask.sed")


def cmd_config(args):
    secrets = args.secrets_dir
    if not 1024 <= args.socks_port <= 65535:
        stop("--socks-port должен быть от 1024 до 65535", EXIT_INPUT)
    private_dir(secrets)
    outside_git(secrets)
    uri_file = args.uri_file or os.path.join(secrets, "quattro.uri")
    private_file(uri_file)
    try:
        links = load_links(uri_file)
    except LinkError as e:
        stop(str(e), EXIT_INPUT)
    if args.list or (len(links) > 1 and args.pick is None):
        print(f"Ссылок в файле: {len(links)}")
        print_list(links)
        if args.list:
            return 0
        stop("выберите одну: tvctl config --pick N", EXIT_INPUT)
    pick = args.pick or 1
    if not 1 <= pick <= len(links):
        stop(f"--pick должен быть от 1 до {len(links)}", EXIT_INPUT)
    spec, problems, notes = check_link(split_link(links[pick - 1]))
    if problems:
        for _, text in problems:
            print("  ✘ " + text, file=sys.stderr)
        stop("ссылка не подходит для этапа 1, конфиг не записан", max(code for code, _ in problems))
    cfg = build_config(spec, args.socks_port)
    write_private(os.path.join(secrets, "xray-config.json"), json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    write_private(os.path.join(secrets, "probe.env"), probe_env(spec, args.socks_port))
    write_private(os.path.join(secrets, "mask.sed"), sed_script(secret_values(cfg)))
    print_summary(spec, notes, pick, len(links), args.socks_port, secrets)
    return 0


def cmd_tun_config(args):
    """Этап 2: к конфигу этапа 1 добавляются вход TUN, DNS-вход на адресе ТВ (для ConnMan), DNS-выход и правила."""
    secrets = args.secrets_dir
    if not re.fullmatch(r"[a-z0-9]{1,15}", args.wan):
        stop("--wan — имя сетевого интерфейса ТВ, например wlan0", EXIT_INPUT)
    if ip_kind(args.tv_ip) != "IPv4":
        stop("--tv-ip — IPv4-адрес ТВ в домашней сети, например 192.168.1.146", EXIT_INPUT)
    try:
        with open(os.path.join(secrets, "xray-config.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        stop("нет конфига этапа 1 — сначала tvctl config", EXIT_INPUT)
    if any(i.get("protocol") == "tun" for i in cfg["inbounds"]):
        stop("в конфиге этапа 1 уже есть вход tun", EXIT_INPUT)
    with open(TUN_TEMPLATE, encoding="utf-8") as f:
        add = json.load(f)
    add["inbound"]["settings"]["autoOutboundsInterface"] = args.wan
    add["dnsInbound"]["listen"] = args.tv_ip
    add["routing"]["rules"][0]["source"] = [args.tv_ip, "127.0.0.1"]
    cfg["inbounds"] += [add["inbound"], add["dnsInbound"]]
    cfg["outbounds"] += add["outbounds"]  # первым остаётся выход quattro — он по умолчанию
    cfg["dns"] = add["dns"]
    cfg["routing"] = add["routing"]
    write_private(os.path.join(secrets, "xray-tun.json"), json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    tun = add["inbound"]["settings"]
    print(f"TUN: интерфейс {tun['name']}, адрес {tun['gateway'][0]}, MTU {tun['mtu']}; собственный трафик Xray идёт через {args.wan}")
    print(f"DNS: Xray слушает {args.tv_ip}:53 только для самого ТВ — на время работы туда смотрит ConnMan;")
    print("     ответы — встроенный DNS Xray (8.8.8.8, 1.1.1.1 через Quattro, только IPv4)")
    print("Сервер и остальные параметры — из конфига этапа 1; SOCKS5 127.0.0.1 остаётся для проверок")
    print(f"Записано (права 600): {secrets}/xray-tun.json")
    return 0


def cmd_redact(args):
    rules = known_rules(args.secrets_dir) + GENERIC
    out = sys.stdout.buffer
    for raw in iter(sys.stdin.buffer.readline, b""):
        out.write(redact_text(raw.decode("utf-8", "replace"), rules).encode("utf-8"))
        out.flush()
    return 0


def main():
    ap = argparse.ArgumentParser(description="Этап 1: конфиг Xray из ссылки Quattro и фильтр секретов")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("config", help="ссылка vless:// → xray-config.json, probe.env, mask.sed (права 600)")
    c.add_argument("--uri-file", help="по умолчанию <папка секретов>/quattro.uri")
    c.add_argument("--pick", type=int, help="номер ссылки, если в файле подписка")
    c.add_argument("--list", action="store_true", help="только показать ссылки (без секретов)")
    c.add_argument("--socks-port", type=int, default=10808)
    t = sub.add_parser("tun-config", help="этап 2: xray-config.json → xray-tun.json (права 600)")
    t.add_argument("--wan", default="wlan0", help="интерфейс ТВ с маршрутом по умолчанию")
    t.add_argument("--tv-ip", default="192.168.1.146", help="IPv4-адрес ТВ в домашней сети (отчёт facts)")
    r = sub.add_parser("redact", help="фильтр: stdin → stdout без секретов")
    for sp in (c, t, r):
        sp.add_argument("--secrets-dir", default=DEFAULT_SECRETS)
    args = ap.parse_args()
    return {"config": cmd_config, "tun-config": cmd_tun_config, "redact": cmd_redact}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
