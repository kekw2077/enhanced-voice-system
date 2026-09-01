part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — экран «Модули»
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/flutter/lib/screens/modules_screen.dart):
   три карточки подсистем, под ними график загрузки процессора и журнал.

   В макете все числа — таймер со случайными скачками. Здесь их нет ни одного:

     нейросеть      → app.connectionStatus, contextUsage, gpuInfo
     синтез речи    → evsTtsEngineLabel + SidecarClient.ttsStatus
     распознавание  → sttEngineLabel / sttRuntimeLabel + sttState + deviceStatus
     график         → SystemMonitor.instance.stats, накопленные за минуту
     журнал         → EvsLogFeed.load() — те же файлы, что вкладка «Журнал»

   Метрика, которой нет, не рисуется. Полоска на выдуманном проценте хуже
   отсутствующей строки: по ней принимают решения.
   ========================================================================== */

class _PrismModules extends StatefulWidget {
  const _PrismModules({required this.onLog});

  /// Открыть полный журнал. В макете журнал лежит карточкой внутри настроек,
  /// а здесь у него уже был свой экран — карточка «Журнал» ведёт на него, и
  /// пункт в рейке ради этого заводить не нужно.
  final VoidCallback onLog;
  @override
  State<_PrismModules> createState() => _PrismModulesState();
}

class _PrismModulesState extends State<_PrismModules> {
  // Кольцевой буфер загрузки процессора на минуту. Своего графика у приложения
  // не было — SystemMonitor отдаёт только мгновенное значение, поэтому историю
  // копим здесь, пока экран открыт. Уходя, теряем: врать про «последние 60 с»
  // сразу после открытия нельзя, и график просто начинается с короткого хвоста.
  static const _spanSeconds = 60;
  final List<double> _cpuTrack = [];
  Timer? _sampler;
  bool _auto = true;

  List<EvsLogLine> _log = const [];
  bool _logLoading = true;

  @override
  void initState() {
    super.initState();
    _sample();
    _sampler = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
    unawaited(_loadLog());
  }

  @override
  void dispose() {
    _sampler?.cancel();
    super.dispose();
  }

  void _sample() {
    if (!_auto || !mounted) return;
    final v = SystemMonitor.instance.stats.value.cpu;
    setState(() {
      _cpuTrack.add(v.clamp(0.0, 1.0));
      if (_cpuTrack.length > _spanSeconds) _cpuTrack.removeAt(0);
    });
  }

