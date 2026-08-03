"""Нужен ли шумоподавление при вашем движке распознавания — замер, а не мнение.

Шумодав в EVS стоит перед распознаванием и работает на каждом кадре звука:
замер на машине разработки — 11,8% одного ядра постоянно, при том что само
распознавание вхолостую не стоит почти ничего. Он там ради слабой локальной
модели; сильной модели агрессивная чистка местами мешает — DeepFilterNet
выедает часть спектра вместе с шумом. Проверяется это только на своём голосе,
в своей комнате, на своих фразах.

    # записать фразы и сразу посчитать (нужен микрофон):
    .venv\\Scripts\\python.exe denoise_bench.py

    # только посчитать, по уже записанному:
    .venv\\Scripts\\python.exe denoise_bench.py --score

Фразы берутся из тех, что вы реально говорите (см. --phrases). Результат —
таблица «режим шумодава → доля ошибок в словах», по одним и тем же записям.
"""
import argparse
import os
import re
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stt_engine as se  # noqa: E402

MODELS = r"F:\EVS\userdata\models"
GIGAAM = os.path.join(MODELS, "gigaam-v3")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-audio")

PHRASES = [
    "пауза",
    "открой музыку",
    "включи трек",
    "открой браузер",
    "открой телегу",
    "громкость на двадцать",
    "следующий",
    "предыдущий",
    "громкость на пятьдесят",
    "открой валорант",
    "как дела",
    "какая погода в могилеве",
]


def norm(s: str) -> list:
    s = s.lower().replace("ё", "е")
    s = re.sub(r"[^\w\s]", " ", s)
    return s.split()


