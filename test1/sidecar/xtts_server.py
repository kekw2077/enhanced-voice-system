"""Сервер клон-голоса XTTS-v2 на видеокарте.

Третий сервер синтеза рядом с `qwen_tts_server.py` и `moss_tts_server.py`, и
контракт HTTP у него ТОТ ЖЕ САМЫЙ, до последнего поля:

    GET  /                        -> {ok, loaded, paused, ...}
    POST /inference_zero_shot     multipart: tts_text, prompt_text, speed,
                                  language, prompt_wav_sha,
                                  prompt_wav=@ref.wav          -> audio/wav
    POST /config   {json}         -> живые настройки
    POST /load                    -> поднять модель заранее
    POST /unload                  -> отпустить видеопамять

Совпадение не ради красоты: на той стороне `CloneHttpEngine` из
`tts_engine.py`, и она уже умеет этот диалог — с контрольной суммой образца
вместо файла, с ответом 409 «отпечатка не знаю» и повтором. Свой диалект
означал бы второй движок в сайдкаре; общий контракт означает смену одного
адреса в настройках.

Чем он отличается от соседей:

  * Считает на ВИДЕОКАРТЕ. MOSS считал на процессоре, и это стоило девяти
    секунд на короткую фразу; здесь речь идёт о секундах.
  * Отпечаток голоса считается ОДИН РАЗ на образец и живёт в памяти. У XTTS
    это отдельный и недешёвый шаг (`get_conditioning_latents`), и делать его
    на каждую фразу — терять на ровном месте.
  * Модель распространяется по лицензии CPML (некоммерческое использование).
    Согласие выражается переменной COQUI_TOS_AGREED=1: без неё загрузка весов
    останавливается и ждёт ответа в консоли, которой у службы нет.

Запуск:

    COQUI_TOS_AGREED=1 python xtts_server.py --port 8762
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import tempfile
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 8762
MODEL_ID = "tts_models/multilingual/multi-dataset/xtts_v2"

# Сколько секунд образца брать в работу. У XTTS отпечаток считается один раз,
# так что длина образца не бьёт по каждой фразе, как это было у MOSS. Но
# рекомендация авторов — шесть-десять секунд, и на длинном образце качество
# скорее падает, чем растёт.
MAX_REF_SECONDS = 12.0

# XTTS предупреждает о тексте длиннее 250 знаков и на нём начинает глотать
# концы. Режем сами, по границам предложений.
MAX_PIECE_CHARS = 220

# Пауза между кусками при склейке.
PIECE_GAP_MS = 110

# Приложение присылает язык словом («Russian»), XTTS ждёт код («ru»). Список
# ровно тот, что модель знает; чужое имя не выдумываем, а падаем на английский
# с записью в лог — молчаливая подмена языка звучит как сломанный голос.
_LANGS = {
    "russian": "ru", "english": "en", "spanish": "es", "french": "fr",
    "german": "de", "italian": "it", "portuguese": "pt", "polish": "pl",
    "turkish": "tr", "dutch": "nl", "czech": "cs", "arabic": "ar",
    "chinese": "zh-cn", "japanese": "ja", "korean": "ko", "hungarian": "hu",
    "hindi": "hi",
}

_SENT_END = re.compile(r'([.!?…]+["»”)\]]*)\s+')


def _log(msg: str) -> None:
    print("[xtts] %s" % msg, flush=True)


def _lang_code(name: str) -> str:
    key = (name or "").strip().lower()
    if not key:
        return "ru"
    if key in _LANGS:
        return _LANGS[key]
    if key in _LANGS.values():
        return key
    _log("язык «%s» модели неизвестен, беру русский" % name)
    return "ru"


def _split_pieces(text: str, limit: int) -> list:
    """Текст кусками, которые модель дочитывает до конца.

    Режем по концам предложений, а слишком длинное предложение — по словам.
    Своя нарезка, а не внутренняя: у внутренней свои представления о длине, и
    на них уже обжигались с MOSS.
    """
    text = " ".join((text or "").split())
    if not text:
        return []
    if len(text) <= limit:
        return [text]
    out, buf = [], ""
    for part in _SENT_END.split(text):
        if not part:
            continue
        if len(buf) + len(part) <= limit:
            buf += part
            continue
        if buf.strip():
            out.append(buf.strip())
        buf = ""
        while len(part) > limit:
            cut = part.rfind(" ", 0, limit)
            if cut <= 0:
                cut = limit
            out.append(part[:cut].strip())
            part = part[cut:].lstrip()
        buf = part
    if buf.strip():
        out.append(buf.strip())
    return [p for p in out if p]


def _to_wav(data: bytes) -> bytes:
    """Любой звуковой файл -> WAV 24 кГц моно.

    В настройках приложения образец выбирают файлом, и там оказывается что
    угодно: MP3 из загрузок, m4a с телефона, ogg. Пока сервер принимал только
    WAV, такой образец валил синтез целиком — с сообщением про RIFF, из
    которого догадаться было невозможно. Проверяем по заголовку и, если это не
    RIFF, зовём ffmpeg: он есть в образе и читает всё.
    """
    if data[:4] == b"RIFF":
        return data
    import subprocess
    try:
        r = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
             "-ac", "1", "-ar", "24000", "-f", "wav", "pipe:1"],
            input=data, capture_output=True, timeout=120)
        if r.returncode == 0 and r.stdout[:4] == b"RIFF":
            _log("образец перекодирован в WAV (%d -> %d байт)"
                 % (len(data), len(r.stdout)))
            return r.stdout
        _log("ffmpeg не справился с образцом: %s"
             % (r.stderr or b"").decode("utf-8", "replace")[:160])
    except Exception as e:
        _log("перекодировать образец не вышло: %s" % e)
    return data


def _trim_wav(data: bytes, max_sec: float) -> bytes:
    """Первые max_sec секунд образца, если он длиннее."""
    try:
        with wave.open(io.BytesIO(data)) as w:
            rate, frames = w.getframerate(), w.getnframes()
            want = int(max_sec * rate)
            if frames <= want:
                return data
            params = w.getparams()
            chunk = w.readframes(want)
        out = io.BytesIO()
        with wave.open(out, "wb") as w2:
            w2.setnchannels(params.nchannels)
            w2.setsampwidth(params.sampwidth)
            w2.setframerate(rate)
            w2.writeframes(chunk)
        _log("образец обрезан: %.1fs -> %.0fs" % (frames / rate, max_sec))
        return out.getvalue()
    except Exception as e:
        _log("образец не разобрался (%s) — беру как есть" % e)
        return data


def _wav_seconds(data: bytes) -> float:
    try:
        with wave.open(io.BytesIO(data)) as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return 0.0


def _pcm16(samples, rate: int, gap_ms: int = 0) -> bytes:
    """Список кусков (numpy-массивы float32 -1..1) -> один WAV."""
    import numpy as np

    gap = np.zeros(int(rate * gap_ms / 1000.0), dtype=np.float32)
    parts = []
    for i, s in enumerate(samples):
        if i:
            parts.append(gap)
        parts.append(np.asarray(s, dtype=np.float32))
    audio = np.concatenate(parts) if parts else np.zeros(0, dtype=np.float32)
    audio = np.clip(audio, -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2").tobytes()
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return out.getvalue()


class Engine:
    """Модель, её отпечатки голоса и вся защита от одновременных запросов."""

    def __init__(self, cache_dir: str = "", device: str = "auto",
                 idle_unload_sec: float = 900.0) -> None:
        self.cache_dir = cache_dir or ""
        self.want_device = device
        self.idle_unload_sec = idle_unload_sec
        self.paused = False
        self.temperature = 0.7
        self.length_penalty = 1.0
        self.repetition_penalty = 5.0
        self.top_k = 50
        self.top_p = 0.85
        self.max_piece_chars = MAX_PIECE_CHARS
        self.gap_ms = PIECE_GAP_MS

        self._model = None
        self._sr = 24000
        self._device = "cpu"
        self._loading = False
        self._lock = threading.Lock()
        self._last_used = 0.0
        # Отпечаток голоса: sha образца -> (латенты gpt, эмбеддинг диктора).
        # Считается один раз и живёт, пока жива модель: у XTTS это отдельный
        # проход по образцу, и повторять его на каждую фразу — терять секунды.
        self._latents: dict = {}
        self._ref_sha = ""
        self._refs_dir = os.path.join(tempfile.gettempdir(), "xtts-refs")
        os.makedirs(self._refs_dir, exist_ok=True)

    # ---- состояние -------------------------------------------------------
    @property
    def loaded(self) -> bool:
        return self._model is not None

    def status(self) -> dict:
        used, total = _vram_mb()
        return {
            "ok": True,
            "name": "xtts-v2",
            # Приложение берёт первое похожее на название поле и пишет его в
            # карточку озвучки. Путь к весам там читался бы как «xtts_v2» —
            # верно, но по-машинному; человеческое имя отдаём отдельно, а
            # полный идентификатор оставляем рядом, он нужен для отчётов.
            "model": "XTTS-v2",
            "model_id": MODEL_ID,
            "loaded": self.loaded,
            "loading": self._loading,
            "paused": self.paused,
            "device": self._device,
            "sample_rate": self._sr,
            "max_piece_chars": self.max_piece_chars,
            "gap_ms": self.gap_ms,
            "idle_unload_sec": self.idle_unload_sec,
            "voices_cached": len(self._latents),
            "ref_sha": self._ref_sha,
            "vram_used_mb": used,
            "vram_total_mb": total,
            "rss_mb": _rss_mb(),
            "generation": {
                "temperature": self.temperature,
                "length_penalty": self.length_penalty,
                "repetition_penalty": self.repetition_penalty,
                "top_k": self.top_k,
                "top_p": self.top_p,
            },
        }

    def apply_config(self, cfg: dict) -> None:
        if "paused" in cfg:
            self.paused = bool(cfg["paused"])
            if self.paused:
                self.unload()
        for key in ("temperature", "length_penalty", "repetition_penalty",
                    "top_p"):
            if key in cfg:
                try:
                    setattr(self, key, float(cfg[key]))
                except Exception:
                    pass
        for key in ("top_k", "max_piece_chars", "gap_ms"):
            if key in cfg:
                try:
                    setattr(self, key, int(cfg[key]))
                except Exception:
                    pass
        if "idle_unload_sec" in cfg:
            try:
                self.idle_unload_sec = float(cfg["idle_unload_sec"])
            except Exception:
                pass

    # ---- модель ----------------------------------------------------------
    def _load(self) -> None:
        if self._model is not None:
            return
        self._loading = True
        try:
            import torch
            _patch_audio_loader()
            from TTS.tts.configs.xtts_config import XttsConfig
            from TTS.tts.models.xtts import Xtts
            from TTS.utils.manage import ModelManager

            dev = self.want_device
            if dev == "auto":
                dev = "cuda" if torch.cuda.is_available() else "cpu"
            t0 = time.time()
            _log("качаю/нахожу веса…")
            mm = ModelManager(output_prefix=self.cache_dir or None,
                              progress_bar=False)
            path, _, _ = mm.download_model(MODEL_ID)
            _log("поднимаю модель на %s…" % dev)
            config = XttsConfig()
            config.load_json(os.path.join(path, "config.json"))
            model = Xtts.init_from_config(config)
            model.load_checkpoint(config, checkpoint_dir=path, eval=True)
            if dev == "cuda":
                model.cuda()
            self._model = model
            self._device = dev
            self._sr = int(getattr(config.audio, "output_sample_rate", 24000))
            self._last_used = time.time()
            _log("готова за %.1fs, частота %d Гц" % (time.time() - t0, self._sr))
        finally:
            self._loading = False

    def warm(self) -> None:
        with self._lock:
            self._load()

    def unload(self) -> None:
        with self._lock:
            self._model = None
            self._latents.clear()
            try:
                import torch
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except Exception:
                pass
            self._release_ram()
        _log("модель отпущена, память возвращена")

    # ---- образец ---------------------------------------------------------
    @staticmethod
    def _release_ram() -> None:
        """Вернуть операционной системе то, что уже не занято.

        Замер на станции: за вечер разговора процесс дорос до 7,75 ГБ хостовой
        памяти при 2,7 ГБ на видеокарте — то есть почти всё осело не в модели.
        Станция на пятнадцать гигабайт, рядом живёт языковая модель, и ей
        просто не осталось места: её llama-server не мог подняться за пять
        минут, а чат отвечал «сервер недоступен».

        Одной сборки мусора мало: питон отдаёт освобождённое своему
        аллокатору, а тот держит арены glibc, и система по-прежнему считает их
        занятыми. malloc_trim возвращает их по-настоящему; на не-glibc его
        просто нет, и это не ошибка.
        """
        try:
            import gc
            gc.collect()
            import ctypes
            ctypes.CDLL("libc.so.6").malloc_trim(0)
        except Exception:
            pass

    def _ref_file(self, sha: str) -> str:
        return os.path.join(self._refs_dir, "%s.wav" % sha)

    def remember_reference(self, wav_bytes: bytes) -> str:
        sha = hashlib.sha256(wav_bytes).hexdigest()
        path = self._ref_file(sha)
        if not os.path.isfile(path):
            with open(path, "wb") as f:
                f.write(_trim_wav(_to_wav(wav_bytes), MAX_REF_SECONDS))
        self._ref_sha = sha
        return sha

    def resolve_reference(self, wav_bytes: bytes, sha: str) -> str:
        """Путь к образцу: по присланному файлу или по одной его сумме."""
        if wav_bytes:
            return self._ref_file(self.remember_reference(wav_bytes))
        sha = (sha or "").strip().lower()
        if not sha:
            raise ValueError("нет ни образца, ни его суммы")
        path = self._ref_file(sha)
        if not os.path.isfile(path):
            raise KeyError(sha)
        self._ref_sha = sha
        return path

    def _voice(self, ref_path: str):
        """Отпечаток голоса по образцу — считается один раз на образец."""
        sha = os.path.splitext(os.path.basename(ref_path))[0]
        got = self._latents.get(sha)
        if got is not None:
            return got
        t0 = time.time()
        latent, emb = self._model.get_conditioning_latents(
            audio_path=[ref_path])
        self._latents[sha] = (latent, emb)
        _log("отпечаток голоса посчитан за %.1fs" % (time.time() - t0))
        return latent, emb

    # ---- синтез ----------------------------------------------------------
    def synthesize(self, text: str, ref_path: str, language: str,
                   speed: float = 1.0) -> bytes:
        pieces = _split_pieces(text, self.max_piece_chars)
        if not pieces:
            raise ValueError("пустой текст")
        with self._lock:
            self._load()
            latent, emb = self._voice(ref_path)
            lang = _lang_code(language)
            t0 = time.time()
            chunks = []
            for p in pieces:
                chunks.append(self._infer(p, lang, latent, emb, speed))
            self._last_used = time.time()
            took = self._last_used - t0
        data = _pcm16(chunks, self._sr, self.gap_ms)
        # После каждой фразы, а не по простою: копится оно именно здесь, и
        # обходится возврат в миллисекунды против секунды синтеза.
        self._release_ram()
        _log("синтез: %d знаков, кусков %d, за %.2fs -> %.1fs звука, память %d МБ"
             % (len(text), len(pieces), took, _wav_seconds(data), _rss_mb()))
        return data

    def _infer(self, text: str, lang: str, latent, emb, speed: float):
        """Один кусок. Необязательные параметры отбрасываются по одному.

        Набор аргументов `inference` у XTTS менялся от версии к версии: где-то
        нет `speed`, где-то `enable_text_splitting`. Падать из-за этого целиком
        глупо — синтез важнее тонкой настройки, поэтому неизвестный параметр
        просто уходит, о чём говорится в лог.
        """
        kw = dict(
            temperature=self.temperature,
            length_penalty=self.length_penalty,
            repetition_penalty=self.repetition_penalty,
            top_k=self.top_k,
            top_p=self.top_p,
            speed=max(0.5, min(2.0, speed or 1.0)),
            enable_text_splitting=False,
        )
        for _ in range(len(kw) + 1):
            try:
                return self._model.inference(text, lang, latent, emb, **kw)["wav"]
            except TypeError as e:
                msg = str(e)
                dropped = next((n for n in list(kw) if n in msg), None)
                if dropped is None:
                    raise
                kw.pop(dropped)
                _log("параметр «%s» этой версии неизвестен — синтезирую без него"
                     % dropped)
        raise RuntimeError("inference не принял ни одного набора параметров")

    def idle_check(self) -> None:
        """Уйти целиком, если долго не звали.

        Не «выгрузить модель», а именно завершить процесс — и вот почему.
        Замер на станции: после выгрузки модели видеопамять возвращается, а
        хостовая — нет, 5,25 ГБ как держались, так и держатся. Их держит не
        модель, а сам torch со своими кэшами, и отпустить их изнутри процесса
        нечем. На станции пятнадцать гигабайт и сосед — языковая модель,
        которой на подъём нужно восемь: пока эти пять лежали мёртвым грузом,
        её llama-server не поднимался за пять минут, а чат отвечал «сервер
        недоступен».

        Уход стоит недорого: контейнер поднимает `--restart unless-stopped`
        за секунды, а первая фраза после простоя и так оплачивала загрузку
        модели — теперь к ней добавляется только старт процесса.
        """
        if self.idle_unload_sec <= 0:
            return
        if time.time() - self._last_used < self.idle_unload_sec:
            return
        if not self.loaded and self._last_used == 0.0:
            return                      # ни разу не работали — уходить не с чем
        _log("простой дольше %.0fs — ухожу, память вернётся станции "
             "(поднимусь на первой же фразе)" % self.idle_unload_sec)
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except Exception:
            pass
        os._exit(0)


def _patch_audio_loader() -> None:
    """Научить torchaudio читать наши WAV без torchcodec.

    С torch 2.9 у torchaudio не осталось собственных бэкендов чтения: он зовёт
    torchcodec, а тот линкуется с libtorch по строгой паре версий и на этой
    сборке не грузится вовсе («Could not load this library»). Гоняться за
    совпадением версий незачем: XTTS читает ровно один файл — образец голоса,
    а его пишем мы сами и всегда в WAV. Разбираем модулем `wave` из стандартной
    библиотеки, всё остальное оставляем прежнему загрузчику.
    """
    try:
        import numpy as np
        import torch
        import torchaudio
    except Exception:
        return
    original = getattr(torchaudio, "load", None)

    def load(path, *args, **kwargs):
        name = path if isinstance(path, str) else getattr(path, "name", "")
        if isinstance(name, str) and name.lower().endswith(".wav"):
            try:
                with wave.open(name, "rb") as w:
                    rate = w.getframerate()
                    width = w.getsampwidth()
                    channels = w.getnchannels()
                    raw = w.readframes(w.getnframes())
                dtype = {1: np.uint8, 2: np.int16, 4: np.int32}.get(width)
                if dtype is not None:
                    a = np.frombuffer(raw, dtype=dtype).astype(np.float32)
                    if width == 1:
                        a = (a - 128.0) / 128.0
                    else:
                        a = a / float(np.iinfo(dtype).max)
                    a = a.reshape(-1, channels).T.copy()
                    return torch.from_numpy(a), rate
            except Exception as e:
                _log("свой разбор WAV не удался (%s) — отдаю прежнему" % e)
        if original is None:
            raise RuntimeError("нечем прочитать %r" % (name,))
        return original(path, *args, **kwargs)

    torchaudio.load = load
    _log("загрузчик аудио заменён на свой (WAV без torchcodec)")


def _rss_mb() -> int:
    """Сколько хостовой памяти занимает процесс. Читаем /proc, а не ставим
    psutil: одна строка против ещё одной зависимости в образе."""
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 0


def _vram_mb() -> tuple:
    """(занято, всего) видеопамяти по драйверу — вся карта, включая соседей."""
    import glob
    for used in sorted(glob.glob(
            "/sys/class/drm/card*/device/mem_info_vram_used")):
        try:
            with open(used) as f:
                u = int(f.read().strip())
            with open(used.replace("_used", "_total")) as f:
                t = int(f.read().strip())
            if t > 0:
                return u // 1048576, t // 1048576
        except Exception:
            continue
    return 0, 0


def parse_multipart(body: bytes, boundary: str) -> dict:
    """Разбор multipart/form-data без внешних библиотек.

    Тот же разбор, что у соседних серверов: полей мало, они плоские, и тащить
    ради них зависимость в контейнер незачем.
    """
    out = {}
    sep = ("--" + boundary).encode()
    for part in body.split(sep):
        if not part or part in (b"--\r\n", b"--"):
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        if not _:
            continue
        name = ""
        for line in head.split(b"\r\n"):
            if b"Content-Disposition" in line:
                m = re.search(rb'name="([^"]*)"', line)
                if m:
                    name = m.group(1).decode("utf-8", "replace")
        if not name:
            continue
        out[name] = data.rstrip(b"\r\n")
    return out


ENGINE: Engine = None  # заполняется в main()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):        # тише стандартного лога
        pass

    def _json(self, obj, code: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _wav(self, data: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> bytes:
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def do_GET(self):
        # `/health` — ради единообразия с соседним сервером: скрипт выкладки
        # ждёт готовности именно по нему, и один общий адрес проверки дешевле
        # двух разных в двух скриптах.
        if self.path.rstrip("/") in ("", "/status", "/health"):
            self._json(ENGINE.status())
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.rstrip("/")
        if path == "/config":
            try:
                cfg = json.loads(self._body().decode("utf-8") or "{}")
            except Exception:
                cfg = {}
            ENGINE.apply_config(cfg if isinstance(cfg, dict) else {})
            self._json(ENGINE.status())
            return
        if path == "/load":
            self._body()
            if not ENGINE.paused:
                threading.Thread(target=ENGINE.warm, daemon=True).start()
            self._json(ENGINE.status())
            return
        if path == "/unload":
            self._body()
            ENGINE.unload()
            self._json(ENGINE.status())
            return
        if path != "/inference_zero_shot":
            self._json({"error": "not found"}, 404)
            return

        ctype = self.headers.get("Content-Type", "")
        m = re.search(r"boundary=([^;]+)", ctype)
        if not m:
            self._json({"error": "нужен multipart/form-data"}, 400)
            return
        fields = parse_multipart(self._body(), m.group(1).strip('"'))
        text = fields.get("tts_text", b"").decode("utf-8", "replace").strip()
        if not text:
            self._json({"error": "пустой tts_text"}, 400)
            return
        if ENGINE.paused:
            self._json({"error": "сервер на паузе"}, 503)
            return
        sha = fields.get("prompt_wav_sha", b"").decode("utf-8", "replace")
        try:
            ref = ENGINE.resolve_reference(fields.get("prompt_wav", b""), sha)
        except KeyError:
            # Клиент прислал только сумму, а образца у нас нет. Это не ошибка,
            # а приглашение прислать файл — сайдкар знает этот ответ и повторит
            # запрос уже с ним.
            self._json({"error": "отпечатка не знаю", "need_prompt_wav": True},
                       409)
            return
        except Exception as e:
            self._json({"error": str(e)}, 400)
            return
        try:
            speed = float(fields.get("speed", b"1.0").decode() or 1.0)
        except Exception:
            speed = 1.0
        lang = fields.get("language", b"").decode("utf-8", "replace")
        try:
            self._wav(ENGINE.synthesize(text, ref, lang, speed))
        except Exception as e:
            _log("синтез не удался: %s" % e)
            self._json({"error": str(e)}, 500)


def _idle_watch() -> None:
    while True:
        time.sleep(30)
        try:
            ENGINE.idle_check()
        except Exception:
            pass


def main() -> int:
    global ENGINE
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("XTTS_PORT", DEFAULT_PORT)))
    ap.add_argument("--host", default=os.environ.get("XTTS_HOST", "0.0.0.0"))
    ap.add_argument("--cache-dir", default=os.environ.get("XTTS_CACHE", ""),
                    help="куда класть веса (иначе кэш TTS по умолчанию)")
    ap.add_argument("--device", default=os.environ.get("XTTS_DEVICE", "auto"),
                    choices=["auto", "cuda", "cpu"])
    ap.add_argument("--idle-unload", type=float,
                    default=float(os.environ.get("XTTS_IDLE", "900")))
    ap.add_argument("--warm", action="store_true",
                    help="поднять модель сразу, не дожидаясь первой фразы")
    args = ap.parse_args()

    # Без согласия с лицензией загрузчик весов ждёт ответа в консоли, которой у
    # службы нет, и сервер молча висит на старте.
    os.environ.setdefault("COQUI_TOS_AGREED", "1")

    ENGINE = Engine(cache_dir=args.cache_dir, device=args.device,
                    idle_unload_sec=args.idle_unload)
    if args.warm:
        threading.Thread(target=ENGINE.warm, daemon=True).start()
    threading.Thread(target=_idle_watch, daemon=True).start()

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    _log("слушаю %s:%d" % (args.host, args.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
