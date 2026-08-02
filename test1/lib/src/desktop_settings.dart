part of '../main.dart';

class _SttTestCard extends StatefulWidget {
  const _SttTestCard();
  @override
  State<_SttTestCard> createState() => _SttTestCardState();
}

class _SttTestCardState extends State<_SttTestCard> {
  bool _testing = false;
  bool _startedStt = false;
  String _partial = '';
  String _final = '';
  StreamSubscription<String>? _pSub;
  StreamSubscription<String>? _fSub;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    final app = context.read<AppState>();
    _pSub = SidecarClient.instance.partial.listen((t) {
      if (mounted) setState(() => _partial = t);
    });
    _fSub = SidecarClient.instance.finalText.listen((t) {
      if (mounted) {
        setState(() {
          _final = t;
          _partial = '';
        });
      }
    });
    // Only take over STT if the assistant isn't already listening.
    if (!VoiceAssistant.instance.isListening) {
      SidecarClient.instance
          .sttStart(app.effectiveSttLanguage, prompt: app.sttBiasPrompt);
      _startedStt = true;
    }
    setState(() => _testing = true);
  }

  void _stop() {
    _pSub?.cancel();
    _pSub = null;
    _fSub?.cancel();
    _fSub = null;
    if (_startedStt) {
      SidecarClient.instance.sttStop();
      _startedStt = false;
    }
    if (mounted) setState(() => _testing = false);
  }

  void _clear() => setState(() {
        _final = '';
        _partial = '';
      });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (_, sc, __) {
        final connected = sc == SidecarStatus.connected;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.spellcheck, size: 15, color: Color(0xFF8A90A0)),
                const SizedBox(width: 7),
                Text(app.t('sttTest'),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: _txt(context))),
              ]),
              const SizedBox(height: 8),
              Text(app.t('sttTestDesc'),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A8090))),
              const SizedBox(height: 12),
              if (!connected)
                Text(app.t('vaSttOffline'),
                    style: const TextStyle(color: Color(0xFFE0985D), fontSize: 13))
              else ...[
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 64),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: _overlayFill(context, 0.03),
                    border: Border.all(color: _stroke(context)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // SelectableText so the recognized phrases can be
                      // selected/copied (Ctrl+C or right-click → Copy).
                      if (_final.isNotEmpty)
                        SelectableText(_final,
                            style: TextStyle(
                                color: _txt(context),
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                      if (_partial.isNotEmpty) ...[
                        if (_final.isNotEmpty) const SizedBox(height: 6),
                        SelectableText(_partial,
                            style: const TextStyle(
                                color: Color(0xFF7A8090),
                                fontSize: 13.5,
                                fontStyle: FontStyle.italic)),
                      ],
                      if (_final.isEmpty && _partial.isEmpty)
                        Text(app.t('sttTestHint'),
                            style: TextStyle(
                                color: _faint(context), fontSize: 13)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  evsGhostButton(context, 
                    _testing ? app.t('sttTestStop') : app.t('sttTestStart'),
                    _testing ? Icons.stop : Icons.mic,
                    onTap: () => _testing ? _stop() : _start(),
                  ),
                  if (_final.isNotEmpty || _partial.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    evsGhostButton(context, 
                      app.t('sttTestClear'),
                      Icons.clear,
                      onTap: _clear,
                    ),
                  ],
                ]),
              ],
            ],
          ),
        );
      },
    );
  }
}

// Web-search settings block: on/off toggle + optional Tavily/Brave API keys.
// Works keyless (DuckDuckGo) by default; a key gives more reliable results.
class _WebSearchCard extends StatefulWidget {
  const _WebSearchCard();
  @override
  State<_WebSearchCard> createState() => _WebSearchCardState();
}

class _WebSearchCardState extends State<_WebSearchCard> {
  late final TextEditingController _tavily;
  late final TextEditingController _brave;
  late final TextEditingController _googleKey;
  late final TextEditingController _googleCx;
  late final TextEditingController _yandexKey;
  late final TextEditingController _yandexFolder;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _tavily = TextEditingController(text: app.tavilyKey);
    _brave = TextEditingController(text: app.braveKey);
    _googleKey = TextEditingController(text: app.googleKey);
    _googleCx = TextEditingController(text: app.googleCx);
    _yandexKey = TextEditingController(text: app.yandexKey);
    _yandexFolder = TextEditingController(text: app.yandexFolder);
  }

  @override
  void dispose() {
    _tavily.dispose();
    _brave.dispose();
    _googleKey.dispose();
    _googleCx.dispose();
    _yandexKey.dispose();
    _yandexFolder.dispose();
    super.dispose();
  }

  // Выбор поисковика. Шесть вариантов — для сегмента многовато, поэтому чипы
  // в перенос; у ненастроенного провайдера подпись гаснет, чтобы было видно,
  // что ключей ему не хватает.
  Widget _providerChips(AppState app) {
    const labels = {
      'auto': null, // берётся из i18n
      'tavily': 'Tavily',
      'brave': 'Brave',
      'google': 'Google',
      'yandex': 'Яндекс',
      'ddg': 'DuckDuckGo',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final id in WebSearchService.providers)
          Builder(builder: (context) {
            final active = app.searchProvider == id;
            final ready =
                id == 'auto' || WebSearchService.instance.configured(id, app);
            return GestureDetector(
              onTap: () => app.setSearchProvider(id),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: active
                      ? _accent(context).withValues(alpha: 0.12)
                      : Colors.transparent,
                  border: Border.all(
                      color: active ? _accent(context) : _stroke(context)),
                ),
                child: Text(
                  labels[id] ?? app.t('webSearchAuto'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? _accent(context)
                        : (ready ? _sub(context) : _faint(context)),
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _keyField(
      TextEditingController c, String hint, ValueChanged<String> onChanged,
      {bool obscure = true}) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: TextField(
        controller: c,
        onChanged: onChanged,
        obscureText: obscure,
        style: TextStyle(fontSize: 12.5, color: _body(context)),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 12.5, color: _faint(context)),
        ),
      ),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(s,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: _sectionLabel(context))),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.t('webSearchEnable'),
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _txt(context))),
                  const SizedBox(height: 3),
                  Text(app.t('webSearchDesc'),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF7A8090))),
                ],
              ),
            ),
            const SizedBox(width: 10),
            evsToggle(context, app.webSearchEnabled, app.setWebSearchEnabled),
          ]),
          if (app.webSearchEnabled) ...[
            const SizedBox(height: 14),
            _label(app.t('webSearchProvider')),
            _providerChips(app),
            const SizedBox(height: 6),
            Text(app.t('webSearchProviderDesc'),
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
            const SizedBox(height: 12),
            Text(app.t('webSearchKeysHint'),
                style:
                    TextStyle(fontSize: 11.5, color: _faint(context))),
            const SizedBox(height: 10),
            _label(app.t('webSearchTavily')),
            _keyField(_tavily, 'tvly-…', app.setTavilyKey),
            const SizedBox(height: 10),
            _label(app.t('webSearchBrave')),
            _keyField(_brave, 'BSA…', app.setBraveKey),
            const SizedBox(height: 12),
            Text(app.t('webSearchGoogleHint'),
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
            const SizedBox(height: 8),
            _label(app.t('webSearchGoogleKey')),
            _keyField(_googleKey, 'AIza…', app.setGoogleKey),
            const SizedBox(height: 10),
            _label(app.t('webSearchGoogleCx')),
            _keyField(_googleCx, 'a1b2c3d4e5f6…', app.setGoogleCx,
                obscure: false),
            const SizedBox(height: 12),
            Text(app.t('webSearchYandexHint'),
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
            const SizedBox(height: 8),
            _label(app.t('webSearchYandexKey')),
            _keyField(_yandexKey, 'AQVN…', app.setYandexKey),
            const SizedBox(height: 10),
            _label(app.t('webSearchYandexFolder')),
            _keyField(_yandexFolder, 'b1g…', app.setYandexFolder,
                obscure: false),
          ],
        ],
      ),
    );
  }
}

// A settings card occupying one or both grid columns.
class _CardSpec {
  final Widget child;
  final bool full;
  const _CardSpec(this.child, {this.full = false});
}

// Live preview for the «Виджеты» settings section: renders the currently
// selected style full-size, with a state switcher (idle/listening/speaking/
// thinking) and a synthetic-voice toggle. The simulation feeds
// VoiceLevels.tts, so history-driven styles (sphere/ring/spectrum) — and the
// sidebar mini-widget — move exactly like they would during real speech.
class _VizPreviewCard extends StatefulWidget {
  const _VizPreviewCard();
  @override
  State<_VizPreviewCard> createState() => _VizPreviewCardState();
}

class _VizPreviewCardState extends State<_VizPreviewCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final ValueNotifier<double> _lvl = ValueNotifier(0);
  String _preview = 'listening'; // idle | listening | speaking | thinking
  bool _simulate = true;

  @override
  void initState() {
    super.initState();
    _ticker =
        AnimationController(vsync: this, duration: const Duration(seconds: 4))
          ..repeat()
          ..addListener(_onTick);
  }

  void _onTick() {
    final t =
        (_ticker.lastElapsedDuration ?? Duration.zero).inMilliseconds / 1000.0;
    final reacts = _preview == 'listening' || _preview == 'speaking';
    if (_simulate) {
      final v = reacts ? _synthVoice(t) : 0.0;
      _lvl.value = v;
      VoiceLevels.instance.tts.value = v;
    } else {
      _lvl.value = VoiceLevels.instance.tts.value;
    }
  }

  // Synthetic "speech" envelope: syllables + micro modulation + slow drift.
  double _synthVoice(double t) {
    final syllable = 0.5 + 0.5 * math.sin(t * 6.2);
    final env = syllable * syllable;
    final micro = 0.5 + 0.5 * math.sin(t * 23.0);
    final drift = 0.5 + 0.5 * math.sin(t * 1.3);
    return (0.12 + 0.88 * env * (0.55 + 0.45 * micro) * (0.7 + 0.3 * drift))
        .clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _ticker
      ..removeListener(_onTick)
      ..dispose();
    if (_simulate) VoiceLevels.instance.tts.value = 0;
    _lvl.dispose();
    super.dispose();
  }

  SiriOrbState get _orbState => switch (_preview) {
        'speaking' => SiriOrbState.speaking,
        'thinking' => SiriOrbState.thinking,
        'idle' => SiriOrbState.idle,
        _ => SiriOrbState.listening,
      };

  LkVisualizerState get _barState => switch (_preview) {
        'speaking' => LkVisualizerState.speaking,
        'thinking' => LkVisualizerState.thinking,
        'idle' => LkVisualizerState.idle,
        _ => LkVisualizerState.listening,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final accent = Color(app.vizAccent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(children: [
        SizedBox(
          height: 230,
          child: Center(
            child: ValueListenableBuilder<double>(
              valueListenable: _lvl,
              builder: (_, lv, __) {
                switch (app.vizType) {
                  case 'waves':
                    return const EvsRingViz(size: 200);
                  case 'bars':
                    return const EvsBarsViz(width: 340, height: 140);
                  case 'orb':
                    return SiriOrb(
                      size: app.orbSize.clamp(120, 210),
                      level: lv,
                      state: _orbState,
                      colors: evsOrbColors(accent),
                      animationDuration: app.orbSpeed,
                    );
                  case 'lkbars':
                    return LkBarVisualizer(
                      level: lv,
                      state: _barState,
                      count: app.barCount,
                      color: accent,
                      barWidth: 12,
                      spacing: 8,
                      minHeight: 12,
                      maxHeight: 150,
                    );
                  case 'wave3d':
                    return const EvsWaveViz(
                        kind: 'wave3d', size: 220, reactive: true);
                  case 'waveflat':
                    return const EvsWaveViz(
                        kind: 'waveflat', size: 220, reactive: true);
                  case 'none':
                    return Text(app.t('vizNone'),
                        style: TextStyle(
                            fontSize: 13, color: _faint(context)));
                  default:
                    return ParticleSphere(
                      size: 190,
                      color: _accent(context),
                      soundLevel: _lvl,
                    );
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        evsSegmentedWide<String>(context, [
          ('idle', app.t('wsStateIdle')),
          ('listening', app.t('wsStateListening')),
          ('speaking', app.t('wsStateSpeaking')),
          ('thinking', app.t('wsStateThinking')),
        ], _preview, (v) => setState(() => _preview = v)),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.graphic_eq, size: 17, color: _sectionLabel(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(app.t('wsSimVoice'),
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _body(context))),
          ),
          evsToggle(context, _simulate, (v) {
            setState(() => _simulate = v);
            if (!v) VoiceLevels.instance.tts.value = 0;
          }),
        ]),
      ]),
    );
  }
}

// Selectable style thumbnail for the «Виджеты» section.
class _VizStyleTile extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final Widget preview;
  final VoidCallback onTap;
  const _VizStyleTile({
    required this.label,
    required this.selected,
    required this.accent,
    required this.preview,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 148,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? _accent(context).withValues(alpha: 0.1)
              : _overlayFill(context, 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : _stroke(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(children: [
          SizedBox(height: 56, child: Center(child: preview)),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? _body(context)
                      : _sectionLabel(context))),
        ]),
      ),
    );
  }
}

// TZ3.4 cold-start: a small pill on the home hero that reflects the backend
// readiness state machine (starting / loading_models / error). Hidden once the
// backend is `ready`, so the user can see when it's safe to speak instead of
// talking into the void during model load.
class _SttReadinessBanner extends StatelessWidget {
  const _SttReadinessBanner();
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.sttState, sc.status]),
      builder: (context, _) {
        final app = context.read<AppState>();
        final state = sc.sttState.value;
        if (state == 'ready') return const SizedBox.shrink();
        String label;
        Color tone;
        IconData? icon;
        switch (state) {
          case 'loading_models':
            label = app.t('sttLoadingModels');
            tone = _info(context);
            break;
          case 'error':
            final msg = sc.sttStateMessage;
            label = (msg != null && msg.isNotEmpty)
                ? '${app.t('sttErrorState')}: $msg'
                : app.t('sttErrorState');
            tone = _danger(context);
            icon = Icons.error_outline;
            break;
          default: // starting / not yet connected
            label = app.t('sttStarting');
            tone = _warn(context);
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: tone.withValues(alpha: 0.28)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Icon(icon, size: 16, color: tone)
                else
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: tone),
                  ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(label,
                      style: EvsType.body.copyWith(
                          fontSize: 13,
                          color: Color.lerp(tone, _txt(context), 0.35))),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// TZ1 "Модель распознавания": two engine cards (Whisper with size selector,
// GigaAM-v3) driven by SidecarClient's live status / capabilities / latency.
// Selecting an engine hot-swaps it; the block locks until ready|error and rolls
// the choice back with a snackbar on failure.
// TZ2 block 6: compact CPU/GPU selector shown under a GPU-capable engine. Hidden
// entirely when no GPU is detected or the engine has no CUDA path. Reused per
// engine. Also surfaces the game-mode offload and CUDA→CPU fallback states.
class _DeviceSelector extends StatelessWidget {
  final AppState app;
  final String engine; // engine this selector controls (e.g. 'whisper')
  final String hintKey;
  const _DeviceSelector(this.app, this.engine, this.hintKey);
  @override
  Widget build(BuildContext context) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge(
          [sc.gpuInfo, sc.engineGpu, sc.deviceStatus, sc.gameModeStatus]),
      builder: (context, _) {
        final gpu = sc.gpuInfo.value; // (available, name, ...)
        final supported = sc.engineGpu.value[engine] == true;
        if (!gpu.$1 || !supported) return const SizedBox.shrink();
        final name = gpu.$2;
        final ds = sc.deviceStatus.value;
        final offloaded = sc.gameModeStatus.value.$1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Text(app.t('deviceLabel'),
                style: TextStyle(color: _sub(context), fontSize: 11)),
            const SizedBox(height: 6),
            evsSegmentedWide<String>(context, 
              [
                ('cpu', app.t('deviceCpu')),
                ('cuda', name.isNotEmpty ? 'GPU · $name' : app.t('deviceGpu')),
              ],
              app.sttDevice,
              (v) => app.setSttDevice(v),
            ),
            const SizedBox(height: 4),
            Text(app.t(hintKey),
                style: TextStyle(color: _faint(context), fontSize: 11)),
            if (offloaded)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(app.t('gmOffloadActive'),
                    style: const TextStyle(
                        color: Color(0xFFF0A030), fontSize: 11)),
              )
            else if (ds != null && ds.$3)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(app.t('deviceFellBack'),
                    style: const TextStyle(
                        color: Color(0xFFF0605E), fontSize: 11)),
              ),
          ],
        );
      },
    );
  }
}

// TZ2 block 4: a "Подробнее" toggle that reveals a longer explanation (2–4
// sentences) under a short option description. Texts come from i18n, not inline.
class _DetailDisclosure extends StatelessWidget {
  final bool open;
  final String detail;
  final String moreLabel;
  final String lessLabel;
  final VoidCallback onToggle;
  const _DetailDisclosure({
    required this.open,
    required this.detail,
    required this.moreLabel,
    required this.lessLabel,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(open ? lessLabel : moreLabel,
                  style: TextStyle(
                      color: _accent(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: _accent(context)),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(detail,
                style: TextStyle(
                    color: _sub(context), fontSize: 12, height: 1.45)),
          ),
      ],
    );
  }
}

class _SttEngineCards extends StatefulWidget {
  final AppState app;
  const _SttEngineCards(this.app);
  @override
  State<_SttEngineCards> createState() => _SttEngineCardsState();
}

class _SttEngineCardsState extends State<_SttEngineCards> {
  String? _pending; // engine being switched to (locks the block)
  final Set<String> _expanded = {}; // engines with "Подробнее" open (TZ2 block 4)

  @override
  void initState() {
    super.initState();
    SidecarClient.instance.engineStatus.addListener(_onStatus);
  }

  @override
  void dispose() {
    SidecarClient.instance.engineStatus.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    final st = SidecarClient.instance.engineStatus.value;
    if (st == null) return;
    // Сервер распознавания отвалился на ходу: сайдкар уже перешёл на локальный
    // движок, чтобы фразы не пропадали. Показываем это, а не молчим — иначе
    // «распознаёт хуже, чем вчера» останется без объяснения. Приходит вне
    // переключения, поэтому проверяется до `_pending`.
    if (st.$2 == 'fallback') {
      if (widget.app.sttSidecarEngine == st.$1) {
        widget.app.setSttSidecarEngine('whisper');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${widget.app.t('engRemoteFellBack')}'
                '${(st.$3 ?? '').isEmpty ? '' : ': ${st.$3}'}')));
      }
      return;
    }
    if (_pending == null || st.$1 != _pending) return;
    if (st.$2 == 'ready') {
      if (mounted) setState(() => _pending = null);
    } else if (st.$2 == 'error') {
      final failed = _pending!;
      final msg = st.$3 ?? widget.app.t('engSwitchFailed');
      if (mounted) setState(() => _pending = null);
      // Visual rollback: revert to Whisper (the one engine that is always
      // there); if Whisper itself is what failed, fall back to GigaAM.
      if (widget.app.sttSidecarEngine == failed) {
        widget.app
            .setSttSidecarEngine(failed == 'whisper' ? 'gigaam' : 'whisper');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${widget.app.t('engSwitchFailed')}: $msg')));
      }
    }
  }

  void _select(String engine) {
    if (_pending != null) return; // block re-press while switching
    if (widget.app.sttSidecarEngine == engine) return;
    setState(() => _pending = engine);
    widget.app.setSttSidecarEngine(engine);
  }

  @override
  Widget build(BuildContext context) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.engines, sc.sttLatencyMs, sc.status]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          _tile('whisper', widget.app.t('engWhisperName'),
              widget.app.t('engWhisperShort')),
          const SizedBox(height: 10),
          _tile('gigaam', widget.app.t('engGigaamName'),
              widget.app.t('engGigaamShort')),
          const SizedBox(height: 10),
          _tile('remote', widget.app.t('engRemoteName'),
              widget.app.t('engRemoteShort')),
        ]),
      ),
    );
  }

  Widget _badge(String text, Color bg, {Color fg = Colors.white}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: TextStyle(
                color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  Widget _tile(String engine, String name, String desc) {
    final app = widget.app;
    final sc = SidecarClient.instance;
    final selected = app.sttSidecarEngine == engine;
    // У серверного движка «доступен» — это «адрес задан»; спрашивать сайдкар
    // бессмысленно, он сообщает свои возможности один раз при подключении, а
    // адрес пользователь вводит потом.
    final avail = engine == 'remote'
        ? app.sttRemoteUrl.trim().isNotEmpty
        : sc.engines.value[engine] == true;
    final loading = _pending == engine;

    String status;
    Color color;
    if (loading) {
      status = app.t('engLoading');
      color = const Color(0xFFB9A6FF);
    } else if (selected) {
      status = app.t('engActive');
      color = const Color(0xFF34D399);
    } else if (avail) {
      status = app.t('engReady');
      color = const Color(0xFF8A8A95);
    } else {
      status = app.t('engNotFound');
      color = const Color(0xFFF0A030);
    }
    final latency = sc.sttLatencyMs.value;

    return Opacity(
      opacity: (_pending != null && !loading) ? 0.5 : 1.0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(engine),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card2(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? _accent(context).withValues(alpha: 0.4)
                  : _stroke(context),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: selected
                        ? const Color(0xFFB9A6FF)
                        : _faint(context)),
                const SizedBox(width: 10),
                Text(name,
                    style: TextStyle(
                        color: _txt(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                if (loading)
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else ...[
                  if (selected && latency > 0) ...[
                    _badge('$latency ${app.t('msShort')}',
                        const Color(0xFF2A2A38)),
                    const SizedBox(width: 6),
                  ],
                  _badge(status, color.withValues(alpha: 0.18), fg: color),
                ],
              ]),
              const SizedBox(height: 6),
              Text(desc,
                  style: TextStyle(
                      color: _sub(context), fontSize: 12)),
              _DetailDisclosure(
                open: _expanded.contains(engine),
                detail: app.t(switch (engine) {
                  'gigaam' => 'engGigaamDetail',
                  'remote' => 'engRemoteDetail',
                  _ => 'engWhisperDetail',
                }),
                moreLabel: app.t('moreDetails'),
                lessLabel: app.t('lessDetails'),
                onToggle: () => setState(() {
                  if (!_expanded.remove(engine)) _expanded.add(engine);
                }),
              ),
              if (engine == 'gigaam' && !avail && !loading)
                FutureBuilder<String>(
                  future: sc.gigaamModelDir(),
                  builder: (_, snap) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${snap.data ?? ''}\nHF: $kGigaamHfRepo',
                      style: TextStyle(
                          color: _faint(context), fontSize: 10.5),
                    ),
                  ),
                ),
              // Поля сервера видны всегда, а не только у выбранного движка:
              // выбрать «на сервере» с пустым адресом — значит сразу получить
              // откат. Сначала настроить и проверить, потом выбирать.
              if (engine == 'remote') _RemoteSttFields(app),
              if (engine == 'whisper' && selected) ...[
                const SizedBox(height: 12),
                Text(app.t('engWhisperSize'),
                    style: TextStyle(
                        color: _sub(context), fontSize: 11)),
                const SizedBox(height: 6),
                evsSegmentedWide<String>(context, 
                  const [('tiny', 'tiny'), ('base', 'base'), ('small', 'small')],
                  ['tiny', 'base', 'small'].contains(app.whisperModel)
                      ? app.whisperModel
                      : 'small',
                  (v) => app.setWhisperModel(v),
                ),
                _DeviceSelector(app, 'whisper', 'deviceHintWhisper'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Адрес, модель и ключ сервера распознавания плюс кнопка «Проверить». Пробу
// делает сайдкар, а не приложение: у него уже есть адрес и та же сетевая
// обстановка, в которой пойдут настоящие запросы, — иначе «здесь работает, там
// нет» не с чем сопоставить. Ответ приходит обычным stt.engine_status.
class _RemoteSttFields extends StatefulWidget {
  const _RemoteSttFields(this.app);
  final AppState app;
  @override
  State<_RemoteSttFields> createState() => _RemoteSttFieldsState();
}

class _RemoteSttFieldsState extends State<_RemoteSttFields> {
  late final TextEditingController _url =
      TextEditingController(text: widget.app.sttRemoteUrl);
  late final TextEditingController _model =
      TextEditingController(text: widget.app.sttRemoteModel);
  late final TextEditingController _key =
      TextEditingController(text: widget.app.sttRemoteKey);
  bool _checking = false;
  String _verdict = '';
  bool _ok = false;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final app = widget.app;
    if (app.sttRemoteUrl.trim().isEmpty) {
      setState(() {
        _ok = false;
        _verdict = app.t('engRemoteNoUrl');
      });
      return;
    }
    setState(() {
      _checking = true;
      _verdict = '';
    });
    final sc = SidecarClient.instance;
    final done = Completer<(String, String?)>();
    void listener() {
      final st = sc.engineStatus.value;
      if (st == null || st.$1 != 'remote') return;
      if (!done.isCompleted) done.complete((st.$2, st.$3));
    }

    sc.engineStatus.addListener(listener);
    try {
      await app.checkSttRemote();
      final r = await done.future.timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _ok = r.$1 == 'ready';
        _verdict = _ok
            ? app.t('engRemoteOnline')
            : '${app.t('engRemoteOffline')}: ${r.$2 ?? ''}';
      });
    } catch (_) {
      if (!mounted) return;
      // Сайдкар не ответил вовсе — это не «сервер офлайн», а «спросить некого».
      setState(() {
        _ok = false;
        _verdict = app.t('engRemoteNoSidecar');
      });
    } finally {
      sc.engineStatus.removeListener(listener);
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 5),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: _sectionLabel(context))),
      );

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(app.t('engRemoteUrl')),
        _RemoteField(controller: _url, onChanged: app.setSttRemoteUrl),
        _label(app.t('engRemoteModel')),
        _RemoteField(controller: _model, onChanged: app.setSttRemoteModel),
        _label(app.t('engRemoteKey')),
        _RemoteField(controller: _key, onChanged: app.setSttRemoteKey),
        const SizedBox(height: 10),
        Row(children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _checking ? null : () => unawaited(_check()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _stroke(context)),
                color: _stroke(context),
              ),
              child: Text(app.t('engRemoteCheck'),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
            ),
          ),
          const SizedBox(width: 10),
          if (_checking)
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
          else if (_verdict.isNotEmpty)
            Expanded(
              child: Text(_verdict,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: _ok ? _success(context) : _danger(context))),
            ),
        ]),
      ],
    );
  }
}

