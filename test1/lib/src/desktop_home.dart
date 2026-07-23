part of '../main.dart';

String _evsRelTime(AppState app, DateTime dt) {
  final now = DateTime.now();
  if (now.difference(dt).inMinutes < 1) return app.t('justNow');
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dt.year, dt.month, dt.day);
  String two(int n) => n.toString().padLeft(2, '0');
  if (that == today) return '${two(dt.hour)}:${two(dt.minute)}';
  if (that == today.subtract(const Duration(days: 1))) return app.t('yesterday');
  return '${dt.day}.${two(dt.month)}';
}

// Executes user-defined voice commands on Windows. Launching apps/files/URLs
// and running shell commands go through dart:io Process; media and volume keys
// use Win32 keybd_event (user32) via FFI. Phrase matching is deterministic
// (exact -> contains -> token overlap); semantic matching is the sidecar's job.

class _RootHome extends StatelessWidget {
  const _RootHome();
  @override
  Widget build(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.windows
      ? const DesktopHome()
      : const ChatScreen();
}

class DesktopHome extends StatelessWidget {
  const DesktopHome({super.key});
  @override
  Widget build(BuildContext context) {
    // Subscribe the shell to theme changes. Every colour token resolves through
    // `_pal(context)` which uses `context.read` (no subscription), and this
    // widget is `const`, so without an explicit dependency the shell background
    // (_bg / _evsShellBg) was computed once and never repainted when themeMode
    // changed (live theme switch, or the async prefs load right after startup) —
    // leaving a stale dark shell behind the transparent chat area while the
    // sidebar/content (which do watch) followed the theme. Rebuild on themeMode.
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    // Nexus interface style swaps in a parallel shell (rail + stage + chat); the
    // classic layout below is untouched. The two shells crossfade on a style
    // switch (TZ §7) via the AnimatedSwitcher keyed on the style.
    final nexus =
        context.select<AppState, AppStyle>((a) => a.appStyle) == AppStyle.nexus;
    final Widget shell = nexus
        ? const _NexusHome()
        : Scaffold(
            backgroundColor: _bg(context),
            body: Container(
              decoration: _evsShellBg(context),
              // The sidebar spans the FULL window height (its themed surface
              // reaches the very top), and the window title bar sits only over
              // the main content — so the top of the window reads as two colours
              // (cream rail on the left, the page background on the right)
              // instead of one strip above a shorter sidebar.
              child: const Row(
                children: [
                  _DesktopSidebar(),
                  Expanded(
                    child: Column(
                      children: [
                        _WindowTitleBar(),
                        Expanded(child: ChatScreen(desktop: true)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: KeyedSubtree(key: ValueKey(nexus), child: shell),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar();

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DesktopSettings()),
    );
  }

  Widget _iconBtn(BuildContext context, IconData icon, VoidCallback onTap,
      {String? tooltip}) {
    final btn = InkResponse(
      radius: 22,
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _overlayFill(context, 0.042),
          border: Border.all(color: _stroke(context)),
        ),
        child: Icon(icon, size: 15, color: _sub(context)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final convs = app.conversations;
    return Container(
      width: 264,
      decoration: _evsRailBg(context),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 16),
              child: Row(
                children: [
                  // The sidebar now reaches the top of the window, so its header
                  // doubles as the drag area (the window title bar sits only over
                  // the main content). Buttons stay outside the drag region.
                  Expanded(
                    child: DragToMoveArea(
                      child: Row(
                        children: [
                          const _EvsLogoMark(),
                          const SizedBox(width: 9),
                          Text(
                            'EVS',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: _txt(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _iconBtn(context, Icons.settings_outlined,
                      () => _openSettings(context),
                      tooltip: app.t('settings')),
                  const SizedBox(width: 8),
                  _iconBtn(context, Icons.add, () {
                    app.buzz();
                    app.newChat();
                  }, tooltip: app.t('newChat')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                'ИСТОРИЯ',
                style: EvsType.sectionLabel
                    .copyWith(letterSpacing: 0.9, color: _sectionLabel(context)),
              ),
            ),
            Expanded(
              child: convs.isEmpty
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      itemCount: convs.length,
                      itemBuilder: (_, i) {
                        final c = convs[i];
                        final active = c.id == app.current?.id;
                        return _historyItem(context, app, c, active);
                      },
                    ),
            ),
            Divider(color: _divider(context), height: 1, indent: 10, endIndent: 10),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 14, 10, 0),
              child: _DesktopSystemWidget(),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 10, 10, 12),
              child: _DesktopMicWidget(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyItem(
      BuildContext context, AppState app, Conversation c, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      // Right-click anywhere on the row → context menu (rename / pin / delete).
      // Desktop uses mouse, so this replaces the old mobile long-press.
      child: GestureDetector(
        onSecondaryTapDown: (d) =>
            showChatContextMenu(context, d.globalPosition, c, app),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              app.buzz();
              app.openChat(c);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: active
                    ? _accent(context).withValues(alpha: 0.10)
                    : Colors.transparent,
                border: Border.all(
                  color: active ? _accent(context).withValues(alpha: 0.2) : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      color: _overlayFill(context, 0.042),
                    ),
                    child: Icon(
                        c.pinned
                            ? Icons.push_pin
                            : Icons.chat_bubble_outline,
                        size: 13,
                        color: _sub(context)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: _txt(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _evsRelTime(app, c.updatedAt),
                          style: TextStyle(fontSize: 11.5, color: _faint(context)),
                        ),
                      ],
                    ),
                  ),
                  // Visible affordance for users who don't try right-click.
                  Builder(
                    builder: (btnCtx) => InkResponse(
                      radius: 16,
                      onTap: () {
                        final box =
                            btnCtx.findRenderObject() as RenderBox?;
                        final pos = box != null
                            ? box.localToGlobal(box.size.center(Offset.zero))
                            : Offset.zero;
                        showChatContextMenu(context, pos, c, app);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.more_vert,
                            size: 16, color: _faint(context)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Shared chat context menu (rename / pin / delete-with-undo), anchored at [pos]
// (global coords). Top-level so both the ConversationsSheet rows AND the
// desktop sidebar history items can use it. Glass mode uses the blurred glass
// menu; standard mode uses showMenu.
Future<void> showChatContextMenu(
    BuildContext ctx, Offset pos, Conversation c, AppState app) async {
  void handle(String? v) {
    if (v == 'rename') promptRenameChat(ctx, c, app);
    if (v == 'pin') app.togglePin(c);
    if (v == 'delete') deleteChatWithUndo(ctx, c, app);
  }

  if (_isGlass(ctx)) {
    final v = await showGlassMenu(
      ctx,
      position: pos,
      items: [
        GlassMenuItem('rename', app.t('rename')),
        GlassMenuItem('pin', c.pinned ? app.t('unpin') : app.t('pin')),
        GlassMenuItem('delete', app.t('delete'), color: Colors.redAccent),
      ],
    );
    handle(v);
    return;
  }
  final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
  final v = await showMenu<String>(
    context: ctx,
    color: _card(ctx),
    position: RelativeRect.fromRect(
      Rect.fromPoints(pos, pos),
      Offset.zero & (overlay?.size ?? const Size(0, 0)),
    ),
    items: [
      PopupMenuItem(
        value: 'rename',
        child: Text(app.t('rename'), style: TextStyle(color: _txt(ctx))),
      ),
      PopupMenuItem(
        value: 'pin',
        child: Text(c.pinned ? app.t('unpin') : app.t('pin'),
            style: TextStyle(color: _txt(ctx))),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Text(app.t('delete'),
            style: const TextStyle(color: Colors.redAccent)),
      ),
    ],
  );
  handle(v);
}

// Delete a chat but offer a few seconds to undo (deletes are otherwise
// irreversible — easy to hit by accident from the context menu).
void deleteChatWithUndo(BuildContext ctx, Conversation c, AppState app) {
  app.deleteChat(c);
  final messenger = ScaffoldMessenger.of(ctx);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: _card(ctx),
    duration: const Duration(seconds: 4),
    content: Text(app.t('chatDeleted'), style: TextStyle(color: _txt(ctx))),
    action: SnackBarAction(
      label: app.t('undo'),
      textColor: _accent(ctx),
      onPressed: () => app.undoDeleteChat(),
    ),
  ));
}

// Rename dialog for a chat. Pre-fills the current title; saving an empty title
// is a no-op (keeps the old one).
void promptRenameChat(BuildContext ctx, Conversation c, AppState app) {
  final ctrl = TextEditingController(text: c.title);
  showDialog(
    context: ctx,
    builder: (dialogContext) => _AppDialog(
      backgroundColor:
          _isGlass(ctx) ? _card(ctx).withValues(alpha: 0.9) : _card(ctx),
      title: Text(app.t('renameChat'), style: TextStyle(color: _txt(ctx))),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: TextStyle(color: _txt(ctx)),
        decoration: InputDecoration(
          hintText: app.t('renameChatHint'),
          hintStyle: TextStyle(color: _sub(ctx)),
        ),
        onSubmitted: (_) {
          app.renameChat(c, ctrl.text);
          Navigator.pop(dialogContext);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(app.t('cancel')),
        ),
        TextButton(
          onPressed: () {
            app.renameChat(c, ctrl.text);
            Navigator.pop(dialogContext);
          },
          child: Text(app.t('save')),
        ),
      ],
    ),
  );
}

// System monitor widget — live CPU/RAM from SystemMonitor (Win32 FFI). VRAM
// has no reliable cross-vendor API, so it stays "—".
class _DesktopSystemWidget extends StatelessWidget {
  const _DesktopSystemWidget();

  String _gb(int bytes, {int digits = 1}) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(digits);

  Widget _bar(BuildContext context, String name, String value, double frac,
      List<Color> grad, Color numColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _sub(context))),
              Text(value,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: numColor)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: _overlayFill(context, 0.1),
              valueColor: AlwaysStoppedAnimation(grad.first),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.only(bottom: 9),
            child: Text('СИСТЕМА',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: _sub(context))),
          ),
          ValueListenableBuilder<SystemStats>(
            valueListenable: SystemMonitor.instance.stats,
            builder: (_, s, __) {
              final active = s.totalRamBytes > 0;
              final ramTxt = active
                  ? '${_gb(s.usedRamBytes)} / ${_gb(s.totalRamBytes, digits: 0)} GB'
                  : '—';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _bar(context, 'CPU',
                      active ? '${(s.cpu * 100).round()}%' : '—', s.cpu,
                      [_accent(context)], _accent(context)),
                  _bar(context, 'RAM', ramTxt, s.ram,
                      [_info(context)], _info(context)),
                  _bar(context, 'VRAM', '—', 0.0, [_warn(context)],
                      _warn(context)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ======================= NEXUS INTERFACE STYLE (shell) =======================
// Alternative desktop shell (Nexus TZ §6, phase 2), rendered ONLY when
// app.appStyle == AppStyle.nexus. The classic DesktopHome path above is left
// byte-for-byte unchanged; this whole block is a parallel layout selected by a
// single branch in DesktopHome.build. Layout: thin rail (66) → stage (status
// pill + NexusHubOrb + transcript + subsystem cards) → chat column (360).

// Unified voice-pipeline state for the Nexus hub + subsystem cards (dorabotki
// §2): the overall stage plus the four conveyor flags, fused from the existing
// sidecar / assistant / TTS-level signals into one notifier. Flags flip only on
// real transitions (coalesced — no setState storms). `level` is a plain sampled
// field the orb reads per animation frame (never pushed), so nothing notifies at
// audio rate. Bind once via bind(app); it lives for the app's lifetime.
class NexusPipeline extends ChangeNotifier {
  NexusPipeline._();
  static final NexusPipeline instance = NexusPipeline._();

  AppState? _app;
  bool _bound = false;
  final List<StreamSubscription> _subs = [];
  Timer? _sttClear;

  String stage = 'idle'; // idle | listening | thinking | speaking
  bool vadActive = false;
  bool sttActive = false;
  bool llmActive = false;
  bool ttsActive = false;
  double level = 0.0; // sampled by the orb ticker; never triggers notify
  String _sig = '';

  void bind(AppState app) {
    if (_bound) return;
    _bound = true;
    _app = app;
    final sc = SidecarClient.instance;
    VoiceAssistant.instance.state.addListener(_recompute);
    VoiceLevels.instance.tts.addListener(_onTts);
    MicMeter.instance.level.addListener(_onMic);
    sc.status.addListener(_onStatus);
    app.addListener(_recompute);
    // VAD is a transient stream — latch the last value.
    _subs.add(sc.vad.listen((speaking) {
      if (vadActive != speaking) {
        vadActive = speaking;
        _recompute();
      }
    }));
    // No explicit "stt end" event: a partial marks STT in-flight, a final (or a
    // short silence) clears it.
    _subs.add(sc.partial.listen((_) => _markStt()));
    _subs.add(sc.finalText.listen((_) => _clearStt()));
    _recompute();
  }

  void _markStt() {
    _sttClear?.cancel();
    _sttClear = Timer(const Duration(milliseconds: 1100), _clearStt);
    if (!sttActive) {
      sttActive = true;
      _recompute();
    }
  }

  void _clearStt() {
    _sttClear?.cancel();
    _sttClear = null;
    if (sttActive) {
      sttActive = false;
      _recompute();
    }
  }

  void _onTts() {
    final v = VoiceLevels.instance.tts.value;
    final active = v > 0.001;
    if (active) level = v; // speaking pulse from the TTS level
    if (ttsActive != active) {
      ttsActive = active;
      _recompute();
    }
  }

  void _onMic() {
    // Sample only while listening; do NOT notify (the orb reads `level`/frame).
    if (stage == 'listening') level = MicMeter.instance.level.value;
  }

  void _onStatus() {
    // The sidecar's transient signals (VAD/partial/TTS-level) have no trailing
    // "reset" event on a disconnect/crash, so a latch could stick forever (orb
    // frozen mid-speech or a lit satellite). On leaving `connected`, force every
    // derived flag back to a resting state.
    if (SidecarClient.instance.status.value != SidecarStatus.connected) {
      vadActive = false;
      if (VoiceLevels.instance.tts.value != 0.0) {
        VoiceLevels.instance.tts.value = 0.0; // fires _onTts → ttsActive=false
      }
      _clearStt(); // recomputes
      _recompute();
    }
  }

  void _recompute() {
    final va = VoiceAssistant.instance.state.value;
    final speaking = VoiceLevels.instance.tts.value > 0.001;
    final String s;
    if (speaking) {
      s = 'speaking';
    } else {
      switch (va) {
        case VaState.listening:
        case VaState.armed:
          s = 'listening';
        case VaState.thinking:
        case VaState.running:
          s = 'thinking';
        case VaState.idle:
          s = 'idle';
      }
    }
    stage = s;
    llmActive = (_app?.isGenerating ?? false) || (_app?.isModelLoading ?? false);
    if (s == 'idle') {
      // Idle self-heals cosmetic latches (a VAD event with no trailing false).
      level = 0.0;
      vadActive = false;
    }
    final sig = '$stage|$vadActive|$sttActive|$llmActive|$ttsActive';
    if (sig != _sig) {
      _sig = sig;
      notifyListeners();
    }
  }
}

// Response-cycle hub (dorabotki §3 / evs-redesign-1-nexus-sync11): a conic core
// that breathes/pulses by stage, a slow dashed orbit, speaking ripples, and four
// pipeline satellites (VAD/STT/LLM/TTS) lit by REAL flags from NexusPipeline.
// The ticker is gated by AmbientMotion/MotionPolicy (idle balanced = static).
// Tap = toggle listening (promptOnce), matching the mic button.
class NexusHubOrb extends StatefulWidget {
  const NexusHubOrb({super.key});
  @override
  State<NexusHubOrb> createState() => _NexusHubOrbState();
}

class _NexusHubOrbState extends State<NexusHubOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AmbientMotion _ambient;
  late final Listenable _anim; // merged once, not per build
  double _t = 0;
  double _energy = 0.16;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    NexusPipeline.instance.bind(context.read<AppState>());
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 4));
    _ambient = AmbientMotion(_ctrl);
    _anim = Listenable.merge([_ctrl, NexusPipeline.instance]);
  }

  @override
  void dispose() {
    _ambient.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe to the theme only (so the skin re-resolves on a theme switch);
    // do NOT context.watch the whole AppState — that would rebuild the orb at
    // token-rate during generation and defeat the MotionPolicy idle gate. The
    // LLM flag comes from the (coalesced) pipeline instead.
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    final skin = _skin(context);
    final pipe = NexusPipeline.instance;
    return GestureDetector(
      onTap: () => VoiceAssistant.instance.promptOnce(),
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          // Advance from real elapsed time, not build count, so speed is
          // identical on 60/120/144 Hz. Pipe-only rebuilds (or a stopped/
          // restarted controller) give a non-positive/huge delta → no advance.
          final e = _ctrl.lastElapsedDuration ?? Duration.zero;
          var dt = (e - _lastElapsed).inMicroseconds / 1e6;
          _lastElapsed = e;
          if (dt < 0 || dt > 0.1) dt = 0;
          _t += dt;
          final target = switch (pipe.stage) {
            'listening' => (0.7 + pipe.level * 0.3).clamp(0.0, 1.0),
            'thinking' => 0.5,
            'speaking' => (0.85 + pipe.level * 0.15).clamp(0.0, 1.0),
            _ => 0.16,
          };
          _energy += (target - _energy) * (1 - math.pow(0.92, dt * 60).toDouble());
          return CustomPaint(
            size: Size.infinite,
            painter: _NexusHubPainter(
              t: _t,
              energy: _energy,
              stage: pipe.stage,
              vad: pipe.vadActive,
              stt: pipe.sttActive,
              llm: pipe.llmActive,
              tts: pipe.ttsActive,
              skin: skin,
            ),
          );
        },
      ),
    );
  }
}

class _NexusHubPainter extends CustomPainter {
  final double t, energy;
  final String stage;
  final bool vad, stt, llm, tts;
  final EvsSkin skin;
  _NexusHubPainter({
    required this.t,
    required this.energy,
    required this.stage,
    required this.vad,
    required this.stt,
    required this.llm,
    required this.tts,
    required this.skin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = skin.pal;
    final cx = size.width / 2, cy = size.height / 2;
    final ctr = Offset(cx, cy);
    final r = math.min(size.width, size.height) / 2;
    final light = p.brightness == Brightness.light;
    final orbitR = r * 0.82;
    final coreR = r * 0.46;

    // ---- dashed orbit ring (slow rotation, ~70s/rev) ----
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = p.sub.withValues(alpha: light ? 0.22 : 0.18);
    const dashes = 64;
    final rot = t * 0.09;
    for (var i = 0; i < dashes; i += 2) {
      final a0 = rot + (i / dashes) * 2 * math.pi;
      final a1 = rot + ((i + 1) / dashes) * 2 * math.pi;
      canvas.drawArc(
          Rect.fromCircle(center: ctr, radius: orbitR), a0, a1 - a0, false, ringPaint);
    }

    // ---- core ----
    final pulse = _pulse();
    final rr = coreR * pulse;
    final glowColor = stage == 'listening' ? p.warn : p.accent;
    if (skin.glow) {
      canvas.drawCircle(
          ctr,
          rr * 1.2,
          Paint()
            ..color = glowColor.withValues(alpha: 0.32 * skin.glowIntensity)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, rr * 0.55));
    } else {
      // Light theme: a soft drop shadow instead of a glow.
      canvas.drawCircle(
          Offset(cx, cy + rr * 0.14),
          rr,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.07)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, rr * 0.4));
    }
    final coreRect = Rect.fromCircle(center: ctr, radius: rr);
    final sweep = SweepGradient(
      transform: const GradientRotation(200 * math.pi / 180),
      colors: [p.info, p.accent, skin.accent2, p.info],
      stops: const [0.0, 0.4, 0.7, 1.0],
    );
    canvas.drawCircle(ctr, rr, Paint()..shader = sweep.createShader(coreRect));
    if (stage == 'thinking') {
      // Saturation "breath": darken/lighten the core subtly.
      final k = 0.5 + 0.5 * math.sin(t * 3.9);
      canvas.drawCircle(
          ctr, rr, Paint()..color = p.bg.withValues(alpha: 0.14 * (1 - k)));
    }
    // Specular highlight (top-left).
    final hc = Offset(cx - rr * 0.28, cy - rr * 0.34);
    canvas.drawCircle(
        hc,
        rr * 0.52,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(center: hc, radius: rr * 0.52)));

    // ---- speaking ripples ----
    if (stage == 'speaking') {
      _ripple(canvas, ctr, coreR, p.info, (t * 0.6) % 1.0);
      _ripple(canvas, ctr, coreR, p.info, ((t * 0.6) + 0.5) % 1.0);
    }

    // ---- satellites on the orbit (VAD top, STT right, LLM bottom, TTS left) ----
    _sat(canvas, Offset(cx, cy - orbitR), 'VAD', vad, p.warn);
    _sat(canvas, Offset(cx + orbitR, cy), 'STT', stt, p.warn);
    _sat(canvas, Offset(cx, cy + orbitR), 'LLM', llm, skin.accent2);
    _sat(canvas, Offset(cx - orbitR, cy), 'TTS', tts, p.info);
  }

  double _pulse() {
    switch (stage) {
      case 'listening':
        return 1 + 0.09 * energy * (0.5 + 0.5 * math.sin(t * 5.4));
      case 'speaking':
        return 1 + 0.05 * (0.5 + 0.5 * math.sin(t * 3.5)) + energy * 0.04;
      case 'thinking':
        return 1 + 0.02 * math.sin(t * 3.9);
      default:
        return 1 + 0.045 * math.sin(t * 1.2); // idle breathe
    }
  }

  void _ripple(Canvas c, Offset ctr, double baseR, Color col, double f) {
    c.drawCircle(
        ctr,
        baseR * (1 + f * 0.7),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = col.withValues(alpha: (0.45 * (1 - f)).clamp(0.0, 1.0)));
  }

  void _sat(Canvas c, Offset pos, String label, bool active, Color color) {
    final p = skin.pal;
    if (active && skin.glow) {
      c.drawCircle(
          pos,
          8,
          Paint()
            ..color = color.withValues(alpha: 0.55 * skin.glowIntensity)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    }
    c.drawCircle(
        pos, 5.5, Paint()..color = active ? color : const Color(0xFF2A3452));
    c.drawCircle(
        pos,
        5.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = p.sub.withValues(alpha: 0.24));
    final tp = _labelPainter(label, active ? color : p.faint);
    tp.paint(c, Offset(pos.dx - tp.width / 2, pos.dy + 9));
  }

  // Satellite labels are constant strings — lay each (label, colour) out once
  // and reuse it across frames instead of re-shaping four TextPainters/frame.
  static final Map<String, TextPainter> _labelCache = {};
  static TextPainter _labelPainter(String label, Color color) =>
      _labelCache.putIfAbsent(
        '$label|${color.hashCode}',
        () => TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
      );

  @override
  bool shouldRepaint(_NexusHubPainter old) => true;
}

// Left navigation rail (66px). Logo (with warn dot) + nav icons + settings at
// the bottom. Nav icons route to existing destinations; "Диалог" is the active
// home view and opens the conversations switcher.
class _NexusRail extends StatelessWidget {
  const _NexusRail();

  // Open settings on a specific section (index into DesktopSettings._sections):
  // 0 General · 3 Voice commands · 5 Model & inference · 8 About. So each rail
  // icon lands on its own relevant screen instead of all opening General.
  void _openSettings(BuildContext context, [int section = 0]) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DesktopSettings(initialSection: section)));

  Widget _navIcon(BuildContext context, IconData icon, String tooltip,
      {bool active = false, VoidCallback? onTap}) {
    final color = active ? _info(context) : _sub(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 24,
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: active
                ? _info(context).withValues(alpha: 0.08)
                : Colors.transparent,
          ),
          child: Icon(icon, size: 19, color: color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Container(
      width: 66,
      decoration: _evsRailBg(context),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 14),
            const DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: _NexusLogoBead(),
              ),
            ),
            const SizedBox(height: 6),
            _navIcon(context, Icons.forum_outlined, app.t('nxNavDialog'),
                active: true,
                onTap: () => Scaffold.of(context).openDrawer()),
            _navIcon(context, Icons.bolt_outlined, app.t('nxNavCommands'),
                onTap: () => _openSettings(context, 3)),
            _navIcon(context, Icons.memory, app.t('nxNavModels'),
                onTap: () => _openSettings(context, 5)),
            _navIcon(context, Icons.receipt_long_outlined, app.t('nxNavLog'),
                onTap: () => _openSettings(context, 8)),
            const Spacer(),
            _navIcon(context, Icons.settings_outlined, app.t('settings'),
                onTap: () => _openSettings(context, 0)),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

// The rail logo: the conic brand bead with a small warn accent dot (TZ §6.1).
class _NexusLogoBead extends StatelessWidget {
  const _NexusLogoBead();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const _EvsLogoMark(),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _warn(context),
                border: Border.all(color: _pal(context).bg, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Central stage: status pill + activation hint, the canvas visualizer with a
// compact mode switch, the latest-exchange transcript, and the mono status line.
class _NexusStage extends StatefulWidget {
  const _NexusStage();
  @override
  State<_NexusStage> createState() => _NexusStageState();
}

class _NexusStageState extends State<_NexusStage> {
  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    NexusPipeline.instance.bind(app);
    // Keep the Flutter-side mic meter alive so the orb's listening pulse reacts
    // to the real input level (the classic shell does this via its mic widget).
    MicMeter.instance.start(deviceId: app.inputDeviceId);
  }

  (String, Color) _statusFor(BuildContext context, String stage, AppState app) {
    switch (stage) {
      case 'listening':
        return (app.t('vaListening'), _warn(context));
      case 'thinking':
        return (app.t('vaThinking'), _accent2(context));
      case 'speaking':
        return (app.t('nxSpeaking'), _info(context));
      default:
        return (app.t('nxIdle'), _faint(context));
    }
  }

  Widget _statusPill(BuildContext context, AppState app) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        NexusPipeline.instance,
        VoiceAssistant.instance.state,
        VoiceAssistant.instance.wakeActive,
      ]),
      builder: (context, _) {
        // Wake feedback first: a recognized activator flashes "«word» — heard
        // you!" and the command-capture window shows "say the command…" —
        // without this the pill sat on «Слушаю…» through the whole wake →
        // command exchange with no visible reaction.
        final va = VoiceAssistant.instance.state.value;
        final woke = VoiceAssistant.instance.wakeActive.value;
        final String label;
        final Color color;
        if (woke) {
          label = '«${app.wakeWord}» — ${app.t('vaWakeHeard')}';
          color = _success(context);
        } else if (va == VaState.armed) {
          label = app.t('vaArmed');
          color = _warn(context);
        } else {
          final s = _statusFor(context, NexusPipeline.instance.stage, app);
          label = s.$1;
          color = s.$2;
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.30)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
              const SizedBox(width: 8),
              Text('${app.t('nxStatus')}: $label',
                  style: EvsType.control.copyWith(color: _txt(context))),
            ],
          ),
        );
      },
    );
  }

