#!/bin/sh
# Этап 1, шаг Г: остановить Xray и удалить всё, что этап положил на ТВ (только $D внутри /tmp).
# Запуск с Mac: tvctl stop. Если Mac недоступен — перезагрузка ТВ тоже всё убирает (папка в /tmp).

D="${TVVPN_DIR:-/tmp/tvvpn}"
case "$D" in
*..* | *' '*) echo "Стоп: недопустимый путь $D"; exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "Стоп: рабочая папка должна быть внутри /tmp, а не $D"; exit 2 ;;
esac

mask() { if [ -s "$D/mask.sed" ]; then sed -f "$D/mask.sed"; else cat; fi; }
listening() { { netstat -ltn; ss -ltn; netstat -an -p tcp; } 2>/dev/null | grep -i listen | grep "[:.]$1[[:space:]]"; }
cmdline() { { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null || ps -o args= -p "$1" 2>/dev/null; }
is_ours() { case "$(cmdline "$1")" in *"$D/xray"*) return 0 ;; esac; return 1; }
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
	# Если работал этап 2 — сначала его откат (правила, таблица 100, IPv6)
	[ -x "$D/rollback.sh" ] && sh "$D/rollback.sh" "через stop этапа 1" && echo "✔ откат этапа 2 выполнен"
	pid=$(cat "$D/xray.pid" 2>/dev/null)
	if [ -n "$pid" ] && is_ours "$pid"; then
		kill "$pid" 2>/dev/null
		i=0
		while is_ours "$pid" && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
		is_ours "$pid" && { kill -9 "$pid" 2>/dev/null; sleep 1; }
		if is_ours "$pid"; then echo "✘ Xray (PID $pid) не остановился"; else echo "✔ Xray остановлен"; fi
	else
		echo "• Xray этапа 1 уже не работал"
	fi
	w=$(cat "$D/watchdog.pid" 2>/dev/null)
	if [ -n "$w" ]; then case "$(cmdline "$w")" in *tvvpn-watchdog*) kill "$w" 2>/dev/null ;; esac; fi

	echo "== Журнал Xray: последние 30 строк"
	tail -n 30 "$D/xray.log" 2>/dev/null | sed 's/^/    /'

	echo "== Сеть: до запуска и сейчас"
	if [ -s "$D/net.before" ]; then
		netsnap > "$D/net.now"
		if diff "$D/net.before" "$D/net.now" > /dev/null 2>&1; then
			echo "✔ интерфейсы, маршруты, правила и DNS как до запуска"
		else
			echo "✘ есть отличия:"
			diff "$D/net.before" "$D/net.now" | head -n 20 | sed 's/^/    /'
		fi
	else
		echo "• снимка сети до запуска нет (start не выполнялся)"
	fi
}

if [ ! -d "$D" ]; then
	echo "Папки $D нет — удалять нечего"
	if (ps w 2>/dev/null || ps) | grep -v grep | grep -q "$D/xray"; then echo "✘ но процесс $D/xray найден — проверьте вручную"; fi
	exit 0
fi
SOCKS_PORT=10808
[ -s "$D/probe.env" ] && . "$D/probe.env"
main 2>&1 | mask

# Удаление — после фильтра: в папке лежит и сам фильтр
echo "== Удаление $D: бинарник, конфиг с секретами, журнал"
rm -rf -- "$D"
if [ -e "$D" ]; then echo "✘ папка не удалилась"; else echo "✔ папка удалена"; fi
if [ -n "$(listening "$SOCKS_PORT")" ]; then echo "✘ порт $SOCKS_PORT всё ещё слушается"; else echo "✔ порт $SOCKS_PORT закрыт"; fi
echo "== Прямой интернет ТВ после остановки"
code=$(curl -sS -o /dev/null --max-time 15 -w '%{http_code}' https://api.ipify.org 2>&1)
case "$code" in 200) echo "✔ работает" ;; *) echo "✘ не отвечает: $code" ;; esac
