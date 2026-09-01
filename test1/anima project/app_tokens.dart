import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';

/// Токены темы Nexus Anima.
///
/// ThemeExtension выбран сознательно: он даёт бесплатный lerp,
/// поэтому переключение темы анимируется само, без ручной интерполяции.
///
/// Доступ в виджете:
///   final t = Theme.of(context).extension<AppTokens>()!;
///   color: t.card
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.name,
    required this.brightness,
    // поверхности
    required this.bg,
    required this.card,
    required this.field,
    required this.chip,
    required this.hover,
    required this.solid,
    // текст
    required this.txt,
    required this.body,
    required this.sub,
    required this.faint,
    // границы и тени
    required this.stroke,
    required this.stroke2,
    required this.shadow,
    required this.glow,
    // акцент
    required this.accSoft,
    required this.accStrong,
    required this.accLine,
    // кнопка
    required this.btn,
    required this.btnFg,
    // фоновая композиция
    required this.a1,
    required this.a2,
    required this.a3,
    required this.dot,
    required this.backdrop,
    // статусы
    required this.ok,
    required this.warn,
    required this.danger,
    // движение
    required this.motion,
  });

  final String name;
  final Brightness brightness;

  final Color bg, card, field, chip, hover, solid;
  final Color txt, body, sub, faint;
  final Color stroke, stroke2, shadow, glow;
  final Color accSoft, accStrong, accLine;
  final Color btn, btnFg;
  final Color a1, a2, a3, dot;
  final BackdropMode backdrop;
  final Color ok, warn, danger;
  final MotionTokens motion;

  @override
  AppTokens copyWith({String? name, Brightness? brightness}) => this;

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppTokens(
      name: t < 0.5 ? name : other.name,
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: c(bg, other.bg),
      card: c(card, other.card),
      field: c(field, other.field),
      chip: c(chip, other.chip),
      hover: c(hover, other.hover),
      solid: c(solid, other.solid),
      txt: c(txt, other.txt),
      body: c(body, other.body),
      sub: c(sub, other.sub),
      faint: c(faint, other.faint),
      stroke: c(stroke, other.stroke),
      stroke2: c(stroke2, other.stroke2),
      shadow: c(shadow, other.shadow),
      glow: c(glow, other.glow),
      accSoft: c(accSoft, other.accSoft),
      accStrong: c(accStrong, other.accStrong),
      accLine: c(accLine, other.accLine),
      btn: c(btn, other.btn),
      btnFg: c(btnFg, other.btnFg),
      a1: c(a1, other.a1),
      a2: c(a2, other.a2),
      a3: c(a3, other.a3),
      dot: c(dot, other.dot),
      backdrop: t < 0.5 ? backdrop : other.backdrop,
      ok: c(ok, other.ok),
      warn: c(warn, other.warn),
      danger: c(danger, other.danger),
      motion: motion.lerp(other.motion, t),
    );
  }
}

/// Как рисуется фон окна.
///
/// systemMica и systemAcrylic отдают размытие композитору Windows —
/// приложение при этом не тратит ни кадра GPU.
/// painted оставлен для тем, которым нужен именно свой градиент.
enum BackdropMode { opaque, systemMica, systemAcrylic, painted }

/// Тайминги. Держать здесь, а не в виджетах:
/// тогда режим экономии меняет их в одном месте.
@immutable
class MotionTokens {
  const MotionTokens({
    required this.fast,
    required this.normal,
    required this.slow,
    required this.ambient,
    required this.curve,
    this.scale = 1.0,
  });

  final Duration fast;     // ховеры, ~160 мс
  final Duration normal;   // появление панелей, ~220 мс
  final Duration slow;     // переходы экранов, ~380 мс
  final Duration ambient;  // фоновое «дыхание», секунды
  final Curve curve;

  /// 1.0 — окно в фокусе, 0.5 — видно но не в фокусе, 0.0 — всё замерло.
  /// Ambient-анимации при scale == 0 должны не замедляться, а
  /// останавливать свой Ticker: замедленная анимация всё равно жрёт GPU.
  final double scale;