  Widget _transcript(BuildContext context, AppState app) {
    final conv = app.current;
    final msgs = conv?.messages ?? const [];
    String? user, reply;
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (reply == null && m.role != 'user') reply = m.content;
      if (user == null && m.role == 'user') user = m.content;
      if (user != null && reply != null) break;
    }
    if ((user ?? '').isEmpty && (reply ?? '').isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if ((user ?? '').isNotEmpty)
          Text(user!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: EvsType.control.copyWith(color: _sub(context))),
        if ((reply ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(reply!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: EvsType.label.copyWith(color: _txt(context))),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
      child: Column(
        children: [
          Row(
            children: [
              _statusPill(context, app),
              const Spacer(),
              Flexible(
                child: Text(
                  '«${app.wakeWord}»   ·   Ctrl+Shift+Space',
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: EvsType.caption.copyWith(color: _faint(context)),
                ),
              ),
            ],
          ),
          // The response-cycle hub: a compact, centred orb (bounded square).
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (ctx, c) {
                  final sz =
                      math.min(math.min(c.maxWidth, c.maxHeight) * 0.92, 360.0);
                  return SizedBox(
                      width: sz, height: sz, child: const NexusHubOrb());
                },
              ),
            ),
          ),
          _transcript(context, app),
          const SizedBox(height: 14),
          const _NexusSubsystemCards(),
        ],
      ),
    );
  }
}

