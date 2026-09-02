part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — экран «Диалог»
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/flutter/lib/screens/chat_screen.dart):
   слева лента в стеклянной панели, справа колонка диалогов на 286px.

   Данные и действия — настоящие, из AppState:
     сообщения      → conv.messages (role user/assistant)
     отправка       → app.sendMessage, ровно как в классическом чате
     остановка      → app.cancelGeneration
     тумблер чата   → app.chatEnabled / setChatEnabled
     кольцо         → app.contextUsage(app.current)
     меню чата      → showChatContextMenu — то же, что в трёх других стилях
     меню реплики   → showEvsMessageMenu — тоже общее

   Ни одной своей копии логики: отличается только форма.
   ========================================================================== */

/// Экран «Диалог»: лента слева, список диалогов справа.
class _PrismChat extends StatelessWidget {
  const _PrismChat({this.query = ''});

  /// Запрос из поля поиска в шапке оболочки. Фильтрует список справа —
  /// своего поля у панели диалогов в макете нет.
  final String query;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Expanded(child: _PrismChatPane()),
        const SizedBox(width: 18),
        SizedBox(width: 286, child: _PrismThreads(query: query)),
      ],
    );
  }
}

/// Лента с композером в стеклянной панели. Одна и та же на двух экранах:
/// на «Диалоге» она во всю ширину, в «Центре» — правая колонка рядом с орбом.
/// Там ей нужна своя шапка (имя чата и меню), потому что шапка окна занята
/// названием экрана.
class _PrismChatPane extends StatefulWidget {
  const _PrismChatPane({this.header = false});
  final bool header;

  @override
  State<_PrismChatPane> createState() => _PrismChatPaneState();
}

