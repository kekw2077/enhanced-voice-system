"""Offline text-to-speech via pyttsx3 (Windows SAPI5).

A single worker thread plays a QUEUE of utterances back-to-back. The Dart side
speaks a reply sentence-by-sentence as the model streams it (lower perceived
latency), so utterances must NOT cut each other off — each `speak()` enqueues;
`stop()` clears the queue and interrupts the current one.

A fresh engine is created per utterance — pyttsx3's run loop is not reentrant,
and re-init avoids the "second say() never speaks" issue on Windows.
"""
from __future__ import annotations

import queue
import threading


class TtsEngine:
    def __init__(self) -> None:
        self._available = False
        try:
            import pyttsx3  # noqa: F401

            self._available = True
        except Exception:
            self._available = False
        self._queue: "queue.Queue" = queue.Queue()
        self._worker: threading.Thread | None = None
        self._stop = threading.Event()  # interrupt current + drain queue
        self._lock = threading.Lock()

    @property
    def available(self) -> bool:
        return self._available

    def speak(self, text: str, rate: float = 1.0, volume: float = 1.0,
              on_done=None, on_level=None) -> None:
        if not self._available or not text.strip():
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
        def _apply_props(engine):
            try:
                base = engine.getProperty("rate") or 200
                engine.setProperty("rate", int(base * max(0.5, min(2.0, rate))))
                engine.setProperty("volume", max(0.0, min(1.0, volume)))
            except Exception:
                pass

        played = False
        try:
            import pyttsx3

            # Preferred path: synthesize to a wav, then play it in chunks
            # through sounddevice while emitting live RMS levels — the app
            # visualizations react to the assistant's real voice.
            try:
                import os
                import tempfile

                import numpy as np
                import sounddevice as sd
                import soundfile as sf

                engine = pyttsx3.init()
                _apply_props(engine)
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
                    chunk = max(1, sr // 30)  # ~30 level updates/sec
                    stream = sd.OutputStream(
                        samplerate=sr, channels=1, dtype="float32")
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
                    played = True
            except Exception:
                played = False

            if not played and not self._stop.is_set():
                # Fallback: direct SAPI playback (no levels, but speech
                # still works if save_to_file/sounddevice misbehave).
                engine = pyttsx3.init()
                _apply_props(engine)
                engine.say(text)
                engine.runAndWait()
                engine.stop()
        except Exception:
            pass

    def stop(self) -> None:
        self._stop.set()
        # Drain any queued utterances so the worker doesn't keep speaking.
        try:
            while True:
                self._queue.get_nowait()
                self._queue.task_done()
        except queue.Empty:
            pass
