part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — экран «Модули»
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/flutter/lib/screens/modules_screen.dart):
   три карточки подсистем, под ними график загрузки процессора и журнал.

   В макете все числа — таймер со случайными скачками. Здесь их нет ни одного:

     нейросеть      → app.connectionStatus, contextUsage, gpuInfo
     синтез речи    → animaTtsEngineLabel + SidecarClient.ttsStatus
     распознавание  → sttEngineLabel / sttRuntimeLabel + sttState + deviceStatus
     график         → SystemMonitor.instance.stats, накопленные за минуту
     журнал         → AnimaLogFeed.load() — те же файлы, что вкладка «Журнал»

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
  // Автообновление — это опрос станции и перечитывание журнала, пока экран
  // открыт. Раньше здесь копилась ещё и минутная история загрузки процессора
  // под график; графика больше нет, а с ним ушёл и посекундный таймер: панели
  // моделей секунда ни к чему, ей важно другое — успеть показать, что модель
  // уже снялась с карты.
  static const _period = Duration(seconds: 10);
  Timer? _sampler;
  bool _auto = true;

  List<AnimaLogLine> _log = const [];
  bool _logLoading = true;

  @override
  void initState() {
    super.initState();
    _sampler = Timer.periodic(_period, (_) => _refresh());
    unawaited(_loadLog());
  }

  @override
  void dispose() {
    _sampler?.cancel();
    super.dispose();
  }

  /// Перечитать станцию и журнал. По таймеру — только при включённом
  /// автообновлении; кнопкой «Обновить» — всегда, на то она и кнопка.
  void _refresh({bool force = false}) {
    if (!mounted || (!_auto && !force)) return;
    unawaited(StationMonitor.instance.refresh(context.read<AppState>()));
    unawaited(_loadLog());
  }

  Future<void> _loadLog() async {
    final lines = await AnimaLogFeed.load();
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
                onTap: () => _refresh(force: true),
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
              const models = _PrismModelsCard();
              final log = _PrismLogCard(
                  lines: _log, loading: _logLoading, onOpen: widget.onLog);
              if (c.maxWidth < 820) {
                return Column(
                  children: [models, const SizedBox(height: 16), log],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(child: models),
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

  /// Запасной путь для общего `animaGhostButton`: он зовётся из всех четырёх
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
  const _PrismModuleRow(this.name, this.value, {this.bar, this.accent = false})
      : divider = false;

  /// Полоса с подписью: ниже начинается другое железо. Нужна ровно потому, что
  /// в одной карточке сошлись метрики этого компьютера и метрики станции, а
  /// читались они как одно целое.
  const _PrismModuleRow.section(this.name)
      : value = '',
        bar = null,
        accent = false,
        divider = true;

  final String name, value;
  final double? bar;
  final bool divider;

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
        StationMonitor.instance.stats,
        VoiceAssistant.instance.lastHeard,
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
    final st = StationMonitor.instance.stats.value;
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
          // Подпись «(этот ПК)» не украшение: карта здесь местная, а модель в
          // строке ниже считается на станции. Без уточнения одно читалось как
          // другое — и по местной видеопамяти делали выводы про чужую.
          _PrismModuleRow(
            gpu.$2.isEmpty
                ? app.t('prismVramLocal')
                : '${app.t('nxGpu')} · ${animaShortHardware(gpu.$2)}',
            '${(gpu.$4 / 1024).toStringAsFixed(1)} / '
                '${(gpu.$3 / 1024).round()} ГБ',
            bar: (gpu.$4 / gpu.$3).clamp(0.0, 1.0),
          ),
        _PrismModuleRow(
          app.t('modelField'),
          app.selectedModel.isEmpty
              ? '—'
              : animaShortModel(app.selectedModel),
          accent: true,
        ),
        // Станция — та же пара чисел, но про её карту. Рисуется только когда
        // она ответила: пустая полоска врала бы ровно там, где по ней и
        // принимают решение «влезет ли ещё одна модель».
        if (st.ok) ...[
          _PrismModuleRow.section(app.t('prismStation')),
          if (st.ramTotalMb > 0) ...[
            _PrismModuleRow(
              st.cpuModel.isEmpty
                  ? app.t('nxCpu')
                  : '${app.t('nxCpu')} · ${animaShortHardware(st.cpuModel)}',
              '${(st.cpuPercent * 100).round()}%',
              bar: st.cpuPercent,
            ),
            _PrismModuleRow(
              app.t('nxRam'),
              '${(st.ramUsedMb / 1024).toStringAsFixed(1)} / '
                  '${(st.ramTotalMb / 1024).round()} ГБ',
              bar: (st.ramUsedMb / st.ramTotalMb).clamp(0.0, 1.0),
            ),
          ],
          if (st.vramTotalMb > 0)
            _PrismModuleRow(
              st.gpuName.isEmpty
                  ? app.t('nxGpu')
                  : '${app.t('nxGpu')} · ${animaShortHardware(st.gpuName)}',
              '${(st.vramUsedMb / 1024).toStringAsFixed(1)} / '
                  '${(st.vramTotalMb / 1024).round()} ГБ',
              bar: (st.vramUsedMb / st.vramTotalMb).clamp(0.0, 1.0),
            ),
          _PrismModuleRow(
            app.t('prismOnCard'),
            st.model.isEmpty
                ? app.t('prismCardFree')
                : '${animaShortModel(st.model)} · '
                    '${(st.modelVramMb / 1024).toStringAsFixed(1)} ГБ',
            accent: st.model.isNotEmpty,
          ),
        ],
      ],
    );
  }

  Widget _tts(BuildContext c, AppState app, SidecarClient sc) {
    final (engine, sub) = animaTtsEngineLabel(app);
    final connected = sc.status.value == SidecarStatus.connected;
    final ok = connected && sc.ttsAvailable;
    final st = StationMonitor.instance.stats.value;
    // Строки про карту и образец — только у клон-голоса. У Piper и системного
    // ни сервера, ни образца нет вовсе, и пустые подписи там были бы враньём.
    final clone = app.ttsEngineChoice == 'clone';
    final live = app.liveVoiceEndpoint.trim();
    final sample = app.voiceSamplePath.trim();
    return _PrismModuleCard(
      title: app.t('navSpeech'),
      status: ok ? app.t('nxOnline') : app.t('nxOffline'),
      statusColor: ok ? _success(c) : _danger(c),
      onTap: () => _openSettings(c, _Pages.voiceEngine),
      rows: [
        _PrismModuleRow(app.t('prismEngine'), engine, accent: true),
        _PrismModuleRow(app.t('prismDetails'), sub),
        if (clone && live.isNotEmpty) ...[
          _PrismModuleRow(
              app.t('prismVoiceModel'), _prismServiceLabel(app, st.live)),
          _PrismModuleRow(app.t('prismServer'), _prismHostPort(live),
              accent: true),
        ],
        if (clone && sample.isNotEmpty)
          _PrismModuleRow(app.t('prismSample'), _prismFileName(sample)),
        _PrismModuleRow(
            app.t('prismSpeech'),
            '${app.ttsRate.toStringAsFixed(1)}× · '
                '${(app.ttsVolume * 100).round()} %'),
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
        // Адрес — только когда распознаёт чужой сервер: у своих движков он
        // никакой, и строка «Сервер: —» ничего не сообщает.
        if (app.sttSidecarEngine == 'remote' &&
            app.sttRemoteUrl.trim().isNotEmpty)
          _PrismModuleRow(
              app.t('prismServer'), _prismHostPort(app.sttRemoteUrl),
              accent: true),
        _PrismModuleRow(app.t('prismDenoise'), switch (app.denoiseMode) {
          'off' => app.t('prismDenoiseOff'),
          'strong' => app.t('prismDenoiseStrong'),
          _ => app.t('prismDenoiseLight'),
        }),
        // Слово-активатор не участвует при удержании клавиши: там вся фраза и
        // есть команда, и показывать его значило бы обещать несуществующее.
        if (app.listenMode != 'ptt' && app.cmdMode == 'wakeword')
          _PrismModuleRow(app.t('cmdActivator'), app.wakeWord, accent: true),
        if (VoiceAssistant.instance.lastHeard.value.trim().isNotEmpty)
          _PrismModuleRow(app.t('prismHeard'),
              VoiceAssistant.instance.lastHeard.value.trim()),
      ],
    );
  }

  /// «100.79.130.7:8762» из «http://100.79.130.7:8762/»: в карточке важен
  /// адрес, а не схема — на неё ушла бы половина строки.
  static String _prismHostPort(String raw) =>
      raw.trim().replaceFirst(RegExp(r'^https?://'), '').split('/').first;

  /// Имя файла образца без пути: путь в строку всё равно не влезает.
  static String _prismFileName(String path) =>
      path.trim().split(RegExp(r'[\\/]')).last;

  /// Состояние соседа по карте — теми же словами, что и панель «Модели на
  /// видеокарте станции». Одно и то же состояние не должно называться на двух
  /// экранах по-разному: человек сверяет их взглядом, а не по коду.
  static String _prismServiceLabel(AppState app, StationService s) => !s.online
      ? app.t('prismModelOffline')
      : s.loading
          ? app.t('prismModelLoading')
          : s.paused
              ? app.t('prismModelPaused')
              : s.loaded
                  ? app.t('prismModelOn')
                  : app.t('prismModelOff');

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
    if (r.divider) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 1, color: _prismChip(context)),
          const SizedBox(height: 11),
          Text(r.name.toUpperCase(),
              style: PrismType.label.copyWith(
                  color: _sub(context),
                  fontSize: 10.5,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700)),
        ],
      );
    }
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
// МОДЕЛИ НА КАРТЕ И ЖУРНАЛ
// --------------------------------------------------------------------------

