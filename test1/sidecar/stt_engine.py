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
    supports_gpu = False

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
    supports_gpu = True  # ctranslate2 CUDA path (TZ2 block 6)

    def __init__(self, model_size: str = "small", device: str = "cpu",
                 compute_type: str = "int8") -> None:
        super().__init__()
        self.model_size = model_size
        self.device = device  # desired device: cpu | cuda
        self.compute_type = compute_type
        self._device_active = "cpu"  # what actually loaded (after fallback)
        self._fell_back = False  # cuda requested but dropped to cpu
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

    @property
    def device_active(self) -> str:
        return self._device_active

    @property
    def fell_back(self) -> bool:
        return self._fell_back

    def set_device(self, device: str) -> None:
        """Switch cpu<->cuda; reloads lazily on next transcription."""
        device = "cuda" if device == "cuda" else "cpu"
        if device != self.device:
            self.device = device
            self._model = None
            self._loaded = False

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
        if self._model is not None:
            return self._model
        from faster_whisper import WhisperModel
        self._fell_back = False
        # The greedy warmup can fire the instant the model finishes downloading,
        # when the just-written model.bin isn't yet openable ("Unable to open
        # file 'model.bin'"). Retry a few times so a cold first-run download race
        # doesn't wedge STT until an app restart.
        last_err = None
        for attempt in range(4):
            try:
                if self.device == "cuda":
                    # Try CUDA; on any init failure (no driver / VRAM / cuDNN)
                    # fall back to CPU so the pipeline never dies (TZ2 block 6).
                    try:
                        self._model = WhisperModel(
                            self.model_size, device="cuda",
                            compute_type=self.compute_type)
                        self._device_active = "cuda"
                        self._loaded = True
                        return self._model
                    except Exception:
                        self._fell_back = True
                self._model = WhisperModel(
                    self.model_size, device="cpu",
                    compute_type=self.compute_type)
                self._device_active = "cpu"
                self._loaded = True
                return self._model
            except Exception as e:
                last_err = e
                time.sleep(2.0)  # let the download/file settle, then retry
        raise last_err

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
    supports_gpu = False  # sherpa-onnx ships CPU-only wheels — selector hidden

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


