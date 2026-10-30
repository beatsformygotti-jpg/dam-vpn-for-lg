#!/bin/bash
# Проверка этапа 1 без ТВ, на фиктивных данных: генератор и его отказы, права файлов, фильтр секретов,
# конфиг глазами той же версии Xray (сборка под macOS) и сценарий start → check → stop на этом Mac.
# Реальные секреты не читаются. На Mac вместо busybox работает /bin/sh — на ТВ возможны отличия.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(dirname "$HERE")"
ROOT="$(dirname "$STAGE")"
PY=(python3 -I "$HERE/lgvpn.py")
T="$(mktemp -d "${SELFTEST_TMP:-/tmp}/tvvpn-selftest.XXXXXX")"
S="$T/secrets"
W="$T/tv"
PORT="${SELFTEST_PORT:-18808}"
FAKE_ID=00000000-0000-4000-8000-0000000000aa
FAKE_HOST=quattro-selftest.example.invalid
FAKE_SNI=cdn-selftest.example.invalid
FAKE_SVC=selftest-grpc-svc
FAKE_PIN=$(printf 'AB:%.0s' $(seq 31))CD  # 32 байта в формате OpenSSL
FAKE_PBK=selftestRealityPublicKey0123456789abcdefghi  # 43 символа base64url
REAL="type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=$FAKE_SNI&fp=edge&pbk=$FAKE_PBK&sid=ab12&headerType=none"
GOOD="type=grpc&security=tls&encryption=none&serviceName=$FAKE_SVC&mode=gun&sni=$FAKE_SNI&alpn=h2&fp=chrome&headerType=none&pcs=$FAKE_PIN"
fails=0

ok() { echo "  OK   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
noleak() { # $1 — текст, $2 — что проверяли
	local hit="" v
	for v in "$FAKE_ID" "$FAKE_HOST" "$FAKE_SNI" "$FAKE_SVC" "$FAKE_PIN" "$FAKE_PBK"; do
		grep -qiF -- "$v" <<< "$1" && hit="$hit $v"
	done
	if [ -z "$hit" ]; then ok "$2: секретов в выводе нет"; else bad "$2: утечка —$hit"; fi
}
link() { printf 'vless://%s@%s:443?%s#Selftest%%20NL\n' "$FAKE_ID" "$FAKE_HOST" "$1"; }
redact() { "${PY[@]}" redact --secrets-dir "$S"; }
perm() { stat -f %Lp "$1" 2> /dev/null || stat -c %a "$1"; }
show() { sed 's/^/       | /' <<< "$1"; }
cleanup() {
	[ -f "$W/xray.pid" ] && kill "$(cat "$W/xray.pid")" 2> /dev/null
	rm -rf "$T"
}
trap cleanup EXIT
mkdir -m 700 "$S"

echo "1. Генератор конфига"
link "$GOOD" > "$S/quattro.uri"
chmod 644 "$S/quattro.uri" # нарочно открытые права: генератор должен закрыть их сам
out=$("${PY[@]}" config --secrets-dir "$S" --socks-port "$PORT" 2>&1)
rc=$?
show "$out"
[ $rc -eq 0 ] && ok "корректная ссылка принята" || bad "корректная ссылка отклонена (код $rc)"
noleak "$out" "сводка генератора"
[ "$(perm "$S")" = 700 ] && ok "папка секретов: 700" || bad "папка секретов: $(perm "$S")"
for f in quattro.uri xray-config.json probe.env mask.sed; do
	[ "$(perm "$S/$f")" = 600 ] && ok "$f: 600" || bad "$f: $(perm "$S/$f")"
done
if python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1]))
i, o = c["inbounds"][0], c["outbounds"][0]
s = o["streamSettings"]
assert i["listen"] == "127.0.0.1" and i["settings"] == {"auth": "noauth", "udp": False}
assert len(c["inbounds"]) == 1 and len(c["outbounds"]) == 1 and o["protocol"] == "vless"
assert s["network"] == "grpc" and s["security"] == "tls" and s["tlsSettings"]["allowInsecure"] is False
assert "finalmask" not in s and "sockopt" not in s and "fragment" not in json.dumps(c)
assert len(s["tlsSettings"]["pinnedPeerCertSha256"].replace(":", "")) == 64
' "$S/xray-config.json"; then
	ok "конфиг: один SOCKS5 на 127.0.0.1, один VLESS, gRPC, TLS, allowInsecure=false, отпечаток pcs, без FinalMask и фрагментации"