// Four live subsystem cards below the stage (dorabotki §4 / sync11): STT · TTS ·
// LLM · System (CPU/RAM/VRAM). Status dots + values are live; the active
// pipeline stage tints the card's key/dot with its slot; clicking a card opens
// its settings section. All data comes from the existing sidecar / metrics
// notifiers (mapped from the datasource survey).
class _NexusSubsystemCards extends StatelessWidget {
  const _NexusSubsystemCards();

  void _open(BuildContext c, int section) => Navigator.of(c).push(
      MaterialPageRoute(builder: (_) => DesktopSettings(initialSection: section)));

  String _gb(int bytes, {int digits = 1}) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(digits);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([
        NexusPipeline.instance,
        sc.status,
        sc.sttState,
        sc.engines,
        sc.ttsStatus,
        sc.deviceStatus,
        sc.gpuInfo,
        sc.gameModeStatus,
        SystemMonitor.instance.stats,
      ]),
      builder: (context, _) {
        final pipe = NexusPipeline.instance;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _sttCard(context, app, sc, pipe)),
              const SizedBox(width: 12),
              Expanded(child: _ttsCard(context, app, sc, pipe)),
              const SizedBox(width: 12),
              Expanded(child: _llmCard(context, app, pipe)),
              const SizedBox(width: 12),
              Expanded(child: _systemCard(context, app, sc)),
            ],
          ),
        );
      },
    );
  }

  Widget _shell(BuildContext c,
      {required String label,
      required Color dot,
      Color? keyColor,
      required Widget body,
      VoidCallback? onTap,
      String? tooltip}) {
    final card = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_overlayFill(c, 0.05), _overlayFill(c, 0.02)],
          ),
          border: Border.all(color: _stroke(c)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EvsType.caption.copyWith(
                          fontSize: 10.5,
                          letterSpacing: 1.3,
                          fontWeight: FontWeight.w700,
                          color: keyColor ?? _faint(c))),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                ),
              ],
            ),
            const SizedBox(height: 8),
            body,
          ],
        ),
      ),
    );
    return tooltip == null ? card : Tooltip(message: tooltip, child: card);
  }

  Widget _valSub(BuildContext c, String val, String sub, {Color? valColor}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(val,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: EvsType.body
                  .copyWith(fontSize: 13.5, color: valColor ?? _txt(c))),
          const SizedBox(height: 3),
          Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: EvsType.mono.copyWith(fontSize: 11, color: _sub(c))),
        ],
      );

  Widget _sttCard(
      BuildContext c, AppState app, SidecarClient sc, NexusPipeline pipe) {
    final gigaam = app.sttSidecarEngine == 'gigaam';
    final engine = gigaam ? 'GigaAM-v3' : 'Whisper · ${app.whisperModel}';
    final device = (sc.deviceStatus.value?.$2 ?? app.sttDevice).toUpperCase();
    final runtime = gigaam ? 'sherpa-onnx' : 'faster-whisper';
    final connected = sc.status.value == SidecarStatus.connected;
    final ready = sc.sttState.value == 'ready';
    final loaded = sc.engines.value[app.sttSidecarEngine] == true;
    final dot =
        !connected ? _danger(c) : (ready && loaded ? _success(c) : _warn(c));
    return _shell(c,
        label: 'STT',
        dot: dot,
        keyColor: pipe.sttActive ? _warn(c) : null,
        onTap: () => _open(c, 1),
        body: _valSub(c, engine, '$runtime · $device'));
  }

  Widget _ttsCard(
      BuildContext c, AppState app, SidecarClient sc, NexusPipeline pipe) {
    final String engine;
    final String sub;
    if (app.cloneEnabled) {
      engine = app.t('nxTtsClone');
      sub = 'XTTS';
    } else if (app.ttsEngineChoice == 'cosyvoice') {
      engine = 'CosyVoice';
      sub =
          (app.cosyvoiceOnline ?? false) ? app.t('nxOnline') : app.t('nxOffline');
    } else if (app.ttsPiperVoice.isEmpty) {
      engine = app.t('nxTtsSystem');
      sub = 'pyttsx3';
    } else {
      engine = 'Piper · ${_voiceName(app.ttsPiperVoice)}';
      sub = 'ru_RU · 22 кГц';
    }
    final connected = sc.status.value == SidecarStatus.connected;
    // Cosyvoice health only gates the dot when cosyvoice is the engine actually
    // in use — a clone (XTTS) override makes cosyvoice reachability irrelevant.
    final cosyOk = app.cloneEnabled ||
        app.ttsEngineChoice != 'cosyvoice' ||
        (app.cosyvoiceOnline ?? false);
    final dot = (!connected || !sc.ttsAvailable)
        ? _danger(c)
        : (cosyOk ? _success(c) : _warn(c));
    return _shell(c,
        label: 'TTS',
        dot: dot,
        keyColor: pipe.ttsActive ? _info(c) : null,
        onTap: () => _open(c, 1),
        body: _valSub(c, engine, sub));
  }

  String _voiceName(String id) {
    const m = {
      'irina': 'Ирина',
      'denis': 'Денис',
      'dmitri': 'Дмитрий',
      'ruslan': 'Руслан',
    };
    for (final e in m.entries) {
      if (id.contains(e.key)) return e.value;
    }
    final s = id
        .replaceAll('ru_RU-', '')
        .replaceAll('-medium', '')
        .replaceAll('-low', '');
    return s.isEmpty ? id : s;
  }

  Widget _llmCard(BuildContext c, AppState app, NexusPipeline pipe) {
    final local = app.isLocalModel(app.selectedModel);
    final model =
        app.selectedModel.isEmpty ? '—' : _shortModel(app.selectedModel);
    final String mode;
    if (local) {
      mode = 'on-device · fllama';
    } else if (app.inferenceMode == 'remote' && app.apiKey.isNotEmpty) {
      mode = 'OpenAI API';
    } else {
      mode = 'Ollama @ ${_host(app.baseUrl)}';
    }
    final dot = switch (app.connectionStatus) {
      ConnectionStatus.connected => _success(c),
      ConnectionStatus.connecting => _warn(c),
      ConnectionStatus.noModel => _warn(c),
      _ => _danger(c),
    };
    return _shell(c,
        label: 'LLM',
        dot: dot,
        keyColor: pipe.llmActive ? _accent2(c) : null,
        onTap: () => _open(c, 5),
        body: _valSub(c, model, mode));
  }

  String _shortModel(String m) {
    var s = m.replaceFirst('local:', '');
    if (s.contains('/')) s = s.split('/').last;
    return s;
  }

  String _host(String url) => url
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'/.*$'), '');

  Widget _systemCard(BuildContext c, AppState app, SidecarClient sc) {
    final (offload, reason) = sc.gameModeStatus.value;
    final gpu = sc.gpuInfo.value;
    final hasVram = gpu.$1 && gpu.$3 > 0;
    final vramFrac = hasVram ? (gpu.$4 / gpu.$3).clamp(0.0, 1.0) : 0.0;
    final s = SystemMonitor.instance.stats.value;
    final active = s.totalRamBytes > 0;
    final tip = offload
        ? (reason == 'vram'
            ? app.t('gmReasonVram')
            : app.t('gmReasonFullscreen'))
        : (hasVram ? gpu.$2 : '');
    return _shell(c,
        label: offload ? app.t('gmOffloadBadge') : app.t('nxSystem'),
        dot: offload ? _warn(c) : _success(c),
        keyColor: offload ? _warn(c) : null,
        tooltip: tip.isEmpty ? null : tip,
        onTap: () => _open(c, 5),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _mrow(c, 'CPU', active ? '${(s.cpu * 100).round()}%' : '—', s.cpu,
                _warn(c)),
            _mrow(
                c,
                'RAM',
                active
                    ? '${_gb(s.usedRamBytes)}/${_gb(s.totalRamBytes, digits: 0)}'
                    : '—',
                s.ram,
                _info(c)),
            if (hasVram)
              _mrow(
                  c,
                  'VRAM',
                  '${(gpu.$4 / 1024).toStringAsFixed(1)}/${(gpu.$3 / 1024).round()}',
                  vramFrac,
                  _accent2(c)),
          ],
        ));
  }

  Widget _mrow(
      BuildContext c, String label, String val, double frac, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: EvsType.caption.copyWith(
                    fontSize: 9.5, letterSpacing: 0.4, color: _faint(c))),
          ),
          const SizedBox(width: 6),
          // Expanded bar + Flexible value both flex, so at the app's minimum
          // window width the row shrinks instead of overflowing (the value
          // ellipsises rather than the four cards blowing past their bounds).
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: _overlayFill(c, 0.1),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(val,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: EvsType.mono.copyWith(fontSize: 10, color: _sub(c))),
          ),
        ],
      ),
    );
  }
}

