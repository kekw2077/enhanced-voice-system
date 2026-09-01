part of '../main.dart';

/* ==========================================================================
   МЕНЮ В ТРЕЕ — СВОИМ ОКНОМ
   --------------------------------------------------------------------------
   Меню, которое Windows рисует по правому щелчку на значке, покрасить нельзя:
   его рисует система, а не мы, и оно следует теме системы, а не стилю EVS.
   Единственный способ получить в нём стекло «Призмы» или углы «Ноктюрна» —
   чтобы меню БЫЛО нашим окном.

   Приём тот же, что уже работает для плавающего виджета: тот же бинарник
   запускается с ключом (`evs.exe --tray-menu --port=N`), поднимает крошечное
   прозрачное окно поверх всех и слушает главный процесс по локальному сокету.
   Отличие одно: виджет всё время на виду, а меню всё время СПРЯТАНО и
   показывается на месте курсора по щелчку. Держать его наготове, а не
   запускать по нажатию, — сознательный размен: процесс Flutter стартует
   полсекунды-секунду, и меню из трёх пунктов, которое столько думает, лучше
   бы осталось системным.

   Если окно почему-то не поднялось (не хватило прав, не нашёлся exe), правый
   щелчок открывает обычное системное меню — оно остаётся на месте как запас.
   Меню, которое не открылось вовсе, хуже некрасивого.
   ========================================================================== */

/// Пункт меню трея. `d` — контур из [PrismIcons] для «Призмы»; остальные стили
/// берут обычный значок из [_kTrayMenuIcons] по ключу пункта.
///
/// Значок НЕ едет по проводу числом. Flutter вырезает из шрифта значков всё,
/// что не встретилось в коде константой, и `IconData(число)`, собранная на
/// лету, ломает сборку релиза целиком («non-constant instances of IconData»).
/// Поэтому по проводу идёт ключ, а значок берётся из таблицы констант.
class TrayMenuEntry {
  const TrayMenuEntry(
    this.key,
    this.label, {
    required this.d,
    this.separatorBefore = false,
    this.disabled = false,
    this.checked = false,
    this.danger = false,
  });

  final String key;
  final String label;
  final String d;
  final bool separatorBefore, disabled, checked, danger;

  IconData get icon => _kTrayMenuIcons[key] ?? Icons.circle_outlined;

  Map<String, dynamic> toJson() => {
        'k': key,
        'l': label,
        'd': d,
        if (separatorBefore) 'sep': true,
        if (disabled) 'off': true,
        if (checked) 'on': true,
        if (danger) 'bad': true,
      };

  static TrayMenuEntry fromJson(Map<String, dynamic> m) => TrayMenuEntry(
        (m['k'] as String?) ?? '',
        (m['l'] as String?) ?? '',
        d: (m['d'] as String?) ?? PrismIcons.dots,
        separatorBefore: m['sep'] == true,
        disabled: m['off'] == true,
        checked: m['on'] == true,
        danger: m['bad'] == true,
      );
}

/// Значки пунктов для «Классического», «Nexus» и «Ноктюрна». Новый пункт без
/// строки здесь получит кружок — заметно, но не сломано.
const Map<String, IconData> _kTrayMenuIcons = {
  'show': Icons.open_in_new_rounded,
  'overlay': Icons.bubble_chart_outlined,
  'quit': Icons.power_settings_new_rounded,
  'loading': Icons.hourglass_empty_rounded,
};

// Геометрия меню. Держится здесь, потому что размер окна считает главный
// процесс (ему решать, куда его ставить), а рисует дочерний — разойдись эти
// числа, и меню поехало бы относительно курсора.
const double _kTrayMenuWidth = 246;
const double _kTrayMenuRow = 38;
const double _kTrayMenuSep = 13;
const double _kTrayMenuPadV = 7;

/// Поле вокруг меню внутри окна: тень рисуется в нём. Без поля она обрезалась
/// бы краем окна ровным прямоугольником, а в 18 точек — обрезалась почти вся,
/// и меню лежало на чужих окнах без единого признака, что оно поверх них.
const double _kTrayMenuMargin = 46;

/// Тень под меню. Та же, что под окном установки обновления: меню всплывает
/// над чужими окнами и обоями, где мягкой панельной тени не хватает — её там
/// просто не видно.
const List<BoxShadow> _kTrayMenuShadow = [
  BoxShadow(
      color: Color(0x8C000000),
      blurRadius: 46,
      spreadRadius: 2,
      offset: Offset(0, 18)),
  BoxShadow(color: Color(0x40000000), blurRadius: 14, offset: Offset(0, 4)),
];

