"""Offline text-to-speech: a queued player with a pluggable synthesis engine.

Playback (a QUEUE of utterances + live RMS levels + stop) is shared; the actual
synthesis of one utterance is delegated to the ACTIVE engine:

  * PiperEngine   — sherpa-onnx VITS (natural Piper voices; needs a download).
  * Pyttsx3Engine — Windows SAPI5 via pyttsx3 (robotic, but instant, no download).

`TtsEngine` is the manager: it owns the queue/worker/playback, selects the
active engine, hot-swaps engine/voice (rolling back to pyttsx3 on failure) and
reports state via `tts.status`. Piper is preferred once a voice is installed;
pyttsx3 is the always-available fallback (used until a Piper voice is downloaded
and if Piper ever fails to load/synthesize).

The Dart side speaks a reply sentence-by-sentence as the model streams it (lower
perceived latency), so utterances must NOT cut each other off — each `speak()`
enqueues; `stop()` clears the queue and interrupts the current one.
"""
from __future__ import annotations

import hashlib
import json
import os
import queue
import threading


class BaseTtsEngine:
    """Synthesis of one utterance. Subclasses implement load/unload/synthesize;
    the queue + audio playback live in the TtsEngine manager."""

    name = "base"

    def __init__(self) -> None:
        self._loaded = False

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    @property
    def available(self) -> bool:
        return False

    def unavailable_reason(self) -> str:
        return ""

    def load(self) -> None:
        self._loaded = True

    def unload(self) -> None:
        self._loaded = False

    def synthesize(self, text: str, rate: float = 1.0, volume: float = 1.0):
        """Return (mono float32 numpy samples, sample_rate) or None on failure."""
        return None


class Pyttsx3Engine(BaseTtsEngine):
    """Windows SAPI5 via pyttsx3. Behaviour preserved from the original engine:
    a FRESH pyttsx3 instance per utterance (its run loop is not reentrant, and
    re-init avoids the 'second say() never speaks' issue on Windows)."""

    name = "pyttsx3"

    def __init__(self) -> None:
        super().__init__()
        try:
            import pyttsx3  # noqa: F401
            self._deps = True
        except Exception:
            self._deps = False

    @property
    def available(self) -> bool:
        return self._deps

    def unavailable_reason(self) -> str:
        return "" if self._deps else "pyttsx3 is not installed"

    @staticmethod
    def _apply_props(engine, rate: float, volume: float) -> None:
        try:
            base = engine.getProperty("rate") or 200
            engine.setProperty("rate", int(base * max(0.5, min(2.0, rate))))
            engine.setProperty("volume", max(0.0, min(1.0, volume)))
        except Exception:
            pass

    def synthesize(self, text: str, rate: float = 1.0, volume: float = 1.0):
        # Synthesize to a wav, then hand the samples back for shared playback.
        try:
            import tempfile

            import pyttsx3
            import soundfile as sf

            engine = pyttsx3.init()
            self._apply_props(engine, rate, volume)
            tmp = os.path.join(tempfile.gettempdir(), "evs_tts_out.wav")
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except Exception:
                pass
            engine.save_to_file(text, tmp)
            engine.runAndWait()
            engine.stop()
            if os.path.exists(tmp) and os.path.getsize(tmp) > 44:
                data, sr = sf.read(tmp, dtype="float32")
                if getattr(data, "ndim", 1) > 1:
                    data = data.mean(axis=1)
                return data, sr
        except Exception:
            pass
        return None

    def speak_direct(self, text: str, rate: float, volume: float,
                     stop_event: "threading.Event") -> None:
        """Last-resort direct SAPI playback (no levels) if synth-to-wav or the
        output stream misbehaves — speech still works."""
        try:
            import pyttsx3
            if stop_event.is_set():
                return
            engine = pyttsx3.init()
            self._apply_props(engine, rate, volume)
            engine.say(text)
            engine.runAndWait()
            engine.stop()
        except Exception:
            pass


