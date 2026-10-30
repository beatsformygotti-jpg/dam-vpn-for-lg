#!/bin/sh
# Автозапуск D.A.M VPN при включении ТВ (Homebrew Channel, /var/lib/webosbrew/init.d). Включается в настройках приложения.
APP=/media/developer/apps/usr/palm/applications/com.damstudio.vpn
[ -x /usr/bin/node ] && [ -f "$APP/service/damvpnd.js" ] && sh "$APP/service/run.sh" --autoconnect
