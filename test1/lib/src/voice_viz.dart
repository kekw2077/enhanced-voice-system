part of '../main.dart';

class VoiceLevels {
  VoiceLevels._();
  static final VoiceLevels instance = VoiceLevels._();

  /// Level of the assistant's speech output (0..1) — fed by the sidecars'
  /// tts.level events in the main process, or by the WS mirror in the widget
  /// process. ALL visualizations react to this (never to the microphone).
  final ValueNotifier<double> tts = ValueNotifier(0.0);
}

// Adapter that drives the user-provided WaveField visualizers (wave_field_3d /
// wave_field_flat) with the live combined voice level, so they slot into the
// same vizType switch as the other hero/overlay styles. Background is kept
// transparent by default so the particles float over the app/widget backdrop;
// callers pass reduced particle counts for small thumbnails to stay cheap.
class EvsWaveViz extends StatelessWidget {
  final String kind; // 'wave3d' | 'waveflat'
  final double size;
  final Color background;
  final int? particleCount; // wave_field_flat only
  final int? numCols; // wave_field_3d only
  final int? numRows; // wave_field_3d only
  // Feather the edges to transparent so the field blends into the backdrop
  // instead of showing a hard rectangle (used for the home/background wave).
  final bool fadeEdges;
  // Recolour the field with the assistant state (green wake / violet thinking /
  // amber running / red error …), easing back to the user's accent when idle —
  // the same hook every other visualization already uses. Off for the static
  // picker thumbnails, which keep the original blue ramp.
  final bool reactive;
  const EvsWaveViz({
    super.key,
    required this.kind,
    this.size = 320,
    this.background = Colors.transparent,
    this.particleCount,
    this.numCols,
    this.numRows,
    this.fadeEdges = false,
    this.reactive = false,
  });

  Widget _field(Color? accent, bool onLight) => ValueListenableBuilder<double>(
        valueListenable: VoiceLevels.instance.tts,
        builder: (_, lv, __) {
          if (kind == 'wave3d') {
            return WaveField3D(
              level: lv,
              background: background,
              numCols: numCols ?? 110,
              numRows: numRows ?? 75,
              accent: accent,
              onLight: onLight,
            );
          }
          return WaveFieldFlat(
            level: lv,
            background: background,
            particleCount: particleCount ?? 5000,
            accent: accent,
            onLight: onLight,
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final onLight = _pal(context).brightness == Brightness.light;
    Widget field;
    if (!reactive) {
      field = _field(null, onLight);
    } else {
      final app = context.watch<AppState>();
      field = AnimatedBuilder(
        animation: Listenable.merge([
          VoiceAssistant.instance.state,
          VoiceAssistant.instance.wakeActive,
          VoiceAssistant.instance.wakePulse,
          vizNotice,
        ]),
        builder: (_, __) {
          final target = vizStateAccent(context, app);
          return TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: target),
            duration: const Duration(milliseconds: 320),
            builder: (_, tweened, ___) => _field(tweened ?? target, onLight),
          );
        },
      );
    }
    if (fadeEdges) {
      // Rectangular edge-feather: a symmetric fade on each of the four sides so
      // the widget dissolves into the background instead of ending on a hard
      // square. A radial vignette left the straight edges ~two-thirds opaque
      // (still boxy); stacking a horizontal and a vertical linear fade with
      // dstIn multiplies the alphas into a soft picture-frame on all sides
      // (corners fade the most, which reads naturally).
      const f = 0.16; // fraction of each side that dissolves
      field = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, f, 1 - f, 1.0],
        ).createShader(rect),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0.0, f, 1 - f, 1.0],
          ).createShader(rect),
          child: field,
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipRect(child: field),
    );
  }
}

// ---- Voice-reactive visualizations (home hero variants) ----
// All amplitudes come from VoiceLevels.history (real mic/TTS levels) — only
// the ring's slow rotation is decorative. A wake-word trigger adds a short
// glow burst (VoiceAssistant.wakePulse).

