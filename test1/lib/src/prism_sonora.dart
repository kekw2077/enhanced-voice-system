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

   • Волна. В макете она пляшет по таймеру. Здесь это [EvsLiveViz] на
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
  const PrismWavePanel({super.key, required this.rendering});

  /// Идёт ли сейчас сохранение в файл. Оно молчит: волна во время него стоит,
  /// и подпись обязана сказать почему, иначе неподвижная волна читается как
  /// поломка.
  final bool rendering;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Подпись справа — активный движок и то, что он о себе сообщает. Числа
    // «48 кГц · 16 бит» из макета выдуманы: у Piper ru_RU частота 22 кГц, у
    // системного голоса своя, и вписывать одно число значило бы соврать.
    final (engine, engineSub) = evsTtsEngineLabel(app);
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
              child: EvsLiveViz(kind: 'lkbars', maxSize: 260),
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
