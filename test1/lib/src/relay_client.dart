part of '../main.dart';

/* ==========================================================================
   СЕТЬ — клиент агента канала (nexus-relay)
   --------------------------------------------------------------------------
   Агент живёт на станции и меряет канал до арендованного VPS: три контрольных
   потока, счётчики WireGuard, состояние маршрута. Здесь — только чтение его
   ответов и опрос по таймеру. Ни одного вычисления над цифрами: что померено,
   то и показываем.

   Почему классы называются Relay, а не Nexus. В EVS «Nexus» — это ИМЯ СТИЛЯ
   оболочки (AppStyle.nexus, NexusPipeline, NexusHubOrb). Назвать так ещё и
   сетевую часть значило бы завести в одном проекте два разных «нексуса»,
   и через месяц никто не вспомнит, какой из них какой.

   Почему опрос, а не поток событий. Агент отдаёт обычный HTTP, как сервер
   картинок, за прогрессом которого EVS уже ходит опросом. Двух гигабайт
   разницы тут нет: кадр статуса — пара килобайт дважды в секунду, и только
   пока экран открыт. Закрыли экран — станцию никто не дёргает.

   Каждое поле здесь может быть null, и это не небрежность. Агент отдаёт null
   там, где мерить нечем: нет туннеля — нет его задержки; нет wg на станции —
   нет скорости. Пустое место в панели честнее нуля, который выглядит как
   измеренный.
   ========================================================================== */

/// Один контрольный поток: канал напрямую, канал с дублированием, туннель.
class RelayStream {
  const RelayStream({
    required this.key,
    required this.name,
    required this.state,
    required this.copies,
    this.lossPct,
    this.lossUpPct,
    this.lossDownPct,
    this.rttMs,
    this.rttMinMs,
    this.rttP95Ms,
    this.jitterMs,
    this.delivered = 0,
    this.lost = 0,
    this.recovered = 0,
    this.totalRecovered = 0,
  });

  /// `direct` | `dup` | `tunnel` — по нему панель раскладывает потоки по местам.
  final String key;
  final String name;

  /// `up` | `degraded` | `down` | `unknown`.
  final String state;
  final int copies;

  final double? lossPct, lossUpPct, lossDownPct;
  final double? rttMs, rttMinMs, rttP95Ms, jitterMs;
  final int delivered, lost, recovered, totalRecovered;

  static double? _d(dynamic v) => v is num ? v.toDouble() : null;
  static int _i(dynamic v) => v is num ? v.toInt() : 0;

