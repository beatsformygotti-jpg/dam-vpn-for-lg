#!/bin/sh
# Этап 2: откуда приложение YouTube берёт адреса. ТОЛЬКО ЧТЕНИЕ, без туннеля.
# 1) что отвечают роутер, ConnMan и 1.1.1.1 на www.youtube.com; 2) в какой среде живёт приложение YouTube
# и какой resolv.conf оно видит; 3) есть ли в ядре NAT (для возможного перенаправления DNS).
# Запуск с Mac: tvctl dns-facts. Приложение YouTube должно быть открыто (можно на экране ошибки).

sec() { printf '\n===== %s =====\n' "$1"; }
ask() { # $1 — описание, $2 — сервер
	out=$(timeout 10 nslookup www.youtube.com "$2" 2>&1)
	if printf '%s\n' "$out" | grep -q NXDOMAIN; then r="NXDOMAIN — «такого адреса нет»"
	elif printf '%s\n' "$out" | sed -n '/^Name:/,$p' | grep -q Address; then r="адреса есть ($(printf '%s\n' "$out" | sed -n '/^Name:/,$p' | grep -c Address) шт.)"
	else r="нет ответа: $(printf '%s' "$out" | grep -i -E "timed out|can't" | head -n 1)"; fi
	echo "  $1: $r"
}

sec "Туннель сейчас"
if ip link show damvpn0 > /dev/null 2>&1; then echo "  damvpn0 есть — проверка ниже будет искажена, сначала tvctl tun-stop"; else echo "  туннеля нет — так и нужно"; fi

sec "Кто отвечает на www.youtube.com (без VPN)"
GW=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')
ask "роутер $GW" "$GW"
ask "ConnMan 127.0.0.1" 127.0.0.1
ask "ConnMan ::1" ::1
ask "Cloudflare 1.1.1.1 напрямую" 1.1.1.1
ask "Google 8.8.8.8 напрямую" 8.8.8.8

sec "Приложение YouTube"
found=0
for p in /proc/[0-9]*; do
	c=$({ tr '\0' ' ' < "$p/cmdline"; } 2> /dev/null)
	case "$c" in *[Yy]ou[Tt]ube* | *cobalt* | *Cobalt*)
		found=1
		pid=${p#/proc/}
		echo "  PID $pid: $(printf '%s' "$c" | cut -c1-120)"
		[ "$(readlink "$p/ns/mnt")" = "$(readlink /proc/1/ns/mnt)" ] && echo "    файловая среда: общая с системой" || echo "    файловая среда: своя (изолированное приложение)"
		echo "    resolv.conf, который видит приложение: $(grep -v '^#' "$p/root/etc/resolv.conf" 2> /dev/null | tr '\n' ' ')"
		grep -i resolv "$p/mountinfo" 2> /dev/null | awk '{print "    монтирование: " $4 " → " $5}' | head -n 3
		;;
	esac
done
[ $found = 1 ] || echo "  процесс YouTube не найден — откройте приложение и повторите"

sec "NAT в ядре (для перенаправления DNS, если понадобится)"
[ -r /proc/config.gz ] && { zcat /proc/config.gz 2> /dev/null || gzip -dc /proc/config.gz; } |
	grep -E '^CONFIG_(NF_NAT|IP_NF_NAT|IP_NF_IPTABLES|IP_NF_TARGET_REDIRECT|NETFILTER_XT_TARGET_REDIRECT|NF_NAT_REDIRECT|NETFILTER_XT_NAT)=' | sed 's/^/  /'
grep -E '^(nf_nat|iptable_nat|xt_REDIRECT|xt_nat|ip_tables)' /proc/modules | awk '{print "  загружен модуль: " $1}'
ls /lib/modules/"$(uname -r)"/kernel/net/ipv4/netfilter 2> /dev/null | grep -E 'nat|ip_tables' | sed 's/^/  файл модуля: /'
echo "  (конец)"
