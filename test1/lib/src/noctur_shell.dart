part of '../main.dart';

/* ===================== СТИЛЬ «НОКТЮРН» — ОБОЛОЧКА =====================
   Третий стиль интерфейса (ТЗ «Ноктюрн», этап 2). От Nexus отличается не
   палитрой, а компоновкой: Nexus — пульт (рейл, орб со спутниками, четыре
   карточки подсистем, чат постоянной колонкой), «Ноктюрн» — инструмент:
   вкладки сверху, сцена во всё окно, телеметрия одной моноширинной строкой по
   низу. Классический стиль и Nexus этим файлом не затрагиваются: он рендерится
   только при app.appStyle == AppStyle.noctur.

   Данные — те же, что у Nexus: NexusPipeline (этапы конвейера и уровень),
   SidecarClient, SystemMonitor, AppState. Ничего нового не считается. */

// Вкладки шапки (ТЗ §5.1). Открывают экраны, а не разделы настроек.
enum NocturTab { dialog, commands, models, log }

// Цвет-слот состояния (ТЗ §5.3). Красит: точку в пилюле шапки, точку и название
// состояния, кольцо, активные узлы цепочки и соответствующий сегмент
// телеметрии. Больше нигде.
Color _nocturSlot(BuildContext c, String stage) => switch (stage) {
  'listening' => _warn(c),
  'thinking' => _accent(c),
  'speaking' => _info(c),
  _ => _faint(c),
};

String _nocturStateLabel(AppState app, String stage) => switch (stage) {
  'listening' => app.t('vaListening'),
  'thinking' => app.t('vaThinking'),
  'speaking' => app.t('nxSpeaking'),
  _ => app.t('nxIdle'),
};

String _nocturStateHint(AppState app, String stage) => switch (stage) {
  'listening' => app.t('ncHintListening'),
  'thinking' => app.t('ncHintThinking'),
  'speaking' => app.t('ncHintSpeaking'),
  _ => app.t('ncHintIdle'),
};

// Свободная горизонтальная линейка, гаснущая в прозрачность по 48 px с каждого
// конца (ТЗ §4.6). Границы карточек и короткие штрихи остаются сплошными.
class _NocturRule extends StatelessWidget {
  const _NocturRule({this.fade = 48});
  final double fade;

  @override
  Widget build(BuildContext context) {
    final line = _stroke(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 0.0;
        final stop = w <= fade * 2 ? 0.5 : fade / w;
        return Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, line, line, Colors.transparent],
              stops: [0.0, stop, 1 - stop, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/* ============================ ШАПКА (§5.1) ============================ */

class NocturTopBar extends StatelessWidget {
  const NocturTopBar({
    super.key,
    required this.tab,
    required this.onTab,
    required this.onHome,
  });

  /// Активная вкладка; null — открыт главный экран (см. _NocturHomeState).
  final NocturTab? tab;
  final ValueChanged<NocturTab> onTab;
  final VoidCallback onHome;

  void _openSettings(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const DesktopSettings()));

  Widget _divider(BuildContext context) => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 14),
    color: _stroke(context),
  );

  Widget _tab(BuildContext context, NocturTab id, String label) {
    final active = id == tab;
    return InkWell(
      onTap: () => onTab(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: active ? _txt(context) : _sub(context),
                ),
              ),
            ),
            // Активная вкладка — сплошной штрих accent 2 px под текстом.
            if (active)
              Container(
                height: 2,
                decoration: BoxDecoration(
                  color: _accent(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Пилюля состояния: точка нужного слота + подпись. В узком окне (§7)
  // название состояния остаётся только в сцене, а в шапке — одна точка.
  Widget _statePill(BuildContext context, AppState app, bool compact) {
    return AnimatedBuilder(
      animation: NexusPipeline.instance,
      builder: (context, _) {
        final stage = NexusPipeline.instance.stage;
        final slot = _nocturSlot(context, stage);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NocturDot(color: slot, size: 6),
              if (!compact) ...[
                const SizedBox(width: 7),
                Text(
                  _nocturStateLabel(app, stage),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _body(context),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Container(
      height: _skin(context).topBarHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _stroke(context))),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          // Марка + «EVS»: знак Genesis, живой (см. genesis_logo.dart). Он же —
          // возврат на главный экран: вкладок четыре, а экранов пять.
          Tooltip(
            message: app.t('ncHome'),
            child: InkWell(
              onTap: onHome,
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 9),
                    child: _EvsLogoMark(size: 22),
                  ),
                  Text(
                    'EVS',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 12 * 0.16,
                      color: _txt(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _divider(context),
          _tab(context, NocturTab.dialog, app.t('nxNavDialog')),
          _tab(context, NocturTab.commands, app.t('ncTabCommands')),
          _tab(context, NocturTab.models, app.t('nxNavModels')),
          _tab(context, NocturTab.log, app.t('nxNavLog')),
          // Распорка тянет окно за шапку.
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _statePill(context, app, MediaQuery.of(context).size.width < 1000),
          const SizedBox(width: 10),
          Tooltip(
            message: app.t('settings'),
            child: InkResponse(
              radius: 20,
              onTap: () => _openSettings(context),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(
                  Icons.settings_outlined,
                  size: 17,
                  color: _sub(context),
                ),
              ),
            ),
          ),
          _divider(context),
          const _WinBtn(Icons.remove, _nocturMinimize),
          const _WinBtn(Icons.crop_square, _nocturMaxToggle, iconSize: 13),
          _WinBtn(Icons.close, () => windowManager.close(), danger: true),
        ],
      ),
    );
  }
}

void _nocturMinimize() => windowManager.minimize();

Future<void> _nocturMaxToggle() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

// Точка состояния: со свечением на тёмной палитре, плоская на светлой (§4.2).
class _NocturDot extends StatelessWidget {
  const _NocturDot({required this.color, this.size = 6});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glow = _skin(context).glow;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.55),
                  blurRadius: size * 1.6,
                ),
              ]
            : null,
      ),
    );
  }
}

/* ==================== СТРОКА ТЕЛЕМЕТРИИ (§5.4) ==================== */

class NocturStatusStrip extends StatelessWidget {
  const NocturStatusStrip({super.key});

