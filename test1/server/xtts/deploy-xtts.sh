#!/usr/bin/env bash
# Клон голоса XTTS-v2 на станции, на видеокарте AMD.
#
#     scp -r server/xtts user@станция:~/evs-xtts
#     scp sidecar/xtts_server.py user@станция:~/evs-xtts/
#     ssh user@станция 'bash ~/evs-xtts/deploy-xtts.sh --ref /путь/к/образцу.wav'
#
# Заканчивается НАСТОЯЩЕЙ проверкой: синтезирует русскую фразу и прогоняет её
# через распознавание, которое уже работает на этой же станции. Совпало —
# значит заработает и в Anima. Это не педантизм: с CosyVoice сервер отвечал,
# отдавал WAV правильной длины и рапортовал «healthy», а речи в нём не было.
#
# Опции: --port N (8762) --ref ФАЙЛ --idle СЕК --down --logs --rebuild
set -uo pipefail

PORT=8762
ACTION=up
REBUILD=0
# Через сколько секунд простоя отдавать видеопамять. Столько же, сколько у
# соседа: карта на станции одна, и держать её за тишину незачем.
IDLE="${EVS_XTTS_IDLE:-900}"
REF=""
STT_URL="${STT_URL:-http://127.0.0.1:9876}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${HOME}/evs-xtts-data"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --idle) IDLE="$2"; shift 2;;
    --ref) REF="$2"; shift 2;;
    --down) ACTION=down; shift;;
    --logs) ACTION=logs; shift;;
    --rebuild) REBUILD=1; shift;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

