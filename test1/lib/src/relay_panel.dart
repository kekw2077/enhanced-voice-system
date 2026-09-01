part of '../main.dart';

/* ==========================================================================
   СЕТЬ — экран канала
   --------------------------------------------------------------------------
   Показывает, что происходит с каналом до игровых серверов, и позволяет
   перевести игровой трафик через VPS или вернуть напрямую.

   Все цифры приходят от агента на станции (`RelayMonitor`). Ни одна не
   считается здесь: панель только рисует. Это то же правило, по которому
   сделан экран «Модули» — метрика, которой нет, не рисуется вовсе. Полоска
   на выдуманном проценте хуже отсутствующей строки: по ней принимают решения,
   а тут решение — играть сейчас или чинить сеть.

   Отсюда же трактовка `null`. Агент отдаёт его там, где мерить нечем: туннель
   опущен — нет его задержки, на станции нет wg — нет скорости. В таких местах
   стоит прочерк и подпись почему, а не ноль.
   ========================================================================== */

/// Пороги окраски потерь. Не выдуманы: Valorant заметно сыпется на устойчивых
/// двух процентах, поэтому «плохо» начинается там, а не на классических 5–15 %,
/// при которых играть уже невозможно (ТЗ §15.3).
Color _relayLossColor(BuildContext c, double? pct) {
  if (pct == null) return _faint(c);
  if (pct >= 2.0) return _danger(c);
  if (pct >= 0.5) return _warn(c);
  return _success(c);
}

Color _relayStateColor(BuildContext c, String state) => switch (state) {
      'up' => _success(c),
      'degraded' => _warn(c),
      'down' => _danger(c),
      _ => _faint(c),
    };

String _relayStateLabel(AppState app, String state) => switch (state) {
      'up' => app.t('relayStateUp'),
      'degraded' => app.t('relayStateDegraded'),
      'down' => app.t('relayStateDown'),
      _ => app.t('relayStateUnknown'),
    };

/// Экран «Сеть». Один виджет на все четыре оболочки: «Призма» держит его
/// вкладкой (`embedded`), остальные открывают страницей.
class RelayPanel extends StatefulWidget {
  const RelayPanel({super.key, this.embedded = false});

  /// Открыт ВНУТРИ оболочки. Тогда своя полоса заголовка и заливка фона не
  /// нужны — их уже нарисовала оболочка, и вторая пара выглядела бы окном
  /// в окне.
  final bool embedded;

  @override
  State<RelayPanel> createState() => _RelayPanelState();
}