// TZ2 block 3: model manager — download / delete asset models (STT / denoise /
// TTS voices) into <userdata>/models/<id>/, reusing downloadFileWithProgress.
// TZ2 block 5: "Голос ассистента" — the always-available system voice plus
// downloadable Piper voice cards, each with download/delete, a "listen sample"
// button and active-voice selection. Preview/select go through the main sidecar.
class _AssistantVoiceCard extends StatefulWidget {
  final AppState app;
  const _AssistantVoiceCard(this.app);
  @override
  State<_AssistantVoiceCard> createState() => _AssistantVoiceCardState();
}

class _AssistantVoiceCardState extends State<_AssistantVoiceCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.app.refreshAssetModels());
  }

  List<AssetModelSpec> get _voices =>
      kAssetModels.where((s) => s.family == 'tts-voice').toList();

  Future<void> _confirmDelete(AssetModelSpec spec) async {
    final app = widget.app;
    if (app.assetActive(spec)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(app.t('mdlActiveCantDelete'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(spec.name, style: TextStyle(color: _txt(context))),
        content: Text(app.t('mdlDeleteConfirm'),
            style: TextStyle(color: _sub(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(app.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.t('mdlDelete'))),
        ],
      ),
    );
    if (ok == true) await app.deleteAssetModel(spec);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: Listenable.merge([app, SidecarClient.instance.ttsStatus]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _systemTile(),
            const SizedBox(height: 10),
            for (final spec in _voices) ...[
              _voiceTile(spec),
              const SizedBox(height: 10),
            ],
            for (final v in widget.app.customVoices) ...[
              _customVoiceTile(v),
              const SizedBox(height: 10),
            ],
            _importVoiceTile(),
          ],
        ),
      ),
    );
  }

  // A voice the user imported themselves. Selectable exactly like a catalogue
  // voice (same models dir, same sidecar path); only removal differs — there is
  // nothing to re-download, so deleting it is final.
  Widget _customVoiceTile(CustomVoice v) {
    final app = widget.app;
    final active = app.ttsPiperVoice == v.voiceId;
    return _shell(
      active: active,
      onSelect: () => app.setTtsPiperVoice(v.voiceId),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(v.name, active ? app.t('mdlActive') : null),
          const SizedBox(height: 4),
          Text(app.t('voiceCustomHint'),
              style: TextStyle(color: _sub(context), fontSize: 12.5)),
          const SizedBox(height: 10),
          Row(children: [
            evsGhostButton(context, app.t('mdlDelete'), Icons.delete_outline,
                onTap: () async {
              await app.removeCustomVoice(v);
              if (mounted) setState(() {});
            }),
          ]),
        ],
      ),
    );
  }

  // Import a Piper voice from disk: a packaged .tar.bz2 bundle, or a raw
  // <name>.onnx (tokens.txt is generated from its .onnx.json and the shared
  // espeak-ng-data is copied from an installed voice).
  Widget _importVoiceTile() {
    final app = widget.app;
    return _shell(
      active: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(app.t('voiceImportTitle'), null),
          const SizedBox(height: 4),
          Text(app.t('voiceImportHint'),
              style: TextStyle(color: _sub(context), fontSize: 12.5)),
          const SizedBox(height: 10),
          evsGhostButton(context, app.t('voiceImportBtn'), Icons.file_open,
              onTap: () async {
            final res = await FilePicker.pickFiles();
            final path = res?.files.single.path;
            if (path == null || path.isEmpty) return;
            final err = await app.importCustomVoice(path);
            if (!mounted) return;
            setState(() {});
            showAppSnackBar(
                context, err ?? app.t('voiceImportOk'));
          }),
        ],
      ),
    );
  }

  Widget _shell(
      {required bool active, VoidCallback? onSelect, required Widget child}) {
    final tile = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card2(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: active ? const Color(0x5534D399) : _stroke(context),
            width: active ? 1.5 : 1),
      ),
      child: child,
    );
    if (onSelect == null) return tile;
    return InkWell(
        borderRadius: BorderRadius.circular(14), onTap: onSelect, child: tile);
  }

  Widget _titleRow(String name, String? status) {
    return Row(children: [
      Expanded(
          child: Text(name,
              style: TextStyle(
                  color: _txt(context),
                  fontSize: 15,
                  fontWeight: FontWeight.w700))),
      if (status != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: const Color(0x2234D399),
              borderRadius: BorderRadius.circular(8)),
          child: Text(status,
              style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Widget _systemTile() {
    final app = widget.app;
    final active = app.ttsPiperVoice.isEmpty;
    return _shell(
      active: active,
      onSelect: active ? null : () => app.setTtsPiperVoice(''),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(
              app.t('voiceSystemName'), active ? app.t('engActive') : null),
          const SizedBox(height: 6),
          Text(app.t('voiceSystemDesc'),
              style: TextStyle(color: _sub(context), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _voiceTile(AssetModelSpec spec) {
    final app = widget.app;
    final installed = app.assetInstalled(spec.id);
    final progress = app.assetProgress[spec.id];
    final downloading = progress != null;
    final active = app.assetActive(spec);
    final sizeMb = (spec.totalSize / 1e6).round();
    final status = active
        ? app.t('engActive')
        : installed
            ? app.t('mdlInstalled')
            : downloading
                ? '${(progress.clamp(0.0, 1.0) * 100).round()}%'
                : null;
    return _shell(
      active: active,
      onSelect: (installed && !active)
          ? () => app.setTtsPiperVoice(spec.voiceId!)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(spec.name, status),
          const SizedBox(height: 6),
          Text(app.t(spec.descKey),
              style: TextStyle(color: _sub(context), fontSize: 12)),
          const SizedBox(height: 4),
          Text('~$sizeMb ${app.t('mbShort')}',
              style: TextStyle(color: _faint(context), fontSize: 11)),
          const SizedBox(height: 10),
          if (downloading)
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: const Color(0xFF2A2A38)),
                ),
              ),
              IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: _sub(context)),
                  tooltip: app.t('cancelDownload'),
                  onPressed: () => app.cancelAssetDownload(spec.id)),
            ])
          else if (installed)
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(app.t('voiceListen')),
                  onPressed: () => app.previewPiperVoice(spec)),
              if (!active)
                FilledButton.icon(
                    icon: const Icon(Icons.check, size: 16),
                    label: Text(app.t('voiceSelect')),
                    onPressed: () => app.setTtsPiperVoice(spec.voiceId!)),
              OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: Text(app.t('mdlDelete')),
                  onPressed: () => _confirmDelete(spec)),
            ])
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(app.t('mdlDownload')),
                  onPressed: () => app.downloadAssetModel(spec)),
            ),
        ],
      ),
    );
  }
}

// Журнал работы приложения (страница _Pages.appLog). Читает те же файлы и тем
// же кодом, что вкладка «Журнал» в «Ноктюрне» — EvsLogFeed; отличается только
// подача: здесь она карточная, как остальные настройки.
class _AppLogCard extends StatefulWidget {
  const _AppLogCard();
  @override
  State<_AppLogCard> createState() => _AppLogCardState();
}

class _AppLogCardState extends State<_AppLogCard> {
  final TextEditingController _search = TextEditingController();
  String _filter = 'all';
  List<EvsLogLine> _lines = const [];
  bool _loading = true;

  static const List<(String, String)> _filters = [
    ('all', 'ncAll'),
    ('voice', 'ncLogVoice'),
    ('model', 'ncLogModel'),
    ('commands', 'ncTabCommands'),
    ('remote', 'ncLogRemote'),
    ('updates', 'ncLogUpdates'),
    ('errors', 'ncLogErrors'),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final out = await EvsLogFeed.load();
    if (!mounted) return;
    setState(() {
      _lines = out;
      _loading = false;
    });
  }

  Color _levelColor(String level) => switch (level) {
        'danger' => _danger(context),
        'warn' => _warn(context),
        'accent' => _accent(context),
        _ => _success(context),
      };

  Widget _chip(AppState app, String id, String labelKey, int? count) {
    final active = _filter == id;
    final color = id == 'errors' ? _danger(context) : _accent(context);
    return GestureDetector(
      onTap: () => setState(() => _filter = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: active ? color.withValues(alpha: 0.12) : Colors.transparent,
          border: Border.all(color: active ? color : _stroke(context)),
        ),
        child: Text(
          count == null ? app.t(labelKey) : '${app.t(labelKey)}  $count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? color : _sub(context),
          ),
        ),
      ),
    );
  }

  Widget _row(AppState app, EvsLogLine l) {
    // Строки ошибок красятся целиком; у остальных цветом уровня — только штрих.
    final text = l.level == 'danger' ? _danger(context) : _sub(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(EvsLogFeed.clock(l.time),
                style: EvsType.mono.copyWith(
                    fontSize: 12, height: 1.9, color: _faint(context))),
          ),
          Container(
            width: 3,
            height: 15,
            margin: const EdgeInsets.only(top: 4, right: 10),
            decoration: BoxDecoration(
              color: _levelColor(l.level),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(
            width: 82,
            child: Text(app.t(EvsLogFeed.labelKey(l.source)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: EvsType.mono.copyWith(
                    fontSize: 12, height: 1.9, color: _faint(context))),
          ),
          Expanded(
            child: SelectableText(l.text,
                style: EvsType.mono
                    .copyWith(fontSize: 12, height: 1.9, color: text)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final q = _search.text.trim().toLowerCase();
    final visible = _lines.where((l) {
      if (_filter != 'all' && l.source != _filter) return false;
      return q.isEmpty || l.text.toLowerCase().contains(q);
    }).toList();
    final errors = _lines.where((l) => l.source == 'errors').length;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(fontSize: 13, color: _txt(context)),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon:
                          Icon(Icons.search, size: 15, color: _faint(context)),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      hintText: app.t('ncSearch'),
                      hintStyle:
                          TextStyle(fontSize: 13, color: _faint(context)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _stroke(context)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _accent(context)),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              evsGhostButton(context, app.t('ncCopy'), Icons.copy_all_outlined,
                  onTap: () {
                Clipboard.setData(
                    ClipboardData(text: EvsLogFeed.asText(visible)));
                showAppSnackBar(context, app.t('ncCopied'));
              }),
              const SizedBox(width: 8),
              evsGhostButton(
                  context, app.t('ncLogFolder'), Icons.folder_open_outlined,
                  onTap: () => unawaited(EvsLogFeed.openFolder())),
              const SizedBox(width: 8),
              evsGhostButton(context, app.t('ncRefresh'), Icons.refresh,
                  onTap: () => unawaited(_load())),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (id, key) in _filters)
                _chip(app, id, key, id == 'errors' ? errors : null),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 420,
            decoration: BoxDecoration(
              color: _card2(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _stroke(context)),
            ),
            clipBehavior: Clip.antiAlias,
            child: _loading
                ? const Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : visible.isEmpty
                    ? Center(
                        child: Text(app.t('ncLogEmpty'),
                            style: TextStyle(
                                fontSize: 13, color: _faint(context))))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: visible.length,
                        itemBuilder: (_, i) => _row(app, visible[i]),
                      ),
          ),
          const SizedBox(height: 8),
          Text('${visible.length} / ${_lines.length}',
              style: EvsType.mono
                  .copyWith(fontSize: 11, color: _faint(context))),
        ],
      ),
    );
  }
}

class _AssetModelsCard extends StatefulWidget {
  final AppState app;
  const _AssetModelsCard(this.app);
  @override
  State<_AssetModelsCard> createState() => _AssetModelsCardState();
}

class _AssetModelsCardState extends State<_AssetModelsCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.app.refreshAssetModels());
  }

  // Piper voices live in the "Голос ассистента" card, not the general manager.
  List<AssetModelSpec> get _models =>
      kAssetModels.where((s) => s.family != 'tts-voice').toList();

  Future<void> _confirmDelete(AssetModelSpec spec) async {
    final app = widget.app;
    if (app.assetActive(spec)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(app.t('mdlActiveCantDelete'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(spec.name, style: TextStyle(color: _txt(context))),
        content: Text(app.t('mdlDeleteConfirm'),
            style: TextStyle(color: _sub(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(app.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.t('mdlDelete'))),
        ],
      ),
    );
    if (ok == true) await app.deleteAssetModel(spec);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final spec in _models) ...[
            _tile(spec),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: Text(app.t('mdlOpenFolder')),
                onPressed: () => app.openModelsFolder(),
              ),
              const Spacer(),
              Builder(builder: (_) {
                final mb = (kAssetModels
                            .where((s) => app.assetInstalled(s.id))
                            .fold<int>(0, (a, s) => a + s.totalSize) /
                        1e6)
                    .round();
                if (mb <= 0) return const SizedBox.shrink();
                return Text('${app.t('mdlTotalDisk')}: $mb ${app.t('mbShort')}',
                    style: TextStyle(
                        color: _faint(context), fontSize: 11));
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tile(AssetModelSpec spec) {
    final app = widget.app;
    final installed = app.assetInstalled(spec.id);
    final progress = app.assetProgress[spec.id];
    final downloading = progress != null;
    final active = app.assetActive(spec);

    String status;
    Color color;
    if (downloading) {
      status = '${(progress.clamp(0.0, 1.0) * 100).round()}%';
      color = const Color(0xFFB9A6FF);
    } else if (active) {
      status = app.t('engActive');
      color = const Color(0xFF34D399);
    } else if (installed) {
      status = app.t('mdlInstalled');
      color = const Color(0xFF34D399);
    } else {
      status = app.t('mdlNotInstalled');
      color = const Color(0xFF8A8A95);
    }
    final sizeMb = (spec.totalSize / 1e6).round();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card2(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(spec.name,
                    style: TextStyle(
                        color: _txt(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(status,
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(app.t(spec.descKey),
              style: TextStyle(color: _sub(context), fontSize: 12)),
          const SizedBox(height: 4),
          Text(
              '~$sizeMb ${app.t('mbShort')} · ~${spec.ramMb} ${app.t('mdlRamShort')}',
              style: TextStyle(color: _faint(context), fontSize: 11)),
          const SizedBox(height: 10),
          if (downloading)
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: const Color(0xFF2A2A38)),
                ),
              ),
              IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: _sub(context)),
                  tooltip: app.t('cancelDownload'),
                  onPressed: () => app.cancelAssetDownload(spec.id)),
            ])
          else
            Align(
              alignment: Alignment.centerLeft,
              child: installed
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: Text(app.t('mdlDelete')),
                      onPressed: () => _confirmDelete(spec))
                  : FilledButton.icon(
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(app.t('mdlDownload')),
                      onPressed: () => app.downloadAssetModel(spec)),
            ),
        ],
      ),
    );
  }
}

// TZ2 block 1: noise-suppression selector (off / light / strong). Applies live;
// warns if the selected mode's model isn't downloaded (→ Models section).
class _DenoiseSelector extends StatefulWidget {
  final AppState app;
  const _DenoiseSelector(this.app);
  @override
  State<_DenoiseSelector> createState() => _DenoiseSelectorState();
}

class _DenoiseSelectorState extends State<_DenoiseSelector> {
  bool _open = false; // "Подробнее" (TZ2 block 4)
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: sc.denoiseStatus,
      builder: (context, _) {
        final mode = app.denoiseMode;
        final needsModel = mode == 'light'
            ? 'denoise-gtcrn'
            : mode == 'strong'
                ? 'denoise-df'
                : null;
        final installed = needsModel == null || app.assetInstalled(needsModel);
        final st = sc.denoiseStatus.value;
        final desc = mode == 'off'
            ? app.t('dnOffShort')
            : mode == 'light'
                ? app.t('dnLightShort')
                : app.t('dnStrongShort');
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              evsSegmentedWide<String>(context, 
                [
                  ('off', app.t('dnOff')),
                  ('light', app.t('dnLight')),
                  ('strong', app.t('dnStrong')),
                ],
                mode,
                (v) => app.setDenoiseMode(v),
              ),
              const SizedBox(height: 8),
              Text(desc,
                  style:
                      TextStyle(color: _sub(context), fontSize: 12)),
              _DetailDisclosure(
                open: _open,
                detail: app.t(mode == 'off'
                    ? 'dnOffDetail'
                    : mode == 'light'
                        ? 'dnLightDetail'
                        : 'dnStrongDetail'),
                moreLabel: app.t('moreDetails'),
                lessLabel: app.t('lessDetails'),
                onToggle: () => setState(() => _open = !_open),
              ),
              if (!installed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    const Icon(Icons.download_for_offline_outlined,
                        size: 14, color: Color(0xFFF0A030)),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(app.t('dnNotInstalled'),
                            style: const TextStyle(
                                color: Color(0xFFF0A030), fontSize: 11))),
                  ]),
                ),
              if (st != null && st.$2 == 'error' && st.$3 != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(st.$3!,
                      style: const TextStyle(
                          color: Color(0xFFF0605E), fontSize: 11)),
                ),
            ],
          ),
        );
      },
    );
  }
}

// TZ2 block 8.2: additional simultaneous microphones. Lists input devices other
// than the primary; each can be toggled "in use" with its own denoise mode. The
// sidecar arbitrates overlapping phrases (loudest wins, 2 s cooldown).
class _MultiMicCard extends StatefulWidget {
  final AppState app;
  const _MultiMicCard(this.app);
  @override
  State<_MultiMicCard> createState() => _MultiMicCardState();
}

class _MultiMicCardState extends State<_MultiMicCard> {
  List<InputDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await MicMeter.instance.listDevices();
    if (mounted) setState(() => _devices = d);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final extras =
        _devices.where((d) => d.id != app.inputDeviceId).toList();
    if (extras.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final d in extras) _row(d)],
        ),
      ),
    );
  }

  Widget _row(InputDevice d) {
    final app = widget.app;
    final active = app.extraMicIds.contains(d.id);
    final mode = app.deviceDenoise[d.id] ?? 'light';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card2(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                active ? const Color(0x5534D399) : _stroke(context)),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(
              child: Text(d.label,
                  style: TextStyle(
                      color: _txt(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w600))),
          evsToggle(context, active, (v) => app.toggleExtraMic(d.id, d.label, v)),
        ]),
        if (active) ...[
          const SizedBox(height: 10),
          evsSegmentedWide<String>(context, 
            [
              ('off', app.t('dnOff')),
              ('light', app.t('dnLight')),
              ('strong', app.t('dnStrong')),
            ],
            mode,
            (v) => app.setExtraMicDenoise(d.id, v),
          ),
        ],
      ]),
    );
  }
}

// TZ2 block 7: game / heavy-GPU mode settings + live "GPU offload" badge.
// Hidden entirely when no GPU is detected (there's nothing to offload).
class _GameModeCard extends StatelessWidget {
  final AppState app;
  const _GameModeCard(this.app);

