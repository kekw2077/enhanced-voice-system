part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — шар ассистента из макета
   --------------------------------------------------------------------------
   Ровно то, что нарисовано в прототипе: три расходящихся кольца, вращающееся
   коническое свечение под ними и ядро с радиальной заливкой и микрофоном.

   Цвета — из макета, по состоянию (`const HEX` в прототипе):

       покой      #5C6478 → #7C8399     слушаю   #3B7BE8 → #C0568F
       думаю      #7F5AAC → #3269CE     говорю   #1F9E7A → #3C8CA8

   Одно отличие от прототипа, сделанное намеренно: ядро дышит на НАСТОЯЩЕМ
   уровне синтеза, пока ассистент говорит. В макете шар просто крутится по
   таймеру — там нечему звучать. Здесь звук есть, и шар, который не отзывается
   на собственный голос, выглядел бы записью, а не ассистентом. Размах
   маленький (±6%), силуэт остаётся макетным.

   Кольца и свечение крутятся, только пока ассистент занят: в прототипе у них
   `animation-play-state: paused` в покое, и это совпадает с MotionPolicy.
   ========================================================================== */

/// Пара цветов состояния, как `HEX` в макете.
(Color, Color) prismStateColors(String stage) => switch (stage) {
      'listening' => (const Color(0xFF3B7BE8), const Color(0xFFC0568F)),
      'thinking' => (const Color(0xFF7F5AAC), const Color(0xFF3269CE)),
      'speaking' => (const Color(0xFF1F9E7A), const Color(0xFF3C8CA8)),
      _ => (const Color(0xFF5C6478), const Color(0xFF7C8399)),
    };

/// Шар ассистента. Размер задаётся снаружи: 190 в «Центре», 96 в предпросмотре
/// настроек, сколько угодно в плавающем виджете — все доли внутри считаются от
/// него, как проценты в макете.
class PrismOrb extends StatefulWidget {
  const PrismOrb({
    super.key,
    this.size = 190,
    this.stage,
    this.showMic = true,
    this.reactive = true,
  });

  final double size;

  /// Состояние принудительно (предпросмотр в настройках). Пусто — берётся
  /// настоящее, из конвейера.
  final String? stage;

  /// Рисовать микрофон в ядре. В маленьком виджете он превращается в кляксу.
  final bool showMic;

  /// Отзываться на живой уровень синтеза.
  final bool reactive;

  @override
  State<PrismOrb> createState() => _PrismOrbState();
}

class _PrismOrbState extends State<PrismOrb> with TickerProviderStateMixin {
  /// Кольцо расходится за 2,9 с — период из макета. Три кольца берут одну
  /// фазу со сдвигом, поэтому контроллер нужен один.
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2900),
  );

  /// Коническое свечение: оборот за 9 с.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  bool _running = false;

  @override
  void initState() {
    super.initState();
    NexusPipeline.instance.addListener(_sync);
    MotionPolicy.foreground.addListener(_sync);
    _sync();
  }

  String get _stage => widget.stage ?? NexusPipeline.instance.stage;

  void _sync() {
    final want = _stage != 'idle' && MotionPolicy.foreground.value;
    if (want == _running) {
      if (mounted && widget.stage == null) setState(() {});
      return;
    }
    _running = want;
    if (want) {
      _ring.repeat();
      _spin.repeat();
    } else {
      _ring.stop();
      _spin.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PrismOrb old) {
    super.didUpdateWidget(old);
    if (old.stage != widget.stage) _sync();
  }

  @override
  void dispose() {
    NexusPipeline.instance.removeListener(_sync);
    MotionPolicy.foreground.removeListener(_sync);
    _ring.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stage = _stage;
    final (c1, c2) = prismStateColors(stage);
    final idle = stage == 'idle';
    final s = widget.size;

    return SizedBox(
      width: s,
      height: s,
      child: ValueListenableBuilder<double>(
        valueListenable: VoiceLevels.instance.tts,
        builder: (context, level, _) {
          // Дыхание ядра: только пока звук идёт и только если о нём просили.
          final lift =
              widget.reactive ? (level.clamp(0.0, 1.0) * 0.06) : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              // Кольца и свечение лежат ПОД ядром и не ловят курсор: нажатие
              // на шар — это удержание микрофона, кольцо его не перехватывает.
              IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ring,
                  builder: (context, _) => Stack(
                    alignment: Alignment.center,
                    children: [
                      for (final (i, phase)
                          in const [(0, 0.0), (1, 0.3276), (2, 0.6552)])
                        _ringAt(
                          (_ring.value + phase) % 1.0,
                          i.isEven ? c2 : c1,
                          s,
                        ),
                    ],
                  ),
                ),
              ),
              IgnorePointer(
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (context, _) => Opacity(
                    opacity: 0.6,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                          sigmaX: s * 0.042, sigmaY: s * 0.042),
                      child: Transform.rotate(
                        angle: _spin.value * 2 * math.pi,
                        child: Container(
                          width: s - s * 0.38,
                          height: s - s * 0.38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: SweepGradient(colors: [c1, c2, c1]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Ядро: 86 из 190 — те же 45% в любом размере.
              AnimatedScale(
                duration: const Duration(milliseconds: 140),
                scale: 1 + lift,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  width: s * 0.452,
                  height: s * 0.452,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.32, -0.4),
                      radius: 0.85,
                      colors: [c1, c2, c2.withValues(alpha: 0.82)],
                      stops: const [0, 0.62, 1],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: c2.withValues(alpha: idle ? 0.3 : 0.6),
                        blurRadius: s * 0.274,
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: widget.showMic
                      ? PrismIcon(PrismIcons.mic,
                          size: s * 0.142,
                          stroke: 1.9,
                          color: Colors.white)
                      : null,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Одно кольцо в своей фазе: scale .7 → 1.5, прозрачность .55 → 0.
  Widget _ringAt(double t, Color color, double s) {
    final scale = 0.7 + t * 0.8;
    final opacity = (0.55 * (1 - t)).clamp(0.0, 1.0);
    return Transform.scale(
      scale: scale,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: opacity)),
        ),
      ),
    );
  }
}
