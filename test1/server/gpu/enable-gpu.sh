#!/usr/bin/env bash
# Перевести Ollama на видеокарту AMD — запускать ПОСЛЕ установки карты.
#
#     ssh npc 'bash ~/enable-gpu.sh'
#
# Скрипт сначала убеждается, что карта на месте и доступна, и только потом
# что-то меняет. Если карты нет — выходит, ничего не тронув: включить проброс
# несуществующего /dev/kfd означает уронить контейнер, который сейчас работает.
#
# Рабочий docker-compose.yml НЕ правится. Вместо этого рядом кладётся
# docker-compose.override.yml — compose подхватывает его сам, а откат сводится
# к удалению одного файла.
set -uo pipefail

DIR=${DIR:-/home/art/home-assistant_ai}
OVERRIDE="$DIR/docker-compose.override.yml"

ok()   { printf '  \033[1;32m[v]\033[0m %s\n' "$*"; }
no()   { printf '  \033[1;31m[x]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m %s\033[0m\n' "$*" >&2; exit 1; }

hdr "Проверка карты"
lspci -nn 2>/dev/null | grep -Ei 'vga|display|3d' | grep -q '\[1002:' \
  || die "Видеокарта AMD не найдена. Карта установлена? Ничего не меняю."
ok "AMD в системе"
[ -e /dev/kfd ] || die "Нет /dev/kfd — драйвер amdgpu не поднялся. Ничего не меняю."
[ -e /dev/dri ] || die "Нет /dev/dri. Ничего не меняю."
ok "/dev/kfd и /dev/dri на месте"

# Группы: без них контейнер получит устройства, но не права на них, и всё
# свалится на процессор молча — самый неприятный вид поломки.
MISSING=""
for g in render video; do
  id -nG | tr ' ' '\n' | grep -qx "$g" || MISSING="$MISSING $g"
done
if [ -n "$MISSING" ]; then
  die "Пользователь не в группах:$MISSING
  sudo usermod -aG render,video $(id -un)   # затем перелогиниться"
fi
ok "пользователь в группах render и video"

hdr "Место на диске"
FREE=$(df -BG --output=avail "$DIR" | tail -1 | tr -dc '0-9')
if [ "${FREE:-0}" -lt 10 ]; then
  die "Свободно ${FREE} ГБ — образу ollama:rocm нужно около 6. Освободите место."
fi
ok "свободно ${FREE} ГБ"

hdr "Накладка для compose"
[ -d "$DIR" ] || die "Нет каталога $DIR"
if [ -e "$OVERRIDE" ]; then
  cp -a "$OVERRIDE" "$OVERRIDE.bak-$(date +%Y%m%d-%H%M%S)"
  ok "прежняя накладка сохранена рядом"
fi
cat > "$OVERRIDE" <<'YAML'
# Ollama на видеокарте AMD (RDNA4 / gfx1200). Файл создан enable-gpu.sh.
#
# Для AMD карта пробрасывается устройствами, а НЕ ключом `--gpus` и не разделом
# `deploy.resources.devices` — то путь NVIDIA, на Radeon он молча ничего не даёт.
#
# Откат: удалить этот файл и выполнить `docker compose up -d ollama`.
services:
  ollama:
    image: ollama/ollama:rocm
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - video
      - render
    security_opt:
      - seccomp:unconfined
    environment:
      # В основном файле стоит 0 «пока на процессоре» — перекрываем.
      - OLLAMA_GPU_LAYERS=999
YAML
ok "записана $OVERRIDE"

hdr "Перезапуск Ollama"
cd "$DIR" || die "не зайти в $DIR"
docker compose pull ollama || die "не скачался образ ollama:rocm"
docker compose up -d ollama || die "контейнер не поднялся — смотрите docker logs ollama"
sleep 6

hdr "Проверка, что считает видеокарта"
docker exec ollama ollama list >/dev/null 2>&1 || die "ollama не отвечает"
MODEL=$(docker exec ollama ollama list 2>/dev/null | awk 'NR==2{print $1}')
if [ -n "$MODEL" ]; then
  docker exec ollama ollama run "$MODEL" "скажи одно слово" >/dev/null 2>&1 || true
  echo "  модель: $MODEL"
  docker exec ollama ollama ps 2>/dev/null | sed 's/^/  /'
fi
if docker logs --tail 200 ollama 2>&1 | grep -qiE 'rocm|radeon|gfx12'; then
  ok "в журнале Ollama видна видеокарта"
  docker logs --tail 200 ollama 2>&1 | grep -iE 'rocm|radeon|gfx12' | tail -3 | sed 's/^/      /'
else
  no "в журнале карты не видно — вероятно, считает процессор"
  echo "      docker logs ollama | grep -i gpu"
fi
