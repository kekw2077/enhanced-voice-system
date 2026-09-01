#!/usr/bin/env bash
# Клон голоса Qwen3-TTS на станции, на видеокарте AMD.
#
#     scp -r server/qwen-tts user@станция:~/evs-qwen
#     scp sidecar/qwen_tts_server.py user@станция:~/evs-qwen/
#     ssh user@станция 'bash ~/evs-qwen/deploy-qwen-tts.sh'
#
# Заканчивается НАСТОЯЩЕЙ проверкой: синтезирует русскую фразу и прогоняет её
# через распознавание, которое уже работает на этой же станции. Совпало —
# значит заработает и в EVS. Это не педантизм: с CosyVoice сервер отвечал,
# отдавал WAV правильной длины и рапортовал «healthy», а речи в нём не было.
#
# Опции: --port N (8760) --model ID --ref ФАЙЛ --down --logs --rebuild
set -uo pipefail

PORT=8760
ACTION=up
REBUILD=0
MODEL="${EVS_QWEN_MODEL:-Qwen/Qwen3-TTS-12Hz-1.7B-Base}"
PRECISION="${EVS_QWEN_PRECISION:-auto}"
# Через сколько секунд простоя отдавать видеопамять. Пять минут оказались
# слишком мало: после паузы первая фраза стоит 17-25 секунд на перезагрузку
# модели, и попадать в это приходится постоянно. Пятнадцать минут покрывают
# разговор с паузами, но не держат карту, когда за компьютером никого.
IDLE="${EVS_QWEN_IDLE:-900}"
REF=""
STT_URL="${STT_URL:-http://127.0.0.1:9876}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${HOME}/evs-qwen-data"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --precision) PRECISION="$2"; shift 2;;
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
  docker rm -f evs-qwen >/dev/null 2>&1 || true
  say "синтез остановлен (веса в $DATA остались)"
  exit 0
fi
if [ "$ACTION" = logs ]; then
  docker logs --tail 60 evs-qwen
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

# docker освобождает временные файлы распаковки не сразу: сразу после сборки
# основы df показывал 8 ГБ, а через десять секунд — 22. Даём ему договорить.
sync; sleep 3
FREE=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
say "Место на диске: ${FREE} ГБ"
[ "${FREE:-0}" -lt 12 ] && die "Нужно хотя бы 12 ГБ: свой слой образа и веса на четыре."
ok "хватает"

say "Общая основа"
if ! docker image inspect evs-rocm-base:latest >/dev/null 2>&1; then
  say "Собираю основу (torch под ROCm, это долго и один раз)"
  docker build -t evs-rocm-base:latest "$DIR/../rocm-base" \
    || docker build -t evs-rocm-base:latest "$HOME/evs-rocm-base" \
    || die "не собралась основа evs-rocm-base"
fi
ok "на месте"

say "Сборка образа"
[ -f "$DIR/qwen_tts_server.py" ] || die "рядом нет qwen_tts_server.py — скопируйте его из sidecar/"
if [ "$REBUILD" = "1" ] || ! docker image inspect evs-qwen:latest >/dev/null 2>&1; then
  docker build -t evs-qwen:latest "$DIR" || die "образ не собрался"
fi
ok "образ готов"

# MIOPEN_FIND_MODE=FAST — не искать лучший алгоритм свёртки перебором на
# каждой новой длине фразы. У синтеза длина ответа каждый раз своя, и
# перебор съедал по 13-15 секунд почти на каждой реплике при 5 секундах
# на самом синтезе. Быстрый режим берёт заведомо годный алгоритм сразу.
# Отдельный том под скомпилированные ядра MIOpen. ROCm компилирует их под
# каждую новую длину фразы: первый такой прогон стоит 16 секунд против 5
# у повторного. Без тома эта работа пропадает при пересоздании контейнера,
# и первая фраза после перезапуска снова тормозит.
say "Запуск ($MODEL)"
mkdir -p "$DATA" "$DATA/miopen"
docker rm -f evs-qwen >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name evs-qwen --restart unless-stopped \
  --device=/dev/kfd --device=/dev/dri \
  --security-opt seccomp=unconfined $GRP \
  -p "${PORT}:8760" \
  -v "$DATA:/models" \
  -v "$DATA/miopen:/root/.cache/miopen" \
  -e EVS_QWEN_MODEL="$MODEL" \
  -e EVS_QWEN_PRECISION="$PRECISION" \
  -e EVS_QWEN_IDLE="$IDLE" \
  -e MIOPEN_FIND_MODE=FAST \
  -e MIOPEN_FIND_ENFORCE=NONE \
  evs-qwen:latest >/dev/null || die "контейнер не поднялся"
