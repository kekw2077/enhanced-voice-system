"""Сторож процессов: замечает, что программа из списка запустилась или закрылась.

Отдельно от gamemode: тот следит за ПЕРЕДНИМ окном и отвечает на вопрос «сейчас
играют?», а здесь вопрос другой — «эта программа вообще появилась?». Игра
запускается раньше, чем разворачивается на весь экран, и звук переключать надо
на запуске, а не когда человек уже услышал колонки.

Опрашивается только то, что назвали в настройках. Не ради экономии: полный
список процессов меняется постоянно, и события «запустился conhost.exe» забили
бы журнал так, что в нём стало бы нечего искать.
"""
from __future__ import annotations

import ctypes
import threading
import time

_TH32CS_SNAPPROCESS = 0x00000002
_MAX_PATH = 260


class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", ctypes.c_ulong),
        ("cntUsage", ctypes.c_ulong),
        ("th32ProcessID", ctypes.c_ulong),
        ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
        ("th32ModuleID", ctypes.c_ulong),
        ("cntThreads", ctypes.c_ulong),
        ("th32ParentProcessID", ctypes.c_ulong),
        ("pcPriClassBase", ctypes.c_long),
        ("dwFlags", ctypes.c_ulong),
        ("szExeFile", ctypes.c_wchar * _MAX_PATH),
    ]


def running() -> set:
    """Имена всех запущенных процессов, в нижнем регистре."""
    names = set()
    try:
        k32 = ctypes.windll.kernel32
        snap = k32.CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
        if snap == -1:
            return names
        try:
            entry = _PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
            ok = k32.Process32FirstW(snap, ctypes.byref(entry))
            while ok:
                names.add(entry.szExeFile.lower())
                ok = k32.Process32NextW(snap, ctypes.byref(entry))
        finally:
            k32.CloseHandle(snap)
    except Exception:
        pass
    return names


# Оболочка Windows держит окна с заголовками, которые выглядят как программы,
# но выбирать их незачем: под «Параметры» звук не переключают.
_SHELL_HOSTS = {
    "explorer.exe", "textinputhost.exe", "applicationframehost.exe",
    "shellexperiencehost.exe", "searchhost.exe", "searchapp.exe",
    "startmenuexperiencehost.exe", "systemsettings.exe", "lockapp.exe",
    "widgets.exe", "widgetboard.exe",
}


def windowed_apps() -> list:
    """Что показать в списке выбора: программы с видимым окном и заголовком.

    Именно так этот список и читается человеком — «League of Legends», а не
    «LeagueClientUx.exe». Заголовок окна для этого годится куда лучше имени
    файла, а всё безоконное (службы, хосты, драйверы) выбирать всё равно
    незачем: звук переключают под то, что видно на экране.
    """
    out = {}
    try:
        from gamemode import _proc_name  # то же добывание имени, что и у сторожа игр

        user32 = ctypes.windll.user32
        cb_type = ctypes.WINFUNCTYPE(
            ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int))

        def _cb(hwnd, _lparam):
            try:
                if not user32.IsWindowVisible(hwnd):
                    return True
                n = user32.GetWindowTextLengthW(hwnd)
                if n <= 0:
                    return True
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(hwnd, buf, n + 1)
                title = buf.value.strip()
                if not title:
                    return True
                exe = _proc_name(hwnd, user32)
                if not exe or exe in _SHELL_HOSTS:
                    return True
                # Первое окно программы выигрывает: у одной программы их бывает
                # много, а в списке она должна быть одной строкой.
                out.setdefault(exe, {"exe": exe, "title": title})
            except Exception:
                pass
            return True

        user32.EnumWindows(cb_type(_cb), None)
    except Exception:
        pass
    return sorted(out.values(), key=lambda d: d["title"].lower())


class ProcWatch:
    """Опрос списка процессов в своём потоке.

    Три секунды — не настройка. Чаще незачем: между запуском игры и первым
    звуком проходит куда больше, а опрос списка процессов не бесплатный.
    """

    PERIOD = 3.0

    def __init__(self, on_change) -> None:
        self._on_change = on_change
        self._watch: set = set()
        self._present: set = set()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None

    def set_watch(self, names) -> None:
        """Сменить список наблюдаемых имён.

        Уже запущенное при смене списка событием НЕ становится: добавив игру в
        настройках во время игры, человек не просил переключать звук — он просил
        переключать впредь.
        """
        fresh = {str(n).strip().lower() for n in (names or []) if str(n).strip()}
        with self._lock:
            self._watch = fresh
            self._present = {n for n in running() if n in fresh}

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.wait(self.PERIOD):
            try:
                with self._lock:
                    watch = set(self._watch)
                    was = set(self._present)
                if not watch:
                    continue
                now = {n for n in running() if n in watch}
                with self._lock:
                    self._present = now
                for name in sorted(now - was):
                    self._on_change(name, True)
                for name in sorted(was - now):
                    self._on_change(name, False)
            except Exception:
                # Сторож, упавший от одной неудачной выборки, перестаёт быть
                # сторожем совсем — а заметить это будет некому.
                pass
