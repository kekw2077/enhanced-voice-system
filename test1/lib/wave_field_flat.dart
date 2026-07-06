import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Flutter-порт `wave.html` — плоское 2D поле из ~5000 частиц с волновой
/// интерференцией и мягким свечением. Позиции частиц хранятся нормированно,
/// сцена рендерится в виртуальном холсте 1080p и масштабируется под виджет.
///
/// Опционально (по умолчанию выключено — идентично HTML):
///  - [level] 0..1 усиливает амплитуду и яркость;
///  - [speed] множитель скорости.
class WaveFieldFlat extends StatefulWidget {
  const WaveFieldFlat({
    super.key,
    this.level = 0,
    this.speed = 1.0,
    this.particleCount = 5000,
    this.background = Colors.black,
    this.glow = true,
  });

  final double level;
  final double speed;
  final int particleCount;
  final Color background;
  final bool glow;

  @override
  State<WaveFieldFlat> createState() => _WaveFieldFlatState();
}

class _WaveFieldFlatState extends State<WaveFieldFlat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Particle> _particles;
  double _time = 0;
  double _lastMs = 0;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    _particles = List.generate(widget.particleCount, (_) {
      return _Particle(
        nx: rnd.nextDouble(),          // нормированные координаты 0..1
        ny: rnd.nextDouble(),
        amp: rnd.nextDouble() * 50 + 20,
      );
    });
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat()
      ..addListener(_tick);
  }

  void _tick() {
    final ms = (_c.lastElapsedDuration ?? Duration.zero).inMilliseconds.toDouble();
    var dt = (ms - _lastMs);
    _lastMs = ms;
    if (dt <= 0 || dt > 100) dt = 16;
    _time += 0.005 * (dt / 16.0) * widget.speed; // исходник: time += 0.005/кадр
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
    return ColoredBox(
      color: widget.background,
      child: CustomPaint(
        painter: _FlatPainter(
          repaint: _c,
          particles: _particles,
          time: () => _time,
          level: () => widget.level.clamp(0.0, 1.0),
          glow: widget.glow,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Particle {
  _Particle({required this.nx, required this.ny, required this.amp});
  final double nx, ny, amp;
}

class _FlatPainter extends CustomPainter {
  _FlatPainter({
    required Listenable repaint,
    required this.particles,
    required this.time,
    required this.level,
    required this.glow,
  }) : super(repaint: repaint);

  final List<_Particle> particles;
  final double Function() time;
  final double Function() level;
  final bool glow;

  // Константы из wave.html
  static const baseR = 0, baseG = 150, baseB = 255;
  static const brightR = 200, brightG = 255, brightB = 255;
  static const waveFreq = 0.02;

  @override
  void paint(Canvas canvas, Size size) {
    const vh = 1080.0;
    final vw = vh * size.width / size.height;
    final k = size.height / vh;
    canvas.save();
    canvas.scale(k);

    final t = time();
    final lv = level();
    final ampBoost = 1 + 1.0 * lv;
    final paint = Paint()..isAntiAlias = true;
    final glowPaint = Paint()
      ..isAntiAlias = true
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    for (final p in particles) {
      final x = p.nx * vw;
      final baseY = p.ny * vh;

      final angleX = x * waveFreq + t * 1.5;
      final angleY = baseY * waveFreq + t;

      final dy = math.sin(angleX) * math.cos(angleY * 0.7) * p.amp * ampBoost;
      final dx = math.cos(angleX * 0.5) * math.sin(angleY) * 10;

      var bf = (math.sin(angleX * 1.1) + math.cos(angleY * 0.8) + 2) / 4;
      bf = (bf + lv * 0.3).clamp(0.0, 1.0);

      final r = (baseR + (brightR - baseR) * bf).round();
      final g = (baseG + (brightG - baseG) * bf).round();
      final b = (baseB + (brightB - baseB) * bf).round();
      final a = (0.3 + bf * 0.7).clamp(0.0, 1.0);
      final radius = 0.8 + bf * 0.5;

      final cx = x + dx;
      final cy = baseY + dy;

      if (glow && radius > 1.2) {
        glowPaint.color = Color.fromRGBO(baseR, baseG, baseB, a * 0.4);
        canvas.drawCircle(Offset(cx, cy), radius * 3.0, glowPaint);
      }
      paint.color = Color.fromRGBO(r, g, b, a);
      canvas.drawCircle(Offset(cx, cy), radius, paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlatPainter old) => true;
}