class _RelayPanelState extends State<RelayPanel> {
  final _mon = RelayMonitor.instance;
  _RelayChartSeries _series = _RelayChartSeries.loss;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _mon.addListener(_onUpdate);
    // attach читает адрес из настроек, поэтому только после первого кадра:
    // до него context.read ещё не даст AppState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mon.attach(context.read<AppState>());
    });
  }

  @override
  void dispose() {
    _mon.removeListener(_onUpdate);
    _mon.detach();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleMode(AppState app) async {
    final st = _mon.status;
    if (st == null || _switching) return;
    final target = st.tunnelActive ? 'direct' : 'tunnel';

    // Предупреждение из ТЗ §8.4: Vanguard видит изменения состояния сетевых
    // адаптеров, и на переключения посреди сессии жалуются чаще всего.
    // Смена маршрута на станции игровой ПК не задевает, но матч мы всё равно
    // не трогаем без спроса.
    if (st.gameActive == true) {
      final ok = await _confirmDuringGame(app);
      if (ok != true) return;
    }

    setState(() => _switching = true);
    final err = await _mon.setMode(target);
    if (!mounted) return;
    setState(() => _switching = false);
    if (err != null) {
      _relayToast(context, '${app.t('relaySwitchFailed')}: $err', bad: true);
    }
  }

  Future<bool?> _confirmDuringGame(AppState app) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: _card(c),
          title: Text(app.t('relayGameWarnTitle'),
              style: TextStyle(color: _txt(c), fontSize: 16)),
          content: Text(app.t('relayGameWarnBody'),
              style: TextStyle(color: _body(c), fontSize: 13.5, height: 1.5)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(app.t('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(app.t('relaySwitchAnyway'),
                    style: TextStyle(color: _warn(c)))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final body = _buildBody(context, app);
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: _bg(context),
      body: Column(
        children: [
          const _WindowTitleBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: body,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppState app) {
    if (!_mon.configured) return _RelaySetup(embedded: widget.embedded);

    final st = _mon.status;
    if (st == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mon.loading)
              Text(app.t('relayConnecting'),
                  style: PrismType.body.copyWith(color: _sub(context)))
            else ...[
              PrismIcon(PrismIcons.info,
                  size: 26, stroke: 1.6, color: _warn(context)),
              const SizedBox(height: 14),
              Text(app.t('relayNoAnswer'),
                  style: PrismType.heading.copyWith(color: _txt(context))),
              const SizedBox(height: 8),
              SizedBox(
                width: 420,
                child: Text(
                  _mon.error ?? app.t('relayNoAnswerHint'),
                  textAlign: TextAlign.center,
                  style: PrismType.caption
                      .copyWith(color: _sub(context), height: 1.5),
                ),
              ),
              const SizedBox(height: 18),
              _PrismGhostButton(
                d: PrismIcons.refresh,
                label: app.t('ncRefresh'),
                onTap: () => unawaited(_mon.refresh()),
              ),
            ],
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Связь с агентом моргнула — цифры на экране уже не свежие, и об
          // этом надо сказать прямо, не убирая их: последний известный снимок
          // полезнее пустоты.
          if (_mon.error != null) ...[
            _RelayStaleBanner(message: _mon.error!),
            const SizedBox(height: 14),
          ],
          _RelayHeader(
            status: st,
            switching: _switching,
            onToggle: () => unawaited(_toggleMode(app)),
          ),
          const SizedBox(height: 16),
          _RelayStats(status: st),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, c) {
              final chart = _RelayChart(
                points: _mon.history,
                series: _series,
                onSeries: (s) => setState(() => _series = s),
              );
              final streams = _RelayStreamCards(status: st);
              if (c.maxWidth < 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [chart, const SizedBox(height: 16), streams],
                );
              }
              // Здесь IntrinsicHeight не нужен: выравнивание по верхнему краю,
              // и высоту ряда и так задаёт самая высокая карточка. Лишний
              // проход по внутренним размерам стоил бы дороже, чем даёт.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: chart),
                  const SizedBox(width: 16),
                  SizedBox(width: 330, child: streams),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          _RelaySettingsCard(status: st),
          if (st.events.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RelayEventsCard(events: st.events),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// ШАПКА: режим и переключатель
// --------------------------------------------------------------------------

class _RelayHeader extends StatelessWidget {
  const _RelayHeader({
    required this.status,
    required this.switching,
    required this.onToggle,
  });

  final RelayStatus status;
  final bool switching;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final r = _ramp(context);
    final on = status.tunnelActive;
    // Переключать некуда, если туннель не поднят: маршрут вёл бы в интерфейс,
    // которого нет. Кнопка гаснет, а причина написана рядом — искать её в
    // журнале человек не должен.
    final canSwitch = status.tunnelUp || on;

    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
      shadow: true,
      child: LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 620;
        final left = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? r.a2 : _sub(context),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  on ? app.t('relayModeTunnel') : app.t('relayModeDirect'),
                  style: PrismType.title.copyWith(
                      color: _txt(context), fontSize: 19),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              on ? app.t('relayModeTunnelSub') : app.t('relayModeDirectSub'),
              style: PrismType.caption
                  .copyWith(color: _sub(context), height: 1.45),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _RelayChip(
                  label: status.tunnelUp
                      ? app.t('relayTunnelUp')
                      : app.t('relayTunnelDown'),
                  color: status.tunnelUp ? _success(context) : _sub(context),
                  hint: status.handshakeAgeS == null
                      ? null
                      : '${app.t('relayHandshake')} '
                          '${_relayAgo(app, status.handshakeAgeS!)}',
                ),
                if (status.riotPrefixes > 0)
                  _RelayChip(
                    label: '${status.riotPrefixes} ${app.t('relayPrefixes')}',
                    color: _sub(context),
                  ),
                // «Идёт игра» показываем, только если станция УМЕЕТ это
                // видеть. Молчание правила счёта — не то же самое, что
                // отсутствие игры, и писать «не играете» было бы выдумкой.
                if (status.gameActive != null)
                  _RelayChip(
                    label: status.gameActive!
                        ? app.t('relayGameOn')
                        : app.t('relayGameOff'),
                    color: status.gameActive! ? r.a2 : _faint(context),
                  ),
              ],
            ),
            if (status.tunnelError != null) ...[
              const SizedBox(height: 12),
              Text('${app.t('relayTunnelProblem')}: ${status.tunnelError}',
                  style: PrismType.caption.copyWith(color: _warn(context))),
            ],
          ],
        );

        final button = _RelayBigButton(
          on: on,
          busy: switching,
          enabled: canSwitch && !switching,
          label: on ? app.t('relayTurnOff') : app.t('relayTurnOn'),
          hint: canSwitch ? null : app.t('relayTunnelNeeded'),
          onTap: onToggle,
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [left, const SizedBox(height: 18), button],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: left),
            const SizedBox(width: 24),
            button,
          ],
        );
      }),
    );
  }
}

class _RelayBigButton extends StatefulWidget {
  const _RelayBigButton({
    required this.on,
    required this.busy,
    required this.enabled,
    required this.label,
    required this.onTap,
    this.hint,
  });

