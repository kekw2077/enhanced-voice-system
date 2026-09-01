part of '../main.dart';

/* ==========================================================================
   Переводчик игры — расширение EVS поверх стороннего приложения
   -------------------------------------------------------------------------
   Оверлей-переводчик Chaos Zero Nightmare живёт отдельным процессом (WPF,
   свой слой DirectComposition поверх окна игры) — внутрь Flutter его не
   поместить. EVS им управляет: запускает, следит, показывает состояние.
   Ровно тот же приём, что у CloneServer в desktop_integration.dart.

   1. Экран один на все оболочки. `embedded: true` — вкладка внутри «Призмы»,
      без флага — отдельная страница в остальных трёх стилях. Своих цветов
      здесь нет ни одного: evsCard/evsRow/evsToggle сами знают, как выглядеть
      в текущем стиле, поэтому будущий пятый стиль подхватится сам.
   2. Процесс регистрируется в ProcessJob. Осиротевший переводчик держал бы
      захват окна и слой поверх игры до перезагрузки.
   3. Готовность ловится по строке в stdout, а не по таймеру: приложению надо
      поднять D3D, DirectComposition и модели OCR, и это занимает по-разному
      на разном железе.
   ========================================================================== */

enum CznState { stopped, starting, running, failed }

/// Управление внешним процессом переводчика.
///
/// Синглтон с ValueNotifier, а не провайдер: состояние нужно и экрану, и
/// сторожу игры, и завершению приложения — как у [CloneServer].
class CznTranslator {
  CznTranslator._();
  static final CznTranslator instance = CznTranslator._();

  /// Строка, которую переводчик печатает, подняв оверлей и модели.
  static const readyMarker = 'CZN_TRANSLATOR_READY';

  final ValueNotifier<CznState> state = ValueNotifier(CznState.stopped);

  /// Причина отказа на языке пользователя. Пусто, пока всё в порядке.
  final ValueNotifier<String> problem = ValueNotifier('');

  io.Process? _proc;
  bool _busy = false;
  Timer? _watch;

  bool get isRunning => state.value == CznState.running;

  /// Путь к CznTranslator.exe: сначала явная настройка, затем рядом с EVS.
  String? resolveExe(AppState app) {
    final manual = app.cznExePath.trim();
    if (manual.isNotEmpty) {
      return io.File(manual).existsSync() ? manual : null;
    }

    final sep = io.Platform.pathSeparator;
    final exeDir = io.File(io.Platform.resolvedExecutable).parent.path;
    final near = io.File('$exeDir${sep}czn${sep}CznTranslator.exe');
    return near.existsSync() ? near.path : null;
  }

  Future<void> start(AppState app) async {
    if (_busy || isRunning) return;
    _busy = true;
    problem.value = '';
    state.value = CznState.starting;

    try {
      final exe = resolveExe(app);
      if (exe == null) {
        problem.value = app.t('cznNoExe');
        state.value = CznState.failed;
        return;
      }

      _proc = await io.Process.start(exe, const [], runInShell: false);
      ProcessJob.instance.add(_proc!.pid);

      final up = Completer<void>();
      for (final stream in [_proc!.stdout, _proc!.stderr]) {
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen((line) {
          unawaited(appendLog('czn', line));
          if (!up.isCompleted && line.contains(readyMarker)) up.complete();
        });
      }

      unawaited(_proc!.exitCode.then((code) {
        _proc = null;
        if (!up.isCompleted) {
          problem.value = '${app.t('cznExited')} ($code)';
          state.value = CznState.failed;
          up.complete();
        } else {
          state.value = CznState.stopped;
        }
      }));

      // Щедрый запас: первый запуск прогревает ONNX, и на встроенной графике
      // это десятки секунд.
      await up.future.timeout(const Duration(seconds: 120));
      if (state.value != CznState.failed) state.value = CznState.running;
    } catch (e) {
      unawaited(appendLog('errors', 'czn: $e'));
      if (state.value != CznState.failed) {
        problem.value = app.t('cznFailed');
        state.value = CznState.failed;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> stop() async {
    _watch?.cancel();
    _watch = null;
    _proc?.kill();
    _proc = null;
    state.value = CznState.stopped;
    problem.value = '';
  }

  /// Сторож: поднимает переводчик, как только появляется окно игры.
  ///
  /// Опрашивается `tasklist`, а не процесс игры — античит запрещает любое
  /// обращение к ней, и имя в списке задач это как раз то, что видно снаружи.
  /// Пять секунд достаточно: игра грузится дольше, а лишний опрос стоит
  /// заметно дороже, чем кажется, — это запуск процесса.
  void watchForGame(AppState app) {
    _watch?.cancel();
    if (!app.cznAutoStart) return;

    _watch = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (isRunning || _busy) return;
      if (await isGameRunning()) await start(app);
    });
  }

  /// Живое состояние переводчика: он пишет его рядом с собой раз в секунду.
  ///
  /// Файл, а не запрос: Flutter здесь не умеет читать SQLite, и тащить нативную
  /// зависимость ради одного процента было бы плохой сделкой. Переводчик и так
  /// считает эти числа для своей панели — остаётся их прочитать.
  Future<Map<String, dynamic>?> readStatus(AppState app) async {
    final exe = resolveExe(app);
    if (exe == null) return null;

    final file = io.File(
      '${io.File(exe).parent.path}${io.Platform.pathSeparator}status.json',
    );
    if (!file.existsSync()) return null;

    try {
      final raw = jsonDecode(await file.readAsString());
      return raw is Map<String, dynamic> ? raw : null;
    } catch (_) {
      // Файл переписывается на ходу: поймать его на середине — обычное дело,
      // и следующая попытка через секунду прочитает целый.
      return null;
    }
  }

  static Future<bool> isGameRunning() async {
    if (!io.Platform.isWindows) return false;
    try {
      final r = await io.Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq $cznGameProcess.exe', '/NH'],
        runInShell: true,
      );
      return '${r.stdout}'.contains(cznGameProcess);
    } catch (_) {
      return false;
    }
  }
}

/// Имя процесса игры. Не «ChaosZeroNightmare» и не имя файла загрузчика:
/// STOVE Shield перезапускает игру под собой, и в списке задач видно именно
/// это. Замерено на живой сессии.
const cznGameProcess = 'ssr-stove-shield';

/// Дозаливка перевода через станцию, запускаемая из EVS.
///
/// Считает не EVS: рядом с переводчиком лежит тот же питоновский конвейер, что
/// гоняли вручную, и встраиваемый Python к нему — оба кладёт `bundle-station.ps1`.
/// Маскировка разметки и разбор ответа станции — проверенный код, переписывать
/// его на Dart значило бы завести вторую реализацию, которая разъедется с первой.
/// EVS только запускает, показывает прогресс и умеет остановить.
class CznFill {
  CznFill._();
  static final CznFill instance = CznFill._();

  final ValueNotifier<bool> running = ValueNotifier(false);
  final ValueNotifier<double> progress = ValueNotifier(0);
  final ValueNotifier<String> message = ValueNotifier('');

  /// Состояние базы, каким его видит идущая заливка. Пусто, пока не сказали.
  ///
  /// Заливка печатает разбивку после каждой порции: во время долгого прогона
  /// это единственное, что двигается, а переводчик при этом может быть вообще
  /// не запущен — и тогда status.json никто не пишет.
  final ValueNotifier<Map<String, int>> counts =
      ValueNotifier(const <String, int>{});

  /// Покрытие по разным текстам, как его видит идущая заливка: переведено и
  /// всего. Нули — ещё не сообщала.
  final ValueNotifier<(int, int)> texts = ValueNotifier((0, 0));

  io.Process? _proc;

  /// Папка переводчика, где лежит всё: exe, база, tools, runtime.
  String? _home(AppState app) {
    final exe = CznTranslator.instance.resolveExe(app);
    return exe == null ? null : io.File(exe).parent.path;
  }

