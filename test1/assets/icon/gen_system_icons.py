"""Пересобрать СИСТЕМНЫЕ иконки EVS (ярлык/exe/установщик и трей).

Системные иконки — это отдельный знак (эквалайзер), он намеренно не совпадает
со знаком Genesis внутри приложения: тот рисуется кодом (lib/src/genesis_logo.dart)
и остаётся на заставке, в углу главного экрана и в «О программе». За растры
Genesis отвечает gen_evs_icon.py, за системные — этот скрипт.

Источники (обе прорисовки одного знака, присланы автором):
  * evs_shortcut.ico — детальная (градиентная подложка, ореол, тонкая рамка).
    Готовый многоразмерный .ico, идёт в exe/установщик/ярлык как есть.
    Рядом лежит её исходник evs_shortcut.svg — этот скрипт его не использует,
    он нужен, если рисунок понадобится править.
  * evs_tray.svg     — упрощённая прорисовка того же знака под мелкие размеры:
    полосы на 31 % шире, разлёт шире, плоская подложка без ореола и рамки.
    Из неё собирается .ico для трея.

Почему две: на 16 px четыре полосы детальной прорисовки имеют зазор 0,7 px и
сливаются в один смазанный столбик. Упрощённая заметно лучше, но сама по себе
проблему не снимает — поэтому здесь кадры 16/20/24/32 не просто уменьшаются, а
выравниваются по пиксельной сетке: ширина полосы и зазор округляются до целого
пикселя, вертикаль остаётся центрированной (в SVG все четыре полосы центрованы
по y = 256). Кадры 48+ рисуются точно по SVG — там зазор уже больше двух
пикселей и подгонка только исказила бы пропорции.

Выходы:
  * app_icon.ico                                 — трей (trayManager.setIcon)
  * ../../windows/runner/resources/app_icon.ico  — exe, ярлык, SetupIconFile

Запуск:  python assets/icon/gen_system_icons.py
Зависимости: pip install pillow

ВАЖНО: в pubspec.yaml у flutter_launcher_icons отключён windows-таргет
(`windows: generate: false`), иначе `dart run flutter_launcher_icons`
переписал бы runner/resources/app_icon.ico знаком Genesis из icon.png.
"""
import os
import re
import shutil
import struct

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TRAY_SVG = os.path.join(HERE, "evs_tray.svg")
SHORTCUT_ICO = os.path.join(HERE, "evs_shortcut.ico")

# Трей Windows берёт 16 px при 100 %, 20 при 125 %, 24 при 150 %, 32 при 200 %;
# крупные кадры нужны Проводнику, если этот .ico где-то покажут как файл.
TRAY_SIZES = [16, 20, 24, 32, 48, 64, 128, 256]
# До какого размера включительно выравнивать по пиксельной сетке.
HINT_UPTO = 32
SS = 8  # супersampling для «честных» кадров


# --------------------------- разбор SVG ---------------------------
# Понимает ровно форму evs_tray.svg: фон-скруглённый прямоугольник, один
# линейный градиент и четыре скруглённых полосы. Это не универсальный парсер —
# при смене SVG проверить здесь.
def parse_tray_svg(path):
    s = open(path, encoding="utf-8").read()
    vb = re.search(r'viewBox="0 0 (\d+) (\d+)"', s)
    src = int(vb.group(1))

    grad = re.search(r'<linearGradient[^>]*x1="([\d.]+)"[^>]*x2="([\d.]+)"', s)
    gx0, gx1 = float(grad.group(1)), float(grad.group(2))
    stops = [
        (float(o), c)
        for o, c in re.findall(r'stop offset="([\d.]+)%" stop-color="(#[0-9A-Fa-f]{6})"', s)
    ]

    rects = re.findall(
        r'<rect([^>]*)/>', s
    )
    bg = None
    bars = []
    for attrs in rects:
        def num(name, default=0.0):
            m = re.search(name + r'="([\d.]+)"', attrs)
            return float(m.group(1)) if m else default
        fill = re.search(r'fill="([^"]+)"', attrs)
        r = (num("x"), num("y"), num("width"), num("height"), num("rx"))
        if fill and fill.group(1).startswith("#"):
            bg = (r, fill.group(1))
        else:
            bars.append(r)
    bars.sort(key=lambda b: b[0])
    return dict(src=src, bg=bg, bars=bars, grad=(gx0, gx1, stops))


def hex_rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def grad_color(spec, t):
    """Цвет градиента в доле t (0..1) по его собственным стопам."""
    _, _, stops = spec
    t = min(max(t, 0.0), 1.0) * 100
    for (o0, c0), (o1, c1) in zip(stops, stops[1:]):
        if t <= o1:
            k = 0 if o1 == o0 else (t - o0) / (o1 - o0)
            a, b = hex_rgb(c0), hex_rgb(c1)
            return tuple(round(a[i] + (b[i] - a[i]) * k) for i in range(3))
    return hex_rgb(stops[-1][1])


