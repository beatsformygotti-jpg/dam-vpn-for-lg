#!/bin/bash
# Скачивает Xray закреплённой версии и сверяет SHA-256 архива со значением, записанным здесь.
# Сборка для ТВ выбирается только по отчёту tvctl facts (RUNBOOK, шаг Б). macos-arm64-v8a — только для selftest.
set -euo pipefail

VERSION=v26.10.29
build="${1:-}"
case "$build" in
linux-arm64-v8a) want=afe01f19045b05237420328028ee1ee2e1edd2100eb41a8cbbf50e683b0a6e58 ;;
linux-arm32-v7a) want=263fa7325c63b3a7f7316405f561e7c790b44c1461992ea648007f0374e9bdf4 ;;
linux-arm32-v6) want=7c2f4ececc528eb4115a990f326a070a7e9a1712b8be6969ef5dc8f59543895d ;;
linux-arm32-v5) want=64f0ecccca9e26e0a37812a07ea3018d4e9c1c420de49afe4d36a6f84a71e6ad ;;
macos-arm64-v8a) want=57755127d38c0c4357e667761c78b257cf617f05015bad5060bf2dae75fcd00b ;;
*)
	echo "Укажите сборку: linux-arm64-v8a | linux-arm32-v7a | linux-arm32-v6 | linux-arm32-v5 | macos-arm64-v8a" >&2
	exit 2
	;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$ROOT/vendor/$build"
if [ -x "$out/xray" ] && [ "$(cat "$out/SHA256-zip" 2>/dev/null)" = "$want" ]; then
	echo "Уже есть: $out/xray (Xray $VERSION, архив сверен ранее)"
	exit 0
fi

mkdir -p "$ROOT/vendor"
dl="$(mktemp -d "$ROOT/vendor/.download.XXXXXX")"
trap 'rm -rf "$dl"' EXIT
zip="Xray-$build.zip"
url="https://github.com/XTLS/Xray-core/releases/download/$VERSION/$zip"
if ! { command -v gh > /dev/null && gh release download "$VERSION" -R XTLS/Xray-core -p "$zip" -D "$dl" 2> /dev/null; }; then
	# без gh — напрямую; если мешает VPN на Mac, то мимо него через en0
	curl -fsSL --retry 2 -o "$dl/$zip" "$url" || curl -fsSL --retry 2 --interface en0 -o "$dl/$zip" "$url"
fi

got=$(shasum -a 256 "$dl/$zip" | awk '{print $1}')
if [ "$got" != "$want" ]; then
	echo "SHA-256 архива не совпал: ожидался $want, получен $got. Файл удалён." >&2
	exit 1
fi
unzip -o -q "$dl/$zip" xray -d "$dl/unpacked"
mkdir -p "$out"
mv -f "$dl/unpacked/xray" "$out/xray"
chmod 755 "$out/xray"
echo "$want" > "$out/SHA256-zip"
shasum -a 256 "$out/xray" | awk '{print $1}' > "$out/SHA256-xray"

echo "Готово: $out/xray — Xray $VERSION, $build"
echo "  SHA-256 архива сверен: $want"
echo "  SHA-256 бинарника: $(cat "$out/SHA256-xray")"
file "$out/xray" 2> /dev/null | sed 's/^[^:]*: /  Тип: /'
