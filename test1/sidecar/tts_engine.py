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


class TtsEngine:
    """Manager: queued playback + pluggable synthesis (Piper | pyttsx3).

    Keeps the original public API (`available`, `speak`, `stop`) so main.py is
    unchanged; adds engine/voice selection with hot-swap and pyttsx3 fallback."""

    def __init__(self, engine: str = "piper", voice: str = "",
                 voice_dir: str = "") -> None:
        self._pyttsx3 = Pyttsx3Engine()
        self._piper = PiperEngine(voice_dir, voice)
        self._desired = engine if engine in ("piper", "pyttsx3") else "piper"
        self._voice = voice or ""
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
        return {"pyttsx3": self._pyttsx3.available, "piper": self._piper.deps}

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
        self._desired = name if name in ("piper", "pyttsx3") else "piper"
        threading.Thread(target=self._apply_blocking, daemon=True).start()

    def set_voice(self, voice_dir: str | None, voice_id: str | None) -> None:
        self._voice = voice_id or ""
        self._piper.set_voice(voice_dir, voice_id)
        # Re-apply so a running Piper picks the new voice (or Piper becomes
        # available now that a voice was downloaded).
        threading.Thread(target=self._apply_blocking, daemon=True).start()

    def _apply_blocking(self) -> None:
        want = self._desired
        # Piper requested but no usable voice -> fall back to pyttsx3 quietly
        # (this is the normal "no voice downloaded yet" state).
        if want == "piper" and not self._piper.available:
            self._active = self._pyttsx3
            self._active_name = "pyttsx3"
            self._emit_status("pyttsx3", "", "ready")
            return
        if want == "pyttsx3":
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

    def _play_one(self, text: str, rate: float, volume: float, on_level) -> None:
        engine = self._active
        res = None
        try:
            res = engine.synthesize(text, rate, volume)
        except Exception:
            res = None
        # Piper failed at runtime -> drop to the system voice for this utterance
        # (and stay there) with a UI event.
        if res is None and engine is self._piper:
            self._emit_status("piper", self._voice, "error",
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

    def _play_samples(self, data, sr: int, on_level) -> bool:
        """Play mono float32 samples through sounddevice, emitting live RMS
        levels (~30/s). Returns True if playback ran, False on device error."""
        try:
            import numpy as np
            import sounddevice as sd

            data = np.asarray(data, dtype=np.float32)
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
