"""Синтез голоса на станции — тот же контракт, что уже понимает EVS.

Контракт снят не из документации, а из кода клиента (sidecar/tts_engine.py,
CosyVoiceEngine):

    GET  /  |  /health  |  /status      -> JSON, проверка доступности
    POST /inference_zero_shot           -> multipart, отдаёт WAV
         поля: tts_text, prompt_text, speed, prompt_wav (файл-образец голоса)
    POST /config                        -> смена настроек на ходу
    POST /unload                        -> выгрузить модель из видеопамяти

Своя обёртка, а не готовый сервер CosyVoice, по одной причине: у официального
FastAPI-сервера нет ни /health, ни /unload, а выгрузка нужна — на станции ту же
видеокарту делит языковая модель, и держать в ней синтез круглосуточно значит
отобрать у неё память просто так.
"""
import io
import json
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_DIR = os.environ.get("COSY_MODEL", "/models/CosyVoice2-0.5B")
PORT = int(os.environ.get("COSY_PORT", "8760"))
# Сколько держать модель в видеопамяти без запросов. 0 — держать всегда.
IDLE_UNLOAD = float(os.environ.get("COSY_IDLE_UNLOAD", "300"))

_lock = threading.Lock()
_model = None
_last_use = 0.0
_device = "неизвестно"


def log(msg: str) -> None:
    print(f"[cosy] {msg}", flush=True)


def patch_torchaudio_load() -> None:
    """Вернуть torchaudio умение читать файлы.

    В torchaudio 2.9 чтение вынесено во внешний TorchCodec, а он в этом образе
    не поднимается: собран под другую версию FFmpeg («Could not load this
    library: libtorchcodec_image.so»). CosyVoice читает образец голоса через
    torchaudio.load у себя внутри, так что обойти это снаружи нельзя — синтез
    падал уже в недрах библиотеки.

    Подменяем ровно одну функцию — чтение — на libsndfile, который в образе
    есть и с WAV справляется. Всё остальное в torchaudio (пересчёт частоты,
    фильтры) считает сам torch и работает как прежде.
    """
    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio

    def _load(uri, frame_offset=0, num_frames=-1, normalize=True,
              channels_first=True, **kw):
        data, sr = sf.read(uri, dtype="float32", always_2d=True,
                           start=frame_offset,
                           frames=num_frames if num_frames and num_frames > 0
                           else -1)
        arr = data.T if channels_first else data
        return torch.from_numpy(np.ascontiguousarray(arr)), sr

    torchaudio.load = _load
    log("чтение аудио переведено на libsndfile")


def pin_attention_backend() -> None:
    """Закрепить проверенный способ считать внимание.

    На новой карте torch сам сообщает: «Mem Efficient attention on Current AMD
    GPU is still experimental». Экспериментальный путь здесь не просто медленнее
    — он считает неверно: модель порождала два кадра вместо речи (ошибка
    «Kernel size can't be greater than actual input size») либо выдавала звук,
    в котором ни русское распознавание, ни Whisper не находили ни слова. То же
    самое повторялось на эталонном образце самих авторов CosyVoice, так что
    дело не в образце.

    Математический путь медленнее ускоренных, но он единственный, который на
    этой карте даёт правильный результат. Медленно и верно лучше, чем быстро и
    впустую.
    """
    import torch
    if not torch.cuda.is_available():
        return
    try:
        torch.backends.cuda.enable_flash_sdp(False)
        torch.backends.cuda.enable_mem_efficient_sdp(False)
        torch.backends.cuda.enable_math_sdp(True)
        log("внимание считается проверенным путём (math)")
    except Exception as e:
        log(f"не удалось закрепить путь внимания: {e}")