  final bool on, busy, enabled;
  final String label;
  final String? hint;
  final VoidCallback onTap;

  @override
  State<_RelayBigButton> createState() => _RelayBigButtonState();
}

class _RelayBigButtonState extends State<_RelayBigButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    final active = widget.enabled;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        MouseRegion(
          cursor:
              active ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Opacity(
            opacity: active ? 1 : 0.45,
            child: GestureDetector(
              onTap: active ? widget.onTap : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                    horizontal: 30, vertical: 15),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: widget.on
                      ? Border.all(color: _stroke(context))
                      : null,
                  color: widget.on
                      ? (_hover && active
                          ? _prismHover(context)
                          : _prismField(context))
                      : null,
                  gradient: widget.on
                      ? null
                      : LinearGradient(colors: [r.a1, r.a2]),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.busy)
                      SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.on ? _txt(context) : Colors.white,
                        ),
                      )
                    else
                      PrismIcon(
                        widget.on ? PrismIcons.stop : PrismIcons.play,
                        size: 15,
                        stroke: 2,
                        color: widget.on ? _txt(context) : Colors.white,
                      ),
                    const SizedBox(width: 10),
                    Text(
                      widget.label,
                      style: PrismType.label.copyWith(
                        color: widget.on ? _txt(context) : Colors.white,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.hint != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 200,
            child: Text(
              widget.hint!,
              textAlign: TextAlign.right,
              style: PrismType.caption
                  .copyWith(color: _faint(context), fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }
}

class _RelayChip extends StatelessWidget {
  const _RelayChip({required this.label, required this.color, this.hint});
  final String label;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: _prismChip(context),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 7),
          Text(label,
              style: PrismType.numeric
                  .copyWith(color: _body(context), fontSize: 11)),
        ],
      ),
    );
    return hint == null ? chip : Tooltip(message: hint!, child: chip);
  }
}

class _RelayStaleBanner extends StatelessWidget {
  const _RelayStaleBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: _warn(context).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _warn(context).withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          PrismIcon(PrismIcons.info,
              size: 15, stroke: 1.8, color: _warn(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${app.t('relayStale')} — $message',
              style: PrismType.caption
                  .copyWith(color: _body(context), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// ГЛАВНЫЕ ЦИФРЫ
// --------------------------------------------------------------------------

class _RelayStats extends StatelessWidget {
  const _RelayStats({required this.status});
  final RelayStatus status;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final r = _ramp(context);
    final win = '${status.windowS} ${app.t('secShort')}';

    final tiles = <Widget>[
      _RelayStat(
        label: app.t('relayLossChannel'),
        value: _relayPct(status.lossChannelPct),
        color: _relayLossColor(context, status.lossChannelPct),
        hint: '${app.t('relayLossChannelHint')} · $win',
      ),
      _RelayStat(
        label: app.t('relayLossEffective'),
        value: _relayPct(status.lossEffectivePct),
        color: _relayLossColor(context, status.lossEffectivePct),
        hint: '${app.t('relayLossEffectiveHint')} · $win',
      ),
      _RelayStat(
        label: app.t('relayRecovered'),
        value: status.recoveredWindow.toString(),
        color: status.recoveredWindow > 0 ? r.a2 : _faint(context),
        hint: status.recoveredTotal > 0
            ? '${app.t('relayRecoveredTotal')} ${status.recoveredTotal} · $win'
            : '${app.t('relayRecoveredHint')} · $win',
      ),
      _RelayStat(
        label: app.t('relayPing'),
        value: status.rttDirectMs == null
            ? '—'
            : '${status.rttDirectMs!.toStringAsFixed(0)} ${app.t('msShort')}',
        color: _txt(context),
        hint: _relayPingHint(app, status),
      ),
      _RelayStat(
        label: app.t('relayJitter'),
        value: status.jitterMs == null
            ? '—'
            : '${status.jitterMs!.toStringAsFixed(1)} ${app.t('msShort')}',
        color: (status.jitterMs ?? 0) > 10 ? _warn(context) : _txt(context),
        hint: app.t('relayJitterHint'),
      ),
      _RelayStat(
        label: app.t('relaySpeed'),
        value: status.tunnelUp
            ? evsFormatBps(status.rxBps + status.txBps)
            : '—',
        color: _txt(context),
        hint: status.tunnelUp
            ? '${app.t('relayDown')} ${evsFormatBps(status.rxBps)} · '
                '${app.t('relayUp')} ${evsFormatBps(status.txBps)}'
            : app.t('relaySpeedNoTunnel'),
      ),
    ];

    return LayoutBuilder(builder: (context, c) {
      // Плитки не должны быть уже 150 px: при меньшей ширине «0.00 %» и
      // подпись под ним начинают переноситься по слогам.
      final perRow = math.max(2, math.min(6, (c.maxWidth / 165).floor()));
      final rows = <Widget>[];
      for (var i = 0; i < tiles.length; i += perRow) {
        final slice = tiles.sublist(i, math.min(i + perRow, tiles.length));
        // IntrinsicHeight обязателен, и это не украшение. `stretch` тянет
        // плитки по вертикали, а ряд живёт внутри прокрутки, где высота не
        // ограничена — без него растягивание уходит в бесконечность и ряд
        // просто не размечается. Заодно он и делает то, ради чего `stretch`
        // здесь стоит: плитки в ряду получают общую высоту по самой высокой,
        // и подписи под числами выравниваются.
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < perRow; j++) ...[
                if (j > 0) const SizedBox(width: 12),
                // Хвост добиваем пустыми местами, чтобы последняя плитка не
                // растягивалась на полэкрана и не спорила по весу с соседями.
                Expanded(
                    child: j < slice.length
                        ? slice[j]
                        : const SizedBox.shrink()),
              ],
            ],
          ),
        ));
        if (i + perRow < tiles.length) rows.add(const SizedBox(height: 12));
      }
      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    });
  }

  static String _relayPct(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(v >= 10 ? 1 : 2)} %';

  static String _relayPingHint(AppState app, RelayStatus s) {
    final parts = <String>[];
    if (s.rttTunnelMs != null) {
      parts.add('${app.t('relayViaTunnel')} '
          '${s.rttTunnelMs!.toStringAsFixed(0)} ${app.t('msShort')}');
    }
    if (s.rttBaseMs != null) {
      parts.add('${app.t('relayBase')} '
          '${s.rttBaseMs!.toStringAsFixed(0)} ${app.t('msShort')}');
    }
    return parts.isEmpty ? app.t('relayPingHint') : parts.join(' · ');
  }
}