ok()   { printf '  \033[1;32m[v]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[!]\033[0m %s\n' "$*"; }
say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m [x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker не найден"

if [ "$ACTION" = down ]; then
  docker rm -f evs-xtts >/dev/null 2>&1 || true
  say "синтез остановлен (веса в $DATA остались)"
  exit 0
fi
if [ "$ACTION" = logs ]; then
  docker logs --tail 60 evs-xtts
  exit 0
fi

say "Проверка видеокарты"
[ -e /dev/kfd ] && [ -e /dev/dri ] || die "Нет /dev/kfd — карта не установлена
  или драйвер не поднялся. Готовность показывает server/gpu/check-gpu.sh"
ok "/dev/kfd и /dev/dri на месте"
# Идентификаторы групп числами: имена docker резолвит внутри образа, а там групп
# render/video нет — контейнер падал с «unable to find group render».
GID_RENDER=$(getent group render | cut -d: -f3)
GID_VIDEO=$(getent group video | cut -d: -f3)
GRP=""
[ -n "${GID_RENDER:-}" ] && GRP="$GRP --group-add $GID_RENDER"
[ -n "${GID_VIDEO:-}" ] && GRP="$GRP --group-add $GID_VIDEO"

sync; sleep 3
FREE=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
say "Место на диске: ${FREE} ГБ"
[ "${FREE:-0}" -lt 8 ] && die "Нужно хотя бы 8 ГБ: свой слой образа и веса на два."
ok "хватает"

say "Общая основа"
docker image inspect evs-rocm-base:latest >/dev/null 2>&1 \
  || die "нет evs-rocm-base — соберите её: docker build -t evs-rocm-base:latest server/rocm-base"
ok "на месте"

say "Сборка образа"
[ -f "$DIR/xtts_server.py" ] || die "рядом нет xtts_server.py — скопируйте его из sidecar/"
if [ "$REBUILD" = "1" ] || ! docker image inspect evs-xtts:latest >/dev/null 2>&1; then
  docker build -t evs-xtts:latest "$DIR" || die "образ не собрался"
fi
ok "образ готов"

# MIOPEN_FIND_MODE=FAST — не искать лучший алгоритм свёртки перебором на каждой
# новой длине фразы. У синтеза длина ответа каждый раз своя, и перебор съедал у
# соседа по 13-15 секунд почти на каждой реплике при 5 секундах на самом
# синтезе. Том под скомпилированные ядра — по той же причине: без него работа
# пропадает при пересоздании контейнера.
say "Запуск"
mkdir -p "$DATA" "$DATA/miopen"
docker rm -f evs-xtts >/dev/null 2>&1 || true
# shellcheck disable=SC2086
# Потолок памяти — не перестраховка, а замер: без него процесс дорос до 7,75 ГБ
# хостовой памяти на станции с пятнадцатью, и языковой модели не осталось места
# — её llama-server не поднимался за пять минут, а чат отвечал «сервер
# недоступен». Шесть гигабайт с запасом перекрывают рабочие два-три; если снова
# полезет вверх, умрёт он один и вернётся сам (--restart), а не утащит соседей.
docker run -d --name evs-xtts --restart unless-stopped \
  --memory=6g --memory-swap=6g \
  --device=/dev/kfd --device=/dev/dri \
  --security-opt seccomp=unconfined $GRP \
  -p "${PORT}:8762" \
  -v "$DATA:/models" \
  -v "$DATA/miopen:/root/.cache/miopen" \
  -e XTTS_IDLE="$IDLE" \
  -e MIOPEN_FIND_MODE=FAST \
  -e MIOPEN_FIND_ENFORCE=NONE \
  evs-xtts:latest >/dev/null || die "контейнер не поднялся"
# Общая сеть с генератором картинок: он просит выгрузить голос перед тем, как
# занять карту, а через адрес шлюза этот контейнер не отвечает — оба на одном
# мосту, ответ приходит не с того адреса, и запрос виснет.
docker network inspect evs-gpu >/dev/null 2>&1 || docker network create evs-gpu >/dev/null 2>&1 || true
docker network connect evs-gpu evs-xtts >/dev/null 2>&1 || true

for i in $(seq 1 90); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
  || die "сервер не отвечает: docker logs evs-xtts"
ok "сервер отвечает"
curl -fsS "http://127.0.0.1:${PORT}/" | sed 's/^/      /'

# ---- Есть ли куда грузиться --------------------------------------------------
# Та же защита, что и у соседнего голоса, и по той же причине: проверка ходит к
# серверу напрямую, мимо арбитра, и на занятой карте валится с HIP out of
# memory — а станция следом уходит вытеснять видеопамять в подкачку и перестаёт
# отвечать до кнопки. Проверено на живой станции, повторять незачем.
have_vram_mb() {
  local total used
  total=$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -1)
  used=$(cat /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1)
  [ -n "$total" ] && [ -n "$used" ] || return 1
  echo $(( (total - used) / 1024 / 1024 ))
}

say "Запас на карте"
FREE_VRAM=$(have_vram_mb) || FREE_VRAM=""
NEED_VRAM=4000
if [ -z "$FREE_VRAM" ]; then
  warn "занятость карты не читается — проверяю как есть"
elif [ "$FREE_VRAM" -lt "$NEED_VRAM" ]; then
  warn "свободно ${FREE_VRAM} МБ, нужно ${NEED_VRAM} — карту держат соседи"
  warn "(языковая модель, генератор картинок, студийный голос)"
  say "Сервер развёрнут и отвечает, но проверку синтезом пропускаю"
  echo "  Освободите карту и повторите: bash $0 --ref \"$REF\""
  exit 0
else
  ok "свободно ${FREE_VRAM} МБ — хватает"
fi

# ---- Проверка настоящей русской фразой ---------------------------------------
say "Проверка настоящим синтезом и распознаванием"
if [ -z "$REF" ]; then
  for cand in "$HOME/samples/ru-RU-DmitryNeural.mp3" "$HOME/samples/ru-RU-SvetlanaNeural.mp3"; do
    [ -f "$cand" ] && REF="$cand" && break
  done
fi
[ -n "$REF" ] && [ -f "$REF" ] || die "Нет образца голоса для проверки.
  Укажите его: bash $0 --ref /путь/к/образцу.wav
  Годится любая запись речи от шести секунд."