double _wakeGlow(int wakeMs) {
  if (wakeMs == 0) return 0;
  final dt = DateTime.now().millisecondsSinceEpoch - wakeMs;
  if (dt >= 1400) return 0;
  return 1.0 - dt / 1400.0;
}

// Mirrored bar "spectrum": bars are FIXED in place and move ONLY up/down
// (no sideways scrolling — user request). Heights = assistant speech level
// shaped by a center bell + light per-bar shimmer, VU-style attack/decay.
class EvsBarsViz extends StatefulWidget {
  final double width;
  final double height;
  final Color? color; // state/accent tint (blended into the bar gradient)
  const EvsBarsViz(
      {super.key, this.width = 340, this.height = 150, this.color});
  @override
  State<EvsBarsViz> createState() => _EvsBarsVizState();
}

class _EvsBarsVizState extends State<EvsBarsViz>
    with SingleTickerProviderStateMixin {
  static const int _n = 33;
  // Driven by MotionPolicy: the idle shimmer costs a full 60 fps repaint even
  // when the assistant is silent, so it only spins while motion is allowed.
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..addListener(_tick);
  late final AmbientMotion _ambient = AmbientMotion(_c);
  final List<double> _cur = List<double>.filled(_n, 0);
  double _t = 0;

  void _tick() {
    _t += 1 / 60;
    final lvl = VoiceLevels.instance.tts.value;
    final glow = _wakeGlow(VoiceAssistant.instance.wakePulse.value);
    const center = (_n - 1) / 2;
    for (var i = 0; i < _n; i++) {
      final d = (i - center).abs() / center;
      final bell = math.cos(d * math.pi / 2);
      final shimmer =
          0.85 + 0.15 * math.sin(_t * (3.1 + (i % 7) * 0.37) + i * 1.7);
      final target =
          (lvl * (0.25 + 0.75 * bell) * shimmer * (1 + glow * 0.6))
              .clamp(0.0, 1.0);
      final k = target > _cur[i] ? 0.45 : 0.14;
      _cur[i] += (target - _cur[i]) * k;
    }
  }

  @override
  void dispose() {
    _ambient.dispose();
    _c
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.width, widget.height),
        painter: _BarsPainter(_cur,
            tint: widget.color, hair: _overlayFill(context, 0.08), repaint: _c),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> heights;
  final Color? tint;
  final Color hair; // center baseline — theme-aware (was hardcoded white alpha)
  _BarsPainter(this.heights,
      {this.tint, this.hair = const Color(0x0FFFFFFF), required Listenable repaint})
      : super(repaint: repaint);

  static const _c1 = Color(0xFF5068D8);
  static const _c2 = Color(0xFF8855CC);
  static const _c3 = Color(0xFFC060D8);
  static const _c4 = Color(0xFFF0D080);

  @override
  void paint(Canvas canvas, Size size) {
    final n = heights.length;
    final midY = size.height / 2;
    final slot = size.width / n;
    final barW = slot * 0.55;
    canvas.drawLine(
        Offset(0, midY),
        Offset(size.width, midY),
        Paint()
          ..color = hair
          ..strokeWidth = 1);
    for (var i = 0; i < n; i++) {
      final v = heights[i].clamp(0.0, 1.0);
      final h = 2 + v * (size.height / 2 - 4);
      final x = slot * i + slot / 2;
      var color = v < 0.35
          ? Color.lerp(_c1, _c2, v / 0.35)!
          : v < 0.7
              ? Color.lerp(_c2, _c3, (v - 0.35) / 0.35)!
              : Color.lerp(_c3, _c4, (v - 0.7) / 0.3)!;
      if (tint != null) color = Color.lerp(color, tint!, 0.6)!;
      canvas.drawLine(
          Offset(x, midY - h),
          Offset(x, midY + h),
          Paint()
            ..color = color.withValues(alpha: 0.55 + 0.45 * v)
            ..strokeWidth = barW
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => true;
}

// Circular ring with radial spikes. Spikes sit at FIXED angles and only
// extend/retract with the assistant speech level (no rotation/circular
// travel — user request); the color sweep still slowly cycles for life.
class EvsRingViz extends StatefulWidget {
  final double size;
  final Color? color; // state/accent tint (blended into the sweep)
  const EvsRingViz({super.key, this.size = 230, this.color});
  @override
  State<EvsRingViz> createState() => _EvsRingVizState();
}

class _EvsRingVizState extends State<EvsRingViz>
    with SingleTickerProviderStateMixin {
  static const int _spikes = 90;
  late final AnimationController _rot =
      AnimationController(vsync: this, duration: const Duration(seconds: 24))
        ..addListener(_tick);
  late final AmbientMotion _ambient = AmbientMotion(_rot);
  final List<double> _cur = List<double>.filled(_spikes, 0);
  double _t = 0;

  void _tick() {
    _t += 1 / 60;
    final lvl = VoiceLevels.instance.tts.value;
    final glow = _wakeGlow(VoiceAssistant.instance.wakePulse.value);
    for (var i = 0; i < _spikes; i++) {
      final shimmer =
          0.8 + 0.2 * math.sin(_t * (2.7 + (i % 9) * 0.53) + i * 2.39);
      final target = (lvl * shimmer * (1 + glow * 0.8)).clamp(0.0, 1.0);
      final k = target > _cur[i] ? 0.45 : 0.14;
      _cur[i] += (target - _cur[i]) * k;
    }
  }

  @override
  void dispose() {
    _ambient.dispose();
    _rot
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _rot,
        builder: (_, __) => CustomPaint(
          size: Size.square(widget.size),
          painter: _RingPainter(
            _cur,
            _rot.value,
            VoiceAssistant.instance.wakePulse.value,
            widget.color,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final List<double> lens; // per-spike smoothed levels, fixed angles
  final double phase; // 0..1 — rotates ONLY the color sweep, not the spikes
  final int wakeMs;
  final Color? tint;
  _RingPainter(this.lens, this.phase, this.wakeMs, this.tint);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.30;
    final maxSpike = size.width * 0.17;
    final glow = _wakeGlow(wakeMs);
    var sweepColors = const [
      Color(0xFF5068D8),
      Color(0xFF8855CC),
      Color(0xFFC060D8),
      Color(0xFF54E0B0),
      Color(0xFF5068D8),
    ];
    if (tint != null) {
      sweepColors =
          sweepColors.map((c) => Color.lerp(c, tint!, 0.55)!).toList();
    }
    final sweep = SweepGradient(
      colors: sweepColors,
      transform: GradientRotation(phase * 2 * math.pi),
    ).createShader(Rect.fromCircle(center: c, radius: r + maxSpike));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + glow * 2
          ..shader = sweep);
    if (glow > 0) {
      canvas.drawCircle(
          c,
          r + glow * 10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10 * glow
            ..shader = sweep
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    }
    final n = lens.length;
    for (var i = 0; i < n; i++) {
      final ang = (i / n) * 2 * math.pi;
      final v = lens[i].clamp(0.0, 1.0);
      final len = 2 + v * maxSpike;
      final dir = Offset(math.cos(ang), math.sin(ang));
      canvas.drawLine(
          c + dir * (r + 2),
          c + dir * (r + 2 + len),
          Paint()
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..shader = sweep
            ..color = Colors.white.withValues(alpha: 0.5 + v * 0.5));
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => true;
}

// ---- Live wrappers for the new widget styles (Siri Orb / LK bars) ----

/// Generates the three orb blob colors from a single accent (HSL shifts) —
/// same recipe as the user-provided widgets settings mock.
SiriOrbColors evsOrbColors(Color accent, {bool onLight = false}) {
  final h = HSLColor.fromColor(accent);
  Color shift(double deg, double satMul, double lightMul) => h
      .withHue((h.hue + deg) % 360)
      .withSaturation((h.saturation * satMul).clamp(0.0, 1.0))
      .withLightness((h.lightness * lightMul).clamp(0.0, 1.0))
      .toColor();
  return SiriOrbColors(
    // Dark orb base on dark themes; a light neutral on the light themes so the
    // orb doesn't read as a dark blob on cream/white.
    bg: onLight ? const Color(0xFFECECF1) : const Color(0xFF0A0A12),
    c1: accent,
    c2: shift(42, 1.0, 1.05),
    c3: shift(-52, 0.95, 1.0),
  );
}

/// Siri Orb / LK bars fed with the REAL combined voice level and the live
/// assistant state: speaking while TTS audio plays, thinking while the LLM
/// works, listening while the mic streams, idle otherwise.
// State-reactive accent for the voice visualizations: the widget/orb changes
// color to signal what the assistant is doing (heard the wake word → green,
// thinking → violet, running → amber, command ok/err → green/red), then returns
// to the user's accent when idle. Replaces the old text badges. Reads the
// (WS-mirrored) VoiceAssistant notifiers + vizNotice, so it works in both the
// main app and the widget process.
// Default visualization accent (violet). When vizAccent still equals this, the
// visualization follows the theme accent; any other value is a user override.
const int kDefaultVizAccent = 0xFFCC785C;

Color vizStateAccent(BuildContext c, AppState app) {
  // Idle/base colour follows the theme accent by default (so the visualization
  // matches Claude terracotta / Apple blue / … ); if the user picked a custom
  // swatch in the Widgets settings (vizAccent changed from the default), honour
  // that override instead.
  final base =
      app.vizAccent == kDefaultVizAccent ? _accent(c) : Color(app.vizAccent);
  final notice = vizNotice.value;
  if (notice != null && notice.$1.isNotEmpty) {
    switch (notice.$2) {
      case 'ok':
        return _success(c);
      case 'err':
        return _danger(c);
      default:
        return base;
    }
  }
  if (VoiceAssistant.instance.wakeActive.value) return _success(c);
  switch (VoiceAssistant.instance.state.value) {
    case VaState.armed:
      return _info(c);
    case VaState.thinking:
      return Color.lerp(_accent(c), _success(c), 0.45)!;
    case VaState.running:
      return _warn(c);
    default:
      return base; // idle / listening / speaking → the user's accent
  }
}

class EvsLiveViz extends StatelessWidget {
  final String kind; // 'orb' | 'lkbars'
  final double maxSize;
  const EvsLiveViz({super.key, required this.kind, required this.maxSize});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return AnimatedBuilder(
      animation: Listenable.merge([
        VoiceLevels.instance.tts,
        VoiceAssistant.instance.state,
        VoiceAssistant.instance.wakeActive,
        VoiceAssistant.instance.wakePulse,
        vizNotice,
      ]),
      builder: (_, __) {
        // Visualizations react ONLY to the assistant's speech output — the
        // microphone never moves them (user decision; the sidebar mic widget
        // is the mic monitor).
        final lv = VoiceLevels.instance.tts.value;
        final va = VoiceAssistant.instance.state.value;
        final speaking = VoiceLevels.instance.tts.value > 0.001;
        final thinking = !speaking &&
            (va == VaState.thinking || va == VaState.running ||
                app.isGenerating);
        final listening = !speaking &&
            !thinking &&
            (va == VaState.listening || MicMeter.instance.active);
        // Colour by assistant state (green wake / violet think / amber run …),
        // smoothly fading back to the user's accent when idle.
        final target = vizStateAccent(context, app);
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: target),
          duration: const Duration(milliseconds: 320),
          builder: (context, tweened, __) {
            final accent = tweened ?? target;
            if (kind == 'lkbars') {
              final st = speaking
                  ? LkVisualizerState.speaking
                  : thinking
                      ? LkVisualizerState.thinking
                      : listening
                          ? LkVisualizerState.listening
                          : LkVisualizerState.idle;
              final barW = maxSize / (app.barCount * 1.7);
              return LkBarVisualizer(
                level: lv,
                state: st,
                count: app.barCount,
                color: accent,
                barWidth: barW,
                spacing: barW * 0.7,
                minHeight: barW,
                maxHeight: maxSize * 0.55,
              );
            }
            final st = speaking
                ? SiriOrbState.speaking
                : thinking
                    ? SiriOrbState.thinking
                    : listening
                        ? SiriOrbState.listening
                        : SiriOrbState.idle;
            return SiriOrb(
              size: math.min(app.orbSize, maxSize),
              level: lv,
              state: st,
              colors: evsOrbColors(accent,
                  onLight: _pal(context).brightness == Brightness.light),
              animationDuration: app.orbSpeed,
            );
          },
        );
      },
    );
  }
}

// ---- Floating overlay-widget view ----
// The root UI of the WIDGET PROCESS (VizOverlayApp): a small transparent
// always-on-top window floating directly on the desktop, independent of the
// chat window. Drag anywhere to move it; double-click (or the hover button)
// asks the main process to open the chat.
class OverlayWidgetView extends StatefulWidget {
  final VoidCallback onOpen;
  final VoidCallback onHide;
  const OverlayWidgetView(
      {super.key, required this.onOpen, required this.onHide});
  @override
  State<OverlayWidgetView> createState() => _OverlayWidgetViewState();
}

class _OverlayWidgetViewState extends State<OverlayWidgetView> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final viz = app.vizType;
    return Material(
      type: MaterialType.transparency,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startDragging(),
          onDoubleTap: widget.onOpen,
          child: LayoutBuilder(builder: (context, box) {
            final s = box.biggest.shortestSide;
            // The window is kWidgetWindowScale× larger than the visualization
            // so there's transparent margin around it; size the backdrop and
            // viz by `content` (the inner box) so the widgets keep their size.
            final content = s / kWidgetWindowScale;
            final pad = (s - content) / 2;
            // Recompute the state colour when the assistant state changes and
            // tween it, so all styles (bars/waves/sphere) react by colour —
            // no more text badges.
            return AnimatedBuilder(
              animation: Listenable.merge([
                VoiceAssistant.instance.state,
                VoiceAssistant.instance.wakeActive,
                VoiceAssistant.instance.wakePulse,
                vizNotice,
              ]),
              builder: (context, __) {
                final targetColor = vizStateAccent(context, app);
                return TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: targetColor),
                  duration: const Duration(milliseconds: 320),
                  builder: (context, tweened, __) {
                    final accent = tweened ?? targetColor;
                    return Stack(alignment: Alignment.center, children: [
                      // Soft dark backdrop, fading to transparent at its edge.
                      Container(
                        width: content,
                        height: content,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [
                            Color(0x59000000),
                            Color(0x33000000),
                            Color(0x00000000),
                          ], stops: [
                            0.0,
                            0.62,
                            1.0,
                          ]),
                        ),
                      ),
                      if (viz == 'bars')
                        EvsBarsViz(
                            width: content * 0.86,
                            height: content * 0.46,
                            color: accent)
                      else if (viz == 'waves')
                        EvsRingViz(size: content * 0.86, color: accent)
                      else if (viz == 'orb')
                        EvsLiveViz(kind: 'orb', maxSize: content * 0.72)
                      else if (viz == 'lkbars')
                        EvsLiveViz(kind: 'lkbars', maxSize: content * 0.8)
                      else if (viz == 'wave3d')
                        EvsWaveViz(
                            kind: 'wave3d',
                            size: content * 0.92,
                            fadeEdges: true,
                            reactive: true)
                      else if (viz == 'waveflat')
                        EvsWaveViz(
                            kind: 'waveflat',
                            size: content * 0.92,
                            fadeEdges: true,
                            reactive: true)
                      else
                        ParticleSphere(
                          size: content * 0.62,
                          color: accent,
                          scattered: false,
                          soundLevel: VoiceLevels.instance.tts,
                        ),
                      // Hover controls: open the full window / hide the widget.
                      Positioned(
                        top: pad + 6,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: _hover ? 1 : 0,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            _ovlBtn(Icons.open_in_full, app.t('ovlOpenChat'),
                                widget.onOpen),
                            const SizedBox(width: 6),
                            _ovlBtn(Icons.close, app.t('ovlHide'), widget.onHide),
                          ]),
                        ),
                      ),
                    ]);
                  },
                );
              },
            );
          }),
        ),
      ),
    );
  }

  // NB: no Tooltip here — OverlayWidgetView lives OUTSIDE the Navigator (see
  // MiraiApp.builder), so there is no Overlay ancestor for tooltips to mount
  // into (they'd throw "No Overlay widget found" on hover).
  Widget _ovlBtn(IconData icon, String tip, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xCC1C1D2A),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Icon(icon, size: 15, color: Colors.white70),
      ),
    );
  }
}

