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
  GPU_ARGS="--device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined --group-add video --group-add render"
else
  die "Нет /dev/kfd — видеокарта не установлена или драйвер не поднялся.
  Синтез на процессоре имеет смысл только для проверки: запустите с --cpu.
  Готовность станции показывает server/gpu/check-gpu.sh"
fi

# ---- 2. Место ----------------------------------------------------------------
FREE=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
say "Место на диске: ${FREE} ГБ"
[ "${FREE:-0}" -lt 25 ] && die "Нужно хотя бы 25 ГБ: образ с torch+ROCm около 12-15, модель ещё 2."
ok "хватает"

# ---- 3. Сборка ---------------------------------------------------------------
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
say "Проверка настоящим запросом синтеза"
python3 - "$PORT" <<'PY'
import io, json, sys, urllib.request, wave, math, struct
port = sys.argv[1]
# Образец голоса: секунда тона. Для проверки контракта годится — важно, что
# сервер принял файл, синтезировал и вернул разборный WAV.
buf = io.BytesIO()
with wave.open(buf, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"".join(struct.pack("<h", int(6000*math.sin(2*math.pi*180*t/16000)))
                           for t in range(16000)))
ref = buf.getvalue()
b = "----evsCheck"
parts = []
def field(n, v):
    parts.append(("--"+b).encode())
    parts.append(('Content-Disposition: form-data; name="%s"\r\n' % n).encode())
    parts.append(str(v).encode())
field("tts_text", "Проверка синтеза на станции.")
field("prompt_text", "проверка")
field("speed", 1.0)
parts.append(("--"+b).encode())
parts.append(b'Content-Disposition: form-data; name="prompt_wav"; filename="ref.wav"\r\nContent-Type: audio/wav\r\n')
parts.append(ref)
parts.append(("--"+b+"--").encode())
body = b"\r\n".join(parts) + b"\r\n"
req = urllib.request.Request(f"http://127.0.0.1:{port}/inference_zero_shot",
                             data=body,
                             headers={"Content-Type": "multipart/form-data; boundary="+b})
try:
    with urllib.request.urlopen(req, timeout=600) as r:
        audio = r.read()
except Exception as e:
    print(f"  [x] синтез не удался: {e}"); sys.exit(1)
try:
    with wave.open(io.BytesIO(audio), "rb") as w:
        secs = w.getnframes() / w.getframerate()
    print(f"  [v] получен WAV: {len(audio)} байт, {secs:.1f} с, {w.getframerate()} Гц")
except Exception as e:
    print(f"  [x] ответ не разбирается как WAV: {e}"); sys.exit(1)
PY
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