  MotionTokens withScale(double s) => MotionTokens(
        fast: fast, normal: normal, slow: slow,
        ambient: ambient, curve: curve, scale: s,
      );

  MotionTokens lerp(MotionTokens o, double t) => MotionTokens(
        fast: t < 0.5 ? fast : o.fast,
        normal: t < 0.5 ? normal : o.normal,
        slow: t < 0.5 ? slow : o.slow,
        ambient: t < 0.5 ? ambient : o.ambient,
        curve: t < 0.5 ? curve : o.curve,
        scale: lerpDouble(scale, o.scale, t) ?? scale,
      );
}

const _motion = MotionTokens(
  fast: Duration(milliseconds: 160),
  normal: Duration(milliseconds: 220),
  slow: Duration(milliseconds: 380),
  ambient: Duration(seconds: 17),
  curve: Curves.easeOutCubic,
);

// ---------------------------------------------------------------------------
// Тема Prism — значения перенесены один в один из HTML-макета.
// ---------------------------------------------------------------------------

const prismDark = AppTokens(
  name: 'Prism Dark',
  brightness: Brightness.dark,
  bg: Color(0xFF07080C),
  card: Color(0x0AFFFFFF),
  field: Color(0x09FFFFFF),
  chip: Color(0x0FFFFFFF),
  hover: Color(0x14FFFFFF),
  solid: Color(0xFF0E1016),
  txt: Color(0xFFF2F4F8),
  body: Color(0xFFC7CBD6),
  sub: Color(0xFF8B9099),
  faint: Color(0xFF666C79),
  stroke: Color(0x14FFFFFF),
  stroke2: Color(0x0AFFFFFF),
  shadow: Color(0x38000000),
  glow: Color(0x339B72CB),
  accSoft: Color(0x299B72CB),
  accStrong: Color(0x429B72CB),
  accLine: Color(0x6B9B72CB),
  btn: Color(0xFFFFFFFF),
  btnFg: Color(0xFF0A0B0E),
  a1: Color(0xFF3269CE),
  a2: Color(0xFF7F5AAC),
  a3: Color(0xFF8A6FD4),
  dot: Color(0x52FFFFFF),
  backdrop: BackdropMode.systemMica,
  ok: Color(0xFF4ADE80),
  warn: Color(0xFFFBBF24),
  danger: Color(0xFFFF7A7A),
  motion: _motion,
);

const prismLight = AppTokens(
  name: 'Prism Light',
  brightness: Brightness.light,
  bg: Color(0xFFEEF2F8),
  card: Color(0xE6FFFFFF),
  field: Color(0x091E3764),
  chip: Color(0x0E1E3764),
  hover: Color(0x0F1E3764),
  solid: Color(0xFFFFFFFF),
  txt: Color(0xFF13161C),
  body: Color(0xFF42464E),
  sub: Color(0xFF666C79),
  faint: Color(0xFF8B9099),
  stroke: Color(0x141E3764),
  stroke2: Color(0x0A1E3764),
  shadow: Color(0x1F000000),
  glow: Color(0x1F7F5AAC),
  accSoft: Color(0x337F5AAC),
  accStrong: Color(0x477F5AAC),
  accLine: Color(0x807F5AAC),
  btn: Color(0xFF17181B),
  btnFg: Color(0xFFFFFFFF),
  a1: Color(0xFF1CACC2),
  a2: Color(0xFF3C8CA8),
  a3: Color(0xFF6D7CC0),
  dot: Color(0x4D1E3764),
  backdrop: BackdropMode.systemAcrylic,
  ok: Color(0xFF16A34A),
  warn: Color(0xFFD18A19),
  danger: Color(0xFFDC2626),
  motion: _motion,
);

/// Реестр тем. Новая тема = один const выше + одна строка здесь.
const appThemes = <String, AppTokens>{
  'prism-dark': prismDark,
  'prism-light': prismLight,
};

ThemeData buildTheme(AppTokens t) => ThemeData(
      brightness: t.brightness,
      scaffoldBackgroundColor:
          t.backdrop == BackdropMode.opaque ? t.bg : Colors.transparent,
      extensions: <ThemeExtension<dynamic>>[t],
    );