def wer(ref: str, hyp: str) -> float:
    """Доля ошибок в словах: расстояние Левенштейна по словам / число слов."""
    r, h = norm(ref), norm(hyp)
    if not r:
        return 0.0
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        d[i][0] = i
    for j in range(len(h) + 1):
        d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            cost = 0 if r[i - 1] == h[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    return d[len(r)][len(h)] / len(r)


# Ниже этого пика запись считается пустой. 500 из 32768 — заведомо ниже любой
# речи и заведомо выше цифрового нуля.
SILENT = 500


def peak_of(pcm: bytes) -> int:
    import numpy as np
    if not pcm:
        return 0
    return int(np.abs(np.frombuffer(pcm, dtype=np.int16)).max())


def list_devices() -> list:
    import sounddevice as sd
    out = []
    print("\nУстройства записи:")
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0:
            mark = "  <- по умолчанию" if i == sd.default.device[0] else ""
            print(f"  [{i:2d}] {d['name']}{mark}")
            out.append(i)
    return out


def pick_device(preset=None) -> int:
    """Выбрать микрофон и убедиться, что он что-то слышит.

    Проверка обязательна: по умолчанию система может отдать виртуальное
    устройство (у одной машины это оказался Moises Virtual Audio), которое пишет
    ровную тишину. Первый прогон этого стенда так и вышел — двенадцать пустых
    записей и «100% ошибок» в отчёте, хотя мерять было нечего.
    """
    import sounddevice as sd
    ids = list_devices()
    dev = preset
    while True:
        if dev is None:
            raw = input("\nНомер устройства (Enter — по умолчанию): ").strip()
            dev = int(raw) if raw.isdigit() else sd.default.device[0]
        if dev not in ids:
            print(f"  [{dev}] — не устройство записи.")
            dev = None
            continue
        print(f"\nПроверка: скажите что-нибудь в «{sd.query_devices(dev)['name']}»…")
        rec = sd.rec(int(3.0 * se.SAMPLE_RATE), samplerate=se.SAMPLE_RATE,
                     channels=1, dtype="int16", device=dev)
        sd.wait()
        p = peak_of(rec.tobytes())
        bar = "#" * min(40, p * 40 // 32768)
        print(f"  уровень: {p:5d}  {bar}")
        if p >= SILENT:
            print("  слышу — продолжаем.")
            return dev
        print("  тишина. Это устройство ничего не пишет — выберите другое.")
        dev = None


def record(preset=None) -> None:
    import sounddevice as sd
    os.makedirs(OUT, exist_ok=True)
    print("\nСейчас нужно прочитать вслух двенадцать фраз — тех же, что вы\n"
          "говорите программе. Говорите как обычно, в обычной обстановке:\n"
          "замеряется именно она, тишина в записи ничего не покажет.")
    dev = pick_device(preset)
    input("\nГотовы — нажмите Enter. ")
    for i, phrase in enumerate(PHRASES, 1):
        for attempt in (1, 2):
            print(f"\n[{i}/{len(PHRASES)}]  «{phrase}»")
            for c in (3, 2, 1):
                print(f"   {c}…", end="", flush=True)
                time.sleep(0.6)
            print("  ГОВОРИТЕ")
            rec = sd.rec(int(3.0 * se.SAMPLE_RATE), samplerate=se.SAMPLE_RATE,
                         channels=1, dtype="int16", device=dev)
            sd.wait()
            pcm = rec.tobytes()
            p = peak_of(pcm)
            print(f"   уровень {p}")
            if p >= SILENT or attempt == 2:
                with wave.open(os.path.join(OUT, f"{i:02d}.wav"), "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(se.SAMPLE_RATE)
                    w.writeframes(pcm)
                break
            print("   пусто — повторим эту фразу.")
    print("\nЗаписано. Считаю…")


def load_pcm(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        return w.readframes(w.getnframes())


def score() -> None:
    import numpy as np
    if not os.path.isdir(OUT):
        print("Нет записей — запустите без --score.")
        return
    eng = se.GigaAmEngine(GIGAAM)
    if not eng.available:
        print(f"GigaAM недоступен: {eng.unavailable_reason()}")
        return
    eng.load()

    # Пустые записи считать нельзя: получится честная на вид таблица со «100%
    # ошибок», где на самом деле мерять было нечего. Ровно так и вышло на первом
    # прогоне — микрофон по умолчанию оказался виртуальным.
    live = [i for i, _ in enumerate(PHRASES, 1)
            if os.path.exists(os.path.join(OUT, f"{i:02d}.wav"))
            and peak_of(load_pcm(os.path.join(OUT, f"{i:02d}.wav"))) >= SILENT]
    if not live:
        print("\nВсе записи пустые — в них цифровая тишина, считать нечего.\n"
              "Скорее всего записывалось не то устройство: перезапустите без\n"
              "--score и выберите микрофон из списка.")
        return
    if len(live) < len(PHRASES):
        print(f"\nПустых записей: {len(PHRASES) - len(live)} — они пропущены.")

    rows = []
    for mode in ("off", "light", "strong"):
        den = se.Denoiser(MODELS)
        den.set_mode(mode)
        if mode != "off" and den.mode == "off":
            print(f"режим '{mode}' недоступен (нет модели) — пропускаю")
            continue
        total, exact, secs = 0.0, 0, 0.0
        n = 0
        for i, phrase in enumerate(PHRASES, 1):
            if i not in live:
                continue
            path = os.path.join(OUT, f"{i:02d}.wav")
            pcm = load_pcm(path)
            step = se.FRAME_SAMPLES * 2
            t0 = time.monotonic()
            out = []
            for k in range(0, len(pcm) - step + 1, step):
                out.extend(den.process(np, pcm[k:k + step]))
            clean = b"".join(out) if out else pcm
            secs += time.monotonic() - t0
            text = eng.transcribe(np, clean, True)
            e = wer(phrase, text)
            total += e
            exact += 1 if e == 0 else 0
            n += 1
            rows.append((mode, phrase, text, e))
        if n:
            print(f"\n=== шумодав: {mode} ===")
            print(f"  доля ошибок в словах : {total / n:.1%}")
            print(f"  фраз слово в слово   : {exact} из {n}")
            print(f"  время чистки на фразу: {secs / n * 1000:.0f} мс")

    print("\n--- что распозналось ---")
    for mode, phrase, text, e in rows:
        flag = " " if e == 0 else "!"
        print(f" {flag} [{mode:<6}] «{phrase}» -> «{text}»")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--score", action="store_true",
                    help="только посчитать, по уже записанному")
    ap.add_argument("--phrases", action="store_true",
                    help="показать фразы и выйти")
    ap.add_argument("--devices", action="store_true",
                    help="показать устройства записи и выйти")
    ap.add_argument("--device", type=int, default=None,
                    help="номер устройства записи (без него — спросит)")
    a = ap.parse_args()
    if a.phrases:
        for p in PHRASES:
            print(p)
    elif a.devices:
        list_devices()
    else:
        if not a.score:
            record(a.device)
        score()
