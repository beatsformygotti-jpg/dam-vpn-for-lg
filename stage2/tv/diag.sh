#!/bin/sh
# Этап 2, диагностика DNS при поднятом туннеле. Ничего не меняет: только запросы адресов и чтение счётчиков.
# Отвечает на вопрос, где теряются запросы адресов: в правилах, в ConnMan или на обратном пути из Xray.
# Запуск с Mac: tvctl tun-diag (после tun-start, до tun-stop).

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac
TUN=damvpn0

mask() { if [ -s "$D/mask.sed" ]; then sed -f "$D/mask.sed"; else cat; fi; }
cnt() { cat "/sys/class/net/$TUN/statistics/$1" 2> /dev/null || echo 0; }
dnslog() { n=$(grep -c 'app/dns: .*querying' "$D/xray.log" 2> /dev/null); echo "${n:-0}"; }

# $1 — описание, остальное — команда nslookup
probe() {
	what=$1
	shift
	tx0=$(cnt tx_packets); rx0=$(cnt rx_packets); l0=$(dnslog)
	out=$(timeout 10 "$@" 2>&1)
	rc=$?
	sleep 1
	tx1=$(cnt tx_packets); rx1=$(cnt rx_packets); l1=$(dnslog)
	if printf '%s\n' "$out" | grep -q 'NXDOMAIN'; then res="ответ получен (такого имени нет — так и должно быть)"
	elif [ $rc -eq 0 ] && printf '%s\n' "$out" | sed -n '/^Name:/,$p' | grep -q 'Address'; then res="ответ получен"
	elif [ $rc -eq 124 ] || [ $rc -eq 143 ] || printf '%s\n' "$out" | grep -q -i 'timed out'; then res="таймаут"
	else res="ошибка (код $rc)"; fi
	echo "  $what: $res | в туннель ушло пакетов: $((tx1 - tx0)), пришло из туннеля: $((rx1 - rx0)), запросов DNS Xray: +$((l1 - l0))"
	printf '%s\n' "$out" | grep -i -E "can't|timed out|server can|NXDOMAIN|refused" | head -n 2 | sed 's/^/      /'
}

main() {
	[ -s "$D/wan" ] && ip link show "$TUN" > /dev/null 2>&1 || { echo "Стоп: туннель не поднят — сначала tvctl tun-start"; return 1; }
	WAN=$(cat "$D/wan")
	GW=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')
	n=$(date +%s)

	echo "0) IPv6 на $WAN: disable_ipv6=$(cat /proc/sys/net/ipv6/conf/$WAN/disable_ipv6), маршрут IPv6 по умолчанию: $(ip -6 route show default | grep -c .) шт."
	echo "1) Куда ядро отправит DNS-запрос к роутеру $GW"
	echo "  обычный сокет:          $(ip route get "$GW" ipproto udp dport 53 2>&1 | head -n 1)"
	echo "  сокет, привязанный к $WAN: $(ip route get "$GW" ipproto udp dport 53 oif "$WAN" 2>&1 | head -n 1)"

	echo "2) Запросы адресов (уникальные имена, чтобы не брать из кэша)"
	probe "напрямую к роутеру, мимо ConnMan" nslookup "d1-$n.example.com" "$GW"
	probe "напрямую к роутеру, youtube" nslookup www.youtube.com "$GW"
	probe "через ConnMan (127.0.0.1)" nslookup "d2-$n.example.com" 127.0.0.1
	probe "как у приложений (resolv.conf)" nslookup "d3-$n.example.com"
	probe "как у приложений, youtube" nslookup www.youtube.com

	echo "3) Защита от подмены адреса (rp_filter: 0 — выкл, 1 — строгая, 2 — мягкая)"
	for i in all default "$WAN" "$TUN"; do
		printf '  %-8s %s\n' "$i" "$(cat "/proc/sys/net/ipv4/conf/$i/rp_filter" 2> /dev/null || echo нет)"
	done

	echo "4) Сокеты ConnMan (откуда он спрашивает роутер)"
	netstat -anup 2> /dev/null | grep -i -E 'connman|:53 ' | head -n 12 | sed 's/^/  /'

	echo "5) DNS-серверы ConnMan сейчас"
	svc=$(connmanctl services 2> /dev/null | awk '$1 ~ /^\*A/ {print $NF; exit}')
	connmanctl services "$svc" 2> /dev/null | grep -E '^ *(State|Nameservers|IPv6) =' | sed 's/^/  /'
	echo "  resolv.conf: $(grep -v '^#' /etc/resolv.conf | tr '\n' ' ')"

	echo "6) Журнал Xray: строки про DNS"
	grep -i -E 'dns|:53 ' "$D/xray.log" | tail -n 12 | cut -c1-260 | sed 's/^/  /'
}

main 2>&1 | mask
