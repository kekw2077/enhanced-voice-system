part of '../main.dart';

/* ==========================================================================
   ОБЩЕЕ ДЛЯ ТРЁХ СТИЛЕЙ  (classic · Nexus · «Ноктюрн»)
   --------------------------------------------------------------------------
   Три оболочки рисуют разную обстановку, но список того, ЧТО умеет
   приложение, у них обязан быть один. Раньше он был расписан по три раза —
   и расходился: архив был только в классической рейке, переключатель чата —
   только в Nexus и «Ноктюрне», выбор модели, «перегенерировать» и
   «копировать» — только в классическом чате.

   Здесь лежит единственный экземпляр каждой такой функции:

   • `animaAppActions`   — список точек входа (новый чат · диалоги · архив ·
                          картинки · озвучка · модели · команды · журнал ·
                          настройки). Каждый стиль строит своё меню из НЕГО,
                          поэтому новая функция появляется сразу в трёх.
   • `AnimaMoreButton`   — кнопка «…», открывающая этот список одинаково везде.
   • `AnimaChatsDialog`  — единственный список диалогов с поиском и полным
                          набором действий над строкой.
   • композер          — выбор модели, отправка/стоп, тумблер чата.
   • сообщение         — контекстное меню и полоса действий под ответом.
   • `animaIconButton`   — одна кнопка-иконка: поведение одно (ripple, tooltip,
                          курсор-палец, состояние «выключена»), геометрия —
                          по стилю.

   Правило: новая функция описывается ЗДЕСЬ и подключается ко всем трём
   оболочкам сразу. Ветка «только в одном стиле» — повод объяснить в
   комментарии, почему у двух других её быть не может.
   ========================================================================== */

// --------------------------------------------------------------------------
// Кнопка-иконка. Поведение общее, геометрия — по стилю: классика — круг 34,
// Nexus — скруглённый квадрат 40, «Ноктюрн» — контурный квадрат 42. Раньше
// каждая оболочка держала свою `_iconBtn`, и одна из них (Nexus, в колонке
// диалога) была на голом GestureDetector: ни отклика на нажатие, ни подсказки,
// ни курсора-пальца.
// --------------------------------------------------------------------------
Widget animaIconButton(
  BuildContext context, {
  required IconData icon,
  required VoidCallback? onTap,
  String? tooltip,
  bool active = false,
  bool danger = false,
  bool filled = false,
}) {
  final skin = _skin(context);
  final nexus = _isNexus(context);
  final noctur = _isNoctur(context);
  final double side = noctur ? 42 : (nexus ? 40 : 34);
  final double iconSize = noctur || nexus ? 18 : 15;
  // Цвет «включённого» состояния берётся у стиля: Nexus красит активное в
  // info (голубой), остальные — в акцент. Опасное действие всегда danger.
  final Color hot = danger
      ? _danger(context)
      : (nexus ? _info(context) : _accent(context));
  final radius = BorderRadius.circular(
    noctur || nexus ? skin.radiusControl : side / 2,
  );
  // «Включено» у Nexus — заливка градиентом accent→accent2 с белым знаком:
  // так выглядел тумблер чата в этом стиле, и вид у него свой не случайно —
  // весь стиль построен на этом градиенте. Общая кнопка её и рисует, чтобы
  // единый набор функций не стоил стилю его собственного вида.
  final bool solid = filled || (active && nexus && !danger);
  final Gradient? grad = solid && nexus && !danger
      ? LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_accent(context), _accent2(context)],
        )
      : null;
  final Color fg = onTap == null
      ? _faint(context)
      : solid
      ? (grad != null ? Colors.white : _onAccent(context))
      : (active ? hot : _sub(context));
  final Widget box = Container(
    width: side,
    height: side,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: radius,
      gradient: grad,
      color: grad != null
          ? null
          : solid
          ? hot
          : active
          ? hot.withValues(alpha: 0.10)
          : _overlayFill(context, nexus ? 0.05 : 0.042),
      border: grad != null
          ? null
          : Border.all(
              color: solid
                  ? hot
                  : active
                  ? hot.withValues(alpha: 0.55)
                  : _stroke(context),
            ),
    ),
    child: Icon(icon, size: iconSize, color: fg),
  );
  final Widget btn = Material(
    color: Colors.transparent,
    child: InkWell(borderRadius: radius, onTap: onTap, child: box),
  );
  return (tooltip == null || tooltip.isEmpty)
      ? btn
      : Tooltip(message: tooltip, child: btn);
}