  Future<void> _addExclusion(BuildContext context) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(app.t('gmExclAdd'), style: TextStyle(color: _txt(context))),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: const InputDecoration(hintText: 'game.exe'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(app.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: Text(app.t('mdlAdd'))),
        ],
      ),
    );
    final n = (name ?? '').trim().toLowerCase();
    if (n.isNotEmpty && !app.gameModeExclusions.contains(n)) {
      app.setGameModeExclusions([...app.gameModeExclusions, n]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.gpuInfo, sc.gameModeStatus]),
      builder: (context, _) {
        if (!sc.gpuInfo.value.$1) return const SizedBox.shrink();
        final (active, reason) = sc.gameModeStatus.value;
        return evsCard(
          context,
          icon: Icons.sports_esports_outlined,
          title: app.t('cardGameMode'),
          rows: [
            if (active)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
                child: Row(children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: const Color(0x22F0A030),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(app.t('gmOffloadBadge'),
                        style: const TextStyle(
                            color: Color(0xFFF0A030),
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      reason == 'vram'
                          ? app.t('gmReasonVram')
                          : app.t('gmReasonFullscreen'),
                      style: TextStyle(
                          color: _sub(context), fontSize: 11)),
                ]),
              ),
            evsRow(context, 
              label: app.t('gmFullscreen'),
              desc: app.t('gmFullscreenDesc'),
              control: evsToggle(context, 
                  app.gameModeFullscreen, (v) => app.setGameModeFullscreen(v)),
            ),
            evsRow(context, 
              label: app.t('gmVram'),
              desc: app.t('gmVramDesc'),
              control: evsToggle(context, app.gameModeVram, (v) => app.setGameModeVram(v)),
            ),
            if (app.gameModeVram) ...[
              evsRow(context, 
                label: app.t('gmVramEnter'),
                control: evsSlider(context, 
                  value: app.gameModeVramEnter.clamp(50, 99),
                  min: 50,
                  max: 99,
                  divisions: 49,
                  label: '${app.gameModeVramEnter.round()}%',
                  onChanged: (v) => app.setGameModeVramThresholds(
                      v, app.gameModeVramExit),
                ),
              ),
              evsRow(context, 
                label: app.t('gmVramExit'),
                control: evsSlider(context, 
                  value: app.gameModeVramExit
                      .clamp(30, app.gameModeVramEnter - 5),
                  min: 30,
                  max: 94,
                  divisions: 64,
                  label: '${app.gameModeVramExit.round()}%',
                  onChanged: (v) => app.setGameModeVramThresholds(
                      app.gameModeVramEnter, v),
                ),
              ),
            ],
            evsRow(context, 
              label: app.t('gmNotify'),
              desc: app.t('gmNotifyDesc'),
              control:
                  evsToggle(context, app.gameModeNotify, (v) => app.setGameModeNotify(v)),
            ),
            evsRow(context, 
              stacked: true,
              label: app.t('gmExclusions'),
              desc: app.t('gmExclusionsDesc'),
              control: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (app.gameModeExclusions.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final ex in app.gameModeExclusions)
                          Chip(
                            label: Text(ex,
                                style: const TextStyle(fontSize: 12)),
                            onDeleted: () => app.setGameModeExclusions(app
                                .gameModeExclusions
                                .where((e) => e != ex)
                                .toList()),
                          ),
                      ],
                    ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(app.t('gmExclAdd')),
                      onPressed: () => _addExclusion(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Settings navigation — two levels: group -> page.
//
// The panel used to be ten flat sections, each one long scroll. "Голос
// ассистента" alone stacked the engine picker, the whole clone block, the
// GPU-load knobs, the interpreter and five FX sliders into ONE card — and a
// card cannot be split across masonry columns, so that column ran several
// screens deep while the others ended after two cards. Every group is now cut
// into short pages: one screen = one topic.
//
// Pages are addressed by a stable string id, never by position. The numeric
// section indexes the Nexus rail passed around silently started pointing at
// the wrong screen every time a section was split (the LLM and System
// subsystem cards opened "Телефоны" instead of the model settings).
class _Pages {
  static const basics = 'general.basics';
  static const startup = 'general.startup';
  static const micDevice = 'mic.device';
  static const stt = 'mic.stt';
  static const listen = 'mic.listen';
  static const voiceOut = 'voice.out';
  static const voiceEngine = 'voice.engine';
  static const voiceClone = 'voice.clone';
  static const voiceFx = 'voice.fx';
  static const voicePhrases = 'voice.phrases';
  static const widgetsLook = 'widgets.look';
  static const widgetsParams = 'widgets.params';
  static const cmdExec = 'cmd.exec';
  static const cmdCatalog = 'cmd.catalog';
  static const cmdSecurity = 'cmd.security';
  static const remote = 'remote';
  static const llmConn = 'llm.conn';
  static const llmModels = 'llm.models';
  static const llmParams = 'llm.params';
  static const personaStyle = 'persona.style';
  static const personaMemory = 'persona.memory';
  static const privAccess = 'privacy.access';
  static const privData = 'privacy.data';
  static const appLog = 'log';
  static const about = 'about.info';
  static const changelog = 'about.changelog';
}

class _NavPage {
  final String id;
  final String titleKey;
  const _NavPage(this.id, this.titleKey);
}

class _NavGroup {
  final IconData icon;
  final String titleKey;
  final String subKey;
  final List<_NavPage> pages;
  const _NavGroup(this.icon, this.titleKey, this.subKey, this.pages);
  // A one-page group needs no second level: the rail row IS the destination.
  bool get single => pages.length == 1;
}

const List<_NavGroup> _kNav = [
  _NavGroup(Icons.settings_outlined, 'navGeneral', 'navGeneralSub', [
    _NavPage(_Pages.basics, 'pgBasics'),
    _NavPage(_Pages.startup, 'pgStartup'),
  ]),
  _NavGroup(Icons.mic_none, 'navVoiceInput', 'navVoiceInputSub', [
    _NavPage(_Pages.micDevice, 'pgMicDevice'),
    _NavPage(_Pages.stt, 'pgStt'),
    _NavPage(_Pages.listen, 'pgListen'),
  ]),
  _NavGroup(
      Icons.record_voice_over_outlined, 'navAssistantVoice',
      'navAssistantVoiceSub', [
    _NavPage(_Pages.voiceOut, 'pgVoiceOut'),
    _NavPage(_Pages.voiceEngine, 'pgVoiceEngine'),
    _NavPage(_Pages.voiceClone, 'pgVoiceClone'),
    _NavPage(_Pages.voiceFx, 'pgVoiceFx'),
    _NavPage(_Pages.voicePhrases, 'pgVoicePhrases'),
  ]),
  _NavGroup(Icons.auto_awesome_outlined, 'navWidgets', 'navWidgetsSub', [
    _NavPage(_Pages.widgetsLook, 'pgWsLook'),
    _NavPage(_Pages.widgetsParams, 'pgWsParams'),
  ]),
  _NavGroup(Icons.bolt_outlined, 'navVoiceCommands', 'navVoiceCommandsSub', [
    _NavPage(_Pages.cmdExec, 'pgCmdExec'),
    _NavPage(_Pages.cmdCatalog, 'pgCmdCatalog'),
    _NavPage(_Pages.cmdSecurity, 'pgCmdSecurity'),
  ]),
  _NavGroup(Icons.phone_iphone, 'navRemote', 'navRemoteSub', [
    _NavPage(_Pages.remote, 'navRemote'),
  ]),
  _NavGroup(Icons.memory, 'navModel', 'navModelSub', [
    _NavPage(_Pages.llmConn, 'pgLlmConn'),
    _NavPage(_Pages.llmModels, 'pgLlmModels'),
    _NavPage(_Pages.llmParams, 'pgLlmParams'),
  ]),
  _NavGroup(Icons.chat_bubble_outline, 'navPersona', 'navPersonaSub', [
    _NavPage(_Pages.personaStyle, 'pgPersonaStyle'),
    _NavPage(_Pages.personaMemory, 'pgPersonaMemory'),
  ]),
  _NavGroup(Icons.lock_outline, 'navPrivacy', 'navPrivacySub', [
    _NavPage(_Pages.privAccess, 'pgPrivAccess'),
    _NavPage(_Pages.privData, 'pgPrivData'),
  ]),
  // Журнал работы приложения. Своя группа, а не пункт внутри «О программе»:
  // рейл Nexus подсвечивается по группе (_inGroup), и внутри «О программе»
  // кнопка журнала загоралась бы заодно на версии и списке изменений.
  _NavGroup(Icons.receipt_long_outlined, 'navLog', 'navLogSub', [
    _NavPage(_Pages.appLog, 'navLog'),
  ]),
  _NavGroup(Icons.info_outline, 'navAbout', 'navAboutSub', [
    _NavPage(_Pages.about, 'pgAboutInfo'),
    _NavPage(_Pages.changelog, 'pgChangelog'),
  ]),
];

// Group holding [id]; falls back to the first group so an unknown/stale id can
// never render an empty panel.
_NavGroup _navGroupOf(String id) => _kNav.firstWhere(
      (g) => g.pages.any((p) => p.id == id),
      orElse: () => _kNav.first,
    );

_NavPage _navPageOf(String id) {
  final g = _navGroupOf(id);
  return g.pages.firstWhere((p) => p.id == id, orElse: () => g.pages.first);
}

class DesktopSettings extends StatefulWidget {
  // Which page to open on (a _Pages id). Lets the Nexus rail and the subsystem
  // cards jump straight to Commands / Models / About instead of landing on the
  // first page.
  final String initialPage;
  const DesktopSettings({super.key, this.initialPage = _Pages.basics});
  @override
  State<DesktopSettings> createState() => _DesktopSettingsState();
}

class _DesktopSettingsState extends State<DesktopSettings> {
  late String _page = widget.initialPage;
  // Held so dispose() can end draft mode without a BuildContext (TZ2.2).
  AppState? _appRef;
  // Phase-1 placeholders for not-yet-wired desktop toggles (autostart, tray…).
  final Map<String, bool> _stub = {
    'autostart': true,
    'tray': true,
    'closeToTray': true,
    'startShown': false,
    'notifications': true,
    'animations': true,
    'autoUpdate': true,
    'showPartial': true,
    'showVizBg': true,
    'cmdEnabled': true,
    'permFiles': true,
    'permBrowser': true,
    'permMedia': true,
    'permSystem': false,
    'permNetwork': true,
    'permRegistry': false,
    'offline': false,
    'noTelemetry': true,
    'noModelNet': false,
  };
  final Map<String, double> _stubNum = {
    'threshold': 65,
    'temp': 0.7,
    'topp': 0.9,
    'maxtok': 1024,
  };
  final List<String> _blacklist = [
    'удали все файлы',
    'форматируй диск',
    'shutdown /s',
  ];
  final TextEditingController _activatorCtrl =
      TextEditingController(text: 'EVS');
  final TextEditingController _stopWordsCtrl = TextEditingController();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _apiKeyCtrl;
  bool _ctrlInit = false;
  List<InputDevice> _micDevices = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ctrlInit) return;
    _ctrlInit = true;
    final app = context.read<AppState>();
    // Enter settings draft mode: changes preview live but persist only on Save.
    _appRef = app;
    app.beginSettingsEdit();
    final p = app.persona;
    _nameCtrl = TextEditingController(text: p.assistantName);
    _promptCtrl = TextEditingController(text: p.customPrompt);
    _serverCtrl = TextEditingController(text: app.serverUrl);
    _apiKeyCtrl = TextEditingController(text: app.apiKey);
    _activatorCtrl.text = app.wakeWord;
    _stopWordsCtrl.text = app.stopWords.join(', ');
    // Keep the meter alive for the input-level bar, and enumerate mics.
    MicMeter.instance.start(deviceId: app.inputDeviceId);
    _loadMicDevices();
  }

  Future<void> _loadMicDevices() async {
    final devs = await MicMeter.instance.listDevices();
    if (mounted) setState(() => _micDevices = devs);
  }

  Widget _inputDeviceControl(AppState app) {
    final items = <(String, String)>[('', app.t('defaultDevice'))];
    for (final d in _micDevices) {
      items.add((d.id, d.label));
    }
    final current = items.firstWhere((e) => e.$1 == app.inputDeviceId,
        orElse: () => items.first);
    return PopupMenuButton<String>(
      tooltip: '',
      color: _card(context),
      onSelected: (id) {
        final label = items
            .firstWhere((e) => e.$1 == id, orElse: () => ('', ''))
            .$2;
        app.setInputDeviceId(id, label: label);
        MicMeter.instance.start(deviceId: id);
        final hint = app.consumeMicHint();
        if (hint.isNotEmpty) showAppSnackBar(context, hint);
      },
      itemBuilder: (_) => [
        for (final it in items)
          PopupMenuItem<String>(
            value: it.$1,
            child: Text(it.$2,
                style: TextStyle(color: _body(context), fontSize: 13)),
          ),
      ],
      child: evsSelectButton(context, current.$2, minWidth: 120),
    );
  }

  @override
  void dispose() {
    // Safety net: if the screen is torn down while still editing (not via Save/
    // Cancel or the exit guard), discard the draft so nothing half-edited sticks.
    _appRef?.abortSettingsEdit();
    if (_ctrlInit) {
      _nameCtrl.dispose();
      _promptCtrl.dispose();
      _serverCtrl.dispose();
      _apiKeyCtrl.dispose();
    }
    _activatorCtrl.dispose();
    _stopWordsCtrl.dispose();
    super.dispose();
  }

  void _persona(void Function(Personalization) mut) {
    final app = context.read<AppState>();
    mut(app.persona);
    app.savePersona(app.persona);
  }

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PopScope(
      canPop: !app.settingsDirty && !app.settingsApplying,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleExit(app);
      },
      child: Scaffold(
        backgroundColor: _bg(context),
        // Nexus: Esc closes settings (the header advertises it). Classic keeps
        // the plain back/close behaviour it always had.
        body: CallbackShortcuts(
          bindings: app.appStyle != AppStyle.standard
              ? {
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      _handleExit(app),
                }
              : const {},
          child: Focus(
            autofocus: app.appStyle != AppStyle.standard,
            child: Container(
              decoration: _evsShellBg(context),
              // Same shell shape as DesktopHome: the nav rail spans the FULL window
              // height and the title bar sits only over the content column. The old
              // order (title bar across the top, rail below it) left a strip above a
              // visibly shortened rail.
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        // Nexus keeps its icon rail visible in settings, so the
                        // window reads as one shell instead of a separate screen.
                        if (app.appStyle == AppStyle.nexus)
                          _NexusRail(
                            activePage: _page,
                            onSection: (p) => setState(() => _page = p),
                          ),
                        _nav(app),
                        Expanded(
                          child: Column(
                            children: [
                              const _WindowTitleBar(),
                              Expanded(child: _sectionScaffold(app)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  _saveBar(app),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Sticky "unsaved changes" bar (TZ2.2): shown whenever the draft is dirty or a
  // save is in flight; collapses with an animation otherwise.
  Widget _saveBar(AppState app) {
    // Nexus style shows no floating "unsaved changes" bar (TZ §6.3): the exit
    // dialog (PopScope → _handleExit) stays the single confirmation point. The
    // settingsDirty / settingsApplying state itself is left untouched.
    if (app.appStyle != AppStyle.standard) {
      return const SizedBox(width: double.infinity);
    }
    final show = app.settingsDirty || app.settingsApplying;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !show
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: _card2(context),
                border: Border(top: BorderSide(color: _stroke(context))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_outlined,
                      size: 19, color: Color(0xFFB9A6FF)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(app.t('settingsUnsaved'),
                        style:
                            TextStyle(color: _txt(context), fontSize: 13)),
                  ),
                  if (app.settingsApplying)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else ...[
                    TextButton(
                      onPressed: () => _revertSettings(app),
                      child: Text(app.t('cancel'),
                          style: TextStyle(color: _sub(context))),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _saveSettings(app),
                      child: Text(app.t('save')),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _saveSettings(AppState app) async {
    final ok = await app.commitSettingsEdit();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text(ok ? app.t('settingsSaved') : app.t('settingsSaveFailed')),
    ));
    // Stay on the screen — re-arm draft mode for further edits.
    app.beginSettingsEdit();
  }

  Future<void> _revertSettings(AppState app) async {
    await app.cancelSettingsEdit();
    if (!mounted) return;
    // Text fields keep their own controller state — resync them to the reverted
    // values so a Cancel visibly rolls back typed text too.
    _resetTextControllers(app);
    app.beginSettingsEdit();
  }

  void _resetTextControllers(AppState app) {
    if (!_ctrlInit) return;
    _serverCtrl.text = app.serverUrl;
    _apiKeyCtrl.text = app.apiKey;
    _activatorCtrl.text = app.wakeWord;
    _stopWordsCtrl.text = app.stopWords.join(', ');
  }

  // Exit guard (TZ2.2): leaving with unsaved changes asks Save / Don't save /
  // Stay. Reached from the back button and the system pop (via PopScope).
  Future<void> _handleExit(AppState app) async {
    if (!app.settingsDirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // Styled to match the update-restart prompt (_showPrompt): dark rounded card,
    // logo mark + title, a hint line, and Stay / Don't-save / Save actions with a
    // gradient primary. Height-capped + scrollable so long copy can't overflow.
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(dctx).size.height * 0.85),
          child: SingleChildScrollView(
            child: Container(
              width: 440,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
              decoration: BoxDecoration(
                color: _card2(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x1AFFFFFF)),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black54,
                      blurRadius: 40,
                      offset: Offset(0, 16)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _EvsLogoMark(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          app.t('settingsExitTitle'),
                          style: TextStyle(
                              color: _txt(context),
                              fontSize: 17,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(app.t('settingsUnsaved'),
                      style: TextStyle(
                          color: _faint(context), fontSize: 12)),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, 'stay'),
                        child: Text(app.t('settingsExitStay'),
                            style: TextStyle(color: _sub(context))),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, 'discard'),
                        child: Text(app.t('settingsExitDiscard'),
                            style: TextStyle(color: _sub(context))),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.pop(dctx, 'save'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: const LinearGradient(
                                colors: [Color(0xFF5068D8), Color(0xFF8855CC)]),
                          ),
                          child: Text(app.t('settingsExitSave'),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'save') {
      await app.commitSettingsEdit();
      if (mounted) Navigator.of(context).pop();
    } else if (choice == 'discard') {
      await app.cancelSettingsEdit();
      if (mounted) Navigator.of(context).pop();
    }
    // 'stay' / dismissed → remain on the screen (draft intact).
  }

  // -------- left nav rail --------
  Widget _nav(AppState app) {
    // Nexus widens the rail slightly and adds a per-section subtitle + a version
    // chip at the bottom (TZ §6.3); «Ноктюрн» uses the same 252 px navigation
    // with subtitles (Noctur TZ §5.9). Classic keeps its exact current look.
    final nexus = app.appStyle != AppStyle.standard;
    return Container(
      width: nexus ? 252 : 244,
      decoration: _evsRailBg(context),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 18),
              child: Row(
                children: [
                  InkResponse(
                    radius: 22,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _overlayFill(context, 0.042),
                        border: Border.all(color: _stroke(context)),
                      ),
                      child: Icon(Icons.arrow_back,
                          size: 15, color: _sub(context)),
                    ),
                  ),
                  const SizedBox(width: 9),
                  const _EvsLogoMark(size: 28),
                  const SizedBox(width: 9),
                  Text('EVS',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: _txt(context))),
                ],
              ),
            ),
            // Nexus header: the panel names itself and advertises Esc, which is
            // wired up in build(). Classic keeps the plain "РАЗДЕЛЫ" label.
            if (nexus)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(app.t('settings'),
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                            color: _txt(context))),
                    const SizedBox(height: 8),
                    Row(children: [
                      Text(app.t('nxCloseHint'),
                          style: EvsType.caption.copyWith(
                              fontSize: 11, color: _faint(context))),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: _overlayFill(context, 0.05),
                          border: Border.all(color: _stroke(context)),
                        ),
                        child: Text('Esc',
                            style: EvsType.mono.copyWith(
                                fontSize: 10.5, color: _sub(context))),
                      ),
                    ]),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Text('РАЗДЕЛЫ',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: _faint(context))),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final g in _kNav) ...[
                    _navGroupTile(app, g, nexus),
                    // Only the group holding the open page unfolds, so the rail
                    // stays one screen tall no matter how many pages exist.
                    if (!g.single && _navGroupOf(_page) == g)
                      for (final p in g.pages) _navPageTile(app, p, nexus),
                  ],
                ],
              ),
            ),
            if (nexus)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Row(
                  children: [
                    _VersionText(),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // First navigation level. A group with pages never carries the filled
  // highlight itself — that belongs to the open page below it — it only tints
  // its icon/label so you can see which branch you are in.
  Widget _navGroupTile(AppState app, _NavGroup g, bool nexus) {
    final actAcc = nexus ? _info(context) : _accent(context);
    final open = _navGroupOf(_page) == g;
    final filled = open && g.single;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          // Tapping a group opens its first page; tapping the open group is a
          // no-op rather than a collapse, so the rail never hides where you are.
          onTap: () => setState(() => _page = g.pages.first.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              color: filled
                  ? actAcc.withValues(alpha: nexus ? 0.09 : 0.13)
                  : Colors.transparent,
              border: Border.all(
                color: filled
                    ? actAcc.withValues(alpha: nexus ? 0.30 : 0.22)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 31,
                  height: 31,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: open
                        ? actAcc.withValues(alpha: 0.2)
                        : _overlayFill(context, 0.042),
                  ),
                  child: Icon(g.icon,
                      size: 14,
                      color: open ? actAcc : const Color(0xFF9691C0)),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: nexus
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(app.t(g.titleKey),
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: open
                                        ? _txt(context)
                                        : _sub(context))),
                            const SizedBox(height: 1),
                            Text(app.t(g.subKey),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11, color: _faint(context))),
                          ],
                        )
                      : Text(app.t(g.titleKey),
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: open ? _txt(context) : _sub(context))),
                ),
                if (!g.single)
                  Icon(open ? Icons.expand_more : Icons.chevron_right,
                      size: 15, color: _faint(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Second navigation level: the actual destinations, indented under the open
  // group and carrying the active highlight.
  Widget _navPageTile(AppState app, _NavPage p, bool nexus) {
    final actAcc = nexus ? _info(context) : _accent(context);
    final active = p.id == _page;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 1, 0, 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _page = p.id),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 7, 11, 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: active
                  ? actAcc.withValues(alpha: nexus ? 0.09 : 0.13)
                  : Colors.transparent,
              border: Border.all(
                color: active
                    ? actAcc.withValues(alpha: nexus ? 0.30 : 0.22)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? actAcc : _stroke(context),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(app.t(p.titleKey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w500,
                          color: active ? _txt(context) : _sub(context))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------- right pane: section topbar + card grid --------
  Widget _sectionScaffold(AppState app) {
    final g = _navGroupOf(_page);
    final p = _navPageOf(_page);
    // One-page groups keep the old "Название — подпись" heading; inside a split
    // group the page name leads and the group name is the breadcrumb.
    final title = g.single ? app.t(g.titleKey) : app.t(p.titleKey);
    final crumb = g.single ? app.t(g.subKey) : app.t(g.titleKey);
    return SafeArea(
      child: Column(
        children: [
          _searchBar(app),
          if (_query.trim().isNotEmpty) ...[
            Divider(color: _stroke(context), height: 1),
            Expanded(child: _searchResults(app)),
          ] else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 14),
            child: Row(
              children: [
                // «Ноктюрн» (§5.9): у настроек своя шапка — контурная кнопка
                // «Назад» и заголовок. Рейла, который в Nexus служит выходом,
                // в этом стиле нет, а Esc-подсказки в шапке тоже нет.
                if (_isNoctur(context)) ...[
                  InkWell(
                    borderRadius:
                        BorderRadius.circular(_skin(context).radiusControl),
                    onTap: () => _handleExit(app),
                    child: Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                            _skin(context).radiusControl),
                        border: Border.all(color: _stroke(context)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_back,
                              size: 14, color: _sub(context)),
                          const SizedBox(width: 6),
                          Text(app.t('ncBack'),
                              style: TextStyle(
                                  fontSize: 12.5, color: _body(context))),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Text(title,
                    style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: _txt(context))),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('— $crumb',
                      style: TextStyle(
                          fontSize: 13, color: _faint(context))),
                ),
              ],
            ),
          ),
          // Live pipeline strip on every voice-related page.
          if (_page.startsWith('mic.') || _page.startsWith('voice.'))
            _voiceStatus(app),
          Divider(color: _stroke(context), height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, cons) {
                const gap = 14.0;
                // Cap the text column on wide monitors: pages are short now,
                // and a lone card stretched across 2500 px reads badly.
                final inner = math.min(cons.maxWidth - 56, 1180.0);
                final cards = _cardsFor(app);
                // Column count follows the window width: 1 / 2 / 3 — but never
                // more columns than there are cards, or a single-card page
                // would render as one narrow strip with two empty columns.
                final w = cons.maxWidth;
                var cols = w < 640 ? 1 : (w < 1024 ? 2 : 3);
                if (cards.isNotEmpty && cols > cards.length) {
                  cols = cards.length;
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
                  // True masonry: cards stack tightly per column instead of the
                  // old paired-row Wrap, which left a big gap whenever two
                  // side-by-side cards had very different heights (or one
                  // collapsed to nothing, e.g. the GPU-only cards).
                  child: Center(
                    child: SizedBox(
                      width: inner,
                      child: _cardMasonry(cards, cols, gap, inner),
                    ),
                  ),
                );
              },
            ),
          ),
          ],
        ],
      ),
    );
  }

  // Live "what is actually running" strip for the voice section. Settings show
  // what is CONFIGURED; this shows what is in effect — which is where the real
  // surprises live (a clone endpoint that was never made the active engine, or
  // no Piper voice installed so speech silently falls to the Windows voice).
  Widget _voiceStatus(AppState app) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.status]),
      builder: (context, _) {
        final up = sc.status.value == SidecarStatus.connected;
        final stt = sttEngineLabel(app);

        String voice;
        bool voiceOk;
        if (app.ttsEngineChoice == 'cosyvoice') {
          voice = app.t('ttsEngineCosy');
          voiceOk = app.cosyvoiceOnline == true;
          // Offline is not "dead": pre-rendered phrases still play from the
          // cache in the cloned voice, so say that instead of just "не отвечает".
          if (!voiceOk) voice = '$voice — ${app.t('voiceStatusCache')}';
        } else if (app.ttsPiperVoice.isNotEmpty) {
          voice = 'Piper';
          voiceOk = true;
        } else {
          voice = app.t('voiceStatusSystem');
          voiceOk = false;
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusChip(
                  app.t('voiceStatusMic'),
                  !up
                      ? app.t('voiceStatusOff')
                      // При Push-to-Talk микрофон открыт только на удержание —
                      // «слушает» здесь неправда.
                      : app.listenMode == 'ptt'
                          ? app.t('voiceStatusPtt')
                          : app.t('voiceStatusReady'),
                  up),
              _statusChip(app.t('voiceStatusStt'), stt, up),
              _statusChip(app.t('voiceStatusVoice'), voice, voiceOk),
            ],
          ),
        );
      },
    );
  }

  Widget _statusChip(String label, String value, bool ok) {
    final c = ok ? _success(context) : _warn(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: c.withValues(alpha: 0.10),
        border: Border.all(color: c.withValues(alpha: 0.32)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 13, color: c),
        const SizedBox(width: 6),
        Text('$label: ',
            style: TextStyle(fontSize: 11.5, color: _sub(context))),
        Text(value,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: _txt(context))),
      ]),
    );
  }

  // ---- Search ------------------------------------------------------------
  //
  // Settings are nine sections deep, so a setting you cannot name the section
  // for is effectively invisible — twice in testing a control was requested
  // that already existed (response volume, mic sensitivity). The index maps a
  // label's i18n key to its section; matching runs over the localized label AND
  // its description, so searching "тихо" or "не слышно" finds the mic gain.
  static const Map<String, String> _searchIndex = {
    'uiStyle': _Pages.basics,
    'fontSize': _Pages.basics,
    'motionMode': _Pages.basics,
    'startupView': _Pages.startup,
    'autostart': _Pages.startup,
    'minimizeToTray': _Pages.startup,
    'globalHotkey': _Pages.startup,
    'cardInputDevice': _Pages.micDevice,
    'extraMics': _Pages.micDevice,
    'micSensitivity': _Pages.stt,
    'micGain': _Pages.stt,
    'recognitionLanguage': _Pages.stt,
    'sttEngine': _Pages.stt,
    'engRemoteName': _Pages.stt,
    'cardDenoise': _Pages.stt,
    'activationMode': _Pages.listen,
    'pttKeysLabel': _Pages.listen,
    'showPartial': _Pages.listen,
    'autoSendPause': _Pages.listen,
    'cardVoiceResp': _Pages.voiceOut,
    'voiceResponses': _Pages.voiceOut,
    'announceReady': _Pages.voiceOut,
    'ttsRate': _Pages.voiceOut,
    'ttsVolume': _Pages.voiceOut,
    'voiceImportTitle': _Pages.voiceOut,
    'ttsEngineTitle': _Pages.voiceEngine,
    'ttsCosyEndpoint': _Pages.voiceEngine,
    'ttsInterp': _Pages.voiceEngine,
    'ttsCosyClone': _Pages.voiceClone,
    'ttsCosySpeed': _Pages.voiceClone,
    'ttsCosyEmotion': _Pages.voiceClone,
    'gpuLoadTitle': _Pages.voiceClone,
    'gpuProfile': _Pages.voiceClone,
    'gpuInGame': _Pages.voiceClone,
    'ttsFx': _Pages.voiceFx,
    'ttsFxPreset': _Pages.voiceFx,
    'clonePhr2Title': _Pages.voicePhrases,
    'cmdAdd': _Pages.cmdCatalog,
    'cmdMode': _Pages.cmdExec,
    'remoteEnable': _Pages.remote,
    'remotePort': _Pages.remote,
    'remoteAddress': _Pages.remote,
    'remoteResponse': _Pages.remote,
    'cardModels': _Pages.llmModels,
    'cardConnMode': _Pages.llmConn,
    'cardGenParams': _Pages.llmParams,
    'navLog': _Pages.appLog,
    'webSearch': _Pages.llmConn,
    'webSearchProvider': _Pages.llmConn,
  };

  List<(String key, String page)> _matches(AppState app) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = <(String, String)>[];
    void consider(String key, String page) {
      final label = app.t(key);
      final desc = app.t('${key}Desc');
      final hay = '$label ${desc == '${key}Desc' ? '' : desc}'.toLowerCase();
      if (hay.contains(q)) out.add((key, page));
    }

    _searchIndex.forEach(consider);
    // Group and page names are searchable too ("телефон" -> Телефоны, "клон"
    // -> Клон и нагрузка GPU).
    for (final g in _kNav) {
      if ('${app.t(g.titleKey)} ${app.t(g.subKey)}'.toLowerCase().contains(q)) {
        out.add((g.titleKey, g.pages.first.id));
      }
      if (g.single) continue;
      for (final p in g.pages) {
        if (app.t(p.titleKey).toLowerCase().contains(q)) {
          out.add((p.titleKey, p.id));
        }
      }
    }
    return out;
  }

  Widget _searchBar(AppState app) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 10),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: _overlayFill(context, 0.04),
              border: Border.all(color: _stroke(context)),
            ),
            child: Row(children: [
              Icon(Icons.search, size: 17, color: _faint(context)),
              const SizedBox(width: 9),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(fontSize: 13, color: _txt(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: app.t('settingsSearchHint'),
                    hintStyle:
                        TextStyle(fontSize: 13, color: _faint(context)),
                  ),
                ),
              ),
              if (_query.isNotEmpty)
                InkResponse(
                  radius: 16,
                  onTap: () => setState(() {
                    _searchCtrl.clear();
                    _query = '';
                  }),
                  child: Icon(Icons.close, size: 16, color: _sub(context)),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _searchResults(AppState app) {
    final res = _matches(app);
    if (res.isEmpty) {
      return Center(
        child: Text(app.t('settingsSearchEmpty'),
            style: TextStyle(fontSize: 13, color: _faint(context))),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
      itemCount: res.length,
      itemBuilder: (_, i) {
        final (key, page) = res[i];
        final desc = app.t('${key}Desc');
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            // Jump to the page that holds it and drop out of search mode.
            onTap: () => setState(() {
              _page = page;
              _searchCtrl.clear();
              _query = '';
            }),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: _overlayFill(context, 0.03),
                border: Border.all(color: _stroke(context)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.t(key),
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: _txt(context))),
                        if (desc != '${key}Desc') ...[
                          const SizedBox(height: 2),
                          Text(desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5, color: _faint(context))),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                      _navGroupOf(page).single
                          ? app.t(_navGroupOf(page).titleKey)
                          : '${app.t(_navGroupOf(page).titleKey)} · '
                              '${app.t(_navPageOf(page).titleKey)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 11.5, color: _sub(context))),
                  const SizedBox(width: 6),
                  Icon(Icons.chevron_right, size: 16, color: _faint(context)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Masonry for the settings cards. Columns stack independently (no paired-row
  // gaps that a tall card or a collapsed GPU-only card used to open); `full`
  // cards break the columns and span the whole row. [cols] comes from the
  // window width, so the same builder serves the 1/2/3-column layouts.
  Widget _cardMasonry(
      List<_CardSpec> cards, int cols, double gap, double inner) {
    if (cols <= 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            cards[i].child,
          ],
        ],
      );
    }
    final colW = (inner - gap * (cols - 1)) / cols;
    final blocks = <Widget>[];
    var columns = List.generate(cols, (_) => <Widget>[]);
    var next = 0;
    void flush() {
      if (columns.every((c) => c.isEmpty)) return;
      blocks.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < cols; i++) ...[
            if (i > 0) SizedBox(width: gap),
            SizedBox(
                width: colW,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: columns[i])),
          ],
        ],
      ));
      columns = List.generate(cols, (_) => <Widget>[]);
      next = 0;
    }

    for (final c in cards) {
      if (c.full) {
        flush();
        blocks.add(SizedBox(width: inner, child: c.child));
        continue;
      }
      final col = columns[next];
      if (col.isNotEmpty) col.add(SizedBox(height: gap));
      col.add(c.child);
      next = (next + 1) % cols;
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < blocks.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          blocks[i],
        ],
      ],
    );
  }

  // One page = one short list of cards. Everything is built per page (not
  // filtered out of one big list) so opening "Эффекты" never constructs the
  // asset-model or changelog cards.
  List<_CardSpec> _cardsFor(AppState app) {
    switch (_page) {
      case _Pages.basics:
        return _basicsCards(app);
      case _Pages.startup:
        return _startupCards(app);
      case _Pages.micDevice:
        return _micDeviceCards(app);
      case _Pages.stt:
        return _sttCards(app);
      case _Pages.listen:
        return _listenCards(app);
      case _Pages.voiceOut:
        return _voiceOutCards(app);
      case _Pages.voiceEngine:
        return _voiceEngineCards(app);
      case _Pages.voiceClone:
        return _voiceCloneCards(app);
      case _Pages.voiceFx:
        return _voiceFxCards(app);
      case _Pages.voicePhrases:
        return _voicePhraseCards(app);
      case _Pages.widgetsLook:
        return _widgetLookCards(app);
      case _Pages.widgetsParams:
        return _widgetParamCards(app);
      case _Pages.cmdExec:
        return _cmdExecCards(app);
      case _Pages.cmdCatalog:
        return _cmdCatalogCards(app);
      case _Pages.cmdSecurity:
        return _cmdSecurityCards(app);
      case _Pages.remote:
        return _remoteInputCards(app);
      case _Pages.llmConn:
        return _llmConnCards(app);
      case _Pages.llmModels:
        return _llmAssetCards(app);
      case _Pages.llmParams:
        return [..._llmPresetCards(app), ..._llmGenCards(app)];
      case _Pages.personaStyle:
        return _personaStyleCards(app);
      case _Pages.personaMemory:
        return _personaMemoryCards(app);
      case _Pages.privAccess:
        return _privacyAccessCards(app);
      case _Pages.privData:
        return _privacyDataCards(app);
      case _Pages.about:
        return [..._aboutInfoCards(app), ..._aboutUpdateCards(app)];
      case _Pages.appLog:
        return _appLogCards(app);
      case _Pages.changelog:
        return _changelogCards(app);
      default:
        return const [];
    }
  }

  // =================== ТЕЛЕФОНЫ ===================
  List<_CardSpec> _remoteInputCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.wifi_tethering,
            title: app.t('remoteCardListener'),
            rows: [_RemoteInputPanel(app)]),
        full: true,
      ),
    ];
  }

  // =================== ОБЩИЕ ===================
  List<_CardSpec> _basicsCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.language,
        title: app.t('cardLangLoc'),
        rows: [
          evsRow(context, 
            stacked: true,
            label: app.t('interfaceLanguage'),
            desc: app.t('interfaceLanguageDesc'),
            control: evsSegmentedWide<String>(context, 
              const [('ru', 'RU'), ('en', 'EN')],
              app.lang,
              (v) => app.setLang(v),
            ),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('recognitionLanguage'),
            desc: app.t('recognitionLanguageDesc'),
            control: evsSegmentedWide<String>(context, 
              [('auto', app.t('sttAuto')), ('ru', 'RU'), ('en', 'EN')],
              app.sttLanguage,
              (v) => app.setSttLanguage(v),
            ),
          ),
        ],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.light_mode_outlined,
        title: app.t('cardAppearance'),
        rows: [
          evsRow(context,
            stacked: true,
            label: app.t('uiStyle'),
            desc: app.t('uiStyleDesc'),
            control: const _StylePicker(),
          ),
          evsRow(context,
            stacked: true,
            label: app.t('themeMode'),
            control: evsSegmentedWide<AppThemeMode>(context, 
              [
                (AppThemeMode.dark, app.t('themeDark')),
                (AppThemeMode.claude, app.t('themeClaude')),
                (AppThemeMode.claudeDark, app.t('themeClaudeDark')),
              ],
              app.themeMode,
              (v) => app.setThemeMode(v),
            ),
          ),
          evsRow(context, 
            label: app.t('fontSize'),
            desc: app.t('fontSizeDesc'),
            control: SizedBox(
              width: 200,
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      min: 0.75,
                      max: 1.5,
                      value: app.fontSize.clamp(0.75, 1.5),
                      activeColor:
                          _isNexus(context) ? _info(context) : _accent(context),
                      onChanged: (v) => app.setFontSize(v),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text('${(app.fontSize * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _accent(context))),
                  ),
                ],
              ),
            ),
          ),
          // Ambient-animation policy (CPU load regulation): the decorative
          // loops used to run 60 fps forever (~a full core idle); this row lets
          // the user pick always / only-when-active / never.
          evsRow(context,
            stacked: true,
            label: app.t('motionMode'),
            desc: app.t('motionModeDesc'),
            control: evsSegmentedWide<String>(context,
              [
                ('full', app.t('motionFull')),
                ('balanced', app.t('motionBalanced')),
                ('saver', app.t('motionSaver')),
              ],
              app.motionMode,
              (v) => app.setMotionMode(v),
            ),
          ),
        ],
      )),
    ];
  }

  List<_CardSpec> _startupCards(AppState app) {
    return [
      _CardSpec(
        evsCard(
          context,
          icon: Icons.desktop_windows_outlined,
          title: app.t('cardStartup'),
          rows: [
            evsRow(context,
              stacked: true,
              label: app.t('startupView'),
              desc: app.t('startupViewDesc'),
              // Один выбор ставит оба флага сразу, поэтому тумблер «Плавающий
              // виджет» в «Виджетах и оверлее» не может с ним разойтись: он и
              // есть половина этого выбора.
              control: evsSegmentedWide<String>(context, [
                ('widget', app.t('startupViewWidget')),
                ('both', app.t('startupViewBoth')),
                ('window', app.t('startupViewWindow')),
                ('none', app.t('startupViewNone')),
              ], _startupView(app), (v) {
                app.setStartupView(
                  window: v == 'both' || v == 'window',
                  widget: v == 'both' || v == 'widget',
                );
              }),
            ),
            evsRow(context,
              label: app.t('autostart'),
              desc: app.t('autostartDesc'),
              control: evsToggle(context, app.autostart, (v) {
                app.setAutostart(v);
                DesktopIntegration.instance.applyAutostart(v);
              }),
            ),
            evsRow(context, 
              label: app.t('minimizeToTray'),
              desc: app.t('minimizeToTrayDesc'),
              control:
                  evsToggle(context, app.minimizeToTray, (v) => app.setMinimizeToTray(v)),
            ),
            evsRow(context, 
              label: app.t('closeToTray'),
              desc: app.t('closeToTrayDesc'),
              control: evsToggle(context, app.closeToTray, (v) => app.setCloseToTray(v)),
            ),
            evsRow(context, 
              label: app.t('globalHotkey'),
              desc: app.t('globalHotkeyDesc'),
              control: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _KeyCap('Ctrl'),
                  _KeySep(),
                  _KeyCap('Shift'),
                  _KeySep(),
                  _KeyCap('Space'),
                ],
              ),
            ),
          ],
        ),
        full: true,
      ),
    ];
  }

  Widget _stubToggle(String key) => evsToggle(context, 
        _stub[key] ?? false,
        (v) => setState(() => _stub[key] = v),
      );

  void _stubSnack(AppState app) =>
      showAppSnackBar(context, app.t('sectionStub'));

  Widget _sidecarChip(AppState app, SidecarStatus s) {
    final (label, color) = switch (s) {
      SidecarStatus.connected => (
          '${app.t('sidecarConnected')}'
              '${SidecarClient.instance.sttAvailable ? ' · ${sttEngineLabel(app)}' : ''}',
          _success(context)
        ),
      SidecarStatus.starting => (app.t('sidecarStarting'), _warn(context)),
      SidecarStatus.stopped => (app.t('sidecarStopped'), _danger(context)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 7),
          // Flexible + ellipsis so a long "Подключён · GigaAM-v3" degrades
          // gracefully in the narrow 3-column layout instead of hard-clipping
          // past the card edge (it still shows in full at 1–2 columns).
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _compBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
      );

  // Download/status control for the Python sidecar component (on-demand, not
  // bundled). Shows a download button when absent, progress while fetching,
  // and "installed" once present / the sidecar is connected.
  Widget _sidecarComponentControl(AppState app) {
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (_, ss, __) => ValueListenableBuilder<ComponentStatus>(
        valueListenable: ComponentManager.instance.statusOf('sidecar'),
        builder: (_, cs, __) {
          if (ss == SidecarStatus.connected) {
            return _compBadge(app.t('componentReady'), _success(context));
          }
          switch (cs.state) {
            case ComponentState.downloading:
              return SizedBox(
                width: 160,
                child: Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                      child: LinearProgressIndicator(
                        value: cs.progress > 0 ? cs.progress : null,
                        minHeight: 6,
                        backgroundColor: _stroke(context),
                        valueColor: const AlwaysStoppedAnimation(_evsGMid),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(cs.progress * 100).round()}%',
                      style: TextStyle(
                          fontSize: 12, color: _faint(context))),
                ]),
              );
            case ComponentState.verifying:
              return _compBadge(app.t('componentVerifying'), _warn(context));
            case ComponentState.ready:
              return _compBadge(
                  app.t('componentReady'), _success(context));
            case ComponentState.error:
              return evsGhostButton(context, app.t('retry'), Icons.refresh,
                  onTap: () => _downloadSidecar(app));
            case ComponentState.absent:
              final info = ComponentManager.instance.infoOf('sidecar');
              final mb = info != null && info.size > 0
                  ? ' (${(info.size / 1048576).round()} MB)'
                  : '';
              return evsGhostButton(context, '${app.t('download')}$mb', Icons.download,
                  onTap: () => _downloadSidecar(app));
          }
        },
      ),
    );
  }

  Future<void> _downloadSidecar(AppState app) async {
    final p = await ComponentManager.instance.ensure('sidecar');
    if (p != null) await SidecarClient.instance.start();
  }

  // In-app update flow control: check → silent download progress → "restart".
  Widget _updateControl(AppState app) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: AppUpdater.instance.status,
      builder: (_, st, __) {
        switch (st) {
          case UpdateStatus.checking:
            return const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2));
          case UpdateStatus.downloading:
            return SizedBox(
              width: 160,
              child: ValueListenableBuilder<double>(
                valueListenable: AppUpdater.instance.progress,
                builder: (_, p, __) => Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                      child: LinearProgressIndicator(
                        value: p > 0 ? p : null,
                        minHeight: 6,
                        backgroundColor: _stroke(context),
                        valueColor: const AlwaysStoppedAnimation(_evsGMid),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(p * 100).round()}%',
                      style: TextStyle(
                          fontSize: 12, color: _faint(context))),
                ]),
              ),
            );
          case UpdateStatus.ready:
            return evsGhostButton(context, 
                '${app.t('updRestart')} · ${AppUpdater.instance.availableVersion}',
                Icons.restart_alt,
                onTap: () => AppUpdater.instance.applyAndRestart());
          case UpdateStatus.upToDate:
            return InkWell(
              onTap: () => AppUpdater.instance.checkAndDownload(),
              child: _compBadge(app.t('updUpToDate'), _success(context)),
            );
          case UpdateStatus.error:
            return evsGhostButton(context, app.t('retry'), Icons.refresh,
                onTap: () => AppUpdater.instance.checkAndDownload());
          case UpdateStatus.idle:
            return evsGhostButton(context, app.t('checkUpdate'), Icons.refresh,
                onTap: () => AppUpdater.instance.checkAndDownload());
        }
      },
    );
  }

  Widget _inlineField(TextEditingController c,
      {bool mono = false, int maxLines = 1, ValueChanged<String>? onChanged}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 13, vertical: maxLines > 1 ? 10 : 0),
      height: maxLines > 1 ? null : 36,
      alignment: maxLines > 1 ? null : Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.06),
        border: Border.all(color: _stroke(context)),
      ),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        onChanged: onChanged,
        style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: _body(context),
            fontFamily: mono ? 'monospace' : null),
        decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero),
      ),
    );
  }

  // Editable server address (and optional API key) for the local-server /
  // remote connection modes — writes straight to AppState.serverUrl/apiKey.
  Widget _serverField(AppState app, {required String hint, bool withKey = false}) {
    Widget field(TextEditingController c, String hintText,
        ValueChanged<String> onChanged) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: _overlayFill(context, 0.04),
          border: Border.all(color: _stroke(context)),
        ),
        child: TextField(
          controller: c,
          onChanged: onChanged,
          style: TextStyle(fontSize: 12.5, color: _body(context)),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: hintText,
            hintStyle: TextStyle(fontSize: 12.5, color: _faint(context)),
          ),
        ),
      );
    }

    Widget saveBtn() => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => app.saveCurrentServer(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _stroke(context)),
              color: _stroke(context),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.bookmark_add_outlined,
                  size: 14, color: _sub(context)),
              const SizedBox(width: 5),
              Text(app.t('saveServerBtn'),
                  style: TextStyle(
                      fontSize: 11.5,
                      color: _sub(context),
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        );

    Widget chip(String s) {
      final active = s == app.serverUrl.trim();
      final accent = _accent(context);
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            _serverCtrl.text = s;
            app.selectSavedServer(s);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(11, 5, 6, 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: active
                  ? accent.withValues(alpha: 0.16)
                  : _overlayFill(context, 0.04),
              border: Border.all(
                  color: active ? accent.withValues(alpha: 0.5) : _stroke(context)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(s,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: active ? accent : _sub(context),
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 5),
              InkWell(
                onTap: () => app.removeSavedServer(s),
                borderRadius: BorderRadius.circular(10),
                child: const Icon(Icons.close,
                    size: 13, color: Color(0xFF7A8090)),
              ),
            ]),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(_serverCtrl, hint, (v) => app.setServer(v, app.apiKey)),
        if (withKey) ...[
          const SizedBox(height: 6),
          field(_apiKeyCtrl, app.t('apiKeyHint'),
              (v) => app.setServer(app.serverUrl, v)),
        ],
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: saveBtn()),
        if (app.savedServers.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final s in app.savedServers) chip(s)],
          ),
        ],
      ],
    );
  }

  // =================== КОМАНДЫ ===================
  List<_CardSpec> _cmdExecCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context, icon: Icons.bolt_outlined, title: app.t('cardCmdExec'), rows: [
          evsRow(context, 
            label: app.t('cmdAllow'),
            desc: app.t('cmdAllowDesc'),
            control: evsToggle(context, app.cmdEnabled, app.setCmdEnabled),
          ),
          evsRow(context, 
            label: app.t('chatToggle'),
            desc: app.t('chatToggleDesc'),
            control: evsToggle(context, app.chatEnabled, app.setChatEnabled),
          ),
        ]),
        full: true,
      ),
      _CardSpec(evsCard(context,
          icon: Icons.schedule, title: app.t('cardCmdRecognition'), rows: [
        evsRow(context, 
          stacked: true,
          label: app.t('cmdMode'),
          desc: app.t('cmdModeDesc'),
          control: evsSegmentedWide<String>(context, [
            ('wakeword', app.t('cmdModeWake')),
            ('separate', app.t('cmdModeSeparate')),
            ('first', app.t('cmdModeFirst')),
          ], app.cmdMode, app.setCmdMode),
        ),
        evsRow(context, 
          label: app.t('cmdActivator'),
          desc: app.t('cmdActivatorDesc'),
          control: SizedBox(
              width: 110,
              child: _inlineField(_activatorCtrl,
                  mono: true, onChanged: (v) => app.setWakeWord(v))),
        ),
        evsRow(context, 
          stacked: true,
          label: app.t('cmdStopWords'),
          desc: app.t('cmdStopWordsDesc'),
          control: _inlineField(_stopWordsCtrl,
              onChanged: (v) => app.setStopWords(v)),
        ),
      ])),
    ];
  }

  List<_CardSpec> _cmdSecurityCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.shield_outlined, title: app.t('cardSecurity'), rows: [
        evsRow(context, 
          label: app.t('cmdThreshold'),
          desc: app.t('cmdThresholdDesc'),
          control: evsSlider(context, 
            value: app.cmdThreshold * 100,
            min: 0,
            max: 100,
            divisions: 20,
            label: '${(app.cmdThreshold * 100).round()}%',
            onChanged: (v) => app.setCmdThreshold(v / 100),
          ),
        ),
        evsRow(context, 
          stacked: true,
          label: app.t('cmdConfirm'),
          control: evsSegmentedWide<String>(context, [
            ('always', app.t('cmdConfirmAlways')),
            ('risky', app.t('cmdConfirmRisky')),
            ('never', app.t('cmdConfirmNever')),
          ], app.cmdConfirm, app.setCmdConfirm),
        ),
      ])),
    ];
  }

  List<_CardSpec> _cmdCatalogCards(AppState app) {
    final cmds = app.voiceCommands;
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.format_list_bulleted, title: app.t('cardCatalog'), rows: [
          if (cmds.isEmpty)
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text(app.t('cmdEmpty'),
                  style: TextStyle(fontSize: 13, color: _faint(context))),
            ),
          for (final c in cmds) _cmdRow(app, c),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                evsAddButton(context, app.t('cmdAdd'), () => _openAddCommandWizard(app)),
                InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => _openSuggestCommands(app),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: _accent(context).withValues(alpha: 0.2)),
                      color: _accent(context).withValues(alpha: 0.1),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_awesome,
                          size: 14, color: _accent(context)),
                      const SizedBox(width: 6),
                      Text(app.t('cmdSuggest'),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _accent(context))),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ]),
        full: true,
      ),
    ];
  }

  Widget _cmdRow(AppState app, VoiceCommand c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context)))),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Row(children: [
                Flexible(
                  child: Text(c.phrase,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _body(context))),
                ),
                if (c.speakPhrase.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: c.speakPhrase,
                      child: const Icon(Icons.volume_up_outlined,
                          size: 13, color: Color(0xFF7A8090)),
                    ),
                  ),
              ])),
          Expanded(
              flex: 2,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: _cmdTypeChip(app, c.type))),
          Expanded(
              flex: 3,
              child: Text(c.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: _faint(context)))),
          InkResponse(
            radius: 18,
            onTap: () => _runCommand(app, c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: _accent(context).withValues(alpha: 0.15)),
              child: Icon(Icons.play_arrow_rounded,
                  size: 15, color: _accent(context)),
            ),
          ),
          InkResponse(
            radius: 18,
            onTap: () => _openEditCommandWizard(app, c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: _overlayFill(context, 0.06)),
              child: Icon(Icons.edit_outlined,
                  size: 13, color: _sub(context)),
            ),
          ),
          InkResponse(
            radius: 18,
            onTap: () => app.removeVoiceCommand(c),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0x14E05D5D)),
              child: const Icon(Icons.delete_outline,
                  size: 13, color: Color(0xFFE08080)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runCommand(AppState app, VoiceCommand c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: _card2(context),
        title: Text(app.t('cmdRunTitle'),
            style: TextStyle(color: _txt(context), fontSize: 16)),
        content: Text('${c.phrase}\n${c.value}',
            style: TextStyle(color: _body(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(app.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(app.t('run'))),
        ],
      ),
    );
    if (ok != true) return;
    // A test-run has no utterance, so app-volume uses the command's default
    // value; it also reports its own outcome (e.g. app not playing).
    if (c.type == VoiceCommandType.appVolume) {
      final (_, say) = await app.applyAppVolume(c, '');
      if (!mounted) return;
      showAppSnackBar(context, say);
      return;
    }
    final success = await CommandExecutor.instance.execute(c);
    if (!mounted) return;
    showAppSnackBar(context, success ? app.t('cmdRunOk') : app.t('cmdRunFail'));
  }

  Widget _cmdTypeChip(AppState app, VoiceCommandType t) {
    final (label, color) = switch (t) {
      VoiceCommandType.app => (app.t('typeApp'), _accent(context)),
      VoiceCommandType.file => (app.t('typeFile'), _info(context)),
      VoiceCommandType.url => (app.t('typeWeb'), _success(context)),
      VoiceCommandType.shell => ('Shell', _warn(context)),
      VoiceCommandType.system => (app.t('typeSystem'), _danger(context)),
      VoiceCommandType.media => (app.t('typeMedia'), _warn(context)),
      VoiceCommandType.appVolume => (app.t('typeAppVolume'), _info(context)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Future<void> _openAddCommandWizard(AppState app) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app),
    );
    if (cmd != null) app.addVoiceCommand(cmd);
  }

  // A quick-profile chip: tap applies it, the pencil (or a long press) edits
  // what it changes. The active profile is outlined in the accent colour and
  // its description is rendered from the CURRENT config, so an edited profile
  // never advertises settings it no longer applies.
  Widget _presetChip(AppState app, String id, String nameKey, IconData icon) {
    final active = app.activeVoicePreset == id;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        app.applyVoicePreset(id);
        showAppSnackBar(context,
            app.t('presetApplied').replaceAll('{name}', app.t(nameKey)));
      },
      onLongPress: () => _editPreset(app, id, nameKey),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: active
              ? _accent(context).withValues(alpha: 0.14)
              : _overlayFill(context, 0.05),
          border: Border.all(
              color: active ? _accent(context) : _stroke(context),
              width: active ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(active ? Icons.check_circle : icon,
              size: 15, color: _accent(context)),
          const SizedBox(width: 7),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(app.t(nameKey),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
              Text(app.presetDescription(id),
                  style: TextStyle(fontSize: 10.5, color: _faint(context))),
            ],
          ),
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _editPreset(app, id, nameKey),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child:
                  Icon(Icons.edit_outlined, size: 14, color: _faint(context)),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _editPreset(AppState app, String id, String nameKey) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PresetEditDialog(
        app: app,
        id: id,
        nameKey: nameKey,
        initial: Map<String, dynamic>.from(app.presetConfig(id)),
      ),
    );
    if (res != null) app.setVoicePreset(id, res);
  }

  Future<void> _openSuggestCommands(AppState app) async {
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _SuggestCommandsDialog(app),
    );
    if (n != null && n > 0 && mounted) {
      showAppSnackBar(
          context, app.t('cmdSuggestSaved').replaceAll('{n}', '$n'));
    }
  }

  Future<void> _openEditCommandWizard(AppState app, VoiceCommand existing) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app, initial: existing),
    );
    if (cmd != null) app.replaceVoiceCommand(existing, cmd);
  }

  // =================== ВИДЖЕТЫ ===================
  // Look of the voice visualization (adapted from the user-provided
  // widgets-settings mock): live preview with a voice simulation, style
  // tiles, per-style parameters, plus the floating-overlay controls.
  List<_CardSpec> _widgetLookCards(AppState app) {
    final accent = Color(app.vizAccent);
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.auto_awesome_outlined,
            title: app.t('cardWsPreview'),
            rows: [const _VizPreviewCard()]),
        full: true,
      ),
      _CardSpec(
        evsCard(context,
            icon: Icons.style_outlined,
            title: app.t('cardWsStyle'),
            rows: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (key, label) in [
                      ('sphere', app.t('vizSphere')),
                      ('waves', app.t('vizWaves')),
                      ('bars', app.t('vizBars')),
                      ('orb', app.t('vizOrb')),
                      ('lkbars', app.t('vizLkBars')),
                      ('wave3d', app.t('vizWave3d')),
                      ('waveflat', app.t('vizWaveFlat')),
                      ('none', app.t('vizNone')),
                    ])
                      _VizStyleTile(
                        label: label,
                        selected: app.vizType == key,
                        accent: accent,
                        preview: _vizMini(key, accent),
                        onTap: () => app.setVizType(key),
                      ),
                  ],
                ),
              ),
            ]),
        full: true,
      ),
    ];
  }

  List<_CardSpec> _widgetParamCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.tune, title: app.t('cardWsParams'), rows: [
        evsRow(context, 
          label: app.t('wsAccent'),
          desc: app.t('wsAccentDesc'),
          control: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final c in const [
              0xFFCC785C,
              0xFF4FC3F7,
              0xFFFF5FA8,
              0xFF34D399,
              0xFFFFB020,
              0xFFF04E4E,
            ])
              GestureDetector(
                onTap: () => app.setVizAccent(c),
                child: Container(
                  margin: const EdgeInsets.only(left: 9),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: app.vizAccent == c
                            ? _txt(context)
                            : Colors.transparent,
                        width: 2),
                    boxShadow: app.vizAccent == c
                        ? [
                            BoxShadow(
                                color: Color(c).withValues(alpha: 0.45),
                                blurRadius: 8)
                          ]
                        : null,
                  ),
                ),
              ),
          ]),
        ),
        if (app.vizType == 'orb') ...[
          evsNamedSlider(context, 
            label: app.t('wsOrbSize'),
            value: app.orbSize.clamp(120, 320),
            min: 120,
            max: 320,
            valueLabel: '${app.orbSize.round()} px',
            left: '120',
            right: '320',
            onChanged: (v) => app.setOrbSize(v),
          ),
          evsNamedSlider(context, 
            label: app.t('wsOrbSpeed'),
            desc: app.t('wsOrbSpeedDesc'),
            value: app.orbSpeed.clamp(6, 40),
            min: 6,
            max: 40,
            valueLabel: '${app.orbSpeed.round()} ${app.t('secShort')}',
            left: app.t('wsFast'),
            right: app.t('wsSlow'),
            onChanged: (v) => app.setOrbSpeed(v),
          ),
        ],
        if (app.vizType == 'lkbars')
          evsNamedSlider(context, 
            label: app.t('wsBarCount'),
            value: app.barCount.toDouble().clamp(3, 13),
            min: 3,
            max: 13,
            valueLabel: '${app.barCount}',
            left: '3',
            right: '13',
            onChanged: (v) => app.setBarCount(v.round()),
          ),
        evsRow(context, 
          label: app.t('showVizBg'),
          desc: app.t('showVizBgDesc'),
          control: evsToggle(context, app.showVizBg, app.setShowVizBg),
        ),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.picture_in_picture_alt_outlined,
          title: app.t('ovlEnter'),
          rows: [
            evsRow(context, 
              label: app.t('ovlShow'),
              desc: app.t('ovlEnterDesc'),
              control: evsToggle(context, app.overlayMode, app.setOverlayMode),
            ),
            evsRow(context, 
              stacked: true,
              label: app.t('ovlSize'),
              desc: app.t('ovlSizeDesc'),
              control: evsSegmentedWide<double>(context, [
                (200.0, app.t('ovlSizeS')),
                (260.0, app.t('ovlSizeM')),
                (330.0, app.t('ovlSizeL')),
              ], app.overlaySize, app.setOverlaySize),
            ),
          ])),
    ];
  }

  // Small static-ish thumbnail for a style tile.
  Widget _vizMini(String key, Color accent) {
    switch (key) {
      case 'waves':
        return const EvsRingViz(size: 52);
      case 'bars':
        return const EvsBarsViz(width: 62, height: 38);
      case 'orb':
        return SiriOrb(
            size: 48,
            level: 0.4,
            state: SiriOrbState.listening,
            colors: evsOrbColors(accent),
            glow: false);
      case 'lkbars':
        return LkBarVisualizer(
            level: 0.5,
            count: 5,
            color: accent,
            barWidth: 5,
            spacing: 3.5,
            minHeight: 5,
            maxHeight: 34);
      case 'wave3d':
        return const EvsWaveViz(
            kind: 'wave3d',
            size: 52,
            numCols: 46,
            numRows: 30,
            background: Color(0xFF060612));
      case 'waveflat':
        return const EvsWaveViz(
            kind: 'waveflat',
            size: 52,
            particleCount: 520,
            background: Color(0xFF04040A));
      case 'none':
        return Icon(Icons.hide_source,
            size: 26, color: _faint(context));
      default:
        return ParticleSphere(
            size: 46,
            color: _accent(context),
            soundLevel: VoiceLevels.instance.tts);
    }
  }

  // =================== МОДЕЛЬ И ИНФЕРЕНС ===================
  // Desktop is remote-only by design: models come from a local server
  // (Ollama) or a remote API endpoint. On-device GGUF inference was removed
  // from the UI (the fllama engine code stays dormant in the codebase).
  List<_CardSpec> _llmPresetCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.tune, title: app.t('cardPresets'), rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text(app.t('presetsDesc'),
                style: TextStyle(fontSize: 12, color: _faint(context))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _presetChip(app, 'fast', 'presetFast', Icons.bolt_outlined),
                _presetChip(app, 'quality', 'presetQuality', Icons.hd_outlined),
                _presetChip(app, 'search', 'presetSearch', Icons.travel_explore),
                _presetChip(
                    app, 'chat', 'presetChat', Icons.chat_bubble_outline),
              ],
            ),
          ),
          // Restore the built-in profile definitions (only offered once at
          // least one profile has been edited).
          if (app.presetsCustomized)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(children: [
                evsGhostButton(context, app.t('presetsReset'), Icons.restore,
                    onTap: () {
                  app.resetVoicePresets();
                  showAppSnackBar(context, app.t('presetsResetDone'));
                }),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(app.t('presetsCustomHint'),
                      style:
                          TextStyle(fontSize: 11, color: _faint(context))),
                ),
              ]),
            ),
        ]),
        full: true,
      ),
    ];
  }

  List<_CardSpec> _llmAssetCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.dns_outlined,
            title: app.t('cardModels'),
            rows: [_AssetModelsCard(app)]),
        full: true,
      ),
    ];
  }

  List<_CardSpec> _llmConnCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context, icon: Icons.wifi, title: app.t('cardConnMode'), rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Column(
              children: [
                evsRadioCard(context, 
                  selected: app.inferenceMode == 'localServer',
                  title: app.t('modeLocalServer'),
                  desc: app.t('modeLocalServerDesc'),
                  onTap: () => app.setInferenceMode('localServer'),
                  extra: app.inferenceMode == 'localServer'
                      ? _serverField(app, hint: 'localhost:11434')
                      : null,
                ),
                const SizedBox(height: 8),
                evsRadioCard(context, 
                  selected: app.inferenceMode == 'remote',
                  title: app.t('modeRemote'),
                  desc: app.t('modeRemoteDesc'),
                  onTap: () => app.setInferenceMode('remote'),
                  extra: app.inferenceMode == 'remote'
                      ? _serverField(app,
                          hint: 'https://api.openai.com/v1', withKey: true)
                      : null,
                ),
              ],
            ),
          ),
          _ConnCheckRow(app),
        ]),
        full: true,
      ),
      _CardSpec(
        evsCard(context,
            icon: Icons.travel_explore,
            title: app.t('webSearch'),
            rows: [const _WebSearchCard()]),
        full: true,
      ),
      _CardSpec(evsCard(context,
          icon: Icons.memory, title: app.t('cardModelPick'), rows: [
        if (app.models.isEmpty)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text(app.t('noModelsYet'),
                style: TextStyle(fontSize: 13, color: _faint(context))),
          ),
        for (final m in app.models)
          _modelRow(app, m, app.modelDisplayName(m, withSuffix: false), ''),
        _ConnCheckRow(app, showRefresh: true),
        if (app.models.isNotEmpty) _ModelModeCard(app),
        _LlmAdvancedCard(app),
      ])),
    ];
  }

  List<_CardSpec> _llmGenCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.tune, title: app.t('cardGenParams'), rows: [
        evsNamedSlider(context, 
          label: 'Temperature',
          desc: app.t('temperatureDesc'),
          value: _stubNum['temp']!,
          min: 0,
          max: 2,
          valueLabel: _stubNum['temp']!.toStringAsFixed(2),
          left: '0.0',
          right: '2.0',
          onChanged: (v) => setState(() => _stubNum['temp'] = v),
        ),
        evsNamedSlider(context, 
          label: 'Top-p',
          desc: app.t('topPDesc'),
          value: _stubNum['topp']!,
          min: 0,
          max: 1,
          valueLabel: _stubNum['topp']!.toStringAsFixed(2),
          left: '0.0',
          right: '1.0',
          onChanged: (v) => setState(() => _stubNum['topp'] = v),
        ),
      ])),
    ];
  }

  Widget _modelRow(AppState app, String key, String name, String size) {
    final active = app.selectedModel == key;
    return InkWell(
      onTap: () => app.selectModel(key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _stroke(context)))),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _accent(context) : Colors.transparent,
                border: Border.all(
                    color: active ? _accent(context) : const Color(0x33FFFFFF),
                    width: 2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(name,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: _body(context))),
            ),
            if (size.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: _overlayFill(context, 0.06)),
                child: Text(size,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _sectionLabel(context))),
              ),
            const SizedBox(width: 8),
            Text(active ? app.t('modelActive') : '',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: _accent(context))),
          ],
        ),
      ),
    );
  }

  // =================== ЛИЧНОСТЬ И ПАМЯТЬ ===================
  List<_CardSpec> _personaStyleCards(AppState app) {
    final p = app.persona;
    String pct(double v) => '${(v * 100).round()}%';
    return [
      _CardSpec(evsCard(context,
          icon: Icons.chat_bubble_outline, title: app.t('cardStyle'), rows: [
        evsNamedSlider(context, 
          label: app.t('formality'),
          value: p.formality,
          valueLabel: pct(p.formality),
          left: app.t('formalLeft'),
          right: app.t('formalRight'),
          onChanged: (v) => _persona((x) => x.formality = v),
        ),
        evsNamedSlider(context, 
          label: app.t('empathy'),
          value: p.empathy,
          valueLabel: pct(p.empathy),
          left: app.t('empathyLeft'),
          right: app.t('empathyRight'),
          onChanged: (v) => _persona((x) => x.empathy = v),
        ),
        evsNamedSlider(context, 
          label: app.t('verbosity'),
          value: p.verbosity,
          valueLabel: pct(p.verbosity),
          left: app.t('verbosityLeft'),
          right: app.t('verbosityRight'),
          onChanged: (v) => _persona((x) => x.verbosity = v),
        ),
        evsNamedSlider(context, 
          label: app.t('humor'),
          value: p.humor,
          valueLabel: pct(p.humor),
          left: app.t('humorLeft'),
          right: app.t('humorRight'),
          onChanged: (v) => _persona((x) => x.humor = v),
        ),
        evsNamedSlider(context, 
          label: app.t('creativity'),
          value: p.creativity,
          valueLabel: pct(p.creativity),
          left: app.t('creativityLeft'),
          right: app.t('creativityRight'),
          onChanged: (v) => _persona((x) => x.creativity = v),
        ),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.person_outline, title: app.t('cardAssistant'), rows: [
        evsRow(context, 
          label: app.t('assistantNameLabel'),
          desc: app.t('assistantNameDesc'),
          control: SizedBox(
            width: 130,
            child: _inlineField(_nameCtrl,
                mono: true,
                onChanged: (v) => _persona((x) => x.assistantName = v)),
          ),
        ),
        evsRow(context, 
          stacked: true,
          label: app.t('emojiPolicy'),
          desc: app.t('emojiPolicyDesc'),
          control: evsSegmentedWide<String>(context, 
            [
              ('emoji_never', app.t('emojiNever')),
              ('emoji_sometimes', app.t('emojiSometimes')),
              ('emoji_always', app.t('emojiAlways')),
            ],
            p.emoji,
            (v) => _persona((x) => x.emoji = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.t('systemPrompt'),
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
              const SizedBox(height: 2),
              Text(app.t('systemPromptDesc'),
                  style: TextStyle(fontSize: 12, color: _faint(context))),
              const SizedBox(height: 8),
              _inlineField(_promptCtrl,
                  maxLines: 3,
                  onChanged: (v) => _persona((x) => x.customPrompt = v)),
            ],
          ),
        ),
      ])),
    ];
  }

  List<_CardSpec> _personaMemoryCards(AppState app) {
    final p = app.persona;
    return [
      _CardSpec(
        evsCard(context, icon: Icons.access_time, title: app.t('cardMemory'), rows: [
          evsRow(context, 
            label: app.t('autoSaveFacts'),
            desc: app.t('autoSaveFactsDesc'),
            control: evsToggle(context, 
                p.autoSaveMemories, (v) => _persona((x) => x.autoSaveMemories = v)),
          ),
          evsRow(context, 
            label: app.t('askBeforeRemember'),
            desc: app.t('askBeforeRememberDesc'),
            control: evsToggle(context, p.askBeforeRemembering,
                (v) => _persona((x) => x.askBeforeRemembering = v)),
          ),
          for (final m in p.savedMemories) _memItem(app, m),
          if (p.savedMemories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: evsDangerButton(context, app.t('clearMemory'),
                    () => _persona((x) => x.savedMemories.clear())),
              ),
            ),
        ]),
        full: true,
      ),
    ];
  }

  Widget _memItem(AppState app, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context)))),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _accent(context).withValues(alpha: 0.12)),
            child: Icon(Icons.place_outlined, size: 12, color: _accent(context)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: _body(context))),
          ),
          InkResponse(
            radius: 16,
            onTap: () => _persona((x) => x.savedMemories.remove(text)),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  color: const Color(0x14E05D5D)),
              child: const Icon(Icons.close, size: 11, color: Color(0xFFE08080)),
            ),
          ),
        ],
      ),
    );
  }

  // =================== ПРИВАТНОСТЬ ===================
  List<_CardSpec> _privacyAccessCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.shield_outlined, title: app.t('cardCmdScope'), rows: [
        _permGrid(app, [
          ('permFiles', app.t('permFiles')),
          ('permBrowser', app.t('permBrowser')),
          ('permMedia', app.t('permMedia')),
          ('permSystem', app.t('permSystem')),
          ('permNetwork', app.t('permNetwork')),
          ('permRegistry', app.t('permRegistry')),
        ]),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.dns_outlined, title: app.t('cardNetSec'), rows: [
        evsRow(context, 
            label: app.t('offlineMode'),
            desc: app.t('offlineModeDesc'),
            control: _stubToggle('offline')),
        evsRow(context, 
            label: app.t('noTelemetry'),
            desc: app.t('noTelemetryDesc'),
            control: _stubToggle('noTelemetry')),
        evsRow(context, 
            label: app.t('noModelNet'),
            desc: app.t('noModelNetDesc'),
            control: _stubToggle('noModelNet')),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.warning_amber_outlined, title: app.t('cardBlacklist'), rows: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _blacklist) _tag(t),
              evsAddButton(context, app.t('add'),
                  () => _stubSnack(app), small: true),
            ],
          ),
        ),
      ])),
    ];
  }

  List<_CardSpec> _privacyDataCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context, icon: Icons.delete_outline, title: app.t('cardData'), rows: [
          evsRow(context, 
            label: app.t('clearHistory'),
            desc: app.t('clearHistoryDesc'),
            control: evsDangerButton(context, app.t('clearHistory'), () => _stubSnack(app)),
          ),
          evsRow(context, 
            label: app.t('resetMemory'),
            desc: app.t('resetMemoryDesc'),
            control: evsDangerButton(context, app.t('resetMemory'), () {
              _persona((x) {
                x.savedMemories.clear();
                x.memoryNote = '';
              });
            }),
          ),
          evsRow(context, 
            label: app.t('resetAll'),
            desc: app.t('resetAllDesc'),
            control: evsDangerButton(context, app.t('fullReset'), () => _stubSnack(app)),
          ),
        ]),
        full: true,
      ),
    ];
  }

  Widget _permGrid(AppState app, List<(String, String)> items) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        // Two columns that always fit the card; one column on a very narrow pane.
        final w = cons.maxWidth < 360 ? cons.maxWidth : cons.maxWidth / 2;
        return Wrap(
          children: [
            for (final it in items)
              SizedBox(
                width: w,
                child: InkWell(
                  onTap: () => setState(
                      () => _stub[it.$1] = !(_stub[it.$1] ?? false)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: (_stub[it.$1] ?? false)
                                ? _accent(context).withValues(alpha: 0.3)
                                : Colors.transparent,
                            border: Border.all(
                                color: _accent(context).withValues(alpha: 0.4), width: 2),
                          ),
                          child: (_stub[it.$1] ?? false)
                              ? Icon(Icons.check,
                                  size: 12, color: _accent(context))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(it.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: _body(context))),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: _overlayFill(context, 0.06),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _sub(context))),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _blacklist.remove(text)),
            child: Icon(Icons.close, size: 13, color: _faint(context)),
          ),
        ],
      ),
    );
  }

  // =================== О ПРОГРАММЕ ===================
  List<_CardSpec> _aboutInfoCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context, icon: Icons.info_outline, title: app.t('navAbout'), rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
            child: Column(
              children: [
                // Genesis (вариант 05) — знак живой, с интро при каждом входе
                // на страницу; под ним локап, как в варианте 04 образца.
                // Гейт переднего плана: страницу открывают, чтобы посмотреть
                // именно на знак, поэтому луп идёт бесконечно, пока окно видно,
                // и не ждёт активности ассистента.
                const _EvsLogoMark(size: 96, gate: MotionGate.foreground),
                const SizedBox(height: 12),
                Text('EVS',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: _txt(context))),
                const SizedBox(height: 4),
                Text('Enhanced Voice System',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _faint(context))),
              ],
            ),
          ),
          _aboutRow(app.t('versionLabel'), const _VersionText()),
          _aboutRow(app.t('platform'), Text('Windows · x64',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: _body(context)))),
        ]),
        full: true,
      ),
    ];
  }

  // =================== ЖУРНАЛ ===================
  // Тот же журнал, что на вкладке «Журнал» в «Ноктюрне», и те же файлы: читает
  // EvsLogFeed. Отсюда его берут классический стиль и Nexus (кнопка «Журнал» в
  // рейле раньше открывала список изменений — то есть журнал патчей вместо
  // журнала работы).
  List<_CardSpec> _appLogCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.receipt_long_outlined,
            title: app.t('navLog'),
            rows: [const _AppLogCard()]),
        full: true,
      ),
    ];
  }

  List<_CardSpec> _changelogCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.description_outlined, title: app.t('changelog'), rows: [
        // The changelog is a page of its own now, so it can list far more than
        // the three entries that used to fit next to the version card.
        for (final e in kChangelog.take(12)) _clItem(e),
      ])),
    ];
  }

  List<_CardSpec> _aboutUpdateCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.refresh, title: app.t('updates'), rows: [
        evsRow(context, 
            label: app.t('autoCheck'),
            desc: app.t('autoCheckDesc'),
            control: evsToggle(context, app.autoUpdateCheck, app.setAutoUpdateCheck)),
        evsRow(context, 
            label: app.t('checkNow'),
            desc: app.t('updFlowDesc'),
            control: _updateControl(app)),
      ])),
    ];
  }

  Widget _aboutRow(String label, Widget value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context)))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _body(context))),
          value,
        ],
      ),
    );
  }

  Widget _clItem(ChangelogEntry e) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.version,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: _body(context))),
          const SizedBox(height: 5),
          for (final ch in e.changes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('·  $ch',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.5, color: _faint(context))),
            ),
        ],
      ),
    );
  }


  // =================== МИКРОФОН И ГОЛОС ===================
  // ---- Микрофон и распознавание ----
  List<_CardSpec> _sttCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.mic_none,
        title: app.t('cardStt'),
        rows: [
          evsRow(context, 
            label: app.t('sidecar'),
            desc: app.t('sidecarDesc'),
            control: ValueListenableBuilder<SidecarStatus>(
              valueListenable: SidecarClient.instance.status,
              builder: (_, s, __) => _sidecarChip(app, s),
            ),
          ),
          evsRow(context, 
            label: app.t('sidecarComponent'),
            desc: app.t('sidecarComponentDesc'),
            control: _sidecarComponentControl(app),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('sttEngine'),
            desc: app.t('sttEngineDesc'),
            control: evsSegmentedWide<String>(context, 
              [('windows', 'Windows STT'), ('whisper', app.t('localEngineName'))],
              app.sttEngine,
              (v) => app.setSttEngine(v),
            ),
          ),
          // The local engine (whisper|gigaam) picker only applies to the local
          // backend — hidden when Windows STT is chosen so GigaAM/Whisper aren't
          // shown as "models" under an unrelated engine.
          if (app.sttEngine == 'whisper') ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(app.t('cardSttModel'),
                  style: TextStyle(
                      color: _body(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
            _SttEngineCards(app),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(app.t('cardDenoise'),
                style: TextStyle(
                    color: _body(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
          _DenoiseSelector(app),
          evsRow(context,
            stacked: true,
            label: app.t('micSensitivity'),
            desc: app.t('micSensitivityDesc'),
            control: evsSegmentedWide<int>(context,
              [
                (3, app.t('micSensLow')),
                (2, app.t('micSensMed')),
                (1, app.t('micSensHigh')),
                (0, app.t('micSensMax')),
              ],
              app.micVadAggr,
              (v) => app.setMicVadAggr(v),
            ),
          ),
          evsRow(context,
            label: app.t('micGain'),
            desc: app.t('micGainDesc'),
            control: evsSlider(context,
              value: app.micGain.clamp(0.5, 4.0),
              min: 0.5,
              max: 4.0,
              divisions: 14,
              label: '${app.micGain.toStringAsFixed(1)}x',
              onChanged: (v) => app.setMicGain(v),
            ),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('recognitionLanguage'),
            desc: app.t('recognitionLanguageDesc'),
            control: evsSegmentedWide<String>(context, 
              [('auto', app.t('sttAuto')), ('ru', 'RU'), ('en', 'EN')],
              app.sttLanguage,
              (v) => app.setSttLanguage(v),
            ),
          ),
          // Recognition test lives inside the STT card (was a separate
          // full-width card, which broke the 2-column grid packing and made
          // the section jump).
          const _SttTestCard(),
        ],
      )),
    ];
  }

  List<_CardSpec> _micDeviceCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.settings_voice_outlined,
        title: app.t('cardInputDevice'),
        rows: [
          evsRow(context, 
            label: app.t('inputDevice'),
            desc: app.t('inputDeviceDesc'),
            control: _inputDeviceControl(app),
          ),
          evsRow(context, 
            label: app.t('inputLevel'),
            control: SizedBox(
              width: 180,
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(3)),
                child: ValueListenableBuilder<double>(
                  valueListenable: MicMeter.instance.level,
                  builder: (_, lvl, __) => LinearProgressIndicator(
                    value: lvl.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: _stroke(context),
                    valueColor: const AlwaysStoppedAnimation(_evsGMid),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Text(app.t('extraMics'),
                style: TextStyle(
                    color: _body(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
            child: Text(app.t('extraMicsDesc'),
                style: TextStyle(color: _faint(context), fontSize: 12)),
          ),
          _MultiMicCard(app),
        ],
      )),
    ];
  }

  List<_CardSpec> _listenCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.headset_mic_outlined,
        title: app.t('cardListenMode'),
        rows: [
          evsRow(context, 
            stacked: true,
            label: app.t('activationMode'),
            desc: app.t('activationModeDesc'),
            control: evsSegmentedWide<String>(context,
              [('continuous', app.t('continuous')), ('ptt', 'Push-to-Talk')],
              app.listenMode,
              (v) => app.setListenMode(v),
            ),
          ),
          // Область назначения клавиш появляется только у Push-to-Talk: в
          // непрерывном режиме удерживать нечего.
          if (app.listenMode == 'ptt') ...[
            evsRow(context,
              stacked: true,
              label: app.t('pttKeysLabel'),
              desc: app.t('pttKeysDesc'),
              control: _PttHotkeyRow(app),
            ),
            _PttNote(app.t('pttNoWake')),
            _PttNote(app.t('pttPassthrough')),
            if (_pttConflictsWithShowWindow(app))
              _PttNote(app.t('pttConflict'), danger: true),
          ],
          evsRow(context,
            label: app.t('autoSendPause'),
            desc: app.t('autoSendPauseDesc'),
            control: evsToggle(context, app.micAutoSend, (v) => app.setMicAutoSend(v)),
          ),
          evsRow(context, 
            label: app.t('pauseDuration'),
            desc: app.t('pauseDurationDesc'),
            control: evsSlider(context, 
              value: app.micPauseSeconds.toDouble().clamp(1, 10),
              min: 1,
              max: 10,
              divisions: 9,
              label: '${app.micPauseSeconds} ${app.t('secShort')}',
              onChanged: (v) => app.setMicPauseSeconds(v.round()),
            ),
          ),
          evsRow(context, 
            label: app.t('showPartial'),
            desc: app.t('showPartialDesc'),
            control: evsToggle(context, app.showPartial, app.setShowPartial),
          ),
        ],
      )),
    ];
  }

  // Окно и виджет — два независимых флага; карточка показывает их пару одним
  // выбором, чтобы «окно и виджет вместе» вообще стало выразимым.
  String _startupView(AppState app) {
    if (app.startupShowWindow) return app.overlayMode ? 'both' : 'window';
    return app.overlayMode ? 'widget' : 'none';
  }

  // Комбинация показа окна (Ctrl+Shift+Space) захардкожена в DesktopIntegration
  // и перехватывается системно: назначив её же на удержание, пользователь при
  // каждой попытке заговорить открывал бы окно.
  bool _pttConflictsWithShowWindow(AppState app) {
    const showWindow = [0x11, 0x10, 0x20]; // VK_CONTROL, VK_SHIFT, VK_SPACE
    if (app.pttKeys.length != showWindow.length) return false;
    return showWindow.every(app.pttKeys.contains);
  }

  // ---- Голос ассистента ----
  //
  // This used to be ONE card ("Голосовые ответы") holding the on/off toggles,
  // the engine picker, the entire clone block, the GPU-load knobs, the
  // interpreter and five FX sliders. A card cannot be split across masonry
  // columns, so it grew into the endless middle column. Now each concern is
  // its own page.
  List<_CardSpec> _voiceOutCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.record_voice_over_outlined,
        title: app.t('cardVoiceResp'),
        rows: [
          evsRow(context,
            label: app.t('voiceResponses'),
            desc: app.t('voiceResponsesDesc'),
            control: evsToggle(context, app.voiceResponses, app.setVoiceResponses),
          ),
          evsRow(context,
            label: app.t('announceReady'),
            desc: app.t('announceReadyDesc'),
            control: evsToggle(context, app.announceReady, app.setAnnounceReady),
          ),
          evsRow(context,
            label: app.t('ttsRate'),
            desc: app.t('ttsRateDesc'),
            control: evsSlider(context,
              value: app.ttsRate.clamp(0.5, 2.0),
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${app.ttsRate.toStringAsFixed(1)}x',
              onChanged: (v) => app.setTtsRate(v),
            ),
          ),
          evsRow(context,
            label: app.t('ttsVolume'),
            control: evsSlider(context,
              value: (app.ttsVolume * 100).clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 20,
              label: '${(app.ttsVolume * 100).round()}%',
              onChanged: (v) => app.setTtsVolume(v / 100),
            ),
          ),
        ],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.record_voice_over_outlined,
        title: app.t('cardAssistantVoice'),
        rows: [_AssistantVoiceCard(app)],
      )),
    ];
  }

  List<_CardSpec> _voiceEngineCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.graphic_eq,
        title: app.t('ttsEngineTitle'),
        rows: [_TtsEngineCard(app)],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.text_fields,
        title: app.t('ttsInterp'),
        rows: [_TtsInterpCard(app)],
      )),
    ];
  }

  List<_CardSpec> _voiceCloneCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.graphic_eq,
        title: app.t('ttsCosySectionTitle'),
        rows: [_TtsCloneCard(app)],
      )),
      // Game mode belongs next to the GPU-load profile: both answer "what
      // happens while a game is running".
      _CardSpec(_GameModeCard(app)),
    ];
  }

  List<_CardSpec> _voiceFxCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.auto_fix_high_outlined,
        title: app.t('ttsFx'),
        rows: [
          evsRow(context,
            label: app.t('ttsFx'),
            desc: app.t('ttsFxDesc'),
            control: evsToggle(context, app.ttsFxEnabled, (v) => app.setTtsFx(enabled: v)),
          ),
          if (app.ttsFxEnabled) ...[
            evsRow(context,
              label: app.t('ttsFxPreset'),
              desc: app.t('ttsFxPresetDesc'),
              control: evsAddButton(context, 'EDI', () => app.applyEdiPreset(), icon: Icons.smart_toy_outlined),
            ),
            evsNamedSlider(context,
              label: app.t('ttsFxDetune'),
              desc: app.t('ttsFxDetuneDesc'),
              value: app.ttsFxDetune,
              valueLabel: '${(app.ttsFxDetune * 100).round()}%',
              onChanged: (v) => app.setTtsFx(detune: v),
            ),
            evsNamedSlider(context,
              label: app.t('ttsFxMetallic'),
              value: app.ttsFxMetallic,
              valueLabel: '${(app.ttsFxMetallic * 100).round()}%',
              onChanged: (v) => app.setTtsFx(metallic: v),
            ),
            evsNamedSlider(context,
              label: app.t('ttsFxReverb'),
              value: app.ttsFxReverb,
              valueLabel: '${(app.ttsFxReverb * 100).round()}%',
              onChanged: (v) => app.setTtsFx(reverb: v),
            ),
            evsNamedSlider(context,
              label: app.t('ttsFxBright'),
              desc: app.t('ttsFxBrightDesc'),
              value: (app.ttsFxLowpass - 800) / 5200,
              valueLabel: '${app.ttsFxLowpass} Hz',
              onChanged: (v) => app.setTtsFx(lowpass: (800 + v * 5200).round()),
            ),
          ],
        ],
      )),
    ];
  }

  List<_CardSpec> _voicePhraseCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.playlist_play,
        title: app.t('clonePhr2Title'),
        rows: [_ClonePhrasesCard(app)],
      )),
    ];
  }
}

