#!/usr/bin/env bash
# Разворачивает на сервере распознавание речи для EVS: GigaAM-v3 в контейнере с
# OpenAI-совместимым эндпоинтом. Адрес, который он напечатает в конце, вставляется
# в EVS: «Микрофон и распознавание» → «Распознавание» → «На сервере».
#
# Один файл, копируется на сервер целиком:
#     scp deploy-stt.sh user@192.168.50.50:~
#     ssh user@192.168.50.50 'bash ~/deploy-stt.sh'
#
# Повторный запуск безопасен: обновляет образ и перезапускает контейнер, модель
# и кэш остаются в томе. Ничего, кроме своего проекта compose (evs-stt), не
# трогает — соседние контейнеры (Ollama и прочее) не заденет.
#
# Почему именно GigaAM-v3, а не Whisper: на русском он и точнее, и дешевле —
# ~3.5% WER на чистой записи против ~5-9% у Whisper large-v3, при этом модель
# 225 МБ и работает примерно в 10 раз быстрее реального времени НА ПРОЦЕССОРЕ.
# То есть видеокарта для этого не обязательна; когда она появится, скрипт сам
# переключится на CUDA-образ (проверка ниже).
#
# Опции:
#   --port N        порт на хосте (по умолчанию 9876)
#   --cpu           принудительно CPU-образ, даже если видеокарта найдена
#   --gpu           принудительно CUDA-образ
#   --tag T         тег образа (по умолчанию latest / cuda)
#   --down          остановить и удалить контейнер (том с моделью остаётся)
#   --logs          показать логи и выйти
set -euo pipefail

PORT=9876
FORCE=""
TAG=""
ACTION="up"
PROJECT="evs-stt"
DIR="${HOME}/evs-stt"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --cpu)  FORCE="cpu"; shift;;
    --gpu)  FORCE="gpu"; shift;;
    --tag)  TAG="$2"; shift 2;;
    --down) ACTION="down"; shift;;
    --logs) ACTION="logs"; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m [!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m [x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. Есть ли чем запускать -----------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker не найден. Поставьте Docker и повторите."
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "docker compose не найден (нужен плагин compose v2 или docker-compose)."
fi
docker info >/dev/null 2>&1 || die "docker есть, но демон недоступен. Проверьте: systemctl status docker, и что вы в группе docker."

# ---- 2. Видеокарта: есть ли она и умеет ли docker её отдать ------------------
#
# Мало найти nvidia-smi на хосте: без NVIDIA Container Toolkit контейнер с
# --gpus просто не стартует. Поэтому проверяем не наличие драйвера, а то, что
# docker реально может дать GPU — единственная проверка, которой можно верить.

USE_GPU=0
if [ "$FORCE" = "gpu" ]; then
  USE_GPU=1
elif [ "$FORCE" != "cpu" ]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    say "Видеокарта найдена, проверяю, отдаёт ли её docker…"
    if docker run --rm --gpus all ubuntu:24.04 true >/dev/null 2>&1; then
      USE_GPU=1
    else
      warn "Видеокарта есть, но docker её не отдаёт — нет NVIDIA Container Toolkit."
      warn "Ставится так: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
      warn "Пока разворачиваю на процессоре (для GigaAM этого достаточно)."
    fi
  fi
fi

if [ -z "$TAG" ]; then
  [ "$USE_GPU" = "1" ] && TAG="cuda" || TAG="latest"
fi
IMAGE="ghcr.io/ekhodzitsky/gigastt:${TAG}"

# ---- 3. Файл compose ---------------------------------------------------------
#
# Пишется рядом, а не подставляется в docker run: так конфигурацию видно
# глазами, её можно поправить и перезапустить одной командой.

mkdir -p "$DIR"
COMPOSE="${DIR}/compose.yml"

{
  echo "# Сгенерирован deploy-stt.sh. Правьте свободно — скрипт перезапишет файл"
  echo "# только при следующем запуске, а \`$DC -p $PROJECT up -d\` работает и без него."
  echo "services:"
  echo "  stt:"
  echo "    image: ${IMAGE}"
  echo "    container_name: evs-stt"
  echo "    restart: unless-stopped"
  echo "    ports:"
  echo "      - \"${PORT}:9876\""
  echo "    volumes:"
  echo "      # Модель (~225 МБ после квантизации) скачивается при первом запуске."
  echo "      # Именованный том, а не папка хоста: внутри контейнера свой"
  echo "      # непривилегированный пользователь, и bind-mount упёрся бы в права."
  echo "      - evs-stt-models:/home/gigastt/.gigastt/models"
  echo "    healthcheck:"
  echo "      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:9876/health\"]"
  echo "      interval: 30s"
  echo "      timeout: 5s"
  echo "      retries: 3"
  if [ "$USE_GPU" = "1" ]; then
    echo "    deploy:"
    echo "      resources:"
    echo "        reservations:"
    echo "          devices:"
    echo "            - driver: nvidia"
    echo "              count: all"
    echo "              capabilities: [gpu]"
  fi
  echo "volumes:"
  echo "  evs-stt-models:"
} > "$COMPOSE"

case "$ACTION" in
  down)
    say "Останавливаю…"
    $DC -p "$PROJECT" -f "$COMPOSE" down
    say "Готово. Том evs-stt-models с моделью остался — удалить: docker volume rm ${PROJECT}_evs-stt-models"
    exit 0;;
  logs)
    exec $DC -p "$PROJECT" -f "$COMPOSE" logs -f --tail=200;;