  Future<void> start(AppState app) async {
    if (running.value) return;

    final home = _home(app);
    if (home == null) {
      message.value = app.t('cznNoExe');
      return;
    }

    final sep = io.Platform.pathSeparator;
    final python = io.File('$home${sep}runtime${sep}python${sep}python.exe');
    final script = io.File('$home${sep}tools${sep}station_fill.py');

    if (!python.existsSync() || !script.existsSync()) {
      message.value = app.t('cznNoConveyor');
      return;
    }

    // Станция описана в config.json переводчика; заливке нужен отдельный файл,
    // поэтому нужная секция выкладывается рядом. Один источник правды остаётся
    // тот же — config.json.
    final cfg = await CznConfig.load(app);
    final work = io.Directory('$home${sep}work')..createSync(recursive: true);
    final stationJson = io.File('${work.path}${sep}station.json');
    stationJson.writeAsStringSync(jsonEncode(cfg?.section('station') ?? const {}));

    running.value = true;
    progress.value = 0;
    message.value = app.t('cznFillStarting');

    try {
      _proc = await io.Process.start(
        python.path,
        [
          script.path,
          '--db', '$home${sep}czn.db',
          '--station', stationJson.path,
          '--work', work.path,
        ],
        workingDirectory: '$home${sep}tools',
        runInShell: false,
        environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'},
      );
      ProcessJob.instance.add(_proc!.pid);

      for (final stream in [_proc!.stdout, _proc!.stderr]) {
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(_onLine);
      }

      final code = await _proc!.exitCode;
      // Остановка убивает процесс, и он выходит не нулём — это остановка, а не
      // сбой: строки пишутся по мере перевода, и всё сделанное уже в базе.
      message.value = code == 0 ? app.t('cznFillDone') : app.t('cznFillStopped');
    } catch (e) {
      unawaited(appendLog('errors', 'czn fill: $e'));
      message.value = app.t('cznFillFailed');
    } finally {
      running.value = false;
      _proc = null;
    }
  }

  void _onLine(String line) {
    unawaited(appendLog('czn', line));

    if (line.startsWith('COUNTS ')) {
      try {
        final raw = jsonDecode(line.substring(7));
        if (raw is Map) {
          counts.value = {
            for (final e in raw.entries)
              if (e.value is num) '${e.key}': (e.value as num).toInt(),
          };
        }
      } catch (_) {
        // Строка прогресса не стоит того, чтобы ронять из-за неё заливку.
      }
      return;
    }

    if (line.startsWith('TEXTS ')) {
      final parts = line.split(' ');
      if (parts.length >= 3) {
        final translated = int.tryParse(parts[2]);
        final total = int.tryParse(parts[1]);
        if (translated != null && total != null) texts.value = (translated, total);
      }
      return;
    }

    if (line.startsWith('PROGRESS ')) {
      final parts = line.split(' ');
      if (parts.length >= 3) {
        final done = int.tryParse(parts[1]) ?? 0;
        final total = int.tryParse(parts[2]) ?? 0;
        if (total > 0) progress.value = (done / total).clamp(0, 1);
      }
      return;
    }

    if (line.trim().isNotEmpty) message.value = line.trim();
  }

  void stop() {
    _proc?.kill();
    _proc = null;
    running.value = false;
  }
}

/// Сравнение игры с базой: что патч добавил, изменил и убрал.
///
/// Считает не EVS. Распаковка `data.pack` живёт в самом переводчике — это порт
/// рипера, снявшего два слоя XOR и формат контейнера, — и вызывается тем же
/// исполняемым файлом с ключом `--check-pack`. Своя реализация здесь означала бы
/// вторую распаковку, которая разойдётся с первой на первом же патче.
class CznPackCheck {
  CznPackCheck._();
  static final CznPackCheck instance = CznPackCheck._();

  /// Строка, которой переводчик отдаёт итог сравнения.
  static const marker = 'PACKDIFF ';

  final ValueNotifier<bool> running = ValueNotifier(false);
  final ValueNotifier<String> message = ValueNotifier('');

  /// Итог последней проверки. null — ещё не проверяли.
  final ValueNotifier<CznPackDiff?> diff = ValueNotifier(null);

  io.Process? _proc;

  Future<void> run(AppState app, {bool apply = false}) async {
    if (running.value) return;

    final exe = CznTranslator.instance.resolveExe(app);
    if (exe == null) {
      message.value = app.t('cznNoExe');
      return;
    }

    running.value = true;
    message.value = app.t(apply ? 'cznPackApplying' : 'cznPackChecking');

    try {
      _proc = await io.Process.start(
        exe,
        ['--check-pack', if (apply) '--apply'],
        runInShell: false,
      );
      ProcessJob.instance.add(_proc!.pid);

      for (final stream in [_proc!.stdout, _proc!.stderr]) {
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(_onLine);
      }

      final code = await _proc!.exitCode;
      if (code != 0 && diff.value == null) {
        message.value = app.t('cznPackFailed');
      } else if (apply) {
        message.value = app.t('cznPackApplied');
      }
    } catch (e) {
      unawaited(appendLog('errors', 'czn pack: $e'));
      message.value = app.t('cznPackFailed');
    } finally {
      running.value = false;
      _proc = null;
    }
  }

  void _onLine(String line) {
    unawaited(appendLog('czn', line));

    // Строка ищется, а не сверяется с началом: у журнала переводчика есть
    // приставка со временем, и итог может приехать за ней.
    final at = line.indexOf(marker);
    if (at >= 0) {
      final parsed = CznPackDiff.parse(line.substring(at + marker.length));
      if (parsed != null) diff.value = parsed;
      return;
    }

    // Человеческий ход показываем как есть, сняв приставку журнала.
    final text = line.replaceFirst(RegExp(r'^\[\d\d:\d\d:\d\d [A-Z]{3}\]\s*'), '');
    if (text.trim().isNotEmpty) message.value = text.trim();
  }

  void stop() {
    _proc?.kill();
    _proc = null;
    running.value = false;
  }
}

/// Итог сравнения пака с базой.
class CznPackDiff {
  const CznPackDiff(this.added, this.changed, this.removed, this.unchanged,
      this.applied);

  final int added, changed, removed, unchanged;
  final bool applied;

  /// Сколько строк ждут перевода после этого патча.
  int get pending => added + changed;

  static CznPackDiff? parse(String json) {
    try {
      final raw = jsonDecode(json);
      if (raw is! Map) return null;
      int at(String key) => (raw[key] as num?)?.toInt() ?? 0;
      return CznPackDiff(at('new'), at('changed'), at('removed'),
          at('unchanged'), raw['applied'] == true);
    } catch (_) {
      return null;
    }
  }
}

/// Настройки переводчика — его собственный `config.json`, правленый отсюда.
///
/// Своей копии настроек EVS не заводит намеренно. Переводчик читает этот файл
/// и перечитывает его на ходу, так что правка применяется сразу, без перезапуска
/// и без всякого протокола между программами. Вторая копия тех же полей
/// неизбежно разъехалась бы с первой — тот же довод, по которому адрес «Сети»
/// правит один диалог, а не два.
///
/// Незнакомые ключи сохраняются как есть: в файле лежат ещё зоны, пороги OCR и
/// адреса станции, которых этот экран не показывает, и потерять их при записи
/// было бы куда хуже, чем не уметь их править.
class CznConfig {
  CznConfig._(this._path, this._data);

  final String _path;
  final Map<String, dynamic> _data;