# Общая сеть с генератором картинок: он просит выгрузить голос перед тем,
# как занять карту, а через адрес шлюза этот контейнер не отвечает —
# оба на одном мосту, ответ приходит не с того адреса, и запрос виснет.
docker network inspect evs-gpu >/dev/null 2>&1 || docker network create evs-gpu >/dev/null 2>&1 || true
docker network connect evs-gpu evs-qwen >/dev/null 2>&1 || true

for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
  || die "сервер не отвечает: docker logs evs-qwen"
ok "сервер отвечает"
curl -fsS "http://127.0.0.1:${PORT}/health" | sed 's/^/      /'

# ---- Проверка настоящей русской фразой ---------------------------------------
# Синтезируем известный текст и отдаём его распознаванию, которое работает на
# этой же станции. Сверяем слова. Именно этой проверки не хватало на CosyVoice:
# там всё выглядело исправным, а речь была бессмысленной, и выяснилось это лишь
# через несколько часов.
say "Проверка настоящим синтезом и распознаванием"
if [ -z "$REF" ]; then
  for cand in "$HOME/samples/ru-RU-DmitryNeural.mp3" "$HOME/samples/ru-RU-SvetlanaNeural.mp3"; do
    [ -f "$cand" ] && REF="$cand" && break
  done
fi
[ -n "$REF" ] && [ -f "$REF" ] || die "Нет образца голоса для проверки.
  Укажите его: bash $0 --ref /путь/к/образцу.wav
  Годится любая запись речи от трёх секунд."
ok "образец: $(basename "$REF")"

REFWAV=/tmp/evs-qwen-ref.wav
docker cp "$REF" evs-qwen:/tmp/ref-src >/dev/null 2>&1 \
  && docker exec evs-qwen ffmpeg -y -loglevel error -i /tmp/ref-src -t 10 -ar 16000 -ac 1 /tmp/ref.wav \
  && docker cp evs-qwen:/tmp/ref.wav "$REFWAV" >/dev/null 2>&1 \
  || die "не удалось подготовить образец"

python3 - "$PORT" "$REFWAV" "$STT_URL" <<'INNER'
import io, json, sys, urllib.request, wave, uuid
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
body, b = multipart({"tts_text": FRAZA, "prompt_text": "", "speed": 1.0},
                    {"prompt_wav": ("ref.wav", ref, "audio/wav")})
req = urllib.request.Request("http://127.0.0.1:%s/inference_zero_shot" % port, data=body,
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

body, b = multipart({"model": "gigaam-v3"},
                    {"file": ("out.wav", audio, "audio/wav")})
req = urllib.request.Request(stt + "/v1/audio/transcriptions", data=body,
                             headers={"Content-Type": "multipart/form-data; boundary=" + b})
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        heard = json.loads(r.read().decode("utf-8")).get("text", "").strip()
except Exception as e:
    print("  [!] распознавание недоступно (%s) — проверить речь нечем." % e)
    print("      Послушайте сами: сохранён ответ сервера.")
    sys.exit(0)

norm = lambda s: set("".join(c if c.isalnum() or c.isspace() else " " for c in s.lower()).split())
want, got = norm(FRAZA), norm(heard)
share = len(want & got) / max(1, len(want))
print("  сказали:   %s" % FRAZA)
print("  услышали:  %s" % (heard or "(тишина)"))
print("  совпало слов: %.0f%%" % (share * 100))
if share < 0.5:
    print("  [x] речь не распознаётся — сервер отвечает, но говорит не то.")
    print("      Так вело себя CosyVoice: проверьте версии пакетов и язык модели.")
    sys.exit(1)
print("  [v] речь разборчива")
INNER
[ $? -eq 0 ] || die "проверка не пройдена — в EVS это тоже не заработает"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS=$(tailscale ip -4 2>/dev/null | head -1 || true)
say "Готово"
echo "  В EVS: «Голос ассистента» -> адрес сервера клон-голоса:"
echo "    http://${IP}:${PORT}"
[ -n "$TS" ] && echo "    http://${TS}:${PORT}   (через Tailscale)"
echo
echo "  Модель отдаёт видеопамять после 5 минут простоя —"
echo "  ту же карту делит языковая модель."
