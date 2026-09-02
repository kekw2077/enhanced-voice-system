"""Nexus Anima sidecar — local voice/ML brain for the desktop app.

A WebSocket server on 127.0.0.1 that exposes STT (faster-whisper), VAD
(webrtcvad), TTS (pyttsx3) and fuzzy command intent matching. The Flutter app
launches this process, reads the chosen port from the "ANIMA_SIDECAR_READY <port>"
stdout line, then connects.

Protocol (JSON text frames)
  client -> server:
    {"type": "stt.start", "language": "ru"|"en"|"auto"}
    {"type": "stt.stop"}
    {"type": "stt.config", "model": "small", "prompt": "...",
                           "engine": "whisper"|"gigaam"|"remote", "gigaam_dir": "...",
                           "remote_url": "http://host:8000", "remote_model": "...",
                           "remote_key": "...", "local_engine": "whisper"|"gigaam",
                           "denoise": "off"|"light"|"strong", "denoise_dir": "...",
                           "device": "cpu"|"cuda"}
    {"type": "stt.remote_check"}                     # probe the remote STT server
    {"type": "tts.speak", "text": "..."}
    {"type": "tts.stop"}
    {"type": "tts.config", "engine": "piper"|"pyttsx3",
                           "voice": "ru_RU-irina-medium", "voice_dir": "..."}
    {"type": "tts.preview", "voice": "...", "voice_dir": "...", "text": "..."}
    {"type": "tts.render", "id": str, "text": "...", "path": "...",
                          "voice"?: "...", "voice_dir"?: "..."}  # синтез в файл
    {"type": "tts.prerender", "phrases": ["...", "..."]}  # прогрев кэша озвучки
    {"type": "intent.parse", "text": "...", "commands": [{"phrase": "..."}], "threshold": 0.5}
    {"type": "audio.sessions"}                       # list active per-app audio sessions
    {"type": "app.volume", "process": "Yandex Music.exe",
                           "action": "set"|"increase"|"decrease"|"mute"|"unmute",
                           "value": 0.30}             # 0..1 for set/increase/decrease
    {"type": "stt.transcribe", "id": str, "audio": "<base64>",
                               "format": "wav"|"pcm16"}  # one-shot network voice cmd
    {"type": "journal.config", "path": "<data root>/events.db",
                               "confirm": "always"|"dangerous"|"never",
                               "settings": {...}}   # журнал, правила, потолок
    {"type": "bus.status"}                   # состояние шины: правила, пути
    {"type": "bus.recent", "limit": 50}      # последние события с исходами
    {"type": "bus.reload"}                   # перечитать rules.yaml с диска
    {"type": "bus.config", "enabled": bool}  # выключатель шины
    {"type": "bus.answer", "id": str, "yes": bool}  # ответ на заданный вопрос
    {"type": "audio.devices"}                # выходы звука: список и текущий
    {"type": "audio.set_default", "device": "<id>"}   # переключить выход
    {"type": "proc.windowed"}                # программы с окном — для выбора
    {"type": "ping"}
  server -> client:
    {"type": "ready", "protocol": int,
                      "capabilities": {"stt": bool, "tts": bool,
                                       "engines": {"whisper": bool, "gigaam": bool},
                                       "tts_engines": {...}, "gpu": {...}}}
    {"type": "bus.status.result", "running": bool, "enabled": bool,
                                  "session": "gaming"|"work"|"idle",
                                  "confirm": str, "journal": "<путь>",
                                  "rules_path": "<путь>", "rules_error": str,
                                  "rules": [{"id": str, "action": str,
                                             "match": str, "tools": [str]}]}
    {"type": "bus.ask", "id": str, "rule": str, "text": "<что спросить>"}
    {"type": "audio.devices.result", "devices": [{"id": str, "name": str,
                                     "state": "active"|"unplugged"|..,
                                     "default": bool}]}
    {"type": "audio.set_default.result", "ok": bool, "reason"?: str}
    {"type": "proc.windowed.result", "apps": [{"exe": str, "title": str}]}
    {"type": "bus.recent.result", "events": [{"ts": str, "source": str,
                                              "type": str, "severity": str,
                                              "subject": {}, "payload": {},
                                              "outcome": str}]}
    {"type": "vad", "speaking": bool}
    {"type": "stt.partial", "text": "..."}
    {"type": "stt.final", "text": "...", "latency_ms": int, "device"?: str}
    {"type": "stt.state", "state": "starting"|"loading_models"|"ready"|"error", "message"?: str}
    {"type": "stt.engine_status", "engine": str, "state": "loading"|"ready"|"error",
                                  "message"?: str,
                                  "probe"?: bool, "models"?: [str]}  # probe = ответ кнопки «Проверить»
    {"type": "stt.device", "engine": str, "requested": "cpu"|"cuda", "active": "cpu"|"cuda", "fell_back": bool}
    {"type": "stt.denoise_status", "mode": str, "state": "ready"|"error", "message"?: str}
    {"type": "tts.done"}
    {"type": "tts.level", "level": float}             # 0..1, ведёт визуализацию
    {"type": "tts.prerender", "state"?: "skip"|"start"|"done"|"error",
                              "done": int, "total": int, "message"?: str}
    {"type": "tts.render.result", "id": str, "ok": bool, "path": str}
    {"type": "tts.status", "engine": str, "voice": str, "state": "loading"|"ready"|"error", "message"?: str}
    {"type": "intent.result", "match": {...}|null}
    {"type": "audio.sessions.result",
        "sessions": [{"process": str, "display_name": str, "volume": float|null}]}
    {"type": "app.volume.result",
        "ok": bool, "found": int, "volume": float|null, "process": str, "action": str}
    {"type": "stt.transcribe.result", "id": str, "text": str, "error"?: str}
    {"type": "pong"}
    {"type": "error", "message": "..."}
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import sys
import traceback
import wave

import websockets

import gpu
import bus_filter
import procwatch
from gamemode import GameModeMonitor
from journal import Journal
from intent import match
from stt_engine import SAMPLE_RATE, SttEngine, log_stage
from tts_engine import TtsEngine

# Version of the contract in the docstring above, announced in the "ready"
# handshake. Bump it whenever a message changes shape in a way an older peer
# cannot read.
#
# It exists because the sidecar ships as a DOWNLOADED component on its own
# release cadence (dist/components.json), so the app and the sidecar really do
# drift apart on a machine. Until now the app had no way to notice: a field the
# other side never sent simply read as absent, and the trouble surfaced later,
# somewhere unrelated. The number does not fix a mismatch — it makes it sayable.
PROTOCOL_VERSION = 1

# Journal, filter and their sources live for the whole process, not per
# connection: a dropped WebSocket should not lose the fact that a game is
# running.
_journal = None
_filter = None
_game = None
# Пути запоминаются на месте открытия: интерфейс показывает их и предлагает
# открыть файл правил, а перечитать правила без пути невозможно.
_journal_path = ""
_rules_path = ""
_rules_error = ""
_procwatch = None
# Настройки приложения: списки игр, проигрыватель музыки, устройства вывода.
# Живут здесь, а не в правилах, потому что их называет человек в интерфейсе, а
# правила на них только ссылаются (in:settings.…).
_settings: dict = {}
# Заданные и ещё не отвеченные вопросы: id -> id правила.
_asks: dict = {}
_ask_seq = 0
# emit текущего подключения. Вопрос рождается в потоке сторожа процессов, а
# уходить должен в приложение — значит нужна ссылка снаружи обработчика.
_emit = None


def _ensure_rules(path: str) -> str:
    """Правила лежат в userdata, а не в сборке: их правят руками.

    В пакете едет только образец. Он копируется один раз и больше не трогается
    — иначе обновление движка затирало бы правила, которые человек под себя
    и настраивал.
    """
    import os
    import shutil
    if not os.path.exists(path):
        seed = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "rules.yaml")
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        shutil.copyfile(seed, path)
        log_stage("rules seeded at " + path)
    return path


def _start_journal(path: str) -> None:
    """Open the event journal and let the game-mode detector feed it.

    Only the DETECTOR half of gamemode is used here. It reports that a
    fullscreen app has held the foreground, or that video memory crossed a
    threshold, and stops at saying so; the GPU offload it once drove is not
    reconnected. That is the point of journalling before filtering — for now
    nothing in the system acts on these rows, they only accumulate until there
    is enough real traffic to tune a filter against.
    """
    global _journal, _filter, _game, _journal_path, _rules_path, _rules_error
    global _procwatch
    if _journal is not None:
        return
    import os
    _journal = Journal(path)
    _journal_path = path
    rules_path = _ensure_rules(
        os.path.join(os.path.dirname(os.path.abspath(path)), "rules.yaml"))
    _rules_path = rules_path
    try:
        rules = bus_filter.load_rules(rules_path)
        _rules_error = ""
    except Exception as e:
        # Сломанный YAML не должен ронять движок: без правил шина превращается
        # обратно в журнал, и это ровно то состояние, из которого она выросла.
        log_stage("rules failed, journal only: " + str(e))
        _rules_error = str(e)
        rules = []
    _filter = bus_filter.Filter(_journal, rules,
                                bus_filter.default_tools(lambda: _settings),
                                ask=_ask)
    _filter.feed(bus_filter.make_event("journal", "journal.opened",
                                       payload={"path": path,
                                                "rules": len(rules)}))

    def on_change(active: bool, reason: str) -> None:
        # Этот детектор и определяет режим сессии `gaming` из спецификации. Оба
        # его триггера уже несут гистерезис — пять секунд выдержки на
        # полноэкранном окне, двусторонние пороги на видеопамяти, — поэтому в
        # фильтр приходит устоявшийся факт, а не дребезг границы.
        try:
            _filter.session = "gaming" if active else "idle"
            _filter.feed(bus_filter.make_event(
                "system.window",
                "session.gaming.entered" if active else "session.gaming.exited",
                payload={"reason": reason} if reason else {}))
        except Exception:
            pass

    _game = GameModeMonitor(on_change=on_change)
    _game.start()

    def on_proc(name: str, started: bool) -> None:
        # Событие — факт, а не команда: что появилось и что в этот момент со
        # звуком. Решение («переключить», «спросить», «не трогать») принимают
        # правила по спискам из настроек, а не источник. Поэтому здесь нет ни
        # слова про наушники — только про то, куда звук идёт сейчас.
        try:
            _filter.feed(bus_filter.make_event(
                "procwatch",
                "app.started" if started else "app.stopped",
                subject={"app": name},
                payload={"output": _where_sound_goes(),
                         "music": _music_is_playing()}))
        except Exception:
            pass

    _procwatch = procwatch.ProcWatch(on_proc)
    _procwatch.start()
    # Настройки могли прийти раньше журнала: приложение шлёт их одним
    # сообщением с путём, а сторожа до этой строки просто не было.
    _apply_settings(_settings)
    log_stage("event journal at %s, rules: %d" % (path, len(rules)))


def _dig_set(path: str):
    cur = _settings
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _where_sound_goes() -> str:
    """Куда сейчас идёт звук — в терминах человека, а не идентификаторов.

    Правило спрашивает «звук на колонках?», а не «устройство по умолчанию равно
    {0.0.0…}». Названия наушников и колонок знает только человек, поэтому факт
    собирается здесь, из его же настроек, и кладётся в событие.
    """
    try:
        import audio_out
        cur = audio_out.default_id()
        if not cur:
            return "unknown"
        if cur == _dig_set("devices.headphones"):
            return "headphones"
        if cur == _dig_set("devices.speakers"):
            return "speakers"
        return "other"
    except Exception:
        return "unknown"


def _music_is_playing() -> bool:
    """Есть ли у проигрывателя живая звуковая сессия.

    Сессия существует, пока программа что-то выводит, — этого достаточно, чтобы
    не приглушать тишину. Точнее Windows и не отвечает: «играет ли музыка» она
    не знает, знает только «идёт ли звук».
    """
    app = _dig_set("music.app")
    if not app:
        return False
    try:
        import app_audio
        want = str(app).lower()
        for s in app_audio.list_sessions():
            if str(s.get("process", "")).lower() == want:
                return True
    except Exception:
        pass
    return False


def _apply_settings(st: dict) -> None:
    """Принять настройки приложения и раздать их тем, кто их ждёт."""
    global _settings
    if not isinstance(st, dict):
        return
    _settings = st
    if _filter is not None:
        _filter.settings = st
    if _procwatch is not None:
        # Наблюдаем за играми и за проигрывателем: закрытая музыка — тоже
        # событие, по которому кто-то однажды захочет правило.
        names = list(_dig_set("games.list") or [])
        music = _dig_set("music.app")
        if music:
            names.append(music)
        _procwatch.set_watch(names)


def _ask(rule, event) -> None:
    """Задать вопрос приложению. Ответ придёт отдельным сообщением."""
    global _ask_seq
    if _emit is None:
        raise RuntimeError("no client")
    text = (rule.say or "").strip()
    if not text:
        raise RuntimeError("rule has nothing to say")
    _ask_seq += 1
    aid = "a%d" % _ask_seq
    _asks[aid] = rule.id
    _emit({"type": "bus.ask", "id": aid, "rule": rule.id, "text": text})


def _bus_status() -> dict:
    """Состояние шины одним снимком — ровно то, что показывает экран настроек.

    Правила отдаются списком, а не числом: «загружено 4» не отвечает на
    единственный вопрос, который возникает у экрана, — какие именно и в каком
    порядке. Порядок здесь тот же, что и при разборе: побеждает первое
    совпавшее, и видеть это надо глазами, а не выяснять опытом.
    """
    rules = []
    if _filter is not None:
        for r in _filter.rules:
            rules.append({
                "id": r.id,
                "action": r.action,
                "match": ", ".join("%s: %s" % (k, v) for k, v in r.match.items()),
                "tools": list(r.tools),
                "cooldown_s": r.cooldown_s,
            })
    return {
        "type": "bus.status.result",
        "running": _journal is not None,
        "enabled": bool(_filter.enabled) if _filter is not None else False,
        "session": _filter.session if _filter is not None else "",
        "confirm": _filter.confirm if _filter is not None else "",
        "journal": _journal_path,
        "rules_path": _rules_path,
        "rules_error": _rules_error,
        "rules": rules,
    }


def _decode_to_pcm16k_mono(np, raw: bytes, fmt: str = "wav") -> bytes:
    """Normalize incoming command audio to the STT engines' native format:
    16 kHz, mono, signed 16-bit little-endian PCM.

    Accepts a full WAV container (any sample rate / channel count / bit depth)
    or, when `fmt` is "pcm16", already-raw 16 kHz mono int16. Downmix and
    resampling use numpy only (linear interpolation) — no extra dependency and
    no audioop, which is gone in Python 3.13+. Raises on unparseable input so
    the caller can report an error rather than feed the engine garbage."""
    if fmt == "pcm16":
        return raw

    with wave.open(io.BytesIO(raw), "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())

    if width == 1:  # 8-bit WAV is unsigned; center it before scaling to int16
        samples = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) \
            * 256.0
    elif width == 2:
        samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32)
    elif width == 4:
        samples = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 65536.0
    else:
        raise ValueError(f"unsupported WAV sample width: {width}")

    if channels > 1:  # average channels down to mono
        samples = samples.reshape(-1, channels).mean(axis=1)

    if rate != SAMPLE_RATE and samples.size:  # linear resample to 16 kHz
        duration = samples.size / float(rate)
        n_out = max(1, int(round(duration * SAMPLE_RATE)))
        src_idx = np.linspace(0.0, samples.size - 1, num=n_out)
        samples = np.interp(src_idx, np.arange(samples.size), samples)

    return np.clip(samples, -32768.0, 32767.0).astype("<i2").tobytes()


async def _handle(ws, stt: SttEngine, tts: TtsEngine) -> None:
    loop = asyncio.get_running_loop()
    out: "asyncio.Queue[dict]" = asyncio.Queue()

    def emit(msg: dict) -> None:
        # Called from worker threads (STT/TTS) — hop back onto the loop.
        loop.call_soon_threadsafe(out.put_nowait, msg)

    # Шине нужно уметь спрашивать, а вопрос рождается в потоке сторожа
    # процессов, снаружи этого обработчика. Подключение всегда одно: приложение
    # держит единственный экземпляр, так что ссылка на emit тоже одна.
    global _emit
    _emit = emit

    async def sender() -> None:
        while True:
            msg = await out.get()
            await ws.send(json.dumps(msg, ensure_ascii=False))

    send_task = asyncio.create_task(sender())
    log_stage("flutter connected")
    await ws.send(json.dumps({
        "type": "ready",
        "protocol": PROTOCOL_VERSION,
        "capabilities": {
            "stt": stt.available,
            "tts": tts.available,
            "engines": stt.capabilities(),
            "tts_engines": tts.capabilities(),
            "gpu": gpu.gpu_info(),
        },
    }))
    # Bind this connection's emitter so engine-status can be reported outside of
    # start/stop, and apply the CLI/desired engines (reports their readiness).
    stt.bind(emit)
    tts.bind(emit)

    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except Exception:
                continue
            try:
                t = data.get("type")
                if t == "stt.start":
                    stt.start(data.get("language", "ru"), emit,
                              device=data.get("device"),
                              prompt=data.get("prompt"),
                              devices=data.get("devices"))
                elif t == "stt.stop":
                    stt.stop()
                elif t == "stt.config":
                    model = data.get("model")
                    if model:
                        stt.set_model(str(model))
                    if "prompt" in data:
                        stt.set_prompt(data.get("prompt"))
                    gdir = data.get("gigaam_dir")
                    if gdir:
                        stt.update_gigaam_dir(str(gdir))
                    # Адрес сервера ставится ДО выбора движка: иначе переключение
                    # на "remote" случилось бы с ещё пустым адресом и сразу упало
                    # бы в «адрес не задан».
                    if any(k in data for k in
                           ("remote_url", "remote_model", "remote_key")):
                        stt.set_remote(url=data.get("remote_url"),
                                       model=data.get("remote_model"),
                                       key=data.get("remote_key"))
                    # Тоже ДО выбора движка: если переключение на сервер сразу
                    # сорвётся, откатываться надо уже на нужный локальный.
                    if data.get("local_engine"):
                        stt.set_local_engine(str(data.get("local_engine")))
                    engine = data.get("engine")
                    if engine:
                        stt.set_engine(str(engine), str(gdir) if gdir else None)
                    ddir = data.get("denoise_dir")
                    if ddir:
                        stt.update_denoise_dir(str(ddir))
                    if "denoise" in data:
                        stt.set_denoise(str(data.get("denoise")))
                    if "device" in data:
                        stt.set_device(str(data.get("device")))
                    if "vad" in data:
                        stt.set_vad_aggressiveness(data.get("vad"))
                    if "gain" in data:
                        stt.set_mic_gain(data.get("gain"))
                elif t == "stt.remote_check":
                    # Кнопка «Проверить» в настройках: жив ли сервер распознавания
                    # и какие у него модели. Ответ — тем же stt.engine_status, что
                    # и обычные состояния движка, чтобы карточка читала один сигнал.
                    # `probe` отличает ответ кнопки от настоящей смены движка:
                    # проверка связи НЕ означает, что распознаём мы теперь сервером.
                    try:
                        models = stt.probe_remote()
                        emit({"type": "stt.engine_status", "engine": "remote",
                              "state": "ready", "probe": True,
                              "models": models})
                    except Exception as e:
                        emit({"type": "stt.engine_status", "engine": "remote",
                              "state": "error", "probe": True, "message": str(e)})
                elif t == "tts.speak":
                    tts.speak(str(data.get("text", "")),
                              rate=float(data.get("rate", 1.0)),
                              volume=float(data.get("volume", 1.0)),
                              on_done=lambda: emit({"type": "tts.done"}),
                              on_level=lambda v: emit(
                                  {"type": "tts.level", "level": v}),
                              # Preview of a prepared phrase: play the rendered
                              # file itself, whatever engine is selected.
                              cached=bool(data.get("cached", False)))
                elif t == "tts.stop":
                    tts.stop()
                elif t == "tts.config":
                    vdir = data.get("voice_dir")
                    voice = data.get("voice")
                    if vdir is not None or voice is not None:
                        tts.set_voice(str(vdir) if vdir else "",
                                      str(voice) if voice else "")
                    # Cloning config (set BEFORE engine so a switch to xtts/cosyvoice
                    # loads with the sample/exe already in place). Cache is shared.
                    if ("cache_dir" in data or "voice_fp" in data
                            or "cache_engine" in data):
                        tts.set_cache(cache_dir=data.get("cache_dir"),
                                      voice_fp=data.get("voice_fp"),
                                      engine=data.get("cache_engine"))
                    clone = data.get("clone")
                    if isinstance(clone, dict):
                        tts.set_clone_config(exe=clone.get("exe"),
                                             ref=clone.get("ref"),
                                             lang=clone.get("lang"))
                    cosy = data.get("cosy")
                    if isinstance(cosy, dict):
                        tts.set_cosy_config(endpoint=cosy.get("endpoint"),
                                            ref=cosy.get("ref"),
                                            prompt_text=cosy.get("prompt"),
                                            speed=cosy.get("speed"),
                                            language=cosy.get("language"))
                    eng = data.get("engine")
                    if eng:
                        tts.set_engine(str(eng))
                    if "fx" in data:
                        tts.set_fx(data.get("fx"))
                elif t == "tts.prerender":
                    # Pre-render a batch of fixed phrases into the clone cache so
                    # they later play instantly (system notifications, command
                    # speak-phrases, the acknowledgement library).
                    tts.prerender(list(data.get("phrases", [])))
                elif t == "tts.render":
                    # Синтез в файл: студия сохраняет озвучку любым голосом, а не
                    # только клоном. Отвечаем по id, чтобы два запроса подряд не
                    # перепутались.
                    rid = str(data.get("id", ""))
                    dst = str(data.get("path", ""))
                    ok = tts.render(str(data.get("text", "")), dst,
                                    voice_dir=str(data.get("voice_dir", "")),
                                    voice_id=str(data.get("voice", "")),
                                    rate=float(data.get("rate", 1.0)))
                    emit({"type": "tts.render.result", "id": rid,
                          "ok": bool(ok), "path": dst if ok else ""})
                elif t == "tts.preview":
                    tts.preview(str(data.get("voice_dir", "")),
                                str(data.get("voice", "")),
                                str(data.get("text", "")),
                                rate=float(data.get("rate", 1.0)),
                                volume=float(data.get("volume", 1.0)))
                elif t == "intent.parse":
                    res = match(
                        str(data.get("text", "")),
                        list(data.get("commands", [])),
                        float(data.get("threshold", 0.5)),
                    )
                    emit({"type": "intent.result", "match": res})
                elif t == "audio.sessions":
                    # COM/pycaw is blocking — run it off the event loop.
                    import app_audio
                    sess = await asyncio.get_event_loop().run_in_executor(
                        None, app_audio.list_sessions)
                    emit({"type": "audio.sessions.result", "sessions": sess})
                elif t == "app.volume":
                    import app_audio
                    _v = data.get("value")
                    _proc = str(data.get("process", ""))
                    _act = str(data.get("action", "set"))
                    r = await asyncio.get_event_loop().run_in_executor(
                        None,
                        lambda: app_audio.apply(
                            _proc, _act,
                            float(_v) if _v is not None else None))
                    emit({"type": "app.volume.result", **r})
                elif t == "stt.transcribe":
                    # One-shot offline recognition for a network voice command
                    # (settings-TZ §14). `audio` is base64; `format` is "wav"
                    # (default) or "pcm16" (raw 16 kHz mono int16). Decode +
                    # recognize off the event loop; reply is keyed by `id` so the
                    # Dart side can match it even if several arrive at once.
                    rid = data.get("id")
                    b64 = str(data.get("audio", ""))
                    fmt = str(data.get("format", "wav"))

                    def _run_transcribe(b64=b64, fmt=fmt):
                        import numpy as np
                        pcm = _decode_to_pcm16k_mono(np, base64.b64decode(b64), fmt)
                        return stt.transcribe_pcm(np, pcm)

                    try:
                        text = await asyncio.get_event_loop().run_in_executor(
                            None, _run_transcribe)
                        emit({"type": "stt.transcribe.result",
                              "id": rid, "text": text})
                    except Exception as e:  # bad audio / decode failure
                        emit({"type": "stt.transcribe.result",
                              "id": rid, "text": "", "error": str(e)})
                elif t == "journal.config":
                    # The app decides where this lives: it is the only side
                    # that knows its own data root, which is not always on the
                    # system drive. An older sidecar simply falls through this
                    # chain and ignores the message, which is the right
                    # outcome — the journal is not load-bearing.
                    jp = str(data.get("path", "")).strip()
                    if jp:
                        try:
                            _start_journal(jp)
                        except Exception as e:
                            log_stage("journal failed: " + str(e))
                    # Потолок подтверждений и списки из настроек приложения.
                    # Правило может спрашивать чаще, чем требует настройка, но
                    # никогда реже — проверка живёт в шаге 2 фильтра.
                    if _filter is not None:
                        c = bus_filter.normalize_confirm(data.get("confirm"))
                        if c:
                            _filter.confirm = c
                        # Выключатель приезжает тем же сообщением, что и путь:
                        # связь рвётся, настройка при этом не меняется, и без
                        # повторной отправки шина после переподключения снова
                        # заработала бы у того, кто её выключил.
                        if "enabled" in data:
                            _filter.enabled = bool(data.get("enabled"))
                    # Вне проверки на фильтр: настройки нужны и до того, как
                    # журнал открыт, — из них берётся список наблюдаемых имён.
                    _apply_settings(data.get("settings"))
                elif t == "bus.status":
                    emit(_bus_status())
                elif t == "bus.recent":
                    # Хвост журнала для экрана настроек. Пустой список — это
                    # не ошибка: шина могла ещё ничего не увидеть.
                    rows = []
                    if _journal is not None:
                        try:
                            lim = int(data.get("limit") or 50)
                            rows = _journal.recent(max(1, min(500, lim)))
                        except Exception as e:
                            log_stage("journal read failed: " + str(e))
                    emit({"type": "bus.recent.result", "events": rows})
                elif t == "bus.reload":
                    # Правила правят руками в файле, поэтому перечитать их надо
                    # без перезапуска движка. Разбор идёт во временный список:
                    # сломанный YAML не должен отобрать уже работающие правила.
                    global _rules_error
                    if _filter is not None and _rules_path:
                        try:
                            fresh = bus_filter.load_rules(_rules_path)
                            _filter.rules = fresh
                            _rules_error = ""
                            log_stage("rules reloaded: %d" % len(fresh))
                        except Exception as e:
                            _rules_error = str(e)
                            log_stage("rules reload failed: " + str(e))
                    emit(_bus_status())
                elif t == "bus.config":
                    if _filter is not None and "enabled" in data:
                        _filter.enabled = bool(data.get("enabled"))
                    emit(_bus_status())
                elif t == "audio.devices":
                    try:
                        import audio_out
                        devs = await asyncio.get_event_loop().run_in_executor(
                            None, audio_out.devices)
                    except Exception as e:
                        log_stage("audio devices failed: " + str(e))
                        devs = []
                    emit({"type": "audio.devices.result", "devices": devs})
                elif t == "audio.set_default":
                    # Ручное переключение из настроек — кнопкой «Проверить».
                    # Названия устройств у Windows такие, что выбрать наушники
                    # с первого раза нельзя: проверить надо ухом, а не глазом.
                    try:
                        import audio_out
                        res = await asyncio.get_event_loop().run_in_executor(
                            None, audio_out.set_default,
                            str(data.get("device", "")))
                    except Exception as e:
                        res = {"ok": False, "reason": "failed", "error": str(e)}
                    res = dict(res)
                    res["type"] = "audio.set_default.result"
                    emit(res)
                elif t == "proc.windowed":
                    apps = await asyncio.get_event_loop().run_in_executor(
                        None, procwatch.windowed_apps)
                    emit({"type": "proc.windowed.result", "apps": apps})
                elif t == "bus.answer":
                    aid = str(data.get("id", ""))
                    rid = _asks.pop(aid, "")
                    yes = bool(data.get("yes"))
                    outcome = "answer_stale"
                    if rid and _filter is not None:
                        rule = _filter.rule_by_id(rid)
                        if rule is None:
                            outcome = "answer_no_rule:" + rid
                        elif not yes:
                            outcome = "declined:" + rid
                        else:
                            ok = await asyncio.get_event_loop().run_in_executor(
                                None, _filter.run_rule_tools, rule)
                            outcome = ("acted:" if ok else "act_failed:") + rid
                    # Ответ — тоже событие: по журналу должно быть видно не
                    # только что спросили, но и что услышали. Отказ — такой же
                    # исход, как согласие, и терять его нельзя.
                    if _journal is not None:
                        try:
                            _journal.write(bus_filter.make_event(
                                "bus", "bus.answered",
                                payload={"rule": rid, "yes": yes}), outcome)
                        except Exception:
                            pass
                elif t == "ping":
                    emit({"type": "pong"})
            except Exception:
                # Одно негодное сообщение не должно рвать СОЕДИНЕНИЕ.
                # Раньше рвало: разбор шёл без охраны, и любая ошибка
                # внутри — хоть обращение к тому, чего уже нет, — гасила
                # обработчик websockets целиком. Программа при этом
                # продолжала работать: чат идёт по HTTP на станцию и
                # ничего не замечает, а распознавание и озвучка живут
                # ровно этим соединением и молча пропадали.
                traceback.print_exc()
                log_stage(f"message {data.get('type')!r} failed; connection kept")
    except websockets.ConnectionClosed:
        pass
    finally:
        send_task.cancel()
        stt.stop()
        # Связь оборвалась — спрашивать некому. Заданные и неотвеченные
        # вопросы снимаются: ответ на вопрос, заданный полчаса назад в другой
        # сессии, применять уже нельзя.
        #
        # Сравнение с СОБСТВЕННЫМ emit обязательно. Переподключения
        # перекрываются: новое успевает встать раньше, чем закроется старое, и
        # безусловная очистка обнулила бы ссылку живого подключения — шина
        # замолчала бы навсегда, ничем этого не показав.
        if globals().get("_emit") is emit:
            globals()["_emit"] = None
            _asks.clear()


async def _main(args) -> None:
    stt = SttEngine(args.model, args.device, args.compute_type,
                    engine=args.engine, gigaam_dir=args.gigaam_dir,
                    denoise=args.denoise, denoise_dir=args.denoise_dir,
                    remote_url=args.stt_remote_url,
                    remote_model=args.stt_remote_model,
                    remote_key=args.stt_remote_key,
                    local_engine=args.stt_local_engine)
    tts = TtsEngine(engine=args.tts_engine, voice=args.tts_voice,
                    voice_dir=args.tts_voice_dir)
    async def handler(ws):
        await _handle(ws, stt, tts)

    log_stage("intent matcher ready; ws server starting")
    async with websockets.serve(handler, args.host, args.port) as server:
        port = args.port or server.sockets[0].getsockname()[1]
        # Flutter parses this line from stdout to learn the port.
        # Оба маркера, старый первым. Приложение и движок выходят порознь,
        # так что рядом может оказаться сборка любого поколения, а это
        # единственный способ узнать порт: не распознав строку, вторая сторона
        # остаётся вообще без голоса. Лишняя строка в stdout не стоит ничего.
        print(f"EVS_SIDECAR_READY {port}", flush=True)
        print(f"ANIMA_SIDECAR_READY {port}", flush=True)
        log_stage(f"ws server listening on port {port}")
        # Start the parent-death watcher ONLY now — after the heavy engine
        # imports (sounddevice/faster-whisper) and the READY print. Its blocking
        # `sys.stdin.buffer.read()` holds the stdin BufferedReader lock, and if
        # it runs during those imports it can deadlock startup so READY never
        # prints (observed: sidecar "Не запущен", process alive but no socket).
        _watch_parent()
        await asyncio.Future()  # run forever


def _watch_parent() -> None:
    """Exit when the launching app dies.

    The app holds our stdin pipe; if it crashes or is force-killed, stdin
    hits EOF — without this watcher, orphaned sidecars pile up (observed: 5
    evs_sidecar.exe processes after repeated app kills).
    """
    import os
    import threading

    def _watch() -> None:
        try:
            while sys.stdin.buffer.read(4096):
                pass
        except Exception:
            pass
        os._exit(0)

    threading.Thread(target=_watch, daemon=True).start()


def main() -> None:
    ap = argparse.ArgumentParser(description="EVS voice/ML sidecar")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = pick a free port")
    ap.add_argument("--model", default="small", help="faster-whisper model size")
    ap.add_argument("--device", default="cpu", help="cpu | cuda")
    ap.add_argument("--compute-type", dest="compute_type", default="int8")
    ap.add_argument("--engine", default="whisper",
                    help="whisper | gigaam | remote")
    ap.add_argument("--stt-remote-url", dest="stt_remote_url", default="",
                    help="OpenAI-compatible base url for remote recognition")
    ap.add_argument("--stt-remote-model", dest="stt_remote_model", default="",
                    help="model name asked of the remote recognition server")
    ap.add_argument("--stt-remote-key", dest="stt_remote_key", default="",
                    help="bearer token for the remote recognition server")
    ap.add_argument("--stt-local-engine", dest="stt_local_engine", default="",
                    help="whisper | gigaam — engine to recognize with when the "
                         "remote server is unreachable")
    ap.add_argument("--gigaam-dir", dest="gigaam_dir", default="",
                    help="GigaAM sherpa-onnx model directory")
    ap.add_argument("--denoise", default="off", help="off | light | strong")
    ap.add_argument("--denoise-dir", dest="denoise_dir", default="",
                    help="models root holding denoise-gtcrn/ and denoise-df/")
    ap.add_argument("--tts-engine", dest="tts_engine", default="piper",
                    help="piper (default) | pyttsx3")
    ap.add_argument("--tts-voice", dest="tts_voice", default="",
                    help="Piper voice id, e.g. ru_RU-irina-medium")
    ap.add_argument("--tts-voice-dir", dest="tts_voice_dir", default="",
                    help="dir holding the Piper voice bundle (<userdata>/models/<id>)")
    args = ap.parse_args()
    # NOTE: _watch_parent() is started from inside _main(), AFTER the server is
    # up and READY is printed — starting it here (before the heavy imports)
    # deadlocked startup on some Windows setups (stdin BufferedReader lock).
    try:
        asyncio.run(_main(args))
    except KeyboardInterrupt:
        pass
    except Exception as e:  # pragma: no cover
        print(f"EVS_SIDECAR_ERROR {e}", file=sys.stderr, flush=True)
        print(f"ANIMA_SIDECAR_ERROR {e}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
