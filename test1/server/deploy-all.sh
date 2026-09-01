#!/usr/bin/env bash
# Развернуть на станции всё разом: общую основу, синтез голоса и генерацию
# картинок. Запускать отвязанно от сессии — сборка идёт полчаса и переживёт
# закрытый ssh:
#
#     ssh npc 'setsid nohup bash ~/evs-deploy-all.sh > ~/evs-deploy.log 2>&1 < /dev/null &'
#     ssh npc 'tail -f ~/evs-deploy.log'
#
# Почему одним скриптом, а не тремя командами по очереди: между шагами нельзя
# запускать `docker image prune` — только что собранная основа ещё никем не
# занята, и чистка сносит её как мусор. На этом уже обожглись: сборка синтеза
# упала на FROM evs-rocm-base через минуту после успешной сборки самой основы.
set -uo pipefail

# Скрипты приезжают с Windows, где перевод строки другой. Bash спотыкается об
# него с невнятным «синтаксическая ошибка рядом с $'in'» — уже спотыкался.
# Нормализуем сами, а не надеемся на аккуратность доставки.
for f in "$HOME"/evs-tts/* "$HOME"/evs-image/* "$HOME"/evs-rocm-base/*; do
  [ -f "$f" ] && sed -i 's/$//' "$f"
done

MODEL_URL="${MODEL_URL:-https://huggingface.co/cagliostrolab/animagine-xl-4.0/resolve/main/animagine-xl-4.0-opt.safetensors}"

stamp() { date '+%H:%M:%S'; }
say()   { printf '\n\033[1;36m######## [%s] %s\033[0m\n' "$(stamp)" "$*"; }
die()   { printf '\n\033[1;31m######## [%s] ОСТАНОВ: %s\033[0m\n' "$(stamp)" "$*" >&2; exit 1; }

say "Свободно на диске: $(df -h / | tail -1 | awk '{print $4}')"

# ---- 1. Общая основа ---------------------------------------------------------
# torch под ROCm весит около десяти гигабайт, и он нужен и синтезу, и генерации.
# Собираем один раз, оба образа наследуются от него.
if docker image inspect evs-rocm-base:latest >/dev/null 2>&1; then
  say "Основа evs-rocm-base уже собрана — пропускаю"
else
  say "Собираю основу evs-rocm-base (torch под ROCm, ~10 минут)"
  docker build -t evs-rocm-base:latest "$HOME/evs-rocm-base" \
    || die "основа не собралась"
fi
docker image inspect evs-rocm-base:latest >/dev/null 2>&1 \
  || die "основа не появилась в списке образов"

# ---- 2. Синтез голоса --------------------------------------------------------
say "Синтез голоса: CosyVoice"
bash "$HOME/evs-tts/deploy-tts.sh" || die "синтез не развернулся"

# ---- 3. Генерация картинок ---------------------------------------------------
say "Генерация картинок: Animagine XL"
bash "$HOME/evs-image/deploy-image.sh" --model-url "$MODEL_URL" \
  || die "генерация не развернулась"

# ---- 4. Итог -----------------------------------------------------------------
say "ГОТОВО"
docker ps --format '  {{.Names}}\t{{.Status}}' | grep -E 'evs-|ollama'
echo
echo "  Свободно на диске: $(df -h / | tail -1 | awk '{print $4}')"
