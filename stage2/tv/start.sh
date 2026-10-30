#!/bin/sh
# Этап 2: весь трафик ТВ через Xray (TUN). Все изменения временные — до отката или перезагрузки:
# интерфейс damvpn0 (создаёт Xray), таблица маршрутов 100, правила с номерами 8991–9004, два маршрута unreachable
# для IPv6 и DNS ConnMan → Xray на адресе ТВ (роутер отвечает NXDOMAIN на www.youtube.com, а ConnMan спрашивает его
# с сокета, привязанного к Wi-Fi, мимо туннеля — dns-facts 30.10). DNS ConnMan — единственная настройка, которая
# сохраняется в ConnMan: откат возвращает её; после отключения питания её возвращает tvctl tun-stop.
# Не трогает: iptables, основную таблицу маршрутов IPv4, resolv.conf, остальные файлы, автозапуск.
# «Мёртвая рука»: без tvctl tun-confirm за DEADMAN секунд — откат сам; через MAXTTL — откат в любом случае.
# Запуск с Mac: tvctl tun-start; вывод проходит через фильтр секретов.

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac
IPV6_BLOCK="${IPV6_BLOCK:-1}" # 1 — закрыть выход в интернет по IPv6 маршрутами unreachable
IPV6_OFF="${IPV6_OFF:-0}"     # 1 — вместо этого выключить IPv6 на WAN (сбивает маршруты ConnMan до перезагрузки)
DNS_VIA="${DNS_VIA:-1}"        # 0 — не переключать DNS ConnMan на Xray
LAN_DIRECT="${LAN_DIRECT:-1}"  # 0 — и локальная сеть через VPN
DEADMAN="${DEADMAN:-300}"
MAXTTL="${MAXTTL:-3600}"
case "$DEADMAN$MAXTTL" in '' | *[!0-9]*) echo "Стоп: DEADMAN и MAXTTL — числа секунд"; exit 2 ;; esac
[ "$MAXTTL" -gt "$DEADMAN" ] || { echo "Стоп: MAXTTL должен быть больше DEADMAN"; exit 2; }
TUN=damvpn0
TABLE=100

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
		echo "# маршруты IPv4"; ip -4 route show table all
		echo "# маршруты IPv6 (без адресов самого ТВ)"; ip -6 route show table all | grep -v -E '^(local|anycast) '
		echo "# правила"; ip rule show
		echo "# DNS"; cat /etc/resolv.conf
		echo "# пересылка и IPv6"; cat /proc/sys/net/ipv4/ip_forward; grep -H . /proc/sys/net/ipv6/conf/*/disable_ipv6
	} 2>/dev/null | sed -e 's/ expires [0-9]*sec//g' -e 's/ linkdown//g'
}
home_hash() { curl -s --max-time 15 https://api.ipify.org | sha256sum | cut -c1-64; }

write_rollback() {
	cat > "$D/rollback.sh" << 'EOF'
#!/bin/sh
# Откат этапа 2. Можно запускать сколько угодно раз: удаляет только своё.
D=$(cd "$(dirname "$0")" && pwd)
echo "$(date -u '+%H:%M:%S UTC') откат: ${1:-вручную}" >> "$D/rollback.log"
if [ -f "$D/ns.changed" ] && [ -s "$D/svc" ]; then
	connmanctl config "$(cat "$D/svc")" --nameservers $(cat "$D/ns.prev" 2> /dev/null) > /dev/null 2>&1
	rm -f "$D/ns.changed"
fi
t=$(cat "$D/resolv.target" 2> /dev/null)
if [ -n "$t" ]; then
	i=0
	while grep -q " $t " /proc/mounts && [ $i -lt 5 ]; do umount "$t" 2> /dev/null || umount -l "$t" 2> /dev/null; i=$((i + 1)); done
fi
if [ -f "$D/ipv6.block" ]; then
	ip -6 route del unreachable ::/1 2> /dev/null
	ip -6 route del unreachable 8000::/1 2> /dev/null
fi
p=8990
while [ $p -le 9009 ]; do
	while ip rule del pref $p 2> /dev/null; do :; done
	p=$((p + 1))
done
ip route flush table 100 2> /dev/null
pid=$(cat "$D/xray.pid" 2> /dev/null)
if [ -n "$pid" ]; then
	case "$({ tr '\0' ' ' < "/proc/$pid/cmdline"; } 2> /dev/null)" in
	*"$D/xray"*)
		kill "$pid" 2> /dev/null
		i=0
		while [ -d "/proc/$pid" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
		[ -d "/proc/$pid" ] && kill -9 "$pid" 2> /dev/null
		;;
	esac
fi
if [ -s "$D/ipv6.prev" ] && [ -s "$D/wan" ]; then
	cat "$D/ipv6.prev" > "/proc/sys/net/ipv6/conf/$(cat "$D/wan")/disable_ipv6"
fi
date -u '+%H:%M:%S UTC' > "$D/rolled_back"
EOF
	chmod 700 "$D/rollback.sh"
}

fail() { echo "✘ $*"; return 1; }
undo() { echo "✘ $* — выполняю откат"; sh "$D/rollback.sh" "ошибка при запуске: $*"; return 1; }

main() {
	for f in xray config-tun.json probe.env mask.sed; do
		[ -s "$D/$f" ] || { fail "нет $D/$f — сначала tvctl tun-config и tvctl push"; return 1; }
	done
	. "$D/probe.env"
	old=$(cat "$D/xray.pid" 2> /dev/null)
	if [ -n "$old" ] && is_ours "$old"; then fail "Xray уже работает (PID $old) — сначала tvctl tun-stop"; return 1; fi
	if ip link show "$TUN" > /dev/null 2>&1; then fail "интерфейс $TUN уже есть"; return 1; fi
	if [ -n "$(ip route show table $TABLE 2> /dev/null)" ]; then fail "таблица маршрутов $TABLE не пуста"; return 1; fi
	if ip rule show | grep -q -E '^(899[0-9]|900[0-9]):'; then fail "правила 8990–9009 уже заняты"; return 1; fi
	if [ -n "$(listening "$SOCKS_PORT")" ]; then fail "порт $SOCKS_PORT занят"; return 1; fi

	WAN=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
	GW=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')
	LAN=$(ip -4 route show dev "$WAN" scope link proto kernel | awk '{print $1; exit}')
	TVIP=$(ip -4 addr show dev "$WAN" | awk '/inet / {split($2, a, "/"); print a[1]; exit}')
	[ -n "$WAN" ] && [ -n "$GW" ] && [ -n "$LAN" ] && [ -n "$TVIP" ] || { fail "не определить сеть: WAN=$WAN GW=$GW LAN=$LAN TV=$TVIP"; return 1; }
	grep -q "\"listen\": \"$TVIP\"" "$D/config-tun.json" || { fail "адрес ТВ сейчас $TVIP, а конфиг собран для другого — tvctl tun-config --tv-ip $TVIP и push"; return 1; }
	grep -q "\"autoOutboundsInterface\": \"$WAN\"" "$D/config-tun.json" || { fail "маршрут по умолчанию через $WAN, а конфиг собран для другого интерфейса"; return 1; }
	svc=$(connmanctl services 2> /dev/null | awk '$1 ~ /^\*A/ {print $NF; exit}')
	DNS4=$(connmanctl services "$svc" 2> /dev/null | sed -n 's/^ *Nameservers = \[ \(.*\) \]/\1/p' | tr ',' '\n' | tr -d ' ' |
		grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 2)
	[ -n "$DNS4" ] || DNS4=$GW
	DPORT=0
	ip rule help 2>&1 | grep -q dport && DPORT=1
	echo "== Сеть: WAN $WAN, локальная сеть $LAN, шлюз $GW, DNS роутера: $(echo $DNS4)"
	[ "$DPORT" = 1 ] && echo "   ip rule понимает dport — DNS пойдёт в туннель" || echo "⚠ ip rule не понимает dport — DNS пойдёт мимо туннеля"

	home_hash > "$D/home.sha"
	netsnap > "$D/net.before"
	echo "$WAN" > "$D/wan"
	echo "$TVIP" > "$D/tvip"
	echo "$svc" > "$D/svc"
	connmanctl services "$svc" 2> /dev/null | sed -n 's/^ *Nameservers\.Configuration = \[\(.*\)\]/\1/p' | tr ',' ' ' | tr -s ' ' > "$D/ns.prev"
	cat "/proc/sys/net/ipv6/conf/$WAN/disable_ipv6" > "$D/ipv6.prev"
	if ip -6 route show default | grep -q .; then echo 1 > "$D/ipv6.default"; else rm -f "$D/ipv6.default"; fi
	write_rollback
	session=$(date +%s)$$
	echo "$session" > "$D/session"
	rm -f "$D/confirmed" "$D/rolled_back"

	echo "== Проверка конфига (xray run -test)"
	"$D/xray" run -test -c "$D/config-tun.json" > "$D/test.log" 2>&1
	rc=$?
	tail -n 5 "$D/test.log"
	[ "$rc" -eq 0 ] || { fail "конфиг не прошёл проверку (код $rc), ничего не менял"; return 1; }

	echo "== Запуск Xray с TUN"
	nohup "$D/xray" run -c "$D/config-tun.json" < /dev/null > "$D/xray.log" 2>&1 &
	pid=$!
	echo "$pid" > "$D/xray.pid"
	i=0
	while [ $i -lt 15 ] && is_ours "$pid" && ! ip link show "$TUN" > /dev/null 2>&1; do sleep 1; i=$((i + 1)); done
	is_ours "$pid" || { tail -n 30 "$D/xray.log"; undo "Xray завершился сразу после запуска"; return 1; }
	ip link show "$TUN" > /dev/null 2>&1 || { undo "Xray не создал $TUN"; return 1; }
	echo "✔ Xray работает (PID $pid), интерфейс $TUN создан"

	echo "== Маршруты и правила"
	ip route add default dev "$TUN" table $TABLE || { undo "не добавился маршрут в таблицу $TABLE"; return 1; }
	if [ "$DPORT" = 1 ]; then
		n=0
		for dns in $DNS4; do
			ip rule add pref $((8991 + n)) to "$dns/32" ipproto udp dport 53 lookup $TABLE &&
				ip rule add pref $((8993 + n)) to "$dns/32" ipproto tcp dport 53 lookup $TABLE || { undo "не добавилось правило DNS"; return 1; }
			n=$((n + 1))
		done
	fi
	{ [ "$LAN_DIRECT" = 0 ] || ip rule add pref 9000 to "$LAN" lookup main; } &&
		ip rule add pref 9001 to "$SERVER/32" lookup main &&
		ip rule add pref 9002 to 224.0.0.0/4 lookup main &&
		ip rule add pref 9003 to 169.254.0.0/16 lookup main &&
		ip rule add pref 9004 lookup $TABLE || { undo "не добавились правила маршрутизации"; return 1; }
	# Адреса, которые должны открываться мимо VPN (сервер D.A.M для подписки с телефона, сервер подписки): 8995–8998
	n=0
	for ip in $DIRECT_IPS; do
		[ $n -ge 4 ] && break
		ip rule add pref $((8995 + n)) to "$ip/32" lookup main || { undo "не добавилось правило для $ip"; return 1; }
		n=$((n + 1))
	done
	if [ "$IPV6_BLOCK" = 1 ]; then
		echo 1 > "$D/ipv6.block"
		ip -6 route add unreachable ::/1 && ip -6 route add unreachable 8000::/1 || { undo "не добавились маршруты, закрывающие IPv6"; return 1; }
		echo "✔ выход в интернет по IPv6 закрыт (unreachable ::/1 и 8000::/1), локальная сеть по IPv6 работает"
	fi
	if [ "$IPV6_OFF" = 1 ]; then
		echo 1 > "/proc/sys/net/ipv6/conf/$WAN/disable_ipv6" || { undo "не выключился IPv6 на $WAN"; return 1; }
	fi
	if [ "$DNS_VIA" = 1 ]; then
		# DNS приложений: ConnMan на время работы спрашивает Xray на адресе ТВ (сокет ConnMan привязан к Wi-Fi —
		# адрес самого ТВ ему доступен), Xray отвечает через Quattro. Откат возвращает прежнюю настройку ConnMan.
		i=0
		while [ $i -lt 10 ] && ! netstat -lun 2> /dev/null | grep -q " $TVIP:53 "; do sleep 1; i=$((i + 1)); done
		netstat -lun 2> /dev/null | grep -q " $TVIP:53 " || { undo "Xray не слушает $TVIP:53"; return 1; }
		echo 1 > "$D/ns.changed"
		connmanctl config "$svc" --nameservers "$TVIP" > /dev/null 2>&1 || { undo "ConnMan не принял DNS $TVIP"; return 1; }
		sleep 1
		connmanctl services "$svc" | grep -q "Nameservers.Configuration = \[ $TVIP \]" || { undo "ConnMan не переключился на DNS $TVIP"; return 1; }
		echo "✔ ConnMan спрашивает адреса у Xray ($TVIP:53), ответы идут через Quattro"
	fi
	ip rule show | grep -E '^(899[0-9]|900[0-9]):'
	ip route show table $TABLE

	# «Мёртвая рука»: откат, если нет подтверждения; затем откат по предельному времени. Сверяет номер сессии.
	nohup sh -c 's() { [ "$(cat "$3/session" 2> /dev/null)" = "$4" ]; }
		sleep "$1"; s "$@" && [ ! -f "$3/confirmed" ] && sh "$3/rollback.sh" "мёртвая рука: нет подтверждения за $1 с"
		sleep "$2"; s "$@" && sh "$3/rollback.sh" "предельное время работы"' \
		tvvpn-deadman "$DEADMAN" "$((MAXTTL - DEADMAN))" "$D" "$session" < /dev/null > /dev/null 2>&1 &
	echo $! > "$D/watchdog.pid"

	echo "== Первая проверка: внешний IP без прокси, как у приложений ТВ"
	now=$(home_hash)
	if [ "$now" = "$(sha256sum < /dev/null | cut -c1-64)" ]; then undo "интернет через туннель не отвечает"; return 1; fi
	if [ "$now" = "$(cat "$D/home.sha")" ]; then undo "IP не изменился — трафик идёт мимо туннеля"; return 1; fi
	echo "✔ трафик ТВ идёт через VPN (IP отличается от домашнего)"
	echo
	echo "Подтвердите в течение $DEADMAN с: tvctl tun-confirm — иначе откат выполнится сам."
	echo "Предельное время работы: $MAXTTL с. Остановить раньше: tvctl tun-stop."
}

main 2>&1 | mask