def unify_llm_dtype(model) -> None:
    """Привести языковую часть модели к одной точности.

    В CosyVoice2 внутри лежит Qwen2, и приезжает он в bfloat16 — так записано в
    его собственной настройке. А слои, которые CosyVoice надстраивает сверху
    (эмбеддинги речи и выходной слой), создаются в обычном float32. Из 294
    весов языковой части 290 оказываются bfloat16 и четыре — float32.

    Встречаясь в одном умножении, они дают
    «mat1 and mat2 must have the same dtype, but got Float and BFloat16».
    Коварство в том, что CosyVoice эту ошибку глотает: генератор просто не
    отдаёт ни одного кадра, и наружу выходит совсем другое сообщение — «Kernel
    size can't be greater than actual input size» от вокодера, которому нечего
    озвучивать. А при fp16 несовпадение маскируется приведением на лету, и тогда
    звук получается, но бессмысленный: ни распознавание, ни Whisper не находят
    в нём слов.

    Поэтому — одна точность на всю языковую часть, прежде чем что-то считать.
    """
    import torch
    llm = getattr(getattr(model, "model", None), "llm", None)
    if llm is None:
        return
    kinds = {p.dtype for p in llm.parameters()}
    if len(kinds) <= 1:
        return
    было = ", ".join(sorted(str(k).replace("torch.", "") for k in kinds))
    llm.float()
    log(f"языковая часть приведена к float32 (было: {было})")


def load_model():
    """Загрузить модель. Под замком: первый же параллельный запрос иначе
    начнёт грузить вторую копию в ту же видеопамять."""
    global _model, _device
    with _lock:
        if _model is not None:
            return _model
        import torch
        pin_attention_backend()
        patch_torchaudio_load()
        sys.path.insert(0, "/opt/CosyVoice")
        sys.path.insert(0, "/opt/CosyVoice/third_party/Matcha-TTS")
        from cosyvoice.cli.cosyvoice import CosyVoice2
        _device = "видеокарта" if torch.cuda.is_available() else "процессор"
        log(f"загружаю модель на {_device}: {MODEL_DIR}")
        t0 = time.time()
        # fp16 только на видеокарте: на процессоре он медленнее обычного fp32.
        _model = CosyVoice2(MODEL_DIR, load_jit=False, load_trt=False,
                            fp16=torch.cuda.is_available())
        unify_llm_dtype(_model)
        log(f"модель загружена за {time.time() - t0:.1f} с")
        return _model


def unload_model() -> None:
    global _model
    with _lock:
        if _model is None:
            return
        _model = None
        try:
            import gc
            import torch
            gc.collect()
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except Exception:
            pass
        log("модель выгружена, видеопамять освобождена")


def idle_watch() -> None:
    """Выгружать модель, когда ею давно не пользовались."""
    if IDLE_UNLOAD <= 0:
        return
    while True:
        time.sleep(30)
        if _model is not None and _last_use and \
                time.time() - _last_use > IDLE_UNLOAD:
            unload_model()


def parse_multipart(body: bytes, boundary: bytes) -> dict:
    """Разбор multipart вручную. Готовых разборщиков в стандартной библиотеке
    для этого случая нет (cgi выпилен в 3.13), а тянуть зависимость ради трёх
    полей — лишнее."""
    out = {}
    sep = b"--" + boundary
    for part in body.split(sep):
        if not part.strip() or part.strip() == b"--":
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        if not _:
            head, _, data = part.partition(b"\n\n")
        name = None
        for line in head.split(b"\n"):
            if b"name=" in line:
                name = line.split(b'name="')[1].split(b'"')[0].decode()
                break
        if name:
            # Срезается РОВНО один служебный перевод строки — тот, что стоит
            # перед следующей границей. `rstrip` здесь был бы ошибкой: в конце
            # WAV вполне могут оказаться байты 0x0D и 0x0A как часть звука, и
            # файл приезжал бы обрезанным. Поймано тестом на настоящем теле
            # запроса: 38 байт вместо 40.
            if data.endswith(b"\r\n"):
                data = data[:-2]
            elif data.endswith(b"\n"):
                data = data[:-1]
            out[name] = data
    return out


