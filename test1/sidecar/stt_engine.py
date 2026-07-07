"""Streaming speech-to-text: mic capture + webrtcvad segmentation + a pluggable
recognition engine.

Capture (16 kHz mono) and webrtcvad segmentation are shared; the actual
recognition of a speech segment is delegated to the ACTIVE engine:

  * WhisperEngine — faster-whisper (multilingual, partial + final results).
  * GigaAmEngine  — sherpa-onnx NeMo transducer (Russian, offline: FINAL only).

`SttEngine` is the manager: it owns capture + VAD + the active engine, hot-swaps
engines (unload old -> load new, rollback on error), and reports state via
`stt.engine_status`. All heavy deps are imported lazily so the server can run
(and report capabilities) even before they are installed.
"""
from __future__ import annotations

import os
import queue
import sys
import threading
import time

SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480
FRAME_BYTES = FRAME_SAMPLES * 2  # int16

# Backend-readiness state machine (TZ3.4). Emitted to the client as
# {"type": "stt.state", "state": ...} so the UI can show a loading orb /
# "Загружаюсь…" line and speak the ready greeting exactly once per launch.
STATE_STARTING = "starting"
STATE_LOADING = "loading_models"
STATE_READY = "ready"
STATE_ERROR = "error"

# Cold-start diagnostics (TZ3.4 §4.1): timestamped stage log on stderr, which
# Flutter captures into userdata/logs/sidecar.log. Lets us see where the seconds
# go on a cold boot (backend start → audio stream → VAD → model load → warmup).
_PROC_T0 = time.monotonic()


def log_stage(stage: str) -> None:
    try:
        dt = time.monotonic() - _PROC_T0
        print(f"[evs-stt +{dt:6.2f}s] {stage}", file=sys.stderr, flush=True)
    except Exception:
        pass

# HuggingFace repo the GigaAM-v3 sherpa-onnx model is published under — surfaced
# in the "model not found" error so the app/user knows where to fetch it.
GIGAAM_HF_REPO = "csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16"
GIGAAM_FILES = ("encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt")

# Default Whisper decoding primer (Russian command vocabulary). Biases the
# decoder toward the words the assistant actually expects. The Dart side may
# override this via `stt.start`/`stt.config` (wake word + vocabulary).
_DEFAULT_PROMPT = (
    "Ирис. Открой, закрой, запусти, останови, включи, выключи, найди, "
    "поставь, громкость, яркость, скриншот, музыка, браузер, блокнот, "
    "стоп, хватит."
)


class BaseSttEngine:
    """Recognition of one VAD-delimited segment. Subclasses implement load/
    unload/transcribe; capture and VAD live in the SttEngine manager."""

    name = "base"
    supports_partial = True

    def __init__(self) -> None:
        self._loaded = False

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    @property
    def available(self) -> bool:
        """True if this engine can run right now (deps + any model files)."""
        return False

    def unavailable_reason(self) -> str:
        return ""

    def load(self) -> None:
        self._loaded = True

    def unload(self) -> None:
        self._loaded = False

    def set_prompt(self, prompt: str | None) -> None:
        pass

    def set_model(self, model_size: str) -> None:
        pass

    def transcribe(self, np, audio_bytes: bytes, final: bool) -> str:
        return ""