else
	bad "структура конфига"
fi
good_sum=$(shasum -a 256 "$S/xray-config.json")

echo "2. Отказы генератора (конфиг при этом не перезаписывается)"
refuse() { # $1 — ссылка, $2 — ожидаемый код, $3 — описание
	printf '%s\n' "$1" > "$S/bad.uri"
	out=$("${PY[@]}" config --secrets-dir "$S" --uri-file "$S/bad.uri" 2>&1)
	rc=$?
	[ $rc -eq "$2" ] && ok "$3 → отказ, код $rc" || bad "$3: код $rc вместо $2"
	noleak "$out" "$3"
}
refuse "$(link "$GOOD&allowInsecure=1")" 3 "allowInsecure=1"
refuse "$(link "${GOOD/type=grpc/type=xhttp}")" 3 "XHTTP вместо gRPC"
refuse "$(link "${GOOD/security=tls/security=reality}&pbk=AAAA&sid=01")" 3 "REALITY вместо TLS"
refuse "$(link "$GOOD&flow=xtls-rprx-vision")" 3 "Vision с gRPC"
refuse "$(link "$GOOD&fragment=tlshello")" 3 "фрагментация"
refuse "$(link "$GOOD&fm=x")" 3 "FinalMask"
refuse "$(link "$GOOD&host=$FAKE_SNI")" 3 "host для gRPC"
refuse "$(link "${GOOD/pcs=$FAKE_PIN/pcs=ABCD}")" 3 "pcs неверной длины"
refuse "$(link "$GOOD&vcn=$FAKE_SNI")" 3 "vcn (не согласован)"
refuse "$(link "${REAL/pbk=$FAKE_PBK/pbk=}")" 3 "REALITY без ключа pbk"
refuse "$(link "$REAL&fm=x")" 3 "REALITY с FinalMask"
refuse "$(link "$GOOD&pbk=$FAKE_PBK")" 3 "pbk при security=tls"
refuse "vless://$FAKE_ID@$FAKE_HOST?$GOOD" 2 "нет порта"
refuse "https://example.invalid/sub/$FAKE_ID" 2 "нет ссылки vless://"
[ "$(shasum -a 256 "$S/xray-config.json")" = "$good_sum" ] && ok "рабочий конфиг не тронут" || bad "рабочий конфиг перезаписан"

echo "3. Подписка из нескольких ссылок"
{ link "$GOOD"; link "${GOOD/mode=gun/mode=multi}"; } | base64 > "$S/sub.uri"
out=$("${PY[@]}" config --secrets-dir "$S" --uri-file "$S/sub.uri" 2>&1)
rc=$?
show "$out"
[ $rc -eq 2 ] && grep -q 'Ссылок в файле: 2' <<< "$out" && ok "без --pick: список и просьба выбрать" || bad "подписка без --pick (код $rc)"
noleak "$out" "список ссылок"

echo "4. Конфиг глазами Xray (та же версия, сборка macOS)"
if "$HERE/fetch_xray.sh" macos-arm64-v8a > "$T/fetch.log" 2>&1; then ok "Xray для macOS скачан, SHA-256 сверен"; else bad "загрузка Xray: $(tail -n 2 "$T/fetch.log")"; fi
X="$ROOT/vendor/macos-arm64-v8a/xray"
out=$("$X" run -test -c "$S/xray-config.json" 2>&1)
rc=$?
grep -q 'Configuration OK' <<< "$out" && [ $rc -eq 0 ] && ok "xray run -test: Configuration OK (mode gun)" || bad "xray run -test (код $rc): $(redact <<< "$out" | tail -n 3)"
noleak "$out" "вывод xray -test"
mkdir -m 700 "$T/multi"
link "${GOOD/mode=gun/mode=multi}" > "$T/multi/quattro.uri"
"${PY[@]}" config --secrets-dir "$T/multi" > /dev/null 2>&1
out=$("$X" run -test -c "$T/multi/xray-config.json" 2>&1)
grep -q 'Configuration OK' <<< "$out" && ok "xray run -test: Configuration OK (mode multi)" || bad "xray run -test, multi: $(redact <<< "$out" | tail -n 3)"

