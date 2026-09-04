"""Генерация картинок на станции. Контракт зеркалит синтез голоса — приложение
уже умеет так разговаривать, второго диалекта заводить незачем:

    GET  /  |  /health          -> JSON: загружена ли модель, чем считает
    GET  /progress              -> ход текущего кадра
    GET  /models                -> что лежит на диске, что выбрано, сколько места
    POST /models/select         -> {model} сменить текущую
    POST /models/pull           -> {url, name} скачать в фоне
    GET  /models/pull           -> ход скачивания
    POST /models/pull/cancel    -> прервать
    POST /models/delete         -> {name} удалить файл
    POST /models/note           -> {model, note} сведения о модели (рекомендации
                                   авторов: сила подсказки, шаги, сэмплер)
    GET  /loras                 -> довески LoRA на диске
    POST /loras/pull            -> {url, name} скачать довесок
    POST /loras/delete          -> {name} удалить довесок
    POST /load                  -> занять видеопамять заранее
    POST /unload                -> освободить видеопамять
    POST /generate              -> JSON {prompt, model, negative, steps, width,
                                          height, seed, cfg, sampler,
                                          loras:[{name,weight}], face,
                                          hires} -> PNG

Выгрузка тут не роскошь, а условие работы: на станции одна карта, и языковая
модель с генератором на ней не помещаются.

**Карту освобождает сам сервер, а не приложение.** Раньше это делал клиент при
открытии студии — и этого хватало ровно до первого запроса к Ollama, который
возвращал языковую модель обратно. А у Ollama на станции `OLLAMA_KEEP_ALIVE=-1`,
то есть вернувшаяся модель остаётся навсегда, и следующая генерация падает с
«HIP out of memory». Клиент не может за этим уследить: он не знает, когда сосед
проснулся. Сервер знает точно — ему память нужна вот сейчас, — поэтому
освобождение стоит непосредственно перед загрузкой весов, а не за минуты до неё.
Клиентская выгрузка при этом остаётся: она убирает ожидание с первого кадра.
"""
import glob
import io
import json
import os
import re
import shutil
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS_DIR = os.environ.get("IMG_MODELS_DIR", "/models")
# Совместимость со старым развёртыванием: раньше путь к единственному чекпоинту
# задавался целиком. Теперь это лишь подсказка, какой из файлов брать по
# умолчанию.
LEGACY_MODEL = os.environ.get("IMG_MODEL", "").strip()
PORT = int(os.environ.get("IMG_PORT", "8770"))
# Через сколько секунд простоя отдавать видеопамять обратно. 0 — держать.
IDLE_UNLOAD = float(os.environ.get("IMG_IDLE_UNLOAD", "600"))
# Соседи по видеокарте. Пусто — не трогать; так сервер остаётся пригодным и на
# машине, где он один.
FREE_OLLAMA = os.environ.get("IMG_FREE_OLLAMA", "").strip().rstrip("/")
# Соседей по синтезу двое, и это не дублирование: студийный голос (Sonora) и
# живой (ответы ассистента) — разные серверы на разных портах. Пока здесь стоял
# один адрес, живой оставался на карте и в неё же грузились веса кадра: 4
# сентября 2026 это уронило станцию — карта ушла в вытеснение видеопамяти, а
# ядро в `svm_range_restore_work`. Список через запятую.
FREE_TTS = [u.strip().rstrip("/")
            for u in os.environ.get("IMG_FREE_TTS", "").split(",") if u.strip()]

# Сколько видеопамяти должно остаться свободной, чтобы браться за веса. Меньше
# — отказ, и это лучший исход из возможных: в полную карту грузится не «чуть
# медленнее», а насмерть, вместе со станцией. Замер: модель просит около семи
# гигабайт.
MIN_FREE_MB = int(os.environ.get("IMG_MIN_FREE_MB", "7000"))

MODEL_SUFFIXES = (".safetensors", ".ckpt")
# Довески лежат ПОДКАТАЛОГОМ в том же томе: они меняются чаще моделей и
# весят в тридцать раз меньше, но живут ровно там же и переживают образ.
LORA_DIR = os.path.join(MODELS_DIR, "lora")
# Определитель лиц для второго прохода. Кладётся в том рядом с весами; без
# файла проход просто не делается — это не повод отказывать в кадре.
FACE_MODEL = os.path.join(MODELS_DIR, "face_yolov8n.pt")
# Насколько расширяем найденную рамку. Сеть отдаёт лицо впритык, а дорисовывать
# надо с запасом: иначе шов ложится по краю подбородка, где его видно больше
# всего.
FACE_PAD = 0.22
# Размах рабочего размера для дорисовки лица. Смысл прохода — в масштабе:
# лицо на общем плане занимает считанные клетки латента, и подробностям взяться
# неоткуда; вырезанное и растянутое, оно считается как отдельный кадр.
#
# Но растягивать НАДО НЕ ВСЕГДА, и это стоило замера: на крупном плане лицо и
# так было 674 пикселя, растяжение до 768 и обратно уронило его резкость с 797
# до 455. Два лишних пересчёта размера съедают больше, чем добавляет проход.
# Поэтому: меньше нижней границы — растягиваем, внутри размаха — работаем как
# есть, больше верхней — ужимаем (иначе не хватит видеопамяти).
FACE_MIN = 512
FACE_MAX = 1024
# Лицо крупнее этого проходить незачем: выигрыш прохода — в растяжении, а
# растягивать тут нечего. Замерено на крупном плане, где лицо занимало
# 793x1014: проход уронил его резкость с 403 до 327. Считать надо по НАЙДЕННОЙ
# рамке, до расширения — расширенная упирается в край кадра и уже не говорит о
# том, насколько лицо крупное.
FACE_SKIP_ABOVE = 512
# Увеличение кадра с дорисовкой. Растянуть и переписать — не то же самое, что
# просто растянуть: растяжение добавляет пикселей, но не подробностей, а
# дорисовка вписывает в новые пиксели то, чего в маленьком кадре не помещалось.
# Сила намеренно небольшая: выше 0,5 меняется сама картинка, а не её мелочи.
HIRES_STRENGTH = 0.35

# Сэмплеры. Имя слева — то, что присылает приложение; справа — класс diffusers
# и его особые настройки. Список короткий намеренно: у SDXL разница между
# соседними вариантами внутри семейства меньше, чем разброс от смены зерна, а
# длинный список создаёт впечатление выбора там, где его нет.
SAMPLERS = {
    "euler_a": ("EulerAncestralDiscreteScheduler", {}),
    "euler": ("EulerDiscreteScheduler", {}),
    "dpmpp_2m": ("DPMSolverMultistepScheduler", {}),
    "dpmpp_2m_karras": ("DPMSolverMultistepScheduler",
                        {"use_karras_sigmas": True}),
    "ddim": ("DDIMScheduler", {}),
}
DEFAULT_SAMPLER = "euler_a"
# Сила подсказки. Умолчание diffusers — 7,5, но авторы чекпоинтов этой ветки
# рекомендуют 5: при 7,5 картинка «пережарена», контуры резче, цвета грубее.
DEFAULT_CFG = 5.0
# По этим словам в имени файла модель считается ускоренной (turbo/lightning и
# родня). У таких сила подсказки равна единице, а при ней негативный запрос НЕ
# РАБОТАЕТ вовсе — не «работает хуже», а не участвует в счёте. Это догадка по
# имени, и приложение так её и подаёт.
DISTILLED_HINTS = ("turbo", "lightning", "lcm", "hyper", "flash", "dmd")

