#!/usr/bin/env bash
# Раздача обновлений EVS со станции: маленький nginx на каталоге с файлами.
#
#     scp deploy-updates.sh user@станция:~
#     ssh user@станция 'bash ~/deploy-updates.sh'
#
# Ставит контейнер и печатает адрес, который вписывается в EVS:
# «О приложении» → «Сервер обновлений». Оттуда пойдут и обновления программы,
# и движок распознавания — по локальной сети вместо интернета.
#
# Сами файлы кладёт publish-to-station.ps1 с машины разработки; этот скрипт
# отвечает только за то, чтобы их было чем отдать.
#
# Опции: --port N (по умолчанию 8099), --down, --logs
set -euo pipefail

PORT=8099
ACTION=up
ROOT="${HOME}/evs-updates"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --down) ACTION=down; shift;;
    --logs) ACTION=logs; shift;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m [x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker не найден"
docker compose version >/dev/null 2>&1 || die "нет плагина docker compose"

mkdir -p "$ROOT/files"
cd "$ROOT"

if [ "$ACTION" = down ]; then
  docker compose -p evs-updates down 2>/dev/null || true
  say "раздача остановлена (файлы в $ROOT/files остались)"
  exit 0
fi
if [ "$ACTION" = logs ]; then
  docker compose -p evs-updates logs --tail 50
  exit 0
fi

cat > compose.yml <<YAML
# Раздача обновлений EVS. Только чтение: каталог примонтирован ro, отдаётся как
# есть. Ничего, кроме статики, тут не нужно — подпись установщика проверяет сам
# WinSparkle, а список компонентов сверяется по sha256 в приложении.
services:
  evs-updates:
    image: nginx:alpine
    container_name: evs-updates
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    volumes:
      - ./files:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
YAML

cat > nginx.conf <<'CONF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;

    # Список файлов — чтобы можно было глазами проверить, что выложено.
    autoindex on;

    # Канал обновлений и список компонентов не кэшируем: они меняются в момент
    # выкладки, и увидеть вчерашний список — ровно то, чего не надо.
    location ~* \.(xml|json)$ {
        add_header Cache-Control "no-store";
    }

    # Установщик и движок именованы по версии и проверяются по контрольной
    # сумме, так что их не грех и подержать.
    location ~* \.(exe|zip)$ {
        add_header Cache-Control "public, max-age=604800";
    }
}
CONF

say "поднимаю раздачу на порту ${PORT}…"
docker compose -p evs-updates up -d
sleep 2

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS=$(tailscale ip -4 2>/dev/null | head -1 || true)
if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/"; then
  say "раздача работает"
else
  die "контейнер поднялся, но не отвечает: docker logs evs-updates"
fi

echo
echo "  Каталог с файлами : $ROOT/files"
echo "  Адрес в локальной сети : http://${IP}:${PORT}"
[ -n "$TS" ] && echo "  Адрес через Tailscale  : http://${TS}:${PORT}"
echo
echo "  Впишите его в EVS: «О приложении» → «Сервер обновлений»."
echo "  Файлы туда кладёт publish-to-station.ps1 с машины разработки."
