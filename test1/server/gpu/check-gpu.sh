#!/usr/bin/env bash
# Готова ли станция к видеокарте AMD (RX 9060 XT, RDNA4 / gfx1200).
#
# Запускать МОЖНО И НУЖНО дважды: до установки карты — увидеть, чего не хватает
# в системе, и после — убедиться, что всё подхватилось.
#
#     scp check-gpu.sh user@станция:~
#     ssh user@станция 'bash ~/check-gpu.sh'
#
# Ничего не меняет и не ставит: только смотрит и печатает вывод.
set -uo pipefail

ok()   { printf '  \033[1;32m[v]\033[0m %s\n' "$*"; }
no()   { printf '  \033[1;31m[x]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[!]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

NEED=()

hdr "Система"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "  $PRETTY_NAME"
  case "${VERSION_ID:-}" in
    22.04|24.04|12|13) ok "версия из числа поддерживаемых ROCm" ;;
    *) warn "ROCm официально проверяют на Ubuntu 22.04/24.04 и Debian 12/13" ;;
  esac
fi
echo "  ядро: $(uname -r)"
# ROCm 7.x требует свежее ядро; на старых amdgpu не знает RDNA4.
kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2)
if [ "$kmaj" -gt 6 ] || { [ "$kmaj" -eq 6 ] && [ "$kmin" -ge 12 ]; }; then
  ok "ядро $kmaj.$kmin — RDNA4 поддерживается"
else
  no "ядро $kmaj.$kmin слишком старое для RDNA4 (нужно 6.12+)"
  NEED+=("обновить ядро до 6.12 или новее")
fi

hdr "Видеокарта"
if command -v lspci >/dev/null 2>&1; then
  gpu=$(lspci -nn | grep -Ei 'vga|display|3d' || true)
  if [ -n "$gpu" ]; then
    echo "$gpu" | sed 's/^/  /'
    if echo "$gpu" | grep -qi 'amd\|ati'; then
      ok "AMD найдена"
    else
      warn "AMD не видно — карта ещё не установлена?"
      NEED+=("установить видеокарту")
    fi
  else
    warn "устройств отображения не найдено"
  fi
else
  warn "нет lspci (пакет pciutils) — пропускаю"
fi

hdr "Драйвер ядра amdgpu"
if [ -e /dev/kfd ]; then
  ok "/dev/kfd есть — вычислительный интерфейс поднят"
else
  no "/dev/kfd нет: amdgpu не загружен или карта не установлена"
  NEED+=("драйвер amdgpu (пакет amdgpu-dkms из репозитория ROCm)")
fi
if lsmod 2>/dev/null | grep -q '^amdgpu'; then
  ok "модуль amdgpu загружен"
else
  no "модуль amdgpu не загружен"
fi
# $USER есть не в каждом окружении (cron, sudo -i, некоторые ssh-сессии), а при
# `set -u` его отсутствие роняет скрипт на середине проверки.
ME=${USER:-$(id -un)}
for g in render video; do
  if id -nG "$ME" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
    ok "пользователь $ME в группе $g"
  else
    no "пользователь $ME НЕ в группе $g — контейнеры не получат карту"
    NEED+=("sudo usermod -aG $g $ME  (и перелогиниться)")
  fi
done

hdr "ROCm"
if command -v rocminfo >/dev/null 2>&1; then
  arch=$(rocminfo 2>/dev/null | grep -m1 -o 'gfx[0-9a-f]*' || true)
  ver=$(cat /opt/rocm/.info/version 2>/dev/null || echo "?")
  ok "rocminfo есть, версия ROCm: $ver, архитектура: ${arch:-не определилась}"
  case "$arch" in
    gfx1200|gfx1201) ok "RDNA4 распознана" ;;
    "") warn "карта не отвечает — проверьте /dev/kfd и права" ;;
    *) warn "это не RDNA4 ($arch) — возможно, встроенная графика" ;;
  esac
  case "$ver" in
    7.*|8.*) ok "версия ROCm подходит для RDNA4" ;;
    *) no "для RX 9060 XT нужен ROCm 7.0.2 или новее"; NEED+=("обновить ROCm до 7.x") ;;
  esac
else
  no "ROCm не установлен"
  NEED+=("установить ROCm 7.x (amdgpu-install --usecase=rocm)")
fi

hdr "Docker"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker работает, версия $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if docker compose version >/dev/null 2>&1; then
    ok "плагин compose есть"
  else
    no "нет docker compose v2"; NEED+=("поставить плагин docker-compose-v2")
  fi
  # Главная проверка: отдаёт ли docker карту контейнеру. Для AMD это НЕ
  # `--gpus all` (это про NVIDIA), а проброс устройств /dev/kfd и /dev/dri.
  if [ -e /dev/kfd ]; then
    if docker run --rm --device=/dev/kfd --device=/dev/dri \
         --security-opt seccomp=unconfined ubuntu:24.04 true >/dev/null 2>&1; then
      ok "контейнер получает /dev/kfd и /dev/dri"
    else
      no "контейнеру не отдаются устройства карты"
      NEED+=("проверить права на /dev/kfd и /dev/dri (группы render/video)")
    fi
  fi
else
  no "docker не найден или демон недоступен"
  NEED+=("установить docker + плагин compose")
fi

hdr "Что уже крутится"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker ps --format '  {{.Names}}  ({{.Image}})' 2>/dev/null | head -20
fi
if command -v ollama >/dev/null 2>&1; then
  ok "ollama установлена локально: $(ollama --version 2>/dev/null | head -1)"
fi

hdr "Память и диск"
free -h 2>/dev/null | sed 's/^/  /' | head -2
df -h / /var/lib/docker 2>/dev/null | sed 's/^/  /' | head -3

hdr "Итог"
if [ ${#NEED[@]} -eq 0 ]; then
  echo "  Станция готова: карта видна, ROCm на месте, docker отдаёт её контейнерам."
  echo "  Дальше — развернуть синтез и переключить Ollama на видеокарту."
else
  echo "  Чтобы всё подхватилось при установке карты, не хватает:"
  for n in "${NEED[@]}"; do echo "   - $n"; done
fi