_lock = threading.Lock()
# Отдельный замок на всю генерацию. Нужен по двум причинам, и обе стоили
# отказов: во-первых, карта одна, и два кадра разом на ней не считаются;
# во-вторых, сторож простоя мог выгрузить модель ПОСРЕДИ запроса — запрос
# досчитывал на своей ссылке, а следующий строил вторую копию, и на карте
# оказывалось два конвейера вместо одного (13,7 ГБ при модели в семь).
_gen_lock = threading.Lock()
_pipe = None
# Идёт ли прямо сейчас подъём весов. Нужен снаружи: приложение показывает в
# панели «Модели на карте», что модель поднимается, а не просто «выгружена» —
# подъём занимает секунд двадцать, и всё это время карточка врала бы.
_loading = False
_last_use = 0.0
_device = "неизвестно"
_model_name = ""
_face_net = None
# Что за довески сейчас применены: список пар (имя файла, вес).
_loras = []
# Ход текущей генерации: на каком шаге из скольких. Кадр считается больше
# минуты, и без этого ожидание неотличимо от зависания. Отдаётся отдельным
# запросом, а не в поток картинки: так контракт /generate остаётся прежним, и
# старый клиент ничего не замечает.
_progress = {"running": False, "step": 0, "total": 0, "started": 0.0,
             "stage": ""}
# Ход скачивания модели — той же формы и по той же причине.
_pull = {"running": False, "name": "", "done": 0, "total": 0, "error": "",
         "started": 0.0, "cancel": False}


# Кто держит карту прямо сейчас. Карта одна, а просящих двое: приложение на
# компьютере (языковая модель, ~8 ГБ) и приложение на телефоне (картинки, ~7).
#
# Отодвигать соседей сервер умел с самого начала — free_gpu() перед загрузкой
# весов. Обратной стороны не было: пока телефон считал кадр, разговор на
# компьютере упирался в занятую карту. Ollama грузила модель поверх картинок и
# уходила считать на процессор, а следующий кадр выгонял её посреди ответа.
#
# Аренда — это заявка «карта моя на столько-то секунд». Пока она держится,
# генерация не отказывает, а ЖДЁТ и говорит об этом в /progress: телефону есть
# что показать человеку, кроме молчаливой полосы ожидания.
_hold = {"who": "", "note": "", "until": 0.0, "since": 0.0}
_hold_lock = threading.Lock()
# Дольше десяти минут карту не держит никто. Срок — не формальность: заявку
# снимает тот, кто её взял, а он может не дожить до этого (закрыли окно,
# оборвалась сеть, упало приложение). Без срока телефон остался бы без карты
# до тех пор, пока кто-нибудь не заметит и не перезапустит сервер.
HOLD_MAX = 600


def log(msg: str) -> None:
    print(f"[img] {msg}", flush=True)


def hold_active() -> bool:
    return _hold["until"] > time.time()


def hold_state():
    left = _hold["until"] - time.time()
    if left <= 0:
        return {"who": "", "note": "", "left": 0}
    return {"who": _hold["who"], "note": _hold["note"], "left": round(left, 1)}


def hold_take(who: str, note: str, sec: float):
    """Занять карту. Возвращается, когда карта ДЕЙСТВИТЕЛЬНО свободна.

    Порядок важен: сначала заявка, потом выгрузка. Наоборот — и очередь успела
    бы занять карту в промежутке между выгрузкой и заявкой."""
    sec = max(5.0, min(float(HOLD_MAX), float(sec or 90)))
    renew = _hold["who"] == who and hold_active()
    with _hold_lock:
        _hold["who"] = who or "сосед"
        _hold["note"] = note or ""
        _hold["until"] = time.time() + sec
        if not renew:
            _hold["since"] = time.time()
    if not renew:
        log(f"карту просит {who or 'сосед'} на {sec:.0f} с: {note}")
        # Ждём конца текущего кадра и снимаем веса с карты. Не выдёргиваем:
        # оборванный на середине кадр — это потерянная минута счёта.
        unload_pipe()
        log("карта отдана")
    return hold_state()


def hold_release(who: str = ""):
    if _hold["who"] and who and who != _hold["who"]:
        # Чужую заявку не снимаем: иначе телефон, закрывая свой экран, снял бы
        # заявку компьютера посреди ответа.
        return hold_state()
    with _hold_lock:
        _hold["who"] = ""
        _hold["note"] = ""
        _hold["until"] = 0.0
        _hold["since"] = 0.0
    log("карта освобождена")
    return hold_state()


def wait_for_hold(limit: float = HOLD_MAX + 60, skip_who: str = "") -> None:
    """Дождаться, пока сосед отпустит карту. Ждём, а не отказываем: запрос
    телефона никуда не денется, а отказ пришлось бы повторять руками.

    [skip_who] — кто спрашивает. Держатель заявки собственной заявки не ждёт:
    иначе клиент, взявший карту под серию кадров, встал бы в очередь сам к
    себе и простоял до конца срока."""
    if not hold_active():
        return
    if skip_who and skip_who == _hold["who"]:
        return
    # Человеку на телефоне показывается пояснение, а не служебное имя, по
    # которому сверяются заявки.
    who = _hold["note"] or _hold["who"] or "сосед"
    log(f"карту держит {who} — жду")
    _progress.update(running=True, step=0, total=0, started=time.time(),
                     stage=f"ждём: {who}")
    end = time.time() + limit
    while hold_active() and time.time() < end:
        time.sleep(0.5)
    _progress.update(running=False, step=0, total=0, stage="")
    log("карта свободна — берусь за кадр")


# --- модели на диске -------------------------------------------------------

def list_models():
    out = []
    try:
        names = sorted(os.listdir(MODELS_DIR))
    except OSError:
        return out
    for n in names:
        if not n.lower().endswith(MODEL_SUFFIXES):
            continue
        p = os.path.join(MODELS_DIR, n)
        if not os.path.isfile(p):
            continue
        try:
            st = os.stat(p)
        except OSError:
            continue
        low = n.lower()
        out.append({
            "name": n, "size": st.st_size, "mtime": int(st.st_mtime),
            # Догадка по имени: ускоренные модели считают кадр без сравнения с
            # негативным запросом, и поле для него надо гасить, а не делать вид.
            "distilled": any(h in low for h in DISTILLED_HINTS),
            "note": read_note(n),
        })
    return out


def note_path(name: str) -> str:
    return os.path.join(MODELS_DIR, name + ".json")


def read_note(name: str):
    """Рекомендации авторов модели, если их кто-то положил рядом с весами.

    Лежат отдельным файлом, а не в коде сервера: модели приходят и уходят, а
    сведения о них должны приходить и уходить вместе с ними."""
    try:
        with open(note_path(name), encoding="utf-8") as f:
            n = json.load(f)
        return n if isinstance(n, dict) else None
    except (OSError, ValueError):
        return None


def list_loras():
    out = []
    try:
        names = sorted(os.listdir(LORA_DIR))
    except OSError:
        return out
    for n in names:
        if not n.lower().endswith(MODEL_SUFFIXES):
            continue
        p = os.path.join(LORA_DIR, n)
        if not os.path.isfile(p):
            continue
        try:
            out.append({"name": n, "size": os.path.getsize(p)})
        except OSError:
            continue
    return out


def adapter_id(name: str) -> str:
    """Имя довеска для PEFT. Точкам и дефисам там не место, а имя файла из них
    состоит наполовину."""
    return "".join(c if c.isalnum() else "_" for c in name)[:60]


def valid_name(name: str) -> bool:
    """Имя файла, а не путь. Проверка отдельная, потому что имя приходит
    снаружи и попадает в `os.path.join` — без неё «../../etc/passwd» был бы
    таким же законным запросом, как «animagine.safetensors»."""
    if not name or name != os.path.basename(name):
        return False
    if not name.lower().endswith(MODEL_SUFFIXES):
        return False
    return re.fullmatch(r"[A-Za-z0-9._@+-]{1,160}", name) is not None


def pick_default() -> str:
    names = [m["name"] for m in list_models()]
    if not names:
        return ""
    if LEGACY_MODEL:
        b = os.path.basename(LEGACY_MODEL)
        if b in names:
            return b
    return names[0]