// --------------------------------------------------------------------------
// Единый список функций приложения.
// --------------------------------------------------------------------------
enum AnimaActionId {
  newChat,
  chats,
  archive,
  images,
  speech,
  relay,
  czn,
  models,
  commands,
  log,
  settings,
}

class AnimaAction {
  final AnimaActionId id;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const AnimaAction(this.id, this.icon, this.label, this.onTap);
}

/// Все точки входа приложения, в одном порядке для всех стилей.
///
/// Переопределения нужны там, где у стиля есть СВОЙ экран для той же функции
/// («Ноктюрн» открывает команды и журнал своими вкладками, а не страницей
/// настроек). Функция при этом остаётся той же самой — меняется только то,
/// куда ведёт нажатие.
List<AnimaAction> animaAppActions(
  BuildContext context, {
  VoidCallback? onChats,
  VoidCallback? onCommands,
  VoidCallback? onLog,
  VoidCallback? onImages,
  VoidCallback? onSpeech,
  VoidCallback? onRelay,
  VoidCallback? onCzn,
  VoidCallback? onNewChat,
}) {
  final app = context.read<AppState>();
  void push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  void settings([String? page]) => push(
    page == null ? const DesktopSettings() : DesktopSettings(initialPage: page),
  );
  return [
    AnimaAction(AnimaActionId.newChat, Icons.add, app.t('newChat'), () {
      app.buzz();
      app.newChat();
      // «Призма» держит диалог внутри оболочки: создав чат из любого её
      // экрана, надо на него же и перейти, иначе новый чат уходит в никуда.
      onNewChat?.call();
    }),
    AnimaAction(
      AnimaActionId.chats,
      Icons.forum_outlined,
      app.t('nxChats'),
      onChats ?? () => unawaited(showEvsChatsDialog(context, app)),
    ),
    AnimaAction(
      AnimaActionId.archive,
      Icons.inventory_2_outlined,
      app.t('archiveTitle'),
      () => unawaited(showChatArchive(context, app)),
    ),
    AnimaAction(
      AnimaActionId.images,
      Icons.image_outlined,
      app.t('navImages'),
      onImages ?? () => push(const LuminaStudio()),
    ),
    AnimaAction(
      AnimaActionId.speech,
      Icons.record_voice_over_outlined,
      app.t('navSpeech'),
      onSpeech ?? () => push(const StudioPanel(mode: StudioMode.speech)),
    ),
    // «Сеть» — один и тот же экран во всех четырёх стилях. «Призма» держит его
    // вкладкой и передаёт onRelay, остальные открывают страницей.
    AnimaAction(
      AnimaActionId.relay,
      Icons.network_check_outlined,
      app.t('prismNavRelay'),
      onRelay ?? () => push(const RelayPanel()),
    ),
    // Переводчик игры — тот же экран во всех четырёх стилях, ровно как «Сеть».
    // Своих цветов у него нет, поэтому пятый стиль подхватит его без правок.
    AnimaAction(
      AnimaActionId.czn,
      Icons.translate_outlined,
      app.t('prismNavCzn'),
      onCzn ?? () => push(const CznPanel()),
    ),
    AnimaAction(
      AnimaActionId.models,
      Icons.memory_outlined,
      app.t('nxNavModels'),
      () => settings(_Pages.llmConn),
    ),
    AnimaAction(
      AnimaActionId.commands,
      Icons.terminal_outlined,
      app.t('ncTabCommands'),
      onCommands ?? () => settings(_Pages.cmdExec),
    ),
    AnimaAction(
      AnimaActionId.log,
      Icons.article_outlined,
      app.t('nxNavLog'),
      onLog ?? () => settings(_Pages.appLog),
    ),
    AnimaAction(
      AnimaActionId.settings,
      Icons.settings_outlined,
      app.t('settings'),
      () => settings(),
    ),
  ];
}

