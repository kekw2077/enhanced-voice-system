#!/usr/bin/env bash
# Синтез голоса CosyVoice на станции, на видеокарте AMD.
#
#     scp -r server/tts user@станция:~/evs-tts
#     ssh user@станция 'bash ~/evs-tts/deploy-tts.sh'
#
# Скрипт собирает образ, скачивает модель, поднимает контейнер и — главное —
# проверяет ТОТ ЖЕ запрос, который шлёт EVS. Если проверка не прошла, значит и
# в программе не заработает, сколько бы контейнер ни говорил «healthy».
#
# Опции: --port N (8760) --cpu (собрать без видеокарты) --down --logs --rebuild
set -uo pipefail

PORT=8760
ACTION=up
FORCE_CPU=0
REBUILD=0
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${HOME}/evs-tts-data"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --cpu) FORCE_CPU=1; shift;;
    --down) ACTION=down; shift;;
    --logs) ACTION=logs; shift;;
    --rebuild) REBUILD=1; shift;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

ok()   { printf '  \033[1;32m[v]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[!]\033[0m %s\n' "$*"; }
say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m [x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker не найден"

if [ "$ACTION" = down ]; then
  docker rm -f evs-tts >/dev/null 2>&1 || true
  say "синтез остановлен (модель в $DATA осталась)"
  exit 0
fi
if [ "$ACTION" = logs ]; then
  docker logs --tail 60 evs-tts
  exit 0
fi

# ---- 1. Видеокарта -----------------------------------------------------------
say "Проверка видеокарты"
GPU_ARGS=""
if [ "$FORCE_CPU" = "1" ]; then
  warn "принудительно на процессоре — синтез будет медленным, только для проверки"
elif [ -e /dev/kfd ] && [ -e /dev/dri ]; then
  ok "/dev/kfd и /dev/dri на месте"
  # Идентификаторы групп — ЧИСЛАМИ с хоста: имена docker резолвит внутри образа,
  # а там групп render/video обычно нет. На этом уже спотыкались: контейнер падал
  # с «unable to find group render».
  GID_RENDER=$(getent group render | cut -d: -f3)
  GID_VIDEO=$(getent group video | cut -d: -f3)
  GRP=""
  [ -n "${GID_RENDER:-}" ] && GRP="$GRP --group-add $GID_RENDER"
  [ -n "${GID_VIDEO:-}" ] && GRP="$GRP --group-add $GID_VIDEO"
  GPU_ARGS="--device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined$GRP"
else
  die "Нет /dev/kfd — видеокарта не установлена или драйвер не поднялся.
  Синтез на процессоре имеет смысл только для проверки: запустите с --cpu.
  Готовность станции показывает server/gpu/check-gpu.sh"
fi

# ---- 2. Место ----------------------------------------------------------------
# Сколько нужно — зависит от того, собрана ли уже общая основа. Пока torch
# качал каждый образ отдельно, требовалось 25 ГБ; теперь основа общая, и синтезу
# остаётся свой небольшой слой плюс модель. Проверять по старому числу значило
# отказываться работать при вполне достаточном месте — так и вышло.
if docker image inspect evs-rocm-base:latest >/dev/null 2>&1; then
  NEED=8
else
  NEED=25
fi
# docker освобождает временные файлы распаковки не мгновенно: сразу после сборки
# основы df показывал 8 ГБ, а через десять секунд — 22. Даём ему договорить.
sync; sleep 5
FREE=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
say "Место на диске: ${FREE} ГБ (нужно ${NEED})"
[ "${FREE:-0}" -lt "$NEED" ] && die "Не хватает места: свободно ${FREE} ГБ, нужно ${NEED}."
ok "хватает"

# ---- 3. Сборка ---------------------------------------------------------------
# Общая основа с torch под ROCm: собирается один раз и используется обоими
# контейнерами. Без неё каждый тянул бы свою копию torch — на станции это
# лишние десять гигабайт.
if ! docker image inspect evs-rocm-base:latest >/dev/null 2>&1; then
  say "Собираю общую основу (torch под ROCm, это долго и один раз)"
  docker build -t evs-rocm-base:latest "$DIR/../rocm-base"     || docker build -t evs-rocm-base:latest "$HOME/evs-rocm-base"     || die "не собралась основа evs-rocm-base"
fi
ok "общая основа на месте"

say "Сборка образа (первый раз — долго, качается torch под ROCm)"
if [ "$REBUILD" = "1" ] || ! docker image inspect evs-tts:latest >/dev/null 2>&1; then
  docker build -t evs-tts:latest "$DIR" || die "образ не собрался"
fi
ok "образ готов"

# ---- 4. Модель ---------------------------------------------------------------
mkdir -p "$DATA"
if [ ! -d "$DATA/CosyVoice2-0.5B" ]; then
  say "Скачиваю модель CosyVoice2-0.5B (~2 ГБ)"
  docker run --rm -v "$DATA:/models" evs-tts:latest python3 -c "
from modelscope import snapshot_download
snapshot_download('iic/CosyVoice2-0.5B', local_dir='/models/CosyVoice2-0.5B')
" || die "модель не скачалась"
fi
ok "модель на месте"

# ---- 5. Запуск ---------------------------------------------------------------
say "Запуск"
docker rm -f evs-tts >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name evs-tts --restart unless-stopped \
  $GPU_ARGS \
  -p "${PORT}:8760" \
  -v "$DATA:/models" \
  -e COSY_MODEL=/models/CosyVoice2-0.5B \
  -e COSY_IDLE_UNLOAD=300 \
  evs-tts:latest >/dev/null || die "контейнер не поднялся"

for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
  || die "сервер не отвечает: docker logs evs-tts"
ok "сервер отвечает"
curl -fsS "http://127.0.0.1:${PORT}/health" | sed 's/^/      /'

# ---- 6. Проверка ТЕМ ЖЕ запросом, что шлёт EVS -------------------------------
# Образцом берём файл из самого CosyVoice, а не синтетический тон. Тон здесь был
# ошибкой: речевых признаков из него не извлечь, и проверка не отличала рабочий
# синтез от сломанного — сервер отвечал, а речи не получалось. У этого файла
# известна расшифровка, и ответ сверяется по длительности.
say "Проверка настоящим запросом синтеза"
REF=/tmp/evs-cosy-ref.wav
docker cp evs-tts:/opt/CosyVoice/asset/zero_shot_prompt.wav "$REF" >/dev/null 2>&1 \
  || die "не достать образец из контейнера"
python3 - "$PORT" "$REF" <<'INNER'
import io, sys, urllib.request, wave
port, ref_path = sys.argv[1], sys.argv[2]
ref = open(ref_path, "rb").read()
CRLF = chr(13) + chr(10)          # без экранирования: так надёжнее в heredoc
b = "----evsCheck"
parts = []
def field(n, v):
    parts.append(("--" + b).encode())
    parts.append(('Content-Disposition: form-data; name="%s"' % n + CRLF).encode())
    parts.append(str(v).encode("utf-8"))
field("tts_text", "收到好友从远方寄来的生日礼物，那份意外的惊喜让我心中充满了甜蜜的快乐。")
field("prompt_text", "希望你以后能够做的比我还好呦。")
field("speed", 1.0)
parts.append(("--" + b).encode())
parts.append(('Content-Disposition: form-data; name="prompt_wav"; filename="ref.wav"' + CRLF + 'Content-Type: audio/wav' + CRLF).encode())
parts.append(ref)
parts.append(("--" + b + "--").encode())
body = CRLF.encode().join(parts) + CRLF.encode()
req = urllib.request.Request(
    "http://127.0.0.1:%s/inference_zero_shot" % port, data=body,
    headers={"Content-Type": "multipart/form-data; boundary=" + b})
try:
    with urllib.request.urlopen(req, timeout=900) as r:
        audio = r.read()
except Exception as e:
    print("  [x] синтез не удался: %s" % e); sys.exit(1)
try:
    with wave.open(io.BytesIO(audio), "rb") as w:
        secs = w.getnframes() / w.getframerate()
        rate = w.getframerate()
except Exception as e:
    print("  [x] ответ не разбирается как WAV: %s" % e); sys.exit(1)
print("  [v] получен WAV: %d байт, %.1f с, %d Гц" % (len(audio), secs, rate))
# Эта фраза звучит около восьми секунд. Втрое дольше — верный признак, что
# модель не проговаривает текст, а бормочет: так и было, пока не выяснилось,
# что transformers стоит не той версии, какую требует CosyVoice.
if not 4.0 <= secs <= 16.0:
    print("  [x] длительность %.1f с не похожа на эту фразу —" % secs)
    print("      синтез отвечает, но говорит не то. Проверьте версии пакетов.")
    sys.exit(1)
INNER
[ $? -eq 0 ] || die "контракт не подтверждён — в EVS это тоже не заработает"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS=$(tailscale ip -4 2>/dev/null | head -1 || true)
say "Готово"
echo "  В EVS: «Голос ассистента» -> адрес сервера клон-голоса:"
echo "    http://${IP}:${PORT}"
[ -n "$TS" ] && echo "    http://${TS}:${PORT}   (через Tailscale)"
echo
echo "  Модель выгружается из видеопамяти после 5 минут простоя —"
echo "  ту же карту делит языковая модель."