def free_bytes() -> int:
    try:
        return shutil.disk_usage(MODELS_DIR).free
    except OSError:
        return 0


# --- видеопамять и соседи --------------------------------------------------

def vram():
    """(занято, всего) в байтах по данным драйвера; (0, 0) — не удалось.

    Читаем sysfs, а не torch: нас интересует вся карта целиком, включая чужие
    процессы, а torch видит только собственные тензоры. Именно эта разница и
    прятала причину отказов — «свободно 8 ГБ» по torch при 500 МБ на деле."""
    for used in sorted(glob.glob("/sys/class/drm/card*/device/mem_info_vram_used")):
        total = used.replace("_used", "_total")
        try:
            with open(used) as f:
                u = int(f.read().strip())
            with open(total) as f:
                t = int(f.read().strip())
        except (OSError, ValueError):
            continue
        if t > 0:
            return u, t
    return 0, 0


def _http(url: str, data=None, timeout=60):
    req = urllib.request.Request(
        url, data=data,
        method="POST" if data is not None else "GET",
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def free_gpu():
    """Попросить соседей отдать видеопамять и дождаться, пока драйвер её вернёт.

    Возвращает список того, что удалось выгрузить. Отказ соседа — не ошибка:
    может, его просто нет на этой машине. Ошибкой это станет ниже, при загрузке
    весов, и там о ней скажут по-человечески."""
    freed = []
    if FREE_OLLAMA:
        try:
            raw = _http(FREE_OLLAMA + "/api/ps", timeout=10)
            models = (json.loads(raw or b"{}") or {}).get("models") or []
        except Exception as e:
            models = []
            log(f"Ollama не ответила ({e}) — пропускаю")
        for m in models:
            name = (m or {}).get("model") or (m or {}).get("name")
            if not name:
                continue
            # Отдельной команды «выгрузи» у Ollama нет: выгрузка — это её же
            # обычный запрос с keep_alive: 0.
            body = json.dumps({"model": name, "keep_alive": 0}).encode()
            try:
                _http(FREE_OLLAMA + "/api/generate", body, timeout=90)
                freed.append(name)
            except Exception as e:
                log(f"не выгрузилась {name}: {e}")
    for url in FREE_TTS:
        who = url.split("//")[-1]
        try:
            _http(url + "/unload", b"", timeout=60)
            freed.append("синтез речи (%s)" % who)
        except Exception as e:
            log(f"синтез {who} не выгрузился: {e}")
    if freed:
        log("прошу освободить карту: " + ", ".join(freed))
        # Драйвер отдаёт память не в тот же миг, когда процесс её отпустил.
        # Ждём, пока занятое перестанет убывать, но не дольше полуминуты.
        u, t = vram()
        deadline = time.time() + 30
        while t and time.time() < deadline:
            time.sleep(1.0)
            u2, t = vram()
            if u2 >= u - (64 << 20):
                break
            u = u2
    u, t = vram()
    if t:
        log(f"видеопамять: занято {u / 2 ** 30:.1f} из {t / 2 ** 30:.1f} ГБ")
    return freed


def require_room() -> None:
    """Отказаться от загрузки, если на карте нет места. Отказ — это ответ.

    Соседей просят освободиться, но просьба не приказ: Ollama может быть занята
    ответом, сервер синтеза — фразой, а карта у станции одна. Раньше сервер в
    таком случае всё равно брался за веса, и дальше решал уже драйвер: он
    начинал вытеснять видеопамять в хостовую, та уходила в подкачку, и станция
    вставала целиком — не «медленно», а до кнопки питания. Пусть лучше кадр не
    посчитается и об этом скажут словами.
    """
    u, t = vram()
    if not t:
        return                      # драйвер молчит — решать не по чему
    free_mb = (t - u) >> 20
    if free_mb >= MIN_FREE_MB:
        return
    raise RuntimeError(
        "на видеокарте свободно %d МБ из %d, для модели нужно %d — сосед не "
        "отпустил карту. Кадр не считаю: загрузка в полную карту вешает "
        "станцию. Попробуйте ещё раз через несколько секунд."
        % (free_mb, t >> 20, MIN_FREE_MB))


# --- конвейер --------------------------------------------------------------

# Сколько видеопамяти просит декодер на пиксель кадра, когда считает его
# целиком. Замерено на этой карте: 1024x1024 требовал 2,25 ГБ ОДНИМ куском.
DECODE_BYTES_PER_PIXEL = 2400
# Сколько видеопамяти успевает занять сам обход по шагам к моменту, когда
# доходит до декодера. Замерено на этой карте: перед кадром свободно 4,6 ГБ, к
# декодированию остаётся 1,4 — за время счёта уходит ещё больше трёх.
RUN_RESERVE = 3 << 30


def tile_vae(pipe, size: int) -> bool:
    """Заставить декодер считать кадр по плиткам не крупнее `size` пикселей;
    `size = 0` — вернуть счёт целым кадром.

    Одного `enable_tiling()` мало, и это стоило нескольких неверных диагнозов.
    Порог у SDXL — 1024, а решение принимается по РАЗМЕРУ ЛАТЕНТА, поэтому
    кадр 1024x1024 под порезку не попадает: вызов проходит без ошибок, флаг
    честно стоит True, а декодер по-прежнему считает кадр целиком. Опускать
    нужно оба порога — и по кадру, и по латенту."""
    try:
        vae = pipe.vae
        scale = 2 ** (len(vae.config.block_out_channels) - 1)
        if not hasattr(pipe, "_evs_tile_default"):
            pipe._evs_tile_default = getattr(vae, "tile_sample_min_size", 1024)
        if size <= 0:
            base = pipe._evs_tile_default
            vae.tile_sample_min_size = base
            vae.tile_latent_min_size = max(1, int(base // scale))
            return True
        if getattr(vae, "tile_sample_min_size", None) == size:
            return True
        vae.enable_tiling()
        vae.enable_slicing()
        vae.tile_sample_min_size = size
        vae.tile_latent_min_size = max(1, int(size // scale))
        log(f"декодер считает кадр по плиткам {size} px — иначе не хватит памяти")
        return True
    except Exception as e:
        log(f"порезку кадра включить не удалось: {e}")
        return False


def _build_pipe(path: str):
    import torch
    from diffusers import StableDiffusionXLPipeline
    cuda = torch.cuda.is_available()   # на ROCm это тоже True
    global _device
    _device = "видеокарта" if cuda else "процессор"
    log(f"загружаю {os.path.basename(path)} на {_device}")
    if cuda:
        free_gpu()
        require_room()
    t0 = time.time()
    # from_single_file — потому что чекпоинты сообщества раздаются одним
    # .safetensors, а не деревом каталогов diffusers.
    pipe = StableDiffusionXLPipeline.from_single_file(
        path,
        torch_dtype=torch.float16 if cuda else torch.float32,
        use_safetensors=True,
    )
    pipe = pipe.to("cuda" if cuda else "cpu")
    pipe.set_progress_bar_config(disable=True)
    if cuda:
        # Декодирование готового кадра — самое прожорливое место: SDXL
        # переводит VAE в полную точность и просит разом больше двух
        # гигабайт, отчего генерация падала при живых соседях на карте.
        # Порезка на плитки считает картинку по кускам: пик памяти падает
        # в разы, а результат тот же.
        try:
            # Порезку включаем У САМОГО декодера, а не только через
            # обёртку конвейера: обёртка в этой версии diffusers до него не
            # доходит, и кадр по-прежнему считался целиком. Видно было по
            # трассировке — свёртка в resnet.py просила 4,5 ГБ одним куском.
            if hasattr(pipe, "vae"):
                try:
                    pipe.vae.enable_tiling()
                    pipe.vae.enable_slicing()
                except Exception:
                    pass
                # И не переводить декодер в полную точность. SDXL делает это
                # из-за переполнения в половинной у ЭТАЛОННОГО декодера;
                # у дообученных моделей свой, и он с половинной справляется.
                # Перевод же удваивает расход ровно в самом дорогом месте.
                try:
                    pipe.vae.config.force_upcast = False
                except Exception:
                    pass
            pipe.enable_vae_tiling()
            pipe.enable_vae_slicing()
            # Внимание считается по частям. На этой карте быстрый путь
            # (memory-efficient attention) помечен экспериментальным, и
            # torch считает внимание в лоб — материализует матрицу целиком
            # и просит 4,5 ГБ одним куском на кадре 1024x1024. Порезка
            # делает то же самое по частям: медленнее на проценты, но
            # генерация перестаёт падать при живых соседях на карте.
            pipe.enable_attention_slicing()
        except Exception as e:
            log(f"порезка недоступна: {e}")
        # Печатаем ФАКТИЧЕСКОЕ состояние, а не «включили». Половина попыток
        # починить нехватку памяти ушла на то, что вызовы отрабатывали без
        # ошибок, а флаги оставались прежними: обёртка конвейера не доходила
        # до декодера, а присваивание в конфиг молча не приживалось.
        try:
            vae = pipe.vae
            log("VAE: порезка={} срезы={} полная точность={} тип={} плитка={}"
                .format(getattr(vae, "use_tiling", None),
                        getattr(vae, "use_slicing", None),
                        vae.config.force_upcast, vae.dtype,
                        getattr(vae, "tile_sample_min_size", None)))
        except Exception:
            pass
    log(f"загружено за {time.time() - t0:.1f} с")
    return pipe


def set_sampler(pipe, name: str) -> str:
    """Поменять сэмплер. Настройка берётся у ИСХОДНОГО планировщика модели, а
    не у текущего: иначе особенности предыдущего выбора (те же сигмы Карраса)
    переползают в следующий, и «вернул как было» возвращает не как было."""
    key = (name or DEFAULT_SAMPLER).strip().lower()
    if key not in SAMPLERS:
        key = DEFAULT_SAMPLER
    cls_name, extra = SAMPLERS[key]
    try:
        import diffusers
        base = getattr(pipe, "_evs_sched_config", None) or pipe.scheduler.config
        cls = getattr(diffusers, cls_name)
        if type(pipe.scheduler).__name__ != cls_name or extra:
            pipe.scheduler = cls.from_config(base, **extra)
    except Exception as e:
        log(f"сэмплер {key} не применился: {e}")
    return key


def detect_faces(image):
    """Рамки лиц на готовом кадре. Пусто — если нечего или нечем.

    Каскады OpenCV тут не годятся, и это проверено: на наклонённом лице
    аниме-каскад отдавал рамку 77 пикселей там, где лицо занимало 340, —
    то есть находил глаз. Небольшая сеть отдаёт ту же картинку рамкой
    464x447 с уверенностью 0,88."""
    if not os.path.isfile(FACE_MODEL):
        return []
    try:
        import numpy as np
        from ultralytics import YOLO
        global _face_net
        if _face_net is None:
            _face_net = YOLO(FACE_MODEL)
        res = _face_net.predict(np.asarray(image)[:, :, ::-1], conf=0.35,
                                verbose=False)[0]
        out = []
        for b in res.boxes:
            x1, y1, x2, y2 = (int(v) for v in b.xyxy[0].tolist())
            if x2 - x1 >= 24 and y2 - y1 >= 24:
                out.append((x1, y1, x2, y2))
        return out
    except Exception as e:
        log(f"лица не искались: {e}")
        return []


def _face_box(box, w, h):
    """Расширить рамку, сделать квадратной и не вылезти за край кадра."""
    x1, y1, x2, y2 = box
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    side = max(x2 - x1, y2 - y1) * (1 + 2 * FACE_PAD)
    side = min(side, w, h)
    x1 = int(max(0, min(w - side, cx - side / 2)))
    y1 = int(max(0, min(h - side, cy - side / 2)))
    side = int(side)
    return x1, y1, x1 + side, y1 + side


def _feather(size, radius):
    """Мягкая маска под вклейку: в середине непрозрачно, к краю сходит на нет.
    Без неё по границе вырезанного квадрата остаётся отчётливый шов."""
    from PIL import Image, ImageDraw, ImageFilter
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([radius, radius, size - radius, size - radius],
                        radius=radius, fill=255)
    return m.filter(ImageFilter.GaussianBlur(radius * 0.6))


# Слова, ради которых стоит унести подсказку в проход по лицу: внешность
# должна совпасть с кадром, качество — остаться заданным. Всё прочее (общий
# план, город, ночь) на вырезе лица только мешает.
FACE_KEEP = ("hair", "eyes", "eye", "masterpiece", "best quality", "absurdres",
             "score", "aesthetic", "highres", "detailed", "1girl", "1boy",
             "solo", "skin", "smile", "blush", "freckles", "glasses")
FACE_LEAD = "face focus, portrait, detailed face, detailed eyes"


def face_prompt_for(prompt: str) -> str:
    """Подсказка для прохода по лицу.

    Сценическую подсказку на вырез лица подавать нельзя, и это видно глазами:
    с «full body, wide shot, city street» модель пытается нарисовать в лице
    целую сцену, и лицо покрывается радужным мусором. Оставляем только то, что
    описывает саму внешность и качество."""
    keep = []
    for tag in prompt.split(","):
        t = tag.strip()
        low = t.lower()
        if t and any(k in low for k in FACE_KEEP):
            keep.append(t)
    return ", ".join([FACE_LEAD] + keep) if keep else FACE_LEAD


def _img2img(pipe):
    """Конвейер дорисовки из ТЕХ ЖЕ частей: веса общие, второй копии модели на
    карте не появляется."""
    from diffusers import StableDiffusionXLImg2ImgPipeline
    i2i = getattr(pipe, "_evs_i2i", None)
    if i2i is None:
        i2i = StableDiffusionXLImg2ImgPipeline(**pipe.components)
        i2i.set_progress_bar_config(disable=True)
        pipe._evs_i2i = i2i
    return i2i


def face_pass(pipe, image, strength, steps, cfg, prompt, negative, gen):
    """Дорисовать каждое найденное лицо отдельным проходом и вклеить обратно.

    Отказ здесь не должен стоить всего кадра: человек уже подождал минуту, и
    отдать картинку без прохода честнее, чем ошибку вместо неё."""
    from PIL import Image
    boxes = detect_faces(image)
    if not boxes:
        log("лиц не найдено — второй проход пропущен")
        return image, 0
    try:
        i2i = _img2img(pipe)
        # На время прохода возвращаем декодеру полную точность. В основном
        # кадре она не нужна и стоит памяти, но здесь картинка проходит через
        # VAE ДВАЖДЫ — сперва внутрь, потом наружу, — и в половинной точности
        # это переполняется: лицо покрывается радужными разводами. Видно только
        # глазами: резкость при этом РАСТЁТ, потому что разводы — тоже перепад.
        import torch
        prev_upcast = pipe.vae.config.force_upcast
        pipe.vae.config.force_upcast = True
        done = 0
        for i, b in enumerate(boxes):
            found = max(b[2] - b[0], b[3] - b[1])
            if found >= FACE_SKIP_ABOVE:
                log(f"лицо {found} px — и так крупное, проход не нужен")
                continue
            x1, y1, x2, y2 = _face_box(b, image.width, image.height)
            side = x2 - x1
            _progress["stage"] = f"лицо {i + 1} из {len(boxes)}"
            crop = image.crop((x1, y1, x2, y2))
            # Рабочий размер кратен восьми: сеть считает в латенте, который
            # ровно во столько раз мельче.
            work = max(FACE_MIN, min(FACE_MAX, (side + 7) // 8 * 8))
            if work != side:
                crop = crop.resize((work, work), Image.LANCZOS)
            # Чем сильнее растянули вырез, тем размытее вход и тем больше надо
            # переписать. При силе 0,4 на вырезе, растянутом вчетверо, модель
            # не может восстановить размытое и досочиняет радужный мусор —
            # проверено глазами, метрика резкости при этом РАСТЁТ и обманывает.
            eff = min(0.75, strength * max(1.0, work / max(1, side)))
            out = i2i(prompt=face_prompt_for(prompt),
                      negative_prompt=negative, image=crop, strength=eff,
                      guidance_scale=cfg, num_inference_steps=steps,
                      generator=gen).images[0]
            if out.size != (side, side):
                out = out.resize((side, side), Image.LANCZOS)
            image.paste(out, (x1, y1), _feather(side, max(8, side // 10)))
            done += 1
        log(f"второй проход: дорисовано лиц {done}")
        return image, done
    except Exception as e:
        log(f"второй проход не выполнен: {e}")
        return image, 0
    finally:
        _progress["stage"] = ""
        # Вернуть как было: полная точность у декодера — временная мера на
        # время прохода, а кадр целиком в ней считать нам не по памяти.
        try:
            pipe.vae.config.force_upcast = prev_upcast
            if not prev_upcast:
                pipe.vae.to(dtype=torch.float16)
        except Exception:
            pass


def hires_pass(pipe, image, scale, steps, cfg, prompt, negative, emb, gen):
    """Растянуть готовый кадр и переписать его в новом размере.

    В отличие от прохода по лицу подсказка здесь ОБЩАЯ, а не своя: переписывается
    весь кадр целиком, и композиция должна остаться той же."""
    from PIL import Image
    w = max(8, int(image.width * scale) // 8 * 8)
    h = max(8, int(image.height * scale) // 8 * 8)
    try:
        i2i = _img2img(pipe)
        big = image.resize((w, h), Image.LANCZOS)
        _progress.update({"running": True, "step": 0, "total": steps,
                          "started": time.time(), "stage": "увеличение"})

        def _tick(_p, step, _t, kw):
            _progress["step"] = step + 1
            return kw

        # Кадр в полтора раза больше исходного декодеру целиком не по силам —
        # режем всегда, а не по расчёту свободной памяти.
        tile_vae(pipe, 512)
        kw = dict(image=big, strength=HIRES_STRENGTH, guidance_scale=cfg,
                  num_inference_steps=steps, generator=gen,
                  callback_on_step_end=_tick)
        if emb is not None:
            pe, pooled, ne, npooled = emb
            out = i2i(prompt_embeds=pe, pooled_prompt_embeds=pooled,
                      negative_prompt_embeds=ne,
                      negative_pooled_prompt_embeds=npooled, **kw).images[0]
        else:
            out = i2i(prompt=prompt, negative_prompt=negative, **kw).images[0]
        log(f"кадр увеличен до {out.width}x{out.height}")
        return out
    except Exception as e:
        # Как и с лицом: отказ здесь не должен стоить всего кадра.
        log(f"увеличение не выполнено: {e}")
        return image
    finally:
        _progress["stage"] = ""


def _pad_pair(c, a, b):
    """Выровнять длину двух наборов эмбеддингов кусками пустого текста.

    Модель требует, чтобы запрос и негативный запрос совпадали по длине, а
    длина у них разная: каждый режется на куски по 77 токенов, и кусков выходит
    разное число. У compel для этого есть свой помощник, но на SDXL он падает —
    `empty_z` есть только у одноко­дировщикового провайдера, а здесь их два.
    Дополняем тем же, чем дополнил бы он: кодировкой пустой строки."""
    import torch
    empty, _ = c("")
    want = max(a.shape[1], b.shape[1])

    def pad(t):
        while t.shape[1] < want:
            need = want - t.shape[1]
            t = torch.cat([t, empty[:, :min(need, empty.shape[1]), :]], dim=1)
        return t

    return pad(a), pad(b)


def encode_prompts(pipe, prompt: str, negative: str):
    """Запрос длиннее 77 токенов — по кускам, а не обрезком.

    CLIP принимает 77 токенов, и всё сверх этого diffusers молча отбрасывает:
    в журнале станции это выглядело как «190 > 77», а на картинке — как будто
    половину запроса не читали. Compel режет текст на куски, кодирует каждый и
    склеивает — так работают все настольные оболочки. Возвращает None, если
    почему-то не вышло: тогда идём прежним путём, с обрезком, но с записью в
    журнал, а не молча."""
    try:
        from compel import Compel, ReturnedEmbeddingsType
        c = getattr(pipe, "_evs_compel", None)
        if c is None:
            c = Compel(
                tokenizer=[pipe.tokenizer, pipe.tokenizer_2],
                text_encoder=[pipe.text_encoder, pipe.text_encoder_2],
                returned_embeddings_type=(
                    ReturnedEmbeddingsType.PENULTIMATE_HIDDEN_STATES_NON_NORMALIZED),
                requires_pooled=[False, True],
                truncate_long_prompts=False)
            pipe._evs_compel = c
        pe, pooled = c(prompt)
        ne, npooled = c(negative or "")
        if pe.shape[1] != ne.shape[1]:
            pe, ne = _pad_pair(c, pe, ne)
        return pe, pooled, ne, npooled
    except Exception as e:
        log(f"длинный запрос не собрался ({e}) — будет обрезан на 77 токенах")
        return None


def _apply_loras(want):
    """Привести набор довесков к запрошенному. Звать под уже взятым `_lock`.

    Возвращает True, если конвейер надо пересобрать с нуля.

    Отключение довеска — не просто снятие веса. Замерено: после первого же
    подключения кадр по тому же зерну не повторяется в точности НИ ОДНИМ из
    способов отключения — ни снятием (`unload_lora_weights`), ни весом 0, ни
    удалением адаптера; расхождение у всех трёх одинаковое (10,6 при 0,0 у двух
    чистых прогонов подряд). Значит дело не в остатках веса, а в том, что PEFT
    один раз оборачивает слои и обратно их не разворачивает. Разница не в
    качестве — это просто другая выборка, — но обещание «снял довесок и вернулся
    к чистой модели» должно быть честным, поэтому набор всегда собирается на
    свежем конвейере."""
    global _loras
    if [n for n, _ in _loras] == [n for n, _ in want]:
        if _loras != want and want:
            _pipe.set_adapters([adapter_id(n) for n, _ in want],
                               adapter_weights=[w for _, w in want])
            _loras = list(want)
        return False
    if _loras:
        return True     # что-то снимаем или меняем — только пересборкой
    for n, _w in want:
        if not valid_name(n):
            raise RuntimeError(f"недопустимое имя довеска: {n}")
        path = os.path.join(LORA_DIR, n)
        if not os.path.isfile(path):
            raise RuntimeError(f"нет довеска: {n}")
        try:
            _pipe.load_lora_weights(LORA_DIR, weight_name=n,
                                    adapter_name=adapter_id(n))
        except Exception as e:
            # Довесок от другой ветки моделей (SD 1.5 к SDXL) — обычное дело, и
            # сказать об этом надо словами, а не трассировкой на весь экран.
            raise RuntimeError(f"довесок {n} не подошёл к этой модели: {e}")
    if want:
        _pipe.set_adapters([adapter_id(n) for n, _ in want],
                           adapter_weights=[w for _, w in want])
        log("довески: " + ", ".join(f"{n} x{w:g}" for n, w in want))
    _loras = list(want)
    return False


def load_pipe(name: str = "", loras=None):
    global _pipe, _model_name, _loras, _loading
    want_loras = [(str(x.get("name") or ""), float(x.get("weight", 1.0)))
                  for x in (loras or []) if isinstance(x, dict)
                  and str(x.get("name") or "")]
    with _lock:
        want = (name or _model_name or pick_default()).strip()
        if not want:
            raise RuntimeError(
                f"в {MODELS_DIR} нет ни одного чекпоинта (*.safetensors)")
        if not valid_name(want):
            raise RuntimeError(f"недопустимое имя модели: {want}")
        path = os.path.join(MODELS_DIR, want)
        if not os.path.isfile(path):
            raise RuntimeError(f"нет файла модели: {want}")
        if _pipe is not None and _model_name == want:
            if not _apply_loras(want_loras):
                return _pipe
            log("набор довесков изменился — собираю конвейер заново")
            _drop_pipe()
            _loras = []
        elif _pipe is not None:
            log(f"смена модели: {_model_name} -> {want}")
            _drop_pipe()
            _loras = []
        _loading = True
        try:
            _pipe = _build_pipe(path)
        finally:
            _loading = False
        # Настройка исходного планировщика — до того, как её кто-то подменил.
        try:
            _pipe._evs_sched_config = _pipe.scheduler.config
        except Exception:
            pass
        _model_name = want
        _loras = []
        _apply_loras(want_loras)
        return _pipe


def _restart_soon(why: str) -> None:
    """Уйти на перезапуск: контейнер поднимет процесс сам.

    Крайняя мера и единственная надёжная. Если после выгрузки модель осталась
    на карте, изнутри процесса её уже не отнять — `empty_cache` кэш отдаёт, а
    живые тензоры нет. Наблюдалось редко и невоспроизводимо, держатель по
    записи в журнале — чей-то словарь; пока причина не найдена, лучше две
    секунды на перезапуск, чем занятая карта до тех пор, пока кто-нибудь не
    заметит. Скачивание при этом не прерываем: его терять больнее."""
    if _pull.get("running"):
        log("память не освободилась, но идёт скачивание — перезапуск отложен")
        return
    log("перезапускаюсь: " + why)

    def _boom():
        # Дать ответу дойти до клиента, потом уходить.
        time.sleep(1.0)
        os._exit(1)

    threading.Thread(target=_boom, daemon=True).start()


def _drop_pipe() -> None:
    """Отпустить конвейер и вернуть память. Зовётся под уже взятым `_lock`."""
    global _pipe
    # Слабая ссылка на самую тяжёлую часть. Если после сборки мусора она жива —
    # значит «выгружено» неправда, и кто-то её держит. Имена держателей важнее
    # самого факта: без них поиск сводится к угадыванию, а угадывал я уже трижды.
    probe = None
    probe_pipe = None
    try:
        import weakref
        if _pipe is not None:
            probe = weakref.ref(_pipe.unet)
            probe_pipe = weakref.ref(_pipe)
    except Exception:
        pass
    _pipe = None
    try:
        import gc
        import torch
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass
    try:
        if probe is not None and probe() is not None:
            import gc as _gc
            parts = []
            for r in _gc.get_referrers(probe()):
                if isinstance(r, dict):
                    keys = [k for k in list(r)[:14] if isinstance(k, str)]
                    owners = sorted({type(o).__name__
                                     for o in _gc.get_referrers(r)})[:4]
                    parts.append("dict(%s) <- %s"
                                 % (",".join(keys)[:120], ",".join(owners)))
                else:
                    parts.append(type(r).__name__)
            log("ВНИМАНИЕ: модель жива после выгрузки, держат: "
                + " | ".join(parts)[:600])
            # Кто держит САМ конвейер — вот это и есть искомое: словари выше
            # принадлежат ему же, и без этой строки поиск упирается в них.
            if probe_pipe is not None and probe_pipe() is not None:
                who = []
                for r in _gc.get_referrers(probe_pipe()):
                    if isinstance(r, dict):
                        who.append("dict(%s)"
                                   % ",".join(str(k) for k in list(r)[:8])[:90])
                    elif isinstance(r, (list, tuple, set)):
                        who.append(type(r).__name__)
                    else:
                        who.append(type(r).__name__)
                log("держат конвейер: " + " | ".join(who)[:400])
            _restart_soon("память не освободилась после выгрузки")
    except Exception:
        pass


def unload_pipe() -> None:
    # Ждём конца генерации, а не выдёргиваем модель у неё из-под рук.
    with _gen_lock:
        _unload_now()


def _unload_now() -> None:
    with _lock:
        if _pipe is None:
            return
        _drop_pipe()
        log("модель выгружена, видеопамять освобождена")


def idle_watch() -> None:
    if IDLE_UNLOAD <= 0:
        return
    while True:
        time.sleep(30)
        # Пока считается кадр — не трогаем.
        if _gen_lock.locked():
            continue
        if _pipe is not None and _last_use and \
                time.time() - _last_use > IDLE_UNLOAD:
            unload_pipe()


# --- скачивание моделей ----------------------------------------------------

def pull_worker(url: str, name: str, dest_dir: str = "") -> None:
    dest_dir = dest_dir or MODELS_DIR
    os.makedirs(dest_dir, exist_ok=True)
    tmp = os.path.join(dest_dir, name + ".part")
    dst = os.path.join(dest_dir, name)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "evs-image/1"})
        with urllib.request.urlopen(req, timeout=60) as r:
            total = int(r.headers.get("Content-Length") or 0)
            _pull["total"] = total
            # Запас в два гигабайта — не суеверие: на этом же диске лежат кэши
            # и система, и полностью забитый раздел ломает не только скачивание.
            free = free_bytes()
            if total and free < total + (2 << 30):
                raise RuntimeError(
                    f"на диске свободно {free / 2 ** 30:.1f} ГБ, "
                    f"а нужно {(total + (2 << 30)) / 2 ** 30:.1f} ГБ")
            with open(tmp, "wb") as f:
                while True:
                    if _pull["cancel"]:
                        raise RuntimeError("отменено")
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    _pull["done"] += len(chunk)
        os.replace(tmp, dst)
        log(f"скачано: {name} ({_pull['done'] / 2 ** 30:.1f} ГБ)")
    except Exception as e:
        _pull["error"] = str(e)
        log(f"не скачалось {name}: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass
    finally:
        _pull["running"] = False


# --- HTTP ------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}") or {}
        except Exception:
            return {}

    def _status(self):
        used, total = vram()
        # Цифры самого torch рядом с драйверными. Расхождение между ними — это
        # и есть ответ на вопрос «кто держит память»: если torch говорит, что
        # у него ноль, а драйвер показывает гигабайты, значит держит не наш
        # тензор, а кэш распределителя или чужой процесс.
        t_alloc = t_res = -1
        try:
            import torch
            if torch.cuda.is_available():
                t_alloc = round(torch.cuda.memory_allocated() / 2 ** 20)
                t_res = round(torch.cuda.memory_reserved() / 2 ** 20)
        except Exception:
            pass
        return {"engine": "sdxl", "loaded": _pipe is not None,
                "loading": _loading,
                "device": _device,
                "model": _model_name or pick_default(),
                "loaded_model": _model_name if _pipe is not None else "",
                "vram_used_mb": round(used / 2 ** 20) if total else 0,
                "vram_total_mb": round(total / 2 ** 20) if total else 0,
                "torch_alloc_mb": t_alloc,
                "torch_reserved_mb": t_res,
                "idle_unload_sec": IDLE_UNLOAD,
                "hold": hold_state()}

    def _models(self):
        return {"dir": MODELS_DIR, "free": free_bytes(),
                "current": _model_name or pick_default(),
                "loaded": _model_name if _pipe is not None else "",
                "items": list_models()}

    def do_GET(self):
        path = self.path.rstrip("/")
        if path == "/progress":
            p = {k: v for k, v in _progress.items()}
            p["elapsed"] = round(time.time() - p["started"], 1) if p["started"] else 0
            # Кто держит карту — здесь же, а не отдельным запросом: клиент и так
            # опрашивает ход раз в секунду, и второй опрос был бы данью форме.
            p["hold"] = hold_state()
            self._json(p)
        elif path == "/models":
            self._json(self._models())
        elif path == "/loras":
            self._json({"dir": LORA_DIR, "free": free_bytes(),
                        "active": [{"name": n, "weight": w} for n, w in _loras],
                        "items": list_loras()})
        elif path == "/gpu":
            self._json(hold_state())
        elif path == "/models/pull":
            p = {k: v for k, v in _pull.items()}
            p["elapsed"] = round(time.time() - p["started"], 1) if p["started"] else 0
            self._json(p)
        elif path in ("", "/health", "/status"):
            self._json(self._status())
        else:
            self._json({"error": "not_found"}, 404)

    def do_POST(self):
        path = self.path.rstrip("/")
        try:
            if path == "/unload":
                unload_pipe()
                self._json(self._status())
                return
            if path == "/load":
                load_pipe(str(self._body().get("model") or "").strip())
                self._json(self._status())
                return
            if path == "/gpu/hold":
                b = self._body()
                self._json(hold_take(str(b.get("who") or "сосед"),
                                     str(b.get("note") or ""),
                                     b.get("sec") or 90))
                return
            if path == "/gpu/release":
                self._json(hold_release(str(self._body().get("who") or "")))
                return
            if path == "/models/select":
                self._select(self._body())
                return
            if path == "/models/pull":
                self._start_pull(self._body())
                return
            if path == "/models/pull/cancel":
                _pull["cancel"] = True
                self._json({"ok": True})
                return
            if path == "/models/note":
                self._note(self._body())
                return
            if path == "/loras/pull":
                self._start_pull(self._body(), LORA_DIR)
                return
            if path == "/loras/delete":
                self._delete_lora(self._body())
                return
            if path == "/models/delete":
                self._delete(self._body())
                return
            if path != "/generate":
                self._json({"error": "not_found"}, 404)
                return
            # Тело читается ОДИН раз: второе чтение того же сокета вернёт
            # пустоту, а круг ниже может пойти по второму разу.
            req = self._body()
            # Генерации выстраиваются в очередь: карта одна.
            #
            # Заявка соседа проверяется дважды — до замка и под ним. Ждать под
            # замком нельзя: тот, кто берёт карту, сам ждёт конца текущего кадра
            # на этом же замке, и вышло бы, что каждый ждёт другого. Поэтому
            # ждём снаружи, а под замком только перепроверяем и идём на второй
            # круг, если заявка появилась, пока мы стояли в очереди.
            who = str(req.get("who") or "")
            while True:
                wait_for_hold(skip_who=who)
                with _gen_lock:
                    if hold_active():
                        continue
                    self._generate(req)
                    return
        except Exception as e:
            # Полная трассировка, а не только текст: «HIP out of memory» ничего
            # не говорит о том, КАКОЙ шаг просил память, а шагов в кадре три —
            # кодирование запроса, обход по шагам и декодирование картинки.
            import traceback
            log("ошибка:" + chr(10) + traceback.format_exc())
            try:
                self._json({"error": str(e)}, 500)
            except Exception:
                pass

    # --- обработчики ---

    def _select(self, req):
        global _model_name
        name = str(req.get("model") or "").strip()
        if not valid_name(name):
            self._json({"error": "bad name"}, 400)
            return
        if not os.path.isfile(os.path.join(MODELS_DIR, name)):
            self._json({"error": "not_found"}, 404)
            return
        # Только запоминаем выбор. Грузить сразу незачем: смена модели чаще
        # всего идёт перед следующей генерацией, и она загрузит сама — иначе
        # человек ждал бы минуту после каждого щелчка по списку.
        with _lock:
            if _pipe is not None and _model_name != name:
                _drop_pipe()
            _model_name = name
        log(f"выбрана модель: {name}")
        self._json(self._models())

    def _delete_lora(self, req):
        global _loras
        name = str(req.get("model") or req.get("name") or "").strip()
        if not valid_name(name):
            self._json({"error": "bad name"}, 400)
            return
        path = os.path.join(LORA_DIR, name)
        if not os.path.isfile(path):
            self._json({"error": "not_found"}, 404)
            return
        with _lock:
            # Удаляем то, что сейчас применено, — конвейер надо собрать заново,
            # иначе он останется с довеском, которого больше нет на диске.
            if any(n == name for n, _ in _loras):
                _drop_pipe()
                _loras = []
            os.remove(path)
        log(f"удалён довесок: {name}")
        self._json({"dir": LORA_DIR, "free": free_bytes(),
                    "active": [{"name": n, "weight": w} for n, w in _loras],
                    "items": list_loras()})

    def _start_pull(self, req, dest_dir: str = ""):
        if _pull["running"]:
            self._json({"error": "busy", "name": _pull["name"]}, 409)
            return
        url = str(req.get("url") or "").strip()
        name = str(req.get("name") or "").strip()
        if not url.startswith(("http://", "https://")):
            self._json({"error": "bad url"}, 400)
            return
        if not name:
            name = os.path.basename(url.split("?")[0])
        if not valid_name(name):
            self._json({"error": "bad name"}, 400)
            return
        dest = dest_dir or MODELS_DIR
        if os.path.isfile(os.path.join(dest, name)):
            self._json({"error": "exists"}, 409)
            return
        note = req.get("note")
        if isinstance(note, dict) and dest == MODELS_DIR:
            try:
                with open(note_path(name), "w", encoding="utf-8") as f:
                    json.dump(note, f, ensure_ascii=False, indent=1)
            except OSError:
                pass
        _pull.update({"running": True, "name": name, "done": 0, "total": 0,
                      "error": "", "started": time.time(), "cancel": False})
        threading.Thread(target=pull_worker, args=(url, name, dest),
                         daemon=True).start()
        log(f"качаю {name} из {url}")
        self._json({"ok": True, "name": name})

    def _note(self, req):
        name = str(req.get("model") or "").strip()
        if not valid_name(name):
            self._json({"error": "bad name"}, 400)
            return
        if not os.path.isfile(os.path.join(MODELS_DIR, name)):
            self._json({"error": "not_found"}, 404)
            return
        note = req.get("note")
        if note is None:
            try:
                os.remove(note_path(name))
            except OSError:
                pass
        elif isinstance(note, dict):
            with open(note_path(name), "w", encoding="utf-8") as f:
                json.dump(note, f, ensure_ascii=False, indent=1)
        else:
            self._json({"error": "bad note"}, 400)
            return
        self._json(self._models())

    def _delete(self, req):
        global _model_name
        name = str(req.get("model") or req.get("name") or "").strip()
        if not valid_name(name):
            self._json({"error": "bad name"}, 400)
            return
        path = os.path.join(MODELS_DIR, name)
        if not os.path.isfile(path):
            self._json({"error": "not_found"}, 404)
            return
        with _lock:
            if _model_name == name and _pipe is not None:
                _drop_pipe()
            os.remove(path)
            try:
                os.remove(note_path(name))
            except OSError:
                pass
            if _model_name == name:
                _model_name = ""
        log(f"удалена модель: {name}")
        self._json(self._models())

    def _generate(self, req):
        prompt = str(req.get("prompt") or "").strip()
        if not prompt:
            self._json({"error": "prompt required"}, 400)
            return
        # Отрицательный запрос по умолчанию — тот, который рекомендуют
        # авторы Animagine XL. Свой сочинять незачем: модель обучалась с
        # оценками качества в подписях, и слова вроде «low score» для неё
        # осмысленны, а для соседних моделей — пустой шум.
        negative = str(req.get("negative")
                       or "lowres, bad anatomy, bad hands, text, error, "
                          "missing fingers, extra digit, fewer digits, "
                          "cropped, worst quality, low quality, low score, "
                          "bad score, average score, signature, watermark, "
                          "username, blurry")
        steps = int(req.get("steps") or 28)
        width = int(req.get("width") or 1024)
        height = int(req.get("height") or 1024)
        seed = req.get("seed")
        model = str(req.get("model") or "").strip()
        try:
            cfg = float(req.get("cfg") or DEFAULT_CFG)
        except (TypeError, ValueError):
            cfg = DEFAULT_CFG
        sampler = str(req.get("sampler") or "").strip()
        # Порезка кадра: пусто — решаем сами по свободной памяти, 0 — считать
        # целиком, число — резать на плитки такого размера. Наружу вынесено
        # ради проверки: «портит ли порезка мелкие детали» — вопрос, на который
        # отвечают сравнением, а не рассуждением.
        tile_req = req.get("tile")
        want_loras = req.get("loras")
        if not isinstance(want_loras, list):
            want_loras = []
        # Сила второго прохода по лицу: 0 — не делать. Выше 0,6 модель начинает
        # рисовать другое лицо вместо того, чтобы дорисовать это.
        try:
            face = max(0.0, min(0.75, float(req.get("face") or 0)))
        except (TypeError, ValueError):
            face = 0.0
        # Во сколько раз увеличить готовый кадр. 0 или 1 — не увеличивать.
        try:
            hires = float(req.get("hires") or 0)
        except (TypeError, ValueError):
            hires = 0.0
        hires = 0.0 if hires <= 1.01 else min(2.0, hires)

        import torch
        # Соседа могло принести, пока модель уже лежала на карте: тогда
        # `load_pipe` ничего не грузит и освобождения не делает. Смотрим на
        # свободное место ДО кадра — это дешевле, чем узнать о нехватке через
        # четыре минуты счёта.
        if _pipe is not None:
            used, total = vram()
            if total and (total - used) < (2 << 30):
                log("перед кадром свободно мало — прошу соседей отойти")
                free_gpu()
        pipe = load_pipe(model, want_loras)
        # Резать ли кадр при декодировании, решаем ЗАРАНЕЕ. Узнать о нехватке
        # памяти на последнем шаге — значит выбросить всё время счёта: у кадра
        # 1024x1024 это две минуты. Считаем свободное место на карте целиком
        # (sysfs, а не torch: соседи для torch невидимы) и сравниваем с тем,
        # сколько декодер попросит одним куском.
        if tile_req is not None:
            tile_vae(pipe, int(tile_req))
        else:
            used, total = vram()
            if total:
                need = width * height * DECODE_BYTES_PER_PIXEL
                spare = total - used
                log(f"перед кадром свободно {spare / 2 ** 30:.1f} ГБ, "
                    f"декодеру нужно {(need + RUN_RESERVE) / 2 ** 30:.1f} ГБ")
                tile_vae(pipe, 512 if spare < need + RUN_RESERVE else 0)
        global _last_use
        _last_use = time.time()
        def _mkgen():
            """Свой источник случайности НА КАЖДУЮ попытку.

            Один на обе не годится: к повтору после нехватки памяти он уже
            израсходован, и кадр выходит другой — при том же заданном зерне.
            Ошибка тихая: картинка получается, просто не та, о которой
            просили, и повторить её потом нечем."""
            if seed is None:
                return None
            g = torch.Generator(
                device="cuda" if torch.cuda.is_available() else "cpu")
            g.manual_seed(int(seed))
            return g
        t0 = time.time()
        _progress.update({"running": True, "step": 0, "total": steps,
                          "started": t0})

        def _tick(_pipe, step, _timestep, kw):
            # Шаги считаются с нуля, а человеку привычнее с единицы.
            _progress["step"] = step + 1
            return kw

        used_sampler = set_sampler(pipe, sampler)
        emb = encode_prompts(pipe, prompt, negative)

        def _run(p):
            common = dict(num_inference_steps=steps, width=width,
                          height=height, generator=_mkgen(),
                          guidance_scale=cfg, callback_on_step_end=_tick)
            if emb is not None:
                pe, pooled, ne, npooled = emb
                return p(prompt_embeds=pe, pooled_prompt_embeds=pooled,
                         negative_prompt_embeds=ne,
                         negative_pooled_prompt_embeds=npooled,
                         **common).images[0]
            return p(prompt=prompt, negative_prompt=negative,
                     **common).images[0]

        try:
            try:
                image = _run(pipe)
            except RuntimeError as oom:
                # Не `torch.OutOfMemoryError`: имя этого класса переезжало между
                # версиями (`torch.cuda.OutOfMemoryError` — старое), а вот текст
                # «out of memory» одинаков и на CUDA, и на HIP. Всё остальное
                # пробрасываем дальше, чтобы не глотать настоящие ошибки.
                if "out of memory" not in str(oom).lower():
                    raise
                # Сосед мог занять карту уже ПОСЛЕ того, как мы загрузились:
                # у Ollama на станции модель не выгружается сама, и её мог
                # вернуть любой запрос из приложения. Просим место ещё раз и
                # повторяем — один раз, чтобы отказ не превратился в петлю.
                log("не хватило видеопамяти — освобождаю карту и пробую снова")
                log(f"torch занял {torch.cuda.memory_allocated() / 2 ** 20:.0f} МБ, "
                    f"держит {torch.cuda.memory_reserved() / 2 ** 20:.0f} МБ")
                _progress["running"] = False
                torch.cuda.empty_cache()
                free_gpu()
                # Пересобираем конвейер с нуля. Не из осторожности: за долгую
                # работу процесс может остаться с занятой памятью, которую
                # `empty_cache` не отдаёт, — тогда сервер отчитывается
                # «выгружено», а на карте держатся гигабайты, и никакое
                # освобождение соседей не помогает. Полная пересборка — 13
                # секунд и единственный надёжный выход из такого состояния.
                # Своя ссылка на конвейер должна умереть ДО выгрузки, иначе
                # выгрузка освободит только половину: старый конвейер жив, пока
                # его держит эта переменная, и новый ложится сверху.
                pipe = None
                emb = None
                _unload_now()
                pipe = load_pipe(model, want_loras)
                set_sampler(pipe, sampler)
                emb = encode_prompts(pipe, prompt, negative)
                # И режем кадр на плитки. В обычном порядке этого не делаем:
                # целый кадр даёт картинку без стыков, а места на свободной
                # карте хватает. Но выбор «со стыками» против «без картинки»
                # решается однозначно.
                tile_vae(pipe, 512)
                torch.cuda.empty_cache()
                _progress.update({"running": True, "step": 0, "total": steps,
                                  "started": time.time()})
                image = _run(pipe)
        finally:
            _progress["running"] = False
        if hires > 0:
            image = hires_pass(pipe, image, hires, max(12, steps), cfg,
                               prompt, negative, emb, _mkgen())
            try:
                torch.cuda.empty_cache()
            except Exception:
                pass
        # Лицо — ПОСЛЕ увеличения: на большом кадре оно крупнее, и дорисовка
        # ложится на большее число пикселей.
        if face > 0:
            image, _n = face_pass(pipe, image, face, max(12, steps), cfg,
                                  prompt, negative, _mkgen())
            try:
                torch.cuda.empty_cache()
            except Exception:
                pass
        log(f"кадр за {time.time() - t0:.1f} с "
        f"(сила {cfg:g}, {used_sampler}, {steps} шагов): {prompt[:60]}")
        # Отдаём кэш аллокатора сразу после кадра. Каждая генерация со
        # своим размером оставляет за собой куски разного калибра, и через
        # несколько кадров «свободной» памяти формально хватает, а цельного
        # куска под следующий шаг уже нет — падает с HIP out of memory.
        try:
            torch.cuda.empty_cache()
        except Exception:
            pass
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        data = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    _model_name = pick_default()
    try:
        os.makedirs(LORA_DIR, exist_ok=True)
    except OSError:
        pass
    threading.Thread(target=idle_watch, daemon=True).start()
    log(f"слушаю порт {PORT}, каталог {MODELS_DIR}, "
        f"модель по умолчанию {_model_name or 'нет'}")
    if FREE_OLLAMA or FREE_TTS:
        log(f"соседи по карте: ollama={FREE_OLLAMA or 'нет'}, "
            f"tts={FREE_TTS or 'нет'}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
