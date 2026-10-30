#!/usr/bin/env python3
"""Сборка D.A.M VPN for LG в .ipk для webOS (без ares-package): ar-архив из debian-binary, control.tar.gz и data.tar.gz.

    python3 -I stage3/tools/build_ipk.py      → dist/com.damstudio.vpn_<версия>_all.ipk

Xray берётся из vendor/ (tvctl fetch linux-arm64-v8a и linux-arm32-v7a — с проверкой SHA-256).
"""
import io
import json
import os
import sys
import tarfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "stage3", "app")
info = json.load(open(os.path.join(APP, "appinfo.json"), encoding="utf-8"))
APPID, VER = info["id"], info["version"]
DEST = f"usr/palm/applications/{APPID}"

# (путь в пакете, файл на диске, исполняемый)
files = []
for rel in ["appinfo.json", "index.html", "style.css", "app.js", "icon.png", "largeIcon.png", "NOTICE.txt", "vendor/qrcode.js",
            "service/damvpnd.js", "service/run.sh", "service/autostart.sh"]:
    files.append((rel, os.path.join(APP, rel), rel.endswith(".sh")))
for d in ["fonts", "LICENSES"]:
    for f in sorted(os.listdir(os.path.join(APP, d))):
        files.append((f"{d}/{f}", os.path.join(APP, d, f), False))
files += [("service/start.sh", os.path.join(ROOT, "stage2", "tv", "start.sh"), True),
          ("service/stop.sh", os.path.join(ROOT, "stage2", "tv", "stop.sh"), True),
          ("bin/xray-arm64", os.path.join(ROOT, "vendor", "linux-arm64-v8a", "xray"), True),
          ("bin/xray-arm32", os.path.join(ROOT, "vendor", "linux-arm32-v7a", "xray"), True)]
missing = [src for _, src, _ in files if not os.path.isfile(src)]
if missing:
    sys.exit("Нет файлов: " + ", ".join(missing) + "\n(для Xray: ./tvctl fetch linux-arm64-v8a и ./tvctl fetch linux-arm32-v7a)")

now = int(time.time())


def tar_gz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as t:
        dirs = set()
        for name, data, mode in entries:
            parts = name.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d and d not in dirs:
                    dirs.add(d)
                    ti = tarfile.TarInfo("./" + d)
                    ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, now
                    t.addfile(ti)
            ti = tarfile.TarInfo("./" + name)
            ti.size, ti.mode, ti.mtime = len(data), mode, now
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


data_entries = []
size = 0
for rel, src, exe in files:
    b = open(src, "rb").read()
    size += len(b)
    data_entries.append((f"{DEST}/{rel}", b, 0o755 if exe else 0o644))
control = (f"Package: {APPID}\nVersion: {VER}\nSection: misc\nPriority: optional\nArchitecture: all\n"
           f"Installed-Size: {size // 1024}\nMaintainer: D.A.M Studio <https://damstudio.tech>\n"
           "Description: D.A.M VPN for LG — VPN для всего телевизора\n").encode()


def ar(members):
    out = io.BytesIO()
    out.write(b"!<arch>\n")
    for name, data in members:
        hdr = f"{name:<16}{now:<12}{0:<6}{0:<6}{0o100644:<8o}{len(data):<10}`\n".encode()
        assert len(hdr) == 60
        out.write(hdr + data + (b"\n" if len(data) % 2 else b""))
    return out.getvalue()


pkg = ar([("debian-binary", b"2.0\n"),
          ("control.tar.gz", tar_gz([("control", control, 0o644)])),
          ("data.tar.gz", tar_gz(data_entries))])
os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
out = os.path.join(ROOT, "dist", f"{APPID}_{VER}_all.ipk")
open(out, "wb").write(pkg)
print(f"Готово: {out} ({len(pkg) / 1e6:.1f} МБ, файлов: {len(files)})")