def to_wav(samples, rate: int) -> bytes:
    import numpy as np
    x = np.asarray(samples, dtype="float32").reshape(-1)
    pcm = (np.clip(x, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _status(self):
        return {"engine": "cosyvoice2", "loaded": _model is not None,
                "device": _device, "model": os.path.basename(MODEL_DIR),
                "idle_unload_sec": IDLE_UNLOAD}

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/health", "/status"):
            self._json(self._status())
        else:
            self._json({"error": "not_found"}, 404)

    def do_POST(self):
        path = self.path.rstrip("/")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n)
            if path == "/unload":
                unload_model()
                self._json(self._status())
                return
            if path == "/config":
                self._json(self._status())
                return
            # Два режима клонирования, как в официальном сервере CosyVoice:
            #   zero_shot     — образец плюс его расшифровка;
            #   cross_lingual — образец без расшифровки, для текста на другом
            #                   языке, чем говорит образец.
            # Второй нужен именно там, где первый начинает частить: голос
            # английский, а говорить надо по-русски.
            if path not in ("/inference_zero_shot", "/inference_cross_lingual"):
                self._json({"error": "not_found"}, 404)
                return
            cross = path == "/inference_cross_lingual"

            ctype = self.headers.get("Content-Type", "")
            if "boundary=" not in ctype:
                self._json({"error": "expected multipart"}, 400)
                return
            boundary = ctype.split("boundary=")[1].strip().encode()
            fields = parse_multipart(body, boundary)
            text = fields.get("tts_text", b"").decode("utf-8", "replace")
            prompt = fields.get("prompt_text", b"").decode("utf-8", "replace")
            ref = fields.get("prompt_wav", b"")
            try:
                speed = float(fields.get("speed", b"1.0") or 1.0)
            except ValueError:
                speed = 1.0
            if not text or not ref:
                self._json({"error": "tts_text and prompt_wav required"}, 400)
                return

            # Образец отдаём ФАЙЛОМ, а не готовым звуком. В этой версии
            # CosyVoice inference_zero_shot ждёт путь и открывает его сам —
            # причём дважды, на 16 и на 24 кГц. Тензор здесь давал «Invalid
            # file», а объект в памяти не годится: после первого чтения он
            # остаётся прочитанным до конца.
            import numpy as np
            import soundfile as sf
            data, sr = sf.read(io.BytesIO(ref), dtype="float32", always_2d=True)
            if sr < 16000:
                # load_wav внутри библиотеки отказывается повышать частоту, а
                # ниже 16 кГц образцы приходят от старых микрофонов.
                import torch
                import torchaudio
                t = torch.from_numpy(np.ascontiguousarray(data.T))
                t = torchaudio.transforms.Resample(sr, 16000)(t)
                data, sr = t.numpy().T, 16000

            import tempfile
            fd, ref_path = tempfile.mkstemp(suffix=".wav", dir="/tmp")
            os.close(fd)
            try:
                sf.write(ref_path, data, sr, subtype="PCM_16")
                model = load_model()
                global _last_use
                _last_use = time.time()
                chunks = []
                if cross:
                    gen = model.inference_cross_lingual(text, ref_path,
                                                        stream=False,
                                                        speed=speed)
                else:
                    gen = model.inference_zero_shot(text, prompt, ref_path,
                                                    stream=False, speed=speed)
                for out in gen:
                    chunks.append(out["tts_speech"].reshape(-1).cpu().numpy())
            finally:
                try:
                    os.unlink(ref_path)
                except OSError:
                    pass
            audio = np.concatenate(chunks) if chunks else np.zeros(1, "float32")
            data = to_wav(audio, model.sample_rate)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:  # ошибка синтеза не должна ронять сервер
            log(f"ошибка: {e}")
            try:
                self._json({"error": str(e)}, 500)
            except Exception:
                pass


if __name__ == "__main__":
    threading.Thread(target=idle_watch, daemon=True).start()
    log(f"слушаю порт {PORT}, модель {MODEL_DIR}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
