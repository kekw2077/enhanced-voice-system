# CosyVoice на видеокарте AMD (ROCm). Собирается на станции.
#
# Базой намеренно взят обычный Ubuntu, а НЕ rocm/pytorch: тот образ весит
# 25-40 ГБ, а на станции свободно около 35. Колёса torch под ROCm приносят
# нужные библиотеки с собой, и образ выходит втрое меньше.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/models/.hf \
    MODELSCOPE_CACHE=/models/.modelscope

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv git curl ca-certificates \
        sox libsox-dev ffmpeg unzip \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# ВНИМАНИЕ: индекс ROCm, не обычный PyPI. С обычного приедет сборка под CUDA,
# на Radeon она не заработает, а ошибка будет невнятной — «no kernel image».
ARG ROCM_INDEX=https://download.pytorch.org/whl/rocm6.4
RUN pip install --no-cache-dir --index-url ${ROCM_INDEX} \
        torch torchaudio

# Зависимости CosyVoice. pynini ставится колесом: сборка из исходников тянет
# полный OpenFst и занимает десятки минут.
RUN pip install --no-cache-dir \
        "numpy<2" scipy soundfile librosa \
        transformers accelerate sentencepiece \
        hyperpyyaml omegaconf einops \
        modelscope huggingface_hub \
        pynini==2.1.6 WeTextProcessing \
        diffusers conformer lightning gdown

RUN git clone --depth 1 --recursive \
        https://github.com/FunAudioLLM/CosyVoice.git /opt/CosyVoice

COPY server.py /opt/server.py

# Модель НЕ вшивается в образ: она живёт в томе, иначе каждая пересборка
# перекачивала бы пару гигабайт, а образ пух бы на ту же величину.
VOLUME ["/models"]
EXPOSE 8760
CMD ["python3", "/opt/server.py"]
