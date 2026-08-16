part of '../main.dart';

class SearchHit {
  final String title;
  final String url;
  final String snippet;
  const SearchHit(this.title, this.url, this.snippet);
}

class WebSearchService {
  WebSearchService._();
  static final WebSearchService instance = WebSearchService._();

  // Heuristic: does this query likely need fresh/live info? Curated RU+EN
  // signals (currency, weather, prices, "now/today", news, scores, release
  // dates, an explicit year). Cheap and works for voice — no extra model call.
  static final RegExp _freshRe = RegExp(
    r'(курс|доллар|евро|валют|биткоин|крипт|погод|weather|температур|'
    r'сегодня|сейчас|текущ|актуальн|последн|latest|current|today|now|'
    r'новост|news|цена|сколько стоит|стоимост|price|сч[её]т|score|'
    r'кто выиграл|результат|расписан|когда выйдет|release date|'
    r'\b20\d{2}\b)',
    caseSensitive: false,
  );
  bool needed(String q) => _freshRe.hasMatch(q);

  /// Все значения настройки «Поисковик». `auto` — прежнее поведение.
  static const List<String> providers = [
    'auto',
    'tavily',
    'brave',
    'google',
    'yandex',
    'ddg',
  ];

  /// Настроен ли провайдер: у платных это наличие ключей, DuckDuckGo — всегда.
  bool configured(String id, AppState? app) => switch (id) {
        'tavily' => (app?.tavilyKey ?? '').isNotEmpty,
        'brave' => (app?.braveKey ?? '').isNotEmpty,
        'google' =>
          (app?.googleKey ?? '').isNotEmpty && (app?.googleCx ?? '').isNotEmpty,
        'yandex' => (app?.yandexKey ?? '').isNotEmpty &&
            (app?.yandexFolder ?? '').isNotEmpty,
        _ => true,
      };

  // Кого и в каком порядке спрашивать.
  //
  // `auto` — сначала те, у кого есть ключ (они точнее и не ломаются от смены
  // вёрстки), DuckDuckGo последним как беcключевой запасной. Явно выбранный
  // провайдер используется СТРОГО один: если человек выбрал Яндекс, ответ из
  // DuckDuckGo вместо него — сюрприз, а не помощь.
  List<String> _order(AppState? app) {
    final chosen = app?.searchProvider ?? 'auto';
    if (chosen != 'auto' && providers.contains(chosen)) return [chosen];
    return [
      for (final p in const ['tavily', 'brave', 'google', 'yandex'])
        if (configured(p, app)) p,
      'ddg',
    ];
  }

  Future<List<SearchHit>> search(String query, {AppState? app}) async {
    // Раньше выбирался первый провайдер с ключом и на этом всё: пустой ответ
    // означал поиск без результата, хотя следующий мог бы ответить. Теперь
    // пустой ответ — повод спросить следующего (в режиме `auto`).
    for (final id in _order(app)) {
      try {
        final hits = await _byId(id, query, app);
        if (hits.isNotEmpty) return hits;
      } catch (e) {
        unawaited(appendLog('errors', 'WebSearch[$id]: $e'));
      }
    }
    return const [];
  }

  Future<List<SearchHit>> _byId(String id, String q, AppState? app) =>
      switch (id) {
        'tavily' => _tavily(q, app?.tavilyKey ?? ''),
        'brave' => _brave(q, app?.braveKey ?? ''),
        'google' => _google(q, app?.googleKey ?? '', app?.googleCx ?? ''),
        'yandex' => _yandex(q, app?.yandexKey ?? '', app?.yandexFolder ?? ''),
        _ => _ddg(q),
      };

  Future<List<SearchHit>> _tavily(String q, String key) async {
    final res = await http
        .post(
          Uri.parse('https://api.tavily.com/search'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'api_key': key,
            'query': q,
            'max_results': 5,
            'include_answer': true,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final hits = <SearchHit>[];
    final answer = (data['answer'] as String?)?.trim() ?? '';
    if (answer.isNotEmpty) hits.add(SearchHit('Сводка', '', answer));
    for (final r in (data['results'] as List? ?? const [])) {
      if (r is Map) {
        hits.add(SearchHit((r['title'] ?? '').toString(),
            (r['url'] ?? '').toString(), (r['content'] ?? '').toString()));
      }
    }
    return hits;
  }

  Future<List<SearchHit>> _brave(String q, String key) async {
    final res = await http.get(
      Uri.parse('https://api.search.brave.com/res/v1/web/search'
          '?q=${Uri.encodeQueryComponent(q)}&count=5'),
      headers: {'Accept': 'application/json', 'X-Subscription-Token': key},
    ).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final web = data['web'];
    final results = (web is Map ? web['results'] : null) as List? ?? const [];
    return [
      for (final r in results)
        if (r is Map)
          SearchHit((r['title'] ?? '').toString(),
              (r['url'] ?? '').toString(), (r['description'] ?? '').toString()),
    ];
  }

  // Google Programmable Search Engine (JSON API). Двух значений мало кто ждёт,
  // но без `cx` запрос не работает: ключ авторизует, а cx говорит, ПО ЧЕМУ
  // искать (движок настраивается на «весь интернет» в консоли Google).
  // Скрейпить выдачу google.com вместо этого нельзя — там капча.
  Future<List<SearchHit>> _google(String q, String key, String cx) async {
    if (key.isEmpty || cx.isEmpty) return const [];
    final res = await http.get(
      Uri.parse('https://www.googleapis.com/customsearch/v1'
          '?key=${Uri.encodeQueryComponent(key)}'
          '&cx=${Uri.encodeQueryComponent(cx)}'
          '&num=5&q=${Uri.encodeQueryComponent(q)}'),
    ).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final r in (data['items'] as List? ?? const []))
        if (r is Map)
          SearchHit((r['title'] ?? '').toString(), (r['link'] ?? '').toString(),
              (r['snippet'] ?? '').toString()),
    ];
  }

