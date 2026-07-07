"""GPU detection + VRAM polling (NVIDIA / NVML) and CUDA availability for STT.

Everything is fail-safe: no NVIDIA GPU / driver / NVML, or a CPU-only build,
reports "unavailable" so the app hides GPU selectors (TZ2 block 6) and the
game-mode VRAM trigger stays off (TZ2 block 7). Only Whisper (ctranslate2) has a
usable CUDA path here; sherpa-onnx (GigaAM / denoise) ships CPU-only wheels, so
those engines report supports_gpu=False and their selector is hidden.
"""
from __future__ import annotations

import threading

_lock = threading.Lock()
_nvml_ready: bool | None = None  # tri-state: None = untried


def _ensure_nvml() -> bool:
    global _nvml_ready
    if _nvml_ready is not None:
        return _nvml_ready
    with _lock:
        if _nvml_ready is not None:
            return _nvml_ready
        try:
            import pynvml
            pynvml.nvmlInit()
            _nvml_ready = True
        except Exception:
            _nvml_ready = False
    return _nvml_ready


def cuda_available() -> bool:
    """True if faster-whisper (ctranslate2) can actually use a CUDA device."""
    try:
        import ctranslate2
        return ctranslate2.get_cuda_device_count() > 0
    except Exception:
        return False


def gpu_info() -> dict:
    """Best-effort snapshot for the UI / capabilities:
    {available, name, vram_total_mb, vram_used_mb, vram_percent, cuda}."""
    info = {
        "available": False,
        "name": "",
        "vram_total_mb": 0,
        "vram_used_mb": 0,
        "vram_percent": 0.0,
        "cuda": cuda_available(),
    }
    if not _ensure_nvml():
        return info
    try:
        import pynvml
        h = pynvml.nvmlDeviceGetHandleByIndex(0)
        name = pynvml.nvmlDeviceGetName(h)
        if isinstance(name, bytes):
            name = name.decode("utf-8", "ignore")
        mem = pynvml.nvmlDeviceGetMemoryInfo(h)
        info["available"] = True
        info["name"] = name
        info["vram_total_mb"] = int(mem.total / (1024 * 1024))
        info["vram_used_mb"] = int(mem.used / (1024 * 1024))
        info["vram_percent"] = \
            (mem.used / mem.total * 100.0) if mem.total else 0.0
    except Exception:
        pass
    return info


def vram_percent() -> float | None:
    """Current VRAM utilization 0..100, or None if NVML is unavailable."""
    if not _ensure_nvml():
        return None
    try:
        import pynvml
        h = pynvml.nvmlDeviceGetHandleByIndex(0)
        mem = pynvml.nvmlDeviceGetMemoryInfo(h)
        return (mem.used / mem.total * 100.0) if mem.total else None
    except Exception:
        return None
