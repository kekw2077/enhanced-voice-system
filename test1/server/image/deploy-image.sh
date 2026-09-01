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
#     ~/evs-image-data/<любое-имя>.safetensors
#
# Опции: --port N (8770) --model-url URL --model-name ИМЯ --down --logs --rebuild
set -uo pipefail

PORT=8770
ACTION=up
REBUILD=0
MODEL_URL=""
MODEL_NAME=""
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${HOME}/evs-image-data"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --model-url) MODEL_URL="$2"; shift 2;;
    --model-name) MODEL_NAME="$2"; shift 2;;
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

# Идентификаторы групп — ЧИСЛАМИ с хоста: имена docker резолвит внутри образа,
# а там групп render/video обычно нет. На этом уже спотыкались: контейнер падал
# с «unable to find group render».
GID_RENDER=$(getent group render | cut -d: -f3)
GID_VIDEO=$(getent group video | cut -d: -f3)
GRP=""
[ -n "${GID_RENDER:-}" ] && GRP="$GRP --group-add $GID_RENDER"
[ -n "${GID_VIDEO:-}" ] && GRP="$GRP --group-add $GID_VIDEO"


# Требование зависит от того, собрана ли общая основа: с ней остаётся свой
# небольшой слой плюс чекпоинт на семь гигабайт, без неё — ещё и torch.
if docker image inspect evs-rocm-base:latest >/dev/null 2>&1; then
  NEED=12
else
  NEED=25
fi
sync; sleep 5
say "Место на диске"
FREE=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
[ "${FREE:-0}" -lt "$NEED" ] && die "Не хватает места: свободно ${FREE} ГБ, нужно ${NEED}."
ok "свободно ${FREE} ГБ"

say "Чекпоинт"
mkdir -p "$DATA" "$DATA/miopen"
# Моделей в каталоге может быть несколько — приложение показывает список и
# переключает их на ходу, оно же скачивает и удаляет через сам сервер.
# Скрипт лишь следит, чтобы хотя бы одна была: пустой каталог значит, что
# генерировать нечем, и проверка настоящей генерацией всё равно провалится.
if [ -z "$MODEL_NAME" ] && [ -n "$MODEL_URL" ]; then
  MODEL_NAME=$(basename "${MODEL_URL%%\?*}")