  // Yandex Search API. Отдаёт XML, а не JSON, поэтому разбор — регулярками:
  // тащить в проект XML-пакет ради одного провайдера не стоит, структура
  // ответа простая и стабильная (<doc> с url/title/passage).
  Future<List<SearchHit>> _yandex(String q, String key, String folder) async {
    if (key.isEmpty || folder.isEmpty) return const [];
    final res = await http.get(
      Uri.parse('https://yandex.ru/search/xml'
          '?folderid=${Uri.encodeQueryComponent(folder)}'
          '&apikey=${Uri.encodeQueryComponent(key)}'
          '&l10n=ru&sortby=rlv&filter=none&maxpassages=2'
          '&groupby=${Uri.encodeQueryComponent('attr=d.mode=deep.groups-on-page=5.docs-in-group=1')}'
          '&query=${Uri.encodeQueryComponent(q)}'),
    ).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    final xml = utf8.decode(res.bodyBytes, allowMalformed: true);
    // Яндекс отвечает 200 и на отказ (нет квоты, неверный ключ) — ошибка лежит
    // внутри XML, иначе она молча выглядела бы как «ничего не нашлось».
    final err = RegExp(r'<error[^>]*>(.*?)</error>', dotAll: true).firstMatch(xml);
    if (err != null) {
      unawaited(appendLog('errors',
          'WebSearch[yandex]: ${_stripHtml(err.group(1) ?? '')}'));
      return const [];
    }
    final hits = <SearchHit>[];
    for (final m
        in RegExp(r'<doc[^>]*>(.*?)</doc>', dotAll: true).allMatches(xml)) {
      final doc = m.group(1) ?? '';
      String tag(String name) {
        final t = RegExp('<$name[^>]*>(.*?)</$name>', dotAll: true)
            .firstMatch(doc)
            ?.group(1);
        return t == null ? '' : _stripHtml(t);
      }

      final title = tag('title');
      if (title.isEmpty) continue;
      final snippet = tag('passage').isNotEmpty ? tag('passage') : tag('headline');
      hits.add(SearchHit(title, tag('url'), snippet));
      if (hits.length >= 5) break;
    }
    return hits;
  }

  // Keyless fallback: scrape DuckDuckGo's HTML endpoint. Fragile by nature
  // (layout can change / it may rate-limit) — hence the optional API keys.
  Future<List<SearchHit>> _ddg(String q) async {
    final res = await http.post(
      Uri.parse('https://html.duckduckgo.com/html/'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'q=${Uri.encodeQueryComponent(q)}',
    ).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    final html = utf8.decode(res.bodyBytes, allowMalformed: true);
    final linkRe =
        RegExp(r'result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', dotAll: true);
    final snipRe = RegExp(r'result__snippet"[^>]*>(.*?)</a>', dotAll: true);
    final links = linkRe.allMatches(html).toList();
    final snips = snipRe.allMatches(html).toList();
    final hits = <SearchHit>[];
    for (var i = 0; i < links.length && i < 5; i++) {
      final url = _decodeDdgUrl(links[i].group(1) ?? '');
      final title = _stripHtml(links[i].group(2) ?? '');
      final snippet =
          i < snips.length ? _stripHtml(snips[i].group(1) ?? '') : '';
      if (title.isNotEmpty) hits.add(SearchHit(title, url, snippet));
    }
    return hits;
  }

  String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // DDG wraps result URLs as /l/?uddg=<encoded> — unwrap when present.
  String _decodeDdgUrl(String href) {
    try {
      final m = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href);
      if (m != null) return Uri.decodeComponent(m.group(1)!);
    } catch (_) {}
    return href.startsWith('//') ? 'https:$href' : href;
  }

  // Compact block appended to the system prompt. Includes today's date so the
  // model knows what "now" refers to.
  String contextBlock(List<SearchHit> hits) {
    if (hits.isEmpty) return '';
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final b = StringBuffer();
    b.writeln('\n\n[Актуальные результаты веб-поиска на $date — используй их, '
        'чтобы ответить по свежим данным; при необходимости укажи источник]');
    var i = 1;
    for (final h in hits.take(5)) {
      final s = h.snippet.length > 320
          ? '${h.snippet.substring(0, 320)}…'
          : h.snippet;
      b.writeln('[$i] ${h.title}${h.url.isNotEmpty ? ' (${h.url})' : ''}');
      if (s.isNotEmpty) b.writeln('    $s');
      i++;
    }
    return b.toString();
  }
}

// ============================ IN-APP UPDATER ============================
// Discord-style updates: silently download the new installer in the
// background, verify it (sha256 from the appcast, falling back to size), then
// show an in-app "restart to update" banner. Applying runs the installer in
// silent mode (detached) and exits; installer.iss relaunches the new version
// when passed /RELAUNCH=1. Replaces WinSparkle's native prompt flow.

enum UpdateStatus { idle, checking, downloading, ready, upToDate, error }

class _FeedItem {
  final String version;
  final String url;
  final int length;
  final String sha256hex; // '' when the feed entry predates sha256 support
  final List<String> notes; // release notes (<li> items from <description>)
  const _FeedItem(
      this.version, this.url, this.length, this.sha256hex, this.notes);
}