// Пояснение под строкой настройки — там, где предупредить важнее, чем
// уместиться в подпись самой строки.
class _PttNote extends StatelessWidget {
  const _PttNote(this.text, {this.danger = false});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 9, 18, 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context))),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(danger ? Icons.error_outline : Icons.info_outline,
              size: 15, color: danger ? _danger(context) : _faint(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: EvsType.caption.copyWith(
                    color: danger ? _danger(context) : _sub(context))),
          ),
        ]),
      );
}

// Запись комбинации Push-to-Talk. Своя, а не HotKeyRecorder из hotkey_manager:
// тот собирает HotKey, которому обязательно нужна не-модификаторная клавиша, а
// на удержание вполне разумно повесить один голый Shift.
class _PttHotkeyRow extends StatefulWidget {
  const _PttHotkeyRow(this.app);
  final AppState app;
  @override
  State<_PttHotkeyRow> createState() => _PttHotkeyRowState();
}

class _PttHotkeyRowState extends State<_PttHotkeyRow> {
  static const int _maxKeys = 3;
  final FocusNode _node = FocusNode(debugLabel: 'ptt-recorder');
  bool _rec = false;
  List<PhysicalKeyboardKey> _best = const [];

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  // Модификаторы впереди — «Ctrl + Shift + G» читается, «G + Ctrl + Shift» нет.
  static int _rank(PhysicalKeyboardKey k) => switch (pttKeyLabel(k)) {
        'Ctrl' => 0,
        'Shift' => 1,
        'Alt' => 2,
        'Win' => 3,
        _ => 4,
      };