/// Кто занимает видеокарту станции — и рычаг к каждому.
///
/// На этом месте был график загрузки процессора. Он ничего не решал: число
/// красивое, а действий по нему не бывает. Карта у станции одна, и решения на
/// ней принимают каждый день — панель показывает, кто её держит, и даёт снять
/// или поднять любого руками.
///
/// Обычно этим занимается [GpuArbiter] сам, и панель не нужна. Нужна она
/// тогда, когда сам он не справился: сосед не отпустил память, генерация
/// ответила «нет места», станция ушла в вытеснение видеопамяти. Раньше в таком
/// случае оставалось идти на станцию через ssh.
class _PrismModelsCard extends StatefulWidget {
  const _PrismModelsCard();

  @override
  State<_PrismModelsCard> createState() => _PrismModelsCardState();
}

class _PrismModelsCardState extends State<_PrismModelsCard> {
  /// Чей запрос сейчас в пути. Пока он идёт, обе кнопки этой строки погашены:
  /// подъём модели занимает секунды, и второй щелчок за это время означал бы
  /// две загрузки подряд на одну карту.
  StationModel? _busy;

  /// Что именно затеяли и когда. Секунды идут в подпись: доли процента у
  /// подъёма весов взять неоткуда — ни один из серверов их не считает, — а
  /// «поднимаю… 8 с» отвечает на настоящий вопрос человека: не завис ли.
  bool _busyLoad = true;
  DateTime? _since;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Пока что-то поднимается или выгружается — опрашиваем станцию чаще
  /// обычного. Общий опрос ходит раз в пятнадцать секунд, и на нём переход
  /// «поднимается → на карте» показался бы с опозданием почти на полминуты.
  void _watch() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {});                      // счётчик секунд
      final st = StationMonitor.instance.stats.value;
      final busy = _busy != null ||
          st.live.loading ||
          st.studio.loading ||
          st.images.loading;
      if (!busy) {
        t.cancel();
        _tick = null;
        _since = null;
        return;
      }
      unawaited(StationMonitor.instance.refresh(context.read<AppState>()));
    });
  }

  Future<void> _set(StationModel which, bool load) async {
    final app = context.read<AppState>();
    setState(() {
      _busy = which;
      _busyLoad = load;
      _since = DateTime.now();
    });
    _watch();
    try {
      await GpuArbiter.instance.setModelLoaded(app, which, load);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// «8 с» — сколько уже идёт начатое. Пусто, пока ничего не начиналось.
  String get _elapsed {
    final t = _since;
    if (t == null) return '';
    return ' ${DateTime.now().difference(t).inSeconds} с';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: AnimatedBuilder(
        animation: StationMonitor.instance.stats,
        builder: (context, _) {
          final st = StationMonitor.instance.stats.value;
          final vram = st.vramTotalMb > 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(app.t('prismModels'),
                      style: PrismType.label.copyWith(
                          color: _txt(context),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (vram)
                    Text(
                      '${(st.vramUsedMb / 1024).toStringAsFixed(1)} / '
                      '${(st.vramTotalMb / 1024).round()} ГБ',
                      style: PrismType.numeric.copyWith(
                          color: _sub(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                ],
              ),
              if (vram) ...[
                const SizedBox(height: 10),
                _PrismVramBar(
                    fraction: (st.vramUsedMb / st.vramTotalMb).clamp(0.0, 1.0)),
              ],
              const SizedBox(height: 16),
              // У языковой модели «онлайн» ничего не значит: сервер Ollama жив
              // всегда, а модель на карте — нет. Поэтому её состояние читается
              // из списка резидентных моделей, а не из ответа сервера.
              _row(
                context,
                app,
                StationModel.llm,
                app.t('prismModelLlm'),
                st.model.isEmpty
                    ? animaShortModel(app.selectedModel)
                    : '${animaShortModel(st.model)} · '
                        '${(st.modelVramMb / 1024).toStringAsFixed(1)} ГБ',
                online: st.ok && app.serverUrl.trim().isNotEmpty,
                loaded: st.model.isNotEmpty,
              ),
              _row(context, app, StationModel.liveVoice,
                  app.t('prismModelLive'), app.t('prismModelLiveNote'),
                  online: st.live.online,
                  loaded: st.live.loaded,
                  loading: st.live.loading,
                  paused: st.live.paused),
              _row(context, app, StationModel.studioVoice,
                  app.t('prismModelStudio'), app.t('prismModelStudioNote'),
                  online: st.studio.online,
                  loaded: st.studio.loaded,
                  loading: st.studio.loading,
                  paused: st.studio.paused),
              _row(context, app, StationModel.images,
                  app.t('prismModelImages'), app.t('prismModelImagesNote'),
                  online: st.images.online,
                  loaded: st.images.loaded,
                  loading: st.images.loading),
              const SizedBox(height: 4),
              Text(app.t('prismModelsHint'),
                  style: PrismType.caption
                      .copyWith(color: _faint(context), fontSize: 11.5)),
            ],
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, AppState app, StationModel which,
      String label, String note,
      {required bool online,
      required bool loaded,
      bool paused = false,
      bool loading = false}) {
    final busy = _busy == which;
    // «Поднимается» может прийти и со стороны: голос греет сам ассистент перед
    // ответом, картинки поднимает первый же кадр с телефона. Поэтому признак
    // берётся и от сервера (`loading`), и от собственной нажатой кнопки.
    final working = busy || loading;
    final (state, color) = working
        ? (
            (busy && !_busyLoad
                    ? app.t('prismModelUnloading')
                    : app.t('prismModelLoading')) +
                (busy ? _elapsed : ''),
            _warn(context)
          )
        : !online
            ? (app.t('prismModelOffline'), _faint(context))
            : paused
                ? (app.t('prismModelPaused'), _sub(context))
                : loaded
                    ? (app.t('prismModelOn'), _success(context))
                    : (app.t('prismModelOff'), _sub(context));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PrismType.body
                              .copyWith(color: _txt(context), fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 6,
                      height: 6,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(state,
                        style: PrismType.caption
                            .copyWith(color: color, fontSize: 11.5)),
                  ],
                ),
                if (note.isNotEmpty)
                  Text(note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PrismType.caption.copyWith(
                          color: _faint(context),
                          fontFamily: kPrismMono,
                          fontSize: 10.5)),
                if (working) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      backgroundColor: _prismChip(context),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(_ramp(context).a2),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          _PrismGhostButton(
            label: app.t('prismModelLoad'),
            onTap: !online || loaded || working
                ? null
                : () => unawaited(_set(which, true)),
          ),
          const SizedBox(width: 8),
          _PrismGhostButton(
            label: app.t('prismModelUnload'),
            onTap: !online || !loaded || working
                ? null
                : () => unawaited(_set(which, false)),
          ),
        ],
      ),
    );
  }
}

/// Полоска занятости видеопамяти станции — та же, что в строках метрик, но во
/// всю ширину карточки: по ней и решают, влезет ли ещё одна модель.
class _PrismVramBar extends StatelessWidget {
  const _PrismVramBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Stack(
        children: [
          Container(height: 6, color: _prismChip(context)),
          Positioned.fill(
            child: AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [r.a1, r.a2]),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrismLogCard extends StatelessWidget {
  const _PrismLogCard(
      {required this.lines, required this.loading, required this.onOpen});
  final List<AnimaLogLine> lines;
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