class WhisperEngine(BaseSttEngine):
    """faster-whisper — behaviour preserved verbatim from the original SttEngine
    (partials on the tail, wide-beam finals, silero VAD pass, hallucination
    filter)."""

    name = "whisper"
    supports_partial = True

    def __init__(self, model_size: str = "small", device: str = "cpu",
                 compute_type: str = "int8") -> None:
        super().__init__()
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._model = None
        self._prompt: str | None = _DEFAULT_PROMPT
        self._language = None
        try:
            import faster_whisper  # noqa: F401
            import numpy  # noqa: F401
            self._deps = True
        except Exception:
            self._deps = False

    @property
    def available(self) -> bool:
        return self._deps

    def unavailable_reason(self) -> str:
        return "" if self._deps else "faster-whisper is not installed"

    def set_language(self, language: str | None) -> None:
        self._language = (language or "ru") if language != "auto" else None

    def set_model(self, model_size: str) -> None:
        """Switch the Whisper model size; reloads lazily on next transcription."""
        if model_size and model_size != self.model_size:
            self.model_size = model_size
            self._model = None
            self._loaded = False

    def set_prompt(self, prompt: str | None) -> None:
        p = (prompt or "").strip()
        self._prompt = p if p else _DEFAULT_PROMPT

    def load(self) -> None:
        self._ensure_model()

    def unload(self) -> None:
        self._model = None
        self._loaded = False

    def _ensure_model(self):
        if self._model is None:
            from faster_whisper import WhisperModel
            self._model = WhisperModel(
                self.model_size, device=self.device,
                compute_type=self.compute_type,
            )
            self._loaded = True
        return self._model

    # Whisper's signature hallucinations on noise/near-silence (it was
    # trained on subtitles): anything matching these is dropped outright.
    _HALLUCINATION_MARKERS = (
        "субтитр", "подписывайтесь", "продолжение следует", "редактор",
        "корректор", "amara.org", "амара.орг", "dimatorzok",
        "thanks for watching", "субтитры делал", "♪",
    )

    @classmethod
    def _hallucinated(cls, text: str) -> bool:
        low = text.lower()
        return any(m in low for m in cls._HALLUCINATION_MARKERS)

    def transcribe(self, np, audio_bytes: bytes, final: bool) -> str:
        model = self._ensure_model()
        samples = (
            np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        )
        # Finals get a silero VAD pass inside faster-whisper: it strips
        # non-speech, so noise segments mostly return empty instead of
        # hallucinated subtitle credits. Finals also use a wider beam +
        # temperature fallback for accuracy (they're infrequent, so the
        # extra CPU is fine); partials stay cheap/raw for low latency.
        segments, _ = model.transcribe(
            samples,
            language=self._language,
            beam_size=5 if final else 1,
            temperature=[0.0, 0.2, 0.4] if final else 0.0,
            initial_prompt=self._prompt,
            vad_filter=final,
            condition_on_previous_text=False,
        )
        text = " ".join(s.text.strip() for s in segments).strip()
        if text and self._hallucinated(text):
            return ""
        return text


class GigaAmEngine(BaseSttEngine):
    """sherpa-onnx NeMo transducer (GigaAM-v3, Russian). Offline recognition —
    no partials; emits FINAL results only. Model files live in `model_dir`."""

    name = "gigaam"
    supports_partial = False

    def __init__(self, model_dir: str | None = None) -> None:
        super().__init__()
        self._dir = model_dir or ""
        self._rec = None
        try:
            import sherpa_onnx  # noqa: F401
            import numpy  # noqa: F401
            self._deps = True
        except Exception:
            self._deps = False

    def set_dir(self, model_dir: str | None) -> None:
        d = model_dir or ""
        if d != self._dir:
            self._dir = d
            self._rec = None
            self._loaded = False

    def _files_present(self) -> bool:
        if not self._dir:
            return False
        return all(os.path.exists(os.path.join(self._dir, f)) for f in GIGAAM_FILES)

    @property
    def available(self) -> bool:
        return self._deps and self._files_present()

    def unavailable_reason(self) -> str:
        if not self._deps:
            return "sherpa-onnx is not installed"
        if not self._dir:
            return "GigaAM model path is not set"
        missing = [f for f in GIGAAM_FILES
                   if not os.path.exists(os.path.join(self._dir, f))]
        if missing:
            return (f"GigaAM model not found in {self._dir} "
                    f"(missing: {', '.join(missing)}). "
                    f"Download from HuggingFace: {GIGAAM_HF_REPO}")
        return ""

    def load(self) -> None:
        import sherpa_onnx
        if not self._files_present():
            raise FileNotFoundError(self.unavailable_reason())
        self._rec = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=os.path.join(self._dir, "encoder.int8.onnx"),
            decoder=os.path.join(self._dir, "decoder.onnx"),
            joiner=os.path.join(self._dir, "joiner.onnx"),
            tokens=os.path.join(self._dir, "tokens.txt"),
            num_threads=2,
            sample_rate=SAMPLE_RATE,
            feature_dim=80,
            decoding_method="greedy_search",
            model_type="nemo_transducer",
        )
        self._loaded = True

    def unload(self) -> None:
        self._rec = None
        self._loaded = False

    def transcribe(self, np, audio_bytes: bytes, final: bool) -> str:
        # Offline recognition has no meaningful partial — only decode finals.
        if not final:
            return ""
        if self._rec is None:
            self.load()
        samples = (
            np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        )
        stream = self._rec.create_stream()
        stream.accept_waveform(SAMPLE_RATE, samples)
        self._rec.decode_stream(stream)
        return (stream.result.text or "").strip()


