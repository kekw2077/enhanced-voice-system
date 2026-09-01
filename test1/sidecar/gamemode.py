"""Game / heavy-GPU mode (TZ2 block 7): auto-offload CUDA engines to the CPU
while a fullscreen app is in the foreground (trigger A) OR video memory is
saturated (trigger B). Two independent triggers, ONE shared offload layer.

Both triggers use two-sided hysteresis so the system doesn't flap:
  * A: the foreground window must stay fullscreen for ~5 s before it counts,
       and excluded processes (video players etc.) never count.
  * B: VRAM must be >= the enter threshold for two consecutive polls to engage,
       and stay <= the exit threshold for ~60 s to disengage (after our own
       unload frees memory, without this it would loop unload<->reload).

The layer is active while EITHER trigger is active; it lifts when both are off.
Windows-only fullscreen detection via ctypes; degrades to VRAM-only (or no-op)
elsewhere. VRAM via NVML (gpu.py) — absent NVIDIA/NVML, trigger B stays off.
"""
from __future__ import annotations

import ctypes
import sys
import threading
import time

import gpu

_POLL_S = 4.0
_FS_HOLD_S = 5.0
_VRAM_EXIT_HOLD_S = 60.0


class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


class MONITORINFO(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_ulong), ("rcMonitor", RECT),
                ("rcWork", RECT), ("dwFlags", ctypes.c_ulong)]


def _proc_name(hwnd, user32) -> str:
    try:
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if not h:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = ctypes.c_ulong(1024)
            if not k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                return ""
            return buf.value.rsplit("\\", 1)[-1].lower()
        finally:
            k32.CloseHandle(h)
    except Exception:
        return ""


def foreground_fullscreen() -> tuple[bool, str]:
    """(is_fullscreen, foreground_exe_name_lower). Non-Windows -> (False, '')."""
    if sys.platform != "win32":
        return False, ""
    try:
        user32 = ctypes.windll.user32
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return False, ""
        cls = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, cls, 256)
        # The desktop / shell is never "a fullscreen app".
        if cls.value in ("Progman", "WorkerW", "Shell_TrayWnd", "Button"):
            return False, ""
        wr = RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(wr))
        hmon = user32.MonitorFromWindow(hwnd, 2)  # NEAREST
        mi = MONITORINFO()
        mi.cbSize = ctypes.sizeof(MONITORINFO)
        user32.GetMonitorInfoW(hmon, ctypes.byref(mi))
        m = mi.rcMonitor
        if (m.right - m.left) <= 0:
            return False, ""
        full = (wr.left <= m.left and wr.top <= m.top and
                wr.right >= m.right and wr.bottom >= m.bottom)
        return bool(full), _proc_name(hwnd, user32)
    except Exception:
        return False, ""


