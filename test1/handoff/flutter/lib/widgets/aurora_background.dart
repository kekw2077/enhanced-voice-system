import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import 'anim_accent.dart';

/// Фоновый слой. Три варианта, как в настройках прототипа:
/// aurora — мягкие пятна (дёшево, работает везде),
/// shader — фрагментный шейдер shaders/aurora.frag,
/// off    — ничего.
class EvsBackgroundLayer extends StatelessWidget {
  const EvsBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    return switch (t.background) {
      EvsBackground.off => const SizedBox.expand(),
      EvsBackground.aurora => const BreatheFilter(child: _Blobs()),
      EvsBackground.shader => const _ShaderAurora(),
    };
  }
}

/// Три размытых пятна внизу экрана — CSS-версия на radial-gradient + blur.
class _Blobs extends StatefulWidget {
  const _Blobs();
  @override
  State<_Blobs> createState() => _BlobsState();
}

class _BlobsState extends State<_Blobs> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final a = t.accent;
    return IgnorePointer(
      child: Opacity(
        opacity: t.palette.auroraOpacity,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 46, sigmaY: 46),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final k = _c.value * 6.2832;
              return Stack(children: [
                _blob(a.a1, const Alignment(-0.8, 1.5), 0.72, 0.94, k),
                _blob(a.a2, const Alignment(0.85, 1.6), 0.76, 0.98, k + 2.1),
                _blob(a.a3, const Alignment(0.05, 1.9), 0.50, 0.86, k + 4.2),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _blob(Color c, Alignment at, double w, double h, double phase) {
    return Align(
      alignment: Alignment(at.x + 0.06 * (phase.remainder(6.2832) / 6.2832 - 0.5), at.y),
      child: FractionallySizedBox(
        widthFactor: w,
        heightFactor: h,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [c, c.withOpacity(0)], stops: const [0, 0.62]),
          ),
        ),
      ),
    );
  }
}

/// Шейдерная аврора. Требует записи в pubspec:
///   flutter:
///     shaders:
///       - shaders/aurora.frag
class _ShaderAurora extends StatefulWidget {
  const _ShaderAurora();
  @override
  State<_ShaderAurora> createState() => _ShaderAuroraState();
}

class _ShaderAuroraState extends State<_ShaderAurora> with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker = createTicker((d) => setState(() => _elapsed = d))..start();
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/aurora.frag');
    if (mounted) setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() { _ticker.dispose(); _shader?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final s = _shader;
    if (s == null) return const _Blobs();
    return IgnorePointer(
      child: Opacity(
        opacity: t.palette.auroraOpacity * 0.85,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
          child: CustomPaint(
            size: Size.infinite,
            painter: _ShaderPainter(
              shader: s,
              time: _elapsed.inMilliseconds / 1000 * (t.anim == EvsAnim.off ? 0 : 1),
              accent: t.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter({required this.shader, required this.time, required this.accent});
  final ui.FragmentShader shader;
  final double time;
  final EvsAccent accent;

  @override
  void paint(Canvas canvas, Size size) {
    void rgb(int at, Color c) {
      shader.setFloat(at, c.red / 255);
      shader.setFloat(at + 1, c.green / 255);
      shader.setFloat(at + 2, c.blue / 255);
    }
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time);
    rgb(3, accent.a1);
    rgb(6, accent.a2);
    rgb(9, accent.a3);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ShaderPainter old) => old.time != time || old.accent != accent;
}
