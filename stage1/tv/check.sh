#!/bin/sh
# Этап 1, шаг Г: проверка туннеля. Ничего не меняет. Запуск с Mac: tvctl check.
# Внешние IP печатаются только замаскированными и никуда не записываются.

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac

mask() { if [ -s "$D/mask.sed" ]; then sed -f "$D/mask.sed"; else cat; fi; }
listening() { { netstat -ltn; ss -ltn; netstat -an -p tcp; } 2>/dev/null | grep -i listen | grep "[:.]$1[[:space:]]"; }
is_ours() {
	c=$({ tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null) || c=$(ps -o args= -p "$1" 2>/dev/null)
	case "$c" in *"$D/xray"*) return 0 ;; esac
	return 1
}
netsnap() {
	{
		echo "# интерфейсы"; ip -o link show | awk -F': ' '{print $2}'
		echo "# маршруты IPv4"; ip route show table all || ip route show
		echo "# маршруты IPv6"; ip -6 route show table all || ip -6 route show
		echo "# правила"; ip rule show; ip -6 rule show
		echo "# DNS"; cat /etc/resolv.conf
		echo "# пересылка"; cat /proc/sys/net/ipv4/ip_forward
	} 2>/dev/null | sed -e 's/ expires [0-9]*sec//g' -e 's/ linkdown//g'
}
is_ip() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$'; }
mask_ip() { case "$1" in *.*.*.*) printf '%s.*.*.*' "${1%%.*}" ;; *:*) printf '%s:…' "${1%%:*}" ;; esac; }

ok=0
bad=0
pass() { echo "  ✔ $*"; ok=$((ok + 1)); }
fail() { echo "  ✘ $*"; bad=$((bad + 1)); }
warn() { echo "  ⚠ $*"; }

