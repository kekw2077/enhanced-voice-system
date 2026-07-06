import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Flutter-порт `wawe2.html` — 3D волновое поле с глубиной резкости.
/// Вся геометрия/камера/DoF сохранены дословно из исходника; сцена рендерится
/// в виртуальном холсте высотой 1080 и равномерно масштабируется под виджет,
/// поэтому вид одинаков при любом размере.
///
/// Опционально (по умолчанию выключено — тогда результат идентичен HTML):
///  - [level]  0..1 усиливает амплитуду волн и яркость гребней;
///  - [levels] спектр (полосы 0..1) — рябь по X повторяет форму спектра;
///  - [speed]  множитель скорости времени (для состояний ассистента).
class WaveField3D extends StatefulWidget {
  const WaveField3D({
    super.key,
    this.level = 0,
    this.levels,
    this.speed = 1.0,
    this.numCols = 110,
    this.numRows = 75,
    this.background = const Color(0xFF020208),
  });

  final double level;
  final List<double>? levels;
  final double speed;
  final int numCols;
  final int numRows;
  final Color background;

  @override
  State<WaveField3D> createState() => _WaveField3DState();
}

class _WaveField3DState extends State<WaveField3D>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  double _time = 0;
  double _lastMs = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat()
      ..addListener(_tick);
  }

  void _tick() {
    final ms = (_c.lastElapsedDuration ?? Duration.zero).inMilliseconds.toDouble();
    var dt = (ms - _lastMs);
    _lastMs = ms;
    if (dt <= 0 || dt > 100) dt = 16;
    // исходник: time += 0.015 за кадр (~60fps) → 0.9/сек
    _time += 0.9 * (dt / 1000.0) * widget.speed;
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
        painter: _Wave3DPainter(
          repaint: _c,
          time: () => _time,
          level: () => widget.level.clamp(0.0, 1.0),
          levels: widget.levels,
          numCols: widget.numCols,
          numRows: widget.numRows,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Wave3DPainter extends CustomPainter {
  _Wave3DPainter({
    required Listenable repaint,
    required this.time,
    required this.level,
    required this.levels,
    required this.numCols,
    required this.numRows,
  }) : super(repaint: repaint);

  final double Function() time;
  final double Function() level;
  final List<double>? levels;
  final int numCols;
  final int numRows;

  // Константы из wawe2.html
  static const double fov = 450;
  static const double focusZ = 320;
  static const double minZ = 70;
  static const double maxZ = 650;
  static const double camHeight = 140;

  double _bandAt(double u) {
    final lv = levels;
    if (lv == null || lv.isEmpty) return 0;
    final f = u * (lv.length - 1);
    final i = f.floor();
    final fr = f - i;
    final j = math.min(i + 1, lv.length - 1);
    return (lv[i] * (1 - fr) + lv[j] * fr).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Виртуальный холст высотой 1080, ширина по соотношению сторон.
    const vh = 1080.0;
    final vw = vh * size.width / size.height;
    final k = size.height / vh;
    canvas.save();
    canvas.scale(k);

    final t = time();
    final lv = level();
    final hasSpectrum = levels != null && levels!.isNotEmpty;

    final vpX = vw / 2;
    const vpY = vh * 0.3; // точка схода
    final paint = Paint()..isAntiAlias = true;

    // Заполнение из глубины вперёд — дальние точки рисуются первыми.
    for (var r = numRows - 1; r >= 0; r--) {
      for (var c = 0; c < numCols; c++) {
        final gridX = (c - numCols / 2) * 16.0;
        final gridZ = minZ + (r / numRows) * (maxZ - minZ);

        final angleX = gridX * 0.012 + t * 1.5;
        final angleZ = gridZ * 0.015 + t * 0.8;

        // амплитуда: базовая, усиленная спектром/уровнем (0 → как в оригинале)
        final u = c / (numCols - 1);
        final ampMul = hasSpectrum ? (1 + 1.4 * _bandAt(u)) : (1 + 1.2 * lv);

        var waveY = (math.sin(angleX) * math.cos(angleZ) * 45 +
                math.sin(gridX * 0.005 - t) * 15) *
            ampMul;
        final waveX = math.sin(gridZ * 0.02 + t) * 20;

        final x3d = gridX + waveX;
        final y3d = camHeight + waveY;
        final z3d = gridZ;

        final scale = fov / z3d;
        final screenX = vpX + x3d * scale;
        final screenY = vpY + y3d * scale;
        if (screenX < 0 || screenX > vw || screenY < 0 || screenY > vh) continue;

        final distToFocus = (z3d - focusZ).abs();
        final blur = math.pow(distToFocus / 110, 2).toDouble();

        final baseSize = 1.1 * scale;
        var radius = baseSize + blur * 1.5;
        if (radius < 0.4) radius = 0.4;

        var crest = (-waveY + 60) / 120;
        crest = crest.clamp(0.0, 1.0);
        // громкость подсвечивает гребни
        crest = (crest + lv * 0.4).clamp(0.0, 1.0);

        final rr = (5 * (1 - crest) + 160 * crest).round();
        final gg = (60 * (1 - crest) + 235 * crest).round();
        final bb = (180 * (1 - crest) + 255 * crest).round();

        var alpha = (0.2 + crest * 0.8) / (1 + blur * 1.1);
        alpha = alpha.clamp(0.01, 1.0);

        paint.color = Color.fromRGBO(rr, gg, bb, alpha);
        canvas.drawCircle(Offset(screenX, screenY), radius, paint);

        // неоновое свечение для ярких точек В ФОКУСЕ
        if (blur < 0.2 && crest > 0.75) {
          paint.color = Color.fromRGBO(rr, gg, bb, alpha * 0.25);
          canvas.drawCircle(Offset(screenX, screenY), radius * 3.5, paint);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _Wave3DPainter old) => true;
}