  void _start() {
    setState(() {
      _rec = true;
      _best = const [];
    });
    _node.requestFocus();
  }

  void _cancel() {
    setState(() {
      _rec = false;
      _best = const [];
    });
    _node.unfocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (!_rec) return KeyEventResult.ignored;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    final down = HardwareKeyboard.instance.physicalKeysPressed.toList()
      ..sort((a, b) {
        final r = _rank(a).compareTo(_rank(b));
        return r != 0 ? r : a.usbHidUsage.compareTo(b.usbHidUsage);
      });
    // Запоминаем самый полный аккорд: пальцы сходят с клавиш не одновременно,
    // и по последнему событию комбинация всегда оказалась бы короче.
    if (down.length > _best.length) {
      setState(() => _best = down.take(_maxKeys).toList());
    }
    if (down.isEmpty && _best.isNotEmpty) _commit();
    return KeyEventResult.handled;
  }

  void _commit() {
    final vks = <int>[];
    final labels = <String>[];
    for (final k in _best) {
      final vk = pttVkFor(k);
      if (vk == null || vk == 0 || vks.contains(vk)) continue;
      vks.add(vk);
      labels.add(pttKeyLabel(k));
    }
    setState(() {
      _rec = false;
      _best = const [];
    });
    _node.unfocus();
    if (vks.isEmpty) return; // клавиши без virtual-key кода опросить нельзя
    widget.app.setPttHotkey(vks, labels.join(' + '));
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final caps = _rec
        ? _best.map(pttKeyLabel).toList()
        : app.pttLabel.split(' + ').where((s) => s.isNotEmpty).toList();
    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: Row(children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (caps.isEmpty)
                Text(_rec ? app.t('pttPressKeys') : app.t('pttUnset'),
                    style: EvsType.caption.copyWith(
                        color: _rec ? _accent(context) : _faint(context)))
              else
                for (int i = 0; i < caps.length; i++) ...[
                  if (i > 0) const _KeySep(),
                  _KeyCap(caps[i]),
                ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _rec ? _cancel : _start,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _rec ? _accent(context) : _stroke(context)),
              color: _rec ? Colors.transparent : _stroke(context),
            ),
            child: Text(
              _rec ? app.t('cancel') : app.t('pttAssign'),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _rec ? _accent(context) : _body(context)),
            ),
          ),
        ),
      ]),
    );
  }
}

