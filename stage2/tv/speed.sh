#!/bin/sh
# Замер скорости на ТВ: напрямую или через временный Xray (SOCKS5 127.0.0.1:10808). Сеть ТВ не меняет:
# Xray и конфиг лежат в /tmp/tvvpn-speed, MODE=clean их удаляет. Печатает только цифры. Запуск с Mac: tvctl speedtest.

D=/tmp/tvvpn-speed
URL='https://speed.cloudflare.com/__down?bytes=20000000'
mbit() { awk -v b="$1" 'BEGIN { printf "%.1f", b * 8 / 1000000 }'; }
one() { curl -s -o /dev/null --max-time 30 -w '%{speed_download} %{size_download} %{http_code}' "$@" "$URL"; echo " $?"; }
# «скорость размер http код_curl» → «172.4» или «сбой (curl 56, HTTP 000, получено 0 байт)»
show() { set -- $1; if [ "$4" = 0 ] && [ "$2" = 20000000 ]; then mbit "$1"; else echo "сбой (curl $4, HTTP $3, получено $2 байт)"; fi; }
RUNS="${RUNS:-3}"
ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2> /dev/null || echo 0; }

case "${MODE:-direct}" in
direct)
	res=""
	i=0
	while [ $i -lt 2 ]; do res="$res $(show "$(one)");"; i=$((i + 1)); done
	echo "напрямую, без VPN, Мбит/с:$res"
	;;
proxy)
	[ -x "$D/xray" ] && [ -s "$D/config.json" ] || { echo "нет $D/xray или конфига"; exit 1; }
	if netstat -ltn 2> /dev/null | grep -q ':10808 '; then echo "порт 10808 занят — сначала tvctl stop или tun-stop"; exit 1; fi
	nohup "$D/xray" run -c "$D/config.json" < /dev/null > "$D/log" 2>&1 &
	pid=$!
	i=0
	while [ $i -lt 20 ] && ! netstat -ltn 2> /dev/null | grep -q '127.0.0.1:10808 '; do sleep 1; i=$((i + 1)); done
	t0=$(ticks $pid)
	s0=$(date +%s)
	res=""
	bad=0
	i=0
	while [ $i -lt "$RUNS" ]; do
		r=$(show "$(one -x socks5h://127.0.0.1:10808)")
		case "$r" in сбой*) bad=1 ;; esac
		res="$res $r;"
		i=$((i + 1))
	done
	t1=$(ticks $pid)
	s1=$(date +%s)
	# тики процессора в секунду ≈ процент одного ядра (USER_HZ = 100)
	cpu=$(awk -v t=$((t1 - t0)) -v s=$((s1 - s0)) 'BEGIN { if (s > 0) printf "%.0f", t / s; else print "?" }')
	kill $pid 2> /dev/null
	sleep 1
	kill -9 $pid 2> /dev/null
	echo "$LABEL, Мбит/с:$res Xray занимал ≈$cpu% одного ядра"
	if [ "$bad" = 1 ]; then
		echo "    журнал Xray у сбоя:"
		grep -i -E 'failed|error|closed|reset|timeout|rejected|EOF' "$D/log" | grep -v 'deprecated' | tail -n 6 | cut -c1-260 | sed 's/^/      /'
	fi
	;;
clean)
	rm -rf "$D"
	echo "папка $D удалена"
	;;
esac
