#!/bin/sh
# Этап 1, шаг А: сведения о ТВ. ТОЛЬКО ЧТЕНИЕ: ничего не создаёт и не меняет, не загружает модули ядра,
# не вызывает iptables и не оставляет процессов. Запуск с Mac: tvctl facts (вывод идёт через фильтр секретов).

sec() { printf '\n===== %s =====\n' "$1"; }
try() { printf '$ %s\n' "$1"; sh -c "$1" 2>&1 | head -n "${2:-40}"; }
elf() {
	# Класс и машина из заголовка ELF: 32 или 64 бита, ARM или AArch64
	b=$(od -An -tx1 -N20 "$1" 2>/dev/null) || b=$(hexdump -n 20 -e '20/1 "%02x " "\n"' "$1" 2>/dev/null)
	set -- $b
	[ "$1$2$3$4" = 7f454c46 ] || { echo "заголовок ELF не прочитан"; return; }
	case "$5" in 01) c=ELF32 ;; 02) c=ELF64 ;; *) c="ELF (класс $5)" ;; esac
	case "${19}${20}" in 2800) m=ARM ;; b700) m=AArch64 ;; 3e00) m=x86-64 ;; 0300) m=x86 ;; *) m="машина ${19}${20}" ;; esac
	echo "$c $m"
}

sec "Кто и когда (для TLS важны точные часы)"
try 'id'
try 'date -u "+%Y-%m-%d %H:%M:%S UTC"'
try 'cat /proc/uptime'

sec "Система"
try 'uname -a'
try 'cat /proc/version'
try 'cat /etc/os-release'
try 'cat /etc/starfish-release'

sec "Архитектура и ABI (по ним выбирается сборка Xray)"
try 'uname -m'
try 'getconf LONG_BIT'
try 'grep -E "^(model name|Processor|CPU architecture|Features|Hardware)" /proc/cpuinfo | sort -u'
try 'grep -c "^processor" /proc/cpuinfo'
for f in /bin/busybox /bin/sh /usr/bin/curl; do
	[ -e "$f" ] || continue
	r=$(readlink -f "$f" 2>/dev/null || echo "$f")
	printf 'ELF %s (%s): %s\n' "$f" "$r" "$(elf "$r")"
done
try 'ls -d /lib/ld-linux* /lib64 2>/dev/null'

sec "Память, место и права /tmp (Xray около 35 МБ, запускается из /tmp)"
try 'grep -E "^(MemTotal|MemFree|MemAvailable)" /proc/meminfo'
try 'df -h /tmp /media/developer 2>/dev/null || df /tmp'
try 'grep -E " (/tmp|/media/developer|/) " /proc/mounts'

sec "TUN — только наличие, ничего не создаём"
try 'ls -l /dev/net/tun'
try 'grep -w tun /proc/misc'
try 'grep -w "^tun" /proc/modules'
try '[ -r /proc/config.gz ] && { zcat /proc/config.gz 2>/dev/null || gzip -dc /proc/config.gz; } | grep -E "CONFIG_TUN[= ]"'
try 'for i in /sys/class/net/*; do [ -e "$i/tun_flags" ] && echo "tun-интерфейс: ${i##*/}"; done; echo "(конец списка)"'

sec "Нужные команды"
try 'for c in sh bash busybox curl wget ip ss netstat nslookup diff tar gzip unzip od hexdump sha256sum nohup setsid timeout kill ps sed awk tr nc openssl iptables ip6tables nft connmanctl luna-send luna-send-pub; do p=$(command -v "$c" 2>/dev/null); printf "%-14s %s\n" "$c" "${p:-нет}"; done' 60
try 'curl --version'
try 'busybox 2>&1 | head -n 1'

sec "Сеть: интерфейсы и адреса"
try 'ip -o link show'
try 'ip -o addr show'

sec "Сеть: маршруты и правила (ищем остатки 0.0.0.0/1, 128.0.0.0/1 и tun0)"
try 'ip route show table all 2>/dev/null || ip route show' 80
try 'ip -6 route show table all 2>/dev/null || ip -6 route show' 60
try 'ip rule show'
try 'ip -6 rule show'

sec "DNS"
try 'ls -l /etc/resolv.conf'
try 'cat /etc/resolv.conf'

sec "ConnMan — только просмотр, имена сетей не выводятся"
try 'connmanctl state'
try 'connmanctl services | awk "{print substr(\$0, 1, 4) \"| \" \$NF}"'
for s in $(connmanctl services 2>/dev/null | awk '{print $NF}' | grep -E '^(wifi|ethernet)_'); do
	printf -- '--- %s\n' "$s"
	connmanctl services "$s" 2>&1 | grep -E '^[[:space:]]*(State|Ethernet|IPv4|IPv4\.Configuration|IPv6|IPv6\.Configuration|Nameservers|Nameservers\.Configuration|Timeservers|Domains\.Configuration|Proxy|Proxy\.Configuration) ='
done

sec "Ядро: пересылка, IPv6, таблицы файрвола (только чтение /proc)"
try 'cat /proc/sys/net/ipv4/ip_forward'
try 'for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do printf "%s=%s\n" "$f" "$(cat "$f")"; done'
try 'cat /proc/net/ip_tables_names /proc/net/ip6_tables_names 2>/dev/null; echo "(конец)"'

sec "Слушающие порты (10808 должен быть свободен)"
try 'netstat -ltn 2>/dev/null || ss -ltn' 60

sec "Остатки прошлых попыток (ProxyTune, WebOS Xray CFG)"
try '(ps w 2>/dev/null || ps) | grep -i -E "xray|v2ray|sing-box|proxytune|tun2socks|hev-socks|clash|mihomo" | grep -v grep; echo "(конец)"'
try 'ls -la /tmp/proxytune_data /tmp/tvvpn /media/developer/temp'
try 'ls -1 /media/developer/apps/usr/palm/applications /media/developer/apps/usr/palm/services'
try 'ls -la /var/lib/webosbrew/init.d'
try 'ip -d link show tun0'

printf '\n===== конец фактов =====\n'
