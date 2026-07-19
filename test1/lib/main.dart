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
part 'src/bootstrap.dart';
part 'src/i18n.dart';
part 'src/models.dart';
part 'src/llm_services.dart';
part 'src/app_state.dart';
part 'src/theme_widgets.dart';
part 'src/desktop_integration.dart';
part 'src/updater_and_web.dart';
part 'src/sidecar_client.dart';
part 'src/desktop_home.dart';
part 'src/remote_input.dart';
part 'src/voice_viz.dart';
part 'src/desktop_settings.dart';
part 'src/chat_screen.dart';
part 'src/voice_screen.dart';
part 'src/settings_screens.dart';

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


final ValueNotifier<(String, String, int)?> vizNotice = ValueNotifier(null);


/* ----------------------- EVS DESKTOP SETTINGS ----------------------------
   Left-nav settings with 7 sections (evs_s1..s7.html). Controls bind to the
   existing AppState/Personalization; genuinely-new areas are shown as UI with
   stub state until their native phase lands. */

// A user-defined voice command (Voice Commands catalog). Execution comes in
// the native phase; the type maps to how `value` is interpreted.
// A phone authorized to send remote commands (TZ §14). The token is a secret —
// shown masked in the UI, matched verbatim by the server. lastSeen is ISO-8601
// or '' if never seen.