/// Заливка меню. В окне программы стеклянная панель лежит на непрозрачной
/// странице, и 4 % белого поверх неё читаются как стекло. Здесь под панелью
/// НЕТ НИЧЕГО: окно прозрачное, за ним сразу рабочий стол, и та же заливка
/// давала не стекло, а плёнку — сквозь меню читался текст чужой программы.
/// Размытие тут тоже не спасает: BackdropFilter размывает то, что нарисовано
/// в этом же окне, а за его краем размывать нечего. Поэтому меню подмешивает
/// под стекло собственную страницу и остаётся своего цвета, но матовым.
Color _trayMenuFill(BuildContext c) {
  final pal = _pal(c);
  final base = pal.bg.withValues(alpha: 0.94);
  return Color.alphaBlend(_isPrism(c) ? _prismCardFill(c) : _card(c), base);
}

Size _trayMenuSize(List<TrayMenuEntry> items) {
  var h = _kTrayMenuPadV * 2;
  for (final e in items) {
    if (e.separatorBefore) h += _kTrayMenuSep;
    h += _kTrayMenuRow;
  }
  return Size(_kTrayMenuWidth + _kTrayMenuMargin * 2,
      h + _kTrayMenuMargin * 2);
}

// ==========================================================================
// СТОРОНА ГЛАВНОГО ПРОЦЕССА
// ==========================================================================

typedef _AllowSetForegroundNative = Int32 Function(Uint32);
typedef _AllowSetForegroundDart = int Function(int);

/// Держит окно меню и говорит ему, когда и где показаться.
class TrayMenuServer {
  TrayMenuServer._();
  static final TrayMenuServer instance = TrayMenuServer._();

  AppState? _app;
  io.HttpServer? _http;
  io.WebSocket? _client;
  io.Process? _proc;
  String _lastCfg = '';
  List<TrayMenuEntry> _items = const [];
  void Function(String key)? _onPick;

  /// Окно поднялось и подключилось — можно показывать своё меню.
  bool get ready => _client != null;

  Future<void> start(AppState app,
      {required void Function(String key) onPick}) async {
    _app = app;
    _onPick = onPick;
    app.addListener(_pushCfg);
    await _spawn();
  }

  /// Пункты меню. Задаются главным процессом, потому что только он знает, что
  /// сейчас можно: во время загрузки «Показать EVS» ничего не откроет.
  void setItems(List<TrayMenuEntry> items) {
    _items = items;
    _pushCfg();
  }

  Future<void> _ensureServer() async {
    if (_http != null) return;
    final srv = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    _http = srv;
    srv.listen((req) async {
      try {
        final ws = await io.WebSocketTransformer.upgrade(req);
        await _client?.close();
        _client = ws;
        _lastCfg = ''; // новому окну — полный снимок
        _pushCfg();
        ws.listen(_onMsg, onDone: () {
          if (identical(_client, ws)) _client = null;
        }, onError: (_) {});
      } catch (_) {}
    });
  }

  /// Запускается из копии с говорящим именем — в диспетчере задач видно, что
  /// это меню трея, а не третий безымянный evs.exe.
  Future<String> _menuExe() async {
    final main = io.Platform.resolvedExecutable;
    try {
      final sep = io.Platform.pathSeparator;
      final copy = io.File('${io.File(main).parent.path}${sep}evs_menu.exe');
      final src = io.File(main);
      if (!await copy.exists() || await copy.length() != await src.length()) {
        await src.copy(copy.path);
      }
      return copy.path;
    } catch (_) {
      return main;
    }
  }

  Future<void> _spawn() async {
    if (_proc != null) return;
    try {
      await _ensureServer();
      final port = _http!.port;
      final exe = await _menuExe();
      _proc = await io.Process.start(
          exe, ['--tray-menu', '--port=$port'],
          mode: io.ProcessStartMode.detached);
      ProcessJob.instance.add(_proc!.pid); // умрёт вместе с приложением
    } catch (_) {
      _proc = null;
    }
  }

  void _pushCfg() {
    final app = _app;
    final ws = _client;
    if (app == null || ws == null) return;
    final cfg = jsonEncode({
      't': 'cfg',
      'style': app.appStyle.name,
      'theme': app.themeMode.name,
      'accent': app.prismAccent.name,
      'lang': app.lang,
      'items': _items.map((e) => e.toJson()).toList(),
    });
    if (cfg == _lastCfg) return;
    _lastCfg = cfg;
    try {
      ws.add(cfg);
    } catch (_) {}
  }