class _RelayStat extends StatelessWidget {
  const _RelayStat({
    required this.label,
    required this.value,
    required this.color,
    required this.hint,
  });

  final String label, value, hint;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return PrismPanel(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PrismType.section.copyWith(color: _sectionLabel(context)),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PrismType.title.copyWith(
              color: color,
              fontSize: 23,
              fontFamily: kPrismMono,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            hint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: PrismType.caption.copyWith(
                color: _faint(context), fontSize: 10.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// ГРАФИК
// --------------------------------------------------------------------------

enum _RelayChartSeries { loss, ping, recovered }

class _RelayChart extends StatelessWidget {
  const _RelayChart({
    required this.points,
    required this.series,
    required this.onSeries,
  });

  final List<RelayPoint> points;
  final _RelayChartSeries series;
  final ValueChanged<_RelayChartSeries> onSeries;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final r = _ramp(context);

    // Две линии на графике потерь и задержки: канал и туннель. Смысл экрана
    // в их РАЗНИЦЕ, и рисовать её порознь значило бы заставлять человека
    // сличать два графика глазами.
    final (a, b, unit, bLabel) = switch (series) {
      _RelayChartSeries.loss => (
          [for (final p in points) p.lossDirect],
          [for (final p in points) p.lossTunnel],
          '%',
          app.t('relaySeriesTunnel'),
        ),
      _RelayChartSeries.ping => (
          [for (final p in points) p.rttDirect],
          [for (final p in points) p.rttTunnel],
          app.t('msShort'),
          app.t('relaySeriesTunnel'),
        ),
      _RelayChartSeries.recovered => (
          [for (final p in points) p.recovered.toDouble()],
          <double?>[],
          '',
          '',
        ),
    };

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
              Expanded(
                child: Text(
                  app.t('relayChartTitle'),
                  style: PrismType.label.copyWith(
                      color: _txt(context),
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700),
                ),
              ),
              _RelaySegmented(
                value: series,
                onChanged: onSeries,
                items: [
                  (_RelayChartSeries.loss, app.t('relayTabLoss')),
                  (_RelayChartSeries.ping, app.t('relayTabPing')),
                  (_RelayChartSeries.recovered, app.t('relayTabRecovered')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              // Пишем, сколько секунд НА САМОМ ДЕЛЕ пришло от агента, а не
              // «последние две минуты»: агент мог быть запущен минуту назад.
              Text(
                '${points.length} ${app.t('secShort')}',
                style: PrismType.numeric
                    .copyWith(color: _faint(context), fontSize: 11),
              ),
              const Spacer(),
              if (b.isNotEmpty) ...[
                _RelayLegend(color: r.a2, label: app.t('relaySeriesDirect')),
                const SizedBox(width: 12),
                _RelayLegend(color: _warn(context), label: bLabel),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: points.length < 2
                ? Center(
                    child: Text(app.t('prismCollecting'),
                        style: PrismType.caption
                            .copyWith(color: _faint(context))),
                  )
                : CustomPaint(
                    size: Size.infinite,
                    painter: _RelayChartPainter(
                      a: a,
                      b: b,
                      unit: unit,
                      colorA: r.a2,
                      colorB: _warn(context),
                      grid: _stroke(context),
                      text: _faint(context),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RelayLegend extends StatelessWidget {
  const _RelayLegend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 3,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: PrismType.numeric
                  .copyWith(color: _faint(context), fontSize: 10.5)),
        ],
      );
}

class _RelaySegmented<T> extends StatelessWidget {
  const _RelaySegmented({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _prismField(context),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in items)
            GestureDetector(
              onTap: () => onChanged(v),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 13, vertical: 6),
                  decoration: BoxDecoration(
                    color: v == value ? _prismChip(context) : null,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    label,
                    style: PrismType.label.copyWith(
                      color: v == value ? _txt(context) : _faint(context),
                      fontSize: 11.5,
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

/// График двух рядов с автомасштабом.
///
/// Автомасштаб, а не фиксированные 0–100 %: потери в игровом канале живут в
/// районе долей процента, и на шкале до ста они были бы неотличимы от нуля —
/// то есть график показывал бы «всё хорошо» ровно тогда, когда всё плохо.
class _RelayChartPainter extends CustomPainter {
  _RelayChartPainter({
    required this.a,
    required this.b,
    required this.unit,
    required this.colorA,
    required this.colorB,
    required this.grid,
    required this.text,
  });

  final List<double?> a, b;
  final String unit;
  final Color colorA, colorB, grid, text;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 34.0;
    final w = size.width - padL;
    if (w <= 0) return;

    var top = 0.0;
    for (final v in [...a, ...b]) {
      if (v != null && v > top) top = v;
    }
    // Пустой ряд или ровный ноль: рисуем шкалу до единицы, чтобы линия легла
    // по низу, а не прыгала по середине от шума в третьем знаке.
    if (top <= 0) top = 1.0;
    top *= 1.15;

    final linePaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);

    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(padL, y), Offset(size.width, y), linePaint);
      final v = top * (1 - i / 2);
      tp.text = TextSpan(
        text: v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 1 ? 1 : 2),
        style: TextStyle(color: text, fontSize: 9, fontFamily: kPrismMono),
      );
      tp.layout();
      tp.paint(canvas, Offset(padL - tp.width - 6, y - tp.height / 2));
    }

    if (unit.isNotEmpty) {
      tp.text = TextSpan(
          text: unit,
          style: TextStyle(color: text, fontSize: 9, fontFamily: kPrismMono));
      tp.layout();
      tp.paint(canvas, Offset(padL - tp.width - 6, size.height - tp.height));
    }

    void drawSeries(List<double?> data, Color color, bool fill) {
      if (data.length < 2) return;
      final step = w / (data.length - 1);
      Offset? at(int i) {
        final v = data[i];
        if (v == null) return null;
        return Offset(
            padL + i * step, size.height * (1 - (v / top).clamp(0.0, 1.0)));
      }

      // Разрывы в данных не соединяем прямой через пропуск: агент отдаёт null
      // там, где мерить было нечем, и прямая читалась бы как измеренная.
      final path = Path();
      var open = false;
      Offset? last;
      for (var i = 0; i < data.length; i++) {
        final p = at(i);
        if (p == null) {
          open = false;
          continue;
        }
        if (!open) {
          path.moveTo(p.dx, p.dy);
          open = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
        last = p;
      }

      if (fill && last != null) {
        final f = Path.from(path)
          ..lineTo(last.dx, size.height)
          ..lineTo(padL, size.height)
          ..close();
        canvas.drawPath(
          f,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.26),
                color.withValues(alpha: 0.01),
              ],
            ).createShader(Offset.zero & size),
        );
      }

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
      if (last != null) canvas.drawCircle(last, 3.2, Paint()..color = color);
    }

    // Туннель рисуем первым, канал поверх: в норме туннель ниже, и верхняя
    // линия должна быть той, ради которой сюда смотрят.
    drawSeries(b, colorB, false);
    drawSeries(a, colorA, true);
  }

  @override
  bool shouldRepaint(_RelayChartPainter old) =>
      old.a.length != a.length ||
      old.colorA != colorA ||
      (a.isNotEmpty && old.a.isNotEmpty && old.a.last != a.last) ||
      (b.isNotEmpty && old.b.isNotEmpty && old.b.last != b.last);
}

// --------------------------------------------------------------------------
// КАРТОЧКИ ПОТОКОВ
// --------------------------------------------------------------------------

class _RelayStreamCards extends StatelessWidget {
  const _RelayStreamCards({required this.status});
  final RelayStatus status;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismSectionLabel(app.t('relayStreams')),
          const SizedBox(height: 6),
          Text(
            app.t('relayStreamsHint'),
            style: PrismType.caption.copyWith(
                color: _faint(context), fontSize: 10.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < status.streams.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: _divider(context)),
              const SizedBox(height: 12),
            ],
            _RelayStreamRow(stream: status.streams[i]),
          ],
        ],
      ),
    );
  }
}