// The Nexus home: rail → stage → chat column (360). The chat column is a
// bespoke compact panel (_NexusChatColumn) matching the concept mockup. A
// Scaffold hosts the conversations drawer opened from the rail's Dialog icon.
class _NexusHome extends StatelessWidget {
  const _NexusHome();

  @override
  Widget build(BuildContext context) {
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    return Scaffold(
      backgroundColor: _bg(context),
      drawerEdgeDragWidth: 24,
      drawer: const Drawer(
        width: 320,
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(),
        child: ConversationsSheet(embedded: true),
      ),
      body: Container(
        decoration: _evsShellBg(context),
        // Rail spans the full window height; the title bar sits over the whole
        // content area (stage + chat) so the window buttons stay top-right.
        child: const Row(
          children: [
            _NexusRail(),
            Expanded(
              child: Column(
                children: [
                  _WindowTitleBar(),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _NexusStage()),
                        SizedBox(width: 360, child: _NexusChatColumn()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Compact chat panel for the Nexus home (concept mockup): header (Диалог +
// time), a message list (user = accent→accent2 bubble, assistant = flat text +
// meta), and an input row (field + send + mic). Send goes through
// AppState.sendMessage; the mic re-uses the wake-word pipeline via promptOnce().
class _NexusChatColumn extends StatefulWidget {
  const _NexusChatColumn();
  @override
  State<_NexusChatColumn> createState() => _NexusChatColumnState();
}

class _NexusChatColumnState extends State<_NexusChatColumn> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  // Trim provider/path noise for the meta line: 'ollama/qwen3:4b' → 'qwen3:4b',
  // 'local:.../model.gguf' → 'model.gguf'.
  String _shortModel(String m) {
    if (m.isEmpty) return '—';
    var s = m.replaceFirst('local:', '');
    if (s.contains('/')) s = s.split('/').last;
    if (s.contains('\\')) s = s.split('\\').last;
    return s;
  }

  Future<void> _send() async {
    final app = context.read<AppState>();
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || app.isModelLoading) return;
    app.buzz();
    _controller.clear();
    setState(() => _sending = true);
    await app.sendMessage(text);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
    });
  }

  Widget _header(BuildContext context, AppState app) {
    final now = DateTime.now();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _stroke(context))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(app.t('nxNavDialog'),
              style: EvsType.label.copyWith(fontSize: 14, color: _txt(context))),
          Text('${app.t('nxToday')} · ${_two(now.hour)}:${_two(now.minute)}',
              style:
                  EvsType.caption.copyWith(fontSize: 11.5, color: _faint(context))),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, AppState app, ChatMessage m, bool isLast) {
    if (m.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 268),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                _accent(context).withValues(alpha: 0.22),
                _accent2(context).withValues(alpha: 0.22),
              ],
            ),
            border:
                Border.all(color: _accent2(context).withValues(alpha: 0.30)),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(m.content,
              style: EvsType.body.copyWith(fontSize: 13.5, color: _txt(context))),
        ),
      );
    }
    // Assistant: flat text + meta (time · model). Empty + generating → dots.
    final waiting = app.isGenerating && isLast && m.content.trim().isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(waiting ? '· · ·' : m.content,
              style: EvsType.body.copyWith(
                  fontSize: 13.5,
                  color: waiting ? _faint(context) : _txt(context))),
          if (!waiting)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${_two(m.time.hour)}:${_two(m.time.minute)} · ${_shortModel(app.selectedModel)}',
                style: EvsType.caption
                    .copyWith(fontSize: 10.5, color: _faint(context)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _iconBtn(BuildContext context, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: _overlayFill(context, 0.05),
          border: Border.all(color: _stroke(context)),
        ),
        child: Icon(icon, size: 18, color: _sub(context)),
      ),
    );
  }

  Widget _micBtn(BuildContext context) {
    return ValueListenableBuilder<VaState>(
      valueListenable: VoiceAssistant.instance.state,
      builder: (context, s, _) {
        final listening = s == VaState.listening || s == VaState.armed;
        return GestureDetector(
          onTap: () => VoiceAssistant.instance.promptOnce(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: listening ? _warn(context) : null,
              gradient: listening
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_accent(context), _accent2(context)],
                    ),
            ),
            child: Icon(Icons.mic_none_rounded,
                size: 18,
                color: listening ? const Color(0xFF1A1204) : Colors.white),
          ),
        );
      },
    );
  }

  Widget _inputRow(BuildContext context, AppState app) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: _overlayFill(context, 0.05),
                border: Border.all(color: _stroke(context)),
              ),
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style:
                    EvsType.body.copyWith(fontSize: 13, color: _txt(context)),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  border: InputBorder.none,
                  hintText: app.t('nxChatHint'),
                  hintStyle: TextStyle(color: _faint(context), fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          _iconBtn(context, Icons.send_rounded, _send),
          const SizedBox(width: 9),
          _micBtn(context),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, AppState app) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 30, color: _faint(context)),
          const SizedBox(height: 10),
          Text(app.t('askAnything'),
              style: EvsType.body.copyWith(color: _faint(context))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final msgs = app.current?.messages ?? const <ChatMessage>[];
    // Follow a streaming reply to the bottom; leave scrolling free when idle.
    if (app.isGenerating) _scrollDown();
    return Container(
      decoration: BoxDecoration(
        color: _overlayFill(context, 0.02),
        border: Border(left: BorderSide(color: _stroke(context))),
      ),
      child: Column(
        children: [
          _header(context, app),
          Expanded(
            child: msgs.isEmpty
                ? _empty(context, app)
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    itemCount: msgs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (_, i) =>
                        _bubble(context, app, msgs[i], i == msgs.length - 1),
                  ),
          ),
          _inputRow(context, app),
        ],
      ),
    );
  }
}
