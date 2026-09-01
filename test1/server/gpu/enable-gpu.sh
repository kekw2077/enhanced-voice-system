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

# Группы хоста здесь НЕ нужны: контейнеры работают от root и открывают
# /dev/kfd напрямую. Проверяем то, что действительно решает, — отдаёт ли docker
# устройства контейнеру. Раньше скрипт падал на группах при полностью рабочей
# карте.
if ! docker run --rm --device=/dev/kfd --device=/dev/dri      --security-opt seccomp=unconfined ubuntu:24.04 true >/dev/null 2>&1; then
  die "docker не отдаёт карту контейнеру — проверьте права на /dev/kfd"
fi
ok "docker отдаёт карту контейнеру"

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
# Идентификаторы групп берём с хоста и подставляем ЧИСЛАМИ. `group_add` с
# именем резолвится внутри образа, а в ollama/ollama:rocm группы render нет —
# контейнер падал с «unable to find group render».
GID_RENDER=$(getent group render | cut -d: -f3)
GID_VIDEO=$(getent group video | cut -d: -f3)
[ -n "$GID_RENDER" ] || die "на хосте нет группы render"
ok "группы хоста: render=$GID_RENDER, video=${GID_VIDEO:-нет}"

cat > "$OVERRIDE" <<YAML
# Ollama на видеокарте AMD (RDNA4 / gfx1200). Файл создан enable-gpu.sh.
#
# Для AMD карта пробрасывается устройствами, а НЕ ключом \`--gpus\` и не разделом
# \`deploy.resources.devices\` — то путь NVIDIA, на Radeon он молча ничего не даёт.
#
# Откат: удалить этот файл и выполнить \`docker compose up -d ollama\`.
services:
  ollama:
    image: ollama/ollama:rocm
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - "${GID_RENDER}"
      - "${GID_VIDEO}"
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
# Разбираем по содержимому строки, а не по номерам столбцов: размер модели
# занимает два поля («8.3 GB»), и подсчёт позиций давал «GB 100%» вместо
# «100% GPU» — проверка объявляла процессор при модели на карте.
PS_LINE=$(docker exec ollama ollama ps 2>/dev/null | sed -n '2p')
case "$PS_LINE" in
  *GPU*) ok "модель считает видеокарта" ;;
  *CPU*) no "модель считает процессор"
         echo "      docker logs ollama | grep -i -E 'rocm|gfx|gpu'" ;;
  *)     no "модель не загружена — docker exec ollama ollama ps" ;;
esac
