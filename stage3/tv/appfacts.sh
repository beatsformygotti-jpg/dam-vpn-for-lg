#!/bin/sh
# Этап 3: на чём строить программу. ТОЛЬКО ЧТЕНИЕ.
echo "== Node.js"; for n in /usr/bin/node /usr/bin/nodejs $(command -v node 2>/dev/null); do [ -x "$n" ] && echo "$n: $($n -v 2>&1)"; done
echo "== busybox: httpd, nc"; busybox --list 2>/dev/null | grep -E '^(httpd|nc|ncat)$'
echo "== Homebrew Channel"; H=/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service; ls "$H" 2>&1 | head -20
grep -o '"[a-zA-Z]*"' "$H/services.json" 2>/dev/null | head -5; grep -l -E 'exec' "$H"/*.js 2>/dev/null | head -3
echo "== root-сервис Homebrew Channel"; ls -l /var/luna-service2-dev/services.d 2>/dev/null | grep -i hbchannel | head -3
echo "== init.d"; ls -la /var/lib/webosbrew/init.d 2>&1
echo "== порт 8090 и 1080x"; netstat -ltn 2>/dev/null | grep -E ':(8090|8091|10808) '
echo "== экран"; luna-send -n 1 -f luna://com.webos.service.tv.systemproperty/getSystemInfo '{"keys":["UHD","modelName","sdkVersion"]}' 2>&1 | grep -E 'UHD|modelName|sdkVersion'
