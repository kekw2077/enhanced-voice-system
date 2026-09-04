#!/usr/bin/env bash
# Свой поиск на станции: SearXNG — метапоисковик, который спрашивает чужие
# поисковики и отдаёт сведённый ответ. Ключей не требует, историю не пишет.
#
#     scp -r server/searxng user@станция:~/evs-searxng
#     ssh user@станция 'bash ~/evs-searxng/deploy-searxng.sh'
#
# Зачем он здесь. Поиск в Anima умеет пять провайдеров, и у четырёх из них цена
# входа — ключ (Tavily, Brave, Google, Яндекс), а бесключевой DuckDuckGo отдаёт
# короткие ответы и первым замечает, что его дёргает программа. SearXNG снимает
# и то, и другое: спрашивает он от своего имени и со станции, а не с домашнего
# адреса пользователя, и отвечает по-настоящему разобранным JSON.
#
# Заканчивается НАСТОЯЩЕЙ проверкой: настоящим запросом через JSON-контракт, тем
# самым, которым ходит приложение. «Контейнер поднялся» — не проверка: у SearXNG
# формат json по умолчанию ВЫКЛЮЧЕН, и сервер в этом случае отвечает 403 ровно
# на том пути, ради которого он и заведён.
#
# Опции: --port N (8888) --down --logs --pull
set -uo pipefail

PORT=8888
ACTION=up
PULL=0
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HOME}/evs-searxng"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --down) ACTION=down; shift;;
    --logs) ACTION=logs; shift;;
    --pull) PULL=1; shift;;
    -h|--help) sed -n '2,19p' "$0"; exit 0;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[1;32m[v]\033[0m %s\n' "$*"; }
die() { printf '  \033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker не найден"
docker compose version >/dev/null 2>&1 || die "нет плагина docker compose"

mkdir -p "$ROOT/config"
cd "$ROOT"

if [ "$ACTION" = down ]; then
  docker compose -p evs-searxng down 2>/dev/null || true
  say "поиск остановлен (настройки в $ROOT/config остались)"
  exit 0
fi
if [ "$ACTION" = logs ]; then
  docker compose -p evs-searxng logs --tail 60
  exit 0
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS=$(tailscale ip -4 2>/dev/null | head -1 || true)
BASE="http://${IP}:${PORT}/"

# Секрет генерируется ОДИН раз и переживает пересборку: он подписывает
# служебные ссылки, и смена его на каждом развёртывании ломала бы открытые
# вкладки без всякой пользы.
SECRET_FILE="$ROOT/config/.secret"
if [ ! -s "$SECRET_FILE" ]; then
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SECRET_FILE"
fi
SECRET="$(cat "$SECRET_FILE")"

say "Настройки"
cat > "$ROOT/config/settings.yml" <<YAML
# Поверх стандартных настроек SearXNG — ровно то, ради чего он здесь.
use_default_settings: true

general:
  instance_name: "Nexus Anima"
  # Страница статистики и «о сервисе» ни к чему: сервер видит одно приложение
  # в домашней сети, а не публика.
  enable_metrics: false

server:
  secret_key: "${SECRET}"
  base_url: "${BASE}"
  # Ограничитель рассчитан на браузеры и людей: он смотрит на заголовки, cookie
  # и частоту запросов. Наш клиент — программа, и для неё это только источник
  # внезапных 429 посреди разговора.
  limiter: false
  image_proxy: false

search:
  # Ради этой строки всё и затевалось. По умолчанию у SearXNG формат json
  # ВЫКЛЮЧЕН, и /search?format=json отвечает 403 — сколько ни настраивай
  # клиента.
  formats:
    - html
    - json
  safe_search: 0
  # Подсказки при наборе нужны браузеру, а приложение шлёт готовый запрос.
  autocomplete: ""
  default_lang: "auto"

ui:
  static_use_hash: true
YAML
ok "config/settings.yml записан"

cat > compose.yml <<YAML
# Один контейнер, без redis: ограничитель выключен, а он единственный, кому
# redis был нужен. Меньше движущихся частей — меньше того, что встанет ночью.
services:
  evs-searxng:
    image: docker.io/searxng/searxng:latest
    container_name: evs-searxng
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    volumes:
      - ./config:/etc/searxng
    environment:
      - SEARXNG_BASE_URL=${BASE}
    # Логи метапоисковика — это список чужих запросов. Держим короткими.
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "2"
YAML

if [ "$PULL" = 1 ]; then
  say "Обновляю образ"
  docker compose -p evs-searxng pull || die "образ не скачался"
fi

say "Запуск"
docker compose -p evs-searxng up -d || die "контейнер не поднялся"

for i in $(seq 1 45); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null && break
  sleep 2
done
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null \
  || die "сервер не отвечает: docker logs evs-searxng"
ok "страница отдаётся"

say "Проверка настоящим запросом"
python3 - "$PORT" <<'INNER'
import json
import sys
import urllib.parse
import urllib.request

port = sys.argv[1]
q = "погода в Москве"
url = "http://127.0.0.1:%s/search?%s" % (
    port, urllib.parse.urlencode({"q": q, "format": "json", "language": "ru"}))
req = urllib.request.Request(url, headers={"User-Agent": "NexusAnima/1.0"})
try:
    with urllib.request.urlopen(req, timeout=40) as r:
        data = json.load(r)
except Exception as e:                      # noqa: BLE001 — печатаем причину как есть
    print("  \033[1;31m[x]\033[0m json-контракт не ответил: %s" % e)
    print("      Чаще всего это значит, что settings.yml не подхватился и"
          " формат json остался выключенным.")
    sys.exit(1)

results = data.get("results") or []
if not results:
    print("  \033[1;31m[x]\033[0m сервер ответил, но ничего не нашёл —"
          " движки заблокированы или нет сети")
    sys.exit(1)

print("  \033[1;32m[v]\033[0m «%s» — %d ответов, движки: %s"
      % (q, len(results), ", ".join(sorted({e for r in results
                                            for e in r.get("engines", [])})[:6])))
print("      первый: %s" % (results[0].get("title") or "")[:70])
INNER
[ $? -eq 0 ] || die "поиск не работает — приложению его давать нельзя"

say "Готово"
echo "  Адрес в локальной сети : http://${IP}:${PORT}"
[ -n "$TS" ] && echo "  Через Tailscale        : http://${TS}:${PORT}"
echo
echo "  Впишите его в Anima: Настройки → «Поиск в интернете» → «Свой SearXNG»."
echo "  Ключи при этом не нужны: сервер спрашивает чужие поисковики сам."