/// Меню со всеми функциями. Список одинаков в трёх стилях целиком — включая
/// то, что стиль уже показывает отдельной кнопкой: человек, привыкший искать
/// «Архив» в этом меню, находит его в любом стиле.
Future<void> showEvsActionsMenu(
  BuildContext context,
  Offset pos, {
  VoidCallback? onChats,
  VoidCallback? onCommands,
  VoidCallback? onLog,
  VoidCallback? onImages,
  VoidCallback? onSpeech,
  VoidCallback? onRelay,
  VoidCallback? onNewChat,
}) async {
  final actions = animaAppActions(
    context,
    onChats: onChats,
    onCommands: onCommands,
    onLog: onLog,
    onImages: onImages,
    onSpeech: onSpeech,
    onRelay: onRelay,
    onNewChat: onNewChat,
  );
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final id = await showMenu<AnimaActionId>(
    context: context,
    color: _card(context),
    position: RelativeRect.fromRect(
      Rect.fromPoints(pos, pos),
      Offset.zero & (overlay?.size ?? Size.zero),
    ),
    items: [
      for (final a in actions)
        PopupMenuItem(
          value: a.id,
          height: 40,
          child: Row(
            children: [
              Icon(a.icon, size: 18, color: _sub(context)),
              const SizedBox(width: 12),
              Text(
                a.label,
                style: TextStyle(color: _txt(context), fontSize: 14),
              ),
            ],
          ),
        ),
    ],
  );
  if (id == null || !context.mounted) return;
  actions.firstWhere((a) => a.id == id).onTap();
}

/// Кнопка «…». Своей геометрии не заводит: либо кнопка стиля
/// (`animaIconButton`), либо чем стиль попросит через [builder] — «Ноктюрн»
/// рисует её текстом в ряду вкладок.
class AnimaMoreButton extends StatelessWidget {
  const AnimaMoreButton({
    super.key,
    this.onChats,
    this.onCommands,
    this.onLog,
    this.builder,
  });

  final VoidCallback? onChats;
  final VoidCallback? onCommands;
  final VoidCallback? onLog;

  /// Своя оболочка кнопки: получает `open` и возвращает виджет.
  final Widget Function(BuildContext context, VoidCallback open)? builder;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Builder(
      builder: (btnCtx) {
        void open() {
          final box = btnCtx.findRenderObject() as RenderBox?;
          final pos = box == null
              ? Offset.zero
              : box.localToGlobal(box.size.bottomLeft(Offset.zero));
          unawaited(
            showEvsActionsMenu(
              btnCtx,
              pos,
              onChats: onChats,
              onCommands: onCommands,
              onLog: onLog,
            ),
          );
        }

        final b = builder;
        if (b != null) return b(btnCtx, open);
        return animaIconButton(
          btnCtx,
          icon: Icons.more_horiz,
          tooltip: app.t('animaMore'),
          onTap: open,
        );
      },
    );
  }
}

// --------------------------------------------------------------------------
// Строка списка диалогов: одинаковые жесты во всех стилях.
// --------------------------------------------------------------------------

/// Кнопка «⋮» у строки диалога — видимый способ добраться до того же меню,
/// что и правой кнопкой. Раньше она была только в классической рейке, и в
/// «Ноктюрне» переименовать чат можно было, лишь угадав правый клик.
Widget animaChatRowMenuButton(
  BuildContext context,
  Conversation c,
  AppState app, {
  VoidCallback? onDone,
}) {
  return Builder(
    builder: (btnCtx) => Tooltip(
      message: app.t('animaMore'),
      child: InkResponse(
        radius: 16,
        onTap: () async {
          final box = btnCtx.findRenderObject() as RenderBox?;
          final pos = box == null
              ? Offset.zero
              : box.localToGlobal(box.size.center(Offset.zero));
          await showChatContextMenu(btnCtx, pos, c, app);
          onDone?.call();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Icon(Icons.more_vert, size: 16, color: _faint(context)),
        ),
      ),
    ),
  );
}

