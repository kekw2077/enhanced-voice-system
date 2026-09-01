import 'package:flutter/material.dart';

/// Дизайн-токены EVS. Значения перенесены из прототипа без изменений.
/// CSS-источник: handoff/tokens/tokens.css

@immutable
class EvsPalette {
  const EvsPalette({
    required this.bg, required this.card, required this.solid,
    required this.txt, required this.body, required this.sub, required this.faint,
    required this.stroke, required this.stroke2, required this.field,
    required this.hover, required this.chip, required this.btn, required this.btnText,
    required this.dot, required this.accentSoft, required this.accentStrong, required this.accentLine,
    required this.auroraOpacity, required this.shadow, required this.glowColor,
  });

  final Color bg, card, solid, txt, body, sub, faint;
  final Color stroke, stroke2, field, hover, chip, btn, btnText, dot;
  final Color accentSoft, accentStrong, accentLine;
  final double auroraOpacity;
  final List<BoxShadow> shadow;
  final Color glowColor;

  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFF5B944);
  static const danger = Color(0xFFFF7A7A);

  static const dark = EvsPalette(
    bg: Color(0xFF07080C),
    card: Color(0x0BFFFFFF),
    solid: Color(0xFF111319),
    txt: Color(0xFFF2F4F8),
    body: Color(0xFFC7CBD6),
    sub: Color(0xFF9399A6),
    faint: Color(0xFF666C79),
    stroke: Color(0x17FFFFFF),
    stroke2: Color(0x2EFFFFFF),
    field: Color(0x09FFFFFF),
    hover: Color(0x12FFFFFF),
    chip: Color(0x0FFFFFFF),
    btn: Color(0xFFFFFFFF),
    btnText: Color(0xFF0A0B0E),
    dot: Color(0x52FFFFFF),
    accentSoft: Color(0x299B72CB),
    accentStrong: Color(0x429B72CB),
    accentLine: Color(0x6B9B72CB),
    auroraOpacity: 0.9,
    shadow: [BoxShadow(color: Color(0x80000000), offset: Offset(0, 24), blurRadius: 64)],
    glowColor: Color(0x6B9B72CB),
  );

  static const light = EvsPalette(
    bg: Color(0xFFEEF2F8),
    card: Color(0x70FFFFFF),
    solid: Color(0xFFFFFFFF),
    txt: Color(0xFF17181B),
    body: Color(0xFF42464E),
    sub: Color(0xFF5F6470),
    faint: Color(0xFF8B9099),
    stroke: Color(0xFFD2DAE8),
    stroke2: Color(0xFFB8C2D2),
    field: Color(0x09121E37),
    hover: Color(0x12121E37),
    chip: Color(0x0E121E37),
    btn: Color(0xFF17181B),
    btnText: Color(0xFFFFFFFF),
    dot: Color(0x4D1E3764),
    accentSoft: Color(0x337F5AAC),
    accentStrong: Color(0x477F5AAC),
    accentLine: Color(0x807F5AAC),
    auroraOpacity: 0.5,
    shadow: [
      BoxShadow(color: Color(0x29192D55), offset: Offset(0, 20), blurRadius: 44),
      BoxShadow(color: Color(0x12192D55), offset: Offset(0, 2), blurRadius: 6),
    ],
    glowColor: Color(0x4D9B72CB),
  );
}

/// Акцентная тройка. Все градиенты интерфейса строятся из a1 → a2 → a3.
@immutable
class EvsAccent {
  const EvsAccent(this.id, this.label, this.a1, this.a2, this.a3);
  final String id, label;
  final Color a1, a2, a3;

  static const google = EvsAccent('google', 'Google', Color(0xFF3269CE), Color(0xFF7F5AAC), Color(0xFFBC505C));
  static const aurora = EvsAccent('aurora', 'Аврора', Color(0xFF1CACC2), Color(0xFF3F63D1), Color(0xFF8A6FD4));
  static const sunset = EvsAccent('sunset', 'Закат',  Color(0xFFD18A19), Color(0xFFCD5374), Color(0xFF7F5AAC));
  static const mint   = EvsAccent('mint',   'Мята',   Color(0xFF1F9E7A), Color(0xFF3C8CA8), Color(0xFF6D7CC0));
  static const all = <EvsAccent>[google, aurora, sunset, mint];

  /// linear-gradient(140deg, a1, a2 55%, a3) — кнопки, логотип, аватар.
  LinearGradient get badge => LinearGradient(
        begin: const Alignment(-0.9, -1), end: const Alignment(0.9, 1),
        colors: [a1, a2, a3], stops: const [0, 0.55, 1],
      );

  /// linear-gradient(96deg, a1, a2 48%, a3) — заголовки с заливкой текста.
  LinearGradient get sweep => LinearGradient(
        begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: [a1, a2, a3], stops: const [0, 0.48, 1],
      );
}

/// Матовость панелей. Прототип: [data-glass]
enum EvsGlass { off, glass, frost, solid }

extension EvsGlassValues on EvsGlass {
  double get blur => switch (this) {
        EvsGlass.off => 0,
        EvsGlass.glass => 26,
        EvsGlass.frost => 16,
        EvsGlass.solid => 0,
      };

  Color card(Brightness b) {
    final isDark = b == Brightness.dark;
    return switch (this) {
      EvsGlass.off || EvsGlass.glass => isDark ? const Color(0x0BFFFFFF) : const Color(0x70FFFFFF),
      EvsGlass.frost => isDark ? const Color(0xA8161922) : const Color(0xC2FFFFFF),
      EvsGlass.solid => isDark ? const Color(0xF20E1016) : const Color(0xFFFFFFFF),
    };
  }
}

class EvsRadius {
  static const chip = 999.0;
  static const tile = 13.0;
  static const card = 20.0;
  static const field = 26.0;
  static const panel = 28.0;
}

class EvsMotion {
  static const rise = Duration(milliseconds: 400);
  static const hover = Duration(milliseconds: 180);
  static const screen = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
}

/// Типографика. Шрифты: Figtree (интерфейс), JetBrains Mono (числа, коды).
/// Проще всего через пакет google_fonts, либо положить .ttf в assets/fonts.
class EvsType {
  static const ui = 'Figtree';
  static const mono = 'JetBrains Mono';

  static const hero = TextStyle(fontFamily: ui, fontSize: 64, fontWeight: FontWeight.w800, letterSpacing: -2.9, height: 1.02);
  static const title = TextStyle(fontFamily: ui, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.44);
  static const section = TextStyle(fontFamily: ui, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.05);
  static const bodyText = TextStyle(fontFamily: ui, fontSize: 14, height: 1.5);
  static const label = TextStyle(fontFamily: ui, fontSize: 12.5, fontWeight: FontWeight.w600);
  static const caption = TextStyle(fontFamily: ui, fontSize: 11.5);
  static const numeric = TextStyle(fontFamily: mono, fontSize: 10.5);
}
