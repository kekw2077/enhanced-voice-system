import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';

/// Сетка точек. Порт canvas-слоя из прототипа, оба режима:
///
/// push — точки разбегаются от курсора на пружине и возвращаются;
/// glow — точки стоят на местах и разгораются волной вслед за курсором,
///        клик пускает расходящийся круг.
///
/// Кладётся под содержимое: Stack(children: [DotGrid(), ...ваш UI]).
class DotGrid extends StatefulWidget {
  const DotGrid({super.key, this.spacing = 15, this.mode, this.color});

  final double spacing;
  final EvsDotMode? mode;
  final Color? color;

  @override
  State<DotGrid> createState() => _DotGridState();
}

class _Dot {
  _Dot(this.ox, this.oy) : x = ox, y = oy;
  final double ox, oy;
  double x, y, vx = 0, vy = 0, lift = 0;
}

class _Ripple {
  _Ripple(this.x, this.y, this.life, this.speed, this.amp);
  final double x, y, speed, amp;
  final int life;
  double t = 0;
}

class _DotGridState extends State<DotGrid> with SingleTickerProviderStateMixin {
  static const _pushRadius = 132.0;
  static const _glowRadius = 190.0;

  late final Ticker _ticker = createTicker(_tick)..start();
  final List<_Dot> _dots = [];
  final List<_Ripple> _ripples = [];

  Size _size = Size.zero;
  Offset _pointer = const Offset(-10000, -10000);
  Offset _smooth = const Offset(-10000, -10000);
  Offset _last = Offset.zero;
  bool _hovering = false;
  double _travel = 0, _time = 0;
  Duration _prev = Duration.zero;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _build(Size s) {
    if (s == _size) return;
    _size = s;
    _dots.clear();
    final sp = widget.spacing;
    final cols = (s.width / sp).ceil() + 1;
    final rows = (s.height / sp).ceil() + 1;
    final offX = (s.width - (cols - 1) * sp) / 2;
    final offY = (s.height - (rows - 1) * sp) / 2;
    for (var i = 0; i < cols; i++) {
      for (var j = 0; j < rows; j++) {
        _dots.add(_Dot(offX + i * sp, offY + j * sp));
      }
    }
  }

  void _tick(Duration now) {
    final dt = math.min(48.0, (now - _prev).inMicroseconds / 1000);
    _prev = now;
    _time += dt;
    final mode = widget.mode ?? EvsTheme.of(context).dots;
    if (mode == EvsDotMode.off) return;
    if (mode == EvsDotMode.push) {
      _stepPush();
    } else {
      _stepGlow(dt);
    }
    setState(() {});
  }

  void _stepPush() {
    for (final d in _dots) {
      var near = 0.0;
      if (_hovering) {
        final dx = d.x - _pointer.dx, dy = d.y - _pointer.dy;
        final d2 = dx * dx + dy * dy;
        if (d2 < _pushRadius * _pushRadius) {
          final dist = math.max(0.001, math.sqrt(d2));
          near = 1 - dist / _pushRadius;
          final push = near * near * 2.6;
          d.vx += dx / dist * push - dy / dist * near * 0.55;
          d.vy += dy / dist * push + dx / dist * near * 0.55;
        }
      }
      d.vx += (d.ox - d.x) * 0.022;
      d.vy += (d.oy - d.y) * 0.022;
      d.vx *= 0.9;
      d.vy *= 0.9;
      d.x += d.vx;
      d.y += d.vy;
      d.lift += (near - d.lift) * 0.12;
    }
  }