class _RelayStreamRow extends StatelessWidget {
  const _RelayStreamRow({required this.stream});
  final RelayStream stream;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = stream;
    final title = switch (s.key) {
      'direct' => app.t('relayStreamDirect'),
      'dup' => app.t('relayStreamDup'),
      'tunnel' => app.t('relayStreamTunnel'),
      _ => s.name,
    };
    final sub = switch (s.key) {
      'direct' => app.t('relayStreamDirectSub'),
      'dup' => app.t('relayStreamDupSub'),
      'tunnel' => app.t('relayStreamTunnelSub'),
      _ => '',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PrismType.label.copyWith(
                      color: _txt(context), fontSize: 13)),
            ),
            const SizedBox(width: 8),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _relayStateColor(context, s.state),
              ),
            ),
            const SizedBox(width: 6),
            Text(_relayStateLabel(app, s.state),
                style: PrismType.numeric.copyWith(
                    color: _relayStateColor(context, s.state), fontSize: 10.5)),
          ],
        ),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(sub,
              style: PrismType.caption.copyWith(
                  color: _faint(context), fontSize: 10.5, height: 1.35)),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 7,
          children: [
            _RelayMini(
              label: app.t('relayLoss'),
              value: s.lossPct == null
                  ? '—'
                  : '${s.lossPct!.toStringAsFixed(2)} %',
              color: _relayLossColor(context, s.lossPct),
            ),
            // Раскладка потерь по направлениям. Суммарный процент не говорит,
            // куда смотреть, а «вверх 5 %, вниз 0 %» говорит сразу.
            if (s.lossUpPct != null)
              _RelayMini(
                label: app.t('relayUpDir'),
                value: '${s.lossUpPct!.toStringAsFixed(1)} %',
                color: _relayLossColor(context, s.lossUpPct),
              ),
            if (s.lossDownPct != null)
              _RelayMini(
                label: app.t('relayDownDir'),
                value: '${s.lossDownPct!.toStringAsFixed(1)} %',
                color: _relayLossColor(context, s.lossDownPct),
              ),
            if (s.rttMs != null)
              _RelayMini(
                label: app.t('relayRtt'),
                value: s.rttMs!.toStringAsFixed(1),
                color: _body(context),
              ),
            if (s.rttP95Ms != null)
              _RelayMini(
                label: 'p95',
                value: s.rttP95Ms!.toStringAsFixed(0),
                color: _body(context),
              ),
            if (s.key == 'dup' && s.recovered > 0)
              _RelayMini(
                label: app.t('relayRecoveredShort'),
                value: s.recovered.toString(),
                color: _ramp(context).a2,
              ),
          ],
        ),
      ],
    );
  }
}