ok "образец: $(basename "$REF")"

REFWAV=/tmp/evs-xtts-ref.wav
docker cp "$REF" evs-xtts:/tmp/ref-src >/dev/null 2>&1 \
  && docker exec evs-xtts ffmpeg -y -loglevel error -i /tmp/ref-src -t 10 -ar 24000 -ac 1 /tmp/ref.wav \
  && docker cp evs-xtts:/tmp/ref.wav "$REFWAV" >/dev/null 2>&1 \
  || die "не удалось подготовить образец"

python3 - "$PORT" "$REFWAV" "$STT_URL" <<'INNER'
import io, json, sys, time, urllib.request, wave, uuid
port, ref_path, stt = sys.argv[1], sys.argv[2], sys.argv[3]
CRLF = chr(13) + chr(10)
FRAZA = "Проверка синтеза речи на станции."

def multipart(fields, files):
    b = "----evs" + uuid.uuid4().hex[:8]
    parts = []
    for n, v in fields.items():
        parts.append(("--" + b).encode())
        parts.append(("Content-Disposition: form-data; name=" + chr(34) + n + chr(34) + CRLF).encode())
        parts.append(str(v).encode("utf-8"))
    for n, (fn, data, ct) in files.items():
        parts.append(("--" + b).encode())
        parts.append(("Content-Disposition: form-data; name=" + chr(34) + n + chr(34) +
                      "; filename=" + chr(34) + fn + chr(34) + CRLF +
                      "Content-Type: " + ct + CRLF).encode())
        parts.append(data)
    parts.append(("--" + b + "--").encode())
    return CRLF.encode().join(parts) + CRLF.encode(), b

ref = open(ref_path, "rb").read()
body, b = multipart({"tts_text": FRAZA, "prompt_text": "", "speed": 1.0,
                     "language": "Russian"},
                    {"prompt_wav": ("ref.wav", ref, "audio/wav")})
req = urllib.request.Request("http://127.0.0.1:%s/inference_zero_shot" % port, data=body,
                             headers={"Content-Type": "multipart/form-data; boundary=" + b})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=1800) as r:
        audio = r.read()
except Exception as e:
    print("  [x] синтез не удался: %s" % e); sys.exit(1)
took = time.time() - t0
try:
    with wave.open(io.BytesIO(audio), "rb") as w:
        secs = w.getnframes() / w.getframerate()
        rate = w.getframerate()
except Exception as e:
    print("  [x] ответ не разбирается как WAV: %s" % e); sys.exit(1)
print("  [v] получен WAV: %d байт, %.1f с, %d Гц (за %.1f с)" % (len(audio), secs, rate, took))
if secs < 0.8:
    print("  [x] звука почти нет — это не речь"); sys.exit(1)

body, b = multipart({"model": "gigaam-v3"},
                    {"file": ("speech.wav", audio, "audio/wav")})
req = urllib.request.Request(stt + "/v1/audio/transcriptions", data=body,
                             headers={"Content-Type": "multipart/form-data; boundary=" + b})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        heard = json.load(r).get("text", "").strip()
except Exception as e:
    print("  [!] распознавание недоступно (%s) — проверьте на слух" % e); sys.exit(0)
print("  [v] распознано: %s" % heard)

def words(s):
    return {w.strip(".,!?—-«»").lower() for w in s.split() if len(w.strip(".,!?—-«»")) > 2}

want, got = words(FRAZA), words(heard)
hit = len(want & got)
print("  [v] совпало слов: %d из %d" % (hit, len(want)))
sys.exit(0 if hit >= max(2, len(want) - 1) else 1)
INNER
RC=$?

say "Итог"
if [ "$RC" = "0" ]; then
  ok "XTTS-v2 говорит по-русски и распознаётся"
  ok "адрес для Anima: http://<адрес станции>:${PORT}"
else
  die "синтез не прошёл проверку — смотрите: docker logs evs-xtts"
fi
