"""Streaming speech-to-text: mic capture + webrtcvad segmentation + faster-whisper.

The engine captures 16 kHz mono audio, uses webrtcvad to find speech segments,
emits {"type": "vad", ...} on speech start/stop, transcribes the growing buffer
periodically for {"type": "stt.partial"} and the whole segment on silence for
{"type": "stt.final"}. All heavy deps are imported lazily so the server can run
(and report capabilities) even before they are installed.
"""
from __future__ import annotations

import queue
import threading
import time

SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480
FRAME_BYTES = FRAME_SAMPLES * 2  # int16


class SttEngine:
    def __init__(self, model_size: str = "small", device: str = "cpu",
                 compute_type: str = "int8") -> None:
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._model = None
        self._available = False
        try:
            import faster_whisper  # noqa: F401
            import sounddevice  # noqa: F401
            import webrtcvad  # noqa: F401
            import numpy  # noqa: F401

            self._available = True
        except Exception:
            self._available = False

        self._running = False
        self._frames: "queue.Queue[bytes]" = queue.Queue()
        self._capture = None
        self._worker: threading.Thread | None = None
        self._on_event = None
        self._language = None

    @property
    def available(self) -> bool:
        return self._available

    def _ensure_model(self):
        if self._model is None:
            from faster_whisper import WhisperModel

            self._model = WhisperModel(
                self.model_size, device=self.device, compute_type=self.compute_type
            )
        return self._model

    def start(self, language: str | None, on_event) -> bool:
        if not self._available or self._running:
            return self._running
        self._on_event = on_event
        self._language = (language or "ru") if language != "auto" else None
        try:
            import sounddevice as sd

            self._running = True
            with self._frames.mutex:
                self._frames.queue.clear()

            def cb(indata, frames, time_info, status):  # PortAudio thread
                if self._running:
                    self._frames.put(bytes(indata))

            self._capture = sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                blocksize=FRAME_SAMPLES,
                dtype="int16",
                channels=1,
                callback=cb,
            )
            self._capture.start()
            self._worker = threading.Thread(target=self._process, daemon=True)
            self._worker.start()
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

    def _emit(self, msg: dict) -> None:
        if self._on_event is not None:
            try:
                self._on_event(msg)
            except Exception:
                pass

    def _process(self) -> None:
        import numpy as np
        import webrtcvad

        vad = webrtcvad.Vad(2)
        speech: list[bytes] = []
        speaking = False
        silence_frames = 0
        last_partial = 0.0
        SILENCE_LIMIT = int(600 / FRAME_MS)  # ~600 ms of silence ends a phrase

        while self._running:
            try:
                frame = self._frames.get(timeout=0.5)
            except queue.Empty:
                continue
            if len(frame) != FRAME_BYTES:
                continue
            try:
                is_speech = vad.is_speech(frame, SAMPLE_RATE)
            except Exception:
                is_speech = False

            if is_speech:
                if not speaking:
                    speaking = True
                    self._emit({"type": "vad", "speaking": True})
                speech.append(frame)
                silence_frames = 0
                now = time.monotonic()
                if now - last_partial > 0.8 and speech:
                    last_partial = now
                    self._transcribe(np, b"".join(speech), final=False)
            elif speaking:
                speech.append(frame)
                silence_frames += 1
                if silence_frames >= SILENCE_LIMIT:
                    speaking = False
                    self._emit({"type": "vad", "speaking": False})
                    audio = b"".join(speech)
                    speech = []
                    silence_frames = 0
                    self._transcribe(np, audio, final=True)

    def _transcribe(self, np, audio_bytes: bytes, final: bool) -> None:
        if not audio_bytes:
            return
        try:
            model = self._ensure_model()
            samples = (
                np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
            )
            segments, _ = model.transcribe(
                samples, language=self._language, beam_size=1, vad_filter=False
            )
            text = " ".join(s.text.strip() for s in segments).strip()
            if text:
                self._emit({
                    "type": "stt.final" if final else "stt.partial",
                    "text": text,
                })
        except Exception as e:  # pragma: no cover
            self._emit({"type": "error", "message": f"transcribe failed: {e}"})