class _SegmentArbiter:
    """Dedups one phrase heard by several mics (TZ2 block 8.2). Segments whose
    end times fall within OVERLAP_S are treated as the same utterance — the
    loudest (best SNR = closest mic) wins and the rest are dropped BEFORE
    recognition. A segment is only released once SETTLE_S has passed since it
    ended, so a slightly-later competitor from another mic can still compete.
    Pure/time-injectable so the logic can be unit-tested without audio."""

    OVERLAP_S = 1.5
    SETTLE_S = 0.6

    def __init__(self) -> None:
        self._pending: list[dict] = []

    def submit(self, label: str, audio: bytes, energy: float,
               t_end: float) -> None:
        self._pending.append(
            {"label": label, "audio": audio, "energy": energy, "t_end": t_end})

    def flush(self, now: float) -> list:
        """Return winner segments whose settle window has elapsed."""
        if not any(now - s["t_end"] >= self.SETTLE_S for s in self._pending):
            return []
        winners = []
        used: list[int] = []
        # Oldest-ended first so groups form deterministically.
        for s in sorted(self._pending, key=lambda x: x["t_end"]):
            if id(s) in used or now - s["t_end"] < self.SETTLE_S:
                continue
            group = [o for o in self._pending
                     if abs(o["t_end"] - s["t_end"]) <= self.OVERLAP_S]
            winner = max(group, key=lambda o: o["energy"])
            winners.append(winner)
            used.extend(id(o) for o in group)
        self._pending = [s for s in self._pending if id(s) not in used]
        return winners


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

        # Compute device (TZ2 block 6/7): the user's desired device vs a
        # temporary game-mode CPU force. Effective = cpu if forced else desired.
        self._desired_device = "cuda" if device == "cuda" else "cpu"
        self._forced_cpu = False

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

        # Multi-mic capture + arbitration (TZ2 block 8.2). Empty/one mic keeps
        # the single-stream path; these stay idle then.
        self._channels: list[dict] = []
        self._arbiter: _SegmentArbiter | None = None
        self._recent: dict[str, float] = {}  # text -> last emit (2 s cooldown)

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
            # Which engines have a usable GPU path (TZ2 block 6). Only Whisper
            # here; sherpa-onnx (GigaAM) is CPU-only in this build.
            "whisper_gpu": WhisperEngine.supports_gpu,
            "gigaam_gpu": GigaAmEngine.supports_gpu,
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
                if want == "whisper":
                    self._emit_device()
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

    # ---- compute device (cpu | cuda) — TZ2 block 6/7 -------------------

    def effective_device(self) -> str:
        return "cpu" if self._forced_cpu else self._desired_device

    def set_device(self, device: str) -> None:
        """The user's desired STT device. Applied immediately unless game mode
        is currently forcing CPU (then it's remembered for when it lifts)."""
        self._desired_device = "cuda" if device == "cuda" else "cpu"
        self._apply_device()

    def force_cpu(self, on: bool) -> None:
        """Game mode parks GPU engines on the CPU without touching the user's
        saved device (TZ2 block 7)."""
        if on == self._forced_cpu:
            return
        self._forced_cpu = on
        self._apply_device()

    def _apply_device(self) -> None:
        dev = self.effective_device()
        if dev == self._whisper.device and self._whisper.is_loaded:
            return
        self._whisper.set_device(dev)
        if self._engine_name == "whisper":
            threading.Thread(target=self._reload_whisper_device,
                             daemon=True).start()

    def _reload_whisper_device(self) -> None:
        try:
            self._emit_status("whisper", "loading")
            self._whisper.load()
            self._emit_status("whisper", "ready")
            self._emit_device()
        except Exception as e:
            self._emit_status("whisper", "error", str(e))

    def _emit_device(self) -> None:
        self._emit({
            "type": "stt.device",
            "engine": "whisper",
            "requested": self._whisper.device,
            "active": self._whisper.device_active,
            "fell_back": self._whisper.fell_back,
        })

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

    @staticmethod
    def _normalize_mics(devices, device) -> list:
        """[(label, denoise_mode), ...] from the `devices` list (block 8.2) or
        the single `device`, deduped by label (one physical device seen twice
        must not be captured twice)."""
        mics = []
        if devices:
            for d in devices:
                if isinstance(d, dict):
                    mics.append((str(d.get("label", "")).strip(),
                                 str(d.get("denoise", "off"))))
                elif str(d).strip():
                    mics.append((str(d).strip(), "off"))
        if not mics and device:
            mics.append((str(device), "off"))
        seen: set = set()
        out = []
        for lbl, dn in mics:
            key = lbl.lower()
            if key in seen or not lbl:
                continue
            seen.add(key)
            out.append((lbl, dn))
        return out

    def start(self, language: str | None, on_event,
              device: str | None = None, prompt: str | None = None,
              devices=None) -> bool:
        if not self.available or self._running:
            return self._running
        self._on_event = on_event
        self._whisper.set_language(language)
        if prompt is not None:
            self.set_prompt(prompt)
        # TZ2 block 8.2: >1 active mic -> multi-channel capture + arbitration;
        # 0/1 mic keeps the original single-stream path unchanged.
        mics = self._normalize_mics(devices, device)
        if len(mics) > 1:
            return self._start_multi(mics)
        if mics:
            device = mics[0][0]
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
        for ch in self._channels:
            try:
                s = ch.get("stream")
                if s is not None:
                    s.stop()
                    s.close()
            except Exception:
                pass
        self._channels = []
        self._arbiter = None

    # ---- one-shot offline transcription (network voice commands) -------

    def transcribe_pcm(self, np, pcm_i16: bytes) -> str:
        """Recognize a COMPLETE utterance handed over as 16 kHz mono int16 PCM.

        No mic capture and no VAD — this is the entry point for voice commands
        arriving over the network (settings-TZ §14: POST /command/voice). The
        active engine is loaded on demand by its own `transcribe` (Whisper via
        `_ensure_model`, GigaAM checks `self._rec`), so a cold call still works
        even before the greedy warmup has finished. Returns the recognized text
        (possibly empty when the audio held no speech)."""
        if not pcm_i16:
            return ""
        return self._active.transcribe(np, pcm_i16, final=True)

    # ---- multi-mic capture + arbitration (TZ2 block 8.2) --------------

    def _start_multi(self, mics: list) -> bool:
        try:
            import sounddevice as sd

            self._running = True
            self._arbiter = _SegmentArbiter()
            self._channels = []
            self._recent = {}
            for label, dn_mode in mics:
                q: "queue.Queue[bytes]" = queue.Queue()
                den = Denoiser(self._denoiser._root)
                den.set_mode(dn_mode)
                ch = {"label": label, "frames": q, "denoiser": den,
                      "stream": None}

                def make_cb(qq):
                    def cb(indata, frames, time_info, status):
                        if self._running:
                            if qq.qsize() > self._MAX_QUEUED_FRAMES:
                                try:
                                    qq.get_nowait()
                                except Exception:
                                    pass
                            qq.put(bytes(indata))
                    return cb

                stream = sd.RawInputStream(
                    samplerate=SAMPLE_RATE, blocksize=FRAME_SAMPLES,
                    dtype="int16", channels=1,
                    device=self._resolve_input_device(label),
                    callback=make_cb(q))
                stream.start()
                ch["stream"] = stream
                self._channels.append(ch)
                threading.Thread(target=self._process_channel, args=(ch,),
                                 daemon=True).start()
            threading.Thread(target=self._arbiter_loop, daemon=True).start()
            log_stage(f"multi-mic capture opened ({len(mics)} devices)")
            self._emit_status(
                self._engine_name,
                "ready" if self._active.available else "error",
                "" if self._active.available else self._active.unavailable_reason(),
            )
            return True
        except Exception as e:  # pragma: no cover
            self._running = False
            self._emit({"type": "error",
                        "message": f"multi-mic start failed: {e}"})
            return False

    def _process_channel(self, ch: dict) -> None:
        """One mic's capture->denoise->VAD, emitting finalized segments (finals
        only, with voice energy) to the arbiter — behaviour mirrors _process."""
        import numpy as np
        import webrtcvad

        vad = webrtcvad.Vad(3)
        speech: list[bytes] = []
        speaking = False
        silence = 0
        e_sum = 0.0
        e_n = 0
        SILENCE_LIMIT = int(600 / FRAME_MS)
        MAX_SPEECH_FRAMES = int(12_000 / FRAME_MS)
        RMS_GATE = 0.010

        def finalize():
            nonlocal speech, speaking, silence, e_sum, e_n
            speaking = False
            audio = b"".join(speech)
            energy = (e_sum / e_n) if e_n else 0.0
            speech = []
            silence = 0
            e_sum = 0.0
            e_n = 0
            if audio and self._arbiter is not None:
                self._arbiter.submit(ch["label"], audio, energy, time.monotonic())

        while self._running:
            try:
                raw = ch["frames"].get(timeout=0.5)
            except queue.Empty:
                continue
            if len(raw) != FRAME_BYTES:
                continue
            for frame in ch["denoiser"].process(np, raw):
                samples = np.frombuffer(frame, dtype=np.int16)
                rms = float(np.sqrt(np.mean((samples / 32768.0) ** 2)))
                try:
                    is_speech = \
                        rms >= RMS_GATE and vad.is_speech(frame, SAMPLE_RATE)
                except Exception:
                    is_speech = False
                if is_speech:
                    speaking = True
                    speech.append(frame)
                    silence = 0
                    e_sum += rms
                    e_n += 1
                    if len(speech) >= MAX_SPEECH_FRAMES:
                        finalize()
                elif speaking:
                    speech.append(frame)
                    silence += 1
                    if silence >= SILENCE_LIMIT:
                        finalize()

    def _arbiter_loop(self) -> None:
        import numpy as np
        while self._running:
            time.sleep(0.15)
            if self._arbiter is None or self._switching:
                continue
            for seg in self._arbiter.flush(time.monotonic()):
                try:
                    t0 = time.monotonic()
                    text = self._active.transcribe(np, seg["audio"], True)
                    latency = int((time.monotonic() - t0) * 1000)
                except Exception as e:  # pragma: no cover
                    self._emit({"type": "error",
                                "message": f"transcribe failed: {e}"})
                    continue
                if not text:
                    continue
                # 2 s cooldown on identical text (same phrase via two mics that
                # both won their overlap groups) — execute a command once.
                now = time.monotonic()
                if now - self._recent.get(text, 0.0) < 2.0:
                    continue
                self._recent[text] = now
                self._emit({"type": "stt.final", "text": text,
                            "latency_ms": latency, "device": seg["label"]})

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
