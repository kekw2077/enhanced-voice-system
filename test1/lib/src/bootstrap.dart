part of '../main.dart';

// Kept short now that the animated ImmersiveSplash provides the real
// startup dwell — otherwise boot would be this delay plus the ~1.5s
// animation stacked back to back.
const _minSplashDuration = Duration(milliseconds: 300);

// Single-instance guard: the main app claims this fixed loopback port. A second
// launch fails to bind, signals the running instance to surface its window, and
// exits — so the desktop shortcut focuses the running app instead of spawning a
// duplicate. Kept alive for the process lifetime so it isn't garbage-collected.
const int _kSingleInstancePort = 47653;
io.ServerSocket? _singleInstanceLock;

// The floating widget window is this many times larger than `overlaySize` so
// there's transparent breathing room around the visualization (the viz itself
// keeps its size — see OverlayWidgetView).
const double kWidgetWindowScale = 1.35;

// HuggingFace repo the GigaAM-v3 sherpa-onnx model is published under — shown in
// the "model not found" hint (TZ1). Mirrors GIGAAM_HF_REPO in the sidecar.
const String kGigaamHfRepo =
    'csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16';

// Named Win32 mutex held for the whole process lifetime. The Inno Setup
// installer declares the same name via AppMutex, so during a silent in-app
// update it can detect the running instance and (with CloseApplications=force)
// close it via Restart Manager before copying files — without this the old
// files stay locked and the update silently doesn't apply. The handle is left
// open for the whole process (released automatically when the process dies), so
// there's nothing to store.
void _claimAppMutex() {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final createMutex = k32
        .lookupFunction<_CreateMutexNative, _CreateMutexDart>('CreateMutexW');
    final name = 'EVS-SingleInstance-Mutex'.toNativeUtf16();
    createMutex(nullptr, 0, name);
    malloc.free(name); // the kernel copies the name
  } catch (_) {}
}

typedef _CreateMutexNative = IntPtr Function(
    Pointer<Void>, Int32, Pointer<Utf16>);
typedef _CreateMutexDart = int Function(Pointer<Void>, int, Pointer<Utf16>);

// Best-effort cleanup of a backend orphaned by a previous crashed session.
// main()'s first-instance path is only reached when no other EVS main is
// running (single-instance guard) and before we spawn our own backend — so any
// surviving evs_sidecar.exe is a stray from a crash, holding the mic/IPC port
// and blocking a clean cold start. The Job Object (ProcessJob) and the
// sidecar's parent-watchdog normally prevent orphans; this is the
// belt-and-suspenders for when both failed (TZ: единое дерево процессов —
// чистый повторный запуск после падения).
Future<void> _sweepOrphanBackends() async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await io.Process.run(
        'taskkill', ['/F', '/IM', 'evs_sidecar.exe'],
        runInShell: false);
  } catch (_) {}
}

// Restore the main window's saved geometry (size / position / maximized) before
// the first show, validated against the current monitor layout so it never
// lands off-screen after a display change. Geometry lives in prefs (userdata),
// so it survives app updates — the installer replaces the program files in
// {app} but never touches {app}\userdata. DPI note: window_manager and
// screen_retriever both work in logical pixels, so the comparison is
// consistent; mixed-DPI multi-monitor may still be approximate.
Future<void> _restoreWindowBounds(SharedPreferences prefs) async {
  try {
    final w = prefs.getDouble('winW');
    final h = prefs.getDouble('winH');
    final x = prefs.getDouble('winX');
    final y = prefs.getDouble('winY');
    // No saved geometry (first run) — keep WindowOptions' centered default.
    if (w == null || h == null || x == null || y == null) return;
    final rect = await _clampToVisibleArea(Rect.fromLTWH(x, y, w, h));
    await windowManager.setBounds(rect);
    if (prefs.getBool('winMax') ?? false) await windowManager.maximize();
  } catch (_) {}
}