class _RelayMini extends StatelessWidget {
  const _RelayMini(
      {required this.label, required this.value, required this.color});
  final String label, value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: PrismType.numeric
                  .copyWith(color: _faint(context), fontSize: 9.5)),
          const SizedBox(height: 2),
          Text(value,
              style: PrismType.numeric.copyWith(
                  color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      );
}

// --------------------------------------------------------------------------
// НАСТРОЙКИ
// --------------------------------------------------------------------------

class _RelaySettingsCard extends StatefulWidget {
  const _RelaySettingsCard({required this.status});
  final RelayStatus status;

  @override
  State<_RelaySettingsCard> createState() => _RelaySettingsCardState();
}

class _RelaySettingsCardState extends State<_RelaySettingsCard> {
  Map<String, dynamic>? _cfg;
  bool _loading = false;
  bool _open = false;
  String? _note;

  Future<void> _load() async {
    setState(() => _loading = true);
    final app = context.read<AppState>();
    try {
      final c = RelayClient(app.relayUrl, app.relayToken);
      final cfg = await c.config();
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _note = e.toString();
      });
    }
  }

  Future<void> _patch(String key, dynamic value) async {
    setState(() => _cfg = {...?_cfg, key: value});
    final err = await RelayMonitor.instance.patchConfig({key: value});
    if (!mounted) return;
    if (err != null) {
      setState(() => _note = err);
      // Не удалось записать — возвращаем экран к тому, что на станции.
      unawaited(_load());
    } else {
      setState(() => _note = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PrismSectionLabel(app.t('relaySettings')),
              const Spacer(),
              _PrismGhostButton(
                d: _open ? PrismIcons.chevronDown : PrismIcons.forward,
                label: _open ? app.t('relayHide') : app.t('relayShow'),
                onTap: () {
                  setState(() => _open = !_open);
                  if (_open && _cfg == null) unawaited(_load());
                },
              ),
            ],
          ),
          if (_open) ...[
            const SizedBox(height: 16),
            if (_loading)
              Text(app.t('prismCollecting'),
                  style: PrismType.caption.copyWith(color: _faint(context)))
            else if (_cfg == null)
              Text(_note ?? app.t('relayNoAnswer'),
                  style: PrismType.caption.copyWith(color: _warn(context)))
            else ...[
              _RelaySwitchRow(
                title: app.t('relayAuto'),
                sub: app.t('relayAutoHint'),
                value: _cfg!['auto_switch'] == true,
                onChanged: (v) => _patch('auto_switch', v),
              ),
              const SizedBox(height: 14),
              _RelayNumberRow(
                title: app.t('relaySwitchLoss'),
                sub: app.t('relaySwitchLossHint'),
                value: (_cfg!['switch_loss_pct'] as num?)?.toDouble() ?? 2.0,
                min: 0.2,
                max: 10,
                step: 0.2,
                suffix: '%',
                onChanged: (v) => _patch('switch_loss_pct', v),
              ),
              const SizedBox(height: 14),
              _RelayNumberRow(
                title: app.t('relayReturnClean'),
                sub: app.t('relayReturnCleanHint'),
                value:
                    ((_cfg!['return_clean_s'] as num?)?.toDouble() ?? 300) / 60,
                min: 1,
                max: 30,
                step: 1,
                suffix: app.t('minShort'),
                onChanged: (v) => _patch('return_clean_s', (v * 60).round()),
              ),
              const SizedBox(height: 14),
              _RelayNumberRow(
                title: app.t('relaySpread'),
                sub: app.t('relaySpreadHint'),
                value: (_cfg!['spread_ms'] as num?)?.toDouble() ?? 0,
                min: 0,
                max: 20,
                step: 1,
                suffix: app.t('msShort'),
                onChanged: (v) => _patch('spread_ms', v.round()),
              ),
              const SizedBox(height: 14),
              _RelayNumberRow(
                title: app.t('relayWindow'),
                sub: app.t('relayWindowHint'),
                value: (_cfg!['window_s'] as num?)?.toDouble() ?? 30,
                min: 5,
                max: 120,
                step: 5,
                suffix: app.t('secShort'),
                onChanged: (v) => _patch('window_s', v.round()),
              ),
              if (_note != null) ...[
                const SizedBox(height: 14),
                Text(_note!,
                    style:
                        PrismType.caption.copyWith(color: _warn(context))),
              ],
              const SizedBox(height: 16),
              Divider(height: 1, color: _divider(context)),
              const SizedBox(height: 14),
              Text(
                app.t('relayAddressLabel'),
                style: PrismType.caption
                    .copyWith(color: _sub(context), height: 1.45),
              ),
              const SizedBox(height: 8),
              Text(
                app.relayUrl.isEmpty ? '—' : app.relayUrl,
                style: PrismType.numeric.copyWith(
                    color: _body(context), fontSize: 11.5),
              ),
              const SizedBox(height: 10),
              _PrismGhostButton(
                d: PrismIcons.settings,
                label: app.t('relayChangeAddress'),
                onTap: () => unawaited(_editAddress(context, app)),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _editAddress(BuildContext context, AppState app) async {
    await showRelayAddressDialog(context, app);
    if (mounted) setState(() => _cfg = null);
  }
}

class _RelaySwitchRow extends StatelessWidget {
  const _RelaySwitchRow({
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  final String title, sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: PrismType.label.copyWith(
                        color: _txt(context), fontSize: 13)),
                const SizedBox(height: 3),
                Text(sub,
                    style: PrismType.caption.copyWith(
                        color: _faint(context), fontSize: 11, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          PrismToggle(value: value, onChanged: onChanged),
        ],
      );
}

class _RelayNumberRow extends StatelessWidget {
  const _RelayNumberRow({
    required this.title,
    required this.sub,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.suffix,
    required this.onChanged,
  });

  final String title, sub, suffix;
  final double value, min, max, step;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    String show(double v) =>
        step >= 1 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: PrismType.label
                      .copyWith(color: _txt(context), fontSize: 13)),
              const SizedBox(height: 3),
              Text(sub,
                  style: PrismType.caption.copyWith(
                      color: _faint(context), fontSize: 11, height: 1.4)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RelayStepButton(
              icon: PrismIcons.back,
              enabled: value > min,
              onTap: () => onChanged(
                  (value - step).clamp(min, max).toDouble()),
            ),
            SizedBox(
              width: 66,
              child: Text(
                '${show(value)} $suffix',
                textAlign: TextAlign.center,
                style: PrismType.numeric.copyWith(
                    color: _txt(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600),
              ),
            ),
            _RelayStepButton(
              icon: PrismIcons.forward,
              enabled: value < max,
              onTap: () => onChanged(
                  (value + step).clamp(min, max).toDouble()),
            ),
          ],
        ),
      ],
    );
  }
}