  static Future<CznConfig?> load(AppState app) async {
    final exe = CznTranslator.instance.resolveExe(app);
    if (exe == null) return null;

    final file = io.File(
      '${io.File(exe).parent.path}${io.Platform.pathSeparator}config.json',
    );
    if (!file.existsSync()) return null;

    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return CznConfig._(file.path, raw);
    } catch (e) {
      unawaited(appendLog('errors', 'czn config: $e'));
      return null;
    }
  }

  /// Секция по пути через точку: `ocr.det` — это `{"ocr": {"det": {…}}}`.
  ///
  /// Вложенность не выдумана здесь: у переводчика пороги детектора и размер
  /// пачки распознавания лежат внутри `ocr`, и плоский ключ пришлось бы
  /// раскладывать при каждой записи. Недостающие уровни создаются, потому что
  /// в файле их может не быть вовсе — умолчания живут в коде переводчика.
  Map<String, dynamic> _section(String path) {
    var node = _data;
    for (final name in path.split('.')) {
      final next = node[name];
      node = next is Map<String, dynamic>
          ? next
          : (node[name] = <String, dynamic>{});
    }
    return node;
  }

  T get<T>(String section, String key, T fallback) {
    final v = _section(section)[key];
    if (v is T) return v;
    if (fallback is double && v is num) return v.toDouble() as T;
    if (fallback is int && v is num) return v.toInt() as T;
    return fallback;
  }

  void set(String section, String key, Object? value) =>
      _section(section)[key] = value;

  /// Ключ в корне файла — там лежит «профиль», а не в секции.
  String root(String key, String fallback) {
    final v = _data[key];
    return v == null ? fallback : '$v';
  }

  void setRoot(String key, Object? value) => _data[key] = value;

  /// Целая секция как есть — заливке нужен весь блок «station» одним куском.
  Map<String, dynamic> section(String name) => _section(name);

  /// Текст настройки. Пустая строка вместо null — поля правятся вводом.
  String text(String section, String key, [String fallback = '']) {
    final v = _section(section)[key];
    return v == null ? fallback : '$v';
  }

  Future<void> save() async {
    // С отступами: файл читают и правят руками, и минифицированный JSON тут
    // был бы недружелюбен к тому, кто откроет его в редакторе.
    await io.File(_path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(_data),
      encoding: utf8,
    );
  }
}

/// Живое состояние переводчика, разобранное из `status.json`.
///
/// Обёртка над сырой картой, а не набор полей: файл пишет другая программа,
/// и её обновление не должно ронять экран. Всё читается с умолчанием, поэтому
/// статус, написанный версией постарше, показывается ровно в той части, что
/// в нём есть.
class CznStatus {
  const CznStatus(this._raw);

  final Map<String, dynamic> _raw;

  // Приведение через `is`, а не через `as`: файл пишет другая программа, и
  // строка на месте числа должна означать «нет числа», а не исключение посреди
  // отрисовки экрана.
  double _num(String key) {
    final v = _raw[key];
    return v is num ? v.toDouble() : 0;
  }

  int _int(String key) {
    final v = _raw[key];
    return v is num ? v.toInt() : 0;
  }

  bool get attached => _raw['attached'] == true;
  String get window => '${_raw['window'] ?? ''}';
  String get backend => '${_raw['backend'] ?? ''}';

  /// Покрытие по РАЗНЫМ текстам — то, на что оверлей действительно способен
  /// ответить. По записям база читается вдвое хуже, чем есть: одна фраза лежит
  /// в ней под каждым ключом игры, а перевод у неё общий.
  int get textTotal => _int('textTotal');
  int get textTranslated => _int('textTranslated');

  double get sessionCoverage => _num('sessionCoverage');

  /// Задержка отрисовки, медиана и 95-й процентиль. null — ещё ни одного кадра
  /// не нарисовано: процентиль пустого ряда это не ноль, а «не измеряли», и
  /// подставить сюда ноль значило бы показать мгновенный отклик там, где его
  /// просто не мерили.
  double? get medianMs => (_raw['changeToDrawMedianMs'] as num?)?.toDouble();
  double? get p95Ms => (_raw['changeToDrawP95Ms'] as num?)?.toDouble();

  /// Откуда пришли ответы этого сеанса: кэш, точное, нестрогое, похожее,
  /// станция, промах.
  Map<String, int> get session {
    final raw = _raw['session'];
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };
  }

  /// Активность по дням, от старого к новому.
  List<CznDay> get history {
    final raw = _raw['history'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          CznDay(
            '${item['day'] ?? ''}',
            (item['resolved'] as num?)?.toInt() ?? 0,
            (item['misses'] as num?)?.toInt() ?? 0,
          ),
    ];
  }
}

/// Один день работы переводчика: сколько экранов удалось перевести и сколько нет.
class CznDay {
  const CznDay(this.day, this.resolved, this.misses);
  final String day;
  final int resolved, misses;
}

/// Точка истории покрытия: день, сколько текстов переведено и сколько всего.
class CznPoint {
  const CznPoint(this.day, this.translated, this.total);

  final String day;
  final int translated, total;

  int get pending => total - translated;
  double get share => total > 0 ? translated / total : 0;

  /// Разбор строки из настроек. Возвращает null для мусора — список переживает
  /// смену формата, и одна нечитаемая точка не должна ронять график.
  static CznPoint? parse(String raw) {
    final parts = raw.split('|');
    if (parts.length < 3) return null;

    final translated = int.tryParse(parts[1]);
    final total = int.tryParse(parts[2]);
    return translated == null || total == null
        ? null
        : CznPoint(parts[0], translated, total);
  }

  static List<CznPoint> all(AppState app) =>
      [for (final raw in app.cznCoverage) ?parse(raw)];
}

/// Экран расширения. Один и тот же во всех оболочках.
class CznPanel extends StatefulWidget {
  const CznPanel({super.key, this.embedded = false});

  /// Открыт ВНУТРИ оболочки — своя полоса заголовка и заливка фона не нужны.
  final bool embedded;

  @override
  State<CznPanel> createState() => _CznPanelState();
}

/// Разделы экрана. Тот же порядок, что в настройках самого переводчика:
/// сначала состояние, потом вид поверх игры, потом всё, что решает, КАК он
/// читает экран и ищет по базе.
enum _CznTab { state, overlay, engine }

class _CznPanelState extends State<CznPanel> {
  final _czn = CznTranslator.instance;
  bool _gameUp = false;
  Timer? _poll;
  CznConfig? _cfg;
  CznStatus? _status;
  _CznTab _tab = _CznTab.state;