  String _host(String url) => url
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'/.*$'), '');

  String _shortModel(String m) {
    var s = m.replaceFirst('local:', '');
    if (s.contains('/')) s = s.split('/').last;
    return s;
  }

  Widget _seg(BuildContext c, String key, String value, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          key,
          style: EvsType.mono.copyWith(fontSize: 11, color: color ?? _faint(c)),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: EvsType.mono.copyWith(fontSize: 11, color: color ?? _sub(c)),
          ),
        ),
      ],
    );
  }

  Widget _dot(BuildContext c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Text(
      '·',
      style: EvsType.mono.copyWith(
        fontSize: 11,
        color: _stroke(c).withValues(alpha: 0.9),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sc = SidecarClient.instance;
    // Порядок сжатия (§7): сначала уходит адрес хоста, затем имя модели, и в
    // самом узком окне остаются только названия движков. Обрезка по ellipsis
    // сама по себе съедала бы то, что длиннее, а не то, что менее важно.
    final w = MediaQuery.of(context).size.width;
    final showHost = w >= 1180;
    final showModel = w >= 1000;
    return Container(
      height: _skin(context).statusBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: AnimatedBuilder(
        animation: Listenable.merge([
          NexusPipeline.instance,
          sc.status,
          sc.deviceStatus,
          sc.gpuInfo,
          sc.gameModeStatus,
          SystemMonitor.instance.stats,
        ]),
        builder: (context, _) {
          final pipe = NexusPipeline.instance;
          // STT: движок · устройство.
          final gigaam = app.sttSidecarEngine == 'gigaam';
          final stt = gigaam ? 'GigaAM-v3' : 'Whisper · ${app.whisperModel}';
          final device = (sc.deviceStatus.value?.$2 ?? app.sttDevice)
              .toUpperCase();
          // LLM: модель @ хост (или on-device).
          final local = app.isLocalModel(app.selectedModel);
          final model = app.selectedModel.isEmpty
              ? '—'
              : _shortModel(app.selectedModel);
          final where = local
              ? 'on-device'
              : (app.inferenceMode == 'remote' && app.apiKey.isNotEmpty
                    ? 'OpenAI API'
                    : _host(app.baseUrl));
          // TTS: голос · оффлайн|сервер.
          final String tts;
          final String ttsWhere;
          if (app.cloneEnabled) {
            tts = app.t('nxTtsClone');
            ttsWhere = 'XTTS';
          } else if (app.ttsEngineChoice == 'cosyvoice') {
            tts = 'CosyVoice';
            ttsWhere = (app.cosyvoiceOnline ?? false)
                ? app.t('nxOnline')
                : app.t('nxOffline');
          } else if (app.ttsPiperVoice.isEmpty) {
            tts = app.t('nxTtsSystem');
            ttsWhere = 'pyttsx3';
          } else {
            tts = 'Piper';
            ttsWhere = app.ttsPiperVoice.replaceAll('ru_RU-', '');
          }
          final (offload, _) = sc.gameModeStatus.value;
          final gpu = sc.gpuInfo.value;
          final hasVram = gpu.$1 && gpu.$3 > 0;
          final reply = pipe.lastReplySec;
          return Row(
            children: [
              // Активный этап красится своим слотом; остальные — обычным.
              Flexible(
                child: _seg(
                  context,
                  'STT',
                  showModel ? '$stt · $device' : stt,
                  color: pipe.sttActive ? _warn(context) : null,
                ),
              ),
              _dot(context),
              Flexible(
                child: _seg(
                  context,
                  'LLM',
                  showHost
                      ? '$model @ $where'
                      : (showModel ? model : app.t('ncLlmShort')),
                  color: pipe.llmActive ? _accent(context) : null,
                ),
              ),
              _dot(context),
              Flexible(
                child: _seg(
                  context,
                  'TTS',
                  showModel ? '$tts · $ttsWhere' : tts,
                  color: pipe.ttsActive ? _info(context) : null,
                ),
              ),
              const Spacer(),
              if (offload) ...[
                Text(
                  app.t('gmOffloadBadge').toUpperCase(),
                  style: EvsType.mono.copyWith(
                    fontSize: 11,
                    color: _warn(context),
                  ),
                ),
                _dot(context),
              ],
              if (hasVram)
                Text(
                  'GPU ${(gpu.$4 / 1024).toStringAsFixed(1)} / ${(gpu.$3 / 1024).round()} ${app.t('ncGb')}',
                  style: EvsType.mono.copyWith(
                    fontSize: 11,
                    color: _sub(context),
                  ),
                ),
              if (hasVram && reply != null) _dot(context),
              if (reply != null)
                Text(
                  app.t('ncReply').replaceAll('{n}', reply.toStringAsFixed(1)),
                  style: EvsType.mono.copyWith(
                    fontSize: 11,
                    color: _sub(context),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/* ======================= КОЛЬЦО-ВИЗУАЛИЗАТОР (§6) ======================= */

// Один режим — кольцо (переключателя режимов у стиля нет; три сцены Nexus
// остаются у Nexus). Слои от внешнего к центру: ореол · внешняя окружность ·
// кольцо штрихов · сектор-развёртка · пунктирная окружность · внутренняя
// окружность · ядро · столбики уровня.
class NocturRingViz extends StatefulWidget {
  const NocturRingViz({super.key});
  @override
  State<NocturRingViz> createState() => _NocturRingVizState();
}

class _NocturRingVizState extends State<NocturRingViz>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AmbientMotion _ambient;
  late final Listenable _anim;
  double _t = 0;
  double _level = 0;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    NexusPipeline.instance.bind(context.read<AppState>());
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    // Вечные вращения — только через политику движения: balanced в простое и
    // saver держат статичный кадр (ТЗ §6).
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
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    final skin = _skin(context);
    return GestureDetector(
      onTap: () => VoiceAssistant.instance.promptOnce(),
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final pipe = NexusPipeline.instance;
          // Время идёт по реальному elapsed, а не по числу кадров — скорость
          // одинакова на 60/120/144 Гц.
          final e = _ctrl.lastElapsedDuration ?? Duration.zero;
          var dt = (e - _last).inMicroseconds / 1e6;
          _last = e;
          if (dt < 0 || dt > 0.1) dt = 0;
          _t += dt;
          final target = (pipe.stage == 'listening' || pipe.stage == 'speaking')
              ? pipe.level
              : 0.0;
          _level +=
              (target - _level) * (1 - math.pow(0.90, dt * 60).toDouble());
          return CustomPaint(
            size: Size.infinite,
            painter: _NocturRingPainter(
              t: _t,
              level: _level,
              stage: pipe.stage,
              slot: _nocturSlot(context, pipe.stage),
              skin: skin,
            ),
          );
        },
      ),
    );
  }
}

class _NocturRingPainter extends CustomPainter {
  _NocturRingPainter({
    required this.t,
    required this.level,
    required this.stage,
    required this.slot,
    required this.skin,
  });

  final double t;
  final double level;
  final String stage;
  final Color slot;
  final EvsSkin skin;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // Габарит-эталон — 334 px (ТЗ §6): всё считается от него и масштабируется.
    final box = math.min(size.width, size.height);
    final k = box / 334.0;
    // Внешняя окружность занимает почти весь габарит; ореол вылетает за него —
    // CustomPaint не обрезает, а вокруг кольца в сцене есть воздух.
    final r = box * 0.46;
    final text = skin.pal.txt;
    final line = skin.pal.stroke;

    // 1. Ореол: радиальный градиент слотом @16 %, вылет 46 px, дыхание 5.6 с.
    final breath = 0.5 + 0.5 * math.sin(t / 5.6 * 2 * math.pi);
    final haloR = r + 46 * k;
    if (skin.glow) {
      canvas.drawCircle(
        c,
        haloR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              slot.withValues(alpha: 0.16 * (0.75 + 0.25 * breath)),
              slot.withValues(alpha: 0.0),
            ],
            stops: const [0.55, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: haloR)),
      );
    } else {
      // Светлая палитра: вместо свечения — мягкая тень (ТЗ §4.2).
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = skin.pal.txt.withValues(alpha: 0.10)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 30 * k),
      );
    }

    // 2. Внешняя окружность 1 px line.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = line,
    );

    // 3. Кольцо штрихов: 100 радиальных штрихов, маска 63–100 % радиуса,
    // вращение 140 с.
    final spin = t / 140 * 2 * math.pi;
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math
          .max(0.8, r * 0.00785) // 0.45° на радиусе
      ..color = text.withValues(alpha: 0.26);
    for (var i = 0; i < 100; i++) {
      final a = spin + i * 3.6 * math.pi / 180;
      final ca = math.cos(a), sa = math.sin(a);
      canvas.drawLine(
        c + Offset(ca * r * 0.63, sa * r * 0.63),
        c + Offset(ca * r, sa * r),
        tickPaint,
      );
    }

    // 4. Сектор-развёртка: конический градиент от прозрачного к слоту, 7 с
    // (в «думаю» — 4 с), режим смешивания screen, по той же кольцевой маске.
    final sweepDur = stage == 'thinking' ? 4.0 : 7.0;
    final sweepA = (t / sweepDur % 1.0) * 2 * math.pi;
    canvas.save();
    canvas.clipPath(
      Path()
        ..addOval(Rect.fromCircle(center: c, radius: r))
        ..addOval(Rect.fromCircle(center: c, radius: r * 0.63))
        ..fillType = PathFillType.evenOdd,
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = SweepGradient(
          transform: GradientRotation(sweepA),
          // Развёртка гаснет к началу оборота, иначе на стыке 360°→0° виден
          // жёсткий шов, а не бегущий по кольцу свет.
          colors: [
            slot.withValues(alpha: 0.0),
            slot.withValues(alpha: 0.0),
            slot.withValues(alpha: stage == 'idle' ? 0.10 : 0.22),
            slot.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.30, 0.94, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.restore();

    // 5. Пунктирная окружность text @12 %, против часовой, 90 с.
    final dashR = r * 0.55;
    final dashSpin = -t / 90 * 2 * math.pi;
    final dashPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = text.withValues(alpha: 0.12);
    const dashes = 64;
    for (var i = 0; i < dashes; i++) {
      final a0 = dashSpin + i * 2 * math.pi / dashes;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: dashR),
        a0,
        math.pi / dashes * 0.9,
        false,
        dashPaint,
      );
    }

    // 6. Внутренняя окружность 1 px слотом @45 %, дыхание 4.2 с.
    final breath2 = 0.5 + 0.5 * math.sin(t / 4.2 * 2 * math.pi);
    canvas.drawCircle(
      c,
      r * 0.42 * (0.985 + 0.03 * breath2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = slot.withValues(alpha: 0.45),
    );

    // 7. Ядро 9 px слотом со свечением 22 px.
    if (skin.glow) {
      canvas.drawCircle(
        c,
        4.5 * k,
        Paint()
          ..color = slot.withValues(alpha: 0.75)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 22 * k),
      );
    }
    canvas.drawCircle(c, 4.5 * k, Paint()..color = slot);

    // 8. Уровень: 5 столбиков 2 px под кольцом, видны в «слушаю» и «говорю».
    if (stage == 'listening' || stage == 'speaking') {
      final barW = 2 * k;
      final gap = 5 * k;
      final baseY = c.dy + r + 18 * k;
      final total = 5 * barW + 4 * gap;
      var x = c.dx - total / 2 + barW / 2;
      const shape = [0.5, 0.8, 1.0, 0.75, 0.45];
      for (var i = 0; i < 5; i++) {
        final h = (6 + 26 * level * shape[i]) * k;
        canvas.drawLine(
          Offset(x, baseY),
          Offset(x, baseY - h),
          Paint()
            ..strokeWidth = barW
            ..strokeCap = StrokeCap.round
            ..color = slot.withValues(alpha: 0.85),
        );
        x += barW + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_NocturRingPainter old) =>
      old.t != t ||
      old.level != level ||
      old.stage != stage ||
      old.slot != slot ||
      old.skin.pal.bg != skin.pal.bg;
}

/* ======================= ГЛАВНЫЙ ЭКРАН (§5.2) ======================= */

class _NocturStage extends StatefulWidget {
  const _NocturStage();
  @override
  State<_NocturStage> createState() => _NocturStageState();
}

class _NocturStageState extends State<_NocturStage> {
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    NexusPipeline.instance.bind(app);
    // Тот же живой уровень микрофона, что у Nexus, — им дышит кольцо.
    MicMeter.instance.start(deviceId: app.inputDeviceId);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final app = context.read<AppState>();
    app.buzz();
    _input.clear();
    setState(() => _sending = true);
    await app.sendMessage(text);
    if (mounted) setState(() => _sending = false);
  }

  // 1. Строка состояния: кикер, точка + название, подсказка; справа —
  // слово-активатор и глобальный хоткей в контурных капсулах.
  Widget _stateRow(BuildContext context, AppState app, double width) {
    final hint = width >= 900;
    final wide = width >= 1080;
    return AnimatedBuilder(
      animation: NexusPipeline.instance,
      builder: (context, _) {
        final stage = NexusPipeline.instance.stage;
        final slot = _nocturSlot(context, stage);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.t('ncStateKicker'),
                    style: EvsType.mono.copyWith(
                      fontSize: 10.5,
                      letterSpacing: 10.5 * 0.2,
                      color: _faint(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _NocturDot(color: slot, size: 8),
                      const SizedBox(width: 10),
                      Text(
                        _nocturStateLabel(app, stage),
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.21,
                          color: slot,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _nocturStateHint(app, stage),
                    style: TextStyle(fontSize: 12.5, color: _faint(context)),
                  ),
                ],
              ),
            ),
            // Слово-активатор берётся из настроек, не хардкод. В узком окне
            // подсказка сворачивается до одного слова и затем исчезает (§7).
            if (hint) ...[
              _NocturCapsule(label: '«${app.wakeWord}»'),
              if (wide) ...[
                const SizedBox(width: 8),
                const _NocturCapsule(label: 'Ctrl+Shift+Space'),
              ],
            ],
          ],
        );
      },
    );
  }

  // 3. Цепочка конвейера: VAD — STT — LLM — TTS.
  Widget _chain(BuildContext context) {
    return AnimatedBuilder(
      animation: NexusPipeline.instance,
      builder: (context, _) {
        final pipe = NexusPipeline.instance;
        final nodes = <(String, bool, Color)>[
          ('VAD', pipe.vadActive, _warn(context)),
          ('STT', pipe.sttActive, _warn(context)),
          ('LLM', pipe.llmActive, _accent(context)),
          ('TTS', pipe.ttsActive, _info(context)),
        ];
        final children = <Widget>[];
        for (var i = 0; i < nodes.length; i++) {
          final (label, active, slot) = nodes[i];
          final color = active ? slot : _faint(context);
          if (i > 0) {
            children.add(
              const SizedBox(
                width: 56,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: _NocturRule(fade: 12),
                ),
              ),
            );
          }
          children.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NocturDot(color: color, size: 5),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: EvsType.mono.copyWith(
                    fontSize: 10.5,
                    letterSpacing: 10.5 * 0.16,
                    color: color,
                  ),
                ),
              ],
            ),
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        );
      },
    );
  }

  // 4. Транскрипт: реплика пользователя и ответ, ширина ≤ 820. Уважает
  // showPartial — пока идёт распознавание, показывается промежуточный текст.
  Widget _transcript(BuildContext context, AppState app) {
    final msgs = app.current?.messages ?? const <ChatMessage>[];
    String? user, reply;
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (reply == null && m.role != 'user') reply = m.content;
      if (user == null && m.role == 'user') user = m.content;
      if (user != null && reply != null) break;
    }
    return StreamBuilder<String>(
      stream: app.showPartial ? SidecarClient.instance.partial : null,
      builder: (context, snap) {
        final partial = (snap.data ?? '').trim();
        final userLine = partial.isNotEmpty ? partial : (user ?? '');
        if (userLine.isEmpty && (reply ?? '').isEmpty) {
          return const SizedBox.shrink();
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (userLine.isNotEmpty)
                Text(
                  userLine,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.45,
                    color: partial.isNotEmpty ? _sub(context) : _txt(context),
                  ),
                ),
              if ((reply ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    reply!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.55,
                      color: _sub(context),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // 5. Поле ввода 42 px + контурная кнопка микрофона 42×42.
  Widget _inputRow(BuildContext context, AppState app) {
    final skin = _skin(context);
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 42,
            child: TextField(
              controller: _input,
              enabled: !_sending,
              onSubmitted: (_) => _send(),
              style: TextStyle(fontSize: 13.5, color: _txt(context)),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                hintText: app
                    .t('ncAskPlaceholder')
                    .replaceAll('{w}', app.wakeWord),
                hintStyle: TextStyle(fontSize: 13.5, color: _faint(context)),
                filled: false,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(skin.radiusControl),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(skin.radiusControl),
                  borderSide: BorderSide(color: _accent(context)),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(skin.radiusControl),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: app.t('vaListening'),
          child: InkWell(
            borderRadius: BorderRadius.circular(skin.radiusControl),
            onTap: () => VoiceAssistant.instance.promptOnce(),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(skin.radiusControl),
                border: Border.all(color: _accent(context)),
              ),
              child: Icon(
                Icons.mic_none_rounded,
                size: 18,
                color: _accent(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return LayoutBuilder(
      builder: (context, c) {
        // Поля экрана 40 (узкое окно — 26); кольцо 334 → 268 → 212 (§7).
        final narrow = c.maxWidth < 1100;
        final pad = narrow ? 26.0 : 40.0;
        final ring = c.maxWidth < 980
            ? (c.maxWidth < 900 ? 212.0 : 268.0)
            : 334.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(pad, 22, pad, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _stateRow(context, app, c.maxWidth),
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: ring,
                    height: ring,
                    child: const NocturRingViz(),
                  ),
                ),
              ),
              _chain(context),
              const SizedBox(height: 20),
              _transcript(context, app),
              const SizedBox(height: 18),
              _inputRow(context, app),
            ],
          ),
        );
      },
    );
  }
}

// Контурная капсула (слово-активатор, хоткей).
class _NocturCapsule extends StatelessWidget {
  const _NocturCapsule({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: _stroke(context)),
    ),
    child: Text(
      label,
      style: EvsType.mono.copyWith(fontSize: 11, color: _sub(context)),
    ),
  );
}