// Live microphone amplitude meter: streams raw PCM via `record` and turns it
// into a smoothed 0..1 level (RMS). If streaming is unavailable on this
// platform/device, `active` stays false and the widget falls back to a
// decorative animation.
class MicMeter {
  MicMeter._();
  static final MicMeter instance = MicMeter._();

  final AudioRecorder _rec = AudioRecorder();
  final ValueNotifier<double> level = ValueNotifier(0.0);
  StreamSubscription<Uint8List>? _sub;
  bool active = false;
  String _deviceId = '';
  String currentLabel = ''; // label of the selected mic ('' = default)
  bool _starting = false;

  // Start (or restart, if the selected device changed) the live meter on the
  // given input device ('' = system default). Idempotent for the same device.
  Future<void> start({String deviceId = '', bool retry = true}) async {
    if (_starting) return;
    if (active && deviceId == _deviceId) return;
    _starting = true;
    try {
      await _stopStream();
      _deviceId = deviceId;
      // hasPermission() is unreliable on Windows desktop (no per-app prompt);
      // call it to nudge any permission flow but don't gate on it — just try
      // to open the stream and fall back gracefully if it throws.
      try {
        await _rec.hasPermission();
      } catch (_) {}
      InputDevice? device;
      if (deviceId.isNotEmpty) {
        for (final d in await listDevices()) {
          if (d.id == deviceId) {
            device = d;
            break;
          }
        }
      }
      // Human-readable name of the selected mic — the Python sidecar matches
      // its PortAudio input by (a prefix of) this label (stt.start device).
      currentLabel = device?.label ?? '';
      final stream = await _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        device: device,
      ));
      active = true;
      _sub = stream.listen(_onData, onError: (_) {});
    } catch (_) {
      active = false;
    } finally {
      _starting = false;
    }
    // One delayed retry if the first attempt didn't produce a live stream
    // (e.g. the device was briefly busy at launch).
    if (!active && retry) {
      Future.delayed(const Duration(milliseconds: 1200),
          () => start(deviceId: deviceId, retry: false));
    }
  }

  Future<List<InputDevice>> listDevices() async {
    try {
      return await _rec.listInputDevices();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _stopStream() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    active = false;
  }

  void _onData(Uint8List bytes) {
    final count = bytes.lengthInBytes ~/ 2;
    if (count == 0) return;
    final bd = ByteData.sublistView(bytes);
    double sum = 0;
    for (int i = 0; i < count; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final rms = math.sqrt(sum / count);
    // Speech RMS is small (~0.01..0.2); boost then clamp, and smooth so the
    // bars glide rather than flicker.
    final norm = (rms * 8).clamp(0.0, 1.0);
    level.value = level.value + (norm - level.value) * 0.5;
  }
}

// Microphone widget: a live equalizer driven by MicMeter (reacts to the mic),
// with a decorative animated fallback when no live level is available.
class _DesktopMicWidget extends StatefulWidget {
  const _DesktopMicWidget();
  @override
  State<_DesktopMicWidget> createState() => _DesktopMicWidgetState();
}

class _DesktopMicWidgetState extends State<_DesktopMicWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));
  late final AmbientMotion _cAmbient = AmbientMotion(_c);
  static const _n = 22;
  // Scrolling history of recent levels → a real moving waveform. Must be
  // growable: the tick does removeAt(0)+add, which throws on a fixed-length
  // list (that's why the waveform used to sit frozen).
  final List<double> _hist = List<double>.filled(_n, 0.0, growable: true);
  Timer? _tick;
  // Consecutive ticks with a silent mic + a fully-flat history. Once the
  // waveform has visibly drained to zero the 16 Hz setState is pure waste, so
  // the timer parks itself and a real mic level (or MotionPolicy re-allowing
  // ambient motion) restarts it.
  int _quiet = 0;

  void _startTicker() {
    _tick ??= Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted) return;
      final lvl = MicMeter.instance.level.value;
      if (lvl < 0.004 && !MotionPolicy.ambient.value) {
        _quiet++;
        if (_quiet > _n && _hist.every((v) => v < 0.004)) {
          _tick?.cancel();
          _tick = null; // parked; _wake() restarts on the next real level
          return;
        }
      } else {
        _quiet = 0;
      }
      setState(() {
        _hist.removeAt(0);
        // Pure microphone level — this widget is the mic monitor (the
        // visualizations elsewhere react to the assistant's speech instead).
        _hist.add(lvl);
      });
    });
  }

  void _wake() {
    if (!mounted) return;
    _quiet = 0;
    if (_tick == null) _startTicker();
  }

  @override
  void initState() {
    super.initState();
    MicMeter.instance
        .start(deviceId: context.read<AppState>().inputDeviceId)
        .then((_) {
      if (!mounted) return;
      setState(() {});
    });
    _startTicker();
    MicMeter.instance.level.addListener(_wake);
    MotionPolicy.ambient.addListener(_wake);
  }

  @override
  void dispose() {
    MicMeter.instance.level.removeListener(_wake);
    MotionPolicy.ambient.removeListener(_wake);
    _tick?.cancel();
    _cAmbient.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final live = MicMeter.instance.active;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _overlayFill(context, 0.042),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(Icons.mic_none, size: 13, color: _sub(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(app.t('microphone'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _sectionLabel(context))),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: _success(context).withValues(alpha: 0.12),
                    border: Border.all(
                        color: _success(context).withValues(alpha: 0.28)),
                  ),
                  child: Text(live ? app.t('micListening') : app.t('ready'),
                      maxLines: 1,
                      style: EvsType.caption.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _success(context))),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 28,
            child: live
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (int i = 0; i < _n; i++) ...[
                        Expanded(child: _bar(3 + _hist[i].clamp(0.0, 1.0) * 25)),
                        if (i < _n - 1) const SizedBox(width: 2.5),
                      ],
                    ],
                  )
                : AnimatedBuilder(
                    animation: _c,
                    builder: (_, __) {
                      final t = _c.value * 2 * math.pi * 3;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (int i = 0; i < _n; i++) ...[
                            Expanded(
                                child: _bar(
                                    6 + ((math.sin(t + i * 0.5) + 1) / 2) * 22)),
                            if (i < _n - 1) const SizedBox(width: 2.5),
                          ],
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _bar(double height) => Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: _accentGradientOf(context),
          ),
        ),
      );
}