class GameModeMonitor:
    def __init__(self, on_change=None, on_notify=None) -> None:
        # on_change(active: bool, reason: str)  reason in ''|'fullscreen'|'vram'
        # on_notify(kind: str)  kind in 'fullscreen'|'vram'|'exit'
        self._on_change = on_change
        self._on_notify = on_notify
        self.texts: dict = {}  # kind -> localized phrase (supplied by Flutter)

        # config (defaults per TZ)
        self.fullscreen_enabled = True
        self.vram_enabled = True
        self.vram_enter = 85.0
        self.vram_exit = 65.0
        self.notify_enabled = True
        self.exclusions: set[str] = set()

        # state
        self._active = False
        self._reason = ""
        self._fs_ok_since = 0.0
        self._vram_hi_count = 0
        self._vram_low_since = 0.0
        self._vram_active = False
        self._fs_active = False

        self._thread: threading.Thread | None = None
        self._running = False

    def bind(self, on_change, on_notify) -> None:
        self._on_change = on_change
        self._on_notify = on_notify

    # injectable reads (so the hysteresis logic can be unit-tested)
    def _read_fullscreen(self) -> tuple[bool, str]:
        return foreground_fullscreen()

    def _read_vram(self) -> float | None:
        return gpu.vram_percent()

    def configure(self, **kw) -> None:
        # None = "leave unchanged" (absent from the message); the app always
        # sends explicit true/false for the toggles.
        if kw.get("fullscreen_enabled") is not None:
            self.fullscreen_enabled = bool(kw["fullscreen_enabled"])
        if kw.get("vram_enabled") is not None:
            self.vram_enabled = bool(kw["vram_enabled"])
        if kw.get("vram_enter") is not None:
            self.vram_enter = float(kw["vram_enter"])
        if kw.get("vram_exit") is not None:
            self.vram_exit = float(kw["vram_exit"])
        # Guard: exit must sit below enter (TZ validation) or hysteresis breaks.
        if self.vram_exit >= self.vram_enter:
            self.vram_exit = max(0.0, self.vram_enter - 10.0)
        if kw.get("notify_enabled") is not None:
            self.notify_enabled = bool(kw["notify_enabled"])
        if kw.get("exclusions") is not None:
            self.exclusions = {str(x).strip().lower()
                               for x in kw["exclusions"] if str(x).strip()}

    def start(self) -> None:
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running = False

    @property
    def active(self) -> bool:
        return self._active

    def release(self) -> None:
        """Drop the offload layer NOW (e.g. the user changed a device setting).
        It re-engages on the next poll if conditions still hold (TZ2 block 7)."""
        self._fs_active = False
        self._vram_active = False
        self._fs_ok_since = 0.0
        self._vram_hi_count = 0
        if self._active:
            self._active = False
            self._reason = ""
            if self._on_change:
                self._on_change(False, "")

    def _tick(self) -> None:
        now = time.monotonic()

        # --- Trigger A: fullscreen foreground with a ~5 s hold -------------
        fs_active = False
        if self.fullscreen_enabled:
            full, exe = self._read_fullscreen()
            if full and exe not in self.exclusions:
                if self._fs_ok_since == 0.0:
                    self._fs_ok_since = now
                elif now - self._fs_ok_since >= _FS_HOLD_S:
                    fs_active = True
            else:
                self._fs_ok_since = 0.0
        else:
            self._fs_ok_since = 0.0
        self._fs_active = fs_active

        # --- Trigger B: VRAM with two-sided hysteresis --------------------
        if self.vram_enabled:
            v = self._read_vram()
            if v is not None:
                if not self._vram_active:
                    if v >= self.vram_enter:
                        self._vram_hi_count += 1
                        if self._vram_hi_count >= 2:
                            self._vram_active = True
                            self._vram_low_since = 0.0
                    else:
                        self._vram_hi_count = 0
                else:
                    if v <= self.vram_exit:
                        if self._vram_low_since == 0.0:
                            self._vram_low_since = now
                        elif now - self._vram_low_since >= _VRAM_EXIT_HOLD_S:
                            self._vram_active = False
                            self._vram_hi_count = 0
                    else:
                        self._vram_low_since = 0.0
        else:
            self._vram_active = False
            self._vram_hi_count = 0

        # --- Shared layer: active while EITHER trigger is on --------------
        want = self._fs_active or self._vram_active
        # Prefer whichever trigger newly caused engagement for the reason text.
        reason = "fullscreen" if self._fs_active else \
            ("vram" if self._vram_active else "")
        if want and not self._active:
            self._active = True
            self._reason = reason
            if self._on_change:
                self._on_change(True, reason)
            if self.notify_enabled and self._on_notify:
                self._on_notify(reason)
        elif not want and self._active:
            self._active = False
            self._reason = ""
            if self._on_change:
                self._on_change(False, "")
            if self.notify_enabled and self._on_notify:
                self._on_notify("exit")

    def _loop(self) -> None:
        while self._running:
            try:
                self._tick()
            except Exception:
                pass
            # Sleep in small slices so stop() is responsive.
            slept = 0.0
            while self._running and slept < _POLL_S:
                time.sleep(0.25)
                slept += 0.25