  /// Показать меню у курсора. `false` — окна нет, зовите системное.
  Future<bool> popUp() async {
    final ws = _client;
    if (ws == null || _items.isEmpty) return false;
    try {
      _allowForeground();
      final at = await screenRetriever.getCursorScreenPoint();
      ws.add(jsonEncode({'t': 'show', 'x': at.dx, 'y': at.dy}));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Отдать процессу меню право выйти на передний план.
  ///
  /// Windows не даёт забрать фокус кому попало: `SetForegroundWindow` работает
  /// только у процесса, который сейчас на переднем плане или получил последний
  /// ввод. Щелчок по значку получил ГЛАВНЫЙ процесс, а окно поднимает
  /// дочерний, — и меню открывалось без фокуса. Без фокуса нет и события
  /// потери фокуса, поэтому щелчок мимо меню его не закрывал, а Esc не
  /// доходил. `AllowSetForegroundWindow` — штатный способ передать это право.
  void _allowForeground() {
    final pid = _proc?.pid;
    if (pid == null) return;
    try {
      DynamicLibrary.open('user32.dll').lookupFunction<
          _AllowSetForegroundNative,
          _AllowSetForegroundDart>('AllowSetForegroundWindow')(pid);
    } catch (_) {}
  }

  void _onMsg(dynamic raw) {
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      if (m['t'] == 'pick') {
        final k = m['k'] as String?;
        if (k != null) _onPick?.call(k);
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _client?.close();
    } catch (_) {}
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
    _client = null;
  }
}

// ==========================================================================
// СТОРОНА ОКНА МЕНЮ
// ==========================================================================

/// Точка входа процесса меню (`evs.exe --tray-menu --port=N`). Ни настроек,
/// ни трея, ни движка: окно только рисует список и отвечает, что нажали.
Future<void> _trayMenuMain(List<String> args) async {
  var port = 0;
  for (final a in args) {
    if (a.startsWith('--port=')) port = int.tryParse(a.substring(7)) ?? 0;
  }
  await windowManager.ensureInitialized();
  try {
    await acrylic.Window.initialize();
  } catch (_) {}
  const opts = WindowOptions(
    size: Size(_kTrayMenuWidth + _kTrayMenuMargin * 2, 200),
    title: 'EVS Menu',
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: true,
    alwaysOnTop: true,
  );
  unawaited(windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.setAsFrameless();
    try {
      await acrylic.Window.setEffect(
        effect: acrylic.WindowEffect.transparent,
        color: const Color(0x00000000),
        dark: true,
      );
    } catch (_) {}
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    // Окно ждёт своего часа спрятанным: показываем его только по щелчку.
    await windowManager.hide();
  }));
  runApp(TrayMenuApp(port: port));
}

class TrayMenuApp extends StatefulWidget {
  const TrayMenuApp({super.key, required this.port});
  final int port;
  @override
  State<TrayMenuApp> createState() => _TrayMenuAppState();
}

