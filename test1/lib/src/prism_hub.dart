part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — экран «Центр»
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/flutter/lib/screens/hub_screen.dart):
   слева колонка 376px — состояние ассистента и загрузка подсистем,
   справа тянется лента диалога.

   Данные настоящие:
     состояние       → NexusPipeline.instance.stage (тот же конвейер, что
                       питает сцену Nexus и кольцо «Ноктюрна»)
     шар             → AnimaLiveViz — живые уровни синтеза, а не таймер
     процессор, ОЗУ  → SystemMonitor.instance.stats
     видеопамять     → SidecarClient.instance.gpuInfo
     ответ модели    → NexusPipeline.instance.lastReplySec

   Демонстрационных чисел здесь нет: если метрика недоступна, строка не
   рисуется вовсе. Прочерк честнее выдуманного процента.
   ========================================================================== */

class _PrismHub extends StatefulWidget {
  const _PrismHub();
  @override
  State<_PrismHub> createState() => _PrismHubState();
}

class _PrismHubState extends State<_PrismHub> {
  @override
  void initState() {
    super.initState();
    // Конвейер общий на всё приложение и идемпотентен: если сцена Nexus его
    // уже подняла, повторный bind ничего не делает.
    NexusPipeline.instance.bind(context.read<AppState>());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // Узкое окно: колонки складываются одна под другую, иначе лента
        // сжимается до нечитаемой полосы.
        final narrow = c.maxWidth < 900;
        if (narrow) {
          return SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                const _PrismAssistantCard(),
                const SizedBox(height: 18),
                const _PrismSubsystems(),
                const SizedBox(height: 18),
                SizedBox(
                    height: math.max(320, c.maxHeight * 0.6),
                    child: const _PrismChatPane(header: true)),
              ],
            ),
          );
        }
        return const Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 376,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PrismAssistantCard(),
                    SizedBox(height: 18),
                    Expanded(child: _PrismSubsystems()),
                  ],
                ),
              ),
              SizedBox(width: 18),
              Expanded(child: _PrismChatPane(header: true)),
            ],
        );
      },
    );
  }
}

