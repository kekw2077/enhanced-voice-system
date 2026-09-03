"""Сервер клон-голоса для живых ответов (MOSS-TTS-Nano, только процессор).

Второй сервер синтеза рядом с `qwen_tts_server.py`, и делят они работу так:

  * ЭТОТ — голос ассистента в разговоре. Крутится постоянно, считает на
    процессоре и видеокарты не касается вовсе. Потому и постоянный: раньше
    живые ответы озвучивал Qwen на карте, а карта одна, и языковой модели
    рядом с ним не оставалось места. Теперь карта под геммой всегда.
  * `qwen_tts_server.py` — студия голоса. Поднимается под открытую Sonora и
    выгружается, как только её закрыли; там качество важнее задержки, и
    четыре гигабайта видеопамяти на время работы студии — приемлемая цена.

Контракт HTTP тот же самый, что у Qwen-сервера, до последнего поля:

    GET  /                        -> {ok, loaded, paused, ...}
    POST /inference_zero_shot     multipart: tts_text, prompt_text, speed,
                                  language, prompt_wav_sha,
                                  prompt_wav=@ref.wav          -> audio/wav
    POST /config   {json}         -> живые настройки
    POST /load                    -> поднять модель заранее
    POST /unload                  -> отпустить память

Совпадение не ради красоты: на той стороне `CloneHttpEngine` из
`tts_engine.py`, и она уже умеет этот диалог — с контрольной суммой образца
вместо файла, с ответом 409 «отпечатка не знаю» и повтором. Свой диалект
означал бы второй движок в сайдкаре и его пересборку; общий контракт
означает смену одного адреса в настройках.

Чего здесь нет и почему:

  * Видеопамяти. Модель на 0.1B живёт в оперативной, и все рычаги
    Qwen-сервера — потолок VRAM, троттлинг, выгрузка по простою — тут просто
    не о чем. `/unload` оставлен ради единообразия и отпускает рантайм.
  * `speed`. Поле принимается для совместимости и не применяется — ровно как
    у соседа.
  * `language`. MOSS определяет язык сам по тексту; отдельного поля у него
    нет. Принимаем и игнорируем, чтобы клиент не менялся.

Запуск (в venv, где стоят onnxruntime, torch/torchaudio 2.7 и WeTextProcessing):

    python moss_tts_server.py --repo /path/to/MOSS-TTS-Nano --port 8761
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import logging
import os
import re
import sys
import tempfile
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 8761

# Сколько потоков отдать onnxruntime. Умолчание самого MOSS — четыре; на
# станции ядер двенадцать, и четыре из них означали бы треть скорости на
# ровном месте. Ноль — «взять сколько есть», решает `_resolve_threads`.
DEFAULT_THREADS = 0

# Параметры генерации. Это НЕ настройка на вкус: без них модель уходит в
# повтор и генерирует, пока не упрётся в потолок кадров. Проверено на станции —
# одна и та же фраза в 55 знаков давала то 0,6 секунды звука, то 30, потому что
# сервер полагался на умолчания манифеста, а те не совпадают с умолчаниями
# `infer_onnx.py`. Решающее здесь `audio_repetition_penalty`: без штрафа за
# повтор маленькая авторегрессионная модель зацикливается почти всегда.
#
# Значения взяты один в один из `infer_onnx.py` — эталонного запуска, на
# котором длительность держится ровно.
GENERATION_DEFAULTS = {
    "text_temperature": 1.0,
    "text_top_p": 1.0,
    "text_top_k": 50,
    "audio_temperature": 0.8,
    "audio_top_p": 0.95,
    "audio_top_k": 25,
    "audio_repetition_penalty": 1.2,
}

# «fixed» — режим сэмплирования из того же эталона. Жадное декодирование здесь
# не спасение, а наоборот: оно упирается в потолок кадров КАЖДЫЙ раз (проверено,
# три прогона из трёх), потому что без случайности зацикливание неизбежно.
SAMPLE_MODE = "fixed"
MAX_NEW_FRAMES = 375

# Знаков русской речи в минуте — та же оценка, что в приложении
# (`kSpeechCharsPerMinute`). Нужна не для красоты: по ней проверяется, не
# разогналась ли модель.
CHARS_PER_MINUTE = 900

# Во сколько раз готовый звук вправе отличаться от ожидаемой длительности.
# Границы широкие намеренно: темп речи гуляет, паузы между внутренними кусками
# тоже. Ловим не «чуть длиннее», а именно разгон — когда 55 знаков дают
# полминуты, или обрыв, когда дают полсекунды.
LENGTH_MIN, LENGTH_MAX = 0.45, 2.2

# Сколько раз пробовать заново, если длительность не сошлась.
RETRIES = 3

# Поднимать ли рантайм заново на каждый запрос.
#
# Это не перестраховка, а вывод из замера. `infer_onnx.py` — новый процесс на
# каждый прогон — попадает в ожидаемую длительность ВСЕГДА: шесть длин от 24 до
# 137 знаков, три разных образца, ни одного промаха. Тот же рантайм, живущий в
# сервере между запросами, врёт: 431 знак давал то 6.6, то 9.0, то 0.6 секунды
# вместо 28.7. Разница ровно одна — переиспользование, и что именно в нём
# накапливается, я не нашёл.
#
# Цена честности — 2.4 секунды на подъём рантайма перед каждым синтезом.
# Выключается через /config, если однажды причину найдут.
FRESH_RUNTIME = True

# Сколько знаков отдавать модели за раз. Не настройка на вкус: на 55 знаках она
# читает ровно, а на 431 обрывается после трети — три попытки из трёх дали 6.6,
# 9.0 и 0.6 секунды вместо ожидаемых 28.7. Потолок в сто двадцать знаков держит
# каждый кусок в той области, где модель надёжна.
MAX_PIECE_CHARS = 120

# Тишина на стыке кусков. Без неё предложения склеиваются встык и слышно шов;
# с большой паузой речь начинает спотыкаться.
PIECE_GAP_MS = 110


def _log(msg: str) -> None:
    print(f"[moss-tts] {msg}", flush=True)


class UnknownReference(Exception):
    """Отпечатка образца нет — пусть клиент пришлёт сам файл.

    Тот же смысл, что у соседа: обычно приезжает одна контрольная сумма, а
    полмегабайта wav на каждую фразу не гоняются.
    """


class MossEngine:
    def __init__(self, repo_dir: str, threads: int = DEFAULT_THREADS,
                 model_dir: str = "") -> None:
        self.repo_dir = os.path.abspath(repo_dir)
        self.model_dir = model_dir or ""
        self.threads = _resolve_threads(threads)
        self.paused = False
        self.gen = dict(GENERATION_DEFAULTS)
        self.sample_mode = SAMPLE_MODE
        self.max_new_frames = MAX_NEW_FRAMES
        self.max_piece_chars = MAX_PIECE_CHARS
        self.gap_ms = PIECE_GAP_MS
        self.fresh_runtime = FRESH_RUNTIME
        self._rt = None
        self._loading = False
        self._lock = threading.Lock()
        self._last_used = 0.0
        # Образец живёт файлом на диске: рантайм принимает путь, а не байты, и
        # держать его между запросами дешевле, чем принимать заново.
        self._ref_path = ""
        self._ref_sha = ""
        self._refs_dir = os.path.join(tempfile.gettempdir(), "moss-tts-refs")
        os.makedirs(self._refs_dir, exist_ok=True)

    # ---- состояние -------------------------------------------------------
    @property
    def loaded(self) -> bool:
        return self._rt is not None

    def status(self) -> dict:
        return {
            "ok": True,
            "name": "moss-tts-nano",
            "model": "OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX",
            "loaded": self.loaded,
            "loading": self._loading,
            "paused": self.paused,
            "device": "cpu",
            "threads": self.threads,
            "sample_mode": self.sample_mode,
            "max_new_frames": self.max_new_frames,
            "max_piece_chars": self.max_piece_chars,
            "gap_ms": self.gap_ms,
            "fresh_runtime": self.fresh_runtime,
            "generation": self.gen,
            "ref_sha": self._ref_sha,
        }

    def apply_config(self, cfg: dict) -> None:
        if "paused" in cfg:
            self.paused = bool(cfg["paused"])
            if self.paused:
                self.unload()
        if "threads" in cfg:
            try:
                t = _resolve_threads(int(cfg["threads"]))
            except Exception:
                t = self.threads
            if t != self.threads:
                self.threads = t
                # Число потоков задаётся при создании сессии, живой правке не
                # поддаётся — поэтому рантайм пересоздаётся.
                self.unload()
        if "sample_mode" in cfg:
            m = str(cfg["sample_mode"]).lower()
            if m in ("greedy", "fixed", "full"):
                self.sample_mode = m
        if "max_new_frames" in cfg:
            try:
                self.max_new_frames = max(32, int(cfg["max_new_frames"]))
            except Exception:
                pass
        if "max_piece_chars" in cfg:
            try:
                self.max_piece_chars = max(30, int(cfg["max_piece_chars"]))
            except Exception:
                pass
        if "fresh_runtime" in cfg:
            self.fresh_runtime = bool(cfg["fresh_runtime"])
        if "gap_ms" in cfg:
            try:
                self.gap_ms = max(0, min(2000, int(cfg["gap_ms"])))
            except Exception:
                pass
        # Параметры генерации правятся поштучно: прислали одну температуру —
        # меняется одна температура, остальное остаётся эталонным.
        for k in GENERATION_DEFAULTS:
            if k in cfg:
                try:
                    self.gen[k] = type(GENERATION_DEFAULTS[k])(cfg[k])
                except Exception:
                    pass
        _log(f"config: {self.status()}")

    # ---- модель ----------------------------------------------------------
    def _load(self) -> None:
        if self._rt is not None:
            return
        self._loading = True
        try:
            sys.path.insert(0, self.repo_dir)
            from onnx_tts_runtime import OnnxTtsRuntime  # noqa: E402

            t0 = time.time()
            _log(f"поднимаю рантайм на {self.threads} потоках…")
            kwargs = dict(thread_count=self.threads, execution_provider="cpu")
            if self.model_dir:
                kwargs["model_dir"] = self.model_dir
            self._rt = OnnxTtsRuntime(**kwargs)
            self._last_used = time.time()
            _log(f"готов за {time.time() - t0:.1f}s")
        finally:
            self._loading = False

    def warm(self) -> None:
        with self._lock:
            self._load()

    def unload(self) -> None:
        with self._lock:
            self._rt = None
        _log("рантайм отпущен")

    # ---- синтез ----------------------------------------------------------
    def _ref_file(self, sha: str) -> str:
        return os.path.join(self._refs_dir, f"{sha}.wav")

    def remember_reference(self, wav_bytes: bytes) -> str:
        sha = hashlib.sha256(wav_bytes).hexdigest()
        path = self._ref_file(sha)
        if not os.path.isfile(path):
            with open(path, "wb") as f:
                f.write(wav_bytes)
        self._ref_path, self._ref_sha = path, sha
        return sha

    def resolve_reference(self, wav_bytes: bytes, sha: str) -> str:
        """Путь к образцу: по присланному файлу или по одной его сумме."""
        if wav_bytes:
            self.remember_reference(wav_bytes)
            return self._ref_path
        sha = (sha or "").strip().lower()
        if not sha:
            raise ValueError("нужен образец голоса или его контрольная сумма")
        path = self._ref_file(sha)
        if not os.path.isfile(path):
            raise UnknownReference(sha)
        self._ref_path, self._ref_sha = path, sha
        return path

    def _synth_once(self, text: str, ref_path: str, seed: int) -> bytes:
        out = os.path.join(tempfile.gettempdir(),
                           f"moss-out-{os.getpid()}.wav")
        # Пишем в файл и читаем обратно, а не разбираем возвращаемую
        # структуру: у рантайма она менялась между версиями, а путь к файлу —
        # часть его же публичного вызова. Параметры генерации пишутся в
        # манифест перед КАЖДЫМ вызовом: часть из них рантайм читает оттуда, а
        # не из аргументов synthesize.
        self._rt.manifest["generation_defaults"].update(self.gen)
        self._rt.synthesize(
            text=text,
            prompt_audio_path=ref_path,
            output_audio_path=out,
            sample_mode=self.sample_mode,
            do_sample=self.sample_mode != "greedy",
            max_new_frames=self.max_new_frames,
            seed=seed,
            streaming=False,
        )
        with open(out, "rb") as f:
            data = f.read()
        try:
            os.remove(out)
        except Exception:
            pass
        return data

    def _synth_checked(self, text: str, ref_path: str) -> bytes:
        """Один кусок с проверкой длительности и повтором.

        ЗЕРНО. Без него один и тот же текст давал то полсекунды звука, то
        тридцать (замер на станции: 0.6s / 30.0s / 3.7s на 55 знаках). Дело не
        в модели: `infer_onnx.py` запускается новым процессом и каждый раз
        стартует с одного состояния генератора случайных чисел, а сервер живёт
        долго — состояние уплывает от запроса к запросу. Зерно считается из
        самого текста: одна фраза всегда звучит одинаково, разные фразы не
        делят одну случайность.

        ПРОВЕРКА ДЛИТЕЛЬНОСТИ. Детерминизм лишь закрепляет результат, а тот
        бывает и плохим. Поэтому звук сверяется с ожидаемой длиной по числу
        знаков, и на обрыве или разгоне попытка повторяется с другим зерном.
        Из попыток берётся ближайшая к ожидаемой: отдать лучшую честнее, чем
        последнюю.
        """
        want = max(0.4, len(text) * 60.0 / CHARS_PER_MINUTE)
        base = int(hashlib.sha256(text.encode("utf-8")).hexdigest()[:8], 16)
        best, best_miss = b"", float("inf")
        for attempt in range(RETRIES):
            if self.fresh_runtime:
                self._rt = None
                self._load()
            data = self._synth_once(text, ref_path, base + attempt)
            got = _wav_seconds(data)
            ratio = got / want if want > 0 else 0.0
            miss = abs(ratio - 1.0)
            if miss < best_miss:
                best, best_miss = data, miss
            if LENGTH_MIN <= ratio <= LENGTH_MAX:
                return best
            _log(f"  кусок «{text[:28]}…»: {got:.1f}s вместо ~{want:.1f}s "
                 f"— пробую другое зерно")
        return best

    def synthesize(self, text: str, ref_path: str) -> bytes:
        """Готовый WAV. Длинный текст режется и собирается обратно.

        Своя нарезка вместо той, что есть у рантайма: его внутренняя не
        спасала — 431 знак обрывался после трети текста. Модель надёжна на
        коротком куске и ненадёжна на длинном, поэтому длинного она здесь
        просто не видит.
        """
        pieces = _split_pieces(text, self.max_piece_chars)
        if not pieces:
            raise ValueError("пустой текст")
        with self._lock:
            self._load()
            t0 = time.time()
            wavs = [self._synth_checked(p, ref_path) for p in pieces]
            self._last_used = time.time()
            took = self._last_used - t0
        out = _join_wavs(wavs, self.gap_ms)
        _log(f"синтез: {len(text)} знаков, кусков {len(pieces)}, за "
             f"{took:.2f}s -> {_wav_seconds(out):.1f}s звука "
             f"(ожидали ~{len(text) * 60.0 / CHARS_PER_MINUTE:.1f}s)")
        return out


def _resolve_threads(n: int) -> int:
    if n and n > 0:
        return int(n)
    try:
        # Оставляем пару ядер станции: на ней живут ещё и языковая модель, и
        # распознавание, и забирать процессор целиком под озвучку невежливо.
        return max(1, (os.cpu_count() or 4) - 2)
    except Exception:
        return 4


# Конец предложения: знак и закрывающая кавычка либо скобка после него.
_SENT_END = re.compile(r'([.!?…]+["»”)\]]*)\s+')


def _split_pieces(text: str, limit: int) -> list:
    """Текст на куски, которые модель дочитывает до конца.

    Режем по концам предложений и набираем до предела; предложение длиннее двух
    пределов доламываем по запятой, а если и её нет — по пробелу. Внутри слова
    не режем: обрубок движок прочитает как отдельное слово.
    """
    text = " ".join(text.split())
    if not text:
        return []
    if len(text) <= limit:
        return [text]
    sents, start = [], 0
    for m in _SENT_END.finditer(text):
        s = text[start:m.end()].strip()
        if s:
            sents.append(s)
        start = m.end()
    tail = text[start:].strip()
    if tail:
        sents.append(tail)

    out, buf = [], ""
    for s in sents:
        while len(s) > limit * 2:
            cut = s.rfind(",", 0, limit)
            if cut <= 0:
                cut = s.rfind(" ", 0, limit)
            if cut <= 0:
                cut = limit
            out.append(s[:cut + 1].strip())
            s = s[cut + 1:].strip()
        if buf and len(buf) + 1 + len(s) > limit:
            out.append(buf)
            buf = s
        else:
            buf = (buf + " " + s).strip() if buf else s
    if buf:
        out.append(buf)
    return [x for x in out if x]


def _join_wavs(parts: list, gap_ms: int) -> bytes:
    """Куски в одну дорожку. Формат у всех один — их сделал один и тот же движок."""
    parts = [p for p in parts if p]
    if not parts:
        return b""
    if len(parts) == 1:
        return parts[0]
    buf = io.BytesIO()
    out = None
    for idx, data in enumerate(parts):
        rd = wave.open(io.BytesIO(data))
        if out is None:
            out = wave.open(buf, "wb")
            out.setnchannels(rd.getnchannels())
            out.setsampwidth(rd.getsampwidth())
            out.setframerate(rd.getframerate())
        if idx and gap_ms > 0:
            n = int(rd.getframerate() * gap_ms / 1000.0)
            out.writeframes(bytes(n * rd.getnchannels() * rd.getsampwidth()))
        out.writeframes(rd.readframes(rd.getnframes()))
        rd.close()
    out.close()
    return buf.getvalue()


def _wav_seconds(data: bytes) -> float:
    try:
        w = wave.open(io.BytesIO(data))
        return w.getnframes() / float(w.getframerate())
    except Exception:
        return 0.0


# --------------------------------------------------------------------------
# Разбор multipart/form-data — тот же, что у Qwen-сервера (в 3.13 нет `cgi`).
# --------------------------------------------------------------------------
def parse_multipart(body: bytes, boundary: str) -> dict:
    out: dict = {}
    sep = ("--" + boundary).encode()
    for part in body.split(sep):
        if not part or part in (b"--\r\n", b"--", b"\r\n"):
            continue
        part = part.lstrip(b"\r\n")
        head, _, payload = part.partition(b"\r\n\r\n")
        if not _:
            head, _, payload = part.partition(b"\n\n")
        if not _:
            continue
        headers = head.decode("utf-8", "replace")
        name = ""
        for token in headers.split(";"):
            token = token.strip()
            if token.startswith("name="):
                name = token[5:].strip('"\r\n ')
        if not name:
            continue
        payload = payload.rstrip(b"\r\n")
        out[name] = payload if b"filename=" in head else \
            payload.decode("utf-8", "replace")
    return out


ENGINE: MossEngine | None = None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # тише стандартного лога
        return

    def _json(self, obj: dict, status: int = 200) -> None:
        blob = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def _body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/status"):
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
        elif path == "/load":
            self._body()
            if not ENGINE.paused:
                threading.Thread(target=ENGINE.warm, daemon=True).start()
            self._json(ENGINE.status())
        elif path == "/unload":
            self._body()
            ENGINE.unload()
            self._json(ENGINE.status())
        elif path == "/inference_zero_shot":
            self._synth()
        else:
            self._json({"error": "not found"}, 404)

    def _synth(self) -> None:
        if ENGINE.paused:
            # Тот же код, что у соседа: по нему сайдкар уходит на кэш и Piper.
            self._json({"error": "paused"}, 503)
            return
        ctype = self.headers.get("Content-Type", "")
        if "boundary=" not in ctype:
            self._json({"error": "expected multipart/form-data"}, 400)
            return
        form = parse_multipart(self._body(),
                               ctype.split("boundary=", 1)[1].strip().strip('"'))
        text = (form.get("tts_text") or "").strip()
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace").strip()
        ref_wav = form.get("prompt_wav") or b""
        if isinstance(ref_wav, str):
            ref_wav = ref_wav.encode("utf-8")
        sha = form.get("prompt_wav_sha") or ""
        if isinstance(sha, bytes):
            sha = sha.decode("utf-8", "replace")
        if not text:
            self._json({"error": "empty tts_text"}, 400)
            return
        try:
            ref_path = ENGINE.resolve_reference(ref_wav, sha)
        except UnknownReference:
            self._json({"error": "unknown_ref"}, 409)
            return
        except ValueError as e:
            self._json({"error": str(e)}, 400)
            return
        try:
            wav = ENGINE.synthesize(text, ref_path)
        except Exception as e:
            logging.exception("synthesis failed")
            self._json({"error": str(e)}, 500)
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.end_headers()
        self.wfile.write(wav)


def main() -> int:
    global ENGINE
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.environ.get("MOSS_REPO", ""),
                    help="папка с исходниками MOSS-TTS-Nano")
    ap.add_argument("--model-dir", default=os.environ.get("MOSS_MODEL_DIR", ""),
                    help="папка с ONNX-моделями (по умолчанию — <repo>/models)")
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("MOSS_PORT", DEFAULT_PORT)))
    ap.add_argument("--host", default=os.environ.get("MOSS_HOST", "0.0.0.0"))
    ap.add_argument("--threads", type=int,
                    default=int(os.environ.get("MOSS_THREADS", DEFAULT_THREADS)))
    ap.add_argument("--warm", action="store_true",
                    help="поднять модель сразу, не дожидаясь первой фразы")
    args = ap.parse_args()
    if not args.repo:
        print("нужен --repo с исходниками MOSS-TTS-Nano", file=sys.stderr)
        return 2

    ENGINE = MossEngine(args.repo, threads=args.threads,
                        model_dir=args.model_dir)
    if args.warm:
        threading.Thread(target=ENGINE.warm, daemon=True).start()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    _log(f"слушаю {args.host}:{args.port}, потоков {ENGINE.threads}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