main() {
	[ -s "$D/probe.env" ] || { echo "Стоп: нет $D/probe.env — сначала tvctl push и tvctl start"; return 1; }
	. "$D/probe.env"
	P="127.0.0.1:$SOCKS_PORT"

	echo "1) Процесс Xray"
	pid=$(cat "$D/xray.pid" 2>/dev/null)
	if [ -n "$pid" ] && is_ours "$pid"; then pass "работает, PID $pid"; else fail "не работает — нужен tvctl start"; fi

	echo "2) Локальный SOCKS5"
	L=$(listening "$SOCKS_PORT")
	if printf '%s\n' "$L" | grep -q "127\.0\.0\.1[:.]$SOCKS_PORT[[:space:]]"; then pass "слушает 127.0.0.1:$SOCKS_PORT"; else fail "127.0.0.1:$SOCKS_PORT не слушается"; fi
	if printf '%s\n' "$L" | grep -v "127\.0\.0\.1[:.]" | grep -q .; then fail "порт $SOCKS_PORT открыт не только на 127.0.0.1"; fi

	echo "3) Сервер Quattro напрямую, без Xray: TCP → TLS → HTTP/2 (справочно, на итог не влияет)"
	H2=
	curl --version 2>/dev/null | grep -qi 'http2' && H2=--http2
	r=$(curl -sS -o /dev/null $H2 --connect-timeout 8 --max-time 15 --connect-to "$PROBE_HOST:$PORT:$SERVER_CONNECT:$PORT" \
		-w 'tcp=%{time_connect}s tls=%{time_appconnect}s http=%{http_version} code=%{http_code} verify=%{ssl_verify_result}' \
		"https://$PROBE_HOST:$PORT/" 2>&1)
	rc=$?
	printf '%s\n' "$r" | sed 's/^/    /'
	case "$rc" in
	0)
		warn "TCP и TLS до сервера прошли, curl принял сертификат"
		if [ -z "$H2" ]; then
			warn "curl на ТВ без HTTP/2 — эту часть пропускаю"
		else
			case "$r" in
			*http=2*) warn "сервер выбрал HTTP/2 — для gRPC так и нужно" ;;
			*) warn "сервер не выбрал HTTP/2 — для gRPC это ошибка (сверить SNI и порт с Quattro)" ;;
			esac
		fi
		;;
	6) warn "ТВ не смог разрешить имя сервера (DNS)" ;;
	7 | 28) warn "нет TCP-соединения или таймаут: порт закрыт, сервер недоступен или соединение режут" ;;
	35 | 56) warn "TLS-рукопожатие оборвано — похоже на блокировку по SNI (DPI); фрагментацию на этапе 1 не включаем" ;;
	60)
		if [ "${PINNED:-0}" = 1 ]; then
			warn "curl не принял сертификат — ожидаемо: сервер проверяется по отпечатку (pcs), а curl знает только центры сертификации"
		else
			warn "curl не принял сертификат: сверьте часы ТВ; у curl своя база сертификатов, у Xray встроенная — смотрите шаги 5–7"
		fi
		;;
	*) warn "curl завершился с кодом $rc" ;;
	esac

	echo "4) Внешний IP напрямую, без прокси"
	dip=$(curl -sS --max-time 15 https://api.ipify.org 2>&1)
	drc=$?
	if [ "$drc" -eq 0 ] && is_ip "$dip"; then
		pass "прямой IP: $(mask_ip "$dip")"
	else
		fail "прямой запрос не прошёл (curl $drc): $(printf '%s' "$dip" | head -n 1)"
		dip=
	fi

	echo "5) Внешний IP через SOCKS5 $P (socks5h: DNS тоже через прокси)"
	pip=$(curl -sS --max-time 25 -x "socks5h://$P" https://api.ipify.org 2>&1)
	prc=$?
	if [ "$prc" -eq 0 ] && is_ip "$pip"; then
		pass "запрос через прокси прошёл, IP: $(mask_ip "$pip")"
		if [ -n "$dip" ]; then
			if [ "$pip" != "$dip" ]; then pass "IP через прокси отличается от прямого"; else fail "IP через прокси совпадает с прямым"; fi
		fi
	else
		fail "запрос через прокси не прошёл (curl $prc): $(printf '%s' "$pip" | head -n 1)"
	fi
	pv=$(curl -sS -v --max-time 25 -x "socks5h://$P" -o /dev/null https://api.ipify.org 2>&1)
	if printf '%s\n' "$pv" | grep -qi 'remotely resolved'; then
		pass "имя api.ipify.org разрешил прокси, а не ТВ (DNS через прокси)"
	else
		fail "не видно «remotely resolved» — DNS через прокси не подтверждён"
	fi
	printf '%s\n' "$pv" | grep -i -E 'SOCKS|SSL connection|ALPN|^< HTTP|^curl: ' | head -n 8 | sed 's/^/    /'

	echo "6) Объём: 1 МБ через прокси"
	v=$(curl -sS -o /dev/null --max-time 60 -x "socks5h://$P" -w '%{size_download} %{speed_download}' \
		'https://speed.cloudflare.com/__down?bytes=1048576' 2>&1)
	vrc=$?
	if [ "$vrc" -eq 0 ] && [ "${v%% *}" = 1048576 ]; then pass "скачан 1 МБ, скорость ${v#* } байт/с"; else fail "1 МБ не скачался (curl $vrc): $(printf '%s' "$v" | head -n 1)"; fi

	echo "7) Журнал Xray: последние 40 строк"
	tail -n 40 "$D/xray.log" | sed 's/^/    /'
	if grep -q 'socks-in >> quattro' "$D/xray.log"; then pass "журнал подтверждает маршрут socks-in → quattro"; else fail "в журнале нет строк «socks-in >> quattro»"; fi
	n=$(grep -c -i -E 'x509|tls: |unrecognized|rpc error|failed to dial|available destination|decode response header|i/o timeout|connection refused|no such host|reset by peer' "$D/xray.log")
	if [ "${n:-0}" -eq 0 ]; then pass "в журнале нет ошибок TLS, gRPC, сети и авторизации"; else fail "строк с ошибками в журнале: $n (разбор — RUNBOOK, «Диагностика»)"; fi

	echo "8) Сеть ТВ с момента запуска"
	if [ -s "$D/net.before" ]; then
		netsnap > "$D/net.now"
		if diff "$D/net.before" "$D/net.now" > /dev/null 2>&1; then
			pass "интерфейсы, маршруты, правила и DNS не изменились"
		else
			fail "есть отличия:"
			diff "$D/net.before" "$D/net.now" | head -n 20 | sed 's/^/    /'
		fi
	else
		fail "нет снимка сети до запуска ($D/net.before)"
	fi

	echo
	echo "Итог: пройдено $ok, не пройдено $bad"
	if [ "$bad" -eq 0 ]; then
		echo "ПРОВЕРКА ПРОЙДЕНА. Для приёмки: ещё два раза tvctl check с паузой не меньше минуты, затем tvctl stop."
	else
		echo "ЕСТЬ ОШИБКИ — разбор по RUNBOOK, раздел «Диагностика». Ничего не исправлять наугад."
	fi
}

main 2>&1 | mask