/* ============================ ОКНО (§5) ============================ */

class _NocturHome extends StatefulWidget {
  const _NocturHome();
  @override
  State<_NocturHome> createState() => _NocturHomeState();
}

class _NocturHomeState extends State<_NocturHome> {
  NocturTab _tab = NocturTab.dialog;
  // Главный экран (макет 1a) — отдельное место назначения, а не вкладка:
  // вкладок в шапке четыре, а экранов пять. Возврат на него — по марке
  // «EVS» слева, поэтому пока мы на нём, ни одна вкладка не подсвечена.
  bool _home = true;

  // У всех четырёх вкладок свои экраны; настройки открываются шестерёнкой
  // поверх окна, как в макете.
  void _openTab(NocturTab t) {
    if (t == _tab && !_home) return;
    switch (t) {
      case NocturTab.dialog:
      case NocturTab.commands:
      case NocturTab.log:
      case NocturTab.models:
        setState(() {
          _tab = t;
          _home = false;
        });
    }
  }

  @override
  void initState() {
    super.initState();
    // «Что нового» после обновления: раньше диалог жил внутри ChatScreen,
    // которого в этой оболочке нет, поэтому «Ноктюрн» после обновления молчал.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final app = context.read<AppState>();
      final entry = await app.consumeWhatsNew();
      if (!mounted || entry == null) return;
      unawaited(showDialog<void>(
        context: context,
        builder: (_) => _NocturWhatsNew(entry),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    return Scaffold(
      backgroundColor: _bg(context),
      drawerEdgeDragWidth: 24,
      // История диалогов — выдвижной ящик (в «Ноктюрне» нет постоянной колонки
      // чата; отдельный экран диалога — этап 3).
      drawer: const Drawer(
        width: 320,
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(),
        child: ConversationsSheet(embedded: true),
      ),
      body: Container(
        decoration: _evsShellBg(context),
        child: Column(
          children: [
            NocturTopBar(
              tab: _home ? null : _tab,
              onTab: _openTab,
              onHome: () => setState(() => _home = true),
            ),
            Expanded(
              child: _home
                  ? const _NocturStage()
                  : switch (_tab) {
                      NocturTab.dialog => const _NocturDialogTab(),
                      NocturTab.commands => const _NocturCommandsTab(),
                      NocturTab.log => const _NocturLogTab(),
                      NocturTab.models => const _NocturModelsTab(),
                    },
            ),
            const NocturStatusStrip(),
          ],
        ),
      ),
    );
  }
}

/* ======================= ВКЛАДКА «ДИАЛОГ» (§5.5) =======================
   История — отдельный экран, а не постоянная колонка: слева список диалогов
   268 px (поиск, группы, активный со штрихом accent), справа тред и композер. */

class _NocturDialogTab extends StatefulWidget {
  const _NocturDialogTab();
  @override
  State<_NocturDialogTab> createState() => _NocturDialogTabState();
}

class _NocturDialogTabState extends State<_NocturDialogTab> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _input = TextEditingController();
  final ScrollController _thread = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Экран истории без выбранного диалога — пустая правая половина; открываем
    // последний, как показано в макете. Пустое состояние остаётся только когда
    // диалогов нет вовсе.
    final app = context.read<AppState>();
    if (app.current != null) _scrollDown(animate: false);
    if (app.current == null && app.conversations.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final latest = app.latest;
        if (mounted && latest != null && app.current == null) {
          app.openChat(latest);
          _scrollDown(animate: false);
        }
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _input.dispose();
    _thread.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final app = context.read<AppState>();
    app.buzz();
    _input.clear();
    setState(() => _sending = true);
    await app.sendMessage(text);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _scrollDown({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_thread.hasClients) return;
      final end = _thread.position.maxScrollExtent;
      if (animate) {
        _thread.animateTo(
          end,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        // Открытый диалог показывается с конца, а не с первой реплики — без
        // этого последние сообщения оказываются под композером.
        _thread.jumpTo(end);
      }
    });
  }

  // Группы списка: закреплённые, затем по дате последнего изменения.
  String _groupOf(AppState app, Conversation c) {
    if (c.pinned) return app.t('ncGrpPinned');
    final now = DateTime.now();
    final d = DateTime(c.updatedAt.year, c.updatedAt.month, c.updatedAt.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    if (diff <= 0) return app.t('ncGrpToday');
    if (diff == 1) return app.t('ncGrpYesterday');
    return app.t('ncGrpEarlier');
  }

  String _preview(Conversation c) {
    if (c.messages.isEmpty) return '';
    return c.messages.last.content.replaceAll('\n', ' ').trim();
  }

  Widget _column(BuildContext context, AppState app) {
    final q = _search.text.trim().toLowerCase();
    final list = [...app.conversations]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final filtered = q.isEmpty
        ? list
        : list
              .where(
                (c) =>
                    c.title.toLowerCase().contains(q) ||
                    c.messages.any((m) => m.content.toLowerCase().contains(q)),
              )
              .toList();
    // Закреплённые идут первой группой, остальное — по дате.
    final groups = <String, List<Conversation>>{};
    for (final c in filtered) {
      groups.putIfAbsent(_groupOf(app, c), () => []).add(c);
    }
    final order = [
      app.t('ncGrpPinned'),
      app.t('ncGrpToday'),
      app.t('ncGrpYesterday'),
      app.t('ncGrpEarlier'),
    ];
    return Container(
      width: 268,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: _stroke(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: SizedBox(
              height: 34,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 12.5, color: _txt(context)),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(
                    Icons.search,
                    size: 15,
                    color: _faint(context),
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  hintText: app.t('ncSearchChats'),
                  hintStyle: TextStyle(fontSize: 12.5, color: _faint(context)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      _skin(context).radiusControl,
                    ),
                    borderSide: BorderSide(color: _stroke(context)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      _skin(context).radiusControl,
                    ),
                    borderSide: BorderSide(color: _accent(context)),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                for (final g in order)
                  if ((groups[g] ?? const []).isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                      child: Text(
                        g.toUpperCase(),
                        style: EvsType.mono.copyWith(
                          fontSize: 10.5,
                          letterSpacing: 10.5 * 0.2,
                          color: _faint(context),
                        ),
                      ),
                    ),
                    for (final c in groups[g]!) _chatRow(context, app, c),
                  ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: SizedBox(
              height: 34,
              child: OutlinedButton.icon(
                onPressed: () {
                  app.newChat();
                  _input.clear();
                },
                icon: const Icon(Icons.add, size: 15),
                label: Text(
                  app.t('newChat'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _body(context),
                  side: BorderSide(color: _stroke(context)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      _skin(context).radiusControl,
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

  Widget _chatRow(BuildContext context, AppState app, Conversation c) {
    final active = app.current?.id == c.id;
    final preview = _preview(c);
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          showChatContextMenu(context, d.globalPosition, c, app),
      child: InkWell(
        onTap: () {
          app.openChat(c);
          _scrollDown(animate: false);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
          decoration: BoxDecoration(
            // Активный элемент — подложка accent @ 12 % и сплошной штрих слева.
            color: active
                ? _accent(context).withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: active ? _accent(context) : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (c.pinned) ...[
                    Icon(Icons.push_pin, size: 11, color: _faint(context)),
                    const SizedBox(width: 5),
                  ],
                  Expanded(
                    child: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: active ? _txt(context) : _body(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _evsRelTime(app, c.updatedAt),
                    style: EvsType.mono.copyWith(
                      fontSize: 10.5,
                      color: _faint(context),
                    ),
                  ),
                ],
              ),
              if (preview.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: _faint(context)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Тред: заголовок с мета-строкой, реплики, композер.
  Widget _threadPane(BuildContext context, AppState app) {
    final conv = app.current;
    if (conv == null) {
      return Center(
        child: Text(
          app.t('ncNoChat'),
          style: TextStyle(fontSize: 13, color: _faint(context)),
        ),
      );
    }
    final model = conv.rpConfig?.lockedModel ?? app.selectedModel;
    final meta = [
      _evsRelTime(app, conv.updatedAt),
      if (model.isNotEmpty) model.replaceFirst('local:', ''),
      app.t('ncReplies').replaceAll('{n}', '${conv.messages.length}'),
    ].join('  ·  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 20, 40, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                conv.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.21,
                  color: _txt(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: EvsType.mono.copyWith(
                  fontSize: 11,
                  color: _faint(context),
                ),
              ),
              const SizedBox(height: 14),
              const _NocturRule(),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _thread,
            padding: const EdgeInsets.fromLTRB(40, 18, 40, 10),
            itemCount: conv.messages.length,
            itemBuilder: (context, i) => _message(
              context,
              app,
              conv,
              conv.messages[i],
              last: i == conv.messages.length - 1,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 6, 40, 18),
          child: _composer(context, app),
        ),
      ],
    );
  }

  Widget _message(
    BuildContext context,
    AppState app,
    Conversation conv,
    ChatMessage m, {
    required bool last,
  }) {
    final skin = _skin(context);
    if (m.role == 'user') {
      // Реплика пользователя — контурный пузырь accent @ 12 %.
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(skin.radiusCard),
                color: _accent(context).withValues(alpha: 0.12),
                border: Border.all(
                  color: _accent(context).withValues(alpha: 0.35),
                ),
              ),
              child: SelectableText(
                m.content,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: _txt(context),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // Ответ — плоский текст с мета-строкой mono. Модель и «озвучено» на
    // отдельные сообщения нигде не сохраняются, поэтому в мета-строке только
    // то, что действительно известно: время (и длительность последнего ответа).
    final reply = last ? NexusPipeline.instance.lastReplySec : null;
    final metaParts = [
      '${m.time.hour.toString().padLeft(2, '0')}:'
          '${m.time.minute.toString().padLeft(2, '0')}',
      if (reply != null) '${reply.toStringAsFixed(1)} ${app.t('ncSec')}',
    ];
    final streaming = last && app.isGenerating;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SelectableText(
                    m.content,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.55,
                      color: _body(context),
                    ),
                  ),
                ),
                if (streaming) const _NocturCaret(),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            metaParts.join('  ·  '),
            style: EvsType.mono.copyWith(
              fontSize: 10.5,
              color: _faint(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context, AppState app) {
    final skin = _skin(context);
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(skin.radiusControl),
      borderSide: BorderSide(color: c),
    );
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 42,
            child: TextField(
              controller: _input,
              enabled: !_sending,
              onSubmitted: (_) => _send(),
              style: TextStyle(fontSize: 13.5, color: _txt(context)),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                hintText: app.t('ncComposerHint'),
                hintStyle: TextStyle(fontSize: 13.5, color: _faint(context)),
                enabledBorder: border(_stroke(context)),
                focusedBorder: border(_accent(context)),
                disabledBorder: border(_stroke(context)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _NocturIconBtn(
          icon: Icons.mic_none_rounded,
          onTap: () => VoiceAssistant.instance.promptOnce(),
        ),
        const SizedBox(width: 8),
        _NocturIconBtn(
          icon: Icons.arrow_upward_rounded,
          accent: true,
          onTap: _send,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _column(context, app),
        Expanded(child: _threadPane(context, app)),
      ],
    );
  }
}

// Каретка потока: прямоугольник accent 7×15 с миганием 1 с (§5.5).
class _NocturCaret extends StatefulWidget {
  const _NocturCaret();
  @override
  State<_NocturCaret> createState() => _NocturCaretState();
}

class _NocturCaretState extends State<_NocturCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 3),
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Opacity(
        opacity: _c.value < 0.5 ? 1 : 0,
        child: Container(width: 7, height: 15, color: _accent(context)),
      ),
    ),
  );
}

// Контурная квадратная кнопка 42×42 (микрофон / отправка).
class _NocturIconBtn extends StatelessWidget {
  const _NocturIconBtn({
    required this.icon,
    required this.onTap,
    this.accent = false,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? _accent(context) : _sub(context);
    return InkWell(
      borderRadius: BorderRadius.circular(_skin(context).radiusControl),
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_skin(context).radiusControl),
          border: Border.all(
            color: accent ? _accent(context) : _stroke(context),
          ),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}

/* ====================== ВКЛАДКА «КОМАНДЫ» (§5.6) ======================
   Таблица вместо карточек: фраза-триггер · действие · тип · отклик, а два
   глобальных правила (порог совпадения и подтверждение) закреплены внизу. */

class _NocturCommandsTab extends StatefulWidget {
  const _NocturCommandsTab();
  @override
  State<_NocturCommandsTab> createState() => _NocturCommandsTabState();
}

class _NocturCommandsTabState extends State<_NocturCommandsTab> {
  final TextEditingController _search = TextEditingController();
  VoiceCommandType? _filter;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // Опасными считаются ровно те же типы, что и при исполнении команды
  // (SidecarClient._runCommand): shell и системные действия.
  bool _risky(VoiceCommand c) =>
      c.type == VoiceCommandType.shell || c.type == VoiceCommandType.system;

  String _typeLabel(AppState app, VoiceCommandType t) => switch (t) {
    VoiceCommandType.app => app.t('typeApp'),
    VoiceCommandType.file => app.t('typeFile'),
    VoiceCommandType.url => app.t('typeWeb'),
    VoiceCommandType.shell => 'Shell',
    VoiceCommandType.system => app.t('typeSystem'),
    VoiceCommandType.media => app.t('typeMedia'),
    VoiceCommandType.appVolume => app.t('typeAppVolume'),
  };

  Future<void> _add(AppState app) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app),
    );
    if (cmd != null) app.addVoiceCommand(cmd);
  }

  Future<void> _edit(AppState app, VoiceCommand c) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app, initial: c),
    );
    if (cmd != null) app.replaceVoiceCommand(c, cmd);
  }

  Future<void> _suggest(AppState app) async {
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _SuggestCommandsDialog(app),
    );
    if (n != null && n > 0 && mounted) {
      showAppSnackBar(
        context,
        app.t('cmdSuggestSaved').replaceAll('{n}', '$n'),
      );
    }
  }

  Future<void> _rowMenu(AppState app, VoiceCommand c, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      color: _card2(context),
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(value: 'edit', child: Text(app.t('ncEdit'))),
        PopupMenuItem(value: 'run', child: Text(app.t('run'))),
        PopupMenuItem(value: 'delete', child: Text(app.t('delete'))),
      ],
    );
    if (v == 'edit') await _edit(app, c);
    if (v == 'delete') app.removeVoiceCommand(c);
    if (v == 'run') {
      final ok = await CommandExecutor.instance.execute(c);
      if (mounted) {
        showAppSnackBar(context, ok ? app.t('cmdRunOk') : app.t('cmdRunFail'));
      }
    }
  }

  Widget _filterTag(BuildContext context, String label, VoiceCommandType? t) {
    final active = _filter == t;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _filter = t),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: active
                ? _accent(context).withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border.all(
              color: active ? _accent(context) : _stroke(context),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: active ? _accent(context) : _sub(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _head(BuildContext context, String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Text(
        label.toUpperCase(),
        style: EvsType.mono.copyWith(
          fontSize: 10.5,
          letterSpacing: 10.5 * 0.2,
          color: _faint(context),
        ),
      ),
    ),
  );

  Widget _row(BuildContext context, AppState app, VoiceCommand c) {
    return Builder(
      builder: (rowCtx) => InkWell(
        onTap: () => _edit(app, c),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _divider(context))),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          c.phrase,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: _txt(context)),
                        ),
                      ),
                    ),
                    if (_risky(c)) ...[
                      const SizedBox(width: 8),
                      // Опасная команда — контурный тег danger.
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _danger(context).withValues(alpha: 0.55),
                          ),
                        ),
                        child: Text(
                          app.t('ncCmdNeedsConfirm'),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: _danger(context),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(
                    c.value.isEmpty ? '—' : c.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EvsType.mono.copyWith(
                      fontSize: 12,
                      color: _sub(context),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _stroke(context)),
                    ),
                    child: Text(
                      _typeLabel(app, c.type),
                      style: TextStyle(fontSize: 11, color: _sub(context)),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  c.speakPhrase.isEmpty ? '—' : c.speakPhrase,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: _faint(context)),
                ),
              ),
              SizedBox(
                width: 34,
                child: InkResponse(
                  radius: 18,
                  onTap: () {
                    final box = rowCtx.findRenderObject() as RenderBox?;
                    final pos = box == null
                        ? Offset.zero
                        : box.localToGlobal(box.size.centerRight(Offset.zero));
                    _rowMenu(app, c, pos);
                  },
                  child: Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: _faint(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Два глобальных правила, закреплённых внизу экрана.
  Widget _rules(BuildContext context, AppState app) {
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 0),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.t('cmdThreshold'),
                  style: TextStyle(fontSize: 13, color: _body(context)),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          value: app.cmdThreshold.clamp(0.3, 0.95),
                          min: 0.3,
                          max: 0.95,
                          activeColor: _accent(context),
                          inactiveColor: _stroke(context),
                          onChanged: (v) => app.setCmdThreshold(v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      app.cmdThreshold.toStringAsFixed(2),
                      style: EvsType.mono.copyWith(
                        fontSize: 12,
                        color: _txt(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.t('cmdConfirm'),
                  style: TextStyle(fontSize: 13, color: _body(context)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final (id, label) in [
                      ('always', app.t('cmdConfirmAlways')),
                      ('risky', app.t('cmdConfirmRisky')),
                      ('never', app.t('cmdConfirmNever')),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(
                            _skin(context).radiusControl,
                          ),
                          onTap: () => app.setCmdConfirm(id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                _skin(context).radiusControl,
                              ),
                              color: app.cmdConfirm == id
                                  ? _accent(context).withValues(alpha: 0.12)
                                  : Colors.transparent,
                              border: Border.all(
                                color: app.cmdConfirm == id
                                    ? _accent(context)
                                    : _stroke(context),
                              ),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                color: app.cmdConfirm == id
                                    ? _accent(context)
                                    : _sub(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final q = _search.text.trim().toLowerCase();
    final all = app.voiceCommands;
    final list = all.where((c) {
      if (_filter != null && c.type != _filter) return false;
      if (q.isEmpty) return true;
      return c.phrase.toLowerCase().contains(q) ||
          c.value.toLowerCase().contains(q);
    }).toList();
    final confirmLabel = switch (app.cmdConfirm) {
      'always' => app.t('cmdConfirmAlways'),
      'never' => app.t('cmdConfirmNever'),
      _ => app.t('cmdConfirmRisky'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 22, 40, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.t('ncTabCommands'),
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.21,
                        color: _txt(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${all.length} · ${app.t('cmdThreshold').toLowerCase()} '
                      '${app.cmdThreshold.toStringAsFixed(2)} · '
                      '${confirmLabel.toLowerCase()}',
                      style: EvsType.mono.copyWith(
                        fontSize: 11,
                        color: _faint(context),
                      ),
                    ),
                  ],
                ),
              ),
              _NocturButton(
                label: app.t('cmdSuggest'),
                onTap: () => _suggest(app),
              ),
              const SizedBox(width: 8),
              _NocturButton(
                label: app.t('cmdAdd'),
                primary: true,
                onTap: () => _add(app),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _NocturRule(),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 260,
                height: 34,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 12.5, color: _txt(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      Icons.search,
                      size: 15,
                      color: _faint(context),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    hintText: app.t('ncSearch'),
                    hintStyle: TextStyle(
                      fontSize: 12.5,
                      color: _faint(context),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        _skin(context).radiusControl,
                      ),
                      borderSide: BorderSide(color: _stroke(context)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        _skin(context).radiusControl,
                      ),
                      borderSide: BorderSide(color: _accent(context)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterTag(context, app.t('ncAll'), null),
                      for (final t in VoiceCommandType.values)
                        _filterTag(context, _typeLabel(app, t), t),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                _head(context, app.t('ncColPhrase'), flex: 3),
                _head(context, app.t('ncColAction'), flex: 4),
                _head(context, app.t('ncColType'), flex: 2),
                _head(context, app.t('ncColReply'), flex: 3),
                const SizedBox(width: 34),
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      app.t('ncNoCommands'),
                      style: TextStyle(fontSize: 13, color: _faint(context)),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) => _row(context, app, list[i]),
                  ),
          ),
          _rules(context, app),
        ],
      ),
    );
  }
}

// Кнопка «Ноктюрна»: контурная (ghost) или с заливкой accent (primary).
class _NocturButton extends StatelessWidget {
  const _NocturButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final r = _skin(context).radiusControl;
    return InkWell(
      borderRadius: BorderRadius.circular(r),
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          color: primary
              ? _accent(context).withValues(alpha: 0.14)
              : Colors.transparent,
          border: Border.all(
            color: primary ? _accent(context) : _stroke(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: primary ? _accent(context) : _body(context),
          ),
        ),
      ),
    );
  }
}

/* ====================== ВКЛАДКА «ЖУРНАЛ» (§5.8) ======================
   Моноширинный поток по реальным файлам из <app-data>/logs: время · штрих
   уровня · источник · сообщение. Уровень выводится из источника, как он и
   пишется в коде (appendLog): голосовой тракт, команды, телефон, ошибки. */

// Одна строка журнала, разобранная из файла `<iso>  <текст>`.
class _NocturLogLine {
  const _NocturLogLine(this.time, this.source, this.text, this.level);
  final DateTime? time;
  final String source; // ключ i18n группы
  final String text;
  final String level; // success | warn | accent | danger
}

class _NocturLogTab extends StatefulWidget {
  const _NocturLogTab();
  @override
  State<_NocturLogTab> createState() => _NocturLogTabState();
}

class _NocturLogTabState extends State<_NocturLogTab> {
  final TextEditingController _search = TextEditingController();
  String _filter = 'all';
  List<_NocturLogLine> _lines = const [];
  String _dir = '';
  bool _loading = true;

  // Файл → (группа фильтра, уровень). Ровно те имена, которыми пишет
  // appendLog(...) по всему проекту, плюс лог установщика обновления.
  static const Map<String, (String, String)> _sources = {
    'sidecar': ('voice', 'warn'),
    'commands': ('commands', 'success'),
    'remote': ('remote', 'accent'),
    'chat': ('model', 'accent'),
    'errors': ('errors', 'danger'),
    'update-runner': ('updates', 'accent'),
  };

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
    final out = <_NocturLogLine>[];
    try {
      final root = await appDataRoot();
      final sep = io.Platform.pathSeparator;
      _dir = '$root${sep}logs';
      for (final e in _sources.entries) {
        // update-runner лежит в корне данных, остальные — в logs/.
        final path = e.key == 'update-runner'
            ? '$root$sep${e.key}.log'
            : '$_dir$sep${e.key}.log';
        final f = io.File(path);
        if (!await f.exists()) continue;
        final all = await f.readAsLines();
        // Хвост: файлы дописываются вечно, а на экране нужен свежий срез.
        final tail = all.length > 400 ? all.sublist(all.length - 400) : all;
        for (final raw in tail) {
          if (raw.trim().isEmpty) continue;
          DateTime? ts;
          var text = raw;
          final sp = raw.indexOf('  ');
          if (sp > 0) {
            ts = DateTime.tryParse(raw.substring(0, sp));
            if (ts != null) text = raw.substring(sp + 2);
          }
          out.add(_NocturLogLine(ts, e.value.$1, text, e.value.$2));
        }
      }
    } catch (_) {}
    out.sort(
      (a, b) => (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)),
    );
    if (mounted) {
      setState(() {
        _lines = out;
        _loading = false;
      });
    }
  }

  Color _levelColor(BuildContext c, String level) => switch (level) {
    'danger' => _danger(c),
    'warn' => _warn(c),
    'accent' => _accent(c),
    _ => _success(c),
  };

  String _clock(DateTime? t) => t == null
      ? '--:--:--'
      : '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}:'
            '${t.second.toString().padLeft(2, '0')}';

  Widget _tag(
    BuildContext context,
    AppState app,
    String id,
    String label, {
    int? count,
  }) {
    final active = _filter == id;
    final danger = id == 'errors';
    final color = danger ? _danger(context) : _accent(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _filter = id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: active ? color.withValues(alpha: 0.12) : Colors.transparent,
            border: Border.all(color: active ? color : _stroke(context)),
          ),
          child: Text(
            count == null ? label : '$label  $count',
            style: TextStyle(
              fontSize: 11.5,
              color: active ? color : _sub(context),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final q = _search.text.trim().toLowerCase();
    final visible = _lines.where((l) {
      if (_filter != 'all' && l.source != _filter) return false;
      if (q.isEmpty) return true;
      return l.text.toLowerCase().contains(q);
    }).toList();
    final errors = _lines.where((l) => l.source == 'errors').length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 22, 40, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.t('nxNavLog'),
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.21,
                        color: _txt(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${visible.length} / ${_lines.length}',
                      style: EvsType.mono.copyWith(
                        fontSize: 11,
                        color: _faint(context),
                      ),
                    ),
                  ],
                ),
              ),
              _NocturButton(
                label: app.t('ncCopy'),
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: visible
                          .map(
                            (l) => '${_clock(l.time)}  ${l.source}  ${l.text}',
                          )
                          .join('\n'),
                    ),
                  );
                  showAppSnackBar(context, app.t('ncCopied'));
                },
              ),
              const SizedBox(width: 8),
              _NocturButton(
                label: app.t('ncLogFolder'),
                onTap: () {
                  if (_dir.isEmpty) return;
                  unawaited(io.Process.run('explorer', [_dir]));
                },
              ),
              const SizedBox(width: 8),
              _NocturButton(
                label: app.t('ncRefresh'),
                onTap: () => unawaited(_load()),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _NocturRule(),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 260,
                height: 34,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 12.5, color: _txt(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      Icons.search,
                      size: 15,
                      color: _faint(context),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    hintText: app.t('ncSearch'),
                    hintStyle: TextStyle(
                      fontSize: 12.5,
                      color: _faint(context),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        _skin(context).radiusControl,
                      ),
                      borderSide: BorderSide(color: _stroke(context)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        _skin(context).radiusControl,
                      ),
                      borderSide: BorderSide(color: _accent(context)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _tag(context, app, 'all', app.t('ncAll')),
                      _tag(context, app, 'voice', app.t('ncLogVoice')),
                      _tag(context, app, 'model', app.t('ncLogModel')),
                      _tag(context, app, 'commands', app.t('ncTabCommands')),
                      _tag(context, app, 'remote', app.t('ncLogRemote')),
                      _tag(context, app, 'updates', app.t('ncLogUpdates')),
                      _tag(
                        context,
                        app,
                        'errors',
                        app.t('ncLogErrors'),
                        count: errors,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_skin(context).radiusCard),
                border: Border.all(color: _stroke(context)),
              ),
              clipBehavior: Clip.antiAlias,
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : visible.isEmpty
                  ? Center(
                      child: Text(
                        app.t('ncLogEmpty'),
                        style: TextStyle(fontSize: 13, color: _faint(context)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: visible.length,
                      itemBuilder: (context, i) =>
                          _logRow(context, app, visible[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logRow(BuildContext context, AppState app, _NocturLogLine l) {
    final color = _levelColor(context, l.level);
    // Строки ошибок целиком красятся danger; у остальных цветом уровня —
    // только вертикальный штрих.
    final textColor = l.level == 'danger' ? _danger(context) : _sub(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              _clock(l.time),
              style: EvsType.mono.copyWith(
                fontSize: 12,
                height: 1.9,
                color: _faint(context),
              ),
            ),
          ),
          Container(
            width: 3,
            height: 15,
            margin: const EdgeInsets.only(top: 4, right: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(
            width: 78,
            child: Text(
              app.t(_sourceLabelKey(l.source)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: EvsType.mono.copyWith(
                fontSize: 12,
                height: 1.9,
                color: _faint(context),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              l.text,
              style: EvsType.mono.copyWith(
                fontSize: 12,
                height: 1.9,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _sourceLabelKey(String source) => switch (source) {
    'voice' => 'ncLogVoice',
    'model' => 'ncLogModel',
    'commands' => 'ncTabCommands',
    'remote' => 'ncLogRemote',
    'updates' => 'ncLogUpdates',
    _ => 'ncLogErrors',
  };
}

/* ====================== ВКЛАДКА «МОДЕЛИ» (§5.7) ======================
   Подключение сверху (локально / удалённый сервер), ниже — каталог по тирам.
   Всё живое: тот же каталог kLocalModels, те же загрузки и тот же выбор
   модели, что и на экране локальных моделей. */

class _NocturModelsTab extends StatefulWidget {
  const _NocturModelsTab();
  @override
  State<_NocturModelsTab> createState() => _NocturModelsTabState();
}

class _NocturModelsTabState extends State<_NocturModelsTab> {
  late final TextEditingController _url;
  LocalModelTier _tier = LocalModelTier.mid;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: context.read<AppState>().serverUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  String _gb(int bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

  Widget _card(BuildContext context, {required Widget child}) => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(_skin(context).radiusCard),
      border: Border.all(color: _stroke(context)),
    ),
    child: child,
  );

  // Сегмент режима подключения (§5.7). Ось у приложения ровно одна —
  // inferenceMode: локальный сервер (Ollama/LAN) или удалённый
  // OpenAI-совместимый. Модели «на устройстве» живут не здесь, а в каталоге
  // ниже, поэтому третьей кнопки в сегменте нет.
  Widget _modeSegment(BuildContext context, AppState app) {
    return Row(
      children: [
        for (final (id, label) in [
          ('localServer', app.t('modeLocalServer')),
          ('remote', app.t('modeRemote')),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(_skin(context).radiusControl),
              onTap: () => app.setInferenceMode(id),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(_skin(context).radiusControl),
                  color: app.inferenceMode == id
                      ? _accent(context).withValues(alpha: 0.12)
                      : Colors.transparent,
                  border: Border.all(
                      color: app.inferenceMode == id
                          ? _accent(context)
                          : _stroke(context)),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: app.inferenceMode == id
                            ? _accent(context)
                            : _sub(context))),
              ),
            ),
          ),
      ],
    );
  }

  // Карточка активной модели + карточка адреса сервера.
  Widget _connection(BuildContext context, AppState app) {
    final connected = app.connectionStatus == ConnectionStatus.connected;
    final dot = switch (app.connectionStatus) {
      ConnectionStatus.connected => _success(context),
      ConnectionStatus.connecting => _warn(context),
      ConnectionStatus.noModel => _warn(context),
      _ => _danger(context),
    };
    final active = app.selectedModel;
    final spec = app.localSpecFor(active);
    final sub = spec != null
        ? '${_gb(spec.sizeBytes)} ${app.t('ncGb')} · '
              '${spec.maxLocalContextSize} ${app.t('ncTokens')} · GGUF'
        : (active.isEmpty
              ? '—'
              : '${app.t('ncRemote')} · ${app.models.length} ${app.t('connModelsCount')}');
    // IntrinsicHeight обязателен: Row со stretch внутри Column не имеет
    // ограниченной высоты, и верстка падает (обе карточки должны быть равной
    // высоты — как в карточках подсистем Nexus).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _card(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          app.t('ncActiveModel').toUpperCase(),
                          style: EvsType.mono.copyWith(
                            fontSize: 10.5,
                            letterSpacing: 10.5 * 0.2,
                            color: _faint(context),
                          ),
                        ),
                      ),
                      _NocturDot(color: dot, size: 6),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    active.isEmpty
                        ? app.t('noModelsAvailable')
                        : (spec?.shortName ?? active),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: _txt(context),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EvsType.mono.copyWith(
                      fontSize: 11,
                      color: _sub(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _card(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.t('ncServerAddress').toUpperCase(),
                    style: EvsType.mono.copyWith(
                      fontSize: 10.5,
                      letterSpacing: 10.5 * 0.2,
                      color: _faint(context),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 34,
                          child: TextField(
                            controller: _url,
                              onSubmitted: (v) =>
                                app.setServer(v.trim(), app.apiKey),
                            style: EvsType.mono.copyWith(
                              fontSize: 12,
                              color: _txt(context),
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  _skin(context).radiusControl,
                                ),
                                borderSide: BorderSide(color: _stroke(context)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  _skin(context).radiusControl,
                                ),
                                borderSide: BorderSide(color: _accent(context)),
                              ),
                              disabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  _skin(context).radiusControl,
                                ),
                                borderSide: BorderSide(color: _stroke(context)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _NocturButton(
                        label: app.t('ncCheck'),
                        onTap: () =>
                            app.setServer(_url.text.trim(), app.apiKey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    app.loadingModels
                        ? app.t('connChecking')
                        : ((app.modelsError ?? '').isNotEmpty
                              ? app.modelsError!
                              : (connected
                                    ? '${app.t('connOnline')} · ${app.models.length} ${app.t('connModelsCount')}'
                                    : app.t('connOffline'))),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EvsType.mono.copyWith(
                      fontSize: 11,
                      color: (app.modelsError ?? '').isNotEmpty
                          ? _danger(context)
                          : _faint(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tierSegment(BuildContext context, AppState app) {
    String label(LocalModelTier t) => switch (t) {
      LocalModelTier.light => app.t('tierLight'),
      LocalModelTier.mid => app.t('tierMid'),
      LocalModelTier.high => app.t('tierHigh'),
      LocalModelTier.roleplay => app.t('tierRoleplay'),
    };
    return Row(
      children: [
        for (final t in LocalModelTier.values)
          if (kLocalModels.any((m) => m.tier == t))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(
                  _skin(context).radiusControl,
                ),
                onTap: () => setState(() => _tier = t),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      _skin(context).radiusControl,
                    ),
                    color: _tier == t
                        ? _accent(context).withValues(alpha: 0.12)
                        : Colors.transparent,
                    border: Border.all(
                      color: _tier == t ? _accent(context) : _stroke(context),
                    ),
                  ),
                  child: Text(
                    label(t),
                    style: TextStyle(
                      fontSize: 12,
                      color: _tier == t ? _accent(context) : _sub(context),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  Widget _modelCard(BuildContext context, AppState app, LocalModelSpec m) {
    final installed = app.downloadedLocalModelIds.contains(m.id);
    final progress = app.localDownloadProgress[m.id];
    final active = app.selectedModel == m.modelKey;
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_skin(context).radiusCard),
        border: Border.all(color: active ? _accent(context) : _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: _txt(context),
                  ),
                ),
              ),
              if (installed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: _accent(context).withValues(alpha: 0.12),
                    border: Border.all(
                      color: _accent(context).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    app.t('ncInstalled'),
                    style: TextStyle(fontSize: 10.5, color: _accent(context)),
                  ),
                )
              else if (progress != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _stroke(context)),
                  ),
                  child: Text(
                    '${(progress * 100).round()} %',
                    style: EvsType.mono.copyWith(
                      fontSize: 10.5,
                      color: _sub(context),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Q4_K_M · ${_gb(m.sizeBytes)} ${app.t('ncGb')} · GGUF',
            style: EvsType.mono.copyWith(fontSize: 11, color: _faint(context)),
          ),
          const SizedBox(height: 8),
          Text(
            m.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: _sub(context)),
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: _overlayFill(context, 0.1),
                valueColor: AlwaysStoppedAnimation(_accent(context)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (progress != null)
                _NocturButton(
                  label: app.t('cancel'),
                  onTap: () => app.cancelLocalModelDownload(m.id),
                )
              else if (!installed)
                _NocturButton(
                  label: app.t('download'),
                  primary: true,
                  onTap: () => unawaited(app.downloadLocalModel(m)),
                )
              else ...[
                _NocturButton(
                  label: active ? app.t('ncActive') : app.t('ncUse'),
                  primary: active,
                  onTap: () => app.selectModel(m.modelKey),
                ),
                const SizedBox(width: 8),
                _NocturButton(
                  label: app.t('delete'),
                  onTap: () => unawaited(app.deleteLocalModel(m)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final catalog = kLocalModels.where((m) => m.tier == _tier).toList();
    final installedBytes = kLocalModels
        .where((m) => app.downloadedLocalModelIds.contains(m.id))
        .fold<int>(0, (a, m) => a + m.sizeBytes);
    final gpu = SidecarClient.instance.gpuInfo.value;
    final hasVram = gpu.$1 && gpu.$3 > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 22, 40, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            app.t('nxNavModels'),
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.21,
              color: _txt(context),
            ),
          ),
          const SizedBox(height: 14),
          _modeSegment(context, app),
          const SizedBox(height: 14),
          _connection(context, app),
          const SizedBox(height: 18),
          const _NocturRule(),
          const SizedBox(height: 14),
          _tierSegment(context, app),
          const SizedBox(height: 14),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                mainAxisExtent: 168,
              ),
              itemCount: catalog.length,
              itemBuilder: (context, i) => _modelCard(context, app, catalog[i]),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${app.t('ncOnDisk')} ${_gb(installedBytes)} ${app.t('ncGb')}'
            '${hasVram ? '   ·   VRAM ${(gpu.$4 / 1024).toStringAsFixed(1)} / ${(gpu.$3 / 1024).round()} ${app.t('ncGb')}' : ''}',
            style: EvsType.mono.copyWith(fontSize: 11, color: _faint(context)),
          ),
        ],
      ),
    );
  }
}

/* ==================== «ЧТО НОВОГО» (§5.11, макет 1g) ====================
   Диалог 640 px: кикер, заголовок с версией в контурной капсуле, гаснущая
   линейка, пункты вертикальным штрихом, подвал со ссылкой на полный список.

   Показывается он и в «Ноктюрне», и в Nexus (см. _NexusHomeState): раньше
   «Что нового» жило внутри классического экрана чата (ChatScreen), которого в
   этих оболочках нет, — то есть после обновления оба стиля молчали. Цвета и
   радиусы приходят из активного скина, поэтому диалог выглядит по стилю. */
class _NocturWhatsNew extends StatelessWidget {
  const _NocturWhatsNew(this.entry);
  final ChangelogEntry entry;

  static const List<String> _stripeSlots = ['accent', 'success', 'info'];

  Color _stripe(BuildContext c, int i) => switch (_stripeSlots[i % 3]) {
        'success' => _success(c),
        'info' => _info(c),
        _ => _accent(c),
      };

  // Пункты changelog — одна строка на пункт. Первое предложение работает
  // заголовком, остальное описанием; если точки нет, пункт остаётся целиком
  // заголовком (ничего не выдумываем).
  (String, String) _split(String s) {
    final i = s.indexOf('. ');
    if (i <= 0 || i > 120) return (s, '');
    return (s.substring(0, i + 1), s.substring(i + 2).trim());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 640,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 18),
        decoration: BoxDecoration(
          color: _card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _stroke(context)),
          boxShadow: _shadow(context, y: 22, blur: 60, a: 0.28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.t('ncWhatsNewKicker'),
                style: EvsType.mono.copyWith(
                    fontSize: 10.5,
                    letterSpacing: 10.5 * 0.2,
                    color: _faint(context))),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(app.t('ncWhatsNew'),
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.26,
                        color: _txt(context))),
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _accent(context)),
                  ),
                  child: Text(entry.version,
                      style: EvsType.mono.copyWith(
                          fontSize: 11.5, color: _accent(context))),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const _NocturRule(fade: 28),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < entry.changes.length; i++)
                      Builder(builder: (context) {
                        final (title, desc) = _split(entry.changes[i]);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 3,
                                margin: const EdgeInsets.only(top: 3, right: 12),
                                height: desc.isEmpty ? 18 : 38,
                                decoration: BoxDecoration(
                                  color: _stripe(context, i),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title,
                                        style: TextStyle(
                                            fontSize: 14,
                                            height: 1.4,
                                            color: _txt(context))),
                                    if (desc.isNotEmpty)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(top: 4),
                                        child: Text(desc,
                                            style: TextStyle(
                                                fontSize: 12.5,
                                                height: 1.5,
                                                color: _sub(context))),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            const DesktopSettings(initialPage: _Pages.changelog)));
                  },
                  child: Text(app.t('ncFullChangelog'),
                      style: TextStyle(
                          fontSize: 12.5, color: _accent(context))),
                ),
                const Spacer(),
                _NocturButton(
                  label: app.t('updLater'),
                  onTap: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                _NocturButton(
                  label: app.t('gotIt'),
                  primary: true,
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