esac

# ---- 4. Поднять ---------------------------------------------------------------

say "Образ: ${IMAGE} ($([ "$USE_GPU" = "1" ] && echo "видеокарта" || echo "процессор"))"
say "Тяну образ (в первый раз это несколько минут)…"
$DC -p "$PROJECT" -f "$COMPOSE" pull
say "Запускаю…"
$DC -p "$PROJECT" -f "$COMPOSE" up -d

# ---- 5. Дождаться готовности --------------------------------------------------
#
# Первый запуск дольше остальных: модель качается с HuggingFace и квантуется.
# Поэтому ждём щедро, но не бесконечно, и при провале показываем логи, а не
# просто «не завелось».

say "Жду готовности (первый запуск качает модель, это до нескольких минут)…"
DEADLINE=$(( $(date +%s) + 900 ))
READY=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    READY=1; break
  fi
  if [ -z "$($DC -p "$PROJECT" -f "$COMPOSE" ps -q stt)" ]; then
    warn "Контейнер не работает. Логи:"
    $DC -p "$PROJECT" -f "$COMPOSE" logs --tail=60 || true
    die "Запуск не удался."
  fi
  sleep 3
done
[ "$READY" = "1" ] || { $DC -p "$PROJECT" -f "$COMPOSE" logs --tail=60 || true; die "Сервер не ответил на /health за 15 минут."; }
say "Сервер отвечает."

# ---- 6. Проверка именно того эндпоинта, которым пользуется EVS -----------------
#
# /health говорит лишь «процесс жив». EVS ходит в /v1/audio/transcriptions
# multipart-ом, и проверять надо это: несовпадение контракта иначе всплывёт
# только на первой произнесённой фразе.

# Кнопка «Проверить» в EVS дёргает GET /v1/models. Ответ 404 её устраивает
# (любой ответ = сервер на месте), но знать, что именно она увидит, полезно
# заранее — иначе «Проверить» покажет непонятное на ровном месте.
MCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/v1/models" || echo 000)
if [ "$MCODE" = "000" ]; then
  warn "GET /v1/models не ответил вовсе — кнопка «Проверить» в EVS скажет, что сервер офлайн."
else
  say "GET /v1/models → HTTP ${MCODE} (кнопке «Проверить» этого достаточно)."
fi

if command -v python3 >/dev/null 2>&1; then
  TMPWAV="$(mktemp --suffix=.wav)"
  python3 - "$TMPWAV" <<'PY'
import math, struct, sys, wave
# Секунда тона: тишину некоторые движки отбрасывают ещё до распознавания, и
# ответ был бы пустым не из-за поломки. Тон гарантирует, что путь пройден весь.
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"".join(
        struct.pack("<h", int(8000 * math.sin(2 * math.pi * 220 * i / 16000)))
        for i in range(16000)))
PY
  say "Проверяю OpenAI-эндпоинт (тот же запрос, что шлёт EVS)…"
  CODE=$(curl -s -o /tmp/evs-stt-probe.json -w '%{http_code}' --max-time 120 \
    -F "file=@${TMPWAV};type=audio/wav" -F "model=gigaam-v3" \
    -F "language=ru" -F "response_format=json" \
    "http://127.0.0.1:${PORT}/v1/audio/transcriptions" || echo 000)
  rm -f "$TMPWAV"
  if [ "$CODE" = "200" ]; then
    say "Эндпоинт отвечает: $(head -c 200 /tmp/evs-stt-probe.json)"
  else
    warn "POST /v1/audio/transcriptions вернул HTTP $CODE:"
    head -c 400 /tmp/evs-stt-probe.json 2>/dev/null || true
    echo
    warn "Сервер запущен, но EVS с ним говорить не сможет — покажите этот вывод."
  fi
  rm -f /tmp/evs-stt-probe.json
else
  warn "python3 нет — пропускаю проверку эндпоинта (сам сервер уже отвечает)."
fi

# ---- 7. Что вставлять в EVS ---------------------------------------------------

IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[ -n "${IP:-}" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "${IP:-}" ] || IP="<ip-сервера>"

echo
say "Готово."
echo
echo "  В EVS: «Микрофон и распознавание» → «Распознавание» → «На сервере»"
echo "     Адрес сервера:  http://${IP}:${PORT}"
echo "     Модель:         gigaam-v3      (это поле сервер игнорирует, но пусть будет осмысленным)"
echo "     Ключ доступа:   пусто          (сервер без авторизации — держите его в локальной сети)"
echo
echo "  Затем «Проверить» и выберите «На сервере»."
echo
echo "  Логи:        bash $0 --logs"
echo "  Остановить:  bash $0 --down"
echo "  Обновить:    bash $0            (повторный запуск подтягивает свежий образ)"
echo
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  warn "Включён ufw. Если EVS не достучится: sudo ufw allow from <подсеть> to any port ${PORT} proto tcp"
fi
warn "Порт ${PORT} открыт на всех интерфейсах и без пароля. Наружу его не выставляйте."