// Explicit "is the server actually reachable" check with a visible verdict, and
// the manual model-list refresh. Both drive AppState.fetchModels(), which IS the
// GET /api/tags round-trip and already records the outcome (unreachable / no
// models found) — a second probe would just be another thing to keep in sync.
class _ConnCheckRow extends StatelessWidget {
  const _ConnCheckRow(this.app, {this.showRefresh = false});
  final AppState app;
  final bool showRefresh;

  @override
  Widget build(BuildContext context) {
    final hasUrl = app.serverUrl.trim().isNotEmpty;
    final busy = app.loadingModels;
    final err = app.modelsError;

    final (String text, Color color) = !hasUrl
        ? (app.t('connBadUrl'), _faint(context))
        : busy
            ? (app.t('connChecking'), _warn(context))
            : err != null
                ? (err, _danger(context))
                : app.models.isEmpty
                    ? ('', _faint(context))
                    : (
                        '${app.t('connOnline')} · ${app.models.length} ${app.t('connModelsCount')}',
                        _success(context)
                      );

    Widget btn(String label, IconData icon) => InkWell(
          borderRadius: BorderRadius.circular(8),
          // Without an address there is nothing to probe, so the button stays
          // inert rather than reporting a misleading failure.
          onTap: (!hasUrl || busy) ? null : () => app.fetchModels(),
          child: Opacity(
            opacity: (!hasUrl || busy) ? 0.45 : 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _stroke(context)),
                color: _stroke(context),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 14, color: _sub(context)),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _body(context))),
              ]),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      child: Row(
        children: [
          btn(app.t(showRefresh ? 'refreshModelsBtn' : 'checkConn'),
              showRefresh ? Icons.refresh : Icons.wifi_find),
          const SizedBox(width: 10),
          if (text.isNotEmpty)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: color)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(text,
                        style: TextStyle(fontSize: 12, color: color),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// TTS engine selector (settings TZ §3.2): Piper (offline, active) vs CosyVoice
// (GPU HTTP server). CosyVoice is only selectable once its endpoint answers a
// probe; the server isn't deployed yet, so it stays greyed with a note. The
// deeper CosyVoice controls (voice cloning, speed, emotion) come once the server
// exists and its API is known.
class _TtsEngineCard extends StatefulWidget {
  const _TtsEngineCard(this.app);
  final AppState app;
  @override
  State<_TtsEngineCard> createState() => _TtsEngineCardState();
}

class _TtsEngineCardState extends State<_TtsEngineCard> {
  late final TextEditingController _ep =
      TextEditingController(text: widget.app.cosyvoiceEndpoint);
  bool _checking = false;

  AppState get app => widget.app;

  @override
  void dispose() {
    _ep.dispose();
    super.dispose();
  }


  Widget _engineChip(String id, String nameKey, String hintKey,
      {required bool enabled}) {
    final selected = app.ttsEngineChoice == id;
    return Expanded(
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? () => app.setTtsEngineChoice(id) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: selected
                  ? const Color(0x263A7BE0)
                  : _overlayFill(context, 0.04),
              border: Border.all(
                  color: selected ? _accent(context) : _stroke(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.t(nameKey),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _body(context))),
                Text(app.t(hintKey),
                    style:
                        TextStyle(fontSize: 11, color: _faint(context))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch directly (this card sits inside a LayoutBuilder) so the online
    // status refreshes on every change.
    context.watch<AppState>();
    final cosyOnline = app.cosyvoiceOnline == true;
    // Selectable as soon as an endpoint AND a voice sample exist — being
    // reachable RIGHT NOW is not a requirement. Gating on the live probe was a
    // dead end: the pre-rendered phrase cache only plays while a cloning engine
    // is selected, so a stopped server made its own cache unreachable and left
    // no way back in the UI.
    final cosyConfigured = app.cosyvoiceEndpoint.trim().isNotEmpty &&
        app.cosyvoiceClonePath.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(children: [
            _engineChip('piper', 'ttsEnginePiper', 'ttsEnginePiperHint',
                enabled: true),
            const SizedBox(width: 8),
            _engineChip('cosyvoice', 'ttsEngineCosy', 'ttsEngineCosyHint',
                enabled: cosyConfigured),
          ]),
        ),
        if (!cosyConfigured)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Text(app.t('ttsCosyUnavailable'),
                style: TextStyle(fontSize: 11.5, color: _warn(context))),
          )
        else if (!cosyOnline)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Text(app.t('ttsCosyFellBack'),
                style: TextStyle(fontSize: 11.5, color: _warn(context))),
          ),
        // Endpoint + check.
        evsRow(context,
          stacked: true,
          label: app.t('ttsCosyEndpoint'),
          control: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RemoteField(
                controller: _ep,
                onChanged: app.setCosyvoiceEndpoint,
              ),
              const SizedBox(height: 8),
              Row(children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _checking
                      ? null
                      : () async {
                          setState(() => _checking = true);
                          await app.checkCosyvoice();
                          if (mounted) setState(() => _checking = false);
                        },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _stroke(context)),
                      color: _stroke(context),
                    ),
                    child: Text(
                        _checking ? app.t('ttsCosyChecking') : app.t('ttsCosyCheck'),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _body(context))),
                  ),
                ),
                const SizedBox(width: 10),
                if (app.cosyvoiceOnline != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: cosyOnline
                                ? _success(context)
                                : _danger(context))),
                    const SizedBox(width: 6),
                    Text(
                        cosyOnline
                            ? app.t('ttsCosyOnline')
                            : app.t('ttsCosyOffline'),
                        style: TextStyle(
                            fontSize: 12,
                            color: cosyOnline
                                ? _success(context)
                                : _danger(context))),
                  ]),
              ]),
            ],
          ),
        ),
        // Управление локальным сервером клона: раньше его поднимали руками из
        // консоли, хотя приложение уже умеет с ним разговаривать.
        evsRow(context,
          stacked: true,
          label: app.t('cloneSrvTitle'),
          desc: app.t('cloneSrvDesc'),
          control: _CloneServerControl(app),
        ),
      ],
    );
  }
}