echo "4б. REALITY + Vision"
mkdir -m 700 "$T/real"
link "$REAL" > "$T/real/quattro.uri"
out=$("${PY[@]}" config --secrets-dir "$T/real" 2>&1)
rc=$?
show "$out"
[ $rc -eq 0 ] && ok "ссылка REALITY принята" || bad "ссылка REALITY отклонена (код $rc)"
noleak "$out" "сводка REALITY"
python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1])); o = c["outbounds"][0]; s = o["streamSettings"]
assert s["network"] == "raw" and s["security"] == "reality" and "tlsSettings" not in s and "grpcSettings" not in s
assert o["settings"]["vnext"][0]["users"][0]["flow"] == "xtls-rprx-vision"
assert set(s["realitySettings"]) == {"serverName", "password", "shortId", "fingerprint"}
' "$T/real/xray-config.json" && ok "конфиг REALITY: raw, reality, Vision, ключи на месте" || bad "структура конфига REALITY"
out=$("$X" run -test -c "$T/real/xray-config.json" 2>&1)
grep -q 'Configuration OK' <<< "$out" && ok "xray run -test: Configuration OK (REALITY)" || bad "xray -test REALITY: $(redact <<< "$out" | tail -n 3)"
noleak "$out" "вывод xray -test REALITY"

echo "5. Фильтр секретов"
upper_sni=$(tr a-z A-Z <<< "$FAKE_SNI")
sample="id=$FAKE_ID host=$FAKE_HOST sni=$upper_sni svc \`$FAKE_SVC\` mac aa:bb:cc:dd:ee:ff ip 8.8.8.8 v6 2a00:1450:4010:c05::71 lan 192.168.1.146 lo 127.0.0.1 wifi_aabbccddeeff_5465737453534944_managed_psk vless://x@y:1?a=b mail test.user@example.com sha 263fa7325c63b3a7f7316405f561e7c790b44c1461992ea648007f0374e9bdf4"
out=$(redact <<< "$sample")
show "$out"
noleak "$out" "фильтр"
leak=""
for v in 8.8.8.8 aa:bb:cc 2a00:1450 5465737453534944 test.user vless://x; do grep -qF -- "$v" <<< "$out" && leak="$leak $v"; done
[ -z "$leak" ] && ok "публичные IP, MAC, имя сети, ссылки и почта скрыты" || bad "не скрыто:$leak"
keep=""
for v in 192.168.1.146 127.0.0.1 263fa7325c63; do grep -qF -- "$v" <<< "$out" || keep="$keep $v"; done
[ -z "$keep" ] && ok "адреса локальной сети и контрольные суммы остались читаемыми" || bad "лишнее скрыто:$keep"

echo "6. Скрипты ТВ на этом Mac (/bin/sh вместо busybox, сервер фиктивный)"
for f in facts start check stop; do
	sh -n "$STAGE/tv/$f.sh" && ok "$f.sh: синтаксис" || bad "$f.sh: синтаксис"
done
mkdir -m 700 "$W"
cp "$X" "$W/xray"
cp "$S/xray-config.json" "$W/config.json"
cp "$S/probe.env" "$S/mask.sed" "$W/"
out=$(TVVPN_DIR="$W" TTL=120 sh "$STAGE/tv/start.sh" 2>&1 | redact)
show "$out"
grep -q "Xray работает: PID .* 127.0.0.1:$PORT" <<< "$out" && ok "start: Xray запущен, слушает только 127.0.0.1:$PORT" || bad "start"
noleak "$out" "вывод start"
out=$(TVVPN_DIR="$W" sh "$STAGE/tv/check.sh" 2>&1 | redact)
show "$out"
grep -q '✔ слушает 127.0.0.1' <<< "$out" && ok "check: видит процесс и порт" || bad "check: процесс или порт"
grep -q '✘ запрос через прокси не прошёл' <<< "$out" && grep -q 'ЕСТЬ ОШИБКИ' <<< "$out" &&
	ok "check: фиктивный сервер честно не проходит" || bad "check: ожидался провал на фиктивном сервере"
