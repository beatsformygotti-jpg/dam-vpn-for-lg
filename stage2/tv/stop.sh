#!/bin/sh
# Этап 2: откат и уборка. Удаляет правила 8990–9009 и таблицу 100, останавливает Xray (интерфейс damvpn0
# исчезает вместе с ним), возвращает IPv6, сверяет сеть со снимком до запуска и удаляет /tmp/tvvpn.
# Запуск с Mac: tvctl tun-stop. Без Mac — sh /tmp/tvvpn/rollback.sh или перезагрузка ТВ.

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac
TUN=damvpn0
TABLE=100

mask() { if [ -s "$D/mask.sed" ]; then sed -f "$D/mask.sed"; else cat; fi; }
netsnap() {
	{
		echo "# интерфейсы"; ip -o link show | awk -F': ' '{print $2}'
		echo "# маршруты IPv4"; ip -4 route show table all
		echo "# маршруты IPv6 (без адресов самого ТВ)"; ip -6 route show table all | grep -v -E '^(local|anycast) '
		echo "# правила"; ip rule show
		echo "# DNS"; cat /etc/resolv.conf
		echo "# пересылка и IPv6"; cat /proc/sys/net/ipv4/ip_forward; grep -H . /proc/sys/net/ipv6/conf/*/disable_ipv6
	} 2>/dev/null | sed -e 's/ expires [0-9]*sec//g' -e 's/ linkdown//g'
}

if [ ! -d "$D" ]; then
	echo "Папки $D нет — этап 2 не запущен"
	# После отключения питания посреди работы в ConnMan мог остаться DNS = адрес самого ТВ — возвращаем автоматический
	w=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
	ip4=$(ip -4 addr show dev "$w" 2> /dev/null | awk '/inet / {split($2, a, "/"); print a[1]; exit}')
	svc=$(connmanctl services 2> /dev/null | awk '$1 ~ /^\*A/ {print $NF; exit}')
	if [ -n "$ip4" ] && connmanctl services "$svc" 2> /dev/null | grep -q "Nameservers.Configuration = \[ $ip4 \]"; then
		connmanctl config "$svc" --nameservers > /dev/null 2>&1 && echo "✔ DNS ConnMan, оставшийся от VPN, возвращён на автоматический"
	fi
	ip rule show | grep -q -E '^(899[0-9]|900[0-9]):' && echo "✘ но правила 8990–9009 есть — перезагрузите ТВ или удалите их вручную"
	exit 0
fi
WAN=$(cat "$D/wan" 2> /dev/null)
PREV6=$(cat "$D/ipv6.prev" 2> /dev/null)
SVC=$(cat "$D/svc" 2> /dev/null)
NSPREV=$(cat "$D/ns.prev" 2> /dev/null)

main() {
	if [ -x "$D/rollback.sh" ]; then
		sh "$D/rollback.sh" "вручную (tvctl tun-stop)"
		echo "== Журнал отката"
		sed 's/^/    /' "$D/rollback.log"
	else
		echo "• rollback.sh нет — tun-start не доходил до изменений"
	fi
	w=$(cat "$D/watchdog.pid" 2> /dev/null)
	[ -n "$w" ] && case "$({ tr '\0' ' ' < "/proc/$w/cmdline"; } 2> /dev/null)" in *tvvpn-deadman*) kill "$w" 2> /dev/null ;; esac

	# После включения IPv6 роутер не сразу присылает маршрут — ждём до минуты, если он был до запуска
	if [ -f "$D/ipv6.default" ] && [ "$PREV6" = 0 ]; then
		i=0
		while [ $i -lt 60 ] && ! ip -6 route show default | grep -q .; do sleep 2; i=$((i + 2)); done
	fi
	echo "== Журнал Xray: последние 20 строк"
	tail -n 20 "$D/xray.log" 2> /dev/null | sed 's/^/    /'
	echo "== Сеть: до запуска и сейчас"
	if [ -s "$D/net.before" ]; then
		netsnap > "$D/net.now"
		if diff "$D/net.before" "$D/net.now" > /dev/null 2>&1; then
			echo "✔ интерфейсы, маршруты, правила, DNS и настройки IPv6 как до запуска"
		else
			echo "✘ есть отличия:"
			diff "$D/net.before" "$D/net.now" | head -n 30 | sed 's/^/    /'
		fi
	fi
}

main 2>&1 | mask

echo "== Удаление $D: бинарник, конфиги с секретами, журналы"
rm -rf -- "$D"
if [ -e "$D" ]; then echo "✘ папка не удалилась"; else echo "✔ папка удалена"; fi
if ip link show "$TUN" > /dev/null 2>&1; then echo "✘ интерфейс $TUN остался"; else echo "✔ интерфейса $TUN нет"; fi
if ip rule show | grep -q -E '^(899[0-9]|900[0-9]):'; then echo "✘ правила 8990–9009 остались"; else echo "✔ правил 8990–9009 нет"; fi
if grep -q " $(readlink -f /etc/resolv.conf) " /proc/mounts; then echo "✘ resolv.conf подменён"; fi
if [ -n "$SVC" ]; then
	now=$(connmanctl services "$SVC" 2> /dev/null | sed -n 's/^ *Nameservers\.Configuration = \[\(.*\)\]/\1/p' | tr ',' ' ' | tr -s ' ')
	if [ "$(echo $now)" = "$(echo $NSPREV)" ]; then echo "✔ DNS ConnMan как до запуска: [$(echo $NSPREV)]"; else echo "✘ DNS ConnMan не вернулся: сейчас [$(echo $now)], было [$(echo $NSPREV)]"; fi
fi
if ip -6 route show | grep -q -E '^unreachable (::|8000::)/1'; then echo "✘ маршруты unreachable для IPv6 остались"; else echo "✔ IPv6 открыт, как до запуска"; fi
if [ -n "$(ip route show table $TABLE 2> /dev/null)" ]; then echo "✘ таблица $TABLE не пуста"; else echo "✔ таблица $TABLE пуста"; fi
if [ -n "$WAN" ] && [ -n "$PREV6" ]; then
	if [ "$(cat "/proc/sys/net/ipv6/conf/$WAN/disable_ipv6")" = "$PREV6" ]; then echo "✔ IPv6 на $WAN как до запуска"; else echo "✘ IPv6 на $WAN не вернулся"; fi
fi
echo "== Прямой интернет ТВ после отката"
code=$(curl -sS -o /dev/null --max-time 15 -w '%{http_code}' https://api.ipify.org 2>&1)
case "$code" in 200) echo "✔ работает" ;; *) echo "✘ не отвечает: $code" ;; esac
