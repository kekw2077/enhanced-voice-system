import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_theme.dart';
import '../evs_tokens.dart';

/// Три декоративные анимации из прототипа: breathe, flow, pulse.
/// В CSS они меняли hue-rotate и позицию градиента; здесь то же самое
/// делается матрицей поворота оттенка и сдвигом стопов.
///
/// Режим берётся из EvsThemeData.anim; при EvsAnim.off анимация не
/// запускается вовсе — контроллер не создаётся, кадры не тратятся.

/// Поворот оттенка у любого поддерева. Дёшево: один ColorFilter на слой.
class BreatheFilter extends StatefulWidget {
  const BreatheFilter({super.key, required this.child, this.amplitude = 14, this.seconds = 17});

  final Widget child;
  /// Максимальный поворот оттенка в градусах в каждую сторону.
  final double amplitude;
  final int seconds;

  @override
  State<BreatheFilter> createState() => _BreatheFilterState();
}

class _BreatheFilterState extends State<BreatheFilter> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  void _sync(EvsAnim anim) {
    final wanted = anim != EvsAnim.off;
    if (wanted && _c == null) {
      _c = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds))..repeat();
    } else if (!wanted && _c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  @override
  void dispose() { _c?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final anim = EvsTheme.of(context).anim;
    _sync(anim);
    final c = _c;
    if (c == null) return widget.child;

    return AnimatedBuilder(
      animation: c,
      builder: (context, child) {
        final k = switch (anim) {
          EvsAnim.pulse => math.sin(c.value * 6.2832 * 2),
          EvsAnim.flow => c.value * 2 - 1,
          _ => math.sin(c.value * 6.2832),
        };
        return ColorFiltered(
          colorFilter: hueRotation(k * widget.amplitude),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Матрица поворота оттенка (по спецификации SVG feColorMatrix type="hueRotate").
ColorFilter hueRotation(double degrees) {
  final a = degrees * math.pi / 180;
  final c = math.cos(a), s = math.sin(a);
  return ColorFilter.matrix(<double>[
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

/// Градиент, который течёт вдоль текста или полосы — CSS-аналог
/// background-size: 200% + сдвиг background-position.
class FlowingGradientText extends StatefulWidget {
  const FlowingGradientText(this.text, {super.key, required this.style, this.textAlign, this.seconds = 13});

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;
  final int seconds;

  @override
  State<FlowingGradientText> createState() => _FlowingGradientTextState();
}

class _FlowingGradientTextState extends State<FlowingGradientText> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  void _sync(bool on) {
    if (on && _c == null) {
      _c = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds))..repeat();
    } else if (!on && _c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  @override
  void dispose() { _c?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    _sync(t.anim != EvsAnim.off);
    final c = _c;

    Widget paint(double shift) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(-1 + shift, 0),
            end: Alignment(1 + shift, 0),
            colors: [t.accent.a1, t.accent.a2, t.accent.a3, t.accent.a1],
            stops: const [0, 0.34, 0.68, 1],
          ).createShader(rect),
          child: Text(widget.text,
              textAlign: widget.textAlign,
              style: widget.style.copyWith(color: Colors.white)),
        );

    if (c == null) return paint(0);
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) => paint(
        t.anim == EvsAnim.pulse
            ? math.sin(c.value * 6.2832) * 0.5
            : c.value * 2 - 1,
      ),
    );
  }
}

/// Мягкое дыхание масштабом и прозрачностью — для акцентных плашек.
class PulseScale extends StatefulWidget {
  const PulseScale({super.key, required this.child, this.seconds = 6, this.amount = 0.04});
  final Widget child;
  final int seconds;
  final double amount;

  @override
  State<PulseScale> createState() => _PulseScaleState();
}

class _PulseScaleState extends State<PulseScale> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  void _sync(bool on) {
    if (on && _c == null) {
      _c = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds))
        ..repeat(reverse: true);
    } else if (!on && _c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  @override
  void dispose() { _c?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    _sync(EvsTheme.of(context).anim != EvsAnim.off);
    final c = _c;
    if (c == null) return widget.child;
    return AnimatedBuilder(
      animation: c,
      builder: (context, child) => Transform.scale(
        scale: 1 + Curves.easeInOut.transform(c.value) * widget.amount,
        child: Opacity(opacity: 0.86 + c.value * 0.14, child: child),
      ),
      child: widget.child,
    );
  }
}