class Denoiser:
    """Streaming noise suppression applied BEFORE the VAD, via sherpa-onnx
    OnlineSpeechDenoiser (16 kHz, frame-by-frame, state kept across calls):

      * off    — bypass (raw audio);
      * light  — GTCRN (~0.5 MB, tiny CPU, low latency);
      * strong — DeepFilterNet (~8 MB, heavier, stronger).

    Models live under <models_root>/denoise-gtcrn/ and /denoise-df/ (downloaded
    via the app's model manager). Fail-safe: any load/run error drops to off and
    reports it — the pipeline keeps running on raw audio.
    """

    def __init__(self, models_root: str = "") -> None:
        self._root = models_root or ""
        self._mode = "off"
        self._den = None
        self._buf = None  # numpy float32 re-chunk buffer
        self._on_status = None

    def bind(self, on_status) -> None:
        self._on_status = on_status

    def _emit(self, state: str, message: str = "") -> None:
        if self._on_status is not None:
            try:
                self._on_status(self._mode, state, message)
            except Exception:
                pass

    def set_root(self, root: str) -> None:
        self._root = root or ""

    def _gtcrn_path(self) -> str:
        return os.path.join(self._root, "denoise-gtcrn", "gtcrn_simple.onnx") \
            if self._root else ""

    def _dfn_path(self) -> str:
        return os.path.join(self._root, "denoise-df", "dpdfnet_baseline.onnx") \
            if self._root else ""

    @property
    def mode(self) -> str:
        return self._mode if self._den is not None else "off"

    def available(self, mode: str) -> bool:
        if mode == "off":
            return True
        try:
            import sherpa_onnx  # noqa: F401
        except Exception:
            return False
        if mode == "light":
            p = self._gtcrn_path()
        elif mode == "strong":
            p = self._dfn_path()
        else:
            return False
        return bool(p and os.path.exists(p))

    def set_mode(self, mode: str) -> None:
        import numpy as np
        mode = mode if mode in ("off", "light", "strong") else "off"
        if mode == "off":
            self._den = None
            self._mode = "off"
            self._buf = None
            self._emit("ready")
            return
        if not self.available(mode):
            self._den = None
            self._mode = "off"
            self._emit("error", f"{mode} denoise model not found")
            return
        try:
            import sherpa_onnx
            cfg = sherpa_onnx.OnlineSpeechDenoiserConfig()
            if mode == "light":
                cfg.model.gtcrn = sherpa_onnx.OfflineSpeechDenoiserGtcrnModelConfig(
                    model=self._gtcrn_path())
            else:
                cfg.model.dpdfnet = \
                    sherpa_onnx.OfflineSpeechDenoiserDpdfNetModelConfig(
                        model=self._dfn_path())
            cfg.model.num_threads = 1
            self._den = sherpa_onnx.OnlineSpeechDenoiser(cfg)
            self._mode = mode
            self._buf = np.zeros(0, dtype=np.float32)
            self._emit("ready")
        except Exception as e:
            self._den = None
            self._mode = "off"
            self._emit("error", str(e))

    def reset(self) -> None:
        import numpy as np
        if self._buf is not None:
            self._buf = np.zeros(0, dtype=np.float32)

    # Feed one raw 480-sample int16 frame; return 0+ denoised 480-sample int16
    # frames (the denoiser buffers internally, so the count per call varies).
    def process(self, np, frame_bytes: bytes) -> list:
        if self._den is None:
            return [frame_bytes]
        try:
            samples = (
                np.frombuffer(frame_bytes, dtype=np.int16).astype(np.float32)
                / 32768.0
            )
            r = self._den.run(samples, SAMPLE_RATE)
            if len(r.samples):
                self._buf = np.concatenate(
                    [self._buf, np.array(r.samples, dtype=np.float32)])
            out = []
            while len(self._buf) >= FRAME_SAMPLES:
                chunk = self._buf[:FRAME_SAMPLES]
                self._buf = self._buf[FRAME_SAMPLES:]
                out.append(
                    (np.clip(chunk, -1.0, 1.0) * 32767).astype(np.int16).tobytes())
            return out
        except Exception as e:
            # Fail-safe: drop to off and pass raw audio through.
            self._den = None
            self._mode = "off"
            self._emit("error", f"denoise failed: {e}")
            return [frame_bytes]


