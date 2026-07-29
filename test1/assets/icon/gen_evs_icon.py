"""Regenerate the EVS app/tray/installer/web icons from the master art.

Source of truth (с 2.10.1): знак Genesis из lib/src/genesis_logo.dart — тот же
код, что рисует логотип в приложении. Мастера icon.png (общий план, с полями)
и icon_tray.png (крупный план под .ico) рендерятся командой

    flutter test test/genesis_icon_test.dart

а этот скрипт пересобирает из них все производные растры. icon.svg остался от
прежней иконки и больше ни на что не влияет.

Область ответственности: только знак Genesis. Системные иконки Windows (трей,
exe, установщик, ярлык) — ДРУГОЙ знак, их собирает соседний gen_system_icons.py;
этот скрипт .ico больше не пишет.

Outputs:
  * icon.png                                       1024, flutter_launcher_icons source
  * ../../web/favicon.png, ../../web/icons/Icon-{192,512}[-maskable].png

Usage:
  python gen_evs_icon.py            # regenerate derived rasters from icon.png
  python gen_evs_icon.py --from-svg # re-rasterize icon.png from icon.svg first
                                    #   (needs `pip install cairosvg`; note its
                                    #   glow-filter fidelity is lower than the
                                    #   Chromium render that produced the shipped
                                    #   master -- prefer re-exporting a browser
                                    #   render if you change the SVG)

Deps: `pip install pillow` (always); `pip install cairosvg` (only for --from-svg).
After running, `dart run flutter_launcher_icons` regenerates the mobile/macOS
icons from the new icon.png as well.
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MASTER = os.path.join(HERE, "icon.png")
SVG = os.path.join(HERE, "icon.svg")
# icon_tray.png (крупный план знака Genesis под .ico) больше не используется:
# .ico ушли в gen_system_icons.py вместе с самим знаком. Мастер и его рендер в
# test/genesis_icon_test.dart оставлены на случай, если Genesis вернётся в
# системные иконки.


def rasterize_from_svg() -> None:
    """Re-render icon.png from icon.svg via cairosvg (fallback path).

    The committed master was produced with Chromium for maximum filter fidelity;
    cairosvg is offered here only as a portable, dependency-light convenience.
    """
    import cairosvg  # optional dep, only for --from-svg

    cairosvg.svg2png(
        url=SVG, write_to=MASTER,
        output_width=1024, output_height=1024, background_color="transparent",
    )
    print("rasterized icon.png from icon.svg (cairosvg)")


def main() -> None:
    if "--from-svg" in sys.argv:
        rasterize_from_svg()

    master = Image.open(MASTER).convert("RGBA")
    if master.size != (1024, 1024):
        master = master.resize((1024, 1024), Image.LANCZOS)

    def rz(size: int) -> Image.Image:
        return master.resize((size, size), Image.LANCZOS)

    # .ico СПЕЦИАЛЬНО не трогаем: системные иконки (трей, exe, установщик,
    # ярлык) — другой знак, их собирает gen_system_icons.py. Раньше эти два
    # файла писались здесь; если вернуть строки обратно, они затрут системные
    # иконки знаком Genesis.

    # Web (matches flutter_launcher_icons web:generate output).
    web_icons = os.path.join(ROOT, "web", "icons")
    rz(512).save(os.path.join(web_icons, "Icon-512.png"))
    rz(192).save(os.path.join(web_icons, "Icon-192.png"))
    rz(512).save(os.path.join(web_icons, "Icon-maskable-512.png"))
    rz(192).save(os.path.join(web_icons, "Icon-maskable-192.png"))
    rz(16).save(os.path.join(ROOT, "web", "favicon.png"))

    print("wrote web icons (master: icon.png); .ico см. gen_system_icons.py")


if __name__ == "__main__":
    main()
