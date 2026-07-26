"""Local GPU voice-clone server for EVS (Qwen3-TTS on CUDA).

Replaces the removed CPU XTTS cloner. Runs in YOUR python venv (not frozen into
the sidecar) so the heavy CUDA/torch stack stays out of the installer, and speaks
the SAME zero-shot HTTP contract EVS already implements (`CosyVoiceEngine` in
tts_engine.py) — so EVS needs no new engine to talk to it:

    GET  /                        -> {ok, loaded, paused, vram_used_mb, ...}
    POST /inference_zero_shot     multipart: tts_text, prompt_text, speed,
                                  prompt_wav=@ref.wav            -> audio/wav
    POST /config   {json}         -> apply GPU-load settings live
    POST /unload                  -> free VRAM right now (game mode)

GPU-load control (the point of this server): there is no driver-level "use 50% of
the GPU" knob, so load is shaped by four real levers, all driven from EVS
settings:

  * idle unload   — drop the model out of VRAM after N idle seconds (0 = never).
                    While unloaded the GPU is completely free.
  * vram cap      — torch.cuda.set_per_process_memory_fraction(): a hard ceiling
                    on what this process may allocate.
  * throttle      — sleep proportionally after each synthesis (duty cycle), so
                    average utilisation drops at the cost of latency.
  * paused        — EVS flips this when its game mode engages: the server unloads
                    and answers 503, and EVS falls back to its phrase cache/Piper.

Usage (in the venv, once):
    pip install -U qwen-tts soundfile numpy
    # torch with CUDA, e.g.:
    pip install torch --index-url https://download.pytorch.org/whl/cu124
    python qwen_tts_server.py --port 8760

Then in EVS: Настройки → Голос → движок «Клон (сервер)», адрес
http://127.0.0.1:8760, и выбрать образец голоса (WAV).
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_MODEL = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"
DEFAULT_PORT = 8760


def _log(msg: str) -> None:
    print(f"[qwen-tts] {msg}", file=sys.stderr, flush=True)


def resolve_cache_dir(explicit: str = "") -> str:
    """Where model weights (~4 GB) are downloaded.

    EVS keeps ALL its data on the drive it is installed on, never the system
    drive — so this must never fall back to the HuggingFace default
    (%USERPROFILE%\\.cache\\huggingface on C:). Order:
      1. --cache-dir
      2. EVS_QWEN_CACHE
      3. EVS_USERDATA\\components\\hf-cache  (shares the sidecar's Whisper cache)
      4. a detected EVS install next to this script's drive
      5. <this script's folder>\\hf-cache
    """
    for cand in (explicit, os.environ.get("EVS_QWEN_CACHE", "")):
        if cand and cand.strip():
            return os.path.abspath(cand.strip())
    userdata = os.environ.get("EVS_USERDATA", "").strip()
    if userdata:
        return os.path.join(os.path.abspath(userdata), "components", "hf-cache")
    here = os.path.dirname(os.path.abspath(__file__))
    drive = os.path.splitdrive(here)[0] or ""
    if drive:
        guess = os.path.join(drive + os.sep, "EVS", "userdata", "components",
                             "hf-cache")
        if os.path.isdir(os.path.dirname(guess)):
            return guess
    return os.path.join(here, "hf-cache")


def pin_cache_to(cache_dir: str) -> None:
    """Point every library that caches to disk at `cache_dir`. MUST run before
    torch / transformers / qwen_tts are imported — they read these at import."""
    os.makedirs(cache_dir, exist_ok=True)
    os.environ["HF_HOME"] = cache_dir
    os.environ["HF_HUB_CACHE"] = os.path.join(cache_dir, "hub")
    # NB: do NOT set TRANSFORMERS_CACHE. It is deprecated, and pointing it at
    # cache_dir (a level above HF_HUB_CACHE) makes transformers resolve model
    # sub-modules against a SECOND, separate cache tree: the weights get
    # re-downloaded into <cache>/models--… while the real snapshot sits in
    # <cache>/hub/models--…, and loading then dies on a missing sub-module
    # ("Can't load feature extractor for …/speech_tokenizer"). HF_HOME already
    # implies <cache>/hub for every HF library.
    os.environ.pop("TRANSFORMERS_CACHE", None)
    os.environ["TORCH_HOME"] = os.path.join(cache_dir, "torch")
    os.environ["XDG_CACHE_HOME"] = cache_dir
    # Big temp files (model shards being written) must not land on C: either.
    tmp = os.path.join(cache_dir, "tmp")
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMP"] = tmp
    os.environ["TEMP"] = tmp


# --------------------------------------------------------------------------
# Engine: lazy load, idle unload, VRAM cap, throttle.
# --------------------------------------------------------------------------
class QwenTtsEngine:
    def __init__(self, model_id: str = DEFAULT_MODEL) -> None:
        self.model_id = model_id
        self._model = None
        self._lock = threading.Lock()   # serialises synthesis (one job at a time)
        self._last_used = 0.0
        self._loading = False

        # Live-tunable settings (pushed by EVS via POST /config).
        self.language = "Russian"
        self.precision = "auto"        # auto | bf16 | fp16
        self.vram_fraction = 0.0       # 0 = no cap; else 0.05..1.0
        self.idle_unload_sec = 120     # 0 = never unload
        self.throttle = 0.0            # 0..1 — fraction of synth time to sleep
        self.paused = False            # game mode

        self._stop = threading.Event()
        threading.Thread(target=self._idle_loop, daemon=True).start()

    # ---- state ----------------------------------------------------------
    @property
    def loaded(self) -> bool:
        return self._model is not None

    def vram_used_mb(self) -> int:
        try:
            import torch
            if not torch.cuda.is_available():
                return 0
            return int(torch.cuda.memory_reserved(0) / (1024 * 1024))
        except Exception:
            return 0

    def status(self) -> dict:
        return {
            "ok": True,
            "name": "qwen-tts",
            "model": self.model_id,
            "loaded": self.loaded,
            "loading": self._loading,
            "paused": self.paused,
            "vram_used_mb": self.vram_used_mb(),
            "language": self.language,
            "precision": self.precision,
            "vram_fraction": self.vram_fraction,
            "idle_unload_sec": self.idle_unload_sec,
            "throttle": self.throttle,
        }

    # ---- config ---------------------------------------------------------
    def apply_config(self, cfg: dict) -> None:
        if "language" in cfg and cfg["language"]:
            self.language = str(cfg["language"])
        if "precision" in cfg and cfg["precision"]:
            p = str(cfg["precision"]).lower()
            if p in ("auto", "bf16", "fp16") and p != self.precision:
                self.precision = p
                self.unload()  # dtype only applies at load time
        if "idle_unload_sec" in cfg:
            try:
                self.idle_unload_sec = max(0, int(cfg["idle_unload_sec"]))
            except Exception:
                pass
        if "throttle" in cfg:
            try:
                self.throttle = min(1.0, max(0.0, float(cfg["throttle"])))
            except Exception:
                pass
        if "vram_fraction" in cfg:
            try:
                f = float(cfg["vram_fraction"])
                f = 0.0 if f <= 0 else min(1.0, max(0.05, f))
            except Exception:
                f = self.vram_fraction
            if f != self.vram_fraction:
                self.vram_fraction = f
                self._apply_vram_cap()
        if "paused" in cfg:
            paused = bool(cfg["paused"])
            self.paused = paused
            if paused:
                # Game mode: give the VRAM back immediately.
                self.unload()
        _log(f"config: {self.status()}")

    def _apply_vram_cap(self) -> None:
        if self.vram_fraction <= 0:
            return
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.set_per_process_memory_fraction(
                    self.vram_fraction, 0)
                _log(f"vram cap -> {self.vram_fraction:.2f} of device 0")
        except Exception as e:
            _log(f"vram cap failed: {e}")

    # ---- load / unload --------------------------------------------------
    def _load(self) -> None:
        if self._model is not None:
            return
        import torch
        from qwen_tts import Qwen3TTSModel

        self._loading = True
        try:
            self._apply_vram_cap()
            if self.precision == "fp16":
                dtype = torch.float16
            elif self.precision == "bf16":
                dtype = torch.bfloat16
            else:  # auto: bf16 when supported (Ampere+), else fp16
                dtype = (torch.bfloat16
                         if getattr(torch.cuda, "is_bf16_supported", lambda: False)()
                         else torch.float16)
            device = "cuda:0" if torch.cuda.is_available() else "cpu"
            _log(f"loading {self.model_id} on {device} ({dtype})…")
            t0 = time.time()
            kwargs = dict(device_map=device, dtype=dtype)
            try:
                # FlashAttention-2 is a big win but is rarely installed on
                # Windows; fall back to the default attention silently.
                self._model = Qwen3TTSModel.from_pretrained(
                    self.model_id, attn_implementation="flash_attention_2",
                    **kwargs)
            except Exception:
                self._model = Qwen3TTSModel.from_pretrained(
                    self.model_id, **kwargs)
            # Start the idle clock NOW. It defaults to 0.0, so without this the
            # idle thread sees "unused since epoch" and evicts the model the
            # moment it appears — every single phrase would then pay the full
            # ~15 s reload.
            self._last_used = time.time()
            _log(f"ready in {time.time() - t0:.1f}s")
        finally:
            self._loading = False

    def unload(self) -> None:
        with self._lock:
            if self._model is None:
                return
            self._model = None
            try:
                import gc
                import torch
                gc.collect()
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except Exception:
                pass
            _log("unloaded (VRAM released)")

    def _idle_loop(self) -> None:
        while not self._stop.wait(5.0):
            try:
                if (self.idle_unload_sec > 0 and self._model is not None
                        and not self._loading and self._last_used > 0
                        and time.time() - self._last_used > self.idle_unload_sec):
                    _log(f"idle > {self.idle_unload_sec}s")
                    self.unload()
            except Exception:
                pass

    # ---- synthesis ------------------------------------------------------
    def synthesize(self, text: str, ref_wav: bytes, ref_text: str,
                   language: str = "") -> tuple[bytes, int]:
        """Returns (wav_bytes, sample_rate). Raises on failure."""
        import numpy as np
        import soundfile as sf

        # The model takes a path/URL/base64/ndarray — hand it a decoded array so
        # nothing touches the disk per request.
        data, sr_in = sf.read(io.BytesIO(ref_wav), dtype="float32")
        if getattr(data, "ndim", 1) > 1:
            data = data.mean(axis=1)

        # Without a transcript of the reference clip the model can only clone the
        # TIMBRE (x-vector mode); its in-context mode hard-fails with "ref_text is
        # required when x_vector_only_mode=False". EVS treats the transcript as
        # optional, so pick the mode that matches what we were actually given —
        # supplying it (Настройки → образец голоса) gives the better clone.
        ref_text = (ref_text or "").strip()
        x_only = not ref_text
        with self._lock:
            t0 = time.time()
            self._load()
            wavs, sr = self._model.generate_voice_clone(
                text=text,
                language=language or self.language,
                ref_audio=(data, sr_in),
                ref_text=ref_text or None,
                x_vector_only_mode=x_only,
            )
            self._last_used = time.time()
            elapsed = self._last_used - t0

        wav = wavs[0] if hasattr(wavs, "__len__") and len(wavs) else wavs
        wav = np.asarray(wav, dtype=np.float32)
        buf = io.BytesIO()
        sf.write(buf, wav, int(sr), format="WAV", subtype="PCM_16")

        # Duty-cycle throttle: idle the GPU for a share of the time we just spent
        # on it, so sustained speech can't hog the card.
        if self.throttle > 0:
            time.sleep(min(5.0, elapsed * self.throttle))
        return buf.getvalue(), int(sr)


ENGINE: QwenTtsEngine | None = None


# --------------------------------------------------------------------------
# Minimal multipart/form-data parser (stdlib `cgi` is gone in 3.13).
# --------------------------------------------------------------------------
def parse_multipart(body: bytes, boundary: str) -> dict:
    out: dict = {}
    sep = b"--" + boundary.encode()
    for chunk in body.split(sep):
        if not chunk or chunk in (b"--\r\n", b"--", b"\r\n"):
            continue
        chunk = chunk.lstrip(b"\r\n")
        head, _, value = chunk.partition(b"\r\n\r\n")
        if not _:
            continue
        headers = head.decode("utf-8", "replace")
        name = ""
        for part in headers.split(";"):
            part = part.strip()
            if part.startswith('name="'):
                name = part[6:].split('"')[0]
                break
        if not name:
            continue
        value = value.rstrip(b"\r\n")
        if "filename=" in headers:
            out[name] = value               # binary payload
        else:
            out[name] = value.decode("utf-8", "replace")
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter default logging
        pass

    # ---- helpers --------------------------------------------------------
    def _json(self, obj: dict, status: int = 200) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    # ---- routes ---------------------------------------------------------
    def do_GET(self):
        # EVS probes the endpoint root for reachability (checkCosyvoice).
        if self.path in ("/", "/health", "/status"):
            self._json(ENGINE.status())
        else:
            self._json({"error": "not_found"}, 404)

    def do_POST(self):
        try:
            if self.path.rstrip("/") == "/config":
                cfg = json.loads(self._read_body() or b"{}")
                ENGINE.apply_config(cfg if isinstance(cfg, dict) else {})
                self._json(ENGINE.status())
                return
            if self.path.rstrip("/") == "/unload":
                ENGINE.unload()
                self._json(ENGINE.status())
                return
            if self.path.rstrip("/") == "/inference_zero_shot":
                self._synth()
                return
            self._json({"error": "not_found"}, 404)
        except Exception as e:
            _log("request failed:\n" + traceback.format_exc())
            try:
                self._json({"error": str(e)}, 500)
            except Exception:
                pass

    def _synth(self) -> None:
        if ENGINE.paused:
            # Game mode: tell EVS we're unavailable so it uses cache/Piper.
            self._json({"error": "paused"}, 503)
            return
        ctype = self.headers.get("Content-Type", "")
        if "boundary=" not in ctype:
            self._json({"error": "expected multipart/form-data"}, 400)
            return
        boundary = ctype.split("boundary=", 1)[1].strip().strip('"')
        form = parse_multipart(self._read_body(), boundary)
        text = (form.get("tts_text") or "").strip()
        ref_wav = form.get("prompt_wav") or b""
        ref_text = form.get("prompt_text") or ""
        language = form.get("language") or ""
        if not text:
            self._json({"error": "empty tts_text"}, 400)
            return
        if not ref_wav:
            self._json({"error": "missing prompt_wav"}, 400)
            return
        # NOTE: `speed` is accepted for contract compatibility but ignored —
        # EVS only caches/plays clone audio at rate 1.0.
        wav, _sr = ENGINE.synthesize(text, ref_wav, ref_text, language)
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.end_headers()
        self.wfile.write(wav)


def main() -> int:
    global ENGINE
    ap = argparse.ArgumentParser(description="EVS GPU voice-clone server (Qwen3-TTS)")
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("EVS_QWEN_PORT", DEFAULT_PORT)))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--model", default=os.environ.get("EVS_QWEN_MODEL", DEFAULT_MODEL))
    ap.add_argument("--language", default="Russian")
    ap.add_argument("--precision", default="auto", choices=["auto", "bf16", "fp16"])
    ap.add_argument("--vram-fraction", type=float, default=0.0,
                    help="hard VRAM cap as a fraction of the card (0 = none)")
    ap.add_argument("--idle-unload", type=int, default=120,
                    help="release VRAM after N idle seconds (0 = never)")
    ap.add_argument("--throttle", type=float, default=0.0,
                    help="0..1 — sleep this share of the synthesis time after each job")
    ap.add_argument("--preload", action="store_true",
                    help="load the model at startup instead of on first request")
    ap.add_argument("--cache-dir", default="",
                    help="where model weights are stored (default: the EVS data "
                         "folder on the install drive — never C:\\Users\\...)")
    args = ap.parse_args()

    # MUST happen before torch / qwen_tts are imported anywhere.
    cache = resolve_cache_dir(args.cache_dir)
    pin_cache_to(cache)
    _log(f"model cache: {cache}")

    ENGINE = QwenTtsEngine(args.model)
    ENGINE.apply_config({
        "language": args.language,
        "precision": args.precision,
        "vram_fraction": args.vram_fraction,
        "idle_unload_sec": args.idle_unload,
        "throttle": args.throttle,
    })
    if args.preload:
        try:
            ENGINE._load()
        except Exception:
            _log("preload failed:\n" + traceback.format_exc())

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    _log(f"listening on http://{args.host}:{args.port}  (model: {args.model})")
    _log("point EVS at this address: Настройки → Голос → Клон (сервер)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        ENGINE.unload()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
