# CosyVoice на видеокарте AMD. Тяжёлая часть — в общей основе evs-rocm-base,
# здесь только то, что нужно именно синтезу.
FROM evs-rocm-base:latest

ENV HF_HOME=/models/.hf \
    MODELSCOPE_CACHE=/models/.modelscope

# pyworld собирается из исходников — готового колеса под Python 3.12 нет, а без
# заголовков Python сборка падает невнятным «Failed building wheel». Нужен он
# обязательно: cosyvoice.dataset.processor импортирует pyworld на верхнем
# уровне, даже когда обучение не используется.
RUN apt-get update && apt-get install -y --no-install-recommends         build-essential python3-dev     && rm -rf /var/lib/apt/lists/*

# Версии закреплены по requirements.txt самого CosyVoice — все четыре, не
# только transformers, которую требует сам CosyVoice. Это не
# перестраховка: со свежей пятой веткой синтез внешне работал — модель
# загружалась, отдавала WAV нужной длительности, — но речь получалась
# бессмысленной. Ни русское распознавание, ни Whisper не находили в ней слов, и
# то же самое повторялось на эталонном образце самих авторов. Пятая ветка заодно
# грузила языковую часть в bfloat16 рядом с float32-слоями CosyVoice, отчего
# синтез молча возвращал два кадра вместо речи. С 4.51.3 эталон проговаривается
# слово в слово.

# pynini ставится колесом: сборка из исходников тянет полный OpenFst и занимает
# десятки минут.
RUN pip install --no-cache-dir \
        "numpy<2" scipy soundfile librosa \
        "transformers==4.51.3" "diffusers==0.29.0" "lightning==2.2.4" \
        accelerate sentencepiece \
        hyperpyyaml omegaconf einops \
        modelscope huggingface_hub \
        pynini==2.1.6 WeTextProcessing \
        conformer gdown

# Остальное, без чего CosyVoice не загружается. Список собран не из
# requirements.txt — там половина про обучение, CUDA и веб-интерфейс, — а
# перебором: каждая строка отвечает конкретному «No module named ...»,
# полученному на живом запуске.
#   onnxruntime      — токенизатор речи и отпечаток голоса (модели в ONNX)
#   openai-whisper   — мел-спектрограммы для этого токенизатора
#   inflect, wetext  — нормализация текста
#   pyworld          — импортируется в cosyvoice.dataset.processor
#   onnx, x-transformers, hydra-core, matplotlib, pyarrow, rich, wget —
#                      подтягиваются по цепочке импортов
#
# numpy закрепляем последней строкой: часть пакетов тянет за собой вторую
# ветку, а CosyVoice с ней не работает.
RUN pip install --no-cache-dir cython \
    && pip install --no-cache-dir \
        "onnxruntime==1.18.0" openai-whisper \
        inflect wetext pyworld onnx \
        x-transformers hydra-core \
        matplotlib pyarrow rich wget \
    && pip install --no-cache-dir "numpy<2"

RUN git clone --depth 1 --recursive \
        https://github.com/FunAudioLLM/CosyVoice.git /opt/CosyVoice

COPY server.py /opt/server.py

# Модель НЕ вшивается в образ: она живёт в томе, иначе каждая пересборка
# перекачивала бы пару гигабайт, а образ пух бы на ту же величину.
VOLUME ["/models"]
EXPOSE 8760
CMD ["python3", "/opt/server.py"]
