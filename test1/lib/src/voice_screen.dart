part of '../main.dart';

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen>
    with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _muted = false;
  bool _available = false;
  bool _initFailed = false;
  bool _listening = false;
  bool _manualStop = false;
  String _recognized = '';
  // Text already confirmed by a previous listen session (before an
  // automatic or manual restart); the live session's words are appended
  // to this so a restart never silently drops what was already said.
  String _committedText = '';
  Timer? _autoSendTimer;
  // Drives auto-send ourselves instead of relying on the engine's own
  // `pauseFor` (which now stays open for the whole session — see _listen):
  // reset on every recognized word, fires once speech has actually paused.
  Timer? _autoSendIdleTimer;
  Timer? _listenWatchdog;
  int _listenRetries = 0;
  static const _maxListenRetries = 5;
  late final AnimationController _borderCtrl;
  // Smoothed 0..1 microphone level driving the sphere's reaction. A
  // ValueNotifier instead of setState so updates (which can fire several
  // times a second) only repaint the sphere, not the whole screen.
  final ValueNotifier<double> _soundLevel = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _borderCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _init();
  }

  void _onSpeechError(dynamic e) {
    _soundLevel.value = 0.0;
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _init({int attempt = 0}) async {
    if (!mounted) return;
    if (attempt == 0) setState(() => _initFailed = false);
    _available = await _speech.initialize(
      onStatus: _onStatus,
      onError: _onSpeechError,
    );
    // SpeechToText() is a process-wide singleton: initialize() short-circuits
    // and returns the cached result without touching its listeners once it
    // has already succeeded once in this app run, so every VoiceScreen
    // opened after the first would otherwise never get status/error
    // callbacks at all. Rebind explicitly so this screen's callbacks are
    // always the ones actually wired up, regardless of which one initialized
    // the engine.
    _speech.statusListener = _onStatus;
    _speech.errorListener = _onSpeechError;
    if (!mounted) return;
    if (_available) {
      if (!_muted) _listen();
      setState(() {});
    } else if (attempt < 2) {
      // initialize() can fail transiently right when the screen opens (mic
      // permission grant still propagating, recognition service not yet
      // bound) — retry a couple of times before surfacing an error instead
      // of giving up on the very first try.
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) _init(attempt: attempt + 1);
    } else {
      setState(() => _initFailed = true);
    }
  }

  void _retryInit() {
    if (!mounted) return;
    _listenRetries = 0;
    _init();
  }

  void _onStatus(String status) {
    if (!mounted) return;
    final wasListening = _listening;
    setState(() => _listening = status == 'listening');
    if (_listening) {
      _listenWatchdog?.cancel();
      _listenRetries = 0;
    } else {
      _soundLevel.value = 0.0;
    }
    final stoppedNaturally = wasListening && !_listening && !_manualStop;
    _manualStop = false;
    if (!stoppedNaturally || _muted) return;
    // `pauseFor` is set far longer than any real pause now (see _listen),
    // so the engine stopping on its own here is an exceptional case (a
    // platform-side hard session cap, a dropped connection, etc.) rather
    // than the normal end of a sentence — just pick the mic back up.
    _committedText = _recognized;
    _listen();
  }

  // speech_to_text reports raw, platform-dependent decibel-ish values (the
  // exact range differs between Android and iOS) rather than a normalized
  // level. Clamp to a generous range, map to 0..1, then smooth so the
  // sphere reacts to the trend of the volume rather than every noisy tick.
  void _onSoundLevel(double level) {
    final normalized = ((level + 2) / 12).clamp(0.0, 1.0);
    _soundLevel.value += (normalized - _soundLevel.value) * 0.35;
  }

  // _autoSendIdleTimer already waited out the configured pause; this extra
  // beat just lets the user see the final transcript before we navigate away.
  void _scheduleAutoSend() {
    _autoSendTimer?.cancel();
    _autoSendTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.pop(context, (_recognized, true));
    });
  }

  // The mic now stays open for the whole screen (see _listen), so silence
  // no longer stops the engine on its own — auto-send has to notice the
  // pause itself instead of reacting to a status change.
  void _resetAutoSendIdleTimer() {
    _autoSendIdleTimer?.cancel();
    if (!context.read<AppState>().micAutoSend) return;
    final pauseSeconds = context.read<AppState>().micPauseSeconds;
    _autoSendIdleTimer = Timer(Duration(seconds: pauseSeconds), () {
      if (!mounted || _muted || _recognized.trim().isEmpty) return;
      _scheduleAutoSend();
    });
  }

  void _listen() {
    if (!mounted) return;
    final app = context.read<AppState>();
    _autoSendTimer?.cancel();
    _speech
        .listen(
          onResult: (r) {
            if (!mounted) return;
            // Each listen() call starts a fresh session whose
            // recognizedWords resets to empty, so prepend whatever was
            // already committed by earlier sessions instead of dropping it.
            setState(() {
              _recognized = _committedText.isEmpty
                  ? r.recognizedWords
                  : (r.recognizedWords.isEmpty
                        ? _committedText
                        : '$_committedText ${r.recognizedWords}');
            });
            _resetAutoSendIdleTimer();
          },
          onSoundLevelChange: _onSoundLevel,
          listenOptions: stt.SpeechListenOptions(
            listenMode: stt.ListenMode.dictation,
            // Deliberately far longer than any real pause: the mic should
            // stay active for the whole screen and only stop on mute or on
            // leaving the screen, never on its own mid-sentence. Auto-send
            // detects the pause itself via _resetAutoSendIdleTimer instead.
            pauseFor: const Duration(minutes: 30),
            localeId: app.effectiveSttLanguage == 'ru' ? 'ru_RU' : 'en_US',
          ),
        )
        // On web, calling start() while the browser hasn't fully torn down a
        // previous recognition session yet throws; let the watchdog below
        // retry instead of leaving an unhandled rejection.
        .catchError((_) {});
    // The engine sometimes ignores the very first listen() call right after
    // initialize() and never reports a 'listening' status — on this device
    // it depends on a network-based recognition service, so it can take a
    // couple seconds to connect rather than failing outright. Restarting it
    // (the same recovery a manual mute/unmute toggle does) reliably kicks it
    // into gear, so do that automatically instead of making the user notice.
    // The retry itself waits a beat before re-listening, mirroring the
    // natural delay a human introduces when tapping mute then unmute.
    _listenWatchdog?.cancel();
    _listenWatchdog = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted || _muted || _listening) return;
      if (_listenRetries >= _maxListenRetries) {
        // Stop retrying silently — tell the user instead of leaving them
        // staring at "Connecting microphone…" forever with no way to know
        // it's actually given up.
        setState(() => _initFailed = true);
        return;
      }
      _listenRetries++;
      _speech.stop().then((_) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted && !_muted && !_listening) _listen();
        });
      });
    });
  }

  void _toggleMute() {
    _autoSendTimer?.cancel();
    _autoSendIdleTimer?.cancel();
    _listenWatchdog?.cancel();
    setState(() => _muted = !_muted);
    if (_muted) {
      _manualStop = true;
      _committedText = _recognized;
      _speech.stop();
    } else {
      _listenRetries = 0;
      _initFailed = false;
      _listen();
    }
  }

  void _openMicSettings(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
          backgroundColor: const Color(0xFF1A1640),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, color: Color(0xFF7C83FD)),
                    const SizedBox(width: 10),
                    Text(
                      app.t('micSettingsTitle'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.micAutoSend,
                  activeThumbColor: const Color(0xFF7C83FD),
                  title: Text(
                    app.t('micAutoSend'),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    app.t('micAutoSendDesc'),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onChanged: (v) {
                    app.setMicAutoSend(v);
                    setDialogState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  app.t('micPauseDuration'),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [1, 2, 3, 5].map((s) {
                    final selected = app.micPauseSeconds == s;
                    return ChoiceChip(
                      label: Text('${s}s'),
                      selected: selected,
                      selectedColor: const Color(0xFF7C83FD),
                      backgroundColor: Colors.white10,
                      labelStyle: TextStyle(
                        color: selected ? Colors.black : Colors.white70,
                        fontWeight: FontWeight.w500,
                      ),
                      onSelected: (_) {
                        app.setMicPauseSeconds(s);
                        setDialogState(() {});
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(
                      app.t('done'),
                      style: const TextStyle(color: Color(0xFF7C83FD)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _autoSendTimer?.cancel();
    _autoSendIdleTimer?.cancel();
    _listenWatchdog?.cancel();
    _borderCtrl.dispose();
    _soundLevel.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                radius: 1.1,
                colors: [Color(0xFF1B1640), Color(0xFF0A0818)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _toggleMute,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _muted ? Icons.mic_off : Icons.mic,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _muted ? app.t('unmute') : app.t('mute'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () => _openMicSettings(context),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: const Icon(Icons.tune, color: Colors.white),
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () =>
                              Navigator.pop(context, (_recognized, false)),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black38,
                            ),
                            child: const Icon(Icons.close, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  ParticleSphere(
                    size: 280,
                    color: const Color(0xFF7C83FD),
                    dense: true,
                    active: _listening,
                    soundLevel: _soundLevel,
                  ),
                  const SizedBox(height: 40),
                  GestureDetector(
                    onTap: _initFailed && _recognized.isEmpty
                        ? _retryInit
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _initFailed && _recognized.isEmpty
                                ? Icons.mic_off
                                : Icons.mic,
                            color: _initFailed && _recognized.isEmpty
                                ? Colors.redAccent
                                : const Color(0xFF7C83FD),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _recognized.isEmpty
                                  ? (_initFailed
                                        ? app.t('micUnavailable')
                                        : (_muted
                                              ? app.t('muted')
                                              : (_listening
                                                    ? app.t('listening')
                                                    : app.t('preparingMic'))))
                                  : _recognized,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_initFailed && _recognized.isEmpty) ...[
                            const SizedBox(width: 10),
                            Text(
                              app.t('retry'),
                              style: const TextStyle(
                                color: Color(0xFF7C83FD),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_initFailed && _recognized.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                      child: Text(
                        app.t('micUnavailableDesc'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    )
                  else if (app.micAutoSend)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                      child: Text(
                        app.t('speakNaturally'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                      child: GestureDetector(
                        onTap: _recognized.trim().isEmpty
                            ? null
                            : () => Navigator.pop(context, (_recognized, true)),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            color: _recognized.trim().isEmpty
                                ? Colors.black38
                                : const Color(0xFF7C83FD),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.arrow_upward,
                                color: _recognized.trim().isEmpty
                                    ? Colors.white38
                                    : Colors.black,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                app.t('send'),
                                style: TextStyle(
                                  color: _recognized.trim().isEmpty
                                      ? Colors.white38
                                      : Colors.black,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: BorderGlowPainter(animation: _borderCtrl, radius: 36),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.all(1.5),
                child: CustomPaint(
                  painter: GradientBorderPainter(
                    animation: _borderCtrl,
                    radius: 36,
                    strokeWidth: 3,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ============================ ЭКРАН БЕСЕД ============================ */

class ConversationsSheet extends StatefulWidget {
  // embedded == true → rendered full-height inside the chat screen's left
  // Drawer (opened by an edge swipe) instead of as a bottom sheet: drops the
  // drag handle / rounded-top / DraggableScrollableSheet sizing. The close
  // (X) button still works in both modes — closing a Drawer is done with
  // Navigator.pop too (it sits on the route's local-history stack).
  final bool embedded;
  const ConversationsSheet({super.key, this.embedded = false});
  @override
  State<ConversationsSheet> createState() => _ConversationsSheetState();
}

class _ConversationsSheetState extends State<ConversationsSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: _sheetSurface(
          context,
          rounded: false,
          child: SafeArea(child: _content(context, null)),
        ),
      );
    }
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: _sheetSurface(
          context,
          rounded: true,
          child: _content(context, scrollCtrl),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, ScrollController? scrollCtrl) {
    final app = context.watch<AppState>();
    final filtered =
        app.conversations
            .where(
              (c) =>
                  c.title.toLowerCase().contains(_query.toLowerCase()) ||
                  c.messages.any(
                    (m) =>
                        m.content.toLowerCase().contains(_query.toLowerCase()),
                  ),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Column(
          children: [
            if (!widget.embedded) ...[
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _sub(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const Spacer(),
                  Text(
                    app.t('conversations'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close, color: _txt(context)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    app.t('chats'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    app.t('chatsDesc'),
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _stat(
                        '${app.chatCount}',
                        app.t('chatsLabel'),
                        Icons.chat_bubble_outline,
                        const Color(0xFF2FE0A8),
                      ),
                      const SizedBox(width: 12),
                      _stat(
                        '${app.pinnedCount}',
                        app.t('pinnedLabel'),
                        Icons.push_pin,
                        const Color(0xFF5B8DEF),
                      ),
                      const SizedBox(width: 12),
                      _stat(
                        app.latest == null
                            ? app.t('noChatsYet')
                            : _ago(app, app.latest!.updatedAt),
                        app.t('latestLabel'),
                        Icons.schedule,
                        const Color(0xFF9B8CFF),
                        small: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _newChatBanner(app),
                  if (app.latest != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      app.t('continueSection'),
                      style: TextStyle(
                        color: _sub(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _continueCard(app.latest!, app),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    app.t('recent'),
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    _emptyRecent(app)
                  else
                    ...filtered.map((c) => _chatTile(c, app)),
                  const SizedBox(height: 16),
                  _searchField(app),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        );
  }

  Widget _stat(
    String value,
    String label,
    IconData icon,
    Color color, {
    bool small = false,
  }) {
    return Expanded(
      child: SizedBox(
        height: 150,
        child: _glassCard(
          context,
          radius: 20,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  color: _txt(context),
                  fontSize: small ? 16 : 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 12,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _newChatBanner(AppState app) {
    return GestureDetector(
      onTap: () {
        app.buzz();
        app.newChat();
        Navigator.pop(context);
      },
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFF4FACFE), _accent(context)],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.edit_outlined, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.t('newChat'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    app.t('startFresh'),
                    style: const TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _emptyRecent(AppState app) {
    return _glassCard(
      context,
      radius: 20,
      alpha: 0.4,
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _sub(context).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.chat_bubble_outline,
              color: _sub(context),
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            app.t('noChatsYet'),
            style: TextStyle(
              color: _txt(context),
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            app.t('noChatsDesc'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  app.buzz();
                  app.newChat();
                  Navigator.pop(context);
                },
                child: Container(
                  decoration: BoxDecoration(
                    gradient: _accentGradient(context),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  child: Text(
                    app.t('startNewChat'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueCard(Conversation c, AppState app) {
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          _openChatMenu(context, d.globalPosition, c, app),
      child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent(context).withValues(alpha: 0.28),
            _card2(context).withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_forward,
                  color: Colors.white,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                app.t('latestConversation'),
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _txt(context),
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${c.messages.length} ${app.t('messages')} · ${_ago(app, c.updatedAt)}',
                      style: TextStyle(color: _sub(context), fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Material(
                  color: Colors.white24,
                  child: InkWell(
                    onTap: () {
                      app.openChat(c);
                      Navigator.pop(context);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      child: Text(
                        app.t('resume'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ));
  }

  Widget _chatTile(Conversation c, AppState app) {
    final tile = ListTile(
      onTap: () {
        app.openChat(c);
        Navigator.pop(context);
      },
      leading: Icon(
        c.pinned ? Icons.push_pin : Icons.chat_bubble_outline,
        color: _txt(context),
      ),
      title: Text(
        c.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${c.messages.length} ${app.t('messages')} · ${_ago(app, c.updatedAt)}',
        style: TextStyle(color: _sub(context)),
      ),
      trailing: _chatTileMenuButton(c, app),
    );
    return GestureDetector(
      // Right-click anywhere on the row → context menu (rename / pin / delete).
      onSecondaryTapDown: (d) =>
          _openChatMenu(context, d.globalPosition, c, app),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: _isGlass(context)
            ? GlassSurface(
                borderRadius: BorderRadius.circular(16),
                child: Material(type: MaterialType.transparency, child: tile),
              )
            : Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Material(
                  color: _card(context).withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(16),
                  child: tile,
                ),
              ),
      ),
    );
  }

  // Chat context menu (rename / pin / delete-with-undo) — delegates to the
  // shared top-level helper (also used by the desktop sidebar).
  Future<void> _openChatMenu(
          BuildContext ctx, Offset pos, Conversation c, AppState app) =>
      showChatContextMenu(ctx, pos, c, app);

  // Overflow (⋮) button for a chat row — opens the shared menu at the button.
  Widget _chatTileMenuButton(Conversation c, AppState app) {
    return Builder(
      builder: (btnCtx) => IconButton(
        icon: Icon(Icons.more_vert, color: _sub(context)),
        onPressed: () {
          final box = btnCtx.findRenderObject() as RenderBox?;
          final pos =
              box != null ? box.localToGlobal(Offset.zero) : Offset.zero;
          _openChatMenu(context, pos, c, app);
        },
      ),
    );
  }

  Widget _searchField(AppState app) {
    final field = TextField(
      style: TextStyle(color: _txt(context)),
      onChanged: (v) => setState(() => _query = v),
      decoration: InputDecoration(
        hintText: app.t('searchChats'),
        hintStyle: TextStyle(color: _sub(context)),
        prefixIcon: Icon(Icons.search, color: _sub(context)),
        filled: !_isGlass(context),
        fillColor: _card(context).withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
      ),
    );
    if (_isGlass(context)) {
      return GlassSurface(borderRadius: BorderRadius.circular(28), child: field);
    }
    return field;
  }

  String _ago(AppState app, DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return app.t('justNow');
    if (d.inMinutes < 60) return '${d.inMinutes} ${app.t('minAgo')}';
    if (d.inHours < 24) return '${d.inHours} ${app.t('hAgo')}';
    return '${d.inDays} ${app.t('dAgo')}';
  }
}