class _RelayStepButton extends StatelessWidget {
  const _RelayStepButton(
      {required this.icon, required this.enabled, required this.onTap});
  final String icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: enabled ? 1 : 0.35,
        child: MouseRegion(
          cursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: enabled ? onTap : null,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: _prismField(context),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: _stroke(context)),
              ),
              child: Center(
                child: PrismIcon(icon,
                    size: 11, stroke: 2.2, color: _txt(context)),
              ),
            ),
          ),
        ),
      );
}

// --------------------------------------------------------------------------
// ЖУРНАЛ СОБЫТИЙ АГЕНТА
// --------------------------------------------------------------------------

class _RelayEventsCard extends StatelessWidget {
  const _RelayEventsCard({required this.events});
  final List<({String ts, String text})> events;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final shown = events.reversed.take(6).toList();
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismSectionLabel(app.t('relayEvents')),
          const SizedBox(height: 12),
          for (final e in shown) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 62,
                  child: Text(
                    e.ts.length >= 19 ? e.ts.substring(11, 19) : e.ts,
                    style: PrismType.numeric
                        .copyWith(color: _faint(context), fontSize: 10.5),
                  ),
                ),
                Expanded(
                  child: Text(e.text,
                      style: PrismType.caption.copyWith(
                          color: _body(context), fontSize: 11.5, height: 1.4)),
                ),
              ],
            ),
            const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// ЭКРАН НАСТРОЙКИ, КОГДА АГЕНТ ЕЩЁ НЕ ПРОПИСАН