// Fit a saved window rect into the current displays: shrink it to the target
// monitor's work area and, if its title bar isn't visible on any monitor
// (config changed), re-center it on the monitor it most overlaps.
Future<Rect> _clampToVisibleArea(Rect rect) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    final rects = <Rect>[];
    for (final d in displays) {
      final pos = d.visiblePosition ?? Offset.zero;
      final size = d.visibleSize ?? d.size;
      rects.add(pos & size);
    }
    if (rects.isEmpty) return rect;
    // Pick the display the window overlaps most (fallback: the first/primary).
    var target = rects.first;
    var bestOverlap = -1.0;
    for (final r in rects) {
      final ix = math.min(rect.right, r.right) - math.max(rect.left, r.left);
      final iy = math.min(rect.bottom, r.bottom) - math.max(rect.top, r.top);
      final overlap = (ix > 0 && iy > 0) ? ix * iy : 0.0;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        target = r;
      }
    }
    var width = rect.width.clamp(900.0, target.width);
    var height = rect.height.clamp(600.0, target.height);
    // Is a meaningful part of the title bar on any monitor?
    final probe = Offset(rect.left + rect.width / 2, rect.top + 12);
    final onScreen = rects.any((r) => r.contains(probe));
    double left, top;
    if (onScreen) {
      left = rect.left.clamp(target.left, target.right - width);
      top = rect.top.clamp(target.top, target.bottom - height);
    } else {
      left = target.left + (target.width - width) / 2;
      top = target.top + (target.height - height) / 2;
    }
    return Rect.fromLTWH(left, top, width, height);
  } catch (_) {
    return rect;
  }
}

// Back SharedPreferences with a JSON file in the app data root (which is
// <exeDir>\userdata in portable mode) instead of the fixed AppData location, so
// chats/settings live next to the program too. Migrates the existing AppData
// prefs once; the legacy file is never deleted (safety net against data loss).
// Must be installed BEFORE any SharedPreferences.getInstance() call.
Future<void> _installPortablePrefs() async {
  try {
    // Only override the store in portable mode. In the AppData fallback the
    // default shared_preferences_windows store already reads the right file
    // (shared_preferences.json) — installing ours (prefs.json) there would hide
    // the user's existing settings/chats.
    final root = await appDataRoot();
    final legacy = await legacyDataRoot();
    if (root == legacy) return;
    SharedPreferencesStorePlatform.instance =
        await _PortablePrefsStore.create();
  } catch (_) {}
}

class _PortablePrefsStore extends SharedPreferencesStorePlatform {
  final io.File _file;
  final Map<String, Object> _cache;
  _PortablePrefsStore._(this._file, this._cache);

