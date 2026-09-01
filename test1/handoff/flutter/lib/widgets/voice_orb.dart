import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../evs_theme.dart';
import '../models/evs_models.dart';

/// Шар ассистента: три расходящихся кольца, вращающееся размытое свечение
/// и сама сфера с иконкой микрофона.
///
/// В покое кольца остановлены — в прототипе это animation-play-state: paused.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.state, this.onTap, this.size = 190});

  final VoiceState state;
  final VoidCallback? onTap;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with TickerProviderStateMixin {
  late final AnimationController _rings =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2900))..repeat();
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat();

  @override
  void dispose() {
    _rings.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(VoiceOrb old) {
    super.didUpdateWidget(old);
    if (widget.state.isIdle) {
      _rings.stop();
    } else if (!_rings.isAnimating) {
      _rings.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final orb = widget.size * 0.4526; // 86 из 190

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(alignment: Alignment.center, children: [
            _ring(inset: 0, color: s.c2, delay: 0),
            _ring(inset: 16, color: s.c1, delay: 0.95 / 2.9),
            _ring(inset: 32, color: s.c2, delay: 1.9 / 2.9),
            Positioned.fill(
              left: 36, right: 36, top: 36, bottom: 36,
              child: AnimatedBuilder(
                animation: _spin,
                builder: (context, child) =>
                    Transform.rotate(angle: _spin.value * 2 * math.pi, child: child),
                child: Opacity(
                  opacity: 0.6,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(colors: [s.c1, s.c2, s.c1]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              width: orb,
              height: orb,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.32, -0.4),
                  colors: [s.c1, s.c2, s.c2.withOpacity(0.82)],
                  stops: const [0, 0.62, 1],
                ),
                boxShadow: [
                  BoxShadow(color: s.c2.withOpacity(s.isIdle ? 0.3 : 0.6), blurRadius: 52, spreadRadius: 2),
                ],
              ),
              child: const Icon(Icons.mic_none_rounded, size: 27, color: Colors.white),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _ring({required double inset, required Color color, required double delay}) {
    return Positioned.fill(
      left: inset, right: inset, top: inset, bottom: inset,
      child: AnimatedBuilder(
        animation: _rings,
        builder: (context, _) {
          final t = (_rings.value + delay) % 1.0;
          return Transform.scale(
            scale: 0.7 + t * 0.8,
            child: Opacity(
              opacity: (0.55 * (1 - t)).clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