class _PrismChatPaneState extends State<_PrismChatPane> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  // Слежение за концом ленты. Отматывала она себя только при отправке своей
  // реплики — а этого мало: при выборе разговора лента открывалась в самом
  // НАЧАЛЕ (у ListView нет причин быть где-то ещё), ответ дописывался за
  // нижним краем, и приходилось тянуть полосу руками.
  String? _convId;
  int _count = 0;
  int _tail = 0; // длина последней реплики — она растёт по мере ответа
  bool _stick = true; // человек у конца ленты и хочет за ней следовать

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_watchTail);
  }

  /// Кто прокрутил вверх — тот читает, и дёргать его вниз нельзя. Возврат к
  /// концу снова включает слежение.
  void _watchTail() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _stick = p.maxScrollExtent - p.pixels < 140;
  }

  @override
  void dispose() {
    _scroll.removeListener(_watchTail);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final text = _input.text.trim();
    if (text.isEmpty || _sending || app.isModelLoading || !app.chatEnabled) {
      return;
    }
    app.buzz();
    _input.clear();
    setState(() => _sending = true);
    // Отматываем сразу: своя реплика уже в списке, и смотреть на неё человек
    // хочет сейчас, а не когда придёт ответ.
    _scrollDown();
    await app.sendMessage(text);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _scrollDown({bool instant = false}) {
    if (!mounted) return;
    _stick = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (!instant) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      // Второй прыжок следующим кадром: лента дорастает уже после первой
      // раскладки — обрамления кода, картинки, разметка, — и одного прыжка
      // не хватало, разговор открывался чуть выше конца.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    });
  }

  /// Куда смотреть после этого кадра. Зовётся из build, поэтому ничего не
  /// перестраивает — только ставит задание на после отрисовки.
  void _followTail(String? id, List<ChatMessage> msgs) {
    // Длина ПОСЛЕДНЕЙ реплики вместе с ходом рассуждения: ответ приходит
    // потоком и растёт в том же объекте, число реплик при этом не меняется.
    final tail = msgs.isEmpty
        ? 0
        : msgs.last.content.length + msgs.last.thinking.length;
    if (id != _convId) {
      // Другой разговор — открываем его на последней реплике, без пролёта
      // через всю переписку.
      _convId = id;
      _count = msgs.length;
      _tail = tail;
      _scrollDown(instant: true);
      return;
    }
    if (msgs.length == _count && tail == _tail) return;
    final grew = msgs.length != _count;
    _count = msgs.length;
    _tail = tail;
    if (_stick) _scrollDown(instant: !grew);
  }

  @override
  Widget build(BuildContext context) => _feed(context);

  Widget _feed(BuildContext context) {
    final app = context.watch<AppState>();
    final conv = app.current;
    final msgs = conv?.messages ?? const <ChatMessage>[];
    final busy = _sending || app.isGenerating;
    _followTail(conv?.id, msgs);

    return PrismPanel(
      radius: 26,
      padding: EdgeInsets.zero,
      shadow: true,
      child: Column(
        children: [
          if (widget.header) _paneHeader(context, app, conv),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(26, 26, 26, 8),
              children: [
                // Приветствие остаётся над лентой, а не заменяет её: в макете
                // это заголовок экрана, и он не исчезает с первой репликой.
                // В «Центре» его нет — там у панели своя шапка, и два
                // заголовка подряд в узкой колонке съели бы всю ленту.
                if (!widget.header) ...[
                  PrismGradientText(
                    app.t('howCanIHelp'),
                    style: PrismType.title.copyWith(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.98),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 520,
                    child: Text(
                      app.t('subtitle'),
                      style: PrismType.body
                          .copyWith(color: _sub(context), fontSize: 13.5),
                    ),
                  ),
                  const SizedBox(height: 23),
                ],
                for (final m in msgs)
                  if (m.role != 'system') ...[
                    _PrismMessage(conv: conv!, message: m),
                    const SizedBox(height: 15),
                  ],
                if (busy) const _PrismTypingRow(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
            // Композер один на оба состояния: выключенный чат гасит его, а не
            // подменяет другой полосой (см. `_composer`).
            child: _composer(context, app, busy),
          ),
        ],
      ),
    );
  }

  /// Шапка панели: имя чата, строка со счётчиком и моделью, меню чата.
  /// Меню — общее `showChatContextMenu`, то же, что у списка диалогов.
  Widget _paneHeader(BuildContext context, AppState app, Conversation? conv) {
    final count =
        conv?.messages.where((m) => m.role != 'system').length ?? 0;
    final model = app.selectedModel.isEmpty
        ? app.t('statusNoModel')
        : animaShortModel(app.selectedModel);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 19, 16, 19),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _stroke(context))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conv?.title ?? app.t('newChat'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PrismType.heading.copyWith(color: _txt(context)),
                ),
                const SizedBox(height: 3),
                Text(
                  '$count · $model',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PrismType.numeric
                      .copyWith(color: _sub(context), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          // Меню открывается ОТ КНОПКИ. `context` в build() — это контекст
          // всей панели, и его bottomRight уводил меню в нижний правый угол
          // ленты, за композер. Builder даёт контекст самой кнопки.
          if (conv != null)
            Builder(
              builder: (btnCtx) => PrismRoundIcon(
                icon: Icons.more_vert_rounded,
                tooltip: app.t('animaMore'),
                onTap: () {
                  final box = btnCtx.findRenderObject() as RenderBox?;
                  final at = box == null
                      ? Offset.zero
                      : box.localToGlobal(box.size.bottomLeft(Offset.zero));
                  unawaited(showChatContextMenu(btnCtx, at, conv, app));
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Композер. Выключенный чат — НЕ отдельная полоса с кнопкой «включить», а
  /// тот же композер погашенным: янтарный контур, подпись «доступны только
  /// голосовые команды», замок вместо облачка и неактивная отправка. Ровно
  /// так это устроено в макете, и так честнее: место под строкой не прыгает,
  /// а выключатель остаётся там же, где его выключили.
  Widget _composer(BuildContext context, AppState app, bool busy) {
    final (used, limit) = app.contextUsage(app.current);
    final percent = limit <= 0 ? 0.0 : (used / limit * 100).clamp(0.0, 100.0);
    final loading = app.isModelLoading;
    final chatOn = app.chatEnabled;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.fromLTRB(16, 8, 9, 8),
      decoration: BoxDecoration(
        color: chatOn ? _prismField(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: chatOn
              ? _stroke(context)
              : _warn(context).withValues(alpha: 0.34),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: chatOn ? 1 : 0.38,
              child: TextField(
                controller: _input,
                enabled: chatOn && !loading,
                onSubmitted: (_) => unawaited(_send()),
                style: PrismType.body.copyWith(color: _txt(context)),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: !chatOn
                      ? app.t('chatDisabledHint')
                      : (loading
                          ? app.t('preparingModel')
                          : app.t('askAnything')),
                  hintStyle:
                      PrismType.body.copyWith(color: _faint(context)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Кольцо контекста — настоящее заполнение окна модели, с числом
          // внутри, как в макете.
          Tooltip(
            message: app.contextHint(app.current),
            child: SizedBox(
              width: 34,
              height: 34,
              child: CustomPaint(
                painter: _PrismContextRing(
                  percent: percent,
                  track: _prismChip(context),
                  color: percent > 80 ? _warn(context) : _ramp(context).a2,
                ),
                child: Center(
                  child: Text(
                    '${percent.round()}',
                    style: PrismType.numeric
                        .copyWith(color: _sub(context), fontSize: 8.5),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _PrismChatLockButton(on: chatOn),
          const SizedBox(width: 6),
          // Одна кнопка на три состояния, чтобы место под ней не прыгало:
          // отправить → остановить (пока идёт генерация) → ждать.
          if (app.isGenerating)
            PrismGradientButton(
              label: app.t('stopGeneration'),
              icon: Icons.stop_rounded,
              trailingIcon: true,
              onTap: () {
                app.buzz();
                app.cancelGeneration();
              },
            )
          else if (busy)
            const SizedBox(
              width: 34,
              height: 34,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: chatOn ? 1 : 0.38,
              child: PrismGradientButton(
                label: app.t('send'),
                d: PrismIcons.send,
                trailingIcon: true,
                onTap: (loading || !chatOn) ? null : () => unawaited(_send()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Кнопка «чат / только команды». Круглая, 34px: облачко, когда чат включён,
/// и янтарный замок на подложке чипа, когда выключен — как в макете.
class _PrismChatLockButton extends StatefulWidget {
  const _PrismChatLockButton({required this.on});
  final bool on;

  @override
  State<_PrismChatLockButton> createState() => _PrismChatLockButtonState();
}

class _PrismChatLockButtonState extends State<_PrismChatLockButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final on = widget.on;
    return Tooltip(
      message: on ? app.t('chatToggleOff') : app.t('chatToggleOn'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            app.buzz();
            app.setChatEnabled(!on);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on
                  ? (_hover ? _prismHover(context) : Colors.transparent)
                  : _prismChip(context),
            ),
            alignment: Alignment.center,
            child: PrismIcon(
              on ? PrismIcons.chat : PrismIcons.lock,
              size: 16,
              stroke: 1.9,
              color: on
                  ? (_hover ? _txt(context) : _sub(context))
                  : _warn(context),
            ),
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------
// РЕПЛИКА
// --------------------------------------------------------------------------

/// Пузырь с аватаром и полосой действий под ответом. Правая кнопка мыши
/// открывает общее меню реплики — то же, что в трёх других стилях.
class _PrismMessage extends StatefulWidget {
  const _PrismMessage({required this.conv, required this.message});
  final Conversation conv;
  final ChatMessage message;

  @override
  State<_PrismMessage> createState() => _PrismMessageState();
}

class _PrismMessageState extends State<_PrismMessage> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final m = widget.message;
    final ai = m.role != 'user';
    final r = _ramp(context);

    final avatar = Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: ai ? LinearGradient(colors: [r.a1, r.a2]) : null,
        color: ai ? null : _prismChip(context),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: ai
          ? const Icon(Icons.auto_awesome, size: 14, color: Colors.white)
          : Icon(Icons.person_outline, size: 15, color: _sub(context)),
    );

    final bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
        decoration: BoxDecoration(
          color: ai ? _prismField(context) : null,
          gradient: ai ? null : LinearGradient(colors: [r.a1, r.a2]),
          border: Border.all(color: ai ? _stroke(context) : Colors.transparent),
          borderRadius: ai
              ? const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20))
              : const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(6),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ход рассуждения — свёрнутым блоком над ответом, тем же виджетом,
            // что и в остальных стилях: это не часть ответа.
            if (ai && m.thinking.trim().isNotEmpty) ...[
              AnimaThinkingBlock(text: m.thinking, live: m.content.isEmpty),
              const SizedBox(height: 8),
            ],
            SelectableText(
              m.content,
              style: PrismType.body.copyWith(
                  color: ai ? _body(context) : Colors.white, height: 1.55),
            ),
          ],
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapDown: (e) => unawaited(showEvsMessageMenu(
          context,
          widget.conv,
          m,
          e.globalPosition,
        )),
        child: Column(
          crossAxisAlignment:
              ai ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.62),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: ai
                    ? [avatar, const SizedBox(width: 11), bubble]
                    : [bubble, const SizedBox(width: 11), avatar],
              ),
            ),
            // Полоса действий проявляется под курсором: три кнопки под каждой
            // репликой навсегда шумят сильнее, чем помогают.
            AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _hover ? 1 : 0,
              child: Padding(
                padding: EdgeInsets.only(
                    left: ai ? 41 : 0, right: ai ? 0 : 41, top: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PrismRoundIcon(
                      icon: Icons.copy_rounded,
                      tooltip: app.t('msgCopy'),
                      size: 28,
                      onTap: () => unawaited(animaCopyMessage(context, m)),
                    ),
                    if (ai)
                      PrismRoundIcon(
                        icon: Icons.volume_up_outlined,
                        tooltip: app.t('studioSay'),
                        size: 28,
                        onTap: () => SidecarClient.instance.speak(
                          m.content,
                          rate: app.ttsRate,
                          volume: app.ttsVolume,
                        ),
                      ),
                    if (ai)
                      PrismRoundIcon(
                        icon: Icons.refresh_rounded,
                        tooltip: app.t('msgRegenerate'),
                        size: 28,
                        onTap: app.isGenerating
                            ? null
                            : () => unawaited(
                                app.regenerateLastReply(widget.conv)),
                      ),
                    PrismRoundIcon(
                      icon: Icons.more_horiz_rounded,
                      tooltip: app.t('animaMore'),
                      size: 28,
                      onTap: () {
                        final box =
                            context.findRenderObject() as RenderBox?;
                        final at = box == null
                            ? Offset.zero
                            : box.localToGlobal(
                                box.size.bottomLeft(Offset.zero));
                        unawaited(showEvsMessageMenu(
                            context, widget.conv, m, at));
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Думаю…» с бегущим бликом по надписи. Крутится под гейтом переднего плана:
/// это не украшение фона, а единственный признак, что ответ идёт.
/// Строка ожидания ответа. Значок — акцентная плитка макета, надпись — общая
/// [AnimaShimmerLabel], та же, что крутится в Nexus: пул фраз («Соображаю»,
/// «Подбираю слова», …) с бегущим бликом.
///
/// Своя надпись здесь была, и она повторяла ту же мысль хуже: одно слово
/// «Думаю» без смены фраз. Два разных ожидания в одной программе — это два
/// места, которые расходятся; пул уже написан, переведён и подчиняется гейту
/// движения, и брать надо его.
class _PrismTypingRow extends StatefulWidget {
  const _PrismTypingRow();
  @override
  State<_PrismTypingRow> createState() => _PrismTypingRowState();
}

class _PrismTypingRowState extends State<_PrismTypingRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2300));
  late final AmbientMotion _ambient =
      AmbientMotion(_c, gate: MotionGate.foreground);

  @override
  void dispose() {
    _ambient.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    return Row(
      children: [
        RotationTransition(
          turns: _c,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [r.a1, r.a2]),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const PrismIcon(PrismIcons.spark,
                size: 14, stroke: 2, color: Colors.white),
          ),
        ),
        const SizedBox(width: 11),
        const AnimaShimmerLabel(),
      ],
    );
  }
}

class _PrismContextRing extends CustomPainter {
  _PrismContextRing({
    required this.percent,
    required this.track,
    required this.color,
  });
  final double percent;
  final Color track, color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = track,
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * (percent / 100),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_PrismContextRing old) =>
      old.percent != percent || old.color != color || old.track != track;
}

// --------------------------------------------------------------------------
// КОЛОНКА ДИАЛОГОВ
// --------------------------------------------------------------------------

/// Правая колонка: настоящие диалоги, сгруппированные по дате, с тем же
/// контекстным меню (переименовать · закрепить · в архив · удалить), что и
/// список диалогов в остальных стилях.
class _PrismThreads extends StatelessWidget {
  const _PrismThreads({this.query = ''});
  final String query;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final q = query.trim().toLowerCase();
    final list = q.isEmpty
        ? app.conversations
        : app.conversations
            .where((c) => c.title.toLowerCase().contains(q))
            .toList();

    // Группировка по дате последнего изменения. «Закреплено» идёт первым и
    // забирает свои чаты из остальных групп, иначе они были бы в двух местах.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final pinned = <Conversation>[];
    final byToday = <Conversation>[];
    final byYesterday = <Conversation>[];
    final earlier = <Conversation>[];
    for (final c in list) {
      if (c.pinned) {
        pinned.add(c);
      } else {
        final d = DateTime(c.updatedAt.year, c.updatedAt.month, c.updatedAt.day);
        if (!d.isBefore(today)) {
          byToday.add(c);
        } else if (!d.isBefore(yesterday)) {
          byYesterday.add(c);
        } else {
          earlier.add(c);
        }
      }
    }
    final groups = <(String, List<Conversation>)>[
      (app.t('ncGrpPinned'), pinned),
      (app.t('ncGrpToday'), byToday),
      (app.t('ncGrpYesterday'), byYesterday),
      (app.t('ncGrpEarlier'), earlier),
    ];

    return PrismPanel(
      radius: 26,
      padding: const EdgeInsets.all(20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PrismSectionLabel(app.t('nxChats')),
              const Spacer(),
              Text('${list.length}',
                  style: PrismType.numeric
                      .copyWith(color: _faint(context), fontSize: 11)),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final (title, items) in groups)
                  if (items.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 8, 2, 2),
                      child: PrismSectionLabel(title, size: 10.5),
                    ),
                    for (final c in items) _PrismThreadTile(conv: c),
                  ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => unawaited(showChatArchive(context, app)),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _prismField(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _stroke(context)),
                ),
                alignment: Alignment.center,
                child: Text(app.t('archiveTitle'),
                    style: PrismType.label
                        .copyWith(color: _sub(context), fontSize: 12.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrismThreadTile extends StatefulWidget {
  const _PrismThreadTile({required this.conv});
  final Conversation conv;

  @override
  State<_PrismThreadTile> createState() => _PrismThreadTileState();
}

class _PrismThreadTileState extends State<_PrismThreadTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = widget.conv;
    final on = identical(app.current, c);
    final count = c.messages.where((m) => m.role != 'system').length;
    final meta = '$count · ${_prismTime(c.updatedAt)}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            app.buzz();
            app.openChat(c);
          },
          onSecondaryTapDown: (e) => unawaited(
              showChatContextMenu(context, e.globalPosition, c, app)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              gradient: on
                  ? LinearGradient(
                      colors: [_prismAccentSoft(context), Colors.transparent],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight)
                  : null,
              color: !on && _hover ? _prismHover(context) : null,
              borderRadius: BorderRadius.circular(15),
              border:
                  Border.all(color: on ? _stroke(context) : Colors.transparent),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.pinned) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 7),
                    child: Icon(Icons.push_pin,
                        size: 12, color: _ramp(context).a2),
                  ),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PrismType.label.copyWith(
                            color: on ? _txt(context) : _body(context),
                            fontSize: 13),
                      ),
                      const SizedBox(height: 3),
                      Text(meta,
                          style: PrismType.numeric.copyWith(
                              color: _faint(context), fontSize: 10.5)),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: _hover || on ? 1 : 0,
                  child: Builder(
                    builder: (btnCtx) => PrismRoundIcon(
                      icon: Icons.more_vert_rounded,
                      tooltip: app.t('animaMore'),
                      size: 26,
                      onTap: () {
                        final box = btnCtx.findRenderObject() as RenderBox?;
                        final at = box == null
                            ? Offset.zero
                            : box.localToGlobal(
                                box.size.bottomLeft(Offset.zero));
                        unawaited(showChatContextMenu(btnCtx, at, c, app));
                      },
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
}

/// Время в строке диалога: сегодня — часы и минуты, раньше — день и месяц.
/// Год не пишем: в списке, отсортированном по свежести, он ничего не решает.
String _prismTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${two(t.hour)}:${two(t.minute)}';
  }
  return '${two(t.day)}.${two(t.month)}';
}
