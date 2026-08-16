# Генерация картинок на видеокарте AMD (ROCm).
#
# База и слой с torch намеренно те же, что у server/tts: docker переиспользует
# общие слои, и второй образ добавляет к диску только diffusers с зависимостями,
# а не ещё десяток гигабайт torch.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/models/.hf

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# ВНИМАНИЕ: индекс ROCm, не обычный PyPI. С обычного приедет сборка под CUDA —
# на Radeon она не заработает, а ошибка будет невнятной.
ARG ROCM_INDEX=https://download.pytorch.org/whl/rocm6.4
RUN pip install --no-cache-dir --index-url ${ROCM_INDEX} torch

RUN pip install --no-cache-dir \
        diffusers transformers accelerate safetensors \
        "numpy<2" pillow sentencepiece protobuf omegaconf

COPY server.py /opt/server.py

# Чекпоинт живёт в томе: он весит около семи гигабайт и меняется чаще образа.
VOLUME ["/models"]
EXPOSE 8770
CMD ["python3", "/opt/server.py"]
