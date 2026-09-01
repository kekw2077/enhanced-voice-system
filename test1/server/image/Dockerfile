# Генерация картинок на видеокарте AMD. Тяжёлая часть — в общей основе
# evs-rocm-base, здесь только diffusers со спутниками.
FROM evs-rocm-base:latest

ENV HF_HOME=/models/.hf

RUN pip install --no-cache-dir \
        diffusers transformers accelerate safetensors \
        "numpy<2" pillow sentencepiece protobuf omegaconf

# Длинные запросы. CLIP принимает 77 токенов, и всё сверх этого diffusers молча
# отбрасывает — в журнале это «190 > 77», а на картинке половина запроса
# просто не прочитана. Compel режет текст на куски и склеивает их
# эмбеддинги. --no-deps намеренно: своими зависимостями compel тянет
# jupyterlab целиком, а нужен ему здесь только разборщик выражений.
# peft — без него diffusers отказывается подключать LoRA: «PEFT backend is
# required for this method».
RUN pip install --no-cache-dir peft

RUN pip install --no-cache-dir --no-deps compel \
    && pip install --no-cache-dir pyparsing lark

# Закрепления версий тут не косметика: свежие scipy, pandas и matplotlib
# собраны под numpy 2, а на нём эта связка torch и diffusers не работает.
# Ломается при этом не там, где ждёшь: transformers перестаёт отдавать
# CLIPImageProcessor, потому что scipy на импорте трогает np.long.
# Второй проход по лицу. Каскады OpenCV тут не годятся — проверено: на
# наклонённом лице аниме-каскад отдавал рамку 77 px там, где лицо занимало
# 340, то есть находил глаз. Небольшая сеть справляется, но тянет за собой
# torchvision, и он ОБЯЗАН быть из того же набора ROCm, что и torch, —
# иначе pip подтянет сборку под другой ускоритель и заменит torch.
RUN pip install --no-cache-dir --no-deps \
        --index-url https://download.pytorch.org/whl/rocm6.4 torchvision \
 && pip install --no-cache-dir --no-deps ultralytics ultralytics-thop \
 && pip install --no-cache-dir pyyaml tqdm psutil py-cpuinfo "matplotlib<3.10" "pandas<2.3" "scipy<1.14" \
 && pip install --no-cache-dir "opencv-python-headless==4.10.0.84" "numpy<2"

COPY server.py /opt/server.py

# Чекпоинт живёт в томе: он весит около семи гигабайт и меняется чаще образа.
VOLUME ["/models"]
EXPOSE 8770
CMD ["python3", "/opt/server.py"]