class _TrayMenuAppState extends State<TrayMenuApp> with WindowListener {
  // Тот же приём, что у виджета: пустой AppState как держатель настроек.
  // Все общие помощники (_pal, _stroke, PrismPanel) читают стиль и тему через
  // провайдер, поэтому меню красится ровно так же, как остальная программа, и
  // ни строчки оформления дублировать не нужно. load() здесь не зовётся и ни
  // один setter не срабатывает — процесс ничего не пишет в настройки.
  AppState? _cfg;
  io.WebSocket? _ws;
  List<TrayMenuEntry> _items = const [];
  bool _open = false;
  // Когда меню показали. Первые мгновения после показа сообщение о потере
  // фокуса игнорируется: окно только что подняли, фокус ещё едет к нему, и
  // ранний blur закрывал бы меню сразу после открытия.
  DateTime _shown = DateTime.fromMillisecondsSinceEpoch(0);
  // Где сейчас стоит карточка меню в координатах экрана — по ней опрос мыши
  // решает, попал щелчок в меню или мимо.
  Rect _cardRect = Rect.zero;
  Timer? _watch;
  // Кнопка мыши хоть раз отпускалась после показа. Меню открывается ещё при
  // нажатой кнопке — той самой, которой щёлкнули по значку, — и без этой
  // проверки оно закрывалось бы тем же щелчком, что открыл.
  bool _sawUp = false;
  _GetAsyncKeyStateDart? _keys;
  bool _keysTried = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _watch?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _boot() async {
    await _installPortablePrefs();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _cfg = AppState(prefs));
    await _connect();
  }

  Future<void> _connect() async {
    try {
      _ws = await io.WebSocket.connect('ws://127.0.0.1:${widget.port}');
      _ws!.listen(_onMsg, onDone: _bye, onError: (_) => _bye());
    } catch (_) {
      _bye();
    }
  }

  // Главный процесс закрылся — меню без него бессмысленно.
  void _bye() => io.exit(0);

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  Future<void> _onMsg(dynamic raw) async {
    final app = _cfg;
    if (app == null) return;
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (m['t']) {
        case 'cfg':
          app.applyTrayMenuCfg(m);
          setState(() => _items = ((m['items'] as List?) ?? const [])
              .map((e) => TrayMenuEntry.fromJson(e as Map<String, dynamic>))
              .toList());
          break;
        case 'show':
          await _showAt(
            (m['x'] as num?)?.toDouble() ?? 0,
            (m['y'] as num?)?.toDouble() ?? 0,
          );
          break;
      }
    } catch (_) {}
  }

  /// Ставим меню так, чтобы его угол пришёлся на курсор, и загоняем целиком в
  /// видимую часть экрана. Значок трея почти всегда в правом нижнем углу,
  /// поэтому по умолчанию меню растёт ВВЕРХ И ВЛЕВО — как системное.
  Future<void> _showAt(double cx, double cy) async {
    if (_items.isEmpty) return;
    final size = _trayMenuSize(_items);
    await windowManager.setSize(size);
    var x = cx - size.width + _kTrayMenuMargin;
    var y = cy - size.height + _kTrayMenuMargin;
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final dp = d.visiblePosition ?? Offset.zero;
        final ds = d.visibleSize ?? d.size;
        if (!((dp & ds).contains(Offset(cx, cy)))) continue;
        x = x.clamp(dp.dx - _kTrayMenuMargin,
            dp.dx + ds.width - size.width + _kTrayMenuMargin);
        y = y.clamp(dp.dy - _kTrayMenuMargin,
            dp.dy + ds.height - size.height + _kTrayMenuMargin);
        break;
      }
    } catch (_) {}
    await windowManager.setPosition(Offset(x, y));
    _cardRect = Rect.fromLTWH(
      x + _kTrayMenuMargin,
      y + _kTrayMenuMargin,
      size.width - _kTrayMenuMargin * 2,
      size.height - _kTrayMenuMargin * 2,
    );
    _shown = DateTime.now();
    _sawUp = false;
    setState(() => _open = true);
    await windowManager.show();
    await windowManager.focus();
    _watch?.cancel();
    // 70 мс: щелчок мимо закрывает меню на глаз мгновенно, а стоит опрос трёх
    // состояний клавиш и чтения положения курсора — и только пока меню открыто.
    _watch = Timer.periodic(const Duration(milliseconds: 70), (_) => _sniff());
  }

  Future<void> _hide() async {
    if (!_open) return;
    _watch?.cancel();
    _watch = null;
    setState(() => _open = false);
    await windowManager.hide();
  }

  _GetAsyncKeyStateDart? get _keyState {
    if (!_keysTried) {
      _keysTried = true;
      try {
        _keys = DynamicLibrary.open('user32.dll').lookupFunction<
            _GetAsyncKeyStateNative, _GetAsyncKeyStateDart>('GetAsyncKeyState');
      } catch (_) {}
    }
    return _keys;
  }

  /// Щелчок мимо меню — закрыть. Событие потери фокуса ниже остаётся, но
  /// полагаться только на него нельзя: фокус к отдельному процессу приезжает
  /// не всегда (см. `AllowSetForegroundWindow`), а меню, которое не уходит с
  /// экрана, пока не ткнёшь в него самого, — хуже системного.
  ///
  /// Мышь читается тем же `GetAsyncKeyState`, что и Push-to-Talk: состояние
  /// кнопок, без единого перехваченного щелчка — чужие окна получают свой
  /// клик целиком.
  Future<void> _sniff() async {
    if (!_open) return;
    final fn = _keyState;
    if (fn == null) return;
    const vkLeft = 0x01, vkRight = 0x02, vkMiddle = 0x04;
    final down = (fn(vkLeft) & 0x8000) != 0 ||
        (fn(vkRight) & 0x8000) != 0 ||
        (fn(vkMiddle) & 0x8000) != 0;
    if (!down) {
      _sawUp = true;
      return;
    }
    if (!_sawUp) return;
    try {
      if (_cardRect.contains(await screenRetriever.getCursorScreenPoint())) {
        return;
      }
    } catch (_) {
      return;
    }
    await _hide();
  }

  // Щелчок мимо меню закрывает его — как любое меню в системе.
  @override
  void onWindowBlur() {
    if (DateTime.now().difference(_shown) < const Duration(milliseconds: 320)) {
      return;
    }
    unawaited(_hide());
  }

  void _pick(TrayMenuEntry e) {
    if (e.disabled) return;
    unawaited(_hide());
    _send({'t': 'pick', 'k': e.key});
  }

  @override
  Widget build(BuildContext context) {
    final app = _cfg;
    if (app == null) return const SizedBox.shrink();
    final skin = skinFor(app.appStyle, app.themeMode, accent: app.prismAccent);
    return ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData(
          useMaterial3: true,
          brightness: skin.pal.brightness,
          scaffoldBackgroundColor: Colors.transparent,
          fontFamily: evsFontFamily(app.appStyle),
          fontFamilyFallback:
              app.appStyle == AppStyle.prism ? kPrismFontFallback : null,
        ),
        home: Builder(
          builder: (context) => _TrayMenuView(
            items: _items,
            onPick: _pick,
            onDismiss: () => unawaited(_hide()),
          ),
        ),
      ),
    );
  }
}