/// Единственный список диалогов с поиском. До этого их было три: колонка
/// «Ноктюрна», окно Nexus и выдвижной ящик `ConversationsSheet` — и каждый
/// умел своё (в одном был архив, в другом закрепление, в третьем ни того ни
/// другого). Действия над строкой берутся из `showChatContextMenu`, того же,
/// что и у постоянных списков.
Future<void> showEvsChatsDialog(BuildContext context, AppState app) =>
    showDialog<void>(
      context: context,
      builder: (_) => AnimaChatsDialog(app: app),
    );

class AnimaChatsDialog extends StatefulWidget {
  const AnimaChatsDialog({super.key, required this.app});
  final AppState app;

  @override
  State<AnimaChatsDialog> createState() => _AnimaChatsDialogState();
}

class _AnimaChatsDialogState extends State<AnimaChatsDialog> {
  final _search = TextEditingController();
  AppState get app => widget.app;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _preview(Conversation c) => c.messages.isEmpty
      ? ''
      : c.messages.last.content.replaceAll('\n', ' ').trim();

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final list = [...app.conversations]
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    final shown = q.isEmpty
        ? list
        : list
              .where(
                (c) =>
                    c.title.toLowerCase().contains(q) ||
                    c.messages.any((m) => m.content.toLowerCase().contains(q)),
              )
              .toList();
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Row(
        children: [
          Icon(Icons.forum_outlined, size: 18, color: _accent(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              app.t('nxChats'),
              style: TextStyle(color: _txt(context), fontSize: 16),
            ),
          ),
          Text(
            '${app.conversations.length}',
            style: TextStyle(fontSize: 12, color: _faint(context)),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 12.5, color: _txt(context)),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 15, color: _faint(context)),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                hintText: app.t('ncSearchChats'),
                hintStyle: TextStyle(fontSize: 12.5, color: _faint(context)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 22),
                      child: Text(
                        app.t('nxChatsEmpty'),
                        style: TextStyle(fontSize: 12.5, color: _sub(context)),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (_, i) => _row(shown[i]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            app.newChat();
            Navigator.pop(context);
          },
          child: Text(app.t('newChat')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(app.t('close')),
        ),
      ],
    );
  }

  Widget _row(Conversation c) {
    final active = c.id == app.current?.id;
    final prev = _preview(c);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: active
            ? _accent(context).withValues(alpha: 0.10)
            : _overlayFill(context, 0.04),
        border: Border.all(color: active ? _accent(context) : _stroke(context)),
      ),
      // Правый клик по строке — то же меню, что и по «⋮»: жест одинаков во
      // всех списках диалогов приложения.
      child: GestureDetector(
        onSecondaryTapDown: (d) async {
          await showChatContextMenu(context, d.globalPosition, c, app);
          if (mounted) setState(() {});
        },
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            app.openChat(c);
            Navigator.pop(context);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
            child: Row(
              children: [
                if (c.pinned) ...[
                  Icon(Icons.push_pin, size: 12, color: _faint(context)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: active
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: active
                                    ? _accent(context)
                                    : _txt(context),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _animaRelTime(app, c.updatedAt),
                            style: TextStyle(
                              fontSize: 11,
                              color: _faint(context),
                            ),
                          ),
                        ],
                      ),
                      if (prev.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          prev,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: _sub(context)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                animaChatRowMenuButton(
                  context,
                  c,
                  app,
                  onDone: () {
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// КОМПОЗЕР: то, что обязано быть в поле ввода любого стиля.
// ==========================================================================

// Кнопки прикрепления файла здесь нет намеренно. Она есть только в
// классическом чате, где была всегда (`_RecentAttachSheet` со списком недавних
// файлов); в «Nexus» и «Ноктюрне» её убрали по просьбе — в узкой колонке
// диалога она отнимала у поля ввода столько ширины, что переносилась даже
// подсказка. Это единственное намеренное расхождение между стилями.

/// Список моделей — один на все стили. Раньше он открывался только из шапки
/// классического чата, а Nexus и «Ноктюрн» отправляли за сменой модели в
/// настройки.
void showEvsModelMenu(BuildContext context) {
  final app = context.read<AppState>();
  final nav = Navigator.of(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogCtx) => _ModelMenu(
        onManage: () {
          Navigator.pop(dialogCtx);
          nav.push(
            MaterialPageRoute(
              builder: (_) => const DesktopSettings(initialPage: _Pages.llmConn),
            ),
          );
        },
        onNewChat: () {
          Navigator.pop(dialogCtx);
          app.newChat();
        },
        onCreateImage: () {
          // Раньше здесь была подсказка «картинки пока не умею». Умеет — с тех
          // пор, как появилась «Люмина»; пункт ведёт туда, а не рассказывает.
          Navigator.pop(dialogCtx);
          nav.push(MaterialPageRoute(builder: (_) => const LuminaStudio()));
        },
      ),
    ),
  );
}

/// Пилюля с именем текущей модели. Нажатие — тот же список моделей.
/// В ролевой игре модель диалога закреплена, и пилюля об этом говорит вместо
/// того, чтобы молча ничего не делать.
Widget animaModelPill(BuildContext context, {double fontSize = 13}) {
  final app = context.watch<AppState>();
  final locked = app.current?.rpModeEnabled == true
      ? app.current?.rpConfig?.lockedModel
      : null;
  final label = app.loadingModels
      ? app.t('loadingModels')
      : app.modelDisplayName(locked ?? app.selectedModel, withSuffix: false);
  return Tooltip(
    message: app.t('nxNavModels'),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          app.buzz();
          if (locked != null) {
            showAppSnackBar(context, app.t('rpModelLockedToast'));
            return;
          }
          showEvsModelMenu(context);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          constraints: const BoxConstraints(maxWidth: 260),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _txt(context),
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                locked != null ? Icons.lock_outline : Icons.keyboard_arrow_down,
                color: _sub(context),
                size: locked != null ? 14 : 18,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ==========================================================================
// ПОДПИСИ ПОДСИСТЕМ
// --------------------------------------------------------------------------
// Как называется движок синтеза прямо сейчас и что писать второй строкой.
// Логика неочевидная (клон перебивает выбранный движок, имя модели у сервера
// спрашивается, а не вписано в код), и держать её в двух оболочках значило бы
// расходиться при первой же правке. Nexus и «Призма» зовут отсюда.
// ==========================================================================

/// (название движка, вторая строка).
(String, String) animaTtsEngineLabel(AppState app) {
  if (app.cloneEnabled) return (app.t('nxTtsClone'), 'XTTS');
  if (app.ttsEngineChoice == 'clone') {
    // Название берём у самого сервера: за этим адресом может стоять любая
    // модель, и вписанное в код имя устаревает молча.
    final name = app.cloneServerModel.isNotEmpty
        ? app.cloneServerModel
        : app.t('nxTtsClone');
    return (
      name,
      (app.qwenOnline ?? false) ? app.t('nxOnline') : app.t('nxOffline'),
    );
  }
  if (app.ttsPiperVoice.isEmpty) return (app.t('nxTtsSystem'), 'pyttsx3');
  return ('Piper · ${animaVoiceName(app.ttsPiperVoice)}', 'ru_RU · 22 кГц');
}

/// Человеческое имя голоса Piper по идентификатору файла.
String animaVoiceName(String id) {
  const m = {
    'irina': 'Ирина',
    'denis': 'Денис',
    'dmitri': 'Дмитрий',
    'ruslan': 'Руслан',
  };
  for (final e in m.entries) {
    if (id.contains(e.key)) return e.value;
  }
  final s = id
      .replaceAll('ru_RU-', '')
      .replaceAll('-medium', '')
      .replaceAll('-low', '');
  return s.isEmpty ? id : s;
}

/// Короткое имя языковой модели: `local:` и путь до файла в строке состояния
/// человеку не нужны.
///
/// Копий этой функции было три — в рейке Nexus, в его же строке под репликой и
/// в телеметрии «Ноктюрна», — и они успели разойтись: только одна резала путь
/// по обратной черте, то есть локальная модель на Windows показывалась в двух
/// стилях полным путём. Здесь объединение всех трёх.
String animaShortModel(String m) {
  var s = m.replaceFirst('local:', '');
  if (s.contains('/')) s = s.split('/').last;
  if (s.contains('\\')) s = s.split('\\').last;
  return s;
}

/// Чат включён / выключен — та же настройка, что «Команды → Разрешить чат».
/// Была в Nexus и «Ноктюрне», но не в классическом стиле: выключив чат оттуда,
/// вернуть его можно было только через настройки.
Widget animaChatToggleButton(BuildContext context) {
  final app = context.watch<AppState>();
  final on = app.chatEnabled;
  return animaIconButton(
    context,
    icon: on ? Icons.chat_bubble_outline_rounded : Icons.speaker_notes_off_outlined,
    tooltip: on ? app.t('chatToggleOff') : app.t('chatToggleOn'),
    active: on,
    onTap: () {
      app.buzz();
      app.setChatEnabled(!on);
    },
  );
}

/// Отправить · остановить · подождать. Одна кнопка на три состояния, чтобы
/// место под ней не прыгало.
///
/// «Остановить» доступно всякий раз, когда идёт генерация. В классическом
/// стиле оно было заведено только для ролевой игры, хотя `cancelGeneration`
/// одинаково работает для любого ответа.
Widget animaSendButton(
  BuildContext context, {
  required bool hasContent,
  required bool busy,
  required VoidCallback onSend,
}) {
  final app = context.watch<AppState>();
  if (app.isGenerating) {
    return animaIconButton(
      context,
      icon: Icons.stop_rounded,
      tooltip: app.t('stopGeneration'),
      danger: true,
      onTap: () {
        app.buzz();
        app.cancelGeneration();
      },
    );
  }
  if (busy) {
    final side = _isNoctur(context) ? 42.0 : (_isNexus(context) ? 40.0 : 34.0);
    return SizedBox(
      width: side,
      height: side,
      child: Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: _sub(context)),
        ),
      ),
    );
  }
  return animaIconButton(
    context,
    icon: Icons.arrow_upward_rounded,
    tooltip: app.t('send'),
    filled: hasContent,
    onTap: hasContent ? onSend : null,
  );
}

// ==========================================================================
// ДЕЙСТВИЯ НАД СООБЩЕНИЕМ
// --------------------------------------------------------------------------
// Копировать · править · перегенерировать · продолжить · удалить. Всё это
// умел только классический чат, да и то часть — из длинного нажатия, которого
// мышью не сделать. Теперь набор один, и он под каждой репликой в каждом
// стиле.
// ==========================================================================

Future<void> animaCopyMessage(BuildContext context, ChatMessage m) async {
  final app = context.read<AppState>();
  await Clipboard.setData(ClipboardData(text: m.content));
  if (!context.mounted) return;
  showAppSnackBar(context, app.t('msgCopied'));
}

/// Удаление с возвратом — как у диалогов (`deleteChatWithUndo`): промахнуться
/// по маленькой иконке легко, а переписка не восстанавливается.
void animaDeleteMessage(
  BuildContext context,
  Conversation conv,
  ChatMessage m,
) {
  final app = context.read<AppState>();
  app.deleteMessage(conv, m);
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: _card(context),
      duration: const Duration(seconds: 5),
      content: Text(
        app.t('msgDeleted'),
        style: TextStyle(color: _txt(context)),
      ),
      action: SnackBarAction(
        label: app.t('undo'),
        textColor: _accent(context),
        onPressed: app.undoDeleteMessage,
      ),
    ),
  );
}

