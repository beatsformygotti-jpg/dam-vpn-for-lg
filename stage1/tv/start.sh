#!/bin/sh
# Этап 1, шаг Г: один временный процесс Xray — SOCKS5 на 127.0.0.1 → VLESS + gRPC + TLS (Quattro).
# Ничего не устанавливает: бинарник и конфиг только в $D внутри /tmp. Маршруты, DNS, ConnMan, файрвол,
# sysctl и автозапуск не трогает. Через TTL секунд (по умолчанию 900) Xray останавливается сам.
# Запуск с Mac: tvctl start; вывод проходит через фильтр секретов.

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac
TTL="${TTL:-900}"
case "$TTL" in '' | *[!0-9]*) echo "Стоп: TTL — число секунд"; exit 2 ;; esac

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

main() {
	for f in xray config.json probe.env mask.sed; do
		[ -s "$D/$f" ] || { echo "Стоп: нет $D/$f — сначала tvctl push"; return 1; }
	done
	[ -x "$D/xray" ] || { echo "Стоп: $D/xray не исполняемый"; return 1; }
	. "$D/probe.env"
	old=$(cat "$D/xray.pid" 2>/dev/null)
	if [ -n "$old" ] && is_ours "$old"; then echo "Стоп: Xray этапа 1 уже работает (PID $old) — сначала tvctl stop"; return 1; fi
	if [ -n "$(listening "$SOCKS_PORT")" ]; then echo "Стоп: порт $SOCKS_PORT уже занят"; return 1; fi

	netsnap > "$D/net.before"
	echo "== Версия Xray"
	"$D/xray" version 2>&1 | head -n 1
	echo "== Проверка конфига (xray run -test)"
	"$D/xray" run -test -c "$D/config.json" > "$D/test.log" 2>&1
	rc=$?
	tail -n 20 "$D/test.log"
	if [ "$rc" -ne 0 ]; then echo "Стоп: конфиг не прошёл проверку (код $rc), Xray не запущен"; return 1; fi

	echo "== Запуск"
	nohup "$D/xray" run -c "$D/config.json" < /dev/null > "$D/xray.log" 2>&1 &
	pid=$!
	echo "$pid" > "$D/xray.pid"
	# Сторож: через TTL секунд останавливает именно этот Xray (сверяет командную строку процесса)
	nohup sh -c 'sleep "$1"; p=$(cat "$2/xray.pid" 2>/dev/null) || exit 0; c=$({ tr "\0" " " < "/proc/$p/cmdline"; } 2>/dev/null) || c=$(ps -o args= -p "$p" 2>/dev/null); case "$c" in *"$2/xray"*) kill "$p" ;; esac' \
		tvvpn-watchdog "$TTL" "$D" < /dev/null > /dev/null 2>&1 &
	echo $! > "$D/watchdog.pid"

	i=0
	while [ $i -lt 15 ] && is_ours "$pid" && [ -z "$(listening "$SOCKS_PORT")" ]; do
		sleep 1
		i=$((i + 1))
	done
	if ! is_ours "$pid"; then
		echo "✘ Xray завершился сразу после запуска. Журнал:"
		tail -n 40 "$D/xray.log"
		return 1
	fi
	L=$(listening "$SOCKS_PORT")
	if printf '%s\n' "$L" | grep -q "127\.0\.0\.1[:.]$SOCKS_PORT[[:space:]]"; then
		echo "✔ Xray работает: PID $pid, SOCKS5 на 127.0.0.1:$SOCKS_PORT, автоостановка через $TTL с"
	else
		echo "✘ Xray работает (PID $pid), но 127.0.0.1:$SOCKS_PORT не слушается:"
		printf '%s\n' "$L"
	fi
	echo "== Начало журнала"
	tail -n 15 "$D/xray.log"
}

main 2>&1 | mask