class PiperEngine(BaseTtsEngine):
    """sherpa-onnx VITS (Piper). The voice bundle lives under `voice_dir`
    (<userdata>/models/<id>) and contains <voice>.onnx + tokens.txt +
    espeak-ng-data/. If only the downloaded .tar.bz2 is present it is extracted
    on load (then removed to save disk)."""

    name = "piper"

    def __init__(self, voice_dir: str = "", voice_id: str = "") -> None:
        super().__init__()
        self._dir = voice_dir or ""
        self._voice = voice_id or ""
        self._tts = None
        self._sr = 22050
        try:
            import sherpa_onnx  # noqa: F401
            import numpy  # noqa: F401
            self._deps = True
        except Exception:
            self._deps = False

    @property
    def deps(self) -> bool:
        return self._deps

    @property
    def voice_id(self) -> str:
        return self._voice

    def set_voice(self, voice_dir: str | None, voice_id: str | None) -> None:
        d = voice_dir or ""
        v = voice_id or ""
        if d != self._dir or v != self._voice:
            self._dir = d
            self._voice = v
            self._tts = None
            self._loaded = False

    def _find_onnx(self) -> str | None:
        if not self._dir or not os.path.isdir(self._dir):
            return None
        for root, _dirs, files in os.walk(self._dir):
            for f in files:
                if f.endswith(".onnx"):
                    return os.path.join(root, f)
        return None

    def _find_tarball(self) -> str | None:
        if not self._dir or not os.path.isdir(self._dir):
            return None
        for f in os.listdir(self._dir):
            if f.endswith(".tar.bz2"):
                return os.path.join(self._dir, f)
        return None

    def _ensure_extracted(self) -> None:
        if self._find_onnx():
            return
        tar = self._find_tarball()
        if not tar:
            return
        import tarfile
        with tarfile.open(tar, "r:bz2") as tf:
            tf.extractall(self._dir)
        try:
            os.remove(tar)  # extracted copy is authoritative; reclaim the space
        except Exception:
            pass

    def _files(self):
        onnx = self._find_onnx()
        if not onnx:
            return None
        base = os.path.dirname(onnx)
        tokens = os.path.join(base, "tokens.txt")
        data_dir = os.path.join(base, "espeak-ng-data")
        if not (os.path.exists(tokens) and os.path.isdir(data_dir)):
            return None
        return onnx, tokens, data_dir

    @property
    def available(self) -> bool:
        # Installable/usable = deps present AND either the extracted model or the
        # downloaded tarball is on disk (extraction happens lazily on load).
        if not self._deps:
            return False
        return bool(self._find_onnx() or self._find_tarball())

    def unavailable_reason(self) -> str:
        if not self._deps:
            return "sherpa-onnx is not installed"
        if not (self._find_onnx() or self._find_tarball()):
            return f"Piper voice not found in {self._dir or '(unset)'}"
        return ""

    def load(self) -> None:
        import sherpa_onnx
        self._ensure_extracted()
        files = self._files()
        if not files:
            raise FileNotFoundError(self.unavailable_reason() or "Piper voice files missing")
        onnx, tokens, data_dir = files
        cfg = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                vits=sherpa_onnx.OfflineTtsVitsModelConfig(
                    model=onnx, tokens=tokens, data_dir=data_dir),
                num_threads=2, provider="cpu",
            ),
            max_num_sentences=2,
        )
        self._tts = sherpa_onnx.OfflineTts(cfg)
        self._sr = self._tts.sample_rate
        self._loaded = True

    def unload(self) -> None:
        self._tts = None
        self._loaded = False

    def synthesize(self, text: str, rate: float = 1.0, volume: float = 1.0):
        try:
            import numpy as np
            if self._tts is None:
                self.load()
            speed = max(0.5, min(2.0, rate))  # higher rate = faster speech
            audio = self._tts.generate(text, sid=0, speed=speed)
            s = np.array(audio.samples, dtype=np.float32)
            vol = max(0.0, min(1.0, volume))
            if vol != 1.0:
                s = np.clip(s * vol, -1.0, 1.0)
            return s, audio.sample_rate
        except Exception:
            return None


