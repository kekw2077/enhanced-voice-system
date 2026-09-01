# Общая основа для контейнеров, считающих на видеокарте AMD.
#
# Существует ради диска. Колёса torch под ROCm весят около десяти гигабайт, и
# двум образам — синтезу и генерации картинок — они нужны одни и те же. Пока
# каждый ставил их сам, docker хранил две копии: на станции со свободными 31 ГБ
# это разница между «влезло» и «не влезло».
#
# Собирается один раз:  docker build -t evs-rocm-base:latest server/rocm-base
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv git curl ca-certificates \
        sox libsox-dev ffmpeg unzip \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# ВНИМАНИЕ: индекс ROCm, не обычный PyPI. С обычного приедет сборка под CUDA —
# на Radeon она не заработает, а ошибка будет невнятной («no kernel image»).
ARG ROCM_INDEX=https://download.pytorch.org/whl/rocm6.4
RUN pip install --no-cache-dir --index-url ${ROCM_INDEX} torch torchaudio
