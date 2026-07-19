part of '../main.dart';

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

  // ---- Elevated launches (bypass the per-launch UAC prompt) ---------------
  // The UAC dialog cannot be auto-confirmed (it lives on the secure desktop by
  // design). Instead, a Task Scheduler task with "run with highest privileges"
  // is created ONCE with a single UAC consent; `schtasks /run` then starts it
  // silently. Only the specific pinned commands are pre-authorized — UAC stays
  // fully enabled for everything else.

  // Stable task name for a launch target (djb2 — String.hashCode is not
  // guaranteed stable across Dart versions, task names must survive updates).
  static String elevatedTaskName(String value) {
    var h = 5381;
    for (final u in value.toLowerCase().codeUnits) {
      h = ((h << 5) + h + u) & 0x7fffffff;
    }
    return 'EVS\\cmd_${h.toRadixString(16)}';
  }

  // The action the task runs — mirrors the normal launch paths below.
  static String _taskAction(VoiceCommand c) {
    if (c.type == VoiceCommandType.shell) return 'cmd /c ${c.value}';
    final target = _unquote(c.value);
    return 'cmd /c start \\"\\" \\"$target\\"';
  }

  Future<bool> _taskExists(String tn) async {
    try {
      final r = await io.Process.run('schtasks', ['/query', '/tn', tn],
          runInShell: false);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Create (or overwrite) the pre-authorized task for [c]. Pops ONE UAC
  /// prompt; returns true when the task verifiably exists afterwards.
  Future<bool> ensureElevatedTask(VoiceCommand c) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return false;
    final tn = elevatedTaskName(c.value);
    try {
      // A batch script dodges the nested-quoting maze of RunAs; /sc onlogon +
      // /disable = the task never fires on its own, it only exists to be /run.
      final dir = await io.Directory.systemTemp.createTemp('evs_task');
      final script = io.File('${dir.path}\\create_task.cmd');
      await script.writeAsString('@echo off\r\n'
          'schtasks /create /tn "$tn" /tr "${_taskAction(c)}" '
          '/sc onlogon /rl highest /f\r\n'
          'if errorlevel 1 exit /b 1\r\n'
          'schtasks /change /tn "$tn" /disable\r\n');
      final r = await io.Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'try { \$p = Start-Process -Verb RunAs -Wait -PassThru '
            '-WindowStyle Hidden -FilePath cmd.exe '
            "-ArgumentList '/c','\"${script.path}\"'; exit \$p.ExitCode } "
            'catch { exit 1 }',
      ]);
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      if (r.exitCode != 0) return false;
      return _taskExists(tn);
    } catch (_) {
      return false;
    }
  }

  /// Best-effort cleanup when an elevated command is removed/downgraded. An
  /// unelevated delete of a highest-privilege task usually fails — that's fine,
  /// a leftover disabled manual-run task is harmless, and popping a surprise
  /// UAC prompt for cleanup would be worse.
  Future<void> tryDeleteElevatedTask(String value) async {
    try {
      await io.Process.run(
          'schtasks', ['/delete', '/tn', elevatedTaskName(value), '/f'],
          runInShell: false);
    } catch (_) {}
  }

  Future<bool> execute(VoiceCommand c) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return false;
    // Pre-authorized elevated launch (no UAC prompt). Falls through to the
    // normal path if the task has gone missing (e.g. deleted by hand).
    if (c.elevated) {
      try {
        final r = await io.Process.run(
            'schtasks', ['/run', '/tn', elevatedTaskName(c.value)],
            runInShell: false);
        if (r.exitCode == 0) return true;
      } catch (_) {}
    }
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
      'https://raw.githubusercontent.com/kekw2077/enhanced-voice-system/main/test1/dist/appcast.xml';

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
    // Ambient-animation gating: subscribe the policy to the activity signals
    // (assistant speech/thinking, wake hits, loud mic) once per launch.
    MotionPolicy.bindSignals();
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
    MotionPolicy.setWindowVisible(true);
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
      // Hidden in the tray: freeze all ambient animation so the idle app stops
      // burning a core repainting frames nobody can see.
      MotionPolicy.setWindowVisible(false);
    } else {
      _quit();
    }
  }

  @override
  void onWindowMinimize() {
    if (_app?.minimizeToTray ?? false) windowManager.hide();
    MotionPolicy.setWindowVisible(false);
  }

  @override
  void onWindowRestore() => MotionPolicy.setWindowVisible(true);

  @override
  void onWindowFocus() {
    MotionPolicy.setWindowVisible(true);
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