  factory RelayStream.fromJson(Map<String, dynamic> j) => RelayStream(
        key: (j['key'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        state: (j['state'] ?? 'unknown').toString(),
        copies: _i(j['copies']),
        lossPct: _d(j['loss_pct']),
        lossUpPct: _d(j['loss_up_pct']),
        lossDownPct: _d(j['loss_down_pct']),
        rttMs: _d(j['rtt_ms']),
        rttMinMs: _d(j['rtt_min_ms']),
        rttP95Ms: _d(j['rtt_p95_ms']),
        jitterMs: _d(j['jitter_ms']),
        delivered: _i(j['delivered']),
        lost: _i(j['lost']),
        recovered: _i(j['recovered']),
        totalRecovered: _i(j['total_recovered']),
      );
}

/// Точка истории — одна секунда. Агент копит их у себя, поэтому график
/// показывает две полноценные минуты сразу при открытии экрана, а не начинает
/// накапливаться с нуля.
class RelayPoint {
  const RelayPoint({
    required this.ts,
    this.lossDirect,
    this.lossTunnel,
    this.rttDirect,
    this.rttTunnel,
    this.recovered = 0,
    this.rxBps = 0,
    this.txBps = 0,
  });

  final int ts;
  final double? lossDirect, lossTunnel, rttDirect, rttTunnel;
  final int recovered, rxBps, txBps;

  factory RelayPoint.fromJson(Map<String, dynamic> j) => RelayPoint(
        ts: RelayStream._i(j['ts']),
        lossDirect: RelayStream._d(j['loss_direct']),
        lossTunnel: RelayStream._d(j['loss_tunnel']),
        rttDirect: RelayStream._d(j['rtt_direct']),
        rttTunnel: RelayStream._d(j['rtt_tunnel']),
        recovered: RelayStream._i(j['recovered']),
        rxBps: RelayStream._i(j['rx_bps']),
        txBps: RelayStream._i(j['tx_bps']),
      );
}

/// Снимок состояния целиком — то, что рисует экран.
class RelayStatus {
  const RelayStatus({
    required this.mode,
    required this.streams,
    required this.tunnelUp,
    required this.uptimeS,
    this.handshakeAgeS,
    this.tunnelError,
    this.rxBps = 0,
    this.txBps = 0,
    this.lossChannelPct,
    this.lossEffectivePct,
    this.recoveredWindow = 0,
    this.recoveredTotal = 0,
    this.rttDirectMs,
    this.rttTunnelMs,
    this.rttBaseMs,
    this.jitterMs,
    this.windowS = 30,
    this.gamePps,
    this.riotPrefixes = 0,
    this.events = const [],
  });

  /// `direct` — трафик идёт мимо туннеля, `tunnel` — через него,
  /// `unknown` — станция не смогла прочитать таблицу маршрутизации.
  final String mode;
  final List<RelayStream> streams;
  final bool tunnelUp;
  final int uptimeS;
  final int? handshakeAgeS;
  final String? tunnelError;
  final int rxBps, txBps;

  /// Пять главных цифр экрана. Каждая приходит из своего счётчика агента.
  final double? lossChannelPct, lossEffectivePct;
  final int recoveredWindow, recoveredTotal;
  final double? rttDirectMs, rttTunnelMs, rttBaseMs, jitterMs;
  final int windowS;

  /// Пакетов в секунду к сети Riot. null — на станции нет считающего правила,
  /// и «игра не идёт» здесь было бы выдумкой, а не наблюдением.
  final double? gamePps;
  final int riotPrefixes;
  final List<({String ts, String text})> events;

  bool get tunnelActive => mode == 'tunnel';

  /// Идёт ли сейчас игра. Порог из ТЗ §15.4: поток к сети Riot выше 20 пак/с.
  bool? get gameActive => gamePps == null ? null : gamePps! > 20;

  RelayStream? stream(String key) {
    for (final s in streams) {
      if (s.key == key) return s;
    }
    return null;
  }

  factory RelayStatus.fromJson(Map<String, dynamic> j) {
    final sum = j['summary'] is Map
        ? Map<String, dynamic>.from(j['summary'] as Map)
        : const <String, dynamic>{};
    final tun = j['tunnel'] is Map
        ? Map<String, dynamic>.from(j['tunnel'] as Map)
        : const <String, dynamic>{};
    final gw = j['gateway'] is Map
        ? Map<String, dynamic>.from(j['gateway'] as Map)
        : const <String, dynamic>{};
    final events = <({String ts, String text})>[];
    for (final e in (j['events'] as List? ?? const [])) {
      if (e is Map) {
        events.add((
          ts: (e['ts'] ?? '').toString(),
          text: (e['text'] ?? '').toString(),
        ));
      }
    }
    return RelayStatus(
      mode: (j['mode'] ?? 'unknown').toString(),
      streams: [
        for (final s in (j['streams'] as List? ?? const []))
          if (s is Map) RelayStream.fromJson(Map<String, dynamic>.from(s)),
      ],
      tunnelUp: tun['up'] == true,
      uptimeS: RelayStream._i(j['uptime_s']),
      handshakeAgeS:
          tun['handshake_age_s'] is num ? (tun['handshake_age_s'] as num).toInt() : null,
      tunnelError: (tun['error'] as String?)?.trim().isEmpty ?? true
          ? null
          : tun['error'] as String,
      rxBps: RelayStream._i(tun['rx_bps']),
      txBps: RelayStream._i(tun['tx_bps']),
      lossChannelPct: RelayStream._d(sum['loss_channel_pct']),
      lossEffectivePct: RelayStream._d(sum['loss_effective_pct']),
      recoveredWindow: RelayStream._i(sum['recovered_window']),
      recoveredTotal: RelayStream._i(sum['recovered_total']),
      rttDirectMs: RelayStream._d(sum['rtt_direct_ms']),
      rttTunnelMs: RelayStream._d(sum['rtt_tunnel_ms']),
      rttBaseMs: RelayStream._d(sum['rtt_base_ms']),
      jitterMs: RelayStream._d(sum['jitter_ms']),
      windowS: RelayStream._i(sum['window_s']) == 0
          ? 30
          : RelayStream._i(sum['window_s']),
      gamePps: RelayStream._d(gw['game_pps']),
      riotPrefixes: RelayStream._i(gw['riot_prefixes']),
      events: events,
    );
  }
}

/// Запросы к агенту. Без своего состояния — состояние держит [RelayMonitor].
class RelayClient {
  RelayClient(String base, this.token) : base = _normalize(base);

  final String base;
  final String token;

  bool get ready => base.isNotEmpty;

  static String _normalize(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return '';
    final withScheme = u.startsWith('http') ? u : 'http://$u';
    return withScheme.endsWith('/')
        ? withScheme.substring(0, withScheme.length - 1)
        : withScheme;
  }

  Map<String, String> get _headers => {
        if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
      };

  Future<Map<String, dynamic>> _get(String path,
      [Duration t = const Duration(seconds: 4)]) async {
    final r = await http.get(Uri.parse('$base$path'), headers: _headers).timeout(t);
    if (r.statusCode == 401) {
      throw const RelayError('нужен токен, или он не тот');
    }
    if (r.statusCode != 200) {
      throw RelayError('агент ответил ${r.statusCode}');
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map<String, dynamic>) throw const RelayError('ответ не разобрать');
    return j;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      [Duration t = const Duration(seconds: 30)]) async {
    final r = await http
        .post(Uri.parse('$base$path'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(t);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final map = j is Map<String, dynamic> ? j : <String, dynamic>{};
    if (r.statusCode != 200) {
      throw RelayError((map['error'] ?? map['message'] ?? 'агент ответил ${r.statusCode}')
          .toString());
    }
    return map;
  }

  Future<RelayStatus> status() async => RelayStatus.fromJson(await _get('/status'));

  Future<List<RelayPoint>> history() async {
    final j = await _get('/history', const Duration(seconds: 6));
    return [
      for (final p in (j['points'] as List? ?? const []))
        if (p is Map) RelayPoint.fromJson(Map<String, dynamic>.from(p)),
    ];
  }

  /// Перевести трафик Riot в туннель или обратно. Возвращает режим, который
  /// станция подтвердила ПОСЛЕ правки маршрутов, а не тот, что мы просили:
  /// показывать желаемое вместо действительного здесь недопустимо.
  Future<String> setMode(String mode) async {
    final j = await _post('/mode', {'mode': mode});
    return (j['mode'] ?? mode).toString();
  }

  /// Правка настроек. Возвращает список тех, что потребуют перезапуска
  /// службы — панель об этом честно предупредит, а не сделает вид, что
  /// изменение уже в силе.
  Future<List<String>> putConfig(Map<String, dynamic> patch) async {
    final j = await _post('/config', patch, const Duration(seconds: 10));
    return [
      for (final k in (j['needs_restart'] as List? ?? const [])) k.toString(),
    ];
  }

  Future<Map<String, dynamic>> config() async {
    final j = await _get('/config');
    return j['config'] is Map
        ? Map<String, dynamic>.from(j['config'] as Map)
        : <String, dynamic>{};
  }
}

class RelayError implements Exception {
  const RelayError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Опрос агента, пока открыт экран. Один на приложение, чтобы два открытых
/// окна не удваивали запросы к станции.
class RelayMonitor extends ChangeNotifier {
  RelayMonitor._();
  static final RelayMonitor instance = RelayMonitor._();

  RelayStatus? status;
  List<RelayPoint> history = const [];

  /// Текст ошибки для человека, либо null. Не bool: состояний три — не
  /// настроено, не отвечает, отвечает, — и второе от первого надо отличать.
  String? error;
  bool get configured => _client?.ready ?? false;
  bool loading = false;

  RelayClient? _client;
  Timer? _poll;
  Timer? _histPoll;
  int _viewers = 0;
  bool _busy = false;

  /// Экран открылся. Второй вызов только увеличивает счётчик — опрос уже идёт.
  void attach(AppState app) {
    _viewers++;
    _client = RelayClient(app.relayUrl, app.relayToken);
    if (_viewers > 1) return;
    if (!_client!.ready) {
      error = null;
      notifyListeners();
      return;
    }
    loading = status == null;
    notifyListeners();
    unawaited(_tick());
    unawaited(_loadHistory());
    // Два раза в секунду: чаще человек всё равно не читает, а станцию дёргать
    // незачем. Агент внутри себя считает раз в секунду — быстрее опрашивать
    // просто нечего.
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    // История нужна только для графика, она меняется медленно.
    _histPoll =
        Timer.periodic(const Duration(seconds: 10), (_) => _loadHistory());
  }

  /// Экран закрылся. Когда закрылся последний — опрос прекращается: держать
  /// станцию под запросами ради экрана, на который никто не смотрит, незачем.
  void detach() {
    if (_viewers > 0) _viewers--;
    if (_viewers > 0) return;
    _poll?.cancel();
    _poll = null;
    _histPoll?.cancel();
    _histPoll = null;
  }

  /// Адрес или токен изменили в настройках — пересоздаём клиент и чистим то,
  /// что показывали от прежнего агента.
  void reconfigure(AppState app) {
    _client = RelayClient(app.relayUrl, app.relayToken);
    status = null;
    history = const [];
    error = null;
    notifyListeners();
    if (_viewers > 0) {
      unawaited(_tick());
      unawaited(_loadHistory());
    }
  }

  Future<void> _tick() async {
    final c = _client;
    if (c == null || !c.ready || _busy) return;
    _busy = true;
    try {
      status = await c.status();
      error = null;
    } catch (e) {
      // Прежние цифры оставляем на экране, но помечаем ошибкой: пустой экран
      // при моргнувшей сети хуже, чем цифры с подписью «связи нет».
      error = e is RelayError ? e.message : e.toString();
    } finally {
      _busy = false;
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadHistory() async {
    final c = _client;
    if (c == null || !c.ready) return;
    try {
      history = await c.history();
      notifyListeners();
    } catch (_) {
      // График — не повод показывать ошибку: статус уже её покажет.
    }
  }

  Future<void> refresh() async {
    await _tick();
    await _loadHistory();
  }

  Future<String?> setMode(String mode) async {
    final c = _client;
    if (c == null || !c.ready) return 'адрес агента не задан';
    try {
      await c.setMode(mode);
      await _tick();
      return null;
    } catch (e) {
      return e is RelayError ? e.message : e.toString();
    }
  }

  Future<String?> patchConfig(Map<String, dynamic> patch) async {
    final c = _client;
    if (c == null || !c.ready) return 'адрес агента не задан';
    try {
      await c.putConfig(patch);
      return null;
    } catch (e) {
      return e is RelayError ? e.message : e.toString();
    }
  }
}

/// Скорость человеческими словами. Игровой трафик — это десятки килобит,
/// и показывать его в мегабитах с тремя нулями после запятой бессмысленно.
String animaFormatBps(int bps) {
  if (bps <= 0) return '0';
  if (bps < 1000) return '$bps бит/с';
  if (bps < 1000000) return '${(bps / 1000).toStringAsFixed(bps < 10000 ? 1 : 0)} кбит/с';
  return '${(bps / 1000000).toStringAsFixed(1)} Мбит/с';
}