/// Карточка ассистента: состояние, шар, подсказка, строка задержки.
class _PrismAssistantCard extends StatelessWidget {
  const _PrismAssistantCard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return AnimatedBuilder(
      animation: Listenable.merge([
        NexusPipeline.instance,
        VoiceAssistant.instance.state,
        VoiceAssistant.instance.wakeActive,
      ]),
      builder: (context, _) {
        final stage = NexusPipeline.instance.stage;
        final idle = stage == 'idle';
        final (label, color) = _prismStatus(context, app, stage);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              ..._prismShadow(context),
              // Пока ассистент занят, карточка светится цветом состояния —
              // это видно боковым зрением, не отвлекая от текста.
              if (!idle)
                BoxShadow(
                    color: color.withValues(alpha: 0.20), blurRadius: 46),
            ],
          ),
          child: PrismPanel(
            radius: 26,
            padding: const EdgeInsets.all(22),
            child: Column(
              children: [
                Row(
                  children: [
                    PrismSectionLabel(app.t('nxAssistant')),
                    const Spacer(),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 450),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 5),
                      decoration: BoxDecoration(
                        color: idle
                            ? _prismChip(context)
                            : color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        label,
                        style: PrismType.label.copyWith(
                            fontSize: 11,
                            color: idle ? _sub(context) : color),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const _PrismOrb(),
                const SizedBox(height: 14),
                Text(
                  _prismStateHint(app, stage),
                  textAlign: TextAlign.center,
                  style: PrismType.label.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: idle ? _txt(context) : color,
                  ),
                ),
                // Вторая строка нужна только в покое: пока ассистент занят,
                // объяснять, как его позвать, поздно.
                if (idle) ...[
                  const SizedBox(height: 5),
                  Text(
                    // Чем звать, зависит от режима: при удержании клавиши
                    // слово-активатор не работает, и предлагать его — врать.
                    pttIdleHint(app) ?? app.t('ncHintIdle'),
                    textAlign: TextAlign.center,
                    style: PrismType.caption
                        .copyWith(color: _sub(context), fontSize: 12.5),
                  ),
                ],
                const SizedBox(height: 14),
                const _PrismLatencyRow(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Подпись и цвет состояния. Те же слова и та же логика, что у пилюли Nexus:
/// сначала отклик на слово-активатор, потом окно команды, потом этап конвейера.
(String, Color) _prismStatus(BuildContext c, AppState app, String stage) {
  if (VoiceAssistant.instance.wakeActive.value) {
    return ('«${app.wakeWord}» — ${app.t('vaWakeHeard')}', _success(c));
  }
  if (VoiceAssistant.instance.state.value == VaState.armed) {
    return (app.t('vaArmed'), _warn(c));
  }
  return switch (stage) {
    'listening' => (app.t('vaListening'), _warn(c)),
    'thinking' => (app.t('vaThinking'), _accent2(c)),
    'speaking' => (app.t('nxSpeaking'), _info(c)),
    _ => (app.t('nxIdle'), _faint(c)),
  };
}

/// Что ассистент делает прямо сейчас, словами. Строки общие с «Ноктюрном»:
/// одно и то же состояние не должно называться в двух стилях по-разному.
String _prismStateHint(AppState app, String stage) => switch (stage) {
      'listening' => app.t('ncHintListening'),
      'thinking' => app.t('ncHintThinking'),
      'speaking' => app.t('ncHintSpeaking'),
      _ => app.t('nxIdle'),
    };

/// Шар. Живая визуализация на настоящих уровнях синтеза — та же, что в
/// плавающем виджете, поэтому вид у ассистента везде один.
///
/// Нажатие работает ТОЛЬКО в режиме удержания: там оно и правда открывает
/// микрофон. В режиме слова-активатора нажимать не на что — кнопка, которая
/// молча ничего не делает, хуже её отсутствия.
class _PrismOrb extends StatelessWidget {
  const _PrismOrb();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ptt = app.listenMode == 'ptt';
    // Шар из макета целиком: кольца, коническое свечение и ядро с микрофоном.
    // Общая визуализация (AnimaLiveViz) здесь НЕ используется — у этого стиля
    // свой шар, и он часть его облика, а не выбираемое оформление виджета.
    const orb = SizedBox(height: 190, child: Center(child: PrismOrb()));
    if (!ptt) return orb;
    return Tooltip(
      message: app.t('pttHintHold'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Listener(
          onPointerDown: (_) => VoiceAssistant.instance.pttPress(),
          onPointerUp: (_) => VoiceAssistant.instance.pttRelease(),
          onPointerCancel: (_) => VoiceAssistant.instance.pttRelease(),
          child: orb,
        ),
      ),
    );
  }
}

/// Строка под шаром: связь с движком распознавания и время последнего ответа.
class _PrismLatencyRow extends StatelessWidget {
  const _PrismLatencyRow();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (context, status, _) {
        final online = status == SidecarStatus.connected;
        final reply = NexusPipeline.instance.lastReplySec;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _prismField(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? _success(context) : _faint(context),
                ),
              ),
              const SizedBox(width: 9),
              Text(
                online ? app.t('nxOnline') : app.t('nxOffline'),
                style: PrismType.numeric
                    .copyWith(color: _sub(context), fontSize: 11),
              ),
              const Spacer(),
              // Время ответа появляется только когда ответ был. До первого
              // обмена показывать «0 с» значило бы соврать.
              if (reply != null)
                Text(
                  '${reply.toStringAsFixed(1)} ${app.t('secShort')}',
                  style: PrismType.numeric
                      .copyWith(color: _sub(context), fontSize: 11),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Загрузка подсистем: процессор, оперативная память, видеопамять.
/// Строка появляется, только если метрика реально пришла.
class _PrismSubsystems extends StatelessWidget {
  const _PrismSubsystems();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PrismPanel(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismSectionLabel(app.t('nxSystem')),
          const SizedBox(height: 15),
          AnimatedBuilder(
            animation: Listenable.merge([
              SystemMonitor.instance.stats,
              SidecarClient.instance.gpuInfo,
            ]),
            builder: (context, _) {
              final s = SystemMonitor.instance.stats.value;
              final live = s.totalRamBytes > 0;
              final gpu = SidecarClient.instance.gpuInfo.value;
              final hasVram = gpu.$1 && gpu.$3 > 0;
              final rows = <Widget>[
                if (live)
                  _PrismMetric(
                    name: app.t('nxCpu'),
                    value: '${(s.cpu * 100).round()}%',
                    fraction: s.cpu,
                  ),
                if (live)
                  _PrismMetric(
                    name: app.t('nxRam'),
                    value: '${_prismGb(s.usedRamBytes)} / '
                        '${_prismGb(s.totalRamBytes, digits: 0)} ГБ',
                    fraction: s.ram,
                  ),
                if (hasVram)
                  _PrismMetric(
                    name: gpu.$2.isEmpty ? app.t('nxVram') : gpu.$2,
                    value: '${(gpu.$4 / 1024).toStringAsFixed(1)} / '
                        '${(gpu.$3 / 1024).round()} ГБ',
                    fraction: (gpu.$4 / gpu.$3).clamp(0.0, 1.0),
                  ),
              ];
              if (rows.isEmpty) {
                return Text(
                  app.t('nxNoTelemetry'),
                  style: PrismType.caption.copyWith(color: _faint(context)),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const SizedBox(height: 15),
                    rows[i],
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

String _prismGb(int bytes, {int digits = 1}) =>
    (bytes / (1024 * 1024 * 1024)).toStringAsFixed(digits);

class _PrismMetric extends StatelessWidget {
  const _PrismMetric({
    required this.name,
    required this.value,
    required this.fraction,
  });
  final String name, value;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    PrismType.body.copyWith(color: _body(context), fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              value,
              style: PrismType.numeric.copyWith(
                  color: _txt(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Stack(
            children: [
              Container(height: 5, color: _prismChip(context)),
              Positioned.fill(
                child: AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 800),
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
        ),
      ],
    );
  }
}