/// Правка реплики отдельным окном. Классический чат правит прямо в пузыре и
/// своей правки не теряет — сюда попадают те стили, у которых поля для этого
/// нет.
Future<void> promptEditMessage(
  BuildContext context,
  Conversation conv,
  ChatMessage m,
) {
  final app = context.read<AppState>();
  final ctrl = TextEditingController(text: m.content);
  return showDialog<void>(
    context: context,
    builder: (dialogCtx) => _AppDialog(
      backgroundColor: _card(context),
      title: Text(app.t('msgEdit'), style: TextStyle(color: _txt(context))),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 16,
          style: TextStyle(color: _txt(context)),
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: _stroke(context)),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: Text(app.t('cancel')),
        ),
        TextButton(
          onPressed: () {
            app.editMessage(conv, m, ctrl.text);
            Navigator.pop(dialogCtx);
          },
          child: Text(app.t('save')),
        ),
      ],
    ),
  );
}

/// Контекстное меню реплики (правый клик / долгое нажатие). Раньше жило в
/// `ChatScreen` и было доступно только там.
Future<void> showEvsMessageMenu(
  BuildContext context,
  Conversation conv,
  ChatMessage m,
  Offset pos, {
  ValueChanged<String>? onCompose,
}) async {
  final app = context.read<AppState>();
  final isPinned = conv.pinnedMessageIds.contains(m.id);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  PopupMenuItem<String> item(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) => PopupMenuItem(
    value: value,
    height: 40,
    child: Row(
      children: [
        Icon(icon, size: 18, color: color ?? _sub(context)),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(color: color ?? _txt(context), fontSize: 14),
        ),
      ],
    ),
  );

  final selected = await showMenu<String>(
    context: context,
    color: _card(context),
    position: RelativeRect.fromRect(
      Rect.fromPoints(pos, pos),
      Offset.zero & (overlay?.size ?? Size.zero),
    ),
    items: [
      item('copy', Icons.copy_outlined, app.t('msgCopy')),
      if (onCompose != null)
        item('compose', Icons.edit_note_outlined, app.t('msgUseInComposer')),
      item('edit', Icons.edit_outlined, app.t('msgEdit')),
      item('remember', Icons.psychology_alt_outlined, app.t('msgRemember')),
      item('forget', Icons.delete_outline, app.t('msgForgetMemory')),
      item(
        'pin',
        isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        isPinned ? app.t('msgUnpinContext') : app.t('msgPinContext'),
      ),
      item(
        'delete',
        Icons.delete_forever_outlined,
        app.t('msgDelete'),
        color: _danger(context),
      ),
    ],
  );
  if (selected == null || !context.mounted) return;
  String? toast;
  switch (selected) {
    case 'copy':
      await animaCopyMessage(context, m);
      return;
    case 'compose':
      onCompose?.call(m.content);
      return;
    case 'edit':
      await promptEditMessage(context, conv, m);
      return;
    case 'remember':
      final persona = conv.persona ?? app.persona;
      if (persona.askBeforeRemembering) {
        final confirmed = await animaPickMemoryCategory(context, app);
        if (confirmed != true || !context.mounted) return;
      }
      app.rememberMessageContent(m.content);
      toast = app.t('msgRemembered');
    case 'forget':
      app.forgetMessageMemory(m.content);
      toast = app.t('msgForgotten');
    case 'pin':
      app.toggleMessagePin(conv, m);
      toast = isPinned ? app.t('msgUnpinned') : app.t('msgPinned');
    case 'delete':
      animaDeleteMessage(context, conv, m);
      return;
  }
  if (toast != null && context.mounted) showAppSnackBar(context, toast);
}

