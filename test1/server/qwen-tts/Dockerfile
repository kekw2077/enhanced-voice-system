# Клон голоса Qwen3-TTS на видеокарте AMD. Тяжёлая часть — в общей основе
# evs-rocm-base, здесь только пакет синтеза.
#
# Сервер НЕ переписан под станцию: сюда кладётся тот же sidecar/qwen_tts_server.py,
# который запускается на компьютере пользователя под CUDA. Он спрашивает у torch,
# есть ли карта, а не какого она производителя, — значит один и тот же файл
# работает в обоих местах, и чинить придётся одно место, а не два.
FROM evs-rocm-base:latest

ENV HF_HOME=/models/.hf \
    EVS_QWEN_CACHE=/models

# qwen-tts тянет transformers нужной ему версии сам. Закреплять здесь ничего не
# закрепляем намеренно: на CosyVoice уже обожглись в обратную сторону — там
# несовпадение версий ломало речь молча, и лечилось это закреплением по
# requirements самого проекта, а не нашими догадками.
RUN pip install --no-cache-dir qwen-tts soundfile numpy

COPY qwen_tts_server.py /opt/server.py

# Веса (~4 ГБ) живут в томе: они переживают пересборку образа и не раздувают его.
VOLUME ["/models"]
EXPOSE 8760
CMD ["python3", "/opt/server.py", "--host", "0.0.0.0", "--port", "8760", \
     "--cache-dir", "/models", "--language", "Russian"]