// --------------------------------------------------------------------------

class _RelaySetup extends StatelessWidget {
  const _RelaySetup({required this.embedded});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: PrismPanel(
          radius: 24,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
          shadow: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.t('relaySetupTitle'),
                  style: PrismType.title
                      .copyWith(color: _txt(context), fontSize: 19)),
              const SizedBox(height: 10),
              Text(app.t('relaySetupBody'),
                  style: PrismType.body.copyWith(
                      color: _sub(context), fontSize: 13.5, height: 1.55)),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _prismField(context),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'bash ~/nexus-station/deploy-station.sh \\\n'
                  '     --vps АДРЕС_VPS --key КЛЮЧ',
                  style: PrismType.numeric.copyWith(
                      color: _body(context), fontSize: 11.5, height: 1.6),
                ),
              ),
              const SizedBox(height: 10),
              Text(app.t('relaySetupHint'),
                  style: PrismType.caption.copyWith(
                      color: _faint(context), height: 1.5)),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: _PrismGhostButton(
                  d: PrismIcons.settings,
                  label: app.t('relaySetAddress'),
                  onTap: () =>
                      unawaited(showRelayAddressDialog(context, app)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ввод адреса и токена агента. Один диалог на все точки входа — из экрана
/// «Сеть» и из настроек, чтобы поля не разъехались между двумя копиями.
Future<void> showRelayAddressDialog(BuildContext context, AppState app) async {
  final url = TextEditingController(text: app.relayUrl);
  final token = TextEditingController(text: app.relayToken);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: _card(c),
      title: Text(app.t('relayAddressTitle'),
          style: TextStyle(color: _txt(c), fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.t('relayAddressBody'),
                style: TextStyle(
                    color: _sub(c), fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 16),
            TextField(
              controller: url,
              style: TextStyle(color: _txt(c), fontSize: 13.5),
              decoration: InputDecoration(
                labelText: app.t('relayAddressField'),
                hintText: 'http://100.79.130.7:8790',
                labelStyle: TextStyle(color: _sub(c)),
                hintStyle: TextStyle(color: _faint(c)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: token,
              style: TextStyle(color: _txt(c), fontSize: 13.5),
              decoration: InputDecoration(
                labelText: app.t('relayTokenField'),
                labelStyle: TextStyle(color: _sub(c)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(app.t('cancel'))),
        TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(app.t('save'))),
      ],
    ),
  );
  if (ok == true) {
    app.setRelay(url: url.text, token: token.text);
  }
  url.dispose();
  token.dispose();
}

// --------------------------------------------------------------------------
// МЕЛОЧИ
// --------------------------------------------------------------------------

/// «12 с назад» / «3 мин назад». Возраст рукопожатия — единственное место,
/// где это нужно, но нужно именно словами: «142» без единиц ни о чём.
String _relayAgo(AppState app, int seconds) {
  if (seconds < 60) return '$seconds ${app.t('secShort')}';
  return '${(seconds / 60).round()} ${app.t('minShort')}';
}

void _relayToast(BuildContext context, String text, {bool bad = false}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(text),
      backgroundColor: bad ? _danger(context) : _card2(context),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
    ),
  );
}