class SttEngine:
    """Manager: mic capture + webrtcvad segmentation, delegating recognition to
    the active engine. Keeps the original constructor signature; adds
    engine selection (whisper|gigaam) and hot-swapping."""

    def __init__(self, model_size: str = "small", device: str = "cpu",
                 compute_type: str = "int8", engine: str = "whisper",
                 gigaam_dir: str | None = None, denoise: str = "off",
                 denoise_dir: str = "") -> None:
        self._whisper = WhisperEngine(model_size, device, compute_type)
        self._gigaam = GigaAmEngine(gigaam_dir)
        self._desired = engine if engine in ("whisper", "gigaam") else "whisper"
        self._engine_name = "whisper"
        self._active: BaseSttEngine = self._whisper
        self._switching = False

        self._denoiser = Denoiser(denoise_dir)
        self._desired_denoise = \
            denoise if denoise in ("off", "light", "strong") else "off"

        # Cold-start readiness state machine (TZ3.4). `_warmed` guards the greedy
        # load + warmup so it runs once per PROCESS, not once per reconnect —
        # the ready greeting must fire exactly once per launch.
        self._state = STATE_STARTING
        self._warmed = False
        self._warm_lock = threading.Lock()

        self._running = False
        self._frames: "queue.Queue[bytes]" = queue.Queue()
        self._capture = None
        self._worker: threading.Thread | None = None
        self._on_event = None

    # ---- capabilities / availability -----------------------------------

    @property
    def available(self) -> bool:
        # Baseline STT availability = the always-present Whisper path plus the
        # capture stack (sounddevice/webrtcvad).
        try:
            import sounddevice  # noqa: F401
            import webrtcvad  # noqa: F401
        except Exception:
            return False
        return self._whisper.available

    def capabilities(self) -> dict:
        return {
            "whisper": self._whisper.available,
            "gigaam": self._gigaam.available,
        }

    @property
    def engine_name(self) -> str:
        return self._engine_name

    # ---- emitter binding (for engine_status outside of start/stop) ------

    def bind(self, on_event) -> None:
        """Attach the current connection's emit callback and kick off the greedy
        model load + warmup (TZ3.4). Runs on a bg thread so the WS handler stays
        responsive; the load/warmup happens once per process, later reconnects
        just re-report the current state to the fresh client."""
        self._on_event = on_event
        self._denoiser.bind(self._emit_denoise_status)
        log_stage("flutter bound; scheduling greedy load + warmup")
        self.set_denoise(self._desired_denoise)
        threading.Thread(target=self._warm_up_blocking, daemon=True).start()

    def _emit(self, msg: dict) -> None:
        if self._on_event is not None:
            try:
                self._on_event(msg)
            except Exception:
                pass

    def _emit_status(self, engine: str, state: str, message: str = "") -> None:
        msg = {"type": "stt.engine_status", "engine": engine, "state": state}
        if message:
            msg["message"] = message
        self._emit(msg)

    def _emit_denoise_status(self, mode: str, state: str,
                             message: str = "") -> None:
        msg = {"type": "stt.denoise_status", "mode": mode, "state": state}
        if message:
            msg["message"] = message
        self._emit(msg)

    def _emit_state(self, state: str, message: str = "") -> None:
        self._state = state
        msg = {"type": "stt.state", "state": state}
        if message:
            msg["message"] = message
        self._emit(msg)

    # ---- cold-start: greedy load + warmup (TZ3.4) ----------------------

    def _warm_up_blocking(self) -> None:
        """Load the desired engine EAGERLY (not on first phrase) and run one
        warmup inference on a second of silence, so the first real command
        doesn't pay the model-init cost. Emits the readiness state machine
        (starting → loading_models → ready|error). Idempotent per process."""
        # Reconnect after warmup: just re-report the settled state + engine
        # status to the new client (no reload, no second ready greeting).
        if self._warmed:
            self._emit_status(
                self._engine_name,
                "ready" if self._active.available else "error",
                "" if self._active.available else self._active.unavailable_reason(),
            )
            self._emit_state(self._state)
            return
        with self._warm_lock:
            if self._warmed:
                self._emit_state(self._state)
                return
            self._emit_state(STATE_STARTING)

            # Resolve the engine to load. If the desired one (e.g. GigaAM) has no
            # model/deps, fall back to Whisper so startup still reaches `ready`.
            want = self._desired
            target = self._gigaam if want == "gigaam" else self._whisper
            if not target.available:
                if want != "whisper":
                    self._emit_status(want, "error", target.unavailable_reason())
                    log_stage(f"engine '{want}' unavailable, falling back to "
                              f"whisper: {target.unavailable_reason()}")
                want, target = "whisper", self._whisper
                if not target.available:
                    self._emit_status("whisper", "error",
                                      self._whisper.unavailable_reason())
                    self._emit_state(STATE_ERROR,
                                     self._whisper.unavailable_reason())
                    log_stage("no STT engine available; state=error")
                    return

            self._emit_state(STATE_LOADING)
            self._emit_status(want, "loading")
            try:
                t0 = time.monotonic()
                target.load()
                self._active = target
                self._engine_name = want
                log_stage(f"engine '{want}' loaded in "
                          f"{int((time.monotonic() - t0) * 1000)} ms")
                self._warm_inference(target)
                self._warmed = True
                self._emit_status(want, "ready")
                self._emit_state(STATE_READY)
                log_stage(f"state=ready (engine '{want}')")
            except Exception as e:
                self._active = self._whisper
                self._engine_name = "whisper"
                self._emit_status(want, "error", str(e))
                self._emit_state(STATE_ERROR, str(e))
                log_stage(f"warmup failed: {e}; state=error")

    def _warm_inference(self, engine: "BaseSttEngine") -> None:
        """Run one throwaway final decode on ~1 s of silence to page in the
        graph / allocate buffers. Best-effort — never fatal to readiness."""
        try:
            import numpy as np
            t0 = time.monotonic()
            engine.transcribe(np, b"\x00" * (SAMPLE_RATE * 2), final=True)
            log_stage(f"warmup inference {int((time.monotonic() - t0) * 1000)} ms")
        except Exception as e:
            log_stage(f"warmup inference skipped: {e}")

    # ---- denoise ------------------------------------------------------

    def set_denoise(self, mode: str) -> None:
        self._desired_denoise = \
            mode if mode in ("off", "light", "strong") else "off"
        # Model load is quick but do it off the audio/WS threads anyway.
        threading.Thread(target=self._denoiser.set_mode,
                         args=(self._desired_denoise,), daemon=True).start()

    def update_denoise_dir(self, root: str | None) -> None:
        self._denoiser.set_root(root or "")

    # ---- engine selection ----------------------------------------------

    def set_engine(self, name: str, gigaam_dir: str | None = None) -> None:
        name = name if name in ("whisper", "gigaam") else "whisper"
        self._desired = name
        if gigaam_dir:
            self._gigaam.set_dir(gigaam_dir)
        # Load on a background thread — the model load must not block the WS loop
        # or the audio stream (pausing recognition during the swap is fine).
        threading.Thread(target=self._switch_blocking, args=(name,),
                         daemon=True).start()

    def _switch_blocking(self, name: str) -> None:
        target = self._gigaam if name == "gigaam" else self._whisper
        if name == self._engine_name and target.is_loaded:
            self._emit_status(name, "ready")
            return
        if not target.available:
            # Missing deps/model files: stay on the current engine.
            self._emit_status(name, "error", target.unavailable_reason())
            return
        prev = self._active
        prev_name = self._engine_name
        self._emit_status(name, "loading")
        self._switching = True
        try:
            target.load()
            self._active = target
            self._engine_name = name
            self._switching = False
            if prev is not target:
                try:
                    prev.unload()
                except Exception:
                    pass
            self._emit_status(name, "ready")
        except Exception as e:  # rollback to the previous engine
            self._switching = False
            self._active = prev
            self._engine_name = prev_name
            self._emit_status(name, "error", str(e))

    def set_model(self, model_size: str) -> None:
        """Switch the Whisper model size (Whisper engine only)."""
        self._whisper.set_model(str(model_size))
        if self._engine_name == "whisper":
            # Reload eagerly if Whisper is active so the next phrase uses it.
            threading.Thread(target=self._switch_blocking, args=("whisper",),
                             daemon=True).start()

    def update_gigaam_dir(self, gigaam_dir: str | None) -> None:
        """Point the GigaAM engine at a (possibly newly downloaded) model dir
        without switching to it."""
        self._gigaam.set_dir(gigaam_dir)

    def set_prompt(self, prompt: str | None) -> None:
        self._whisper.set_prompt(prompt)
        self._gigaam.set_prompt(prompt)

    # ---- input device --------------------------------------------------

    @staticmethod
    def _resolve_input_device(name: str | None):
        """PortAudio input index for a Windows device label ('' = default)."""
        if not name:
            return None
        try:
            import sounddevice as sd

            want = name.strip().lower()[:28]
            if not want:
                return None
            for i, d in enumerate(sd.query_devices()):
                if d.get("max_input_channels", 0) <= 0:
                    continue
                have = str(d.get("name", "")).strip().lower()[:28]
                if have and (want in have or have in want or
                             want.startswith(have) or have.startswith(want)):
                    return i
        except Exception:
            pass
        return None

    # ---- capture lifecycle ---------------------------------------------

    _MAX_QUEUED_FRAMES = 30_000 // FRAME_MS

    def start(self, language: str | None, on_event,
              device: str | None = None, prompt: str | None = None) -> bool:
        if not self.available or self._running:
            return self._running
        self._on_event = on_event
        self._whisper.set_language(language)
        if prompt is not None:
            self.set_prompt(prompt)
        try:
            import sounddevice as sd

            self._running = True
            with self._frames.mutex:
                self._frames.queue.clear()

            def cb(indata, frames, time_info, status):  # PortAudio thread
                if self._running:
                    if self._frames.qsize() > self._MAX_QUEUED_FRAMES:
                        try:
                            self._frames.get_nowait()
                        except Exception:
                            pass
                    self._frames.put(bytes(indata))

            self._capture = sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                blocksize=FRAME_SAMPLES,
                dtype="int16",
                channels=1,
                device=self._resolve_input_device(device),
                callback=cb,
            )
            self._capture.start()
            log_stage("audio stream opened")
            self._denoiser.reset()
            self._worker = threading.Thread(target=self._process, daemon=True)
            self._worker.start()
            # Report the active engine's readiness to the client.
            self._emit_status(
                self._engine_name,
                "ready" if self._active.available else "error",
                "" if self._active.available else self._active.unavailable_reason(),
            )
            return True
        except Exception as e:  # pragma: no cover
            self._running = False
            self._emit({"type": "error", "message": f"stt start failed: {e}"})
            return False

    def stop(self) -> None:
        self._running = False
        try:
            if self._capture is not None:
                self._capture.stop()
                self._capture.close()
        except Exception:
            pass
        self._capture = None

    # ---- VAD segmentation loop (unchanged behaviour) -------------------

    def _process(self) -> None:
        import numpy as np
        import webrtcvad

        # Aggressiveness 3 (strictest): laptop mic arrays emit a constant
        # noise floor that level 2 happily labels "speech" — the segment then
        # NEVER closes, stt.final never fires and the assistant looks dead
        # (observed live: 150 s of nonstop partials, zero finals).
        vad = webrtcvad.Vad(3)
        log_stage("VAD loaded")
        first_frame = True
        speech: list[bytes] = []
        speaking = False
        silence_frames = 0
        last_partial = 0.0
        SILENCE_LIMIT = int(600 / FRAME_MS)  # ~600 ms of silence ends a phrase
        MAX_SPEECH_FRAMES = int(12_000 / FRAME_MS)  # force a final after 12 s
        PARTIAL_TAIL_FRAMES = int(5_000 / FRAME_MS)  # partials: last 5 s only
        # Noise gate on top of VAD — silence on some mics still passes VAD and
        # Whisper then hallucinates subtitle credits out of it.
        RMS_GATE = 0.010

        def finalize():
            nonlocal speech, speaking, silence_frames
            speaking = False
            self._emit({"type": "vad", "speaking": False})
            audio = b"".join(speech)
            speech = []
            silence_frames = 0
            self._transcribe(np, audio, final=True)

        while self._running:
            try:
                raw = self._frames.get(timeout=0.5)
            except queue.Empty:
                continue
            if len(raw) != FRAME_BYTES:
                continue
            if first_frame:
                first_frame = False
                log_stage("first audio frame processed")
            # Denoise BEFORE the VAD — the denoiser buffers internally, so one
            # raw frame yields 0+ cleaned 480-sample frames (off = passthrough).
            for frame in self._denoiser.process(np, raw):
                samples = np.frombuffer(frame, dtype=np.int16)
                rms = float(np.sqrt(np.mean((samples / 32768.0) ** 2)))
                try:
                    is_speech = \
                        rms >= RMS_GATE and vad.is_speech(frame, SAMPLE_RATE)
                except Exception:
                    is_speech = False

                if is_speech:
                    if not speaking:
                        speaking = True
                        self._emit({"type": "vad", "speaking": True})
                    speech.append(frame)
                    silence_frames = 0
                    if len(speech) >= MAX_SPEECH_FRAMES:
                        finalize()
                        continue
                    now = time.monotonic()
                    if now - last_partial > 0.8 and speech:
                        last_partial = now
                        # Re-transcribing the WHOLE buffer every 0.8 s is what
                        # melts the CPU on long segments — partials only need the
                        # recent tail (they're just live feedback for the pill).
                        tail = speech[-PARTIAL_TAIL_FRAMES:]
                        self._transcribe(np, b"".join(tail), final=False)
                elif speaking:
                    speech.append(frame)
                    silence_frames += 1
                    if silence_frames >= SILENCE_LIMIT:
                        finalize()

    def _transcribe(self, np, audio_bytes: bytes, final: bool) -> None:
        if not audio_bytes:
            return
        # Pause recognition while an engine swap is in flight.
        if self._switching:
            return
        engine = self._active
        # Offline engines (GigaAM) have no partials — skip them entirely.
        if not final and not engine.supports_partial:
            return
        try:
            t0 = time.monotonic()
            text = engine.transcribe(np, audio_bytes, final)
            latency_ms = int((time.monotonic() - t0) * 1000)
            if text:
                msg = {
                    "type": "stt.final" if final else "stt.partial",
                    "text": text,
                }
                if final:
                    msg["latency_ms"] = latency_ms
                self._emit(msg)
        except Exception as e:  # pragma: no cover
            self._emit({"type": "error", "message": f"transcribe failed: {e}"})
