part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — части экрана Nexus Sonora
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/design, блок `isTts`): слева вкладки, карточка
   голоса с ползунками и поле текста; справа волна и последние озвучки.

   Здесь только ФОРМА. Синтез, выбор голоса и очередь остаются в
   [_StudioPanelState] — те же `_voice`, `_voices`, `_submit`, `_renderSpeech`.

   Три места, где макет обещает больше, чем умеет движок, и что сделано вместо:

   • Ползунок «Тон голоса». Ни Piper, ни системный голос высоту тона не
     принимают — параметра просто нет в протоколе синтеза. Мёртвый ползунок
     хуже отсутствующего, поэтому их два: скорость и громкость. Оба настоящие
     и оба те же, что в настройках голоса.

   • «48 кГц · 16 бит» в подписи под волной. Частота у каждого движка своя
     (Piper ru_RU отдаёт 22 кГц), поэтому подпись читает её у активного
     движка, а не повторяет число из макета.

   • Волна. В макете она пляшет по таймеру. Здесь это [AnimaLiveViz] на
     настоящих уровнях синтеза — та же визуализация, что в шаре «Центра» и в
     плавающем виджете. Она движется, когда EVS ГОВОРИТ вслух; сохранение в
     файл идёт молча, и во время него волна честно стоит.
   ========================================================================== */

/// Полоса вкладок из макета: стеклянная подложка, выбранная вкладка залита
/// градиентом. Вкладки делят ширину поровну.
class PrismTabsStrip<T> extends StatelessWidget {
  const PrismTabsStrip({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
    this.disabled = const {},
  });

  /// (значение, подпись).
  final List<(T, String)> tabs;
  final T value;
  final ValueChanged<T> onChanged;

  /// Вкладки, которые сейчас нельзя выбрать, и почему — текст идёт в подсказку.
  final Map<T, String> disabled;