  void _stepGlow(double dt) {
    final k = 1 - math.pow(0.001, dt / 1000).toDouble();
    _smooth = Offset(
      _smooth.dx + (_pointer.dx - _smooth.dx) * k * 0.55,
      _smooth.dy + (_pointer.dy - _smooth.dy) * k * 0.55,
    );
    _ripples.removeWhere((r) => (r.t += dt) > r.life);
    if (_hovering) {
      _travel += (_pointer - _last).distance;
      _last = _pointer;
      if (_travel > 30) {
        _travel = 0;
        _ripples.add(_Ripple(_pointer.dx, _pointer.dy, 900, 0.3, 0.8));
        if (_ripples.length > 16) _ripples.removeAt(0);
      }
    }
    for (final d in _dots) {
      var b = 0.0;
      if (_hovering) {
        final v = Offset(d.ox - _smooth.dx, d.oy - _smooth.dy);
        final d2 = v.distanceSquared;
        if (d2 < _glowRadius * _glowRadius) {
          final t = 1 - math.sqrt(d2) / _glowRadius;
          b = t * t * (3 - 2 * t);
        }
      }
      for (final r in _ripples) {
        final ring = r.t * r.speed;
        final dist = math.max(0.0001, (Offset(d.ox, d.oy) - Offset(r.x, r.y)).distance);
        final g = math.exp(-math.pow(dist - ring, 2) / 2600) * (1 - r.t / r.life) * r.amp;
        if (g > b) b = g;
      }
      final wave = 0.5 + 0.5 * math.sin(d.ox * 0.011 + d.oy * 0.017 + _time * 0.0007);
      if (wave * wave * 0.13 > b) b = wave * wave * 0.13;
      d.lift = b;
      d.x = d.ox;
      d.y = d.oy;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final mode = widget.mode ?? t.dots;
    if (mode == EvsDotMode.off) return const SizedBox.expand();

    return LayoutBuilder(builder: (context, c) {
      _build(Size(c.maxWidth, c.maxHeight));
      return MouseRegion(
        opaque: false,
        onEnter: (_) => _hovering = true,
        onExit: (_) {
          _hovering = false;
          _pointer = const Offset(-10000, -10000);
        },
        onHover: (e) {
          if (!_hovering) _smooth = e.localPosition;
          _hovering = true;
          _pointer = e.localPosition;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (e) {
            if (mode != EvsDotMode.glow) return;
            _ripples.add(_Ripple(e.localPosition.dx, e.localPosition.dy, 1600, 0.62, 1));
          },
          child: CustomPaint(
            size: Size.infinite,
            painter: _DotPainter(
              dots: _dots,
              glow: mode == EvsDotMode.glow,
              base: widget.color ?? t.palette.dot,
              peak: t.accent.a2,
            ),
          ),
        ),
      );
    });
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter({required this.dots, required this.glow, required this.base, required this.peak});

  final List<_Dot> dots;
  final bool glow;
  final Color base, peak;

  @override
  void paint(Canvas canvas, Size size) {
    if (!glow) {
      final paint = Paint()..color = base;
      for (final d in dots) {
        canvas.drawCircle(Offset(d.x, d.y), 1.15 + d.lift * 1.45, paint);
      }
      return;
    }
    // Режим свечения: рисуем пачками по уровню яркости — на порядок дешевле,
    // чем менять цвет кисти на каждой точке.
    const levels = 12;
    final buckets = List.generate(levels, (_) => <_Dot>[]);
    for (final d in dots) {
      final lv = d.lift <= 0 ? 0 : math.min(levels - 1, 1 + (d.lift * (levels - 1)).floor());
      buckets[lv].add(d);
    }
    final baseA = math.max(0.05, base.opacity * 0.45);
    final peakA = math.min(1.0, base.opacity * 2.7);
    for (var lv = 0; lv < levels; lv++) {
      if (buckets[lv].isEmpty) continue;
      final t = lv == 0 ? 0.0 : lv / (levels - 1);
      final paint = Paint()
        ..color = Color.lerp(base, peak, t * 0.85)!.withOpacity(baseA + (peakA - baseA) * t);
      for (final d in buckets[lv]) {
        canvas.drawCircle(Offset(d.ox, d.oy), 1.05 * (1 + d.lift * 1.9), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) => true;
}