/// Само меню. Оформление берётся из общих токенов, поэтому «Ноктюрн» получает
/// свои углы и цвета, «Nexus» — свои, а «Призма» — стекло с размытием.
class _TrayMenuView extends StatelessWidget {
  const _TrayMenuView({
    required this.items,
    required this.onPick,
    required this.onDismiss,
  });

  final List<TrayMenuEntry> items;
  final void Function(TrayMenuEntry) onPick;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final prism = _isPrism(context);
    final rows = <Widget>[];
    for (final e in items) {
      if (e.separatorBefore) {
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          child: Container(height: 1, color: _stroke(context)),
        ));
      }
      rows.add(_TrayMenuRow(entry: e, onTap: () => onPick(e)));
    }

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );

    final radius = prism ? 18.0 : _skin(context).radiusCard;
    // Тень одна на оба оформления и рисуется ОТДЕЛЬНЫМ слоем под карточкой:
    // у «Призмы» своя, панельная, рассчитана на то, что панель лежит на
    // странице программы, а не на обоях.
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: _kTrayMenuShadow,
      ),
      child: prism
          ? PrismPanel(
              radius: radius,
              color: _trayMenuFill(context),
              padding: const EdgeInsets.symmetric(vertical: _kTrayMenuPadV),
              child: body,
            )
          : Container(
              padding: const EdgeInsets.symmetric(vertical: _kTrayMenuPadV),
              decoration: BoxDecoration(
                color: _trayMenuFill(context),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: _stroke(context)),
              ),
              child: body,
            ),
    );

    // Esc закрывает — привычка, которая ничего не стоит.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
        },
        child: Focus(
          autofocus: true,
          // Поле под тень — часть окна, и щелчок по нему до рабочего стола не
          // доходит. Без этого угол в 46 точек вокруг меню молча съедал бы
          // клик, которым его пытаются закрыть.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: Padding(
              padding: const EdgeInsets.all(_kTrayMenuMargin),
              // Щелчок по самой карточке — не по пункту, а в поле между
              // ними — не должен доходить до закрытия выше.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrayMenuRow extends StatefulWidget {
  const _TrayMenuRow({required this.entry, required this.onTap});
  final TrayMenuEntry entry;
  final VoidCallback onTap;

  @override
  State<_TrayMenuRow> createState() => _TrayMenuRowState();
}

class _TrayMenuRowState extends State<_TrayMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final prism = _isPrism(context);
    final on = !e.disabled;
    final fg = e.disabled
        ? _faint(context)
        : (e.danger ? _danger(context) : _txt(context));
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: on ? widget.onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: _kTrayMenuRow,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: _hover && on
                  ? (prism ? _prismHover(context) : _accent(context)
                      .withValues(alpha: 0.14))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(prism ? 12 : 9),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: prism
                      ? PrismIcon(e.d, size: 16, stroke: 1.9, color: fg)
                      : Icon(e.icon, size: 17, color: fg),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    e.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: fg,
                      // Обводка «Призмы» здесь не нужна: под меню своя
                      // непрозрачная подложка, а не аврора.
                      shadows: const [],
                    ),
                  ),
                ),
                // Галочка у переключателя: меню показывает СОСТОЯНИЕ, а не
                // только действие — иначе «Плавающий виджет» ничего не
                // сообщает о том, включён он сейчас или нет.
                if (e.checked)
                  Icon(Icons.check_rounded, size: 16, color: _accent(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
