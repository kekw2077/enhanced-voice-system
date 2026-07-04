import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Цвета орба — по аналогии с props `colors` в SmoothUI SiriOrb.
/// Значения по умолчанию подобраны под тёмную тему EVS.
class SiriOrbColors {
  const SiriOrbColors({
    this.bg = const Color(0xFF0A0A12),
    this.c1 = const Color(0xFFFF5FA8), // розовый
    this.c2 = const Color(0xFF4FC3F7), // голубой
    this.c3 = const Color(0xFF9B7BFF), // фиолетовый
  });

  final Color bg;
  final Color c1;
  final Color c2;
  final Color c3;
}

/// Состояние — как у bar-визуализатора, чтобы дирижировать из одного места.
enum SiriOrbState { idle, listening, speaking, thinking }

/// Flutter-реплика SmoothUI «Siri Orb»: цветные блобы + вращающийся
/// конический блик + блюр + свечение. Работает офлайн и на десктопе.
///
/// Реактивность:
///  - в listening/speaking орб «дышит» по [level] (0..1, RMS с микрофона/TTS);
///  - в thinking — ускоренное вращение и пульсация;
///  - в idle — медленное спокойное дыхание.
class SiriOrb extends StatefulWidget {
  const SiriOrb({
    super.key,
    this.size = 200,
    this.level = 0,
    this.state = SiriOrbState.idle,
    this.colors = const SiriOrbColors(),
    this.animationDuration = 20,
    this.animate = true,
    this.glow = true,
  });

  final double size;

  /// Входной уровень 0..1 (используется в listening/speaking).
  final double level;

  final SiriOrbState state;

  final SiriOrbColors colors;

  /// Секунды на полный оборот (как `animationDuration` в SmoothUI).
  final double animationDuration;

  /// false → заморозить вращение (для prefers-reduced-motion).
  final bool animate;

  /// Внешнее свечение (bloom) под орбом.
  final bool glow;

  @override
  State<SiriOrb> createState() => _SiriOrbState();
}

class _SiriOrbState extends State<SiriOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  double _level = 0; // сглаженный уровень
  double _phase = 0; // фаза вращения 0..1 (собственная, чтобы менять скорость)

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.animationDuration * 1000).round()),
    );
    if (widget.animate) _c.repeat();
    _c.addListener(_tick);
  }

  double get _speedMul => switch (widget.state) {
        SiriOrbState.thinking => 3.0,
        SiriOrbState.speaking => 1.8,
        SiriOrbState.listening => 1.3,
        SiriOrbState.idle => 1.0,
      };

  bool get _reactsToAudio =>
      widget.state == SiriOrbState.listening ||
      widget.state == SiriOrbState.speaking;

  double _idleLevel() {
    final thinking = widget.state == SiriOrbState.thinking;
    final base = thinking ? 0.5 : 0.16;
    final amp = thinking ? 0.28 : 0.12;
    return (base + amp * (0.5 + 0.5 * math.sin(_phase * 2 * math.pi * 2)))
        .clamp(0.0, 1.0);
  }

  void _tick() {
    // Продвигаем собственную фазу (~60 к/с), скорость зависит от состояния.
    _phase += (_speedMul / (widget.animationDuration * 60));
    if (_phase > 1) _phase -= 1;

    final target = _reactsToAudio ? widget.level.clamp(0.0, 1.0) : _idleLevel();
    final k = target > _level ? 0.35 : 0.12; // быстрее растёт, плавнее спадает
    _level += (target - _level) * k;
    // setState не нужен: painter перерисовывается через repaint: _c.
  }

  @override
  void didUpdateWidget(covariant SiriOrb old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) {
      widget.animate ? _c.repeat() : _c.stop();
    }
    if (old.animationDuration != widget.animationDuration) {
      _c.duration =
          Duration(milliseconds: (widget.animationDuration * 1000).round());
      if (widget.animate) _c.repeat();
    }
  }

  @override
  void dispose() {
    _c
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _SiriOrbPainter(
          repaint: _c,
          phase: () => _phase,
          level: () => _level,
          colors: widget.colors,
          glow: widget.glow,
        ),
      ),
    );
  }
}

