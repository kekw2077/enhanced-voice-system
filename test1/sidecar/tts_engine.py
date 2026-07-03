"""Offline text-to-speech via pyttsx3 (Windows SAPI5).

Runs synthesis on a worker thread so the asyncio server stays responsive.
A fresh engine is created per utterance — pyttsx3's run loop is not reentrant,
and re-init avoids the "second say() never speaks" issue on Windows.
"""
from __future__ import annotations

import threading


class TtsEngine:
    def __init__(self) -> None:
        self._available = False
        try:
            import pyttsx3  # noqa: F401

            self._available = True
        except Exception:
            self._available = False
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    @property
    def available(self) -> bool:
        return self._available

    def speak(self, text: str, rate: float = 1.0, volume: float = 1.0,
              on_done=None, on_level=None) -> None:
        if not self._available or not text.strip():
            if on_done:
                on_done()
            return
        self.stop()
        self._stop.clear()

        def _apply_props(engine):
            try:
                base = engine.getProperty("rate") or 200
                engine.setProperty("rate", int(base * max(0.5, min(2.0, rate))))
                engine.setProperty("volume", max(0.0, min(1.0, volume)))
            except Exception:
                pass

        def _run():
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

                if not played:
                    # Fallback: direct SAPI playback (no levels, but speech
                    # still works if save_to_file/sounddevice misbehave).
                    engine = pyttsx3.init()
                    _apply_props(engine)
                    engine.say(text)
                    engine.runAndWait()
                    engine.stop()
            except Exception:
                pass
            finally:
                if on_level is not None:
                    try:
                        on_level(0.0)
                    except Exception:
                        pass
                if on_done and not self._stop.is_set():
                    on_done()

        self._thread = threading.Thread(target=_run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        # pyttsx3 has no clean cross-thread stop; the daemon thread ends with
        # the current utterance. We just stop signalling on_done.