/// Куда положить запомненное. Вынесено из `ChatScreen`, чтобы меню реплики
/// работало одинаково во всех стилях.
Future<bool?> animaPickMemoryCategory(BuildContext context, AppState app) {
  const categories = [
    'memCatPreference',
    'memCatProfile',
    'memCatProject',
    'memCatOther',
  ];
  var selected = categories.first;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('chooseMemoryCategory'),
          style: TextStyle(color: _txt(context)),
        ),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final cat in categories)
              ChoiceChip(
                label: Text(app.t(cat)),
                selected: selected == cat,
                labelStyle: TextStyle(
                  color: selected == cat ? _onAccent(context) : _txt(context),
                  fontWeight: FontWeight.w500,
                ),
                selectedColor: _accent(context),
                backgroundColor: _bg(context).withValues(alpha: 0.4),
                side: BorderSide(color: _stroke(context)),
                onSelected: (_) => setDialogState(() => selected = cat),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(app.t('save')),
          ),
        ],
      ),
    ),
  );
}

/// Полоса действий под репликой: копировать · править · перегенерировать ·
/// продолжить · удалить.
///
/// Видна всегда, а не по наведению: полоса, которая появляется под курсором,
/// не находится ни с клавиатуры, ни на ощупь, и именно из-за этого половина
/// действий раньше жила в длинном нажатии — жесте, которого у мыши нет.
/// «Перегенерировать» и «Продолжить» показываются только у последнего ответа:
/// в середине переписки они переписали бы не то, на что нажали.
class AnimaMessageActions extends StatelessWidget {
  const AnimaMessageActions({
    super.key,
    required this.conversation,
    required this.message,
    this.isLast = false,
    this.onEdit,
    this.onRegenerate,
    this.onContinue,
    this.alignEnd = false,
  });

