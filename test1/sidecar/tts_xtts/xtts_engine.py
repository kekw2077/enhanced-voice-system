"""XTTS v2 voice-cloning engine (Coqui TTS).

Loads the multilingual XTTS v2 model and synthesizes speech in a target voice
cloned from a short reference wav (~6-10 s). Heavy: needs torch + the ~1.8 GB
model, which downloads on first load into the TTS cache (TTS_HOME / the app
data folder, set by the launcher). All heavy imports are lazy so the server can
report capabilities even before the deps are present.

License note: XTTS v2 ships under the Coqui Public Model License (CPML),
non-commercial. Fine for personal use.
"""
from __future__ import annotations

import os
import tempfile
import threading


class XttsEngine:
    def __init__(self) -> None:
        self._available = False
        self.init_error: str | None = None
        try:
            import torch  # noqa: F401
            from TTS.api import TTS  # noqa: F401
            import sounddevice  # noqa: F401
            import soundfile  # noqa: F401

            self._available = True
        except Exception:
            self._available = False
            import traceback
            self.init_error = traceback.format_exc()
        self._tts = None
        self._speaker_wav: str | None = None
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    @property
    def available(self) -> bool:
        return self._available

    @property
    def loaded(self) -> bool:
        return self._tts is not None

    def load(self) -> bool:
        if not self._available:
            return False
        with self._lock:
            if self._tts is not None:
                return True
            try:
                import torch
                from TTS.api import TTS

                device = "cuda" if torch.cuda.is_available() else "cpu"
                self._tts = TTS(
                    "tts_models/multilingual/multi-dataset/xtts_v2"
                ).to(device)
                return True
            except Exception:
                self._tts = None
                return False

    def set_speaker(self, wav_path: str) -> bool:
        if wav_path and os.path.exists(wav_path):
            self._speaker_wav = wav_path
            return True
        return False

    def speak(self, text: str, language: str = "ru",
              on_done=None, on_error=None, on_level=None) -> None:
        if not self._available or not text.strip():
            if on_done:
                on_done()
            return
        self.stop()
        self._stop.clear()

        def _run():
            try:
                if not self.load():
                    if on_error:
                        on_error("model load failed")
                    return
                if not self._speaker_wav:
                    if on_error:
                        on_error("no speaker sample")
                    return
                import numpy as np
                import sounddevice as sd
                import soundfile as sf

                lang = language if language in ("ru", "en") else "en"
                out = os.path.join(tempfile.gettempdir(), "evs_xtts_out.wav")
                with self._lock:
                    self._tts.tts_to_file(
                        text=text,
                        speaker_wav=self._speaker_wav,
                        language=lang,
                        file_path=out,
                    )
                if self._stop.is_set():
                    return
                # Chunked playback with live RMS levels so the app's voice
                # visualizations react to the cloned speech in real time.
                data, sr = sf.read(out, dtype="float32")
                if getattr(data, "ndim", 1) > 1:
                    data = data.mean(axis=1)
                chunk = max(1, sr // 30)
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
            except Exception as e:  # pragma: no cover
                if on_error:
                    on_error(str(e))
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
        try:
            import sounddevice as sd

            sd.stop()
        except Exception:
            pass