// Кнопка «запустить/остановить» + состояние. Сам процесс ведёт CloneServer
// (desktop_integration.dart): он же кладёт его в ProcessJob, чтобы модель не
// осталась висеть в видеопамяти, если приложение упадёт.
class _CloneServerControl extends StatefulWidget {
  const _CloneServerControl(this.app);
  final AppState app;
  @override
  State<_CloneServerControl> createState() => _CloneServerControlState();
}

class _CloneServerControlState extends State<_CloneServerControl> {
  late final TextEditingController _py;

  @override
  void initState() {
    super.initState();
    _py = TextEditingController(text: widget.app.cloneServerPython);
  }

  @override
  void dispose() {
    _py.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final srv = CloneServer.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([srv.state, srv.problem]),
      builder: (context, _) {
        final st = srv.state.value;
        final busy = st == CloneServerState.starting;
        final running = st == CloneServerState.running;
        final (label, color) = switch (st) {
          CloneServerState.running => (app.t('cloneSrvRunning'), _success(context)),
          CloneServerState.starting => (app.t('cloneSrvStarting'), _warn(context)),
          CloneServerState.failed => (srv.problem.value, _danger(context)),
          CloneServerState.stopped => (app.t('cloneSrvStopped'), _faint(context)),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: busy
                    ? null
                    : () => unawaited(
                        running ? srv.stop(app) : srv.start(app)),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: running ? _danger(context) : _stroke(context)),
                    color: running ? Colors.transparent : _stroke(context),
                  ),
                  child: Text(
                    running ? app.t('cloneSrvStop') : app.t('cloneSrvStart'),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: running ? _danger(context) : _body(context)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: color)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: color)),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 10),
            Text(app.t('cloneSrvPython'),
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _sectionLabel(context))),
            const SizedBox(height: 5),
            _RemoteField(
              controller: _py,
              onChanged: app.setCloneServerPython,
            ),
          ],
        );
      },
    );
  }
}

// The clone half of what used to be one giant TTS card: reference sample,
// voice/emotion/instruct and the GPU-load profile of the render server. Split
// out so "Движок синтеза" and "Клон и нагрузка GPU" are separate pages instead
// of one column several screens tall.
class _TtsCloneCard extends StatefulWidget {
  const _TtsCloneCard(this.app);
  final AppState app;
  @override
  State<_TtsCloneCard> createState() => _TtsCloneCardState();
}

class _TtsCloneCardState extends State<_TtsCloneCard> {
  // CosyVoice deep-control text fields (§3.2).
  late final TextEditingController _voice =
      TextEditingController(text: widget.app.cosyvoiceVoice);
  late final TextEditingController _clonePrompt =
      TextEditingController(text: widget.app.cosyvoiceClonePromptText);
  late final TextEditingController _instruct =
      TextEditingController(text: widget.app.cosyvoiceInstruct);
  bool _gpuAdvOpen = false; // raw GPU-load knobs, collapsed by default

  // Emotion presets → i18n label keys (map to instruct phrases once wired).
  static const List<(String, String)> _emotions = [
    ('neutral', 'ttsCosyEmotionNeutral'),
    ('happy', 'ttsCosyEmotionHappy'),
    ('sad', 'ttsCosyEmotionSad'),
    ('serious', 'ttsCosyEmotionSerious'),
    ('calm', 'ttsCosyEmotionCalm'),
    ('excited', 'ttsCosyEmotionExcited'),
  ];

  AppState get app => widget.app;

  Future<void> _pickCloneSample() async {
    final res = await FilePicker.pickFiles();
    final p = res?.files.single.path;
    if (p != null && p.isNotEmpty) app.setCosyvoiceClonePath(p);
  }

  @override
  void dispose() {
    _voice.dispose();
    _clonePrompt.dispose();
    _instruct.dispose();
    super.dispose();
  }

  // Emotion preset dropdown (§3.2 wireframe shows a "[ нейтральная ▾ ]" select).
  Widget _cosyEmotionDropdown() {
    final value =
        _emotions.any((e) => e.$1 == app.cosyvoiceEmotion) ? app.cosyvoiceEmotion : 'neutral';
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF1A1B25),
          style: TextStyle(fontSize: 12.5, color: _body(context)),
          icon: Icon(Icons.expand_more, size: 18, color: _sub(context)),
          items: [
            for (final e in _emotions)
              DropdownMenuItem(value: e.$1, child: Text(app.t(e.$2))),
          ],
          onChanged: (v) {
            if (v != null) app.setCosyvoiceEmotion(v);
          },
        ),
      ),
    );
  }

  // Deep CosyVoice controls (§3.2). UI + persisted state only — no synthesis
  // routing yet. Shown once an endpoint is entered so it can be configured
  // before the server is actually reachable.
  List<Widget> _cosyDeepControls() {
    final sc = SidecarClient.instance;
    return [
      // Scope header: everything below belongs to the REMOTE CosyVoice server
      // (including its own clone sample) — not to the local XTTS clone card.
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
        child: Row(children: [
          Icon(Icons.dns_outlined, size: 15, color: _sub(context)),
          const SizedBox(width: 7),
          Text(app.t('ttsCosySectionTitle'),
              style: TextStyle(
                  color: _body(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
        child: Text(app.t('ttsCosyWiringHint'),
            style: TextStyle(fontSize: 11, color: _faint(context))),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyVoice'),
        desc: app.t('ttsCosyVoiceHint'),
        control:
            _RemoteField(controller: _voice, onChanged: app.setCosyvoiceVoice),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyClone'),
        control: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _pickCloneSample,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _stroke(context)),
                    color: _stroke(context),
                  ),
                  child: Text(app.t('ttsCosyClonePick'),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _body(context))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  app.cosyvoiceClonePath.isEmpty
                      ? app.t('ttsCosyCloneNone')
                      : app.cosyvoiceClonePath
                          .split(io.Platform.pathSeparator)
                          .last,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: _sub(context)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _RemoteField(
                controller: _clonePrompt,
                onChanged: app.setCosyvoiceClonePromptText),
            const SizedBox(height: 4),
            Text(app.t('ttsCosyClonePromptHint'),
                style: TextStyle(fontSize: 11, color: _faint(context))),
          ],
        ),
      ),
      evsRow(context, 
        label: app.t('ttsCosySpeed'),
        control: evsSlider(context, 
          value: app.cosyvoiceSpeed.clamp(0.5, 2.0),
          min: 0.5,
          max: 2.0,
          divisions: 15,
          label: '${app.cosyvoiceSpeed.toStringAsFixed(1)}x',
          onChanged: app.setCosyvoiceSpeed,
        ),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyEmotion'),
        control: _cosyEmotionDropdown(),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyInstruct'),
        desc: app.t('ttsCosyInstructHint'),
        control: _RemoteField(
            controller: _instruct, onChanged: app.setCosyvoiceInstruct),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyDevice'),
        control: AnimatedBuilder(
          animation: sc.gpuInfo,
          builder: (context, _) {
            final name = sc.gpuInfo.value.$2;
            return evsSegmentedWide<String>(context, 
              [
                ('cpu', app.t('deviceCpu')),
                ('cuda', name.isNotEmpty ? 'GPU · $name' : app.t('deviceGpu')),
              ],
              app.cosyvoiceDevice,
              app.setCosyvoiceDevice,
            );
          },
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Watch directly (this card sits inside a LayoutBuilder) so the clone
    // sample label refreshes on every change.
    context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Deep CosyVoice controls (§3.2) — voice/preset, clone-by-WAV sample,
        // speed, emotion, instruct and synthesis device. Always visible so the
        // voice cloner is discoverable and can be configured up front (they
        // still only take effect once the clone server is reachable).
        ..._cosyDeepControls(),
        ..._gpuLoadControls(),
      ],
    );
  }

  // GPU-load control for the clone server. There is no driver-level "use N% of
  // the GPU" knob, so the load is shaped by a VRAM ceiling, idle unloading, a
  // duty-cycle throttle and a game-mode stand-down — presented as one profile
  // with the raw knobs tucked under "Дополнительно".
  List<Widget> _gpuLoadControls() {
    final totalMb = SidecarClient.instance.gpuInfo.value.$3;
    final maxGb = totalMb > 0 ? (totalMb / 1024).floorToDouble() : 12.0;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
        child: Text(app.t('gpuLoadTitle'),
            style: TextStyle(
                color: _body(context),
                fontSize: 13,
                fontWeight: FontWeight.w700)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: Text(app.t('gpuLoadHint'),
            style: TextStyle(fontSize: 11, color: _faint(context))),
      ),
      evsRow(context,
        stacked: true,
        label: app.t('gpuProfile'),
        control: evsSegmentedWide<String>(context, [
          ('max', app.t('gpuProfileMax')),
          ('balanced', app.t('gpuProfileBalanced')),
          ('quiet', app.t('gpuProfileQuiet')),
          if (app.cloneGpuProfile == 'custom')
            ('custom', app.t('gpuProfileCustom')),
        ], app.cloneGpuProfile, app.setCloneGpuProfile),
      ),
      evsRow(context,
        stacked: true,
        label: app.t('gpuInGame'),
        desc: app.t('gpuInGameDesc'),
        control: evsSegmentedWide<String>(context, [
          ('cache', app.t('gpuInGameCache')),
          ('normal', app.t('gpuInGameNormal')),
          ('off', app.t('gpuInGameOff')),
        ], app.cloneGpuInGame, app.setCloneGpuInGame),
      ),
      // Collapsible raw knobs — touching any of them switches the profile to
      // "Своё", so the preset never silently misreports the real values.
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _gpuAdvOpen = !_gpuAdvOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(
                  _gpuAdvOpen
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 18,
                  color: _sub(context)),
              const SizedBox(width: 4),
              Text(app.t('gpuAdvanced'),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _sub(context))),
            ]),
          ),
        ),
      ),
      if (_gpuAdvOpen) ...[
        evsRow(context,
          label: app.t('gpuVramLimit'),
          desc: app.cloneGpuVramLimitGb <= 0
              ? app.t('gpuVramNoLimit')
              : '${app.cloneGpuVramLimitGb.toStringAsFixed(1)} ГБ / '
                  '${maxGb.toStringAsFixed(0)} ГБ',
          control: evsSlider(context,
            value: app.cloneGpuVramLimitGb.clamp(0, maxGb),
            min: 0,
            max: maxGb,
            divisions: (maxGb * 2).round(),
            label: app.cloneGpuVramLimitGb <= 0
                ? app.t('gpuVramNoLimit')
                : '${app.cloneGpuVramLimitGb.toStringAsFixed(1)} ГБ',
            onChanged: app.setCloneGpuVramLimitGb,
          ),
        ),
        evsRow(context,
          label: app.t('gpuIdleUnload'),
          desc: app.t('gpuIdleUnloadDesc'),
          control: evsSlider(context,
            value: app.cloneGpuIdleUnloadSec.toDouble().clamp(0, 600),
            min: 0,
            max: 600,
            divisions: 20,
            label: app.cloneGpuIdleUnloadSec <= 0
                ? app.t('gpuIdleNever')
                : '${app.cloneGpuIdleUnloadSec} c',
            onChanged: (v) => app.setCloneGpuIdleUnloadSec(v.round()),
          ),
        ),
        evsRow(context,
          label: app.t('gpuThrottle'),
          desc: app.t('gpuThrottleDesc'),
          control: evsSlider(context,
            value: app.cloneGpuThrottle.clamp(0.0, 1.0),
            min: 0,
            max: 1,
            divisions: 10,
            label: '${(app.cloneGpuThrottle * 100).round()}%',
            onChanged: app.setCloneGpuThrottle,
          ),
        ),
        evsRow(context,
          stacked: true,
          label: app.t('gpuPrecision'),
          desc: app.t('gpuPrecisionDesc'),
          control: evsSegmentedWide<String>(context, [
            ('auto', app.t('gpuPrecisionAuto')),
            ('bf16', 'bf16'),
            ('fp16', 'fp16'),
          ], app.cloneGpuPrecision, app.setCloneGpuPrecision),
        ),
      ],
    ];
  }
}

// Editor for ONE quick profile: pick which settings it applies and their
// values. An unchecked row means the profile leaves that setting untouched —
// that's how "Поиск"/"Чат" stay single-purpose while "Быстро" changes three
// things at once.
class _PresetEditDialog extends StatefulWidget {
  const _PresetEditDialog({
    required this.app,
    required this.id,
    required this.nameKey,
    required this.initial,
  });
  final AppState app;
  final String id;
  final String nameKey;
  final Map<String, dynamic> initial;
  @override
  State<_PresetEditDialog> createState() => _PresetEditDialogState();
}

class _PresetEditDialogState extends State<_PresetEditDialog> {
  late String? _device = widget.initial['device'] as String?;
  late String? _denoise = widget.initial['denoise'] as String?;
  late bool? _web = widget.initial['web'] as bool?;

  AppState get app => widget.app;

  Widget _section({
    required String label,
    required bool on,
    required ValueChanged<bool> onToggle,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            SizedBox(
              width: 28,
              child: Checkbox(
                value: on,
                onChanged: (v) => onToggle(v ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 12.5, color: _body(context))),
            ),
          ]),
          if (on)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 6),
              child: child,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Text('${app.t('presetEditTitle')} · ${app.t(widget.nameKey)}',
          style: TextStyle(color: _txt(context), fontSize: 15)),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(app.t('presetEditHint'),
                  style: TextStyle(fontSize: 11.5, color: _faint(context))),
              const SizedBox(height: 4),
              _section(
                label: app.t('presetFieldDevice'),
                on: _device != null,
                onToggle: (v) => setState(() => _device = v ? 'cpu' : null),
                child: evsSegmentedWide<String>(context, [
                  ('cpu', app.t('deviceCpu')),
                  ('cuda', app.t('deviceGpu')),
                ], _device ?? 'cpu', (v) => setState(() => _device = v)),
              ),
              _section(
                label: app.t('presetFieldDenoise'),
                on: _denoise != null,
                onToggle: (v) => setState(() => _denoise = v ? 'light' : null),
                child: evsSegmentedWide<String>(context, [
                  ('off', app.t('presetDnOff')),
                  ('light', app.t('presetDnLight')),
                  ('strong', app.t('presetDnStrong')),
                ], _denoise ?? 'light', (v) => setState(() => _denoise = v)),
              ),
              _section(
                label: app.t('presetFieldWeb'),
                on: _web != null,
                onToggle: (v) => setState(() => _web = v ? true : null),
                child: evsSegmentedWide<bool>(context, [
                  (true, app.t('presetWebOn')),
                  (false, app.t('presetWebOff')),
                ], _web ?? true, (v) => setState(() => _web = v)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(app.t('cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, <String, dynamic>{
            if (_device != null) 'device': _device,
            if (_denoise != null) 'denoise': _denoise,
            if (_web != null) 'web': _web,
          }),
          child: Text(app.t('save')),
        ),
      ],
    );
  }
}

// Voice clone (XTTS · CPU) — a self-contained section, deliberately SEPARATE
// from the CosyVoice controls above: both offer "clone from a WAV sample", but
// this one is the local CPU cloner (its own component + phrase cache) while
// CosyVoice's sample belongs to its remote GPU server. Keeping them in one card
// made the two sets of settings read as one and confused which was which.
//
// Currently NOT shown (CPU build was unintelligible) — kept for the GPU-render
// rework. ignore: unused_element
class _VoiceCloneCard extends StatefulWidget {
  const _VoiceCloneCard(this.app);
  final AppState app;
  @override
  State<_VoiceCloneCard> createState() => _VoiceCloneCardState();
}

class _VoiceCloneCardState extends State<_VoiceCloneCard> {
  final TextEditingController _phrase = TextEditingController();

  AppState get app => widget.app;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _pickCloneWav() async {
    final res = await FilePicker.pickFiles();
    final p = res?.files.single.path;
    if (p != null && p.isNotEmpty) app.setCloneSamplePath(p);
  }