class CloneWorkerEngine(BaseTtsEngine):
    """Voice-clone engine backed by an external worker process (evs_clone.exe,
    XTTS-v2 on CPU — a separate downloaded component so torch never bloats the
    base sidecar). The worker loads the model once and caches the speaker
    "fingerprint" from the reference sample; each utterance is a JSON request on
    stdin and a temp WAV path on stdout, read back here for shared playback
    (levels + FX applied by the manager). Reference re-encode is cheap; the model
    load (~15 s) happens once on first use."""

    name = "xtts"

    def __init__(self, exe: str = "", ref: str = "", lang: str = "ru") -> None:
        super().__init__()
        self._exe = exe or ""
        self._ref = ref or ""
        self._lang = lang or "ru"
        self._proc = None
        self._sr = 24000
        self._ref_set = False
        self._io_lock = threading.Lock()

    @property
    def available(self) -> bool:
        return bool(self._exe and os.path.isfile(self._exe)
                    and self._ref and os.path.isfile(self._ref))

    def unavailable_reason(self) -> str:
        if not self._exe or not os.path.isfile(self._exe):
            return "voice-clone component not installed"
        if not self._ref or not os.path.isfile(self._ref):
            return "no voice sample selected"
        return ""

    def set_config(self, exe=None, ref=None, lang=None) -> None:
        restart = False
        if exe is not None and exe != self._exe:
            self._exe = exe
            restart = True
        if ref is not None and ref != self._ref:
            self._ref = ref
            self._ref_set = False
        if lang:
            self._lang = lang
        if restart:
            self._stop_proc()

    def _send(self, obj) -> None:
        self._proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self._proc.stdin.flush()

    def _readline(self):
        line = self._proc.stdout.readline()
        if not line:
            raise RuntimeError("clone worker closed")
        return json.loads(line)

    def load(self) -> None:
        import subprocess
        if self._proc is not None and self._proc.poll() is None:
            return
        if not self.available:
            raise FileNotFoundError(self.unavailable_reason())
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._proc = subprocess.Popen(
            [self._exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
            bufsize=1, creationflags=flags)
        while True:  # drain until the model is loaded
            r = self._readline()
            if r.get("event") == "ready":
                if not r.get("ok"):
                    raise RuntimeError(r.get("err", "clone worker load failed"))
                self._sr = int(r.get("sr", 24000))
                break
        self._ensure_ref()
        self._loaded = True

    def _ensure_ref(self) -> None:
        if self._ref_set:
            return
        self._send({"cmd": "setref", "ref": self._ref})
        r = self._readline()
        if not r.get("ok"):
            raise RuntimeError(r.get("err", "setref failed"))
        self._ref_set = True

    def _stop_proc(self) -> None:
        p, self._proc = self._proc, None
        self._loaded = False
        self._ref_set = False
        if p is not None:
            try:
                if p.poll() is None:
                    p.stdin.write('{"cmd":"quit"}\n')
                    p.stdin.flush()
            except Exception:
                pass
            try:
                p.terminate()
            except Exception:
                pass

    def unload(self) -> None:
        self._stop_proc()

    def synthesize(self, text: str, rate: float = 1.0, volume: float = 1.0):
        import tempfile
        import time

        import numpy as np
        import soundfile as sf
        with self._io_lock:
            try:
                if self._proc is None or self._proc.poll() is not None:
                    self.load()
                self._ensure_ref()
                out = os.path.join(
                    tempfile.gettempdir(),
                    "evs_clone_%d.wav" % (int(time.time() * 1000) % 1000000))
                self._send({"cmd": "synth", "text": text, "out": out,
                            "lang": self._lang,
                            "speed": max(0.5, min(2.0, rate))})
                r = self._readline()
                if not r.get("ok") or not os.path.exists(out):
                    return None
                data, sr = sf.read(out, dtype="float32")
                try:
                    os.remove(out)
                except Exception:
                    pass
                if getattr(data, "ndim", 1) > 1:
                    data = data.mean(axis=1)
                vol = max(0.0, min(1.0, volume))
                if vol != 1.0:
                    data = np.clip(data * vol, -1.0, 1.0)
                return data, sr
            except Exception:
                self._stop_proc()  # force a clean respawn next time
                return None


class CosyVoiceEngine(BaseTtsEngine):
    """Voice clone via an external CosyVoice HTTP server (GPU workstation). No
    local model — synthesis is a POST to `endpoint` returning WAV bytes. Shares
    the manager's phrase cache exactly like the XTTS engine, so pre-rendered
    phrases play instantly regardless of which cloning engine is active.

    Expected zero-shot contract (official CosyVoice FastAPI, adjust per server):
      POST {endpoint}/inference_zero_shot
      form: tts_text, prompt_text, prompt_wav=@sample.wav  -> audio/wav stream.
    Best-effort: any failure returns None so the manager falls back."""

    name = "cosyvoice"

    def __init__(self, endpoint: str = "", ref: str = "",
                 prompt_text: str = "", speed: float = 1.0) -> None:
        super().__init__()
        self._endpoint = (endpoint or "").rstrip("/")
        self._ref = ref or ""
        self._prompt = prompt_text or ""
        self._speed = speed or 1.0

    @property
    def available(self) -> bool:
        return bool(self._endpoint and self._ref and os.path.isfile(self._ref))

    def unavailable_reason(self) -> str:
        if not self._endpoint:
            return "CosyVoice server endpoint not set"
        if not self._ref or not os.path.isfile(self._ref):
            return "no voice sample selected"
        return ""

    def set_config(self, endpoint=None, ref=None, prompt_text=None,
                   speed=None) -> None:
        if endpoint is not None:
            self._endpoint = endpoint.rstrip("/")
        if ref is not None:
            self._ref = ref
        if prompt_text is not None:
            self._prompt = prompt_text
        if speed is not None:
            self._speed = speed

    def load(self) -> None:
        if not self.available:
            raise RuntimeError(self.unavailable_reason())
        self._loaded = True

    def synthesize(self, text: str, rate: float = 1.0, volume: float = 1.0):
        import io as _io
        import urllib.request

        import numpy as np
        import soundfile as sf
        try:
            with open(self._ref, "rb") as f:
                wav_bytes = f.read()
            boundary = "----evsCosy%d" % (threading.get_ident() & 0xffffff)
            parts = []

            def field(name, value):
                parts.append(("--" + boundary).encode())
                parts.append(
                    ('Content-Disposition: form-data; name="%s"\r\n' % name)
                    .encode())
                parts.append(str(value).encode("utf-8"))

            field("tts_text", text)
            field("prompt_text", self._prompt)
            field("speed", self._speed)
            parts.append(("--" + boundary).encode())
            parts.append(
                b'Content-Disposition: form-data; name="prompt_wav"; '
                b'filename="ref.wav"\r\nContent-Type: audio/wav\r\n')
            parts.append(wav_bytes)
            parts.append(("--" + boundary + "--").encode())
            body = b"\r\n".join(parts) + b"\r\n"
            req = urllib.request.Request(
                self._endpoint + "/inference_zero_shot", data=body,
                headers={"Content-Type":
                         "multipart/form-data; boundary=" + boundary})
            with urllib.request.urlopen(req, timeout=120) as resp:
                audio = resp.read()
            data, sr = sf.read(_io.BytesIO(audio), dtype="float32")
            if getattr(data, "ndim", 1) > 1:
                data = data.mean(axis=1)
            vol = max(0.0, min(1.0, volume))
            if vol != 1.0:
                data = np.clip(data * vol, -1.0, 1.0)
            return data, sr
        except Exception:
            return None


class TtsEngine:
    """Manager: queued playback + pluggable synthesis (Piper | pyttsx3 | clone).

    Keeps the original public API (`available`, `speak`, `stop`) so main.py is
    unchanged; adds engine/voice selection with hot-swap and pyttsx3 fallback.
    Cloning engines (xtts, cosyvoice) share an engine-agnostic phrase cache:
    pre-rendered / previously-spoken phrases play instantly from disk."""

    def __init__(self, engine: str = "piper", voice: str = "",
                 voice_dir: str = "") -> None:
        self._pyttsx3 = Pyttsx3Engine()
        self._piper = PiperEngine(voice_dir, voice)
        self._clone = CloneWorkerEngine()      # xtts (external worker)
        self._cosy = CosyVoiceEngine()         # cosyvoice (external HTTP server)
        self._engines = {"piper": self._piper, "pyttsx3": self._pyttsx3,
                         "xtts": self._clone, "cosyvoice": self._cosy}
        self._desired = engine if engine in self._engines else "piper"
        self._voice = voice or ""
        # Engine-agnostic phrase cache (shared by xtts + cosyvoice).
        self._cache_dir = ""
        self._voice_fp = ""
        # Resolve the real starting engine: Piper only when a voice is present,
        # otherwise the always-available system voice.
        self._active: BaseTtsEngine = self._pyttsx3
        self._active_name = "pyttsx3"
        self._switching = False

        self._queue: "queue.Queue" = queue.Queue()
        self._worker: threading.Thread | None = None
        self._stop = threading.Event()  # interrupt current + drain queue
        self._lock = threading.Lock()
        self._on_event = None

    # ---- capabilities / status ----------------------------------------

    @property
    def available(self) -> bool:
        return self._pyttsx3.available or self._piper.available

    def capabilities(self) -> dict:
        return {"pyttsx3": self._pyttsx3.available, "piper": self._piper.deps,
                "xtts": self._clone.available, "cosyvoice": self._cosy.available}

    @property
    def engine_name(self) -> str:
        return self._active_name

    def bind(self, on_event) -> None:
        """Attach the connection's emit callback and apply the desired engine/
        voice (from CLI/config), reporting readiness."""
        self._on_event = on_event
        threading.Thread(target=self._apply_blocking, daemon=True).start()

    def _emit(self, msg: dict) -> None:
        if self._on_event is not None:
            try:
                self._on_event(msg)
            except Exception:
                pass

    def _emit_status(self, engine: str, voice: str, state: str,
                     message: str = "") -> None:
        msg = {"type": "tts.status", "engine": engine, "voice": voice,
               "state": state}
        if message:
            msg["message"] = message
        self._emit(msg)

    # ---- engine / voice selection -------------------------------------

    def set_engine(self, name: str) -> None:
        self._desired = name if name in self._engines else "piper"
        threading.Thread(target=self._apply_blocking, daemon=True).start()

    def set_clone_config(self, exe=None, ref=None, lang=None) -> None:
        self._clone.set_config(exe=exe, ref=ref, lang=lang)
        if self._desired == "xtts":
            threading.Thread(target=self._apply_blocking, daemon=True).start()

    def set_cosy_config(self, endpoint=None, ref=None, prompt_text=None,
                        speed=None) -> None:
        self._cosy.set_config(endpoint=endpoint, ref=ref,
                              prompt_text=prompt_text, speed=speed)
        if self._desired == "cosyvoice":
            threading.Thread(target=self._apply_blocking, daemon=True).start()

    def set_cache(self, cache_dir=None, voice_fp=None) -> None:
        """Phrase-cache location + the active voice's fingerprint (so different
        samples / engines never share cached audio)."""
        if cache_dir is not None:
            self._cache_dir = cache_dir or ""
        if voice_fp is not None:
            self._voice_fp = voice_fp or ""

    def set_voice(self, voice_dir: str | None, voice_id: str | None) -> None:
        self._voice = voice_id or ""
        self._piper.set_voice(voice_dir, voice_id)
        # Re-apply so a running Piper picks the new voice (or Piper becomes
        # available now that a voice was downloaded).
        threading.Thread(target=self._apply_blocking, daemon=True).start()

    def _apply_blocking(self) -> None:
        want = self._desired
        if want == "pyttsx3":
            self._active = self._pyttsx3
            self._active_name = "pyttsx3"
            self._emit_status("pyttsx3", "", "ready")
            return
        # Cloning engines (xtts worker / cosyvoice HTTP): load with fallback to
        # the system voice, same shape as Piper below.
        if want in ("xtts", "cosyvoice"):
            eng = self._engines[want]
            if not eng.available:
                self._active = self._pyttsx3
                self._active_name = "pyttsx3"
                self._emit_status(want, "", "error", eng.unavailable_reason())
                self._emit_status("pyttsx3", "", "ready")
                return
            self._switching = True
            self._emit_status(want, self._voice, "loading")
            try:
                if not eng.is_loaded:
                    eng.load()
                self._active = eng
                self._active_name = want
                self._switching = False
                self._emit_status(want, self._voice, "ready")
            except Exception as e:
                self._switching = False
                self._active = self._pyttsx3
                self._active_name = "pyttsx3"
                self._emit_status(want, self._voice, "error", str(e))
                self._emit_status("pyttsx3", "", "ready")
            return
        # Piper requested but no usable voice -> fall back to pyttsx3 quietly
        # (this is the normal "no voice downloaded yet" state).
        if want == "piper" and not self._piper.available:
            self._active = self._pyttsx3
            self._active_name = "pyttsx3"
            self._emit_status("pyttsx3", "", "ready")
            return
        # Load Piper (may extract the tarball) on this bg thread.
        self._switching = True
        self._emit_status("piper", self._voice, "loading")
        try:
            if not self._piper.is_loaded:
                self._piper.load()
            self._active = self._piper
            self._active_name = "piper"
            self._switching = False
            self._emit_status("piper", self._voice, "ready")
        except Exception as e:  # rollback to the system voice
            self._switching = False
            self._active = self._pyttsx3
            self._active_name = "pyttsx3"
            self._emit_status("piper", self._voice, "error", str(e))
            self._emit_status("pyttsx3", "", "ready")

    def _fallback_to_pyttsx3(self) -> None:
        self._active = self._pyttsx3
        self._active_name = "pyttsx3"

    def preview(self, voice_dir: str, voice_id: str, text: str,
                rate: float = 1.0, volume: float = 1.0) -> None:
        """Speak a fixed sample in a specific Piper voice WITHOUT touching the
        persistent active engine/voice (TZ2 block 5). Interrupts any current
        speech, then plays the sample on a bg thread."""
        def _run() -> None:
            try:
                eng = PiperEngine(voice_dir, voice_id)
                if not eng.available:
                    self._emit_status("piper", voice_id, "error",
                                      eng.unavailable_reason())
                    return
                eng.load()
                res = eng.synthesize(text, rate, volume)
                if res is None:
                    self._emit_status("piper", voice_id, "error",
                                      "preview synthesis failed")
                    return
                # Interrupt anything speaking, then play the one-off sample.
                self.stop()
                self._stop.clear()
                self._play_samples(
                    res[0], res[1],
                    lambda v: self._emit({"type": "tts.level", "level": v}))
                self._emit({"type": "tts.done"})
            except Exception as e:
                self._emit_status("piper", voice_id, "error", str(e))
        threading.Thread(target=_run, daemon=True).start()

    # ---- queued playback ----------------------------------------------

    def speak(self, text: str, rate: float = 1.0, volume: float = 1.0,
              on_done=None, on_level=None) -> None:
        if not self.available or not text.strip():
            if on_done:
                on_done()
            return
        # A new utterance cancels any pending stop and joins the queue.
        self._stop.clear()
        self._queue.put((text, rate, volume, on_done, on_level))
        self._ensure_worker()

    def _ensure_worker(self) -> None:
        with self._lock:
            if self._worker is None or not self._worker.is_alive():
                self._worker = threading.Thread(target=self._run, daemon=True)
                self._worker.start()

    def _run(self) -> None:
        while True:
            try:
                item = self._queue.get(timeout=30)  # idle-exit after 30s
            except queue.Empty:
                return
            text, rate, volume, on_done, on_level = item
            try:
                if not self._stop.is_set():
                    self._play_one(text, rate, volume, on_level)
            finally:
                self._queue.task_done()
            # Only signal "level 0 / done" once the whole queue is drained, so
            # visualizations don't flicker to zero between sentences.
            drained = self._queue.empty()
            if drained or self._stop.is_set():
                if on_level is not None:
                    try:
                        on_level(0.0)
                    except Exception:
                        pass
            if drained and not self._stop.is_set() and on_done is not None:
                try:
                    on_done()
                except Exception:
                    pass

    # ---- shared phrase cache (xtts / cosyvoice) -----------------------

    def _is_clone(self, engine) -> bool:
        return engine is self._clone or engine is self._cosy

    def _cache_ok(self, rate: float) -> bool:
        # Cache only at natural speed — rate bakes into synthesis, so a changed
        # rate needs its own render; the common case (rate≈1.0) stays instant.
        return bool(self._cache_dir and self._voice_fp) and abs(rate - 1.0) < 0.02

    def _cache_file(self, text: str):
        lang = getattr(self._active, "_lang", "ru")
        key = "%s|%s|%s|%s" % (self._active_name, self._voice_fp, lang,
                               text.strip())
        h = hashlib.sha1(key.encode("utf-8")).hexdigest()
        folder = os.path.join(self._cache_dir, self._active_name, self._voice_fp)
        return folder, os.path.join(folder, h + ".wav")

    @staticmethod
    def _scale(data, volume: float):
        v = max(0.0, min(1.0, volume))
        if v == 1.0:
            return data
        import numpy as np
        return np.clip(np.asarray(data, dtype=np.float32) * v, -1.0, 1.0)

    @staticmethod
    def _read_wav(path):
        try:
            import numpy as np
            import soundfile as sf
            data, sr = sf.read(path, dtype="float32")
            if getattr(data, "ndim", 1) > 1:
                data = data.mean(axis=1)
            return np.asarray(data, dtype=np.float32), sr
        except Exception:
            return None

    @staticmethod
    def _store_wav(path: str, folder: str, data, sr) -> None:
        try:
            import numpy as np
            import soundfile as sf
            os.makedirs(folder, exist_ok=True)
            tmp = path + ".part"
            sf.write(tmp, np.asarray(data, dtype=np.float32), int(sr))
            os.replace(tmp, path)
        except Exception:
            pass

    def prerender(self, phrases) -> None:
        """Render a batch of fixed phrases into the cache with the active cloning
        engine so they later play instantly. Skips parametric phrases ({N}) and
        ones already cached; emits `tts.prerender` progress."""
        def _run() -> None:
            eng = self._active
            if not self._is_clone(eng) or not (self._cache_dir and self._voice_fp):
                self._emit({"type": "tts.prerender", "state": "skip",
                            "done": 0, "total": 0})
                return
            try:
                if not eng.is_loaded:
                    eng.load()
            except Exception as e:
                self._emit({"type": "tts.prerender", "state": "error",
                            "message": str(e)})
                return
            seen, uniq = set(), []
            for p in (phrases or []):
                p = (p or "").strip()
                if p and "{" not in p and p not in seen:
                    seen.add(p)
                    uniq.append(p)
            total = len(uniq)
            self._emit({"type": "tts.prerender", "state": "start",
                        "done": 0, "total": total})
            done = 0
            for p in uniq:
                if self._stop.is_set():
                    break
                folder, cf = self._cache_file(p)
                if not os.path.isfile(cf):
                    try:
                        res = eng.synthesize(p, 1.0, 1.0)
                        if res is not None:
                            self._store_wav(cf, folder, res[0], res[1])
                    except Exception:
                        pass
                done += 1
                self._emit({"type": "tts.prerender", "done": done,
                            "total": total})
            self._emit({"type": "tts.prerender", "state": "done",
                        "done": done, "total": total})
        threading.Thread(target=_run, daemon=True).start()

    def _play_one(self, text: str, rate: float, volume: float, on_level) -> None:
        engine = self._active
        res = None
        # Cloning engines: serve from / populate the shared phrase cache.
        if self._is_clone(engine) and self._cache_ok(rate):
            folder, cf = self._cache_file(text)
            if os.path.isfile(cf):
                res = self._read_wav(cf)
            if res is None:
                try:
                    res = engine.synthesize(text, 1.0, 1.0)  # natural, cacheable
                except Exception:
                    res = None
                if res is not None:
                    self._store_wav(cf, folder, res[0], res[1])
            if res is not None:
                res = (self._scale(res[0], volume), res[1])
        else:
            try:
                res = engine.synthesize(text, rate, volume)
            except Exception:
                res = None
        # Piper / clone failed at runtime -> drop to the system voice for this
        # utterance (and stay there) with a UI event.
        if res is None and (engine is self._piper or self._is_clone(engine)):
            self._emit_status(self._active_name, self._voice, "error",
                              "synthesis failed; using system voice")
            self._fallback_to_pyttsx3()
            try:
                res = self._pyttsx3.synthesize(text, rate, volume)
            except Exception:
                res = None
        played = False
        if res is not None and not self._stop.is_set():
            played = self._play_samples(res[0], res[1], on_level)
        if not played and not self._stop.is_set():
            # Last resort: direct SAPI (no levels, but speech still works).
            self._pyttsx3.speak_direct(text, rate, volume, self._stop)

    def set_fx(self, cfg) -> None:
        """Voice post-FX config (dict) applied to synth audio before playback."""
        self._fx = dict(cfg) if isinstance(cfg, dict) else None

    def _apply_fx(self, data, sr):
        fx = getattr(self, "_fx", None)
        if not fx or not fx.get("enabled"):
            return data
        try:
            return _voice_fx(data, int(sr), fx)
        except Exception:
            return data

    def _play_samples(self, data, sr: int, on_level) -> bool:
        """Play mono float32 samples through sounddevice, emitting live RMS
        levels (~30/s). Returns True if playback ran, False on device error."""
        try:
            import numpy as np
            import sounddevice as sd

            data = np.asarray(data, dtype=np.float32)
            data = self._apply_fx(data, int(sr))
            chunk = max(1, int(sr) // 30)
            stream = sd.OutputStream(samplerate=int(sr), channels=1,
                                     dtype="float32")
            stream.start()
            try:
                for i in range(0, len(data), chunk):
                    if self._stop.is_set():
                        break
                    buf = data[i:i + chunk]
                    stream.write(buf.reshape(-1, 1))
                    if on_level is not None and len(buf):
                        rms = float(np.sqrt(np.mean(buf * buf)))
                        on_level(min(1.0, rms * 8.0))
            finally:
                stream.stop()
                stream.close()
            return True
        except Exception:
            return False

    def stop(self) -> None:
        self._stop.set()
        # Drain any queued utterances so the worker doesn't keep speaking.
        try:
            while True:
                self._queue.get_nowait()
                self._queue.task_done()
        except queue.Empty:
            pass


# ---- Voice post-FX (numpy-only, vectorized; applied before playback) -------
# A configurable chain for stylised voices (e.g. an "EDI"-style synthetic AI):
# high-pass -> detuned chorus double -> flanger/ring "metallic" -> low-pass ->
# short reverb. All params come from the app via {"type":"tts.config","fx":{...}}.
def _fx_fir_lp(x, sr, fc, taps=257):
    import numpy as np
    if fc <= 0 or fc >= sr / 2:
        return x
    n = np.arange(taps) - (taps - 1) / 2.0
    h = np.sinc(2 * fc / sr * n) * np.hamming(taps)
    h = (h / np.sum(h)).astype(np.float32)
    return np.convolve(x, h, mode="same").astype(np.float32)


def _fx_fir_hp(x, sr, fc, taps=257):
    import numpy as np
    if fc <= 20:
        return x
    n = np.arange(taps) - (taps - 1) / 2.0
    lp = np.sinc(2 * fc / sr * n) * np.hamming(taps)
    lp = lp / np.sum(lp)
    h = -lp
    h[(taps - 1) // 2] += 1.0
    return np.convolve(x, h.astype(np.float32), mode="same").astype(np.float32)


def _fx_delay_wet(x, sr, base_ms, depth_ms, rate_hz):
    """Time-varying fractional delay (single read tap) -> chorus/flanger wet."""
    import numpy as np
    n = len(x)
    t = np.arange(n) / sr
    d = (base_ms + depth_ms * np.sin(2 * np.pi * rate_hz * t)) * sr / 1000.0
    idx = np.arange(n) - d
    i0 = np.floor(idx).astype(np.int64)
    frac = (idx - i0).astype(np.float32)
    i0c = np.clip(i0, 0, n - 1)
    i1c = np.clip(i0 + 1, 0, n - 1)
    wet = x[i0c] * (1 - frac) + x[i1c] * frac
    wet[idx < 0] = 0.0
    return wet.astype(np.float32)


def _fx_reverb(x, sr, decay=0.6):
    """FIR reverb: convolve with a synthetic exponentially-decaying-noise IR."""
    import numpy as np
    L = max(1, int(sr * decay))
    rng = np.random.default_rng(1234)
    env = np.exp(-np.arange(L) / (sr * decay * 0.33)).astype(np.float32)
    ir = rng.standard_normal(L).astype(np.float32) * env
    ir[0] = 1.0
    ir /= (np.sqrt(np.sum(ir * ir)) + 1e-9)
    N = 1
    while N < len(x) + L:
        N <<= 1
    y = np.fft.irfft(np.fft.rfft(x, N) * np.fft.rfft(ir, N), N)[:len(x)]
    return y.astype(np.float32)


def _voice_fx(data, sr, fx):
    """Apply the configured voice FX to a mono float32 buffer. Best-effort:
    returns the input unchanged on any error."""
    import numpy as np
    x = np.asarray(data, dtype=np.float32).copy()
    if x.size == 0:
        return data
    hp = float(fx.get("highpass", 110.0))
    lp = float(fx.get("lowpass", 3000.0))
    detune = max(0.0, min(1.0, float(fx.get("detune", 0.0))))
    metallic = max(0.0, min(1.0, float(fx.get("metallic", 0.0))))
    rev = max(0.0, min(1.0, float(fx.get("reverb", 0.0))))
    ring_hz = float(fx.get("ringHz", 80.0))
    if hp > 20:
        x = _fx_fir_hp(x, sr, hp)
    if detune > 0.001:
        # two slightly different detuned "voices" -> synthetic AI doubling
        a = _fx_delay_wet(x, sr, 18.0, 6.0, 0.7)
        b = _fx_delay_wet(x, sr, 25.0, 9.0, 1.1)
        x = ((1.0 - 0.5 * detune) * x + 0.5 * detune * (a + b)).astype(np.float32)
    if metallic > 0.001:
        f = _fx_delay_wet(x, sr, 2.5, 2.0, 0.35)  # short flanger
        x = ((1.0 - 0.5 * metallic) * x + 0.5 * metallic * f).astype(np.float32)
        t = np.arange(len(x)) / sr
        car = np.sin(2 * np.pi * ring_hz * t).astype(np.float32)
        x = (x * (1.0 - 0.25 * metallic) + (x * car) * (0.25 * metallic)).astype(np.float32)
    if lp < sr / 2:
        x = _fx_fir_lp(x, sr, lp)
    if rev > 0.001:
        w = _fx_reverb(x, sr, 0.6)
        sc = (np.sqrt(np.mean(x * x)) + 1e-9) / (np.sqrt(np.mean(w * w)) + 1e-9)
        x = (x * (1.0 - 0.5 * rev) + w * sc * (0.5 * rev)).astype(np.float32)
    pk = float(np.max(np.abs(x))) + 1e-9
    if pk > 0.99:
        x = (x * (0.99 / pk)).astype(np.float32)
    return x
