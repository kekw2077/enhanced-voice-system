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

    def speak(self, text: str, on_done=None) -> None:
        if not self._available or not text.strip():
            if on_done:
                on_done()
            return
        self.stop()
        self._stop.clear()

        def _run():
            try:
                import pyttsx3

                engine = pyttsx3.init()
                engine.say(text)
                engine.runAndWait()
                engine.stop()
            except Exception:
                pass
            finally:
                if on_done and not self._stop.is_set():
                    on_done()

        self._thread = threading.Thread(target=_run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        # pyttsx3 has no clean cross-thread stop; the daemon thread ends with
        # the current utterance. We just stop signalling on_done.