  Widget _compBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _componentControl() {
    return ValueListenableBuilder<ComponentStatus>(
      valueListenable: ComponentManager.instance.statusOf('clone'),
      builder: (_, cs, __) {
        switch (cs.state) {
          case ComponentState.downloading:
            return SizedBox(
              width: 180,
              child: Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                    child: LinearProgressIndicator(
                      value: cs.progress > 0 ? cs.progress : null,
                      minHeight: 6,
                      backgroundColor: _stroke(context),
                      valueColor: const AlwaysStoppedAnimation(_evsGMid),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(cs.progress * 100).round()}%',
                    style: TextStyle(fontSize: 12, color: _faint(context))),
              ]),
            );
          case ComponentState.verifying:
            return _compBadge(app.t('componentVerifying'), _warn(context));
          case ComponentState.ready:
            return _compBadge(app.t('componentReady'), _success(context));
          case ComponentState.error:
            return evsGhostButton(context, app.t('retry'), Icons.refresh,
                onTap: () => ComponentManager.instance.ensure('clone'));
          case ComponentState.absent:
            final info = ComponentManager.instance.infoOf('clone');
            final gb = info != null && info.size > 0
                ? ' (${(info.size / 1073741824).toStringAsFixed(1)} GB)'
                : '';
            return evsGhostButton(context, '${app.t('download')}$gb',
                Icons.download,
                onTap: () => ComponentManager.instance.ensure('clone'));
        }
      },
    );
  }

  // Live engine status — makes "it doesn't work" diagnosable: shows whether the
  // clone engine actually became active, is still loading, or fell back (e.g.
  // the ~3 GB component hasn't finished downloading yet).
  Widget _engineStatus() {
    return ValueListenableBuilder<(String, String, String, String?)?>(
      valueListenable: SidecarClient.instance.ttsStatus,
      builder: (_, st, __) {
        String label;
        Color color;
        if (st != null && st.$1 == 'xtts' && st.$3 == 'ready') {
          label = app.t('cloneEngineReady');
          color = _success(context);
        } else if (st != null && st.$1 == 'xtts' && st.$3 == 'loading') {
          label = app.t('cloneEngineLoading');
          color = _warn(context);
        } else if (st != null && st.$1 == 'xtts' && st.$3 == 'error') {
          label = '${app.t('cloneEngineError')}: ${st.$4 ?? ''}';
          color = _danger(context);
        } else {
          // Not active yet — most often the component is still downloading.
          label = app.t('cloneEngineInactive');
          color = _faint(context);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 4),
          child: Row(children: [
            Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: color)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 11.5, color: color)),
            ),
          ]),
        );
      },
    );
  }

  // Read-only preview of the full phrase set that gets pre-rendered into the
  // cloned voice, grouped by source. It is derived live from AppState
  // (clonePhrasesToRender), so it updates itself the moment a voice command or
  // a library phrase is added/removed — no manual sync.
  Widget _phrasesTable() {
    final rows = <(String, String)>[]; // (source label, phrase)
    void add(String src, String? s) {
      final v = (s ?? '').trim();
      if (v.isNotEmpty && !v.contains('{')) rows.add((src, v));
    }

    add(app.t('cloneSrcSystem'), app.t('readyGreeting'));
    add(app.t('cloneSrcSystem'), app.t('gmNotifyFullscreen'));
    add(app.t('cloneSrcSystem'), app.t('gmNotifyVram'));
    add(app.t('cloneSrcSystem'), app.t('gmNotifyExit'));
    add(app.t('cloneSrcSystem'), app.t('vaDone'));
    for (final c in app.voiceCommands) {
      add(app.t('cloneSrcCommand'), c.speakPhrase);
    }
    for (final p in AppState.kCloneAckPhrases) {
      add(app.t('cloneSrcAck'), p);
    }
    for (final p in app.clonePhraseLib) {
      add(app.t('cloneSrcCustom'), p);
    }
    // Deduplicate on the phrase text (first source wins) — matches the cache,
    // which keys on the phrase.
    final seen = <String>{};
    final uniq = [
      for (final r in rows)
        if (seen.add(r.$2)) r
    ];
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _stroke(context)),
        color: _overlayFill(context, 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Text(
                app.t('clonePhrasesCount').replaceAll('{n}', '${uniq.length}'),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _sub(context))),
          ),
          Divider(height: 1, color: _stroke(context)),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: uniq.length,
              itemBuilder: (_, i) {
                final r = uniq[i];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: Row(children: [
                    Expanded(
                      child: Text(r.$2,
                          style: TextStyle(
                              fontSize: 12, color: _body(context))),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: _overlayFill(context, 0.06),
                      ),
                      child: Text(r.$1,
                          style: TextStyle(
                              fontSize: 9.5, color: _faint(context))),
                    ),
                  ]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _prerenderStatus() {
    return ValueListenableBuilder<(int, int, String)>(
      valueListenable: SidecarClient.instance.prerenderProgress,
      builder: (_, pr, __) {
        final done = pr.$1, total = pr.$2, state = pr.$3;
        if (total == 0 || state == 'done' || state == 'skip') {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 4),
          child: Text('${app.t('clonePrerender')} $done/$total',
              style: TextStyle(fontSize: 11, color: _accent(context))),
        );
      },
    );
  }

  // Editable extra phrases pre-rendered into the cloned voice (on top of the
  // built-in system + command speak-phrases).
  Widget _phraseLib() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (app.clonePhraseLib.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in app.clonePhraseLib)
                Chip(
                  label: Text(p,
                      style:
                          TextStyle(fontSize: 11.5, color: _body(context))),
                  backgroundColor: _overlayFill(context, 0.05),
                  side: BorderSide(color: _stroke(context)),
                  deleteIconColor: _faint(context),
                  onDeleted: () => app.removeClonePhrase(p),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: _RemoteField(controller: _phrase, onChanged: (_) {})),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              app.addClonePhrase(_phrase.text);
              _phrase.clear();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _stroke(context)),
                color: _stroke(context),
              ),
              child: Text(app.t('clonePhraseAdd'),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
            ),
          ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe directly to AppState: this card lives inside a LayoutBuilder,
    // whose builder does not always re-run on a bare notifyListeners, so relying
    // on the parent rebuild left the picked-sample label (and phrase list)
    // stale. Watching here guarantees the card refreshes on every change.
    context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
          child: Row(children: [
            Icon(Icons.graphic_eq, size: 15, color: _accent(context)),
            const SizedBox(width: 7),
            Text(app.t('cloneSectionTitle'),
                style: TextStyle(
                    color: _body(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
          child: Text(app.t('cloneSectionHint'),
              style: TextStyle(fontSize: 11, color: _faint(context))),
        ),
        evsRow(context,
          label: app.t('cloneTitle'),
          desc: app.t('cloneHint'),
          control: evsToggle(context, app.cloneEnabled, app.setCloneEnabled),
        ),
        if (app.cloneEnabled) ...[
          evsRow(context,
            stacked: true,
            label: app.t('cloneComponent'),
            desc: app.t('cloneComponentDesc'),
            control: _componentControl(),
          ),
          evsRow(context,
            stacked: true,
            label: app.t('cloneSample'),
            control: Row(children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _pickCloneWav,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _stroke(context)),
                    color: _stroke(context),
                  ),
                  child: Text(app.t('cloneSamplePick'),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _body(context))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  app.cloneSamplePath.isEmpty
                      ? app.t('cloneSampleNone')
                      : app.cloneSamplePath
                          .split(io.Platform.pathSeparator)
                          .last,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: _sub(context)),
                ),
              ),
            ]),
          ),
          _engineStatus(),
          _prerenderStatus(),
          evsRow(context,
            stacked: true,
            label: app.t('clonePhr2Title'),
            desc: app.t('clonePhrasesDesc'),
            control: _phrasesTable(),
          ),
          evsRow(context,
            stacked: true,
            label: app.t('clonePhraseLib'),
            desc: app.t('clonePhraseLibHint'),
            control: _phraseLib(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
            child: Text(app.t('cloneCpuNote'),
                style: TextStyle(fontSize: 11, color: _faint(context))),
          ),
        ],
      ],
    );
  }
}

// Voice interpreter controls (settings TZ §3.2): on/off, rules-vs-model, and
// the interpreter model name when "model" is chosen. Stateful only for the
// model-name field's controller.
class _TtsInterpCard extends StatefulWidget {
  const _TtsInterpCard(this.app);
  final AppState app;
  @override
  State<_TtsInterpCard> createState() => _TtsInterpCardState();
}

class _TtsInterpCardState extends State<_TtsInterpCard> {
  // Interpreter model picker: the server's model list plus a "default" first
  // entry ('') that follows the global chat/selected model
  // (AppState.effectiveTtsInterpModel). A stored model the server no longer
  // advertises is kept as an extra entry rather than silently reset.
  Widget _interpModelDropdown(AppState app) {
    final remote =
        app.models.where((m) => !app.isLocalModel(m)).toList();
    final current = app.ttsInterpModel.trim();
    if (current.isNotEmpty && !remote.contains(current)) remote.add(current);
    final def = app.effectiveTtsInterpModel;
    final defLabel = app
        .t('ttsInterpModelDefault')
        .replaceAll('{model}', def.isEmpty ? '—' : def);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          isExpanded: true,
          isDense: true,
          dropdownColor: _card2(context),
          style: TextStyle(fontSize: 12.5, color: _body(context)),
          icon: Icon(Icons.expand_more, size: 18, color: _sub(context)),
          items: [
            DropdownMenuItem(value: '', child: Text(defLabel)),
            for (final m in remote)
              DropdownMenuItem(value: m, child: Text(m)),
          ],
          onChanged: (v) {
            if (v != null) app.setTtsInterpModel(v);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        evsRow(context, 
          label: app.t('ttsInterp'),
          desc: app.t('ttsInterpDesc'),
          control: evsToggle(context, app.ttsInterpEnabled, app.setTtsInterpEnabled),
        ),
        if (app.ttsInterpEnabled) ...[
          evsRow(context, 
            stacked: true,
            label: app.t('ttsInterpMode'),
            control: evsSegmentedWide<String>(context, 
              [
                ('rules', app.t('ttsInterpRules')),
                ('model', app.t('ttsInterpModel')),
              ],
              app.ttsInterpMode,
              (v) => app.setTtsInterpMode(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text(
              app.ttsInterpMode == 'model'
                  ? app.t('ttsInterpModelHint')
                  : app.t('ttsInterpRulesHint'),
              style: TextStyle(fontSize: 11.5, color: _faint(context)),
            ),
          ),
          if (app.ttsInterpMode == 'model')
            evsRow(context,
              stacked: true,
              label: app.t('ttsInterpModelField'),
              desc: app.t('ttsInterpModelPickDesc'),
              control: _interpModelDropdown(app),
            ),
        ],
      ],
    );
  }
}

// Optional per-mode model override (search vs chat). Empty = follow the global
// selection, so leaving both alone reproduces the previous single-model
// behaviour. A stored value that is no longer advertised by the server is kept
// and flagged rather than silently swapped (settings TZ §12).
class _ModelModeCard extends StatelessWidget {
  const _ModelModeCard(this.app);
  final AppState app;

  Widget _picker(BuildContext context, String current,
      ValueChanged<String> onPick) {
    final missing = current.isNotEmpty && !app.models.contains(current);
    final label = current.isEmpty
        ? app.t('modelDefaultGlobal')
        : missing
            ? '$current  ⚠ ${app.t('modelNotOnServer')}'
            : app.modelDisplayName(current, withSuffix: false);
    return PopupMenuButton<String>(
      tooltip: '',
      color: _card(context),
      onSelected: onPick,
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: '',
          child: Text(app.t('modelDefaultGlobal'),
              style: TextStyle(color: _body(context), fontSize: 13)),
        ),
        // Keep a missing-but-selected value in the menu so it can be seen and
        // cleared instead of vanishing.
        if (missing)
          PopupMenuItem<String>(
            value: current,
            child: Text('$current  ⚠',
                style: TextStyle(color: _warn(context), fontSize: 13)),
          ),
        for (final m in app.models)
          PopupMenuItem<String>(
            value: m,
            child: Text(app.modelDisplayName(m, withSuffix: false),
                style: TextStyle(color: _body(context), fontSize: 13)),
          ),
      ],
      child: evsSelectButton(context, label, minWidth: 150),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.t('modelPerMode'),
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
              const SizedBox(height: 3),
              Text(app.t('modelPerModeDesc'),
                  style:
                      TextStyle(fontSize: 12, color: _faint(context))),
            ],
          ),
        ),
        evsRow(context, 
          label: app.t('modelForSearch'),
          control: _picker(context, app.searchModel, app.setSearchModel),
        ),
        evsRow(context, 
          label: app.t('modelForChat'),
          control: _picker(context, app.chatModel, app.setChatModel),
        ),
      ],
    );
  }
}

// Advanced Ollama request parameters, collapsed by default (progressive
// disclosure — the basics stay visible, this is opt-in). Every field is
// optional: clearing one drops the parameter from the request entirely rather
// than substituting a default, so the model keeps deciding.
class _LlmAdvancedCard extends StatefulWidget {
  const _LlmAdvancedCard(this.app);
  final AppState app;

  @override
  State<_LlmAdvancedCard> createState() => _LlmAdvancedCardState();
}

class _LlmAdvancedCardState extends State<_LlmAdvancedCard> {
  bool _open = false;
  late final TextEditingController _ctx =
      TextEditingController(text: widget.app.llmNumCtx?.toString() ?? '');
  late final TextEditingController _pred =
      TextEditingController(text: widget.app.llmNumPredict?.toString() ?? '');
  late final TextEditingController _temp =
      TextEditingController(text: widget.app.llmTemperature?.toString() ?? '');
  late final TextEditingController _ka =
      TextEditingController(text: widget.app.llmKeepAlive);
  String? _ctxErr;
  String? _predErr;
  String? _tempErr;

  @override
  void dispose() {
    _ctx.dispose();
    _pred.dispose();
    _temp.dispose();
    _ka.dispose();
    super.dispose();
  }

  // Blank clears the parameter; anything unparsable is reported and NOT saved,
  // so a typo can never reach the request as a silent zero.
  void _onInt(String raw, void Function(int?) save, void Function(String?) err) {
    final t = raw.trim();
    if (t.isEmpty) {
      err(null);
      save(null);
      return;
    }
    final v = int.tryParse(t);
    if (v == null || v <= 0) {
      err(widget.app.t('llmBadNumber'));
      return;
    }
    err(null);
    save(v);
  }

  void _onTemp(String raw) {
    final app = widget.app;
    final t = raw.trim();
    if (t.isEmpty) {
      setState(() => _tempErr = null);
      app.setLlmTemperature(null);
      return;
    }
    final v = double.tryParse(t.replaceAll(',', '.'));
    if (v == null) {
      setState(() => _tempErr = app.t('llmBadNumber'));
      return;
    }
    if (v < 0 || v > 1.5) {
      setState(() => _tempErr = app.t('llmTempRange'));
      return;
    }
    setState(() => _tempErr = null);
    app.setLlmTemperature(v);
  }

  Widget _field(TextEditingController c, ValueChanged<String> onChanged,
      {String? error}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _overlayFill(context, 0.04),
            border: Border.all(
                color: error == null ? _stroke(context) : const Color(0xFFF0685E)),
          ),
          child: TextField(
            controller: c,
            onChanged: onChanged,
            style: TextStyle(fontSize: 12.5, color: _body(context)),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: widget.app.t('llmDefaultHint'),
              hintStyle:
                  TextStyle(fontSize: 12.5, color: _faint(context)),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error,
                style:
                    const TextStyle(fontSize: 11, color: Color(0xFFF0685E))),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.t('cardLlmAdv'),
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: _body(context))),
                      const SizedBox(height: 3),
                      Text(app.t('llmAdvDesc'),
                          style: TextStyle(
                              fontSize: 12, color: _faint(context))),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: _sub(context)),
              ],
            ),
          ),
        ),
        if (_open) ...[
          evsRow(context, 
            label: app.t('llmNumCtx'),
            desc: app.t('llmNumCtxDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_ctx,
                  (v) => _onInt(v, app.setLlmNumCtx,
                      (e) => setState(() => _ctxErr = e)),
                  error: _ctxErr),
            ),
          ),
          evsRow(context, 
            label: app.t('llmNumPredict'),
            desc: app.t('llmNumPredictDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_pred,
                  (v) => _onInt(v, app.setLlmNumPredict,
                      (e) => setState(() => _predErr = e)),
                  error: _predErr),
            ),
          ),
          evsRow(context, 
            label: app.t('llmTemp'),
            desc: app.t('llmTempDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_temp, _onTemp, error: _tempErr),
            ),
          ),
          evsRow(context,
            label: app.t('llmKeepAlive'),
            desc: app.t('llmKeepAliveDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_ka, (v) => app.setLlmKeepAlive(v.trim())),
            ),
          ),
        ],
      ],
    );
  }
}

// "Стиль интерфейса" control (Nexus TZ §7): two schematic preview tiles
// (Classic · Nexus). Tapping applies immediately via setAppStyle — outside the
// settings dirty mechanism. Each tile paints itself with ITS OWN style's skin
// (for the current theme) so you preview both looks side by side.
class _StylePicker extends StatelessWidget {
  const _StylePicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    Widget tile(AppStyle style, String label) {
      final selected = app.appStyle == style;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => app.setAppStyle(style),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 132,
              height: 78,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? _accent(context) : _stroke(context),
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(
                painter: _StylePreviewPainter(
                    style, skinFor(style, app.themeMode)),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 14,
                  color: selected ? _accent(context) : _faint(context),
                ),
                const SizedBox(width: 4),
                Text(label,
                    style: EvsType.control.copyWith(
                        color: selected ? _txt(context) : _sub(context))),
              ],
            ),
          ],
        ),
      );
    }

    // Под плитками — одна строка про ВЫБРАННЫЙ стиль: три описания рядом
    // читаются как список требований, а не как подсказка.
    final desc = switch (app.appStyle) {
      AppStyle.standard => app.t('uiStyleClassicDesc'),
      AppStyle.nexus => app.t('uiStyleNexusDesc'),
      AppStyle.noctur => app.t('uiStyleNocturDesc'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 12,
          children: [
            tile(AppStyle.standard, app.t('uiStyleClassic')),
            tile(AppStyle.nexus, app.t('uiStyleNexus')),
            tile(AppStyle.noctur, app.t('uiStyleNoctur')),
          ],
        ),
        const SizedBox(height: 10),
        Text(desc,
            style: TextStyle(fontSize: 11.5, color: _faint(context))),
      ],
    );
  }
}

// Schematic thumbnail of a UI style, painted in that style's skin colours.
// Classic = left sidebar + content; Nexus = thin rail + central stage (sphere +
// status pill/line) + right chat column. Purely decorative — no real data.
class _StylePreviewPainter extends CustomPainter {
  final AppStyle style;
  final EvsSkin skin;
  _StylePreviewPainter(this.style, this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    final p = skin.pal;
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = p.bg);

    void bar(double x, double y, double bw, double bh, Color col,
        [double r = 2]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, bw, bh), Radius.circular(r)),
        Paint()..color = col,
      );
    }

    if (style == AppStyle.nexus) {
      // Soft top glow (dark skins only) for the Nexus mood.
      if (skin.glow) {
        canvas.drawCircle(
          Offset(w * 0.55, -h * 0.1),
          h * 0.6,
          Paint()..color = p.accent.withValues(alpha: 0.10),
        );
      }
      final railW = w * 0.14;
      // Rail.
      bar(0, 0, railW, h, p.card, 0);
      for (var i = 0; i < 4; i++) {
        bar(railW * 0.32, 8.0 + i * 9, railW * 0.36, 4,
            i == 0 ? p.info : p.faint, 2);
      }
      // Chat column on the right.
      final chatW = w * 0.30;
      final chatX = w - chatW;
      bar(chatX, 0, chatW, h, p.card, 0);
      bar(chatX + 6, 12, chatW - 18, 10, p.accent.withValues(alpha: 0.30), 4);
      bar(chatX + 6, 30, chatW - 24, 6, p.stroke, 3);
      bar(chatX + 6, 42, chatW - 14, 6, p.stroke, 3);
      // Central stage: status pill on top, sphere in the middle, status line.
      final stageX = railW + 6, stageR = (chatX - 6) - stageX;
      bar(stageX, 9, stageR * 0.55, 7, p.warn.withValues(alpha: 0.55), 4);
      final cx = stageX + stageR / 2, cy = h * 0.52;
      canvas.drawCircle(Offset(cx, cy), h * 0.20,
          Paint()..color = p.accent.withValues(alpha: 0.22));
      canvas.drawCircle(
          Offset(cx, cy),
          h * 0.20,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = skin.accent2.withValues(alpha: 0.75));
      bar(stageX + stageR * 0.15, h - 12, stageR * 0.7, 4, p.faint, 2);
    } else if (style == AppStyle.noctur) {
      // «Ноктюрн»: header strip with tabs, the ring across the whole window,
      // one telemetry line along the bottom (Noctur TZ §5.10).
      final headH = h * 0.17;
      bar(0, 0, w, headH, p.card, 0);
      bar(5, headH * 0.36, 9, headH * 0.28, p.accent, 1.5); // марка
      for (var i = 0; i < 4; i++) {
        bar(20.0 + i * 13, headH * 0.38, 9, headH * 0.24,
            i == 0 ? p.txt : p.faint, 1.5);
      }
      bar(20, headH - 1.6, 9, 1.6, p.accent, 0); // штрих под активной вкладкой
      // Кольцо по центру оставшейся площади.
      final cy = headH + (h - headH - h * 0.14) / 2;
      final r = math.min(h * 0.24, w * 0.18);
      canvas.drawCircle(
          Offset(w / 2, cy),
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = p.accent.withValues(alpha: 0.8));
      canvas.drawCircle(
          Offset(w / 2, cy),
          r * 0.62,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = p.txt.withValues(alpha: 0.22));
      canvas.drawCircle(
          Offset(w / 2, cy), 1.6, Paint()..color = p.accent);
      // Строка телеметрии.
      final stripH = h * 0.14;
      bar(0, h - stripH, w, stripH, p.card, 0);
      for (var i = 0; i < 3; i++) {
        bar(6.0 + i * 22, h - stripH / 2 - 1, 16, 2,
            i == 0 ? p.warn : p.faint, 1);
      }
      bar(w - 22, h - stripH / 2 - 1, 16, 2, p.faint, 1);
    } else {
      // Classic: wide left sidebar + content area with a header + list rows.
      final sideW = w * 0.30;
      bar(0, 0, sideW, h, p.card, 0);
      for (var i = 0; i < 5; i++) {
        bar(8, 10.0 + i * 12, sideW - 16, 7, i == 0 ? p.accent : p.stroke, 3);
      }
      final contentX = sideW + 8;
      bar(contentX, 10, (w - contentX) * 0.7, 9,
          p.accent.withValues(alpha: 0.35), 4);
      for (var i = 0; i < 4; i++) {
        bar(contentX, 28.0 + i * 11, (w - contentX) - 8, 7, p.stroke, 3);
      }
    }
  }

  @override
  bool shouldRepaint(_StylePreviewPainter old) =>
      old.style != style || old.skin.pal.bg != skin.pal.bg;
}

// The phrases pre-rendered into the cloned voice, with a listen button each.
// Without this the phrase cache was invisible: you could not tell what had been
// prepared, nor hear whether it actually came out in your own voice.
class _ClonePhrasesCard extends StatefulWidget {
  const _ClonePhrasesCard(this.app);
  final AppState app;
  @override
  State<_ClonePhrasesCard> createState() => _ClonePhrasesCardState();
}

class _ClonePhrasesCardState extends State<_ClonePhrasesCard> {
  AppState get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final phrases = app.clonePhrasesToRender();
    // Prepared phrases only replace normal speech while a CLONING engine is the
    // selected one. Picking Piper silently turned the whole cache off, which
    // reads as "the clone stopped working" — so say it, and offer the switch.
    final cloneOff = app.ttsEngineChoice != 'cosyvoice' &&
        app.cosyvoiceClonePath.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(
            app.t('clonePhr2Hint')
                .replaceAll('{n}', '${phrases.length}'),
            style: TextStyle(fontSize: 11.5, color: _faint(context)),
          ),
        ),
        if (cloneOff)
          Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: _warn(context).withValues(alpha: 0.10),
              border: Border.all(color: _warn(context).withValues(alpha: 0.32)),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 16, color: _warn(context)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(app.t('clonePhr2NotUsed'),
                    style: TextStyle(fontSize: 11.5, color: _body(context))),
              ),
              const SizedBox(width: 10),
              evsGhostButton(
                  context, app.t('clonePhr2Enable'), Icons.record_voice_over,
                  onTap: () => app.setTtsEngineChoice('cosyvoice')),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: evsGhostButton(
                context, app.t('clonePhr2Prepare'), Icons.download_done,
                onTap: () {
              SidecarClient.instance.prerender(phrases);
              showAppSnackBar(context, app.t('clonePhr2Preparing'));
            }),
          ),
        ),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _stroke(context)),
            color: _overlayFill(context, 0.03),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: phrases.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: _stroke(context)),
            itemBuilder: (_, i) {
              final p = phrases[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                child: Row(children: [
                  Expanded(
                    child: Text(p,
                        style:
                            TextStyle(fontSize: 12.5, color: _body(context))),
                  ),
                  IconButton(
                    tooltip: app.t('clonePhr2Play'),
                    icon: Icon(Icons.play_circle_outline,
                        size: 19, color: _info(context)),
                    // Plays the RENDERED file, not "this phrase through the
                    // current engine" — the point of the button is to hear what
                    // was prepared, so it must not answer in Piper.
                    onPressed: () => SidecarClient.instance.speak(p,
                        rate: app.ttsRate,
                        volume: app.ttsVolume,
                        cached: true),
                  ),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }
}