  static Future<_PortablePrefsStore> create() async {
    final root = await appDataRoot();
    final sep = io.Platform.pathSeparator;
    final file = io.File('$root${sep}prefs.json');
    var data = <String, Object>{};
    try {
      if (await file.exists()) {
        data = _decode(await file.readAsString());
      } else {
        // One-time migration from the legacy AppData shared_preferences.json.
        final legacyRoot = await legacyDataRoot();
        if (legacyRoot != root) {
          final legacy = io.File('$legacyRoot${sep}shared_preferences.json');
          if (await legacy.exists()) {
            data = _decode(await legacy.readAsString());
            try {
              await file.writeAsString(jsonEncode(data));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return _PortablePrefsStore._(file, data);
  }

  static Map<String, Object> _decode(String s) {
    final out = <String, Object>{};
    try {
      final m = jsonDecode(s);
      if (m is Map) {
        m.forEach((k, v) {
          if (v != null) out[k.toString()] = v as Object;
        });
      }
    } catch (_) {}
    return out;
  }

  Future<void> _persist() async {
    try {
      await _file.writeAsString(jsonEncode(_cache));
    } catch (_) {}
  }

  @override
  Future<bool> clear() async {
    _cache.clear();
    await _persist();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    // JSON turns List<String> into List<dynamic>; restore the type
    // SharedPreferences expects.
    final out = <String, Object>{};
    _cache.forEach((k, v) {
      out[k] = v is List ? v.map((e) => e.toString()).toList() : v;
    });
    return out;
  }

  @override
  Future<bool> remove(String key) async {
    _cache.remove(key);
    await _persist();
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _cache[key] = value;
    await _persist();
    return true;
  }
}


class WidgetPosStore {
  static Future<io.File?> _file() async {
    try {
      final root = await appDataRoot();
      return io.File('$root${io.Platform.pathSeparator}widget_pos.json');
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> read() async {
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return null;
      final m = jsonDecode(await f.readAsString());
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeAbsolute(Offset pos) async {
    try {
      final f = await _file();
      if (f == null) return;
      final rec = <String, dynamic>{'absX': pos.dx, 'absY': pos.dy};
      final anchor = await _anchorFor(pos);
      if (anchor != null) rec.addAll(anchor);
      await f.writeAsString(jsonEncode(rec));
    } catch (_) {}
  }

  // One-time migration: seed the file from the legacy prefs overlayX/Y (owned by
  // the main process) so an existing widget keeps its spot across this update.
  static Future<void> migrateFromPrefs(SharedPreferences prefs) async {
    try {
      final f = await _file();
      if (f == null || await f.exists()) return;
      final x = prefs.getDouble('overlayX');
      final y = prefs.getDouble('overlayY');
      if (x == null || y == null) return;
      await writeAbsolute(Offset(x, y));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> _anchorFor(Offset pos) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final dp = d.visiblePosition ?? Offset.zero;
        final ds = d.visibleSize ?? d.size;
        if ((dp & ds).contains(pos)) {
          return {
            'mon': d.id,
            'monName': d.name,
            'relX': pos.dx - dp.dx,
            'relY': pos.dy - dp.dy,
            'scale': d.scaleFactor ?? 1.0,
          };
        }
      }
    } catch (_) {}
    return null;
  }

  // Resolve a saved record into an absolute position for the CURRENT monitor
  // layout. Returns null when the saved monitor is gone AND the absolute
  // fallback isn't on any current display — the caller then parks the widget on
  // a safe default WITHOUT overwriting the record, so it returns to its place
  // when the monitor comes back.
  static Future<Offset?> resolve(Map<String, dynamic> rec) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return null;
      final mon = rec['mon'];
      final monName = rec['monName'];
      final relX = (rec['relX'] as num?)?.toDouble();
      final relY = (rec['relY'] as num?)?.toDouble();
      if (relX != null && relY != null) {
        for (final d in displays) {
          final match = (mon != null && d.id == mon) ||
              (monName != null && d.name == monName);
          if (match) {
            final dp = d.visiblePosition ?? Offset.zero;
            return Offset(dp.dx + relX, dp.dy + relY);
          }
        }
      }
      // Saved monitor absent — use the absolute fallback only if still on-screen.
      final absX = (rec['absX'] as num?)?.toDouble();
      final absY = (rec['absY'] as num?)?.toDouble();
      if (absX != null && absY != null) {
        final pos = Offset(absX, absY);
        for (final d in displays) {
          final dp = d.visiblePosition ?? Offset.zero;
          final ds = d.visibleSize ?? d.size;
          if ((dp & ds).contains(pos)) return pos;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/* ==================== ПРОЦЕСС ПЛАВАЮЩЕГО ВИДЖЕТА ==================== */

// Entry point of the widget process (`evs.exe --viz-overlay --port=N`): a
// tiny transparent always-on-top window rendering just the voice
// visualization. No prefs writes, tray, hotkeys, sidecar, updater or mic
// here — everything it shows arrives from the main process over a localhost
// WebSocket, and it exits as soon as that socket closes.
Future<void> _vizOverlayMain(List<String> args) async {
  var port = 0;
  for (final a in args) {
    if (a.startsWith('--port=')) port = int.tryParse(a.substring(7)) ?? 0;
  }
  await windowManager.ensureInitialized();
  try {
    await acrylic.Window.initialize();
  } catch (_) {}
  // Placeholder size; the first cfg from the main process sets the real one
  // (overlaySize * kWidgetWindowScale). Pre-scaled to avoid a resize flash.
  const opts = WindowOptions(
    size: Size(260 * kWidgetWindowScale, 260 * kWidgetWindowScale),
    minimumSize: Size(120, 120),
    title: 'EVS Widget',
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
    // Restore the widget's own saved position (its private file) before showing,
    // resolved against the current monitor layout. If its monitor is gone, park
    // at a safe default WITHOUT touching the saved record (see WidgetPosStore).
    Offset? restored;
    final rec = await WidgetPosStore.read();
    if (rec != null) restored = await WidgetPosStore.resolve(rec);
    if (restored != null) {
      await windowManager.setPosition(restored);
    } else {
      await windowManager.setAlignment(Alignment.centerRight);
    }
    await windowManager.show();
  }));
  runApp(VizOverlayApp(port: port));
}

class VizOverlayApp extends StatefulWidget {
  final int port;
  const VizOverlayApp({super.key, required this.port});
  @override
  State<VizOverlayApp> createState() => _VizOverlayAppState();
}

class _VizOverlayAppState extends State<VizOverlayApp> with WindowListener {
  // A bare AppState used purely as the config holder: the shared widgets
  // (OverlayWidgetView, EvsLiveViz, …) read vizType/accent/… through the
  // provider, so mirroring the main process's settings into it makes them
  // work unchanged. load() is never called and no setter ever runs here, so
  // this process never writes shared_preferences.
  AppState? _cfg;
  io.WebSocket? _ws;
  // The widget persists its OWN position (WidgetPosStore) — onWindowMoved is
  // unreliable after a native startDragging() on Windows, so poll the position
  // on a timer and write the file on any real change. _userMoved gates the
  // final flush so a widget parked on a default spot (its monitor gone) never
  // overwrites the saved location.
  Timer? _posTimer;
  Offset? _lastPollPos;
  bool _userMoved = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _boot();
  }

  Future<void> _boot() async {
    // Same portable prefs store as the main process (same exe folder → same
    // root). Read-only here, but keeps both processes pointed at one file.
    await _installPortablePrefs();
    final prefs = await SharedPreferences.getInstance();
    setState(() => _cfg = AppState(prefs));
    await _connect();
    _startPositionWatch();
  }

  void _startPositionWatch() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final p = await windowManager.getPosition();
        final last = _lastPollPos;
        final moved = last == null ||
            (p.dx - last.dx).abs() > 1 ||
            (p.dy - last.dy).abs() > 1;
        if (!moved) return;
        _lastPollPos = p;
        // Skip the first reading (the restored/parked spot); only persist once
        // the user has actually dragged the widget somewhere new. The widget
        // writes its OWN file — no round-trip through the main process.
        if (last != null) {
          _userMoved = true;
          unawaited(WidgetPosStore.writeAbsolute(p));
        }
      } catch (_) {}
    });
  }

  Future<void> _connect() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final ws = await io.WebSocket.connect('ws://127.0.0.1:${widget.port}');
        _ws = ws;
        ws.listen(_onMsg, onDone: _die, onError: (_) => _die());
        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    _die();
  }

  // The main app is gone (socket closed / never appeared) — so are we. Flush the
  // final position first (the last <500 ms of dragging the poll may have missed)
  // — but only if the user actually moved the widget, so a widget parked on a
  // default spot because its monitor is gone never overwrites the saved record.
  Future<void> _die() async {
    if (_userMoved) {
      try {
        await WidgetPosStore.writeAbsolute(await windowManager.getPosition());
      } catch (_) {}
    }
    io.exit(0);
  }

  void _onMsg(dynamic data) {
    final app = _cfg;
    if (app == null || data is! String) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'cfg':
        app.applyVizCfg(m);
        final size = (m['size'] as num?)?.toDouble();
        if (size != null) unawaited(windowManager.setSize(Size(size, size)));
        // Position is restored by the widget itself before show (WidgetPosStore)
        // — the main process no longer sends x/y in cfg.
        break;
      case 'lvl':
        VoiceLevels.instance.tts.value =
            ((m['v'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
        break;
      case 'va':
        // Mirror the main process's assistant state into this process's
        // (unattached) singletons — the shared badge/glow widgets listen to
        // exactly these notifiers.
        final s = m['s'] as String?;
        if (s != null) {
          VoiceAssistant.instance.state.value = VaState.values
              .firstWhere((e) => e.name == s, orElse: () => VaState.idle);
        }
        if (m['wake'] is bool) {
          VoiceAssistant.instance.wakeActive.value = m['wake'] as bool;
        }
        final pulse = (m['pulse'] as num?)?.toInt();
        if (pulse != null) VoiceAssistant.instance.wakePulse.value = pulse;
        break;
      case 'note':
        final ts = DateTime.now().millisecondsSinceEpoch;
        vizNotice.value = (
          (m['text'] as String?) ?? '',
          (m['kind'] as String?) ?? 'info',
          ts,
        );
        Timer(const Duration(milliseconds: 2800), () {
          if (vizNotice.value?.$3 == ts) vizNotice.value = null;
        });
        break;
      case 'bye':
        _die();
    }
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = _cfg;
    if (app == null) return const SizedBox.shrink();
    return ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
          fontFamily: 'Nunito',
        ),
        home: OverlayWidgetView(
          onOpen: () => _send({'t': 'open'}),
          onHide: () async {
            await windowManager.hide();
            _send({'t': 'hidden'});
          },
        ),
      ),
    );
  }
}

/* ============================ ЛОКАЛИЗАЦИЯ ============================ */

