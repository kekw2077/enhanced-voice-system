"""Regenerate the EVS app/tray/installer/web icons from the master art.

Source of truth (с 2.10.1): знак Genesis из lib/src/genesis_logo.dart — тот же
код, что рисует логотип в приложении. Мастера icon.png (общий план, с полями)
и icon_tray.png (крупный план под .ico) рендерятся командой

    flutter test test/genesis_icon_test.dart

а этот скрипт пересобирает из них все производные растры. icon.svg остался от
прежней иконки и больше ни на что не влияет.

Outputs:
  * icon.png                                       1024, flutter_launcher_icons source
  * app_icon.ico                                   multi-size, system tray
  * ../../windows/runner/resources/app_icon.ico    exe + Inno Setup installer icon
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
# Отдельный мастер под .ico: в кадре 16-32 px кольцо на общем плане теряется,
# поэтому знак там взят крупнее (см. test/genesis_icon_test.dart). Если файла
# нет — .ico собираются из общего мастера, как раньше.
ICO_MASTER = os.path.join(HERE, "icon_tray.png")
SVG = os.path.join(HERE, "icon.svg")

# Multi-resolution frames baked into each .ico (Explorer/taskbar/tray pick one).
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


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

    ico_src = master
    if os.path.exists(ICO_MASTER):
        ico_src = Image.open(ICO_MASTER).convert("RGBA")
        if ico_src.size != (1024, 1024):
            ico_src = ico_src.resize((1024, 1024), Image.LANCZOS)

    def rz_ico(size: int) -> Image.Image:
        return ico_src.resize((size, size), Image.LANCZOS)

    # System tray icon.
    rz_ico(256).save(os.path.join(HERE, "app_icon.ico"), format="ICO", sizes=ICO_SIZES)

    # Windows exe icon + Inno Setup installer icon (SetupIconFile).
    rz_ico(256).save(
        os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico"),
        format="ICO", sizes=ICO_SIZES,
    )

    # Web (matches flutter_launcher_icons web:generate output).
    web_icons = os.path.join(ROOT, "web", "icons")
    rz(512).save(os.path.join(web_icons, "Icon-512.png"))
    rz(192).save(os.path.join(web_icons, "Icon-192.png"))
    rz(512).save(os.path.join(web_icons, "Icon-maskable-512.png"))
    rz(192).save(os.path.join(web_icons, "Icon-maskable-192.png"))
    rz(16).save(os.path.join(ROOT, "web", "favicon.png"))

    print("wrote app_icon.ico, windows app_icon.ico, web icons (master: icon.png)")


if __name__ == "__main__":
    main()