  final Conversation conversation;
  final ChatMessage message;
  final bool isLast;

  /// Правка на месте, если она у стиля есть (классический пузырь). Иначе —
  /// общее окно правки.
  final void Function(ChatMessage m)? onEdit;

  /// Свои обёртки над перегенерацией/продолжением, если стилю нужно погасить
  /// собственный композер на время ответа.
  final VoidCallback? onRegenerate;
  final VoidCallback? onContinue;

  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final assistant = message.role != 'user';
    final tail = assistant && isLast && !app.isGenerating;

    Widget btn(IconData icon, String tip, VoidCallback onTap, {bool danger = false}) {
      return Tooltip(
        message: tip,
        child: InkResponse(
          radius: 16,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(
              icon,
              size: 15,
              color: danger ? _danger(context) : _faint(context),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment:
            alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          btn(Icons.copy_outlined, app.t('msgCopy'),
              () => unawaited(animaCopyMessage(context, message))),
          btn(Icons.edit_outlined, app.t('msgEdit'), () {
            final edit = onEdit;
            if (edit != null) {
              edit(message);
            } else {
              unawaited(promptEditMessage(context, conversation, message));
            }
          }),
          if (tail)
            btn(Icons.refresh, app.t('msgRegenerate'), () {
              final r = onRegenerate;
              if (r != null) {
                r();
              } else {
                app.buzz();
                unawaited(app.regenerateLastReply(conversation));
              }
            }),
          if (tail)
            btn(Icons.fast_forward, app.t('msgContinue'), () {
              final c = onContinue;
              if (c != null) {
                c();
              } else {
                app.buzz();
                unawaited(app.continueReply(conversation));
              }
            }),
          btn(
            Icons.delete_outline,
            app.t('msgDelete'),
            () => animaDeleteMessage(context, conversation, message),
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// Обёртка реплики: правый клик и долгое нажатие открывают меню, снизу —
/// полоса действий. Три оболочки рисуют разные пузыри, но ведут себя так
/// одинаково.
class AnimaMessageFrame extends StatelessWidget {
  const AnimaMessageFrame({
    super.key,
    required this.conversation,
    required this.message,
    required this.child,
    this.isLast = false,
    this.alignEnd = false,
    this.actions = true,
    this.onEdit,
    this.onCompose,
    this.onRegenerate,
    this.onContinue,
  });

  final Conversation conversation;
  final ChatMessage message;
  final Widget child;
  final bool isLast;
  final bool alignEnd;

  /// false — пока реплика печатается: действовать ещё не над чем.
  final bool actions;

  final void Function(ChatMessage m)? onEdit;
  final ValueChanged<String>? onCompose;
  final VoidCallback? onRegenerate;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    void menu(Offset pos) => unawaited(
      showEvsMessageMenu(
        context,
        conversation,
        message,
        pos,
        onCompose: onCompose,
      ),
    );
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onSecondaryTapDown: (d) => menu(d.globalPosition),
          onLongPressStart: (d) => menu(d.globalPosition),
          child: child,
        ),
        if (actions)
          AnimaMessageActions(
            conversation: conversation,
            message: message,
            isLast: isLast,
            alignEnd: alignEnd,
            onEdit: onEdit,
            onRegenerate: onRegenerate,
            onContinue: onContinue,
          ),
      ],
    );
  }
}