class _SiriOrbPainter extends CustomPainter {
  _SiriOrbPainter({
    required Listenable repaint,
    required this.phase,
    required this.level,
    required this.colors,
    required this.glow,
  }) : super(repaint: repaint);

  final double Function() phase;
  final double Function() level;
  final SiriOrbColors colors;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase();
    final lv = level();
    final r = size.width / 2;
    final center = Offset(r, r);

    // Внешнее свечение (bloom) под орбом.
    if (glow) {
      final gr = r * (1.05 + 0.10 * lv);
      final glowPaint = Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.5)
        ..shader = RadialGradient(
          colors: [
            colors.c2.withAlpha((90 * (0.4 + 0.6 * lv)).round()),
            colors.c2.withAlpha(0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: gr));
      canvas.drawCircle(center, gr, glowPaint);
    }

    // Всё дальнейшее рисуем в отдельный слой, а в конце «выедаем» альфу к
    // кромке (BlendMode.dstIn с радиальным градиентом) — так край получается
    // дымчатым/растушёванным, а не резкой линией, как при жёстком clipPath.
    final layerRect = Rect.fromCircle(center: center, radius: r * 1.15);
    canvas.saveLayer(layerRect, Paint());
    // Ограничим размах блюра блобов, чтобы не расползались далеко за кромку.
    canvas.clipRect(layerRect);

    // Фон.
    canvas.drawCircle(center, r, Paint()..color = colors.bg);

    // Цветные блобы, вращающиеся вокруг центра. BlendMode.plus даёт
    // аддитивное «неоновое» смешение на тёмном фоне.
    final orbit = r * (0.34 + 0.10 * lv);
    final blobR = r * (0.85 + 0.15 * lv);
    final blur = MaskFilter.blur(BlurStyle.normal, r * 0.38);

    void blob(Color c, double offsetTurns) {
      final ang = 2 * math.pi * (t + offsetTurns);
      final pos = center + Offset(math.cos(ang), math.sin(ang)) * orbit;
      final paint = Paint()
        ..maskFilter = blur
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [c.withAlpha(210), c.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: pos, radius: blobR));
      canvas.drawCircle(pos, blobR, paint);
    }

    blob(colors.c1, 0.0);
    blob(colors.c2, 1 / 3);
    blob(colors.c3, 2 / 3);

    // Вращающийся конический блик (отражающая «плёнка»).
    final sweep = Paint()
      ..blendMode = BlendMode.softLight
      ..shader = SweepGradient(
        transform: GradientRotation(2 * math.pi * t),
        colors: [
          Colors.white.withAlpha(0),
          Colors.white.withAlpha(70),
          Colors.white.withAlpha(0),
          Colors.white.withAlpha(50),
          Colors.white.withAlpha(0),
        ],
        stops: const [0.0, 0.2, 0.45, 0.7, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, sweep);

    // Объём: верхний хайлайт + нижняя тень.
    final shade = Paint()
      ..blendMode = BlendMode.overlay
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.4),
        radius: 1.1,
        colors: [Colors.white.withAlpha(45), Colors.black.withAlpha(60)],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, shade);

    // Растушёванная кромка: центр полностью непрозрачный, ближе к краю альфа
    // плавно уходит в ноль — мягкий «дымчатый» край без резкой обводки.
    final edgeMask = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = RadialGradient(
        colors: [Colors.white, Colors.white, Colors.white.withAlpha(0)],
        stops: const [0.0, 0.82, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, edgeMask);

    canvas.restore();
    // Обводка убрана намеренно — именно она давала «строгую линию» по кругу.
  }

  @override
  bool shouldRepaint(covariant _SiriOrbPainter old) => true;
}
