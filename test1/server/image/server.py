"""Генерация картинок на станции. Контракт зеркалит синтез голоса — приложение
уже умеет так разговаривать, второго диалекта заводить незачем:

    GET  /  |  /health          -> JSON: загружена ли модель, чем считает
    POST /load                  -> занять видеопамять заранее
    POST /unload                -> освободить видеопамять
    POST /generate              -> JSON {prompt, negative, steps, width,
                                          height, seed} -> PNG

Выгрузка тут не роскошь, а условие работы: на станции одна карта, и языковая
модель с генератором на ней не помещаются. Приложение выгружает языковую модель
перед открытием студии и возвращает после — этот сервер обязан уметь ту же
вежливость со своей стороны.
"""
import io
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_PATH = os.environ.get("IMG_MODEL", "/models/checkpoint.safetensors")
PORT = int(os.environ.get("IMG_PORT", "8770"))
# Через сколько секунд простоя отдавать видеопамять обратно. 0 — держать.
IDLE_UNLOAD = float(os.environ.get("IMG_IDLE_UNLOAD", "600"))

_lock = threading.Lock()
_pipe = None
_last_use = 0.0
_device = "неизвестно"


def log(msg: str) -> None:
    print(f"[img] {msg}", flush=True)


def load_pipe():
    global _pipe, _device
    with _lock:
        if _pipe is not None:
            return _pipe
        import torch
        from diffusers import StableDiffusionXLPipeline
        if not os.path.isfile(MODEL_PATH):
            raise RuntimeError(f"нет файла модели: {MODEL_PATH}")
        cuda = torch.cuda.is_available()   # на ROCm это тоже True
        _device = "видеокарта" if cuda else "процессор"
        log(f"загружаю {os.path.basename(MODEL_PATH)} на {_device}")
        t0 = time.time()
        # from_single_file — потому что чекпоинты сообщества раздаются одним
        # .safetensors, а не деревом каталогов diffusers.
        pipe = StableDiffusionXLPipeline.from_single_file(
            MODEL_PATH,
            torch_dtype=torch.float16 if cuda else torch.float32,
            use_safetensors=True,
        )
        pipe = pipe.to("cuda" if cuda else "cpu")
        pipe.set_progress_bar_config(disable=True)
        _pipe = pipe
        log(f"загружено за {time.time() - t0:.1f} с")
        return _pipe


def unload_pipe() -> None:
    global _pipe
    with _lock:
        if _pipe is None:
            return
        _pipe = None
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
    if IDLE_UNLOAD <= 0:
        return
    while True:
        time.sleep(30)
        if _pipe is not None and _last_use and \
                time.time() - _last_use > IDLE_UNLOAD:
            unload_pipe()


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
        return {"engine": "sdxl", "loaded": _pipe is not None,
                "device": _device, "model": os.path.basename(MODEL_PATH),
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
            raw = self.rfile.read(n) if n else b"{}"
            if path == "/unload":
                unload_pipe()
                self._json(self._status())
                return
            if path == "/load":
                load_pipe()
                self._json(self._status())
                return
            if path != "/generate":
                self._json({"error": "not_found"}, 404)
                return

            req = json.loads(raw or b"{}")
            prompt = str(req.get("prompt") or "").strip()
            if not prompt:
                self._json({"error": "prompt required"}, 400)
                return
            # Служебный отрицательный запрос по умолчанию — то, что у этой
            # ветки моделей принято отсекать всегда.
            negative = str(req.get("negative")
                           or "lowres, bad anatomy, bad hands, text, error, "
                              "missing fingers, worst quality, low quality, "
                              "jpeg artifacts, signature, watermark")
            steps = int(req.get("steps") or 28)
            width = int(req.get("width") or 1024)
            height = int(req.get("height") or 1024)
            seed = req.get("seed")

            import torch
            pipe = load_pipe()
            global _last_use
            _last_use = time.time()
            gen = None
            if seed is not None:
                gen = torch.Generator(
                    device="cuda" if torch.cuda.is_available() else "cpu")
                gen.manual_seed(int(seed))
            t0 = time.time()
            image = pipe(prompt=prompt, negative_prompt=negative,
                         num_inference_steps=steps, width=width,
                         height=height, generator=gen).images[0]
            log(f"кадр за {time.time() - t0:.1f} с: {prompt[:60]}")
            buf = io.BytesIO()
            image.save(buf, format="PNG")
            data = buf.getvalue()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            log(f"ошибка: {e}")
            try:
                self._json({"error": str(e)}, 500)
            except Exception:
                pass


if __name__ == "__main__":
    threading.Thread(target=idle_watch, daemon=True).start()
    log(f"слушаю порт {PORT}, модель {MODEL_PATH}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