fi
case "$MODEL_NAME" in *.safetensors|*.ckpt) :;; *) MODEL_NAME="";; esac
[ -z "$MODEL_NAME" ] && MODEL_NAME=checkpoint.safetensors
HAVE=$(ls -S "$DATA"/*.safetensors "$DATA"/*.ckpt 2>/dev/null | head -1)
if [ -z "$HAVE" ]; then
  CKPT="$DATA/$MODEL_NAME"
  if [ -n "$MODEL_URL" ]; then
    say "качаю чекпоинт (несколько гигабайт)"
    curl -fL --progress-bar -o "$CKPT.part" "$MODEL_URL" \
      || die "не скачалось: проверьте ссылку (для Civitai нужен токен в URL)"
    mv "$CKPT.part" "$CKPT"
    HAVE="$CKPT"
  else
    die "В $DATA нет ни одного чекпоинта и не задан --model-url.
  Положите файл модели туда, либо передайте прямую ссылку:
    bash $0 --model-url 'https://...' --model-name имя.safetensors
  Для Civitai ссылка выглядит как .../api/download/models/<id>?token=<ваш токен>"
  fi
fi
COUNT=$(ls "$DATA"/*.safetensors "$DATA"/*.ckpt 2>/dev/null | wc -l)
SIZE=$(du -h "$HAVE" | cut -f1)
ok "чекпоинтов в каталоге: $COUNT, по умолчанию $(basename "$HAVE") ($SIZE)"

# Определитель лиц для второго прохода — шесть мегабайт, качается один раз.
# Без него проход просто не делается: отказывать в кадре из-за этого нельзя.
if [ ! -f "$DATA/face_yolov8n.pt" ]; then
  curl -fsL -o "$DATA/face_yolov8n.pt.part" \
    'https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8n.pt' \
    && mv "$DATA/face_yolov8n.pt.part" "$DATA/face_yolov8n.pt" \
    || warn "определитель лиц не скачался — второй проход будет пропускаться"
fi
[ -f "$DATA/face_yolov8n.pt" ] && ok "определитель лиц на месте"

# Общая основа с torch под ROCm: собирается один раз и используется обоими
# контейнерами. Без неё каждый тянул бы свою копию torch — на станции это
# лишние десять гигабайт.
if ! docker image inspect evs-rocm-base:latest >/dev/null 2>&1; then
  say "Собираю общую основу (torch под ROCm, это долго и один раз)"
  docker build -t evs-rocm-base:latest "$DIR/../rocm-base"     || docker build -t evs-rocm-base:latest "$HOME/evs-rocm-base"     || die "не собралась основа evs-rocm-base"
fi
ok "общая основа на месте"

say "Сборка образа"
if [ "$REBUILD" = "1" ] || ! docker image inspect evs-image:latest >/dev/null 2>&1; then
  docker build -t evs-image:latest "$DIR" || die "образ не собрался"
fi
ok "образ готов"

# expandable_segments — против раздробленности видеопамяти. Без него после
# нескольких кадров PyTorch держит 13 ГБ, из которых 5 «зарезервировано и
# не используется», и следующая же генерация падает с HIP out of memory,
# хотя модель занимает всего семь. Совет из текста самой ошибки.
# Две переменные намеренно: под ROCm читается HIP-вариант, но сборки
# по-прежнему понимают и CUDA-имя, а какая именно сработает — зависит от
# версии torch.
# MIOPEN_FIND_MODE=FAST и том под скомпилированные ядра — то же лекарство,
# что понадобилось синтезу на этой карте. Без него ROCm ищет алгоритм
# свёртки перебором на каждом новом размере кадра, а результат перебора
# теряется при пересоздании контейнера.
# Адрес хоста со стороны контейнера. Нужен, чтобы сервер САМ просил соседей
# отдать видеопамять перед загрузкой весов. Раньше это делало только
# приложение при открытии студии — и этого хватало ровно до первого запроса
# к Ollama, который возвращал языковую модель обратно уже НАВСЕГДА
# (на станции OLLAMA_KEEP_ALIVE=-1). Клиент не знает, когда сосед проснулся;
# сервер знает точно — память нужна ему прямо сейчас.
GW=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
GW=${GW:-172.17.0.1}

# Общая сеть с сервером синтеза. Через адрес шлюза он НЕ отвечает, хотя
# порт опубликован: оба контейнера сидят на одном мосту, и ответ приходит
# с адреса контейнера, а не шлюза — соединение просто виснет до таймаута.
# С Ollama этого не видно, она в другой подсети, поэтому обращение к ней
# остаётся через шлюз. Своя сеть даёт ещё и имя вместо адреса: адрес
# контейнера меняется при каждом пересоздании, имя — нет.
docker network inspect evs-gpu >/dev/null 2>&1 || docker network create evs-gpu >/dev/null 2>&1 || true
TTS_HOST="${GW}:8760"
if docker inspect evs-qwen >/dev/null 2>&1; then
  docker network connect evs-gpu evs-qwen >/dev/null 2>&1 || true
  TTS_HOST="evs-qwen:8760"
fi

say "Запуск"
docker rm -f evs-image >/dev/null 2>&1 || true
docker run -d --name evs-image --restart unless-stopped \
  --device=/dev/kfd --device=/dev/dri \
  --security-opt seccomp=unconfined $GRP \
  -p "${PORT}:8770" \
  -v "$DATA:/models" \
  -v "$DATA/miopen:/root/.cache/miopen" \
  -e MIOPEN_FIND_MODE=FAST \
  -e PYTORCH_HIP_ALLOC_CONF=expandable_segments:True \
  -e PYTORCH_ALLOC_CONF=expandable_segments:True \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e MIOPEN_FIND_ENFORCE=NONE \
  -e IMG_MODELS_DIR=/models \
  -e "IMG_MODEL=/models/$(basename "$HAVE")" \
  -e "IMG_FREE_OLLAMA=http://${GW}:11434" \
  -e "IMG_FREE_TTS=http://${TTS_HOST}" \
  -e IMG_IDLE_UNLOAD=600 \
  evs-image:latest >/dev/null || die "контейнер не поднялся"
docker network connect evs-gpu evs-image >/dev/null 2>&1 || true

for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
  || die "сервер не отвечает: docker logs evs-image"
ok "сервер отвечает"
curl -fsS "http://127.0.0.1:${PORT}/health" | sed 's/^/      /'

# Перед проверкой освобождаем карту от языковой модели. Иначе чекпоинт туда
# просто не помещается: Gemma держит восемь гигабайт «навсегда», картинкам нужно
# ещё семь, а на карте шестнадцать. Это не теория — на этом станция и легла:
# средняя загрузка ушла за двести, а контейнер генерации убило прямо на загрузке
# модели. В приложении тем же занимается арбитр видеокарты; скрипт обязан вести
# себя так же, иначе он проверяет не то, что будет на самом деле.
OLLAMA_URL=${OLLAMA_URL:-http://127.0.0.1:11434}
LOADED=$(curl -fsS -m 10 "$OLLAMA_URL/api/ps" 2>/dev/null   | grep -o '"model":"[^"]*"' | cut -d'"' -f4 | sort -u)
for m in $LOADED; do
  say "освобождаю карту: выгружаю $m"
  curl -fsS -m 60 "$OLLAMA_URL/api/generate" -H 'Content-Type: application/json'     -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null 2>&1 || true
done
[ -n "$LOADED" ] && sleep 3
# Синтез голоса тоже держит видеопамять — около пяти гигабайт. Без его выгрузки
# картинкам остаётся мало, и генерация падает на декодировании кадра. В самом
# приложении этим занимается арбитр видеокарты; здесь надо руками.
TTS_URL=${TTS_URL:-http://127.0.0.1:8760}
if curl -fsS -m 5 "$TTS_URL/health" >/dev/null 2>&1; then
  say "освобождаю карту: выгружаю синтез голоса"
  curl -fsS -m 30 -X POST "$TTS_URL/unload" >/dev/null 2>&1 || true
  sleep 2
fi
VRAM=$(cat /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1)
[ -n "$VRAM" ] && ok "видеопамять занята: $((VRAM / 1024 / 1024)) МБ"

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

# Возвращаем всё как было: карту — языковой модели, иначе следующая же команда
# голосом будет ждать её загрузки, а человек решит, что помощник завис.
# ИМЕННО POST: сервер принимает выгрузку только так, а curl без -X шлёт GET
# и получает 404. С флагом -f это молчаливый отказ: выгрузка «проходила»,
# модель оставалась на карте, и вернувшаяся языковая модель уже не
# помещалась целиком — сползала на процессор и работала вдвое медленнее.
curl -fsS -m 30 -X POST "http://127.0.0.1:${PORT}/unload" >/dev/null 2>&1 || true
sleep 2
if curl -fsS -m 5 "$TTS_URL/health" >/dev/null 2>&1; then
  say "возвращаю синтез голоса"
  curl -fsS -m 10 -X POST "$TTS_URL/load" >/dev/null 2>&1 || true
fi
for m in $LOADED; do
  say "возвращаю языковую модель: $m"
  curl -fsS -m 180 "$OLLAMA_URL/api/generate" -H 'Content-Type: application/json'     -d "{\"model\":\"$m\",\"prompt\":\"привет\",\"stream\":false}"     >/dev/null 2>&1 || true
done

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS=$(tailscale ip -4 2>/dev/null | head -1 || true)
say "Готово"
echo "  В EVS: Настройки -> Нейросеть -> Подключение -> Сервер изображений:"
echo "    http://${IP}:${PORT}"
[ -n "$TS" ] && echo "    http://${TS}:${PORT}   (через Tailscale)"
echo
echo "  Модель отдаёт видеопамять после 10 минут простоя."
