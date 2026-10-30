#!/bin/sh
# Этап 2: проверка — идёт ли весь трафик ТВ через VPN. Ничего не меняет. Запуск с Mac: tvctl tun-check.
# Внешние IP печатаются только замаскированными и никуда не записываются.

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac
TUN=damvpn0
TABLE=100

mask() { if [ -s "$D/mask.sed" ]; then sed -f "$D/mask.sed"; else cat; fi; }
is_ours() {
	c=$({ tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null) || c=$(ps -o args= -p "$1" 2>/dev/null)
	case "$c" in *"$D/xray"*) return 0 ;; esac
	return 1
}
is_ip() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$'; }
mask_ip() { case "$1" in *.*.*.*) printf '%s.*.*.*' "${1%%.*}" ;; *:*) printf '%s:…' "${1%%:*}" ;; esac; }

ok=0
bad=0
pass() { echo "  ✔ $*"; ok=$((ok + 1)); }
fail() { echo "  ✘ $*"; bad=$((bad + 1)); }
warn() { echo "  ⚠ $*"; }

main() {
	[ -s "$D/probe.env" ] && [ -s "$D/wan" ] || { echo "Стоп: этап 2 не запущен — сначала tvctl tun-start"; return 1; }
	. "$D/probe.env"
	WAN=$(cat "$D/wan")
	if [ -f "$D/rolled_back" ]; then
		echo "Откат уже выполнен в $(cat "$D/rolled_back"):"
		sed 's/^/    /' "$D/rollback.log"
		echo "Для новой попытки: tvctl tun-stop, затем tvctl push и tvctl tun-start"
		return 1
	fi

	echo "1) Xray и интерфейс $TUN"
	pid=$(cat "$D/xray.pid" 2> /dev/null)
	if [ -n "$pid" ] && is_ours "$pid"; then pass "Xray работает, PID $pid"; else fail "Xray не работает"; fi
	if ip link show "$TUN" 2> /dev/null | grep -q 'UP'; then pass "$TUN поднят"; else fail "$TUN нет или он выключен"; fi

	echo "2) Правила и таблица $TABLE"
	r=$(ip rule show | grep -E '^(899[0-9]|900[0-9]):')
	printf '%s\n' "$r" | sed 's/^/    /'
	if printf '%s\n' "$r" | grep -q "^9004:.*lookup $TABLE"; then pass "весь трафик по умолчанию направлен в таблицу $TABLE"; else fail "нет правила 9004"; fi
	if printf '%s\n' "$r" | grep -q '^9000:'; then pass "локальная сеть идёт мимо туннеля (правило 9000)"; else fail "нет правила для локальной сети"; fi
	if ip route show table $TABLE | grep -q "default dev $TUN"; then pass "в таблице $TABLE маршрут через $TUN"; else fail "в таблице $TABLE нет маршрута через $TUN"; fi

	echo "3) IPv6 наружу"
	if [ -f "$D/ipv6.block" ]; then
		if [ "$(ip -6 route show | grep -c '^unreachable ')" -ge 2 ]; then pass "выход по IPv6 закрыт маршрутами unreachable, локальный IPv6 не тронут"; else fail "маршрутов, закрывающих IPv6, нет"; fi
	elif [ "$(cat /proc/sys/net/ipv6/conf/$WAN/disable_ipv6)" = 1 ]; then
		pass "IPv6 выключен на $WAN"
	else
		fail "IPv6 не закрыт"
	fi

	echo "4) Внешний IP без прокси — так ходят приложения ТВ"
	ip4=$(curl -sS --max-time 20 https://api.ipify.org 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ] && is_ip "$ip4"; then
		pass "интернет работает, IP: $(mask_ip "$ip4")"
		home=$(cat "$D/home.sha" 2> /dev/null)
		if [ "$home" = "$(sha256sum < /dev/null | cut -c1-64)" ]; then
			warn "домашний IP при запуске не определился — сравнить не с чем"
		elif [ "$(printf '%s' "$ip4" | sha256sum | cut -c1-64)" != "$home" ]; then
			pass "IP отличается от домашнего — трафик идёт через VPN"
		else
			fail "IP совпадает с домашним — трафик идёт мимо VPN"
		fi
	else
		fail "запрос без прокси не прошёл (curl $rc): $(printf '%s' "$ip4" | head -n 1)"
	fi
	sip=$(curl -sS --max-time 20 -x "socks5h://127.0.0.1:$SOCKS_PORT" https://api.ipify.org 2>&1)
	if is_ip "$sip" && [ "$sip" = "$ip4" ]; then pass "тот же IP, что через SOCKS5 этапа 1 — выход один: Quattro"; else warn "IP без прокси и через SOCKS5 различаются или SOCKS5 не ответил"; fi

	echo "5) DNS через туннель"
	svc=$(cat "$D/svc" 2> /dev/null)
	TVIP=$(cat "$D/tvip" 2> /dev/null)
	if connmanctl services "$svc" 2> /dev/null | grep -q "Nameservers.Configuration = \[ $TVIP \]"; then pass "ConnMan спрашивает адреса у Xray ($TVIP:53)"; else fail "ConnMan не переключён на Xray"; fi
	# Уникальное имя: если Xray его искал, значит запрос приложения дошёл до DNS Xray (а не до роутера)
	name="check-$(date +%s)-$$.example.com"
	nslookup "$name" > /dev/null 2>&1
	yt=$(nslookup www.youtube.com 2>&1)
	sleep 1
	if grep -q "$name" "$D/xray.log"; then
		pass "запрос адреса через ConnMan дошёл до DNS Xray (ответ — через Quattro)"
	else
		fail "запрос адреса через ConnMan не дошёл до Xray — адреса сайтов узнаются мимо VPN"
	fi
	if printf '%s\n' "$yt" | sed -n '/^Name:/,$p' | grep -q 'Address'; then pass "www.youtube.com находится через ConnMan — как у приложений"; else fail "www.youtube.com не находится: $(printf '%s' "$yt" | grep -i -E "can't|timed out" | head -n 1)"; fi

	echo "6) Утечка через IPv6"
	v6=$(curl -6 -sS --max-time 8 https://api64.ipify.org 2>&1)
	if [ $? -ne 0 ]; then pass "IPv6-запрос наружу не проходит — мимо VPN не утечёт"; else fail "IPv6-запрос прошёл: $(mask_ip "$v6")"; fi

	echo "7) Скорость: 20 МБ без прокси, как у приложений"
	v=$(curl -sS -o /dev/null --max-time 60 -w '%{size_download} %{speed_download} %{http_code}' 'https://speed.cloudflare.com/__down?bytes=20000000' 2>&1)
	set -- $v
	if [ "$1" = 20000000 ]; then
		pass "скачано 20 МБ: $(awk -v b="$2" 'BEGIN { printf "%.0f", b * 8 / 1000000 }') Мбит/с"
	elif [ "$3" = 429 ]; then
		warn "сервис замера ответил 429 (слишком много замеров с этого адреса VPN) — туннель работает, скорость не измерена"
	else
		fail "20 МБ не скачались: $(printf '%s' "$v" | head -n 1)"
	fi

	echo "8) Журнал Xray"
	if grep -q 'tun-in >> quattro' "$D/xray.log"; then pass "журнал подтверждает маршрут tun-in → quattro"; else fail "в журнале нет «tun-in >> quattro»"; fi
	n=$(grep -c -i -E 'x509|tls: |unrecognized|rpc error|failed to dial|available destination|decode response header|i/o timeout|connection refused|no such host|reset by peer' "$D/xray.log")
	if [ "${n:-0}" -eq 0 ]; then pass "ошибок TLS, gRPC, сети и авторизации нет"; else warn "строк с ошибками: $n — последние:"; grep -i -E 'x509|tls: |unrecognized|rpc error|failed to dial|available destination|decode response header|i/o timeout|connection refused|no such host|reset by peer' "$D/xray.log" | tail -n 3 | cut -c1-300 | sed 's/^/    /'; fi

	echo "9) Мёртвая рука"
	if [ -f "$D/confirmed" ]; then echo "  • подтверждено в $(cat "$D/confirmed"); откат — по tvctl tun-stop или по предельному времени"
	else echo "  • НЕ подтверждено: без tvctl tun-confirm откат выполнится сам"; fi

	echo
	echo "Итог: пройдено $ok, не пройдено $bad"
	if [ "$bad" -eq 0 ]; then echo "ЭТАП 2: ПРОВЕРКА ПРОЙДЕНА"; else echo "ЭТАП 2: ЕСТЬ ОШИБКИ — tvctl tun-stop и отчёт на разбор"; fi
}

main 2>&1 | mask