  @override
  void initState() {
    super.initState();
    _czn.state.addListener(_onUpdate);
    _czn.problem.addListener(_onUpdate);
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshGame();
      _refreshStatus();
    });
    _refreshGame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConfig();
      _refreshStatus();
    });
  }

  Future<void> _refreshStatus() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final raw = await _czn.readStatus(app);
    if (!mounted) return;

    final status = raw == null ? null : CznStatus(raw);
    setState(() => _status = status);

    // Точку истории ставит EVS: переводчик знает, сколько переведено сейчас,
    // но не помнит вчерашнего, а рост перевода виден только в сравнении.
    if (status != null && status.textTotal > 0) {
      app.recordCznCoverage(status.textTranslated, status.textTotal);
    }
  }

  Future<void> _loadConfig() async {
    if (!mounted) return;
    final cfg = await CznConfig.load(context.read<AppState>());
    if (mounted) setState(() => _cfg = cfg);
  }

  /// Правка настройки переводчика. Пишется сразу: он следит за файлом и
  /// подхватывает изменение на следующем кадре, поэтому кнопка «Применить»
  /// была бы лишним шагом между движением ползунка и видимым результатом.
  void _edit(String section, String key, Object? value) {
    final cfg = _cfg;
    if (cfg == null) return;
    setState(() => cfg.set(section, key, value));
    unawaited(cfg.save());
  }

  /// Ключ верхнего уровня: профиль лежит не в секции, а прямо в корне файла.
  void _editRoot(String key, Object? value) {
    final cfg = _cfg;
    if (cfg == null) return;
    setState(() => cfg.setRoot(key, value));
    unawaited(cfg.save());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _czn.state.removeListener(_onUpdate);
    _czn.problem.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshGame() async {
    final up = await CznTranslator.isGameRunning();
    if (mounted && up != _gameUp) setState(() => _gameUp = up);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final body = _body(context, app);

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: _bg(context),
      body: Column(
        children: [
          _WindowTitleBar(title: app.t('cznTitle')),
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

  Widget _body(BuildContext context, AppState app) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          evsSegmentedWide<_CznTab>(
            context,
            [
              (_CznTab.state, app.t('cznTabState')),
              (_CznTab.overlay, app.t('cznTabOverlay')),
              (_CznTab.engine, app.t('cznTabEngine')),
            ],
            _tab,
            (v) => setState(() => _tab = v),
          ),
          const SizedBox(height: 16),
          ...switch (_tab) {
            _CznTab.state => _statePage(context, app),
            _CznTab.overlay => _settingsPage(context, app, [
                _overlayCard,
                _windowCard,
                _responseCard,
              ]),
            _CznTab.engine => _settingsPage(context, app, [
                _ocrCard,
                _lookupCard,
                _stationCard,
                _liveCard,
                _logCard,
              ]),
          },
        ],
      ),
    );
  }

  List<Widget> _statePage(BuildContext context, AppState app) => [
        _stateCard(context, app),
        const SizedBox(height: 16),
        _gameCard(context, app),
        const SizedBox(height: 16),
        _baseCard(context, app),
        if (_status != null) ...[
          const SizedBox(height: 16),
          _sessionCard(context, app),
        ],
        const SizedBox(height: 16),
        _packCard(context, app),
        const SizedBox(height: 16),
        _fillCard(context, app),
        const SizedBox(height: 16),
        _pathCard(context, app),
      ];

  /// Страницы настроек собраны одинаково: карточки через отступ. Файла
  /// переводчика нет — вместо них одна строка о том, почему их нет, и та же
  /// кнопка выбора пути, что на обзоре.
  List<Widget> _settingsPage(
    BuildContext context,
    AppState app,
    List<Widget Function(BuildContext, AppState)> cards,
  ) {
    if (_cfg == null) {
      return [
        evsCard(
          context,
          icon: Icons.tune,
          title: app.t('cznSettingsTitle'),
          rows: [
            evsRow(
              context,
              stacked: true,
              label: app.t('cznNoConfig'),
              desc: app.t('cznNoConfigDesc'),
              control: evsGhostButton(
                context,
                app.t('cznPick'),
                Icons.folder_outlined,
                onTap: () => unawaited(showCznPathDialog(context, app)),
              ),
            ),
          ],
        ),
      ];
    }

    return [
      for (var i = 0; i < cards.length; i++) ...[
        if (i > 0) const SizedBox(height: 16),
        cards[i](context, app),
      ],
    ];
  }

  // ------------------------------------------------------------------ обзор

  /// Сколько текста переведено: числа, разбивка полосой и рост по дням.
  ///
  /// Показывается и с выключенным переводчиком: последняя точка истории — это
  /// последнее известное состояние базы, а идущая дозаливка сообщает свои
  /// числа сама, и тогда карточка двигается вместе с ней.
  Widget _baseCard(BuildContext context, AppState app) {
    return AnimatedBuilder(
      animation: CznFill.instance.texts,
      builder: (context, _) {
        final points = CznPoint.all(app);
        final now = _base(points);

        return evsCard(
          context,
          icon: Icons.donut_large_outlined,
          title: app.t('cznBaseTitle'),
          rows: [
            if (now == null)
              evsRow(
                context,
                label: app.t('cznBaseUnknown'),
                desc: app.t('cznBaseUnknownDesc'),
                control: const SizedBox.shrink(),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 26,
                      runSpacing: 14,
                      children: [
                        _tile(
                            context,
                            '${(now.share * 100).toStringAsFixed(1)}%',
                            app.t('cznBaseShare'),
                            _accent(context)),
                        _tile(context, evsThousands(now.translated),
                            app.t('cznBaseTranslated'), _success(context)),
                        _tile(context, evsThousands(now.pending),
                            app.t('cznBasePending'), _warn(context)),
                        _tile(context, evsThousands(now.total),
                            app.t('cznBaseTotal'), null),
                      ],
                    ),
                    const SizedBox(height: 18),
                    evsMeter(context, [
                      EvsMeterPart(app.t('cznBaseTranslatedShort'),
                          now.translated, _success(context)),
                      EvsMeterPart(
                          app.t('cznBasePendingShort'), now.pending, _warn(context)),
                    ]),
                  ],
                ),
              ),
              _chartRow(
                context,
                title: app.t('cznTrendTitle'),
                desc: points.length < 2
                    ? app.t('cznTrendWaiting')
                    : app.t('cznTrendDesc'),
                child: evsTrend(
                  context,
                  values: [for (final p in points) p.share * 100],
                  maxValue: 100,
                  caption: points.isEmpty
                      ? null
                      : '${points.first.day} — ${points.last.day}',
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Что показать как «сейчас»: свежие числа идущей заливки, иначе живой
  /// статус переводчика, иначе последнее, что EVS видел.
  CznPoint? _base(List<CznPoint> points) {
    final (translated, total) = CznFill.instance.texts.value;
    if (total > 0) return CznPoint('', translated, total);

    final status = _status;
    if (status != null && status.textTotal > 0) {
      return CznPoint('', status.textTranslated, status.textTotal);
    }

    return points.isEmpty ? null : points.last;
  }

  /// Живое состояние сеанса: покрытие, откуда пришли ответы, задержка.
  Widget _sessionCard(BuildContext context, AppState app) {
    final st = _status!;
    final session = st.session;
    final resolved = session.entries
        .where((e) => e.key != 'miss')
        .fold<int>(0, (sum, e) => sum + e.value);
    final asked = resolved + (session['miss'] ?? 0);
    final days = st.history;

    return evsCard(
      context,
      icon: Icons.insights_outlined,
      title: app.t('cznStatusTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznAttached'),
          desc: st.attached
              ? '${st.window} · ${st.backend}'
              : app.t('cznNotAttached'),
          active: st.attached,
          control: const SizedBox.shrink(),
        ),
        evsRow(
          context,
          label: app.t('cznSessionCoverage'),
          desc: app.t('cznSessionCoverageDesc'),
          control: Text(
            // Переводчик отдаёт 100 % на пустом сеансе — доля от нуля у него
            // единица по построению. Показывать «100 %», когда не спросили
            // ничего, значит хвалиться несделанным.
            asked == 0
                ? '—'
                : '${(st.sessionCoverage * 100).toStringAsFixed(0)}%  ·  '
                    '${evsThousands(resolved)} / ${evsThousands(asked)}',
            style: EvsType.caption.copyWith(color: _sub(context)),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznLatency'),
          desc: app.t('cznLatencyDesc'),
          control: Text(
            st.medianMs == null || st.p95Ms == null
                ? '—'
                : '${st.medianMs!.toStringAsFixed(0)} / '
                    '${st.p95Ms!.toStringAsFixed(0)} ${app.t('msShort')}',
            style: EvsType.caption.copyWith(color: _sub(context)),
          ),
        ),
        if (asked > 0)
          _chartRow(
            context,
            title: app.t('cznSourcesTitle'),
            desc: app.t('cznSourcesDesc'),
            child: evsMeter(context, [
              EvsMeterPart(app.t('cznSrcCache'), session['cache'] ?? 0,
                  _success(context)),
              EvsMeterPart(
                  app.t('cznSrcExact'), session['exact'] ?? 0, _accent(context)),
              EvsMeterPart(
                  app.t('cznSrcLoose'), session['loose'] ?? 0, _info(context)),
              EvsMeterPart(
                  app.t('cznSrcScene'), session['scene'] ?? 0, _accent2(context)),
              EvsMeterPart(
                  app.t('cznSrcFuzzy'), session['fuzzy'] ?? 0, _warn(context)),
              EvsMeterPart(app.t('cznSrcStation'), session['station'] ?? 0,
                  _sub(context)),
              EvsMeterPart(
                  app.t('cznSrcMiss'), session['miss'] ?? 0, _danger(context)),
            ]),
          ),
        if (days.length > 1)
          _chartRow(
            context,
            title: app.t('cznDailyTitle'),
            desc: app.t('cznDailyDesc'),
            child: evsTrend(
              context,
              values: [for (final d in days) d.resolved.toDouble()],
              bars: true,
              caption: '${days.first.day} — ${days.last.day}',
            ),
          ),
      ],
    );
  }

  /// Число крупно, подпись мелко. Из этого собран весь верх обзора.
  Widget _tile(BuildContext context, String value, String label, Color? color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: EvsType.title
                .copyWith(color: color ?? _txt(context), fontSize: 21)),
        const SizedBox(height: 3),
        Text(label, style: EvsType.caption.copyWith(color: _faint(context))),
      ],
    );
  }

  /// Строка карточки под график: заголовок, пояснение и сам рисунок.
  ///
  /// Не evsRow: там подпись и управление стоят рядом и делят ширину, а графику
  /// нужна вся — сжатый до половины карточки он перестаёт читаться.
  Widget _chartRow(
    BuildContext context, {
    required String title,
    required String desc,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: EvsType.label.copyWith(color: _txt(context))),
          const SizedBox(height: 3),
          Text(desc, style: EvsType.caption.copyWith(color: _faint(context))),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  /// Проверка игры: распаковать data.pack и сверить с базой.
  ///
  /// Стоит перед дозаливкой не случайно: сначала узнать, что патч принёс, потом
  /// добавить это в очередь, и только потом переводить. В обратном порядке
  /// дозаливка честно перевела бы то, что уже переведено, и не тронула новое.
  Widget _packCard(BuildContext context, AppState app) {
    final pack = CznPackCheck.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([pack.running, pack.message, pack.diff]),
      builder: (context, _) {
        final diff = pack.diff.value;
        final busy = pack.running.value;

        return evsCard(
          context,
          icon: Icons.travel_explore_outlined,
          title: app.t('cznPackTitle'),
          rows: [
            evsRow(
              context,
              label: app.t('cznPackCheck'),
              desc: pack.message.value.isNotEmpty
                  ? pack.message.value
                  : app.t('cznPackCheckDesc'),
              active: busy,
              control: evsGhostButton(
                context,
                busy ? app.t('cznStop') : app.t('cznPackRun'),
                busy ? Icons.stop_outlined : Icons.search,
                onTap: () =>
                    busy ? pack.stop() : unawaited(pack.run(app)),
              ),
            ),
            if (diff != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Wrap(
                  spacing: 26,
                  runSpacing: 14,
                  children: [
                    _tile(context, evsThousands(diff.added),
                        app.t('cznPackNew'), _success(context)),
                    _tile(context, evsThousands(diff.changed),
                        app.t('cznPackChanged'), _warn(context)),
                    _tile(context, evsThousands(diff.removed),
                        app.t('cznPackRemoved'), _sub(context)),
                    _tile(context, evsThousands(diff.unchanged),
                        app.t('cznPackSame'), null),
                  ],
                ),
              ),
              evsRow(
                context,
                label: diff.pending > 0
                    ? app.t('cznPackQueue')
                    : app.t('cznPackNothing'),
                desc: diff.applied
                    ? app.t('cznPackAppliedDesc')
                    : (diff.pending > 0
                        ? app.t('cznPackQueueDesc')
                        : app.t('cznPackNothingDesc')),
                active: diff.pending > 0 && !diff.applied,
                control: diff.pending > 0 && !diff.applied
                    ? evsGhostButton(
                        context,
                        app.t('cznPackApply'),
                        Icons.playlist_add,
                        onTap: busy
                            ? null
                            : () => unawaited(pack.run(app, apply: true)),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Дозаливка перевода: запуск, прогресс, остановка.
  Widget _fillCard(BuildContext context, AppState app) {
    final fill = CznFill.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([fill.running, fill.progress, fill.message]),
      builder: (context, _) => evsCard(
        context,
        icon: Icons.playlist_add_check_outlined,
        title: app.t('cznFillTitle'),
        rows: [
          evsRow(
            context,
            label: app.t('cznFillRun'),
            desc: fill.message.value.isNotEmpty
                ? fill.message.value
                : app.t('cznFillDesc'),
            active: fill.running.value,
            control: evsGhostButton(
              context,
              fill.running.value ? app.t('cznStop') : app.t('cznStart'),
              fill.running.value
                  ? Icons.stop_outlined
                  : Icons.play_arrow_outlined,
              onTap: () => fill.running.value
                  ? fill.stop()
                  : unawaited(fill.start(app)),
            ),
          ),
          if (fill.running.value)
            evsRow(
              context,
              label: app.t('cznFillProgress'),
              desc: '${(fill.progress.value * 100).toStringAsFixed(0)}%',
              control: SizedBox(
                width: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fill.progress.value,
                    minHeight: 6,
                    backgroundColor: _stroke(context),
                    color: _accent(context),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- настройки

  Widget _overlayCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final size = cfg.get('overlay', 'fontSize', 18.0);
    final scale = cfg.get('overlay', 'minFontScale', 0.8);
    final opacity = cfg.get('overlay', 'backdropOpacity', 0.78);
    final feather = cfg.get('overlay', 'backdropFeather', 0.22);
    final blur = cfg.get('overlay', 'backdropBlur', 8);

    return evsCard(
      context,
      icon: Icons.layers_outlined,
      title: app.t('cznOverlayTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznFontFamily'),
          desc: app.t('cznFontFamilyDesc'),
          control: _CznField(
            value: cfg.text('overlay', 'fontFamily', 'Segoe UI'),
            hint: 'Segoe UI',
            onDone: (v) => _edit('overlay', 'fontFamily', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznFontSize'),
          desc: app.t('cznFontSizeDesc'),
          control: evsSlider(
            context,
            value: size.clamp(10, 36),
            min: 10,
            max: 36,
            divisions: 26,
            label: size.round().toString(),
            onChanged: (v) => _edit('overlay', 'fontSize', v.roundToDouble()),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznMinScale'),
          desc: app.t('cznMinScaleDesc'),
          control: evsSlider(
            context,
            value: scale.clamp(0.5, 1.0),
            min: 0.5,
            max: 1.0,
            divisions: 10,
            label: '${(scale * 100).round()}%',
            onChanged: (v) =>
                _edit('overlay', 'minFontScale', (v * 100).round() / 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznTextColor'),
          desc: app.t('cznTextColorDesc'),
          control: _CznField(
            value: cfg.text('overlay', 'textColor', '#FFF2E8'),
            hint: '#FFF2E8',
            width: 128,
            swatch: true,
            onDone: (v) => _edit('overlay', 'textColor', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznBackdropColor'),
          desc: app.t('cznBackdropColorDesc'),
          control: _CznField(
            value: cfg.text('overlay', 'backdropColor', '#141014'),
            hint: '#141014',
            width: 128,
            swatch: true,
            onDone: (v) => _edit('overlay', 'backdropColor', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznBackdrop'),
          desc: app.t('cznBackdropDesc'),
          control: evsSlider(
            context,
            value: opacity.clamp(0, 1),
            min: 0,
            max: 1,
            divisions: 20,
            label: '${(opacity * 100).round()}%',
            onChanged: (v) =>
                _edit('overlay', 'backdropOpacity', (v * 100).round() / 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznBlur'),
          desc: app.t('cznBlurDesc'),
          control: evsSlider(
            context,
            value: blur.toDouble().clamp(4, 32),
            min: 4,
            max: 32,
            divisions: 14,
            label: '$blur',
            onChanged: (v) => _edit('overlay', 'backdropBlur', (v / 2).round() * 2),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznFeather'),
          desc: app.t('cznFeatherDesc'),
          control: evsSlider(
            context,
            value: feather.clamp(0, 1.2),
            min: 0,
            max: 1.2,
            divisions: 24,
            label: feather <= 0 ? app.t('cznFeatherOff') : feather.toStringAsFixed(2),
            onChanged: (v) =>
                _edit('overlay', 'backdropFeather', (v * 20).round() / 20),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznFollowFocus'),
          desc: app.t('cznFollowFocusDesc'),
          control: evsToggle(
            context,
            cfg.get('overlay', 'followFocus', true),
            (v) => _edit('overlay', 'followFocus', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznDebug'),
          desc: app.t('cznDebugDesc'),
          control: evsToggle(
            context,
            cfg.get('overlay', 'debug', false),
            (v) => _edit('overlay', 'debug', v),
          ),
        ),
      ],
    );
  }

  Widget _windowCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final scan = cfg.get('capture', 'windowSearchIntervalMs', 2000);

    return evsCard(
      context,
      icon: Icons.crop_free,
      title: app.t('cznWindowTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznProcess'),
          desc: app.t('cznProcessDesc'),
          control: _CznField(
            value: cfg.text('capture', 'processName', cznGameProcess),
            hint: cznGameProcess,
            onDone: (v) => _edit('capture', 'processName', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznWindowName'),
          desc: app.t('cznWindowNameDesc'),
          control: _CznField(
            value: cfg.text('capture', 'windowTitle'),
            hint: 'Chaos Zero Nightmare',
            onDone: (v) => _edit('capture', 'windowTitle', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznWindowClass'),
          desc: app.t('cznWindowClassDesc'),
          control: _CznField(
            value: cfg.text('capture', 'windowClass'),
            hint: 'GLFW30',
            width: 128,
            onDone: (v) => _edit('capture', 'windowClass', v),
          ),
        ),
        evsRow(
          context,
          stacked: true,
          label: app.t('cznPackPath'),
          desc: app.t('cznPackPathDesc'),
          control: _CznField(
            value: cfg.text('sync', 'packPath'),
            hint: 'data.pack',
            width: double.infinity,
            onDone: (v) => _edit('sync', 'packPath', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznScanInterval'),
          desc: app.t('cznScanIntervalDesc'),
          control: evsSlider(
            context,
            value: scan.toDouble().clamp(500, 10000),
            min: 500,
            max: 10000,
            divisions: 19,
            label: '${(scan / 1000).toStringAsFixed(1)} ${app.t('secShort')}',
            onChanged: (v) => _edit(
                'capture', 'windowSearchIntervalMs', (v / 500).round() * 500),
          ),
        ),
      ],
    );
  }

  Widget _responseCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final settle = cfg.get('detect', 'settleMs', 100);
    final poll = cfg.get('detect', 'pollEveryNthFrame', 1);
    final distance = cfg.get('detect', 'hashDistanceThreshold', 4);
    final hold = cfg.get('detect', 'holdMs', 1200);
    final restless = cfg.get('detect', 'restlessMs', 700);

    return evsCard(
      context,
      icon: Icons.speed_outlined,
      title: app.t('cznResponseTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznSettle'),
          desc: app.t('cznSettleDesc'),
          control: evsSlider(
            context,
            value: settle.toDouble().clamp(40, 300),
            min: 40,
            max: 300,
            divisions: 26,
            label: '$settle ${app.t('msShort')}',
            onChanged: (v) => _edit('detect', 'settleMs', v.round()),
          ),
        ),
        evsRow(
          context,
          stacked: true,
          label: app.t('cznPoll'),
          desc: app.t('cznPollDesc'),
          control: evsSegmentedWide<int>(
            context,
            [
              (1, app.t('cznPollEvery')),
              (2, app.t('cznPollHalf')),
              (4, app.t('cznPollQuarter')),
            ],
            poll.clamp(1, 4),
            (v) => _edit('detect', 'pollEveryNthFrame', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznRestless'),
          desc: app.t('cznRestlessDesc'),
          control: evsSlider(
            context,
            value: restless.toDouble().clamp(200, 3000),
            min: 200,
            max: 3000,
            divisions: 28,
            label: '${(restless / 1000).toStringAsFixed(1)} ${app.t('secShort')}',
            onChanged: (v) => _edit('detect', 'restlessMs', (v / 100).round() * 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznHold'),
          desc: app.t('cznHoldDesc'),
          control: evsSlider(
            context,
            value: hold.toDouble().clamp(0, 5000),
            min: 0,
            max: 5000,
            divisions: 25,
            label: hold <= 0
                ? app.t('cznHoldOff')
                : '${(hold / 1000).toStringAsFixed(1)} ${app.t('secShort')}',
            onChanged: (v) => _edit('detect', 'holdMs', (v / 200).round() * 200),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznHashDistance'),
          desc: app.t('cznHashDistanceDesc'),
          control: evsSlider(
            context,
            value: distance.toDouble().clamp(1, 16),
            min: 1,
            max: 16,
            divisions: 15,
            label: '$distance',
            onChanged: (v) =>
                _edit('detect', 'hashDistanceThreshold', v.round()),
          ),
        ),
      ],
    );
  }

  Widget _ocrCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final side = cfg.get('ocr.det', 'limitSideLen', 960);
    final threshold = cfg.get('ocr.det', 'threshold', 0.3);
    final unclip = cfg.get('ocr.det', 'unclipRatio', 1.6);
    final minArea = cfg.get('ocr.det', 'minArea', 24);
    final batch = cfg.get('ocr.rec', 'batchSize', 8);
    final adapter = cfg.get('ocr', 'adapterIndex', -1);

    return evsCard(
      context,
      icon: Icons.text_fields_outlined,
      title: app.t('cznOcrTitle'),
      rows: [
        evsRow(
          context,
          stacked: true,
          label: app.t('cznProvider'),
          desc: app.t('cznProviderDesc'),
          control: evsSegmentedWide<String>(
            context,
            [
              ('Auto', app.t('cznProviderAuto')),
              ('DirectMl', app.t('cznProviderGpu')),
              ('Cpu', app.t('cznProviderCpu')),
            ],
            cfg.text('ocr', 'provider', 'Auto'),
            (v) => _edit('ocr', 'provider', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznAdapter'),
          desc: app.t('cznAdapterDesc'),
          control: evsSlider(
            context,
            value: adapter.toDouble().clamp(-1, 3),
            min: -1,
            max: 3,
            divisions: 4,
            label: adapter < 0 ? app.t('cznAdapterAuto') : '#$adapter',
            onChanged: (v) => _edit('ocr', 'adapterIndex', v.round()),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznQuantized'),
          desc: app.t('cznQuantizedDesc'),
          control: evsToggle(
            context,
            cfg.get('ocr', 'quantized', false),
            (v) => _edit('ocr', 'quantized', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznDetSide'),
          desc: app.t('cznDetSideDesc'),
          control: evsSlider(
            context,
            value: side.toDouble().clamp(320, 1600),
            min: 320,
            max: 1600,
            divisions: 20,
            label: '$side',
            onChanged: (v) =>
                _edit('ocr.det', 'limitSideLen', (v / 64).round() * 64),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznDetThreshold'),
          desc: app.t('cznDetThresholdDesc'),
          control: evsSlider(
            context,
            value: threshold.clamp(0.1, 0.7),
            min: 0.1,
            max: 0.7,
            divisions: 12,
            label: threshold.toStringAsFixed(2),
            onChanged: (v) =>
                _edit('ocr.det', 'threshold', (v * 100).round() / 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznUnclip'),
          desc: app.t('cznUnclipDesc'),
          control: evsSlider(
            context,
            value: unclip.clamp(1.0, 3.0),
            min: 1.0,
            max: 3.0,
            divisions: 20,
            label: unclip.toStringAsFixed(1),
            onChanged: (v) =>
                _edit('ocr.det', 'unclipRatio', (v * 10).round() / 10),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznMinArea'),
          desc: app.t('cznMinAreaDesc'),
          control: evsSlider(
            context,
            value: minArea.toDouble().clamp(4, 100),
            min: 4,
            max: 100,
            divisions: 24,
            label: '$minArea',
            onChanged: (v) => _edit('ocr.det', 'minArea', (v / 4).round() * 4),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznRecBatch'),
          desc: app.t('cznRecBatchDesc'),
          control: evsSlider(
            context,
            value: batch.toDouble().clamp(1, 16),
            min: 1,
            max: 16,
            divisions: 15,
            label: '$batch',
            onChanged: (v) => _edit('ocr.rec', 'batchSize', v.round()),
          ),
        ),
      ],
    );
  }

  Widget _lookupCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final fuzzy = cfg.get('lookup', 'fuzzyThreshold', 0.85);
    final low = cfg.get('lookup', 'fuzzyThresholdLowConfidence', 0.80);
    final minLength = cfg.get('lookup', 'fuzzyMinLength', 24);
    final cutoff = cfg.get('lookup', 'lowConfidenceCutoff', 0.7);
    final candidates = cfg.get('lookup', 'ftsCandidateLimit', 50);
    final cache = cfg.get('lookup', 'zoneCacheCapacity', 20000);

    return evsCard(
      context,
      icon: Icons.manage_search_outlined,
      title: app.t('cznLookupTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznFuzzy'),
          desc: app.t('cznFuzzyDesc'),
          control: evsSlider(
            context,
            value: fuzzy.clamp(0.6, 1.0),
            min: 0.6,
            max: 1.0,
            divisions: 40,
            label: fuzzy.toStringAsFixed(2),
            onChanged: (v) =>
                _edit('lookup', 'fuzzyThreshold', (v * 100).round() / 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznFuzzyLow'),
          desc: app.t('cznFuzzyLowDesc'),
          control: evsSlider(
            context,
            value: low.clamp(0.6, 1.0),
            min: 0.6,
            max: 1.0,
            divisions: 40,
            label: low.toStringAsFixed(2),
            onChanged: (v) => _edit('lookup', 'fuzzyThresholdLowConfidence',
                (v * 100).round() / 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznFuzzyMin'),
          desc: app.t('cznFuzzyMinDesc'),
          control: evsSlider(
            context,
            value: minLength.toDouble().clamp(0, 60),
            min: 0,
            max: 60,
            divisions: 20,
            label: '$minLength',
            onChanged: (v) =>
                _edit('lookup', 'fuzzyMinLength', (v / 3).round() * 3),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznLowConf'),
          desc: app.t('cznLowConfDesc'),
          control: evsSlider(
            context,
            value: cutoff.clamp(0.3, 1.0),
            min: 0.3,
            max: 1.0,
            divisions: 14,
            label: cutoff.toStringAsFixed(2),
            onChanged: (v) =>
                _edit('lookup', 'lowConfidenceCutoff', (v * 100).round() / 100),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznCandidates'),
          desc: app.t('cznCandidatesDesc'),
          control: evsSlider(
            context,
            value: candidates.toDouble().clamp(10, 200),
            min: 10,
            max: 200,
            divisions: 19,
            label: '$candidates',
            onChanged: (v) =>
                _edit('lookup', 'ftsCandidateLimit', (v / 10).round() * 10),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznZoneCache'),
          desc: app.t('cznZoneCacheDesc'),
          control: evsSlider(
            context,
            value: cache.toDouble().clamp(1000, 60000),
            min: 1000,
            max: 60000,
            divisions: 59,
            label: evsThousands(cache),
            onChanged: (v) =>
                _edit('lookup', 'zoneCacheCapacity', (v / 1000).round() * 1000),
          ),
        ),
      ],
    );
  }

  Widget _stationCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final batch = cfg.get('station', 'batch', 25);
    final timeout = cfg.get('station', 'timeoutSeconds', 300);
    final retries = cfg.get('station', 'retries', 2);
    final threads = cfg.get('station', 'numThread', 0);
    final chunk = cfg.get('station', 'chunk', 100);

    return evsCard(
      context,
      icon: Icons.dns_outlined,
      title: app.t('cznStationTitle'),
      rows: [
        evsRow(
          context,
          stacked: true,
          label: app.t('cznStationEndpoint'),
          desc: app.t('cznStationEndpointDesc'),
          control: _CznField(
            value: cfg.text('station', 'endpoint', 'http://127.0.0.1:11434'),
            hint: 'http://100.79.130.7:11434',
            width: double.infinity,
            onDone: (v) => _edit('station', 'endpoint', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznStationModel'),
          desc: app.t('cznStationModelDesc'),
          control: _CznField(
            value: cfg.text('station', 'model', 'qwen3:4b'),
            hint: 'gemma3:12b',
            onDone: (v) => _edit('station', 'model', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznStationBatch'),
          desc: app.t('cznStationBatchDesc'),
          control: evsSlider(
            context,
            value: batch.toDouble().clamp(3, 99),
            min: 3,
            max: 99,
            divisions: 32,
            label: '$batch',
            onChanged: (v) => _edit('station', 'batch', (v / 3).round() * 3),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznStationTimeout'),
          desc: app.t('cznStationTimeoutDesc'),
          control: evsSlider(
            context,
            value: timeout.toDouble().clamp(30, 900),
            min: 30,
            max: 900,
            divisions: 29,
            label: '$timeout ${app.t('secShort')}',
            onChanged: (v) =>
                _edit('station', 'timeoutSeconds', (v / 30).round() * 30),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznStationRetries'),
          desc: app.t('cznStationRetriesDesc'),
          control: evsSlider(
            context,
            value: retries.toDouble().clamp(0, 5),
            min: 0,
            max: 5,
            divisions: 5,
            label: '$retries',
            onChanged: (v) => _edit('station', 'retries', v.round()),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznStationThreads'),
          desc: app.t('cznStationThreadsDesc'),
          control: evsSlider(
            context,
            value: threads.toDouble().clamp(0, 32),
            min: 0,
            max: 32,
            divisions: 16,
            label: threads == 0 ? app.t('cznAdapterAuto') : '$threads',
            onChanged: (v) => _edit('station', 'numThread', (v / 2).round() * 2),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznStationChunk'),
          desc: app.t('cznStationChunkDesc'),
          control: evsSlider(
            context,
            value: chunk.toDouble().clamp(20, 500),
            min: 20,
            max: 500,
            divisions: 24,
            label: '$chunk',
            onChanged: (v) => _edit('station', 'chunk', (v / 20).round() * 20),
          ),
        ),
      ],
    );
  }

  Widget _liveCard(BuildContext context, AppState app) {
    final cfg = _cfg!;
    final on = cfg.get('sync', 'fallbackEnabled', true);
    final timeout = cfg.get('sync', 'timeoutSeconds', 3);
    final parallel = cfg.get('sync', 'maxParallelRequests', 2);

    return evsCard(
      context,
      icon: Icons.bolt_outlined,
      title: app.t('cznLiveTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznFallback'),
          desc: app.t('cznFallbackDesc'),
          active: on,
          control: evsToggle(
            context,
            on,
            (v) => _edit('sync', 'fallbackEnabled', v),
          ),
        ),
        evsRow(
          context,
          stacked: true,
          label: app.t('cznLiveEndpoint'),
          desc: app.t('cznLiveEndpointDesc'),
          control: _CznField(
            value: cfg.text('sync', 'ollamaEndpoint', 'http://127.0.0.1:11434'),
            hint: 'http://100.79.130.7:11434',
            width: double.infinity,
            onDone: (v) => _edit('sync', 'ollamaEndpoint', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznLiveModel'),
          desc: app.t('cznLiveModelDesc'),
          control: _CznField(
            value: cfg.text('sync', 'model', 'qwen3-loc'),
            hint: 'gemma3:12b',
            onDone: (v) => _edit('sync', 'model', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznLiveTimeout'),
          desc: app.t('cznLiveTimeoutDesc'),
          control: evsSlider(
            context,
            value: timeout.toDouble().clamp(1, 30),
            min: 1,
            max: 30,
            divisions: 29,
            label: '$timeout ${app.t('secShort')}',
            onChanged: (v) => _edit('sync', 'timeoutSeconds', v.round()),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznLiveParallel'),
          desc: app.t('cznLiveParallelDesc'),
          control: evsSlider(
            context,
            value: parallel.toDouble().clamp(1, 8),
            min: 1,
            max: 8,
            divisions: 7,
            label: '$parallel',
            onChanged: (v) => _edit('sync', 'maxParallelRequests', v.round()),
          ),
        ),
      ],
    );
  }

  Widget _logCard(BuildContext context, AppState app) {
    final cfg = _cfg!;

    return evsCard(
      context,
      icon: Icons.article_outlined,
      title: app.t('cznLogTitle'),
      rows: [
        evsRow(
          context,
          stacked: true,
          label: app.t('cznLogLevel'),
          desc: app.t('cznLogLevelDesc'),
          control: evsSegmentedWide<String>(
            context,
            [
              ('Debug', app.t('cznLogDebug')),
              ('Information', app.t('cznLogInfo')),
              ('Warning', app.t('cznLogWarn')),
            ],
            cfg.text('logging', 'level', 'Information'),
            (v) => _edit('logging', 'level', v),
          ),
        ),
        evsRow(
          context,
          label: app.t('cznLogDir'),
          desc: app.t('cznLogDirDesc'),
          control: _CznField(
            value: cfg.text('logging', 'directory', 'logs'),
            hint: 'logs',
            onDone: (v) => _edit('logging', 'directory', v),
          ),
        ),
        evsRow(
          context,
          stacked: true,
          label: app.t('cznProfile'),
          desc: app.t('cznProfileDesc'),
          control: evsSegmentedWide<String>(
            context,
            [
              ('default', app.t('cznProfileFull')),
              ('laptop', app.t('cznProfileLaptop')),
            ],
            cfg.root('profile', 'default'),
            (v) => _editRoot('profile', v),
          ),
        ),
      ],
    );
  }

  Widget _stateCard(BuildContext context, AppState app) {
    final s = _czn.state.value;
    final label = switch (s) {
      CznState.running => app.t('cznRunning'),
      CznState.starting => app.t('cznStarting'),
      CznState.failed => app.t('cznFailedState'),
      CznState.stopped => app.t('cznStopped'),
    };
    final busy = s == CznState.starting;

    return evsCard(
      context,
      icon: Icons.translate_outlined,
      title: app.t('cznTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznStateLabel'),
          desc: _czn.problem.value.isNotEmpty ? _czn.problem.value : label,
          active: s == CznState.running,
          control: evsGhostButton(
            context,
            _czn.isRunning ? app.t('cznStop') : app.t('cznStart'),
            _czn.isRunning ? Icons.stop_outlined : Icons.play_arrow_outlined,
            onTap: busy
                ? null
                : () =>
                    unawaited(_czn.isRunning ? _czn.stop() : _czn.start(app)),
          ),
        ),
      ],
    );
  }

  Widget _gameCard(BuildContext context, AppState app) {
    return evsCard(
      context,
      icon: Icons.sports_esports_outlined,
      title: app.t('cznGameTitle'),
      rows: [
        evsRow(
          context,
          label: app.t('cznGameState'),
          desc: _gameUp ? app.t('cznGameUp') : app.t('cznGameDown'),
          active: _gameUp,
          control: const SizedBox.shrink(),
        ),
        evsRow(
          context,
          label: app.t('cznAutoStart'),
          desc: app.t('cznAutoStartDesc'),
          control: evsToggle(context, app.cznAutoStart, (v) {
            app.setCznAutoStart(v);
            _czn.watchForGame(app);
          }),
        ),
      ],
    );
  }

  Widget _pathCard(BuildContext context, AppState app) {
    final resolved = _czn.resolveExe(app);
    return evsCard(
      context,
      icon: Icons.folder_outlined,
      title: app.t('cznPathTitle'),
      rows: [
        evsRow(
          context,
          stacked: true,
          label: app.t('cznExeLabel'),
          desc: resolved ?? app.t('cznNoExe'),
          control: evsGhostButton(
            context,
            app.t('cznPick'),
            Icons.tune,
            onTap: () => unawaited(showCznPathDialog(context, app)),
          ),
        ),
      ],
    );
  }
}

/// Поле ввода одной настройки переводчика.
///
/// Пишет не на каждую букву, а по Enter и по уходу фокуса: переводчик следит
/// за файлом и перечитывает его на каждое изменение, и посимвольная запись
/// заставляла бы его перезагружать настройки двадцать раз, пока набирают
/// адрес, — с половиной адреса в промежуточных состояниях.
class _CznField extends StatefulWidget {
  const _CznField({
    required this.value,
    required this.onDone,
    this.hint,
    this.width = 176,
    this.swatch = false,
  });

  final String value;
  final ValueChanged<String> onDone;
  final String? hint;
  final double width;

  /// Показать квадратик с цветом слева — поле хранит `#RRGGBB`.
  final bool swatch;

  @override
  State<_CznField> createState() => _CznFieldState();
}

class _CznFieldState extends State<_CznField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_CznField old) {
    super.didUpdateWidget(old);
    // Значение перечитали из файла, пока поле не трогают, — подхватываем. Пока
    // в нём набирают, ввод главнее: иначе трёхсекундный опрос затирал бы
    // набранное на полуслове.
    if (widget.value != old.value && !_focus.hasFocus) {
      _ctrl.text = widget.value;
    }
  }

  void _commit() {
    final text = _ctrl.text.trim();
    if (text != widget.value) widget.onDone(text);
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _ctrl,
      focusNode: _focus,
      textAlign: widget.width == double.infinity
          ? TextAlign.left
          : TextAlign.right,
      style: EvsType.body.copyWith(fontSize: 13, color: _txt(context)),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: EvsType.body.copyWith(fontSize: 13, color: _faint(context)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        filled: true,
        fillColor: _overlayFill(context, 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _stroke(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _stroke(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _accent(context)),
        ),
      ),
      onSubmitted: (_) => _commit(),
    );

    final sized = widget.width == double.infinity
        ? field
        : SizedBox(width: widget.width, child: field);

    if (!widget.swatch) return sized;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: cznParseColor(widget.value) ?? Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: _stroke(context)),
          ),
        ),
        const SizedBox(width: 8),
        sized,
      ],
    );
  }
}

/// `#RRGGBB` или `#AARRGGBB` в цвет. null — если строка не про цвет: поле
/// правят руками, и половина набранного значения не должна ничего красить.
Color? cznParseColor(String raw) {
  var hex = raw.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;

  final value = int.tryParse(hex, radix: 16);
  return value == null ? null : Color(value);
}

/// Диалог пути к переводчику. Живёт здесь, а не в настройках: два экземпляра
/// одного поля неизбежно разъезжаются — тот же довод, что у «Сети».
Future<void> showCznPathDialog(BuildContext context, AppState app) async {
  final ctrl = TextEditingController(text: app.cznExePath);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(app.t('cznPathTitle')),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(
          hintText: r'C:\Files\CZN Translator\CznTranslator.exe',
          labelText: app.t('cznExeLabel'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(app.t('cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(app.t('save')),
        ),
      ],
    ),
  );

  if (ok == true) app.setCznExePath(ctrl.text);
  ctrl.dispose();
}