noleak "$out" "вывод check"
out=$(TVVPN_DIR="$W" sh "$STAGE/tv/stop.sh" 2>&1 | redact)
show "$out"
grep -q '✔ Xray остановлен' <<< "$out" && [ ! -e "$W" ] && ok "stop: Xray остановлен, папка удалена" || bad "stop"
noleak "$out" "вывод stop"

echo "7. Этап 2: конфиг с TUN (без запуска — TUN создаётся только при старте Xray)"
out=$("${PY[@]}" tun-config --secrets-dir "$S" 2>&1)
rc=$?
show "$out"
[ $rc -eq 0 ] && ok "tun-config собран" || bad "tun-config (код $rc)"
noleak "$out" "сводка tun-config"
[ "$(perm "$S/xray-tun.json")" = 600 ] && ok "xray-tun.json: 600" || bad "xray-tun.json: $(perm "$S/xray-tun.json")"
if python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1]))
o = [x["tag"] for x in c["outbounds"]]
t = [x for x in c["inbounds"] if x["protocol"] == "tun"][0]["settings"]
d = [x for x in c["inbounds"] if x["tag"] == "dns-in"][0]
r = c["routing"]["rules"]
assert o == ["quattro", "dns-out", "block"], o
assert t["name"] == "damvpn0" and t["autoOutboundsInterface"] == "wlan0" and "autoSystemRoutingTable" not in t
assert d["listen"] == "192.168.1.146" and d["port"] == 53 and d["protocol"] == "tunnel"
assert r[0] == {"inboundTag": ["dns-in"], "source": ["192.168.1.146", "127.0.0.1"], "outboundTag": "dns-out"}
assert r[1] == {"inboundTag": ["dns-in"], "outboundTag": "block"}
assert r[2] == {"inboundTag": ["tun-in"], "port": "53", "outboundTag": "dns-out"}
assert c["outbounds"][0]["streamSettings"]["tlsSettings"]["allowInsecure"] is False
' "$S/xray-tun.json"; then
	ok "первым выходом остаётся quattro, TUN damvpn0 на wlan0, DNS-вход 192.168.1.146:53 только для ТВ, остальным — блок"
else
	bad "структура xray-tun.json"
fi
out=$("$X" run -test -c "$S/xray-tun.json" 2>&1)
grep -q 'Configuration OK' <<< "$out" && ok "xray run -test: Configuration OK (конфиг с TUN)" || bad "xray -test с TUN: $(redact <<< "$out" | tail -n 3)"
"${PY[@]}" tun-config --secrets-dir "$S" > /dev/null 2>&1 && grep -q '"tun"' "$S/xray-tun.json" && ok "повторный tun-config берёт конфиг этапа 1, TUN не дублируется" || bad "повторный tun-config"
for f in start check diag dnsfacts speed stop; do
	sh -n "$ROOT/stage2/tv/$f.sh" && ok "этап 2, $f.sh: синтаксис" || bad "этап 2, $f.sh: синтаксис"
done

if [ -d "$ROOT/.git" ]; then
	echo "8. Git"
	for p in quattro.uri x/xray-config.json probe.env mask.sed vendor/x reports/x.txt; do
		git -C "$ROOT" check-ignore -q "$p" && ok "игнорируется: $p" || bad "НЕ игнорируется: $p"
	done
	git -C "$ROOT" check-ignore -q stage1/config.template.json && bad "шаблон конфига игнорируется" || ok "шаблон конфига не игнорируется"
	# Номер сессии Claude в строке «claude --resume» — не секрет, его не считаем
	re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
	found=$(cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 grep -hIE "$re" 2> /dev/null |
		grep -v 'claude --resume' | grep -oE "$re" | grep -v -x "$FAKE_ID" | sort -u)
	[ -z "$found" ] && ok "в файлах для Git нет UUID и ссылок vless:// с UUID (кроме фиктивного)" || bad "в файлах для Git найдено: $found"
fi

echo
if [ "$fails" -eq 0 ]; then echo "САМОПРОВЕРКА ПРОЙДЕНА"; else echo "САМОПРОВЕРКА: ошибок $fails"; fi
[ "$fails" -eq 0 ]
