"""Generate the EVS app/tray icon — the conic-gradient orb from evs_ui.html.

Reproduces the `.logo-mark` CSS exactly:
  background: conic-gradient(from 160deg, #5068d8, #8855cc, #c060d8, #5068d8);
  ::after (dark center) diameter = 14/30 of the outer circle, color #09090f.

Outputs assets/icon/icon.png (1024, source for flutter_launcher_icons) and
assets/icon/app_icon.ico (multi-size, used by the system tray).
"""
import os
import numpy as np
from PIL import Image

OUT = os.path.dirname(os.path.abspath(__file__))
SS = 2048  # supersampled render, downscaled for anti-aliasing


def hex2rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


BLUE = hex2rgb("5068d8")
MID = hex2rgb("8855cc")
PINK = hex2rgb("c060d8")
DARK = hex2rgb("09090f")
STOPS = [(0.0, BLUE), (1 / 3, MID), (2 / 3, PINK), (1.0, BLUE)]


def render(n):
    y, x = np.mgrid[0:n, 0:n].astype(np.float64)
    c = (n - 1) / 2.0
    dx, dy = x - c, y - c
    dist = np.sqrt(dx * dx + dy * dy)
    R = n / 2.0 - n * 0.02            # small margin from edge
    inner = R * (14.0 / 30.0)         # CSS center-hole ratio

    # CSS conic: 0deg at top, clockwise; gradient starts `from 160deg`.
    ang = np.mod(np.degrees(np.arctan2(dx, -dy)), 360.0)
    t = np.mod(ang - 160.0, 360.0) / 360.0

    col = np.zeros((n, n, 3))
    for (t0, c0), (t1, c1) in zip(STOPS[:-1], STOPS[1:]):
        m = (t >= t0) & (t <= t1)
        f = ((t[m] - t0) / (t1 - t0))[:, None]
        col[m] = c0[None, :] * (1 - f) + c1[None, :] * f

    aa = max(1.0, n * 0.0015)
    outer_a = np.clip((R - dist) / aa + 0.5, 0, 1)
    center_a = np.clip((inner - dist) / aa + 0.5, 0, 1)

    img = np.zeros((n, n, 4))
    for k in range(3):
        img[..., k] = col[..., k] * (1 - center_a) + DARK[k] * center_a
    img[..., 3] = outer_a * 255.0
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA")


big = render(SS)
big.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "icon.png"))
big.resize((256, 256), Image.LANCZOS).save(
    os.path.join(OUT, "app_icon.ico"),
    format="ICO",
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
print("wrote icon.png + app_icon.ico")