class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  final ValueNotifier<UpdateStatus> status = ValueNotifier(UpdateStatus.idle);
  final ValueNotifier<double> progress = ValueNotifier(0);
  String availableVersion = '';
  List<String> releaseNotes = const [];
  String? lastError;
  String? _installerPath;
  String _promptedVersion = '';
  // Version the user explicitly dismissed with "Later" — persisted so the
  // update dialog isn't shown again for it on every launch (the passive
  // top-bar pill still offers the update). Cleared implicitly when a newer
  // version appears (availableVersion changes).
  String _declinedVersion = '';
  // Version whose silent install was detected as FAILED on the next launch
  // (files never advanced). Persisted so the auto-check offers manual recovery
  // instead of re-showing the modal restart prompt in a loop. Cleared on a
  // successful apply or when a newer version appears.
  String _lastFailedVersion = '';
  Timer? _timer;
  bool _busy = false;
  AppState? _app;

  void start(AppState app) {
    _app = app;
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _declinedVersion = app.prefs.getString('updDeclinedVersion') ?? '';
    _lastFailedVersion = app.prefs.getString('updLastFailedVersion') ?? '';
    unawaited(_checkPreviousUpdateOutcome(app));
    unawaited(_cleanupOldInstallers());
    // Don't auto-poll during development unless a staging feed is forced.
    final hasOverride =
        (io.Platform.environment['EVS_UPDATE_FEED'] ?? '').trim().isNotEmpty;
    if (kDebugMode && !hasOverride) return;
    unawaited(checkAndDownload());
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) {
      if (_app?.autoUpdateCheck ?? true) unawaited(checkAndDownload());
    });
  }

  // Downloaded installers are one-shot; drop leftovers from previous updates.
  // The staged update-splash copy (~50 MB) goes with them: it only has to exist
  // between "apply" and the relaunch, and it's re-staged for the next update.
  Future<void> _cleanupOldInstallers() async {
    try {
      final dir = io.File(await updateDownloadPath('x')).parent;
      await for (final f in dir.list()) {
        final name = f.uri.pathSegments.last;
        if (f is io.File &&
            name.startsWith('EVS-Setup-') &&
            name.endsWith('.exe')) {
          try {
            await f.delete();
          } catch (_) {} // pending installer may be locked — fine, keep it
        }
      }
    } catch (_) {}
    try {
      final splash = io.Directory(await updateDownloadPath(_kUpdateSplashDir));
      if (await splash.exists()) await splash.delete(recursive: true);
    } catch (_) {}
  }

  // A previous run launched the silent installer (marker written by
  // applyAndRestart). If we're back up but the version DIDN'T advance, the
  // update silently failed to apply (locked files / cancelled) — surface it
  // instead of looping invisibly. One-shot: the marker is always cleared.
  /// Пишет ли установщик прямо сейчас. Признак — свежая запись в его логе:
  /// отдельного способа спросить у Inno Setup «ты ещё жив» нет, а лог он ведёт
  /// построчно на каждый распакованный файл.
  Future<bool> _installerRunning() async {
    try {
      final f = io.File(await updateDownloadPath('update-install.log'));
      if (!await f.exists()) return false;
      final age = DateTime.now().difference(await f.lastModified());
      return age.inSeconds < 90;
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkPreviousUpdateOutcome(AppState app) async {
    try {
      final marker = io.File(await updateDownloadPath('pending_update.txt'));
      if (!await marker.exists()) return;
      final expected = (await marker.readAsString()).trim();
      // Установщик ещё работает — судить рано. Его лог пишется построчно всю
      // распаковку, так что свежая запись в нём и означает «идёт прямо сейчас».
      // Без этой проверки вердикт выносился через считаные секунды после старта
      // установщика: в журнале ошибок с июля лежат «обновление не применилось»,
      // написанные в момент, когда установщик распаковал 66 МБ из 224 и
      // прекрасно довёл дело до конца. Маркер в таком случае НЕ трогаем —
      // разберёмся на следующем запуске.
      if (await _installerRunning()) return;
      try {
        await marker.delete();
      } catch (_) {}
      if (expected.isEmpty) return;
      final info = await PackageInfo.fromPlatform();
      if (_isNewer(expected, info.version)) {
        // FAILED: the running files never advanced to the new version.
        unawaited(appendLog('errors',
            'update did not apply: still ${info.version}, expected $expected'));
        // Attach the tail of both the updater-runner and the installer's own
        // log (if any) so the failure reason (runner never ran / locked file /
        // permission / …) is captured for diagnosis.
        for (final name in const ['update-runner.log', 'update-install.log']) {
          try {
            final logf = io.File(await updateDownloadPath(name));
            if (await logf.exists()) {
              final lines = await logf.readAsLines();
              final tail =
                  lines.length > 25 ? lines.sublist(lines.length - 25) : lines;
              unawaited(
                  appendLog('errors', '$name tail:\n${tail.join('\n')}'));
            } else {
              unawaited(appendLog('errors', '$name: MISSING (updater step never ran)'));
            }
          } catch (_) {}
        }
        // Remember the failed version so the auto-check offers manual recovery
        // instead of re-showing the modal restart prompt every launch.
        _lastFailedVersion = expected;
        unawaited(app.prefs.setString('updLastFailedVersion', expected));
        // Let them know once, after the window is actually visible.
        Future.delayed(const Duration(seconds: 3), () {
          final ctx = rootNavKey.currentContext;
          // ignore: use_build_context_synchronously
          if (ctx != null) showAppSnackBar(ctx, app.t('updFailedApply'));
        });
      } else if (expected == info.version) {
        // SUCCESS: we're running the freshly-installed version. Clear any
        // failure memory, surface the window (overlay mode otherwise re-hides
        // it, so a successful relaunch looks like "it didn't reopen"), and
        // confirm once.
        if (_lastFailedVersion.isNotEmpty) {
          _lastFailedVersion = '';
          unawaited(app.prefs.remove('updLastFailedVersion'));
        }
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            await windowManager.show();
            await windowManager.focus();
          } catch (_) {}
          final ctx = rootNavKey.currentContext;
          if (ctx != null && ctx.mounted) {
            showAppSnackBar(
                ctx, app.t('updApplied').replaceAll('{v}', expected));
          }
        });
      }
    } catch (_) {}
  }

  Future<void> checkAndDownload() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    if (_busy || status.value == UpdateStatus.ready) return;
    _busy = true;
    status.value = UpdateStatus.checking;
    try {
      final info = await PackageInfo.fromPlatform();
      final res = await http
          .get(Uri.parse(DesktopIntegration.effectiveFeedUrl))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception('feed HTTP ${res.statusCode}');
      final item = _newestItem(utf8.decode(res.bodyBytes));
      if (item == null || !_isNewer(item.version, info.version)) {
        status.value = UpdateStatus.upToDate;
        debugPrint('EVS_UPDATER up-to-date (current ${info.version})');
        return;
      }
      availableVersion = item.version;
      releaseNotes = item.notes;
      final dest = await updateDownloadPath('EVS-Setup-${item.version}.exe');
      if (!await _validFile(dest, item)) {
        status.value = UpdateStatus.downloading;
        progress.value = 0;
        debugPrint('EVS_UPDATER downloading ${item.version}');
        var lastReported = -1;
        await downloadFileWithProgress(item.url, dest, (r, t) {
          progress.value = t > 0 ? r / t : 0;
          // Mirror the real download progress into the shared status file
          // (throttled to whole percents) so the update splash can show the
          // whole lifecycle, not just the install half.
          final pct = (progress.value * 100).floor();
          if (pct != lastReported) {
            lastReported = pct;
            unawaited(_writeUpdateStatus(
                'download ${progress.value.toStringAsFixed(3)}'));
          }
        }, () => false);
        if (!await _validFile(dest, item)) {
          try {
            await io.File(dest).delete();
          } catch (_) {}
          throw Exception('update failed verification');
        }
      }
      _installerPath = dest;
      status.value = UpdateStatus.ready;
      debugPrint('EVS_UPDATER READY ${item.version}');
      _maybePrompt();
    } catch (e) {
      lastError = e.toString();
      status.value = UpdateStatus.error;
      debugPrint('EVS_UPDATER ERROR $e');
      unawaited(appendLog('errors', 'AppUpdater: $e'));
    } finally {
      _busy = false;
    }
  }

  // EVS-styled "update ready" dialog (Discord-style: everything is already
  // downloaded, one click restarts onto the new version). Shown once per
  // version; declining leaves the top-bar pill available.
  bool _promptPending = false;

  /// Called when the main window gains focus — show a prompt that was
  /// deferred because the window was hidden when the update became ready.
  void promptIfPending() {
    if (!_promptPending) return;
    _promptPending = false;
    _maybePrompt();
  }

  void _maybePrompt() {
    if (_promptedVersion == availableVersion) return;
    // Already dismissed with "Later" on a previous run — don't nag again; the
    // passive top-bar pill still lets them update when they want.
    if (_declinedVersion == availableVersion) return;
    () async {
      // The chat window often starts hidden (the floating widget is the only
      // visible surface) — a dialog shown now would go unseen. Defer until
      // the window is actually up (onWindowFocus → promptIfPending).
      var visible = true;
      try {
        visible = await windowManager.isVisible();
      } catch (_) {}
      if (!visible) {
        _promptPending = true;
        return;
      }
      _showPrompt();
    }();
  }

  // Open the GitHub release page for a version in the default browser (manual
  // recovery when a silent install keeps failing). explorer.exe launches URLs
  // via the default handler — no url_launcher dependency needed.
  Future<void> _openReleasePage(String version) async {
    final url =
        'https://github.com/kekw2077/enhanced-voice-system/releases/tag/desktop-v$version';
    try {
      await io.Process.start('explorer.exe', [url],
          mode: io.ProcessStartMode.detached);
    } catch (_) {}
  }

  void _showPrompt() {
    if (_promptedVersion == availableVersion) return;
    final app = _app;
    _promptedVersion = availableVersion;
    final ctx = rootNavKey.currentContext;
    if (ctx == null || app == null) return;
    // A prior silent install of THIS exact version was detected as failed —
    // don't re-show the restart prompt (that's the loop the user hit). Offer
    // manual download instead; the passive top-bar pill stays available too.
    if (availableVersion.isNotEmpty && availableVersion == _lastFailedVersion) {
      showDialog(
        context: ctx,
        builder: (dctx) => _AppDialog(
          title: Text('${app.t('updAvailableTitle')} — $availableVersion'),
          content: Text(
              app.t('updFailedManual').replaceAll('{v}', availableVersion)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(app.t('updLater')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dctx);
                unawaited(_openReleasePage(availableVersion));
              },
              child: Text(app.t('updDownloadManual')),
            ),
          ],
        ),
      );
      return;
    }
    showDialog(
      context: ctx,
      builder: (dctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 440,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          decoration: BoxDecoration(
            color: _card2(dctx),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x1AFFFFFF)),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black54, blurRadius: 40, offset: Offset(0, 16)),
            ],
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dctx).size.height * 0.85),
            child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _EvsLogoMark(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${app.t('updAvailableTitle')} — $availableVersion',
                      style: TextStyle(
                          color: _txt(dctx),
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (releaseNotes.isNotEmpty) ...[
                for (final n in releaseNotes.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Icon(Icons.circle,
                              size: 5, color: _accent(dctx)),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(n,
                              style: TextStyle(
                                  color: _body(dctx),
                                  fontSize: 13,
                                  height: 1.45)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
              ],
              Text(app.t('updDialogHint'),
                  style:
                      TextStyle(color: _faint(dctx), fontSize: 12)),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      // Remember the dismissal so we don't re-prompt for this
                      // version on every launch.
                      _declinedVersion = availableVersion;
                      unawaited(app.prefs
                          .setString('updDeclinedVersion', availableVersion));
                      Navigator.pop(dctx);
                    },
                    child: Text(app.t('updLater'),
                        style: TextStyle(color: _sub(dctx))),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.pop(dctx);
                      applyAndRestart();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(
                            colors: [Color(0xFF5068D8), Color(0xFF8855CC)]),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.restart_alt,
                              size: 16, color: Colors.white),
                          const SizedBox(width: 7),
                          Text(app.t('updRestart'),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Staged copy of the running build, from which the update splash runs while
  // the installer works and the app itself is closed. Lives under the app data
  // root (portable: <exeDir>\userdata) — a folder the installer never touches,
  // unlike everything in the program directory. See _updateSplashMain.
  static const String _kUpdateSplashDir = 'update-splash';
  static const String _kUpdateSplashExe = 'evs_updating.exe';

  // Single source of truth for "where is the update right now", shared between
  // the three parties that each only know their own piece: this app while it
  // downloads, the update script while it waits/installs/relaunches, and the
  // splash process that draws the progress bar. One line, `<phase> [value]`:
  //   download <0..1> · wait · install · relaunch · done
  // A plain file, because the splash runs in another process started by a batch
  // script — nothing fancier survives that boundary.
  static const String _kUpdateStatusFile = 'update-status.txt';

  Future<void> _writeUpdateStatus(String line) async {
    try {
      await io.File(await updateDownloadPath(_kUpdateStatusFile))
          .writeAsString(line);
    } catch (_) {}
  }

  // Copy the build next to the app data root under a different exe name.
  // Different name matters twice: the update script waits for every evs.exe to
  // close and then force-kills the leftovers, so a splash called evs.exe would
  // both hang the wait loop and get shot; and Task Manager shows what it is.
  // Returns the exe path, or null if staging failed (then the update just runs
  // without a splash, exactly as before).
  Future<String?> _stageUpdateSplash() async {
    try {
      final src = io.File(io.Platform.resolvedExecutable).parent;
      final dstPath = await updateDownloadPath(_kUpdateSplashDir);
      final dst = io.Directory(dstPath);
      if (await dst.exists()) await dst.delete(recursive: true);
      await dst.create(recursive: true);
      final sep = io.Platform.pathSeparator;
      await for (final e in src.list(followLinks: false)) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final low = name.toLowerCase();
        // userdata is our own data root (and holds this very copy); the widget
        // and sidecar exes aren't needed to draw a logo; unins* belongs to Setup.
        if (low == 'userdata' ||
            low == 'evs_widget.exe' ||
            low == 'evs_sidecar.exe' ||
            low.startsWith('unins')) {
          continue;
        }
        if (e is io.Directory) {
          await _copyDirInto(e, io.Directory('$dstPath$sep$name'));
        } else if (e is io.File) {
          // The runner finds its data\ folder next to the exe whatever the exe
          // is called, so renaming the copy is safe.
          final target = low == 'evs.exe' ? _kUpdateSplashExe : name;
          await e.copy('$dstPath$sep$target');
        }
      }
      final exe = io.File('$dstPath$sep$_kUpdateSplashExe');
      return await exe.exists() ? exe.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _copyDirInto(io.Directory src, io.Directory dst) async {
    await dst.create(recursive: true);
    final sep = io.Platform.pathSeparator;
    await for (final e in src.list(followLinks: false)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is io.Directory) {
        await _copyDirInto(e, io.Directory('${dst.path}$sep$name'));
      } else if (e is io.File) {
        await e.copy('${dst.path}$sep$name');
      }
    }
  }

  // Launch the verified installer silently (detached, so it survives our exit)
  // and quit; the installer swaps the files and relaunches the new version.
  Future<void> applyAndRestart() async {
    final path = _installerPath;
    if (path == null || status.value != UpdateStatus.ready) return;
    // Marker read by _checkPreviousUpdateOutcome on the next launch: if the
    // version didn't advance, the silent install failed and we say so instead
    // of looping invisibly.
    try {
      await io.File(await updateDownloadPath('pending_update.txt'))
          .writeAsString(availableVersion);
    } catch (_) {}
    // Install OVER the currently-running copy, wherever it lives (portable
    // F:\EVS, a manually-placed folder, or the default %LocalAppData%\Programs\
    // EVS). Without /DIR the installer's fixed DefaultDirName installs a SECOND
    // copy in AppData, the running exe is never replaced, its version never
    // advances, and the update re-offers on every launch — the reported loop.
    final exePath = io.Platform.resolvedExecutable;
    final runDir = io.File(exePath).parent.path;
    final scriptPath = await updateDownloadPath('evs_update.cmd');
    // The .cmd does the work, but a scheduled task running `cmd /c` pops a
    // console window in the user's session — visible for the whole update.
    // wscript has no window of its own and Run(..., 0, False) starts the batch
    // hidden, so the update happens silently. The .cmd deletes both files.
    final vbsPath = await updateDownloadPath('evs_update.vbs');
    final installLog = await updateDownloadPath('update-install.log');
    final runnerLog = await updateDownloadPath('update-runner.log');
    // A SELF-CONTAINED updater that runs entirely OUTSIDE this process. The old
    // approach launched a detached PowerShell and immediately quit — but that
    // child did not reliably outlive our exit here, so the installer never ran
    // (no update-install.log was ever produced across many versions). This .cmd
    // is started via a one-shot Scheduled Task, which the OS runs independently
    // of our process/session, guaranteeing it survives quitForUpdate below. It:
    //  1) waits until every evs.exe (main + widget) has closed, force-killing
    //     any leftover so nothing keeps the app files locked,
    //  2) installs silently OVER the running directory (/DIR) with a log,
    //  3) relaunches the freshly-installed evs.exe,
    //  4) removes the task and deletes itself.
    // Every step is written to update-runner.log so a failure is diagnosable.
    //
    // The Genesis splash is started BY THE SCRIPT, not by us: our own children
    // live in a Job Object with KILL_ON_JOB_CLOSE (ProcessJob) and would die
    // with us, while the script already runs detached via the scheduled task.
    // Starting it first (before the wait loop) means the logo is up before our
    // window disappears — no black gap. The taskkill after the relaunch takes it
    // down again; the splash also has its own watchdogs (see _updateSplashMain).
    final splashExe = await _stageUpdateSplash();
    final lang = _app?.lang ?? 'ru';
    final statusPath = await updateDownloadPath(_kUpdateStatusFile);
    // The splash gets BOTH paths explicitly: it runs from the staged copy
    // inside userdata, so resolving the data root itself would land one level
    // too deep. The install log doubles as the only real progress signal Inno
    // gives us — the splash watches it grow.
    final splashStart = splashExe == null
        ? ''
        : 'start "" "$splashExe" --update-splash --lang=$lang '
            '--status="$statusPath" --log="$installLog"\n';
    final splashKill = splashExe == null
        ? ''
        : 'taskkill /F /IM $_kUpdateSplashExe >nul 2>&1\n';
    final script = '''@echo off
setlocal enableextensions
set "RLOG=$runnerLog"
set "USTAT=$statusPath"
echo [%date% %time%] updater started > "%RLOG%"
${splashStart}echo wait> "%USTAT%"
:waitloop
set "RUNNING="
tasklist /FI "IMAGENAME eq evs.exe" 2>nul | find /I "evs.exe" >nul && set "RUNNING=1"
tasklist /FI "IMAGENAME eq evs_widget.exe" 2>nul | find /I "evs_widget.exe" >nul && set "RUNNING=1"
if defined RUNNING (
  timeout /t 1 /nobreak >nul
  goto waitloop
)
echo [%date% %time%] evs closed, killing leftovers >> "%RLOG%"
taskkill /F /IM evs.exe /IM evs_widget.exe /IM evs_sidecar.exe >nul 2>&1
timeout /t 1 /nobreak >nul
echo [%date% %time%] launching installer >> "%RLOG%"
echo install> "%USTAT%"
"$path" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /DIR="$runDir" /LOG="$installLog"
echo [%date% %time%] installer exit %errorlevel%, relaunching >> "%RLOG%"
echo relaunch> "%USTAT%"
start "" "$exePath"
timeout /t 2 /nobreak >nul
echo done> "%USTAT%"
${splashKill}echo [%date% %time%] done >> "%RLOG%"
schtasks /Delete /TN "EVSSelfUpdate" /F >nul 2>&1
del "$vbsPath" >nul 2>&1
del "%~f0" >nul 2>&1
''';
    try {
      await io.File(scriptPath).writeAsString(script);
    } catch (_) {}
    try {
      await io.File(vbsPath).writeAsString(
          'CreateObject("WScript.Shell").Run "cmd /c ""$scriptPath""", 0, False\n');
    } catch (_) {}
    bool launched = false;
    // Preferred: a one-shot scheduled task detaches the script from this process
    // entirely (not a child, not in our session/job) so it survives our exit.
    try {
      await io.Process.run('schtasks', [
        '/Create', '/TN', 'EVSSelfUpdate',
        // wscript keeps the whole update invisible (see vbsPath above).
        '/TR', 'wscript.exe //B //nologo "$vbsPath"',
        '/SC', 'ONCE', '/ST', '23:59', '/F',
      ]);
      final r = await io.Process.run('schtasks', ['/Run', '/TN', 'EVSSelfUpdate']);
      launched = r.exitCode == 0;
    } catch (_) {}
    // Fallback: launch the script through the shell (`start`) so it is reparented
    // to the session and outlives us.
    if (!launched) {
      try {
        // Same hidden path as the task, just started directly.
        await io.Process.start(
          'wscript.exe',
          ['//B', '//nologo', vbsPath],
          mode: io.ProcessStartMode.detached,
        );
        launched = true;
      } catch (_) {}
      // wscript can be disabled by policy — fall back to the visible console
      // rather than losing the update entirely.
      if (!launched) {
        try {
          await io.Process.start(
            'cmd.exe',
            ['/c', 'start', '""', '/min', 'cmd', '/c', scriptPath],
            mode: io.ProcessStartMode.detached,
          );
          launched = true;
        } catch (_) {}
      }
    }
    // Last resort: the installer's own /RELAUNCH (Restart Manager closes us).
    if (!launched) {
      try {
        await io.Process.start(path, [
          '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
          '/RELAUNCH=1', '/DIR=$runDir',
        ], mode: io.ProcessStartMode.detached);
        launched = true;
      } catch (e) {
        lastError = e.toString();
        status.value = UpdateStatus.error;
        return;
      }
    }
    await DesktopIntegration.instance.quitForUpdate();
  }

  Future<bool> _validFile(String path, _FeedItem item) async {
    try {
      final f = io.File(path);
      if (!await f.exists()) return false;
      if (item.sha256hex.isNotEmpty) {
        final digest = await sha256.bind(f.openRead()).first;
        return digest.toString().toLowerCase() == item.sha256hex.toLowerCase();
      }
      return item.length > 0 && await f.length() == item.length;
    } catch (_) {
      return false;
    }
  }

  // Minimal appcast parse (the feed is ours, format controlled): newest
  // windows <item> by version.
  _FeedItem? _newestItem(String xml) {
    _FeedItem? best;
    for (final m in RegExp(r'<item>([\s\S]*?)</item>').allMatches(xml)) {
      final block = m.group(1)!;
      if (!block.contains('sparkle:os="windows"')) continue;
      final v = RegExp(r'sparkle:version="([^"]+)"').firstMatch(block)?.group(1);
      final url = RegExp(r'url="([^"]+)"').firstMatch(block)?.group(1);
      if (v == null || url == null) continue;
      final len = int.tryParse(
              RegExp(r'length="(\d+)"').firstMatch(block)?.group(1) ?? '') ??
          0;
      final sha = RegExp(r'evs:sha256="([0-9a-fA-F]{64})"')
              .firstMatch(block)
              ?.group(1) ??
          '';
      // Release notes: the <li> items inside <description>, tags stripped.
      final notes = <String>[];
      final desc = RegExp(r'<description>([\s\S]*?)</description>')
          .firstMatch(block)
          ?.group(1);
      if (desc != null) {
        for (final li in RegExp(r'<li>([\s\S]*?)</li>').allMatches(desc)) {
          final t = li
              .group(1)!
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (t.isNotEmpty) notes.add(t);
        }
      }
      final item = _FeedItem(v, url, len, sha, notes);
      if (best == null || _isNewer(item.version, best.version)) best = item;
    }
    return best;
  }

  // True when a > b for dotted versions ("1.0.4" vs "1.0.3+4" — build ignored).
  static bool _isNewer(String a, String b) {
    List<int> parse(String v) => v
        .split('+')
        .first
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < 3; i++) {
      final ai = i < x.length ? x[i] : 0, bi = i < y.length ? y[i] : 0;
      if (ai != bi) return ai > bi;
    }
    return false;
  }
}

// ============================ COMPONENT MANAGER ============================
// Heavy native pieces (the Python sidecar exe, the XTTS voice-clone engine) are
// NOT bundled in the installer — they're downloaded on demand into the app's
// data folder and sha256-verified. This keeps the installer (and every update)
// small. Manifest `components.json` is hosted next to the appcast.

enum ComponentState { absent, downloading, verifying, ready, error }

class ComponentStatus {
  final ComponentState state;
  final double progress; // 0..1 while downloading
  final String? error;
  const ComponentStatus(this.state, {this.progress = 0, this.error});
}

class ComponentInfo {
  final String id;
  final String fileName; // downloaded file (an .exe, or an .zip if archive)
  final String version;
  final String url;
  final String sha256;
  final int size;
  final bool archive; // fileName is a zip to extract into <dir>/<id>/
  final String exe; // for archives: path to the launchable exe inside the dir
  // >1 = split asset: fetch `<url>.001`..`<url>.00N` and concatenate (GitHub
  // caps release assets at 2 GiB; the clone component is far bigger).
  final int parts;
  const ComponentInfo(
      {required this.id,
      required this.fileName,
      required this.version,
      required this.url,
      required this.sha256,
      required this.size,
      this.archive = false,
      this.exe = '',
      this.parts = 1});

  factory ComponentInfo.fromJson(String id, Map<String, dynamic> j) =>
      ComponentInfo(
        id: id,
        fileName: (j['file'] ?? '$id.bin') as String,
        version: (j['version'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        sha256: (j['sha256'] ?? '') as String,
        size: (j['size'] ?? 0) as int,
        archive: j['archive'] == true,
        exe: (j['exe'] ?? '') as String,
        parts: (j['parts'] ?? 1) as int,
      );
}

class ComponentManager {
  ComponentManager._();
  static final ComponentManager instance = ComponentManager._();

  static const String manifestUrl =
      'https://raw.githubusercontent.com/kekw2077/enhanced-voice-system/main/test1/dist/components.json';

  /// Откуда брать список компонентов: свой сервер обновлений, если задан.
  /// Адреса самих файлов лежат ВНУТРИ списка, так что перенос на свой сервер —
  /// это и подмена списка, и подмена ссылок в нём; выкладка это делает сама.
  static String effectiveManifestUrl(AppState? app) =>
      app?.updateUrlFor('components.json') ?? manifestUrl;

  /// Настройки — ради адреса своего сервера обновлений. Ставится один раз при
  /// запуске; до этого момента (и в тестах) действует адрес по умолчанию.
  AppState? _app;
  set app(AppState v) => _app = v;

  Map<String, ComponentInfo> _manifest = {};
  final Map<String, ValueNotifier<ComponentStatus>> _status = {};
  String? _dir;

  ValueNotifier<ComponentStatus> statusOf(String id) => _status.putIfAbsent(
      id, () => ValueNotifier(const ComponentStatus(ComponentState.absent)));

  ComponentInfo? infoOf(String id) => _manifest[id];

  Future<String> _componentsDir() async => _dir ??= await componentsDirPath();

  // Absolute path to a component's launchable file if present, else null. For
  // an archive component this is the extracted exe (<dir>/<id>/<exe>).
  Future<String?> installedPath(String id, {String? fileName}) async {
    final sep = io.Platform.pathSeparator;
    final dir = await _componentsDir();
    final info = _manifest[id];
    if (info != null && info.archive) {
      final p = '$dir$sep$id$sep${info.exe}';
      return await io.File(p).exists() ? p : null;
    }
    if (info == null) {
      // Manifest unavailable (e.g. the fetch timed out and there was no cache):
      // probe disk directly and PREFER the current onedir layout
      // (components/<id>/<exe>) over any stale legacy onefile — otherwise we
      // launch an old sidecar that rejects the current CLI args (the reported
      // "голосовой движок не запущен").
      if (fileName != null) {
        final onedir = '$dir$sep$id$sep$fileName';
        if (await io.File(onedir).exists()) return onedir;
        final onefile = '$dir$sep$fileName';
        if (await io.File(onefile).exists()) return onefile;
      }
      return null;
    }
    final name = fileName ?? info.fileName;
    final p = '$dir$sep$name';
    return await io.File(p).exists() ? p : null;
  }

  bool isReady(String id) => statusOf(id).value.state == ComponentState.ready;

  /// Читает манифест компонентов. **Сначала кэш на диске, сеть — фоном.**
  ///
  /// Чтобы решить, какой файл движка запускать, свежий манифест не нужен:
  /// нужен тот, по которому компонент уже установлен, а он лежит рядом. Сеть
  /// нужна только чтобы УЗНАТЬ о новой версии, а это не срочно — обновление всё
  /// равно применяется на следующем запуске. Раньше запрос стоял на пути
  /// запуска с таймаутом 15 секунд: полторы секунды в лучшем случае и до
  /// пятнадцати, если до GitHub не достучаться.
  Future<void> loadManifest() async {
    final sep = io.Platform.pathSeparator;
    final cache = io.File('${await _componentsDir()}${sep}manifest.json');
    var fromCache = false;
    try {
      if (await cache.exists()) {
        _parseManifest(await cache.readAsString());
        fromCache = true;
      }
    } catch (_) {}
    if (fromCache) {
      // Кэш есть — стартуем по нему, а свежий подтянем в фоне: он повлияет на
      // stageUpdate (припасти обновление к следующему запуску), не на этот.
      unawaited(_fetchManifest(cache));
      await refreshStates();
      return;
    }
    // Кэша нет вовсе — первый запуск. Тут без сети действительно никак:
    // неизвестно даже, что качать.
    await _fetchManifest(cache);
    await refreshStates();
  }

  Future<void> _fetchManifest(io.File cache) async {
    try {
      final res = await http
          .get(Uri.parse(effectiveManifestUrl(_app)))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return;
      _parseManifest(res.body);
      try {
        await cache.writeAsString(res.body);
      } catch (_) {}
    } catch (_) {}
  }

  void _parseManifest(String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final comps = (j['components'] as Map?)?.cast<String, dynamic>() ?? {};
      _manifest = {
        for (final e in comps.entries)
          e.key: ComponentInfo.fromJson(
              e.key, (e.value as Map).cast<String, dynamic>())
      };
    } catch (_) {}
  }

  Future<void> refreshStates() async {
    for (final id in _manifest.keys) {
      final st = statusOf(id);
      if (st.value.state == ComponentState.downloading ||
          st.value.state == ComponentState.verifying) {
        continue;
      }
      final p = await installedPath(id);
      st.value = ComponentStatus(
          p != null ? ComponentState.ready : ComponentState.absent);
    }
  }

  // Ensure a component is present (download if missing). Returns its path.
  // Updates to an already-present component go through stageUpdate/apply, not
  // here — you can't replace a running exe in place.
  Future<String?> ensure(String id) async {
    final existing = await installedPath(id);
    if (existing != null) {
      statusOf(id).value = const ComponentStatus(ComponentState.ready);
      return existing;
    }
    return download(id);
  }

  // One-time reclaim: the CPU voice clone (XTTS) was removed from EVS — it
  // produced unintelligible speech and its component + caches weighed ~8 GB on
  // disk. Delete any leftover clone install/cache/markers so an updated machine
  // gets the space back. Best-effort and idempotent (a no-op once gone), so it's
  // safe to call on every launch.
  Future<void> purgeClone() async {
    try {
      final sep = io.Platform.pathSeparator;
      final dir = await _componentsDir();
      for (final n in const ['clone', 'tts-clone', 'tts-cache']) {
        try {
          final d = io.Directory('$dir$sep$n');
          if (await d.exists()) await d.delete(recursive: true);
        } catch (_) {}
      }
      for (final f in const [
        '.clone.version',
        '.tts-clone.version',
        'evs_clone.zip',
        'evs_clone.zip.new',
        'evs_clone.zip.part',
        'evs_clone.zip.001',
        'evs_clone.zip.002',
      ]) {
        try {
          final file = io.File('$dir$sep$f');
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Одноразовая уборка: сайдкар когда-то был одним файлом (`evs_sidecar.exe`),
  /// потом стал распакованной папкой `components/sidecar/`. Файлы прежнего
  /// формата код с тех пор не открывает ни разу — но лежат они по 100 МБ
  /// каждый: на этой машине 212 МБ вдвоём.
  ///
  /// Удалять их не просто ради места. `installedPath` при недоступном манифесте
  /// умеет подхватить старый одиночный exe — а он не понимает нынешние
  /// аргументы запуска и падает на их разборе, выдавая «голосовой движок не
  /// запущен». То есть это не запасной вариант, а ловушка.
  ///
  /// Идемпотентно: после первого раза — пустой проход.
  Future<void> purgeLegacySidecar() async {
    try {
      final sep = io.Platform.pathSeparator;
      final dir = await _componentsDir();
      // Только формат «один файл» и обрывки закачек. Ни `sidecar/`, ни
      // `evs_sidecar.zip.new` тут не трогаем: первое — рабочий движок, второе
      // разбирает applyStagedUpdates по маркеру версии.
      for (final f in const [
        'evs_sidecar.exe',
        'evs_sidecar.exe.new',
        'evs_sidecar.zip.part',
      ]) {
        final file = io.File('$dir$sep$f');
        try {
          if (!await file.exists()) continue;
          final mb = (await file.length()) ~/ (1024 * 1024);
          if (await _deleteStubborn(file)) {
            unawaited(appendLog('sidecar', 'убран файл старого формата: $f '
                '($mb МБ)'));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<String> _versionMarkerPath(String id) async =>
      '${await _componentsDir()}${io.Platform.pathSeparator}.$id.version';

  /// Удалить файл, которого Windows ещё может не отпустить. Сразу после
  /// распаковки её собственный хэндл на архив живёт ещё мгновение, и
  /// одиночный `delete()` тихо проваливается — а провалившееся удаление здесь
  /// стоило пользователю 88 секунд на каждом запуске. Несколько попыток с
  /// паузой закрывают вопрос; если и они не помогли, следующий запуск отсеет
  /// файл по маркеру версии.
  Future<bool> _deleteStubborn(io.File f) async {
    for (var i = 0; i < 5; i++) {
      try {
        if (!await f.exists()) return true;
        await f.delete();
        return true;
      } catch (_) {
        await Future.delayed(Duration(milliseconds: 120 * (i + 1)));
      }
    }
    unawaited(appendLog('errors',
        'не удалось удалить припасённый файл ${f.path} — будет отсеян по версии'));
    return false;
  }

  Future<String?> _readVersion(String id) async {
    try {
      return await io.File(await _versionMarkerPath(id)).readAsString();
    } catch (_) {
      return null;
    }
  }

  // If the manifest advertises a newer version than what's installed, download
  // it to a staged "<file>.new" beside the current one. Non-blocking and safe
  // while the component is running (the live exe isn't touched). Applied on the
  // next launch by applyStagedUpdates(), before the component starts.
  //
  // Archives stage too: the zip is downloaded to "<file>.new" and extracted at
  // the next launch. (They used to be skipped entirely — once the sidecar became
  // an archive component that silently KILLED its update path, leaving installs
  // stuck on an old sidecar forever: the "clone never works" bug.)
  Future<void> stageUpdate(String id) async {
    final info = _manifest[id];
    if (info == null || info.url.isEmpty) return;
    if (await installedPath(id) == null) return; // nothing installed to update
    if (await _readVersion(id) == info.version) return; // already current
    final sep = io.Platform.pathSeparator;
    final staged = '${await _componentsDir()}$sep${info.fileName}.new';
    if (await io.File(staged).exists() && await _verify(staged, info.sha256)) {
      return; // already staged
    }
    try {
      await _fetchAsset(info, staged, null);
      if (!await _verify(staged, info.sha256)) {
        try {
          await io.File(staged).delete();
        } catch (_) {}
      }
    } catch (_) {
      try {
        await io.File('$staged.part').delete();
      } catch (_) {}
    }
  }

  // Swap in any staged "<file>.new" updates. Call before launching components
  // (so the target exe isn't locked). Archive components re-extract into
  // components/<id>/ — safe here for the same reason: nothing is running yet.
  Future<void> applyStagedUpdates() async {
    try {
      final dir = await _componentsDir();
      final sep = io.Platform.pathSeparator;
      for (final entry in _manifest.entries) {
        final name = entry.value.fileName;
        final staged = io.File('$dir$sep$name.new');
        if (!await staged.exists()) continue;
        // Эта версия уже стоит — припасённый файл лишний. Проверка обязана быть
        // ПЕРВОЙ: без неё каждый запуск считал sha256 по сотне мегабайт и
        // распаковывал их заново. Так и было — удалить архив после распаковки
        // не удавалось (Windows ещё держал файл), маркер версии при этом
        // обновлялся, и приложение переустанавливало один и тот же движок
        // каждый раз. Замер на машине пользователя: 88 секунд из 94.
        if ((await _readVersion(entry.key))?.trim() ==
            entry.value.version.trim()) {
          await _deleteStubborn(staged);
          continue;
        }
        if (entry.value.archive) {
          if (!await _verify(staged.path, entry.value.sha256)) {
            try {
              await staged.delete(); // corrupt stage — re-download next run
            } catch (_) {}
            continue;
          }
          final exe =
              await _extract(entry.key, staged.path, entry.value.exe);
          if (exe != null) {
            await _deleteStubborn(staged);
            try {
              await io.File(await _versionMarkerPath(entry.key))
                  .writeAsString(entry.value.version);
            } catch (_) {}
          }
          // Extract failed (e.g. a transient lock): KEEP the verified staged
          // zip — it retries on the next launch instead of re-downloading.
          continue;
        }
        final target = '$dir$sep$name';
        try {
          if (await io.File(target).exists()) await io.File(target).delete();
          await staged.rename(target);
          await io.File(await _versionMarkerPath(entry.key))
              .writeAsString(entry.value.version);
        } catch (_) {}
      }
    } catch (_) {}
  }

  // Download a component's asset (single file, or split .001/.002… parts
  // concatenated) into [dest]. Shared by download() and stageUpdate().
  Future<void> _fetchAsset(ComponentInfo info, String dest,
      void Function(double frac)? onProgress) async {
    if (info.parts > 1) {
      final sink = io.File(dest).openWrite();
      try {
        for (var i = 1; i <= info.parts; i++) {
          final partUrl = '${info.url}.${i.toString().padLeft(3, '0')}';
          final partFile = '$dest.p$i';
          await downloadFileWithProgress(partUrl, partFile, (r, t) {
            final frac = t > 0 ? r / t : 0.0;
            onProgress?.call((i - 1 + frac) / info.parts);
          }, () => false);
          await sink.addStream(io.File(partFile).openRead());
          try {
            await io.File(partFile).delete();
          } catch (_) {}
        }
      } finally {
        await sink.close();
      }
    } else {
      await downloadFileWithProgress(info.url, dest,
          (r, t) => onProgress?.call(t > 0 ? r / t : 0), () => false);
    }
  }

  Future<String?> download(String id) async {
    final info = _manifest[id];
    if (info == null || info.url.isEmpty) {
      statusOf(id).value =
          const ComponentStatus(ComponentState.error, error: 'no manifest');
      return null;
    }
    final st = statusOf(id);
    final dest =
        '${await _componentsDir()}${io.Platform.pathSeparator}${info.fileName}';
    st.value = const ComponentStatus(ComponentState.downloading);
    try {
      await _fetchAsset(info, dest, (frac) {
        st.value =
            ComponentStatus(ComponentState.downloading, progress: frac);
      });
      st.value = const ComponentStatus(ComponentState.verifying);
      if (!await _verify(dest, info.sha256)) {
        try {
          await io.File(dest).delete();
        } catch (_) {}
        st.value = const ComponentStatus(ComponentState.error,
            error: 'checksum mismatch');
        return null;
      }
      String result = dest;
      if (info.archive) {
        final extracted = await _extract(id, dest, info.exe);
        if (extracted == null) {
          st.value = const ComponentStatus(ComponentState.error,
              error: 'extract failed');
          return null;
        }
        try {
          await io.File(dest).delete(); // drop the zip, keep the folder
        } catch (_) {}
        result = extracted;
      }
      try {
        await io.File(await _versionMarkerPath(id)).writeAsString(info.version);
      } catch (_) {}
      st.value = const ComponentStatus(ComponentState.ready);
      return result;
    } catch (e) {
      st.value = ComponentStatus(ComponentState.error, error: e.toString());
      return null;
    }
  }

  // Extract an archive component's zip into <dir>/<id>/ (via PowerShell
  // Expand-Archive — Windows only). Returns the launchable exe path.
  //
  // Имя exe приходит параметром, а НЕ читается тут из `_manifest`: распаковка
  // длится секунды, а с кэш-первым `loadManifest()` в это же время фоном едет
  // свежий манифест и переприсваивает карту. Читая её после распаковки, можно
  // не найти компонент, вернуть null — и удачная распаковка выглядит как
  // неудачная: маркер версии не пишется, припасённый архив остаётся, и
  // следующий запуск распаковывает всё заново. Это ровно тот цикл, который
  // стоил пользователю полутора минут; поймано на синтетическом компоненте.
  Future<String?> _extract(String id, String zipPath, String exeName) async {
    if (exeName.isEmpty) return null;
    final sep = io.Platform.pathSeparator;
    final dir = await _componentsDir();
    final target = '$dir$sep$id';
    try {
      final t = io.Directory(target);
      if (await t.exists()) await t.delete(recursive: true);
      final r = await io.Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Expand-Archive -Path "$zipPath" -DestinationPath "$target" -Force'
      ]);
      if (r.exitCode != 0) return null;
      final exe = '$target$sep$exeName';
      return await io.File(exe).exists() ? exe : null;
    } catch (_) {
      return null;
    }
  }

  // Stream the file through sha256 so huge components don't load into memory.
  Future<bool> _verify(String path, String expected) async {
    if (expected.isEmpty) return true;
    try {
      final digest = await sha256.bind(io.File(path).openRead()).first;
      return digest.toString().toLowerCase() == expected.toLowerCase();
    } catch (_) {
      return false;
    }
  }
}

