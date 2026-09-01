import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_theme.dart';
import '../models/evs_models.dart';
import 'voice_orb.dart';

/// Визуализация ассистента в семи стилях — то, что рисуется в плавающем
/// виджете и (по флагу «Показывать в фоне») на главном экране.
/// Названия совпадают с настройками: Сфера, Волны, Бары, Siri Orb,
/// Полоски, Волны 3D, Поле частиц, Нет.
class VizVisual extends StatefulWidget {
  const VizVisual({super.key, required this.style, required this.state, this.size = 160, this.bars = 30, this.spinSeconds = 9});

  final String style;
  final VoiceState state;
  final double size;
  final int bars, spinSeconds;

  @override
  State<VizVisual> createState() => _VizVisualState();
}

class _VizVisualState extends State<VizVisual> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Duration(seconds: widget.spinSeconds))..repeat();

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (widget.style == 'Нет') return const SizedBox.shrink();
    if (widget.style == 'Сфера') {
      return VoiceOrb(state: widget.state, size: widget.size);
    }

    final t = EvsTheme.of(context);
    final active = !widget.state.isIdle;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final phase = active ? _c.value : 0.0;
          return switch (widget.style) {
            'Siri Orb' => Transform.rotate(
                angle: phase * 2 * math.pi,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [t.accent.a1, t.accent.a2, t.accent.a3, t.accent.a1]),
                  ),
                ),
              ),
            'Волны' || 'Волны 3D' => CustomPaint(
                painter: _WavePainter(
                  phase: phase,
                  colors: [t.accent.a1, t.accent.a2, t.accent.a3],
                  layers: widget.style == 'Волны 3D' ? 4 : 2,
                  amplitude: active ? 1 : 0.35,
                ),
              ),
            'Поле частиц' => CustomPaint(
                painter: _ParticlePainter(phase: phase, color: t.accent.a2, active: active),
              ),
            _ => CustomPaint(
                painter: _BarsPainter(
                  phase: phase,
                  count: widget.style == 'Полоски' ? widget.bars * 2 : widget.bars,
                  thin: widget.style == 'Полоски',
                  from: t.accent.a1,
                  to: t.accent.a3,
                  active: active,
                ),
              ),
          };
        },
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.phase, required this.count, required this.thin,
    required this.from, required this.to, required this.active});
  final double phase;
  final int count;
  final bool thin, active;
  final Color from, to;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / count;
    final w = thin ? slot * 0.34 : slot * 0.58;
    final paint = Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [from, to])
          .createShader(Offset.zero & size);
    for (var i = 0; i < count; i++) {
      final base = 0.24 + math.sin(i / 2.2).abs() * 0.7;
      final swing = active ? 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi + i * 0.35)) : 1.0;
      final h = (size.height * base * swing).clamp(4.0, size.height);
      final x = i * slot + (slot - w) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, w, h),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.phase != phase;
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.phase, required this.colors, required this.layers, required this.amplitude});
  final double phase, amplitude;
  final List<Color> colors;
  final int layers;

  @override
  void paint(Canvas canvas, Size size) {
    for (var l = 0; l < layers; l++) {
      final k = l / math.max(1, layers - 1);
      final amp = size.height * 0.16 * amplitude * (1 - k * 0.45);
      final y0 = size.height * (0.5 + k * 0.12);
      final path = Path()..moveTo(0, size.height);
      for (var x = 0.0; x <= size.width; x += 3) {
        final u = x / size.width;
        final y = y0 + math.sin(u * 6.2832 * 1.4 + phase * 6.2832 + l * 0.9) * amp;
        if (x == 0) path.lineTo(0, y); else path.lineTo(x, y);
      }
      path..lineTo(size.width, size.height)..close();
      canvas.drawPath(path, Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [colors[l % colors.length].withOpacity(0.42 - k * 0.1), colors[l % colors.length].withOpacity(0)],
        ).createShader(Offset.zero & size));
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.phase != phase;
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({required this.phase, required this.color, required this.active});
  final double phase;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 9.0;
    final paint = Paint()..color = color;
    for (var x = step / 2; x < size.width; x += step) {
      for (var y = step / 2; y < size.height; y += step) {
        final d = (Offset(x, y) - size.center(Offset.zero)).distance / (size.width / 2);
        final w = active ? 0.5 + 0.5 * math.sin(phase * 6.2832 * 2 - d * 5) : 0.35;
        canvas.drawCircle(Offset(x, y), 1.2 * (0.5 + w), paint..color = color.withOpacity((0.18 + w * 0.55).clamp(0.0, 1.0)));
      }
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.phase != phase;
}
