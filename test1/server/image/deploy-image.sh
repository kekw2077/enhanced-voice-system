#!/usr/bin/env bash
# Генерация картинок на станции, на видеокарте AMD.
#
#     scp -r server/image user@станция:~/evs-image
#     ssh user@станция 'bash ~/evs-image/deploy-image.sh --model-url <ссылка>'
#
# Как и синтез, скрипт сначала убеждается, что карта на месте, и только потом
# что-то делает. Заканчивается НАСТОЯЩЕЙ генерацией: если картинка не получилась,
# в приложении она тоже не получится, сколько бы контейнер ни рапортовал.
#
# Про чекпоинт. Скачать его автоматически нельзя: WAI Illustrious раздаётся с
# Civitai, а там для загрузки нужен личный токен. Поэтому либо дайте прямую
# ссылку через --model-url, либо положите файл сами:
#     ~/evs-image-data/checkpoint.safetensors
#
# Опции: --port N (8770) --model-url URL --down --logs --rebuild
set -uo pipefail

PORT=8770
ACTION=up
REBUILD=0
MODEL_URL=""
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${HOME}/evs-image-data"
CKPT="$DATA/checkpoint.safetensors"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --model-url) MODEL_URL="$2"; shift 2;;
    --down) ACTION=down; shift;;
    --logs) ACTION=logs; shift;;
    --rebuild) REBUILD=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

ok()   { printf '  \033[1;32m[v]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[!]\033[0m %s\n' "$*"; }
say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m [x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker не найден"

if [ "$ACTION" = down ]; then
  docker rm -f evs-image >/dev/null 2>&1 || true
  say "генерация остановлена (чекпоинт в $DATA остался)"
  exit 0
fi
if [ "$ACTION" = logs ]; then
  docker logs --tail 60 evs-image
  exit 0
fi

say "Проверка видеокарты"
[ -e /dev/kfd ] && [ -e /dev/dri ] || die "Нет /dev/kfd — карта не установлена
  или драйвер не поднялся. Готовность показывает server/gpu/check-gpu.sh
  Генерация на процессоре бессмысленна: кадр считался бы минутами."
ok "/dev/kfd и /dev/dri на месте"

say "Место на диске"
FREE=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
[ "${FREE:-0}" -lt 20 ] && die "Нужно хотя бы 20 ГБ: образ и чекпоинт на семь."
ok "свободно ${FREE} ГБ"

say "Чекпоинт"
mkdir -p "$DATA"
if [ ! -f "$CKPT" ]; then
  if [ -n "$MODEL_URL" ]; then
    say "качаю чекпоинт (несколько гигабайт)"
    curl -fL --progress-bar -o "$CKPT.part" "$MODEL_URL" \
      || die "не скачалось: проверьте ссылку (для Civitai нужен токен в URL)"
    mv "$CKPT.part" "$CKPT"
  else
    die "Нет $CKPT и не задан --model-url.
  Положите файл модели сюда, либо передайте прямую ссылку:
    bash $0 --model-url 'https://...'
  Для Civitai ссылка выглядит как .../api/download/models/<id>?token=<ваш токен>"
  fi
fi
SIZE=$(du -h "$CKPT" | cut -f1)
ok "чекпоинт на месте ($SIZE)"

say "Сборка образа"
if [ "$REBUILD" = "1" ] || ! docker image inspect evs-image:latest >/dev/null 2>&1; then
  docker build -t evs-image:latest "$DIR" || die "образ не собрался"
fi
ok "образ готов"

say "Запуск"
docker rm -f evs-image >/dev/null 2>&1 || true
docker run -d --name evs-image --restart unless-stopped \
  --device=/dev/kfd --device=/dev/dri \
  --security-opt seccomp=unconfined --group-add video --group-add render \
  -p "${PORT}:8770" \
  -v "$DATA:/models" \
  -e IMG_MODEL=/models/checkpoint.safetensors \
  -e IMG_IDLE_UNLOAD=600 \
  evs-image:latest >/dev/null || die "контейнер не поднялся"

for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
  || die "сервер не отвечает: docker logs evs-image"
ok "сервер отвечает"
curl -fsS "http://127.0.0.1:${PORT}/health" | sed 's/^/      /'

say "Проверка настоящей генерацией (первый кадр долгий — грузится модель)"
TMP=$(mktemp /tmp/evs-img-XXXX.png)
HTTP=$(curl -s -o "$TMP" -w '%{http_code}' --max-time 900 \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"1girl, silver hair, red eyes, city, night, masterpiece","steps":20,"width":768,"height":768}' \
  "http://127.0.0.1:${PORT}/generate")
if [ "$HTTP" != "200" ]; then
  head -c 400 "$TMP"; echo
  die "генерация не удалась (HTTP $HTTP) — docker logs evs-image"
fi
# Проверяем, что это действительно PNG, а не JSON с ошибкой под видом картинки.
if ! head -c 8 "$TMP" | grep -q 'PNG'; then
  die "ответ не PNG — смотрите docker logs evs-image"
fi
ok "картинка получена: $(du -h "$TMP" | cut -f1)"
rm -f "$TMP"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS=$(tailscale ip -4 2>/dev/null | head -1 || true)
say "Готово"
echo "  В EVS: Настройки -> Нейросеть -> Подключение -> Сервер изображений:"
echo "    http://${IP}:${PORT}"
[ -n "$TS" ] && echo "    http://${TS}:${PORT}   (через Tailscale)"
echo
echo "  Модель отдаёт видеопамять после 10 минут простоя."