def bars_layer(size, boxes, spec, src, ss):
    """Полосы с горизонтальным градиентом: градиент по всей ширине, полосы — маска."""
    gx0, gx1, _ = spec
    W = size * ss
    grad = Image.new("RGB", (W, 1))
    px = grad.load()
    for x in range(W):
        t = ((x + 0.5) / ss / (size / src) - gx0) / (gx1 - gx0)
        px[x, 0] = grad_color(spec, t)
    grad = grad.resize((W, W))
    mask = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(mask)
    for (x, y, w, h, r) in boxes:
        d.rounded_rectangle([x * ss, y * ss, (x + w) * ss - 1, (y + h) * ss - 1],
                            radius=r * ss, fill=255)
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def frame_true(size, svg):
    """Кадр точно по SVG: рисуем в SS раз крупнее и уменьшаем."""
    src = svg["src"]
    k = size / src
    ss = SS
    W = size * ss
    (bx, by, bw, bh, br), fill = svg["bg"]
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        [0, 0, W - 1, W - 1], radius=br * k * ss, fill=hex_rgb(fill) + (255,))
    boxes = [(x * k, y * k, w * k, h * k, r * k) for (x, y, w, h, r) in svg["bars"]]
    img.alpha_composite(bars_layer(size, boxes, svg["grad"], src, ss))
    return img.resize((size, size), Image.LANCZOS)


def frame_hinted(size, svg):
    """Кадр, выровненный по пиксельной сетке: целые ширина полосы и зазор."""
    src = svg["src"]
    k = size / src
    x0s, _, w0, _, _ = svg["bars"][0]
    x1s = svg["bars"][1][0]
    bar = max(2, round(w0 * k))
    gap = max(1, round((x1s - (x0s + w0)) * k))
    total = 4 * bar + 3 * gap
    left = (size - total) // 2

    boxes, x = [], left
    for (_, y, _, h, _) in svg["bars"]:
        hp = max(2, round(h * k))
        # Все полосы в SVG центрованы по середине холста — сохраняем это.
        boxes.append((x, (size - hp) / 2, bar, hp, bar / 2))
        x += bar + gap

    ss = SS
    W = size * ss
    (_, _, _, _, br), fill = svg["bg"]
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        [0, 0, W - 1, W - 1], radius=br * k * ss, fill=hex_rgb(fill) + (255,))
    # Градиент считаем по фактическому разлёту полос, а не по координатам SVG.
    spec = (left / k, (left + total) / k, svg["grad"][2])
    img.alpha_composite(bars_layer(size, boxes, spec, src, ss))
    return img.resize((size, size), Image.LANCZOS)


# --------------------------- запись .ico ---------------------------
def _bmp_entry(img):
    """32-битный BMP-кадр для .ico: BITMAPINFOHEADER + XOR(BGRA) + AND-маска."""
    w, h = img.size
    px = img.load()
    hdr = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    xor = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))
    stride = ((w + 31) // 32) * 4
    mask = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray(stride)
        for x in range(w):
            if px[x, y][3] < 128:
                row[x // 8] |= 0x80 >> (x % 8)
        mask += row
    return bytes(hdr) + bytes(xor) + bytes(mask)


def write_ico(path, frames):
    """frames: [(size, PIL.Image)]. ≤64 — BMP, крупнее — PNG (как принято)."""
    import io
    blobs = []
    for size, img in frames:
        if size <= 64:
            blobs.append((size, _bmp_entry(img)))
        else:
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            blobs.append((size, buf.getvalue()))
    out = bytearray(struct.pack("<HHH", 0, 1, len(blobs)))
    offset = 6 + 16 * len(blobs)
    for size, blob in blobs:
        b = 0 if size >= 256 else size
        out += struct.pack("<BBBBHHII", b, b, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for _, blob in blobs:
        out += blob
    open(path, "wb").write(bytes(out))


def main():
    svg = parse_tray_svg(TRAY_SVG)
    frames = [(s, frame_hinted(s, svg) if s <= HINT_UPTO else frame_true(s, svg))
              for s in TRAY_SIZES]
    tray = os.path.join(HERE, "app_icon.ico")
    write_ico(tray, frames)

    exe_icon = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
    shutil.copyfile(SHORTCUT_ICO, exe_icon)

    hinted = [s for s in TRAY_SIZES if s <= HINT_UPTO]
    print(f"tray  -> {tray} ({len(frames)} кадров, по сетке: {hinted})")
    print(f"exe   -> {exe_icon} (копия evs_shortcut.ico)")


if __name__ == "__main__":
    main()
