import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:ffi/ffi.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:record/record.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:tray_manager/tray_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:fllama/fllama.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:system_info_plus/system_info_plus.dart';

import 'local_model_stub.dart' if (dart.library.io) 'local_model_io.dart';
// Voice visualization widget variants (self-contained CustomPainter widgets,
// adapted from user-provided LiveKit-style bars and SmoothUI Siri Orb).
import 'lk_bar_visualizer.dart';
import 'siri_orb.dart';
import 'wave_field_3d.dart';
import 'wave_field_flat.dart';

// --- Library split into physical part-files under lib/src/ (one library, so all
// private `_` visibility is preserved). See CLAUDE.md for the class→file map. ---
part 'src/app_state.dart';
part 'src/voice_viz.dart';
part 'src/desktop_settings.dart';
part 'src/chat_screen.dart';
part 'src/voice_screen.dart';
part 'src/settings_screens.dart';

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

void main(List<String> args) async {
  final startedAt = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  final isWindows = defaultTargetPlatform == TargetPlatform.windows;

  // Second-process mode: the floating visualization widget runs as its OWN
  // window/process (`evs.exe --viz-overlay --port=N`), fed by the main app
  // over a localhost WebSocket (VizOverlayServer). This way the widget truly
  // coexists with the chat window, and all the window plumbing
  // (frameless/transparent/topmost/drag) is just this process's main window.
  if (isWindows && args.contains('--viz-overlay')) {
    await _vizOverlayMain(args);
    return;
  }

  // Enforce a single running instance of the main app (widget process above is
  // exempt — it returned already).
  if (isWindows) {
    try {
      _singleInstanceLock = await io.ServerSocket.bind(
          io.InternetAddress.loopbackIPv4, _kSingleInstancePort);
      // First instance: hold the named mutex the installer looks for (AppMutex),
      // so a silent in-app update can close us via Restart Manager.
      _claimAppMutex();
      // Sole instance confirmed and no backend spawned yet: reap any backend
      // orphaned by a previous crash before it blocks the mic/port.
      await _sweepOrphanBackends();
      // We're the first instance: any later launch connects here → show window.
      _singleInstanceLock!.listen((conn) {
        conn.listen((_) {}, onError: (_) {}, cancelOnError: true);
        unawaited(DesktopIntegration.instance.showMainWindow());
        conn.destroy();
      });
    } catch (_) {
      // Port already held → another instance is running. Tell it to surface,
      // then exit without starting a duplicate.
      try {
        final s = await io.Socket.connect(
            io.InternetAddress.loopbackIPv4, _kSingleInstancePort,
            timeout: const Duration(seconds: 2));
        s.add(const [1]);
        await s.flush();
        await s.close();
      } catch (_) {}
      io.exit(0);
    }
  }

  // Portable data (when the app folder is writable): move existing engines/logs
  // next to the program, and back SharedPreferences with a file there. Both run
  // before getInstance / any data access. No-op / AppData fallback otherwise.
  if (isWindows) {
    await migrateHeavyDataIfPortable();
    await _installPortablePrefs();
  }
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(prefs);
  if (isWindows) {
    await windowManager.ensureInitialized();
    await hotKeyManager.unregisterAll();
    // Frameless window — hide the native title bar; EVS draws its own controls
    // (see _WindowTitleBar). Window stays resizable. With the widget enabled
    // (default) the chat window starts HIDDEN — only the floating widget and
    // the tray icon appear; double-click on the widget / tray opens the chat.
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(900, 600),
      center: true,
      title: 'EVS',
      titleBarStyle: TitleBarStyle.hidden,
    );
    final startHidden = prefs.getBool('overlayMode') ?? true;
    unawaited(windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Restore saved geometry before the first paint (no jump from the default
      // size to the saved one). Applied even while hidden, so a later show from
      // the tray/widget already lands at the right spot.
      await _restoreWindowBounds(prefs);
      if (startHidden) {
        // The native runner shows the window on the first frame regardless —
        // hide explicitly: with the widget enabled, only the floating widget
        // and the tray icon should be visible at startup.
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    }));
  }
  await app.load();

  if (isWindows) {
    await DesktopIntegration.instance.init(app);
  }

  final elapsed = DateTime.now().difference(startedAt);
  if (elapsed < _minSplashDuration) {
    await Future.delayed(_minSplashDuration - elapsed);
  }

  runApp(ChangeNotifierProvider.value(value: app, child: const MiraiApp()));
}

// The floating widget owns its own position, persisted to a DEDICATED file
// (userdata/widget_pos.json) written ONLY by the widget process — never through
// the shared prefs. Rationale (TZ3.3): main + widget share one prefs.json, each
// with its own in-memory cache, so a full-file _persist() from one process
// clobbers fresh values written by the other; and routing the position through
// the main app lost the last drag before shutdown when the widget was killed. A
// private file removes both problems (single writer, survives the main app
// dying). Stores absolute coords plus a best-effort monitor anchor (stable
// display id + work-area-relative offset + DPI) so a widget parked on a second
// monitor returns there after a disconnect/reconnect.
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

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'appName': 'EVS',
    // EVS desktop UI
    'yesterday': 'Вчера',
    'microphone': 'Микрофон',
    'ready': 'Готов',
    'micListening': 'Слушаю',
    'apiKeyHint': 'API-ключ (если нужен)',
    'statusLocalModel': 'Локальная нейросеть',
    'statusRemoteModel': 'Удалённая нейросеть',
    'statusOnline': 'онлайн',
    'statusConnected': 'подключена',
    'statusConnecting': 'подключение…',
    'statusNoModel': 'модель не выбрана',
    'statusDisconnected': 'не подключена',
    'statusError': 'ошибка подключения',
    'statusTitle': 'Состояние нейросети',
    'modelField': 'Модель',
    'serverField': 'Сервер',
    'navGeneral': 'Общие',
    'navGeneralSub': 'настройки приложения',
    'navVoiceInput': 'Голосовой ввод',
    'navVoiceInputSub': 'распознавание и микрофон',
    'navVoiceCommands': 'Голосовые команды',
    'navVoiceCommandsSub': 'управление компьютером',
    'navModel': 'Модель и инференс',
    'navModelSub': 'нейросеть и подключение',
    'navPersona': 'Личность и память',
    'navPersonaSub': 'персонализация ассистента',
    'navPrivacy': 'Приватность',
    'navPrivacySub': 'данные и доступ',
    'navAbout': 'О приложении',
    'navAboutSub': 'версия и обновления',
    'sectionStub': 'Раздел в разработке — скоро здесь появятся настройки.',
    'cardLangLoc': 'Язык и локализация',
    'interfaceLanguage': 'Язык интерфейса',
    'interfaceLanguageDesc': 'Язык меню, кнопок и уведомлений',
    'recognitionLanguage': 'Язык распознавания (STT)',
    'recognitionLanguageDesc': 'По умолчанию совпадает с языком интерфейса',
    'sttAuto': 'Авто',
    'cardAppearance': 'Внешний вид',
    'appStyleDesc': 'Liquid Glass — размытие и акриловые эффекты',
    'styleClassic': 'Классический',
    'fontSizeDesc': 'Влияет на размер шрифта и элементов',
    'cardStartup': 'Запуск и поведение',
    'autostart': 'Автозапуск с Windows',
    'autostartDesc': 'Запускать EVS при входе в систему',
    'minimizeToTray': 'Сворачивать в трей',
    'minimizeToTrayDesc': 'Убирать в значок при сворачивании',
    'closeToTray': 'Закрывать в трей',
    'closeToTrayDesc': 'При закрытии окна сворачивать в трей, а не выходить',
    'globalHotkey': 'Глобальная горячая клавиша',
    'globalHotkeyDesc': 'Показать окно EVS из любого приложения',
    'trayShow': 'Показать EVS',
    'trayQuit': 'Выход',
    'notifications': 'Уведомления',
    'notificationsDesc': 'Показывать системные уведомления Windows',
    'uiAnimations': 'Анимации интерфейса',
    'uiAnimationsDesc': 'Плавные переходы и эффекты',
    'sidecar': 'Голосовой движок (Python)',
    'sidecarDesc': 'Отдельный процесс EVS для Whisper, VAD и озвучки',
    'sidecarConnected': 'Подключён',
    'sidecarStarting': 'Запуск…',
    'sidecarStopped': 'Не запущен',
    'sidecarComponent': 'Компонент движка',
    'sidecarComponentDesc': 'Догружается отдельно (не входит в установщик)',
    'download': 'Скачать',
    'componentReady': 'Установлен',
    'componentVerifying': 'Проверка…',
    'cardStt': 'Движок STT',
    'sttEngine': 'Движок распознавания',
    'sttEngineDesc': 'Локальный движок (Whisper/GigaAM) работает офлайн на вашем железе',
    'localEngineName': 'Локальный (EVS)',
    'msShort': 'мс',
    'cardSttModel': 'Локальный движок',
    'engWhisperName': 'Whisper',
    'engWhisperShort': 'Мультиязычная, средняя точность',
    'engGigaamName': 'GigaAM-v3',
    'engGigaamShort': 'Лучшая точность для русского. Рекомендуется',
    'moreDetails': 'Подробнее',
    'lessDetails': 'Свернуть',
    'checkConn': 'Проверить соединение',
    'connChecking': 'Проверка…',
    'connOnline': 'Соединение есть',
    'connModelsCount': 'моделей',
    'connBadUrl': 'Укажите адрес сервера выше',
    'refreshModelsBtn': 'Обновить список',
    'cardPresets': 'Быстрые профили',
    'presetsDesc':
        'Один тап настраивает несколько параметров сразу. Тонкую настройку можно сделать ниже.',
    'presetFast': 'Быстро',
    'presetFastDesc': 'CPU · лёгкое шумоподавление · без веб-поиска',
    'presetQuality': 'Качество',
    'presetQualityDesc': 'GPU · сильное шумоподавление',
    'presetSearch': 'Поиск',
    'presetSearchDesc': 'Веб-поиск включён',
    'presetChat': 'Чат',
    'presetChatDesc': 'Веб-поиск выключен',
    'presetApplied': 'Профиль применён: {name}',
    'modelPerMode': 'Модель по режиму',
    'modelPerModeDesc':
        'Разные модели для поиска и обычного чата. Поисковая используется, когда '
            'для ответа подтянуты веб-результаты.',
    'modelForSearch': 'Для поиска',
    'modelForChat': 'Для чата',
    'modelDefaultGlobal': 'Как выбрана глобально',
    'modelNotOnServer': 'не найдена на сервере',
    'cardLlmAdv': 'Дополнительно',
    'llmAdvDesc':
        'Параметры запроса к модели. Пустое поле — параметр не отправляется, '
            'работает значение самой модели.',
    'llmNumCtx': 'Размер контекста',
    'llmNumCtxDesc': 'num_ctx — сколько токенов модель держит в контексте',
    'llmNumPredict': 'Лимит ответа',
    'llmNumPredictDesc': 'num_predict — максимальная длина ответа в токенах',
    'llmTemp': 'Температура',
    'llmTempDesc': 'temperature — 0 предсказуемо, выше — свободнее (0–1.5)',
    'llmKeepAlive': 'Держать модель в памяти',
    'llmKeepAliveDesc': 'keep_alive — например 30m или -1 (не выгружать)',
    'llmDefaultHint': 'по умолчанию',
    'llmBadNumber': 'Нужно число',
    'llmTempRange': 'Допустимо 0–1.5',
    'engWhisperDetail':
        'Понимает много языков, но короткие русские команды распознаёт хуже GigaAM. Медленнее на длинных фразах — обрабатывает звук 30-секундными окнами. base и tiny легче и быстрее, но точность ещё ниже — вариант для слабого железа.',
    'engGigaamDetail':
        'Обучена специально на русской речи, уверенно распознаёт короткие команды. ~300 МБ на диске, ~0.6–1 ГБ ОЗУ, отклик ~0.1–0.3 с. Работает только с русским языком.',
    'dnOffDetail':
        'Микрофон передаётся как есть. Подходит для тихой комнаты и хорошего микрофона; ресурсы не тратятся.',
    'dnLightDetail':
        'GTCRN — лёгкая нейросеть: убирает постоянный шум (вентиляторы, гул) и часть резких звуков. Задержка ~10 мс, нагрузка на процессор незаметна.',
    'dnStrongDetail':
        'DeepFilterNet — модель посерьёзнее: давит клавиатуру, музыку, разговоры. Ощутимо больше нагрузки на процессор, требует скачивания модели (~8 МБ). Включай, если лёгкого шумоподавления не хватает.',
    'engActive': 'Активна',
    'engReady': 'Готова',
    'engLoading': 'Загружается…',
    'engNotFound': 'Модель не найдена',
    'engSwitchFailed': 'Не удалось переключить движок',
    'engWhisperSize': 'Размер модели',
    'cardModels': 'Модели',
    'mdlInstalled': 'Установлена',
    'mdlNotInstalled': 'Не установлена',
    'mdlDownload': 'Скачать',
    'mdlOpenFolder': 'Открыть папку моделей',
    'mdlRamShort': 'МБ ОЗУ',
    'mdlActiveCantDelete': 'Нельзя удалить активную модель',
    'mdlDeleteConfirm': 'Удалить модель с диска?',
    'mdlDelete': 'Удалить',
    'mbShort': 'МБ',
    'mdlTotalDisk': 'Занято на диске',
    'cardDenoise': 'Шумоподавление',
    'mdlAdd': 'Добавить',
    'deviceLabel': 'Обработка',
    'deviceCpu': 'CPU',
    'deviceGpu': 'GPU',
    'deviceHintWhisper': 'На GPU Whisper работает в разы быстрее на длинных фразах.',
    'deviceFellBack': 'Не удалось задействовать GPU — работаю на процессоре.',
    'cardGameMode': 'Игровой режим',
    'gmFullscreen': 'Игровой режим',
    'gmFullscreenDesc': 'В полноэкранной игре переношу GPU-движки на процессор',
    'gmVram': 'Следить за видеопамятью',
    'gmVramDesc': 'Разгружать GPU, когда видеопамять почти заполнена (нужен NVIDIA)',
    'gmVramEnter': 'Порог включения',
    'gmVramExit': 'Порог выключения',
    'gmNotify': 'Голосовое уведомление',
    'gmNotifyDesc': 'Проговаривать вход/выход из разгрузки; бейдж остаётся в любом случае',
    'gmExclusions': 'Исключения',
    'gmExclusionsDesc': 'Процессы, которые полноэкранны, но не игры (видеоплеер и т.п.)',
    'gmExclAdd': 'Добавить процесс',
    'gmOffloadActive': 'Сейчас активна разгрузка GPU — движки на процессоре.',
    'gmOffloadBadge': 'Разгрузка GPU',
    'gmReasonFullscreen': 'полноэкранный режим',
    'gmReasonVram': 'заполнена видеопамять',
    'gmNotifyFullscreen': 'Обнаружен полноэкранный режим — переключаюсь на процессор',
    'gmNotifyVram': 'Видеопамять почти заполнена — переключаюсь на процессор',
    'gmNotifyExit': 'Возвращаю настройки',
    'extraMics': 'Дополнительные микрофоны',
    'extraMicsDesc': 'Слушать сразу с нескольких микрофонов (например, в разных комнатах). Одна фраза, услышанная несколькими, выполнится один раз.',
    'micSelfCleaningHint': 'У этого микрофона своё шумоподавление — встроенное отключено, чтобы не обрабатывать звук дважды.',
    'dnOff': 'Выкл',
    'dnLight': 'Лёгкое',
    'dnStrong': 'Сильное',
    'dnOffShort': 'Микрофон как есть — для тихой комнаты и хорошего микрофона.',
    'dnLightShort':
        'Убирает фоновый шум, почти не тратит ресурсы. Рекомендуется.',
    'dnStrongShort':
        'Максимальное подавление: клавиатура, музыка, разговоры. Дороже по CPU.',
    'dnNotInstalled': 'Модель не скачана — откройте раздел «Модели».',
    'whisperOffline': 'Whisper (офлайн)',
    'whisperModel': 'Модель Whisper',
    'whisperModelDesc':
        'Влияет на качество и скорость. Внимание: medium на CPU обрабатывает '
            'фразу ~минуту — ассистент будет казаться мёртвым. Рекомендуется small',
    'cardInputDevice': 'Устройство ввода',
    'inputDevice': 'Устройство ввода',
    'inputDeviceDesc': 'Микрофон, используемый для записи',
    'defaultDevice': 'По умолчанию',
    'micTest': 'Тест микрофона',
    'micTestDesc': 'Проверьте уровень и качество сигнала',
    'runTest': 'Запустить тест',
    'inputLevel': 'Уровень входного сигнала',
    'cardListenMode': 'Режим прослушивания',
    'activationMode': 'Режим активации',
    'activationModeDesc': 'Push-to-talk требует удержания клавиши',
    'continuous': 'Непрерывное',
    'autoSendPause': 'Авто-отправка по паузе',
    'autoSendPauseDesc': 'Отправлять текст автоматически после тишины',
    'pauseDuration': 'Длительность паузы',
    'pauseDurationDesc': 'Через сколько секунд считать фразу завершённой',
    'secShort': 'с',
    'showPartial': 'Показывать частичный текст',
    'showPartialDesc': 'Отображать распознанное прямо во время речи',
    'cardVoiceViz': 'Визуализация голоса',
    'vizType': 'Тип визуализации',
    'vizTypeDesc': 'Анимация, реагирующая на уровень голоса',
    'vizSphere': 'Сфера',
    'vizWaves': 'Волны',
    'vizBars': 'Бары',
    'vizNone': 'Нет',
    'navWidgets': 'Виджеты',
    'navWidgetsSub': 'визуализация и оверлей',
    'cardWsPreview': 'Предпросмотр',
    'cardWsStyle': 'Стиль виджета',
    'cardWsParams': 'Параметры',
    'vizOrb': 'Siri Orb',
    'vizLkBars': 'Полоски',
    'vizWave3d': 'Волны 3D',
    'vizWaveFlat': 'Поле частиц',
    'settingsUnsaved': 'Есть несохранённые изменения',
    'settingsSaved': 'Настройки применены и сохранены',
    'settingsSaveFailed':
        'Не удалось применить настройки. Возвращены прежние значения',
    'settingsExitTitle': 'Сохранить изменения?',
    'settingsExitSave': 'Сохранить',
    'settingsExitDiscard': 'Не сохранять',
    'settingsExitStay': 'Остаться',
    'wsAccent': 'Акцентный цвет',
    'wsAccentDesc': 'Цвет Siri Orb и Полосок',
    'wsOrbSize': 'Размер орба',
    'wsOrbSpeed': 'Скорость вращения',
    'wsOrbSpeedDesc': 'Секунд на полный оборот',
    'wsFast': 'быстро',
    'wsSlow': 'медленно',
    'wsBarCount': 'Количество полосок',
    'wsSimVoice': 'Имитация голоса',
    'wsStateIdle': 'Ожидание',
    'wsStateListening': 'Слушает',
    'wsStateSpeaking': 'Говорит',
    'wsStateThinking': 'Думает',
    'ovlEnter': 'Плавающий виджет',
    'ovlEnterDesc':
        'Визуализация в маленьком прозрачном окне поверх всех окон. '
            'Двойной клик по виджету — вернуться в чат',
    'ovlShow': 'Показывать виджет',
    'ovlSize': 'Размер виджета',
    'ovlSizeDesc': 'Размер плавающего окна с визуализацией',
    'ovlSizeS': 'Маленький',
    'ovlSizeM': 'Средний',
    'ovlSizeL': 'Большой',
    'ovlOpenChat': 'Открыть EVS',
    'ovlHide': 'Скрыть виджет',
    'trayOverlay': 'Плавающий виджет',
    'showVizBg': 'Показывать в фоне',
    'showVizBgDesc': 'Отображать визуализацию на главном экране',
    'cardVoiceResp': 'Голос ответа',
    'voiceResponses': 'Озвучивать ответы',
    'voiceResponsesDesc': 'Проговаривать ответы ассистента голосом',
    'announceReady': 'Озвучивать готовность',
    'announceReadyDesc': 'Произносить голосом, когда ассистент готов слушать',
    'ttsEngineTitle': 'Движок озвучки',
    'ttsEnginePiper': 'Piper',
    'ttsEnginePiperHint': 'быстро, офлайн, CPU',
    'ttsEngineCosy': 'CosyVoice',
    'ttsEngineCosyHint': 'качество, GPU',
    'ttsCosyUnavailable': 'CosyVoice недоступен — сервер не отвечает',
    'ttsCosyEndpoint': 'Endpoint CosyVoice',
    'ttsCosyCheck': 'Проверить соединение',
    'ttsCosyOnline': 'На связи',
    'ttsCosyOffline': 'Не отвечает',
    'ttsCosyFellBack': 'CosyVoice недоступен — озвучка переключена на Piper',
    'ttsCosyChecking': 'Проверка…',
    'ttsCosyWiringHint':
        'Настройки сохраняются. Синтез через CosyVoice подключится, когда сервер будет развёрнут.',
    'ttsCosyVoice': 'Голос / пресет',
    'ttsCosyVoiceHint': 'ID пресета (spk_id) — для моделей SFT. Необязательно.',
    'ttsCosyClone': 'Клонировать по образцу',
    'ttsCosyClonePick': 'Выбрать WAV…',
    'ttsCosyCloneNone': 'Образец не выбран',
    'ttsCosyClonePrompt': 'Текст в образце',
    'ttsCosyClonePromptHint': 'Что произнесено в WAV-образце (нужно для клонирования).',
    'ttsCosySpeed': 'Скорость',
    'ttsCosyEmotion': 'Эмоция',
    'ttsCosyEmotionNeutral': 'Нейтрально',
    'ttsCosyEmotionHappy': 'Радостно',
    'ttsCosyEmotionSad': 'Грустно',
    'ttsCosyEmotionSerious': 'Строго',
    'ttsCosyEmotionCalm': 'Спокойно',
    'ttsCosyEmotionExcited': 'Воодушевлённо',
    'ttsCosyInstruct': 'Инструкция (свободный текст)',
    'ttsCosyInstructHint': 'Своя инструкция стиля/эмоции — переопределяет пресет.',
    'ttsCosyDevice': 'Устройство синтеза',
    'ttsInterp': 'Интерпретатор озвучки',
    'ttsInterpDesc':
        'Приводит текст к произносимому виду перед синтезом: числа и даты словами, '
            'без эмодзи и разметки.',
    'ttsInterpRules': 'Правилами',
    'ttsInterpRulesHint': 'Быстро, офлайн',
    'ttsInterpModel': 'Через модель',
    'ttsInterpModelHint': 'Точнее, но медленнее и нужен сервер',
    'ttsInterpModelField': 'Модель интерпретатора',
    'ttsInterpFellBack':
        'Модель интерпретатора недоступна — озвучиваю по правилам.',
    'readyGreeting': 'Готова слушать',
    'sttStarting': 'Запуск…',
    'sttLoadingModels': 'Загружаю модели…',
    'sttReadyMsg': 'Готова слушать',
    'sttErrorState': 'Ошибка запуска распознавания',
    'ttsRate': 'Скорость речи',
    'ttsRateDesc': 'Темп проговаривания',
    'ttsVolume': 'Громкость',
    'cardAssistantVoice': 'Голос ассистента',
    'voiceSystemName': 'Системный голос (без скачивания)',
    'voiceSystemDesc': 'Звучит машинно, зато работает сразу — без загрузок.',
    'voiceListen': 'Прослушать',
    'voiceSelect': 'Выбрать',
    'voiceSamplePhrase': 'Привет! Я EVS, твой голосовой ассистент.',
    'voiceIrina': 'Женский голос, среднее качество (Piper).',
    'voiceDenis': 'Мужской голос, среднее качество (Piper).',
    'voiceDmitri': 'Мужской голос, среднее качество (Piper).',
    'voiceRuslan': 'Мужской голос, среднее качество (Piper).',
    'cardCmdExec': 'Выполнение команд',
    'cmdAllow': 'Разрешить выполнение команд',
    'cmdAllowDesc':
        'EVS сможет запускать приложения, открывать сайты и управлять системой',
    'cardCmdRecognition': 'Распознавание команд',
    'cmdMode': 'Режим распознавания',
    'cmdModeDesc': 'Как EVS понимает, что это команда, а не текст для ввода',
    'cmdModeWake': 'Слово-активатор',
    'cmdModeSeparate': 'Отдельный режим',
    'cmdModeFirst': 'Сначала команда',
    'cmdActivator': 'Слово-активатор',
    'cmdActivatorDesc': 'Скажите «EVS» перед командой, напр. «EVS, открой браузер»',
    'cmdStopWords': 'Слова остановки',
    'cmdStopWordsDesc': 'Через запятую. Прервут озвучку и генерацию (напр. «стоп, хватит, отмена»)',
    'saveServerBtn': 'Сохранить адрес',
    'vaListening': 'Слушаю…',
    'vaThinking': 'Думаю…',
    'vaRunning': 'Выполняю…',
    'vaDone': 'Готово',
    'vaFailed': 'Не удалось выполнить команду',
    'vaCmdDisabled': 'Команда распознана, но выполнение выключено (включите «Разрешить выполнение команд»)',
    'vaCmdNotFound': 'Команда не найдена',
    'chatToggle': 'Чат',
    'chatToggleDesc': 'Выключите, чтобы работали только команды: нераспознанная фраза не уйдёт в чат, а ответит «Команда не найдена». Текстовый ввод при этом отключается.',
    'chatDisabledHint': 'Чат отключён — работают только голосовые команды',
    'vaSttOffline': 'Голосовой движок не подключён',
    'updRestart': 'Перезапустить',
    'updUpToDate': 'Актуальная версия',
    'updReadyShort': 'Обновление',
    'updFlowDesc': 'Обновление скачается в фоне — останется перезапустить',
    'updAvailableTitle': 'Доступно обновление',
    'updDialogHint': 'Обновление уже скачано. Перезапустите EVS, чтобы применить.',
    'updLater': 'Позже',
    'updFailedApply': 'Обновление не установилось. Закройте EVS полностью и попробуйте снова.',
    'updApplied': 'EVS обновлён до {v}',
    'updFailedManual': 'Автообновление до {v} не установилось. Скачайте установщик вручную.',
    'updDownloadManual': 'Скачать',
    'webSearch': 'Веб-поиск',
    'webSearchEnable': 'Искать в интернете',
    'webSearchDesc': 'Ассистент найдёт свежие данные (курс, погода, новости), когда вопрос этого требует.',
    'webSearchKeysHint': 'Работает без ключа (DuckDuckGo). Ключ Tavily или Brave — стабильнее и качественнее.',
    'webSearchTavily': 'Tavily API-ключ (необязательно)',
    'webSearchBrave': 'Brave API-ключ (необязательно)',
    'webSearching': '🔎 Ищу в интернете…',
    'vaWakeHeard': 'услышал, говорите!',
    'vaArmed': 'Говорите команду…',
    'vaCmdUnknown': 'Команду не понял',
    'vaStopped': 'Остановлено',
    'vaConfirmTitle': 'Выполнить команду?',
    'vaConfirmBody': 'EVS распознал команду:',
    'cardSecurity': 'Безопасность',
    'cmdThreshold': 'Порог совпадения фразы',
    'cmdThresholdDesc': 'Насколько точно фраза должна совпасть с командой',
    'cmdConfirm': 'Подтверждение перед выполнением',
    'cmdConfirmAlways': 'Всегда',
    'cmdConfirmRisky': 'Только опасные',
    'cmdConfirmNever': 'Никогда',
    'cardCatalog': 'Каталог команд',
    'cmdEmpty': 'Пока нет команд — добавьте первую.',
    'cmdAdd': 'Добавить команду',
    'cmdPhrase': 'Фраза-триггер',
    'cmdValue': 'Значение (путь, URL, действие)',
    'next': 'Далее',
    'cmdWizType': 'Что добавить?',
    'cmdWizProgram': 'Программа',
    'cmdWizFile': 'Файл',
    'cmdWizSite': 'Сайт',
    'cmdWizSystem': 'Система',
    'cmdWizMedia': 'Медиа',
    'cmdSuggest': 'Предложить команды',
    'cmdSuggestTitle': 'Предложенные команды',
    'cmdSuggestScanning': 'Сканирую приложения и подбираю фразы…',
    'cmdSuggestEmpty': 'Не нашлось новых приложений для команд.',
    'cmdSuggestSaveSel': 'Сохранить выбранные',
    'cmdSuggestCollision': 'Фраза уже используется',
    'cmdSuggestFreq': 'часто',
    'cmdSuggestPrivacy':
        'Имена приложений уходят только в вашу локальную модель. Пути берутся из системы, ИИ их не трогает.',
    'cmdSuggestSaved': 'Добавлено команд: {n}',
    'cmdOnboardTitle': 'Голосовые команды для ваших приложений',
    'cmdOnboardBody':
        'EVS может просмотреть установленные приложения и предложить готовые голосовые команды для их запуска. Список можно отредактировать перед сохранением.',
    'cmdOnboardYes': 'Подобрать команды',
    'navRemote': 'Телефоны',
    'navRemoteSub': 'удалённый ввод с телефона',
    'remoteCardListener': 'Удалённый ввод',
    'remoteEnable': 'Принимать команды с телефонов',
    'remoteEnableDesc':
        'Локальный слушатель по Tailscale/LAN. Наружу порт не публикуется; команды принимаются только от привязанных устройств.',
    'remotePort': 'Порт',
    'remoteServerOff': 'Слушатель выключен',
    'remoteServerOn': 'Слушает',
    'remotePortBusy': 'Порт занят — смените порт',
    'remoteAddress': 'Адрес для подключения',
    'remoteResponse': 'Куда отдавать ответ',
    'remoteRespDesktop': 'Озвучивать на десктопе',
    'remoteRespPhone': 'Текст на телефон',
    'remoteRespBoth': 'Оба',
    'remoteCardDevices': 'Подключённые телефоны',
    'remoteNoDevices': 'Пока нет привязанных телефонов',
    'remoteCardAdd': 'Добавить телефон',
    'remotePairCode': 'Код сопряжения',
    'remotePairHint':
        'Введите этот код (или отсканируйте QR) в приложении на телефоне. Действует 5 минут.',
    'remoteNewCode': 'Обновить код',
    'remoteScanQr': 'QR для подключения',
    'remoteUnpair': 'Отвязать',
    'remotePermVoice': 'Голос',
    'remotePermText': 'Текст',
    'remoteOnline': 'в сети',
    'remoteLastSeen': 'был(а) в сети',
    'remoteNever': 'ещё не подключался',
    'remoteEnableFirst': 'Сначала включите приём команд',
    'cmdWizVolume': 'Громкость приложения',
    'volPickApp': 'Приложение (из воспроизводящих сейчас)',
    'volNoSessions':
        'Нет приложений, воспроизводящих звук. Запустите нужное (например, музыку) и обновите список.',
    'volAction': 'Действие',
    'volActSet': 'Установить',
    'volActInc': 'Прибавить',
    'volActDec': 'Убавить',
    'volActMute': 'Заглушить',
    'volActUnmute': 'Вернуть звук',
    'volDefault': 'Значение по умолчанию',
    'cmdWizPickProgram': 'Выберите программу',
    'cmdWizPickExe': 'Выбрать файл вручную…',
    'cmdWizNoPrograms': 'Программы не найдены',
    'cmdWizSearch': 'Поиск…',
    'cmdWizPhrase': 'Фраза-триггер',
    'cmdWizPhraseHint': 'Скажите эту фразу, чтобы выполнить',
    'cmdWizSpeak': 'Фраза для озвучки (необязательно)',
    'cmdWizSpeakHint': 'например: Открываю Яндекс Музыку',
    'sysLock': 'Блокировка экрана',
    'sysSleep': 'Спящий режим',
    'sysVolUp': 'Громкость +',
    'sysVolDown': 'Громкость −',
    'sysMute': 'Без звука',
    'mediaPlay': 'Плей / Пауза',
    'mediaNext': 'Следующий трек',
    'mediaPrev': 'Предыдущий трек',
    'sttTest': 'Тест распознавания',
    'sttTestDesc': 'Произнесите фразу и посмотрите, как её записал распознаватель — удобно, чтобы подобрать фразу-триггер.',
    'sttTestStart': 'Начать тест',
    'sttTestStop': 'Остановить',
    'sttTestHint': 'Скажите что-нибудь — здесь появится распознанный текст…',
    'sttTestClear': 'Очистить',
    'run': 'Запустить',
    'cmdRunTitle': 'Выполнить команду?',
    'cmdRunOk': 'Команда выполнена',
    'cmdRunFail': 'Не удалось выполнить команду',
    'typeApp': 'Приложение',
    'typeFile': 'Файл',
    'typeWeb': 'Сайт',
    'typeSystem': 'Системное',
    'typeMedia': 'Медиа',
    'typeAppVolume': 'Громкость',
    'volNotPlaying': '{app} сейчас не воспроизводит звук',
    'volNoNumber': 'Не расслышал число',
    'volSet': 'Громкость {app}: {N}%',
    'add': 'Добавить',
    'cardConnMode': 'Режим подключения',
    'modeOnDevice': 'Локально на устройстве (on-device)',
    'modeOnDeviceDesc':
        'Модель работает прямо на вашем компьютере. Максимальная приватность, нет зависимости от сети.',
    'modeLocalServer': 'Локальный сервер (Ollama / LAN)',
    'modeLocalServerDesc':
        'Подключение к серверу в локальной сети. Данные не выходят за пределы вашей сети.',
    'modeRemote': 'Удалённый сервер (OpenAI-совместимый)',
    'modeRemoteDesc':
        'Запросы уходят в интернет. Поддерживаются любые OpenAI-совместимые API.',
    'cardModelPick': 'Выбор модели',
    'noModelsYet': 'Нет загруженных моделей — скачайте модель ниже.',
    'modelActive': 'активна',
    'cardGenParams': 'Параметры генерации',
    'temperatureDesc': 'Выше — креативнее, ниже — точнее',
    'topPDesc': 'Вероятностный порог выборки токенов',
    'cardStyle': 'Стиль ответов',
    'formality': 'Формальность',
    'formalLeft': 'Официально',
    'formalRight': 'Дружески',
    'empathy': 'Эмпатия',
    'empathyLeft': 'Нейтрально',
    'empathyRight': 'Высокая',
    'verbosity': 'Многословность',
    'verbosityLeft': 'Лаконично',
    'verbosityRight': 'Подробно',
    'humor': 'Юмор',
    'humorLeft': 'Серьёзно',
    'humorRight': 'С юмором',
    'creativity': 'Креативность',
    'creativityLeft': 'Буквально',
    'creativityRight': 'Творчески',
    'cardAssistant': 'Личность ассистента',
    'assistantNameLabel': 'Имя ассистента',
    'assistantNameDesc': 'Как ассистент будет называть себя',
    'emojiPolicy': 'Политика эмодзи',
    'emojiPolicyDesc': 'Как часто использовать эмодзи в ответах',
    'emojiNever': 'Никогда',
    'emojiSometimes': 'Иногда',
    'emojiAlways': 'Часто',
    'cardMemory': 'Память',
    'autoSaveFacts': 'Автосохранение фактов',
    'autoSaveFactsDesc': 'EVS сам запоминает важные детали из разговора',
    'askBeforeRemember': 'Спрашивать перед «Запомнить»',
    'askBeforeRememberDesc': 'Показывать запрос перед добавлением воспоминания',
    'clearMemory': 'Очистить память',
    'cardCmdScope': 'Область действия команд',
    'permFiles': 'Файлы и папки',
    'permBrowser': 'Браузер и сайты',
    'permMedia': 'Медиа и звук',
    'permSystem': 'Системные настройки',
    'permNetwork': 'Сетевые запросы',
    'permRegistry': 'Реестр Windows',
    'cardNetSec': 'Сетевая безопасность',
    'offlineMode': 'Офлайн-режим',
    'offlineModeDesc': 'Запретить все сетевые запросы (модель + обновления)',
    'noTelemetry': 'Запретить телеметрию',
    'noTelemetryDesc': 'Не отправлять анонимную статистику использования',
    'noModelNet': 'Запретить сетевые запросы модели',
    'noModelNetDesc': 'Только локальный инференс, без API',
    'cardBlacklist': 'Чёрный список фраз',
    'cardData': 'Данные и конфиденциальность',
    'clearHistory': 'Очистить историю чатов',
    'clearHistoryDesc':
        'Удалить все сеансы и переписки без возможности восстановления',
    'resetMemory': 'Сбросить память и профиль',
    'resetMemoryDesc': 'Удалить все воспоминания, профиль пользователя и заметку',
    'resetAll': 'Сбросить все настройки',
    'resetAllDesc': 'Вернуть EVS к заводским настройкам. Действие необратимо.',
    'fullReset': 'Полный сброс',
    'versionLabel': 'Версия',
    'platform': 'Платформа',
    'changelog': 'Список изменений',
    'updates': 'Обновления',
    'autoCheck': 'Автоматическая проверка',
    'autoCheckDesc': 'Проверять обновления при запуске',
    'checkNow': 'Проверить сейчас',
    'checkUpdate': 'Обновить',
    'howCanIHelp': 'Чем могу помочь?',
    'subtitle':
        'Приватный ИИ для письма, планирования, кода и повседневных вопросов.',
    'askAnything': 'Спросите что угодно',
    'summarize': 'Кратко',
    'rewrite': 'Переписать',
    'fixGrammar': 'Грамматика',
    'downloadedModels': 'Доступные модели',
    'manageModels': 'Управление моделями',
    'newChat': 'Новый чат',
    'createImage': 'Создать изображение',
    'createImageHint':
        'Создание изображения — отправьте запрос модели изображений',
    'loadingModels': 'Загрузка моделей…',
    'loadingShort': 'Загрузка',
    'gettingReady': 'Готовим…',
    'loadingYourModel': 'Загружаем модель — секунду.',
    'preparingModel': 'Подготовка модели',
    'noModelsFound': 'Модели не найдены',
    'noModelsAvailable': 'Нет доступных моделей',
    'refreshModels': 'Обновить список моделей',
    'mute': 'Выкл. микрофон',
    'unmute': 'Вкл. микрофон',
    'listening': 'Внимательно слушаю…',
    'preparingMic': 'Подключение микрофона…',
    'micUnavailable': 'Не удалось подключить микрофон',
    'micUnavailableDesc':
        'Проверьте разрешение на запись звука и подключение к интернету, затем попробуйте снова.',
    'retry': 'Повторить',
    'muted': 'Микрофон выключен',
    'micSettingsTitle': 'Настройки микрофона',
    'micAutoSend': 'Автоотправка после паузы',
    'micAutoSendDesc': 'Сообщение отправится само, как только вы замолчите',
    'micPauseDuration': 'Длительность паузы перед отправкой',
    'send': 'Отправить',
    'speakNaturally':
        'Говорите свободно. EVS ответит, как только вы сделаете паузу.',
    'conversations': 'Беседы',
    'chats': 'Чаты',
    'chatsDesc':
        'Здесь хранятся ваши недавние диалоги, готовые продолжиться в любой момент.',
    'chatsLabel': 'ЧАТЫ',
    'pinnedLabel': 'ЗАКРЕПЛЁННЫЕ',
    'latestLabel': 'ПОСЛЕДНИЙ',
    'noChatsYet': 'Чатов пока нет',
    'startFresh': 'Начните новый пустой диалог.',
    'continueSection': 'Продолжить',
    'latestConversation': 'ПОСЛЕДНИЙ ДИАЛОГ',
    'resume': 'Возобновить',
    'recent': 'Недавние',
    'noChatsDesc':
        'Как только вы начнёте общение, история диалогов появится здесь.',
    'startNewChat': 'Начать новый чат',
    'searchChats': 'Поиск по чатам и сообщениям',
    'messages': 'сообщений',
    'pin': 'Закрепить',
    'unpin': 'Открепить',
    'delete': 'Удалить',
    'chatDeleted': 'Чат удалён',
    'undo': 'Отменить',
    'rename': 'Переименовать',
    'renameChat': 'Переименовать чат',
    'renameChatHint': 'Название чата',
    'msgCopy': 'Копировать',
    'msgEdit': 'Редактировать',
    'msgRegenerate': 'Перегенерировать',
    'msgContinue': 'Продолжить',
    'msgUseInComposer': 'Использовать в поле ввода',
    'msgRemember': 'Запомнить',
    'msgForgetMemory': 'Забыть связанное воспоминание',
    'msgPinContext': 'Закрепить в контексте чата',
    'msgUnpinContext': 'Открепить из контекста чата',
    'msgCopied': 'Скопировано',
    'msgRemembered': 'Добавлено в память',
    'msgForgotten': 'Воспоминание забыто',
    'msgPinned': 'Закреплено в контексте чата',
    'msgUnpinned': 'Откреплено из контекста чата',
    'savedMemoriesSection': 'Сохранённые воспоминания',
    'noSavedMemories': 'Пока нет сохранённых воспоминаний.',
    'pinnedMessagesSection': 'Закреплённые сообщения',
    'noPinnedMessages': 'Пока нет закреплённых сообщений.',
    'justNow': 'только что',
    'minAgo': 'мин назад',
    'hAgo': 'ч назад',
    'dAgo': 'дн назад',
    'settings': 'Настройки',
    'settingsDesc':
        'Настройте EVS, управляйте поведением приложения и просматривайте сведения в одном месте.',
    'sectionApp': 'Приложение',
    'sectionTheme': 'Оформление',
    'sectionAbout': 'О приложении',
    'checkForUpdates': 'Проверить обновления',
    'downloadingUpdate': 'Скачивание обновления…',
    'updateAvailable': 'Доступно обновление',
    'upToDate': 'У вас последняя версия',
    'updateCheckFailed': 'Не удалось проверить обновления',
    'updateDownloadFailed': 'Не удалось скачать обновление',
    'downloadUpdateNow': 'Скачать и установить',
    'later': 'Позже',
    'aboutVersion': 'О версии',
    'whatsNewTitle': 'Что нового в версии',
    'gotIt': 'Понятно',
    'manageModelsItem': 'Управление моделями',
    'localModelsItem': 'Локальные модели',
    'localModelsTitle': 'Локальные модели',
    'localModelsDesc':
        'Скачайте модель прямо на устройство и общайтесь с ней без подключения к серверу.',
    'tierLight': 'Лёгкие',
    'tierLightDesc': 'Для слабых/старых телефонов (32-бит ARM, мало ОЗУ)',
    'tierMid': 'Средние',
    'tierMidDesc':
        'Для современных смартфонов среднего класса (например, Honor 70)',
    'tierHigh': 'Мощные',
    'tierHighDesc':
        'Для флагманов с большим запасом ОЗУ (например, iPhone 15 Pro Max)',
    'tierRoleplay': 'Для ролевой игры',
    'tierRoleplayDesc':
        'Файнтюны на ролевых/литературных диалогах, а не только на ассистентских задачах',
    'onDevice': 'на устройстве',
    'downloadModel': 'Скачать',
    'downloadingModel': 'Загрузка…',
    'cancelDownload': 'Отмена',
    'useModel': 'Использовать',
    'modelInUse': 'Используется',
    'deleteModel': 'Удалить',
    'localModelMissing':
        'Файл модели не найден. Скачайте модель ещё раз в разделе «Локальные модели».',
    'modelCrashWarn':
        'Локальная модель вызвала сбой при загрузке и отключена:',
    'deleteLocalModelTitle': 'Удалить модель?',
    'deleteLocalModelBody':
        'Файл модели будет удалён с устройства. Скачать её снова можно в любой момент.',
    'personalization': 'Персонализация',
    'memory': 'Память',
    'rpMode': 'Режим ролевой игры',
    'rpModeOn': 'Режим ролевой игры включён для этого чата',
    'rpModeOff': 'Режим ролевой игры выключен для этого чата',
    'rpEnableDesc':
        'Заменяет обычный системный промпт на персонажа из этой вкладки и фиксирует модель за этим чатом.',
    'stopGeneration': 'Остановить генерацию',
    'tabRoleplay': 'Ролевая игра',
    'rpDesc':
        'Имена персонажей, сценарий, параметры генерации и блокнот мира для этого чата.',
    'rpModelLocked': 'Модель зафиксирована для этого чата',
    'rpModelLockedToast':
        'Модель этого чата зафиксирована при включении режима ролевой игры и не меняется внутри сессии.',
    'rpMyCharacter': 'Мой персонаж',
    'rpMyCharacterDesc': 'Кто вы в этой истории — имя и описание вашего персонажа.',
    'rpAiRole': 'Роль ИИ',
    'rpAiRoleDesc': 'Кем должна быть нейросеть в этом чате — имя и личность персонажа.',
    'rpUserName': 'Ваше имя',
    'rpUserDescription': 'Описание вашего персонажа',
    'rpUserDescriptionDesc':
        'Кто ваш персонаж — внешность, характер, роль в истории. Модель учитывает это, обращаясь к вам, но играет не за вас.',
    'rpUserDescriptionHint':
        'Опишите своего персонажа. Доступны {{user}} и {{char}}.',
    'rpAiName': 'Имя персонажа ИИ',
    'rpScenarioSection': 'Сценарий',
    'systemPrompt': 'Системный промпт / личность персонажа',
    'systemPromptDesc':
        'Главное описание персонажа — голос, характер, манера речи. Заменяет обычный системный промпт личности в этом чате.',
    'rpSystemPromptHint':
        'Опишите персонажа от первого лица. Доступны {{user}} и {{char}}.',
    'rpPlaceholderExampleTitle': 'Пример',
    'rpPlaceholderExample':
        '«Ты — {{char}}, бывалый капитан космического корабля. Ты называешь {{user}} новым членом экипажа и общаешься с ним грубовато, но по-доброму.» При ответе модель сама заменит {{user}} и {{char}} на имена из полей выше.',
    'scenario': 'Сценарий / окружение',
    'scenarioDesc':
        'Вступление и контекст истории — обстановка, в которой начинается диалог.',
    'rpScenarioHint': 'С чего начинается история?',
    'rpSampling': 'Параметры генерации',
    'rpTemperature': 'Температура',
    'rpTemperatureDesc':
        'Выше — более случайные и неожиданные ответы, ниже — более предсказуемые.',
    'rpTopP': 'Top-P',
    'rpTopPDesc':
        'Отсекает менее вероятные варианты слов; меньшее значение — более предсказуемый текст.',
    'rpRepetitionPenalty': 'Штраф за повторение',
    'rpRepetitionPenaltyDesc':
        'Снижает шанс, что модель повторяет одни и те же фразы.',
    'rpMaxTokens': 'Длина ответа',
    'rpMaxTokensDesc': 'Примерный потолок длины одного ответа.',
    'rpPresetShort': 'Коротко (150)',
    'rpPresetMedium': 'Средне (300)',
    'rpPresetLong': 'Роман (600)',
    'rpPresetEpic': 'Эпопея (1000)',
    'rpLorebook': 'Блокнот мира',
    'rpLorebookEnable': 'Блокнот мира (Lorebook)',
    'rpLorebookDesc':
        'Статьи с ключевыми словами подмешиваются в промпт, когда упоминаются в чате.',
    'rpLorebookKeywords': 'Ключевые слова, через запятую',
    'rpLorebookContent': 'Описание для промпта',
    'rpLorebookAddEntry': 'Добавить статью',
    'rpStopSequences': 'Стоп-последовательности',
    'rpStopSequencesDesc':
        'Генерация останавливается, как только модель выводит один из этих фрагментов текста.',
    'rpStopSequenceHint': 'Введите текст и нажмите Enter',
    'rpContextWindow': 'Лимит контекста',
    'rpContextWindowDesc':
        'Сколько последних сообщений чата помещается в запрос к модели за один раз.',
    'rpContextFull':
        'Контекст этого чата почти заполнен — можно сжать старую историю в краткое резюме.',
    'rpCompressButton': 'Сжать память чата',
    'language': 'Язык',
    'serverAddress': 'Адрес сервера',
    'showKeyboard': 'Клавиатура при запуске',
    'haptics': 'Виброотклик',
    'themeMode': 'Тема',
    'themeSystem': 'Системная',
    'themeLight': 'Светлая',
    'themeDark': 'Тёмная',
    'themeClaude': 'Claude',
    'themeClaudeDark': 'Claude (тёмная)',
    'themeGray': 'Серая',
    'appStyle': 'Стиль приложения',
    'appStyleDialogTitle': 'Стиль приложения',
    'appStyleStandard': 'Обычный',
    'appStyleGlass': 'Liquid Glass',
    'showChips': 'Показывать подсказки',
    'fontSize': 'Размер шрифта',
    'deleteHistory': 'Удалить историю диалогов',
    'terms': 'Условия использования',
    'privacy': 'Политика конфиденциальности',
    'licenses': 'Лицензии',
    'cantUndo': 'Это действие нельзя отменить.',
    'cancel': 'Отмена',
    'save': 'Сохранить',
    'done': 'Готово',
    'reset': 'Сбросить',
    'serverDialogTitle': 'Подключение к нейросети',
    'serverUrlLabel': 'Адрес (IP:порт или https://...)',
    'serverUrlHint': 'например 192.168.1.100:11434 или https://api.site.com',
    'apiKeyOptional': 'API-ключ (необязательно)',
    'languageDialogTitle': 'Выбор языка',
    'russian': 'Русский',
    'english': 'English',
    'addModelHint': 'Добавьте модель вручную',
    'attachFile': 'Прикрепить файл',
    'fileAttached': 'Файл прикреплён',
    'imageNotSupportedWarning':
        'Эта модель не понимает изображения — увидит только имя файла.',
    'recentPhotos': 'Недавние',
    'noRecentPhotos': 'Нет недавних фото',
    'photoAccessDenied':
        'Нет доступа к галерее. Разрешите доступ к фото в настройках устройства.',
    'attachTabGallery': 'Галерея',
    'attachTabFile': 'Файл',
    'serverError': 'Ошибка сервера',
    'unreachable': 'Не удалось подключиться к серверу',
    'checkAddress': 'Проверьте адрес в настройках.',
    'pers': 'Персонализация',
    'chatPers': 'Настройки этого чата',
    'tabPersonality': 'Личность',
    'tabMemory': 'Память',
    'persDesc': 'Настройте личность, поведение и контекст ассистента под себя.',
    'memoryDesc':
        'Управляйте тем, что EVS запоминает о вас, и сколько контекста диалога видят локальные модели.',
    'persPersona': 'Личность и стиль общения',
    'persPreset': 'Готовая персона',
    'persPresetDesc':
        'Шаблон стиля общения — мгновенно подстраивает черты характера и тон ниже.',
    'preset_friend': 'Лучший друг',
    'preset_mentor': 'Наставник / Коуч',
    'preset_expert': 'Эксперт',
    'preset_creative': 'Креативный партнёр',
    'preset_custom': 'Свой стиль',
    'slidersTitle': 'Черты характера',
    'sl_formality': 'Формальность',
    'sl_formalityDesc': 'Насколько официально или непринуждённо звучит ответ.',
    'sl_empathy': 'Эмпатия',
    'sl_empathyDesc': 'Тёплый и поддерживающий тон — или сухой и по делу.',
    'sl_verbosity': 'Детализация',
    'sl_verbosityDesc':
        'Подробные объяснения — или короткие ответы по существу.',
    'sl_humor': 'Юмор',
    'sl_humorDesc': 'Насколько уместны шутки и игривость.',
    'sl_creativity': 'Креативность',
    'sl_creativityDesc':
        'Привычные ответы — или нестандартные идеи и сравнения.',
    'speechStyle': 'Стиль речи',
    'emojiUsage': 'Эмодзи',
    'emojiUsageDesc': 'Как часто в ответах появляются эмодзи.',
    'emoji_never': 'Никогда',
    'emoji_sometimes': 'Иногда',
    'emoji_always': 'Всегда',
    'answerFormat': 'Формат ответов',
    'answerFormatDesc':
        'Обычный текст, списки или таблицы, когда это подходит по смыслу.',
    'fmt_plain': 'Обычный текст',
    'fmt_lists': 'Списки',
    'fmt_tables': 'Таблицы где можно',
    'persBehavior': 'Функциональность и поведение',
    'defaultLength': 'Длина ответа по умолчанию',
    'defaultLengthDesc': 'Целевая длина ответа, если вы не уточнили иначе.',
    'len_short': 'Короткая',
    'len_normal': 'Стандартная',
    'len_long': 'Развёрнутая',
    'proactivity': 'Проактивность',
    'proactivityDesc':
        'Отвечать только на вопрос, переспрашивать при неясности или предлагать смежные темы.',
    'pro_answer': 'Только отвечать',
    'pro_clarify': 'Задавать уточнения',
    'pro_suggest': 'Предлагать темы',
    'useMarkdown': 'Использовать markdown-разметку',
    'useMarkdownDesc': 'Заголовки, списки и выделение текста в ответах.',
    'memorySection': 'Память и контекст',
    'longMemory': 'Долговременная память',
    'longMemoryDesc': 'Учитывать заметку ниже при ответах ассистента.',
    'memoryNote': 'Запомни обо мне, что…',
    'autoSaveMemories': 'Автосохранение полезных деталей',
    'autoSaveMemoriesDesc':
        'После каждого ответа тихо спрашивать модель, стоит ли запомнить что-то устойчивое: предпочтения, факты профиля, текущие задачи.',
    'askBeforeRemembering': 'Спрашивать перед сохранением',
    'askBeforeRememberingDesc':
        'Выбирать категорию воспоминания при сохранении сообщения вручную.',
    'deleteAllMemories': 'Удалить все воспоминания',
    'deleteAllMemoriesDesc': 'Очистить все сохранённые воспоминания на устройстве.',
    'deleteAllMemoriesConfirm':
        'Все сохранённые воспоминания будут удалены без возможности восстановления.',
    'chooseMemoryCategory': 'Выберите категорию воспоминания',
    'memCatPreference': 'Предпочтение',
    'memCatProfile': 'Профиль',
    'memCatProject': 'Проект',
    'memCatOther': 'Другое',
    'contextSize': 'Размер контекста',
    'contextSizeDesc':
        'Сколько диалога помнит локальная модель. Больше — лучше память, но выше нагрузка на устройство и медленнее ответы.',
    'contextSizeMaxFor': 'Максимум для',
    'contextSizeMaxForDevice': 'Максимум для этого устройства',
    'contextSizeMovedToRp':
        'Для этого чата размер контекста настраивается во вкладке «Ролевая игра» — там же, где лимит контекста и параметры генерации.',
    'persProfile': 'О вас',
    'name': 'Имя',
    'pronouns': 'Местоимения',
    'profession': 'Профессия',
    'interests': 'Интересы и хобби',
    'goals': 'Цели',
    'useMyData': 'Использовать мои данные для ответов',
    'useMyDataDesc': 'Имя, профессия, интересы и другие поля из этого раздела.',
    'knowledgeLevel': 'Уровень знаний',
    'kl_beginner': 'Новичок',
    'kl_student': 'Студент',
    'kl_expert': 'Эксперт',
    'location': 'Местоположение (город / часовой пояс)',
    'persSafety': 'Безопасность и границы',
    'avoidTopics': 'Темы для избегания',
    'contentFilter': 'Фильтр контента',
    'cf_strict': 'Строгий',
    'cf_balanced': 'Сбалансированный',
    'cf_off': 'Без фильтра',
    'warnUncertain': 'Предупреждать о неуверенности и чувствительных темах',
    'warnUncertainDesc': 'Честно говорить, когда ассистент не уверен в ответе.',
    'localDataTitle': 'Персонализация хранится локально на устройстве',
    'localDataDesc':
        'Имя, заметки и настройки личности не уходят на сервер — они используются только для построения промпта, который видит модель.',
    'persAdvanced': 'Продвинутые настройки',
    'reasoning': 'Стиль мышления',
    'reasoningDesc':
        'Отвечать сразу или сначала рассуждать пошагово, показывая ход мысли.',
    'rs_fast': 'Быстрый и интуитивный',
    'rs_step': 'Пошаговое рассуждение',
    'toneTitle': 'Тон в тексте',
    'toneTitleDesc': 'Общая эмоциональная окраска текста ответов.',
    'tone_neutral': 'Нейтральный',
    'tone_sarcastic': 'Саркастичный',
    'tone_melancholic': 'Меланхоличный',
    'tone_excited': 'Восторженный',
    'customPrompt': 'Свой системный промпт',
    'customPromptDesc':
        'Добавляется в конец системного промпта — для правил, которых нет среди настроек выше.',
    'customPromptHint': 'Прямая инструкция ассистенту…',
  },
  'en': {
    'appName': 'EVS',
    // EVS desktop UI
    'yesterday': 'Yesterday',
    'microphone': 'Microphone',
    'ready': 'Ready',
    'micListening': 'Listening',
    'apiKeyHint': 'API key (if required)',
    'statusLocalModel': 'Local model',
    'statusRemoteModel': 'Remote model',
    'statusOnline': 'online',
    'statusConnected': 'connected',
    'statusConnecting': 'connecting…',
    'statusNoModel': 'no model selected',
    'statusDisconnected': 'not connected',
    'statusError': 'connection error',
    'statusTitle': 'Model status',
    'modelField': 'Model',
    'serverField': 'Server',
    'navGeneral': 'General',
    'navGeneralSub': 'application settings',
    'navVoiceInput': 'Voice input',
    'navVoiceInputSub': 'recognition & microphone',
    'navVoiceCommands': 'Voice commands',
    'navVoiceCommandsSub': 'computer control',
    'navModel': 'Model & inference',
    'navModelSub': 'neural net & connection',
    'navPersona': 'Personality & memory',
    'navPersonaSub': 'assistant personalization',
    'navPrivacy': 'Privacy',
    'navPrivacySub': 'data & access',
    'navAbout': 'About',
    'navAboutSub': 'version & updates',
    'sectionStub': 'Section under construction — settings coming soon.',
    'cardLangLoc': 'Language & localization',
    'interfaceLanguage': 'Interface language',
    'interfaceLanguageDesc': 'Language of menus, buttons and notifications',
    'recognitionLanguage': 'Recognition language (STT)',
    'recognitionLanguageDesc': 'Defaults to the interface language',
    'sttAuto': 'Auto',
    'cardAppearance': 'Appearance',
    'appStyleDesc': 'Liquid Glass — blur and acrylic effects',
    'styleClassic': 'Classic',
    'fontSizeDesc': 'Affects font and element sizes',
    'cardStartup': 'Startup & behavior',
    'autostart': 'Launch at startup',
    'autostartDesc': 'Start EVS when you sign in',
    'minimizeToTray': 'Minimize to tray',
    'minimizeToTrayDesc': 'Hide to the tray icon when minimized',
    'closeToTray': 'Close to tray',
    'closeToTrayDesc': 'Closing the window hides to tray instead of quitting',
    'globalHotkey': 'Global hotkey',
    'globalHotkeyDesc': 'Show the EVS window from any application',
    'trayShow': 'Show EVS',
    'trayQuit': 'Quit',
    'notifications': 'Notifications',
    'notificationsDesc': 'Show Windows system notifications',
    'uiAnimations': 'UI animations',
    'uiAnimationsDesc': 'Smooth transitions and effects',
    'sidecar': 'Voice engine (Python)',
    'sidecarDesc': 'Separate EVS process for Whisper, VAD and TTS',
    'sidecarConnected': 'Connected',
    'sidecarStarting': 'Starting…',
    'sidecarStopped': 'Stopped',
    'sidecarComponent': 'Engine component',
    'sidecarComponentDesc': 'Downloaded separately (not in the installer)',
    'download': 'Download',
    'componentReady': 'Installed',
    'componentVerifying': 'Verifying…',
    'cardStt': 'STT engine',
    'sttEngine': 'Recognition engine',
    'sttEngineDesc': 'The local engine (Whisper/GigaAM) runs offline on your hardware',
    'localEngineName': 'Local (EVS)',
    'msShort': 'ms',
    'cardSttModel': 'Local engine',
    'engWhisperName': 'Whisper',
    'engWhisperShort': 'Multilingual, average accuracy',
    'engGigaamName': 'GigaAM-v3',
    'engGigaamShort': 'Best accuracy for Russian. Recommended',
    'moreDetails': 'More',
    'lessDetails': 'Less',
    'checkConn': 'Check connection',
    'connChecking': 'Checking…',
    'connOnline': 'Connected',
    'connModelsCount': 'models',
    'connBadUrl': 'Enter the server address above',
    'refreshModelsBtn': 'Refresh list',
    'cardPresets': 'Quick profiles',
    'presetsDesc':
        'One tap sets several options at once. Fine-tune below afterwards.',
    'presetFast': 'Fast',
    'presetFastDesc': 'CPU · light denoise · no web search',
    'presetQuality': 'Quality',
    'presetQualityDesc': 'GPU · strong denoise',
    'presetSearch': 'Search',
    'presetSearchDesc': 'Web search on',
    'presetChat': 'Chat',
    'presetChatDesc': 'Web search off',
    'presetApplied': 'Profile applied: {name}',
    'modelPerMode': 'Model per mode',
    'modelPerModeDesc':
        'Separate models for search and ordinary chat. The search model is used '
            'when live web results are pulled into the answer.',
    'modelForSearch': 'For search',
    'modelForChat': 'For chat',
    'modelDefaultGlobal': 'As selected globally',
    'modelNotOnServer': 'not on server',
    'cardLlmAdv': 'Advanced',
    'llmAdvDesc': 'Request parameters for the model. A blank field is not sent '
        'at all — the model\'s own default applies.',
    'llmNumCtx': 'Context size',
    'llmNumCtxDesc': 'num_ctx — how many tokens the model keeps in context',
    'llmNumPredict': 'Response limit',
    'llmNumPredictDesc': 'num_predict — maximum response length in tokens',
    'llmTemp': 'Temperature',
    'llmTempDesc': 'temperature — 0 is predictable, higher is freer (0–1.5)',
    'llmKeepAlive': 'Keep model loaded',
    'llmKeepAliveDesc': 'keep_alive — e.g. 30m, or -1 to never unload',
    'llmDefaultHint': 'default',
    'llmBadNumber': 'Must be a number',
    'llmTempRange': 'Allowed 0–1.5',
    'engWhisperDetail':
        'Understands many languages, but recognizes short Russian commands worse than GigaAM. Slower on long phrases — it processes audio in 30-second windows. base and tiny are lighter and faster but less accurate — for weak hardware.',
    'engGigaamDetail':
        'Trained specifically on Russian speech; confidently recognizes short commands. ~300 MB on disk, ~0.6–1 GB RAM, ~0.1–0.3 s latency. Russian only.',
    'dnOffDetail':
        'The microphone is passed through untouched. Good for a quiet room and a decent mic; costs nothing.',
    'dnLightDetail':
        'GTCRN — a lightweight neural net: removes constant noise (fans, hum) and some sharp sounds. ~10 ms latency, negligible CPU.',
    'dnStrongDetail':
        'DeepFilterNet — a heavier model: suppresses keyboard, music, conversations. Noticeably more CPU and needs a model download (~8 MB). Use it when light suppression is not enough.',
    'engActive': 'Active',
    'engReady': 'Ready',
    'engLoading': 'Loading…',
    'engNotFound': 'Model not found',
    'engSwitchFailed': 'Could not switch engine',
    'engWhisperSize': 'Model size',
    'cardModels': 'Models',
    'mdlInstalled': 'Installed',
    'mdlNotInstalled': 'Not installed',
    'mdlDownload': 'Download',
    'mdlOpenFolder': 'Open models folder',
    'mdlRamShort': 'MB RAM',
    'mdlActiveCantDelete': "Can't delete the active model",
    'mdlDeleteConfirm': 'Delete this model from disk?',
    'mdlDelete': 'Delete',
    'mbShort': 'MB',
    'mdlTotalDisk': 'Disk used',
    'cardDenoise': 'Noise suppression',
    'mdlAdd': 'Add',
    'deviceLabel': 'Processing',
    'deviceCpu': 'CPU',
    'deviceGpu': 'GPU',
    'deviceHintWhisper': 'On the GPU, Whisper is much faster on long phrases.',
    'deviceFellBack': 'Could not use the GPU — running on the CPU.',
    'cardGameMode': 'Game mode',
    'gmFullscreen': 'Game mode',
    'gmFullscreenDesc': 'Move GPU engines to the CPU while a fullscreen game is up',
    'gmVram': 'Watch video memory',
    'gmVramDesc': 'Offload the GPU when VRAM is nearly full (needs NVIDIA)',
    'gmVramEnter': 'Engage threshold',
    'gmVramExit': 'Release threshold',
    'gmNotify': 'Voice notification',
    'gmNotifyDesc': 'Speak on entering/leaving offload; the badge stays regardless',
    'gmExclusions': 'Exclusions',
    'gmExclusionsDesc': 'Processes that are fullscreen but not games (video player, etc.)',
    'gmExclAdd': 'Add process',
    'gmOffloadActive': 'GPU offload is active — engines are on the CPU.',
    'gmOffloadBadge': 'GPU offload',
    'gmReasonFullscreen': 'fullscreen mode',
    'gmReasonVram': 'video memory full',
    'gmNotifyFullscreen': 'Fullscreen mode detected — switching to the processor',
    'gmNotifyVram': 'Video memory is nearly full — switching to the processor',
    'gmNotifyExit': 'Restoring settings',
    'extraMics': 'Additional microphones',
    'extraMicsDesc': 'Listen on several microphones at once (e.g. in different rooms). One phrase heard by several runs only once.',
    'micSelfCleaningHint': 'This microphone has its own noise suppression — the built-in one is off so audio isn\'t processed twice.',
    'dnOff': 'Off',
    'dnLight': 'Light',
    'dnStrong': 'Strong',
    'dnOffShort': 'Mic as-is — for a quiet room and a good microphone.',
    'dnLightShort':
        'Removes background noise, barely uses resources. Recommended.',
    'dnStrongShort':
        'Maximum suppression: keyboard, music, chatter. Heavier on CPU.',
    'dnNotInstalled': 'Model not downloaded — open the Models section.',
    'whisperOffline': 'Whisper (offline)',
    'whisperModel': 'Whisper model',
    'whisperModelDesc':
        'Affects quality and speed. Warning: medium takes ~a minute per '
            'utterance on CPU — the assistant will feel dead. Small is recommended',
    'cardInputDevice': 'Input device',
    'inputDevice': 'Input device',
    'inputDeviceDesc': 'Microphone used for recording',
    'defaultDevice': 'Default',
    'micTest': 'Microphone test',
    'micTestDesc': 'Check the level and signal quality',
    'runTest': 'Run test',
    'inputLevel': 'Input signal level',
    'cardListenMode': 'Listening mode',
    'activationMode': 'Activation mode',
    'activationModeDesc': 'Push-to-talk requires holding a key',
    'continuous': 'Continuous',
    'autoSendPause': 'Auto-send on pause',
    'autoSendPauseDesc': 'Send text automatically after silence',
    'pauseDuration': 'Pause duration',
    'pauseDurationDesc': 'How many seconds of silence end a phrase',
    'secShort': 's',
    'showPartial': 'Show partial text',
    'showPartialDesc': 'Display recognized text live while speaking',
    'cardVoiceViz': 'Voice visualization',
    'vizType': 'Visualization type',
    'vizTypeDesc': 'Animation reacting to your voice level',
    'vizSphere': 'Sphere',
    'vizWaves': 'Waves',
    'vizBars': 'Bars',
    'vizNone': 'None',
    'navWidgets': 'Widgets',
    'navWidgetsSub': 'visualization & overlay',
    'cardWsPreview': 'Preview',
    'cardWsStyle': 'Widget style',
    'cardWsParams': 'Parameters',
    'vizOrb': 'Siri Orb',
    'vizLkBars': 'Stripes',
    'vizWave3d': 'Waves 3D',
    'vizWaveFlat': 'Particle field',
    'settingsUnsaved': 'You have unsaved changes',
    'settingsSaved': 'Settings applied and saved',
    'settingsSaveFailed': 'Could not apply settings. Previous values restored',
    'settingsExitTitle': 'Save changes?',
    'settingsExitSave': 'Save',
    'settingsExitDiscard': "Don't save",
    'settingsExitStay': 'Stay',
    'wsAccent': 'Accent color',
    'wsAccentDesc': 'Color of the Siri Orb and Stripes',
    'wsOrbSize': 'Orb size',
    'wsOrbSpeed': 'Rotation speed',
    'wsOrbSpeedDesc': 'Seconds per full turn',
    'wsFast': 'fast',
    'wsSlow': 'slow',
    'wsBarCount': 'Number of bars',
    'wsSimVoice': 'Voice simulation',
    'wsStateIdle': 'Idle',
    'wsStateListening': 'Listening',
    'wsStateSpeaking': 'Speaking',
    'wsStateThinking': 'Thinking',
    'ovlEnter': 'Floating widget',
    'ovlEnterDesc':
        'The visualization in a small transparent always-on-top window. '
            'Double-click the widget to return to the chat',
    'ovlShow': 'Show the widget',
    'ovlSize': 'Widget size',
    'ovlSizeDesc': 'Size of the floating visualization window',
    'ovlSizeS': 'Small',
    'ovlSizeM': 'Medium',
    'ovlSizeL': 'Large',
    'ovlOpenChat': 'Open EVS',
    'ovlHide': 'Hide widget',
    'trayOverlay': 'Floating widget',
    'showVizBg': 'Show in background',
    'showVizBgDesc': 'Display the visualization on the home screen',
    'cardVoiceResp': 'Voice response',
    'voiceResponses': 'Speak responses',
    'voiceResponsesDesc': 'Read the assistant\'s replies aloud',
    'announceReady': 'Announce readiness',
    'announceReadyDesc': 'Say aloud when the assistant is ready to listen',
    'ttsEngineTitle': 'Voice engine',
    'ttsEnginePiper': 'Piper',
    'ttsEnginePiperHint': 'fast, offline, CPU',
    'ttsEngineCosy': 'CosyVoice',
    'ttsEngineCosyHint': 'quality, GPU',
    'ttsCosyUnavailable': 'CosyVoice unavailable — server not responding',
    'ttsCosyEndpoint': 'CosyVoice endpoint',
    'ttsCosyCheck': 'Check connection',
    'ttsCosyOnline': 'Online',
    'ttsCosyOffline': 'Not responding',
    'ttsCosyFellBack': 'CosyVoice unavailable — switched to Piper',
    'ttsCosyChecking': 'Checking…',
    'ttsCosyWiringHint':
        'Settings are saved. CosyVoice synthesis connects once the server is deployed.',
    'ttsCosyVoice': 'Voice / preset',
    'ttsCosyVoiceHint': 'Preset id (spk_id) — for SFT models. Optional.',
    'ttsCosyClone': 'Clone from sample',
    'ttsCosyClonePick': 'Choose WAV…',
    'ttsCosyCloneNone': 'No sample chosen',
    'ttsCosyClonePrompt': 'Text in the sample',
    'ttsCosyClonePromptHint': 'What is spoken in the WAV sample (needed for cloning).',
    'ttsCosySpeed': 'Speed',
    'ttsCosyEmotion': 'Emotion',
    'ttsCosyEmotionNeutral': 'Neutral',
    'ttsCosyEmotionHappy': 'Happy',
    'ttsCosyEmotionSad': 'Sad',
    'ttsCosyEmotionSerious': 'Serious',
    'ttsCosyEmotionCalm': 'Calm',
    'ttsCosyEmotionExcited': 'Excited',
    'ttsCosyInstruct': 'Instruction (free text)',
    'ttsCosyInstructHint': 'Your own style/emotion instruction — overrides the preset.',
    'ttsCosyDevice': 'Synthesis device',
    'ttsInterp': 'Speech interpreter',
    'ttsInterpDesc':
        'Rewrites text into a speakable form before synthesis: numbers and dates '
            'as words, no emoji or markup.',
    'ttsInterpRules': 'Rules',
    'ttsInterpRulesHint': 'Fast, offline',
    'ttsInterpModel': 'Via model',
    'ttsInterpModelHint': 'More accurate but slower, needs a server',
    'ttsInterpModelField': 'Interpreter model',
    'ttsInterpFellBack':
        'Interpreter model unavailable — speaking with rules.',
    'readyGreeting': 'Ready to listen',
    'sttStarting': 'Starting…',
    'sttLoadingModels': 'Loading models…',
    'sttReadyMsg': 'Ready to listen',
    'sttErrorState': 'Speech engine failed to start',
    'ttsRate': 'Speech rate',
    'ttsRateDesc': 'Speaking tempo',
    'ttsVolume': 'Volume',
    'cardAssistantVoice': 'Assistant voice',
    'voiceSystemName': 'System voice (no download)',
    'voiceSystemDesc': 'Sounds robotic, but works instantly — no downloads.',
    'voiceListen': 'Listen',
    'voiceSelect': 'Select',
    'voiceSamplePhrase': 'Hello! I am EVS, your voice assistant.',
    'voiceIrina': 'Female voice, medium quality (Piper).',
    'voiceDenis': 'Male voice, medium quality (Piper).',
    'voiceDmitri': 'Male voice, medium quality (Piper).',
    'voiceRuslan': 'Male voice, medium quality (Piper).',
    'cardCmdExec': 'Command execution',
    'cmdAllow': 'Allow command execution',
    'cmdAllowDesc':
        'EVS can launch apps, open sites and control the system',
    'cardCmdRecognition': 'Command recognition',
    'cmdMode': 'Recognition mode',
    'cmdModeDesc': 'How EVS tells a command apart from dictation',
    'cmdModeWake': 'Wake word',
    'cmdModeSeparate': 'Separate mode',
    'cmdModeFirst': 'Command first',
    'cmdActivator': 'Wake word',
    'cmdActivatorDesc': 'Say “EVS” before a command, e.g. “EVS, open browser”',
    'cmdStopWords': 'Stop words',
    'cmdStopWordsDesc': 'Comma-separated. Interrupt speech and generation (e.g. “stop, cancel, quiet”)',
    'saveServerBtn': 'Save address',
    'vaListening': 'Listening…',
    'vaThinking': 'Thinking…',
    'vaRunning': 'Running…',
    'vaDone': 'Done',
    'vaFailed': 'Could not run the command',
    'vaCmdDisabled': 'Command recognized, but execution is off (enable "Allow command execution")',
    'vaCmdNotFound': 'Command not found',
    'chatToggle': 'Chat',
    'chatToggleDesc': 'Turn off for commands only: an unrecognized phrase won\'t go to chat, it answers "Command not found". Text input is disabled too.',
    'chatDisabledHint': 'Chat is off — voice commands only',
    'vaSttOffline': 'Voice engine not connected',
    'updRestart': 'Restart',
    'updUpToDate': 'Up to date',
    'updReadyShort': 'Update',
    'updFlowDesc': 'Downloads in the background — just restart to apply',
    'updAvailableTitle': 'Update available',
    'updDialogHint': 'The update is already downloaded. Restart EVS to apply.',
    'updLater': 'Later',
    'updFailedApply': 'The update did not install. Fully close EVS and try again.',
    'updApplied': 'EVS updated to {v}',
    'updFailedManual': 'Auto-update to {v} did not install. Download the installer manually.',
    'updDownloadManual': 'Download',
    'webSearch': 'Web search',
    'webSearchEnable': 'Search the web',
    'webSearchDesc': 'The assistant fetches fresh info (rates, weather, news) when a question needs it.',
    'webSearchKeysHint': 'Works without a key (DuckDuckGo). A Tavily or Brave key is more reliable and higher quality.',
    'webSearchTavily': 'Tavily API key (optional)',
    'webSearchBrave': 'Brave API key (optional)',
    'webSearching': '🔎 Searching the web…',
    'vaWakeHeard': 'heard you, go ahead!',
    'vaArmed': 'Say the command…',
    'vaCmdUnknown': 'Could not understand the command',
    'vaStopped': 'Stopped',
    'vaConfirmTitle': 'Run command?',
    'vaConfirmBody': 'EVS recognized a command:',
    'cardSecurity': 'Security',
    'cmdThreshold': 'Phrase match threshold',
    'cmdThresholdDesc': 'How closely a phrase must match a command',
    'cmdConfirm': 'Confirm before running',
    'cmdConfirmAlways': 'Always',
    'cmdConfirmRisky': 'Risky only',
    'cmdConfirmNever': 'Never',
    'cardCatalog': 'Command catalog',
    'cmdEmpty': 'No commands yet — add the first one.',
    'cmdAdd': 'Add command',
    'cmdPhrase': 'Trigger phrase',
    'cmdValue': 'Value (path, URL, action)',
    'next': 'Next',
    'cmdWizType': 'What to add?',
    'cmdWizProgram': 'Program',
    'cmdWizFile': 'File',
    'cmdWizSite': 'Website',
    'cmdWizSystem': 'System',
    'cmdWizMedia': 'Media',
    'cmdSuggest': 'Suggest commands',
    'cmdSuggestTitle': 'Suggested commands',
    'cmdSuggestScanning': 'Scanning apps and drafting phrases…',
    'cmdSuggestEmpty': 'No new apps to make commands for.',
    'cmdSuggestSaveSel': 'Save selected',
    'cmdSuggestCollision': 'Phrase already in use',
    'cmdSuggestFreq': 'frequent',
    'cmdSuggestPrivacy':
        'Only app names go to your local model. Paths come from the system; the AI never touches them.',
    'cmdSuggestSaved': 'Commands added: {n}',
    'cmdOnboardTitle': 'Voice commands for your apps',
    'cmdOnboardBody':
        'EVS can look through your installed apps and suggest ready-made voice commands to launch them. You can edit the list before saving.',
    'cmdOnboardYes': 'Suggest commands',
    'navRemote': 'Phones',
    'navRemoteSub': 'remote input from a phone',
    'remoteCardListener': 'Remote input',
    'remoteEnable': 'Accept commands from phones',
    'remoteEnableDesc':
        'Local listener over Tailscale/LAN. The port is not exposed to the internet; only paired devices may send commands.',
    'remotePort': 'Port',
    'remoteServerOff': 'Listener off',
    'remoteServerOn': 'Listening',
    'remotePortBusy': 'Port is busy — change it',
    'remoteAddress': 'Connection address',
    'remoteResponse': 'Where to send the reply',
    'remoteRespDesktop': 'Speak on desktop',
    'remoteRespPhone': 'Text back to phone',
    'remoteRespBoth': 'Both',
    'remoteCardDevices': 'Connected phones',
    'remoteNoDevices': 'No paired phones yet',
    'remoteCardAdd': 'Add a phone',
    'remotePairCode': 'Pairing code',
    'remotePairHint':
        'Enter this code (or scan the QR) in the phone app. Valid for 5 minutes.',
    'remoteNewCode': 'New code',
    'remoteScanQr': 'QR to connect',
    'remoteUnpair': 'Unpair',
    'remotePermVoice': 'Voice',
    'remotePermText': 'Text',
    'remoteOnline': 'online',
    'remoteLastSeen': 'last seen',
    'remoteNever': 'never connected',
    'remoteEnableFirst': 'Enable command receiving first',
    'cmdWizVolume': 'App volume',
    'volPickApp': 'App (from those playing now)',
    'volNoSessions':
        'No apps are playing sound. Start one (e.g. music) and refresh the list.',
    'volAction': 'Action',
    'volActSet': 'Set',
    'volActInc': 'Increase',
    'volActDec': 'Decrease',
    'volActMute': 'Mute',
    'volActUnmute': 'Unmute',
    'volDefault': 'Default value',
    'cmdWizPickProgram': 'Pick a program',
    'cmdWizPickExe': 'Choose a file manually…',
    'cmdWizNoPrograms': 'No programs found',
    'cmdWizSearch': 'Search…',
    'cmdWizPhrase': 'Trigger phrase',
    'cmdWizPhraseHint': 'Say this phrase to run it',
    'cmdWizSpeak': 'Phrase to speak (optional)',
    'cmdWizSpeakHint': 'e.g. Opening Yandex Music',
    'sysLock': 'Lock screen',
    'sysSleep': 'Sleep',
    'sysVolUp': 'Volume +',
    'sysVolDown': 'Volume −',
    'sysMute': 'Mute',
    'mediaPlay': 'Play / Pause',
    'mediaNext': 'Next track',
    'mediaPrev': 'Previous track',
    'sttTest': 'Recognition test',
    'sttTestDesc': 'Say a phrase and see how the recognizer wrote it — handy for designing a trigger phrase.',
    'sttTestStart': 'Start test',
    'sttTestStop': 'Stop',
    'sttTestHint': 'Say something — the recognized text appears here…',
    'sttTestClear': 'Clear',
    'run': 'Run',
    'cmdRunTitle': 'Run this command?',
    'cmdRunOk': 'Command executed',
    'cmdRunFail': 'Command failed',
    'typeApp': 'App',
    'typeFile': 'File',
    'typeWeb': 'Site',
    'typeSystem': 'System',
    'typeMedia': 'Media',
    'typeAppVolume': 'Volume',
    'volNotPlaying': '{app} is not playing any sound right now',
    'volNoNumber': "I didn't catch a number",
    'volSet': '{app} volume: {N}%',
    'add': 'Add',
    'cardConnMode': 'Connection mode',
    'modeOnDevice': 'On-device (local)',
    'modeOnDeviceDesc':
        'The model runs right on your PC. Maximum privacy, no network dependency.',
    'modeLocalServer': 'Local server (Ollama / LAN)',
    'modeLocalServerDesc':
        'Connect to a server on your local network. Data stays inside your network.',
    'modeRemote': 'Remote server (OpenAI-compatible)',
    'modeRemoteDesc':
        'Requests go to the internet. Any OpenAI-compatible API is supported.',
    'cardModelPick': 'Model selection',
    'noModelsYet': 'No downloaded models — download one below.',
    'modelActive': 'active',
    'cardGenParams': 'Generation parameters',
    'temperatureDesc': 'Higher — more creative, lower — more precise',
    'topPDesc': 'Probability threshold for token sampling',
    'cardStyle': 'Reply style',
    'formality': 'Formality',
    'formalLeft': 'Formal',
    'formalRight': 'Friendly',
    'empathy': 'Empathy',
    'empathyLeft': 'Neutral',
    'empathyRight': 'High',
    'verbosity': 'Verbosity',
    'verbosityLeft': 'Concise',
    'verbosityRight': 'Detailed',
    'humor': 'Humor',
    'humorLeft': 'Serious',
    'humorRight': 'Playful',
    'creativity': 'Creativity',
    'creativityLeft': 'Literal',
    'creativityRight': 'Creative',
    'cardAssistant': 'Assistant personality',
    'assistantNameLabel': 'Assistant name',
    'assistantNameDesc': 'What the assistant calls itself',
    'emojiPolicy': 'Emoji policy',
    'emojiPolicyDesc': 'How often to use emoji in replies',
    'emojiNever': 'Never',
    'emojiSometimes': 'Sometimes',
    'emojiAlways': 'Often',
    'cardMemory': 'Memory',
    'autoSaveFacts': 'Auto-save facts',
    'autoSaveFactsDesc': 'EVS remembers important details from the conversation',
    'askBeforeRemember': 'Ask before “Remember”',
    'askBeforeRememberDesc': 'Show a prompt before adding a memory',
    'clearMemory': 'Clear memory',
    'cardCmdScope': 'Command scope',
    'permFiles': 'Files & folders',
    'permBrowser': 'Browser & sites',
    'permMedia': 'Media & sound',
    'permSystem': 'System settings',
    'permNetwork': 'Network requests',
    'permRegistry': 'Windows registry',
    'cardNetSec': 'Network security',
    'offlineMode': 'Offline mode',
    'offlineModeDesc': 'Block all network requests (model + updates)',
    'noTelemetry': 'Disable telemetry',
    'noTelemetryDesc': 'Do not send anonymous usage statistics',
    'noModelNet': 'Disable model network',
    'noModelNetDesc': 'Local inference only, no API',
    'cardBlacklist': 'Phrase blacklist',
    'cardData': 'Data & privacy',
    'clearHistory': 'Clear chat history',
    'clearHistoryDesc': 'Delete all sessions and chats permanently',
    'resetMemory': 'Reset memory & profile',
    'resetMemoryDesc': 'Delete all memories, the user profile and the note',
    'resetAll': 'Reset all settings',
    'resetAllDesc': 'Return EVS to factory defaults. This cannot be undone.',
    'fullReset': 'Full reset',
    'versionLabel': 'Version',
    'platform': 'Platform',
    'changelog': 'Changelog',
    'updates': 'Updates',
    'autoCheck': 'Automatic check',
    'autoCheckDesc': 'Check for updates on launch',
    'checkNow': 'Check now',
    'checkUpdate': 'Update',
    'howCanIHelp': 'How can I help?',
    'subtitle':
        'Private AI for writing, planning, coding, and everyday questions.',
    'askAnything': 'Ask anything',
    'summarize': 'Summarize',
    'rewrite': 'Rewrite',
    'fixGrammar': 'Fix Grammar',
    'downloadedModels': 'Downloaded Models',
    'manageModels': 'Manage Models',
    'newChat': 'New Chat',
    'createImage': 'Create Image',
    'createImageHint': 'Create Image — send a request to an image model',
    'loadingModels': 'Loading models…',
    'loadingShort': 'Loading',
    'gettingReady': 'Getting ready…',
    'loadingYourModel': 'Loading your model — just a moment.',
    'preparingModel': 'Preparing model',
    'noModelsFound': 'No models found',
    'noModelsAvailable': 'No models available',
    'refreshModels': 'Refresh model list',
    'mute': 'Mute',
    'unmute': 'Unmute',
    'listening': 'Listening carefully…',
    'preparingMic': 'Connecting microphone…',
    'micUnavailable': 'Couldn\'t connect to the microphone',
    'micUnavailableDesc':
        'Check the microphone permission and your internet connection, then try again.',
    'retry': 'Retry',
    'muted': 'Muted',
    'micSettingsTitle': 'Microphone settings',
    'micAutoSend': 'Auto-send after pause',
    'micAutoSendDesc': 'The message sends itself as soon as you go quiet',
    'micPauseDuration': 'Pause duration before sending',
    'send': 'Send',
    'speakNaturally':
        'Speak naturally. EVS will respond as soon as you pause.',
    'conversations': 'Conversations',
    'chats': 'Chats',
    'chatsDesc':
        'Your recent work lives here, ready to resume whenever you are.',
    'chatsLabel': 'CHATS',
    'pinnedLabel': 'PINNED',
    'latestLabel': 'LATEST',
    'noChatsYet': 'No chats yet',
    'startFresh': 'Start fresh with an empty thread.',
    'continueSection': 'Continue',
    'latestConversation': 'LATEST CONVERSATION',
    'resume': 'Resume',
    'recent': 'Recent',
    'noChatsDesc':
        'Once you start chatting, your local conversation history will show up here.',
    'startNewChat': 'Start New Chat',
    'searchChats': 'Search chats and messages',
    'messages': 'messages',
    'pin': 'Pin',
    'unpin': 'Unpin',
    'delete': 'Delete',
    'chatDeleted': 'Chat deleted',
    'undo': 'Undo',
    'rename': 'Rename',
    'renameChat': 'Rename chat',
    'renameChatHint': 'Chat name',
    'msgCopy': 'Copy',
    'msgEdit': 'Edit',
    'msgRegenerate': 'Regenerate',
    'msgContinue': 'Continue',
    'msgUseInComposer': 'Use in composer',
    'msgRemember': 'Remember this',
    'msgForgetMemory': 'Forget related memory',
    'msgPinContext': 'Pin to chat context',
    'msgUnpinContext': 'Unpin from chat context',
    'msgCopied': 'Copied',
    'msgRemembered': 'Added to memory',
    'msgForgotten': 'Memory forgotten',
    'msgPinned': 'Pinned to chat context',
    'msgUnpinned': 'Unpinned from chat context',
    'savedMemoriesSection': 'Saved memories',
    'noSavedMemories': 'No saved memories yet.',
    'pinnedMessagesSection': 'Pinned messages',
    'noPinnedMessages': 'No pinned messages yet.',
    'justNow': 'just now',
    'minAgo': 'm ago',
    'hAgo': 'h ago',
    'dAgo': 'd ago',
    'settings': 'Settings',
    'settingsDesc':
        'Personalize EVS, manage device behavior, and review the app details in one place.',
    'sectionApp': 'App',
    'sectionTheme': 'Theme',
    'sectionAbout': 'About',
    'checkForUpdates': 'Check for updates',
    'downloadingUpdate': 'Downloading update…',
    'updateAvailable': 'Update available',
    'upToDate': 'You have the latest version',
    'updateCheckFailed': 'Failed to check for updates',
    'updateDownloadFailed': 'Failed to download update',
    'downloadUpdateNow': 'Download and install',
    'later': 'Later',
    'aboutVersion': 'About version',
    'whatsNewTitle': "What's new in version",
    'gotIt': 'Got it',
    'manageModelsItem': 'Manage models',
    'localModelsItem': 'Local models',
    'localModelsTitle': 'Local models',
    'localModelsDesc':
        'Download a model straight to your device and chat with it without a server connection.',
    'tierLight': 'Light',
    'tierLightDesc': 'For weak/older phones (32-bit ARM, low RAM)',
    'tierMid': 'Mid-range',
    'tierMidDesc': 'For modern mid-range smartphones (e.g. Honor 70)',
    'tierHigh': 'High-end',
    'tierHighDesc': 'For flagships with plenty of RAM (e.g. iPhone 15 Pro Max)',
    'tierRoleplay': 'For roleplay',
    'tierRoleplayDesc':
        'Fine-tunes trained on roleplay/creative-writing dialogue, not just assistant tasks',
    'onDevice': 'on-device',
    'downloadModel': 'Download',
    'downloadingModel': 'Downloading…',
    'cancelDownload': 'Cancel',
    'useModel': 'Use',
    'modelInUse': 'In use',
    'deleteModel': 'Delete',
    'localModelMissing':
        'Model file not found. Download it again from the Local models screen.',
    'modelCrashWarn': 'A local model crashed on load and was disabled:',
    'deleteLocalModelTitle': 'Delete this model?',
    'deleteLocalModelBody':
        'The model file will be removed from your device. You can download it again anytime.',
    'personalization': 'Personalization',
    'memory': 'Memory',
    'rpMode': 'Roleplay mode',
    'rpModeOn': 'Roleplay mode is on for this chat',
    'rpModeOff': 'Roleplay mode is off for this chat',
    'rpEnableDesc':
        "Replaces the regular system prompt with the character from this tab and locks the model to this chat.",
    'stopGeneration': 'Stop generating',
    'tabRoleplay': 'Roleplay',
    'rpDesc':
        'Character names, scenario, generation settings, and the world lorebook for this chat.',
    'rpModelLocked': 'Model is locked for this chat',
    'rpModelLockedToast':
        "This chat's model was locked in when roleplay mode turned on and can't change within the session.",
    'rpMyCharacter': 'My character',
    'rpMyCharacterDesc': 'Who you are in this story — your character\'s name and description.',
    'rpAiRole': "AI's role",
    'rpAiRoleDesc': "Who the AI should be in this chat — the character's name and personality.",
    'rpUserName': 'Your name',
    'rpUserDescription': 'Your character description',
    'rpUserDescriptionDesc':
        'Who your character is — appearance, personality, role in the story. The model takes this into account when addressing you, but does not play as you.',
    'rpUserDescriptionHint':
        'Describe your character. {{user}} and {{char}} are available.',
    'rpAiName': "AI character's name",
    'rpScenarioSection': 'Scenario',
    'systemPrompt': 'System prompt / character personality',
    'systemPromptDesc':
        "The character's core description — voice, personality, way of speaking. Replaces the regular personality system prompt for this chat.",
    'rpSystemPromptHint':
        'Describe the character in first person. {{user}} and {{char}} are available.',
    'rpPlaceholderExampleTitle': 'Example',
    'rpPlaceholderExample':
        '"You are {{char}}, a grizzled starship captain. You call {{user}} the crew\'s newest recruit and speak to them gruffly but warmly." The model will replace {{user}} and {{char}} with the names from the fields above.',
    'scenario': 'Scenario / setting',
    'scenarioDesc':
        'The opening context for the story — the setting the conversation starts in.',
    'rpScenarioHint': 'How does the story begin?',
    'rpSampling': 'Generation settings',
    'rpTemperature': 'Temperature',
    'rpTemperatureDesc':
        'Higher makes replies more random and surprising; lower makes them more predictable.',
    'rpTopP': 'Top-P',
    'rpTopPDesc':
        'Cuts off unlikely word choices; a lower value makes the text more predictable.',
    'rpRepetitionPenalty': 'Repetition penalty',
    'rpRepetitionPenaltyDesc':
        'Lowers the chance the model repeats the same phrases.',
    'rpMaxTokens': 'Reply length',
    'rpMaxTokensDesc': 'Roughly how long a single reply is allowed to be.',
    'rpPresetShort': 'Short (150)',
    'rpPresetMedium': 'Medium (300)',
    'rpPresetLong': 'Novel (600)',
    'rpPresetEpic': 'Epic (1000)',
    'rpLorebook': 'Lorebook',
    'rpLorebookEnable': 'World lorebook',
    'rpLorebookDesc':
        "Entries get mixed into the prompt when their keywords show up in chat.",
    'rpLorebookKeywords': 'Keywords, comma-separated',
    'rpLorebookContent': 'Description for the prompt',
    'rpLorebookAddEntry': 'Add entry',
    'rpStopSequences': 'Stop sequences',
    'rpStopSequencesDesc':
        "Generation stops as soon as the model outputs one of these snippets.",
    'rpStopSequenceHint': 'Type text and press Enter',
    'rpContextWindow': 'Context window limit',
    'rpContextWindowDesc':
        'How many recent messages from this chat fit into a single request to the model.',
    'rpContextFull':
        "This chat's context is almost full — you can compress the older history into a summary.",
    'rpCompressButton': 'Compress chat memory',
    'language': 'Language',
    'serverAddress': 'Server address',
    'showKeyboard': 'Show keyboard on launch',
    'haptics': 'Haptics',
    'themeMode': 'Theme',
    'themeSystem': 'System',
    'themeLight': 'Light',
    'themeDark': 'Dark',
    'themeClaude': 'Claude',
    'themeClaudeDark': 'Claude (dark)',
    'themeGray': 'Gray',
    'appStyle': 'App style',
    'appStyleDialogTitle': 'App style',
    'appStyleStandard': 'Standard',
    'appStyleGlass': 'Liquid Glass',
    'showChips': 'Show prompt chips',
    'fontSize': 'Font size',
    'deleteHistory': 'Delete conversation history',
    'terms': 'Terms & Conditions',
    'privacy': 'Privacy Policy',
    'licenses': 'Licenses',
    'cantUndo': 'This cannot be undone.',
    'cancel': 'Cancel',
    'save': 'Save',
    'done': 'Done',
    'reset': 'Reset',
    'serverDialogTitle': 'AI connection',
    'serverUrlLabel': 'Address (IP:port or https://...)',
    'serverUrlHint': 'e.g. 192.168.1.100:11434 or https://api.site.com',
    'apiKeyOptional': 'API key (optional)',
    'languageDialogTitle': 'Select language',
    'russian': 'Русский',
    'english': 'English',
    'addModelHint': 'Add model manually',
    'attachFile': 'Attach file',
    'fileAttached': 'File attached',
    'imageNotSupportedWarning':
        "This model can't understand images — it will only see the file name.",
    'recentPhotos': 'Recent',
    'noRecentPhotos': 'No recent photos',
    'photoAccessDenied':
        "No access to your photos. Allow photo access in the device settings.",
    'attachTabGallery': 'Gallery',
    'attachTabFile': 'File',
    'serverError': 'Server error',
    'unreachable': 'Could not reach the server',
    'checkAddress': 'Check the address in Settings.',
    'pers': 'Personalization',
    'chatPers': 'This chat\'s settings',
    'tabPersonality': 'Personality',
    'tabMemory': 'Memory',
    'persDesc': "Tailor the assistant's personality, behavior and context.",
    'memoryDesc':
        "Control what EVS remembers about you, and how much conversation context local models can see.",
    'persPersona': 'Character & vibe',
    'persPreset': 'Persona preset',
    'persPresetDesc':
        'A style template — instantly adjusts the traits and tone below.',
    'preset_friend': 'Best friend',
    'preset_mentor': 'Mentor / Coach',
    'preset_expert': 'Expert',
    'preset_creative': 'Creative partner',
    'preset_custom': 'Custom',
    'slidersTitle': 'Character traits',
    'sl_formality': 'Formality',
    'sl_formalityDesc': 'How formal or casual the answer sounds.',
    'sl_empathy': 'Empathy',
    'sl_empathyDesc': 'A warm, supportive tone — or a dry, businesslike one.',
    'sl_verbosity': 'Detail',
    'sl_verbosityDesc':
        'Detailed explanations — or short, to-the-point replies.',
    'sl_humor': 'Humor',
    'sl_humorDesc': 'How much room there is for jokes and playfulness.',
    'sl_creativity': 'Creativity',
    'sl_creativityDesc':
        'Conventional answers — or unconventional ideas and comparisons.',
    'speechStyle': 'Speech style',
    'emojiUsage': 'Emoji',
    'emojiUsageDesc': 'How often emoji show up in replies.',
    'emoji_never': 'Never',
    'emoji_sometimes': 'Sometimes',
    'emoji_always': 'Always',
    'answerFormat': 'Answer format',
    'answerFormatDesc': 'Plain text, lists, or tables, whichever fits the content.',
    'fmt_plain': 'Plain text',
    'fmt_lists': 'Lists',
    'fmt_tables': 'Tables when possible',
    'persBehavior': 'Functionality & behavior',
    'defaultLength': 'Default answer length',
    'defaultLengthDesc':
        'Target reply length unless you ask for something different.',
    'len_short': 'Short',
    'len_normal': 'Standard',
    'len_long': 'Detailed',
    'proactivity': 'Proactivity',
    'proactivityDesc':
        'Answer only what was asked, ask clarifying questions, or suggest related topics.',
    'pro_answer': 'Answer only',
    'pro_clarify': 'Ask clarifying questions',
    'pro_suggest': 'Suggest related topics',
    'useMarkdown': 'Use markdown formatting',
    'useMarkdownDesc': 'Headings, lists, and emphasis in responses.',
    'memorySection': 'Memory & context',
    'longMemory': 'Long-term memory',
    'longMemoryDesc': "Factor the note below into the assistant's answers.",
    'memoryNote': 'Remember about me that…',
    'autoSaveMemories': 'Auto-save useful details',
    'autoSaveMemoriesDesc':
        'After every reply, quietly ask the model whether anything stable is worth remembering: preferences, profile details, ongoing projects.',
    'askBeforeRemembering': 'Ask before remembering',
    'askBeforeRememberingDesc':
        'Choose a memory category when you save a message manually.',
    'deleteAllMemories': 'Delete all memories',
    'deleteAllMemoriesDesc': 'Clear every saved memory from this device.',
    'deleteAllMemoriesConfirm':
        'All saved memories will be permanently deleted.',
    'chooseMemoryCategory': 'Choose a memory category',
    'memCatPreference': 'Preference',
    'memCatProfile': 'Profile',
    'memCatProject': 'Project',
    'memCatOther': 'Other',
    'contextSize': 'Context size',
    'contextSizeDesc':
        "How much of the conversation the local model remembers. Higher means better memory, but more load on the device and slower replies.",
    'contextSizeMaxFor': 'Maximum for',
    'contextSizeMaxForDevice': 'Maximum for this device',
    'contextSizeMovedToRp':
        'For this chat, context size is configured in the "Roleplay" tab — alongside the context limit and generation settings.',
    'persProfile': 'About you',
    'name': 'Name',
    'pronouns': 'Pronouns',
    'profession': 'Profession',
    'interests': 'Interests & hobbies',
    'goals': 'Goals',
    'useMyData': 'Use my data to improve answers',
    'useMyDataDesc': 'Name, profession, interests, and the other fields below.',
    'knowledgeLevel': 'Knowledge level',
    'kl_beginner': 'Beginner',
    'kl_student': 'Student',
    'kl_expert': 'Expert',
    'location': 'Location (city / timezone)',
    'persSafety': 'Safety & limits',
    'avoidTopics': 'Topics to avoid',
    'contentFilter': 'Content filter',
    'cf_strict': 'Strict',
    'cf_balanced': 'Balanced',
    'cf_off': 'No filter',
    'warnUncertain': 'Warn on uncertainty and sensitive topics',
    'warnUncertainDesc': "Be upfront when the assistant isn't sure.",
    'localDataTitle': 'Personalization is stored locally on this device',
    'localDataDesc':
        "Your name, notes, and personality settings never leave the device — they're only used to build the prompt the model sees.",
    'persAdvanced': 'Advanced',
    'reasoning': 'Reasoning style',
    'reasoningDesc':
        'Answer right away, or think step by step and show the reasoning.',
    'rs_fast': 'Fast & intuitive',
    'rs_step': 'Step-by-step reasoning',
    'toneTitle': 'Text tone',
    'toneTitleDesc': 'Overall emotional flavor of the reply text.',
    'tone_neutral': 'Neutral',
    'tone_sarcastic': 'Sarcastic',
    'tone_melancholic': 'Melancholic',
    'tone_excited': 'Excited',
    'customPrompt': 'Custom system prompt',
    'customPromptDesc':
        "Appended to the end of the system prompt — for rules not covered by the settings above.",
    'customPromptHint': 'Direct instruction to the assistant…',
  },
};

/* ============================ МОДЕЛИ ДАННЫХ ============================ */

class ChatMessage {
  final String id;
  final String role;
  // Mutable so a streaming reply can grow this in place (see
  // AppState.sendMessageStreaming) instead of replacing the message object
  // on every chunk.
  String content;
  final DateTime time;
  final List<String> attachments;
  ChatMessage({
    String? id,
    required this.role,
    required this.content,
    DateTime? time,
    List<String>? attachments,
  }) : id = id ?? const Uuid().v4(),
       time = time ?? DateTime.now(),
       attachments = attachments ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'time': time.toIso8601String(),
    'attachments': attachments,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String?,
    role: j['role'] as String? ?? 'user',
    content: j['content'] as String? ?? '',
    time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
    attachments:
        (j['attachments'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
  );
}

class Conversation {
  final String id;
  String title;
  bool pinned;
  DateTime updatedAt;
  List<ChatMessage> messages;
  Personalization? persona;
  List<String> pinnedMessageIds;
  // Opt-in per-chat mode for roleplay-oriented features (currently: live
  // streaming with a Stop Generation button instead of waiting silently for
  // the full reply). Off by default so the existing chat flow is untouched
  // unless the user explicitly turns it on for a given conversation.
  bool rpModeEnabled;
  // RP-specific settings for this chat (character names, system prompt,
  // sampling, lorebook, locked model...) — nullable and cloned-while-editing
  // the same way persona is; only ever non-null once rpModeEnabled has been
  // turned on at least once for this conversation.
  RPSessionConfig? rpConfig;

  Conversation({
    required this.id,
    required this.title,
    this.pinned = false,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.persona,
    List<String>? pinnedMessageIds,
    this.rpModeEnabled = false,
    this.rpConfig,
  }) : updatedAt = updatedAt ?? DateTime.now(),
       messages = messages ?? [],
       pinnedMessageIds = pinnedMessageIds ?? [];

  // Pinned messages stay part of the prompt for every reply in this chat,
  // no matter how long the conversation grows — appended after the regular
  // personalization prompt so it isn't buried/ignored like the rest.
  String pinnedContextBlock() {
    final pinnedMsgs = messages.where((m) => pinnedMessageIds.contains(m.id));
    if (pinnedMsgs.isEmpty) return '';
    final b = StringBuffer('Pinned context — always keep this in mind:\n');
    for (final m in pinnedMsgs) {
      b.writeln('- ${m.content}');
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'pinned': pinned,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'persona': persona?.toJson(),
    'pinnedMessageIds': pinnedMessageIds,
    'rpModeEnabled': rpModeEnabled,
    'rpConfig': rpConfig?.toJson(),
  };
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    pinned: j['pinned'] as bool? ?? false,
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    messages:
        (j['messages'] as List<dynamic>?)
            ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    persona: j['persona'] is Map<String, dynamic>
        ? Personalization.fromJson(j['persona'] as Map<String, dynamic>)
        : null,
    pinnedMessageIds:
        (j['pinnedMessageIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
    rpModeEnabled: j['rpModeEnabled'] as bool? ?? false,
    rpConfig: j['rpConfig'] is Map<String, dynamic>
        ? RPSessionConfig.fromJson(j['rpConfig'] as Map<String, dynamic>)
        : null,
  );
}

class Personalization {
  Personalization();

  String preset = 'preset_custom';
  double formality = 0.5;
  double empathy = 0.5;
  double verbosity = 0.5;
  double humor = 0.3;
  double creativity = 0.5;
  String emoji = 'emoji_sometimes';
  String answerFormat = 'fmt_plain';
  String defaultLength = 'len_normal';
  String proactivity = 'pro_clarify';
  bool useMarkdown = true;
  bool longMemory = true;
  String memoryNote = '';
  // Individual snippets saved via the "Remember this" action on a chat
  // message, as opposed to memoryNote which is one freeform note the user
  // types by hand.
  List<String> savedMemories = [];
  bool askBeforeRemembering = true;
  // When on, after every assistant reply a small silent follow-up request
  // asks the same model to extract one durable fact worth remembering (or
  // "NONE"), so savedMemories grows without the user tapping "Remember".
  bool autoSaveMemories = true;
  String name = '';
  String pronouns = '';
  String profession = '';
  String interests = '';
  String goals = '';
  bool useMyData = true;
  String knowledgeLevel = 'kl_student';
  String location = '';
  String avoidTopics = '';
  String contentFilter = 'cf_balanced';
  bool warnUncertain = true;
  String reasoning = 'rs_fast';
  String tone = 'tone_neutral';
  String customPrompt = '';
  // Name the assistant refers to itself by (used at the top of the system
  // prompt). Editable in the desktop Personality settings; defaults to EVS.
  String assistantName = 'EVS';
  // Effective context window (in tokens) handed to local on-device models.
  // fllama internally hardcodes n_parallel=4 and splits the requested
  // contextSize across 4 slots, so callers must request 4x this value to
  // actually get this much usable context — see _sendLocalMessage.
  int localContextSize = 2048;

  Map<String, dynamic> toJson() => {
    'preset': preset,
    'formality': formality,
    'empathy': empathy,
    'verbosity': verbosity,
    'humor': humor,
    'creativity': creativity,
    'emoji': emoji,
    'answerFormat': answerFormat,
    'defaultLength': defaultLength,
    'proactivity': proactivity,
    'useMarkdown': useMarkdown,
    'longMemory': longMemory,
    'memoryNote': memoryNote,
    'savedMemories': savedMemories,
    'askBeforeRemembering': askBeforeRemembering,
    'autoSaveMemories': autoSaveMemories,
    'name': name,
    'pronouns': pronouns,
    'profession': profession,
    'interests': interests,
    'goals': goals,
    'useMyData': useMyData,
    'knowledgeLevel': knowledgeLevel,
    'location': location,
    'avoidTopics': avoidTopics,
    'contentFilter': contentFilter,
    'warnUncertain': warnUncertain,
    'reasoning': reasoning,
    'tone': tone,
    'customPrompt': customPrompt,
    'assistantName': assistantName,
    'localContextSize': localContextSize,
  };

  factory Personalization.fromJson(Map<String, dynamic> j) {
    final p = Personalization();
    p.preset = (j['preset'] as String?) ?? p.preset;
    p.formality = (j['formality'] as num?)?.toDouble() ?? p.formality;
    p.empathy = (j['empathy'] as num?)?.toDouble() ?? p.empathy;
    p.verbosity = (j['verbosity'] as num?)?.toDouble() ?? p.verbosity;
    p.humor = (j['humor'] as num?)?.toDouble() ?? p.humor;
    p.creativity = (j['creativity'] as num?)?.toDouble() ?? p.creativity;
    p.emoji = (j['emoji'] as String?) ?? p.emoji;
    p.answerFormat = (j['answerFormat'] as String?) ?? p.answerFormat;
    p.defaultLength = (j['defaultLength'] as String?) ?? p.defaultLength;
    p.proactivity = (j['proactivity'] as String?) ?? p.proactivity;
    p.useMarkdown = (j['useMarkdown'] as bool?) ?? p.useMarkdown;
    p.longMemory = (j['longMemory'] as bool?) ?? p.longMemory;
    p.memoryNote = (j['memoryNote'] as String?) ?? p.memoryNote;
    p.savedMemories =
        (j['savedMemories'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        p.savedMemories;
    p.askBeforeRemembering =
        (j['askBeforeRemembering'] as bool?) ?? p.askBeforeRemembering;
    p.autoSaveMemories =
        (j['autoSaveMemories'] as bool?) ?? p.autoSaveMemories;
    p.name = (j['name'] as String?) ?? p.name;
    p.pronouns = (j['pronouns'] as String?) ?? p.pronouns;
    p.profession = (j['profession'] as String?) ?? p.profession;
    p.interests = (j['interests'] as String?) ?? p.interests;
    p.goals = (j['goals'] as String?) ?? p.goals;
    p.useMyData = (j['useMyData'] as bool?) ?? p.useMyData;
    p.knowledgeLevel = (j['knowledgeLevel'] as String?) ?? p.knowledgeLevel;
    p.location = (j['location'] as String?) ?? p.location;
    p.avoidTopics = (j['avoidTopics'] as String?) ?? p.avoidTopics;
    p.contentFilter = (j['contentFilter'] as String?) ?? p.contentFilter;
    p.warnUncertain = (j['warnUncertain'] as bool?) ?? p.warnUncertain;
    p.reasoning = (j['reasoning'] as String?) ?? p.reasoning;
    p.tone = (j['tone'] as String?) ?? p.tone;
    p.customPrompt = (j['customPrompt'] as String?) ?? p.customPrompt;
    p.assistantName = (j['assistantName'] as String?) ?? p.assistantName;
    p.localContextSize =
        (j['localContextSize'] as num?)?.toInt() ?? p.localContextSize;
    return p;
  }

  Personalization clone() => Personalization.fromJson(toJson());

  void applyPreset(String preset) {
    this.preset = preset;
    switch (preset) {
      case 'preset_friend':
        formality = 0.15;
        empathy = 0.8;
        verbosity = 0.4;
        humor = 0.8;
        creativity = 0.6;
        emoji = 'emoji_always';
        tone = 'tone_excited';
        break;
      case 'preset_mentor':
        formality = 0.5;
        empathy = 0.7;
        verbosity = 0.6;
        humor = 0.3;
        creativity = 0.5;
        emoji = 'emoji_sometimes';
        proactivity = 'pro_clarify';
        tone = 'tone_neutral';
        break;
      case 'preset_expert':
        formality = 0.9;
        empathy = 0.2;
        verbosity = 0.7;
        humor = 0.05;
        creativity = 0.2;
        emoji = 'emoji_never';
        answerFormat = 'fmt_lists';
        tone = 'tone_neutral';
        break;
      case 'preset_creative':
        formality = 0.3;
        empathy = 0.6;
        verbosity = 0.6;
        humor = 0.7;
        creativity = 0.95;
        emoji = 'emoji_sometimes';
        tone = 'tone_excited';
        break;
    }
  }

  // Plain declarative sentences instead of a dense "name: X; pronouns: Y; ..."
  // list — small/mid local models tend to skim past or ignore facts packed
  // into one compressed key:value sentence, but pick up on short individual
  // statements much more reliably (the same reason buildLocalSystemPrompt
  // below uses plain sentences for tone/emoji instead of a directive line).
  void _writeProfileFacts(StringBuffer b) {
    if (name.isNotEmpty) b.writeln("The user's name is $name.");
    if (pronouns.isNotEmpty) {
      b.writeln("The user's pronouns are $pronouns.");
    }
    if (profession.isNotEmpty) b.writeln('The user works as $profession.');
    if (interests.isNotEmpty) {
      b.writeln('The user is interested in $interests.');
    }
    if (goals.isNotEmpty) b.writeln("The user's goal: $goals.");
    if (location.isNotEmpty) b.writeln('The user is located in $location.');
  }

  void _writeMemoryFacts(StringBuffer b) {
    if (!longMemory) return;
    if (memoryNote.isNotEmpty) {
      b.writeln('Remember about the user: $memoryNote');
    }
    for (final mem in savedMemories) {
      b.writeln('Also remember: $mem');
    }
  }

  // Same reasoning as _writeProfileFacts: one sentence per trait that's
  // actually away from the neutral middle, instead of a single dense
  // "Style: formality medium, empathy medium, ..." line — models were
  // visibly ignoring the personality sliders entirely with the old format.
  //
  // Thresholds at 0.4/0.6 (not 0.33/0.66) and a second, stronger tier past
  // 0.15/0.85 — the old 0.33-0.66 dead zone covered the sliders' own 0.5
  // default, so a moderate drag in either direction produced no directive
  // at all and the setting looked like it did nothing.
  void _writeStyleFacts(StringBuffer b) {
    if (formality >= 0.85) {
      b.writeln('Write very formally, like an official document.');
    } else if (formality >= 0.6) {
      b.writeln('Write formally and professionally.');
    } else if (formality < 0.15) {
      b.writeln('Write very casually, like texting a close friend; slang is fine.');
    } else if (formality < 0.4) {
      b.writeln('Write casually and informally, like talking to a friend.');
    }
    if (empathy >= 0.85) {
      b.writeln('Be deeply warm and emotionally supportive; validate feelings.');
    } else if (empathy >= 0.6) {
      b.writeln('Be warm and emotionally supportive in your responses.');
    } else if (empathy < 0.15) {
      b.writeln('Be strictly factual and blunt; skip emotional commentary entirely.');
    } else if (empathy < 0.4) {
      b.writeln(
        'Stay matter-of-fact and businesslike, without emotional commentary.',
      );
    }
    if (verbosity >= 0.85) {
      b.writeln('Give thorough, in-depth answers with examples and context.');
    } else if (verbosity >= 0.6) {
      b.writeln('Elaborate with extra detail and explanation.');
    } else if (verbosity < 0.15) {
      b.writeln('Be extremely terse; answer in as few words as possible.');
    } else if (verbosity < 0.4) {
      b.writeln('Be concise; avoid unnecessary elaboration.');
    }
    if (humor >= 0.85) {
      b.writeln('Be consistently witty and playful; jokes are welcome often.');
    } else if (humor >= 0.6) {
      b.writeln('Feel free to be playful and use humor.');
    } else if (humor < 0.15) {
      b.writeln('Stay strictly serious; do not joke at all.');
    } else if (humor < 0.4) {
      b.writeln('Keep a serious tone, avoid jokes.');
    }
    if (creativity >= 0.85) {
      b.writeln('Favor bold, unconventional ideas and unexpected angles.');
    } else if (creativity >= 0.6) {
      b.writeln('Be imaginative and creative in how you answer.');
    } else if (creativity < 0.15) {
      b.writeln('Stick strictly to the safest, most conventional answer.');
    } else if (creativity < 0.4) {
      b.writeln('Stick to straightforward, conventional answers.');
    }
  }

  String buildSystemPrompt() {
    final b = StringBuffer();
    final who = assistantName.trim().isEmpty ? 'EVS' : assistantName.trim();
    b.writeln('You are $who, a helpful AI assistant.');

    _writeStyleFacts(b);

    b.writeln(
      emoji == 'emoji_never'
          ? 'Never use emoji.'
          : emoji == 'emoji_always'
          ? 'Use emoji frequently.'
          : 'Use emoji occasionally.',
    );

    if (answerFormat == 'fmt_lists') {
      b.writeln('Prefer structured bullet lists.');
    } else if (answerFormat == 'fmt_tables') {
      b.writeln('Use tables whenever data fits a table.');
    }

    b.writeln(
      defaultLength == 'len_short'
          ? 'Keep answers very short (max 2 sentences).'
          : defaultLength == 'len_long'
          ? 'Give detailed, thorough answers.'
          : 'Give standard-length answers.',
    );

    if (proactivity == 'pro_clarify') {
      b.writeln('Ask clarifying questions when the task is unclear.');
    } else if (proactivity == 'pro_suggest') {
      b.writeln('Proactively suggest interesting related topics.');
    } else {
      b.writeln('Only answer what is asked.');
    }

    if (useMarkdown) b.writeln('Use markdown formatting.');

    b.writeln(
      'Reasoning: ${reasoning == 'rs_step' ? 'think step by step and show your reasoning' : 'answer directly and intuitively'}.',
    );

    if (tone != 'tone_neutral') {
      b.writeln('Overall tone of text: ${tone.replaceFirst('tone_', '')}.');
    }

    if (useMyData) {
      _writeProfileFacts(b);
      b.writeln(
        'Explain things at a ${knowledgeLevel.replaceFirst('kl_', '')} level.',
      );
    }

    _writeMemoryFacts(b);

    if (avoidTopics.isNotEmpty) {
      b.writeln('Avoid these topics: $avoidTopics.');
    }
    b.writeln(
      contentFilter == 'cf_strict'
          ? 'Apply a strict safety filter; block adult and violent content.'
          : contentFilter == 'cf_off'
          ? 'Minimal content filtering for an adult, private conversation.'
          : 'Apply a balanced content filter.',
    );
    if (warnUncertain) {
      b.writeln(
        'Warn the user when you are uncertain or the topic is sensitive (medical, financial, legal).',
      );
    }

    if (customPrompt.trim().isNotEmpty) {
      b.writeln('Additional user instruction: ${customPrompt.trim()}');
    }
    return b.toString();
  }

  // Small on-device models reliably break down when given the full
  // multi-directive prompt above (formality/empathy/verbosity/tone/etc.) —
  // they tend to start mimicking its "key: value" structure instead of
  // actually answering. Keep only what's simple enough for them to follow
  // and important enough to be worth the tokens.
  String buildLocalSystemPrompt() {
    final b = StringBuffer();
    b.writeln(
      'You are EVS, a helpful assistant. Answer naturally and directly.',
    );
    if (defaultLength == 'len_short') {
      b.writeln('Keep answers short.');
    } else if (defaultLength == 'len_long') {
      b.writeln('Give detailed answers.');
    }
    _writeStyleFacts(b);
    if (emoji == 'emoji_never') {
      b.writeln('Never use emoji.');
    } else if (emoji == 'emoji_always') {
      b.writeln('Use emoji frequently.');
    }
    if (tone != 'tone_neutral') {
      final toneWord = switch (tone) {
        'tone_sarcastic' => 'sarcastic',
        'tone_melancholic' => 'melancholic',
        'tone_excited' => 'excited and energetic',
        _ => null,
      };
      if (toneWord != null) b.writeln('Write in a $toneWord tone.');
    }
    if (useMyData) _writeProfileFacts(b);
    _writeMemoryFacts(b);
    if (avoidTopics.isNotEmpty) {
      b.writeln('Avoid these topics: $avoidTopics.');
    }
    if (contentFilter == 'cf_strict') {
      b.writeln('Avoid adult and violent content.');
    }
    if (customPrompt.trim().isNotEmpty) {
      b.writeln('Additional instruction: ${customPrompt.trim()}');
    }
    return b.toString();
  }

  // "Never use emoji" is a plain-language system-prompt instruction like
  // every other personality setting, but unlike formality/tone/verbosity it
  // has a hard, checkable answer (an emoji is either there or it isn't) —
  // and models reliably keep using emoji anyway when earlier turns in the
  // same chat already established that pattern, no matter how the system
  // prompt is worded. So for this one setting only, enforce it directly on
  // the model's output instead of just hoping the prompt is followed.
  static final RegExp _emojiPattern = RegExp(
    '[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2300}-\u{23FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );

  String enforceEmojiPolicy(String text) {
    if (emoji != 'emoji_never') return text;
    return text
        .replaceAll(_emojiPattern, '')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
  }
}

/* ============================ РЕЖИМ РОЛЕВОЙ ИГРЫ (RP) ============================ */

// Sampling-параметры генерации для RP-режима. mirostatMode/tfsZ из исходного
// ТЗ сознательно не добавлены — у закреплённой версии fllama (OpenAiRequest,
// см. package:fllama/misc/openai.dart) просто нет таких полей; добавлять их
// в данные, которые ни на что не влияют, было бы нечестным UI.
class RPSamplingConfig {
  RPSamplingConfig();

  double temperature = 0.9;
  double topP = 0.90;
  // Маппится на fllama presencePenalty / remote repeat_penalty — это и есть
  // репетишн-пенальти, отдельного поля под него не нужно.
  double repetitionPenalty = 1.10;
  int maxResponseTokens = 300;

  Map<String, dynamic> toJson() => {
    'temperature': temperature,
    'topP': topP,
    'repetitionPenalty': repetitionPenalty,
    'maxResponseTokens': maxResponseTokens,
  };

  factory RPSamplingConfig.fromJson(Map<String, dynamic> j) {
    final c = RPSamplingConfig();
    c.temperature = (j['temperature'] as num?)?.toDouble() ?? c.temperature;
    c.topP = (j['topP'] as num?)?.toDouble() ?? c.topP;
    c.repetitionPenalty =
        (j['repetitionPenalty'] as num?)?.toDouble() ?? c.repetitionPenalty;
    c.maxResponseTokens =
        (j['maxResponseTokens'] as num?)?.toInt() ?? c.maxResponseTokens;
    return c;
  }

  RPSamplingConfig clone() => RPSamplingConfig.fromJson(toJson());
}

// Одна статья "блокнота мира" — keywords через запятую, матчится
// регистронезависимо против последних N сообщений чата (см.
// RPMemoryManager.scanLorebook).
class LoreEntry {
  String keywords;
  String content;
  LoreEntry({this.keywords = '', this.content = ''});

  Map<String, dynamic> toJson() => {'keywords': keywords, 'content': content};
  factory LoreEntry.fromJson(Map<String, dynamic> j) => LoreEntry(
    keywords: j['keywords'] as String? ?? '',
    content: j['content'] as String? ?? '',
  );
}

// Настройки RP-режима для конкретного чата — нестандартное nullable поле
// Conversation.rpConfig, по образцу уже существующего Conversation.persona.
class RPSessionConfig {
  RPSessionConfig();

  String userCharacterName = '';
  // Описание персонажа пользователя — кто он в этой истории. Передаётся
  // модели как справочный контекст (см. RPMemoryManager.buildSystemPrompt),
  // в отличие от systemPrompt, который описывает персонажа ИИ и задаёт его
  // голос.
  String userCharacterDescription = '';
  String aiCharacterName = '';
  // Свободный текст с {{user}}/{{char}} — в отличие от Personalization,
  // которая собирает промпт программно из отдельных директив, RP-режим
  // использует один авторский шаблон (см. RPMemoryManager.buildSystemPrompt).
  String systemPrompt = '';
  String scenario = '';
  RPSamplingConfig sampling = RPSamplingConfig();
  bool isLorebookEnabled = false;
  List<LoreEntry> lorebook = [];
  List<String> stopSequences = [];
  // Снимок AppState.selectedModel в момент первого включения RP для этого
  // чата — дальше не меняется (см. AppState.toggleRpMode).
  String? lockedModel;
  int contextWindowLimit = 4096;
  // Сгенерированное резюме старой истории чата (контекстная компрессия по
  // запросу пользователя) — null, пока пользователь не нажал "Сжать".
  String? rollingSummary;
  int? summaryCoversUpToMessageIndex;

  Map<String, dynamic> toJson() => {
    'userCharacterName': userCharacterName,
    'userCharacterDescription': userCharacterDescription,
    'aiCharacterName': aiCharacterName,
    'systemPrompt': systemPrompt,
    'scenario': scenario,
    'sampling': sampling.toJson(),
    'isLorebookEnabled': isLorebookEnabled,
    'lorebook': lorebook.map((e) => e.toJson()).toList(),
    'stopSequences': stopSequences,
    'lockedModel': lockedModel,
    'contextWindowLimit': contextWindowLimit,
    'rollingSummary': rollingSummary,
    'summaryCoversUpToMessageIndex': summaryCoversUpToMessageIndex,
  };

  factory RPSessionConfig.fromJson(Map<String, dynamic> j) {
    final c = RPSessionConfig();
    c.userCharacterName = j['userCharacterName'] as String? ?? '';
    c.userCharacterDescription =
        j['userCharacterDescription'] as String? ?? '';
    c.aiCharacterName = j['aiCharacterName'] as String? ?? '';
    c.systemPrompt = j['systemPrompt'] as String? ?? '';
    c.scenario = j['scenario'] as String? ?? '';
    c.sampling = j['sampling'] is Map<String, dynamic>
        ? RPSamplingConfig.fromJson(j['sampling'] as Map<String, dynamic>)
        : RPSamplingConfig();
    c.isLorebookEnabled = j['isLorebookEnabled'] as bool? ?? false;
    c.lorebook =
        (j['lorebook'] as List<dynamic>?)
            ?.map((e) => LoreEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    c.stopSequences =
        (j['stopSequences'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    c.lockedModel = j['lockedModel'] as String?;
    c.contextWindowLimit =
        (j['contextWindowLimit'] as num?)?.toInt() ?? c.contextWindowLimit;
    c.rollingSummary = j['rollingSummary'] as String?;
    c.summaryCoversUpToMessageIndex =
        (j['summaryCoversUpToMessageIndex'] as num?)?.toInt();
    return c;
  }

  RPSessionConfig clone() => RPSessionConfig.fromJson(toJson());
}

// Assembles the RP-mode system prompt (system prompt + scenario + rolling
// summary + lorebook + pinned context) and manages what actually gets sent
// to the model as history (lorebook scan, sliding-window trim). Pure static
// functions, no AppState dependency — operates only on Conversation/
// RPSessionConfig/ChatMessage.
class RPMemoryManager {
  static String _substitutePlaceholders(String text, RPSessionConfig cfg) {
    var out = text;
    if (cfg.userCharacterName.trim().isNotEmpty) {
      out = out.replaceAll('{{user}}', cfg.userCharacterName.trim());
    }
    if (cfg.aiCharacterName.trim().isNotEmpty) {
      out = out.replaceAll('{{char}}', cfg.aiCharacterName.trim());
    }
    return out;
  }

  // Replaces persona.buildSystemPrompt() entirely for RP-mode chats — RP
  // uses one author-written template instead of Personalization's
  // programmatically-assembled sentences. conv.pinnedContextBlock() is
  // still appended so pinned messages keep working in RP mode too.
  static String buildSystemPrompt(Conversation conv) {
    final cfg = conv.rpConfig!;
    final b = StringBuffer();
    final aiName = cfg.aiCharacterName.trim();
    final userName = cfg.userCharacterName.trim();
    if (cfg.systemPrompt.trim().isNotEmpty) {
      b.writeln(_substitutePlaceholders(cfg.systemPrompt.trim(), cfg));
      // The substitution above only fills in a name where the user's own
      // prompt text happens to use {{user}}/{{char}} — a freeform custom
      // prompt that never does leaves the model with no idea what to call
      // the user (the AI's own name tends to come through anyway, since
      // the prompt is written in its voice). State both names explicitly
      // so a forgotten {{user}} token can't silently drop it.
      if (userName.isNotEmpty || aiName.isNotEmpty) {
        final who = [
          if (userName.isNotEmpty) 'the user is $userName',
          if (aiName.isNotEmpty) 'you are $aiName',
        ].join(' and ');
        b.writeln('(For reference: $who.)');
      }
    } else {
      final ai = aiName.isNotEmpty ? aiName : 'a character';
      b.writeln(
        'You are roleplaying as $ai${userName.isNotEmpty ? " opposite $userName" : ""}. '
        'Stay in character and respond only as your character would.',
      );
    }
    if (cfg.userCharacterDescription.trim().isNotEmpty) {
      final who = userName.isNotEmpty ? userName : 'the user';
      b.writeln(
        'About $who (the human player, not you): '
        '${_substitutePlaceholders(cfg.userCharacterDescription.trim(), cfg)}',
      );
    }
    if (cfg.scenario.trim().isNotEmpty) {
      b.writeln(
        'Scenario: ${_substitutePlaceholders(cfg.scenario.trim(), cfg)}',
      );
    }
    if (cfg.rollingSummary != null && cfg.rollingSummary!.isNotEmpty) {
      b.writeln('Summary of earlier events: ${cfg.rollingSummary}');
    }
    if (cfg.isLorebookEnabled) {
      final lore = scanLorebook(conv, cfg);
      if (lore.isNotEmpty) b.writeln(lore);
    }
    final pinned = conv.pinnedContextBlock();
    if (pinned.isNotEmpty) b.writeln(pinned);
    return b.toString();
  }

  static String scanLorebook(
    Conversation conv,
    RPSessionConfig cfg, {
    int lastN = 10,
  }) {
    final recent = conv.messages.length > lastN
        ? conv.messages.sublist(conv.messages.length - lastN)
        : conv.messages;
    final haystack = recent.map((m) => m.content.toLowerCase()).join(' ');
    final matched = <String>[];
    for (final entry in cfg.lorebook) {
      final kws = entry.keywords
          .split(',')
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty);
      if (kws.any(haystack.contains)) matched.add(entry.content);
    }
    return matched.join('\n');
  }

  // FIFO sliding window: once history is over budget, keep the first
  // message (greeting/scenario opener) plus the last [keepLastN], drop the
  // rest. Only affects what's SENT to the model — conv.messages (UI) is
  // never touched here.
  static List<ChatMessage> trimForContext(
    List<ChatMessage> history,
    int contextWindowLimit, {
    int keepLastN = 8,
  }) {
    if (history.length <= keepLastN + 1) return history;
    final estTokens = history.fold<int>(
      0,
      (sum, m) => sum + TokenCounter.estimate(m.content),
    );
    if (estTokens <= contextWindowLimit) return history;
    final greeting = [history.first];
    final tail = history.sublist(history.length - keepLastN);
    return [...greeting, ...tail];
  }

  // Context-compression-on-demand (ТЗ-4): true once estimated tokens cross
  // 80% of the chat's contextWindowLimit.
  static bool checkContextThreshold(
    List<ChatMessage> history,
    RPSessionConfig cfg,
  ) {
    final estTokens = history.fold<int>(
      0,
      (sum, m) => sum + TokenCounter.estimate(m.content),
    );
    return estTokens > cfg.contextWindowLimit * 0.8;
  }

  static const _summarizationPrompt =
      'Summarize the following roleplay conversation history concisely, '
      'preserving key plot points, character states, and facts established. '
      'Write the summary in plain prose, third person, no preamble.';

  // Reuses the conversation's own ILLMService (the locked model, passed in
  // by the caller) via a one-off synthetic exchange — NOT the chat's real
  // persona/RP config, so the summarizer doesn't inherit the character's
  // tone instructions.
  static Future<String> summarizeOldContext(
    ILLMService service,
    List<ChatMessage> oldMessages,
  ) async {
    final transcript = oldMessages
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');
    final synthetic = Conversation(
      id: 'rp-summary-temp',
      title: '',
      persona: Personalization(),
    );
    final history = [
      ChatMessage(
        role: 'user',
        content: '$_summarizationPrompt\n\n$transcript',
      ),
    ];
    return service.generateResponse(synthetic, history);
  }
}

// Post-processing safety nets applied to a finished RP reply (after
// streaming completes, never mid-stream — closing a `*` early then having
// more text arrive would look broken).
class RPGuardFilters {
  // Native stop-sequence support only exists for the remote backend (see
  // RemoteLLMService._buildBody); this regex is the only defense for local
  // models, and a backstop for remote ones too. Cuts the reply at the start
  // of a line that looks like the model writing the user's own dialogue.
  static String antiImpersonationFilter(String text, RPSessionConfig cfg) {
    final patterns = <String>[
      r'\{\{user\}\}\s*:',
      if (cfg.userCharacterName.trim().isNotEmpty)
        '${RegExp.escape(cfg.userCharacterName.trim())}\\s*:',
      // Deliberately not \b-bounded: Dart/JS regex \b treats Cyrillic
      // letters as non-word characters, so it doesn't reliably bound
      // Cyrillic text — requiring trailing whitespace instead sidesteps that.
      r'\*?Вы\s',
    ];
    final combined = RegExp(
      '^(${patterns.join('|')})',
      multiLine: true,
      caseSensitive: false,
    );
    final match = combined.firstMatch(text);
    if (match == null) return text;
    return text.substring(0, match.start).trimRight();
  }

  // RP replies often use *asterisks* for actions/thoughts — if the model
  // cuts off mid-italics, auto-close the trailing one instead of leaving
  // broken markdown in the chat UI.
  static String formatEnforcer(String text) {
    final count = '*'.allMatches(text).length;
    return count.isOdd ? '$text*' : text;
  }

  static String apply(String text, RPSessionConfig cfg) =>
      formatEnforcer(antiImpersonationFilter(text, cfg));
}

/* ============================ ЛОКАЛЬНЫЕ МОДЕЛИ ============================ */

enum LocalModelTier { light, mid, high, roleplay }

class LocalModelSpec {
  final String id;
  final String displayName;
  // Short, recognizable label without "Instruct"/version/quant suffixes —
  // shown anywhere the user just needs to know which model is active (chat
  // header, model picker, RP locked-model card). The full displayName stays
  // on the Local Models download screen, where the extra precision actually
  // helps pick what to download.
  final String shortName;
  final int sizeBytes;
  final String url;
  final String fileName;
  final LocalModelTier tier;
  // Native context window the model was actually trained/released with (not
  // a device-RAM guess) — the per-model ceiling shown on the context-size
  // control. fllama hardcodes n_parallel=4 and splits the requested
  // contextSize across 4 slots (see localContextSize * 4 at the call site),
  // so the slider's real usable max is this divided by 4, not the raw value.
  final int maxContextTokens;
  // None of the catalog entries below are vision/multimodal GGUF builds —
  // fllama is given plain OpenAiRequest.messages text, no image bytes — so
  // this defaults to false rather than requiring every entry to spell it
  // out. Flip it on a per-entry basis if a real vision GGUF is ever added.
  final bool isVisionCapable;

  const LocalModelSpec({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.sizeBytes,
    required this.url,
    required this.fileName,
    required this.tier,
    required this.maxContextTokens,
    this.isVisionCapable = false,
  });

  String get modelKey => 'local:$id';

  int get maxLocalContextSize => maxContextTokens ~/ 4;
}

const List<LocalModelSpec> kLocalModels = [
  // Средние — современные смартфоны среднего класса (например, Honor 70)
  LocalModelSpec(
    id: 'qwen2.5-1.5b',
    displayName: 'Qwen2.5 1.5B Instruct',
    shortName: 'Qwen 1.5B',
    sizeBytes: 1117320736,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 32768,
  ),
  LocalModelSpec(
    id: 'gemma2-2b',
    displayName: 'Gemma 2 2B Instruct',
    shortName: 'Gemma 2B',
    sizeBytes: 1708582752,
    url:
        'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf?download=true',
    fileName: 'gemma-2-2b-it-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 8192,
  ),
  LocalModelSpec(
    id: 'qwen2.5-3b',
    displayName: 'Qwen2.5 3B Instruct',
    shortName: 'Qwen 3B',
    sizeBytes: 2104932768,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 32768,
  ),
  LocalModelSpec(
    id: 'phi-3-mini-4k',
    displayName: 'Phi-3 Mini 4K Instruct',
    shortName: 'Phi-3 Mini',
    sizeBytes: 2393231072,
    url:
        'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf?download=true',
    fileName: 'Phi-3-mini-4k-instruct-q4.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 4096,
  ),
  // 7B/8B-классу (Mistral 7B, Qwen2.5 7B, Llama 3.1 8B, EVA-Qwen2.5 7B) тут
  // больше нет места — на практике эти модели слишком тяжёлые для типичного
  // телефона и стабильно приводили к падениям приложения (нехватка памяти
  // под n_ctx*4 из-за квирка fllama, см. maxLocalContextSize). Каталог
  // сознательно ограничен моделями среднего размера с большим нативным
  // контекстом — оптимальный баланс качества письма/ролевой игры и
  // надёжности на устройстве.
  LocalModelSpec(
    id: 'llama-3.2-3b',
    displayName: 'Llama 3.2 3B Instruct',
    shortName: 'Llama 3B',
    sizeBytes: 2019377696,
    url:
        'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 131072,
  ),
  LocalModelSpec(
    id: 'phi-3.5-mini',
    displayName: 'Phi-3.5 Mini Instruct',
    shortName: 'Phi-3.5 Mini',
    sizeBytes: 2393232672,
    url:
        'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf?download=true',
    fileName: 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 131072,
  ),
];

String formatBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

/* ============================ ИСТОРИЯ ИЗМЕНЕНИЙ ============================ */
// Keep in sync with CHANGELOG.md — this is the in-app copy shown on the
// "About version" screen and in the post-update "what's new" dialog.

class ChangelogEntry {
  final String version;
  final List<String> changes;
  const ChangelogEntry(this.version, this.changes);
}

const List<ChangelogEntry> kChangelog = [
  ChangelogEntry('2.3.0', [
    'Темы теперь управляют и семантическими цветами: в палитру добавлены роли info/warn, а статусы подключения, полосы CPU/RAM/VRAM, тона баннеров, цвета типов команд и состояния визуализации следуют теме (success/danger/info/warn/accent) — новая тема перекрашивает эти элементы целиком.',
    'Убрана последняя остаточная лаванда (состояние «думает» у визуализации и мелкие иконки).',
  ]),
  ChangelogEntry('2.2.1', [
    'Исправлены невидимые на светлых темах рамки во всех карточках настроек, диалогах, полях ввода и разделителях — единый токен обводки следует теме.',
    'Выбранные состояния (движок распознавания и др.) и метки разделов теперь следуют акценту/теме, без жёстко-синего и «слепого» серого на кремовом.',
  ]),
  ChangelogEntry('2.2.0', [
    'Единая дизайн-система: общие токены цвета/типографики/отступов; карточки, строки, кнопки, слайдеры, переключатели и radio переведены на токены — корректные рамки и контраст на светлых темах во всём приложении.',
    'Темы курированы до трёх: Тёмная, Claude и Claude (тёмная). Steam/Apple/Discord убраны (сохранённая ранее из них тема автоматически переключается на Тёмную).',
    'Полностью убран остаточный фиолетовый — все акценты следуют текущей теме; цвет визуализации по умолчанию — терракота.',
    'Растушёвка краёв визуализации: волна на плавающем виджете больше не обрывается жёстким квадратом, а мягко растворяется по всем сторонам.',
    'Пузыри чата, меню моделей и баннер статуса распознавания переведены на токены (мягкие тени, тональные статусы, читаемость).',
  ]),
  ChangelogEntry('2.1.5', [
    'Добавлено: тёмная версия темы Claude (тёплый графит, кремовый текст, терракотовый акцент) — в списке тем «Claude (тёмная)».',
    'Улучшено: боковая колонка теперь кремовая/тёмная от самого верха до низа, а верх окна двухцветный (рейка слева, фон справа) — без «уступа» сверху.',
    'Исправлено: на светлых темах не было рамок вокруг метрик (CPU/RAM/VRAM) и панели микрофона; значение CPU было фиолетовым, логотип EVS — белым на кремовом.',
    'Исправлено: убран остаточный фиолет на светлых темах (бейдж «Слушаю», ссылки «Подробнее», иконки).',
  ]),
  ChangelogEntry('2.1.4', [
    'Исправлено: голосовой движок иногда не запускался («голосовой движок не запущен»), если при старте не удавалось загрузить манифест компонентов (нет сети) — выбирался старый сайдкар, не понимающий новых параметров. Теперь манифест кэшируется локально (работает офлайн), а при его отсутствии выбирается актуальный сайдкар.',
    'Исправлено: «Открыть папку моделей» открывала «Документы» вместо папки с моделями (из-за смешанных слэшей в пути).',
    'Улучшено: убраны оставшиеся фиолетовые тексты/иконки на светлых темах (ссылка «Подробнее» и др.) — теперь по цвету выбранной темы.',
  ]),
  ChangelogEntry('2.1.3', [
    'Дочерние процессы теперь различимы в диспетчере задач (вкладка «Подробности»): виджет визуализации запускается как evs_widget.exe — отдельно от evs.exe (главное приложение) и evs_sidecar.exe (голосовой движок), видно, за что отвечает каждый.',
  ]),
  ChangelogEntry('2.1.2', [
    'Исправлено: обновление не устанавливалось, а приложение уходило в петлю перезапуска — установщик обновления не переживал закрытие приложения и фактически не запускался (лог установки не появлялся ни разу). Теперь установка идёт отдельным самостоятельным процессом через планировщик задач и переживает выход приложения; каждый шаг пишется в update-runner.log.',
    'Примечание: этот фикс живёт ВНУТРИ обновления, поэтому текущую (сломанную) версию он вылечить не может — эту сборку нужно один раз установить вручную, дальше авто-обновления заработают штатно.',
  ]),
  ChangelogEntry('2.1.1', [
    'Акценты интерфейса теперь следуют выбранной теме (Claude — терракота, Apple — синий, Steam/Discord — свои): пузыри чата, визуализация, переключатели и выбранные пункты больше не фиолетовые по умолчанию.',
    'Светлые темы: текст стал читаемо-тёмным везде, включая выбранные (обведённые) настройки.',
    'Убрана кнопка голосового ввода из строки ввода — микрофон и так слушает команды постоянно.',
    'Настройки CosyVoice (голос/пресет, клонирование по образцу WAV, скорость, эмоция, устройство) теперь видны всегда — можно настроить заранее, до подъёма сервера.',
  ]),
  ChangelogEntry('2.1.0', [
    'Добавлено: светлые темы оформления — Apple (светлая) и Claude (кремовая), плюс Discord; выбираются в «Оформление». Интерфейс перекрашен под светлый фон: текст, рамки, диалоги и панели корректно читаются на белом.',
    'Добавлено: подсказка настройки голосовых команд при первом запуске — можно сразу предложить команды запуска для ваших приложений.',
    'Исправлено: окно обновления могло появляться при каждом запуске (петля перезапуска) — установщик теперь ставит новую версию поверх запущенной копии, и версия корректно обновляется.',
  ]),
  ChangelogEntry('2.0.3', [
    'Добавлено: приём команд с телефонов по сети (Tailscale/LAN) — раздел «Телефоны». Привязка по одноразовому коду или QR, у каждого телефона свои права (голос/текст) и токен; ответ озвучивается на десктопе и/или возвращается на телефон.',
    'Добавлено: выбор движка озвучки — Piper (офлайн) или CosyVoice (когда его сервер доступен); проверка соединения с CosyVoice.',
  ]),
  ChangelogEntry('2.0.2', [
    'Добавлено: умный подбор голосовых команд — ассистент сам предлагает команды запуска для ваших приложений (по частоте использования), фразы придумывает ИИ, пути берутся из системы.',
    'Добавлено: управление громкостью приложения голосом — «громкость на 30» ставит уровень конкретной программы (число можно словами).',
    'Добавлено: интерпретатор озвучки — перед синтезом убирает эмодзи и разметку, приводит текст к произносимому виду (правилами или через модель).',
    'Добавлено: раздел «Модель и инференс» — проверка соединения, обновление списка моделей, модель отдельно для поиска и чата, параметры (num_ctx, temperature, keep_alive) в блоке «Дополнительно».',
    'Добавлено: быстрые профили одним нажатием — Быстро / Качество / Поиск / Чат.',
    'Улучшено: раскладка настроек подстраивается под ширину окна (1/2/3 колонки), без пустот и «уехавших» карточек.',
  ]),
  ChangelogEntry('2.0.1', [
    'Исправлено: GigaAM, шумоподавление и голоса Piper не включались (ошибка «ORT Version» / «модель не найдена») — движок пересобран, конфликт библиотек устранён.',
    'Исправлено: Whisper иногда не открывался («Unable to open file model.bin») при переключении движков — теперь дожидается докачки модели.',
    'Исправлено: разъезжалась сетка настроек — большие пустоты и «уехавшие» карточки. Колонки набиваются независимо и подстраиваются под ширину окна.',
    'Исправлено: бейдж голосового движка всегда показывал «Whisper» — теперь показывает активную модель (GigaAM или Whisper).',
    'Улучшено: понятнее выбор распознавания — «Windows STT» или «Локальный (EVS)»; модели Whisper/GigaAM относятся только к локальному движку.',
    'Улучшено: визуализация «волна» больше не резкий квадрат (мягкие края) и меняет цвет по состоянию ассистента, как остальные визуализации.',
  ]),
  ChangelogEntry('2.0.0', [
    'Добавлено: шумоподавление микрофона (лёгкое/сильное), как в Discord — по умолчанию включено.',
    'Добавлено: новый движок распознавания GigaAM (лучшая точность для русского) + выбор движка и модели Whisper, у каждого варианта — «Подробнее».',
    'Добавлено: естественные голоса ассистента (Piper) — Ирина, Денис, Дмитрий, Руслан: скачать, прослушать образец, выбрать.',
    'Добавлено: менеджер моделей — скачивание/удаление движков распознавания, шумоподавления и голосов с прогрессом.',
    'Добавлено: выбор CPU/GPU для распознавания и игровой режим — авто-разгрузка видеокарты в полноэкранных играх и при нехватке видеопамяти (с голосовым уведомлением).',
    'Добавлено: несколько микрофонов одновременно (например, в разных комнатах) — своё шумоподавление на каждый, одна фраза выполняется один раз.',
    'Добавлено: голосовое уведомление «Готова слушать» при запуске и индикатор загрузки — ассистент больше не «глохнет» после старта.',
    'Добавлено: единая тема; окно и виджет запоминают размер и положение (в т.ч. на втором мониторе) и переживают обновление; кнопка «Сохранить/Отменить» в настройках; новые визуализаторы.',
    'Убрано: клонирование голоса (XTTS) — заменено естественными голосами Piper.',
  ]),
  ChangelogEntry('1.1.2', [
    'Исправлены «кракозябры» в названиях приложений из Microsoft Store (кодировка UTF-8).',
    'Тумблер «Чат» больше не растягивается на всю ширину.',
    'При неудачной команде показывается распознанный текст («Команда не найдена: …») — видно, что именно услышано.',
    'Ещё надёжнее установка обновлений: перед заменой файлов принудительно завершаются все процессы приложения (виджет/движки).',
  ]),
  ChangelogEntry('1.1.1', [
    'Надёжнее установка обновлений: перед заменой файлов приложение дожидается полного закрытия всех своих процессов (включая виджет), а затем само перезапускается. Если что-то пошло не так — пишется подробный лог установки (update-install.log) для диагностики.',
  ]),
  ChangelogEntry('1.1.0', [
    'Режим «только команды»: тумблер «Чат» в настройках — выключите, чтобы ассистент выполнял только команды. Нераспознанная фраза не уходит в чат, а отвечает «Команда не найдена»; текстовый ввод при этом отключается.',
    'Редактирование команд: у каждой команды появилась кнопка-карандаш — открывает мастер с уже заполненными полями.',
    'Приложения из Microsoft Store теперь попадают в список (включая Яндекс Музыку и другие Store-приложения/PWA) и запускаются командой.',
    'Точнее распознавание команд: убрана лишняя пунктуация и добавлено совпадение по словам (лишние слова/порядок больше не мешают). При уходе фразы в чат в лог пишется балл совпадения — для диагностики.',
    'Тест распознавания: распознанный текст можно выделить и скопировать, добавлена кнопка «Очистить».',
  ]),
  ChangelogEntry('1.0.13', [
    'Фраза-озвучка команды: при добавлении команды можно вписать фразу, которую ассистент произнесёт при её выполнении (например «Открываю Яндекс Музыку»). Работает при включённых голосовых ответах.',
    'В список программ для команд добавлены приложения из Microsoft Store — их теперь можно назначать на голосовые команды и запускать.',
    'В списке приложений при добавлении команды показываются их иконки.',
    'Портативный режим: если папка программы доступна для записи, все данные (движки, модели, чаты, настройки, логи) хранятся рядом с программой, а не в системной папке. Существующие данные переносятся автоматически.',
    'Удаление чатов на компьютере: правый клик по чату в боковой панели (или кнопка «⋮») открывает меню — переименовать, закрепить, удалить (с отменой).',
  ]),
  ChangelogEntry('1.0.12', [
    'Веб-поиск: ассистент сам ищет свежие данные в интернете (курс валют, погода, новости), когда вопрос этого требует, и отвечает по ним. Включается в «Модель», работает без ключа (DuckDuckGo) или с ключом Tavily/Brave.',
    'Исправлен микрофон, который «переставал слышать» после перезапуска: распознавание теперь надёжно перезапускается при каждом переподключении голосового движка. Тест распознавания снова показывает текст.',
    'Обновление больше не предлагается при каждом запуске и надёжнее устанавливается (закрытие старой версии перед заменой файлов); если установка не удалась — приложение сообщит об этом.',
    'Виджет запоминает своё положение: где оставили — там и появится после перезапуска.',
    'Удаление чата теперь можно отменить (кнопка «Отменить»). Раздел настроек распознавания больше не «съезжает».',
  ]),
  ChangelogEntry('1.0.11', [
    'Тест распознавания в настройках: произнесите фразу и сразу увидите, как её записал распознаватель — удобно подбирать фразу-триггер.',
    'Добавление команды переделано в пошаговый мастер: выбор типа (программа / файл / сайт / система / медиа) → для программы список установленных приложений → фраза-триггер.',
    'Убраны «встроенные» команды: теперь выполняются ТОЛЬКО добавленные вами команды. «Открой калькулятор/браузер/музыку» без добавления больше ничего не запускает.',
    'Виджет без текстовых плашек: прозрачная область больше, а реакции («услышал», «думаю», «выполняю») показываются сменой цвета с возвратом к исходному.',
  ]),
  ChangelogEntry('1.0.10', [
    'Один экземпляр приложения: повторный запуск ярлыка больше не открывает вторую копию, а разворачивает уже запущенное окно.',
    'Удаление чата правой кнопкой мыши: клик ПКМ по чату в списке открывает меню (переименовать / закрепить / удалить).',
    'Сфера Siri теперь с мягким, растушёванным краем вместо жёсткой линии по окружности.',
    'Быстрее озвучка ответов: ассистент начинает говорить первое предложение почти сразу, не дожидаясь генерации всего ответа (фразы идут подряд без обрыва).',
  ]),
  ChangelogEntry('1.0.9', [
    'Исправлен запуск голосового движка (иногда показывал «Не запущен»): фоновый процесс распознавания больше не зависает на старте.',
    'Все вспомогательные процессы (движок распознавания, виджет, синтез голоса) теперь гарантированно закрываются вместе с приложением — даже при аварийном завершении или снятии через диспетчер задач, ничего не остаётся висеть в фоне.',
  ]),
  ChangelogEntry('1.0.8', [
    'Лучше распознавание речи: подсказка распознавателю (слово-активатор + словарь команд) и более точный разбор завершённых фраз (шире поиск + перебор температур) — короткие команды слышатся стабильнее.',
    'Остановка голосом: скажите «стоп», «хватит» (или «EVS, стоп») — ассистент сразу прервёт озвучку и текущую генерацию ответа. Набор стоп-слов редактируется в настройках.',
    'Несколько адресов серверов: сохраняйте адреса локального/удалённого сервера и переключайтесь между ними в один тап (настройки → подключение).',
    'Плашка статуса больше не залипает: показывает только состояние (Слушаю / услышал активатор / ошибка), без зависающих распознанных фраз.',
    'Понимание команд улучшено: после активатора команды выполняются точнее (расширенный список действий и примеры для интерпретатора), а обычные вопросы по-прежнему уходят в чат.',
  ]),
  ChangelogEntry('1.0.7', [
    'Виджет стал отдельным окном (собственный процесс): чат и виджет видны одновременно, виджет всегда поверх окон, приложение стартует только виджетом у правого края.',
    'Починено распознавание речи: фразы теперь корректно завершаются и обрабатываются за секунды (VAD + шумовой гейт + сброс отстающей очереди), отфильтрованы галлюцинации Whisper («Субтитры…»), выбранный микрофон реально передаётся распознавателю, medium автоматически заменён на small (на CPU он обрабатывал фразу ~минуту).',
    'Голосовые команды больше не попадают в чат: каталог → нейросеть-интерпретатор (теперь реально работает: «открой…», «найди…» и т.п.) → выполнение; результат — голосом и бейджем на виджете.',
    'Стадии ассистента видны на виджете и в шапке: «услышал» → «Говорите команду…» (активатор без команды ждёт её отдельной фразой 8 секунд) → «Думаю…» → «Выполняю…» → «Выполнено».',
    'Виджет и визуализации реагируют только на голос ассистента; «Бары» и «Кольцо» двигаются строго вверх-вниз/по радиусу, без прокрутки и вращения.',
    'Логи commands/chat/errors в папке данных приложения.',
  ]),
  ChangelogEntry('1.0.6', [
    'EVS теперь открывается плавающим виджетом у правого края экрана: маленькое прозрачное окно поверх всех окон, перетаскивается мышью, двойной клик разворачивает чат, закрытие чата возвращает виджет.',
    'Два новых стиля визуализации — Siri Orb (цветные блобы с бликом) и Полоски (LiveKit-стиль), оба реагируют на реальный звук.',
    'Новый раздел настроек «Виджеты»: живой предпросмотр с имитацией голоса, выбор стиля, акцентный цвет, размер/скорость орба, число полосок и настройки плавающего виджета.',
    'Подключение модели теперь только через сервер: локальный (Ollama) по адресу или удалённый по адресу с API-ключом; загрузка локальных моделей убрана.',
    'Исправлен вылет при запуске с выбранной локальной моделью: сбойная модель теперь гарантированно отключается после первого падения.',
  ]),
  ChangelogEntry('1.0.5', [
    'Живые визуализации голоса: три варианта виджета (сфера, кольцо, бары) — реагируют на реальный звук с микрофона и на озвучку ответов, переключаются в настройках («Тип визуализации»).',
    'Видимая реакция на слово-активатор: при «EVS…» плашка вспыхивает «услышал, говорите!», визуализация даёт импульс.',
    'Окно обновления в стиле EVS: тёмный диалог со списком изменений и кнопками «Перезапустить»/«Позже» (появляется, когда обновление уже скачано).',
    'Озвучка ответов теперь транслирует уровень звука в интерфейс (виджеты «дышат» голосом ассистента).',
    'Обновлён список изменений (история версий EVS).',
  ]),
  ChangelogEntry('1.0.4', [
    'Обновления как в Discord: скачиваются в фоне, в приложении появляется плашка «Обновление · Перезапустить» — один клик, и новая версия открывается сама.',
    'Виджет микрофона на главном экране снова реагирует на звук (волна была заморожена из-за ошибки).',
    'Убраны пер-чатовые настройки и ролевая игра из десктопного чата — ассистент настраивается глобально в настройках EVS.',
    'Тогл «Автопроверка обновлений» стал рабочим.',
  ]),
  ChangelogEntry('1.0.3', [
    'Исправлен вылет приложения при запуске после скачивания локальной модели (сбойная модель отключается автоматически).',
    'Голосовые команды и кнопка запуска в каталоге теперь открывают приложения, ярлыки (.lnk) и ссылки.',
    'Виден отклик ассистента: что услышано, статус движка, уведомления о выполнении команд.',
    'Слово-активатор «EVS» распознаётся и в русской речи (транслитерация).',
  ]),
  ChangelogEntry('1.0.2', [
    'Голосовой ассистент «как у Алисы»: постоянное прослушивание со словом-активатором, выполнение команд из каталога, озвучка ответов.',
    'Клонирование голоса (XTTS): ответы вашим голосом из образца WAV 6–10 секунд, офлайн.',
    'Тонкие обновления: установщик ~15 МБ, тяжёлые компоненты (голосовой движок, клонирование) догружаются отдельно по требованию.',
    'Рабочий выбор модели Whisper, реальная плашка статуса нейросети с окном ошибки, настройки во всю ширину.',
  ]),
  ChangelogEntry('1.0.1', [
    'Автообновления через собственный канал (appcast + подписанные установщики).',
    'Первый цикл обновления проверен: 1.0.0 → 1.0.1.',
  ]),
  ChangelogEntry('1.0.0', [
    'Проект переименован из «Mirai» в «EVS» (Enhanced Voice System — система усовершенствованного голосового управления): новое отображаемое имя, заголовок окна, имя ассистента и метаданные приложения; исполняемый файл теперь evs.exe.',
    'EVS — это десктоп-ответвление (только Windows) от разработки Mirai; нумерация версий начинается заново с 1.0.0.',
  ]),
  ChangelogEntry('2.14.2', [
    'Экран «Подготовка модели»: при открытии чата с локальной моделью она заранее прогревается — видна карточка загрузки, поле ввода блокируется до готовности (первый ответ быстрее).',
    'Все всплывающие окна в стеклянном стиле теперь оформлены как Liquid Glass (полупрозрачные с размытием).',
    'Окно «Управление моделями» теперь открывается по центру экрана в общем стиле, а не выезжает снизу.',
    'Размер контекста локальной модели автоматически ограничивается под объём ОЗУ устройства — защита от вылетов при слишком большом контексте.',
    '«Жидкое стекло» переименовано в «Liquid Glass».',
  ]),
  ChangelogEntry('2.14.1', [
    'На iPhone — системный шрифт iOS (San Francisco), как в самой системе. На Android/ПК остаётся Nunito.',
    'Мелкие правки оформления: точки «печатает…» выровнены по центру пузыря; область названия модели в шапке — по размеру текста.',
  ]),
  ChangelogEntry('2.14.0', [
    'Под последним ответом нейросети — три кнопки (во всех чатах): Редактировать (правка прямо в пузыре), Перегенерировать (заново сгенерировать ответ), Продолжить (следующий ход ассистента по контексту, без вашей реплики).',
  ]),
  ChangelogEntry('2.13.2', [
    'Вкладки «Память»/«Ролевая игра» в стеклянном стиле — капсула с «парящей» пилюлей (сегмент-контрол iOS 26) вместо подчёркивания.',
    'Экран «Настройки этого чата» в стеклянном стиле получил собственный мягкий цветной фон вместо размытия живого чата за ним.',
  ]),
  ChangelogEntry('2.13.1', [
    'Лимит контекста в ролевой игре предлагает все значения до максимума модели (раньше обрезалось на 8192).',
    'Контекстные меню (⋮ у чата, долгое нажатие на сообщение) — в стиле «Жидкое стекло» с размытием.',
    'Экран «Настройки этого чата» в стеклянном стиле открывается полупрозрачным слоем поверх чата.',
    'Между строками настроек добавлены тонкие разделители.',
    'Уведомления всплывают по центру стеклянной «пилюлей», а не белой полосой снизу.',
    'Плитка чата в списке стала немного уже.',
    'Исправлено: свайп-открытие списка чатов больше не поднимает клавиатуру.',
  ]),
  ChangelogEntry('2.13.0', [
    'Список чатов открывается свайпом от левого края (полноэкранно); кнопка чатов из шапки убрана, настройки чата — справа, название модели по центру.',
    'Новый стиль «Жидкое стекло» (iOS 26) — в настройках под «Темой» пункт «Стиль приложения». Переоформлен весь интерфейс, включая тумблеры. Работает поверх любой темы.',
    'Чаты можно переименовывать — пункт «Переименовать» в меню чата (⋮).',
    'При запуске играет анимация: сфера приближается и растворяется, открывая чат. Тапом можно пропустить. Старый статичный сплэш убран.',
    'В ролевой игре у своего персонажа можно задать описание (внешность, характер, роль), не только имя.',
    'Обводка вокруг названия модели в шапке — тоньше, того же цвета, что у круглых кнопок, с отступом.',
  ]),
  ChangelogEntry('2.12.0', [
    'Переключатель ролевой игры убран из шапки чата — теперь он внутри вкладки «Ролевая игра», которая всегда видна рядом с «Память».',
    'В описание системного промпта ролевой игры добавлен пример использования {{user}} и {{char}}.',
    'Размер контекста для ролевых чатов больше не дублируется в двух вкладках — единственный лимит теперь на вкладке «Ролевая игра».',
    'Название модели в шапке чата — без «(на устройстве)», с акцентной обводкой.',
    'При прикреплении фото — миниатюра прямо в поле ввода, а не отдельный блок с именем файла.',
    'Из каталога локальных моделей убраны тяжёлые 7B/8B модели — часто приводили к нехватке памяти и падению приложения. Добавлены Llama 3.2 3B и Phi-3.5 Mini с контекстом 128K токенов.',
  ]),
  ChangelogEntry('2.11.1', [
    'Исправлен статус-бар на iOS (время, сеть, заряд батареи пропадали).',
    'В ролевой игре добавлен пресет длины ответа «Эпопея» (1000 токенов).',
    'Имена персонажей в ролевой игре надёжнее доходят до модели, даже при своём системном промпте без {{user}}.',
    'Настройки персонажей переразложены: «Мой персонаж» отдельно от «Роль ИИ».',
  ]),
  ChangelogEntry('2.11.0', [
    'Новая иконка приложения — светящийся синий орб с частицами вместо прежнего волнистого узора.',
    'Сплэш-экран при запуске теперь показывает тот же орб на фирменном фоне, для светлой и тёмной темы.',
  ]),
  ChangelogEntry('2.10.2', [
    'В конце настроек теперь видна версия приложения (номер версии и сборки).',
  ]),
  ChangelogEntry('2.10.1', [
    'Вкладка «Личность» временно скрыта из настроек персонализации — её слайдеры и переключатели всё ещё не давали заметной разницы в ответах модели.',
    'Дублирующий пункт «Персонализация» в общих настройках убран — он открывал тот же экран, что и «Память».',
  ]),
  ChangelogEntry('2.10.0', [
    'В каталог локальных моделей добавлена EVA-Qwen2.5 7B — файнтюн под ролевую игру, в отдельной категории «Для ролевой игры».',
    'Контроль размера контекста для локальных моделей перенесён из вкладки «Личность» в «Память»; максимум подстраивается под реально выбранную модель.',
    'Названия моделей в шапке чата и меню выбора стали короче, без версий и квантования.',
    'В шапке чата кнопки режима ролевой игры и настроек чата расположены друг под другом, область с названием модели стала заметно шире.',
    'В настройках персонализации и списке диалогов тап по пустому месту экрана скрывает клавиатуру — как и в самом чате.',
    'При прикреплении изображения — предупреждение, если выбранная модель не может видеть содержимое картинки.',
  ]),
  ChangelogEntry('2.9.2', [
    'Настройка «Эмодзи: Никогда» теперь гарантированно убирает эмодзи из ответа, а не просто намекает модели в системном промпте.',
  ]),
  ChangelogEntry('2.9.1', [
    'Ползунки личности (формальность, эмпатия, детализация, юмор, креативность) заметнее влияют на ответы — раньше движение в средней трети шкалы вообще ничего не меняло.',
    'У каждой настройки на вкладках «Личность» и «Ролевая игра» теперь есть короткое описание того, что именно она меняет.',
  ]),
  ChangelogEntry('2.9.0', [
    'Новый режим «Ролевая игра» для отдельного чата — модель фиксируется за этим чатом в момент включения.',
    'Вкладка «Ролевая игра»: имена персонажа и пользователя, системный промпт и сценарий, тонкая настройка генерации, блокнот мира, стоп-фразы и лимит контекста.',
    'Ответ модели в режиме ролевой игры появляется построчно по мере генерации, с кнопкой остановки.',
    'Баннер «Сжать память чата», когда история приближается к лимиту контекста.',
    'Защита от типичных для ролевых диалогов сбоев: модель не пишет реплики от имени пользователя, незакрытая разметка автоматически закрывается.',
  ]),
  ChangelogEntry('2.8.1', [
    'Проверка обновлений на Android больше не путает Android- и iOS-релизы репозитория при поиске последней версии.',
  ]),
  ChangelogEntry('2.8.0', [
    'В чате: тап по пустой области экрана скрывает клавиатуру; на iOS статус-бар и Dynamic Island больше не перекрываются содержимым чата.',
    'Настройки персонализации теперь реально применяются к локальным моделям среднего и мощного тиров, а не только к удалённым.',
    'Лёгкий тир локальных моделей убран из каталога — был слишком слабым для системного промпта.',
    'Вкладки «Личность»/«Память» переоформлены; для локальных моделей добавлен контроль размера контекста.',
    'Долгое нажатие на сообщение открывает меню: Копировать / В поле ввода / Запомнить / Забыть / Закрепить в контексте.',
    'В «Памяти»: сохранённые воспоминания и закреплённые сообщения чата, «Спрашивать перед сохранением», «Автосохранение полезных деталей».',
    'Прикрепление файлов — шторка снизу с реальной сеткой недавних фото из галереи и вкладкой «Файл».',
    'Кнопка отправки подсвечивается зелёным, когда есть текст или прикреплённый файл.',
    'Новый вариант темы «Серая» — нейтральная палитра без сине-фиолетового оттенка.',
    'В списке диалогов — карточка «Продолжить» с последним чатом и кнопкой «Возобновить».',
    'Шрифт по всему приложению заменён на Nunito.',
    'Голосовой ввод больше не выключает микрофон во время пауз в речи — сессия остаётся активной всё время на экране, выключается только по кнопке микрофона или при выходе с экрана.',
  ]),
  ChangelogEntry('2.7.3', [
    'На экране голосового ввода вокруг анимированной рамки добавлен мягкий рассеивающийся свет того же сине-фиолетового градиента, расходящийся к центру экрана.',
  ]),
  ChangelogEntry('2.7.2', [
    'Пока нейросеть генерирует ответ, вместо «Думаю…» — зацикленная анимация из трёх волнообразно подпрыгивающих точек.',
  ]),
  ChangelogEntry('2.7.1', [
    'Пузыри сообщений нейросети в чате окрашены тем же синим градиентом, что и акцентные кнопки.',
  ]),
  ChangelogEntry('2.7.0', [
    'Голосовой ввод больше не "засыпает" молча после паузы — распознавание автоматически перезапускается, а уже распознанный текст не теряется.',
    'Если микрофон не удаётся подключить вообще, экран голосового ввода теперь явно показывает ошибку с кнопкой «Повторить» вместо бесконечного «Подключение микрофона…».',
  ]),
  ChangelogEntry('2.6.1', [
    'Вкладки «Личность»/«Память» в настройках персонализации перенесены с левой боковой панели наверх, под заголовок экрана.',
  ]),
  ChangelogEntry('2.6.0', [
    'Экран «Память» (заметки, профиль «о вас», запретные темы/безопасность) объединён с экраном персонализации как вкладка сбоку — раньше «Память» всегда редактировала только общие настройки, даже если открыта из конкретного чата. Теперь обе вкладки сохраняются туда же, куда и настройки личности.',
  ]),
  ChangelogEntry('2.5.0', [
    'Настройки персонализации снова применяются к локальным моделям среднего и мощного тиров — раньше все локальные модели получали урезанный промпт, теперь это ограничение касается только самых слабых (лёгкий тир).',
    'Даже для лёгкого тира добавилась реакция на тон ответа и частоту эмодзи.',
  ]),
  ChangelogEntry('2.4.0', [
    'Подключён Shorebird Code Push: обычные обновления теперь прилетают в фоне небольшим патчем и применяются при следующем перезапуске приложения, без скачивания нового APK целиком. Крупные изменения по-прежнему идут через полный APK с GitHub.',
  ]),
  ChangelogEntry('2.3.2', [
    'Описание тира («Для слабых/старых телефонов…» и т.д.) на экране «Локальные модели» больше не обрезается посередине строки — теперь идёт на отдельной строке под названием тира и переносится целиком.',
  ]),
  ChangelogEntry('2.3.1', [
    'Убрана картинка со сплэш-экрана — теперь это просто фон фирменного цвета (светлый/тёмный), без изображения.',
  ]),
  ChangelogEntry('2.3.0', [
    'Локальные модели теперь получают сильно укороченный системный промпт (имя ассистента, длина ответа, запретные темы, кастомная инструкция) вместо полного набора директив персонализации — маленькие модели не справлялись с длинным промптом и путали его структуру с содержанием ответа.',
    'Проверка обновлений в настройках теперь показывает результат во всплывающем диалоговом окне (ошибка / последняя версия / доступно обновление с кнопкой «Скачать и установить») вместо короткого уведомления внизу экрана.',
  ]),
  ChangelogEntry('2.2.0', [
    'Убрана модель TinyLlama 1.1B Chat из каталога локальных моделей — слишком слабая, не справлялась с системным промптом и выдавала бессвязные ответы.',
    'Добавлена Gemma 2 2B Instruct (средний тир) — известна хорошим качеством именно обычного диалога при небольшом размере.',
    'Исправлен визуальный баг: пункт «Создать изображение» в меню выбора модели мог выходить за границы меню на узких экранах вместо аккуратной обрезки текста.',
  ]),
  ChangelogEntry('2.1.0', [
    'Сфера на экране голосового ввода теперь реагирует на громкость с микрофона в реальном времени: пульсирует сильнее, ярче светится и быстрее дрожит при громком звуке, и успокаивается в тишине.',
    'На Windows-сборке эффект не виден — нативный SAPI-плагин речи не передаёт уровень громкости; полноценно работает на Android (и должно — на iOS).',
  ]),
  ChangelogEntry('2.0.0', [
    'Приложение и репозиторий переименованы из «Alice AI» в «Mirai»: новое отображаемое имя, системный промпт ассистента, package name и applicationId/bundle id на всех платформах.',
    'Важно: из-за смены applicationId/bundle id уже установленные копии Alice AI не обновятся поверх — Mirai ставится как отдельное приложение, старое нужно удалить вручную.',
  ]),
  ChangelogEntry('1.7.1', [
    'Исправлена ошибка «exceeds the available context size» при разговоре с локальной моделью (TinyLlama и др.) — fllama делит запрошенный размер контекста на 4 параллельных слота, из-за чего модели реально доставалось только 512 токенов вместо 2048.',
    'Кнопка отправки в поле ввода больше не меняет размер при переходе в состояние «отправляется».',
  ]),
  ChangelogEntry('1.7.0', [
    'Новый пункт «О версии» в настройках («О приложении») — открывает экран со списком изменений по всем версиям приложения.',
    'После обновления приложения при первом запуске показывается всплывающее окно с описанием того, что изменилось в новой версии.',
  ]),
  ChangelogEntry('1.6.0', [
    'Экран голосового ввода: добавлена анимированная светящаяся рамка по краям экрана (тот же вращающийся синий/фиолетовый градиент, что и вокруг поля ввода текста).',
    'Цветовая гамма экрана голосового ввода (фон, сфера, акценты) перекрашена из бирюзовой в сине-фиолетовую, чтобы сочетаться с новой рамкой.',
  ]),
  ChangelogEntry('1.5.2', [
    'Исправлена миграция старых данных: заглушка «Alice Nano» и адрес сервера по умолчанию (192.168.1.100:11434), сохранённые версиями приложения до 1.4.1, теперь автоматически вычищаются при загрузке вместо того, чтобы выглядеть как настоящие сохранённые значения.',
    'Поле адреса сервера пустое по умолчанию и показывает серый пример-подсказку, пока пользователь не введёт свой адрес.',
  ]),
  ChangelogEntry('1.5.1', [
    'Единый синий градиент применён ко всем акцентным кнопкам («Новый чат», CTA в пустом списке чатов) и ползункам (размер шрифта, параметры персонализации).',
    'Шрифт по всему приложению стал на ступень менее жирным (w800→w700, w700→w600, w600→w500).',
    'Масштаб текста теперь учитывает системную настройку размера шрифта устройства, а не только внутренний слайдер приложения.',
  ]),
  ChangelogEntry('1.5.0', [
    'Настройки поведения модели теперь можно задать индивидуально для каждого чата: новая кнопка (значок «человек+шестерёнка») в верхней панели открывает экран персонализации именно для текущего чата. Если для чата заданы свои настройки, общие настройки приложения на него больше не влияют.',
  ]),
  ChangelogEntry('1.4.1', [
    'Убрана несуществующая модель-заглушка «Alice Nano»: при отсутствии подключения к серверу и нескачанных локальных моделей теперь честно показывается «Нет доступных моделей» вместо фейкового названия.',
  ]),
  ChangelogEntry('1.4.0', [
    'Проверка обновлений в настройках («О приложении» → «Проверить обновления»): сравнивает версию с последним релизом на GitHub, скачивает APK и запускает установку — без переходов по ссылкам (Android).',
    'Сфера на главном экране теперь по-настоящему разлетается на частицы при появлении клавиатуры и собирается обратно при скрытии (раньше — простое затухание/уменьшение).',
    'Увеличено количество частиц в сфере, добавлена случайная яркость каждой частицы — силуэт выглядит менее "идеально круглым".',
  ]),
  ChangelogEntry('1.3.0', [
    'Нативный сплэш-экран при запуске (свой дизайн вместо чёрного/белого экрана), отдельно для светлой и тёмной темы — Android (включая Android 12+), iOS, Web.',
    'Минимальная длительность показа сплэша (1.2с), чтобы он не "мигал" на быстрых устройствах.',
  ]),
  ChangelogEntry('1.2.0', [
    'Каталог локальных моделей расширен с 2 до 9: добавлены лёгкие (Qwen2.5 0.5B, Llama 3.2 1B), средние (Qwen2.5 3B, Phi-3 Mini) и мощные (Mistral 7B, Qwen2.5 7B, Llama 3.1 8B) варианты.',
    'Модели в экране «Локальные модели» сгруппированы по категориям устройств (лёгкие/средние/мощные) с разделителями.',
    'Список моделей сделан компактнее (карточки в одну строку вместо нескольких).',
  ]),
  ChangelogEntry('1.1.0', [
    'Локальный инференс на устройстве через fllama (llama.cpp/GGUF) — чат работает офлайн без сервера.',
    'Экран «Локальные модели»: скачивание с прогрессом, выбор, удаление.',
    'Исправления голосового ввода: разрешения микрофона на Android, надёжность переподключения, кнопка «Отправить».',
    'Новая иконка приложения (закруглённые углы, обрезка лишних полей).',
  ]),
  ChangelogEntry('1.0.0', [
    'Базовая версия: переименование приложения в Alice AI.',
  ]),
];

/* ============================ LLM PROVIDER PATTERN ============================ */
//
// Unifies the local (fllama) and remote (Ollama/OpenAI-compatible HTTP)
// backends behind one interface, so AppState.sendMessage() doesn't have to
// branch on isLocalModel() itself. Both implementations need a handful of
// AppState fields (selectedModel, serverUrl, persona...) and helpers
// (t(), buildSystemPrompt() via persona, _extractContent) — passed in via
// the AppState reference rather than duplicated, since these services
// aren't meant to be used outside AppState's own call path. Kept as plain
// classes in this file rather than split into their own files/packages —
// the project is deliberately single-file (see CLAUDE.md).

abstract class ILLMService {
  /// No-op placeholder for both backends today: fllama loads/caches GGUF
  /// weights lazily on the first fllamaChat() call (there's no separate
  /// "load" step to await), and the remote backend has nothing to connect
  /// ahead of time either. Kept on the interface for whichever backend
  /// eventually needs real setup (e.g. a local engine with an explicit
  /// load step) without having to change callers.
  Future<void> initialize();

  /// Local: the model file is actually downloaded. Remote: the server
  /// responds to a lightweight reachability check. Neither is a guarantee
  /// the next generateResponse/generateStream call will succeed (a local
  /// model can still fail to load, a server can still time out) — it's a
  /// best-effort check, not a hard contract.
  Future<bool> isAvailable();

  /// [history] is the conversation so far, NOT including the reply being
  /// generated (callers must not have appended a placeholder for it yet).
  Future<String> generateResponse(Conversation conv, List<ChatMessage> history);

  /// Same contract as [generateResponse], but emits the cumulative reply
  /// text so far on every update instead of waiting for the final string.
  Stream<String> generateStream(Conversation conv, List<ChatMessage> history);

  /// Best-effort interrupt for whichever generateResponse/generateStream
  /// call is currently in flight on this instance. Safe to call when
  /// nothing is running.
  Future<void> stopGeneration();

  /// Proactively load the model into memory so the first real reply is fast
  /// (and so the UI can show a "preparing model" state). Local: runs a tiny
  /// 1-token inference to force the GGUF to load. Remote: no-op (nothing to
  /// preload). Resolves when the model is ready (or immediately on failure).
  Future<void> warmUp(String modelKey);
}

// RP-mode chats lock in whichever model was selected the first time RP
// turned on for them (Conversation.rpConfig.lockedModel) — once locked, that
// chat keeps using it regardless of whatever AppState.selectedModel is set
// to globally afterwards. Non-RP chats always just follow the global model.
// Voice interpreter (settings TZ §3.2 / §7): clean the assistant's text before
// it is handed to TTS. The "rules" mode is a pure offline sanitizer — strip the
// markup a speech engine would read literally (`* # _ ~ ` | > [ ] { } \`) plus
// emoji, while KEEPING sentence punctuation (. , ! ? —) that drives pauses.
class VoiceInterpreter {
  static final RegExp _markup = RegExp(r'[*#_~`|>\[\]{}\\]');
  static final RegExp _emoji = RegExp(
    '[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2300}-\u{23FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );
  // A markdown link's brackets are stripped by _markup, leaving "text(url)";
  // drop the bare URL tail so TTS does not spell out "h-t-t-p-s…".
  static final RegExp _url = RegExp(r'\(?https?://\S+\)?');
  static final RegExp _spaces = RegExp(r'[ \t]{2,}');

  static String rules(String text) {
    var s = text.replaceAll(_emoji, '');
    s = s.replaceAll(_url, ' ');
    s = s.replaceAll(_markup, '');
    s = s.replaceAll(_spaces, ' ');
    // Trim each line, collapse 3+ blank lines to one, drop leading/trailing ws.
    s = s.split('\n').map((l) => l.trim()).join('\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  // System prompt for the "model" mode. The model rewrites for the ear: numbers
  // and dates as words, no emoji/markup, punctuation preserved. Reply is the
  // cleaned text only.
  static const String modelSystemPrompt =
      'Ты — нормализатор текста для синтеза речи. Перепиши текст так, чтобы его '
      'было естественно произнести вслух: числа и даты словами, убери эмодзи и '
      'разметку (* # _ ~ ` | > [ ] { }), сохрани знаки . , ! ? — для пауз. Ничего '
      'не добавляй и не комментируй — верни ТОЛЬКО очищенный текст.';
}

// Extract a number from a spoken phrase — digits ("на 30") or spelled-out
// Russian ("тридцать", "двадцать пять") — for parametric voice commands like
// "громкость на {N}" (new-features Ф2 §2.3, §2.7). Range is not enforced here;
// the caller clamps. Returns null when the phrase has no number.
class NumberWords {
  static const Map<String, int> _units = {
    'ноль': 0, 'один': 1, 'одна': 1, 'одну': 1, 'два': 2, 'две': 2, 'три': 3,
    'четыре': 4, 'пять': 5, 'шесть': 6, 'семь': 7, 'восемь': 8, 'девять': 9,
    'десять': 10, 'одиннадцать': 11, 'двенадцать': 12, 'тринадцать': 13,
    'четырнадцать': 14, 'пятнадцать': 15, 'шестнадцать': 16, 'семнадцать': 17,
    'восемнадцать': 18, 'девятнадцать': 19,
  };
  static const Map<String, int> _tens = {
    'двадцать': 20, 'тридцать': 30, 'сорок': 40, 'пятьдесят': 50,
    'шестьдесят': 60, 'семьдесят': 70, 'восемьдесят': 80, 'девяносто': 90,
    'сто': 100,
  };

  static int? extract(String text) {
    final lower = text.toLowerCase();
    final d = RegExp(r'\d+').firstMatch(lower);
    if (d != null) return int.tryParse(d.group(0)!);
    final words = lower.split(RegExp(r'[^а-яё]+')).where((w) => w.isNotEmpty);
    int? acc;
    for (final w in words) {
      final t = _tens[w];
      final u = _units[w];
      if (t != null) {
        acc = (acc ?? 0) + t;
      } else if (u != null) {
        acc = (acc ?? 0) + u;
      } else if (acc != null) {
        break; // the numeral run ended
      }
    }
    return acc;
  }
}

String _effectiveModelFor(AppState app, Conversation conv) {
  if (conv.rpModeEnabled) {
    final locked = conv.rpConfig?.lockedModel;
    if (locked != null && locked.isNotEmpty) return locked;
  }
  return app.selectedModel;
}

class LocalLLMService implements ILLMService {
  LocalLLMService(this.app);
  final AppState app;
  int? _activeRequestId;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAvailable() async {
    final spec = app.localSpecFor(app.selectedModel);
    if (spec == null) return false;
    final dir = await localModelsDirPath();
    return localModelFileExists('$dir/${spec.fileName}');
  }

  // Shared by generateResponse/generateStream so the prompt-construction
  // logic (system prompt + tier-based prompt builder + pinned context)
  // only lives in one place.
  Future<(String modelPath, List<Message> messages)?> _prepare(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    final key = _effectiveModelFor(app, conv);
    // Refuse a model that hard-crashed the native loader (would crash again).
    if (app.crashedLocalModels.contains(key)) return null;
    final spec = app.localSpecFor(key);
    if (spec == null) return null;
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return null;

    final rpActive = conv.rpModeEnabled && conv.rpConfig != null;
    final effectivePersona = conv.persona ?? app.persona;
    // Only the weakest (light-tier) models reliably break down on the full
    // multi-directive prompt — mid/high tier local models are capable
    // instruct models in their own right and should get full
    // personalization, same as remote models. RP mode always bypasses this
    // tier check: its own prompt (RPMemoryManager.buildSystemPrompt) is
    // short and user-authored by nature, so the problem buildLocalSystemPrompt
    // exists to solve doesn't really apply the same way.
    final systemPrompt = (rpActive
            ? RPMemoryManager.buildSystemPrompt(conv)
            : (spec.tier == LocalModelTier.light
                      ? effectivePersona.buildLocalSystemPrompt()
                      : effectivePersona.buildSystemPrompt()) +
                  conv.pinnedContextBlock()) +
        app.pendingWebContext; // live web results for this turn (may be empty)
    final effectiveHistory = rpActive
        ? RPMemoryManager.trimForContext(
            history,
            conv.rpConfig!.contextWindowLimit,
          )
        : history;

    final messages = <Message>[
      Message(Role.system, systemPrompt),
      ...effectiveHistory.map(
        (m) => Message(
          m.role == 'user' ? Role.user : Role.assistant,
          m.content.isNotEmpty
              ? m.content
              : '[Attached files: ${m.attachments.join(', ')}]',
        ),
      ),
    ];
    return (modelPath, messages);
  }

  OpenAiRequest _buildRequest(
    Conversation conv,
    String modelPath,
    List<Message> messages,
  ) {
    final effectivePersona = conv.persona ?? app.persona;
    final rpActive = conv.rpModeEnabled && conv.rpConfig != null;
    final sampling = rpActive ? conv.rpConfig?.sampling : null;
    // Defensive re-clamp: the UI control already keeps the relevant size
    // within the live model's range, but this guards the actual request too
    // in case the stored value predates a model switch. RP chats use their
    // own contextWindowLimit (Roleplay tab) as the single source of truth
    // instead of the persona's localContextSize (Memory tab) -- showing both
    // controls for the same chat used to let them disagree.
    final spec = app.localSpecFor(_effectiveModelFor(app, conv));
    // Clamp to the smaller of the model's native ceiling and what the device's
    // RAM can safely hold — this also rescues an already-saved oversized value
    // (e.g. 16384/32768 from before this cap existed) that would OOM-crash.
    final maxLocalContextSize = math.min(
      spec?.maxLocalContextSize ?? 4096,
      app.ramContextCeiling,
    );
    final requestedContextSize = rpActive
        ? conv.rpConfig!.contextWindowLimit
        : effectivePersona.localContextSize;
    final clampedContextSize = requestedContextSize > maxLocalContextSize
        ? maxLocalContextSize
        : requestedContextSize;
    return OpenAiRequest(
      messages: messages,
      modelPath: modelPath,
      // fllama hardcodes n_parallel=4 natively and ignores nParallel on
      // native platforms, splitting contextSize into 4 slots internally
      // (n_ctx_seq = n_ctx / 4). Requesting 4x the user-facing/effective
      // size gives back that much usable context.
      contextSize: clampedContextSize * 4,
      maxTokens: sampling?.maxResponseTokens ?? 512,
      temperature: sampling?.temperature ?? 0.7,
      topP: sampling?.topP ?? 1.0,
      presencePenalty: sampling?.repetitionPenalty ?? 1.1,
    );
  }

  @override
  Future<String> generateResponse(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    final prepared = await _prepare(conv, history);
    if (prepared == null) return app.t('localModelMissing');
    final (modelPath, messages) = prepared;

    final completer = Completer<String>();
    await setModelLoadingFlag(modelPath);
    // NB: fllamaChat returns as soon as the request is QUEUED — the native
    // load/inference continues on its own thread. The sentinel must stay on
    // disk until the first callback (= survived the crash-prone load), NOT
    // until fllamaChat returns, or a native crash leaves no trace.
    var cleared = false;
    try {
      await fllamaChat(_buildRequest(conv, modelPath, messages), (
        response,
        openaiJson,
        done,
      ) {
        if (!cleared) {
          cleared = true;
          unawaited(clearModelLoadingFlag());
        }
        if (done && !completer.isCompleted) completer.complete(response);
      });
    } catch (e) {
      if (!cleared) {
        cleared = true;
        unawaited(clearModelLoadingFlag());
      }
      if (!completer.isCompleted) {
        completer.complete('${app.t('unreachable')} ($e)');
      }
    }
    return completer.future;
  }

  @override
  Stream<String> generateStream(Conversation conv, List<ChatMessage> history) {
    final controller = StreamController<String>();
    () async {
      final prepared = await _prepare(conv, history);
      if (prepared == null) {
        controller.add(app.t('localModelMissing'));
        await controller.close();
        return;
      }
      final (modelPath, messages) = prepared;
      await setModelLoadingFlag(modelPath);
      var cleared = false;
      try {
        final requestId = await fllamaChat(
          _buildRequest(conv, modelPath, messages),
          (response, openaiJson, done) {
            // First callback = native side loaded past the crash-prone point.
            if (!cleared) {
              cleared = true;
              unawaited(clearModelLoadingFlag());
            }
            if (!controller.isClosed) controller.add(response);
            if (done && !controller.isClosed) controller.close();
          },
        );
        _activeRequestId = requestId;
      } catch (e) {
        if (!controller.isClosed) {
          controller.add('${app.t('unreachable')} ($e)');
          await controller.close();
        }
      } finally {
        if (!cleared) await clearModelLoadingFlag();
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> stopGeneration() async {
    final id = _activeRequestId;
    if (id != null) fllamaCancelInference(id);
  }

  @override
  Future<void> warmUp(String modelKey) async {
    final spec = app.localSpecFor(modelKey);
    if (spec == null) return;
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return;
    final completer = Completer<void>();
    // Native load can hard-crash the process — mark it so a crash is detected
    // on the next launch (see AppState.load / crashed-model handling).
    // fllamaChat only QUEUES the request (the load happens on a native
    // thread), so the sentinel is cleared on the first callback — clearing
    // right after fllamaChat returns would erase it before the crash.
    await setModelLoadingFlag(modelKey);
    var cleared = false;
    try {
      // Minimal 1-token request just to force the GGUF to load into memory
      // (and warm the OS file cache). We don't care about the output.
      await fllamaChat(
        OpenAiRequest(
          messages: [Message(Role.user, '.')],
          modelPath: modelPath,
          contextSize: 2048,
          maxTokens: 1,
        ),
        (response, openaiJson, done) {
          if (!cleared) {
            cleared = true;
            unawaited(clearModelLoadingFlag());
          }
          if (done && !completer.isCompleted) completer.complete();
        },
      );
    } catch (_) {
      if (!cleared) {
        cleared = true;
        unawaited(clearModelLoadingFlag());
      }
      if (!completer.isCompleted) completer.complete();
    }
    return completer.future;
  }
}

class RemoteLLMService implements ILLMService {
  RemoteLLMService(this.app);
  final AppState app;
  http.Client? _activeClient;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAvailable() async {
    if (app.serverUrl.trim().isEmpty) return false;
    try {
      final headers = <String, String>{};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final res = await http
          .get(Uri.parse('${app.baseUrl}/api/tags'), headers: headers)
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  List<Map<String, dynamic>> _buildMessages(
    Conversation conv,
    List<ChatMessage> history,
  ) {
    final rpActive = conv.rpModeEnabled && conv.rpConfig != null;
    final systemPrompt = (rpActive
            ? RPMemoryManager.buildSystemPrompt(conv)
            : (conv.persona ?? app.persona).buildSystemPrompt() +
                  conv.pinnedContextBlock()) +
        app.pendingWebContext; // live web results for this turn (may be empty)
    final effectiveHistory = rpActive
        ? RPMemoryManager.trimForContext(
            history,
            conv.rpConfig!.contextWindowLimit,
          )
        : history;
    return [
      {'role': 'system', 'content': systemPrompt},
      ...effectiveHistory.map(
        (m) => {
          'role': m.role,
          'content': m.content.isNotEmpty
              ? m.content
              : '[Attached files: ${m.attachments.join(', ')}]',
        },
      ),
    ];
  }

  // RP mode forwards RPSamplingConfig/stopSequences as Ollama's `options` and
  // keeps full control of sampling; everything else uses the user's global
  // inference options from Settings, which are omitted field-by-field when left
  // blank so the model default applies.
  Map<String, dynamic> _buildBody(
    Conversation conv,
    List<ChatMessage> history,
    bool stream,
  ) {
    final body = <String, dynamic>{
      // Per-mode override: a turn with live web results uses the search model,
      // everything else the chat model (both fall back to the global model when
      // unset). RP-locked chats keep their pinned model — handled inside.
      'model': app.modelForTurn(conv,
          isSearch: app.pendingWebContext.trim().isNotEmpty),
      'stream': stream,
      'messages': _buildMessages(conv, history),
    };
    if (conv.rpModeEnabled && conv.rpConfig != null) {
      final s = conv.rpConfig!.sampling;
      body['options'] = {
        'temperature': s.temperature,
        'top_p': s.topP,
        'repeat_penalty': s.repetitionPenalty,
        'num_predict': s.maxResponseTokens,
        if (conv.rpConfig!.stopSequences.isNotEmpty)
          'stop': conv.rpConfig!.stopSequences,
      };
    } else {
      final opts = app.llmOptions();
      if (opts.isNotEmpty) body['options'] = opts;
    }
    // Top-level in Ollama's API, not an `options` entry. It only controls how
    // long the model stays resident, so it is orthogonal to sampling and
    // applies to roleplay requests too.
    final ka = app.llmKeepAlive.trim();
    if (ka.isNotEmpty) body['keep_alive'] = ka;
    return body;
  }

  @override
  Future<String> generateResponse(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    final client = http.Client();
    _activeClient = client;
    try {
      final headers = {'Content-Type': 'application/json'};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final res = await client
          .post(
            Uri.parse('${app.baseUrl}/api/chat'),
            headers: headers,
            body: jsonEncode(_buildBody(conv, history, false)),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode == 200) {
        try {
          final data = jsonDecode(res.body);
          if (data is Map<String, dynamic>) {
            return app._extractContent(data) ?? '—';
          }
          return '—';
        } catch (_) {
          return '—';
        }
      }
      return '${app.t('serverError')} ${res.statusCode}: ${res.body}';
    } catch (e) {
      // A cancel-triggered client.close() lands here too; the caller checks
      // _genCancelled and drops this string rather than showing it.
      return '${app.t('unreachable')} ${app.baseUrl}.\n($e)\n\n${app.t('checkAddress')}';
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  @override
  Stream<String> generateStream(Conversation conv, List<ChatMessage> history) {
    final controller = StreamController<String>();
    () async {
      final headers = {'Content-Type': 'application/json'};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final client = http.Client();
      _activeClient = client;
      final buffer = StringBuffer();
      try {
        final request = http.Request('POST', Uri.parse('${app.baseUrl}/api/chat'))
          ..headers.addAll(headers)
          ..body = jsonEncode(_buildBody(conv, history, true));
        final streamedResponse = await client
            .send(request)
            .timeout(const Duration(seconds: 60));
        if (streamedResponse.statusCode != 200) {
          final body = await streamedResponse.stream.bytesToString();
          controller.add(
            '${app.t('serverError')} ${streamedResponse.statusCode}: $body',
          );
          return;
        }
        await streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
              if (line.trim().isEmpty) return;
              try {
                final data = jsonDecode(line);
                if (data is Map<String, dynamic>) {
                  final delta = app._extractContent(data);
                  if (delta != null && delta.isNotEmpty) {
                    buffer.write(delta);
                    controller.add(buffer.toString());
                  }
                }
              } catch (_) {
                // Partial/garbled line (e.g. mid-chunk on a slow
                // connection) — skip it, the stream keeps arriving.
              }
            });
      } catch (e) {
        // A cancel-triggered client.close() also lands here; only show an
        // error if nothing actually streamed yet, otherwise keep the
        // partial reply that's already on screen.
        if (buffer.isEmpty) {
          controller.add(
            '${app.t('unreachable')} ${app.baseUrl}.\n($e)\n\n${app.t('checkAddress')}',
          );
        }
      } finally {
        client.close();
        if (!controller.isClosed) await controller.close();
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> stopGeneration() async {
    _activeClient?.close();
  }

  @override
  Future<void> warmUp(String modelKey) async {}
}

/// Picks the active backend purely off [isLocal] — re-evaluated on every
/// access, so it always reflects the model currently selected in settings.
class LLMServiceFactory {
  LLMServiceFactory({
    required AppState app,
    required LocalLLMService local,
    required RemoteLLMService remote,
    required bool Function() isLocal,
  }) : _app = app,
       _local = local,
       _remote = remote,
       _isLocal = isLocal;

  final AppState _app;
  final LocalLLMService _local;
  final RemoteLLMService _remote;
  final bool Function() _isLocal;

  ILLMService get current => _isLocal() ? _local : _remote;

  // RP chats may have locked in a model of a different type (local/remote)
  // than whatever is currently selected globally — `current` alone isn't
  // enough for them, it only reflects the global selector.
  ILLMService forConversation(Conversation conv) =>
      _app.isLocalModel(_effectiveModelFor(_app, conv)) ? _local : _remote;

  Future<void> warmUp(String key) =>
      _app.isLocalModel(key) ? _local.warmUp(key) : _remote.warmUp(key);
}

/// Lightweight token-count approximation for context-budget purposes —
/// deliberately cheap (no I/O), since it's meant to be safe to call on
/// every keystroke rather than just once per request. English/Latin text
/// runs roughly 4 chars/token; Cyrillic tokenizes denser (smaller share of
/// most vocabs, more multi-byte UTF-8), roughly 2.5 chars/token. Both are
/// heuristics, not exact counts — for an exact local count, use
/// [estimateForLocalModel] instead.
class TokenCounter {
  static final RegExp _cyrillic = RegExp(r'[Ѐ-ӿ]');

  static int estimate(String text) {
    if (text.isEmpty) return 0;
    final cyrillicChars = _cyrillic.allMatches(text).length;
    final charsPerToken = cyrillicChars > text.length / 2 ? 2.5 : 4.0;
    return (text.length / charsPerToken).ceil();
  }

  /// Exact count via fllama's own tokenizer for the given local GGUF —
  /// only meaningful for the local backend. Remote APIs only report token
  /// counts after the fact, in their response usage stats, so there's
  /// nothing equivalent to call ahead of a request for them. Falls back to
  /// [estimate] if the model can't be tokenized (e.g. not downloaded).
  static Future<int> estimateForLocalModel(String text, String modelPath) async {
    try {
      return await fllamaTokenize(
        FllamaTokenizeRequest(input: text, modelPath: modelPath),
      );
    } catch (_) {
      return estimate(text);
    }
  }
}

/* ============================ СОСТОЯНИЕ ============================ */

// Selectable themes. Dark palettes (dark/steam/discord) ride the color seams +
// ThemeData cleanly. Light palettes (apple/claude) also switch, but their full
// readability over the remaining hardcoded dark-assuming colors is a
// compiler-in-the-loop pass (see APPLE-THEME-TODO.md).
// Curated theme set: a neutral dark plus the two Claude editorial palettes.
// (apple/steam/discord were dropped in the design-system consolidation; a saved
// legacy value migrates to `dark` via the orElse in the prefs load.)
enum AppThemeMode { dark, claude, claudeDark }

// Liquid Glass was removed — only the standard (solid) style remains. Kept as a
// single-value enum so the appStyle field / prefs migration stay graceful.
enum AppStyle { standard }

// Real connection/readiness state of the selected model, shown by the desktop
// status badge (and its detail dialog).
enum ConnectionStatus { connecting, connected, noModel, disconnected, error }

// ---- Asset models (STT / denoise / TTS voices) — TZ2 model manager ----
// Registry of downloadable non-GGUF models. Each lives in its own dir under
// <userdata>/models/<id>/; downloads reuse downloadFileWithProgress per file.
class AssetFile {
  final String name; // filename under models/<id>/
  final String url;
  final int size; // bytes — progress weighting + display
  const AssetFile(this.name, this.url, this.size);
}

class AssetModelSpec {
  final String id; // dir under <userdata>/models/
  final String family; // 'stt' | 'denoise' | 'tts-voice'
  final String name;
  final String descKey; // i18n key, short description
  final int ramMb; // RAM estimate for display
  final List<AssetFile> files;
  final String? voiceId; // Piper voice id (tts-voice family only)
  const AssetModelSpec({
    required this.id,
    required this.family,
    required this.name,
    required this.descKey,
    required this.ramMb,
    required this.files,
    this.voiceId,
  });
  int get totalSize => files.fold(0, (a, f) => a + f.size);
}

const String _hfGigaam =
    'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16/resolve/main';
const String _sherpaEnh =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models';
// Self-contained Piper voice bundles (model.onnx + tokens.txt + espeak-ng-data),
// downloaded as a .tar.bz2 the sidecar extracts on first load (TZ2 block 5).
const String _sherpaTts =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

const List<AssetModelSpec> kAssetModels = [
  AssetModelSpec(
    id: 'gigaam-v3',
    family: 'stt',
    name: 'GigaAM-v3',
    descKey: 'engGigaamShort',
    ramMb: 800,
    files: [
      AssetFile('encoder.int8.onnx', '$_hfGigaam/encoder.int8.onnx', 224570814),
      AssetFile('decoder.onnx', '$_hfGigaam/decoder.onnx', 3331651),
      AssetFile('joiner.onnx', '$_hfGigaam/joiner.onnx', 1440448),
      AssetFile('tokens.txt', '$_hfGigaam/tokens.txt', 196),
    ],
  ),
  AssetModelSpec(
    id: 'denoise-gtcrn',
    family: 'denoise',
    name: 'GTCRN (лёгкое)',
    descKey: 'dnLightShort',
    ramMb: 60,
    files: [AssetFile('gtcrn_simple.onnx', '$_sherpaEnh/gtcrn_simple.onnx', 535638)],
  ),
  AssetModelSpec(
    id: 'denoise-df',
    family: 'denoise',
    name: 'DeepFilterNet (сильное)',
    descKey: 'dnStrongShort',
    ramMb: 200,
    files: [
      AssetFile('dpdfnet_baseline.onnx',
          '$_sherpaEnh/dpdfnet_baseline.onnx', 8791035),
    ],
  ),
  // Piper TTS voices (ru_RU). Each is a self-contained sherpa bundle.
  AssetModelSpec(
    id: 'tts-irina',
    family: 'tts-voice',
    name: 'Ирина',
    descKey: 'voiceIrina',
    ramMb: 120,
    voiceId: 'ru_RU-irina-medium',
    files: [
      AssetFile('vits-piper-ru_RU-irina-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-irina-medium.tar.bz2', 67153308),
    ],
  ),
  AssetModelSpec(
    id: 'tts-denis',
    family: 'tts-voice',
    name: 'Денис',
    descKey: 'voiceDenis',
    ramMb: 120,
    voiceId: 'ru_RU-denis-medium',
    files: [
      AssetFile('vits-piper-ru_RU-denis-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-denis-medium.tar.bz2', 67190991),
    ],
  ),
  AssetModelSpec(
    id: 'tts-dmitri',
    family: 'tts-voice',
    name: 'Дмитрий',
    descKey: 'voiceDmitri',
    ramMb: 120,
    voiceId: 'ru_RU-dmitri-medium',
    files: [
      AssetFile('vits-piper-ru_RU-dmitri-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-dmitri-medium.tar.bz2', 67188551),
    ],
  ),
  AssetModelSpec(
    id: 'tts-ruslan',
    family: 'tts-voice',
    name: 'Руслан',
    descKey: 'voiceRuslan',
    ramMb: 120,
    voiceId: 'ru_RU-ruslan-medium',
    files: [
      AssetFile('vits-piper-ru_RU-ruslan-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-ruslan-medium.tar.bz2', 67210684),
    ],
  ),
];

class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  AppState(this.prefs);

  final _uuid = const Uuid();

  String lang = 'ru';
  String t(String key) => _i18n[lang]?[key] ?? _i18n['en']?[key] ?? key;

  AppThemeMode themeMode = AppThemeMode.dark;
  AppStyle appStyle = AppStyle.standard;

  // TZ2.2 settings draft: while the settings screen is open, _save() is deferred
  // and applied only on Save; Cancel re-reads the fields from prefs (which still
  // hold the last-saved values, since persistence was deferred). Backend
  // side-effects (STT model, mic device, autostart) are synced on Save/Cancel.
  bool _settingsEditing = false;
  bool settingsDirty = false;
  bool settingsApplying = false;
  // Snapshot of the settings values captured when the draft opened. Dirtiness is
  // computed by diffing the current values against this — so a control that
  // re-fires its setter with an IDENTICAL value (e.g. when a section is first
  // built on tab switch) no longer flips the "unsaved changes" state.
  String _savedSnapshot = '';
  bool get settingsEditing => _settingsEditing;
  bool haptics = true;
  bool showKeyboardOnLaunch = false;
  bool showPromptChips = true;
  double fontSize = 1.0;
  bool micAutoSend = true;
  int micPauseSeconds = 3;

  String serverUrl = '';
  String apiKey = '';
  // User-saved server addresses (local Ollama / remote API) for quick switching.
  List<String> savedServers = [];
  List<String> models = [];
  String selectedModel = '';
  bool loadingModels = false;
  String? modelsError;

  Set<String> downloadedLocalModelIds = {};
  // Local models whose native load crashed the process — never auto-warm these.
  Set<String> crashedLocalModels = {};
  // Set for one run if the last launch crashed loading this local model (used
  // to warn the user once).
  String? lastModelCrash;
  final Map<String, double> localDownloadProgress = {};
  final Set<String> _cancelledLocalDownloads = {};

  // Live-streaming generation (RP mode only — see sendMessage/Conversation.
  // rpModeEnabled). isGenerating drives the Stop Generation button; the
  // cancel callback is whatever the active backend (fllama/HTTP) needs to
  // actually interrupt itself.
  bool isGenerating = false;
  void Function()? _cancelGeneration;
  // Set when a cancel was requested (voice "stop" or the Stop button) so the
  // non-streaming path can drop the aborted reply instead of writing an error
  // message into the chat.
  bool _genCancelled = false;
  void cancelGeneration() {
    _genCancelled = true;
    _cancelGeneration?.call();
  }

  // Proactive local-model warm-up state: true while a downloaded local model
  // is being loaded into memory (via a tiny warm-up inference) so the UI can
  // show a "preparing model" screen. fllama gives no real load-progress on
  // native, so this is an indeterminate state whose start/end track the
  // actual warm-up. `_warmedModelKey` avoids re-warming the same model within
  // a session; `_warmupSeq` ignores stale completions after a model switch.
  bool isModelLoading = false;
  String? loadingModelKey;
  String? _warmedModelKey;
  int _warmupSeq = 0;

  Future<void> warmUpModelFor(Conversation? conv) async {
    final key = conv != null ? _effectiveModelFor(this, conv) : selectedModel;
    if (!isLocalModel(key)) {
      if (isModelLoading) {
        isModelLoading = false;
        notifyListeners();
      }
      return;
    }
    final spec = localSpecFor(key);
    if (spec == null) return;
    // Never auto-warm a model that hard-crashed the native loader before.
    if (crashedLocalModels.contains(key)) return;
    if (_warmedModelKey == key || isGenerating || isModelLoading) return;
    final dir = await localModelsDirPath();
    if (!await localModelFileExists('$dir/${spec.fileName}')) return;
    final seq = ++_warmupSeq;
    isModelLoading = true;
    loadingModelKey = key;
    notifyListeners();
    try {
      await _llmFactory.warmUp(key);
      _warmedModelKey = key;
    } catch (_) {
    } finally {
      if (seq == _warmupSeq) {
        isModelLoading = false;
        loadingModelKey = null;
        notifyListeners();
      }
    }
  }

  // Total device RAM in MB (via system_info_plus), detected once at startup.
  // Null until detected or if the platform/plugin can't report it.
  int? deviceRamMb;

  // Set by the Win32 SystemMonitor on Windows (system_info_plus returns null
  // there), so the context-size ceiling reflects real RAM instead of 4096.
  void setDeviceRamMb(int mb) {
    if (mb <= 0 || mb == deviceRamMb) return;
    deviceRamMb = mb;
    notifyListeners();
  }

  Future<void> _detectDeviceRam() async {
    try {
      final mb = await SystemInfoPlus.physicalMemory;
      if (mb != null && mb > 0) {
        deviceRamMb = mb;
        notifyListeners();
      }
    } catch (_) {
      // Plugin/platform may not report memory — leave null, fall back to the
      // safe default ceiling below.
    }
  }

  // Safe upper bound for the user-facing local-model context size (BEFORE the
  // fllama ×4 multiplier), derived from device RAM. The model's own native
  // ceiling (LocalModelSpec.maxLocalContextSize) can be far larger than the
  // phone can actually hold: e.g. Llama 3.2 3B advertises 131072, so the
  // control offered up to 32768 and 16384/32768 → n_ctx 65k/131k → OOM crash.
  // KV cache for a ~3B model is ≈112 KB/token and weights ≈2 GB, so we aim to
  // keep weights+KV well under ~65% of RAM. Tuned conservatively around the
  // user's data point (6 GB-class iPhone: 4096 ok, 16384 crashed).
  int get ramContextCeiling {
    final mb = deviceRamMb;
    if (mb == null) return 4096; // RAM unknown → safe middle ground.
    if (mb < 3500) return 1024; // ~3 GB
    if (mb < 5500) return 2048; // 4 GB
    if (mb < 7500) return 4096; // 6 GB (user's known-good)
    if (mb < 9500) return 8192; // 8 GB
    if (mb < 13000) return 16384; // 12 GB
    return 32768; // 16 GB+
  }

  // LLM provider pattern (see ILLMService above) — one instance of each
  // backend, picked per-call by the factory based on the currently
  // selected model. Kept as fields (not created fresh per call) so a
  // service instance's in-flight request/client survives long enough for
  // a later stopGeneration() to actually reach it.
  late final LocalLLMService _localLLM = LocalLLMService(this);
  late final RemoteLLMService _remoteLLM = RemoteLLMService(this);
  late final LLMServiceFactory _llmFactory = LLMServiceFactory(
    app: this,
    local: _localLLM,
    remote: _remoteLLM,
    isLocal: () => isLocalModel(selectedModel),
  );

  bool checkingForUpdate = false;
  String? updateCheckError;
  String? updateAvailableVersion;
  String? _updateApkUrl;
  double? updateDownloadProgress;
  String? lastSeenVersion;

  Personalization persona = Personalization();

  // EVS desktop additions.
  // How the model is reached: 'local' (on-device), 'localServer' (Ollama/LAN),
  // 'remote' (internet). localServer/remote both use serverUrl; this just
  // drives the Model settings UI and which fields apply.
  String inferenceMode = 'local';
  // Per-request inference options forwarded to Ollama. null / empty means "do
  // not send this field" so the model's own default applies — leaving a box
  // blank must not silently impose a value.
  int? llmNumCtx;
  int? llmNumPredict;
  double? llmTemperature;
  String llmKeepAlive = '';
  // Optional per-mode model overrides. Empty means "use whatever is selected
  // globally", which keeps the existing single-model behaviour intact — the
  // point is to let a RAG-tuned model answer search turns without changing what
  // ordinary chat uses.
  String searchModel = '';
  String chatModel = '';
  // User-defined voice commands (catalog). Execution lands in the native
  // phase; for now they are stored and editable.
  List<VoiceCommand> voiceCommands = [];
  // Remote input from phones over Tailscale/LAN (TZ §14). A local HTTP listener
  // (RemoteInputServer) accepts authorized text/voice commands. Off by default;
  // only paired devices (per-device token) may send.
  bool remoteInputEnabled = false;
  int remoteInputPort = 8770;
  String remoteResponseTarget = 'both'; // desktop_tts | phone_text | both
  List<RemoteDevice> remoteDevices = [];
  // First-run onboarding for the AI voice-command wizard (new-features Ф1 §1.4).
  // Set once the offer has been shown so it never nags on later launches — the
  // wizard stays available on demand from the commands screen.
  bool commandOnboardingSeen = false;
  // Desktop window/tray/startup preferences (applied by DesktopIntegration).
  bool autostart = false;
  bool minimizeToTray = true;
  bool closeToTray = true;
  // Voice input preferences.
  String inputDeviceId = ''; // '' = system default microphone
  // Per-device denoise mode (TZ2 block 8.1): deviceId -> off|light|strong. A
  // self-cleaning virtual mic (NVIDIA Broadcast/Krisp) defaults to off so the
  // signal isn't denoised twice; everything else defaults to light.
  final Map<String, String> deviceDenoise = {};
  static const List<String> kSelfCleaningMics = ['nvidia broadcast', 'krisp'];
  String _pendingMicHint = ''; // one-shot UI hint after auto-off on a clean mic
  // Extra active microphones (TZ2 block 8.2). The primary mic is inputDeviceId;
  // these are additional simultaneous inputs, each arbitrated by the sidecar.
  List<String> extraMicIds = [];
  String listenMode = 'continuous'; // 'continuous' | 'ptt'
  String sttLanguage = 'auto'; // 'auto' | 'ru' | 'en'
  String whisperModel = 'small'; // tiny | base | small | medium (sidecar)
  String sttEngine = 'whisper'; // 'whisper' (sidecar) | 'windows' (speech_to_text)
  // Sidecar recognition engine (TZ1): which model the sidecar uses. Distinct
  // from sttEngine above (sidecar-vs-native backend).
  String sttSidecarEngine = 'whisper'; // 'whisper' | 'gigaam'
  // Noise suppression before the VAD (TZ2 block 1). 'light' is the default but
  // needs the GTCRN model; the sidecar fail-safes to off until it's present.
  String denoiseMode = 'light'; // 'off' | 'light' | 'strong'
  // Compute device for GPU-capable engines (TZ2 block 6). Only Whisper has a
  // CUDA path here; the selector is hidden entirely when no GPU is detected.
  String sttDevice = 'cpu'; // 'cpu' | 'cuda'
  // Game mode (TZ2 block 7): auto-offload GPU engines to CPU under load.
  bool gameModeFullscreen = true; // trigger A: fullscreen foreground
  bool gameModeVram = true; // trigger B: VRAM saturation (needs NVML)
  double gameModeVramEnter = 85; // % to engage the VRAM trigger
  double gameModeVramExit = 65; // % to disengage (must be < enter)
  bool gameModeNotify = true; // speak on enter/exit; badge stays regardless
  List<String> gameModeExclusions = []; // exe names that don't count as games
  // Voice assistant / command recognition.
  String cmdMode = 'wakeword'; // 'wakeword' | 'separate' | 'first'
  String wakeWord = 'EVS';
  // Voice "stop" vocabulary (interrupts speech + generation). User-editable;
  // seeded with sensible defaults. Matched fuzzily on the first 1-2 tokens
  // after an optional wake word (see VoiceAssistant._isStopPhrase).
  static const List<String> kDefaultStopWords = [
    'стоп', 'стой', 'хватит', 'отмена', 'замолчи', 'тихо', 'прекрати',
    'заткнись', 'stop', 'cancel', 'quiet', 'enough',
  ];
  List<String> stopWords = List<String>.from(kDefaultStopWords);
  // Whisper decoding primer sent to the sidecar: the current wake word plus a
  // command/stop vocabulary, so recognition is biased toward the phrases the
  // assistant actually listens for.
  String get sttBiasPrompt {
    const vocab = 'Открой, закрой, запусти, останови, включи, выключи, найди, '
        'поставь, громкость, яркость, скриншот, музыка, браузер, блокнот.';
    final stops = stopWords.take(6).join(', ');
    return '$wakeWord. $vocab${stops.isEmpty ? '' : ' $stops.'}';
  }

  double cmdThreshold = 0.65; // 0..1 fuzzy phrase-match threshold
  String cmdConfirm = 'risky'; // 'always' | 'risky' | 'never'
  bool cmdEnabled = false; // allow command execution (off by default for safety)
  // Chat on/off. When false, EVS is a pure command assistant: voice that
  // doesn't match a command says "command not found" (never falls back to a
  // chat turn), and the text composer is disabled.
  bool chatEnabled = true;
  // Voice visualization.
  // 'sphere' | 'waves' | 'bars' | 'orb' (Siri Orb) | 'lkbars' (Полоски) |
  // 'wave3d' (Волны 3D) | 'waveflat' (Поле частиц) | 'none'
  String vizType = 'sphere';
  bool showVizBg = true;
  bool showPartial = true;
  // Widget appearance (the «Виджеты» settings section). Accent drives the
  // Siri Orb blob palette (HSL shifts) and the LK bars color.
  int vizAccent = 0xFFCC785C;
  double orbSize = 200; // 120..320 px
  double orbSpeed = 20; // seconds per rotation, 6..40
  int barCount = 7; // 3..13 bars
  // Floating widget: a SEPARATE always-on-top transparent window (own
  // process, see VizOverlayServer/VizOverlayApp) showing the voice
  // visualization. Enabled by default; it opens together with the app at the
  // right edge of the desktop while the chat window starts hidden.
  bool overlayMode = true; // widget on/off — persisted
  double overlaySize = 260; // widget window size, px (200 | 260 | 330)
  // Periodic background update checks (the in-app Discord-style updater).
  bool autoUpdateCheck = true;
  // Web search: when on, the assistant fetches live results for queries that
  // look like they need fresh info (WebSearchService.needed) and feeds them to
  // the model. Keyless DuckDuckGo by default; an optional Tavily/Brave API key
  // gives more reliable results.
  bool webSearchEnabled = false;
  String tavilyKey = '';
  String braveKey = '';
  // Retrieved web context for the CURRENT turn only — appended to the system
  // prompt, then cleared. Never persisted, never leaks into later turns.
  String pendingWebContext = '';
  // Voice responses (TTS).
  bool voiceResponses = false;
  // Speak a one-shot "готова слушать" greeting when the backend finishes
  // loading its STT models on launch (TZ3.4). On by default; the visual
  // ready-signal on the orb stays regardless of this toggle.
  bool announceReady = true;
  // TTS voice (TZ2 block 5): '' = system voice (pyttsx3, no download); otherwise
  // a Piper voice id (e.g. 'ru_RU-irina-medium'), synthesized by the sidecar.
  String ttsPiperVoice = '';
  double ttsRate = 1.0;
  double ttsVolume = 1.0;
  // Voice interpreter (settings TZ §3.2): normalize spoken text. Enabled with
  // 'rules' by default (TZ). 'model' rewrites via ttsInterpModel and falls back
  // to rules if that model is unreachable.
  bool ttsInterpEnabled = true;
  String ttsInterpMode = 'rules'; // 'rules' | 'model'
  String ttsInterpModel = 'qwen3-interp';
  bool _ttsInterpFellBack = false; // one-shot "fell back to rules" notice guard
  // TTS engine choice (settings TZ §3.2). Piper is the built-in offline engine;
  // CosyVoice is a separate HTTP server (GPU) — selectable only once its
  // endpoint responds. The server isn't deployed yet, so it stays unavailable.
  String ttsEngineChoice = 'piper'; // 'piper' | 'cosyvoice'
  String cosyvoiceEndpoint = '';
  // Transient (not persisted): null = unknown, true/false = last check result.
  bool? cosyvoiceOnline;
  // CosyVoice deep controls (settings TZ §3.2). UI + persisted state only for
  // now — synthesis routing to the server is wired once it's deployed and its
  // API confirmed (the app currently synthesizes only through Piper/pyttsx3).
  // `cosyvoiceVoice` — optional preset / spk_id for SFT-style models.
  // `cosyvoiceClonePath` + `cosyvoiceClonePromptText` — a WAV sample and the
  // text spoken in it, for zero-shot voice cloning. `cosyvoiceSpeed` — 0.5..2.0.
  // `cosyvoiceEmotion` — a preset that maps to an instruct phrase later;
  // `cosyvoiceInstruct` — optional free-text instruct override.
  // `cosyvoiceDevice` — 'cpu' | 'cuda' (RTX 3060).
  String cosyvoiceVoice = '';
  String cosyvoiceClonePath = '';
  String cosyvoiceClonePromptText = '';
  double cosyvoiceSpeed = 1.0;
  String cosyvoiceEmotion = 'neutral';
  String cosyvoiceInstruct = '';
  String cosyvoiceDevice = 'cuda'; // 'cpu' | 'cuda'

  // STT language resolved against the UI language when set to 'auto'.
  String get effectiveSttLanguage =>
      sttLanguage == 'auto' ? lang : sttLanguage;

  // Real readiness of the selected model for the status badge.
  ConnectionStatus get connectionStatus {
    if (loadingModels) return ConnectionStatus.connecting;
    final sel = selectedModel;
    if (sel.isEmpty) return ConnectionStatus.noModel;
    if (isLocalModel(sel)) {
      final id = sel.substring('local:'.length);
      return downloadedLocalModelIds.contains(id)
          ? ConnectionStatus.connected
          : ConnectionStatus.noModel; // selected but not downloaded yet
    }
    // Remote model.
    if (serverUrl.trim().isEmpty) return ConnectionStatus.disconnected;
    if (modelsError != null) return ConnectionStatus.error;
    if (models.where((m) => !isLocalModel(m)).isEmpty) {
      return ConnectionStatus.disconnected; // never reached the server yet
    }
    return ConnectionStatus.connected;
  }

  List<Conversation> conversations = [];
  Conversation? current;

  String get baseUrl {
    var u = serverUrl.trim();
    if (u.isEmpty) return 'http://localhost:11434';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  /// Silent one-shot LLM request: no conversation is touched, isGenerating
  /// stays false — used by the voice-command interpreter so commands never
  /// leak into the chat history. Returns null on any failure.
  // Only the dark theme ships today.
  bool get isDarkMode => true;

  Future<void> load() async {
    // Detect device RAM in the background (no await — the context-size ceiling
    // falls back to a safe default until it resolves).
    unawaited(_detectDeviceRam());
    lang = prefs.getString('lang') ?? 'ru';
    // Any legacy value (system/light/gray) migrates to the single dark theme.
    final tm = prefs.getString('themeMode') ?? 'dark';
    themeMode = AppThemeMode.values.firstWhere(
      (e) => e.name == tm,
      orElse: () => AppThemeMode.dark,
    );
    final as = prefs.getString('appStyle') ?? 'standard';
    appStyle = AppStyle.values.firstWhere(
      (e) => e.name == as,
      orElse: () => AppStyle.standard,
    );
    haptics = prefs.getBool('haptics') ?? true;
    showKeyboardOnLaunch = prefs.getBool('showKeyboardOnLaunch') ?? false;
    showPromptChips = prefs.getBool('showPromptChips') ?? true;
    fontSize = prefs.getDouble('fontSize') ?? 1.0;
    micAutoSend = prefs.getBool('micAutoSend') ?? true;
    micPauseSeconds = prefs.getInt('micPauseSeconds') ?? 3;
    serverUrl = prefs.getString('serverUrl') ?? '';
    savedServers = prefs.getStringList('savedServers') ?? [];
    // Absent key -> null -> parameter is not sent at all (see llmOptions).
    llmNumCtx = prefs.getInt('llmNumCtx');
    llmNumPredict = prefs.getInt('llmNumPredict');
    llmTemperature = prefs.getDouble('llmTemperature');
    llmKeepAlive = prefs.getString('llmKeepAlive') ?? '';
    searchModel = prefs.getString('searchModel') ?? '';
    chatModel = prefs.getString('chatModel') ?? '';
    // Migrate away placeholder values that earlier versions persisted as if
    // they were real user data.
    if (serverUrl == '192.168.1.100:11434') serverUrl = '';
    apiKey = prefs.getString('apiKey') ?? '';
    models = (prefs.getStringList('models') ?? [])
        .where((m) => m != 'Alice Nano')
        .toList();
    selectedModel =
        prefs.getString('selectedModel') ??
        (models.isNotEmpty ? models.first : '');
    if (selectedModel == 'Alice Nano') {
      selectedModel = models.isNotEmpty ? models.first : '';
    }
    downloadedLocalModelIds =
        (prefs.getStringList('downloadedLocalModelIds') ?? []).toSet();
    crashedLocalModels =
        (prefs.getStringList('crashedLocalModels') ?? []).toSet();
    // Detect a native model-load crash from the previous run: if the loading
    // sentinel survived (fllama crashed the whole process before it could be
    // cleared), disable that model and switch to a remote one so the app can
    // start instead of crash-looping.
    final crashedFlag = await readModelLoadingFlag();
    if (crashedFlag != null) {
      await clearModelLoadingFlag();
      if (isLocalModel(selectedModel)) {
        crashedLocalModels.add(selectedModel);
        lastModelCrash = selectedModel;
        final remote = models.where((m) => !isLocalModel(m)).toList();
        selectedModel = remote.isNotEmpty ? remote.first : '';
        // Persist immediately so a force-kill before the next save can't leave
        // the crashing model selected again.
        await prefs.setString('selectedModel', selectedModel);
        await prefs.setStringList(
            'crashedLocalModels', crashedLocalModels.toList());
      }
    }
    lastSeenVersion = prefs.getString('lastSeenVersion');
    inferenceMode = prefs.getString('inferenceMode') ?? 'localServer';
    // Desktop is remote-only now: migrate installs that still point at
    // on-device inference (the mode was removed from the settings UI).
    if (inferenceMode == 'local') inferenceMode = 'localServer';
    if (isLocalModel(selectedModel)) {
      final remote = models.where((m) => !isLocalModel(m)).toList();
      selectedModel = remote.isNotEmpty ? remote.first : '';
    }
    autostart = prefs.getBool('autostart') ?? false;
    minimizeToTray = prefs.getBool('minimizeToTray') ?? true;
    closeToTray = prefs.getBool('closeToTray') ?? true;
    inputDeviceId = prefs.getString('inputDeviceId') ?? '';
    extraMicIds = prefs.getStringList('extraMicIds') ?? <String>[];
    deviceDenoise.clear();
    try {
      final raw = prefs.getString('deviceDenoise');
      if (raw != null && raw.isNotEmpty) {
        (jsonDecode(raw) as Map).forEach(
            (k, v) => deviceDenoise[k.toString()] = v.toString());
      }
    } catch (_) {}
    listenMode = prefs.getString('listenMode') ?? 'continuous';
    sttLanguage = prefs.getString('sttLanguage') ?? 'auto';
    whisperModel = prefs.getString('whisperModel') ?? 'small';
    // One-time rescue (1.0.7): medium/large are unusable on CPU — measured
    // ~50 s per utterance on this class of hardware, the audio queue grows
    // faster than it drains and the assistant appears completely dead. Reset
    // to small once; the user can still explicitly pick medium again.
    if (!(prefs.getBool('whisperCpuMigrated') ?? false)) {
      await prefs.setBool('whisperCpuMigrated', true);
      if (whisperModel == 'medium' || whisperModel == 'large') {
        whisperModel = 'small';
        await prefs.setString('whisperModel', whisperModel);
      }
    }
    sttEngine = prefs.getString('sttEngine') ?? 'whisper';
    sttSidecarEngine = prefs.getString('sttSidecarEngine') ?? 'whisper';
    denoiseMode = prefs.getString('denoiseMode') ?? 'light';
    sttDevice = prefs.getString('sttDevice') ?? 'cpu';
    gameModeFullscreen = prefs.getBool('gameModeFullscreen') ?? true;
    gameModeVram = prefs.getBool('gameModeVram') ?? true;
    gameModeVramEnter = prefs.getDouble('gameModeVramEnter') ?? 85;
    gameModeVramExit = prefs.getDouble('gameModeVramExit') ?? 65;
    gameModeNotify = prefs.getBool('gameModeNotify') ?? true;
    gameModeExclusions = prefs.getStringList('gameModeExclusions') ?? <String>[];
    cmdMode = prefs.getString('cmdMode') ?? 'wakeword';
    wakeWord = prefs.getString('wakeWord') ?? 'EVS';
    final sw = prefs.getStringList('stopWords');
    stopWords = (sw == null || sw.isEmpty)
        ? List<String>.from(kDefaultStopWords)
        : sw;
    cmdThreshold = prefs.getDouble('cmdThreshold') ?? 0.65;
    cmdConfirm = prefs.getString('cmdConfirm') ?? 'risky';
    cmdEnabled = prefs.getBool('cmdEnabled') ?? false;
    chatEnabled = prefs.getBool('chatEnabled') ?? true;
    vizType = prefs.getString('vizType') ?? 'sphere';
    showVizBg = prefs.getBool('showVizBg') ?? true;
    showPartial = prefs.getBool('showPartial') ?? true;
    overlayMode = prefs.getBool('overlayMode') ?? true;
    overlaySize = prefs.getDouble('overlaySize') ?? 260;
    vizAccent = prefs.getInt('vizAccent') ?? 0xFFCC785C;
    orbSize = prefs.getDouble('orbSize') ?? 200;
    orbSpeed = prefs.getDouble('orbSpeed') ?? 20;
    barCount = prefs.getInt('barCount') ?? 7;
    autoUpdateCheck = prefs.getBool('autoUpdateCheck') ?? true;
    webSearchEnabled = prefs.getBool('webSearchEnabled') ?? false;
    tavilyKey = prefs.getString('tavilyKey') ?? '';
    braveKey = prefs.getString('braveKey') ?? '';
    voiceResponses = prefs.getBool('voiceResponses') ?? false;
    announceReady = prefs.getBool('announceReady') ?? true;
    ttsPiperVoice = prefs.getString('ttsPiperVoice') ?? '';
    ttsRate = prefs.getDouble('ttsRate') ?? 1.0;
    ttsVolume = prefs.getDouble('ttsVolume') ?? 1.0;
    ttsInterpEnabled = prefs.getBool('ttsInterpEnabled') ?? true;
    ttsInterpMode = prefs.getString('ttsInterpMode') ?? 'rules';
    ttsInterpModel = prefs.getString('ttsInterpModel') ?? 'qwen3-interp';
    ttsEngineChoice = prefs.getString('ttsEngineChoice') ?? 'piper';
    cosyvoiceEndpoint = prefs.getString('cosyvoiceEndpoint') ?? '';
    cosyvoiceVoice = prefs.getString('cosyvoiceVoice') ?? '';
    cosyvoiceClonePath = prefs.getString('cosyvoiceClonePath') ?? '';
    cosyvoiceClonePromptText =
        prefs.getString('cosyvoiceClonePromptText') ?? '';
    cosyvoiceSpeed = prefs.getDouble('cosyvoiceSpeed') ?? 1.0;
    cosyvoiceEmotion = prefs.getString('cosyvoiceEmotion') ?? 'neutral';
    cosyvoiceInstruct = prefs.getString('cosyvoiceInstruct') ?? '';
    cosyvoiceDevice = prefs.getString('cosyvoiceDevice') ?? 'cuda';
    final vcRaw = prefs.getString('voiceCommands');
    if (vcRaw != null) {
      try {
        final decoded = jsonDecode(vcRaw);
        if (decoded is List) {
          voiceCommands = decoded
              .map((e) => VoiceCommand.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
    remoteInputEnabled = prefs.getBool('remoteInputEnabled') ?? false;
    remoteInputPort = prefs.getInt('remoteInputPort') ?? 8770;
    remoteResponseTarget = prefs.getString('remoteResponseTarget') ?? 'both';
    commandOnboardingSeen = prefs.getBool('commandOnboardingSeen') ?? false;
    final rdRaw = prefs.getString('remoteDevices');
    if (rdRaw != null) {
      try {
        final decoded = jsonDecode(rdRaw);
        if (decoded is List) {
          remoteDevices = decoded
              .map((e) => RemoteDevice.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }

    final pj = prefs.getString('persona');
    if (pj != null) {
      try {
        final decoded = jsonDecode(pj);
        if (decoded is Map<String, dynamic>) {
          persona = Personalization.fromJson(decoded);
        }
      } catch (_) {}
    }

    final raw = prefs.getString('conversations');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          conversations = decoded
              .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {
        conversations = [];
      }
    }
    notifyListeners();
    fetchModels();
  }

  // Stable string of every user-editable setting, used to detect REAL changes in
  // draft mode (see `_savedSnapshot`). Excludes volatile non-settings data
  // (conversations, model lists, paired devices) that can change outside the
  // settings screen and shouldn't count as an unsaved edit.
  String _settingsSnapshot() => <Object?>[
        lang, themeMode.name, appStyle.name, haptics, showKeyboardOnLaunch,
        showPromptChips, fontSize, micAutoSend, micPauseSeconds, serverUrl,
        savedServers.join(','), llmNumCtx, llmNumPredict, llmTemperature,
        llmKeepAlive, searchModel, chatModel, apiKey, selectedModel, inferenceMode,
        autostart, minimizeToTray, closeToTray, inputDeviceId, extraMicIds.join(','),
        jsonEncode(deviceDenoise), listenMode, sttLanguage, whisperModel, sttEngine,
        sttSidecarEngine, denoiseMode, sttDevice, gameModeFullscreen, gameModeVram,
        gameModeVramEnter, gameModeVramExit, gameModeNotify,
        gameModeExclusions.join(','), cmdMode, wakeWord, stopWords.join(','),
        cmdThreshold, cmdConfirm, cmdEnabled, chatEnabled, vizType, showVizBg,
        showPartial, overlayMode, overlaySize, vizAccent, orbSize, orbSpeed,
        barCount, autoUpdateCheck, webSearchEnabled, tavilyKey, braveKey,
        voiceResponses, announceReady, ttsPiperVoice, ttsRate, ttsVolume,
        ttsInterpEnabled, ttsInterpMode, ttsInterpModel, ttsEngineChoice,
        cosyvoiceEndpoint, cosyvoiceVoice, cosyvoiceClonePath,
        cosyvoiceClonePromptText, cosyvoiceSpeed, cosyvoiceEmotion,
        cosyvoiceInstruct, cosyvoiceDevice,
        jsonEncode(voiceCommands.map((c) => c.toJson()).toList()),
        remoteInputEnabled, remoteInputPort, remoteResponseTarget,
        jsonEncode(persona.toJson()),
      ].join('');

  Future<void> _save() async {
    if (_settingsEditing) {
      // Draft mode: defer persistence to Save. Flag dirty only when the values
      // actually differ from the snapshot taken when the draft opened — an
      // idempotent setter re-fire (e.g. on section switch) is not an edit.
      settingsDirty = _settingsSnapshot() != _savedSnapshot;
      return;
    }
    await prefs.setString('lang', lang);
    await prefs.setString('themeMode', themeMode.name);
    await prefs.setString('appStyle', appStyle.name);
    await prefs.setBool('haptics', haptics);
    await prefs.setBool('showKeyboardOnLaunch', showKeyboardOnLaunch);
    await prefs.setBool('showPromptChips', showPromptChips);
    await prefs.setDouble('fontSize', fontSize);
    await prefs.setBool('micAutoSend', micAutoSend);
    await prefs.setInt('micPauseSeconds', micPauseSeconds);
    await prefs.setString('serverUrl', serverUrl);
    await prefs.setStringList('savedServers', savedServers);
    // Remove rather than write a sentinel: "unset" has to survive a restart,
    // otherwise a cleared field would come back as a real value.
    if (llmNumCtx == null) {
      await prefs.remove('llmNumCtx');
    } else {
      await prefs.setInt('llmNumCtx', llmNumCtx!);
    }
    if (llmNumPredict == null) {
      await prefs.remove('llmNumPredict');
    } else {
      await prefs.setInt('llmNumPredict', llmNumPredict!);
    }
    if (llmTemperature == null) {
      await prefs.remove('llmTemperature');
    } else {
      await prefs.setDouble('llmTemperature', llmTemperature!);
    }
    await prefs.setString('llmKeepAlive', llmKeepAlive);
    await prefs.setString('searchModel', searchModel);
    await prefs.setString('chatModel', chatModel);
    await prefs.setString('apiKey', apiKey);
    await prefs.setStringList('models', models);
    await prefs.setString('selectedModel', selectedModel);
    await prefs.setStringList(
      'downloadedLocalModelIds',
      downloadedLocalModelIds.toList(),
    );
    await prefs.setStringList(
        'crashedLocalModels', crashedLocalModels.toList());
    await prefs.setString('persona', jsonEncode(persona.toJson()));
    await prefs.setString('inferenceMode', inferenceMode);
    await prefs.setBool('autostart', autostart);
    await prefs.setBool('minimizeToTray', minimizeToTray);
    await prefs.setBool('closeToTray', closeToTray);
    await prefs.setString('inputDeviceId', inputDeviceId);
    await prefs.setStringList('extraMicIds', extraMicIds);
    await prefs.setString('deviceDenoise', jsonEncode(deviceDenoise));
    await prefs.setString('listenMode', listenMode);
    await prefs.setString('sttLanguage', sttLanguage);
    await prefs.setString('whisperModel', whisperModel);
    await prefs.setString('sttEngine', sttEngine);
    await prefs.setString('sttSidecarEngine', sttSidecarEngine);
    await prefs.setString('denoiseMode', denoiseMode);
    await prefs.setString('sttDevice', sttDevice);
    await prefs.setBool('gameModeFullscreen', gameModeFullscreen);
    await prefs.setBool('gameModeVram', gameModeVram);
    await prefs.setDouble('gameModeVramEnter', gameModeVramEnter);
    await prefs.setDouble('gameModeVramExit', gameModeVramExit);
    await prefs.setBool('gameModeNotify', gameModeNotify);
    await prefs.setStringList('gameModeExclusions', gameModeExclusions);
    await prefs.setString('cmdMode', cmdMode);
    await prefs.setString('wakeWord', wakeWord);
    await prefs.setStringList('stopWords', stopWords);
    await prefs.setDouble('cmdThreshold', cmdThreshold);
    await prefs.setString('cmdConfirm', cmdConfirm);
    await prefs.setBool('cmdEnabled', cmdEnabled);
    await prefs.setBool('chatEnabled', chatEnabled);
    await prefs.setString('vizType', vizType);
    await prefs.setBool('showVizBg', showVizBg);
    await prefs.setBool('showPartial', showPartial);
    await prefs.setBool('overlayMode', overlayMode);
    await prefs.setDouble('overlaySize', overlaySize);
    await prefs.setInt('vizAccent', vizAccent);
    await prefs.setDouble('orbSize', orbSize);
    await prefs.setDouble('orbSpeed', orbSpeed);
    await prefs.setInt('barCount', barCount);
    await prefs.setBool('autoUpdateCheck', autoUpdateCheck);
    await prefs.setBool('webSearchEnabled', webSearchEnabled);
    await prefs.setString('tavilyKey', tavilyKey);
    await prefs.setString('braveKey', braveKey);
    await prefs.setBool('voiceResponses', voiceResponses);
    await prefs.setBool('announceReady', announceReady);
    await prefs.setString('ttsPiperVoice', ttsPiperVoice);
    await prefs.setDouble('ttsRate', ttsRate);
    await prefs.setDouble('ttsVolume', ttsVolume);
    await prefs.setBool('ttsInterpEnabled', ttsInterpEnabled);
    await prefs.setString('ttsInterpMode', ttsInterpMode);
    await prefs.setString('ttsInterpModel', ttsInterpModel);
    await prefs.setString('ttsEngineChoice', ttsEngineChoice);
    await prefs.setString('cosyvoiceEndpoint', cosyvoiceEndpoint);
    await prefs.setString('cosyvoiceVoice', cosyvoiceVoice);
    await prefs.setString('cosyvoiceClonePath', cosyvoiceClonePath);
    await prefs.setString('cosyvoiceClonePromptText', cosyvoiceClonePromptText);
    await prefs.setDouble('cosyvoiceSpeed', cosyvoiceSpeed);
    await prefs.setString('cosyvoiceEmotion', cosyvoiceEmotion);
    await prefs.setString('cosyvoiceInstruct', cosyvoiceInstruct);
    await prefs.setString('cosyvoiceDevice', cosyvoiceDevice);
    await prefs.setString(
      'voiceCommands',
      jsonEncode(voiceCommands.map((c) => c.toJson()).toList()),
    );
    await prefs.setBool('remoteInputEnabled', remoteInputEnabled);
    await prefs.setInt('remoteInputPort', remoteInputPort);
    await prefs.setString('remoteResponseTarget', remoteResponseTarget);
    await prefs.setBool('commandOnboardingSeen', commandOnboardingSeen);
    await prefs.setString('remoteDevices',
        jsonEncode(remoteDevices.map((d) => d.toJson()).toList()));
    await prefs.setString(
      'conversations',
      jsonEncode(conversations.map((c) => c.toJson()).toList()),
    );
  }

  // ---- TZ2.2 settings draft controls ----

  // Arm draft mode when the settings screen opens: further setter calls preview
  // live but defer persistence until Save.
  void beginSettingsEdit() {
    _settingsEditing = true;
    settingsDirty = false;
    settingsApplying = false;
    _savedSnapshot = _settingsSnapshot();
  }

  // Save: persist the current fields and sync the backend. On failure, revert to
  // the last-saved values and report it (prefs are left as they were).
  Future<bool> commitSettingsEdit() async {
    if (!_settingsEditing) return true;
    settingsApplying = true;
    notifyListeners();
    var ok = true;
    try {
      _settingsEditing = false;
      await _save();
      await _applySettingsSideEffects();
      settingsDirty = false;
    } catch (_) {
      ok = false;
      _restoreSettingsFields();
      try {
        await _applySettingsSideEffects();
      } catch (_) {}
      settingsDirty = false;
    } finally {
      settingsApplying = false;
      notifyListeners();
    }
    return ok;
  }

  // Cancel: drop the live-previewed changes by re-reading the fields from prefs
  // (unchanged since persistence was deferred), then resync the backend.
  Future<void> cancelSettingsEdit() async {
    if (!_settingsEditing) return;
    _settingsEditing = false;
    _restoreSettingsFields();
    settingsDirty = false;
    await _applySettingsSideEffects();
    notifyListeners();
  }

  // Safety net if the settings screen is torn down without Save/Cancel — treat
  // as discard so half-edited values never persist.
  void abortSettingsEdit() {
    if (!_settingsEditing) return;
    _settingsEditing = false;
    // Only revert if there were live-previewed changes; a clean exit just clears
    // the flag (otherwise _save() would stay deferred after leaving settings).
    if (settingsDirty) {
      _restoreSettingsFields();
      unawaited(_applySettingsSideEffects());
      settingsDirty = false;
    }
    notifyListeners();
  }

  // Sync the backend to the current field values (after Save or a revert) so a
  // live-previewed change is either finalised or undone.
  Future<void> _applySettingsSideEffects() async {
    try {
      SidecarClient.instance.setSttModel(whisperModel);
    } catch (_) {}
    try {
      unawaited(SidecarClient.instance.setSttEngine(sttSidecarEngine));
    } catch (_) {}
    try {
      unawaited(SidecarClient.instance.setDenoise(denoiseMode));
    } catch (_) {}
    try {
      SidecarClient.instance.setSttDevice(sttDevice);
    } catch (_) {}
    try {
      applyGameModeConfig();
    } catch (_) {}
    try {
      unawaited(MicMeter.instance.start(deviceId: inputDeviceId));
    } catch (_) {}
    try {
      await DesktopIntegration.instance.applyAutostart(autostart);
    } catch (_) {}
  }

  // Re-read the settings fields from prefs (which hold the last-saved values,
  // since _save() was deferred during editing) — the revert for Cancel / a
  // failed Save. Mirrors the settings reads in load(); keep the two in sync.
  // Model catalogue / persona / conversations are managed elsewhere and left
  // untouched.
  void _restoreSettingsFields() {
    lang = prefs.getString('lang') ?? 'ru';
    themeMode = AppThemeMode.dark;
    appStyle = AppStyle.standard;
    haptics = prefs.getBool('haptics') ?? true;
    showKeyboardOnLaunch = prefs.getBool('showKeyboardOnLaunch') ?? false;
    showPromptChips = prefs.getBool('showPromptChips') ?? true;
    fontSize = prefs.getDouble('fontSize') ?? 1.0;
    micAutoSend = prefs.getBool('micAutoSend') ?? true;
    micPauseSeconds = prefs.getInt('micPauseSeconds') ?? 3;
    serverUrl = prefs.getString('serverUrl') ?? '';
    savedServers = prefs.getStringList('savedServers') ?? [];
    apiKey = prefs.getString('apiKey') ?? '';
    llmNumCtx = prefs.getInt('llmNumCtx');
    llmNumPredict = prefs.getInt('llmNumPredict');
    llmTemperature = prefs.getDouble('llmTemperature');
    llmKeepAlive = prefs.getString('llmKeepAlive') ?? '';
    searchModel = prefs.getString('searchModel') ?? '';
    chatModel = prefs.getString('chatModel') ?? '';
    inferenceMode = prefs.getString('inferenceMode') ?? 'localServer';
    if (inferenceMode == 'local') inferenceMode = 'localServer';
    autostart = prefs.getBool('autostart') ?? false;
    minimizeToTray = prefs.getBool('minimizeToTray') ?? true;
    closeToTray = prefs.getBool('closeToTray') ?? true;
    inputDeviceId = prefs.getString('inputDeviceId') ?? '';
    extraMicIds = prefs.getStringList('extraMicIds') ?? <String>[];
    deviceDenoise.clear();
    try {
      final raw = prefs.getString('deviceDenoise');
      if (raw != null && raw.isNotEmpty) {
        (jsonDecode(raw) as Map).forEach(
            (k, v) => deviceDenoise[k.toString()] = v.toString());
      }
    } catch (_) {}
    listenMode = prefs.getString('listenMode') ?? 'continuous';
    sttLanguage = prefs.getString('sttLanguage') ?? 'auto';
    whisperModel = prefs.getString('whisperModel') ?? 'small';
    sttEngine = prefs.getString('sttEngine') ?? 'whisper';
    sttSidecarEngine = prefs.getString('sttSidecarEngine') ?? 'whisper';
    denoiseMode = prefs.getString('denoiseMode') ?? 'light';
    sttDevice = prefs.getString('sttDevice') ?? 'cpu';
    gameModeFullscreen = prefs.getBool('gameModeFullscreen') ?? true;
    gameModeVram = prefs.getBool('gameModeVram') ?? true;
    gameModeVramEnter = prefs.getDouble('gameModeVramEnter') ?? 85;
    gameModeVramExit = prefs.getDouble('gameModeVramExit') ?? 65;
    gameModeNotify = prefs.getBool('gameModeNotify') ?? true;
    gameModeExclusions = prefs.getStringList('gameModeExclusions') ?? <String>[];
    cmdMode = prefs.getString('cmdMode') ?? 'wakeword';
    wakeWord = prefs.getString('wakeWord') ?? 'EVS';
    final sw = prefs.getStringList('stopWords');
    stopWords = (sw == null || sw.isEmpty)
        ? List<String>.from(kDefaultStopWords)
        : sw;
    cmdThreshold = prefs.getDouble('cmdThreshold') ?? 0.65;
    cmdConfirm = prefs.getString('cmdConfirm') ?? 'risky';
    cmdEnabled = prefs.getBool('cmdEnabled') ?? false;
    chatEnabled = prefs.getBool('chatEnabled') ?? true;
    vizType = prefs.getString('vizType') ?? 'sphere';
    showVizBg = prefs.getBool('showVizBg') ?? true;
    showPartial = prefs.getBool('showPartial') ?? true;
    overlayMode = prefs.getBool('overlayMode') ?? true;
    overlaySize = prefs.getDouble('overlaySize') ?? 260;
    vizAccent = prefs.getInt('vizAccent') ?? 0xFFCC785C;
    orbSize = prefs.getDouble('orbSize') ?? 200;
    orbSpeed = prefs.getDouble('orbSpeed') ?? 20;
    barCount = prefs.getInt('barCount') ?? 7;
    autoUpdateCheck = prefs.getBool('autoUpdateCheck') ?? true;
    webSearchEnabled = prefs.getBool('webSearchEnabled') ?? false;
    tavilyKey = prefs.getString('tavilyKey') ?? '';
    braveKey = prefs.getString('braveKey') ?? '';
    voiceResponses = prefs.getBool('voiceResponses') ?? false;
    announceReady = prefs.getBool('announceReady') ?? true;
    ttsPiperVoice = prefs.getString('ttsPiperVoice') ?? '';
    ttsRate = prefs.getDouble('ttsRate') ?? 1.0;
    ttsVolume = prefs.getDouble('ttsVolume') ?? 1.0;
    ttsInterpEnabled = prefs.getBool('ttsInterpEnabled') ?? true;
    ttsInterpMode = prefs.getString('ttsInterpMode') ?? 'rules';
    ttsInterpModel = prefs.getString('ttsInterpModel') ?? 'qwen3-interp';
    ttsEngineChoice = prefs.getString('ttsEngineChoice') ?? 'piper';
    cosyvoiceEndpoint = prefs.getString('cosyvoiceEndpoint') ?? '';
    cosyvoiceVoice = prefs.getString('cosyvoiceVoice') ?? '';
    cosyvoiceClonePath = prefs.getString('cosyvoiceClonePath') ?? '';
    cosyvoiceClonePromptText =
        prefs.getString('cosyvoiceClonePromptText') ?? '';
    cosyvoiceSpeed = prefs.getDouble('cosyvoiceSpeed') ?? 1.0;
    cosyvoiceEmotion = prefs.getString('cosyvoiceEmotion') ?? 'neutral';
    cosyvoiceInstruct = prefs.getString('cosyvoiceInstruct') ?? '';
    cosyvoiceDevice = prefs.getString('cosyvoiceDevice') ?? 'cuda';
    final vcRaw = prefs.getString('voiceCommands');
    if (vcRaw != null) {
      try {
        final decoded = jsonDecode(vcRaw);
        if (decoded is List) {
          voiceCommands = decoded
              .map((e) => VoiceCommand.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
    remoteInputEnabled = prefs.getBool('remoteInputEnabled') ?? false;
    remoteInputPort = prefs.getInt('remoteInputPort') ?? 8770;
    remoteResponseTarget = prefs.getString('remoteResponseTarget') ?? 'both';
    final rdRaw = prefs.getString('remoteDevices');
    if (rdRaw != null) {
      try {
        final decoded = jsonDecode(rdRaw);
        if (decoded is List) {
          remoteDevices = decoded
              .map((e) => RemoteDevice.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
  }

  void setInferenceMode(String v) {
    inferenceMode = v;
    _save();
    notifyListeners();
  }

  /// Ollama `options` for a normal (non-roleplay) request, built from whatever
  /// the user actually filled in. A blank field is omitted entirely so the
  /// model's own default wins — never send a value the user did not choose.
  /// `keep_alive` is NOT here: Ollama takes it as a top-level request field,
  /// not an `options` entry.
  Map<String, dynamic> llmOptions() => {
        if (llmNumCtx != null) 'num_ctx': llmNumCtx,
        if (llmNumPredict != null) 'num_predict': llmNumPredict,
        if (llmTemperature != null) 'temperature': llmTemperature,
      };

  void setLlmNumCtx(int? v) {
    llmNumCtx = v;
    _save();
    notifyListeners();
  }

  void setLlmNumPredict(int? v) {
    llmNumPredict = v;
    _save();
    notifyListeners();
  }

  void setLlmTemperature(double? v) {
    llmTemperature = v;
    _save();
    notifyListeners();
  }

  void setLlmKeepAlive(String v) {
    llmKeepAlive = v;
    _save();
    notifyListeners();
  }

  void setSearchModel(String v) {
    searchModel = v;
    _save();
    notifyListeners();
  }

  // One-tap profiles (settings TZ §6). Each sets a small bundle of existing
  // settings through their normal setters (so persistence + sidecar updates
  // happen), and only touches toggle/segment-backed fields so the UI reflects
  // the change on the next rebuild without fighting any text controller.
  void applyVoicePreset(String id) {
    switch (id) {
      case 'fast': // Быстро: CPU, light denoise, no web search
        setSttDevice('cpu');
        setDenoiseMode('light');
        setWebSearchEnabled(false);
        break;
      case 'quality': // Качество: GPU, strong denoise
        setSttDevice('cuda');
        setDenoiseMode('strong');
        break;
      case 'search': // Поиск: web results on
        setWebSearchEnabled(true);
        break;
      case 'chat': // Чат: web results off
        setWebSearchEnabled(false);
        break;
    }
  }

  void setChatModel(String v) {
    chatModel = v;
    _save();
    notifyListeners();
  }

  void setTtsInterpEnabled(bool v) {
    ttsInterpEnabled = v;
    _save();
    notifyListeners();
  }

  void setTtsInterpMode(String v) {
    ttsInterpMode = v == 'model' ? 'model' : 'rules';
    _save();
    notifyListeners();
  }

  void setTtsEngineChoice(String v) {
    // CosyVoice can only be made active once its endpoint answers (§3.2).
    if (v == 'cosyvoice' && cosyvoiceOnline != true) return;
    ttsEngineChoice = v == 'cosyvoice' ? 'cosyvoice' : 'piper';
    _save();
    notifyListeners();
  }

  void setCosyvoiceEndpoint(String v) {
    cosyvoiceEndpoint = v.trim();
    cosyvoiceOnline = null; // must re-check after an address change
    _save();
    notifyListeners();
  }

  // CosyVoice deep-control setters (§3.2). State only for now — values are
  // persisted and will be sent to the CosyVoice server once synthesis routing
  // is wired (see PATCH-2.0.1-STATUS.md follow-up).
  void setCosyvoiceVoice(String v) {
    cosyvoiceVoice = v.trim();
    _save();
    notifyListeners();
  }

  void setCosyvoiceClonePath(String v) {
    cosyvoiceClonePath = v;
    _save();
    notifyListeners();
  }

  void setCosyvoiceClonePromptText(String v) {
    cosyvoiceClonePromptText = v;
    _save();
    notifyListeners();
  }

  void setCosyvoiceSpeed(double v) {
    cosyvoiceSpeed = v;
    _save();
    notifyListeners();
  }

  void setCosyvoiceEmotion(String v) {
    cosyvoiceEmotion = v;
    _save();
    notifyListeners();
  }

  void setCosyvoiceInstruct(String v) {
    cosyvoiceInstruct = v;
    _save();
    notifyListeners();
  }

  void setCosyvoiceDevice(String v) {
    cosyvoiceDevice = v == 'cuda' ? 'cuda' : 'cpu';
    _save();
    notifyListeners();
  }

  // Best-effort reachability probe for the CosyVoice HTTP server. Any response
  // (even an error status) means it's up; a timeout/refusal means offline. The
  // server isn't deployed yet, so this normally reports offline and CosyVoice
  // stays unselectable.
  Future<bool> checkCosyvoice() async {
    final url = cosyvoiceEndpoint.trim();
    if (url.isEmpty) {
      cosyvoiceOnline = false;
      notifyListeners();
      return false;
    }
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      cosyvoiceOnline = res.statusCode > 0;
    } catch (_) {
      cosyvoiceOnline = false;
      // A downed server must never leave CosyVoice as the active engine — fall
      // back to Piper so speech keeps working, persist it, and note it once.
      if (ttsEngineChoice == 'cosyvoice') {
        ttsEngineChoice = 'piper';
        _save();
        VizOverlayServer.instance.note(t('ttsCosyFellBack'), kind: 'info');
      }
    }
    notifyListeners();
    return cosyvoiceOnline ?? false;
  }

  // One-shot probe at launch: if CosyVoice is the saved engine or an endpoint is
  // configured, verify reachability so an unavailable server auto-reverts to
  // Piper (§3.2) instead of leaving the app "stuck" on an unreachable engine.
  Future<void> checkCosyvoiceOnStartup() async {
    if (ttsEngineChoice == 'cosyvoice' || cosyvoiceEndpoint.trim().isNotEmpty) {
      await checkCosyvoice();
    }
  }

  void setTtsInterpModel(String v) {
    ttsInterpModel = v.trim();
    _ttsInterpFellBack = false; // give the new model a fresh chance to notify
    _save();
    // No notifyListeners(): the field is edited live via its own controller and
    // a rebuild here would fight the cursor.
  }

  /// Normalize [text] for TTS per the interpreter settings. Always safe: any
  /// failure of the "model" path degrades to the offline rules sanitizer, and a
  /// disabled interpreter returns the text untouched.
  Future<String> interpretForTts(String text) async {
    if (!ttsInterpEnabled) return text;
    if (ttsInterpMode == 'model') {
      final refined = await _ttsInterpViaModel(text);
      if (refined != null && refined.trim().isNotEmpty) return refined.trim();
      // Model unavailable / failed → rules, and tell the user once (§12).
      if (!_ttsInterpFellBack) {
        _ttsInterpFellBack = true;
        // Fresh global-navigator context (not captured across the await above).
        final ctx = rootNavKey.currentContext;
        // ignore: use_build_context_synchronously
        if (ctx != null) showAppSnackBar(ctx, t('ttsInterpFellBack'));
      }
    }
    return VoiceInterpreter.rules(text);
  }

  // Best-effort one-shot rewrite via the interpreter model. Returns null on any
  // problem (no server, model missing, timeout, bad response) so the caller can
  // fall back. Deliberately non-streaming and short-timeout — this sits in the
  // speak path.
  Future<String?> _ttsInterpViaModel(String text) async {
    final base = baseUrl;
    if (serverUrl.trim().isEmpty || ttsInterpModel.trim().isEmpty) return null;
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
      final res = await http
          .post(Uri.parse('$base/api/chat'),
              headers: headers,
              body: jsonEncode({
                'model': ttsInterpModel.trim(),
                'stream': false,
                'messages': [
                  {'role': 'system', 'content': VoiceInterpreter.modelSystemPrompt},
                  {'role': 'user', 'content': text},
                ],
                'options': {'temperature': 0.2},
              }))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map) return null;
      final msg = data['message'];
      final content = msg is Map ? msg['content'] : null;
      return content is String ? content : null;
    } catch (_) {
      return null;
    }
  }

  /// Model name for the outgoing remote request, applying the optional per-mode
  /// override. A turn counts as "search" when live web results were pulled for
  /// it (pendingWebContext) — the only search-vs-chat distinction this app has.
  /// The override is honoured only when the server actually advertises it, so a
  /// stale choice falls back to the globally selected model instead of 404-ing;
  /// an RP-locked chat always keeps its pinned model.
  String modelForTurn(Conversation conv, {required bool isSearch}) {
    if (conv.rpModeEnabled) {
      final locked = conv.rpConfig?.lockedModel;
      if (locked != null && locked.isNotEmpty) return locked;
    }
    final override = isSearch ? searchModel : chatModel;
    if (override.isNotEmpty && models.contains(override)) return override;
    return _effectiveModelFor(this, conv);
  }

  void setAutostart(bool v) {
    autostart = v;
    _save();
    notifyListeners();
  }

  void setMinimizeToTray(bool v) {
    minimizeToTray = v;
    _save();
    notifyListeners();
  }

  void setCloseToTray(bool v) {
    closeToTray = v;
    _save();
    notifyListeners();
  }

  String consumeMicHint() {
    final h = _pendingMicHint;
    _pendingMicHint = '';
    return h;
  }

  // Resolve a device's denoise mode: a remembered per-device override, else a
  // default from the self-cleaning marker list (TZ2 block 8.1).
  String _denoiseForDevice(String id, String label) {
    if (deviceDenoise.containsKey(id)) return deviceDenoise[id]!;
    final lower = label.toLowerCase();
    final selfClean = kSelfCleaningMics.any((m) => lower.contains(m));
    final mode = selfClean ? 'off' : 'light';
    deviceDenoise[id] = mode;
    if (selfClean) _pendingMicHint = t('micSelfCleaningHint');
    return mode;
  }

  void setInputDeviceId(String v, {String label = ''}) {
    inputDeviceId = v;
    extraMicIds.remove(v); // the primary can't also be an "extra"
    // Apply this device's saved/derived denoise mode (block 8.1).
    final mode = _denoiseForDevice(v, label);
    if (mode != denoiseMode) {
      denoiseMode = mode;
      unawaited(SidecarClient.instance.setDenoise(denoiseMode));
    }
    _save();
    notifyListeners();
    unawaited(syncActiveMics());
  }

  // Toggle an additional simultaneous microphone (TZ2 block 8.2). First use of
  // a device derives its per-device denoise default (block 8.1).
  void toggleExtraMic(String id, String label, bool on) {
    if (id.isEmpty || id == inputDeviceId) return;
    if (on) {
      if (!extraMicIds.contains(id)) extraMicIds.add(id);
      _denoiseForDevice(id, label); // seed its denoise default
    } else {
      extraMicIds.remove(id);
    }
    _save();
    notifyListeners();
    unawaited(syncActiveMics());
    _restartCaptureForMicChange();
  }

  // Set an extra mic's denoise mode (each active input has its own — block 8.1).
  void setExtraMicDenoise(String id, String mode) {
    deviceDenoise[id] = (mode == 'light' || mode == 'strong') ? mode : 'off';
    _save();
    notifyListeners();
    unawaited(syncActiveMics());
    _restartCaptureForMicChange();
  }

  // Multi-mic capture is chosen at stt.start; bounce the listener so a mic
  // add/remove takes effect without an app restart.
  void _restartCaptureForMicChange() {
    try {
      if (SidecarClient.instance.status.value == SidecarStatus.connected) {
        VoiceAssistant.instance.restartListening();
      }
    } catch (_) {}
  }

  // Resolve the active mics (primary + extras) to {label, denoise} and hand the
  // list to the sidecar for multi-mic capture/arbitration (TZ2 block 8.2).
  Future<void> syncActiveMics() async {
    try {
      final devices = await MicMeter.instance.listDevices();
      final labelFor = {for (final d in devices) d.id: d.label};
      final ids = <String>[inputDeviceId, ...extraMicIds];
      final seen = <String>{};
      final out = <Map<String, String>>[];
      for (final id in ids) {
        if (seen.contains(id)) continue;
        seen.add(id);
        final label = id.isEmpty ? '' : (labelFor[id] ?? '');
        if (id.isNotEmpty && label.isEmpty) continue; // an unplugged extra
        out.add({'label': label, 'denoise': deviceDenoise[id] ?? denoiseMode});
      }
      SidecarClient.instance.setActiveMics(out);
    } catch (_) {}
  }

  void setListenMode(String v) {
    listenMode = v;
    _save();
    notifyListeners();
  }

  void setSttLanguage(String v) {
    sttLanguage = v;
    _save();
    notifyListeners();
  }

  void setWhisperModel(String v) {
    whisperModel = v;
    _save();
    notifyListeners();
    SidecarClient.instance.setSttModel(v);
  }

  void setSttEngine(String v) {
    sttEngine = v;
    _save();
    notifyListeners();
  }

  // Switch the sidecar recognition engine (whisper | gigaam). Applies live for
  // preview (the card shows loading/ready/error); the choice persists on Save
  // and is resynced to the backend on Save/Cancel via _applySettingsSideEffects.
  void setSttSidecarEngine(String v) {
    sttSidecarEngine = v == 'gigaam' ? 'gigaam' : 'whisper';
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setSttEngine(sttSidecarEngine));
  }

  // Switch noise suppression (off | light | strong). Applies live for preview;
  // persists on Save, resynced on Save/Cancel via _applySettingsSideEffects.
  void setDenoiseMode(String v) {
    denoiseMode = (v == 'light' || v == 'strong') ? v : 'off';
    // Remember the choice for the current input device (TZ2 block 8.1) so it
    // sticks per-mic (and is not re-defaulted on the next device switch).
    deviceDenoise[inputDeviceId] = denoiseMode;
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setDenoise(denoiseMode));
    unawaited(syncActiveMics());
  }

  // STT compute device (TZ2 block 6). Live preview; persisted on Save.
  void setSttDevice(String v) {
    sttDevice = v == 'cuda' ? 'cuda' : 'cpu';
    _save();
    notifyListeners();
    SidecarClient.instance.setSttDevice(sttDevice);
  }

  // Localized game-mode notification phrases + config, pushed to the sidecar
  // whenever any game-mode setting changes (TZ2 block 7).
  void applyGameModeConfig() {
    SidecarClient.instance.configureGameMode(
      fullscreen: gameModeFullscreen,
      vram: gameModeVram,
      vramEnter: gameModeVramEnter,
      vramExit: gameModeVramExit,
      notify: gameModeNotify,
      exclusions: gameModeExclusions,
      texts: {
        'fullscreen': t('gmNotifyFullscreen'),
        'vram': t('gmNotifyVram'),
        'exit': t('gmNotifyExit'),
      },
    );
  }

  void setGameModeFullscreen(bool v) {
    gameModeFullscreen = v;
    _save();
    notifyListeners();
    applyGameModeConfig();
  }

  void setGameModeVram(bool v) {
    gameModeVram = v;
    _save();
    notifyListeners();
    applyGameModeConfig();
  }

  void setGameModeNotify(bool v) {
    gameModeNotify = v;
    _save();
    notifyListeners();
    applyGameModeConfig();
  }

  // Two-sided: exit must stay below enter or the hysteresis breaks (the sidecar
  // also guards this).
  void setGameModeVramThresholds(double enter, double exit) {
    gameModeVramEnter = enter.clamp(50, 99);
    gameModeVramExit = exit.clamp(30, gameModeVramEnter - 5);
    _save();
    notifyListeners();
    applyGameModeConfig();
  }

  void setGameModeExclusions(List<String> v) {
    gameModeExclusions = v;
    _save();
    notifyListeners();
    applyGameModeConfig();
  }

  void setCmdMode(String v) {
    cmdMode = v;
    _save();
    notifyListeners();
  }

  void setWakeWord(String v) {
    final t = v.trim();
    wakeWord = t.isEmpty ? 'EVS' : t;
    _save();
    notifyListeners();
  }

  // Replace the voice "stop" vocabulary from a free-text field (comma/newline
  // separated). Falls back to the defaults if the user clears it entirely.
  void setStopWords(String csv) {
    final list = csv
        .split(RegExp(r'[,\n]'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    stopWords = list.isEmpty ? List<String>.from(kDefaultStopWords) : list;
    _save();
    notifyListeners();
  }

  // --- Saved server addresses (quick-switch chips) ---
  void saveCurrentServer() {
    final url = serverUrl.trim();
    if (url.isEmpty || savedServers.contains(url)) return;
    savedServers.insert(0, url);
    if (savedServers.length > 8) savedServers = savedServers.sublist(0, 8);
    _save();
    notifyListeners();
  }

  void removeSavedServer(String url) {
    savedServers.remove(url);
    _save();
    notifyListeners();
  }

  void selectSavedServer(String url) => setServer(url, apiKey);

  void setCmdThreshold(double v) {
    cmdThreshold = v;
    _save();
    notifyListeners();
  }

  void setCmdConfirm(String v) {
    cmdConfirm = v;
    _save();
    notifyListeners();
  }

  void setCmdEnabled(bool v) {
    cmdEnabled = v;
    _save();
    notifyListeners();
  }

  void setChatEnabled(bool v) {
    chatEnabled = v;
    _save();
    notifyListeners();
  }

  void setVizType(String v) {
    vizType = v;
    _save();
    notifyListeners();
  }

  void setShowVizBg(bool v) {
    showVizBg = v;
    _save();
    notifyListeners();
  }

  // Show/hide the floating widget (its own process — VizOverlayServer
  // spawns/kills it; the setting persists as 'overlayMode').
  void setOverlayMode(bool v) {
    if (overlayMode == v) return;
    overlayMode = v;
    _save();
    notifyListeners();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(VizOverlayServer.instance.setVisible(v));
    }
  }

  void setOverlaySize(double v) {
    overlaySize = v;
    _save();
    // The cfg push (AppState listener in VizOverlayServer) live-resizes the
    // widget window.
    notifyListeners();
  }

  // Applies a `cfg` message in the WIDGET process (see VizOverlayApp): this
  // AppState instance is just a mirror of the main process's settings there —
  // assign fields and notify, never save.
  void applyVizCfg(Map<String, dynamic> m) {
    lang = (m['lang'] as String?) ?? lang;
    vizType = (m['vizType'] as String?) ?? vizType;
    vizAccent = (m['vizAccent'] as num?)?.toInt() ?? vizAccent;
    orbSize = (m['orbSize'] as num?)?.toDouble() ?? orbSize;
    orbSpeed = (m['orbSpeed'] as num?)?.toDouble() ?? orbSpeed;
    barCount = (m['barCount'] as num?)?.toInt() ?? barCount;
    wakeWord = (m['wakeWord'] as String?) ?? wakeWord;
    notifyListeners();
  }

  void setVizAccent(int v) {
    vizAccent = v;
    _save();
    notifyListeners();
  }

  void setOrbSize(double v) {
    orbSize = v;
    _save();
    notifyListeners();
  }

  void setOrbSpeed(double v) {
    orbSpeed = v;
    _save();
    notifyListeners();
  }

  void setBarCount(int v) {
    barCount = v;
    _save();
    notifyListeners();
  }

  void setShowPartial(bool v) {
    showPartial = v;
    _save();
    notifyListeners();
  }

  void setAutoUpdateCheck(bool v) {
    autoUpdateCheck = v;
    _save();
    notifyListeners();
  }

  void setWebSearchEnabled(bool v) {
    webSearchEnabled = v;
    _save();
    notifyListeners();
  }

  void setTavilyKey(String v) {
    tavilyKey = v.trim();
    _save();
    notifyListeners();
  }

  void setBraveKey(String v) {
    braveKey = v.trim();
    _save();
    notifyListeners();
  }

  void setVoiceResponses(bool v) {
    voiceResponses = v;
    _save();
    notifyListeners();
  }

  void setAnnounceReady(bool v) {
    announceReady = v;
    _save();
    notifyListeners();
  }

  // Select the active TTS voice (TZ2 block 5). '' = system voice (pyttsx3);
  // otherwise a Piper voice id. Delivered to the sidecar (engine + voice dir).
  void setTtsPiperVoice(String voiceId) {
    ttsPiperVoice = voiceId;
    _save();
    final modelId = _voiceModelId(voiceId);
    unawaited(SidecarClient.instance.setTtsVoice(voiceId, modelId: modelId));
    notifyListeners();
  }

  // Map a Piper voice id back to its <userdata>/models/<id> registry entry.
  String _voiceModelId(String voiceId) {
    for (final s in kAssetModels) {
      if (s.family == 'tts-voice' && s.voiceId == voiceId) return s.id;
    }
    return '';
  }

  // Play a fixed sample phrase in a downloaded Piper voice without changing the
  // active voice (TZ2 block 5, "Прослушать образец").
  void previewPiperVoice(AssetModelSpec spec) {
    if (spec.voiceId == null) return;
    SidecarClient.instance.previewTtsVoice(
        spec.voiceId!, spec.id, t('voiceSamplePhrase'),
        rate: ttsRate, volume: ttsVolume);
  }

  void setTtsRate(double v) {
    ttsRate = v;
    _save();
    notifyListeners();
  }

  void setTtsVolume(double v) {
    ttsVolume = v;
    _save();
    notifyListeners();
  }

  // Run a per-app volume command (Ф2). [utterance] is the recognized phrase, if
  // any, from which the target number is extracted; test-runs pass ''. Returns
  // (ok, message-to-say). Handles the §2.6 edge cases: no number → default or a
  // "didn't catch a number" reply; out of range → clamp; app not playing → a
  // friendly "not playing sound" reply (ok=false).
  Future<(bool, String)> applyAppVolume(
      VoiceCommand cmd, String utterance) async {
    final sc = SidecarClient.instance;
    final appLabel = cmd.value.isNotEmpty ? cmd.value : cmd.process;
    if (cmd.action == 'mute' || cmd.action == 'unmute') {
      final r = await sc.setAppVolume(cmd.process, cmd.action);
      final ok = r['ok'] == true;
      if (!ok) return (false, t('volNotPlaying').replaceAll('{app}', appLabel));
      return (
        true,
        cmd.speakPhrase.trim().isNotEmpty ? cmd.speakPhrase.trim() : t('vaDone')
      );
    }
    var n = NumberWords.extract(utterance) ?? cmd.defaultValue;
    if (n == null) return (false, t('volNoNumber'));
    n = n.clamp(cmd.argMin, cmd.argMax);
    final r =
        await sc.setAppVolume(cmd.process, cmd.action, value: n / 100.0);
    if (r['ok'] != true) {
      return (false, t('volNotPlaying').replaceAll('{app}', appLabel));
    }
    final say = cmd.speakPhrase.trim().isNotEmpty
        ? cmd.speakPhrase.trim().replaceAll('{N}', '$n')
        : t('volSet').replaceAll('{app}', appLabel).replaceAll('{N}', '$n');
    return (true, say);
  }

  // Build AI voice-command suggestions (Ф1). Uses the real app scan (paths are
  // authoritative — never from the model), ranks by UserAssist frequency, asks
  // the configured server model for phrases (names only), and falls back to
  // "открой <name>" per app when the model is unavailable or replies badly.
  // Apps already mapped to a command are skipped so a repeat run only offers new
  // ones (§1.8).
  Future<List<CmdSuggestion>> buildCommandSuggestions({int topN = 20}) async {
    final apps = (await listInstalledPrograms())
        .where((p) => !SuggestionEngine.isJunk(p))
        .toList();
    final usage = await readUsageScores();
    final existingTargets = voiceCommands
        .where((c) => c.type == VoiceCommandType.app)
        .map((c) => c.value.toLowerCase())
        .toSet();
    final candidates = apps
        .where((p) => !existingTargets.contains(p.value.toLowerCase()))
        .toList()
      ..sort((a, b) {
        final sa = SuggestionEngine.scoreFor(a, usage);
        final sb = SuggestionEngine.scoreFor(b, usage);
        if (sa != sb) return sb.compareTo(sa); // most-used first
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final top = candidates.take(topN).toList();
    final anyUsage = top.any((p) => SuggestionEngine.scoreFor(p, usage) > 0);

    Map<String, List<String>>? ai;
    if (top.isNotEmpty) {
      ai = await _requestSuggestionPhrases(top.map((e) => e.name).toList());
    }

    final out = <CmdSuggestion>[];
    for (var i = 0; i < top.length; i++) {
      final p = top[i];
      final score = SuggestionEngine.scoreFor(p, usage);
      final phrases = ai?[p.name];
      final phrase = (phrases != null && phrases.isNotEmpty)
          ? phrases.first
          : SuggestionEngine.fallbackPhrase(p.name);
      out.add(CmdSuggestion(
        p,
        phrase,
        // Pre-check the frequently-used apps; if there's no frequency data at
        // all, pre-check the first few so the list is still actionable (§1.5a).
        selected: anyUsage ? score > 0 : i < 6,
        usage: score,
      ));
    }
    SuggestionEngine.resolveCollisions(out, voiceCommands);
    return out;
  }

  // Best-effort call to the configured server model for suggestion phrases.
  // Returns null (→ per-app fallback) when there's no server, the model is local
  // (this needs Ollama), the request fails, or the reply isn't parseable JSON.
  Future<Map<String, List<String>>?> _requestSuggestionPhrases(
      List<String> names) async {
    final model = chatModel.isNotEmpty ? chatModel : selectedModel;
    if (serverUrl.trim().isEmpty || model.isEmpty || isLocalModel(model)) {
      return null;
    }
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
      final res = await http
          .post(Uri.parse('$baseUrl/api/chat'),
              headers: headers,
              body: jsonEncode({
                'model': model,
                'stream': false,
                'messages': [
                  {'role': 'user', 'content': SuggestionEngine.buildPrompt(names)}
                ],
                'options': {'temperature': 0.2},
              }))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map) return null;
      final msg = data['message'];
      final content = msg is Map ? msg['content'] : null;
      return content is String
          ? SuggestionEngine.parseModelJson(content)
          : null;
    } catch (_) {
      return null;
    }
  }

  // ---- Remote input from phones (TZ §14) ----

  void setRemoteInputEnabled(bool v) {
    remoteInputEnabled = v;
    _save();
    notifyListeners();
    if (v) {
      RemoteInputServer.instance.start(this);
    } else {
      RemoteInputServer.instance.stop();
    }
  }

  void setRemoteInputPort(int v) {
    remoteInputPort = v;
    _save();
    notifyListeners();
    if (remoteInputEnabled) RemoteInputServer.instance.start(this); // rebind
  }

  void setRemoteResponseTarget(String v) {
    remoteResponseTarget =
        (v == 'desktop_tts' || v == 'phone_text') ? v : 'both';
    _save();
    notifyListeners();
  }

  void addRemoteDevice(RemoteDevice d) {
    remoteDevices.add(d);
    _save();
    notifyListeners();
  }

  void removeRemoteDevice(RemoteDevice d) {
    // Unpair = immediate token revocation (§14.7).
    remoteDevices.removeWhere((x) => x.id == d.id);
    _save();
    notifyListeners();
  }

  void renameRemoteDevice(RemoteDevice d, String name) {
    d.name = name.trim();
    _save();
    notifyListeners();
  }

  void setRemoteDevicePerms(RemoteDevice d, {bool? voice, bool? text}) {
    if (voice != null) d.permVoice = voice;
    if (text != null) d.permText = text;
    _save();
    notifyListeners();
  }

  void setRemoteDeviceEnabled(RemoteDevice d, bool v) {
    d.enabled = v;
    _save();
    notifyListeners();
  }

  // Server-side: stamp a device's last activity (no full save churn per request
  // — persisted opportunistically).
  void touchRemoteDevice(RemoteDevice d) {
    d.lastSeen = DateTime.now().toUtc().toIso8601String();
    notifyListeners();
  }

  RemoteDevice? remoteDeviceByToken(String token) {
    for (final d in remoteDevices) {
      if (d.token == token) return d;
    }
    return null;
  }

  // Run a remote text command through the normal LLM backend and return the
  // reply. A one-off synthetic conversation (global persona, no chat history) —
  // it must not touch or pollute the user's open chats.
  Future<String> runRemoteCommand(String text) async {
    final service = _llmFactory.current;
    final synthetic = Conversation(id: 'remote-temp', title: '');
    final history = [ChatMessage(role: 'user', content: text)];
    final reply = await service.generateResponse(synthetic, history);
    return persona.enforceEmojiPolicy(reply).trim();
  }

  void addVoiceCommand(VoiceCommand c) {
    voiceCommands.add(c);
    _save();
    notifyListeners();
  }

  // Whether to offer the AI command-suggestion wizard on this launch (Ф1 §1.4).
  // Windows-only (the app scan + UserAssist ranking are Windows features), once
  // ever, and only when the user has no app-launch commands yet — someone who
  // already set them up doesn't need the onboarding.
  bool get shouldOfferCommandOnboarding =>
      io.Platform.isWindows &&
      !commandOnboardingSeen &&
      !voiceCommands.any((c) => c.type == VoiceCommandType.app);

  void markCommandOnboardingSeen() {
    if (commandOnboardingSeen) return;
    commandOnboardingSeen = true;
    _save();
  }

  void removeVoiceCommand(VoiceCommand c) {
    voiceCommands.remove(c);
    _save();
    notifyListeners();
  }

  // Replace an existing command in place (keeps its list position) — used by
  // the edit flow.
  void replaceVoiceCommand(VoiceCommand oldCmd, VoiceCommand newCmd) {
    final i = voiceCommands.indexOf(oldCmd);
    if (i < 0) {
      voiceCommands.add(newCmd);
    } else {
      voiceCommands[i] = newCmd;
    }
    _save();
    notifyListeners();
  }

  void buzz() {
    if (haptics) HapticFeedback.lightImpact();
  }

  void setLang(String l) {
    lang = l;
    _save();
    notifyListeners();
  }

  void setThemeMode(AppThemeMode v) {
    themeMode = v;
    _save();
    notifyListeners();
  }

  void setHaptics(bool v) {
    haptics = v;
    _save();
    notifyListeners();
  }

  void setShowKeyboard(bool v) {
    showKeyboardOnLaunch = v;
    _save();
    notifyListeners();
  }

  void setShowChips(bool v) {
    showPromptChips = v;
    _save();
    notifyListeners();
  }

  void setFontSize(double v) {
    fontSize = v;
    _save();
    notifyListeners();
  }

  void setMicAutoSend(bool v) {
    micAutoSend = v;
    _save();
    notifyListeners();
  }

  void setMicPauseSeconds(int v) {
    micPauseSeconds = v;
    _save();
    notifyListeners();
  }

  void savePersona(Personalization p) {
    persona = p;
    _save();
    notifyListeners();
  }

  void saveConversationPersona(Conversation conv, Personalization p) {
    conv.persona = p;
    _save();
    notifyListeners();
  }

  void saveConversationRpConfig(Conversation conv, RPSessionConfig cfg) {
    conv.rpConfig = cfg;
    _save();
    notifyListeners();
  }

  // Mutates whichever Personalization is actually in effect for the current
  // chat (its own override if it has one, otherwise the global one) — the
  // same target buildSystemPrompt()/buildLocalSystemPrompt() read from.
  void rememberMessageContent(String content) {
    final target = current?.persona ?? persona;
    if (content.isEmpty || target.savedMemories.contains(content)) return;
    target.savedMemories.add(content);
    _save();
    notifyListeners();
  }

  void forgetMessageMemory(String content) {
    final target = current?.persona ?? persona;
    if (!target.savedMemories.remove(content)) return;
    _save();
    notifyListeners();
  }

  void toggleMessagePin(Conversation conv, ChatMessage m) {
    if (!conv.pinnedMessageIds.remove(m.id)) {
      conv.pinnedMessageIds.add(m.id);
    }
    _save();
    notifyListeners();
  }

  void setServer(String url, String key) {
    serverUrl = url;
    apiKey = key;
    _save();
    notifyListeners();
    fetchModels();
  }

  Future<void> fetchModels() async {
    if (serverUrl.trim().isEmpty) return;
    loadingModels = true;
    modelsError = null;
    notifyListeners();
    try {
      final headers = <String, String>{};
      if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';

      List<String> found = [];

      try {
        final res = await http
            .get(Uri.parse('$baseUrl/api/tags'), headers: headers)
            .timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data is Map<String, dynamic> && data['models'] is List) {
            final list = data['models'] as List;
            found = list.map((e) => e['name'].toString()).toList();
          }
        }
      } catch (_) {}

      if (found.isEmpty) {
        try {
          final res = await http
              .get(Uri.parse('$baseUrl/v1/models'), headers: headers)
              .timeout(const Duration(seconds: 12));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data is Map<String, dynamic> && data['data'] is List) {
              final list = data['data'] as List;
              found = list.map((e) => e['id'].toString()).toList();
            }
          }
        } catch (_) {}
      }

      if (found.isNotEmpty) {
        final keptLocal = models.where(isLocalModel).toList();
        models = [...found, ...keptLocal.where((m) => !found.contains(m))];
        if (!models.contains(selectedModel)) selectedModel = models.first;
        modelsError = null;
      } else {
        modelsError = t('noModelsFound');
      }
    } catch (e) {
      modelsError = t('unreachable');
    } finally {
      loadingModels = false;
      _save();
      notifyListeners();
    }
  }

  void selectModel(String m) {
    selectedModel = m;
    // Explicitly choosing a model = the user wants to try it again, so lift any
    // previous crash block (a fresh crash will just re-arm it).
    crashedLocalModels.remove(m);
    _save();
    notifyListeners();
    // Warm up the newly selected local model so its "preparing" screen shows
    // right away (a different model isn't warmed yet, so the guard passes).
    if (isLocalModel(m)) unawaited(warmUpModelFor(current));
  }

  void addModel(String m) {
    if (m.trim().isEmpty || models.contains(m)) return;
    models.add(m.trim());
    _save();
    notifyListeners();
  }

  void removeModel(String m) {
    models.remove(m);
    if (selectedModel == m) {
      selectedModel = models.isNotEmpty ? models.first : '';
    }
    _save();
    notifyListeners();
  }

  bool isLocalModel(String s) => s.startsWith('local:');

  LocalModelSpec? localSpecFor(String modelKey) {
    if (!isLocalModel(modelKey)) return null;
    final id = modelKey.substring('local:'.length);
    for (final spec in kLocalModels) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  String modelDisplayName(String modelKey, {bool withSuffix = true}) {
    if (modelKey.isEmpty) return t('noModelsAvailable');
    final spec = localSpecFor(modelKey);
    if (spec == null) return modelKey;
    return withSuffix ? '${spec.shortName} (${t('onDevice')})' : spec.shortName;
  }

  Future<void> downloadLocalModel(LocalModelSpec spec) async {
    if (localDownloadProgress.containsKey(spec.id)) return;
    _cancelledLocalDownloads.remove(spec.id);
    localDownloadProgress[spec.id] = 0;
    notifyListeners();
    try {
      final dir = await localModelsDirPath();
      final destPath = '$dir/${spec.fileName}';
      await downloadFileWithProgress(spec.url, destPath, (received, total) {
        localDownloadProgress[spec.id] = total > 0 ? received / total : 0;
        notifyListeners();
      }, () => _cancelledLocalDownloads.contains(spec.id));
      downloadedLocalModelIds.add(spec.id);
      addModel(spec.modelKey);
    } catch (_) {
      // Cancelled or failed; nothing left on disk thanks to downloadFileWithProgress cleanup.
    } finally {
      localDownloadProgress.remove(spec.id);
      _cancelledLocalDownloads.remove(spec.id);
      _save();
      notifyListeners();
    }
  }

  void cancelLocalModelDownload(String id) {
    _cancelledLocalDownloads.add(id);
  }

  // ---- Asset model manager (TZ2 block 3) ----
  final Map<String, double> assetProgress = {}; // id -> 0..1 while downloading
  final Set<String> _cancelledAssets = {};
  final Map<String, bool> _assetInstalled = {}; // id -> all files present (cache)

  bool assetInstalled(String id) => _assetInstalled[id] == true;
  bool assetDownloading(String id) => assetProgress.containsKey(id);

  // An asset model is "active" if it's the currently selected engine/voice.
  bool assetActive(AssetModelSpec spec) {
    if (spec.family == 'tts-voice') {
      return spec.voiceId != null && spec.voiceId == ttsPiperVoice;
    }
    return spec.id == 'gigaam-v3' && sttSidecarEngine == 'gigaam';
  }

  Future<void> refreshAssetModels() async {
    for (final spec in kAssetModels) {
      _assetInstalled[spec.id] = await _assetFilesPresent(spec);
    }
    notifyListeners();
  }

  Future<bool> _assetFilesPresent(AssetModelSpec spec) async {
    try {
      final base = await modelsDirPath();
      final sep = io.Platform.pathSeparator;
      // Piper voices download as a .tar.bz2 the sidecar extracts (then removes)
      // on first load, so "installed" = the tarball is fully present OR an
      // extracted .onnx exists under the voice dir.
      if (spec.family == 'tts-voice') {
        final dir = io.Directory('$base$sep${spec.id}');
        if (!await dir.exists()) return false;
        final want = spec.files.isNotEmpty ? spec.files.first.size : 0;
        await for (final e in dir.list(recursive: true)) {
          if (e is! io.File) continue;
          final n = e.path.toLowerCase();
          if (n.endsWith('.onnx')) return true;
          if (n.endsWith('.tar.bz2') &&
              (want <= 0 || await e.length() >= want * 0.95)) {
            return true;
          }
        }
        return false;
      }
      for (final f in spec.files) {
        final file = io.File('$base$sep${spec.id}$sep${f.name}');
        if (!await file.exists()) return false;
        if (f.size > 10000 && await file.length() < f.size * 0.95) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> downloadAssetModel(AssetModelSpec spec) async {
    if (assetProgress.containsKey(spec.id)) return;
    _cancelledAssets.remove(spec.id);
    assetProgress[spec.id] = 0;
    notifyListeners();
    try {
      final base = await modelsDirPath();
      final sep = io.Platform.pathSeparator;
      final dir = io.Directory('$base$sep${spec.id}');
      if (!await dir.exists()) await dir.create(recursive: true);
      final total = spec.totalSize;
      var done = 0; // bytes finished in earlier files
      for (final f in spec.files) {
        final dest = '${dir.path}$sep${f.name}';
        final existing = io.File(dest);
        // Whole-file resume: skip a file that's already fully there.
        if (await existing.exists() &&
            f.size > 10000 &&
            await existing.length() >= f.size * 0.95) {
          done += f.size;
          assetProgress[spec.id] = total > 0 ? done / total : 0;
          notifyListeners();
          continue;
        }
        final fileBase = done;
        await downloadFileWithProgress(f.url, dest, (received, _) {
          assetProgress[spec.id] = total > 0 ? (fileBase + received) / total : 0;
          notifyListeners();
        }, () => _cancelledAssets.contains(spec.id));
        done += f.size;
      }
      _assetInstalled[spec.id] = await _assetFilesPresent(spec);
      // Make a now-downloaded GigaAM selectable without re-entering settings:
      // update the engine capability optimistically and hand the sidecar the
      // (now-populated) model dir.
      if (spec.id == 'gigaam-v3' && (_assetInstalled[spec.id] ?? false)) {
        final e = Map<String, bool>.from(SidecarClient.instance.engines.value);
        e['gigaam'] = true;
        SidecarClient.instance.engines.value = e;
        unawaited(SidecarClient.instance.setSttEngine(sttSidecarEngine));
      }
      // A just-downloaded voice that's already the active one: hand the sidecar
      // its (now-populated) dir so it can switch to Piper without a re-entry.
      if (spec.family == 'tts-voice' &&
          spec.voiceId == ttsPiperVoice &&
          (_assetInstalled[spec.id] ?? false)) {
        unawaited(
            SidecarClient.instance.setTtsVoice(spec.voiceId!, modelId: spec.id));
      }
    } catch (_) {
      _assetInstalled[spec.id] = false;
    } finally {
      assetProgress.remove(spec.id);
      _cancelledAssets.remove(spec.id);
      notifyListeners();
    }
  }

  void cancelAssetDownload(String id) => _cancelledAssets.add(id);

  Future<void> deleteAssetModel(AssetModelSpec spec) async {
    try {
      final base = await modelsDirPath();
      final sep = io.Platform.pathSeparator;
      final dir = io.Directory('$base$sep${spec.id}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _assetInstalled[spec.id] = false;
    notifyListeners();
  }

  Future<int> assetDiskSize(AssetModelSpec spec) async {
    try {
      final base = await modelsDirPath();
      final sep = io.Platform.pathSeparator;
      final dir = io.Directory('$base$sep${spec.id}');
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is io.File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> openModelsFolder() async {
    try {
      // modelsDirPath joins with '/', producing a mixed-slash path like
      // "F:\EVS\userdata/models"; explorer.exe can't navigate that and silently
      // opens Documents instead — normalize to backslashes on Windows.
      final dir = (await modelsDirPath()).replaceAll('/', r'\');
      await io.Process.start('explorer.exe', [dir], runInShell: false);
    } catch (_) {}
  }

  Future<void> deleteLocalModel(LocalModelSpec spec) async {
    final dir = await localModelsDirPath();
    await deleteLocalModelFile('$dir/${spec.fileName}');
    downloadedLocalModelIds.remove(spec.id);
    removeModel(spec.modelKey);
    _save();
    notifyListeners();
  }

  static const _updateRepo = 'kekw2077/mirai';

  bool _isNewerVersion(String remote, String local) {
    List<int> parse(String v) =>
        v.split('+').first.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final r = parse(remote);
    final l = parse(local);
    for (var i = 0; i < 3; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }

  // Called once after launch. Returns the changelog entry to show in a
  // "what's new" dialog if the app was just updated, or null if this is a
  // fresh install or the version hasn't changed since last launch.
  Future<ChangelogEntry?> consumeWhatsNew() async {
    final info = await PackageInfo.fromPlatform();
    final current = info.version;
    final previous = lastSeenVersion;
    if (previous == current) return null;
    lastSeenVersion = current;
    await prefs.setString('lastSeenVersion', current);
    if (previous == null) return null; // fresh install, nothing to announce
    for (final entry in kChangelog) {
      if (entry.version == current) return entry;
    }
    return null;
  }

  Future<void> checkForUpdates() async {
    checkingForUpdate = true;
    updateCheckError = null;
    updateAvailableVersion = null;
    _updateApkUrl = null;
    notifyListeners();
    try {
      // The repo also publishes iOS AltStore releases (tagged `ios-vX.Y.Z`,
      // shipping a .ipa, not a .apk) — those can be more recent than the
      // last Android release, so /releases/latest isn't reliable here.
      // Walk the release list (already newest-first) and use the first one
      // that actually carries an .apk asset.
      final res = await http.get(
        Uri.parse('https://api.github.com/repos/$_updateRepo/releases'),
      );
      if (res.statusCode == 404) {
        return; // no releases published yet — not an error
      }
      if (res.statusCode != 200) {
        updateCheckError = t('updateCheckFailed');
        return;
      }
      final list = jsonDecode(res.body) as List;
      String? apkUrl;
      String remoteVersion = '';
      for (final r in list) {
        final release = r as Map<String, dynamic>;
        final assets = (release['assets'] as List?) ?? [];
        for (final a in assets) {
          final name = (a['name'] as String?) ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apkUrl = a['browser_download_url'] as String?;
            final tag = (release['tag_name'] as String?) ?? '';
            remoteVersion = tag.startsWith('v') ? tag.substring(1) : tag;
            break;
          }
        }
        if (apkUrl != null) break;
      }
      final info = await PackageInfo.fromPlatform();
      if (apkUrl != null &&
          remoteVersion.isNotEmpty &&
          _isNewerVersion(remoteVersion, info.version)) {
        updateAvailableVersion = remoteVersion;
        _updateApkUrl = apkUrl;
      }
    } catch (_) {
      updateCheckError = t('updateCheckFailed');
    } finally {
      checkingForUpdate = false;
      notifyListeners();
    }
  }

  Future<void> downloadAndInstallUpdate() async {
    final url = _updateApkUrl;
    if (url == null) return;
    updateDownloadProgress = 0;
    updateCheckError = null;
    notifyListeners();
    try {
      final path = await updateDownloadPath('mirai_update.apk');
      await downloadFileWithProgress(url, path, (received, total) {
        updateDownloadProgress = total > 0 ? received / total : null;
        notifyListeners();
      }, () => false);
      updateDownloadProgress = null;
      notifyListeners();
      await installApk(path);
    } catch (_) {
      updateCheckError = t('updateDownloadFailed');
      updateDownloadProgress = null;
      notifyListeners();
    }
  }

  int get chatCount => conversations.length;
  int get pinnedCount => conversations.where((c) => c.pinned).length;
  Conversation? get latest {
    if (conversations.isEmpty) return null;
    final sorted = [...conversations]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted.first;
  }

  void newChat() {
    final c = Conversation(id: _uuid.v4(), title: t('newChat'));
    conversations.insert(0, c);
    current = c;
    _save();
    notifyListeners();
  }

  void openChat(Conversation c) {
    current = c;
    notifyListeners();
  }

  void togglePin(Conversation c) {
    c.pinned = !c.pinned;
    _save();
    notifyListeners();
  }

  // Manual chat rename. Empty/whitespace input is ignored so a chat never
  // ends up with a blank title.
  void renameChat(Conversation c, String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    c.title = t;
    _save();
    notifyListeners();
  }

  void toggleRpMode(Conversation c) {
    c.rpModeEnabled = !c.rpModeEnabled;
    if (c.rpModeEnabled) {
      c.rpConfig ??= RPSessionConfig();
      // Model is locked exactly once, the first time RP turns on for this
      // chat — turning RP off and back on later does not re-lock, matching
      // "the model can't be changed within this session" from the spec.
      if (c.rpConfig!.lockedModel == null && selectedModel.isNotEmpty) {
        c.rpConfig!.lockedModel = selectedModel;
        c.rpConfig!.contextWindowLimit = isLocalModel(selectedModel)
            ? 4096
            : 16384;
      }
    }
    _save();
    notifyListeners();
  }

  // Context compression on demand (ТЗ-4): summarizes everything except the
  // last 8 messages via the chat's own locked model, stores the summary on
  // rpConfig.rollingSummary — RPMemoryManager.buildSystemPrompt/trimForContext
  // pick it up on the next request automatically.
  bool isCompressingContext = false;

  Future<void> compressRpContext(Conversation conv) async {
    final cfg = conv.rpConfig;
    if (cfg == null || isCompressingContext) return;
    const keepLastN = 8;
    if (conv.messages.length <= keepLastN) return;
    isCompressingContext = true;
    notifyListeners();
    try {
      final old = conv.messages.sublist(0, conv.messages.length - keepLastN);
      final service = _llmFactory.forConversation(conv);
      final summary = await RPMemoryManager.summarizeOldContext(service, old);
      cfg.rollingSummary = summary.trim();
      cfg.summaryCoversUpToMessageIndex = old.length;
      _save();
    } finally {
      isCompressingContext = false;
      notifyListeners();
    }
  }

  // The last deleted chat + its list index, kept so the UI can offer Undo.
  (Conversation, int)? _lastDeletedChat;

  void deleteChat(Conversation c) {
    final idx = conversations.indexOf(c);
    if (idx < 0) return;
    conversations.removeAt(idx);
    _lastDeletedChat = (c, idx);
    if (current == c) current = null;
    _save();
    notifyListeners();
  }

  // Restore the most recently deleted chat to its original position.
  void undoDeleteChat() {
    final d = _lastDeletedChat;
    if (d == null) return;
    final (c, idx) = d;
    conversations.insert(idx.clamp(0, conversations.length), c);
    _lastDeletedChat = null;
    _save();
    notifyListeners();
  }

  void deleteAll() {
    conversations.clear();
    current = null;
    _save();
    notifyListeners();
  }

  String? _extractContent(Map<String, dynamic> data) {
    if (data['message'] is Map && data['message']['content'] != null) {
      return data['message']['content'].toString();
    }
    if (data['response'] != null) {
      return data['response'].toString();
    }
    if (data['choices'] is List && (data['choices'] as List).isNotEmpty) {
      final choices = data['choices'] as List;
      if (choices[0] is Map &&
          choices[0]['message'] is Map &&
          choices[0]['message']['content'] != null) {
        return choices[0]['message']['content'].toString();
      }
    }
    return null;
  }

  Future<String> sendMessage(
    String text, {
    List<String> attachments = const [],
  }) async {
    unawaited(appendLog(
        'chat', text.length > 120 ? '${text.substring(0, 120)}…' : text));
    current ??= () {
      final c = Conversation(id: _uuid.v4(), title: t('newChat'));
      conversations.insert(0, c);
      return c;
    }();
    final conv = current!;

    conv.messages.add(
      ChatMessage(role: 'user', content: text, attachments: attachments),
    );
    if (conv.title == t('newChat') || conv.title == 'New Chat') {
      conv.title = text.isNotEmpty
          ? (text.length > 32 ? '${text.substring(0, 32)}…' : text)
          : conv.title;
    }
    conv.updatedAt = DateTime.now();
    notifyListeners();
    return _generateAssistantReply(conv, userTextForMemory: text);
  }

  // Voice path: stream the reply and hand each completed SENTENCE to
  // [onSentence] as soon as it arrives, so TTS can start speaking the first
  // sentence while the rest is still generating (much lower perceived latency
  // than awaiting the whole reply). The full turn is still shown in the chat.
  Future<String> streamReplyForVoice(
      String userText, void Function(String sentence) onSentence) async {
    unawaited(appendLog(
        'chat', userText.length > 120 ? '${userText.substring(0, 120)}…' : userText));
    current ??= () {
      final c = Conversation(id: _uuid.v4(), title: t('newChat'));
      conversations.insert(0, c);
      return c;
    }();
    final conv = current!;
    conv.messages.add(ChatMessage(role: 'user', content: userText));
    if (conv.title == t('newChat') || conv.title == 'New Chat') {
      conv.title = userText.isNotEmpty
          ? (userText.length > 32 ? '${userText.substring(0, 32)}…' : userText)
          : conv.title;
    }
    conv.updatedAt = DateTime.now();
    notifyListeners();

    await _prepareWebContext(userText, voice: true, conv: conv);

    _genCancelled = false;
    final history = List<ChatMessage>.from(conv.messages);
    final assistantMessage = ChatMessage(role: 'assistant', content: '');
    conv.messages.add(assistantMessage);
    isGenerating = true;
    notifyListeners();
    final service = _llmFactory.current;
    _cancelGeneration = () => unawaited(service.stopGeneration());

    var spokenUpTo = 0;
    var full = '';
    try {
      if (selectedModel.isEmpty) {
        full = t('noModelsAvailable');
        assistantMessage.content = full;
        notifyListeners();
      } else {
        await for (final chunk in service.generateStream(conv, history)) {
          full = chunk; // cumulative
          assistantMessage.content = full;
          notifyListeners();
          if (!_genCancelled) {
            spokenUpTo = _emitSentences(full, spokenUpTo, onSentence);
          }
        }
      }
    } finally {
      isGenerating = false;
      _cancelGeneration = null;
      pendingWebContext = ''; // don't leak this turn's results into later ones
      conv.updatedAt = DateTime.now();
      _save();
      notifyListeners();
    }
    if (_genCancelled) return '';
    final reply = (conv.persona ?? persona).enforceEmojiPolicy(full);
    assistantMessage.content = reply.trim();
    notifyListeners();
    // Speak any trailing text that didn't end on a sentence boundary.
    final tail = full.length > spokenUpTo ? full.substring(spokenUpTo).trim() : '';
    if (tail.isNotEmpty) onSentence(tail);
    unawaited(_autoSaveMemoryFromExchange(conv, userText, reply.trim()));
    return reply;
  }

  // Emit each newly-completed sentence in [text] after index [from]; returns
  // the index up to which sentences have been dispatched. Splits on . ! ? … and
  // newlines. Called repeatedly as the cumulative stream grows.
  static final RegExp _sentenceBoundary = RegExp(r'[.!?…\n]');
  int _emitSentences(
      String text, int from, void Function(String) onSentence) {
    var start = from;
    var searchPos = from;
    while (searchPos < text.length) {
      final m = _sentenceBoundary.firstMatch(text.substring(searchPos));
      if (m == null) break;
      final end = searchPos + m.end;
      final sentence = text.substring(start, end).trim();
      if (sentence.length >= 2) onSentence(sentence);
      start = end;
      searchPos = end;
    }
    return start;
  }

  // Regenerate the last assistant reply: drop the trailing assistant
  // message(s) and generate a fresh one from the same context. No memory
  // auto-save — the user turn didn't change, only the reply.
  Future<void> regenerateLastReply(Conversation conv) async {
    if (isGenerating) return;
    while (conv.messages.isNotEmpty && conv.messages.last.role == 'assistant') {
      conv.messages.removeLast();
    }
    conv.updatedAt = DateTime.now();
    _save();
    notifyListeners();
    await _generateAssistantReply(conv);
  }

  // Continue the dialogue: generate another assistant turn from the current
  // context without the user typing anything ("what happens next").
  Future<void> continueReply(Conversation conv) async {
    if (isGenerating || conv.messages.isEmpty) return;
    await _generateAssistantReply(conv);
  }

  // Manual edit of any message's text (used by the in-bubble inline editor).
  void editMessage(Conversation conv, ChatMessage msg, String newText) {
    msg.content = newText.trim();
    conv.updatedAt = DateTime.now();
    _save();
    notifyListeners();
  }

  // Shared generation core. Assumes conv.messages already ends where the new
  // assistant reply should be generated from (sendMessage appended the user
  // turn; regenerate trimmed the old reply; continue leaves it as-is). RP
  // chats stream the reply in place; everything else awaits the full reply.
  // Best-effort: if web search is enabled and the query looks like it needs
  // fresh info, fetch results and stash them in pendingWebContext for this
  // turn (the prompt builders append it to the system prompt). Cleared by the
  // caller after generation so it never leaks into later turns.
  Future<void> _prepareWebContext(String? query,
      {bool voice = false, Conversation? conv}) async {
    pendingWebContext = '';
    final q = query?.trim() ?? '';
    if (q.isEmpty || !webSearchEnabled) return;
    if (conv?.rpModeEnabled ?? false) return; // don't web-search roleplay
    if (!WebSearchService.instance.needed(q)) return;
    if (voice) {
      VizOverlayServer.instance.note(t('webSearching'), kind: 'info');
    } else {
      final ctx = rootNavKey.currentContext;
      if (ctx != null) showAppSnackBar(ctx, t('webSearching'));
    }
    final hits = await WebSearchService.instance.search(q, app: this);
    pendingWebContext = WebSearchService.instance.contextBlock(hits);
  }

  Future<String> _generateAssistantReply(
    Conversation conv, {
    String? userTextForMemory,
  }) async {
    String replyText = '';
    _genCancelled = false;
    await _prepareWebContext(userTextForMemory, conv: conv);
    try {
    if (conv.rpModeEnabled) {
      final history = List<ChatMessage>.from(conv.messages);
      final assistantMessage = ChatMessage(role: 'assistant', content: '');
      conv.messages.add(assistantMessage);
      isGenerating = true;
      notifyListeners();

      final service = _llmFactory.forConversation(conv);
      _cancelGeneration = () => unawaited(service.stopGeneration());
      try {
        if (selectedModel.isEmpty) {
          assistantMessage.content = t('noModelsAvailable');
          notifyListeners();
        } else {
          await for (final chunk in service.generateStream(conv, history)) {
            assistantMessage.content = chunk;
            notifyListeners();
          }
          if (conv.rpConfig != null) {
            assistantMessage.content = RPGuardFilters.apply(
              assistantMessage.content,
              conv.rpConfig!,
            );
            notifyListeners();
          }
        }
      } finally {
        isGenerating = false;
        _cancelGeneration = null;
        conv.updatedAt = DateTime.now();
        _save();
        notifyListeners();
      }
      replyText = assistantMessage.content;
    } else {
      final service = _llmFactory.current;
      _cancelGeneration = () => unawaited(service.stopGeneration());
      String rawReply;
      try {
        rawReply = selectedModel.isEmpty
            ? t('noModelsAvailable')
            : await service.generateResponse(conv, conv.messages);
      } finally {
        _cancelGeneration = null;
      }
      // Cancelled (voice "stop"/Stop button): drop the aborted reply instead
      // of writing the backend's error string into the chat.
      if (_genCancelled) {
        conv.updatedAt = DateTime.now();
        notifyListeners();
        return '';
      }
      final reply = (conv.persona ?? persona).enforceEmojiPolicy(rawReply);
      conv.messages.add(ChatMessage(role: 'assistant', content: reply.trim()));
      conv.updatedAt = DateTime.now();
      _save();
      notifyListeners();
      replyText = reply;
    }
    } finally {
      pendingWebContext = ''; // don't leak this turn's results into later ones
    }

    if (userTextForMemory != null) {
      unawaited(
        _autoSaveMemoryFromExchange(conv, userTextForMemory, replyText.trim()),
      );
    }
    return replyText;
  }

  static const _memoryExtractionPrompt =
      'You extract durable facts about the user from one chat exchange, for '
      "a personal assistant's long-term memory. Stable facts only: "
      'preferences, profile details (name, job, location), ongoing projects '
      'or goals. Skip one-off questions, small talk, and anything temporary. '
      'Reply with exactly one short factual sentence about the user and '
      'nothing else, or reply with exactly NONE if there is nothing worth '
      'remembering.';

  Future<void> _autoSaveMemoryFromExchange(
    Conversation conv,
    String userText,
    String assistantText,
  ) async {
    final effectivePersona = conv.persona ?? persona;
    if (!effectivePersona.longMemory ||
        !effectivePersona.autoSaveMemories ||
        userText.trim().isEmpty ||
        selectedModel.isEmpty) {
      return;
    }
    final exchange = 'User: $userText\nAssistant: $assistantText';
    String result;
    try {
      result = isLocalModel(selectedModel)
          ? await _runLocalExtraction(exchange)
          : await _runRemoteExtraction(exchange);
    } catch (_) {
      return;
    }
    final fact = result.trim();
    if (fact.isEmpty || fact.toUpperCase() == 'NONE') return;
    if (effectivePersona.savedMemories.contains(fact)) return;
    effectivePersona.savedMemories.add(fact);
    _save();
    notifyListeners();
  }

  Future<String> _runRemoteExtraction(String exchange) async {
    final headers = {'Content-Type': 'application/json'};
    if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
    final res = await http
        .post(
          Uri.parse('$baseUrl/api/chat'),
          headers: headers,
          body: jsonEncode({
            'model': selectedModel,
            'stream': false,
            'messages': [
              {'role': 'system', 'content': _memoryExtractionPrompt},
              {'role': 'user', 'content': exchange},
            ],
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return 'NONE';
    final data = jsonDecode(res.body);
    if (data is! Map<String, dynamic>) return 'NONE';
    return _extractContent(data) ?? 'NONE';
  }

  Future<String> _runLocalExtraction(String exchange) async {
    // Same crash-sentinel discipline as LocalLLMService: never touch a model
    // that hard-crashed the native loader, and keep the sentinel on disk
    // until the first callback (fllamaChat only queues the request).
    if (crashedLocalModels.contains(selectedModel)) return 'NONE';
    final spec = localSpecFor(selectedModel);
    if (spec == null) return 'NONE';
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return 'NONE';

    final completer = Completer<String>();
    await setModelLoadingFlag(selectedModel);
    var cleared = false;
    try {
      await fllamaChat(
        OpenAiRequest(
          messages: [
            Message(Role.system, _memoryExtractionPrompt),
            Message(Role.user, exchange),
          ],
          modelPath: modelPath,
          contextSize: persona.localContextSize * 4,
          maxTokens: 60,
          temperature: 0.2,
        ),
        (response, openaiJson, done) {
          if (!cleared) {
            cleared = true;
            unawaited(clearModelLoadingFlag());
          }
          if (done && !completer.isCompleted) completer.complete(response);
        },
      );
    } catch (_) {
      if (!cleared) {
        cleared = true;
        unawaited(clearModelLoadingFlag());
      }
      if (!completer.isCompleted) completer.complete('NONE');
    }
    return completer.future;
  }
}

/* ============================ ТЕМА / ПРИЛОЖЕНИЕ ============================ */

// Root navigator key — lets background controllers (VoiceAssistant) show
// dialogs without a captured BuildContext.
final GlobalKey<NavigatorState> rootNavKey = GlobalKey<NavigatorState>();

class MiraiApp extends StatelessWidget {
  const MiraiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavKey,
      title: 'EVS',
      theme: _buildTheme(app.themeMode),
      darkTheme: _buildTheme(app.themeMode),
      themeMode: _palFor(app.themeMode).brightness == Brightness.light
          ? ThemeMode.light
          : ThemeMode.dark,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        // Combine the OS-level accessibility text scale with the app's own
        // font size setting, instead of discarding the system scale.
        final systemFactor = mq.textScaler.scale(100) / 100;
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(systemFactor * app.fontSize),
          ),
          child: child!,
        );
      },
      home: const ImmersiveSplash(),
    );
  }

  // On iOS, use the system font (San Francisco) — exactly the iOS typography —
  // by NOT forcing a bundled family (Flutter then falls back to the platform
  // default, which is SF on iOS). Apple's SF can't be bundled for other
  // platforms (proprietary), so Android/desktop/web keep the bundled Nunito.
  String? get _appFontFamily =>
      defaultTargetPlatform == TargetPlatform.iOS ? null : 'Nunito';

  ThemeData _buildTheme(AppThemeMode mode) {
    final p = _palFor(mode);
    final scheme = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: p.brightness,
    ).copyWith(
      primary: p.accent,
      surface: p.card2,
      onSurface: p.txt,
    );
    final card = p.card;
    final txtStyle = TextStyle(color: p.txt);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      dividerColor: p.stroke,
      fontFamily: _appFontFamily,
      // Cover the surfaces that otherwise fall back to Material defaults so the
      // system dialogs / menus / snackbars / tooltips follow the app theme even
      // when a call site doesn't set colours explicitly (TZ3.1 §1.2).
      dialogTheme: DialogThemeData(backgroundColor: card),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        textStyle: txtStyle,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: txtStyle,
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: card,
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        textStyle: txtStyle,
      ),
    );
  }
}

// Animated startup transition: the particle sphere (same one shown on the
// empty chat screen) swells toward the viewer and dissolves smoothly as the
// chat reveals behind it — "flying into" the sphere. Plays once per cold
// launch; a tap anywhere skips straight to the chat. The native static-orb
// splash is the instant first frame before this; ChatScreen is mounted under
// the overlay the whole time so it's already warm when the overlay clears.
class ImmersiveSplash extends StatefulWidget {
  const ImmersiveSplash({super.key});
  @override
  State<ImmersiveSplash> createState() => _ImmersiveSplashState();
}

class _ImmersiveSplashState extends State<ImmersiveSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _skip() {
    if (_done) return;
    _ctrl.stop();
    setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const _RootHome();
    return Stack(
      children: [
        const _RootHome(),
        Positioned.fill(
          child: GestureDetector(
            onTap: _skip,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                final t = _ctrl.value;
                // Brief hold, then ramp immersion; the whole overlay fades
                // out over the last third so the chat shows through.
                final immerse = t < 0.15 ? 0.0 : ((t - 0.15) / 0.85);
                final fade = (1 - ((t - 0.7) / 0.3)).clamp(0.0, 1.0);
                return Opacity(
                  opacity: fade,
                  child: Container(
                    color: _bg(context),
                    alignment: Alignment.center,
                    child: ParticleSphere(
                      size: 240,
                      dense: true,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : const Color(0xFF2F6BFF),
                      immerse: Curves.easeIn.transform(
                        immerse.clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// Semantic theme palette. The color helpers below resolve against the active
// AppThemeMode, so the hundreds of `_bg(context)`/`_card(context)`/… call sites
// re-theme automatically. A theme file specifies these 14 roles; everything
// semantic (connection statuses, CPU/RAM/VRAM bars, command-type badges, banner
// tones) is mapped onto the five anchors accent/success/danger/info/warn, so a
// new theme repaints the entire UI — no per-element hardcoded colours.
class _Palette {
  final Color bg; // page background
  final Color card; // primary surface
  final Color card2; // elevated surface / popovers
  final Color txt; // primary text
  final Color sub; // secondary text
  final Color accent; // primary interactive
  final Color stroke; // hairline / border
  final Color body; // light "body" text (secondary-primary)
  final Color faint; // muted / tertiary text
  final Color success; // done / success / connected
  final Color danger; // error
  final Color info; // in-progress / neutral-informational (connecting, loading)
  final Color warn; // caution / attention (no-model, starting)
  final Brightness brightness;
  const _Palette({
    required this.bg,
    required this.card,
    required this.card2,
    required this.txt,
    required this.sub,
    required this.accent,
    required this.stroke,
    required this.body,
    required this.faint,
    required this.success,
    required this.danger,
    required this.info,
    required this.warn,
    required this.brightness,
  });
}

// Dark = the app's shipped palette (canonical current values).
const _Palette _kDark = _Palette(
  bg: Color(0xFF0E0E15),
  card: Color(0xFF1C1C26),
  card2: Color(0xFF15151E),
  txt: Color(0xFFFFFFFF),
  sub: Color(0xFF8A8A95),
  accent: Color(0xFF7C8CF8),
  stroke: Color(0x14FFFFFF),
  body: Color(0xFFD0D4E2),
  faint: Color(0xFF6E7280),
  success: Color(0xFF54E08A),
  danger: Color(0xFFE05D5D),
  info: Color(0xFF5B9DF0),
  warn: Color(0xFFE0B24A),
  brightness: Brightness.dark,
);

// Claude — warm cream editorial palette (claudeDESIGN.md). Light theme: full
// readability needs the color pass (APPLE-THEME-TODO.md).
const _Palette _kClaude = _Palette(
  bg: Color(0xFFFAF9F5),
  card: Color(0xFFEFE9DE),
  card2: Color(0xFFF5F0E8),
  txt: Color(0xFF141413),
  sub: Color(0xFF6C6A64),
  accent: Color(0xFFCC785C),
  stroke: Color(0xFFE6DFD8),
  body: Color(0xFF3D3D3A),
  faint: Color(0xFF8E8B82),
  success: Color(0xFF5DB872),
  danger: Color(0xFFC64545),
  info: Color(0xFF2C6FD6),
  warn: Color(0xFFB8862A),
  brightness: Brightness.light,
);

// Claude — dark editorial palette (claude.ai dark mode): warm charcoal surfaces,
// cream text, the same terracotta accent.
const _Palette _kClaudeDark = _Palette(
  bg: Color(0xFF262624),
  card: Color(0xFF30302E),
  card2: Color(0xFF383735),
  txt: Color(0xFFF2F0E9),
  sub: Color(0xFFA8A69C),
  accent: Color(0xFFD97757),
  stroke: Color(0xFF423F3B),
  body: Color(0xFFE4E1D8),
  faint: Color(0xFF8E8C85),
  success: Color(0xFF5DB872),
  danger: Color(0xFFE0685E),
  info: Color(0xFF5B9DF0),
  warn: Color(0xFFE0B24A),
  brightness: Brightness.dark,
);

_Palette _palFor(AppThemeMode m) {
  switch (m) {
    case AppThemeMode.claude:
      return _kClaude;
    case AppThemeMode.claudeDark:
      return _kClaudeDark;
    case AppThemeMode.dark:
      return _kDark;
  }
}

_Palette _pal(BuildContext c) => _palFor(c.read<AppState>().themeMode);

// Canonical surface/text tokens — resolve against the active theme. The
// BuildContext param is kept so the hundreds of call sites stay unchanged.
Color _bg(BuildContext c) => _pal(c).bg;
Color _card(BuildContext c) => _pal(c).card;
Color _txt(BuildContext c) => _pal(c).txt;
Color _sub(BuildContext c) => _pal(c).sub;
Color _body(BuildContext c) => _pal(c).body;
Color _faint(BuildContext c) => _pal(c).faint;
Color _accent(BuildContext c) => _pal(c).accent;
Color _stroke(BuildContext c) => _pal(c).stroke;
Color _card2(BuildContext c) => _pal(c).card2;
Color _success(BuildContext c) => _pal(c).success;
Color _danger(BuildContext c) => _pal(c).danger;

// --- Derived semantic tokens ---------------------------------------------
// Computed from the base tokens above, so every theme gets them for free (no
// new _Palette fields). These replace the scattered hardcoded literals that
// were invisible or wrong on the light themes.

// Hairline divider inside cards/lists — fainter than the row `stroke`. Was the
// const white-alpha `_stroke(context)`, invisible on cream.
Color _divider(BuildContext c) => _stroke(c).withValues(alpha: 0.55);

// Muted ALL-CAPS section label (card headers). Was the fixed slate 0xFF8890A8.
Color _sectionLabel(BuildContext c) => _faint(c);

// Readable text/icon on top of an accent fill — black or white by the accent's
// luminance (terracotta/indigo take white; a pale accent takes near-black).
Color _onAccent(BuildContext c) => _accent(c).computeLuminance() > 0.55
    ? const Color(0xFF141413)
    : Colors.white;

// Semantic status colours (info/warn) — tuned per brightness for contrast.
Color _info(BuildContext c) => _pal(c).info;
Color _warn(BuildContext c) => _pal(c).warn;

// Modal barrier behind dialogs/sheets.
Color _scrim(BuildContext c) => Colors.black
    .withValues(alpha: _pal(c).brightness == Brightness.dark ? 0.58 : 0.32);

// Soft theme-aware drop shadow for elevated surfaces (cards/menus/sheets).
List<BoxShadow> _shadow(BuildContext c,
        {double y = 8, double blur = 24, double a = 0.18}) =>
    [
      BoxShadow(
        color: Colors.black.withValues(
            alpha: _pal(c).brightness == Brightness.dark ? a * 1.6 : a),
        blurRadius: blur,
        offset: Offset(0, y),
      )
    ];

// --- Design scales — single source of truth for spacing / radii / type.
// Ad-hoc `fontSize:` and magic paddings migrate onto these per screen.

abstract final class EvsSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class EvsRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 18;
  static const double pill = 999;
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
}

// Type scale. Colour is intentionally omitted — apply a token at the call site,
// e.g. `EvsType.body.copyWith(color: _txt(context))`. Family comes from
// ThemeData (Nunito), so it is not set here.
abstract final class EvsType {
  static const TextStyle display =
      TextStyle(fontSize: 30, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -0.3);
  static const TextStyle title =
      TextStyle(fontSize: 20, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: -0.2);
  static const TextStyle heading =
      TextStyle(fontSize: 16, height: 1.25, fontWeight: FontWeight.w700);
  static const TextStyle sectionLabel = TextStyle(
      fontSize: 11.5, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: 0.6);
  static const TextStyle body =
      TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w400);
  static const TextStyle bodyStrong =
      TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600);
  static const TextStyle label =
      TextStyle(fontSize: 13.5, height: 1.3, fontWeight: FontWeight.w600);
  static const TextStyle control =
      TextStyle(fontSize: 12.5, height: 1.2, fontWeight: FontWeight.w600);
  static const TextStyle caption =
      TextStyle(fontSize: 12, height: 1.4, fontWeight: FontWeight.w400);
  static const TextStyle mono =
      TextStyle(fontSize: 12.5, height: 1.4, fontFamily: 'monospace');
}

// Two-stop gradient derived from the theme accent — replaces the hardcoded
// blue/violet gradients on the assistant bubble, primary buttons and toggles so
// they follow each theme's accent (terracotta on Claude, blue on Apple, …).
List<Color> _accentGradientOf(BuildContext c) {
  final a = _accent(c);
  return [Color.lerp(a, Colors.white, 0.22)!, a];
}

LinearGradient _accentGradient(BuildContext c) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _accentGradientOf(c),
    );

// Subtle overlay fill / hairline that used to be a hardcoded white alpha (tuned
// for the dark shell). White-on-white is invisible on the light themes, so flip
// to a black alpha there — same visual weight on both.
Color _overlayFill(BuildContext c, double a) =>
    (_pal(c).brightness == Brightness.dark ? Colors.white : Colors.black)
        .withValues(alpha: a);

// Hero-visualization mark colour: light marks on dark themes, the theme accent
// (dark enough to read) on the light themes — the same rule ParticleSphere
// already applies inline.
Color _vizColor(BuildContext c) =>
    _pal(c).brightness == Brightness.dark ? Colors.white : _accent(c);

// Soft halo so text stays legible when it sits directly over a visualization or
// media (hero title/subtitle, the dark VoiceScreen). Dark halo on dark themes,
// light halo on light — either way it lifts the glyphs off the busy backdrop.
List<Shadow> _overTextShadows(BuildContext c) {
  final halo =
      (_pal(c).brightness == Brightness.dark ? Colors.black : Colors.white)
          .withValues(alpha: 0.6);
  return [
    Shadow(color: halo, blurRadius: 14),
    Shadow(color: halo, blurRadius: 5),
  ];
}

// Liquid Glass was removed — only the standard style ships. Kept as a no-op so
// the (now dead) glass branches at call sites still compile and render the
// standard path. TODO: physically prune those branches in a later cleanup.
bool _isGlass(BuildContext c) => false;

// Outer panel for bottom sheets / the chats drawer: a translucent blurred
// surface in glass style, a solid one otherwise. `rounded` controls the top
// corners (off for the full-height embedded chats drawer).
Widget _sheetSurface(
  BuildContext context, {
  bool rounded = true,
  Color? solid,
  required Widget child,
}) {
  final radius = rounded
      ? const BorderRadius.vertical(top: Radius.circular(24))
      : BorderRadius.zero;
  if (_isGlass(context)) {
    return GlassSurface(borderRadius: radius, child: child);
  }
  return Container(
    decoration: BoxDecoration(color: solid ?? _bg(context), borderRadius: radius),
    child: child,
  );
}

// Toggle: a true iOS CupertinoSwitch in glass style, the green Material
// Switch otherwise. Same green on/off semantics in both.
Widget _iosSwitch(
  BuildContext context,
  bool value,
  ValueChanged<bool> onChanged,
) {
  if (_isGlass(context)) {
    return CupertinoSwitch(
      value: value,
      activeTrackColor: const Color(0xFF34C759),
      onChanged: onChanged,
    );
  }
  return Switch(
    value: value,
    activeThumbColor: Colors.white,
    activeTrackColor: const Color(0xFF34C759),
    onChanged: onChanged,
  );
}

// Card-like surface used across screens (stat tiles, chat tiles, model
// cards, etc.). Glass mode → translucent blurred surface; standard mode →
// the original solid translucent _card fill (so standard is unchanged).
Widget _glassCard(
  BuildContext context, {
  required Widget child,
  double radius = 18,
  EdgeInsetsGeometry? padding,
  double alpha = 0.5,
}) {
  if (_isGlass(context)) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(radius),
      padding: padding,
      child: child,
    );
  }
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: _card(context).withValues(alpha: alpha),
      borderRadius: BorderRadius.circular(radius),
    ),
    child: child,
  );
}

class GlassMenuItem {
  final String value;
  final String label;
  final IconData? icon;
  final Color? color;
  const GlassMenuItem(this.value, this.label, {this.icon, this.color});
}

// Glass-styled context menu (used in glass mode instead of PopupMenuButton /
// showMenu, which can't backdrop-blur). Positions a GlassSurface near the
// anchor [position] (a global point), clamped on-screen, over a dismissible
// barrier. Returns the tapped item's value, or null if dismissed.
Future<String?> showGlassMenu(
  BuildContext context, {
  required Offset position,
  required List<GlassMenuItem> items,
  double menuWidth = 220,
}) {
  final size = MediaQuery.of(context).size;
  final menuHeight = items.length * 50.0 + 8;
  var left = position.dx;
  if (left + menuWidth > size.width - 8) left = size.width - 8 - menuWidth;
  if (left < 8) left = 8;
  var top = position.dy;
  if (top + menuHeight > size.height - 8) top = size.height - 8 - menuHeight;
  if (top < 8) top = 8;
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.08),
    transitionDuration: const Duration(milliseconds: 130),
    pageBuilder: (ctx, _, _) {
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: menuWidth,
            child: GlassSurface(
              borderRadius: BorderRadius.circular(16),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      InkWell(
                        onTap: () => Navigator.pop(ctx, items[i].value),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              if (items[i].icon != null) ...[
                                Icon(
                                  items[i].icon,
                                  size: 20,
                                  color: items[i].color ?? _txt(ctx),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(
                                  items[i].label,
                                  style: TextStyle(
                                    color: items[i].color ?? _txt(ctx),
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (i != items.length - 1)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: _sub(ctx).withValues(alpha: 0.14),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (ctx, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

// App-wide toast: a centered floating pill instead of the default full-width
// white SnackBar at the bottom edge. Glass mode → blurred glass pill;
// standard → solid rounded pill.
void showAppSnackBar(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.of(context);
  final label = Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(color: _txt(context), fontSize: 14),
  );
  const pad = EdgeInsets.symmetric(horizontal: 18, vertical: 12);
  final pill = _isGlass(context)
      ? GlassSurface(
          borderRadius: BorderRadius.circular(18),
          padding: pad,
          child: label,
        )
      : Container(
          padding: pad,
          decoration: BoxDecoration(
            color: _card(context),
            borderRadius: BorderRadius.circular(18),
          ),
          child: label,
        );
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      duration: const Duration(seconds: 2),
      content: Center(child: pill),
    ),
  );
}

// Opens the chat/personalization settings screen (normal opaque page). In
// glass style the screen gives itself an ambient colored backdrop so its
// glass tabs/cards read — see PersonalizationScreen.build.
void openPersonalization(
  BuildContext context, {
  Conversation? conversation,
  int initialTab = 0,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PersonalizationScreen(
        conversation: conversation,
        initialTab: initialTab,
      ),
    ),
  );
}

// Reusable translucent blurred surface for the Liquid Glass style. A real
// backdrop blur (so content behind shows through), a translucent fill tuned
// per brightness, and a soft top-left specular border. Used by the chat
// chrome (top bar, input bar, circle buttons), sheets, and cards when the
// glass style is on. Blur sigma is kept modest on purpose — stacking many
// BackdropFilters is expensive on weak devices.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final bool circle;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.blur = 18,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.white.withValues(alpha: 0.55);
    final highlight = dark
        ? Colors.white.withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.7);
    final shade = dark
        ? Colors.black.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.06);
    final clip = circle ? BorderRadius.circular(999) : borderRadius;
    return ClipRRect(
      borderRadius: clip,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: clip,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(highlight.withValues(alpha: 0.10), fill),
                fill,
                Color.alphaBlend(shade, fill),
              ],
            ),
            border: Border.all(color: highlight, width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

// Soft ambient colored glow used as the backdrop for glass screens (e.g. the
// chat-settings tabs), so the translucent glass surfaces above have a
// non-uniform background to refract. Three big blurred color blobs over the
// theme background.
class AmbientGlow extends StatelessWidget {
  const AmbientGlow({super.key});

  Widget _blob(Color c, double size) => ImageFiltered(
    imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final a = dark ? 0.55 : 0.30;
    return Container(
      color: _bg(context),
      child: Stack(
        children: [
          Positioned(
            left: -50,
            top: 140,
            child: _blob(const Color(0xFF3C78FF).withValues(alpha: a), 360),
          ),
          Positioned(
            right: -40,
            top: 120,
            child: _blob(const Color(0xFF9B5AFF).withValues(alpha: a), 320),
          ),
          Positioned(
            left: 150,
            top: 180,
            child: _blob(const Color(0xFF28C8B4).withValues(alpha: a), 240),
          ),
        ],
      ),
    );
  }
}

// Dialog that adopts the Liquid Glass look (translucent blurred surface) when
// the glass style is on, and the normal solid AlertDialog otherwise. Mirrors
// the AlertDialog API (title/content/actions/backgroundColor) so call sites
// are a drop-in swap.
class _AppDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  const _AppDialog({
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!_isGlass(context)) {
      return AlertDialog(
        title: title,
        content: content,
        actions: actions,
        backgroundColor: backgroundColor ?? _card(context),
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(28),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              DefaultTextStyle.merge(
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
                child: title!,
              ),
            if (title != null && content != null) const SizedBox(height: 14),
            if (content != null)
              Flexible(child: SingleChildScrollView(child: content!)),
            if (actions != null && actions!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class GlassTab {
  final String label;
  final IconData icon;
  const GlassTab({required this.label, required this.icon});
}

// Liquid Glass (iOS 26) segmented control: a frosted capsule with a floating
// active pill that slides between tabs. Ported from the project's reference
// design; label/icon colors adapt to the theme so it works on light too.
class LiquidGlassTabs extends StatelessWidget {
  const LiquidGlassTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    this.height = 58,
    this.accent = const Color(0xFF2F8DFF),
    this.blurSigma = 18,
    this.animationDuration = const Duration(milliseconds: 320),
  });

  final List<GlassTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final double height;
  final Color accent;
  final double blurSigma;
  final Duration animationDuration;

  @override
  Widget build(BuildContext context) {
    final radius = height / 2;
    const pad = 5.0;
    final pillRadius = radius - pad;
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: const EdgeInsets.all(pad),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.05),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: _ActivePill(
                    count: tabs.length,
                    index: selectedIndex,
                    radius: pillRadius,
                    duration: animationDuration,
                    accent: accent,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(pillRadius),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [
                            Colors.white.withValues(alpha: 0.12),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: _LiquidTabLabels(
                    tabs: tabs,
                    selectedIndex: selectedIndex,
                    onChanged: onChanged,
                    accent: accent,
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

class _ActivePill extends StatelessWidget {
  const _ActivePill({
    required this.count,
    required this.index,
    required this.radius,
    required this.duration,
    required this.accent,
  });

  final int count;
  final int index;
  final double radius;
  final Duration duration;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final align = count <= 1 ? 0.0 : (index / (count - 1)) * 2 - 1;
    final glassTop = Color.lerp(Colors.white, accent, 0.10)!;
    final glassBottom = Color.lerp(Colors.white, accent, 0.18)!;
    return AnimatedAlign(
      alignment: Alignment(align, 0),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: FractionallySizedBox(
        widthFactor: 1 / count,
        heightFactor: 1,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                glassTop.withValues(alpha: 0.60),
                glassBottom.withValues(alpha: 0.30),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.50),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.18),
                blurRadius: 1,
                offset: const Offset(0, -1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiquidTabLabels extends StatelessWidget {
  const _LiquidTabLabels({
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    required this.accent,
  });

  final List<GlassTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final idle = _sub(context);
    return Row(
      children: List.generate(tabs.length, (i) {
        final selected = i == selectedIndex;
        return Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(i),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tabs[i].icon,
                    size: 18,
                    color: selected ? accent : idle,
                  ),
                  const SizedBox(width: 8),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: selected ? _txt(context) : idle,
                    ),
                    child: Text(tabs[i].label),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

/* ============================ СФЕРА ИЗ ЧАСТИЦ ============================ */

class ParticleSphere extends StatefulWidget {
  final double size;
  final Color color;
  final bool dense;
  final bool active;
  final bool scattered;
  // Splash "immersion" progress (0..1): the sphere swells toward the viewer
  // and its particles stream smoothly outward along their own radial
  // direction while fading — "flying into" the sphere. Distinct from
  // `scattered`, which is the chaotic keyboard-scatter. Driven externally by
  // ImmersiveSplash's controller, not the internal disperse animation.
  final double immerse;
  // Optional live microphone level (smoothed, 0..1) — when provided, the
  // sphere's pulse, particle brightness, and jitter speed react to it.
  final ValueListenable<double>? soundLevel;
  const ParticleSphere({
    super.key,
    this.size = 220,
    this.color = Colors.white,
    this.dense = false,
    this.active = false,
    this.scattered = false,
    this.immerse = 0.0,
    this.soundLevel,
  });

  @override
  State<ParticleSphere> createState() => _ParticleSphereState();
}

class _ParticleSphereState extends State<ParticleSphere>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AnimationController _disperseCtrl;
  late final List<_P> _points;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _disperseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: widget.scattered ? 1.0 : 0.0,
    );
    final rnd = math.Random(7);
    final count = widget.dense ? 560 : 300;
    _points = List.generate(count, (_) {
      final u = rnd.nextDouble();
      final v = rnd.nextDouble();
      final theta = 2 * math.pi * u;
      final phi = math.acos(2 * v - 1);
      return _P(
        theta,
        phi,
        0.6 + rnd.nextDouble() * 1.8,
        rnd.nextDouble(),
        0.25 + rnd.nextDouble() * 0.85,
      );
    });
  }

  @override
  void didUpdateWidget(ParticleSphere old) {
    super.didUpdateWidget(old);
    if (widget.scattered != old.scattered) {
      if (widget.scattered) {
        _disperseCtrl.forward();
      } else {
        _disperseCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _disperseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final soundLevel = widget.soundLevel;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: soundLevel == null
            ? Listenable.merge([_ctrl, _disperseCtrl])
            : Listenable.merge([_ctrl, _disperseCtrl, soundLevel]),
        builder: (_, __) => CustomPaint(
          painter: _SpherePainter(
            _points,
            _ctrl.value,
            widget.color,
            widget.active,
            Curves.easeOutCubic.transform(_disperseCtrl.value),
            soundLevel?.value ?? 0.0,
            widget.immerse,
          ),
        ),
      ),
    );
  }
}

class _P {
  final double theta, phi, radius, seed, brightness;
  _P(this.theta, this.phi, this.radius, this.seed, this.brightness);
}

class _SpherePainter extends CustomPainter {
  final List<_P> points;
  final double t;
  final Color color;
  final bool active;
  final double disperse;
  // Smoothed microphone level, 0 (silence) .. 1 (loud). Only meaningful
  // while [active] is true; drives extra pulse, brightness and per-particle
  // jitter on top of the constant idle rotation/breathing.
  final double level;
  // Splash immersion 0..1 — sphere swells past the viewer and particles
  // stream smoothly outward (radially) while fading. See ParticleSphere.immerse.
  final double immerse;
  _SpherePainter(
    this.points,
    this.t,
    this.color,
    this.active,
    this.disperse,
    this.level,
    this.immerse,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseR = size.width / 2 * 0.92;
    final imm = immerse.clamp(0.0, 1.0);
    // The sphere balloons toward the viewer as immersion ramps up (quadratic
    // for an accelerating "fly-in"); every particle rides this larger radius
    // outward along its own direction, so they stream past the edges smoothly
    // instead of scattering randomly.
    final R = baseR * (1 + imm * imm * 6);
    final rotY = t * 2 * math.pi;
    final reactive = active ? level.clamp(0.0, 1.0) : 0.0;
    final pulse = active
        ? (0.92 + 0.08 * math.sin(t * 2 * math.pi * 3) + reactive * 0.22)
        : 1.0;
    // Louder input makes particles jitter faster around their resting spot.
    final jitterPhase = t * 2 * math.pi * (8 + reactive * 30);

    if (disperse < 1.0) {
      final glow = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(
              alpha: 0.18 * (1 - disperse) * (1 - imm) * (1 + reactive),
            ),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: R));
      canvas.drawCircle(center, R, glow);
    }

    final paint = Paint();
    for (final p in points) {
      double x = math.sin(p.phi) * math.cos(p.theta);
      double y = math.sin(p.phi) * math.sin(p.theta);
      double z = math.cos(p.phi);

      final cx = x * math.cos(rotY) + z * math.sin(rotY);
      final cz = -x * math.sin(rotY) + z * math.cos(rotY);
      x = cx;
      z = cz;

      final scale = (z + 1.5) / 2.5;
      double px = center.dx + x * R * pulse;
      double py = center.dy + y * R * pulse;

      if (reactive > 0) {
        final jitterAngle = jitterPhase + p.seed * 2 * math.pi;
        final jitterDist = reactive * p.radius * 2.4 * p.seed;
        px += math.cos(jitterAngle) * jitterDist;
        py += math.sin(jitterAngle) * jitterDist;
      }

      if (disperse > 0) {
        final dirAngle = p.seed * 2 * math.pi * 5.3;
        final dist = (0.5 + p.seed * 2.2) * R * disperse;
        px += math.cos(dirAngle) * dist;
        py += math.sin(dirAngle) * dist;
      }

      final opacity =
          ((0.25 + 0.75 * scale) *
                  p.brightness *
                  (1 - disperse) *
                  (1 - imm) *
                  (1 + reactive * 0.6))
              .clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(
        Offset(px, py),
        p.radius *
            scale *
            (1 - disperse * 0.3) *
            (1 + imm * 0.8) *
            (1 + reactive * 0.35),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpherePainter old) => true;
}

/* ============================ АНИМИРОВАННАЯ ОБВОДКА (УЛУЧШЕННАЯ) ============================ */

class GradientBorderPainter extends CustomPainter {
  final Animation<double> animation;
  final double radius;
  final double strokeWidth;
  final bool enabled;

  GradientBorderPainter({
    required this.animation,
    this.radius = 30,
    this.strokeWidth = 2,
    this.enabled = true,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !enabled) return;
    final rect = Offset.zero & size;

    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.blue.withValues(alpha: 0.8),
          Colors.purple.withValues(alpha: 0.8),
          Colors.blue.withValues(alpha: 0.8),
        ],
        transform: GradientRotation(animation.value * 2 * math.pi),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    // Stroke is centered on the full bounds (not inset), so half of it
    // bleeds outside the canvas where the opaque child can't cover it —
    // that's the only part of the ring that ends up visible.
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant GradientBorderPainter oldDelegate) => true;
}

// A soft, blurred halo of the same rotating border gradient, painted wider
// and behind the crisp ring so light appears to scatter inward from the
// edges toward the center instead of stopping sharply at the border line.
class BorderGlowPainter extends CustomPainter {
  final Animation<double> animation;
  final double radius;
  final double strokeWidth;
  final double blurSigma;

  BorderGlowPainter({
    required this.animation,
    this.radius = 30,
    this.strokeWidth = 50,
    this.blurSigma = 35,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.blue.withValues(alpha: 0.4),
          Colors.purple.withValues(alpha: 0.4),
          Colors.blue.withValues(alpha: 0.4),
        ],
        transform: GradientRotation(animation.value * 2 * math.pi),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma)
      ..isAntiAlias = true;

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant BorderGlowPainter oldDelegate) => true;
}

const kAccentGradientColors = [Color(0xFF4FACFE), Color(0xFF2F6BFF)];
const kSendActiveColor = Color(0xFF1ED760);

class GradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const GradientSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final trackRadius = Radius.circular(trackRect.height / 2);
    final activeTrackRadius = Radius.circular(
      (trackRect.height + additionalActiveTrackHeight) / 2,
    );

    final inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? Colors.white12;
    context.canvas.drawRRect(
      RRect.fromLTRBR(
        thumbCenter.dx,
        trackRect.top,
        trackRect.right,
        trackRect.bottom,
        trackRadius,
      ),
      inactivePaint,
    );

    final activeRect = RRect.fromLTRBR(
      trackRect.left,
      trackRect.top - (additionalActiveTrackHeight / 2),
      thumbCenter.dx,
      trackRect.bottom + (additionalActiveTrackHeight / 2),
      activeTrackRadius,
    );
    final activePaint = Paint()
      ..shader = const LinearGradient(
        colors: kAccentGradientColors,
      ).createShader(activeRect.outerRect);
    context.canvas.drawRRect(activeRect, activePaint);
  }
}

class AnimatedBorder extends StatefulWidget {
  final Widget child;
  final double radius;
  final double strokeWidth;
  final bool enabled;

  const AnimatedBorder({
    super.key,
    required this.child,
    this.radius = 28,
    this.strokeWidth = 2,
    this.enabled = true,
  });

  @override
  State<AnimatedBorder> createState() => _AnimatedBorderState();
}

class _AnimatedBorderState extends State<AnimatedBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: _sub(context).withValues(alpha: 0.3),
            width: widget.strokeWidth,
          ),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      );
    }
    return RepaintBoundary(
      child: Padding(
        // Reserves room for the half of the stroke that bleeds outside the
        // painted bounds (see GradientBorderPainter) so it isn't clipped.
        padding: EdgeInsets.all(widget.strokeWidth / 2),
        child: CustomPaint(
          painter: GradientBorderPainter(
            animation: _ctrl,
            radius: widget.radius,
            strokeWidth: widget.strokeWidth,
            enabled: widget.enabled,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/* ============================ ГЛАВНЫЙ ЭКРАН ============================ */

/* ======================= EVS DESKTOP UI (Windows) =======================
   Desktop shell from the EVS mockups (evs_ui.html / evs_s*.html): a left
   sidebar (history + System/Mic widgets) plus the existing chat screen
   embedded on the right (ChatScreen(desktop: true)), so the animated
   composer, the particle orb and all send/voice logic are reused as-is. */

// Mockup palette: violet accent + blue→purple→pink gradient on near-black.
const Color _evsGMid = Color(0xFF8855CC);
const Color _evsBgSolid = Color(0xFF09090F);

// Desktop window background — the radial gradient from the mockups.
const BoxDecoration _evsBgDecoration = BoxDecoration(
  gradient: RadialGradient(
    center: Alignment(0.2, -0.7),
    radius: 1.2,
    colors: [Color(0xFF13151E), Color(0xFF0D0E16), _evsBgSolid],
    stops: [0.0, 0.45, 1.0],
  ),
);

// Shell window background: keep the dark radial gradient on dark themes; on the
// light themes (apple/claude) fall back to the flat themed page background so the
// whole shell actually reads as light instead of a dark plate.
BoxDecoration _evsShellBg(BuildContext c) =>
    _pal(c).brightness == Brightness.dark
        ? _evsBgDecoration
        : BoxDecoration(color: _bg(c));

// Left nav rail / sidebar background: dark vertical gradient on dark themes, a
// flat themed card surface on light.
BoxDecoration _evsRailBg(BuildContext c) => BoxDecoration(
      border: Border(right: BorderSide(color: _stroke(c))),
      gradient: _pal(c).brightness == Brightness.dark
          ? const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0B0C14), _evsBgSolid],
            )
          : null,
      color: _pal(c).brightness == Brightness.dark ? null : _card(c),
    );

// The conic-gradient "bead" logo used across desktop screens.
// The brand mark: the new logo (assets/icon/icon.png) with a one-shot entrance
// animation that replays each time the widget mounts (fade + scale-overshoot +
// slight spin-settle), then holds static. Keeps a `const` constructor so the
// existing `const _EvsLogoMark(...)` call sites stay valid unchanged.
class _EvsLogoMark extends StatefulWidget {
  final double size;
  const _EvsLogoMark({this.size = 30});
  @override
  State<_EvsLogoMark> createState() => _EvsLogoMarkState();
}

class _EvsLogoMarkState extends State<_EvsLogoMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<double> _spin;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 720));
    _fade = CurvedAnimation(
        parent: _ctrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOut));
    _scale = Tween<double>(begin: 0.55, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _spin = Tween<double>(begin: -0.45, end: 0.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Opacity(
        opacity: _fade.value.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: _spin.value,
          child: Transform.scale(scale: _scale.value, child: child),
        ),
      ),
      child: Image.asset(
        'assets/icon/icon.png',
        width: widget.size,
        height: widget.size,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

String _evsRelTime(AppState app, DateTime dt) {
  final now = DateTime.now();
  if (now.difference(dt).inMinutes < 1) return app.t('justNow');
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dt.year, dt.month, dt.day);
  String two(int n) => n.toString().padLeft(2, '0');
  if (that == today) return '${two(dt.hour)}:${two(dt.minute)}';
  if (that == today.subtract(const Duration(days: 1))) return app.t('yesterday');
  return '${dt.day}.${two(dt.month)}';
}

// Executes user-defined voice commands on Windows. Launching apps/files/URLs
// and running shell commands go through dart:io Process; media and volume keys
// use Win32 keybd_event (user32) via FFI. Phrase matching is deterministic
// (exact -> contains -> token overlap); semantic matching is the sidecar's job.
typedef _KeybdEventNative = Void Function(Uint8, Uint8, Uint32, IntPtr);
typedef _KeybdEventDart = void Function(int, int, int, int);

class CommandExecutor {
  CommandExecutor._();
  static final CommandExecutor instance = CommandExecutor._();

  _KeybdEventDart? _keybd;
  bool _keybdTried = false;

  _KeybdEventDart? get _keybdFn {
    if (!_keybdTried) {
      _keybdTried = true;
      try {
        _keybd = DynamicLibrary.open('user32.dll')
            .lookupFunction<_KeybdEventNative, _KeybdEventDart>('keybd_event');
      } catch (_) {}
    }
    return _keybd;
  }

  void _tapKey(int vk) {
    final fn = _keybdFn;
    if (fn == null) return;
    fn(vk, 0, 0, 0); // key down
    fn(vk, 0, 2, 0); // key up (KEYEVENTF_KEYUP)
  }

  // Strip surrounding quotes users often paste around a path.
  static String _unquote(String s) {
    var t = s.trim();
    if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
      t = t.substring(1, t.length - 1);
    }
    return t;
  }

  Future<bool> execute(VoiceCommand c) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return false;
    try {
      switch (c.type) {
        case VoiceCommandType.app:
        case VoiceCommandType.file:
        case VoiceCommandType.url:
          final target = _unquote(c.value);
          // Microsoft Store / UWP apps are launched by their AppsFolder id
          // ("shell:AppsFolder\<AUMID>") via explorer, which cmd's `start`
          // doesn't handle reliably.
          if (target.toLowerCase().startsWith('shell:')) {
            await io.Process.start('explorer.exe', [target],
                runInShell: false);
            return true;
          }
          // `start` resolves .lnk shortcuts, exes, folders and URLs alike. The
          // empty "" is the window-title arg `start` requires before the path.
          final r = await io.Process.run(
              'cmd', ['/c', 'start', '', target],
              runInShell: false);
          return r.exitCode == 0;
        case VoiceCommandType.shell:
          await io.Process.start('cmd', ['/c', c.value], runInShell: false);
          return true;
        case VoiceCommandType.system:
          return _system(c.value);
        case VoiceCommandType.media:
          return _media(c.value);
        case VoiceCommandType.appVolume:
          // Per-app volume needs the sidecar (Core Audio) and the spoken number,
          // so it is dispatched via AppState.applyAppVolume, not this launcher.
          return false;
      }
    } catch (_) {
      return false;
    }
  }

  bool _system(String v) {
    final t = v.toLowerCase();
    if (t.contains('lock') || t.contains('блок')) {
      io.Process.run('rundll32', ['user32.dll,LockWorkStation']);
      return true;
    }
    if (t.contains('sleep') || t.contains('сон') || t.contains('сп')) {
      io.Process.run('rundll32', ['powrprof.dll,SetSuspendState', '0', '1', '0']);
      return true;
    }
    if (t.contains('mute') || t.contains('звук')) {
      _tapKey(0xAD);
      return true;
    }
    final up = t.contains('up') || t.contains('+') || t.contains('гром');
    final down = t.contains('down') || t.contains('-') || t.contains('тиш');
    if (t.contains('vol') || t.contains('гром') || up || down) {
      _tapKey(down ? 0xAE : 0xAF); // volume down / up
      return true;
    }
    return false;
  }

  bool _media(String v) {
    final t = v.toLowerCase();
    if (t.contains('next') || t.contains('след')) {
      _tapKey(0xB0);
    } else if (t.contains('prev') || t.contains('пред')) {
      _tapKey(0xB1);
    } else {
      _tapKey(0xB3); // play/pause
    }
    return true;
  }

  String _norm(String s) => s
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[^0-9a-zа-яё ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  // Best deterministic match for a spoken phrase, or null if below threshold.
  VoiceCommand? match(String text, List<VoiceCommand> cmds,
      {double threshold = 0.5}) {
    final t = _norm(text);
    if (t.isEmpty) return null;
    VoiceCommand? best;
    double bestScore = 0;
    for (final c in cmds) {
      final p = _norm(c.phrase);
      if (p.isEmpty) continue;
      double s;
      if (t == p) {
        s = 1.0;
      } else if (t.contains(p) || p.contains(t)) {
        s = 0.9;
      } else {
        final ta = t.split(' ').toSet();
        final pa = p.split(' ').toSet();
        final inter = ta.intersection(pa).length;
        final union = ta.union(pa).length;
        s = union == 0 ? 0 : inter / union;
      }
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    return bestScore >= threshold ? best : null;
  }
}

typedef _GmsExNative = Int32 Function(Pointer<Uint8>);
typedef _GmsExDart = int Function(Pointer<Uint8>);
typedef _GetSystemTimesNative = Int32 Function(
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetSystemTimesDart = int Function(
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

class SystemStats {
  final double cpu; // 0..1
  final double ram; // 0..1
  final int totalRamBytes;
  final int usedRamBytes;
  const SystemStats(
      {this.cpu = 0, this.ram = 0, this.totalRamBytes = 0, this.usedRamBytes = 0});
}

// Win32 CPU + RAM monitor via kernel32 (GlobalMemoryStatusEx / GetSystemTimes).
// Windows-only; silently no-ops elsewhere. Also feeds real total RAM back into
// AppState so the local-model context ceiling stops defaulting to 4096 on PC.
class SystemMonitor {
  SystemMonitor._();
  static final SystemMonitor instance = SystemMonitor._();

  final ValueNotifier<SystemStats> stats = ValueNotifier(const SystemStats());
  Timer? _timer;
  _GmsExDart? _gmsEx;
  _GetSystemTimesDart? _getSystemTimes;
  int _prevIdle = 0, _prevKernel = 0, _prevUser = 0;

  void start(AppState app) {
    if (defaultTargetPlatform != TargetPlatform.windows || _timer != null) return;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      _gmsEx =
          k32.lookupFunction<_GmsExNative, _GmsExDart>('GlobalMemoryStatusEx');
      _getSystemTimes = k32.lookupFunction<_GetSystemTimesNative,
          _GetSystemTimesDart>('GetSystemTimes');
    } catch (_) {
      return;
    }
    _sample(app, first: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample(app));
  }

  void _sample(AppState app, {bool first = false}) {
    final mem = _readMemory();
    final cpu = _readCpu();
    final prev = stats.value;
    stats.value = SystemStats(
      cpu: cpu ?? prev.cpu,
      ram: mem?.$1 ?? prev.ram,
      totalRamBytes: mem?.$2 ?? prev.totalRamBytes,
      usedRamBytes: mem?.$3 ?? prev.usedRamBytes,
    );
    if (first && mem != null && mem.$2 > 0) {
      app.setDeviceRamMb((mem.$2 / (1024 * 1024)).round());
    }
  }

  (double, int, int)? _readMemory() {
    final fn = _gmsEx;
    if (fn == null) return null;
    final buf = calloc<Uint8>(64);
    try {
      final bd = ByteData.sublistView(buf.asTypedList(64));
      bd.setUint32(0, 64, Endian.little); // dwLength
      if (fn(buf) == 0) return null;
      final load = bd.getUint32(4, Endian.little) / 100.0;
      final total = bd.getUint64(8, Endian.little);
      final avail = bd.getUint64(16, Endian.little);
      return (load.clamp(0.0, 1.0), total, total - avail);
    } finally {
      calloc.free(buf);
    }
  }

  double? _readCpu() {
    final fn = _getSystemTimes;
    if (fn == null) return null;
    final idle = calloc<Uint64>();
    final kernel = calloc<Uint64>();
    final user = calloc<Uint64>();
    try {
      if (fn(idle, kernel, user) == 0) return null;
      final i = idle.value, k = kernel.value, u = user.value;
      final dIdle = i - _prevIdle;
      final dTotal = (k - _prevKernel) + (u - _prevUser);
      _prevIdle = i;
      _prevKernel = k;
      _prevUser = u;
      if (dTotal <= 0) return null;
      return ((dTotal - dIdle) / dTotal).clamp(0.0, 1.0);
    } finally {
      calloc.free(idle);
      calloc.free(kernel);
      calloc.free(user);
    }
  }
}

// Ties every helper process the app spawns (Python voice sidecar, the floating
// widget process, the XTTS voice-clone engine) to THIS process's lifetime via a
// Windows Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. When the app
// exits — cleanly, on a crash, or force-killed from Task Manager — the OS
// closes the job handle and terminates every assigned child, so nothing is left
// running. Graceful shutdown still kills them explicitly first; this is the
// safety net for the paths where that code never runs. No-ops off Windows.
class ProcessJob {
  ProcessJob._();
  static final ProcessJob instance = ProcessJob._();

  int _job = 0; // job HANDLE (0 = unavailable)
  bool _init = false;
  _OpenProcessDart? _openProcess;
  _AssignJobDart? _assign;
  _CloseHandleDart? _closeHandle;

  void _ensure() {
    if (_init) return;
    _init = true;
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final createJob =
          k32.lookupFunction<_CreateJobNative, _CreateJobDart>('CreateJobObjectW');
      final setInfo = k32.lookupFunction<_SetJobInfoNative, _SetJobInfoDart>(
          'SetInformationJobObject');
      _openProcess = k32
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      _assign = k32
          .lookupFunction<_AssignJobNative, _AssignJobDart>('AssignProcessToJobObject');
      _closeHandle = k32
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
      final job = createJob(nullptr, nullptr);
      if (job == 0) return;
      // JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on x64; its LimitFlags
      // (a DWORD) sits at offset 16. Set JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
      final info = calloc<Uint8>(144);
      try {
        final bd = ByteData.sublistView(info.asTypedList(144));
        bd.setUint32(16, 0x00002000, Endian.little); // LimitFlags
        const jobObjectExtendedLimitInformation = 9;
        if (setInfo(job, jobObjectExtendedLimitInformation, info, 144) == 0) {
          _closeHandle?.call(job);
          return;
        }
      } finally {
        calloc.free(info);
      }
      _job = job;
    } catch (_) {
      _job = 0;
    }
  }

  // Assign a freshly spawned helper process to the job. Safe to call for any
  // pid; silently no-ops if the job is unavailable.
  void add(int pid) {
    _ensure();
    final job = _job;
    final open = _openProcess, assign = _assign, close = _closeHandle;
    if (job == 0 || pid <= 0 || open == null || assign == null || close == null) {
      return;
    }
    try {
      // PROCESS_SET_QUOTA (0x0100) | PROCESS_TERMINATE (0x0001).
      final h = open(0x0101, 0, pid);
      if (h == 0) return;
      try {
        assign(job, h);
      } finally {
        close(h);
      }
    } catch (_) {}
  }
}

typedef _CreateJobNative = IntPtr Function(Pointer<Void>, Pointer<Void>);
typedef _CreateJobDart = int Function(Pointer<Void>, Pointer<Void>);
typedef _SetJobInfoNative = Int32 Function(IntPtr, Int32, Pointer<Uint8>, Uint32);
typedef _SetJobInfoDart = int Function(int, int, Pointer<Uint8>, int);
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _AssignJobNative = Int32 Function(IntPtr, IntPtr);
typedef _AssignJobDart = int Function(int, int);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

// Windows desktop integration: system tray, minimize/close-to-tray, a global
// "show window" hotkey (Ctrl+Shift+Space) and launch-at-startup. All calls are
// guarded to Windows and wrapped in try/catch so an unsupported platform or a
// missing capability never crashes startup.
// ==================== FLOATING-WIDGET PROCESS SERVER ====================
// Runs in the MAIN app: hosts a localhost WebSocket, spawns the widget
// process (`evs.exe --viz-overlay --port=N`) and feeds it settings (cfg),
// the assistant speech level (lvl), assistant state (va) and transient
// notices (note). The widget sends back `open` (double-click → show the
// chat), `moved` (persist position) and `hidden` (its × button).
class VizOverlayServer {
  VizOverlayServer._();
  static final VizOverlayServer instance = VizOverlayServer._();

  AppState? _app;
  io.HttpServer? _http;
  io.WebSocket? _client;
  io.Process? _proc;
  bool _enabled = false;
  int _respawns = 0;
  String _lastCfg = '';

  Future<void> start(AppState app) async {
    _app = app;
    app.addListener(_pushCfg);
    VoiceLevels.instance.tts.addListener(_pushLvl);
    VoiceAssistant.instance.state.addListener(_pushVa);
    VoiceAssistant.instance.wakeActive.addListener(_pushVa);
    VoiceAssistant.instance.wakePulse.addListener(_pushVa);
    // One-time: hand the legacy prefs position over to the widget's own file so
    // its saved spot survives this update; afterwards the widget owns it.
    await WidgetPosStore.migrateFromPrefs(app.prefs);
    if (app.overlayMode) await _spawn();
  }

  Future<void> setVisible(bool on) async {
    _enabled = on;
    if (on) {
      _respawns = 0;
      await _spawn();
    } else {
      _killProc();
    }
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
        _lastCfg = ''; // force a full cfg snapshot for the new client
        _pushCfg();
        _pushVa();
        ws.listen(_onMsg, onDone: () {
          if (identical(_client, ws)) _client = null;
        }, onError: (_) {});
      } catch (_) {}
    });
  }

  // The widget runs the SAME binary with --viz-overlay; launch it from a
  // distinctly-named copy so it shows as "evs_widget.exe" in Task Manager's
  // Details tab instead of a second anonymous "evs.exe" (you can tell the
  // visualization widget apart from the main app and the voice sidecar).
  // Refreshed whenever the main exe changes (after an update); falls back to the
  // main exe if the directory isn't writable. NB: the updater's kill-list
  // (applyAndRestart) must include evs_widget.exe so updates can replace files.
  Future<String> _widgetExe() async {
    final main = io.Platform.resolvedExecutable;
    try {
      final sep = io.Platform.pathSeparator;
      final copy = io.File('${io.File(main).parent.path}${sep}evs_widget.exe');
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
    _enabled = true;
    try {
      await _ensureServer();
      if (_proc != null) return;
      final proc = await io.Process.start(await _widgetExe(),
          ['--viz-overlay', '--port=${_http!.port}']);
      _proc = proc;
      ProcessJob.instance.add(proc.pid); // die with the app
      unawaited(proc.exitCode.then((_) {
        if (!identical(_proc, proc)) return;
        _proc = null;
        _client = null;
        // Crash guard: bring the widget back once; repeated deaths (or the
        // user closing it twice) leave it off until re-enabled.
        if (_enabled && _respawns < 1) {
          _respawns++;
          unawaited(_spawn());
        }
      }));
    } catch (_) {}
  }

  void _killProc() {
    _send({'t': 'bye'});
    final p = _proc;
    _proc = null;
    _client?.close();
    _client = null;
    if (p != null) {
      // Give it a moment to exit cleanly on 'bye', then make sure.
      Future.delayed(const Duration(milliseconds: 400), () {
        try {
          p.kill();
        } catch (_) {}
      });
    }
  }

  void dispose() {
    _enabled = false;
    _killProc();
    try {
      _http?.close(force: true);
    } catch (_) {}
    _http = null;
  }

  void _send(Map<String, dynamic> m) {
    try {
      _client?.add(jsonEncode(m));
    } catch (_) {}
  }

  /// Transient notice on the widget (command executed/failed, …) — the main
  /// window is often hidden, so in-app toasts alone would go unseen.
  void note(String text, {String kind = 'info'}) =>
      _send({'t': 'note', 'text': text, 'kind': kind});

  void _pushCfg() {
    final app = _app;
    if (app == null || _client == null) return;
    final m = {
      't': 'cfg',
      'lang': app.lang,
      // The widget always shows something — 'none' only hides the chat hero.
      'vizType': app.vizType == 'none' ? 'sphere' : app.vizType,
      'vizAccent': app.vizAccent,
      'orbSize': app.orbSize,
      'orbSpeed': app.orbSpeed,
      'barCount': app.barCount,
      'wakeWord': app.wakeWord,
      'size': app.overlaySize * kWidgetWindowScale,
    };
    final s = jsonEncode(m);
    if (s == _lastCfg) return;
    _lastCfg = s;
    try {
      _client?.add(s);
    } catch (_) {}
  }

  void _pushLvl() => _send({'t': 'lvl', 'v': VoiceLevels.instance.tts.value});

  void _pushVa() => _send({
        't': 'va',
        's': VoiceAssistant.instance.state.value.name,
        'wake': VoiceAssistant.instance.wakeActive.value,
        'pulse': VoiceAssistant.instance.wakePulse.value,
      });

  void _onMsg(dynamic data) {
    final app = _app;
    if (data is! String || app == null) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'open':
        unawaited(DesktopIntegration.instance.showMainWindow());
        break;
      case 'hidden':
        // The user hid the widget with its × — reflect that in settings
        // (also kills the now-invisible process).
        if (app.overlayMode) app.setOverlayMode(false);
        break;
    }
  }
}

class DesktopIntegration with WindowListener, TrayListener {
  DesktopIntegration._();
  static final DesktopIntegration instance = DesktopIntegration._();

  // WinSparkle update feed (auto_updater). Points at the appcast.xml hosted on
  // the desktop branch; each <item> carries a DSA-signed Windows installer
  // enclosure (see dist/appcast.xml + dist/README.md). Updating the app =
  // publishing a new installer + bumping this feed. Unlike Shorebird this
  // delivers FULL builds, native code included.
  // NB: the Flutter project lives in the repo's test1/ subdir, so the raw path
  // includes test1/. Branch is `desktop`.
  static const String updateFeedUrl =
      'https://raw.githubusercontent.com/kekw2077/mirai/desktop/test1/dist/appcast.xml';

  // Effective feed: an EVS_UPDATE_FEED env var overrides the baked-in URL. Lets
  // you point a build at a staging/local appcast (e.g. http://localhost:8000/
  // appcast.xml) to test the whole WinSparkle flow without publishing — and is
  // handy for a self-hosted feed later. Empty/unset -> production URL.
  static String get effectiveFeedUrl {
    try {
      final env = io.Platform.environment['EVS_UPDATE_FEED'];
      if (env != null && env.trim().isNotEmpty) return env.trim();
    } catch (_) {}
    return updateFeedUrl;
  }

  AppState? _app;
  Timer? _winSaveTimer;

  Future<void> init(AppState app) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _app = app;
    try {
      launchAtStartup.setup(
        appName: 'EVS',
        appPath: io.Platform.resolvedExecutable,
      );
      await applyAutostart(app.autostart);

      await trayManager.setIcon('assets/icon/app_icon.ico');
      await trayManager.setToolTip('EVS');
      await _rebuildTrayMenu();
      trayManager.addListener(this);

      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      await hotKeyManager.unregisterAll();
      final hk = HotKey(
        key: PhysicalKeyboardKey.space,
        modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
        scope: HotKeyScope.system,
      );
      await hotKeyManager.register(hk, keyDownHandler: (_) => _show());

      SystemMonitor.instance.start(app);
      unawaited(MicMeter.instance.start(deviceId: app.inputDeviceId));
      unawaited(_bootstrapSidecar(app));
      VoiceAssistant.instance.attach(app);
      // Bring the remote-input listener up if it was left enabled (TZ §14).
      if (app.remoteInputEnabled) RemoteInputServer.instance.start(app);

      // Auto-update (Discord-style): AppUpdater silently downloads the new
      // installer in the background and shows an in-app "restart to update"
      // banner — no native WinSparkle prompts.
      AppUpdater.instance.start(app);

      // Verify CosyVoice reachability once at launch; an unavailable server
      // auto-reverts the TTS engine to Piper (§3.2) so speech never silently
      // breaks and the app doesn't stay stuck on an unreachable engine.
      unawaited(app.checkCosyvoiceOnStartup());

      // Floating widget: separate process, fed over a localhost WebSocket.
      // Spawns immediately when enabled (the chat window itself may stay
      // hidden — see main()).
      unawaited(VizOverlayServer.instance.start(app));

      // Widget-first startup: the native runner re-shows the window on the
      // first frame AFTER main()'s early hide — hide again once rendering
      // has settled so only the widget and tray remain.
      if (app.overlayMode) {
        unawaited(Future.delayed(const Duration(milliseconds: 900), () async {
          if (_app?.overlayMode ?? false) await windowManager.hide();
        }));
      }
    } catch (_) {}
  }

  // Cleanly shut everything down and exit so the (already launched, detached)
  // silent installer can replace our files and relaunch the new version.
  Future<void> quitForUpdate() => _quit();

  // Load the component manifest, then start the sidecar. On a slim install the
  // sidecar isn't present locally, so fetch the (essential) component first —
  // its download progress shows in Settings → STT. XTTS stays opt-in.
  Future<void> _bootstrapSidecar(AppState app) async {
    try {
      await ComponentManager.instance.loadManifest();
      // Apply any update staged on a previous run (before the exe is launched).
      await ComponentManager.instance.applyStagedUpdates();
      SidecarClient.instance.setSttModel(app.whisperModel);
      await SidecarClient.instance.setSttEngine(app.sttSidecarEngine);
      await SidecarClient.instance.setDenoise(app.denoiseMode);
      SidecarClient.instance.setSttDevice(app.sttDevice); // sets CLI arg too
      await SidecarClient.instance.setTtsVoice(app.ttsPiperVoice,
          modelId: app._voiceModelId(app.ttsPiperVoice));
      // One-shot readiness greeting (TZ3.4): the first time the backend reaches
      // `ready` this launch, speak via the always-available system TTS (pyttsx3),
      // not the clone voice (which may need a download). Visual orb signal is
      // independent of this toggle.
      SidecarClient.instance.onStateReady = () {
        if (app.announceReady && SidecarClient.instance.ttsAvailable) {
          SidecarClient.instance.speak(app.t('readyGreeting'),
              rate: app.ttsRate, volume: app.ttsVolume);
        }
      };
      // Start with whatever sidecar is available now (component / bundled /
      // dev). Only download if nothing is present — never block startup on an
      // update. A newer component version is staged in the background for the
      // next launch (applied by applyStagedUpdates above).
      if (!await SidecarClient.instance.hasLocalSidecar()) {
        await ComponentManager.instance.ensure('sidecar');
      } else {
        unawaited(ComponentManager.instance.stageUpdate('sidecar'));
      }
      await SidecarClient.instance.start();
      // Push game-mode config (thresholds, exclusions, localized phrases) now
      // that the socket is up; the sidecar started the monitor with defaults.
      app.applyGameModeConfig();
      unawaited(app.syncActiveMics()); // resolve multi-mic devices (block 8.2)
    } catch (_) {}
  }

  Future<void> _rebuildTrayMenu() async {
    final app = _app;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: app?.t('trayShow') ?? 'Show EVS'),
      MenuItem(
          key: 'overlay', label: app?.t('trayOverlay') ?? 'Floating widget'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: app?.t('trayQuit') ?? 'Quit'),
    ]));
  }

  // Used by VizOverlayServer when the floating widget is double-clicked.
  Future<void> showMainWindow() => _show();

  Future<void> applyAutostart(bool enable) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      if (enable) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (_) {}
  }

  Future<void> _show() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _quit() async {
    // Capture final geometry while the window is still alive.
    await saveWindowNow();
    // Explicitly stop every helper process on a clean exit. The Job Object
    // (ProcessJob) is the backstop for crashes / force-kills where this code
    // never runs.
    try {
      VizOverlayServer.instance.dispose();
    } catch (_) {}
    try {
      await SidecarClient.instance.stop();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
  }

  // Persist the main window's geometry, debounced. Fired on every move/resize/
  // (un)maximize; the 500 ms debounce collapses a drag into one write. Skips
  // hidden/minimized states so a tray-hidden window never overwrites the real
  // geometry with garbage. Written to prefs (userdata) → survives updates.
  void _scheduleWindowSave() {
    _winSaveTimer?.cancel();
    _winSaveTimer =
        Timer(const Duration(milliseconds: 500), () => unawaited(saveWindowNow()));
  }

  Future<void> saveWindowNow() async {
    final app = _app;
    if (app == null) return;
    try {
      if (!await windowManager.isVisible()) return;
      if (await windowManager.isMinimized()) return;
      final maximized = await windowManager.isMaximized();
      await app.prefs.setBool('winMax', maximized);
      // Keep the last *restored* size while maximized, so unmaximizing later
      // returns to it instead of a full-screen rect.
      if (!maximized) {
        final b = await windowManager.getBounds();
        await app.prefs.setDouble('winX', b.left);
        await app.prefs.setDouble('winY', b.top);
        await app.prefs.setDouble('winW', b.width);
        await app.prefs.setDouble('winH', b.height);
      }
    } catch (_) {}
  }

  @override
  void onWindowResized() => _scheduleWindowSave();

  @override
  void onWindowMoved() => _scheduleWindowSave();

  @override
  void onWindowMaximize() => _scheduleWindowSave();

  @override
  void onWindowUnmaximize() => _scheduleWindowSave();

  @override
  void onWindowClose() {
    // Flush geometry synchronously enough to survive a hard close (the debounce
    // timer may not fire before we hide/quit).
    unawaited(saveWindowNow());
    if (_app?.closeToTray ?? false) {
      windowManager.hide();
    } else {
      _quit();
    }
  }

  @override
  void onWindowMinimize() {
    if (_app?.minimizeToTray ?? false) windowManager.hide();
  }

  @override
  void onWindowFocus() {
    // A deferred "update ready" prompt waits for the chat window to actually
    // be on screen (it may start hidden behind the floating widget).
    AppUpdater.instance.promptIfPending();
  }

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
        break;
      case 'overlay':
        final app = _app;
        if (app != null) app.setOverlayMode(!app.overlayMode);
        break;
      case 'quit':
        _quit();
        break;
    }
  }
}

// ============================ WEB SEARCH ============================
// RAG web search: fetch a few results for a query and format them as a compact
// context block fed to the model, so the assistant can answer with fresh info
// (exchange rates, weather, news…). Provider order: Tavily (key) → Brave (key)
// → keyless DuckDuckGo HTML scrape. Every network call is wrapped so a failure
// just yields an empty result and the model answers as it normally would.
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

  Future<List<SearchHit>> search(String query, {AppState? app}) async {
    final tav = app?.tavilyKey ?? '';
    final brave = app?.braveKey ?? '';
    try {
      if (tav.isNotEmpty) return await _tavily(query, tav);
      if (brave.isNotEmpty) return await _brave(query, brave);
      return await _ddg(query);
    } catch (e) {
      unawaited(appendLog('errors', 'WebSearch: $e'));
      return const [];
    }
  }

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
  }

  // A previous run launched the silent installer (marker written by
  // applyAndRestart). If we're back up but the version DIDN'T advance, the
  // update silently failed to apply (locked files / cancelled) — surface it
  // instead of looping invisibly. One-shot: the marker is always cleared.
  Future<void> _checkPreviousUpdateOutcome(AppState app) async {
    try {
      final marker = io.File(await updateDownloadPath('pending_update.txt'));
      if (!await marker.exists()) return;
      final expected = (await marker.readAsString()).trim();
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
          // ignore: use_build_context_synchronously
          if (ctx != null) {
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
        await downloadFileWithProgress(item.url, dest, (r, t) {
          progress.value = t > 0 ? r / t : 0;
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
        'https://github.com/kekw2077/mirai/releases/tag/desktop-v$version';
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
                      const TextStyle(color: Color(0xFF6E7280), fontSize: 12)),
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
    final script = '''@echo off
setlocal enableextensions
set "RLOG=$runnerLog"
echo [%date% %time%] updater started > "%RLOG%"
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
"$path" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /DIR="$runDir" /LOG="$installLog"
echo [%date% %time%] installer exit %errorlevel%, relaunching >> "%RLOG%"
start "" "$exePath"
echo [%date% %time%] done >> "%RLOG%"
schtasks /Delete /TN "EVSSelfUpdate" /F >nul 2>&1
del "%~f0" >nul 2>&1
''';
    try {
      await io.File(scriptPath).writeAsString(script);
    } catch (_) {}
    bool launched = false;
    // Preferred: a one-shot scheduled task detaches the script from this process
    // entirely (not a child, not in our session/job) so it survives our exit.
    try {
      await io.Process.run('schtasks', [
        '/Create', '/TN', 'EVSSelfUpdate',
        '/TR', 'cmd /c "$scriptPath"',
        '/SC', 'ONCE', '/ST', '23:59', '/F',
      ]);
      final r = await io.Process.run('schtasks', ['/Run', '/TN', 'EVSSelfUpdate']);
      launched = r.exitCode == 0;
    } catch (_) {}
    // Fallback: launch the script through the shell (`start`) so it is reparented
    // to the session and outlives us.
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
  const ComponentInfo(
      {required this.id,
      required this.fileName,
      required this.version,
      required this.url,
      required this.sha256,
      required this.size,
      this.archive = false,
      this.exe = ''});

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
      );
}

class ComponentManager {
  ComponentManager._();
  static final ComponentManager instance = ComponentManager._();

  static const String manifestUrl =
      'https://raw.githubusercontent.com/kekw2077/mirai/desktop/test1/dist/components.json';

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

  Future<void> loadManifest() async {
    final sep = io.Platform.pathSeparator;
    final cache = io.File('${await _componentsDir()}${sep}manifest.json');
    String? body;
    try {
      final res = await http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        body = res.body;
        try {
          await cache.writeAsString(body);
        } catch (_) {}
      }
    } catch (_) {}
    // Offline / fetch failed: fall back to the last cached manifest so component
    // resolution (which sidecar exe to launch) still works without network,
    // instead of an empty manifest that reverts to a stale legacy onefile.
    if (body == null) {
      try {
        if (await cache.exists()) body = await cache.readAsString();
      } catch (_) {}
    }
    if (body != null) {
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
    await refreshStates();
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

  Future<String> _versionMarkerPath(String id) async =>
      '${await _componentsDir()}${io.Platform.pathSeparator}.$id.version';

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
  Future<void> stageUpdate(String id) async {
    final info = _manifest[id];
    if (info == null || info.url.isEmpty) return;
    if (info.archive) return; // archives update via re-download, not staging
    if (await installedPath(id) == null) return; // nothing installed to update
    if (await _readVersion(id) == info.version) return; // already current
    final sep = io.Platform.pathSeparator;
    final staged = '${await _componentsDir()}$sep${info.fileName}.new';
    if (await io.File(staged).exists() && await _verify(staged, info.sha256)) {
      return; // already staged
    }
    try {
      await downloadFileWithProgress(info.url, staged, (_, __) {}, () => false);
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
  // (so the target exe isn't locked).
  Future<void> applyStagedUpdates() async {
    try {
      final dir = await _componentsDir();
      final sep = io.Platform.pathSeparator;
      for (final entry in _manifest.entries) {
        if (entry.value.archive) continue; // archives aren't staged
        final name = entry.value.fileName;
        final staged = io.File('$dir$sep$name.new');
        if (!await staged.exists()) continue;
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
      await downloadFileWithProgress(info.url, dest, (r, t) {
        st.value = ComponentStatus(ComponentState.downloading,
            progress: t > 0 ? r / t : 0);
      }, () => false);
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
        final extracted = await _extract(id, dest);
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
  Future<String?> _extract(String id, String zipPath) async {
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
      final exe = '$target$sep${_manifest[id]?.exe ?? ''}';
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

enum SidecarStatus { stopped, starting, connected }

// Manages the Python voice/ML sidecar: spawns the process (bundled
// evs_sidecar.exe in release, `python sidecar/main.py` in dev), reads its
// chosen port from stdout, connects over a localhost WebSocket and exposes
// STT/VAD/TTS/intent. Everything is best-effort: if Python or the sidecar is
// missing, status stays `stopped` and the app keeps working with system STT.
class SidecarClient {
  SidecarClient._();
  static final SidecarClient instance = SidecarClient._();

  final ValueNotifier<SidecarStatus> status =
      ValueNotifier(SidecarStatus.stopped);
  bool sttAvailable = false;
  bool ttsAvailable = false;
  // TTS engine/voice (TZ2 block 5): '' voice = system pyttsx3; else a Piper
  // voice synthesized in-sidecar. Applied at spawn (CLI) and hot-swapped live.
  String _ttsEngine = 'pyttsx3';
  String _ttsVoice = '';
  String _ttsVoiceDir = '';
  final ValueNotifier<Map<String, bool>> ttsEngines =
      ValueNotifier(const {'pyttsx3': false, 'piper': false});
  final ValueNotifier<(String engine, String voice, String state, String? msg)?>
      ttsStatus = ValueNotifier(null);
  String _sttModel = 'small'; // Whisper model size sent on connect / on change
  String _sttEngine = 'whisper'; // active sidecar engine: whisper | gigaam
  String _gigaamDir = ''; // <userdata>/models/gigaam-v3, resolved lazily
  // Live STT-engine state for the "Модель распознавания" UI (TZ1).
  final ValueNotifier<(String engine, String state, String? message)?>
      engineStatus = ValueNotifier(null);
  final ValueNotifier<int> sttLatencyMs = ValueNotifier(0);
  String lastSttDevice = ''; // winning mic label from the last final (block 8.2)
  final ValueNotifier<Map<String, bool>> engines =
      ValueNotifier(const {'whisper': false, 'gigaam': false});
  String _denoise = 'off'; // off | light | strong
  String _denoiseDir = ''; // <userdata>/models (holds denoise-gtcrn/, denoise-df/)
  final ValueNotifier<(String mode, String state, String? message)?>
      denoiseStatus = ValueNotifier(null);
  // Compute device (TZ2 block 6): user's desired STT device. GPU info comes from
  // `ready`; only Whisper has a CUDA path (gigaam/denoise are CPU-only here).
  String _sttDevice = 'cpu'; // cpu | cuda
  // (available, name, vramTotalMb, vramUsedMb, vramPercent, cuda)
  final ValueNotifier<(bool, String, int, int, double, bool)> gpuInfo =
      ValueNotifier((false, '', 0, 0, 0.0, false));
  final ValueNotifier<Map<String, bool>> engineGpu =
      ValueNotifier(const {'whisper': false, 'gigaam': false});
  // (requested, active, fellBack) from stt.device.
  final ValueNotifier<(String, String, bool)?> deviceStatus =
      ValueNotifier(null);
  // Game mode (TZ2 block 7): (active, reason) from gamemode.status.
  final ValueNotifier<(bool active, String reason)> gameModeStatus =
      ValueNotifier((false, ''));
  // Backend readiness state machine (TZ3.4): starting | loading_models | ready
  // | error. The sidecar loads STT models greedily on connect and warms them
  // up, so the first real command doesn't pay the init cost; the UI reflects
  // this so the user knows when it's safe to speak.
  final ValueNotifier<String> sttState = ValueNotifier('starting');
  String? _sttStateMessage; // error detail (shown in UI on `error`)
  String? get sttStateMessage => _sttStateMessage;
  // Fired exactly once per app launch the first time the backend reaches
  // `ready` — used for the one-shot "готова слушать" greeting. Reconnects
  // re-emit `ready`, but this stays guarded so the greeting never repeats.
  void Function()? onStateReady;
  bool _readyAnnounced = false;

  final _partial = StreamController<String>.broadcast();
  final _finalText = StreamController<String>.broadcast();
  final _vad = StreamController<bool>.broadcast();
  Stream<String> get partial => _partial.stream;
  Stream<String> get finalText => _finalText.stream;
  Stream<bool> get vad => _vad.stream;

  io.Process? _proc;
  io.WebSocket? _ws;
  bool _starting = false;

  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    if (_starting || status.value == SidecarStatus.connected) return;
    _starting = true;
    status.value = SidecarStatus.starting;
    try {
      final launch = await _resolveLaunchAsync();
      if (launch == null) {
        status.value = SidecarStatus.stopped;
        return;
      }
      // Keep Whisper model downloads inside the app's data folder.
      final env = <String, String>{};
      try {
        final cache = '${await componentsDirPath()}'
            '${io.Platform.pathSeparator}hf-cache';
        env['HF_HOME'] = cache;
      } catch (_) {}
      // Choose the STT engine + denoise mode at spawn (TZ1 / TZ2 block 1).
      await _ensureGigaamDir();
      await _ensureDenoiseDir();
      final args = <String>[
        ...launch.$2,
        '--engine', _sttEngine,
        '--denoise', _denoise,
        '--device', _sttDevice,
        '--tts-engine', _ttsEngine,
      ];
      if (_gigaamDir.isNotEmpty) args.addAll(['--gigaam-dir', _gigaamDir]);
      if (_denoiseDir.isNotEmpty) args.addAll(['--denoise-dir', _denoiseDir]);
      if (_ttsVoice.isNotEmpty) args.addAll(['--tts-voice', _ttsVoice]);
      if (_ttsVoiceDir.isNotEmpty) args.addAll(['--tts-voice-dir', _ttsVoiceDir]);
      _proc = await io.Process.start(launch.$1, args,
          runInShell: false, environment: env);
      ProcessJob.instance.add(_proc!.pid); // die with the app
      // The sidecar's stderr used to be silently dropped, so STT/mic failures
      // (bad device, model load errors, crashes) left no trace. Log it to
      // logs/sidecar.log so problems are diagnosable.
      _proc!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final t = line.trim();
        if (t.isNotEmpty) unawaited(appendLog('sidecar', 'ERR $t'));
      });
      final ready = Completer<int>();
      _proc!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('EVS_SIDECAR_READY')) {
          final p = int.tryParse(line.split(' ').last.trim());
          if (p != null && !ready.isCompleted) ready.complete(p);
        } else if (line.trim().isNotEmpty) {
          unawaited(appendLog('sidecar', line.trim()));
        }
      });
      _proc!.exitCode.then((_) {
        if (status.value != SidecarStatus.connected) {
          status.value = SidecarStatus.stopped;
        }
      });
      final port = await ready.future.timeout(const Duration(seconds: 25));
      await _connect(port);
    } catch (_) {
      status.value = SidecarStatus.stopped;
    } finally {
      _starting = false;
    }
  }

  // True if a sidecar is available locally (downloaded component, bundled exe,
  // or dev source) — i.e. start() can run without downloading first.
  Future<bool> hasLocalSidecar() async => (await _resolveLaunchAsync()) != null;

  // Prefer the on-demand downloaded component, then fall back to a bundled exe
  // / dev source. Async because the components dir lookup is async.
  Future<(String, List<String>)?> _resolveLaunchAsync() async {
    try {
      final comp =
          await ComponentManager.instance.installedPath('sidecar',
              fileName: 'evs_sidecar.exe');
      if (comp != null) return (comp, ['--port', '0']);
    } catch (_) {}
    return _resolveLaunch();
  }

  (String, List<String>)? _resolveLaunch() {
    try {
      final sep = io.Platform.pathSeparator;
      final exeDir = io.File(io.Platform.resolvedExecutable).parent.path;
      // Release: frozen sidecar bundled next to the app exe.
      final bundled = io.File('$exeDir${sep}evs_sidecar.exe');
      if (bundled.existsSync()) return (bundled.path, ['--port', '0']);
      // Dev: run from source. Search the working dir and a few parents of the
      // exe (build\windows\x64\runner\Debug -> ... -> test1) for sidecar\main.py,
      // preferring the project venv interpreter over system python.
      final roots = <String>[io.Directory.current.path];
      var dir = io.Directory(exeDir);
      for (int i = 0; i < 7; i++) {
        roots.add(dir.path);
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
      for (final base in roots) {
        final main = io.File('$base${sep}sidecar${sep}main.py');
        if (!main.existsSync()) continue;
        final venvPy =
            io.File('$base${sep}sidecar$sep.venv${sep}Scripts${sep}python.exe');
        final py = venvPy.existsSync() ? venvPy.path : 'python';
        return (py, [main.path, '--port', '0']);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _connect(int port) async {
    _ws = await io.WebSocket.connect('ws://127.0.0.1:$port');
    status.value = SidecarStatus.connected;
    // Tell the sidecar which Whisper model to use (it lazy-loads on first
    // transcription / model change).
    _send({'type': 'stt.config', 'model': _sttModel});
    _ws!.listen((data) {
      try {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        switch (m['type']) {
          case 'ready':
            final c = m['capabilities'] as Map?;
            sttAvailable = c?['stt'] == true;
            ttsAvailable = c?['tts'] == true;
            final e = c?['engines'];
            if (e is Map) {
              engines.value = {
                'whisper': e['whisper'] == true,
                'gigaam': e['gigaam'] == true,
              };
              engineGpu.value = {
                'whisper': e['whisper_gpu'] == true,
                'gigaam': e['gigaam_gpu'] == true,
              };
            }
            final g = c?['gpu'];
            if (g is Map) {
              gpuInfo.value = (
                g['available'] == true,
                g['name'] as String? ?? '',
                (g['vram_total_mb'] as num?)?.toInt() ?? 0,
                (g['vram_used_mb'] as num?)?.toInt() ?? 0,
                (g['vram_percent'] as num?)?.toDouble() ?? 0.0,
                g['cuda'] == true,
              );
            }
            final te = c?['tts_engines'];
            if (te is Map) {
              ttsEngines.value = {
                'pyttsx3': te['pyttsx3'] == true,
                'piper': te['piper'] == true,
              };
            }
            break;
          case 'stt.partial':
            _partial.add(m['text'] as String? ?? '');
            break;
          case 'stt.final':
            final lat = (m['latency_ms'] as num?)?.toInt();
            if (lat != null) sttLatencyMs.value = lat;
            // Which mic won arbitration (multi-mic, block 8.2) — logged with the
            // command so it's visible which device heard the winning phrase.
            lastSttDevice = m['device'] as String? ?? '';
            _finalText.add(m['text'] as String? ?? '');
            break;
          case 'stt.engine_status':
            engineStatus.value = (
              m['engine'] as String? ?? '',
              m['state'] as String? ?? '',
              m['message'] as String?,
            );
            break;
          case 'stt.denoise_status':
            denoiseStatus.value = (
              m['mode'] as String? ?? '',
              m['state'] as String? ?? '',
              m['message'] as String?,
            );
            break;
          case 'stt.state':
            final s = m['state'] as String? ?? '';
            _sttStateMessage = m['message'] as String?;
            sttState.value = s;
            unawaited(appendLog('sidecar',
                'state: $s${_sttStateMessage != null && _sttStateMessage!.isNotEmpty ? ' — $_sttStateMessage' : ''}'));
            // One-shot readiness greeting: fire the hook the first time the
            // backend is ready this launch; reconnects re-emit `ready` but the
            // guard keeps the greeting to exactly one per launch.
            if (s == 'ready' && !_readyAnnounced) {
              _readyAnnounced = true;
              try {
                onStateReady?.call();
              } catch (_) {}
            }
            break;
          case 'vad':
            _vad.add(m['speaking'] == true);
            break;
          // Live playback level of the assistant's speech — feeds the
          // visualizations while TTS is talking.
          case 'tts.level':
            VoiceLevels.instance.tts.value =
                ((m['level'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
            break;
          case 'tts.done':
            VoiceLevels.instance.tts.value = 0;
            break;
          case 'audio.sessions.result':
            final list = (m['sessions'] as List?)
                    ?.whereType<Map>()
                    .map((e) => e.cast<String, dynamic>())
                    .toList() ??
                <Map<String, dynamic>>[];
            for (final c in _sessionWaiters) {
              if (!c.isCompleted) c.complete(list);
            }
            _sessionWaiters.clear();
            break;
          case 'app.volume.result':
            final res = m.cast<String, dynamic>();
            for (final c in _volumeWaiters) {
              if (!c.isCompleted) c.complete(res);
            }
            _volumeWaiters.clear();
            break;
          case 'stt.transcribe.result':
            // One-shot network-voice recognition (§14). Keyed by request id so
            // overlapping phone commands don't cross wires.
            final id = m['id']?.toString() ?? '';
            final c = _transcribeWaiters.remove(id);
            if (c != null && !c.isCompleted) {
              c.complete((m['text'] as String? ?? '').trim());
            }
            break;
          case 'tts.status':
            ttsStatus.value = (
              m['engine'] as String? ?? '',
              m['voice'] as String? ?? '',
              m['state'] as String? ?? '',
              m['message'] as String?,
            );
            break;
          case 'stt.device':
            deviceStatus.value = (
              m['requested'] as String? ?? 'cpu',
              m['active'] as String? ?? 'cpu',
              m['fell_back'] == true,
            );
            break;
          case 'gamemode.status':
            gameModeStatus.value = (
              m['active'] == true,
              m['reason'] as String? ?? '',
            );
            break;
        }
      } catch (_) {}
    }, onDone: () => status.value = SidecarStatus.stopped,
        onError: (_) => status.value = SidecarStatus.stopped);
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  // Active mics resolved by AppState (label + per-device denoise). 2+ entries
  // trigger multi-mic capture + arbitration in the sidecar (TZ2 block 8.2).
  List<Map<String, String>> _activeMics = [];
  void setActiveMics(List<Map<String, String>> mics) => _activeMics = mics;

  void sttStart(String language, {String? prompt}) {
    // Selected mic by name — otherwise the sidecar records from the system
    // default device, which may differ from the one picked in Settings (the
    // level meter there uses the picked one). Only send a device when we
    // actually have one: a stale/empty label could point at a mic that's gone
    // and break capture — an empty field lets the sidecar fall back to the
    // system default.
    final mics =
        _activeMics.where((m) => (m['label'] ?? '').isNotEmpty).toList();
    final useMulti = mics.length >= 2;
    final device = MicMeter.instance.currentLabel;
    _send({
      'type': 'stt.start',
      'language': language,
      if (useMulti) 'devices': mics,
      if (!useMulti && device.isNotEmpty) 'device': device,
      // Whisper decoding primer (wake word + command vocabulary) to bias
      // recognition toward the phrases the assistant expects.
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
    });
  }
  void sttStop() => _send({'type': 'stt.stop'});
  // Switch the Whisper model size live (sidecar reloads on next transcription).
  void setSttModel(String model) {
    _sttModel = model;
    _send({'type': 'stt.config', 'model': model});
  }

  Future<void> _ensureGigaamDir() async {
    if (_gigaamDir.isNotEmpty) return;
    try {
      final root = await appDataRoot();
      final sep = io.Platform.pathSeparator;
      _gigaamDir = '$root${sep}models${sep}gigaam-v3';
    } catch (_) {}
  }

  /// Path where the GigaAM model is expected — surfaced in the UI "not found"
  /// hint so the user knows where to place it.
  Future<String> gigaamModelDir() async {
    await _ensureGigaamDir();
    return _gigaamDir;
  }

  // Switch the sidecar recognition engine live (whisper | gigaam). Applied at
  // spawn via CLI too; here it hot-swaps a running sidecar (TZ1).
  Future<void> setSttEngine(String engine) async {
    _sttEngine = engine == 'gigaam' ? 'gigaam' : 'whisper';
    await _ensureGigaamDir();
    _send({
      'type': 'stt.config',
      'engine': _sttEngine,
      'gigaam_dir': _gigaamDir,
    });
  }

  Future<void> _ensureDenoiseDir() async {
    if (_denoiseDir.isNotEmpty) return;
    try {
      _denoiseDir = await modelsDirPath();
    } catch (_) {}
  }

  // Switch the noise-suppression mode live (off | light | strong) — TZ2 block 1.
  Future<void> setDenoise(String mode) async {
    _denoise = (mode == 'light' || mode == 'strong') ? mode : 'off';
    await _ensureDenoiseDir();
    _send({
      'type': 'stt.config',
      'denoise': _denoise,
      'denoise_dir': _denoiseDir,
    });
  }

  // Switch the STT compute device live (cpu | cuda) — TZ2 block 6. Applied at
  // spawn via CLI too. A manual change also lifts any game-mode offload layer.
  void setSttDevice(String device) {
    _sttDevice = device == 'cuda' ? 'cuda' : 'cpu';
    _send({'type': 'stt.config', 'device': _sttDevice});
  }

  // Push the game-mode config (triggers, thresholds, exclusions, localized
  // notification phrases) to the sidecar — TZ2 block 7.
  void configureGameMode({
    required bool fullscreen,
    required bool vram,
    required double vramEnter,
    required double vramExit,
    required bool notify,
    required List<String> exclusions,
    required Map<String, String> texts,
  }) {
    _send({
      'type': 'gamemode.config',
      'fullscreen_enabled': fullscreen,
      'vram_enabled': vram,
      'vram_enter': vramEnter,
      'vram_exit': vramExit,
      'notify_enabled': notify,
      'exclusions': exclusions,
      'texts': texts,
    });
  }

  // <userdata>/models/<modelId> — where a Piper voice bundle is downloaded.
  Future<String> _voiceDirFor(String modelId) async {
    if (modelId.isEmpty) return '';
    try {
      final sep = io.Platform.pathSeparator;
      return '${await modelsDirPath()}$sep$modelId';
    } catch (_) {
      return '';
    }
  }

  // Switch the active TTS voice live (TZ2 block 5). '' voice = system pyttsx3;
  // otherwise Piper with the given voice id + its downloaded dir. Applied at
  // spawn via CLI too (fields are read by start()).
  Future<void> setTtsVoice(String voiceId, {String modelId = ''}) async {
    _ttsVoice = voiceId;
    if (voiceId.isEmpty) {
      _ttsEngine = 'pyttsx3';
      _ttsVoiceDir = '';
    } else {
      _ttsEngine = 'piper';
      _ttsVoiceDir = await _voiceDirFor(modelId);
    }
    _send({
      'type': 'tts.config',
      'engine': _ttsEngine,
      'voice': _ttsVoice,
      'voice_dir': _ttsVoiceDir,
    });
  }

  // Speak a fixed sample in a specific Piper voice without changing the active
  // one (TZ2 block 5, "Прослушать образец").
  Future<void> previewTtsVoice(String voiceId, String modelId, String text,
      {double rate = 1.0, double volume = 1.0}) async {
    final dir = await _voiceDirFor(modelId);
    _send({
      'type': 'tts.preview',
      'voice': voiceId,
      'voice_dir': dir,
      'text': text,
      'rate': rate,
      'volume': volume,
    });
  }

  // Pending request/response waiters for the per-app volume feature (Ф2). The
  // sidecar replies once per request; a list tolerates a rare overlap and is
  // cleared when the reply lands.
  final List<Completer<List<Map<String, dynamic>>>> _sessionWaiters = [];
  final List<Completer<Map<String, dynamic>>> _volumeWaiters = [];

  // One-shot transcription waiters (network voice, §14), keyed by request id.
  // Recognition can be slow (cold model, long clip), so several may be in
  // flight; the map matches each reply to its caller.
  final Map<String, Completer<String>> _transcribeWaiters = {};
  int _transcribeSeq = 0;

  // Active per-app audio sessions (for the command-config picker). Empty on
  // timeout or when the sidecar is down.
  Future<List<Map<String, dynamic>>> listAudioSessions() {
    final c = Completer<List<Map<String, dynamic>>>();
    _sessionWaiters.add(c);
    _send({'type': 'audio.sessions'});
    return c.future.timeout(const Duration(seconds: 4),
        onTimeout: () => <Map<String, dynamic>>[]);
  }

  // Set/adjust/mute a process's volume. [value] is 0..1 for set/increase/
  // decrease. Result carries {ok, found, volume, ...}; ok=false means the app
  // had no active session.
  Future<Map<String, dynamic>> setAppVolume(String process, String action,
      {double? value}) {
    final c = Completer<Map<String, dynamic>>();
    _volumeWaiters.add(c);
    _send({
      'type': 'app.volume',
      'process': process,
      'action': action,
      if (value != null) 'value': value,
    });
    return c.future.timeout(const Duration(seconds: 4),
        onTimeout: () => <String, dynamic>{'ok': false, 'found': 0});
  }

  // Recognize a complete utterance handed over as base64 audio (a WAV
  // container, or raw 16 kHz mono int16 when [format] is 'pcm16'). Used by the
  // network voice endpoint (§14): the phone posts audio, the sidecar decodes +
  // transcribes it, and we route the text through the normal command pipeline.
  // Returns '' on timeout, a decode/STT failure, or silence.
  Future<String> transcribeAudio(String audioBase64,
      {String format = 'wav'}) {
    final id = 't${_transcribeSeq++}';
    final c = Completer<String>();
    _transcribeWaiters[id] = c;
    _send({
      'type': 'stt.transcribe',
      'id': id,
      'audio': audioBase64,
      'format': format,
    });
    return c.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _transcribeWaiters.remove(id);
      return '';
    });
  }

  void speak(String text, {double rate = 1.0, double volume = 1.0}) =>
      _send({'type': 'tts.speak', 'text': text, 'rate': rate, 'volume': volume});
  // Cut off any in-progress speech synthesis/playback immediately (voice stop
  // command). The sidecar's main.py already handles `tts.stop`.
  void stopSpeaking() => _send({'type': 'tts.stop'});
  void parseIntent(String text, List<Map<String, dynamic>> commands,
          {double threshold = 0.5}) =>
      _send({
        'type': 'intent.parse',
        'text': text,
        'commands': commands,
        'threshold': threshold,
      });

  Future<void> stop() async {
    try {
      await _ws?.close();
    } catch (_) {}
    try {
      _proc?.kill();
    } catch (_) {}
    status.value = SidecarStatus.stopped;
  }
}

// ============================ VOICE ASSISTANT ============================
// Alice-like always-listening loop. When wake-word mode is on, it keeps the
// sidecar's Whisper STT running, watches finalized transcripts for the wake
// word ("EVS, ..."), and routes the rest to a matching voice command (with a
// confirmation policy) or to the chat model — optionally speaking the reply.

// armed = the wake word was heard on its own; the NEXT utterance is taken as
// the command without repeating the wake word (~8 s window).
enum VaState { idle, listening, armed, thinking, running }

class VoiceAssistant {
  VoiceAssistant._();
  static final VoiceAssistant instance = VoiceAssistant._();

  AppState? _app;
  bool _attached = false;
  bool _listening = false;
  bool _busy = false;
  // Set true when a voice "stop" phrase interrupts the current command/reply so
  // the in-flight `_handle` won't speak the (now-cancelled) result.
  bool _stopFlag = false;
  // Serializes TTS so the interpreter (which may be async in "model" mode) can
  // never reorder streamed sentences: each _speak links onto the previous one.
  Future<void> _ttsChain = Future.value();

  // UI signals (home-screen indicator).
  final ValueNotifier<VaState> state = ValueNotifier(VaState.idle);
  // The last phrase Whisper heard (shown so the user can confirm recognition
  // works and see how their wake word is actually transcribed).
  final ValueNotifier<String> lastHeard = ValueNotifier('');
  // Wake-word feedback: `wakeActive` flips true for ~2.5 s so the UI can flash
  // "heard you!"; `wakePulse` carries the trigger timestamp for the
  // visualizers' glow burst.
  final ValueNotifier<bool> wakeActive = ValueNotifier(false);
  final ValueNotifier<int> wakePulse = ValueNotifier(0);
  Timer? _wakeTimer;

  void _flagWake() {
    wakePulse.value = DateTime.now().millisecondsSinceEpoch;
    wakeActive.value = true;
    _wakeTimer?.cancel();
    _wakeTimer = Timer(const Duration(milliseconds: 2500), () {
      wakeActive.value = false;
    });
  }

  // Command-capture window after a bare wake word ("EVS" with nothing after
  // it): the next final utterance is the command. Auto-expires back to
  // listening if the user stays silent.
  Timer? _armTimer;

  void _arm() {
    state.value = VaState.armed;
    _armTimer?.cancel();
    _armTimer = Timer(const Duration(seconds: 8), () {
      if (state.value == VaState.armed) {
        state.value = _listening ? VaState.listening : VaState.idle;
      }
    });
  }

  void _disarm() {
    _armTimer?.cancel();
    _armTimer = null;
  }

  bool get isListening => _listening;

  void attach(AppState app) {
    _app = app;
    if (_attached) return;
    _attached = true;
    app.addListener(_sync);
    SidecarClient.instance.status.addListener(_sync);
    SidecarClient.instance.finalText.listen(_onFinal);
    _sync();
  }

  void _toast(String msg) {
    final ctx = rootNavKey.currentContext;
    if (ctx != null) showAppSnackBar(ctx, msg);
  }

  // Cyrillic → Latin so a Latin wake word ("EVS") still matches when Whisper
  // transcribes Russian speech in Cyrillic ("евс", "ивэс", …).
  static const Map<String, String> _translitMap = {
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e',
    'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'i', 'к': 'k', 'л': 'l', 'м': 'm',
    'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
    'ф': 'f', 'х': 'h', 'ц': 'c', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch',
    'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'u', 'я': 'ya',
  };

  String _translit(String s) {
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      b.write(_translitMap[ch] ?? ch);
    }
    return b.toString();
  }

  // Whether we've already sent `stt.start` to the CURRENT sidecar connection.
  // Reset whenever the sidecar drops or we stop listening, so a freshly
  // (re)connected sidecar always gets a new stt.start — otherwise the
  // assistant goes deaf after the sidecar restarts (e.g. an update-relaunch),
  // because `_listening` stays true and the old code only started STT on the
  // false→true edge.
  bool _sttStartedForSession = false;

  // Start/stop continuous listening based on settings + sidecar availability.
  void _sync() {
    final app = _app;
    if (app == null) return;
    final connected =
        SidecarClient.instance.status.value == SidecarStatus.connected;
    if (!connected) _sttStartedForSession = false; // next connect must restart
    // Only the wake-word mode listens continuously; 'separate'/'first' are
    // button-triggered, so the app doesn't capture audio non-stop by surprise.
    final want =
        connected && app.sttEngine == 'whisper' && app.cmdMode == 'wakeword';
    if (want) {
      if (!_listening) {
        _listening = true;
        if (state.value == VaState.idle) state.value = VaState.listening;
      }
      // (Re)issue stt.start once per sidecar connection. A newly (re)connected
      // sidecar has no memory of a previous STT session, so this is what keeps
      // the mic alive across sidecar restarts.
      if (!_sttStartedForSession) {
        _sttStartedForSession = true;
        SidecarClient.instance
            .sttStart(app.effectiveSttLanguage, prompt: app.sttBiasPrompt);
      }
    } else if (_listening) {
      _listening = false;
      _sttStartedForSession = false;
      _disarm();
      SidecarClient.instance.sttStop();
      state.value = VaState.idle;
    }
  }

  // Re-issue stt.start without an app restart — e.g. the active mic set changed
  // (TZ2 block 8) so the sidecar must reopen capture with the new devices.
  void restartListening() {
    if (!_listening) return;
    SidecarClient.instance.sttStop();
    _sttStartedForSession = false;
    _sync();
  }

  Future<void> _onFinal(String text) async {
    final app = _app;
    if (app == null || !_listening) return;
    final raw = text.trim();
    if (raw.isEmpty) return;

    // Voice "stop" — checked BEFORE the busy guard so it interrupts an
    // in-progress reply/speech (with or without the wake word: "Ирис стоп" /
    // "хватит").
    if (_isStopPhrase(raw, app.wakeWord)) {
      _stopEverything(app);
      return;
    }
    if (_busy) return;
    // Surface what was heard so the user can confirm recognition works. Not
    // shown on the pill anymore (only the status is), kept for potential logs.
    lastHeard.value = raw;

    String? command;
    if (app.cmdMode == 'wakeword') {
      if (state.value == VaState.armed) {
        // Wake word already heard on its own — this whole utterance is the
        // command.
        _disarm();
        command = raw;
      } else {
        command = _stripWakeWord(raw, app.wakeWord);
        if (command == null) return; // wake word not heard — ignore
        _flagWake(); // visible "heard you!" pulse in the pill + visualizers
        command = command.trim();
        if (command.isEmpty) {
          // Bare wake word: arm command capture — the next phrase is the
          // command (visualized as "say the command…" on the badge/pill).
          _arm();
          return;
        }
      }
    } else if (app.cmdMode == 'first') {
      command = raw;
    } else {
      return;
    }
    command = command.trim();
    if (command.isEmpty) return;

    _busy = true;
    _stopFlag = false;
    try {
      await _handle(app, command);
    } catch (e) {
      unawaited(appendLog('errors', 'VoiceAssistant._handle: $e'));
    } finally {
      _busy = false;
      if (_listening) state.value = VaState.listening;
    }
  }

  // Stop-command detection: interrupts speech + generation. Matched on the
  // first 1-2 tokens after an optional wake word, against the user-editable
  // AppState.stopWords vocabulary.
  bool _isStopPhrase(String text, String wake) {
    final words = _app?.stopWords ?? AppState.kDefaultStopWords;
    if (words.isEmpty) return false;
    // Allow an optional leading wake word ("Ирис, стоп"). If the wake word is
    // present, use the remainder; otherwise test the phrase as-is.
    final stripped = _stripWakeWord(text, wake);
    final body = (stripped != null && stripped.trim().isNotEmpty)
        ? stripped
        : text;
    final tokens = body.toLowerCase().split(RegExp(r'[\s,.:;!?]+'))
      ..removeWhere((t) => t.isEmpty);
    if (tokens.isEmpty) return false;
    for (final t in tokens.take(2)) {
      for (final w in words) {
        if (w.isEmpty) continue;
        if (t == w || t.startsWith(w) || _ratio(t, w) >= 0.85) return true;
      }
    }
    return false;
  }

  // Interrupt everything the assistant is doing: cut off TTS (both engines),
  // cancel any in-flight generation, and flag so a pending reply isn't spoken.
  void _stopEverything(AppState app) {
    _stopFlag = true;
    try {
      SidecarClient.instance.stopSpeaking();
    } catch (_) {}
    app.cancelGeneration();
    _disarm();
    _toast(app.t('vaStopped'));
    VizOverlayServer.instance.note(app.t('vaStopped'), kind: 'info');
    unawaited(appendLog('commands', 'STOP (voice)'));
    if (_listening && !_busy) state.value = VaState.listening;
  }

  // Strip a leading wake word; returns the remaining command, or null if the
  // utterance doesn't start with the wake word (fuzzy on the first token).
  String? _stripWakeWord(String text, String wake) {
    final w = _translit(wake.trim());
    if (w.isEmpty) return text;
    final lower = text.toLowerCase();
    final tokens = lower.split(RegExp(r'[\s,.:;!?]+'))
      ..removeWhere((t) => t.isEmpty);
    if (tokens.isEmpty) return null;

    // Whisper often renders a short acronym as 1-3 tokens ("евс" / "и в эс"),
    // sometimes in Cyrillic. Try transliterated matches over the first few
    // tokens, keeping the leftover as the command.
    for (var take = 1; take <= 3 && take <= tokens.length; take++) {
      final headTokens = tokens.take(take).toList();
      final head = _translit(headTokens.join());
      final ratio = _ratio(head, w);
      // Lenient: acronyms are hard; accept a decent transliterated match, or a
      // prefix/containment.
      if (head == w ||
          ratio >= 0.5 ||
          (w.length >= 2 && (head.startsWith(w) || w.startsWith(head)))) {
        // Drop the first `take` tokens from the original text.
        var rest = text;
        for (final t in headTokens) {
          final idx = rest.toLowerCase().indexOf(t);
          if (idx >= 0) rest = rest.substring(idx + t.length);
        }
        return rest.replaceFirst(RegExp(r'^[\s,.:;!?]+'), '');
      }
    }
    return null;
  }

  // Message routing (user spec): COMMANDS are executed silently — they must
  // NEVER appear in the chat history. Only plain speech becomes a chat turn.
  Future<void> _handle(AppState app, String command) async {
    state.value = VaState.thinking;
    // 1) The user's command catalog (fuzzy match) — the ONLY thing that runs a
    //    command. No built-in/auto-interpreted launches: if the user didn't add
    //    it, it's not a command.
    final (match, score) = _matchCommand(app, command);
    if (match != null) {
      await _runCommand(app, match, utterance: command);
      return;
    }
    // No command matched. In commands-only mode (chat disabled) tell the user
    // instead of falling back to a chat turn.
    if (!app.chatEnabled) {
      unawaited(appendLog(
          'commands',
          'NO MATCH (chat off): "${_norm(command)}" '
              'best=${score.toStringAsFixed(2)}/${app.cmdThreshold}'));
      // Show what was actually heard so a mismatch between the recognized text
      // and the command phrase is obvious.
      _toast('${app.t('vaCmdNotFound')}: «$command»');
      VizOverlayServer.instance
          .note('${app.t('vaCmdNotFound')}: «$command»', kind: 'err');
      if (app.voiceResponses) _speak(app, app.t('vaCmdNotFound'));
      state.value = _listening ? VaState.listening : VaState.idle;
      return;
    }
    // Diagnostic: record why this went to chat (best score vs threshold) so
    // "exact command went to chat" reports can be traced from commands.log.
    unawaited(appendLog(
        'commands',
        'NO MATCH → chat: "${_norm(command)}" '
            'best=${score.toStringAsFixed(2)}/${app.cmdThreshold}'));
    // 2) Everything else is normal speech → a regular (visible) chat turn.
    _toast('${app.t('vaThinking')} $command');
    if (app.voiceResponses) {
      // Queued sidecar TTS: stream the reply and speak each sentence as soon as
      // it arrives — first audio starts almost immediately instead of after the
      // whole reply. A voice "stop" interrupts stream + TTS queue.
      await app.streamReplyForVoice(command, (sentence) {
        if (!_stopFlag) _speak(app, sentence);
      });
    } else {
      await app.sendMessage(command);
    }
  }

  // Execute a catalog/interpreted command with the usual safety policies.
  // [utterance] carries the recognized phrase so parametric commands (app
  // volume) can read their number from it.
  Future<void> _runCommand(AppState app, VoiceCommand cmd,
      {String utterance = ''}) async {
    if (!app.cmdEnabled) {
      _toast(app.t('vaCmdDisabled'));
      VizOverlayServer.instance.note(app.t('vaCmdDisabled'), kind: 'err');
      return;
    }
    final risky = cmd.type == VoiceCommandType.shell ||
        cmd.type == VoiceCommandType.system;
    final needConfirm =
        app.cmdConfirm == 'always' || (app.cmdConfirm == 'risky' && risky);
    if (needConfirm && !await _confirm(app, cmd)) {
      unawaited(appendLog('commands', 'DECLINED: ${cmd.phrase}'));
      return;
    }
    state.value = VaState.running;
    _toast('${app.t('vaRunning')} ${cmd.phrase}');
    VizOverlayServer.instance.note('${app.t('vaRunning')} ${cmd.phrase}');
    // App-volume runs through the sidecar (Core Audio) and speaks its own
    // outcome (set / not-playing / no-number), so it bypasses CommandExecutor.
    if (cmd.type == VoiceCommandType.appVolume) {
      final (ok, say) = await app.applyAppVolume(cmd, utterance);
      if (!ok) _toast(say);
      VizOverlayServer.instance.note(say, kind: ok ? 'ok' : 'err');
      if (app.voiceResponses) _speak(app, say);
      unawaited(appendLog('commands',
          '${cmd.phrase} -> [appVolume] ${cmd.process} : ${ok ? 'OK' : 'FAIL'}'));
      state.value = _listening ? VaState.listening : VaState.idle;
      return;
    }
    final ok = await CommandExecutor.instance.execute(cmd);
    if (!ok) _toast(app.t('vaFailed'));
    VizOverlayServer.instance
        .note(ok ? app.t('vaDone') : app.t('vaFailed'), kind: ok ? 'ok' : 'err');
    if (app.voiceResponses) {
      // A command with its own spoken phrase announces itself (e.g. "Открываю
      // Яндекс Музыку"); otherwise fall back to the generic done/failed line.
      final say = (ok && cmd.speakPhrase.trim().isNotEmpty)
          ? cmd.speakPhrase.trim()
          : (ok ? app.t('vaDone') : app.t('vaFailed'));
      _speak(app, say);
    }
    final micVia = SidecarClient.instance.lastSttDevice;
    unawaited(appendLog(
        'commands',
        '${cmd.phrase} -> [${cmd.type.name}] ${cmd.value} : '
        '${ok ? 'OK' : 'FAIL'}${micVia.isNotEmpty ? ' (mic: $micVia)' : ''}'));
  }

  // Best catalog match for a spoken phrase. Returns the matched command (null
  // if below threshold) AND the best score reached — the score is logged when
  // routing to chat so we can diagnose "exact command went to chat" reports.
  (VoiceCommand?, double) _matchCommand(AppState app, String text) {
    final t = _norm(text);
    final tTokens = t.split(' ').where((e) => e.isNotEmpty).toSet();
    VoiceCommand? best;
    double bestScore = 0;
    for (final c in app.voiceCommands) {
      final phrase = _norm(c.phrase);
      if (phrase.isEmpty) continue;
      double s;
      if (t == phrase) {
        s = 1.0;
      } else if (t.contains(phrase) || phrase.contains(t)) {
        s = 0.9;
      } else {
        s = _ratio(t, phrase);
        // Token-subset: every word of the command phrase is present in the
        // utterance (handles filler words / word order / recognizer noise like
        // "открой мне телегу", "телегу открой").
        final pTokens = phrase.split(' ').where((e) => e.isNotEmpty).toSet();
        if (pTokens.isNotEmpty && pTokens.every(tTokens.contains)) {
          s = math.max(s, 0.95);
        }
      }
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    final matched =
        (best != null && bestScore >= app.cmdThreshold) ? best : null;
    return (matched, bestScore);
  }

  void _speak(AppState app, String text) {
    // Run text through the interpreter (rules/model), then synthesize in the
    // sidecar. Chained so "model" mode's async rewrite keeps sentence order; a
    // stop mid-stream skips whatever is still queued.
    _ttsChain = _ttsChain.then((_) async {
      if (_stopFlag) return;
      final say = await app.interpretForTts(text);
      if (_stopFlag || say.trim().isEmpty) return;
      SidecarClient.instance.speak(say, rate: app.ttsRate, volume: app.ttsVolume);
    }).catchError((_) {});
  }

  Future<bool> _confirm(AppState app, VoiceCommand c) async {
    final ctx = rootNavKey.currentContext;
    if (ctx == null) return app.cmdConfirm == 'never';
    final res = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => _AppDialog(
        title: Text(app.t('vaConfirmTitle')),
        content: Text('${app.t('vaConfirmBody')}\n\n«${c.phrase}» → ${c.value}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(app.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(app.t('run'))),
        ],
      ),
    );
    return res ?? false;
  }

  String _norm(String s) => s
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[^0-9a-zа-яё ]'), '') // drop punctuation
      .replaceAll(RegExp(r'\s+'), ' ');

  // Normalized similarity 0..1 from Levenshtein distance.
  double _ratio(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final d = _levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    return 1.0 - d / maxLen;
  }

  int _levenshtein(String a, String b) {
    final m = a.length, n = b.length;
    var prev = List<int>.generate(n + 1, (i) => i);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = cur[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[n];
  }
}

// On Windows the EVS desktop shell is the root; every other platform keeps
// the existing mobile ChatScreen. Uses defaultTargetPlatform (not dart:io)
// so the shared file still compiles for web.
class _RootHome extends StatelessWidget {
  const _RootHome();
  @override
  Widget build(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.windows
      ? const DesktopHome()
      : const ChatScreen();
}

class DesktopHome extends StatelessWidget {
  const DesktopHome({super.key});
  @override
  Widget build(BuildContext context) {
    // Subscribe the shell to theme changes. Every colour token resolves through
    // `_pal(context)` which uses `context.read` (no subscription), and this
    // widget is `const`, so without an explicit dependency the shell background
    // (_bg / _evsShellBg) was computed once and never repainted when themeMode
    // changed (live theme switch, or the async prefs load right after startup) —
    // leaving a stale dark shell behind the transparent chat area while the
    // sidebar/content (which do watch) followed the theme. Rebuild on themeMode.
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    return Scaffold(
      backgroundColor: _bg(context),
      body: Container(
        decoration: _evsShellBg(context),
        // The sidebar spans the FULL window height (its themed surface reaches
        // the very top), and the window title bar sits only over the main
        // content — so the top of the window reads as two colours (cream rail on
        // the left, the page background on the right) instead of one strip above
        // a shorter sidebar.
        child: const Row(
          children: [
            _DesktopSidebar(),
            Expanded(
              child: Column(
                children: [
                  _WindowTitleBar(),
                  Expanded(child: ChatScreen(desktop: true)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar();

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DesktopSettings()),
    );
  }

  Widget _iconBtn(BuildContext context, IconData icon, VoidCallback onTap,
      {String? tooltip}) {
    final btn = InkResponse(
      radius: 22,
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _overlayFill(context, 0.042),
          border: Border.all(color: _stroke(context)),
        ),
        child: Icon(icon, size: 15, color: _sub(context)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final convs = app.conversations;
    return Container(
      width: 264,
      decoration: _evsRailBg(context),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 16),
              child: Row(
                children: [
                  // The sidebar now reaches the top of the window, so its header
                  // doubles as the drag area (the window title bar sits only over
                  // the main content). Buttons stay outside the drag region.
                  Expanded(
                    child: DragToMoveArea(
                      child: Row(
                        children: [
                          const _EvsLogoMark(),
                          const SizedBox(width: 9),
                          Text(
                            'EVS',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: _txt(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _iconBtn(context, Icons.settings_outlined,
                      () => _openSettings(context),
                      tooltip: app.t('settings')),
                  const SizedBox(width: 8),
                  _iconBtn(context, Icons.add, () {
                    app.buzz();
                    app.newChat();
                  }, tooltip: app.t('newChat')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                'ИСТОРИЯ',
                style: EvsType.sectionLabel
                    .copyWith(letterSpacing: 0.9, color: _sectionLabel(context)),
              ),
            ),
            Expanded(
              child: convs.isEmpty
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      itemCount: convs.length,
                      itemBuilder: (_, i) {
                        final c = convs[i];
                        final active = c.id == app.current?.id;
                        return _historyItem(context, app, c, active);
                      },
                    ),
            ),
            Divider(color: _divider(context), height: 1, indent: 10, endIndent: 10),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 14, 10, 0),
              child: _DesktopSystemWidget(),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 10, 10, 12),
              child: _DesktopMicWidget(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyItem(
      BuildContext context, AppState app, Conversation c, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      // Right-click anywhere on the row → context menu (rename / pin / delete).
      // Desktop uses mouse, so this replaces the old mobile long-press.
      child: GestureDetector(
        onSecondaryTapDown: (d) =>
            showChatContextMenu(context, d.globalPosition, c, app),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              app.buzz();
              app.openChat(c);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: active
                    ? _accent(context).withValues(alpha: 0.10)
                    : Colors.transparent,
                border: Border.all(
                  color: active ? _accent(context).withValues(alpha: 0.2) : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      color: _overlayFill(context, 0.042),
                    ),
                    child: Icon(
                        c.pinned
                            ? Icons.push_pin
                            : Icons.chat_bubble_outline,
                        size: 13,
                        color: _sub(context)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: _txt(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _evsRelTime(app, c.updatedAt),
                          style: TextStyle(fontSize: 11.5, color: _faint(context)),
                        ),
                      ],
                    ),
                  ),
                  // Visible affordance for users who don't try right-click.
                  Builder(
                    builder: (btnCtx) => InkResponse(
                      radius: 16,
                      onTap: () {
                        final box =
                            btnCtx.findRenderObject() as RenderBox?;
                        final pos = box != null
                            ? box.localToGlobal(box.size.center(Offset.zero))
                            : Offset.zero;
                        showChatContextMenu(context, pos, c, app);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.more_vert,
                            size: 16, color: _faint(context)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Shared chat context menu (rename / pin / delete-with-undo), anchored at [pos]
// (global coords). Top-level so both the ConversationsSheet rows AND the
// desktop sidebar history items can use it. Glass mode uses the blurred glass
// menu; standard mode uses showMenu.
Future<void> showChatContextMenu(
    BuildContext ctx, Offset pos, Conversation c, AppState app) async {
  void handle(String? v) {
    if (v == 'rename') promptRenameChat(ctx, c, app);
    if (v == 'pin') app.togglePin(c);
    if (v == 'delete') deleteChatWithUndo(ctx, c, app);
  }

  if (_isGlass(ctx)) {
    final v = await showGlassMenu(
      ctx,
      position: pos,
      items: [
        GlassMenuItem('rename', app.t('rename')),
        GlassMenuItem('pin', c.pinned ? app.t('unpin') : app.t('pin')),
        GlassMenuItem('delete', app.t('delete'), color: Colors.redAccent),
      ],
    );
    handle(v);
    return;
  }
  final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
  final v = await showMenu<String>(
    context: ctx,
    color: _card(ctx),
    position: RelativeRect.fromRect(
      Rect.fromPoints(pos, pos),
      Offset.zero & (overlay?.size ?? const Size(0, 0)),
    ),
    items: [
      PopupMenuItem(
        value: 'rename',
        child: Text(app.t('rename'), style: TextStyle(color: _txt(ctx))),
      ),
      PopupMenuItem(
        value: 'pin',
        child: Text(c.pinned ? app.t('unpin') : app.t('pin'),
            style: TextStyle(color: _txt(ctx))),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Text(app.t('delete'),
            style: const TextStyle(color: Colors.redAccent)),
      ),
    ],
  );
  handle(v);
}

// Delete a chat but offer a few seconds to undo (deletes are otherwise
// irreversible — easy to hit by accident from the context menu).
void deleteChatWithUndo(BuildContext ctx, Conversation c, AppState app) {
  app.deleteChat(c);
  final messenger = ScaffoldMessenger.of(ctx);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: _card(ctx),
    duration: const Duration(seconds: 4),
    content: Text(app.t('chatDeleted'), style: TextStyle(color: _txt(ctx))),
    action: SnackBarAction(
      label: app.t('undo'),
      textColor: _accent(ctx),
      onPressed: () => app.undoDeleteChat(),
    ),
  ));
}

// Rename dialog for a chat. Pre-fills the current title; saving an empty title
// is a no-op (keeps the old one).
void promptRenameChat(BuildContext ctx, Conversation c, AppState app) {
  final ctrl = TextEditingController(text: c.title);
  showDialog(
    context: ctx,
    builder: (dialogContext) => _AppDialog(
      backgroundColor:
          _isGlass(ctx) ? _card(ctx).withValues(alpha: 0.9) : _card(ctx),
      title: Text(app.t('renameChat'), style: TextStyle(color: _txt(ctx))),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: TextStyle(color: _txt(ctx)),
        decoration: InputDecoration(
          hintText: app.t('renameChatHint'),
          hintStyle: TextStyle(color: _sub(ctx)),
        ),
        onSubmitted: (_) {
          app.renameChat(c, ctrl.text);
          Navigator.pop(dialogContext);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(app.t('cancel')),
        ),
        TextButton(
          onPressed: () {
            app.renameChat(c, ctrl.text);
            Navigator.pop(dialogContext);
          },
          child: Text(app.t('save')),
        ),
      ],
    ),
  );
}

// System monitor widget — live CPU/RAM from SystemMonitor (Win32 FFI). VRAM
// has no reliable cross-vendor API, so it stays "—".
class _DesktopSystemWidget extends StatelessWidget {
  const _DesktopSystemWidget();

  String _gb(int bytes, {int digits = 1}) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(digits);

  Widget _bar(BuildContext context, String name, String value, double frac,
      List<Color> grad, Color numColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _sub(context))),
              Text(value,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: numColor)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: _overlayFill(context, 0.1),
              valueColor: AlwaysStoppedAnimation(grad.first),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _overlayFill(context, 0.042),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Text('СИСТЕМА',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: _sub(context))),
          ),
          ValueListenableBuilder<SystemStats>(
            valueListenable: SystemMonitor.instance.stats,
            builder: (_, s, __) {
              final active = s.totalRamBytes > 0;
              final ramTxt = active
                  ? '${_gb(s.usedRamBytes)} / ${_gb(s.totalRamBytes, digits: 0)} GB'
                  : '—';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _bar(context, 'CPU',
                      active ? '${(s.cpu * 100).round()}%' : '—', s.cpu,
                      [_accent(context)], _accent(context)),
                  _bar(context, 'RAM', ramTxt, s.ram,
                      [_info(context)], _info(context)),
                  _bar(context, 'VRAM', '—', 0.0, [_warn(context)],
                      _warn(context)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// Combined live audio level driving every voice visualization: microphone
// input (MicMeter) + TTS playback level (`tts.level` events streamed by the
// sidecars while the assistant speaks). Keeps a short rolling history so the
// bar/ring visualizers show a real moving waveform, not a canned loop.
/// Transient notice shown on the floating widget (command executed/failed …):
/// (text, kind 'ok'|'err'|'info', timestamp-ms). Set by the widget process's
/// WS client on `note` messages; auto-expires in _VaStageBadge.
final ValueNotifier<(String, String, int)?> vizNotice = ValueNotifier(null);

class VoiceLevels {
  VoiceLevels._();
  static final VoiceLevels instance = VoiceLevels._();

  /// Level of the assistant's speech output (0..1) — fed by the sidecars'
  /// tts.level events in the main process, or by the WS mirror in the widget
  /// process. ALL visualizations react to this (never to the microphone).
  final ValueNotifier<double> tts = ValueNotifier(0.0);
}

// Adapter that drives the user-provided WaveField visualizers (wave_field_3d /
// wave_field_flat) with the live combined voice level, so they slot into the
// same vizType switch as the other hero/overlay styles. Background is kept
// transparent by default so the particles float over the app/widget backdrop;
// callers pass reduced particle counts for small thumbnails to stay cheap.
class EvsWaveViz extends StatelessWidget {
  final String kind; // 'wave3d' | 'waveflat'
  final double size;
  final Color background;
  final int? particleCount; // wave_field_flat only
  final int? numCols; // wave_field_3d only
  final int? numRows; // wave_field_3d only
  // Feather the edges to transparent so the field blends into the backdrop
  // instead of showing a hard rectangle (used for the home/background wave).
  final bool fadeEdges;
  // Recolour the field with the assistant state (green wake / violet thinking /
  // amber running / red error …), easing back to the user's accent when idle —
  // the same hook every other visualization already uses. Off for the static
  // picker thumbnails, which keep the original blue ramp.
  final bool reactive;
  const EvsWaveViz({
    super.key,
    required this.kind,
    this.size = 320,
    this.background = Colors.transparent,
    this.particleCount,
    this.numCols,
    this.numRows,
    this.fadeEdges = false,
    this.reactive = false,
  });

  Widget _field(Color? accent, bool onLight) => ValueListenableBuilder<double>(
        valueListenable: VoiceLevels.instance.tts,
        builder: (_, lv, __) {
          if (kind == 'wave3d') {
            return WaveField3D(
              level: lv,
              background: background,
              numCols: numCols ?? 110,
              numRows: numRows ?? 75,
              accent: accent,
              onLight: onLight,
            );
          }
          return WaveFieldFlat(
            level: lv,
            background: background,
            particleCount: particleCount ?? 5000,
            accent: accent,
            onLight: onLight,
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final onLight = _pal(context).brightness == Brightness.light;
    Widget field;
    if (!reactive) {
      field = _field(null, onLight);
    } else {
      final app = context.watch<AppState>();
      field = AnimatedBuilder(
        animation: Listenable.merge([
          VoiceAssistant.instance.state,
          VoiceAssistant.instance.wakeActive,
          VoiceAssistant.instance.wakePulse,
          vizNotice,
        ]),
        builder: (_, __) {
          final target = vizStateAccent(context, app);
          return TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: target),
            duration: const Duration(milliseconds: 320),
            builder: (_, tweened, ___) => _field(tweened ?? target, onLight),
          );
        },
      );
    }
    if (fadeEdges) {
      // Rectangular edge-feather: a symmetric fade on each of the four sides so
      // the widget dissolves into the background instead of ending on a hard
      // square. A radial vignette left the straight edges ~two-thirds opaque
      // (still boxy); stacking a horizontal and a vertical linear fade with
      // dstIn multiplies the alphas into a soft picture-frame on all sides
      // (corners fade the most, which reads naturally).
      const f = 0.16; // fraction of each side that dissolves
      field = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, f, 1 - f, 1.0],
        ).createShader(rect),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0.0, f, 1 - f, 1.0],
          ).createShader(rect),
          child: field,
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipRect(child: field),
    );
  }
}

// ---- Voice-reactive visualizations (home hero variants) ----
// All amplitudes come from VoiceLevels.history (real mic/TTS levels) — only
// the ring's slow rotation is decorative. A wake-word trigger adds a short
// glow burst (VoiceAssistant.wakePulse).

double _wakeGlow(int wakeMs) {
  if (wakeMs == 0) return 0;
  final dt = DateTime.now().millisecondsSinceEpoch - wakeMs;
  if (dt >= 1400) return 0;
  return 1.0 - dt / 1400.0;
}

// Mirrored bar "spectrum": bars are FIXED in place and move ONLY up/down
// (no sideways scrolling — user request). Heights = assistant speech level
// shaped by a center bell + light per-bar shimmer, VU-style attack/decay.
class EvsBarsViz extends StatefulWidget {
  final double width;
  final double height;
  final Color? color; // state/accent tint (blended into the bar gradient)
  const EvsBarsViz(
      {super.key, this.width = 340, this.height = 150, this.color});
  @override
  State<EvsBarsViz> createState() => _EvsBarsVizState();
}

class _EvsBarsVizState extends State<EvsBarsViz>
    with SingleTickerProviderStateMixin {
  static const int _n = 33;
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat()
        ..addListener(_tick);
  final List<double> _cur = List<double>.filled(_n, 0);
  double _t = 0;

  void _tick() {
    _t += 1 / 60;
    final lvl = VoiceLevels.instance.tts.value;
    final glow = _wakeGlow(VoiceAssistant.instance.wakePulse.value);
    const center = (_n - 1) / 2;
    for (var i = 0; i < _n; i++) {
      final d = (i - center).abs() / center;
      final bell = math.cos(d * math.pi / 2);
      final shimmer =
          0.85 + 0.15 * math.sin(_t * (3.1 + (i % 7) * 0.37) + i * 1.7);
      final target =
          (lvl * (0.25 + 0.75 * bell) * shimmer * (1 + glow * 0.6))
              .clamp(0.0, 1.0);
      final k = target > _cur[i] ? 0.45 : 0.14;
      _cur[i] += (target - _cur[i]) * k;
    }
  }

  @override
  void dispose() {
    _c
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.width, widget.height),
        painter: _BarsPainter(_cur,
            tint: widget.color, hair: _overlayFill(context, 0.08), repaint: _c),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> heights;
  final Color? tint;
  final Color hair; // center baseline — theme-aware (was hardcoded white alpha)
  _BarsPainter(this.heights,
      {this.tint, this.hair = const Color(0x0FFFFFFF), required Listenable repaint})
      : super(repaint: repaint);

  static const _c1 = Color(0xFF5068D8);
  static const _c2 = Color(0xFF8855CC);
  static const _c3 = Color(0xFFC060D8);
  static const _c4 = Color(0xFFF0D080);

  @override
  void paint(Canvas canvas, Size size) {
    final n = heights.length;
    final midY = size.height / 2;
    final slot = size.width / n;
    final barW = slot * 0.55;
    canvas.drawLine(
        Offset(0, midY),
        Offset(size.width, midY),
        Paint()
          ..color = hair
          ..strokeWidth = 1);
    for (var i = 0; i < n; i++) {
      final v = heights[i].clamp(0.0, 1.0);
      final h = 2 + v * (size.height / 2 - 4);
      final x = slot * i + slot / 2;
      var color = v < 0.35
          ? Color.lerp(_c1, _c2, v / 0.35)!
          : v < 0.7
              ? Color.lerp(_c2, _c3, (v - 0.35) / 0.35)!
              : Color.lerp(_c3, _c4, (v - 0.7) / 0.3)!;
      if (tint != null) color = Color.lerp(color, tint!, 0.6)!;
      canvas.drawLine(
          Offset(x, midY - h),
          Offset(x, midY + h),
          Paint()
            ..color = color.withValues(alpha: 0.55 + 0.45 * v)
            ..strokeWidth = barW
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => true;
}

// Circular ring with radial spikes. Spikes sit at FIXED angles and only
// extend/retract with the assistant speech level (no rotation/circular
// travel — user request); the color sweep still slowly cycles for life.
class EvsRingViz extends StatefulWidget {
  final double size;
  final Color? color; // state/accent tint (blended into the sweep)
  const EvsRingViz({super.key, this.size = 230, this.color});
  @override
  State<EvsRingViz> createState() => _EvsRingVizState();
}

class _EvsRingVizState extends State<EvsRingViz>
    with SingleTickerProviderStateMixin {
  static const int _spikes = 90;
  late final AnimationController _rot =
      AnimationController(vsync: this, duration: const Duration(seconds: 24))
        ..repeat()
        ..addListener(_tick);
  final List<double> _cur = List<double>.filled(_spikes, 0);
  double _t = 0;

  void _tick() {
    _t += 1 / 60;
    final lvl = VoiceLevels.instance.tts.value;
    final glow = _wakeGlow(VoiceAssistant.instance.wakePulse.value);
    for (var i = 0; i < _spikes; i++) {
      final shimmer =
          0.8 + 0.2 * math.sin(_t * (2.7 + (i % 9) * 0.53) + i * 2.39);
      final target = (lvl * shimmer * (1 + glow * 0.8)).clamp(0.0, 1.0);
      final k = target > _cur[i] ? 0.45 : 0.14;
      _cur[i] += (target - _cur[i]) * k;
    }
  }

  @override
  void dispose() {
    _rot
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _rot,
        builder: (_, __) => CustomPaint(
          size: Size.square(widget.size),
          painter: _RingPainter(
            _cur,
            _rot.value,
            VoiceAssistant.instance.wakePulse.value,
            widget.color,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final List<double> lens; // per-spike smoothed levels, fixed angles
  final double phase; // 0..1 — rotates ONLY the color sweep, not the spikes
  final int wakeMs;
  final Color? tint;
  _RingPainter(this.lens, this.phase, this.wakeMs, this.tint);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.30;
    final maxSpike = size.width * 0.17;
    final glow = _wakeGlow(wakeMs);
    var sweepColors = const [
      Color(0xFF5068D8),
      Color(0xFF8855CC),
      Color(0xFFC060D8),
      Color(0xFF54E0B0),
      Color(0xFF5068D8),
    ];
    if (tint != null) {
      sweepColors =
          sweepColors.map((c) => Color.lerp(c, tint!, 0.55)!).toList();
    }
    final sweep = SweepGradient(
      colors: sweepColors,
      transform: GradientRotation(phase * 2 * math.pi),
    ).createShader(Rect.fromCircle(center: c, radius: r + maxSpike));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + glow * 2
          ..shader = sweep);
    if (glow > 0) {
      canvas.drawCircle(
          c,
          r + glow * 10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10 * glow
            ..shader = sweep
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    }
    final n = lens.length;
    for (var i = 0; i < n; i++) {
      final ang = (i / n) * 2 * math.pi;
      final v = lens[i].clamp(0.0, 1.0);
      final len = 2 + v * maxSpike;
      final dir = Offset(math.cos(ang), math.sin(ang));
      canvas.drawLine(
          c + dir * (r + 2),
          c + dir * (r + 2 + len),
          Paint()
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..shader = sweep
            ..color = Colors.white.withValues(alpha: 0.5 + v * 0.5));
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => true;
}

// ---- Live wrappers for the new widget styles (Siri Orb / LK bars) ----

/// Generates the three orb blob colors from a single accent (HSL shifts) —
/// same recipe as the user-provided widgets settings mock.
SiriOrbColors evsOrbColors(Color accent, {bool onLight = false}) {
  final h = HSLColor.fromColor(accent);
  Color shift(double deg, double satMul, double lightMul) => h
      .withHue((h.hue + deg) % 360)
      .withSaturation((h.saturation * satMul).clamp(0.0, 1.0))
      .withLightness((h.lightness * lightMul).clamp(0.0, 1.0))
      .toColor();
  return SiriOrbColors(
    // Dark orb base on dark themes; a light neutral on the light themes so the
    // orb doesn't read as a dark blob on cream/white.
    bg: onLight ? const Color(0xFFECECF1) : const Color(0xFF0A0A12),
    c1: accent,
    c2: shift(42, 1.0, 1.05),
    c3: shift(-52, 0.95, 1.0),
  );
}

/// Siri Orb / LK bars fed with the REAL combined voice level and the live
/// assistant state: speaking while TTS audio plays, thinking while the LLM
/// works, listening while the mic streams, idle otherwise.
// State-reactive accent for the voice visualizations: the widget/orb changes
// color to signal what the assistant is doing (heard the wake word → green,
// thinking → violet, running → amber, command ok/err → green/red), then returns
// to the user's accent when idle. Replaces the old text badges. Reads the
// (WS-mirrored) VoiceAssistant notifiers + vizNotice, so it works in both the
// main app and the widget process.
// Default visualization accent (violet). When vizAccent still equals this, the
// visualization follows the theme accent; any other value is a user override.
const int kDefaultVizAccent = 0xFFCC785C;

Color vizStateAccent(BuildContext c, AppState app) {
  // Idle/base colour follows the theme accent by default (so the visualization
  // matches Claude terracotta / Apple blue / … ); if the user picked a custom
  // swatch in the Widgets settings (vizAccent changed from the default), honour
  // that override instead.
  final base =
      app.vizAccent == kDefaultVizAccent ? _accent(c) : Color(app.vizAccent);
  final notice = vizNotice.value;
  if (notice != null && notice.$1.isNotEmpty) {
    switch (notice.$2) {
      case 'ok':
        return _success(c);
      case 'err':
        return _danger(c);
      default:
        return base;
    }
  }
  if (VoiceAssistant.instance.wakeActive.value) return _success(c);
  switch (VoiceAssistant.instance.state.value) {
    case VaState.armed:
      return _info(c);
    case VaState.thinking:
      return Color.lerp(_accent(c), _success(c), 0.45)!;
    case VaState.running:
      return _warn(c);
    default:
      return base; // idle / listening / speaking → the user's accent
  }
}

class EvsLiveViz extends StatelessWidget {
  final String kind; // 'orb' | 'lkbars'
  final double maxSize;
  const EvsLiveViz({super.key, required this.kind, required this.maxSize});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return AnimatedBuilder(
      animation: Listenable.merge([
        VoiceLevels.instance.tts,
        VoiceAssistant.instance.state,
        VoiceAssistant.instance.wakeActive,
        VoiceAssistant.instance.wakePulse,
        vizNotice,
      ]),
      builder: (_, __) {
        // Visualizations react ONLY to the assistant's speech output — the
        // microphone never moves them (user decision; the sidebar mic widget
        // is the mic monitor).
        final lv = VoiceLevels.instance.tts.value;
        final va = VoiceAssistant.instance.state.value;
        final speaking = VoiceLevels.instance.tts.value > 0.001;
        final thinking = !speaking &&
            (va == VaState.thinking || va == VaState.running ||
                app.isGenerating);
        final listening = !speaking &&
            !thinking &&
            (va == VaState.listening || MicMeter.instance.active);
        // Colour by assistant state (green wake / violet think / amber run …),
        // smoothly fading back to the user's accent when idle.
        final target = vizStateAccent(context, app);
        return TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: target),
          duration: const Duration(milliseconds: 320),
          builder: (context, tweened, __) {
            final accent = tweened ?? target;
            if (kind == 'lkbars') {
              final st = speaking
                  ? LkVisualizerState.speaking
                  : thinking
                      ? LkVisualizerState.thinking
                      : listening
                          ? LkVisualizerState.listening
                          : LkVisualizerState.idle;
              final barW = maxSize / (app.barCount * 1.7);
              return LkBarVisualizer(
                level: lv,
                state: st,
                count: app.barCount,
                color: accent,
                barWidth: barW,
                spacing: barW * 0.7,
                minHeight: barW,
                maxHeight: maxSize * 0.55,
              );
            }
            final st = speaking
                ? SiriOrbState.speaking
                : thinking
                    ? SiriOrbState.thinking
                    : listening
                        ? SiriOrbState.listening
                        : SiriOrbState.idle;
            return SiriOrb(
              size: math.min(app.orbSize, maxSize),
              level: lv,
              state: st,
              colors: evsOrbColors(accent,
                  onLight: _pal(context).brightness == Brightness.light),
              animationDuration: app.orbSpeed,
            );
          },
        );
      },
    );
  }
}

// ---- Floating overlay-widget view ----
// The root UI of the WIDGET PROCESS (VizOverlayApp): a small transparent
// always-on-top window floating directly on the desktop, independent of the
// chat window. Drag anywhere to move it; double-click (or the hover button)
// asks the main process to open the chat.
class OverlayWidgetView extends StatefulWidget {
  final VoidCallback onOpen;
  final VoidCallback onHide;
  const OverlayWidgetView(
      {super.key, required this.onOpen, required this.onHide});
  @override
  State<OverlayWidgetView> createState() => _OverlayWidgetViewState();
}

class _OverlayWidgetViewState extends State<OverlayWidgetView> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final viz = app.vizType;
    return Material(
      type: MaterialType.transparency,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startDragging(),
          onDoubleTap: widget.onOpen,
          child: LayoutBuilder(builder: (context, box) {
            final s = box.biggest.shortestSide;
            // The window is kWidgetWindowScale× larger than the visualization
            // so there's transparent margin around it; size the backdrop and
            // viz by `content` (the inner box) so the widgets keep their size.
            final content = s / kWidgetWindowScale;
            final pad = (s - content) / 2;
            // Recompute the state colour when the assistant state changes and
            // tween it, so all styles (bars/waves/sphere) react by colour —
            // no more text badges.
            return AnimatedBuilder(
              animation: Listenable.merge([
                VoiceAssistant.instance.state,
                VoiceAssistant.instance.wakeActive,
                VoiceAssistant.instance.wakePulse,
                vizNotice,
              ]),
              builder: (context, __) {
                final targetColor = vizStateAccent(context, app);
                return TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: targetColor),
                  duration: const Duration(milliseconds: 320),
                  builder: (context, tweened, __) {
                    final accent = tweened ?? targetColor;
                    return Stack(alignment: Alignment.center, children: [
                      // Soft dark backdrop, fading to transparent at its edge.
                      Container(
                        width: content,
                        height: content,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [
                            Color(0x59000000),
                            Color(0x33000000),
                            Color(0x00000000),
                          ], stops: [
                            0.0,
                            0.62,
                            1.0,
                          ]),
                        ),
                      ),
                      if (viz == 'bars')
                        EvsBarsViz(
                            width: content * 0.86,
                            height: content * 0.46,
                            color: accent)
                      else if (viz == 'waves')
                        EvsRingViz(size: content * 0.86, color: accent)
                      else if (viz == 'orb')
                        EvsLiveViz(kind: 'orb', maxSize: content * 0.72)
                      else if (viz == 'lkbars')
                        EvsLiveViz(kind: 'lkbars', maxSize: content * 0.8)
                      else if (viz == 'wave3d')
                        EvsWaveViz(
                            kind: 'wave3d',
                            size: content * 0.92,
                            fadeEdges: true,
                            reactive: true)
                      else if (viz == 'waveflat')
                        EvsWaveViz(
                            kind: 'waveflat',
                            size: content * 0.92,
                            fadeEdges: true,
                            reactive: true)
                      else
                        ParticleSphere(
                          size: content * 0.62,
                          color: accent,
                          scattered: false,
                          soundLevel: VoiceLevels.instance.tts,
                        ),
                      // Hover controls: open the full window / hide the widget.
                      Positioned(
                        top: pad + 6,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: _hover ? 1 : 0,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            _ovlBtn(Icons.open_in_full, app.t('ovlOpenChat'),
                                widget.onOpen),
                            const SizedBox(width: 6),
                            _ovlBtn(Icons.close, app.t('ovlHide'), widget.onHide),
                          ]),
                        ),
                      ),
                    ]);
                  },
                );
              },
            );
          }),
        ),
      ),
    );
  }

  // NB: no Tooltip here — OverlayWidgetView lives OUTSIDE the Navigator (see
  // MiraiApp.builder), so there is no Overlay ancestor for tooltips to mount
  // into (they'd throw "No Overlay widget found" on hover).
  Widget _ovlBtn(IconData icon, String tip, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xCC1C1D2A),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Icon(icon, size: 15, color: Colors.white70),
      ),
    );
  }
}

// Live microphone amplitude meter: streams raw PCM via `record` and turns it
// into a smoothed 0..1 level (RMS). If streaming is unavailable on this
// platform/device, `active` stays false and the widget falls back to a
// decorative animation.
class MicMeter {
  MicMeter._();
  static final MicMeter instance = MicMeter._();

  final AudioRecorder _rec = AudioRecorder();
  final ValueNotifier<double> level = ValueNotifier(0.0);
  StreamSubscription<Uint8List>? _sub;
  bool active = false;
  String _deviceId = '';
  String currentLabel = ''; // label of the selected mic ('' = default)
  bool _starting = false;

  // Start (or restart, if the selected device changed) the live meter on the
  // given input device ('' = system default). Idempotent for the same device.
  Future<void> start({String deviceId = '', bool retry = true}) async {
    if (_starting) return;
    if (active && deviceId == _deviceId) return;
    _starting = true;
    try {
      await _stopStream();
      _deviceId = deviceId;
      // hasPermission() is unreliable on Windows desktop (no per-app prompt);
      // call it to nudge any permission flow but don't gate on it — just try
      // to open the stream and fall back gracefully if it throws.
      try {
        await _rec.hasPermission();
      } catch (_) {}
      InputDevice? device;
      if (deviceId.isNotEmpty) {
        for (final d in await listDevices()) {
          if (d.id == deviceId) {
            device = d;
            break;
          }
        }
      }
      // Human-readable name of the selected mic — the Python sidecar matches
      // its PortAudio input by (a prefix of) this label (stt.start device).
      currentLabel = device?.label ?? '';
      final stream = await _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        device: device,
      ));
      active = true;
      _sub = stream.listen(_onData, onError: (_) {});
    } catch (_) {
      active = false;
    } finally {
      _starting = false;
    }
    // One delayed retry if the first attempt didn't produce a live stream
    // (e.g. the device was briefly busy at launch).
    if (!active && retry) {
      Future.delayed(const Duration(milliseconds: 1200),
          () => start(deviceId: deviceId, retry: false));
    }
  }

  Future<List<InputDevice>> listDevices() async {
    try {
      return await _rec.listInputDevices();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _stopStream() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    active = false;
  }

  void _onData(Uint8List bytes) {
    final count = bytes.lengthInBytes ~/ 2;
    if (count == 0) return;
    final bd = ByteData.sublistView(bytes);
    double sum = 0;
    for (int i = 0; i < count; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final rms = math.sqrt(sum / count);
    // Speech RMS is small (~0.01..0.2); boost then clamp, and smooth so the
    // bars glide rather than flicker.
    final norm = (rms * 8).clamp(0.0, 1.0);
    level.value = level.value + (norm - level.value) * 0.5;
  }
}

// Microphone widget: a live equalizer driven by MicMeter (reacts to the mic),
// with a decorative animated fallback when no live level is available.
class _DesktopMicWidget extends StatefulWidget {
  const _DesktopMicWidget();
  @override
  State<_DesktopMicWidget> createState() => _DesktopMicWidgetState();
}

class _DesktopMicWidgetState extends State<_DesktopMicWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();
  static const _n = 22;
  // Scrolling history of recent levels → a real moving waveform. Must be
  // growable: the tick does removeAt(0)+add, which throws on a fixed-length
  // list (that's why the waveform used to sit frozen).
  final List<double> _hist = List<double>.filled(_n, 0.0, growable: true);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    MicMeter.instance
        .start(deviceId: context.read<AppState>().inputDeviceId)
        .then((_) {
      if (!mounted) return;
      setState(() {});
    });
    _tick = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted) return;
      setState(() {
        _hist.removeAt(0);
        // Pure microphone level — this widget is the mic monitor (the
        // visualizations elsewhere react to the assistant's speech instead).
        _hist.add(MicMeter.instance.level.value);
      });
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final live = MicMeter.instance.active;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _overlayFill(context, 0.042),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(Icons.mic_none, size: 13, color: _sub(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(app.t('microphone'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _sectionLabel(context))),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: _success(context).withValues(alpha: 0.12),
                    border: Border.all(
                        color: _success(context).withValues(alpha: 0.28)),
                  ),
                  child: Text(live ? app.t('micListening') : app.t('ready'),
                      maxLines: 1,
                      style: EvsType.caption.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _success(context))),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 28,
            child: live
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (int i = 0; i < _n; i++) ...[
                        Expanded(child: _bar(3 + _hist[i].clamp(0.0, 1.0) * 25)),
                        if (i < _n - 1) const SizedBox(width: 2.5),
                      ],
                    ],
                  )
                : AnimatedBuilder(
                    animation: _c,
                    builder: (_, __) {
                      final t = _c.value * 2 * math.pi * 3;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (int i = 0; i < _n; i++) ...[
                            Expanded(
                                child: _bar(
                                    6 + ((math.sin(t + i * 0.5) + 1) / 2) * 22)),
                            if (i < _n - 1) const SizedBox(width: 2.5),
                          ],
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _bar(double height) => Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: _accentGradientOf(context),
          ),
        ),
      );
}

/* ----------------------- EVS DESKTOP SETTINGS ----------------------------
   Left-nav settings with 7 sections (evs_s1..s7.html). Controls bind to the
   existing AppState/Personalization; genuinely-new areas are shown as UI with
   stub state until their native phase lands. */

// A user-defined voice command (Voice Commands catalog). Execution comes in
// the native phase; the type maps to how `value` is interpreted.
// A phone authorized to send remote commands (TZ §14). The token is a secret —
// shown masked in the UI, matched verbatim by the server. lastSeen is ISO-8601
// or '' if never seen.
class RemoteDevice {
  final String id;
  String name;
  final String token;
  bool permVoice;
  bool permText;
  bool enabled;
  String lastSeen;
  RemoteDevice({
    required this.id,
    required this.name,
    required this.token,
    this.permVoice = true,
    this.permText = true,
    this.enabled = true,
    this.lastSeen = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'token': token,
        'voice': permVoice,
        'text': permText,
        'enabled': enabled,
        'last_seen': lastSeen,
      };

  factory RemoteDevice.fromJson(Map<String, dynamic> j) => RemoteDevice(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        token: j['token'] as String? ?? '',
        permVoice: j['voice'] as bool? ?? true,
        permText: j['text'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        lastSeen: j['last_seen'] as String? ?? '',
      );
}

// Local HTTP listener that accepts remote commands from paired phones over
// Tailscale/LAN (TZ §14). Bound to all local interfaces (not port-forwarded to
// the internet — that's the user's router). Auth is a per-device bearer token
// issued during pairing; a short-lived one-time code gates pairing itself.
//
// Endpoints:
//   GET  /               -> {ok:true, name:"EVS"}                (discovery)
//   POST /pair    {code, name?}                 -> {device_id, token}
//   POST /command/text  (Bearer) {text}         -> {reply}
//   POST /command/voice (Bearer) audio/* body   -> {text, reply}
//        (WAV or raw 16 kHz mono PCM16; or JSON {audio:<base64>, format})
class RemoteInputServer {
  RemoteInputServer._();
  static final RemoteInputServer instance = RemoteInputServer._();

  io.HttpServer? _server;
  AppState? _app;
  String? _pairCode;
  DateTime? _pairExpires;
  final _rnd = math.Random.secure();

  bool get running => _server != null;

  Future<void> start(AppState app) async {
    _app = app;
    await stop();
    try {
      _server = await io.HttpServer.bind(
          io.InternetAddress.anyIPv4, app.remoteInputPort, shared: true);
      _server!.listen(_handle, onError: (_) {});
      unawaited(appendLog('remote', 'listening on :${app.remoteInputPort}'));
    } catch (e) {
      _server = null;
      unawaited(
          appendLog('remote', 'bind failed on :${app.remoteInputPort}: $e'));
      VizOverlayServer.instance.note(app.t('remotePortBusy'), kind: 'err');
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  // Fresh one-time pairing code with a 5-minute TTL (§14.2).
  String newPairCode() {
    final a = (1000 + _rnd.nextInt(9000)).toString();
    final b = (10 + _rnd.nextInt(90)).toString();
    _pairCode = '$a-$b';
    _pairExpires = DateTime.now().add(const Duration(minutes: 5));
    return _pairCode!;
  }

  String? get activePairCode =>
      (_pairExpires != null && DateTime.now().isBefore(_pairExpires!))
          ? _pairCode
          : null;

  String _newToken() {
    final b = List<int>.generate(24, (_) => _rnd.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }

  Future<Map<String, dynamic>> _readJson(io.HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    if (body.trim().isEmpty) return {};
    final d = jsonDecode(body);
    return d is Map ? d.cast<String, dynamic>() : {};
  }

  Future<List<int>> _readBytes(io.HttpRequest req) async {
    final chunks = <int>[];
    await for (final c in req) {
      chunks.addAll(c);
    }
    return chunks;
  }

  void _send(io.HttpRequest req, Map<String, dynamic> body, {int status = 200}) {
    req.response
      ..statusCode = status
      ..headers.contentType = io.ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }

  String? _bearer(io.HttpRequest req) {
    final h = req.headers.value('authorization') ?? '';
    return h.toLowerCase().startsWith('bearer ') ? h.substring(7).trim() : null;
  }

  Future<void> _handle(io.HttpRequest req) async {
    final app = _app;
    if (app == null) {
      _send(req, {'error': 'not_ready'}, status: 503);
      return;
    }
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/') {
        _send(req, {'ok': true, 'name': 'EVS'});
        return;
      }
      if (req.method == 'POST' && path == '/pair') {
        final body = await _readJson(req);
        final code = (body['code'] ?? '').toString().trim();
        if (activePairCode == null || code != activePairCode) {
          _send(req, {'error': 'invalid_code'}, status: 401);
          return;
        }
        _pairCode = null; // one-time
        final dev = RemoteDevice(
          id: 'd${_rnd.nextInt(1 << 32)}',
          name: (body['name'] ?? 'Телефон').toString().trim(),
          token: _newToken(),
        );
        app.addRemoteDevice(dev);
        _send(req, {'device_id': dev.id, 'token': dev.token});
        return;
      }
      // Authorized endpoints.
      final dev = app.remoteDeviceByToken(_bearer(req) ?? '');
      if (dev == null || !dev.enabled) {
        _send(req, {'error': 'unauthorized'}, status: 401);
        return;
      }
      app.touchRemoteDevice(dev);
      if (req.method == 'POST' && path == '/command/text') {
        if (!dev.permText) {
          _send(req, {'error': 'forbidden'}, status: 403);
          return;
        }
        final body = await _readJson(req);
        final text = (body['text'] ?? '').toString().trim();
        if (text.isEmpty) {
          _send(req, {'error': 'empty'}, status: 400);
          return;
        }
        final reply = await app.runRemoteCommand(text);
        // Speak on the desktop unless the phone asked for text only (§14.5).
        if (app.remoteResponseTarget != 'phone_text') {
          final say = await app.interpretForTts(reply);
          SidecarClient.instance.speak(say,
              rate: app.ttsRate, volume: app.ttsVolume);
        }
        _send(req, {'reply': reply});
        return;
      }
      if (req.method == 'POST' && path == '/command/voice') {
        if (!dev.permVoice) {
          _send(req, {'error': 'forbidden'}, status: 403);
          return;
        }
        // Accept either a raw audio body (Content-Type audio/*, WAV or raw
        // 16 kHz mono PCM16) or a JSON envelope {audio:<base64>, format}. The
        // audio is decoded + recognized by the sidecar, then the resulting
        // text takes the same path as /command/text.
        final ctype = req.headers.contentType?.mimeType ?? '';
        String b64;
        String fmt;
        if (ctype == 'application/json') {
          final j = await _readJson(req);
          b64 = (j['audio'] ?? '').toString();
          fmt = (j['format'] ?? 'wav').toString();
        } else {
          final bytes = await _readBytes(req);
          if (bytes.isEmpty) {
            _send(req, {'error': 'empty'}, status: 400);
            return;
          }
          b64 = base64.encode(bytes);
          // RIFF magic ⇒ WAV; otherwise assume raw 16 kHz mono PCM16.
          fmt = (bytes.length >= 4 &&
                  bytes[0] == 0x52 &&
                  bytes[1] == 0x49 &&
                  bytes[2] == 0x46 &&
                  bytes[3] == 0x46)
              ? 'wav'
              : 'pcm16';
        }
        if (b64.isEmpty) {
          _send(req, {'error': 'empty'}, status: 400);
          return;
        }
        final text =
            await SidecarClient.instance.transcribeAudio(b64, format: fmt);
        if (text.isEmpty) {
          // Nothing recognized (silence, decode failure, or sidecar down).
          _send(req, {'error': 'stt_failed', 'text': '', 'reply': ''},
              status: 422);
          return;
        }
        final reply = await app.runRemoteCommand(text);
        if (app.remoteResponseTarget != 'phone_text') {
          final say = await app.interpretForTts(reply);
          SidecarClient.instance
              .speak(say, rate: app.ttsRate, volume: app.ttsVolume);
        }
        _send(req, {'text': text, 'reply': reply});
        return;
      }
      _send(req, {'error': 'not_found'}, status: 404);
    } catch (e) {
      try {
        _send(req, {'error': 'server_error'}, status: 500);
      } catch (_) {}
    }
  }
}

// Non-loopback IPv4 addresses of this machine, so the UI can show where a phone
// should connect (Tailscale 100.x, LAN 192.168/10.x). Tailscale addresses are
// surfaced first — that's the reliable path across networks.
Future<List<String>> localAddresses() async {
  final out = <String>[];
  try {
    for (final ni
        in await io.NetworkInterface.list(type: io.InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
  } catch (_) {}
  out.sort((a, b) {
    final ta = a.startsWith('100.') ? 0 : 1;
    final tb = b.startsWith('100.') ? 0 : 1;
    return ta != tb ? ta - tb : a.compareTo(b);
  });
  return out;
}

enum VoiceCommandType { app, file, url, shell, system, media, appVolume }

class VoiceCommand {
  String phrase;
  VoiceCommandType type;
  String value;
  // Optional phrase spoken (TTS) when the command runs — e.g. "Открываю Яндекс
  // Музыку". Only spoken when voice responses are enabled. Empty = say the
  // generic "done" line instead.
  String speakPhrase;
  // Parametric fields for VoiceCommandType.appVolume (new-features Ф2). `value`
  // holds the app's display name; `process` the audio-session exe. `phrase` is
  // a template with {N} (e.g. "громкость на {N}"). action is one of
  // set/increase/decrease/mute/unmute. defaultValue applies when the utterance
  // names no number; argMin/argMax bound and clamp it.
  String process;
  String action;
  int? defaultValue;
  int argMin;
  int argMax;
  VoiceCommand({
    required this.phrase,
    required this.type,
    required this.value,
    this.speakPhrase = '',
    this.process = '',
    this.action = 'set',
    this.defaultValue,
    this.argMin = 0,
    this.argMax = 100,
  });

  Map<String, dynamic> toJson() => {
        'phrase': phrase,
        'type': type.name,
        'value': value,
        if (speakPhrase.isNotEmpty) 'speak': speakPhrase,
        if (type == VoiceCommandType.appVolume) ...{
          'process': process,
          'action': action,
          if (defaultValue != null) 'default': defaultValue,
          'min': argMin,
          'max': argMax,
        },
      };

  factory VoiceCommand.fromJson(Map<String, dynamic> j) => VoiceCommand(
        phrase: j['phrase'] as String? ?? '',
        type: VoiceCommandType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => VoiceCommandType.app,
        ),
        value: j['value'] as String? ?? '',
        speakPhrase: j['speak'] as String? ?? '',
        process: j['process'] as String? ?? '',
        action: j['action'] as String? ?? 'set',
        defaultValue: (j['default'] as num?)?.toInt(),
        argMin: (j['min'] as num?)?.toInt() ?? 0,
        argMax: (j['max'] as num?)?.toInt() ?? 100,
      );
}

// One launchable program in the add-command picker.
class ProgramEntry {
  final String name;
  // Command value: a .lnk/.exe path (classic) or "shell:AppsFolder\<AppID>"
  // (Microsoft Store / UWP). CommandExecutor.execute launches both.
  final String value;
  // Key for the icon cache: the .lnk/.exe path, or "uwp:<AppID>".
  final String iconSource;
  const ProgramEntry(this.name, this.value, this.iconSource);
}

// Enumerate installed programs: classic apps from the Start Menu (.lnk, both
// all-users and per-user trees) PLUS Microsoft Store / UWP apps (Get-StartApps,
// AppIDs containing "!"). De-duplicated by name, sorted. CommandExecutor
// resolves .lnk shortcuts and launches UWP via shell:AppsFolder.
Future<List<ProgramEntry>> listInstalledPrograms() async {
  final out = <String, ProgramEntry>{}; // name -> entry (dedupe by name)
  final roots = <String>[];
  final programData = io.Platform.environment['ProgramData'];
  final appData = io.Platform.environment['APPDATA'];
  if (programData != null) {
    roots.add('$programData\\Microsoft\\Windows\\Start Menu\\Programs');
  }
  if (appData != null) {
    roots.add('$appData\\Microsoft\\Windows\\Start Menu\\Programs');
  }
  bool isNoise(String name) {
    final lower = name.toLowerCase();
    return lower.contains('uninstall') ||
        lower.contains('удал') ||
        lower.contains('readme') ||
        lower.contains('license');
  }

  for (final root in roots) {
    final dir = io.Directory(root);
    if (!await dir.exists()) continue;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! io.File) continue;
        final path = e.path;
        if (!path.toLowerCase().endsWith('.lnk')) continue;
        var name = path.split(io.Platform.pathSeparator).last;
        name = name.substring(0, name.length - 4); // drop ".lnk"
        if (isNoise(name)) continue;
        out.putIfAbsent(name, () => ProgramEntry(name, path, path));
      }
    } catch (_) {}
  }

  // Microsoft Store / UWP / PWA apps via Get-StartApps. Include AUMIDs (with
  // "!") AND packaged/PWA entries whose AppID is a bare id (no backslash, not a
  // {GUID}\path, not an auto-generated system entry). The latter catches Store
  // PWAs like Yandex Music (AppID "Yandex", no "!"). Classic {GUID}\path apps
  // are already covered by the .lnk scan, so they're excluded here.
  try {
    final res = await io.Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        // Force UTF-8 output so Cyrillic app names aren't mojibake (PowerShell
        // otherwise writes the OEM codepage, which we'd misdecode).
        '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
            r"Get-StartApps | Where-Object { $_.AppID -like '*!*' -or "
            r"($_.AppID -notlike '*\*' -and $_.AppID -notlike '{*' -and "
            r"$_.AppID -notlike 'Microsoft.AutoGenerated*') } | "
            'Select-Object Name,AppID | ConvertTo-Json -Compress'
      ],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 12));
    if (res.exitCode == 0) {
      // Drop anything (BOM/whitespace) before the JSON starts, then parse.
      var jsonStr = res.stdout as String;
      final start = jsonStr.indexOf(RegExp(r'[\[{]'));
      if (start > 0) jsonStr = jsonStr.substring(start);
      final decoded = jsonDecode(jsonStr.trim());
      final items = decoded is List ? decoded : [decoded];
      for (final it in items) {
        if (it is! Map) continue;
        final name = (it['Name'] ?? '').toString().trim();
        final appId = (it['AppID'] ?? '').toString().trim();
        if (name.isEmpty || appId.isEmpty || isNoise(name)) continue;
        out.putIfAbsent(
            name,
            () => ProgramEntry(
                name, 'shell:AppsFolder\\$appId', 'uwp:$appId'));
      }
    }
  } catch (_) {}

  final list = out.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

// ---- AI voice-command suggestions (new-features Ф1) ----

// One AI-proposed command in the confirmation screen: an app from the real scan
// (its path is authoritative — the model never touches it), a proposed, editable
// phrase, whether it's selected, and whether the phrase collides.
class CmdSuggestion {
  final ProgramEntry program;
  String phrase;
  bool selected;
  bool collides;
  final int usage;
  CmdSuggestion(this.program, this.phrase,
      {this.selected = true, this.collides = false, this.usage = 0});
}

// Windows UserAssist run-counts keyed by normalized app name (leaf without
// .exe/.lnk, lowercased). Best-effort: {} on any failure, and the caller falls
// back to alphabetical order (Ф1 §1.5a / §1.8). Uses PowerShell -EncodedCommand
// (base64 UTF-16LE) so the script needs no shell-quoting.
Future<Map<String, int>> readUsageScores() async {
  if (!io.Platform.isWindows) return {};
  const ps = r'''
$ErrorActionPreference='SilentlyContinue'
function R13($s){ -join ($s.ToCharArray()|%{ $c=[int][char]$_
  if($c-ge65-and$c-le90){[char](65+($c-65+13)%26)}
  elseif($c-ge97-and$c-le122){[char](97+($c-97+13)%26)}else{[char]$c} }) }
$guids='{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}','{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}'
$out=@{}
foreach($g in $guids){
  $k="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\$g\Count"
  if(-not(Test-Path $k)){continue}
  $p=Get-Item $k
  foreach($n in $p.GetValueNames()){
    if([string]::IsNullOrEmpty($n)){continue}
    $d=R13 $n; $data=$p.GetValue($n); $c=0
    if($data -is [byte[]] -and $data.Length -ge 8){$c=[BitConverter]::ToUInt32($data,4)}
    $leaf=($d -split '[\\/]')[-1] -replace '\.(exe|lnk)$',''
    $leaf=$leaf.ToLower().Trim()
    if($leaf){ if(-not $out.ContainsKey($leaf) -or $out[$leaf]-lt $c){$out[$leaf]=$c} }
  }
}
$out.GetEnumerator()|%{ "$($_.Key)`t$($_.Value)" }
''';
  try {
    final units = ps.codeUnits;
    final b = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      b[i * 2] = units[i] & 0xff;
      b[i * 2 + 1] = (units[i] >> 8) & 0xff;
    }
    final r = await io.Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64.encode(b),
    ]).timeout(const Duration(seconds: 12));
    final map = <String, int>{};
    for (final line in (r.stdout as String).split('\n')) {
      final parts = line.trim().split('\t');
      if (parts.length == 2) {
        final n = int.tryParse(parts[1].trim());
        if (n != null) map[parts[0].trim()] = n;
      }
    }
    return map;
  } catch (_) {
    return {};
  }
}

class SuggestionEngine {
  static String normalizeName(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\.(exe|lnk)$'), '').trim();

  // Filter out installers/updaters/uninstallers and EVS itself before anything
  // is shown or sent to the model (§1.8).
  static final RegExp _junk = RegExp(
      r'(uninstall|установка|удал|setup|installer|updater|обновлen|crash|report|helper|redist|vcredist)',
      caseSensitive: false);
  static bool isJunk(ProgramEntry p) {
    final n = p.name.toLowerCase();
    if (n == 'evs' || p.value.toLowerCase().contains('evs.exe')) return true;
    return _junk.hasMatch(n);
  }

  static int scoreFor(ProgramEntry p, Map<String, int> usage) {
    final byName = usage[normalizeName(p.name)];
    if (byName != null) return byName;
    // Fall back to the exe basename of the launch target.
    final v = p.value.toLowerCase();
    final slash = v.lastIndexOf(RegExp(r'[\\/]'));
    final leaf = normalizeName(slash >= 0 ? v.substring(slash + 1) : v);
    return usage[leaf] ?? 0;
  }

  static String fallbackPhrase(String name) {
    var n = name.trim();
    // Drop a trailing version/edition tail so "открой" reads naturally.
    n = n.replaceAll(RegExp(r'\s*\d[\d.]*$'), '').trim();
    return 'открой ${n.toLowerCase()}';
  }

  // Prompt the model to return ONLY JSON {name: [phrases]}. Names only — never
  // paths (§1.3).
  static String buildPrompt(List<String> names) =>
      'Для каждого приложения из списка предложи 1–3 коротких естественных '
      'русских голосовых фразы для его запуска. Фразы должны быть разными и не '
      'пересекаться между приложениями. Ответь ТОЛЬКО валидным JSON, без пояснений '
      'и разметки: {"Google Chrome": ["открой хром", "браузер"]}\n\n'
      'Список приложений: ${jsonEncode(names)}';

  // Defensive parse: tolerate ```-fences and surrounding prose, extract the
  // first {...} block, coerce to {name: [phrases]}. Null on failure.
  static Map<String, List<String>>? parseModelJson(String raw) {
    try {
      var s = raw.trim();
      s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '').replaceAll('```', '');
      final start = s.indexOf('{');
      final end = s.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final decoded = jsonDecode(s.substring(start, end + 1));
      if (decoded is! Map) return null;
      final out = <String, List<String>>{};
      decoded.forEach((k, v) {
        if (v is List) {
          final phrases = v
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (phrases.isNotEmpty) out[k.toString()] = phrases;
        } else if (v is String && v.trim().isNotEmpty) {
          out[k.toString()] = [v.trim()];
        }
      });
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  // Assign a unique phrase per suggestion and flag any that still collide with an
  // existing command or an earlier suggestion (§1.8). Mutates in place.
  static void resolveCollisions(
      List<CmdSuggestion> sugg, List<VoiceCommand> existing) {
    final taken = <String>{
      for (final c in existing) c.phrase.trim().toLowerCase(),
    };
    for (final s in sugg) {
      final p = s.phrase.trim().toLowerCase();
      if (p.isEmpty || taken.contains(p)) {
        s.collides = true;
      } else {
        taken.add(p);
        s.collides = false;
      }
    }
  }
}

// Remote-input settings panel (TZ §14): enable the listener, port, connection
// address + pairing QR, response target, and the paired-device list. Stateful
// for the port field, the async local-address lookup and the transient pairing
// code. Device data lives on AppState, so the surrounding watch() rebuilds this
// when a phone pairs or is edited.
class _RemoteInputPanel extends StatefulWidget {
  const _RemoteInputPanel(this.app);
  final AppState app;
  @override
  State<_RemoteInputPanel> createState() => _RemoteInputPanelState();
}

class _RemoteInputPanelState extends State<_RemoteInputPanel> {
  late final TextEditingController _port =
      TextEditingController(text: widget.app.remoteInputPort.toString());
  List<String> _addrs = [];
  String? _pairCode;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _loadAddrs();
  }

  Future<void> _loadAddrs() async {
    final a = await localAddresses();
    if (mounted) setState(() => _addrs = a);
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  String get _primaryAddr => _addrs.isNotEmpty ? _addrs.first : '127.0.0.1';

  void _newCode() {
    setState(() => _pairCode = RemoteInputServer.instance.newPairCode());
  }

  // Payload the phone app scans: everything it needs to pair in one QR.
  String _qrData() => jsonEncode({
        'host': _primaryAddr,
        'port': app.remoteInputPort,
        if (_pairCode != null) 'code': _pairCode,
      });

  String _deviceStatus(RemoteDevice d) {
    if (d.lastSeen.isEmpty) return app.t('remoteNever');
    final t = DateTime.tryParse(d.lastSeen);
    if (t == null) return app.t('remoteNever');
    final diff = DateTime.now().toUtc().difference(t.toUtc());
    if (diff.inSeconds < 120) return app.t('remoteOnline');
    final mins = diff.inMinutes;
    final human = mins < 60
        ? '$mins м назад'
        : mins < 1440
            ? '${mins ~/ 60} ч назад'
            : '${mins ~/ 1440} дн назад';
    return '${app.t('remoteLastSeen')} $human';
  }

  @override
  Widget build(BuildContext context) {
    final on = app.remoteInputEnabled;
    final running = RemoteInputServer.instance.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        evsRow(context, 
          label: app.t('remoteEnable'),
          desc: app.t('remoteEnableDesc'),
          control: evsToggle(context, on, app.setRemoteInputEnabled),
        ),
        if (on) ...[
          // Status + port.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(children: [
              Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: running
                          ? _success(context)
                          : _danger(context))),
              const SizedBox(width: 7),
              Text(running ? app.t('remoteServerOn') : app.t('remoteServerOff'),
                  style: TextStyle(
                      fontSize: 12,
                      color: running
                          ? _success(context)
                          : _danger(context))),
            ]),
          ),
          evsRow(context, 
            label: app.t('remotePort'),
            control: SizedBox(
              width: 90,
              child: _RemoteField(
                controller: _port,
                onChanged: (v) {
                  final p = int.tryParse(v.trim());
                  if (p != null && p > 0 && p < 65536) app.setRemoteInputPort(p);
                },
              ),
            ),
          ),
          // Connection addresses.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Text(app.t('remoteAddress'),
                style: TextStyle(
                    fontSize: 12.5, color: _body(context))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in _addrs)
                  Text('$a:${app.remoteInputPort}',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                          color: _sub(context))),
                if (_addrs.isEmpty)
                  Text('127.0.0.1:${app.remoteInputPort}',
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFF6E7280))),
              ],
            ),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('remoteResponse'),
            control: evsSegmentedWide<String>(context, [
              ('desktop_tts', app.t('remoteRespDesktop')),
              ('phone_text', app.t('remoteRespPhone')),
              ('both', app.t('remoteRespBoth')),
            ], app.remoteResponseTarget, app.setRemoteResponseTarget),
          ),
          Divider(color: _stroke(context), height: 20),
          _addPhoneSection(),
          Divider(color: _stroke(context), height: 20),
          _devicesSection(),
        ],
      ],
    );
  }

  Widget _addPhoneSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(app.t('remoteCardAdd'),
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _body(context))),
        ),
        if (_pairCode == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: evsAddButton(context, app.t('remoteCardAdd'), _newCode),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8)),
                  child: QrImageView(
                    data: _qrData(),
                    size: 120,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.t('remotePairCode'),
                          style: TextStyle(
                              fontSize: 12, color: _sub(context))),
                      const SizedBox(height: 2),
                      SelectableText(_pairCode!,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                              color: _txt(context))),
                      const SizedBox(height: 6),
                      Text(app.t('remotePairHint'),
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFF6E7280))),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: _newCode,
                        borderRadius: BorderRadius.circular(8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.refresh,
                              size: 14, color: _sub(context)),
                          const SizedBox(width: 5),
                          Text(app.t('remoteNewCode'),
                              style: TextStyle(
                                  fontSize: 12, color: _sub(context))),
                        ]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _devicesSection() {
    final devs = app.remoteDevices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(app.t('remoteCardDevices'),
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _body(context))),
        ),
        if (devs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(app.t('remoteNoDevices'),
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF6E7280))),
          ),
        for (final d in devs) _deviceRow(d),
      ],
    );
  }

  Widget _deviceRow(RemoteDevice d) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.03),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.smartphone, size: 15, color: _sub(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(d.name.isEmpty ? 'Телефон' : d.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
            ),
            Text(_deviceStatus(d),
                style: const TextStyle(fontSize: 11, color: Color(0xFF6E7280))),
            const SizedBox(width: 8),
            evsToggle(context, d.enabled, (v) => app.setRemoteDeviceEnabled(d, v)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _permChip(app.t('remotePermVoice'), d.permVoice,
                (v) => app.setRemoteDevicePerms(d, voice: v)),
            const SizedBox(width: 8),
            _permChip(app.t('remotePermText'), d.permText,
                (v) => app.setRemoteDevicePerms(d, text: v)),
            const Spacer(),
            InkWell(
              onTap: () => app.removeRemoteDevice(d),
              borderRadius: BorderRadius.circular(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.link_off, size: 13, color: Color(0xFFE08080)),
                const SizedBox(width: 4),
                Text(app.t('remoteUnpair'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFE08080))),
              ]),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _permChip(String label, bool on, ValueChanged<bool> onTap) {
    return InkWell(
      onTap: () => onTap(!on),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: on ? const Color(0x2654E08A) : _overlayFill(context, 0.04),
          border: Border.all(
              color: on ? _success(context) : _stroke(context)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(on ? Icons.check : Icons.close,
              size: 12,
              color: on ? _success(context) : const Color(0xFF6E7280)),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: on ? _body(context) : const Color(0xFF6E7280))),
        ]),
      ),
    );
  }
}

// Small bordered text field matching the settings look (used by the remote panel).
class _RemoteField extends StatelessWidget {
  const _RemoteField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: 12.5, color: _body(context)),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

// AI voice-command suggestion review (Ф1 §1.7). Loads suggestions, lets the user
// tick apps, edit each phrase (with live collision checking), and saves the
// selected ones. Paths shown are read-only — they come from the scan, not the
// model. Pops the number saved, or null on cancel.
class _SuggestCommandsDialog extends StatefulWidget {
  const _SuggestCommandsDialog(this.app);
  final AppState app;
  @override
  State<_SuggestCommandsDialog> createState() => _SuggestCommandsDialogState();
}

class _SuggestCommandsDialogState extends State<_SuggestCommandsDialog> {
  List<CmdSuggestion>? _sugg; // null = loading
  final Map<CmdSuggestion, TextEditingController> _ctrls = {};
  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await app.buildCommandSuggestions();
    if (!mounted) return;
    for (final x in s) {
      _ctrls[x] = TextEditingController(text: x.phrase);
    }
    _deselectColliding(s);
    setState(() => _sugg = s);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // A colliding phrase can't be saved (§1.8: don't silently save a clash), so it
  // is unchecked and its box disabled until the phrase is edited to be unique.
  void _deselectColliding(List<CmdSuggestion> s) {
    for (final x in s) {
      if (x.collides) x.selected = false;
    }
  }

  void _onEdit(CmdSuggestion s, String v) {
    s.phrase = v;
    SuggestionEngine.resolveCollisions(_sugg!, app.voiceCommands);
    _deselectColliding(_sugg!);
    setState(() {});
  }

  void _save() {
    final chosen = _sugg!.where((s) => s.selected && !s.collides).toList();
    for (final s in chosen) {
      app.addVoiceCommand(VoiceCommand(
        phrase: s.phrase.trim(),
        type: VoiceCommandType.app,
        value: s.program.value, // authoritative path from the scan
      ));
    }
    Navigator.pop(context, chosen.length);
  }

  @override
  Widget build(BuildContext context) {
    final sugg = _sugg;
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Text(app.t('cmdSuggestTitle'),
          style: TextStyle(color: _txt(context), fontSize: 17)),
      content: SizedBox(
        width: 470,
        height: 470,
        child: sugg == null
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(height: 14),
                  Text(app.t('cmdSuggestScanning'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _sub(context), fontSize: 13)),
                ]),
              )
            : sugg.isEmpty
                ? Center(
                    child: Text(app.t('cmdSuggestEmpty'),
                        style: const TextStyle(color: Color(0xFF6E7280))))
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        const Icon(Icons.lock_outline,
                            size: 14, color: Color(0xFF6E7280)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(app.t('cmdSuggestPrivacy'),
                              style: const TextStyle(
                                  fontSize: 11.5, color: Color(0xFF6E7280))),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: sugg.length,
                        itemBuilder: (_, i) => _row(sugg[i]),
                      ),
                    ),
                  ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(app.t('cancel')),
        ),
        if (sugg != null && sugg.isNotEmpty)
          TextButton(
            onPressed: sugg.any((s) => s.selected && !s.collides) ? _save : null,
            child: Text(app.t('cmdSuggestSaveSel')),
          ),
      ],
    );
  }

  Widget _badge(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: color.withValues(alpha: 0.14),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      );

  Widget _row(CmdSuggestion s) {
    final isStore = s.program.value.toLowerCase().startsWith('shell:appsfolder');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(6, 8, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.03),
        border: Border.all(
            color: s.collides ? const Color(0xFFE0685E) : _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
              width: 26,
              height: 26,
              child: Checkbox(
                value: s.selected,
                onChanged:
                    s.collides ? null : (v) => setState(() => s.selected = v ?? false),
                visualDensity: VisualDensity.compact,
                side: const BorderSide(color: Color(0xFF6E7280)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(s.program.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
            ),
            if (s.usage > 0) _badge(app.t('cmdSuggestFreq'), _success(context)),
            if (isStore) _badge('Store', const Color(0xFF7BA0E0)),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 2, right: 2),
            child: TextField(
              controller: _ctrls[s],
              onChanged: (v) => _onEdit(s, v),
              style: TextStyle(fontSize: 12.5, color: _body(context)),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: _overlayFill(context, 0.04),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
              ),
            ),
          ),
          if (s.collides)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 3),
              child: Text(app.t('cmdSuggestCollision'),
                  style: const TextStyle(fontSize: 11, color: Color(0xFFE0685E))),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 3),
            child: Text(
              isStore ? 'Microsoft Store' : s.program.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: _faint(context)),
            ),
          ),
        ],
      ),
    );
  }
}

// Step-by-step "add command" wizard: pick a category (program / file / site /
// system / media) → choose the value (installed-program list, file picker, URL,
// or a system/media action) → enter the trigger phrase. Pops the built
// VoiceCommand, or null on cancel.
class _AddCommandWizard extends StatefulWidget {
  final AppState app;
  // When set, the wizard opens in EDIT mode: pre-filled and jumps straight to
  // the phrase step; "Save" returns the updated command.
  final VoiceCommand? initial;
  const _AddCommandWizard({required this.app, this.initial});
  @override
  State<_AddCommandWizard> createState() => _AddCommandWizardState();
}

class _AddCommandWizardState extends State<_AddCommandWizard> {
  int _step = 0; // 0 = category, 1 = value, 2 = phrase
  VoiceCommandType? _type;
  String _value = '';
  String _valueLabel = ''; // human-friendly summary
  final _phraseCtrl = TextEditingController();
  final _speakCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  List<ProgramEntry>? _programs; // null = loading
  String _progFilter = '';
  final Map<String, String> _iconPaths = {}; // iconSource -> cached PNG path
  // App-volume (appVolume) wizard state.
  List<Map<String, dynamic>>? _sessions; // null = loading active audio sessions
  String _avProcess = '';
  String _avAction = 'set';
  final _avDefaultCtrl = TextEditingController();

  bool get _isEdit => widget.initial != null;
  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    final it = widget.initial;
    if (it != null) {
      _type = it.type;
      _value = it.value;
      _valueLabel = it.value;
      _phraseCtrl.text = it.phrase;
      _speakCtrl.text = it.speakPhrase;
      _avProcess = it.process;
      _avAction = it.action;
      _avDefaultCtrl.text = it.defaultValue?.toString() ?? '';
      _step = 2; // straight to the phrase step; user can go Back to re-pick
    }
  }

  @override
  void dispose() {
    _phraseCtrl.dispose();
    _speakCtrl.dispose();
    _urlCtrl.dispose();
    _avDefaultCtrl.dispose();
    super.dispose();
  }

  static const _cats = <(VoiceCommandType, String, IconData)>[
    (VoiceCommandType.app, 'cmdWizProgram', Icons.apps),
    (VoiceCommandType.file, 'cmdWizFile', Icons.insert_drive_file_outlined),
    (VoiceCommandType.url, 'cmdWizSite', Icons.language),
    (VoiceCommandType.system, 'cmdWizSystem', Icons.settings_suggest_outlined),
    (VoiceCommandType.media, 'cmdWizMedia', Icons.music_note_outlined),
    (VoiceCommandType.appVolume, 'cmdWizVolume', Icons.volume_up_outlined),
  ];

  Future<void> _pickCategory(VoiceCommandType t) async {
    setState(() {
      _type = t;
      _value = '';
      _valueLabel = '';
    });
    if (t == VoiceCommandType.app) {
      setState(() {
        _programs = null;
        _step = 1;
      });
      final progs = await listInstalledPrograms();
      if (mounted) setState(() => _programs = progs);
      // Extract real app icons in the background; fill them in as they arrive.
      final map =
          await buildProgramIcons(progs.map((e) => e.iconSource).toList());
      if (mounted && map.isNotEmpty) setState(() => _iconPaths.addAll(map));
    } else if (t == VoiceCommandType.file) {
      await _pickFileValue();
    } else if (t == VoiceCommandType.appVolume) {
      // Default the phrase template so the {N} slot is discoverable.
      if (_phraseCtrl.text.trim().isEmpty) _phraseCtrl.text = 'громкость на {N}';
      setState(() {
        _sessions = null;
        _step = 1;
      });
      await _loadSessions();
    } else {
      setState(() => _step = 1);
    }
  }

  Future<void> _loadSessions() async {
    final s = await SidecarClient.instance.listAudioSessions();
    if (mounted) setState(() => _sessions = s);
  }

  Future<void> _pickFileValue() async {
    try {
      final res = await FilePicker.pickFiles();
      final p = res?.files.single.path;
      if (p != null && p.isNotEmpty && mounted) {
        setState(() {
          _value = p;
          _valueLabel = p.split(io.Platform.pathSeparator).last;
          _step = 2;
        });
      }
    } catch (_) {}
  }

  void _chooseValue(String value, String label) {
    setState(() {
      _value = value;
      _valueLabel = label;
      _step = 2;
    });
  }

  void _finish() {
    final phrase = _phraseCtrl.text.trim();
    if (phrase.isEmpty || _type == null || _value.trim().isEmpty) return;
    if (_type == VoiceCommandType.appVolume) {
      if (_avProcess.trim().isEmpty) return;
      final def = int.tryParse(_avDefaultCtrl.text.trim());
      Navigator.pop(
          context,
          VoiceCommand(
            phrase: phrase,
            type: VoiceCommandType.appVolume,
            value: _value.trim(), // display name
            speakPhrase: _speakCtrl.text.trim(),
            process: _avProcess.trim(),
            action: _avAction,
            defaultValue: def,
          ));
      return;
    }
    Navigator.pop(
        context,
        VoiceCommand(
          phrase: phrase,
          type: _type!,
          value: _value.trim(),
          speakPhrase: _speakCtrl.text.trim(),
        ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card2(context),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      title: Row(children: [
        if (_step > 0)
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.arrow_back, color: _txt(context), size: 20),
            onPressed: () => setState(() => _step -= 1),
          ),
        if (_step > 0) const SizedBox(width: 8),
        Expanded(
          child: Text(_stepTitle(),
              style: TextStyle(color: _txt(context), fontSize: 17)),
        ),
      ]),
      content: SizedBox(width: 380, child: _stepBody()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(app.t('cancel')),
        ),
        if (_step == 1 && _type == VoiceCommandType.appVolume)
          TextButton(
            onPressed: _avProcess.trim().isEmpty
                ? null
                : () => setState(() => _step = 2),
            child: Text(app.t('next')),
          ),
        if (_step == 2)
          TextButton(
            onPressed: _finish,
            child: Text(_isEdit ? app.t('save') : app.t('add')),
          ),
      ],
    );
  }

  // Step 1 for app-volume: pick a currently-playing app (from the sidecar's live
  // audio sessions — §2.4), the action, and a fallback value.
  Widget _volumeStep() {
    final sessions = _sessions;
    const actions = <(String, String)>[
      ('set', 'volActSet'),
      ('increase', 'volActInc'),
      ('decrease', 'volActDec'),
      ('mute', 'volActMute'),
      ('unmute', 'volActUnmute'),
    ];
    return SizedBox(
      height: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(app.t('volPickApp'),
                  style: TextStyle(
                      fontSize: 13, color: _body(context))),
            ),
            IconButton(
              tooltip: app.t('refreshModelsBtn'),
              icon: Icon(Icons.refresh, size: 18, color: _sub(context)),
              onPressed: () {
                setState(() => _sessions = null);
                _loadSessions();
              },
            ),
          ]),
          const SizedBox(height: 4),
          Expanded(
            child: sessions == null
                ? const Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : sessions.isEmpty
                    ? Center(
                        child: Text(app.t('volNoSessions'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 12.5, color: Color(0xFF6E7280))))
                    : ListView(
                        children: [
                          for (final s in sessions)
                            _sessionTile(
                              (s['process'] ?? '').toString(),
                              (s['display_name'] ?? '').toString(),
                              (s['volume'] as num?)?.toDouble(),
                            ),
                        ],
                      ),
          ),
          const SizedBox(height: 8),
          Text(app.t('volAction'),
              style: TextStyle(fontSize: 12.5, color: _sub(context))),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in actions)
                ChoiceChip(
                  label: Text(app.t(a.$2), style: const TextStyle(fontSize: 12)),
                  selected: _avAction == a.$1,
                  onSelected: (_) => setState(() => _avAction = a.$1),
                  backgroundColor: const Color(0xFF20202B),
                  selectedColor: const Color(0xFF3A3550),
                  labelStyle: TextStyle(color: _body(context)),
                ),
            ],
          ),
          // A fallback value only makes sense for the numeric actions.
          if (_avAction == 'set' ||
              _avAction == 'increase' ||
              _avAction == 'decrease') ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(app.t('volDefault'),
                    style: TextStyle(
                        fontSize: 12.5, color: _body(context))),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _avDefaultCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 12.5, color: _body(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: app.t('llmDefaultHint'),
                    hintStyle:
                        TextStyle(fontSize: 12, color: _faint(context)),
                    filled: true,
                    fillColor: _overlayFill(context, 0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _stroke(context)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _stroke(context)),
                    ),
                  ),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _sessionTile(String process, String display, double? vol) {
    final selected = _avProcess.toLowerCase() == process.toLowerCase();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() {
        _avProcess = process;
        _value = display.isNotEmpty ? display : process;
        _valueLabel = _value;
      }),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected
              ? const Color(0x263A7BE0)
              : _overlayFill(context, 0.03),
          border: Border.all(
              color: selected ? _accent(context) : _stroke(context)),
        ),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: selected ? const Color(0xFF7BA0E0) : const Color(0xFF6E7280)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(display.isNotEmpty ? display : process,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: _body(context))),
                Text(process,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF6E7280))),
              ],
            ),
          ),
          if (vol != null)
            Text('${(vol * 100).round()}%',
                style: TextStyle(fontSize: 11.5, color: _sub(context))),
        ]),
      ),
    );
  }

  String _stepTitle() {
    if (_step == 0) return app.t('cmdWizType');
    if (_step == 2) return app.t('cmdWizPhrase');
    switch (_type) {
      case VoiceCommandType.app:
        return app.t('cmdWizPickProgram');
      case VoiceCommandType.url:
        return app.t('cmdWizSite');
      case VoiceCommandType.system:
        return app.t('cmdWizSystem');
      case VoiceCommandType.media:
        return app.t('cmdWizMedia');
      case VoiceCommandType.appVolume:
        return app.t('cmdWizVolume');
      default:
        return app.t('cmdAdd');
    }
  }

  Widget _stepBody() {
    if (_step == 0) return _categoryStep();
    if (_step == 2) return _phraseStep();
    switch (_type) {
      case VoiceCommandType.appVolume:
        return _volumeStep();
      case VoiceCommandType.app:
        return _programStep();
      case VoiceCommandType.url:
        return _urlStep();
      case VoiceCommandType.system:
        return _actionStep(const [
          ('lock', 'sysLock', Icons.lock_outline),
          ('sleep', 'sysSleep', Icons.bedtime_outlined),
          ('vol up', 'sysVolUp', Icons.volume_up),
          ('vol down', 'sysVolDown', Icons.volume_down),
          ('mute', 'sysMute', Icons.volume_off),
        ]);
      case VoiceCommandType.media:
        return _actionStep(const [
          ('play', 'mediaPlay', Icons.play_arrow),
          ('next', 'mediaNext', Icons.skip_next),
          ('prev', 'mediaPrev', Icons.skip_previous),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _categoryStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (type, key, icon) in _cats)
          _wizTile(icon, app.t(key), () => _pickCategory(type)),
      ],
    );
  }

  // Real app icon (from the PowerShell-built cache) when available, else a
  // neutral fallback. UWP entries use "uwp:" iconSource; classic use the path.
  Widget _progIcon(ProgramEntry p) {
    final path = _iconPaths[p.iconSource];
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Image.file(io.File(path),
            width: 22,
            height: 22,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _progIconFallback(p)),
      );
    }
    return _progIconFallback(p);
  }

  Widget _progIconFallback(ProgramEntry p) => Icon(
        p.iconSource.startsWith('uwp:') ? Icons.storefront : Icons.launch,
        size: 18,
        color: _accent(context),
      );

  Widget _programStep() {
    final progs = _programs;
    return SizedBox(
      height: 360,
      child: Column(
        children: [
          TextField(
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF7A8090)),
              hintText: app.t('cmdWizSearch'),
              hintStyle: TextStyle(color: _faint(context), fontSize: 13),
            ),
            onChanged: (v) => setState(() => _progFilter = v.toLowerCase()),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _pickFileValue,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(app.t('cmdWizPickExe')),
            ),
          ),
          Expanded(
            child: progs == null
                ? const Center(child: CircularProgressIndicator())
                : Builder(builder: (_) {
                    final filtered = _progFilter.isEmpty
                        ? progs
                        : progs
                            .where((p) =>
                                p.name.toLowerCase().contains(_progFilter))
                            .toList();
                    if (filtered.isEmpty) {
                      return Center(
                          child: Text(app.t('cmdWizNoPrograms'),
                              style: const TextStyle(color: Color(0xFF6E7280))));
                    }
                    return ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final p = filtered[i];
                        return ListTile(
                          dense: true,
                          leading: _progIcon(p),
                          title: Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: _body(context), fontSize: 13)),
                          onTap: () => _chooseValue(p.value, p.name),
                        );
                      },
                    );
                  }),
          ),
        ],
      ),
    );
  }

  Widget _urlStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _urlCtrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: const InputDecoration(hintText: 'https://…'),
          onSubmitted: (_) => _confirmUrl(),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _confirmUrl,
            child: Text(app.t('next')),
          ),
        ),
      ],
    );
  }

  void _confirmUrl() {
    var u = _urlCtrl.text.trim();
    if (u.isEmpty) return;
    if (!u.contains('://')) u = 'https://$u';
    _chooseValue(u, u);
  }

  Widget _actionStep(List<(String, String, IconData)> actions) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (value, key, icon) in actions)
          _wizTile(icon, app.t(key), () => _chooseValue(value, app.t(key))),
      ],
    );
  }

  Widget _phraseStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _overlayFill(context, 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(Icons.bolt, size: 15, color: _accent(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _valueLabel.isNotEmpty ? _valueLabel : _value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _sub(context), fontSize: 12.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _phraseCtrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: InputDecoration(
            labelText: app.t('cmdWizPhrase'),
            hintText: app.t('cmdWizPhraseHint'),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _finish(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _speakCtrl,
          style: TextStyle(color: _txt(context)),
          decoration: InputDecoration(
            labelText: app.t('cmdWizSpeak'),
            hintText: app.t('cmdWizSpeakHint'),
            prefixIcon: const Icon(Icons.volume_up_outlined,
                size: 18, color: Color(0xFF7A8090)),
          ),
          onSubmitted: (_) => _finish(),
        ),
      ],
    );
  }

  Widget _wizTile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _overlayFill(context, 0.04),
          border: Border.all(color: _stroke(context)),
        ),
        child: Row(children: [
          Icon(icon, size: 19, color: _accent(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: _body(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          Icon(Icons.chevron_right, size: 18, color: _faint(context)),
        ]),
      ),
    );
  }
}

// Recognition-test panel: speak and see exactly how the recognizer transcribes
// your phrase (to design a trigger phrase). Reuses the shared sidecar STT
// streams; only drives STT itself if the always-on assistant isn't already
// listening — so it never breaks the assistant.
class _SttTestCard extends StatefulWidget {
  const _SttTestCard();
  @override
  State<_SttTestCard> createState() => _SttTestCardState();
}

class _SttTestCardState extends State<_SttTestCard> {
  bool _testing = false;
  bool _startedStt = false;
  String _partial = '';
  String _final = '';
  StreamSubscription<String>? _pSub;
  StreamSubscription<String>? _fSub;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    final app = context.read<AppState>();
    _pSub = SidecarClient.instance.partial.listen((t) {
      if (mounted) setState(() => _partial = t);
    });
    _fSub = SidecarClient.instance.finalText.listen((t) {
      if (mounted) {
        setState(() {
          _final = t;
          _partial = '';
        });
      }
    });
    // Only take over STT if the assistant isn't already listening.
    if (!VoiceAssistant.instance.isListening) {
      SidecarClient.instance
          .sttStart(app.effectiveSttLanguage, prompt: app.sttBiasPrompt);
      _startedStt = true;
    }
    setState(() => _testing = true);
  }

  void _stop() {
    _pSub?.cancel();
    _pSub = null;
    _fSub?.cancel();
    _fSub = null;
    if (_startedStt) {
      SidecarClient.instance.sttStop();
      _startedStt = false;
    }
    if (mounted) setState(() => _testing = false);
  }

  void _clear() => setState(() {
        _final = '';
        _partial = '';
      });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (_, sc, __) {
        final connected = sc == SidecarStatus.connected;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.spellcheck, size: 15, color: Color(0xFF8A90A0)),
                const SizedBox(width: 7),
                Text(app.t('sttTest'),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: _txt(context))),
              ]),
              const SizedBox(height: 8),
              Text(app.t('sttTestDesc'),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A8090))),
              const SizedBox(height: 12),
              if (!connected)
                Text(app.t('vaSttOffline'),
                    style: const TextStyle(color: Color(0xFFE0985D), fontSize: 13))
              else ...[
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 64),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: _overlayFill(context, 0.03),
                    border: Border.all(color: _stroke(context)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // SelectableText so the recognized phrases can be
                      // selected/copied (Ctrl+C or right-click → Copy).
                      if (_final.isNotEmpty)
                        SelectableText(_final,
                            style: TextStyle(
                                color: _txt(context),
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                      if (_partial.isNotEmpty) ...[
                        if (_final.isNotEmpty) const SizedBox(height: 6),
                        SelectableText(_partial,
                            style: const TextStyle(
                                color: Color(0xFF7A8090),
                                fontSize: 13.5,
                                fontStyle: FontStyle.italic)),
                      ],
                      if (_final.isEmpty && _partial.isEmpty)
                        Text(app.t('sttTestHint'),
                            style: TextStyle(
                                color: _faint(context), fontSize: 13)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  evsGhostButton(context, 
                    _testing ? app.t('sttTestStop') : app.t('sttTestStart'),
                    _testing ? Icons.stop : Icons.mic,
                    onTap: () => _testing ? _stop() : _start(),
                  ),
                  if (_final.isNotEmpty || _partial.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    evsGhostButton(context, 
                      app.t('sttTestClear'),
                      Icons.clear,
                      onTap: _clear,
                    ),
                  ],
                ]),
              ],
            ],
          ),
        );
      },
    );
  }
}

// Web-search settings block: on/off toggle + optional Tavily/Brave API keys.
// Works keyless (DuckDuckGo) by default; a key gives more reliable results.
class _WebSearchCard extends StatefulWidget {
  const _WebSearchCard();
  @override
  State<_WebSearchCard> createState() => _WebSearchCardState();
}

class _WebSearchCardState extends State<_WebSearchCard> {
  late final TextEditingController _tavily;
  late final TextEditingController _brave;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _tavily = TextEditingController(text: app.tavilyKey);
    _brave = TextEditingController(text: app.braveKey);
  }

  @override
  void dispose() {
    _tavily.dispose();
    _brave.dispose();
    super.dispose();
  }

  Widget _keyField(
      TextEditingController c, String hint, ValueChanged<String> onChanged) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: TextField(
        controller: c,
        onChanged: onChanged,
        obscureText: true,
        style: TextStyle(fontSize: 12.5, color: _body(context)),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 12.5, color: _faint(context)),
        ),
      ),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(s,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: _sectionLabel(context))),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.t('webSearchEnable'),
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _txt(context))),
                  const SizedBox(height: 3),
                  Text(app.t('webSearchDesc'),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF7A8090))),
                ],
              ),
            ),
            const SizedBox(width: 10),
            evsToggle(context, app.webSearchEnabled, app.setWebSearchEnabled),
          ]),
          if (app.webSearchEnabled) ...[
            const SizedBox(height: 14),
            Text(app.t('webSearchKeysHint'),
                style:
                    const TextStyle(fontSize: 11.5, color: Color(0xFF6E7280))),
            const SizedBox(height: 10),
            _label(app.t('webSearchTavily')),
            _keyField(_tavily, 'tvly-…', app.setTavilyKey),
            const SizedBox(height: 10),
            _label(app.t('webSearchBrave')),
            _keyField(_brave, 'BSA…', app.setBraveKey),
          ],
        ],
      ),
    );
  }
}

// A settings card occupying one or both grid columns.
class _CardSpec {
  final Widget child;
  final bool full;
  const _CardSpec(this.child, {this.full = false});
}

// Live preview for the «Виджеты» settings section: renders the currently
// selected style full-size, with a state switcher (idle/listening/speaking/
// thinking) and a synthetic-voice toggle. The simulation feeds
// VoiceLevels.tts, so history-driven styles (sphere/ring/spectrum) — and the
// sidebar mini-widget — move exactly like they would during real speech.
class _VizPreviewCard extends StatefulWidget {
  const _VizPreviewCard();
  @override
  State<_VizPreviewCard> createState() => _VizPreviewCardState();
}

class _VizPreviewCardState extends State<_VizPreviewCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final ValueNotifier<double> _lvl = ValueNotifier(0);
  String _preview = 'listening'; // idle | listening | speaking | thinking
  bool _simulate = true;

  @override
  void initState() {
    super.initState();
    _ticker =
        AnimationController(vsync: this, duration: const Duration(seconds: 4))
          ..repeat()
          ..addListener(_onTick);
  }

  void _onTick() {
    final t =
        (_ticker.lastElapsedDuration ?? Duration.zero).inMilliseconds / 1000.0;
    final reacts = _preview == 'listening' || _preview == 'speaking';
    if (_simulate) {
      final v = reacts ? _synthVoice(t) : 0.0;
      _lvl.value = v;
      VoiceLevels.instance.tts.value = v;
    } else {
      _lvl.value = VoiceLevels.instance.tts.value;
    }
  }

  // Synthetic "speech" envelope: syllables + micro modulation + slow drift.
  double _synthVoice(double t) {
    final syllable = 0.5 + 0.5 * math.sin(t * 6.2);
    final env = syllable * syllable;
    final micro = 0.5 + 0.5 * math.sin(t * 23.0);
    final drift = 0.5 + 0.5 * math.sin(t * 1.3);
    return (0.12 + 0.88 * env * (0.55 + 0.45 * micro) * (0.7 + 0.3 * drift))
        .clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _ticker
      ..removeListener(_onTick)
      ..dispose();
    if (_simulate) VoiceLevels.instance.tts.value = 0;
    _lvl.dispose();
    super.dispose();
  }

  SiriOrbState get _orbState => switch (_preview) {
        'speaking' => SiriOrbState.speaking,
        'thinking' => SiriOrbState.thinking,
        'idle' => SiriOrbState.idle,
        _ => SiriOrbState.listening,
      };

  LkVisualizerState get _barState => switch (_preview) {
        'speaking' => LkVisualizerState.speaking,
        'thinking' => LkVisualizerState.thinking,
        'idle' => LkVisualizerState.idle,
        _ => LkVisualizerState.listening,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final accent = Color(app.vizAccent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(children: [
        SizedBox(
          height: 230,
          child: Center(
            child: ValueListenableBuilder<double>(
              valueListenable: _lvl,
              builder: (_, lv, __) {
                switch (app.vizType) {
                  case 'waves':
                    return const EvsRingViz(size: 200);
                  case 'bars':
                    return const EvsBarsViz(width: 340, height: 140);
                  case 'orb':
                    return SiriOrb(
                      size: app.orbSize.clamp(120, 210),
                      level: lv,
                      state: _orbState,
                      colors: evsOrbColors(accent),
                      animationDuration: app.orbSpeed,
                    );
                  case 'lkbars':
                    return LkBarVisualizer(
                      level: lv,
                      state: _barState,
                      count: app.barCount,
                      color: accent,
                      barWidth: 12,
                      spacing: 8,
                      minHeight: 12,
                      maxHeight: 150,
                    );
                  case 'wave3d':
                    return const EvsWaveViz(
                        kind: 'wave3d', size: 220, reactive: true);
                  case 'waveflat':
                    return const EvsWaveViz(
                        kind: 'waveflat', size: 220, reactive: true);
                  case 'none':
                    return Text(app.t('vizNone'),
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF6E7280)));
                  default:
                    return ParticleSphere(
                      size: 190,
                      color: _accent(context),
                      soundLevel: _lvl,
                    );
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        evsSegmentedWide<String>(context, [
          ('idle', app.t('wsStateIdle')),
          ('listening', app.t('wsStateListening')),
          ('speaking', app.t('wsStateSpeaking')),
          ('thinking', app.t('wsStateThinking')),
        ], _preview, (v) => setState(() => _preview = v)),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.graphic_eq, size: 17, color: _sectionLabel(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(app.t('wsSimVoice'),
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _body(context))),
          ),
          evsToggle(context, _simulate, (v) {
            setState(() => _simulate = v);
            if (!v) VoiceLevels.instance.tts.value = 0;
          }),
        ]),
      ]),
    );
  }
}

// Selectable style thumbnail for the «Виджеты» section.
class _VizStyleTile extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final Widget preview;
  final VoidCallback onTap;
  const _VizStyleTile({
    required this.label,
    required this.selected,
    required this.accent,
    required this.preview,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 148,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? _accent(context).withValues(alpha: 0.1)
              : _overlayFill(context, 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : _stroke(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(children: [
          SizedBox(height: 56, child: Center(child: preview)),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? _body(context)
                      : _sectionLabel(context))),
        ]),
      ),
    );
  }
}

// TZ3.4 cold-start: a small pill on the home hero that reflects the backend
// readiness state machine (starting / loading_models / error). Hidden once the
// backend is `ready`, so the user can see when it's safe to speak instead of
// talking into the void during model load.
class _SttReadinessBanner extends StatelessWidget {
  const _SttReadinessBanner();
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.sttState, sc.status]),
      builder: (context, _) {
        final app = context.read<AppState>();
        final state = sc.sttState.value;
        if (state == 'ready') return const SizedBox.shrink();
        String label;
        Color tone;
        IconData? icon;
        switch (state) {
          case 'loading_models':
            label = app.t('sttLoadingModels');
            tone = _info(context);
            break;
          case 'error':
            final msg = sc.sttStateMessage;
            label = (msg != null && msg.isNotEmpty)
                ? '${app.t('sttErrorState')}: $msg'
                : app.t('sttErrorState');
            tone = _danger(context);
            icon = Icons.error_outline;
            break;
          default: // starting / not yet connected
            label = app.t('sttStarting');
            tone = _warn(context);
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: tone.withValues(alpha: 0.28)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Icon(icon, size: 16, color: tone)
                else
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: tone),
                  ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(label,
                      style: EvsType.body.copyWith(
                          fontSize: 13,
                          color: Color.lerp(tone, _txt(context), 0.35))),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// TZ1 "Модель распознавания": two engine cards (Whisper with size selector,
// GigaAM-v3) driven by SidecarClient's live status / capabilities / latency.
// Selecting an engine hot-swaps it; the block locks until ready|error and rolls
// the choice back with a snackbar on failure.
// TZ2 block 6: compact CPU/GPU selector shown under a GPU-capable engine. Hidden
// entirely when no GPU is detected or the engine has no CUDA path. Reused per
// engine. Also surfaces the game-mode offload and CUDA→CPU fallback states.
class _DeviceSelector extends StatelessWidget {
  final AppState app;
  final String engine; // engine this selector controls (e.g. 'whisper')
  final String hintKey;
  const _DeviceSelector(this.app, this.engine, this.hintKey);
  @override
  Widget build(BuildContext context) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge(
          [sc.gpuInfo, sc.engineGpu, sc.deviceStatus, sc.gameModeStatus]),
      builder: (context, _) {
        final gpu = sc.gpuInfo.value; // (available, name, ...)
        final supported = sc.engineGpu.value[engine] == true;
        if (!gpu.$1 || !supported) return const SizedBox.shrink();
        final name = gpu.$2;
        final ds = sc.deviceStatus.value;
        final offloaded = sc.gameModeStatus.value.$1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Text(app.t('deviceLabel'),
                style: TextStyle(color: _sub(context), fontSize: 11)),
            const SizedBox(height: 6),
            evsSegmentedWide<String>(context, 
              [
                ('cpu', app.t('deviceCpu')),
                ('cuda', name.isNotEmpty ? 'GPU · $name' : app.t('deviceGpu')),
              ],
              app.sttDevice,
              (v) => app.setSttDevice(v),
            ),
            const SizedBox(height: 4),
            Text(app.t(hintKey),
                style: const TextStyle(color: Color(0xFF6E7280), fontSize: 11)),
            if (offloaded)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(app.t('gmOffloadActive'),
                    style: const TextStyle(
                        color: Color(0xFFF0A030), fontSize: 11)),
              )
            else if (ds != null && ds.$3)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(app.t('deviceFellBack'),
                    style: const TextStyle(
                        color: Color(0xFFF0605E), fontSize: 11)),
              ),
          ],
        );
      },
    );
  }
}

// TZ2 block 4: a "Подробнее" toggle that reveals a longer explanation (2–4
// sentences) under a short option description. Texts come from i18n, not inline.
class _DetailDisclosure extends StatelessWidget {
  final bool open;
  final String detail;
  final String moreLabel;
  final String lessLabel;
  final VoidCallback onToggle;
  const _DetailDisclosure({
    required this.open,
    required this.detail,
    required this.moreLabel,
    required this.lessLabel,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(open ? lessLabel : moreLabel,
                  style: TextStyle(
                      color: _accent(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: _accent(context)),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(detail,
                style: TextStyle(
                    color: _sub(context), fontSize: 12, height: 1.45)),
          ),
      ],
    );
  }
}

class _SttEngineCards extends StatefulWidget {
  final AppState app;
  const _SttEngineCards(this.app);
  @override
  State<_SttEngineCards> createState() => _SttEngineCardsState();
}

class _SttEngineCardsState extends State<_SttEngineCards> {
  String? _pending; // engine being switched to (locks the block)
  final Set<String> _expanded = {}; // engines with "Подробнее" open (TZ2 block 4)

  @override
  void initState() {
    super.initState();
    SidecarClient.instance.engineStatus.addListener(_onStatus);
  }

  @override
  void dispose() {
    SidecarClient.instance.engineStatus.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    final st = SidecarClient.instance.engineStatus.value;
    if (st == null || _pending == null || st.$1 != _pending) return;
    if (st.$2 == 'ready') {
      if (mounted) setState(() => _pending = null);
    } else if (st.$2 == 'error') {
      final failed = _pending!;
      final msg = st.$3 ?? widget.app.t('engSwitchFailed');
      if (mounted) setState(() => _pending = null);
      // Visual rollback: revert the choice to the other engine.
      if (widget.app.sttSidecarEngine == failed) {
        widget.app.setSttSidecarEngine(failed == 'gigaam' ? 'whisper' : 'gigaam');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${widget.app.t('engSwitchFailed')}: $msg')));
      }
    }
  }

  void _select(String engine) {
    if (_pending != null) return; // block re-press while switching
    if (widget.app.sttSidecarEngine == engine) return;
    setState(() => _pending = engine);
    widget.app.setSttSidecarEngine(engine);
  }

  @override
  Widget build(BuildContext context) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.engines, sc.sttLatencyMs, sc.status]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          _tile('whisper', widget.app.t('engWhisperName'),
              widget.app.t('engWhisperShort')),
          const SizedBox(height: 10),
          _tile('gigaam', widget.app.t('engGigaamName'),
              widget.app.t('engGigaamShort')),
        ]),
      ),
    );
  }

  Widget _badge(String text, Color bg, {Color fg = Colors.white}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: TextStyle(
                color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  Widget _tile(String engine, String name, String desc) {
    final app = widget.app;
    final sc = SidecarClient.instance;
    final selected = app.sttSidecarEngine == engine;
    final avail = sc.engines.value[engine] == true;
    final loading = _pending == engine;

    String status;
    Color color;
    if (loading) {
      status = app.t('engLoading');
      color = const Color(0xFFB9A6FF);
    } else if (selected) {
      status = app.t('engActive');
      color = const Color(0xFF34D399);
    } else if (avail) {
      status = app.t('engReady');
      color = const Color(0xFF8A8A95);
    } else {
      status = app.t('engNotFound');
      color = const Color(0xFFF0A030);
    }
    final latency = sc.sttLatencyMs.value;

    return Opacity(
      opacity: (_pending != null && !loading) ? 0.5 : 1.0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(engine),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card2(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? _accent(context).withValues(alpha: 0.4)
                  : _stroke(context),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: selected
                        ? const Color(0xFFB9A6FF)
                        : const Color(0xFF6E7280)),
                const SizedBox(width: 10),
                Text(name,
                    style: TextStyle(
                        color: _txt(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                if (loading)
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else ...[
                  if (selected && latency > 0) ...[
                    _badge('$latency ${app.t('msShort')}',
                        const Color(0xFF2A2A38)),
                    const SizedBox(width: 6),
                  ],
                  _badge(status, color.withValues(alpha: 0.18), fg: color),
                ],
              ]),
              const SizedBox(height: 6),
              Text(desc,
                  style: TextStyle(
                      color: _sub(context), fontSize: 12)),
              _DetailDisclosure(
                open: _expanded.contains(engine),
                detail: app.t(
                    engine == 'gigaam' ? 'engGigaamDetail' : 'engWhisperDetail'),
                moreLabel: app.t('moreDetails'),
                lessLabel: app.t('lessDetails'),
                onToggle: () => setState(() {
                  if (!_expanded.remove(engine)) _expanded.add(engine);
                }),
              ),
              if (engine == 'gigaam' && !avail && !loading)
                FutureBuilder<String>(
                  future: sc.gigaamModelDir(),
                  builder: (_, snap) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${snap.data ?? ''}\nHF: $kGigaamHfRepo',
                      style: const TextStyle(
                          color: Color(0xFF6E7280), fontSize: 10.5),
                    ),
                  ),
                ),
              if (engine == 'whisper' && selected) ...[
                const SizedBox(height: 12),
                Text(app.t('engWhisperSize'),
                    style: TextStyle(
                        color: _sub(context), fontSize: 11)),
                const SizedBox(height: 6),
                evsSegmentedWide<String>(context, 
                  const [('tiny', 'tiny'), ('base', 'base'), ('small', 'small')],
                  ['tiny', 'base', 'small'].contains(app.whisperModel)
                      ? app.whisperModel
                      : 'small',
                  (v) => app.setWhisperModel(v),
                ),
                _DeviceSelector(app, 'whisper', 'deviceHintWhisper'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// TZ2 block 3: model manager — download / delete asset models (STT / denoise /
// TTS voices) into <userdata>/models/<id>/, reusing downloadFileWithProgress.
// TZ2 block 5: "Голос ассистента" — the always-available system voice plus
// downloadable Piper voice cards, each with download/delete, a "listen sample"
// button and active-voice selection. Preview/select go through the main sidecar.
class _AssistantVoiceCard extends StatefulWidget {
  final AppState app;
  const _AssistantVoiceCard(this.app);
  @override
  State<_AssistantVoiceCard> createState() => _AssistantVoiceCardState();
}

class _AssistantVoiceCardState extends State<_AssistantVoiceCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.app.refreshAssetModels());
  }

  List<AssetModelSpec> get _voices =>
      kAssetModels.where((s) => s.family == 'tts-voice').toList();

  Future<void> _confirmDelete(AssetModelSpec spec) async {
    final app = widget.app;
    if (app.assetActive(spec)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(app.t('mdlActiveCantDelete'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(spec.name, style: TextStyle(color: _txt(context))),
        content: Text(app.t('mdlDeleteConfirm'),
            style: TextStyle(color: _sub(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(app.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.t('mdlDelete'))),
        ],
      ),
    );
    if (ok == true) await app.deleteAssetModel(spec);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: Listenable.merge([app, SidecarClient.instance.ttsStatus]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _systemTile(),
            const SizedBox(height: 10),
            for (final spec in _voices) ...[
              _voiceTile(spec),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  Widget _shell(
      {required bool active, VoidCallback? onSelect, required Widget child}) {
    final tile = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card2(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: active ? const Color(0x5534D399) : _stroke(context),
            width: active ? 1.5 : 1),
      ),
      child: child,
    );
    if (onSelect == null) return tile;
    return InkWell(
        borderRadius: BorderRadius.circular(14), onTap: onSelect, child: tile);
  }

  Widget _titleRow(String name, String? status) {
    return Row(children: [
      Expanded(
          child: Text(name,
              style: TextStyle(
                  color: _txt(context),
                  fontSize: 15,
                  fontWeight: FontWeight.w700))),
      if (status != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: const Color(0x2234D399),
              borderRadius: BorderRadius.circular(8)),
          child: Text(status,
              style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Widget _systemTile() {
    final app = widget.app;
    final active = app.ttsPiperVoice.isEmpty;
    return _shell(
      active: active,
      onSelect: active ? null : () => app.setTtsPiperVoice(''),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(
              app.t('voiceSystemName'), active ? app.t('engActive') : null),
          const SizedBox(height: 6),
          Text(app.t('voiceSystemDesc'),
              style: TextStyle(color: _sub(context), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _voiceTile(AssetModelSpec spec) {
    final app = widget.app;
    final installed = app.assetInstalled(spec.id);
    final progress = app.assetProgress[spec.id];
    final downloading = progress != null;
    final active = app.assetActive(spec);
    final sizeMb = (spec.totalSize / 1e6).round();
    final status = active
        ? app.t('engActive')
        : installed
            ? app.t('mdlInstalled')
            : downloading
                ? '${(progress.clamp(0.0, 1.0) * 100).round()}%'
                : null;
    return _shell(
      active: active,
      onSelect: (installed && !active)
          ? () => app.setTtsPiperVoice(spec.voiceId!)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(spec.name, status),
          const SizedBox(height: 6),
          Text(app.t(spec.descKey),
              style: TextStyle(color: _sub(context), fontSize: 12)),
          const SizedBox(height: 4),
          Text('~$sizeMb ${app.t('mbShort')}',
              style: const TextStyle(color: Color(0xFF6E7280), fontSize: 11)),
          const SizedBox(height: 10),
          if (downloading)
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: const Color(0xFF2A2A38)),
                ),
              ),
              IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: _sub(context)),
                  tooltip: app.t('cancelDownload'),
                  onPressed: () => app.cancelAssetDownload(spec.id)),
            ])
          else if (installed)
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(app.t('voiceListen')),
                  onPressed: () => app.previewPiperVoice(spec)),
              if (!active)
                FilledButton.icon(
                    icon: const Icon(Icons.check, size: 16),
                    label: Text(app.t('voiceSelect')),
                    onPressed: () => app.setTtsPiperVoice(spec.voiceId!)),
              OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: Text(app.t('mdlDelete')),
                  onPressed: () => _confirmDelete(spec)),
            ])
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(app.t('mdlDownload')),
                  onPressed: () => app.downloadAssetModel(spec)),
            ),
        ],
      ),
    );
  }
}

class _AssetModelsCard extends StatefulWidget {
  final AppState app;
  const _AssetModelsCard(this.app);
  @override
  State<_AssetModelsCard> createState() => _AssetModelsCardState();
}

class _AssetModelsCardState extends State<_AssetModelsCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.app.refreshAssetModels());
  }

  // Piper voices live in the "Голос ассистента" card, not the general manager.
  List<AssetModelSpec> get _models =>
      kAssetModels.where((s) => s.family != 'tts-voice').toList();

  Future<void> _confirmDelete(AssetModelSpec spec) async {
    final app = widget.app;
    if (app.assetActive(spec)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(app.t('mdlActiveCantDelete'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(spec.name, style: TextStyle(color: _txt(context))),
        content: Text(app.t('mdlDeleteConfirm'),
            style: TextStyle(color: _sub(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(app.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.t('mdlDelete'))),
        ],
      ),
    );
    if (ok == true) await app.deleteAssetModel(spec);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final spec in _models) ...[
            _tile(spec),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: Text(app.t('mdlOpenFolder')),
                onPressed: () => app.openModelsFolder(),
              ),
              const Spacer(),
              Builder(builder: (_) {
                final mb = (kAssetModels
                            .where((s) => app.assetInstalled(s.id))
                            .fold<int>(0, (a, s) => a + s.totalSize) /
                        1e6)
                    .round();
                if (mb <= 0) return const SizedBox.shrink();
                return Text('${app.t('mdlTotalDisk')}: $mb ${app.t('mbShort')}',
                    style: const TextStyle(
                        color: Color(0xFF6E7280), fontSize: 11));
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tile(AssetModelSpec spec) {
    final app = widget.app;
    final installed = app.assetInstalled(spec.id);
    final progress = app.assetProgress[spec.id];
    final downloading = progress != null;
    final active = app.assetActive(spec);

    String status;
    Color color;
    if (downloading) {
      status = '${(progress.clamp(0.0, 1.0) * 100).round()}%';
      color = const Color(0xFFB9A6FF);
    } else if (active) {
      status = app.t('engActive');
      color = const Color(0xFF34D399);
    } else if (installed) {
      status = app.t('mdlInstalled');
      color = const Color(0xFF34D399);
    } else {
      status = app.t('mdlNotInstalled');
      color = const Color(0xFF8A8A95);
    }
    final sizeMb = (spec.totalSize / 1e6).round();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card2(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(spec.name,
                    style: TextStyle(
                        color: _txt(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(status,
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(app.t(spec.descKey),
              style: TextStyle(color: _sub(context), fontSize: 12)),
          const SizedBox(height: 4),
          Text(
              '~$sizeMb ${app.t('mbShort')} · ~${spec.ramMb} ${app.t('mdlRamShort')}',
              style: const TextStyle(color: Color(0xFF6E7280), fontSize: 11)),
          const SizedBox(height: 10),
          if (downloading)
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: const Color(0xFF2A2A38)),
                ),
              ),
              IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: _sub(context)),
                  tooltip: app.t('cancelDownload'),
                  onPressed: () => app.cancelAssetDownload(spec.id)),
            ])
          else
            Align(
              alignment: Alignment.centerLeft,
              child: installed
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: Text(app.t('mdlDelete')),
                      onPressed: () => _confirmDelete(spec))
                  : FilledButton.icon(
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(app.t('mdlDownload')),
                      onPressed: () => app.downloadAssetModel(spec)),
            ),
        ],
      ),
    );
  }
}

// TZ2 block 1: noise-suppression selector (off / light / strong). Applies live;
// warns if the selected mode's model isn't downloaded (→ Models section).
class _DenoiseSelector extends StatefulWidget {
  final AppState app;
  const _DenoiseSelector(this.app);
  @override
  State<_DenoiseSelector> createState() => _DenoiseSelectorState();
}

class _DenoiseSelectorState extends State<_DenoiseSelector> {
  bool _open = false; // "Подробнее" (TZ2 block 4)
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: sc.denoiseStatus,
      builder: (context, _) {
        final mode = app.denoiseMode;
        final needsModel = mode == 'light'
            ? 'denoise-gtcrn'
            : mode == 'strong'
                ? 'denoise-df'
                : null;
        final installed = needsModel == null || app.assetInstalled(needsModel);
        final st = sc.denoiseStatus.value;
        final desc = mode == 'off'
            ? app.t('dnOffShort')
            : mode == 'light'
                ? app.t('dnLightShort')
                : app.t('dnStrongShort');
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              evsSegmentedWide<String>(context, 
                [
                  ('off', app.t('dnOff')),
                  ('light', app.t('dnLight')),
                  ('strong', app.t('dnStrong')),
                ],
                mode,
                (v) => app.setDenoiseMode(v),
              ),
              const SizedBox(height: 8),
              Text(desc,
                  style:
                      TextStyle(color: _sub(context), fontSize: 12)),
              _DetailDisclosure(
                open: _open,
                detail: app.t(mode == 'off'
                    ? 'dnOffDetail'
                    : mode == 'light'
                        ? 'dnLightDetail'
                        : 'dnStrongDetail'),
                moreLabel: app.t('moreDetails'),
                lessLabel: app.t('lessDetails'),
                onToggle: () => setState(() => _open = !_open),
              ),
              if (!installed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    const Icon(Icons.download_for_offline_outlined,
                        size: 14, color: Color(0xFFF0A030)),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(app.t('dnNotInstalled'),
                            style: const TextStyle(
                                color: Color(0xFFF0A030), fontSize: 11))),
                  ]),
                ),
              if (st != null && st.$2 == 'error' && st.$3 != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(st.$3!,
                      style: const TextStyle(
                          color: Color(0xFFF0605E), fontSize: 11)),
                ),
            ],
          ),
        );
      },
    );
  }
}

// TZ2 block 8.2: additional simultaneous microphones. Lists input devices other
// than the primary; each can be toggled "in use" with its own denoise mode. The
// sidecar arbitrates overlapping phrases (loudest wins, 2 s cooldown).
class _MultiMicCard extends StatefulWidget {
  final AppState app;
  const _MultiMicCard(this.app);
  @override
  State<_MultiMicCard> createState() => _MultiMicCardState();
}

class _MultiMicCardState extends State<_MultiMicCard> {
  List<InputDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await MicMeter.instance.listDevices();
    if (mounted) setState(() => _devices = d);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final extras =
        _devices.where((d) => d.id != app.inputDeviceId).toList();
    if (extras.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final d in extras) _row(d)],
        ),
      ),
    );
  }

  Widget _row(InputDevice d) {
    final app = widget.app;
    final active = app.extraMicIds.contains(d.id);
    final mode = app.deviceDenoise[d.id] ?? 'light';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card2(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                active ? const Color(0x5534D399) : _stroke(context)),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(
              child: Text(d.label,
                  style: TextStyle(
                      color: _txt(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w600))),
          evsToggle(context, active, (v) => app.toggleExtraMic(d.id, d.label, v)),
        ]),
        if (active) ...[
          const SizedBox(height: 10),
          evsSegmentedWide<String>(context, 
            [
              ('off', app.t('dnOff')),
              ('light', app.t('dnLight')),
              ('strong', app.t('dnStrong')),
            ],
            mode,
            (v) => app.setExtraMicDenoise(d.id, v),
          ),
        ],
      ]),
    );
  }
}

// TZ2 block 7: game / heavy-GPU mode settings + live "GPU offload" badge.
// Hidden entirely when no GPU is detected (there's nothing to offload).
class _GameModeCard extends StatelessWidget {
  final AppState app;
  const _GameModeCard(this.app);

  Future<void> _addExclusion(BuildContext context) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(app.t('gmExclAdd'), style: TextStyle(color: _txt(context))),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: const InputDecoration(hintText: 'game.exe'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(app.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: Text(app.t('mdlAdd'))),
        ],
      ),
    );
    final n = (name ?? '').trim().toLowerCase();
    if (n.isNotEmpty && !app.gameModeExclusions.contains(n)) {
      app.setGameModeExclusions([...app.gameModeExclusions, n]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = SidecarClient.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([sc.gpuInfo, sc.gameModeStatus]),
      builder: (context, _) {
        if (!sc.gpuInfo.value.$1) return const SizedBox.shrink();
        final (active, reason) = sc.gameModeStatus.value;
        return evsCard(
          context,
          icon: Icons.sports_esports_outlined,
          title: app.t('cardGameMode'),
          rows: [
            if (active)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
                child: Row(children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: const Color(0x22F0A030),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(app.t('gmOffloadBadge'),
                        style: const TextStyle(
                            color: Color(0xFFF0A030),
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      reason == 'vram'
                          ? app.t('gmReasonVram')
                          : app.t('gmReasonFullscreen'),
                      style: TextStyle(
                          color: _sub(context), fontSize: 11)),
                ]),
              ),
            evsRow(context, 
              label: app.t('gmFullscreen'),
              desc: app.t('gmFullscreenDesc'),
              control: evsToggle(context, 
                  app.gameModeFullscreen, (v) => app.setGameModeFullscreen(v)),
            ),
            evsRow(context, 
              label: app.t('gmVram'),
              desc: app.t('gmVramDesc'),
              control: evsToggle(context, app.gameModeVram, (v) => app.setGameModeVram(v)),
            ),
            if (app.gameModeVram) ...[
              evsRow(context, 
                label: app.t('gmVramEnter'),
                control: evsSlider(context, 
                  value: app.gameModeVramEnter.clamp(50, 99),
                  min: 50,
                  max: 99,
                  divisions: 49,
                  label: '${app.gameModeVramEnter.round()}%',
                  onChanged: (v) => app.setGameModeVramThresholds(
                      v, app.gameModeVramExit),
                ),
              ),
              evsRow(context, 
                label: app.t('gmVramExit'),
                control: evsSlider(context, 
                  value: app.gameModeVramExit
                      .clamp(30, app.gameModeVramEnter - 5),
                  min: 30,
                  max: 94,
                  divisions: 64,
                  label: '${app.gameModeVramExit.round()}%',
                  onChanged: (v) => app.setGameModeVramThresholds(
                      app.gameModeVramEnter, v),
                ),
              ),
            ],
            evsRow(context, 
              label: app.t('gmNotify'),
              desc: app.t('gmNotifyDesc'),
              control:
                  evsToggle(context, app.gameModeNotify, (v) => app.setGameModeNotify(v)),
            ),
            evsRow(context, 
              stacked: true,
              label: app.t('gmExclusions'),
              desc: app.t('gmExclusionsDesc'),
              control: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (app.gameModeExclusions.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final ex in app.gameModeExclusions)
                          Chip(
                            label: Text(ex,
                                style: const TextStyle(fontSize: 12)),
                            onDeleted: () => app.setGameModeExclusions(app
                                .gameModeExclusions
                                .where((e) => e != ex)
                                .toList()),
                          ),
                      ],
                    ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(app.t('gmExclAdd')),
                      onPressed: () => _addExclusion(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class DesktopSettings extends StatefulWidget {
  const DesktopSettings({super.key});
  @override
  State<DesktopSettings> createState() => _DesktopSettingsState();
}

class _DesktopSettingsState extends State<DesktopSettings> {
  int _section = 0;
  // Held so dispose() can end draft mode without a BuildContext (TZ2.2).
  AppState? _appRef;
  // Phase-1 placeholders for not-yet-wired desktop toggles (autostart, tray…).
  final Map<String, bool> _stub = {
    'autostart': true,
    'tray': true,
    'closeToTray': true,
    'startShown': false,
    'notifications': true,
    'animations': true,
    'autoUpdate': true,
    'showPartial': true,
    'showVizBg': true,
    'cmdEnabled': true,
    'permFiles': true,
    'permBrowser': true,
    'permMedia': true,
    'permSystem': false,
    'permNetwork': true,
    'permRegistry': false,
    'offline': false,
    'noTelemetry': true,
    'noModelNet': false,
  };
  final Map<String, double> _stubNum = {
    'threshold': 65,
    'temp': 0.7,
    'topp': 0.9,
    'maxtok': 1024,
  };
  final List<String> _blacklist = [
    'удали все файлы',
    'форматируй диск',
    'shutdown /s',
  ];
  final TextEditingController _activatorCtrl =
      TextEditingController(text: 'EVS');
  final TextEditingController _stopWordsCtrl = TextEditingController();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _apiKeyCtrl;
  bool _ctrlInit = false;
  List<InputDevice> _micDevices = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ctrlInit) return;
    _ctrlInit = true;
    final app = context.read<AppState>();
    // Enter settings draft mode: changes preview live but persist only on Save.
    _appRef = app;
    app.beginSettingsEdit();
    final p = app.persona;
    _nameCtrl = TextEditingController(text: p.assistantName);
    _promptCtrl = TextEditingController(text: p.customPrompt);
    _serverCtrl = TextEditingController(text: app.serverUrl);
    _apiKeyCtrl = TextEditingController(text: app.apiKey);
    _activatorCtrl.text = app.wakeWord;
    _stopWordsCtrl.text = app.stopWords.join(', ');
    // Keep the meter alive for the input-level bar, and enumerate mics.
    MicMeter.instance.start(deviceId: app.inputDeviceId);
    _loadMicDevices();
  }

  Future<void> _loadMicDevices() async {
    final devs = await MicMeter.instance.listDevices();
    if (mounted) setState(() => _micDevices = devs);
  }

  Widget _inputDeviceControl(AppState app) {
    final items = <(String, String)>[('', app.t('defaultDevice'))];
    for (final d in _micDevices) {
      items.add((d.id, d.label));
    }
    final current = items.firstWhere((e) => e.$1 == app.inputDeviceId,
        orElse: () => items.first);
    return PopupMenuButton<String>(
      tooltip: '',
      color: _card(context),
      onSelected: (id) {
        final label = items
            .firstWhere((e) => e.$1 == id, orElse: () => ('', ''))
            .$2;
        app.setInputDeviceId(id, label: label);
        MicMeter.instance.start(deviceId: id);
        final hint = app.consumeMicHint();
        if (hint.isNotEmpty) showAppSnackBar(context, hint);
      },
      itemBuilder: (_) => [
        for (final it in items)
          PopupMenuItem<String>(
            value: it.$1,
            child: Text(it.$2,
                style: TextStyle(color: _body(context), fontSize: 13)),
          ),
      ],
      child: evsSelectButton(context, current.$2, minWidth: 120),
    );
  }

  @override
  void dispose() {
    // Safety net: if the screen is torn down while still editing (not via Save/
    // Cancel or the exit guard), discard the draft so nothing half-edited sticks.
    _appRef?.abortSettingsEdit();
    if (_ctrlInit) {
      _nameCtrl.dispose();
      _promptCtrl.dispose();
      _serverCtrl.dispose();
      _apiKeyCtrl.dispose();
    }
    _activatorCtrl.dispose();
    _stopWordsCtrl.dispose();
    super.dispose();
  }

  void _persona(void Function(Personalization) mut) {
    final app = context.read<AppState>();
    mut(app.persona);
    app.savePersona(app.persona);
  }

  late final List<(IconData, String, String)> _sections = const [
    (Icons.settings_outlined, 'navGeneral', 'navGeneralSub'),
    (Icons.mic_none, 'navVoiceInput', 'navVoiceInputSub'),
    (Icons.auto_awesome_outlined, 'navWidgets', 'navWidgetsSub'),
    (Icons.bolt_outlined, 'navVoiceCommands', 'navVoiceCommandsSub'),
    (Icons.phone_iphone, 'navRemote', 'navRemoteSub'),
    (Icons.memory, 'navModel', 'navModelSub'),
    (Icons.chat_bubble_outline, 'navPersona', 'navPersonaSub'),
    (Icons.lock_outline, 'navPrivacy', 'navPrivacySub'),
    (Icons.info_outline, 'navAbout', 'navAboutSub'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PopScope(
      canPop: !app.settingsDirty && !app.settingsApplying,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleExit(app);
      },
      child: Scaffold(
        backgroundColor: _bg(context),
        body: Container(
          decoration: _evsShellBg(context),
          child: Column(
            children: [
              const _WindowTitleBar(),
              Expanded(
                child: Row(
                  children: [
                    _nav(app),
                    Expanded(child: _sectionScaffold(app)),
                  ],
                ),
              ),
              _saveBar(app),
            ],
          ),
        ),
      ),
    );
  }

  // Sticky "unsaved changes" bar (TZ2.2): shown whenever the draft is dirty or a
  // save is in flight; collapses with an animation otherwise.
  Widget _saveBar(AppState app) {
    final show = app.settingsDirty || app.settingsApplying;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !show
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: _card2(context),
                border: Border(top: BorderSide(color: _stroke(context))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_outlined,
                      size: 19, color: Color(0xFFB9A6FF)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(app.t('settingsUnsaved'),
                        style:
                            TextStyle(color: _txt(context), fontSize: 13)),
                  ),
                  if (app.settingsApplying)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else ...[
                    TextButton(
                      onPressed: () => _revertSettings(app),
                      child: Text(app.t('cancel'),
                          style: TextStyle(color: _sub(context))),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _saveSettings(app),
                      child: Text(app.t('save')),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _saveSettings(AppState app) async {
    final ok = await app.commitSettingsEdit();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text(ok ? app.t('settingsSaved') : app.t('settingsSaveFailed')),
    ));
    // Stay on the screen — re-arm draft mode for further edits.
    app.beginSettingsEdit();
  }

  Future<void> _revertSettings(AppState app) async {
    await app.cancelSettingsEdit();
    if (!mounted) return;
    // Text fields keep their own controller state — resync them to the reverted
    // values so a Cancel visibly rolls back typed text too.
    _resetTextControllers(app);
    app.beginSettingsEdit();
  }

  void _resetTextControllers(AppState app) {
    if (!_ctrlInit) return;
    _serverCtrl.text = app.serverUrl;
    _apiKeyCtrl.text = app.apiKey;
    _activatorCtrl.text = app.wakeWord;
    _stopWordsCtrl.text = app.stopWords.join(', ');
  }

  // Exit guard (TZ2.2): leaving with unsaved changes asks Save / Don't save /
  // Stay. Reached from the back button and the system pop (via PopScope).
  Future<void> _handleExit(AppState app) async {
    if (!app.settingsDirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // Styled to match the update-restart prompt (_showPrompt): dark rounded card,
    // logo mark + title, a hint line, and Stay / Don't-save / Save actions with a
    // gradient primary. Height-capped + scrollable so long copy can't overflow.
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(dctx).size.height * 0.85),
          child: SingleChildScrollView(
            child: Container(
              width: 440,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
              decoration: BoxDecoration(
                color: _card2(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x1AFFFFFF)),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black54,
                      blurRadius: 40,
                      offset: Offset(0, 16)),
                ],
              ),
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
                          app.t('settingsExitTitle'),
                          style: TextStyle(
                              color: _txt(context),
                              fontSize: 17,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(app.t('settingsUnsaved'),
                      style: const TextStyle(
                          color: Color(0xFF6E7280), fontSize: 12)),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, 'stay'),
                        child: Text(app.t('settingsExitStay'),
                            style: TextStyle(color: _sub(context))),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, 'discard'),
                        child: Text(app.t('settingsExitDiscard'),
                            style: TextStyle(color: _sub(context))),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.pop(dctx, 'save'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: const LinearGradient(
                                colors: [Color(0xFF5068D8), Color(0xFF8855CC)]),
                          ),
                          child: Text(app.t('settingsExitSave'),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700)),
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
    if (!mounted) return;
    if (choice == 'save') {
      await app.commitSettingsEdit();
      if (mounted) Navigator.of(context).pop();
    } else if (choice == 'discard') {
      await app.cancelSettingsEdit();
      if (mounted) Navigator.of(context).pop();
    }
    // 'stay' / dismissed → remain on the screen (draft intact).
  }

  // -------- left nav rail --------
  Widget _nav(AppState app) {
    return Container(
      width: 244,
      decoration: _evsRailBg(context),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 18),
              child: Row(
                children: [
                  InkResponse(
                    radius: 22,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _overlayFill(context, 0.042),
                        border: Border.all(color: _stroke(context)),
                      ),
                      child: Icon(Icons.arrow_back,
                          size: 15, color: _sub(context)),
                    ),
                  ),
                  const SizedBox(width: 9),
                  const _EvsLogoMark(size: 28),
                  const SizedBox(width: 9),
                  Text('EVS',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: _txt(context))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text('РАЗДЕЛЫ',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                      color: _faint(context))),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _sections.length,
                itemBuilder: (_, i) {
                  final s = _sections[i];
                  final active = i == _section;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(13),
                        onTap: () => setState(() => _section = i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 11, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            color: active
                                ? _accent(context).withValues(alpha: 0.13)
                                : Colors.transparent,
                            border: Border.all(
                              color: active
                                  ? _accent(context).withValues(alpha: 0.22)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 31,
                                height: 31,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(9),
                                  color: active
                                      ? _accent(context).withValues(alpha: 0.2)
                                      : _overlayFill(context, 0.042),
                                ),
                                child: Icon(s.$1,
                                    size: 14,
                                    color: active
                                        ? _accent(context)
                                        : const Color(0xFF9691C0)),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(app.t(s.$2),
                                    style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                        color: active
                                            ? _txt(context)
                                            : _sub(context))),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------- right pane: section topbar + card grid --------
  Widget _sectionScaffold(AppState app) {
    final s = _sections[_section];
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 14),
            child: Row(
              children: [
                Text(app.t(s.$2),
                    style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: _txt(context))),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('— ${app.t(s.$3)}',
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF6E7280))),
                ),
              ],
            ),
          ),
          Divider(color: _stroke(context), height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, cons) {
                const gap = 14.0;
                final inner = cons.maxWidth - 56; // minus horizontal padding
                // Column count follows the window width: 1 / 2 / 3.
                final w = cons.maxWidth;
                final cols = w < 640 ? 1 : (w < 1024 ? 2 : 3);
                final cards = _cardsFor(app);
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
                  // True masonry: cards stack tightly per column instead of the
                  // old paired-row Wrap, which left a big gap whenever two
                  // side-by-side cards had very different heights (or one
                  // collapsed to nothing, e.g. the GPU-only cards).
                  child: _cardMasonry(cards, cols, gap, inner),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Masonry for the settings cards. Columns stack independently (no paired-row
  // gaps that a tall card or a collapsed GPU-only card used to open); `full`
  // cards break the columns and span the whole row. [cols] comes from the
  // window width, so the same builder serves the 1/2/3-column layouts.
  Widget _cardMasonry(
      List<_CardSpec> cards, int cols, double gap, double inner) {
    if (cols <= 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            cards[i].child,
          ],
        ],
      );
    }
    final colW = (inner - gap * (cols - 1)) / cols;
    final blocks = <Widget>[];
    var columns = List.generate(cols, (_) => <Widget>[]);
    var next = 0;
    void flush() {
      if (columns.every((c) => c.isEmpty)) return;
      blocks.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < cols; i++) ...[
            if (i > 0) SizedBox(width: gap),
            SizedBox(
                width: colW,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: columns[i])),
          ],
        ],
      ));
      columns = List.generate(cols, (_) => <Widget>[]);
      next = 0;
    }

    for (final c in cards) {
      if (c.full) {
        flush();
        blocks.add(SizedBox(width: inner, child: c.child));
        continue;
      }
      final col = columns[next];
      if (col.isNotEmpty) col.add(SizedBox(height: gap));
      col.add(c.child);
      next = (next + 1) % cols;
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < blocks.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          blocks[i],
        ],
      ],
    );
  }

  List<_CardSpec> _cardsFor(AppState app) {
    switch (_section) {
      case 0:
        return _generalCards(app);
      case 1:
        return _voiceInputCards(app);
      case 2:
        return _widgetsCards(app);
      case 3:
        return _voiceCommandCards(app);
      case 4:
        return _remoteInputCards(app);
      case 5:
        return _modelCards(app);
      case 6:
        return _personaCards(app);
      case 7:
        return _privacyCards(app);
      case 8:
        return _aboutCards(app);
      default:
        return const [];
    }
  }

  // =================== SECTION 4: REMOTE INPUT (PHONES) ===================
  List<_CardSpec> _remoteInputCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.wifi_tethering,
            title: app.t('remoteCardListener'),
            rows: [_RemoteInputPanel(app)]),
        full: true,
      ),
    ];
  }

  // =================== SECTION 0: GENERAL ===================
  List<_CardSpec> _generalCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.language,
        title: app.t('cardLangLoc'),
        rows: [
          evsRow(context, 
            stacked: true,
            label: app.t('interfaceLanguage'),
            desc: app.t('interfaceLanguageDesc'),
            control: evsSegmentedWide<String>(context, 
              const [('ru', 'RU'), ('en', 'EN')],
              app.lang,
              (v) => app.setLang(v),
            ),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('recognitionLanguage'),
            desc: app.t('recognitionLanguageDesc'),
            control: evsSegmentedWide<String>(context, 
              [('auto', app.t('sttAuto')), ('ru', 'RU'), ('en', 'EN')],
              app.sttLanguage,
              (v) => app.setSttLanguage(v),
            ),
          ),
        ],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.light_mode_outlined,
        title: app.t('cardAppearance'),
        rows: [
          evsRow(context, 
            stacked: true,
            label: app.t('themeMode'),
            control: evsSegmentedWide<AppThemeMode>(context, 
              [
                (AppThemeMode.dark, app.t('themeDark')),
                (AppThemeMode.claude, app.t('themeClaude')),
                (AppThemeMode.claudeDark, app.t('themeClaudeDark')),
              ],
              app.themeMode,
              (v) => app.setThemeMode(v),
            ),
          ),
          evsRow(context, 
            label: app.t('fontSize'),
            desc: app.t('fontSizeDesc'),
            control: SizedBox(
              width: 200,
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      min: 0.75,
                      max: 1.5,
                      value: app.fontSize.clamp(0.75, 1.5),
                      activeColor: _accent(context),
                      onChanged: (v) => app.setFontSize(v),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text('${(app.fontSize * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _accent(context))),
                  ),
                ],
              ),
            ),
          ),
        ],
      )),
      _CardSpec(
        evsCard(
          context,
          icon: Icons.desktop_windows_outlined,
          title: app.t('cardStartup'),
          rows: [
            evsRow(context, 
              label: app.t('autostart'),
              desc: app.t('autostartDesc'),
              control: evsToggle(context, app.autostart, (v) {
                app.setAutostart(v);
                DesktopIntegration.instance.applyAutostart(v);
              }),
            ),
            evsRow(context, 
              label: app.t('minimizeToTray'),
              desc: app.t('minimizeToTrayDesc'),
              control:
                  evsToggle(context, app.minimizeToTray, (v) => app.setMinimizeToTray(v)),
            ),
            evsRow(context, 
              label: app.t('closeToTray'),
              desc: app.t('closeToTrayDesc'),
              control: evsToggle(context, app.closeToTray, (v) => app.setCloseToTray(v)),
            ),
            evsRow(context, 
              label: app.t('globalHotkey'),
              desc: app.t('globalHotkeyDesc'),
              control: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _KeyCap('Ctrl'),
                  _KeySep(),
                  _KeyCap('Shift'),
                  _KeySep(),
                  _KeyCap('Space'),
                ],
              ),
            ),
          ],
        ),
        full: true,
      ),
    ];
  }

  Widget _stubToggle(String key) => evsToggle(context, 
        _stub[key] ?? false,
        (v) => setState(() => _stub[key] = v),
      );

  void _stubSnack(AppState app) =>
      showAppSnackBar(context, app.t('sectionStub'));

  Widget _sidecarChip(AppState app, SidecarStatus s) {
    final (label, color) = switch (s) {
      SidecarStatus.connected => (
          '${app.t('sidecarConnected')}'
              '${SidecarClient.instance.sttAvailable ? ' · ${app.sttSidecarEngine == 'gigaam' ? app.t('engGigaamName') : app.t('engWhisperName')}' : ''}',
          _success(context)
        ),
      SidecarStatus.starting => (app.t('sidecarStarting'), _warn(context)),
      SidecarStatus.stopped => (app.t('sidecarStopped'), _danger(context)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 7),
          // Flexible + ellipsis so a long "Подключён · GigaAM-v3" degrades
          // gracefully in the narrow 3-column layout instead of hard-clipping
          // past the card edge (it still shows in full at 1–2 columns).
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _compBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
      );

  // Download/status control for the Python sidecar component (on-demand, not
  // bundled). Shows a download button when absent, progress while fetching,
  // and "installed" once present / the sidecar is connected.
  Widget _sidecarComponentControl(AppState app) {
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (_, ss, __) => ValueListenableBuilder<ComponentStatus>(
        valueListenable: ComponentManager.instance.statusOf('sidecar'),
        builder: (_, cs, __) {
          if (ss == SidecarStatus.connected) {
            return _compBadge(app.t('componentReady'), _success(context));
          }
          switch (cs.state) {
            case ComponentState.downloading:
              return SizedBox(
                width: 160,
                child: Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                      child: LinearProgressIndicator(
                        value: cs.progress > 0 ? cs.progress : null,
                        minHeight: 6,
                        backgroundColor: _stroke(context),
                        valueColor: const AlwaysStoppedAnimation(_evsGMid),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(cs.progress * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6E7280))),
                ]),
              );
            case ComponentState.verifying:
              return _compBadge(app.t('componentVerifying'), _warn(context));
            case ComponentState.ready:
              return _compBadge(
                  app.t('componentReady'), _success(context));
            case ComponentState.error:
              return evsGhostButton(context, app.t('retry'), Icons.refresh,
                  onTap: () => _downloadSidecar(app));
            case ComponentState.absent:
              final info = ComponentManager.instance.infoOf('sidecar');
              final mb = info != null && info.size > 0
                  ? ' (${(info.size / 1048576).round()} MB)'
                  : '';
              return evsGhostButton(context, '${app.t('download')}$mb', Icons.download,
                  onTap: () => _downloadSidecar(app));
          }
        },
      ),
    );
  }

  Future<void> _downloadSidecar(AppState app) async {
    final p = await ComponentManager.instance.ensure('sidecar');
    if (p != null) await SidecarClient.instance.start();
  }

  // In-app update flow control: check → silent download progress → "restart".
  Widget _updateControl(AppState app) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: AppUpdater.instance.status,
      builder: (_, st, __) {
        switch (st) {
          case UpdateStatus.checking:
            return const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2));
          case UpdateStatus.downloading:
            return SizedBox(
              width: 160,
              child: ValueListenableBuilder<double>(
                valueListenable: AppUpdater.instance.progress,
                builder: (_, p, __) => Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                      child: LinearProgressIndicator(
                        value: p > 0 ? p : null,
                        minHeight: 6,
                        backgroundColor: _stroke(context),
                        valueColor: const AlwaysStoppedAnimation(_evsGMid),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(p * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6E7280))),
                ]),
              ),
            );
          case UpdateStatus.ready:
            return evsGhostButton(context, 
                '${app.t('updRestart')} · ${AppUpdater.instance.availableVersion}',
                Icons.restart_alt,
                onTap: () => AppUpdater.instance.applyAndRestart());
          case UpdateStatus.upToDate:
            return InkWell(
              onTap: () => AppUpdater.instance.checkAndDownload(),
              child: _compBadge(app.t('updUpToDate'), _success(context)),
            );
          case UpdateStatus.error:
            return evsGhostButton(context, app.t('retry'), Icons.refresh,
                onTap: () => AppUpdater.instance.checkAndDownload());
          case UpdateStatus.idle:
            return evsGhostButton(context, app.t('checkUpdate'), Icons.refresh,
                onTap: () => AppUpdater.instance.checkAndDownload());
        }
      },
    );
  }

  Widget _inlineField(TextEditingController c,
      {bool mono = false, int maxLines = 1, ValueChanged<String>? onChanged}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 13, vertical: maxLines > 1 ? 10 : 0),
      height: maxLines > 1 ? null : 36,
      alignment: maxLines > 1 ? null : Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.06),
        border: Border.all(color: _stroke(context)),
      ),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        onChanged: onChanged,
        style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: _body(context),
            fontFamily: mono ? 'monospace' : null),
        decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero),
      ),
    );
  }

  // Editable server address (and optional API key) for the local-server /
  // remote connection modes — writes straight to AppState.serverUrl/apiKey.
  Widget _serverField(AppState app, {required String hint, bool withKey = false}) {
    Widget field(TextEditingController c, String hintText,
        ValueChanged<String> onChanged) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: _overlayFill(context, 0.04),
          border: Border.all(color: _stroke(context)),
        ),
        child: TextField(
          controller: c,
          onChanged: onChanged,
          style: TextStyle(fontSize: 12.5, color: _body(context)),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: hintText,
            hintStyle: TextStyle(fontSize: 12.5, color: _faint(context)),
          ),
        ),
      );
    }

    Widget saveBtn() => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => app.saveCurrentServer(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _stroke(context)),
              color: _stroke(context),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.bookmark_add_outlined,
                  size: 14, color: _sub(context)),
              const SizedBox(width: 5),
              Text(app.t('saveServerBtn'),
                  style: TextStyle(
                      fontSize: 11.5,
                      color: _sub(context),
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        );

    Widget chip(String s) {
      final active = s == app.serverUrl.trim();
      final accent = _accent(context);
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            _serverCtrl.text = s;
            app.selectSavedServer(s);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(11, 5, 6, 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: active
                  ? accent.withValues(alpha: 0.16)
                  : _overlayFill(context, 0.04),
              border: Border.all(
                  color: active ? accent.withValues(alpha: 0.5) : _stroke(context)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(s,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: active ? accent : _sub(context),
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 5),
              InkWell(
                onTap: () => app.removeSavedServer(s),
                borderRadius: BorderRadius.circular(10),
                child: const Icon(Icons.close,
                    size: 13, color: Color(0xFF7A8090)),
              ),
            ]),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(_serverCtrl, hint, (v) => app.setServer(v, app.apiKey)),
        if (withKey) ...[
          const SizedBox(height: 6),
          field(_apiKeyCtrl, app.t('apiKeyHint'),
              (v) => app.setServer(app.serverUrl, v)),
        ],
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: saveBtn()),
        if (app.savedServers.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final s in app.savedServers) chip(s)],
          ),
        ],
      ],
    );
  }

  // =================== SECTION 2: VOICE COMMANDS ===================
  List<_CardSpec> _voiceCommandCards(AppState app) {
    final cmds = app.voiceCommands;
    return [
      _CardSpec(
        evsCard(context, icon: Icons.bolt_outlined, title: app.t('cardCmdExec'), rows: [
          evsRow(context, 
            label: app.t('cmdAllow'),
            desc: app.t('cmdAllowDesc'),
            control: evsToggle(context, app.cmdEnabled, app.setCmdEnabled),
          ),
          evsRow(context, 
            label: app.t('chatToggle'),
            desc: app.t('chatToggleDesc'),
            control: evsToggle(context, app.chatEnabled, app.setChatEnabled),
          ),
        ]),
        full: true,
      ),
      _CardSpec(evsCard(context,
          icon: Icons.schedule, title: app.t('cardCmdRecognition'), rows: [
        evsRow(context, 
          stacked: true,
          label: app.t('cmdMode'),
          desc: app.t('cmdModeDesc'),
          control: evsSegmentedWide<String>(context, [
            ('wakeword', app.t('cmdModeWake')),
            ('separate', app.t('cmdModeSeparate')),
            ('first', app.t('cmdModeFirst')),
          ], app.cmdMode, app.setCmdMode),
        ),
        evsRow(context, 
          label: app.t('cmdActivator'),
          desc: app.t('cmdActivatorDesc'),
          control: SizedBox(
              width: 110,
              child: _inlineField(_activatorCtrl,
                  mono: true, onChanged: (v) => app.setWakeWord(v))),
        ),
        evsRow(context, 
          stacked: true,
          label: app.t('cmdStopWords'),
          desc: app.t('cmdStopWordsDesc'),
          control: _inlineField(_stopWordsCtrl,
              onChanged: (v) => app.setStopWords(v)),
        ),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.shield_outlined, title: app.t('cardSecurity'), rows: [
        evsRow(context, 
          label: app.t('cmdThreshold'),
          desc: app.t('cmdThresholdDesc'),
          control: evsSlider(context, 
            value: app.cmdThreshold * 100,
            min: 0,
            max: 100,
            divisions: 20,
            label: '${(app.cmdThreshold * 100).round()}%',
            onChanged: (v) => app.setCmdThreshold(v / 100),
          ),
        ),
        evsRow(context, 
          stacked: true,
          label: app.t('cmdConfirm'),
          control: evsSegmentedWide<String>(context, [
            ('always', app.t('cmdConfirmAlways')),
            ('risky', app.t('cmdConfirmRisky')),
            ('never', app.t('cmdConfirmNever')),
          ], app.cmdConfirm, app.setCmdConfirm),
        ),
      ])),
      _CardSpec(
        evsCard(context,
            icon: Icons.format_list_bulleted, title: app.t('cardCatalog'), rows: [
          if (cmds.isEmpty)
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text(app.t('cmdEmpty'),
                  style: const TextStyle(fontSize: 13, color: Color(0xFF6E7280))),
            ),
          for (final c in cmds) _cmdRow(app, c),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                evsAddButton(context, app.t('cmdAdd'), () => _openAddCommandWizard(app)),
                InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => _openSuggestCommands(app),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: _accent(context).withValues(alpha: 0.2)),
                      color: _accent(context).withValues(alpha: 0.1),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_awesome,
                          size: 14, color: _accent(context)),
                      const SizedBox(width: 6),
                      Text(app.t('cmdSuggest'),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _accent(context))),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ]),
        full: true,
      ),
    ];
  }

  Widget _cmdRow(AppState app, VoiceCommand c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context)))),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Row(children: [
                Flexible(
                  child: Text(c.phrase,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _body(context))),
                ),
                if (c.speakPhrase.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: c.speakPhrase,
                      child: const Icon(Icons.volume_up_outlined,
                          size: 13, color: Color(0xFF7A8090)),
                    ),
                  ),
              ])),
          Expanded(
              flex: 2,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: _cmdTypeChip(app, c.type))),
          Expanded(
              flex: 3,
              child: Text(c.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF6E7280)))),
          InkResponse(
            radius: 18,
            onTap: () => _runCommand(app, c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: _accent(context).withValues(alpha: 0.15)),
              child: Icon(Icons.play_arrow_rounded,
                  size: 15, color: _accent(context)),
            ),
          ),
          InkResponse(
            radius: 18,
            onTap: () => _openEditCommandWizard(app, c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: _overlayFill(context, 0.06)),
              child: Icon(Icons.edit_outlined,
                  size: 13, color: _sub(context)),
            ),
          ),
          InkResponse(
            radius: 18,
            onTap: () => app.removeVoiceCommand(c),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0x14E05D5D)),
              child: const Icon(Icons.delete_outline,
                  size: 13, color: Color(0xFFE08080)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runCommand(AppState app, VoiceCommand c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: _card2(context),
        title: Text(app.t('cmdRunTitle'),
            style: TextStyle(color: _txt(context), fontSize: 16)),
        content: Text('${c.phrase}\n${c.value}',
            style: TextStyle(color: _body(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(app.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(app.t('run'))),
        ],
      ),
    );
    if (ok != true) return;
    // A test-run has no utterance, so app-volume uses the command's default
    // value; it also reports its own outcome (e.g. app not playing).
    if (c.type == VoiceCommandType.appVolume) {
      final (_, say) = await app.applyAppVolume(c, '');
      if (!mounted) return;
      showAppSnackBar(context, say);
      return;
    }
    final success = await CommandExecutor.instance.execute(c);
    if (!mounted) return;
    showAppSnackBar(context, success ? app.t('cmdRunOk') : app.t('cmdRunFail'));
  }

  Widget _cmdTypeChip(AppState app, VoiceCommandType t) {
    final (label, color) = switch (t) {
      VoiceCommandType.app => (app.t('typeApp'), _accent(context)),
      VoiceCommandType.file => (app.t('typeFile'), _info(context)),
      VoiceCommandType.url => (app.t('typeWeb'), _success(context)),
      VoiceCommandType.shell => ('Shell', _warn(context)),
      VoiceCommandType.system => (app.t('typeSystem'), _danger(context)),
      VoiceCommandType.media => (app.t('typeMedia'), _warn(context)),
      VoiceCommandType.appVolume => (app.t('typeAppVolume'), _info(context)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Future<void> _openAddCommandWizard(AppState app) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app),
    );
    if (cmd != null) app.addVoiceCommand(cmd);
  }

  Widget _presetChip(AppState app, String id, String nameKey, String descKey,
      IconData icon) {
    return Tooltip(
      message: app.t(descKey),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          app.applyVoicePreset(id);
          showAppSnackBar(context,
              app.t('presetApplied').replaceAll('{name}', app.t(nameKey)));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _overlayFill(context, 0.05),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: _accent(context)),
            const SizedBox(width: 7),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(app.t(nameKey),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _body(context))),
                Text(app.t(descKey),
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFF6E7280))),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _openSuggestCommands(AppState app) async {
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _SuggestCommandsDialog(app),
    );
    if (n != null && n > 0 && mounted) {
      showAppSnackBar(
          context, app.t('cmdSuggestSaved').replaceAll('{n}', '$n'));
    }
  }

  Future<void> _openEditCommandWizard(AppState app, VoiceCommand existing) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app, initial: existing),
    );
    if (cmd != null) app.replaceVoiceCommand(existing, cmd);
  }

  // =================== SECTION 2: WIDGETS ===================
  // Look of the voice visualization (adapted from the user-provided
  // widgets-settings mock): live preview with a voice simulation, style
  // tiles, per-style parameters, plus the floating-overlay controls.
  List<_CardSpec> _widgetsCards(AppState app) {
    final accent = Color(app.vizAccent);
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.auto_awesome_outlined,
            title: app.t('cardWsPreview'),
            rows: [const _VizPreviewCard()]),
        full: true,
      ),
      _CardSpec(
        evsCard(context,
            icon: Icons.style_outlined,
            title: app.t('cardWsStyle'),
            rows: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (key, label) in [
                      ('sphere', app.t('vizSphere')),
                      ('waves', app.t('vizWaves')),
                      ('bars', app.t('vizBars')),
                      ('orb', app.t('vizOrb')),
                      ('lkbars', app.t('vizLkBars')),
                      ('wave3d', app.t('vizWave3d')),
                      ('waveflat', app.t('vizWaveFlat')),
                      ('none', app.t('vizNone')),
                    ])
                      _VizStyleTile(
                        label: label,
                        selected: app.vizType == key,
                        accent: accent,
                        preview: _vizMini(key, accent),
                        onTap: () => app.setVizType(key),
                      ),
                  ],
                ),
              ),
            ]),
        full: true,
      ),
      _CardSpec(evsCard(context,
          icon: Icons.tune, title: app.t('cardWsParams'), rows: [
        evsRow(context, 
          label: app.t('wsAccent'),
          desc: app.t('wsAccentDesc'),
          control: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final c in const [
              0xFFCC785C,
              0xFF4FC3F7,
              0xFFFF5FA8,
              0xFF34D399,
              0xFFFFB020,
              0xFFF04E4E,
            ])
              GestureDetector(
                onTap: () => app.setVizAccent(c),
                child: Container(
                  margin: const EdgeInsets.only(left: 9),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: app.vizAccent == c
                            ? _txt(context)
                            : Colors.transparent,
                        width: 2),
                    boxShadow: app.vizAccent == c
                        ? [
                            BoxShadow(
                                color: Color(c).withValues(alpha: 0.45),
                                blurRadius: 8)
                          ]
                        : null,
                  ),
                ),
              ),
          ]),
        ),
        if (app.vizType == 'orb') ...[
          evsNamedSlider(context, 
            label: app.t('wsOrbSize'),
            value: app.orbSize.clamp(120, 320),
            min: 120,
            max: 320,
            valueLabel: '${app.orbSize.round()} px',
            left: '120',
            right: '320',
            onChanged: (v) => app.setOrbSize(v),
          ),
          evsNamedSlider(context, 
            label: app.t('wsOrbSpeed'),
            desc: app.t('wsOrbSpeedDesc'),
            value: app.orbSpeed.clamp(6, 40),
            min: 6,
            max: 40,
            valueLabel: '${app.orbSpeed.round()} ${app.t('secShort')}',
            left: app.t('wsFast'),
            right: app.t('wsSlow'),
            onChanged: (v) => app.setOrbSpeed(v),
          ),
        ],
        if (app.vizType == 'lkbars')
          evsNamedSlider(context, 
            label: app.t('wsBarCount'),
            value: app.barCount.toDouble().clamp(3, 13),
            min: 3,
            max: 13,
            valueLabel: '${app.barCount}',
            left: '3',
            right: '13',
            onChanged: (v) => app.setBarCount(v.round()),
          ),
        evsRow(context, 
          label: app.t('showVizBg'),
          desc: app.t('showVizBgDesc'),
          control: evsToggle(context, app.showVizBg, app.setShowVizBg),
        ),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.picture_in_picture_alt_outlined,
          title: app.t('ovlEnter'),
          rows: [
            evsRow(context, 
              label: app.t('ovlShow'),
              desc: app.t('ovlEnterDesc'),
              control: evsToggle(context, app.overlayMode, app.setOverlayMode),
            ),
            evsRow(context, 
              stacked: true,
              label: app.t('ovlSize'),
              desc: app.t('ovlSizeDesc'),
              control: evsSegmentedWide<double>(context, [
                (200.0, app.t('ovlSizeS')),
                (260.0, app.t('ovlSizeM')),
                (330.0, app.t('ovlSizeL')),
              ], app.overlaySize, app.setOverlaySize),
            ),
          ])),
    ];
  }

  // Small static-ish thumbnail for a style tile.
  Widget _vizMini(String key, Color accent) {
    switch (key) {
      case 'waves':
        return const EvsRingViz(size: 52);
      case 'bars':
        return const EvsBarsViz(width: 62, height: 38);
      case 'orb':
        return SiriOrb(
            size: 48,
            level: 0.4,
            state: SiriOrbState.listening,
            colors: evsOrbColors(accent),
            glow: false);
      case 'lkbars':
        return LkBarVisualizer(
            level: 0.5,
            count: 5,
            color: accent,
            barWidth: 5,
            spacing: 3.5,
            minHeight: 5,
            maxHeight: 34);
      case 'wave3d':
        return const EvsWaveViz(
            kind: 'wave3d',
            size: 52,
            numCols: 46,
            numRows: 30,
            background: Color(0xFF060612));
      case 'waveflat':
        return const EvsWaveViz(
            kind: 'waveflat',
            size: 52,
            particleCount: 520,
            background: Color(0xFF04040A));
      case 'none':
        return const Icon(Icons.hide_source,
            size: 26, color: Color(0xFF6E7280));
      default:
        return ParticleSphere(
            size: 46,
            color: _accent(context),
            soundLevel: VoiceLevels.instance.tts);
    }
  }

  // =================== SECTION 3: MODEL & INFERENCE ===================
  // Desktop is remote-only by design: models come from a local server
  // (Ollama) or a remote API endpoint. On-device GGUF inference was removed
  // from the UI (the fllama engine code stays dormant in the codebase).
  List<_CardSpec> _modelCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context,
            icon: Icons.tune, title: app.t('cardPresets'), rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text(app.t('presetsDesc'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6E7280))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _presetChip(app, 'fast', 'presetFast', 'presetFastDesc',
                    Icons.bolt_outlined),
                _presetChip(app, 'quality', 'presetQuality', 'presetQualityDesc',
                    Icons.hd_outlined),
                _presetChip(app, 'search', 'presetSearch', 'presetSearchDesc',
                    Icons.travel_explore),
                _presetChip(app, 'chat', 'presetChat', 'presetChatDesc',
                    Icons.chat_bubble_outline),
              ],
            ),
          ),
        ]),
        full: true,
      ),
      _CardSpec(
        evsCard(context,
            icon: Icons.dns_outlined,
            title: app.t('cardModels'),
            rows: [_AssetModelsCard(app)]),
        full: true,
      ),
      _CardSpec(
        evsCard(context, icon: Icons.wifi, title: app.t('cardConnMode'), rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Column(
              children: [
                evsRadioCard(context, 
                  selected: app.inferenceMode == 'localServer',
                  title: app.t('modeLocalServer'),
                  desc: app.t('modeLocalServerDesc'),
                  onTap: () => app.setInferenceMode('localServer'),
                  extra: app.inferenceMode == 'localServer'
                      ? _serverField(app, hint: 'localhost:11434')
                      : null,
                ),
                const SizedBox(height: 8),
                evsRadioCard(context, 
                  selected: app.inferenceMode == 'remote',
                  title: app.t('modeRemote'),
                  desc: app.t('modeRemoteDesc'),
                  onTap: () => app.setInferenceMode('remote'),
                  extra: app.inferenceMode == 'remote'
                      ? _serverField(app,
                          hint: 'https://api.openai.com/v1', withKey: true)
                      : null,
                ),
              ],
            ),
          ),
          _ConnCheckRow(app),
        ]),
        full: true,
      ),
      _CardSpec(
        evsCard(context,
            icon: Icons.travel_explore,
            title: app.t('webSearch'),
            rows: [const _WebSearchCard()]),
        full: true,
      ),
      _CardSpec(evsCard(context,
          icon: Icons.memory, title: app.t('cardModelPick'), rows: [
        if (app.models.isEmpty)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text(app.t('noModelsYet'),
                style: const TextStyle(fontSize: 13, color: Color(0xFF6E7280))),
          ),
        for (final m in app.models)
          _modelRow(app, m, app.modelDisplayName(m, withSuffix: false), ''),
        _ConnCheckRow(app, showRefresh: true),
        if (app.models.isNotEmpty) _ModelModeCard(app),
        _LlmAdvancedCard(app),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.tune, title: app.t('cardGenParams'), rows: [
        evsNamedSlider(context, 
          label: 'Temperature',
          desc: app.t('temperatureDesc'),
          value: _stubNum['temp']!,
          min: 0,
          max: 2,
          valueLabel: _stubNum['temp']!.toStringAsFixed(2),
          left: '0.0',
          right: '2.0',
          onChanged: (v) => setState(() => _stubNum['temp'] = v),
        ),
        evsNamedSlider(context, 
          label: 'Top-p',
          desc: app.t('topPDesc'),
          value: _stubNum['topp']!,
          min: 0,
          max: 1,
          valueLabel: _stubNum['topp']!.toStringAsFixed(2),
          left: '0.0',
          right: '1.0',
          onChanged: (v) => setState(() => _stubNum['topp'] = v),
        ),
      ])),
    ];
  }

  Widget _modelRow(AppState app, String key, String name, String size) {
    final active = app.selectedModel == key;
    return InkWell(
      onTap: () => app.selectModel(key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _stroke(context)))),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? _accent(context) : Colors.transparent,
                border: Border.all(
                    color: active ? _accent(context) : const Color(0x33FFFFFF),
                    width: 2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(name,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: _body(context))),
            ),
            if (size.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: _overlayFill(context, 0.06)),
                child: Text(size,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _sectionLabel(context))),
              ),
            const SizedBox(width: 8),
            Text(active ? app.t('modelActive') : '',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: _accent(context))),
          ],
        ),
      ),
    );
  }

  // =================== SECTION 4: PERSONALITY & MEMORY ===================
  List<_CardSpec> _personaCards(AppState app) {
    final p = app.persona;
    String pct(double v) => '${(v * 100).round()}%';
    return [
      _CardSpec(evsCard(context,
          icon: Icons.chat_bubble_outline, title: app.t('cardStyle'), rows: [
        evsNamedSlider(context, 
          label: app.t('formality'),
          value: p.formality,
          valueLabel: pct(p.formality),
          left: app.t('formalLeft'),
          right: app.t('formalRight'),
          onChanged: (v) => _persona((x) => x.formality = v),
        ),
        evsNamedSlider(context, 
          label: app.t('empathy'),
          value: p.empathy,
          valueLabel: pct(p.empathy),
          left: app.t('empathyLeft'),
          right: app.t('empathyRight'),
          onChanged: (v) => _persona((x) => x.empathy = v),
        ),
        evsNamedSlider(context, 
          label: app.t('verbosity'),
          value: p.verbosity,
          valueLabel: pct(p.verbosity),
          left: app.t('verbosityLeft'),
          right: app.t('verbosityRight'),
          onChanged: (v) => _persona((x) => x.verbosity = v),
        ),
        evsNamedSlider(context, 
          label: app.t('humor'),
          value: p.humor,
          valueLabel: pct(p.humor),
          left: app.t('humorLeft'),
          right: app.t('humorRight'),
          onChanged: (v) => _persona((x) => x.humor = v),
        ),
        evsNamedSlider(context, 
          label: app.t('creativity'),
          value: p.creativity,
          valueLabel: pct(p.creativity),
          left: app.t('creativityLeft'),
          right: app.t('creativityRight'),
          onChanged: (v) => _persona((x) => x.creativity = v),
        ),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.person_outline, title: app.t('cardAssistant'), rows: [
        evsRow(context, 
          label: app.t('assistantNameLabel'),
          desc: app.t('assistantNameDesc'),
          control: SizedBox(
            width: 130,
            child: _inlineField(_nameCtrl,
                mono: true,
                onChanged: (v) => _persona((x) => x.assistantName = v)),
          ),
        ),
        evsRow(context, 
          stacked: true,
          label: app.t('emojiPolicy'),
          desc: app.t('emojiPolicyDesc'),
          control: evsSegmentedWide<String>(context, 
            [
              ('emoji_never', app.t('emojiNever')),
              ('emoji_sometimes', app.t('emojiSometimes')),
              ('emoji_always', app.t('emojiAlways')),
            ],
            p.emoji,
            (v) => _persona((x) => x.emoji = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.t('systemPrompt'),
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
              const SizedBox(height: 2),
              Text(app.t('systemPromptDesc'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6E7280))),
              const SizedBox(height: 8),
              _inlineField(_promptCtrl,
                  maxLines: 3,
                  onChanged: (v) => _persona((x) => x.customPrompt = v)),
            ],
          ),
        ),
      ])),
      _CardSpec(
        evsCard(context, icon: Icons.access_time, title: app.t('cardMemory'), rows: [
          evsRow(context, 
            label: app.t('autoSaveFacts'),
            desc: app.t('autoSaveFactsDesc'),
            control: evsToggle(context, 
                p.autoSaveMemories, (v) => _persona((x) => x.autoSaveMemories = v)),
          ),
          evsRow(context, 
            label: app.t('askBeforeRemember'),
            desc: app.t('askBeforeRememberDesc'),
            control: evsToggle(context, p.askBeforeRemembering,
                (v) => _persona((x) => x.askBeforeRemembering = v)),
          ),
          for (final m in p.savedMemories) _memItem(app, m),
          if (p.savedMemories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: evsDangerButton(context, app.t('clearMemory'),
                    () => _persona((x) => x.savedMemories.clear())),
              ),
            ),
        ]),
        full: true,
      ),
    ];
  }

  Widget _memItem(AppState app, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context)))),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _accent(context).withValues(alpha: 0.12)),
            child: Icon(Icons.place_outlined, size: 12, color: _accent(context)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: _body(context))),
          ),
          InkResponse(
            radius: 16,
            onTap: () => _persona((x) => x.savedMemories.remove(text)),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  color: const Color(0x14E05D5D)),
              child: const Icon(Icons.close, size: 11, color: Color(0xFFE08080)),
            ),
          ),
        ],
      ),
    );
  }

  // =================== SECTION 5: PRIVACY ===================
  List<_CardSpec> _privacyCards(AppState app) {
    return [
      _CardSpec(evsCard(context,
          icon: Icons.shield_outlined, title: app.t('cardCmdScope'), rows: [
        _permGrid(app, [
          ('permFiles', app.t('permFiles')),
          ('permBrowser', app.t('permBrowser')),
          ('permMedia', app.t('permMedia')),
          ('permSystem', app.t('permSystem')),
          ('permNetwork', app.t('permNetwork')),
          ('permRegistry', app.t('permRegistry')),
        ]),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.dns_outlined, title: app.t('cardNetSec'), rows: [
        evsRow(context, 
            label: app.t('offlineMode'),
            desc: app.t('offlineModeDesc'),
            control: _stubToggle('offline')),
        evsRow(context, 
            label: app.t('noTelemetry'),
            desc: app.t('noTelemetryDesc'),
            control: _stubToggle('noTelemetry')),
        evsRow(context, 
            label: app.t('noModelNet'),
            desc: app.t('noModelNetDesc'),
            control: _stubToggle('noModelNet')),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.warning_amber_outlined, title: app.t('cardBlacklist'), rows: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _blacklist) _tag(t),
              evsAddButton(context, app.t('add'),
                  () => _stubSnack(app), small: true),
            ],
          ),
        ),
      ])),
      _CardSpec(
        evsCard(context, icon: Icons.delete_outline, title: app.t('cardData'), rows: [
          evsRow(context, 
            label: app.t('clearHistory'),
            desc: app.t('clearHistoryDesc'),
            control: evsDangerButton(context, app.t('clearHistory'), () => _stubSnack(app)),
          ),
          evsRow(context, 
            label: app.t('resetMemory'),
            desc: app.t('resetMemoryDesc'),
            control: evsDangerButton(context, app.t('resetMemory'), () {
              _persona((x) {
                x.savedMemories.clear();
                x.memoryNote = '';
              });
            }),
          ),
          evsRow(context, 
            label: app.t('resetAll'),
            desc: app.t('resetAllDesc'),
            control: evsDangerButton(context, app.t('fullReset'), () => _stubSnack(app)),
          ),
        ]),
        full: true,
      ),
    ];
  }

  Widget _permGrid(AppState app, List<(String, String)> items) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        // Two columns that always fit the card; one column on a very narrow pane.
        final w = cons.maxWidth < 360 ? cons.maxWidth : cons.maxWidth / 2;
        return Wrap(
          children: [
            for (final it in items)
              SizedBox(
                width: w,
                child: InkWell(
                  onTap: () => setState(
                      () => _stub[it.$1] = !(_stub[it.$1] ?? false)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: (_stub[it.$1] ?? false)
                                ? _accent(context).withValues(alpha: 0.3)
                                : Colors.transparent,
                            border: Border.all(
                                color: _accent(context).withValues(alpha: 0.4), width: 2),
                          ),
                          child: (_stub[it.$1] ?? false)
                              ? Icon(Icons.check,
                                  size: 12, color: _accent(context))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(it.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: _body(context))),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: _overlayFill(context, 0.06),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _sub(context))),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _blacklist.remove(text)),
            child: Icon(Icons.close, size: 13, color: _faint(context)),
          ),
        ],
      ),
    );
  }

  // =================== SECTION 6: ABOUT ===================
  List<_CardSpec> _aboutCards(AppState app) {
    return [
      _CardSpec(
        evsCard(context, icon: Icons.info_outline, title: app.t('navAbout'), rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
            child: Column(
              children: [
                const _EvsLogoMark(size: 60),
                const SizedBox(height: 10),
                Text('EVS',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: _txt(context))),
                const SizedBox(height: 4),
                const Text('Enhanced Voice System',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6E7280))),
              ],
            ),
          ),
          _aboutRow(app.t('versionLabel'), const _VersionText()),
          _aboutRow(app.t('platform'), Text('Windows · x64',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: _body(context)))),
        ]),
        full: true,
      ),
      _CardSpec(evsCard(context,
          icon: Icons.description_outlined, title: app.t('changelog'), rows: [
        for (final e in kChangelog.take(3)) _clItem(e),
      ])),
      _CardSpec(evsCard(context,
          icon: Icons.refresh, title: app.t('updates'), rows: [
        evsRow(context, 
            label: app.t('autoCheck'),
            desc: app.t('autoCheckDesc'),
            control: evsToggle(context, app.autoUpdateCheck, app.setAutoUpdateCheck)),
        evsRow(context, 
            label: app.t('checkNow'),
            desc: app.t('updFlowDesc'),
            control: _updateControl(app)),
      ])),
    ];
  }

  Widget _aboutRow(String label, Widget value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: _stroke(context)))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _body(context))),
          value,
        ],
      ),
    );
  }

  Widget _clItem(ChangelogEntry e) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.version,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: _body(context))),
          const SizedBox(height: 5),
          for (final ch in e.changes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('·  $ch',
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.5, color: Color(0xFF6E7280))),
            ),
        ],
      ),
    );
  }


  // =================== SECTION 1: VOICE INPUT ===================
  List<_CardSpec> _voiceInputCards(AppState app) {
    return [
      _CardSpec(evsCard(
        context,
        icon: Icons.mic_none,
        title: app.t('cardStt'),
        rows: [
          evsRow(context, 
            label: app.t('sidecar'),
            desc: app.t('sidecarDesc'),
            control: ValueListenableBuilder<SidecarStatus>(
              valueListenable: SidecarClient.instance.status,
              builder: (_, s, __) => _sidecarChip(app, s),
            ),
          ),
          evsRow(context, 
            label: app.t('sidecarComponent'),
            desc: app.t('sidecarComponentDesc'),
            control: _sidecarComponentControl(app),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('sttEngine'),
            desc: app.t('sttEngineDesc'),
            control: evsSegmentedWide<String>(context, 
              [('windows', 'Windows STT'), ('whisper', app.t('localEngineName'))],
              app.sttEngine,
              (v) => app.setSttEngine(v),
            ),
          ),
          // The local engine (whisper|gigaam) picker only applies to the local
          // backend — hidden when Windows STT is chosen so GigaAM/Whisper aren't
          // shown as "models" under an unrelated engine.
          if (app.sttEngine == 'whisper') ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(app.t('cardSttModel'),
                  style: TextStyle(
                      color: _body(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
            _SttEngineCards(app),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(app.t('cardDenoise'),
                style: TextStyle(
                    color: _body(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
          _DenoiseSelector(app),
          evsRow(context, 
            stacked: true,
            label: app.t('recognitionLanguage'),
            desc: app.t('recognitionLanguageDesc'),
            control: evsSegmentedWide<String>(context, 
              [('auto', app.t('sttAuto')), ('ru', 'RU'), ('en', 'EN')],
              app.sttLanguage,
              (v) => app.setSttLanguage(v),
            ),
          ),
          // Recognition test lives inside the STT card (was a separate
          // full-width card, which broke the 2-column grid packing and made
          // the section jump).
          const _SttTestCard(),
        ],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.settings_voice_outlined,
        title: app.t('cardInputDevice'),
        rows: [
          evsRow(context, 
            label: app.t('inputDevice'),
            desc: app.t('inputDeviceDesc'),
            control: _inputDeviceControl(app),
          ),
          evsRow(context, 
            label: app.t('inputLevel'),
            control: SizedBox(
              width: 180,
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(3)),
                child: ValueListenableBuilder<double>(
                  valueListenable: MicMeter.instance.level,
                  builder: (_, lvl, __) => LinearProgressIndicator(
                    value: lvl.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: _stroke(context),
                    valueColor: const AlwaysStoppedAnimation(_evsGMid),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Text(app.t('extraMics'),
                style: TextStyle(
                    color: _body(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
            child: Text(app.t('extraMicsDesc'),
                style: const TextStyle(color: Color(0xFF6E7280), fontSize: 12)),
          ),
          _MultiMicCard(app),
        ],
      )),
      _CardSpec(_GameModeCard(app)),
      _CardSpec(evsCard(
        context,
        icon: Icons.headset_mic_outlined,
        title: app.t('cardListenMode'),
        rows: [
          evsRow(context, 
            stacked: true,
            label: app.t('activationMode'),
            desc: app.t('activationModeDesc'),
            control: evsSegmentedWide<String>(context, 
              [('continuous', app.t('continuous')), ('ptt', 'Push-to-Talk')],
              app.listenMode,
              (v) => app.setListenMode(v),
            ),
          ),
          evsRow(context, 
            label: app.t('autoSendPause'),
            desc: app.t('autoSendPauseDesc'),
            control: evsToggle(context, app.micAutoSend, (v) => app.setMicAutoSend(v)),
          ),
          evsRow(context, 
            label: app.t('pauseDuration'),
            desc: app.t('pauseDurationDesc'),
            control: evsSlider(context, 
              value: app.micPauseSeconds.toDouble().clamp(1, 10),
              min: 1,
              max: 10,
              divisions: 9,
              label: '${app.micPauseSeconds} ${app.t('secShort')}',
              onChanged: (v) => app.setMicPauseSeconds(v.round()),
            ),
          ),
          evsRow(context, 
            label: app.t('showPartial'),
            desc: app.t('showPartialDesc'),
            control: evsToggle(context, app.showPartial, app.setShowPartial),
          ),
        ],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.record_voice_over_outlined,
        title: app.t('cardVoiceResp'),
        rows: [
          evsRow(context, 
            label: app.t('voiceResponses'),
            desc: app.t('voiceResponsesDesc'),
            control: evsToggle(context, app.voiceResponses, app.setVoiceResponses),
          ),
          evsRow(context, 
            label: app.t('announceReady'),
            desc: app.t('announceReadyDesc'),
            control: evsToggle(context, app.announceReady, app.setAnnounceReady),
          ),
          _TtsEngineCard(app),
          _TtsInterpCard(app),
          evsRow(context, 
            label: app.t('ttsRate'),
            desc: app.t('ttsRateDesc'),
            control: evsSlider(context, 
              value: app.ttsRate.clamp(0.5, 2.0),
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${app.ttsRate.toStringAsFixed(1)}x',
              onChanged: (v) => app.setTtsRate(v),
            ),
          ),
          evsRow(context, 
            label: app.t('ttsVolume'),
            control: evsSlider(context, 
              value: (app.ttsVolume * 100).clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 20,
              label: '${(app.ttsVolume * 100).round()}%',
              onChanged: (v) => app.setTtsVolume(v / 100),
            ),
          ),
        ],
      )),
      _CardSpec(evsCard(
        context,
        icon: Icons.record_voice_over_outlined,
        title: app.t('cardAssistantVoice'),
        rows: [_AssistantVoiceCard(app)],
      )),
    ];
  }
}

// Explicit "is the server actually reachable" check with a visible verdict, and
// the manual model-list refresh. Both drive AppState.fetchModels(), which IS the
// GET /api/tags round-trip and already records the outcome (unreachable / no
// models found) — a second probe would just be another thing to keep in sync.
class _ConnCheckRow extends StatelessWidget {
  const _ConnCheckRow(this.app, {this.showRefresh = false});
  final AppState app;
  final bool showRefresh;

  @override
  Widget build(BuildContext context) {
    final hasUrl = app.serverUrl.trim().isNotEmpty;
    final busy = app.loadingModels;
    final err = app.modelsError;

    final (String text, Color color) = !hasUrl
        ? (app.t('connBadUrl'), _faint(context))
        : busy
            ? (app.t('connChecking'), _warn(context))
            : err != null
                ? (err, _danger(context))
                : app.models.isEmpty
                    ? ('', _faint(context))
                    : (
                        '${app.t('connOnline')} · ${app.models.length} ${app.t('connModelsCount')}',
                        _success(context)
                      );

    Widget btn(String label, IconData icon) => InkWell(
          borderRadius: BorderRadius.circular(8),
          // Without an address there is nothing to probe, so the button stays
          // inert rather than reporting a misleading failure.
          onTap: (!hasUrl || busy) ? null : () => app.fetchModels(),
          child: Opacity(
            opacity: (!hasUrl || busy) ? 0.45 : 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _stroke(context)),
                color: _stroke(context),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 14, color: _sub(context)),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _body(context))),
              ]),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      child: Row(
        children: [
          btn(app.t(showRefresh ? 'refreshModelsBtn' : 'checkConn'),
              showRefresh ? Icons.refresh : Icons.wifi_find),
          const SizedBox(width: 10),
          if (text.isNotEmpty)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: color)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(text,
                        style: TextStyle(fontSize: 12, color: color),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// TTS engine selector (settings TZ §3.2): Piper (offline, active) vs CosyVoice
// (GPU HTTP server). CosyVoice is only selectable once its endpoint answers a
// probe; the server isn't deployed yet, so it stays greyed with a note. The
// deeper CosyVoice controls (voice cloning, speed, emotion) come once the server
// exists and its API is known.
class _TtsEngineCard extends StatefulWidget {
  const _TtsEngineCard(this.app);
  final AppState app;
  @override
  State<_TtsEngineCard> createState() => _TtsEngineCardState();
}

class _TtsEngineCardState extends State<_TtsEngineCard> {
  late final TextEditingController _ep =
      TextEditingController(text: widget.app.cosyvoiceEndpoint);
  // CosyVoice deep-control text fields (§3.2).
  late final TextEditingController _voice =
      TextEditingController(text: widget.app.cosyvoiceVoice);
  late final TextEditingController _clonePrompt =
      TextEditingController(text: widget.app.cosyvoiceClonePromptText);
  late final TextEditingController _instruct =
      TextEditingController(text: widget.app.cosyvoiceInstruct);
  bool _checking = false;

  // Emotion presets → i18n label keys (map to instruct phrases once wired).
  static const List<(String, String)> _emotions = [
    ('neutral', 'ttsCosyEmotionNeutral'),
    ('happy', 'ttsCosyEmotionHappy'),
    ('sad', 'ttsCosyEmotionSad'),
    ('serious', 'ttsCosyEmotionSerious'),
    ('calm', 'ttsCosyEmotionCalm'),
    ('excited', 'ttsCosyEmotionExcited'),
  ];

  AppState get app => widget.app;

  Future<void> _pickCloneSample() async {
    final res = await FilePicker.pickFiles();
    final p = res?.files.single.path;
    if (p != null && p.isNotEmpty) app.setCosyvoiceClonePath(p);
  }

  @override
  void dispose() {
    _ep.dispose();
    _voice.dispose();
    _clonePrompt.dispose();
    _instruct.dispose();
    super.dispose();
  }

  Widget _engineChip(String id, String nameKey, String hintKey,
      {required bool enabled}) {
    final selected = app.ttsEngineChoice == id;
    return Expanded(
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? () => app.setTtsEngineChoice(id) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: selected
                  ? const Color(0x263A7BE0)
                  : _overlayFill(context, 0.04),
              border: Border.all(
                  color: selected ? _accent(context) : _stroke(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.t(nameKey),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _body(context))),
                Text(app.t(hintKey),
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF6E7280))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Emotion preset dropdown (§3.2 wireframe shows a "[ нейтральная ▾ ]" select).
  Widget _cosyEmotionDropdown() {
    final value =
        _emotions.any((e) => e.$1 == app.cosyvoiceEmotion) ? app.cosyvoiceEmotion : 'neutral';
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF1A1B25),
          style: TextStyle(fontSize: 12.5, color: _body(context)),
          icon: Icon(Icons.expand_more, size: 18, color: _sub(context)),
          items: [
            for (final e in _emotions)
              DropdownMenuItem(value: e.$1, child: Text(app.t(e.$2))),
          ],
          onChanged: (v) {
            if (v != null) app.setCosyvoiceEmotion(v);
          },
        ),
      ),
    );
  }

  // Deep CosyVoice controls (§3.2). UI + persisted state only — no synthesis
  // routing yet. Shown once an endpoint is entered so it can be configured
  // before the server is actually reachable.
  List<Widget> _cosyDeepControls() {
    final sc = SidecarClient.instance;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
        child: Text(app.t('ttsCosyWiringHint'),
            style: const TextStyle(fontSize: 11, color: Color(0xFF6E7280))),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyVoice'),
        desc: app.t('ttsCosyVoiceHint'),
        control:
            _RemoteField(controller: _voice, onChanged: app.setCosyvoiceVoice),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyClone'),
        control: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _pickCloneSample,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _stroke(context)),
                    color: _stroke(context),
                  ),
                  child: Text(app.t('ttsCosyClonePick'),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _body(context))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  app.cosyvoiceClonePath.isEmpty
                      ? app.t('ttsCosyCloneNone')
                      : app.cosyvoiceClonePath
                          .split(io.Platform.pathSeparator)
                          .last,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: _sub(context)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _RemoteField(
                controller: _clonePrompt,
                onChanged: app.setCosyvoiceClonePromptText),
            const SizedBox(height: 4),
            Text(app.t('ttsCosyClonePromptHint'),
                style: const TextStyle(fontSize: 11, color: Color(0xFF6E7280))),
          ],
        ),
      ),
      evsRow(context, 
        label: app.t('ttsCosySpeed'),
        control: evsSlider(context, 
          value: app.cosyvoiceSpeed.clamp(0.5, 2.0),
          min: 0.5,
          max: 2.0,
          divisions: 15,
          label: '${app.cosyvoiceSpeed.toStringAsFixed(1)}x',
          onChanged: app.setCosyvoiceSpeed,
        ),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyEmotion'),
        control: _cosyEmotionDropdown(),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyInstruct'),
        desc: app.t('ttsCosyInstructHint'),
        control: _RemoteField(
            controller: _instruct, onChanged: app.setCosyvoiceInstruct),
      ),
      evsRow(context, 
        stacked: true,
        label: app.t('ttsCosyDevice'),
        control: AnimatedBuilder(
          animation: sc.gpuInfo,
          builder: (context, _) {
            final name = sc.gpuInfo.value.$2;
            return evsSegmentedWide<String>(context, 
              [
                ('cpu', app.t('deviceCpu')),
                ('cuda', name.isNotEmpty ? 'GPU · $name' : app.t('deviceGpu')),
              ],
              app.cosyvoiceDevice,
              app.setCosyvoiceDevice,
            );
          },
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cosyOnline = app.cosyvoiceOnline == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Text(app.t('ttsEngineTitle'),
              style: TextStyle(
                  color: _body(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
          child: Row(children: [
            _engineChip('piper', 'ttsEnginePiper', 'ttsEnginePiperHint',
                enabled: true),
            const SizedBox(width: 8),
            _engineChip('cosyvoice', 'ttsEngineCosy', 'ttsEngineCosyHint',
                enabled: cosyOnline),
          ]),
        ),
        if (!cosyOnline)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Text(app.t('ttsCosyUnavailable'),
                style: TextStyle(fontSize: 11.5, color: _warn(context))),
          ),
        // Endpoint + check.
        evsRow(context, 
          stacked: true,
          label: app.t('ttsCosyEndpoint'),
          control: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RemoteField(
                controller: _ep,
                onChanged: app.setCosyvoiceEndpoint,
              ),
              const SizedBox(height: 8),
              Row(children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _checking
                      ? null
                      : () async {
                          setState(() => _checking = true);
                          await app.checkCosyvoice();
                          if (mounted) setState(() => _checking = false);
                        },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _stroke(context)),
                      color: _stroke(context),
                    ),
                    child: Text(
                        _checking ? app.t('ttsCosyChecking') : app.t('ttsCosyCheck'),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _body(context))),
                  ),
                ),
                const SizedBox(width: 10),
                if (app.cosyvoiceOnline != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: cosyOnline
                                ? _success(context)
                                : _danger(context))),
                    const SizedBox(width: 6),
                    Text(
                        cosyOnline
                            ? app.t('ttsCosyOnline')
                            : app.t('ttsCosyOffline'),
                        style: TextStyle(
                            fontSize: 12,
                            color: cosyOnline
                                ? _success(context)
                                : _danger(context))),
                  ]),
              ]),
            ],
          ),
        ),
        // Deep CosyVoice controls (§3.2) — voice/preset, clone-by-WAV sample,
        // speed, emotion, instruct and synthesis device. Always visible now so
        // the voice cloner is discoverable and can be configured up front (they
        // still only take effect once the CosyVoice server is reachable).
        ..._cosyDeepControls(),
      ],
    );
  }
}

// Voice interpreter controls (settings TZ §3.2): on/off, rules-vs-model, and
// the interpreter model name when "model" is chosen. Stateful only for the
// model-name field's controller.
class _TtsInterpCard extends StatefulWidget {
  const _TtsInterpCard(this.app);
  final AppState app;
  @override
  State<_TtsInterpCard> createState() => _TtsInterpCardState();
}

class _TtsInterpCardState extends State<_TtsInterpCard> {
  late final TextEditingController _model =
      TextEditingController(text: widget.app.ttsInterpModel);

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        evsRow(context, 
          label: app.t('ttsInterp'),
          desc: app.t('ttsInterpDesc'),
          control: evsToggle(context, app.ttsInterpEnabled, app.setTtsInterpEnabled),
        ),
        if (app.ttsInterpEnabled) ...[
          evsRow(context, 
            stacked: true,
            label: app.t('ttsInterpMode'),
            control: evsSegmentedWide<String>(context, 
              [
                ('rules', app.t('ttsInterpRules')),
                ('model', app.t('ttsInterpModel')),
              ],
              app.ttsInterpMode,
              (v) => app.setTtsInterpMode(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text(
              app.ttsInterpMode == 'model'
                  ? app.t('ttsInterpModelHint')
                  : app.t('ttsInterpRulesHint'),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6E7280)),
            ),
          ),
          if (app.ttsInterpMode == 'model')
            evsRow(context, 
              label: app.t('ttsInterpModelField'),
              control: SizedBox(
                width: 160,
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: _overlayFill(context, 0.04),
                    border: Border.all(color: _stroke(context)),
                  ),
                  child: TextField(
                    controller: _model,
                    onChanged: app.setTtsInterpModel,
                    style: TextStyle(
                        fontSize: 12.5, color: _body(context)),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: 'qwen3-interp',
                      hintStyle:
                          TextStyle(fontSize: 12.5, color: _faint(context)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

// Optional per-mode model override (search vs chat). Empty = follow the global
// selection, so leaving both alone reproduces the previous single-model
// behaviour. A stored value that is no longer advertised by the server is kept
// and flagged rather than silently swapped (settings TZ §12).
class _ModelModeCard extends StatelessWidget {
  const _ModelModeCard(this.app);
  final AppState app;

  Widget _picker(BuildContext context, String current,
      ValueChanged<String> onPick) {
    final missing = current.isNotEmpty && !app.models.contains(current);
    final label = current.isEmpty
        ? app.t('modelDefaultGlobal')
        : missing
            ? '$current  ⚠ ${app.t('modelNotOnServer')}'
            : app.modelDisplayName(current, withSuffix: false);
    return PopupMenuButton<String>(
      tooltip: '',
      color: _card(context),
      onSelected: onPick,
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: '',
          child: Text(app.t('modelDefaultGlobal'),
              style: TextStyle(color: _body(context), fontSize: 13)),
        ),
        // Keep a missing-but-selected value in the menu so it can be seen and
        // cleared instead of vanishing.
        if (missing)
          PopupMenuItem<String>(
            value: current,
            child: Text('$current  ⚠',
                style: TextStyle(color: _warn(context), fontSize: 13)),
          ),
        for (final m in app.models)
          PopupMenuItem<String>(
            value: m,
            child: Text(app.modelDisplayName(m, withSuffix: false),
                style: TextStyle(color: _body(context), fontSize: 13)),
          ),
      ],
      child: evsSelectButton(context, label, minWidth: 150),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.t('modelPerMode'),
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
              const SizedBox(height: 3),
              Text(app.t('modelPerModeDesc'),
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF6E7280))),
            ],
          ),
        ),
        evsRow(context, 
          label: app.t('modelForSearch'),
          control: _picker(context, app.searchModel, app.setSearchModel),
        ),
        evsRow(context, 
          label: app.t('modelForChat'),
          control: _picker(context, app.chatModel, app.setChatModel),
        ),
      ],
    );
  }
}

// Advanced Ollama request parameters, collapsed by default (progressive
// disclosure — the basics stay visible, this is opt-in). Every field is
// optional: clearing one drops the parameter from the request entirely rather
// than substituting a default, so the model keeps deciding.
class _LlmAdvancedCard extends StatefulWidget {
  const _LlmAdvancedCard(this.app);
  final AppState app;

  @override
  State<_LlmAdvancedCard> createState() => _LlmAdvancedCardState();
}

class _LlmAdvancedCardState extends State<_LlmAdvancedCard> {
  bool _open = false;
  late final TextEditingController _ctx =
      TextEditingController(text: widget.app.llmNumCtx?.toString() ?? '');
  late final TextEditingController _pred =
      TextEditingController(text: widget.app.llmNumPredict?.toString() ?? '');
  late final TextEditingController _temp =
      TextEditingController(text: widget.app.llmTemperature?.toString() ?? '');
  late final TextEditingController _ka =
      TextEditingController(text: widget.app.llmKeepAlive);
  String? _ctxErr;
  String? _predErr;
  String? _tempErr;

  @override
  void dispose() {
    _ctx.dispose();
    _pred.dispose();
    _temp.dispose();
    _ka.dispose();
    super.dispose();
  }

  // Blank clears the parameter; anything unparsable is reported and NOT saved,
  // so a typo can never reach the request as a silent zero.
  void _onInt(String raw, void Function(int?) save, void Function(String?) err) {
    final t = raw.trim();
    if (t.isEmpty) {
      err(null);
      save(null);
      return;
    }
    final v = int.tryParse(t);
    if (v == null || v <= 0) {
      err(widget.app.t('llmBadNumber'));
      return;
    }
    err(null);
    save(v);
  }

  void _onTemp(String raw) {
    final app = widget.app;
    final t = raw.trim();
    if (t.isEmpty) {
      setState(() => _tempErr = null);
      app.setLlmTemperature(null);
      return;
    }
    final v = double.tryParse(t.replaceAll(',', '.'));
    if (v == null) {
      setState(() => _tempErr = app.t('llmBadNumber'));
      return;
    }
    if (v < 0 || v > 1.5) {
      setState(() => _tempErr = app.t('llmTempRange'));
      return;
    }
    setState(() => _tempErr = null);
    app.setLlmTemperature(v);
  }

  Widget _field(TextEditingController c, ValueChanged<String> onChanged,
      {String? error}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _overlayFill(context, 0.04),
            border: Border.all(
                color: error == null ? _stroke(context) : const Color(0xFFF0685E)),
          ),
          child: TextField(
            controller: c,
            onChanged: onChanged,
            style: TextStyle(fontSize: 12.5, color: _body(context)),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: widget.app.t('llmDefaultHint'),
              hintStyle:
                  TextStyle(fontSize: 12.5, color: _faint(context)),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error,
                style:
                    const TextStyle(fontSize: 11, color: Color(0xFFF0685E))),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.t('cardLlmAdv'),
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: _body(context))),
                      const SizedBox(height: 3),
                      Text(app.t('llmAdvDesc'),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6E7280))),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: _sub(context)),
              ],
            ),
          ),
        ),
        if (_open) ...[
          evsRow(context, 
            label: app.t('llmNumCtx'),
            desc: app.t('llmNumCtxDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_ctx,
                  (v) => _onInt(v, app.setLlmNumCtx,
                      (e) => setState(() => _ctxErr = e)),
                  error: _ctxErr),
            ),
          ),
          evsRow(context, 
            label: app.t('llmNumPredict'),
            desc: app.t('llmNumPredictDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_pred,
                  (v) => _onInt(v, app.setLlmNumPredict,
                      (e) => setState(() => _predErr = e)),
                  error: _predErr),
            ),
          ),
          evsRow(context, 
            label: app.t('llmTemp'),
            desc: app.t('llmTempDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_temp, _onTemp, error: _tempErr),
            ),
          ),
          evsRow(context, 
            label: app.t('llmKeepAlive'),
            desc: app.t('llmKeepAliveDesc'),
            control: SizedBox(
              width: 120,
              child: _field(_ka, (v) => app.setLlmKeepAlive(v.trim())),
            ),
          ),
        ],
      ],
    );
  }
}

/* ---- shared desktop-settings building blocks (mockup styling) ---- */

Widget evsCard(
  BuildContext context, {
  required IconData icon,
  required String title,
  required List<Widget> rows,
}) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: EvsRadius.rLg,
      color: _overlayFill(context, 0.033),
      border: Border.all(color: _stroke(context)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 13, 18, 11),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _divider(context))),
          ),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: EvsRadius.rSm,
                  color: _accent(context).withValues(alpha: 0.15),
                ),
                child: Icon(icon, size: 13, color: _accent(context)),
              ),
              const SizedBox(width: 9),
              Text(title.toUpperCase(),
                  style:
                      EvsType.sectionLabel.copyWith(color: _sectionLabel(context))),
            ],
          ),
        ),
        ...rows,
      ],
    ),
  );
}

Widget evsRow(BuildContext context, {
  required String label,
  String? desc,
  required Widget control,
  bool stacked = false,
}) {
  final labelCol = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: EvsType.label.copyWith(color: _body(context))),
      if (desc != null) ...[
        const SizedBox(height: 2),
        Text(desc, style: EvsType.caption.copyWith(color: _sub(context))),
      ],
    ],
  );
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: _stroke(context))),
    ),
    // Stacked: label on top, control full-width below (used for wide
    // segmented selectors so they don't fold into a floating block). Inline:
    // label left, control bounded on the right.
    child: stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              labelCol,
              const SizedBox(height: 11),
              control,
            ],
          )
        : Row(
            children: [
              Expanded(flex: 3, child: labelCol),
              const SizedBox(width: 12),
              // Bound the control so a long select can't squeeze the label.
              Flexible(
                flex: 2,
                child: Align(alignment: Alignment.centerRight, child: control),
              ),
            ],
          ),
  );
}

// Full-width segmented selector: equal-width pills in a single row that fills
// the available width (used with `evsRow(context, stacked: true)`). Replaces the
// right-aligned Wrap that folded 3–4 options into a cramped floating block.
Widget evsSegmentedWide<T>(
  BuildContext context,
  List<(T, String)> options,
  T value,
  ValueChanged<T> onChanged,
) {
  return Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(11),
      color: _overlayFill(context, 0.055),
      border: Border.all(color: _stroke(context)),
    ),
    child: Row(
      children: [
        for (int i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(options[i].$1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: options[i].$1 == value
                      ? _accent(context).withValues(alpha: 0.22)
                      : Colors.transparent,
                  border: Border.all(
                    color: options[i].$1 == value
                        ? _accent(context).withValues(alpha: 0.45)
                        : Colors.transparent,
                  ),
                ),
                child: Text(options[i].$2,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: options[i].$1 == value
                            ? _txt(context)
                            : _sub(context))),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

Widget evsSegmented<T>(
  BuildContext context,
  List<(T, String)> options,
  T value,
  ValueChanged<T> onChanged,
) {
  return Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(11),
      color: _overlayFill(context, 0.055),
      border: Border.all(color: _stroke(context)),
    ),
    // Wrap (not Row) so the options flow onto a second line in narrow cards
    // instead of overflowing.
    child: Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.end,
      children: [
        for (final o in options)
          GestureDetector(
            onTap: () => onChanged(o.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: o.$1 == value
                    ? _accent(context).withValues(alpha: 0.22)
                    : Colors.transparent,
                border: Border.all(
                  color: o.$1 == value
                      ? _accent(context).withValues(alpha: 0.45)
                      : Colors.transparent,
                ),
              ),
              child: Text(o.$2,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: o.$1 == value
                          ? _txt(context)
                          : _sub(context))),
            ),
          ),
      ],
    ),
  );
}

Widget evsToggle(BuildContext context, bool value, ValueChanged<bool> onChanged) {
  return GestureDetector(
    onTap: () => onChanged(!value),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 42,
      height: 23,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: value ? _accentGradient(context) : null,
        color: value ? null : _overlayFill(context, 0.12),
        border: Border.all(
            color: value ? Colors.transparent : _stroke(context)),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.all(2),
      child: Container(
        width: 17,
        height: 17,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
      ),
    ),
  );
}

// Dropdown-styled display button (non-functional placeholder for stub selects).
Widget evsSelectButton(BuildContext context, String label, {double minWidth = 148, VoidCallback? onTap}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      constraints: BoxConstraints(minWidth: minWidth),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.06),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _body(context))),
          ),
          const SizedBox(width: 7),
          Icon(Icons.keyboard_arrow_down, size: 16, color: _faint(context)),
        ],
      ),
    ),
  );
}

Widget evsGhostButton(BuildContext context, String label, IconData icon, {VoidCallback? onTap}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.042),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: _sub(context)),
          const SizedBox(width: 6),
          Text(label, style: EvsType.control.copyWith(color: _sub(context))),
        ],
      ),
    ),
  );
}

Widget evsSlider(BuildContext context, {
  required double value,
  required double min,
  required double max,
  int? divisions,
  required String label,
  required ValueChanged<double> onChanged,
}) {
  // Up to 210px wide, but shrinks to fit narrow cards (no fixed width that
  // would overflow inside evsRow's bounded control slot).
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 210),
    child: Row(
      children: [
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: _accent(context),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 46,
          child: Text(label,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _accent(context))),
        ),
      ],
    ),
  );
}

// Full-width labelled slider (Style/Generation cards in the mockups).
Widget evsNamedSlider(BuildContext context, {
  required String label,
  String? desc,
  required double value,
  double min = 0,
  double max = 1,
  String? valueLabel,
  String? left,
  String? right,
  required ValueChanged<double> onChanged,
}) {
  return Container(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: _stroke(context))),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _body(context))),
            if (valueLabel != null)
              Text(valueLabel,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: _accent(context))),
          ],
        ),
        if (desc != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(desc,
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
          ),
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 4,
            overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: _accent(context),
            inactiveColor: _overlayFill(context, 0.10),
            onChanged: onChanged,
          ),
        ),
        if (left != null || right != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(left ?? '',
                  style: TextStyle(fontSize: 11, color: _faint(context))),
              Text(right ?? '',
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ],
          ),
      ],
    ),
  );
}

// Selectable connection-mode card (Model section).
Widget evsRadioCard(BuildContext context, {
  required bool selected,
  required String title,
  required String desc,
  required VoidCallback onTap,
  Widget? extra,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: selected ? _accent(context).withValues(alpha: 0.1) : _overlayFill(context, 0.03),
        border: Border.all(
            color: selected ? _accent(context).withValues(alpha: 0.3) : _stroke(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected ? _accent(context) : _faint(context), width: 2),
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: _accent(context)))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: EvsType.label.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? _txt(context) : _body(context))),
                const SizedBox(height: 2),
                Text(desc,
                    style: EvsType.caption
                        .copyWith(height: 1.35, color: _sub(context))),
                if (extra != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: extra,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget evsAddButton(BuildContext context, String label, VoidCallback onTap,
    {IconData icon = Icons.add, bool small = false}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 12 : 16, vertical: small ? 4 : 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _accent(context).withValues(alpha: 0.15),
        border: Border.all(color: _accent(context).withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: small ? 12 : 13, color: _accent(context)),
          const SizedBox(width: 7),
          Text(label,
              style: TextStyle(
                  fontSize: small ? 12 : 13,
                  fontWeight: FontWeight.w700,
                  color: _accent(context))),
        ],
      ),
    ),
  );
}

Widget evsDangerButton(BuildContext context, String label, VoidCallback onTap) {
  final d = _danger(context);
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: d.withValues(alpha: 0.12),
        border: Border.all(color: d.withValues(alpha: 0.32)),
      ),
      child: Text(label,
          style: EvsType.label
              .copyWith(fontSize: 13, fontWeight: FontWeight.w700, color: d)),
    ),
  );
}

// App version line for the About section (real data via package_info_plus).
class _VersionText extends StatelessWidget {
  const _VersionText();
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final info = snap.data;
        final text =
            info == null ? '—' : '${info.version} · build ${info.buildNumber}';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _accent(context).withValues(alpha: 0.12),
            border: Border.all(color: _accent(context).withValues(alpha: 0.25)),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _accent(context))),
        );
      },
    );
  }
}

// Custom frameless-window title bar: a draggable region + minimize / maximize
// / close controls (the native Windows title bar is hidden via window_manager).
class _WindowTitleBar extends StatelessWidget {
  const _WindowTitleBar();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          // Toggle the floating widget (separate transparent always-on-top
          // window with the voice visualization).
          Tooltip(
            message: context.read<AppState>().t('ovlEnter'),
            child: _WinBtn(Icons.picture_in_picture_alt_outlined, () {
              final app = context.read<AppState>();
              app.setOverlayMode(!app.overlayMode);
            }, iconSize: 14),
          ),
          _WinBtn(Icons.remove, () => windowManager.minimize()),
          _WinBtn(Icons.crop_square, () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          }, iconSize: 13),
          _WinBtn(Icons.close, () => windowManager.close(), danger: true),
        ],
      ),
    );
  }
}

class _WinBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final double iconSize;
  const _WinBtn(this.icon, this.onTap, {this.danger = false, this.iconSize = 16});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 36,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: danger
              ? _danger(context).withValues(alpha: 0.20)
              : _stroke(context),
          child: Center(
              child: Icon(icon, size: iconSize, color: _sub(context))),
        ),
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  final String label;
  const _KeyCap(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: _overlayFill(context, 0.08),
          border: Border.all(color: _stroke(context)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _body(context),
                fontFamily: 'monospace')),
      );
}

class _KeySep extends StatelessWidget {
  const _KeySep();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text('+', style: TextStyle(fontSize: 11, color: _faint(context))),
      );
}

class ChatScreen extends StatefulWidget {
  // When true, the screen is embedded inside the desktop shell (DesktopHome):
  // it drops its own drawer (the desktop sidebar replaces it) and renders the
  // desktop top bar instead of the mobile one. The composer, message list and
  // empty/hero state are reused unchanged.
  final bool desktop;
  const ChatScreen({super.key, this.desktop = false});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  bool _sending = false;
  final List<String> _pendingAttachments = [];
  // id of the assistant message currently being edited inline (its bubble
  // shows a text field instead of the text), plus its editing controller.
  String? _editingMessageId;
  final _editController = TextEditingController();

  // Desktop sidecar voice input (Whisper STT via the Python sidecar).
  bool _scListening = false;
  StreamSubscription<String>? _scPartialSub;
  StreamSubscription<String>? _scFinalSub;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    if (widget.desktop) {
      _scPartialSub = SidecarClient.instance.partial.listen((t) {
        if (mounted && _scListening) _controller.text = t;
      });
      _scFinalSub = SidecarClient.instance.finalText.listen(_onVoiceFinal);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final app = context.read<AppState>();
      // Warn once if the last run crashed loading a local model (we've since
      // switched away from it so the app could start).
      if (app.lastModelCrash != null) {
        final name = app.modelDisplayName(app.lastModelCrash!, withSuffix: false);
        app.lastModelCrash = null;
        showAppSnackBar(context, '${app.t('modelCrashWarn')} $name');
      }
      // Preload the current chat's local model so the "preparing model"
      // screen shows on open (no-op for remote / already-warmed models).
      unawaited(app.warmUpModelFor(app.current));
      if (app.showKeyboardOnLaunch) {
        _inputFocus.requestFocus();
      }
      // First-run: offer the AI command-suggestion wizard (Ф1 §1.4). Awaited so
      // it doesn't stack on top of the "what's new" dialog below.
      await _maybeOfferCommandOnboarding(app);
      if (!mounted) return;
      final entry = await app.consumeWhatsNew();
      if (!mounted || entry == null) return;
      showDialog(
        context: context,
        builder: (dialogContext) => _AppDialog(
          title: Text('${app.t('whatsNewTitle')} ${entry.version}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final change in entry.changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('•  $change'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(app.t('gotIt')),
            ),
          ],
        ),
      );
    });
  }

  // First-launch onboarding for the AI command wizard (Ф1 §1.4). Offers once,
  // on Windows only, when no app-launch commands exist yet. Accepting opens the
  // existing suggestion wizard; either choice marks the offer as seen so it
  // never reappears (the wizard stays reachable from the commands screen).
  Future<void> _maybeOfferCommandOnboarding(AppState app) async {
    if (!app.shouldOfferCommandOnboarding) return;
    app.markCommandOnboardingSeen();
    final accept = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: Text(app.t('cmdOnboardTitle')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(app.t('cmdOnboardBody')),
            const SizedBox(height: 12),
            Text(
              app.t('cmdSuggestPrivacy'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF6E7280)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(app.t('later')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(app.t('cmdOnboardYes')),
          ),
        ],
      ),
    );
    if (accept != true || !mounted) return;
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _SuggestCommandsDialog(app),
    );
    if (n != null && n > 0 && mounted) {
      showAppSnackBar(
          context, app.t('cmdSuggestSaved').replaceAll('{n}', '$n'));
    }
  }

  @override
  void dispose() {
    _scPartialSub?.cancel();
    _scFinalSub?.cancel();
    if (_scListening) SidecarClient.instance.sttStop();
    _controller.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  // Desktop voice button: use the sidecar's Whisper STT when connected,
  // otherwise fall back to the existing speech_to_text VoiceScreen.
  // The input-bar mic button was removed (the mic already listens for commands
  // continuously), so this is currently unreferenced — kept so the VoiceScreen
  // dictation flow can be re-exposed without rebuilding it.
  // ignore: unused_element
  void _desktopVoice() {
    final sc = SidecarClient.instance;
    if (sc.status.value != SidecarStatus.connected || !sc.sttAvailable) {
      _openVoice();
      return;
    }
    final app = context.read<AppState>();
    if (_scListening) {
      sc.sttStop();
      setState(() => _scListening = false);
    } else {
      sc.sttStart(app.effectiveSttLanguage, prompt: app.sttBiasPrompt);
      setState(() => _scListening = true);
    }
  }

  // Final transcript from the sidecar: if it matches a voice command, run it
  // (with spoken feedback); otherwise drop it into the input and auto-send.
  void _onVoiceFinal(String text) {
    if (!mounted || !_scListening) return;
    final app = context.read<AppState>();
    SidecarClient.instance.sttStop();
    setState(() => _scListening = false);
    final t = text.trim();
    if (t.isEmpty) return;
    if (app.voiceCommands.isNotEmpty) {
      final cmd = CommandExecutor.instance.match(t, app.voiceCommands);
      if (cmd != null) {
        _controller.clear();
        if (cmd.type == VoiceCommandType.appVolume) {
          // Parametric: read the number from the spoken phrase `t`.
          app.applyAppVolume(cmd, t).then((r) {
            if (!mounted) return;
            if (SidecarClient.instance.ttsAvailable) {
              SidecarClient.instance.speak(r.$2);
            }
            showAppSnackBar(context, r.$2);
          });
          return;
        }
        CommandExecutor.instance.execute(cmd);
        if (SidecarClient.instance.ttsAvailable) {
          SidecarClient.instance.speak(app.t('cmdRunOk'));
        }
        showAppSnackBar(context, '${app.t('cmdRunOk')}: ${cmd.phrase}');
        return;
      }
    }
    _controller.text = t;
    if (app.micAutoSend) _send(t);
  }

  // Regenerate the last assistant reply (drops it, generates a fresh one).
  Future<void> _regenerate() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final conv = app.current;
    if (conv == null || _sending || app.isGenerating) return;
    app.buzz();
    setState(() => _sending = true);
    await app.regenerateLastReply(conv);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  // Continue the story: generate another assistant turn from the current
  // context, without the user typing a reply.
  Future<void> _continue() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final conv = app.current;
    if (conv == null || _sending || app.isGenerating) return;
    app.buzz();
    setState(() => _sending = true);
    await app.continueReply(conv);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _startEdit(ChatMessage m) {
    setState(() {
      _editingMessageId = m.id;
      _editController.text = m.content;
    });
  }

  void _cancelEdit() {
    setState(() => _editingMessageId = null);
  }

  void _saveEdit(ChatMessage m) {
    final app = context.read<AppState>();
    final conv = app.current;
    if (conv != null) app.editMessage(conv, m, _editController.text);
    setState(() => _editingMessageId = null);
  }

  static const _imageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  ];

  bool _isImageAttachment(String path) =>
      _imageExtensions.contains(path.split('.').last.toLowerCase());

  // Mirai never actually sends image bytes to either backend today (local
  // GGUF requests and the Ollama request body both only carry text), so a
  // remote model is treated the same as a non-vision one here regardless of
  // what it nominally supports server-side.
  bool _modelSupportsVision(AppState app) {
    if (!app.isLocalModel(app.selectedModel)) return false;
    return app.localSpecFor(app.selectedModel)?.isVisionCapable ?? false;
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        setState(() => _pendingAttachments.add(file.path!));
        if (mounted) {
          final app = context.read<AppState>();
          showAppSnackBar(context, app.t('fileAttached'));
        }
      }
    }
  }

  Future<void> _send([String? preset]) async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final text = (preset ?? _controller.text).trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) ||
        _sending ||
        app.isModelLoading) {
      return;
    }
    app.buzz();
    _controller.clear();
    final attachments = List<String>.from(_pendingAttachments);
    setState(() {
      _sending = true;
      _pendingAttachments.clear();
    });
    await app.sendMessage(text, attachments: attachments);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _scrollDown() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openModelMenu() {
    if (!mounted) return;
    final app = context.read<AppState>();
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _ModelMenu(
        onManage: () {
          Navigator.pop(context);
          _openSettings();
        },
        onNewChat: () {
          Navigator.pop(context);
          app.newChat();
          if (mounted) setState(() {});
        },
        onCreateImage: () {
          Navigator.pop(context);
          if (!mounted) return;
          showAppSnackBar(context, app.t('createImageHint'));
        },
      ),
    );
  }

  void _openSettings() {
    if (!mounted) return;
    if (widget.desktop) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DesktopSettings()),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: _scrim(context),
      builder: (_) => const SettingsSheet(),
    );
  }

  // Desktop top bar (mockup): model pill on the left, an online status badge,
  // and a profile button on the right. The settings entry lives in the
  // sidebar (DesktopHome), so it is not repeated here.
  Widget _desktopTopBar(AppState app) {
    final lockedModel = app.current?.rpModeEnabled == true
        ? app.current?.rpConfig?.lockedModel
        : null;
    final isLocal = app.isLocalModel(lockedModel ?? app.selectedModel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 24, 12),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {
              app.buzz();
              if (lockedModel != null) {
                showAppSnackBar(context, app.t('rpModelLockedToast'));
                return;
              }
              _openModelMenu();
            },
            child: _modelBubbleWrap(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      app.loadingModels
                          ? app.t('loadingModels')
                          : app.modelDisplayName(
                              lockedModel ?? app.selectedModel,
                              withSuffix: false,
                            ),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _txt(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    lockedModel != null
                        ? Icons.lock_outline
                        : Icons.keyboard_arrow_down,
                    color: _sub(context),
                    size: lockedModel != null ? 16 : 20,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          _updateReadyPill(app),
          _vaIndicator(app),
          // Per-chat personalization / roleplay settings are intentionally not
          // exposed on desktop — the assistant is configured globally in
          // DesktopSettings («Личность и память»).
          _desktopStatusBadge(app, isLocal),
        ],
      ),
    );
  }

  // "Update ready — restart" pill (Discord-style): appears once the new
  // installer is downloaded and verified; clicking applies it silently and
  // relaunches the app on the new version.
  Widget _updateReadyPill(AppState app) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: AppUpdater.instance.status,
      builder: (_, st, __) {
        if (st != UpdateStatus.ready) return const SizedBox.shrink();
        return InkWell(
          borderRadius: BorderRadius.circular(21),
          onTap: () => AppUpdater.instance.applyAndRestart(),
          child: _vaPill(
              Icons.system_update_alt,
              '${app.t('updReadyShort')} ${AppUpdater.instance.availableVersion} · ${app.t('updRestart')}',
              _success(context)),
        );
      },
    );
  }

  // Voice-assistant status pill in the top bar. Only shown when the user turned
  // on always-listening (wake-word mode). Reflects the real state: STT offline,
  // listening (+ last heard phrase), thinking, or running.
  Widget _vaIndicator(AppState app) {
    if (app.cmdMode != 'wakeword' || app.sttEngine != 'whisper') {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (_, sc, __) {
        if (sc != SidecarStatus.connected) {
          return _vaPill(
              Icons.mic_off, app.t('vaSttOffline'), const Color(0xFFE0985D));
        }
        return ValueListenableBuilder<VaState>(
          valueListenable: VoiceAssistant.instance.state,
          builder: (_, s, __) {
            final (label, color) = switch (s) {
              VaState.armed => (app.t('vaArmed'), _info(context)),
              VaState.thinking => (app.t('vaThinking'), _success(context)),
              VaState.running => (app.t('vaRunning'), _warn(context)),
              _ => (app.t('vaListening'), _accent(context)),
            };
            if (s == VaState.listening || s == VaState.idle) {
              // Flash a bright "wake word heard!" state for ~2.5 s so the
              // trigger is unmistakable, then fall back to the plain status.
              // We deliberately do NOT surface the raw transcript here — it
              // lingered and cluttered the pill with mis-heard phrases.
              return ValueListenableBuilder<bool>(
                valueListenable: VoiceAssistant.instance.wakeActive,
                builder: (_, woke, __) {
                  if (woke) {
                    return _vaPill(
                        Icons.check_circle,
                        '«${app.wakeWord}» — ${app.t('vaWakeHeard')}',
                        _success(context));
                  }
                  return _vaPill(Icons.graphic_eq, label, color);
                },
              );
            }
            return _vaPill(Icons.graphic_eq, label, color);
          },
        );
      },
    );
  }

  Widget _vaPill(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Color.lerp(color, _txt(context), 0.4)!,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  // Colour for a connection status (dot + tint + border).
  Color _statusColor(BuildContext context, ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => _success(context),
        ConnectionStatus.connecting => _info(context),
        ConnectionStatus.noModel => _warn(context),
        ConnectionStatus.disconnected => _faint(context),
        ConnectionStatus.error => _danger(context),
      };

  String _statusText(AppState app, ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => app.t('statusConnected'),
        ConnectionStatus.connecting => app.t('statusConnecting'),
        ConnectionStatus.noModel => app.t('statusNoModel'),
        ConnectionStatus.disconnected => app.t('statusDisconnected'),
        ConnectionStatus.error => app.t('statusError'),
      };

  Widget _desktopStatusBadge(AppState app, bool isLocal) {
    final status = app.connectionStatus;
    final color = _statusColor(context, status);
    final label = status == ConnectionStatus.connected
        ? '${isLocal ? app.t('statusLocalModel') : app.t('statusRemoteModel')} · ${app.t('statusConnected')}'
        : _statusText(app, status);
    final textColor = Color.lerp(color, _txt(context), 0.45)!;
    return InkWell(
      borderRadius: BorderRadius.circular(21),
      onTap: () => _showConnectionDialog(app, status, isLocal),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: color, blurRadius: 9, spreadRadius: 1),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.info_outline,
                size: 14, color: color.withValues(alpha: 0.55)),
          ],
        ),
      ),
    );
  }

  void _showConnectionDialog(
      AppState app, ConnectionStatus status, bool isLocal) {
    if (!mounted) return;
    final isRemote = !isLocal && !app.isLocalModel(app.selectedModel);
    final modelName = app.selectedModel.isEmpty
        ? app.t('statusNoModel')
        : app.modelDisplayName(app.selectedModel, withSuffix: false);
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 92,
                  child: Text(k, style: TextStyle(color: _sub(context)))),
              Expanded(
                  child: Text(v,
                      style: TextStyle(
                          color: _txt(context),
                          fontWeight: FontWeight.w600))),
            ],
          ),
        );
    showDialog(
      context: context,
      builder: (dctx) => _AppDialog(
        title: Text(app.t('statusTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: _statusColor(context, status))),
              const SizedBox(width: 8),
              Text(_statusText(app, status),
                  style: TextStyle(
                      color: _txt(context), fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            row(app.t('modelField'), modelName),
            if (isRemote)
              row(app.t('serverField'),
                  app.serverUrl.isEmpty ? '—' : app.serverUrl),
            if (status == ConnectionStatus.error && app.modelsError != null) ...[
              const SizedBox(height: 10),
              Text(app.modelsError!,
                  style: const TextStyle(
                      color: Color(0xFFE05A6A), fontSize: 13, height: 1.4)),
            ],
          ],
        ),
        actions: [
          if (isRemote)
            TextButton(
              onPressed: () {
                Navigator.pop(dctx);
                app.fetchModels();
              },
              child: Text(app.t('retry')),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(app.t('gotIt')),
          ),
        ],
      ),
    );
  }

  void _openChatPersonalization() {
    if (!mounted) return;
    final app = context.read<AppState>();
    if (app.current == null) app.newChat();
    openPersonalization(context, conversation: app.current);
  }

  void _openVoice() async {
    if (!mounted) return;
    final result = await Navigator.of(context).push<(String, bool)>(
      MaterialPageRoute(builder: (_) => const VoiceScreen()),
    );
    if (!mounted || result == null) return;
    final (text, autoSend) = result;
    if (text.trim().isEmpty) return;
    if (autoSend) {
      _send(text);
    } else {
      _controller.text = text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conv = app.current;
    final hasMessages = conv != null && conv.messages.isNotEmpty;

    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: SafeArea(
        top: !widget.desktop,
        child: Column(
          children: [
            widget.desktop ? _desktopTopBar(app) : _topBar(app),
            if (app.isModelLoading) _modelLoadingCard(app),
            Expanded(
              child: hasMessages ? _messageList(conv, app) : _emptyState(app),
            ),
            if (app.showPromptChips && !hasMessages) _promptChips(app),
            if (conv != null &&
                conv.rpModeEnabled &&
                conv.rpConfig != null &&
                RPMemoryManager.checkContextThreshold(
                  conv.messages,
                  conv.rpConfig!,
                ))
              _compressionBanner(conv, app),
            _inputBar(app),
          ],
        ),
      ),
    );

    // Desktop shell provides its own sidebar (DesktopHome) instead of the
    // mobile edge-swipe drawer, and a transparent scaffold so the shell's
    // gradient background shows through.
    if (widget.desktop) {
      return Scaffold(backgroundColor: Colors.transparent, body: body);
    }

    return Scaffold(
      backgroundColor: _bg(context),
      // Full-width left drawer holds the chat list — opened by an edge swipe
      // (the old top-bar chats button is gone). Drawer keeps the OS status
      // bar visible (not immersive); its content uses its own SafeArea.
      drawerEdgeDragWidth: 56,
      // Opening the drawer must drop any text-field focus, otherwise the
      // keyboard (from the chat input or the drawer's search field) stays up
      // over the drawer with no way to dismiss it.
      onDrawerChanged: (opened) {
        if (opened) FocusManager.instance.primaryFocus?.unfocus();
      },
      drawer: Drawer(
        width: MediaQuery.of(context).size.width,
        backgroundColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: const ConversationsSheet(embedded: true),
      ),
      body: body,
    );
  }

  // Top "Preparing <model>" card with an indeterminate bar, shown while the
  // local model warms up (see AppState.warmUpModelFor).
  Widget _modelLoadingCard(AppState app) {
    final spec = app.loadingModelKey != null
        ? app.localSpecFor(app.loadingModelKey!)
        : null;
    final label = spec != null
        ? '${app.t('preparingModel')} ${spec.shortName}'
        : app.t('preparingModel');
    final row = Row(
      children: [
        Icon(Icons.auto_awesome, size: 18, color: _sub(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: _sub(context).withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation(_accent(context)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: _glassCard(
        context,
        radius: 16,
        alpha: 0.6,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: row,
      ),
    );
  }

  Widget _topBar(AppState app) {
    final lockedModel = app.current?.rpModeEnabled == true
        ? app.current?.rpConfig?.lockedModel
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          _circleBtn(Icons.settings_outlined, _openSettings),
          const SizedBox(width: 8),
          // Centered between the two buttons but hugging the model name (not
          // stretched full-width); long names still ellipsize within the
          // available space.
          Expanded(
            child: Center(
              child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                app.buzz();
                if (lockedModel != null) {
                  showAppSnackBar(context, app.t('rpModelLockedToast'));
                  return;
                }
                _openModelMenu();
              },
              child: _modelBubbleWrap(
                child: Opacity(
                  opacity: lockedModel != null ? 0.6 : 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (app.loadingModels) ...[
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            app.t('loadingModels'),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _sub(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ] else ...[
                        Flexible(
                          child: Text(
                            app.isModelLoading
                                ? app.t('loadingShort')
                                : app.modelDisplayName(
                                    lockedModel ?? app.selectedModel,
                                    withSuffix: false,
                                  ),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _txt(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          lockedModel != null
                              ? Icons.lock_outline
                              : Icons.keyboard_arrow_down,
                          color: _txt(context),
                          size: lockedModel != null ? 18 : 24,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            ),
          ),
          const SizedBox(width: 8),
          _circleBtn(Icons.manage_accounts_outlined, _openChatPersonalization),
        ],
      ),
    );
  }

  // Input-bar surface: translucent blurred in glass style, solid card
  // otherwise. Sits inside the AnimatedBorder, so no border of its own here.
  Widget _inputSurface({required Widget child}) {
    const pad = EdgeInsets.symmetric(horizontal: 4, vertical: 4);
    if (_isGlass(context)) {
      return GlassSurface(
        borderRadius: BorderRadius.circular(20),
        padding: pad,
        child: child,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _card(context),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: pad,
      child: child,
    );
  }

  // Outer wrapper for the model-name bubble: a translucent blurred pill in
  // glass style, the bordered solid pill otherwise.
  Widget _modelBubbleWrap({required Widget child}) {
    const pad = EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    if (_isGlass(context)) {
      return GlassSurface(
        borderRadius: BorderRadius.circular(20),
        padding: pad,
        child: child,
      );
    }
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _sub(context).withValues(alpha: 0.3)),
      ),
      child: child,
    );
  }

  Widget _circleBtn(
    IconData icon,
    VoidCallback onTap, {
    bool active = false,
    String? tooltip,
  }) {
    final iconWidget = Icon(
      icon,
      color: active ? _accent(context) : _txt(context),
      size: 22,
    );
    // Glass style (non-active) → translucent blurred circle; active state
    // keeps its blue tint in both styles. Standard style → the original
    // solid circle.
    final Widget face = (_isGlass(context) && !active)
        ? GlassSurface(
            circle: true,
            child: SizedBox(width: 48, height: 48, child: Center(child: iconWidget)),
          )
        : Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? _accent(context)
                    : _sub(context).withValues(alpha: 0.3),
                width: active ? 1.5 : 1,
              ),
              color: active
                  ? _accent(context).withValues(alpha: 0.18)
                  : _card(context).withValues(alpha: 0.4),
            ),
            child: iconWidget,
          );
    final btn = InkResponse(
      onTap: () {
        if (!mounted) return;
        context.read<AppState>().buzz();
        onTap();
      },
      radius: 28,
      child: face,
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  Widget _emptyState(AppState app) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Voice visualization on the home screen, gated by settings
            // (vizType 'none' or showVizBg off hides it; waves/bars currently
            // render as the sphere).
            if (app.showVizBg && app.vizType != 'none') ...[
              const SizedBox(height: 20),
              // vizType picks the hero visualization; all react to the real
              // combined voice level (mic + assistant speech).
              if (app.vizType == 'bars')
                const EvsBarsViz(width: 360, height: 150)
              else if (app.vizType == 'waves')
                const EvsRingViz(size: 220)
              else if (app.vizType == 'orb')
                const EvsLiveViz(kind: 'orb', maxSize: 320)
              else if (app.vizType == 'lkbars')
                const EvsLiveViz(kind: 'lkbars', maxSize: 340)
              else if (app.vizType == 'wave3d')
                const EvsWaveViz(
                    kind: 'wave3d', size: 320, fadeEdges: true, reactive: true)
              else if (app.vizType == 'waveflat')
                const EvsWaveViz(
                    kind: 'waveflat', size: 320, fadeEdges: true, reactive: true)
              else
                ParticleSphere(
                  size: 200,
                  color: _vizColor(context),
                  scattered: keyboardOpen,
                  soundLevel: VoiceLevels.instance.tts,
                ),
            ],
            const SizedBox(height: 20),
            const _SttReadinessBanner(),
            Text(
              app.isModelLoading ? app.t('gettingReady') : app.t('howCanIHelp'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _txt(context),
                fontSize: 28,
                fontWeight: FontWeight.w700,
                // The hero sits directly over the visualization; a soft halo
                // keeps it legible whatever the viz is doing underneath.
                shadows: _overTextShadows(context),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                app.isModelLoading
                    ? app.t('loadingYourModel')
                    : app.t('subtitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 14,
                  height: 1.4,
                  shadows: _overTextShadows(context),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _messageList(Conversation conv, AppState app) {
    // In RP mode the assistant message is already a real (possibly still
    // empty) entry in conv.messages from the moment generation starts (see
    // AppState._generateAssistantReply), so the synthetic placeholder below
    // would otherwise show a second "thinking" bubble alongside it.
    final showSyntheticPlaceholder = _sending && !conv.rpModeEnabled;
    if (app.isGenerating && conv.rpModeEnabled) {
      // Keep the growing reply in view as it streams in, the same way
      // _send() already does once for the non-streaming reply.
      _scrollDown();
    }
    final busy = _sending || app.isGenerating;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: conv.messages.length + (showSyntheticPlaceholder ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= conv.messages.length) {
          return _bubble(
            ChatMessage(role: 'assistant', content: ''),
            thinking: true,
          );
        }
        final m = conv.messages[i];
        final isStreamingPlaceholder =
            app.isGenerating &&
            conv.rpModeEnabled &&
            i == conv.messages.length - 1 &&
            m.role == 'assistant' &&
            m.content.isEmpty;
        // Action bar (edit / regenerate / continue) under the last assistant
        // reply when idle.
        final showActions =
            !busy &&
            i == conv.messages.length - 1 &&
            m.role == 'assistant' &&
            m.content.isNotEmpty;
        return _bubble(
          m,
          thinking: isStreamingPlaceholder,
          showActions: showActions,
        );
      },
    );
  }

  Widget _bubble(
    ChatMessage m, {
    bool thinking = false,
    bool showActions = false,
  }) {
    final isUser = m.role == 'user';
    final editing = _editingMessageId == m.id;
    final fg = _onAccent(context);
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      decoration: BoxDecoration(
        color: isUser ? Theme.of(context).colorScheme.primary : null,
        gradient: isUser
            ? null
            : _accentGradient(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.attachments.isNotEmpty)
            ...m.attachments.map(
              (a) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.attach_file,
                      size: 14,
                      color: fg.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        a.split('/').last,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.75),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (thinking)
            const _ThinkingDots()
          else if (editing)
            _editBubbleBody(m)
          else if (m.content.isNotEmpty)
            Text(
              m.content,
              style: EvsType.body.copyWith(color: fg),
            ),
        ],
      ),
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          thinking || editing
              ? bubble
              : GestureDetector(
                  onLongPressStart: (d) =>
                      _showMessageActions(m, d.globalPosition),
                  child: bubble,
                ),
          if (showActions && !editing) _messageActionsBar(m),
        ],
      ),
    );
  }

  // Inline editor shown inside an assistant bubble in place of its text.
  Widget _editBubbleBody(ChatMessage m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: _editController,
          autofocus: true,
          minLines: 1,
          maxLines: 12,
          style: EvsType.body.copyWith(color: _onAccent(context)),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _cancelEdit,
              style: TextButton.styleFrom(
                foregroundColor: _onAccent(context).withValues(alpha: 0.7),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: Text(context.read<AppState>().t('cancel')),
            ),
            TextButton(
              onPressed: () => _saveEdit(m),
              style: TextButton.styleFrom(
                foregroundColor: _onAccent(context),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: Text(context.read<AppState>().t('save')),
            ),
          ],
        ),
      ],
    );
  }

  // Edit / regenerate / continue controls under the last assistant reply.
  Widget _messageActionsBar(ChatMessage m) {
    final app = context.read<AppState>();
    Widget btn(IconData icon, String tooltip, VoidCallback onTap) {
      return IconButton(
        icon: Icon(icon, size: 18, color: _txt(context)),
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(),
      );
    }

    Widget sep() => Container(
      width: 1,
      height: 20,
      color: _sub(context).withValues(alpha: 0.25),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.edit_outlined, app.t('msgEdit'), () => _startEdit(m)),
        sep(),
        btn(Icons.refresh, app.t('msgRegenerate'), _regenerate),
        sep(),
        btn(Icons.fast_forward, app.t('msgContinue'), _continue),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6, left: 2),
      child: _isGlass(context)
          ? GlassSurface(borderRadius: BorderRadius.circular(18), child: row)
          : Container(
              decoration: BoxDecoration(
                color: _card(context).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(18),
              ),
              child: row,
            ),
    );
  }

  void _showMessageActions(ChatMessage m, Offset globalPosition) async {
    final app = context.read<AppState>();
    final conv = app.current;
    final isPinned = conv != null && conv.pinnedMessageIds.contains(m.id);
    final String? selected;
    if (_isGlass(context)) {
      selected = await showGlassMenu(
        context,
        position: globalPosition,
        menuWidth: 260,
        items: [
          GlassMenuItem('copy', app.t('msgCopy'), icon: Icons.copy_outlined),
          GlassMenuItem(
            'compose',
            app.t('msgUseInComposer'),
            icon: Icons.edit_note_outlined,
          ),
          GlassMenuItem(
            'remember',
            app.t('msgRemember'),
            icon: Icons.psychology_alt_outlined,
          ),
          GlassMenuItem(
            'forget',
            app.t('msgForgetMemory'),
            icon: Icons.delete_outline,
            color: Colors.redAccent,
          ),
          GlassMenuItem(
            'pin',
            isPinned ? app.t('msgUnpinContext') : app.t('msgPinContext'),
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          ),
        ],
      );
    } else {
      selected = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          globalPosition.dx,
          globalPosition.dy,
          globalPosition.dx,
          globalPosition.dy,
        ),
        color: _card(context),
        items: [
          _menuItem('copy', Icons.copy_outlined, app.t('msgCopy')),
          _menuItem(
            'compose',
            Icons.edit_note_outlined,
            app.t('msgUseInComposer'),
          ),
          _menuItem(
            'remember',
            Icons.psychology_alt_outlined,
            app.t('msgRemember'),
          ),
          _menuItem(
            'forget',
            Icons.delete_outline,
            app.t('msgForgetMemory'),
            color: Colors.redAccent,
          ),
          _menuItem(
            'pin',
            isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            isPinned ? app.t('msgUnpinContext') : app.t('msgPinContext'),
          ),
        ],
      );
    }
    if (selected == null || !mounted) return;
    String? toast;
    switch (selected) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.content));
        toast = app.t('msgCopied');
        break;
      case 'compose':
        _controller.text = m.content;
        _inputFocus.requestFocus();
        break;
      case 'remember':
        final effectivePersona = conv?.persona ?? app.persona;
        if (effectivePersona.askBeforeRemembering) {
          final confirmed = await _pickMemoryCategory(app);
          if (confirmed != true || !mounted) break;
        }
        app.rememberMessageContent(m.content);
        toast = app.t('msgRemembered');
        break;
      case 'forget':
        app.forgetMessageMemory(m.content);
        toast = app.t('msgForgotten');
        break;
      case 'pin':
        if (conv != null) {
          app.toggleMessagePin(conv, m);
          toast = isPinned ? app.t('msgUnpinned') : app.t('msgPinned');
        }
        break;
    }
    if (toast != null && mounted) {
      showAppSnackBar(context, toast);
    }
  }

  Future<bool?> _pickMemoryCategory(AppState app) {
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
                    color: selected == cat ? Colors.white : _txt(context),
                    fontWeight: FontWeight.w500,
                  ),
                  selectedColor: _accent(context),
                  backgroundColor: _bg(context).withValues(alpha: 0.4),
                  side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
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

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? _txt(context)),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color ?? _txt(context))),
        ],
      ),
    );
  }

  Widget _promptChips(AppState app) {
    final chips = [
      (app.t('summarize'), Icons.edit_outlined),
      (app.t('rewrite'), Icons.auto_awesome),
      (app.t('fixGrammar'), Icons.spellcheck),
    ];
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final c in chips)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ActionChip(
                onPressed: () => _send('${c.$1}: '),
                backgroundColor: _card(context).withValues(alpha: 0.6),
                side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
                avatar: Icon(c.$2, size: 18, color: _txt(context)),
                label: Text(
                  c.$1,
                  style: TextStyle(
                    color: _txt(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _compressionBanner(Conversation conv, AppState app) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: _glassCard(
        context,
        radius: 14,
        alpha: 0.6,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, color: _sub(context), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              app.t('rpContextFull'),
              style: TextStyle(color: _txt(context), fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: app.isCompressingContext
                ? null
                : () => app.compressRpContext(conv),
            child: app.isCompressingContext
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _sub(context),
                    ),
                  )
                : Text(app.t('rpCompressButton')),
          ),
        ],
        ),
      ),
    );
  }

  // Image attachments get an actual thumbnail (matches the reference
  // screenshot); non-image files keep the old filename chip, since there's
  // nothing meaningful to preview for those.
  Widget _attachmentPreviewRow(AppState app) {
    final showVisionWarning =
        _pendingAttachments.any(_isImageAttachment) &&
        !_modelSupportsVision(app);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _pendingAttachments.map((a) {
              return _isImageAttachment(a)
                  ? _imageAttachmentThumb(a)
                  : _fileAttachmentChip(a);
            }).toList(),
          ),
          if (showVisionWarning) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_outlined,
                  size: 14,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    app.t('imageNotSupportedWarning'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _imageAttachmentThumb(String path) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: attachmentThumbnail(path, size: 72),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => setState(() => _pendingAttachments.remove(path)),
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fileAttachmentChip(String path) {
    return Chip(
      avatar: const Icon(Icons.attach_file, size: 16),
      label: Text(
        path.split('/').last,
        style: TextStyle(fontSize: 12, color: _txt(context)),
      ),
      onDeleted: () => setState(() => _pendingAttachments.remove(path)),
      backgroundColor: _bg(context).withValues(alpha: 0.4),
      side: BorderSide(color: _sub(context).withValues(alpha: 0.3)),
    );
  }

  Widget _inputBar(AppState app) {
    // Commands-only mode: text chat is disabled — show a locked bar (voice
    // push-to-talk stays so commands still work).
    if (!app.chatEnabled) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
        child: _inputSurface(
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(Icons.lock_outline, size: 18, color: _sub(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(app.t('chatDisabledHint'),
                    style: TextStyle(color: _sub(context), fontSize: 14)),
              ),
              const SizedBox(width: 14),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      child: AnimatedBorder(
        radius: 20,
        strokeWidth: 2,
        child: _inputSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_pendingAttachments.isNotEmpty)
                _attachmentPreviewRow(app),
              Row(
                children: [
              // Кнопка добавления с анимированной обводкой
              _buildAnimatedBtn(
                onTap: () {
                  app.buzz();
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: Colors.transparent,
                    barrierColor: _scrim(context),
                    isScrollControlled: true,
                    builder: (_) => _RecentAttachSheet(
                      onPick: (path) =>
                          setState(() => _pendingAttachments.add(path)),
                      onPickFile: _pickFile,
                    ),
                  );
                },
                icon: Icons.add,
              ),
              const SizedBox(width: 4),
              // Поле ввода
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _inputFocus,
                  enabled: !app.isModelLoading,
                  style: TextStyle(color: _txt(context), fontSize: 16),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: app.isModelLoading
                        ? app.t('preparingModel')
                        : app.t('askAnything'),
                    hintStyle: TextStyle(color: _sub(context), fontSize: 16),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              // Кнопка отправки (фиксированный размер, чтобы не "скакать"
              // между обычным и состоянием отправки)
              Builder(
                builder: (context) {
                  final hasContent =
                      _controller.text.trim().isNotEmpty ||
                      _pendingAttachments.isNotEmpty;
                  final canStop =
                      app.isGenerating && (app.current?.rpModeEnabled ?? false);
                  return Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: canStop
                          ? Colors.redAccent
                          : hasContent
                          ? kSendActiveColor
                          : _txt(context).withValues(alpha: 0.1),
                    ),
                    child: canStop
                        ? IconButton(
                            onPressed: () {
                              app.buzz();
                              app.cancelGeneration();
                            },
                            tooltip: app.t('stopGeneration'),
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white,
                            ),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          )
                        : _sending
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: hasContent
                                  ? Colors.white
                                  : _txt(context),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _send(),
                            icon: Icon(
                              Icons.arrow_upward,
                              color: hasContent ? Colors.white : _txt(context),
                            ),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                  );
                },
              ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedBtn({
    required VoidCallback onTap,
    required IconData icon,
  }) {
    final iconWidget = Icon(icon, color: _txt(context), size: 20);
    return AnimatedBorder(
      radius: 20,
      strokeWidth: 2,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: _isGlass(context)
              ? GlassSurface(
                  circle: true,
                  padding: const EdgeInsets.all(8),
                  child: iconWidget,
                )
              : Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _card(context),
                    shape: BoxShape.circle,
                  ),
                  child: iconWidget,
                ),
        ),
      ),
    );
  }
}

// Mirrors the iOS Messages attachment drawer: a draggable sheet with a grid
// of recent photos up top and a row of source tabs at the bottom. Only
// Gallery/File are kept — Gift/Wallet/Location/Checklist don't map to
// anything this app does.
class _RecentAttachSheet extends StatefulWidget {
  final ValueChanged<String> onPick;
  final VoidCallback onPickFile;
  const _RecentAttachSheet({required this.onPick, required this.onPickFile});

  @override
  State<_RecentAttachSheet> createState() => _RecentAttachSheetState();
}

class _RecentAttachSheetState extends State<_RecentAttachSheet> {
  List<AssetEntity> _assets = [];
  bool _loading = true;
  bool _denied = false;
  final Set<String> _pickedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) {
        if (mounted) {
          setState(() {
            _loading = false;
            _denied = true;
          });
        }
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      final assets = albums.isEmpty
          ? <AssetEntity>[]
          : await albums.first.getAssetListPaged(page: 0, size: 60);
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
      });
    } catch (_) {
      // photo_manager has no implementation on this platform (Windows,
      // Linux and Web aren't supported) — fall back to the same "no
      // access" state so the user can still attach via the file picker.
      if (mounted) {
        setState(() {
          _loading = false;
          _denied = true;
        });
      }
    }
  }

  Future<void> _onTapAsset(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null || !mounted) return;
    setState(() => _pickedIds.add(asset.id));
    widget.onPick(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return _sheetSurface(
          context,
          solid: _card(context),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _sub(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    const SizedBox(width: 40),
                    Expanded(
                      child: Text(
                        app.t('recentPhotos'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _txt(context),
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: _txt(context)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody(scrollController, app)),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _attachTab(
                        Icons.photo_outlined,
                        app.t('attachTabGallery'),
                        selected: true,
                        onTap: () {},
                      ),
                      _attachTab(
                        Icons.attach_file,
                        app.t('attachTabFile'),
                        selected: false,
                        onTap: () {
                          Navigator.pop(context);
                          widget.onPickFile();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(ScrollController scrollController, AppState app) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            app.t('photoAccessDenied'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _sub(context)),
          ),
        ),
      );
    }
    if (_assets.isEmpty) {
      return Center(
        child: Text(
          app.t('noRecentPhotos'),
          style: TextStyle(color: _sub(context)),
        ),
      );
    }
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _assets.length,
      itemBuilder: (_, i) {
        final asset = _assets[i];
        final picked = _pickedIds.contains(asset.id);
        return GestureDetector(
          onTap: () => _onTapAsset(asset),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FutureBuilder<Uint8List?>(
                  future: asset.thumbnailDataWithSize(
                    const ThumbnailSize.square(200),
                  ),
                  builder: (_, snap) {
                    if (snap.data == null) {
                      return Container(color: _bg(context));
                    }
                    return Image.memory(snap.data!, fit: BoxFit.cover);
                  },
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: picked ? _accent(context) : Colors.black38,
                    border: Border.all(color: Colors.white70, width: 1.2),
                  ),
                  child: picked
                      ? const Icon(Icons.check, size: 13, color: Colors.white)
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _attachTab(
    IconData icon,
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: selected ? _accent(context) : _sub(context),
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? _txt(context) : _sub(context),
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Three dots bouncing in a left-to-right wave, replacing a static "thinking…"
// label in the assistant's placeholder bubble while a reply is generating.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              // Stagger each dot's phase so they crest one after another
              // instead of all bobbing in lockstep.
              final phase = (_ctrl.value + i * 0.18) % 1.0;
              final lift = math.sin(phase * math.pi).clamp(0.0, 1.0);
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
                child: Transform.translate(
                  // Bob symmetrically around the bubble's vertical center
                  // (rest sits slightly below center, peak slightly above)
                  // instead of only travelling upward.
                  offset: Offset(0, 3 - 6 * lift),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _txt(context).withValues(alpha: 0.6 + 0.4 * lift),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/* ============================ МЕНЮ ВЫБОРА МОДЕЛИ ============================ */

class _ModelMenu extends StatelessWidget {
  final VoidCallback onManage;
  final VoidCallback onNewChat;
  final VoidCallback onCreateImage;
  const _ModelMenu({
    required this.onManage,
    required this.onNewChat,
    required this.onCreateImage,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Stack(
      children: [
        Positioned(
          top: 70,
          left: MediaQuery.of(context).size.width * 0.14,
          right: MediaQuery.of(context).size.width * 0.14,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              decoration: BoxDecoration(
                color: _card(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _stroke(context)),
                boxShadow: _shadow(context, y: 12, blur: 32),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      children: [
                        Text(
                          app.t('downloadedModels'),
                          style: TextStyle(
                            color: _sub(context),
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        if (app.loadingModels)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _sub(context),
                            ),
                          )
                        else
                          InkWell(
                            onTap: () {
                              app.buzz();
                              app.fetchModels();
                            },
                            child: Icon(
                              Icons.refresh,
                              color: _sub(context),
                              size: 18,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (app.models.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              child: Text(
                                app.modelsError ?? app.t('noModelsFound'),
                                style: TextStyle(
                                  color: _faint(context),
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          for (final m in app.models)
                            InkWell(
                              onTap: () {
                                app.buzz();
                                app.selectModel(m);
                                Navigator.pop(context);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      app.selectedModel == m
                                          ? Icons.check
                                          : Icons.circle_outlined,
                                      color: app.selectedModel == m
                                          ? _txt(context)
                                          : _faint(context),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        app.modelDisplayName(m),
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: _txt(context),
                                          fontSize: 18,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    color: _stroke(context),
                    indent: 20,
                    endIndent: 20,
                  ),
                  _menuItem(
                    context,
                    Icons.inventory_2_outlined,
                    app.t('manageModels'),
                    onManage,
                  ),
                  _menuItem(
                      context, Icons.edit_outlined, app.t('newChat'), onNewChat),
                  _menuItem(
                      context, null, app.t('createImage'), onCreateImage),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem(
      BuildContext context, IconData? icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: _txt(context), size: 20),
              const SizedBox(width: 14),
            ] else
              const SizedBox(width: 34),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _txt(context), fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ============================ ГОЛОСОВОЙ ЭКРАН ============================ */

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen>
    with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _muted = false;
  bool _available = false;
  bool _initFailed = false;
  bool _listening = false;
  bool _manualStop = false;
  String _recognized = '';
  // Text already confirmed by a previous listen session (before an
  // automatic or manual restart); the live session's words are appended
  // to this so a restart never silently drops what was already said.
  String _committedText = '';
  Timer? _autoSendTimer;
  // Drives auto-send ourselves instead of relying on the engine's own
  // `pauseFor` (which now stays open for the whole session — see _listen):
  // reset on every recognized word, fires once speech has actually paused.
  Timer? _autoSendIdleTimer;
  Timer? _listenWatchdog;
  int _listenRetries = 0;
  static const _maxListenRetries = 5;
  late final AnimationController _borderCtrl;
  // Smoothed 0..1 microphone level driving the sphere's reaction. A
  // ValueNotifier instead of setState so updates (which can fire several
  // times a second) only repaint the sphere, not the whole screen.
  final ValueNotifier<double> _soundLevel = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _borderCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _init();
  }

  void _onSpeechError(dynamic e) {
    _soundLevel.value = 0.0;
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _init({int attempt = 0}) async {
    if (!mounted) return;
    if (attempt == 0) setState(() => _initFailed = false);
    _available = await _speech.initialize(
      onStatus: _onStatus,
      onError: _onSpeechError,
    );
    // SpeechToText() is a process-wide singleton: initialize() short-circuits
    // and returns the cached result without touching its listeners once it
    // has already succeeded once in this app run, so every VoiceScreen
    // opened after the first would otherwise never get status/error
    // callbacks at all. Rebind explicitly so this screen's callbacks are
    // always the ones actually wired up, regardless of which one initialized
    // the engine.
    _speech.statusListener = _onStatus;
    _speech.errorListener = _onSpeechError;
    if (!mounted) return;
    if (_available) {
      if (!_muted) _listen();
      setState(() {});
    } else if (attempt < 2) {
      // initialize() can fail transiently right when the screen opens (mic
      // permission grant still propagating, recognition service not yet
      // bound) — retry a couple of times before surfacing an error instead
      // of giving up on the very first try.
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) _init(attempt: attempt + 1);
    } else {
      setState(() => _initFailed = true);
    }
  }

  void _retryInit() {
    if (!mounted) return;
    _listenRetries = 0;
    _init();
  }

  void _onStatus(String status) {
    if (!mounted) return;
    final wasListening = _listening;
    setState(() => _listening = status == 'listening');
    if (_listening) {
      _listenWatchdog?.cancel();
      _listenRetries = 0;
    } else {
      _soundLevel.value = 0.0;
    }
    final stoppedNaturally = wasListening && !_listening && !_manualStop;
    _manualStop = false;
    if (!stoppedNaturally || _muted) return;
    // `pauseFor` is set far longer than any real pause now (see _listen),
    // so the engine stopping on its own here is an exceptional case (a
    // platform-side hard session cap, a dropped connection, etc.) rather
    // than the normal end of a sentence — just pick the mic back up.
    _committedText = _recognized;
    _listen();
  }

  // speech_to_text reports raw, platform-dependent decibel-ish values (the
  // exact range differs between Android and iOS) rather than a normalized
  // level. Clamp to a generous range, map to 0..1, then smooth so the
  // sphere reacts to the trend of the volume rather than every noisy tick.
  void _onSoundLevel(double level) {
    final normalized = ((level + 2) / 12).clamp(0.0, 1.0);
    _soundLevel.value += (normalized - _soundLevel.value) * 0.35;
  }

  // _autoSendIdleTimer already waited out the configured pause; this extra
  // beat just lets the user see the final transcript before we navigate away.
  void _scheduleAutoSend() {
    _autoSendTimer?.cancel();
    _autoSendTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.pop(context, (_recognized, true));
    });
  }

  // The mic now stays open for the whole screen (see _listen), so silence
  // no longer stops the engine on its own — auto-send has to notice the
  // pause itself instead of reacting to a status change.
  void _resetAutoSendIdleTimer() {
    _autoSendIdleTimer?.cancel();
    if (!context.read<AppState>().micAutoSend) return;
    final pauseSeconds = context.read<AppState>().micPauseSeconds;
    _autoSendIdleTimer = Timer(Duration(seconds: pauseSeconds), () {
      if (!mounted || _muted || _recognized.trim().isEmpty) return;
      _scheduleAutoSend();
    });
  }

  void _listen() {
    if (!mounted) return;
    final app = context.read<AppState>();
    _autoSendTimer?.cancel();
    _speech
        .listen(
          onResult: (r) {
            if (!mounted) return;
            // Each listen() call starts a fresh session whose
            // recognizedWords resets to empty, so prepend whatever was
            // already committed by earlier sessions instead of dropping it.
            setState(() {
              _recognized = _committedText.isEmpty
                  ? r.recognizedWords
                  : (r.recognizedWords.isEmpty
                        ? _committedText
                        : '$_committedText ${r.recognizedWords}');
            });
            _resetAutoSendIdleTimer();
          },
          onSoundLevelChange: _onSoundLevel,
          listenOptions: stt.SpeechListenOptions(
            listenMode: stt.ListenMode.dictation,
            // Deliberately far longer than any real pause: the mic should
            // stay active for the whole screen and only stop on mute or on
            // leaving the screen, never on its own mid-sentence. Auto-send
            // detects the pause itself via _resetAutoSendIdleTimer instead.
            pauseFor: const Duration(minutes: 30),
            localeId: app.effectiveSttLanguage == 'ru' ? 'ru_RU' : 'en_US',
          ),
        )
        // On web, calling start() while the browser hasn't fully torn down a
        // previous recognition session yet throws; let the watchdog below
        // retry instead of leaving an unhandled rejection.
        .catchError((_) {});
    // The engine sometimes ignores the very first listen() call right after
    // initialize() and never reports a 'listening' status — on this device
    // it depends on a network-based recognition service, so it can take a
    // couple seconds to connect rather than failing outright. Restarting it
    // (the same recovery a manual mute/unmute toggle does) reliably kicks it
    // into gear, so do that automatically instead of making the user notice.
    // The retry itself waits a beat before re-listening, mirroring the
    // natural delay a human introduces when tapping mute then unmute.
    _listenWatchdog?.cancel();
    _listenWatchdog = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted || _muted || _listening) return;
      if (_listenRetries >= _maxListenRetries) {
        // Stop retrying silently — tell the user instead of leaving them
        // staring at "Connecting microphone…" forever with no way to know
        // it's actually given up.
        setState(() => _initFailed = true);
        return;
      }
      _listenRetries++;
      _speech.stop().then((_) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted && !_muted && !_listening) _listen();
        });
      });
    });
  }

  void _toggleMute() {
    _autoSendTimer?.cancel();
    _autoSendIdleTimer?.cancel();
    _listenWatchdog?.cancel();
    setState(() => _muted = !_muted);
    if (_muted) {
      _manualStop = true;
      _committedText = _recognized;
      _speech.stop();
    } else {
      _listenRetries = 0;
      _initFailed = false;
      _listen();
    }
  }

  void _openMicSettings(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
          backgroundColor: const Color(0xFF1A1640),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, color: Color(0xFF7C83FD)),
                    const SizedBox(width: 10),
                    Text(
                      app.t('micSettingsTitle'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.micAutoSend,
                  activeThumbColor: const Color(0xFF7C83FD),
                  title: Text(
                    app.t('micAutoSend'),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    app.t('micAutoSendDesc'),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onChanged: (v) {
                    app.setMicAutoSend(v);
                    setDialogState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  app.t('micPauseDuration'),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [1, 2, 3, 5].map((s) {
                    final selected = app.micPauseSeconds == s;
                    return ChoiceChip(
                      label: Text('${s}s'),
                      selected: selected,
                      selectedColor: const Color(0xFF7C83FD),
                      backgroundColor: Colors.white10,
                      labelStyle: TextStyle(
                        color: selected ? Colors.black : Colors.white70,
                        fontWeight: FontWeight.w500,
                      ),
                      onSelected: (_) {
                        app.setMicPauseSeconds(s);
                        setDialogState(() {});
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(
                      app.t('done'),
                      style: const TextStyle(color: Color(0xFF7C83FD)),
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

  @override
  void dispose() {
    _autoSendTimer?.cancel();
    _autoSendIdleTimer?.cancel();
    _listenWatchdog?.cancel();
    _borderCtrl.dispose();
    _soundLevel.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                radius: 1.1,
                colors: [Color(0xFF1B1640), Color(0xFF0A0818)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _toggleMute,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _muted ? Icons.mic_off : Icons.mic,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _muted ? app.t('unmute') : app.t('mute'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () => _openMicSettings(context),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: const Icon(Icons.tune, color: Colors.white),
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () =>
                              Navigator.pop(context, (_recognized, false)),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black38,
                            ),
                            child: const Icon(Icons.close, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  ParticleSphere(
                    size: 280,
                    color: const Color(0xFF7C83FD),
                    dense: true,
                    active: _listening,
                    soundLevel: _soundLevel,
                  ),
                  const SizedBox(height: 40),
                  GestureDetector(
                    onTap: _initFailed && _recognized.isEmpty
                        ? _retryInit
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _initFailed && _recognized.isEmpty
                                ? Icons.mic_off
                                : Icons.mic,
                            color: _initFailed && _recognized.isEmpty
                                ? Colors.redAccent
                                : const Color(0xFF7C83FD),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _recognized.isEmpty
                                  ? (_initFailed
                                        ? app.t('micUnavailable')
                                        : (_muted
                                              ? app.t('muted')
                                              : (_listening
                                                    ? app.t('listening')
                                                    : app.t('preparingMic'))))
                                  : _recognized,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_initFailed && _recognized.isEmpty) ...[
                            const SizedBox(width: 10),
                            Text(
                              app.t('retry'),
                              style: const TextStyle(
                                color: Color(0xFF7C83FD),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_initFailed && _recognized.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                      child: Text(
                        app.t('micUnavailableDesc'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    )
                  else if (app.micAutoSend)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                      child: Text(
                        app.t('speakNaturally'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                      child: GestureDetector(
                        onTap: _recognized.trim().isEmpty
                            ? null
                            : () => Navigator.pop(context, (_recognized, true)),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            color: _recognized.trim().isEmpty
                                ? Colors.black38
                                : const Color(0xFF7C83FD),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.arrow_upward,
                                color: _recognized.trim().isEmpty
                                    ? Colors.white38
                                    : Colors.black,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                app.t('send'),
                                style: TextStyle(
                                  color: _recognized.trim().isEmpty
                                      ? Colors.white38
                                      : Colors.black,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: BorderGlowPainter(animation: _borderCtrl, radius: 36),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.all(1.5),
                child: CustomPaint(
                  painter: GradientBorderPainter(
                    animation: _borderCtrl,
                    radius: 36,
                    strokeWidth: 3,
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

/* ============================ ЭКРАН БЕСЕД ============================ */

class ConversationsSheet extends StatefulWidget {
  // embedded == true → rendered full-height inside the chat screen's left
  // Drawer (opened by an edge swipe) instead of as a bottom sheet: drops the
  // drag handle / rounded-top / DraggableScrollableSheet sizing. The close
  // (X) button still works in both modes — closing a Drawer is done with
  // Navigator.pop too (it sits on the route's local-history stack).
  final bool embedded;
  const ConversationsSheet({super.key, this.embedded = false});
  @override
  State<ConversationsSheet> createState() => _ConversationsSheetState();
}

class _ConversationsSheetState extends State<ConversationsSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: _sheetSurface(
          context,
          rounded: false,
          child: SafeArea(child: _content(context, null)),
        ),
      );
    }
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: _sheetSurface(
          context,
          rounded: true,
          child: _content(context, scrollCtrl),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, ScrollController? scrollCtrl) {
    final app = context.watch<AppState>();
    final filtered =
        app.conversations
            .where(
              (c) =>
                  c.title.toLowerCase().contains(_query.toLowerCase()) ||
                  c.messages.any(
                    (m) =>
                        m.content.toLowerCase().contains(_query.toLowerCase()),
                  ),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Column(
          children: [
            if (!widget.embedded) ...[
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _sub(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const Spacer(),
                  Text(
                    app.t('conversations'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close, color: _txt(context)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    app.t('chats'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    app.t('chatsDesc'),
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _stat(
                        '${app.chatCount}',
                        app.t('chatsLabel'),
                        Icons.chat_bubble_outline,
                        const Color(0xFF2FE0A8),
                      ),
                      const SizedBox(width: 12),
                      _stat(
                        '${app.pinnedCount}',
                        app.t('pinnedLabel'),
                        Icons.push_pin,
                        const Color(0xFF5B8DEF),
                      ),
                      const SizedBox(width: 12),
                      _stat(
                        app.latest == null
                            ? app.t('noChatsYet')
                            : _ago(app, app.latest!.updatedAt),
                        app.t('latestLabel'),
                        Icons.schedule,
                        const Color(0xFF9B8CFF),
                        small: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _newChatBanner(app),
                  if (app.latest != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      app.t('continueSection'),
                      style: TextStyle(
                        color: _sub(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _continueCard(app.latest!, app),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    app.t('recent'),
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    _emptyRecent(app)
                  else
                    ...filtered.map((c) => _chatTile(c, app)),
                  const SizedBox(height: 16),
                  _searchField(app),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        );
  }

  Widget _stat(
    String value,
    String label,
    IconData icon,
    Color color, {
    bool small = false,
  }) {
    return Expanded(
      child: SizedBox(
        height: 150,
        child: _glassCard(
          context,
          radius: 20,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  color: _txt(context),
                  fontSize: small ? 16 : 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 12,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _newChatBanner(AppState app) {
    return GestureDetector(
      onTap: () {
        app.buzz();
        app.newChat();
        Navigator.pop(context);
      },
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFF4FACFE), _accent(context)],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.edit_outlined, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.t('newChat'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    app.t('startFresh'),
                    style: const TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _emptyRecent(AppState app) {
    return _glassCard(
      context,
      radius: 20,
      alpha: 0.4,
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _sub(context).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.chat_bubble_outline,
              color: _sub(context),
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            app.t('noChatsYet'),
            style: TextStyle(
              color: _txt(context),
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            app.t('noChatsDesc'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  app.buzz();
                  app.newChat();
                  Navigator.pop(context);
                },
                child: Container(
                  decoration: BoxDecoration(
                    gradient: _accentGradient(context),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  child: Text(
                    app.t('startNewChat'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueCard(Conversation c, AppState app) {
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          _openChatMenu(context, d.globalPosition, c, app),
      child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent(context).withValues(alpha: 0.28),
            _card2(context).withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_forward,
                  color: Colors.white,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                app.t('latestConversation'),
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _txt(context),
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${c.messages.length} ${app.t('messages')} · ${_ago(app, c.updatedAt)}',
                      style: TextStyle(color: _sub(context), fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Material(
                  color: Colors.white24,
                  child: InkWell(
                    onTap: () {
                      app.openChat(c);
                      Navigator.pop(context);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      child: Text(
                        app.t('resume'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ));
  }

  Widget _chatTile(Conversation c, AppState app) {
    final tile = ListTile(
      onTap: () {
        app.openChat(c);
        Navigator.pop(context);
      },
      leading: Icon(
        c.pinned ? Icons.push_pin : Icons.chat_bubble_outline,
        color: _txt(context),
      ),
      title: Text(
        c.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${c.messages.length} ${app.t('messages')} · ${_ago(app, c.updatedAt)}',
        style: TextStyle(color: _sub(context)),
      ),
      trailing: _chatTileMenuButton(c, app),
    );
    return GestureDetector(
      // Right-click anywhere on the row → context menu (rename / pin / delete).
      onSecondaryTapDown: (d) =>
          _openChatMenu(context, d.globalPosition, c, app),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: _isGlass(context)
            ? GlassSurface(
                borderRadius: BorderRadius.circular(16),
                child: Material(type: MaterialType.transparency, child: tile),
              )
            : Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Material(
                  color: _card(context).withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(16),
                  child: tile,
                ),
              ),
      ),
    );
  }

  // Chat context menu (rename / pin / delete-with-undo) — delegates to the
  // shared top-level helper (also used by the desktop sidebar).
  Future<void> _openChatMenu(
          BuildContext ctx, Offset pos, Conversation c, AppState app) =>
      showChatContextMenu(ctx, pos, c, app);

  // Overflow (⋮) button for a chat row — opens the shared menu at the button.
  Widget _chatTileMenuButton(Conversation c, AppState app) {
    return Builder(
      builder: (btnCtx) => IconButton(
        icon: Icon(Icons.more_vert, color: _sub(context)),
        onPressed: () {
          final box = btnCtx.findRenderObject() as RenderBox?;
          final pos =
              box != null ? box.localToGlobal(Offset.zero) : Offset.zero;
          _openChatMenu(context, pos, c, app);
        },
      ),
    );
  }

  Widget _searchField(AppState app) {
    final field = TextField(
      style: TextStyle(color: _txt(context)),
      onChanged: (v) => setState(() => _query = v),
      decoration: InputDecoration(
        hintText: app.t('searchChats'),
        hintStyle: TextStyle(color: _sub(context)),
        prefixIcon: Icon(Icons.search, color: _sub(context)),
        filled: !_isGlass(context),
        fillColor: _card(context).withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
      ),
    );
    if (_isGlass(context)) {
      return GlassSurface(borderRadius: BorderRadius.circular(28), child: field);
    }
    return field;
  }

  String _ago(AppState app, DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return app.t('justNow');
    if (d.inMinutes < 60) return '${d.inMinutes} ${app.t('minAgo')}';
    if (d.inHours < 24) return '${d.inHours} ${app.t('hAgo')}';
    return '${d.inDays} ${app.t('dAgo')}';
  }
}

/* ============================ ЭКРАН НАСТРОЕК ============================ */

