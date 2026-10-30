#!/bin/sh
# Запуск фоновой части D.A.M VPN (root). Повторный запуск ничего не делает. $1 = --autoconnect при старте ТВ.
SVC=$(cd "$(dirname "$0")" && pwd)
if netstat -ltn 2>/dev/null | grep -q '127.0.0.1:8098 '; then echo "уже работает"; exit 0; fi
nohup /usr/bin/node "$SVC/damvpnd.js" "$@" < /dev/null > /tmp/damvpnd.log 2>&1 &
echo "запущено"