  Future<void> _loadLog() async {
    final lines = await EvsLogFeed.load();
    if (!mounted) return;
    setState(() {
      // Последние записи сверху: на карточке помещается десяток, и это должны
      // быть свежие.
      _log = lines.reversed.take(9).toList();
      _logLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PrismSectionLabel(app.t('prismSubsystems')),
              const Spacer(),
              Text(app.t('prismAutoRefresh'),
                  style: PrismType.body
                      .copyWith(color: _sub(context), fontSize: 12.5)),
              const SizedBox(width: 10),
              PrismToggle(
                value: _auto,
                onChanged: (v) => setState(() => _auto = v),
              ),
              const SizedBox(width: 14),
              _PrismGhostButton(
                d: PrismIcons.refresh,
                label: app.t('ncRefresh'),
                onTap: () {
                  _sample();
                  unawaited(_loadLog());
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _PrismSubsystemCards(),
          const SizedBox(height: 16),
          // На узком окне график и журнал встают друг под друга: график шириной
          // в полтораста пикселей не читается.
          LayoutBuilder(
            builder: (context, c) {
              final chart = _PrismCpuChart(track: _cpuTrack, span: _spanSeconds);
              final log = _PrismLogCard(
                  lines: _log, loading: _logLoading, onOpen: widget.onLog);
              if (c.maxWidth < 820) {
                return Column(
                  children: [chart, const SizedBox(height: 16), log],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: chart),
                  const SizedBox(width: 16),
                  SizedBox(width: 300, child: log),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Кнопка-призрак в стиле «Призмы»: контур и подложка поля, без градиента —
/// это второстепенное действие, и заливать его акцентом значило бы спорить с
/// настоящей кнопкой рядом.
class _PrismGhostButton extends StatefulWidget {
  const _PrismGhostButton({
    this.d,
    this.icon,
    required this.label,
    required this.onTap,
  });

  // onTap == null — действие сейчас невозможно (нечего сохранять, нечего
  // обновлять). Кнопка гаснет и перестаёт ловить курсор, а не исчезает:
  // пропавшая кнопка заставляет искать, куда она делась.

  /// Контур иконки из макета — см. [PrismIcons]. Экраны «Призмы» передают его.
  final String? d;

  /// Запасной путь для общего `evsGhostButton`: он зовётся из всех четырёх
  /// стилей и знает только про Material-иконки. Своего контура у такого
  /// вызова нет, и рисовать его наугад было бы хуже, чем взять готовую.
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_PrismGhostButton> createState() => _PrismGhostButtonState();
}

class _PrismGhostButtonState extends State<_PrismGhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Opacity(
        opacity: on ? 1 : 0.42,
        child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color:
                _hover && on ? _prismHover(context) : _prismField(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Без значка кнопка тоже законна: «Отмена» рядом с «Сохранить»
              // не нуждается в картинке, а выдуманный значок только сбивал бы.
              if (widget.d != null) ...[
                PrismIcon(widget.d!, size: 14, stroke: 2, color: _txt(context)),
                const SizedBox(width: 8),
              ] else if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: _txt(context)),
                const SizedBox(width: 8),
              ],
              Text(widget.label,
                  style: PrismType.label
                      .copyWith(color: _txt(context), fontSize: 12.5)),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------
// КАРТОЧКИ ПОДСИСТЕМ
// --------------------------------------------------------------------------

/// Одна строка карточки: подпись, значение и, если метрика измеряется, полоска.
class _PrismModuleRow {
  const _PrismModuleRow(this.name, this.value, {this.bar, this.accent = false});
  final String name, value;
  final double? bar;

  /// Значение — не число, а имя (модель, голос, устройство). Красится акцентом
  /// и без полоски: у него нет «сколько из скольки».
  final bool accent;
}

class _PrismSubsystemCards extends StatelessWidget {
  const _PrismSubsystemCards();

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
      ]),
      builder: (context, _) {
        final cards = [
          _llm(context, app, sc),
          _tts(context, app, sc),
          _stt(context, app, sc),
        ];
        return LayoutBuilder(
          builder: (context, c) {
            // Три карточки рядом требуют примерно 800px; ниже этого они
            // складываются, иначе подписи режутся на середине слова.
            if (c.maxWidth < 800) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: 16),
                    cards[i],
                  ],
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(width: 16),
                    Expanded(child: cards[i]),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _llm(BuildContext c, AppState app, SidecarClient sc) {
    final status = app.connectionStatus;
    final (used, limit) = app.contextUsage(app.current);
    final gpu = sc.gpuInfo.value;
    final hasVram = gpu.$1 && gpu.$3 > 0;
    final (label, color) = switch (status) {
      ConnectionStatus.connected => (app.t('statusConnected'), _success(c)),
      ConnectionStatus.connecting => (app.t('statusConnecting'), _warn(c)),
      ConnectionStatus.noModel => (app.t('statusNoModel'), _warn(c)),
      _ => (app.t('statusDisconnected'), _danger(c)),
    };
    return _PrismModuleCard(
      title: app.t('prismNeural'),
      status: label,
      statusColor: color,
      onTap: () => _openSettings(c, _Pages.llmConn),
      rows: [
        if (limit > 0)
          _PrismModuleRow(
            app.t('genNumCtx'),
            '$used / $limit',
            bar: (used / limit).clamp(0.0, 1.0),
          ),
        if (hasVram)
          _PrismModuleRow(
            app.t('nxVram'),
            '${(gpu.$4 / 1024).toStringAsFixed(1)} / '
                '${(gpu.$3 / 1024).round()} ГБ',
            bar: (gpu.$4 / gpu.$3).clamp(0.0, 1.0),
          ),
        _PrismModuleRow(
          app.t('modelField'),
          app.selectedModel.isEmpty
              ? '—'
              : evsShortModel(app.selectedModel),
          accent: true,
        ),
      ],
    );
  }

  Widget _tts(BuildContext c, AppState app, SidecarClient sc) {
    final (engine, sub) = evsTtsEngineLabel(app);
    final connected = sc.status.value == SidecarStatus.connected;
    final ok = connected && sc.ttsAvailable;
    return _PrismModuleCard(
      title: app.t('navSpeech'),
      status: ok ? app.t('nxOnline') : app.t('nxOffline'),
      statusColor: ok ? _success(c) : _danger(c),
      onTap: () => _openSettings(c, _Pages.voiceEngine),
      rows: [
        _PrismModuleRow(app.t('prismEngine'), engine, accent: true),
        _PrismModuleRow(app.t('prismDetails'), sub),
      ],
    );
  }

  Widget _stt(BuildContext c, AppState app, SidecarClient sc) {
    final connected = sc.status.value == SidecarStatus.connected;
    final ready = sc.sttState.value == 'ready';
    final loaded = sc.engines.value[app.sttSidecarEngine] == true;
    final device = (sc.deviceStatus.value?.$2 ?? app.sttDevice).toUpperCase();
    final (label, color) = !connected
        ? (app.t('nxOffline'), _danger(c))
        : (ready && loaded)
            ? (app.t('nxOnline'), _success(c))
            : (app.t('statusConnecting'), _warn(c));
    return _PrismModuleCard(
      title: app.t('pgStt'),
      status: label,
      statusColor: color,
      onTap: () => _openSettings(c, _Pages.stt),
      rows: [
        _PrismModuleRow(app.t('prismEngine'), sttEngineLabel(app), accent: true),
        _PrismModuleRow(app.t('prismRuntime'),
            '${sttRuntimeLabel(app)} · $device'),
      ],
    );
  }

  static void _openSettings(BuildContext c, String page) =>
      Navigator.of(c).push(
        MaterialPageRoute(builder: (_) => DesktopSettings(initialPage: page)),
      );
}

class _PrismModuleCard extends StatelessWidget {
  const _PrismModuleCard({
    required this.title,
    required this.status,
    required this.statusColor,
    required this.rows,
    required this.onTap,
  });

  final String title, status;
  final Color statusColor;
  final List<_PrismModuleRow> rows;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: PrismPanel(
          radius: 24,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          shadow: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PrismType.label.copyWith(
                          color: _txt(context),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: statusColor),
                  ),
                  const SizedBox(width: 7),
                  Text(status,
                      style: PrismType.numeric
                          .copyWith(color: statusColor, fontSize: 11)),
                ],
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: 13),
                _row(context, rows[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _PrismModuleRow r) {
    final ramp = _ramp(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PrismType.body
                      .copyWith(color: _sub(context), fontSize: 12.5)),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                r.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: PrismType.numeric.copyWith(
                  color: r.accent ? ramp.a2 : _txt(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (r.bar != null) ...[
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              children: [
                Container(height: 4, color: _prismChip(context)),
                Positioned.fill(
                  child: AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.centerLeft,
                    widthFactor: r.bar!.clamp(0.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [ramp.a1, ramp.a2]),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// --------------------------------------------------------------------------
// ГРАФИК И ЖУРНАЛ
// --------------------------------------------------------------------------

class _PrismCpuChart extends StatelessWidget {
  const _PrismCpuChart({required this.track, required this.span});
  final List<double> track;
  final int span;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final r = _ramp(context);
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(app.t('prismCpuLoad'),
                  style: PrismType.label.copyWith(
                      color: _txt(context),
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                // Пишем, сколько НА САМОМ ДЕЛЕ накоплено, а не «последние 60 с»:
                // сразу после открытия экрана в графике три секунды.
                '${track.length} ${app.t('secShort')}',
                style: PrismType.numeric
                    .copyWith(color: _faint(context), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 120,
            child: track.length < 2
                ? Center(
                    child: Text(app.t('prismCollecting'),
                        style: PrismType.caption
                            .copyWith(color: _faint(context))),
                  )
                : CustomPaint(
                    size: Size.infinite,
                    painter: _PrismSparkPainter(
                      track: track,
                      span: span,
                      a1: r.a1,
                      a2: r.a2,
                      grid: _stroke(context),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PrismSparkPainter extends CustomPainter {
  _PrismSparkPainter({
    required this.track,
    required this.span,
    required this.a1,
    required this.a2,
    required this.grid,
  });

  final List<double> track;
  final int span;
  final Color a1, a2, grid;

  @override
  void paint(Canvas canvas, Size size) {
    // Три горизонтали — 0, 50 и 100 %. Больше линий на графике в 120 пикселей
    // читаются как сетка, а не как шкала.
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }

    // График всегда занимает всю ширину, но точки ставятся по своей позиции в
    // окне: пока минута не набралась, линия идёт слева и обрывается там, где
    // кончились данные, а не растягивается на весь холст выдуманным шагом.
    final step = size.width / (span - 1);
    Offset at(int i) =>
        Offset(i * step, size.height * (1 - track[i].clamp(0.0, 1.0)));

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < track.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }

    final last = at(track.length - 1);
    final fill = Path.from(path)
      ..lineTo(last.dx, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [a2.withValues(alpha: 0.28), a1.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(colors: [a1, a2])
            .createShader(Offset.zero & size),
    );

    canvas.drawCircle(last, 3.2, Paint()..color = a2);
  }

  @override
  bool shouldRepaint(_PrismSparkPainter old) =>
      old.track.length != track.length ||
      old.a1 != a1 ||
      (track.isNotEmpty && old.track.isNotEmpty && old.track.last != track.last);
}

class _PrismLogCard extends StatelessWidget {
  const _PrismLogCard(
      {required this.lines, required this.loading, required this.onOpen});
  final List<EvsLogLine> lines;
  final bool loading;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PrismSectionLabel(app.t('nxNavLog')),
              const Spacer(),
              _PrismGhostButton(
                label: app.t('prismLogOpen'),
                d: PrismIcons.forward,
                onTap: onOpen,
              ),
            ],
          ),
          const SizedBox(height: 11),
          if (loading)
            Text(app.t('prismCollecting'),
                style: PrismType.caption.copyWith(color: _faint(context)))
          else if (lines.isEmpty)
            Text(app.t('ncLogEmpty'),
                style: PrismType.caption.copyWith(color: _faint(context)))
          else
            for (final l in lines) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      color: _prismLogColor(context, l.level),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: PrismType.body.copyWith(
                              color: _body(context),
                              fontSize: 12.5,
                              height: 1.4),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l.time == null ? '' : _prismLogTime(l.time!),
                          style: PrismType.numeric.copyWith(
                              color: _faint(context), fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 11),
            ],
        ],
      ),
    );
  }
}

/// Цвет точки в журнале — по уровню записи, теми же слотами, что и везде.
Color _prismLogColor(BuildContext c, String level) => switch (level) {
      'danger' => _danger(c),
      'warn' => _warn(c),
      'success' => _success(c),
      _ => _ramp(c).a2,
    };

/// Время записи: сегодняшние — часами, старые — датой.
String _prismLogTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
  return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
}