  @override
  Widget build(BuildContext context) {
    return PrismPanel(
      radius: 18,
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: _PrismTab(
                label: tabs[i].$2,
                selected: tabs[i].$1 == value,
                lockedWhy: disabled[tabs[i].$1],
                onTap: () => onChanged(tabs[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PrismTab extends StatefulWidget {
  const _PrismTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.lockedWhy,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? lockedWhy;

  @override
  State<_PrismTab> createState() => _PrismTabState();
}

class _PrismTabState extends State<_PrismTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final locked = widget.lockedWhy != null;
    final on = widget.selected;
    Widget tab = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        gradient: on
            ? LinearGradient(
                begin: const Alignment(-1, -0.2),
                end: const Alignment(1, 0.2),
                colors: [_ramp(context).a1, _ramp(context).a2],
              )
            : null,
        color: on ? null : (_hover ? _prismHover(context) : null),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Text(
        widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: on ? Colors.white : _sub(context),
        ),
      ),
    );
    if (locked) tab = Opacity(opacity: 0.45, child: tab);
    tab = MouseRegion(
      cursor: locked ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: locked ? null : widget.onTap, child: tab),
    );
    return locked ? Tooltip(message: widget.lockedWhy!, child: tab) : tab;
  }
}

/// Пилюля выбора: подпись и шеврон. В макете так выбирают голос.
class PrismPickPill extends StatefulWidget {
  const PrismPickPill({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<PrismPickPill> createState() => _PrismPickPillState();
}

class _PrismPickPillState extends State<PrismPickPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? _prismHover(context) : _prismField(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PrismType.label
                      .copyWith(color: _txt(context), fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 9),
              PrismIcon(PrismIcons.chevronDown,
                  size: 13, stroke: 2.2, color: _sub(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Панель «Волна»: живая визуализация синтеза и подпись под ней.
class PrismWavePanel extends StatelessWidget {
  const PrismWavePanel({
    super.key,
    required this.rendering,
    this.preparing = false,
  });

  /// Идёт ли сейчас сохранение в файл. Оно молчит: волна во время него стоит,
  /// и подпись обязана сказать почему, иначе неподвижная волна читается как
  /// поломка.
  final bool rendering;

  /// Нажали «Озвучить», а звук ещё не пошёл: движок грузится, клон считает на
  /// сервере. Волна в эти секунды тоже стоит, и «тишина» под ней — прямая
  /// неправда: ждут как раз её.
  final bool preparing;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Подпись справа — активный движок и то, что он о себе сообщает. Числа
    // «48 кГц · 16 бит» из макета выдуманы: у Piper ru_RU частота 22 кГц, у
    // системного голоса своя, и вписывать одно число значило бы соврать.
    final (engine, engineSub) = animaTtsEngineLabel(app);
    return PrismPanel(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismSectionLabel(app.t('prismWave')),
          const SizedBox(height: 15),
          // Высота 96px — из макета. Столбцы рисует общая визуализация, а не
          // своя копия: вид ассистента обязан быть один во всей программе.
          const SizedBox(
            height: 96,
            child: Center(
              child: AnimaLiveViz(kind: 'lkbars', maxSize: 260),
            ),
          ),
          const SizedBox(height: 15),
          ValueListenableBuilder<double>(
            valueListenable: VoiceLevels.instance.tts,
            builder: (context, level, _) {
              final state = level > 0.001
                  ? app.t('prismStateSpeaking')
                  : rendering
                      ? app.t('prismStateRendering')
                      : preparing
                          ? app.t('prismStatePreparing')
                          : app.t('prismStateSilent');
              return Row(
                children: [
                  Text(state,
                      style: PrismType.numeric
                          .copyWith(color: _faint(context), fontSize: 10.5)),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      engineSub.isEmpty ? engine : '$engine · $engineSub',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: PrismType.numeric
                          .copyWith(color: _faint(context), fontSize: 10.5),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Ход озвучки: бегущая полоса, прошедшее время и срок ожидания.
///
/// Доли пути здесь нет, и взяться ей неоткуда: сайдкар синтезирует текст
/// одним вызовом (`tts_engine.render` → `synthesize`) и о середине не
/// сообщает — ни шагов, ни процентов в протоколе синтеза не заведено.
/// Выдуманный процент был бы хуже отсутствующего, поэтому полоса бежит без
/// доли, а рядом стоит то, что известно точно: сколько уже ждём и сколько
/// ждать осталось. На единственный вопрос, который тут задают, — «оно ещё
/// живо?» — этого хватает.
///
/// Часы свои: виджет живёт ровно столько, сколько идёт работа, и секунду
/// отсчитывает сам. Считай их экран — он перерисовывался бы целиком раз в
/// секунду, вместе с волной и списком озвучек.
class PrismSpeechProgress extends StatefulWidget {
  const PrismSpeechProgress({
    super.key,
    required this.label,
    required this.limit,
    this.value,
  });

  /// Что именно идёт: синтез в файл или подготовка к речи вслух.
  final String label;

  /// Доля сделанного — но только там, где её есть чем подтвердить. Нарезка её
  /// даёт: куски пересчитаны, готовые лежат на диске. Внутри одного куска
  /// доли нет, и тогда полоса честно бежит без неё.
  final double? value;

  /// Сколько ждут ответа. По истечении срока ожидание обрывается, и человек
  /// вправе видеть, сколько у него осталось, а не узнавать это по ошибке.
  final Duration limit;

  @override
  State<PrismSpeechProgress> createState() => _PrismSpeechProgressState();
}

class _PrismSpeechProgressState extends State<PrismSpeechProgress> {
  final DateTime _from = DateTime.now();
  Timer? _tick;
  Duration _gone = Duration.zero;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _gone = DateTime.now().difference(_from));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Срок вышел, а ответа нет. Цифры краснеют раньше, чем придёт ошибка: с
    // этой секунды ждать уже нечего, и сказать это лучше сразу.
    final over = _gone >= widget.limit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PrismType.caption
                    .copyWith(fontSize: 11.5, color: _sub(context)),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${prismClock(_gone)} / ${prismClock(widget.limit)}',
              style: PrismType.numeric.copyWith(
                fontSize: 11,
                color: over ? _warn(context) : _faint(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: widget.value,
            minHeight: 4,
            backgroundColor: _stroke(context),
            valueColor: AlwaysStoppedAnimation<Color>(
                over ? _warn(context) : _ramp(context).a2),
          ),
        ),
      ],
    );
  }
}

/// «0:07», «2:00» — минуты и секунды для часов ожидания.
String prismClock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Список кусков: что сделано, что идёт сейчас, что сорвалось.
///
/// Это и есть «видно, что происходит». До нарезки ход работы был одним словом
/// «сохраняю» на полчаса; теперь это восемнадцать строк, в которых семь с
/// галочкой, одна крутится, и у каждой видно начало её текста — так понятно
/// не только «сколько осталось», но и «на чём именно оно споткнулось».
///
/// Сорвавшийся кусок остаётся на месте со своей ошибкой: продолжить можно с
/// него, не пересчитывая готовое.
class PrismChunkList extends StatelessWidget {
  const PrismChunkList({
    super.key,
    required this.chunks,
    required this.busy,
    this.onCancel,
    this.onResume,
  });

  final List<SpeechChunk> chunks;

  /// Идёт ли партия прямо сейчас: от этого зависит, что предложить — остановку
  /// или продолжение.
  final bool busy;

  final VoidCallback? onCancel, onResume;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final done = chunks.where((c) => c.state == SpeechChunkState.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              app.t('prismChunksDone').replaceAll('{done}', '$done')
                  .replaceAll('{total}', '${chunks.length}'),
              style: PrismType.numeric
                  .copyWith(fontSize: 11.5, color: _sub(context)),
            ),
            const Spacer(),
            // Остановка — после текущего куска, а не мгновенная: синтез уже
            // отдан движку, и оборвать его на середине нечем. Подпись говорит
            // ровно это, чтобы нажавший не решил, что кнопка не сработала.
            if (busy && onCancel != null)
              _PrismGhostButton(
                label: app.t('prismChunksStop'),
                d: PrismIcons.stop,
                onTap: onCancel,
              )
            // Продолжить предлагаем не только после ошибки: остановленная
            // партия — тот же случай, куски на диске те же, и заново считать
            // их незачем.
            else if (onResume != null &&
                chunks.any((c) => c.state != SpeechChunkState.done))
              _PrismGhostButton(
                label: app.t('prismChunksResume'),
                d: PrismIcons.play,
                onTap: onResume,
              ),
          ],
        ),
        const SizedBox(height: 11),
        for (final c in chunks) ...[
          _PrismChunkRow(chunk: c),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _PrismChunkRow extends StatelessWidget {
  const _PrismChunkRow({required this.chunk});
  final SpeechChunk chunk;

  @override
  Widget build(BuildContext context) {
    final c = chunk;
    final failed = c.state == SpeechChunkState.failed;
    final running = c.state == SpeechChunkState.running;
    final done = c.state == SpeechChunkState.done;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: running ? _prismHover(context) : _prismField(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: failed ? _danger(context) : _stroke(context)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${c.index + 1}',
              style: PrismType.numeric
                  .copyWith(fontSize: 10.5, color: _faint(context)),
            ),
          ),
          SizedBox(
            width: 16,
            height: 16,
            child: running
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(_ramp(context).a2),
                  )
                : done
                    ? PrismIcon(PrismIcons.check,
                        size: 13, stroke: 2.4, color: _success(context))
                    : failed
                        ? PrismIcon(PrismIcons.info,
                            size: 13, stroke: 2, color: _danger(context))
                        : Center(
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _stroke(context),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c.error ?? c.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: PrismType.caption.copyWith(
                fontSize: 11.5,
                color: failed ? _danger(context) : _sub(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            done && c.took > Duration.zero
                ? prismClock(c.took)
                : '${c.text.characters.length}',
            style: PrismType.numeric
                .copyWith(fontSize: 10, color: _faint(context)),
          ),
        ],
      ),
    );
  }
}

/// Строка в «Последних озвучках»: значок, голос и текст, время справа.
class PrismSpeechRow extends StatefulWidget {
  const PrismSpeechRow({
    super.key,
    required this.voice,
    required this.text,
    required this.time,
    required this.onTap,
    this.busy = false,
    this.error,
  });

  final String voice, text, time;
  final VoidCallback onTap;
  final bool busy;
  final String? error;

  @override
  State<PrismSpeechRow> createState() => _PrismSpeechRowState();
}

class _PrismSpeechRowState extends State<PrismSpeechRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final failed = widget.error != null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.busy ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: _hover ? _prismHover(context) : _prismField(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _prismChip(context),
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: widget.busy
                    ? SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              _ramp(context).a2),
                        ),
                      )
                    : PrismIcon(
                        failed ? PrismIcons.info : PrismIcons.play,
                        size: 13,
                        stroke: 2,
                        fill: !failed,
                        color: failed ? _danger(context) : _ramp(context).a2,
                      ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.voice,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PrismType.label
                          .copyWith(color: _txt(context), fontSize: 12.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.error ?? widget.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PrismType.caption.copyWith(
                        fontSize: 11,
                        color: failed ? _danger(context) : _faint(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.time,
                style: PrismType.numeric
                    .copyWith(color: _faint(context), fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «2 мин», «3 ч», «вчера» — время в том коротком виде, в каком оно стоит в
/// макете. Точная дата в списке из трёх строк не нужна.
String prismAgo(AppState app, DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return app.t('prismJustNow');
  if (d.inHours < 1) return '${d.inMinutes} ${app.t('minShort')}';
  if (d.inDays < 1) return '${d.inHours} ${app.t('hourShort')}';
  return '${d.inDays} ${app.t('dayShort')}';
}
