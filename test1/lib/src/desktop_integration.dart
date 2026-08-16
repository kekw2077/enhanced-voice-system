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
      // Scratch dir under the app's own data root (<exeDir>\userdata), never
      // the system temp: EVS keeps everything it writes on the drive it is
      // installed on.
      final dir = await io.Directory(
              '${await appDataRoot()}${io.Platform.pathSeparator}tmp')
          .createTemp('evs_task');
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

// ==================== PUSH-TO-TALK: УДЕРЖАНИЕ КЛАВИШИ ====================

typedef _GetAsyncKeyStateNative = Int16 Function(Int32);
typedef _GetAsyncKeyStateDart = int Function(int);

/// Следит за комбинацией Push-to-Talk и превращает её в «зажал / отпустил».
///
/// Почему опрос, а не хоткей: `hotkey_manager` на Windows физически не может
/// сообщить об отпускании — нативный плагин шлёт только `onKeyDown`, потому что
/// `RegisterHotKey` присылает единственное сообщение `WM_HOTKEY` на нажатие.
/// `GetAsyncKeyState` читает состояние клавиатуры, ничего не перехватывая: если
/// на PTT назначена обычная буква, она продолжает работать во всех остальных
/// программах. `RegisterHotKey` её бы, наоборот, проглотил системно — для
/// комбинации с модификатором это удобно, а для одиночной клавиши означало бы,
/// что её больше нигде не набрать, пока EVS запущен.
class PttWatcher {
  PttWatcher._();
  static final PttWatcher instance = PttWatcher._();

  _GetAsyncKeyStateDart? _fn;
  bool _tried = false;
  Timer? _timer;
  List<int> _vks = const [];
  bool _down = false;

  _GetAsyncKeyStateDart? get _get {
    if (!_tried) {
      _tried = true;
      try {
        _fn = DynamicLibrary.open('user32.dll').lookupFunction<
            _GetAsyncKeyStateNative, _GetAsyncKeyStateDart>('GetAsyncKeyState');
      } catch (_) {}
    }
    return _fn;
  }

  /// Подписаться на настройки: опрос живёт ровно пока выбран режим «по нажатию»
  /// и комбинация назначена.
  void bind(AppState app) {
    app.addListener(() => apply(app));
    apply(app);
  }

  void apply(AppState app) {
    if (app.listenMode != 'ptt' || app.pttKeys.isEmpty) {
      _stop();
      return;
    }
    _vks = app.pttKeys;
    if (_timer != null) return;
    if (_get == null) {
      // Не Windows или user32 не открылась. Молча ничего не делать нельзя:
      // снаружи это выглядит как «Push-to-Talk просто не работает».
      unawaited(appendLog('errors', 'PTT: GetAsyncKeyState недоступна'));
      return;
    }
    // 30 мс: задержка на слух незаметна, а нагрузка — три чтения состояния
    // клавиатуры в такт, то есть около сотни вызовов в секунду.
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) => _poll());
    unawaited(appendLog('sidecar', 'PTT: опрос включён (${app.pttLabel})'));
  }

  void _stop() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    unawaited(appendLog('sidecar', 'PTT: опрос выключен'));
    if (_down) {
      _down = false;
      VoiceAssistant.instance.pttRelease();
    }
  }

  void _poll() {
    final fn = _get;
    if (fn == null || _vks.isEmpty) return;
    var all = true;
    for (final vk in _vks) {
      // Старший бит = клавиша зажата сейчас. Младший («нажималась с прошлого
      // вызова») намеренно не трогаем: он сбрасывается чтением и увёл бы
      // состояние в разнос при двух читателях.
      if (fn(vk) & 0x8000 == 0) {
        all = false;
        break;
      }
    }
    if (all == _down) return;
    _down = all;
    if (all) {
      VoiceAssistant.instance.pttPress();
    } else {
      VoiceAssistant.instance.pttRelease();
    }
  }
}

/// Virtual-key коды Windows для клавиши из записанной комбинации. Левый и
/// правый модификаторы сводятся к общему коду: пользователь жмёт «Shift», а не
/// «правый Shift», и требовать ту же половину клавиатуры было бы придиркой.
int? pttVkFor(PhysicalKeyboardKey key) {
  const ctrl = [
    PhysicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlRight
  ];
  const shift = [
    PhysicalKeyboardKey.shiftLeft,
    PhysicalKeyboardKey.shiftRight
  ];
  const alt = [PhysicalKeyboardKey.altLeft, PhysicalKeyboardKey.altRight];
  if (ctrl.contains(key)) return 0x11; // VK_CONTROL
  if (shift.contains(key)) return 0x10; // VK_SHIFT
  if (alt.contains(key)) return 0x12; // VK_MENU
  return key.keyCode;
}

/// Подпись клавиши для капсов в настройках. `debugName` даёт «Key G» / «Digit
/// 1» — сокращаем до того, что написано на самой клавише.
String pttKeyLabel(PhysicalKeyboardKey key) {
  const named = <int, String>{
    0x000700e0: 'Ctrl', 0x000700e4: 'Ctrl',
    0x000700e1: 'Shift', 0x000700e5: 'Shift',
    0x000700e2: 'Alt', 0x000700e6: 'Alt',
    0x000700e3: 'Win', 0x000700e7: 'Win',
  };
  final fixed = named[key.usbHidUsage];
  if (fixed != null) return fixed;
  final n = key.debugName ?? '';
  if (n.startsWith('Key ')) return n.substring(4);
  if (n.startsWith('Digit ')) return n.substring(6);
  if (n.startsWith('Numpad ')) return 'Num ${n.substring(7)}';
  return n.isEmpty ? '?' : n;
}

/// Подсказка покоя для режима Push-to-Talk, или null в обычном режиме.
/// Одна на все стили — чтобы следующий не написал свою, снова про «Айрис».
String? pttIdleHint(AppState app) {
  if (app.listenMode != 'ptt') return null;
  if (app.pttLabel.isEmpty) return app.t('pttHintUnset');
  return '${app.t('pttHintHold')}: ${app.pttLabel}';
}

/// Чем ассистента зовут прямо сейчас: слово-активатор или комбинация
/// удержания. Пусто — режим удержания выбран, а клавиши ещё не назначены.
String activatorLabel(AppState app) =>
    app.listenMode == 'ptt' ? app.pttLabel : '«${app.wakeWord}»';

/// Название активного движка распознавания для строк состояния. Одна на все
/// стили: три копии тернарника «gigaam или whisper» и так уже разъезжались,
/// а на третьем движке разъехались бы наверняка.
String sttEngineLabel(AppState app) => switch (_sttEngineNow(app)) {
      'gigaam' => 'GigaAM-v3',
      'remote' => app.t('engRemoteName'),
      _ => 'Whisper · ${app.whisperModel}',
    };

/// Чем именно распознаётся — нижняя строка телеметрии.
String sttRuntimeLabel(AppState app) {
  // Выбран сервер, а работает локальная модель — нижняя строка объясняет
  // почему, вместо названия библиотеки.
  if (app.sttSidecarEngine == 'remote' && _sttEngineNow(app) != 'remote') {
    return app.t('engRemoteLocalNow');
  }
  return switch (_sttEngineNow(app)) {
    'gigaam' => 'sherpa-onnx',
    'remote' => app.sttRemoteModel.isEmpty ? 'HTTP' : app.sttRemoteModel,
    _ => 'faster-whisper',
  };
}

/// Движок, о котором говорят подписи: выбранный — пока сайдкар не сказал, что
/// распознаёт другим. Выбор «на сервере» при молчащем сервере не отменяется
/// (сайдкар вернётся туда сам), но и показывать сервер, когда работает
/// локальная модель, нельзя — с этого начинается «распознаёт хуже, чем вчера».
String _sttEngineNow(AppState app) {
  final live = app.sttEngineLive;
  if (live.isEmpty || !AppState.kSttSidecarEngines.contains(live)) {
    return app.sttSidecarEngine;
  }
  return live;
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
    // Свой сервер обновлений из настроек. Ниже переменной окружения намеренно:
    // та ставится ради отладочного канала и должна перебивать всё остальное.
    final own = instance._app?.updateUrlFor('appcast.xml');
    if (own != null) return own;
    return updateFeedUrl;
  }

  AppState? _app;
  Timer? _winSaveTimer;

  Future<void> init(AppState app) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _app = app;
    // Карточка загрузки ушла — если виджет выключен, самое время показать
    // главное окно: пока она висела, оно намеренно было скрыто. Ставится ДО
    // всего остального: свались что-нибудь ниже, окно так и не появилось бы.
    BootSplash.instance.onDone = () {
      final a = _app;
      if (a == null) return;
      // Порядок важен: сначала виджет (у него свой процесс и своё окно), потом
      // главное окно — чтобы фокус остался на нём, а не уехал на виджет.
      unawaited(VizOverlayServer.instance.start(a));
      if (a.startupShowWindow) unawaited(_show());
      unawaited(_rebuildTrayMenu()); // «Загрузка…» → обычное меню
    };
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
      // Распознавание отдано системному движку — сигнала `ready` от сайдкара не
      // будет вовсе, и окну загрузки ждать нечего.
      if (app.sttEngine != 'whisper') {
        unawaited(BootSplash.instance.finish());
      }
      VoiceAssistant.instance.attach(app);
      // Push-to-Talk: опрос клавиатуры включается сам, когда выбран режим «по
      // нажатию» и назначена комбинация.
      PttWatcher.instance.bind(app);
      // Bring the remote-input listener up if it was left enabled (TZ §14).
      if (app.remoteInputEnabled) RemoteInputServer.instance.start(app);

      // Auto-update (Discord-style): AppUpdater silently downloads the new
      // installer in the background and shows an in-app "restart to update"
      // banner — no native WinSparkle prompts.
      // Проверка обновлений идёт параллельно и на готовность не влияет — она
      // отражается побочной строкой окна загрузки, а не основной подписью.
      AppUpdater.instance.status.addListener(() {
        BootSplash.instance.note(switch (AppUpdater.instance.status.value) {
          UpdateStatus.checking => 'bootNoteUpdCheck',
          UpdateStatus.downloading => 'bootNoteUpdDownload',
          UpdateStatus.ready => 'bootNoteUpdReady',
          _ => '',
        });
      });
      AppUpdater.instance.start(app);

      // Verify CosyVoice reachability once at launch; an unavailable server
      // auto-reverts the TTS engine to Piper (§3.2) so speech never silently
      // breaks and the app doesn't stay stuck on an unreachable engine.
      unawaited(app.checkCosyvoiceOnStartup());

      // Floating widget: separate process, fed over a localhost WebSocket.
      // Spawns immediately when enabled (the chat window itself may stay
      // hidden — see main()).
      // Виджет — тоже «окно программы»: поднимать его, пока движок грузится,
      // значит предлагать нажать на то, что ещё не работает. Пока висит
      // карточка загрузки, ждём; поднимет его onDone вместе с главным окном.
      if (!BootSplash.instance.active) {
        unawaited(VizOverlayServer.instance.start(app));
      }

      // Widget-first startup: the native runner re-shows the window on the
      // first frame AFTER main()'s early hide — hide again once rendering
      // has settled so only the widget and tray remain.
      if (!app.startupShowWindow || BootSplash.instance.active) {
        unawaited(Future.delayed(const Duration(milliseconds: 900), () async {
          if (!(_app?.startupShowWindow ?? true) ||
              BootSplash.instance.active) {
            await windowManager.hide();
          }
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
      // Окно загрузки закрывается по `ready` — это и есть «готова слушать».
      // `connected` тут не годится: он значит лишь поднятый WebSocket, а модели
      // после него грузятся ещё пару секунд.
      SidecarClient.instance.status.addListener(() {
        if (SidecarClient.instance.status.value == SidecarStatus.connected) {
          BootSplash.instance.phase('connect');
        }
      });
      SidecarClient.instance.sttState.addListener(() {
        switch (SidecarClient.instance.sttState.value) {
          case 'loading_models':
            BootSplash.instance.phase('models');
          case 'ready':
            unawaited(BootSplash.instance.finish());
          case 'error':
            unawaited(BootSplash.instance.finish(failed: true));
        }
      });
      // До загрузки списка: иначе первый запрос уйдёт на GitHub, даже когда
      // задан свой сервер.
      ComponentManager.instance.app = app;
      await ComponentManager.instance.loadManifest();
      // Apply any update staged on a previous run (before the exe is launched).
      await ComponentManager.instance.applyStagedUpdates();
      SidecarClient.instance.setSttModel(app.whisperModel);
      // Адрес сервера распознавания — до выбора движка: он же уезжает в
      // аргументы запуска сайдкара, и «на сервере» должен подняться сразу с
      // адресом, а не с пустым.
      await SidecarClient.instance.setSttRemote(
          url: app.sttRemoteUrl,
          model: app.sttRemoteModel,
          key: app.sttRemoteKey);
      await SidecarClient.instance.setSttLocalEngine(app.sttLocalEngine);
      await SidecarClient.instance.setSttEngine(app.sttSidecarEngine);
      // Чем распознаётся на самом деле. Слушаем здесь, а не в карточке
      // настроек: сервер может отвалиться, когда настройки закрыты, и тогда
      // подписи в интерфейсе продолжали показывать «на сервере».
      SidecarClient.instance.activeSttEngine.addListener(
          () => app.setSttEngineLive(
              SidecarClient.instance.activeSttEngine.value));
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
        // Первый запуск: компонент в сотню мегабайт качается прямо сейчас, и
        // это единственный этап с настоящим процентом — показываем его.
        final st = ComponentManager.instance.statusOf('sidecar');
        void onProgress() =>
            BootSplash.instance.phase('component', value: st.value.progress);
        st.addListener(onProgress);
        onProgress();
        await ComponentManager.instance.ensure('sidecar');
        st.removeListener(onProgress);
      } else {
        unawaited(ComponentManager.instance.stageUpdate('sidecar'));
      }
      BootSplash.instance.phase('sidecar');
      // The CPU voice clone (XTTS) was removed — reclaim its ~8 GB component and
      // caches from disk (idempotent no-op once gone).
      unawaited(ComponentManager.instance.purgeClone());
      // Движок прежнего формата (один файл) — те же 212 МБ впустую, что и у
      // клон-голоса выше. Зовётся ПОСЛЕ hasLocalSidecar/ensure: к этому моменту
      // рабочая распакованная папка точно на месте.
      unawaited(ComponentManager.instance.purgeLegacySidecar());
      await SidecarClient.instance.start();
      // Push game-mode config (thresholds, exclusions, localized phrases) now
      // that the socket is up; the sidecar started the monitor with defaults.
      app.applyGameModeConfig();
      // Clone server (GPU): activate it as the TTS engine if configured, and
      // follow game mode so it releases/reclaims VRAM with the game.
      app.hookCloneGpuGameMode();
      unawaited(app.applyCloneServer());
      unawaited(app.syncActiveMics()); // resolve multi-mic devices (block 8.2)
    } catch (_) {
      // Сайдкар не поднялся — готовности не будет, держать окно загрузки не за
      // чем. Ошибку показываем в нём же, а не роняем окно молча.
      unawaited(BootSplash.instance.finish(failed: true));
    }
  }

  Future<void> _rebuildTrayMenu() async {
    final app = _app;
    // Пока идёт загрузка, «Показать EVS» всё равно ничего не откроет — значит
    // и предлагать его нельзя: неактивный пункт честнее кнопки, которая молча
    // не срабатывает. Меню пересобирается по готовности (BootSplash.onDone).
    if (BootSplash.instance.active) {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(
            key: 'loading',
            label: app?.t('trayLoading') ?? 'Загрузка…',
            disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: app?.t('trayQuit') ?? 'Quit'),
      ]));
      return;
    }
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
    // Пока идёт загрузка, окно открывать нечему: движок ещё не поднят, команды
    // не принимаются, а на экране висит карточка загрузки. Раньше окно можно
    // было вытащить из трея прямо поверх неё и получить наполовину живое
    // приложение. Единственная точка входа — сюда сходятся и трей, и горячая
    // клавиша, и повторный запуск.
    if (BootSplash.instance.active) {
      unawaited(appendLog('sidecar', 'показ окна отложен: идёт загрузка'));
      return;
    }
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
      // Сервер клона держит модель в VRAM — просим освободить её штатно, пока
      // процесс ещё жив; ProcessJob потом просто добьёт остаток.
      final app = _app;
      if (app != null && CloneServer.instance.isRunning) {
        await CloneServer.instance.stop(app);
      }
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

// ==================== ЛОКАЛЬНЫЙ СЕРВЕР СИНТЕЗА ====================
// Кнопка «запустить/остановить» для sidecar/qwen_tts_server.py — того самого
// сервера клон-голоса на видеокарте, который до сих пор поднимали руками из
// консоли. Приложение с ним и так умеет разговаривать (движок озвучки
// «Клон (сервер)» шлёт HTTP на cosyvoiceEndpoint) — здесь добавляется только
// управление его жизненным циклом, без единого нового протокола.
//
// Почему не просто Process.start: сервер держит модель в VRAM, и осиротевший
// процесс занимал бы видеопамять до перезагрузки. ProcessJob (см. выше) кладёт
// его в Job Object с KILL_ON_JOB_CLOSE — он умрёт вместе с приложением даже
// при аварийном завершении.

enum CloneServerState { stopped, starting, running, failed }

class CloneServer {
  CloneServer._();
  static final CloneServer instance = CloneServer._();

  final ValueNotifier<CloneServerState> state =
      ValueNotifier(CloneServerState.stopped);

  /// Причина отказа для подписи под кнопкой (пусто, если всё хорошо).
  final ValueNotifier<String> problem = ValueNotifier('');

  io.Process? _proc;
  bool _busy = false;

  bool get isRunning => state.value == CloneServerState.running;

  /// Порт из адреса в настройках; 8760 — тот же дефолт, что у самого скрипта.
  static int portOf(String endpoint) {
    final p = Uri.tryParse(endpoint.trim())?.port ?? 0;
    return p == 0 ? 8760 : p;
  }

  /// Скрипт лежит в ассетах и разворачивается рядом с данными: в установленной
  /// версии папки sidecar/ нет, а держать вторую копию в репозитории — верный
  /// способ забыть про неё при правке.
  Future<String?> _ensureScript() async {
    try {
      final dir = io.Directory(
          '${await appDataRoot()}${io.Platform.pathSeparator}tts-server');
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = io.File(
          '${dir.path}${io.Platform.pathSeparator}qwen_tts_server.py');
      final data = await rootBundle.load('sidecar/qwen_tts_server.py');
      final bytes = data.buffer.asUint8List();
      // Перезаписываем только при отличии — иначе каждый запуск трогает файл.
      if (!await f.exists() || (await f.length()) != bytes.length) {
        await f.writeAsBytes(bytes, flush: true);
      }
      return f.path;
    } catch (e) {
      unawaited(appendLog('errors', 'CloneServer script: $e'));
      return null;
    }
  }

  /// Интерпретатор с torch+CUDA. Сначала — заданный руками, иначе ищем сами.
  Future<String?> resolvePython(AppState app) async {
    final manual = app.cloneServerPython.trim();
    if (manual.isNotEmpty) {
      return await io.File(manual).exists() ? manual : null;
    }
    final sep = io.Platform.pathSeparator;
    final candidates = <String>[];
    // Рядом с приложением и вверх по дереву — так найдётся venv из репозитория
    // на машине разработки.
    var dir = io.File(io.Platform.resolvedExecutable).parent;
    for (var i = 0; i < 7; i++) {
      candidates.add('${dir.path}${sep}sidecar$sep.venv-gpu${sep}Scripts'
          '${sep}python.exe');
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    try {
      candidates.add('${await appDataRoot()}${sep}tts-server$sep.venv'
          '${sep}Scripts${sep}python.exe');
    } catch (_) {}
    for (final c in candidates) {
      if (await io.File(c).exists()) return c;
    }
    return null;
  }

  Future<void> start(AppState app) async {
    if (_busy || isRunning) return;
    _busy = true;
    problem.value = '';
    state.value = CloneServerState.starting;
    try {
      final py = await resolvePython(app);
      if (py == null) {
        problem.value = app.t('cloneSrvNoPython');
        state.value = CloneServerState.failed;
        return;
      }
      final script = await _ensureScript();
      if (script == null) {
        problem.value = app.t('cloneSrvNoScript');
        state.value = CloneServerState.failed;
        return;
      }
      final port = portOf(app.cosyvoiceEndpoint);
      // Веса (~4 ГБ) кладём в общий кэш EVS на диске установки, а не в профиль
      // пользователя на C: — сервер уважает EVS_QWEN_CACHE.
      final env = <String, String>{};
      try {
        env['EVS_QWEN_CACHE'] =
            '${await componentsDirPath()}${io.Platform.pathSeparator}hf-cache';
      } catch (_) {}
      _proc = await io.Process.start(
        py,
        [script, '--port', '$port'],
        runInShell: false,
        environment: env,
      );
      ProcessJob.instance.add(_proc!.pid); // умрёт вместе с приложением
      final up = Completer<void>();
      // Сервер печатает всё в stderr с префиксом [qwen-tts]; строка про
      // listening — его аналог EVS_SIDECAR_READY у сайдкара.
      _proc!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final t = line.trim();
        if (t.isEmpty) return;
        unawaited(appendLog('tts-server', t));
        if (!up.isCompleted && t.contains('listening on http')) up.complete();
      });
      _proc!.exitCode.then((code) {
        _proc = null;
        if (!up.isCompleted) {
          problem.value = '${app.t('cloneSrvExited')} ($code)';
          state.value = CloneServerState.failed;
        } else {
          state.value = CloneServerState.stopped;
        }
      });
      // Импорт torch на холодную занимает десятки секунд — таймаут щедрый.
      await up.future.timeout(const Duration(seconds: 180));
      state.value = CloneServerState.running;
      if (app.cosyvoiceEndpoint.trim().isEmpty) {
        app.setCosyvoiceEndpoint('http://127.0.0.1:$port');
      }
      unawaited(app.checkCosyvoice());
    } catch (e) {
      unawaited(appendLog('errors', 'CloneServer start: $e'));
      if (state.value != CloneServerState.failed) {
        problem.value = app.t('cloneSrvFailed');
        state.value = CloneServerState.failed;
      }
      try {
        _proc?.kill();
      } catch (_) {}
      _proc = null;
    } finally {
      _busy = false;
    }
  }

  Future<void> stop(AppState app) async {
    if (_busy) return;
    _busy = true;
    try {
      // Сначала попросить освободить VRAM штатно: /unload сервер умеет, а
      // при kill его finally уже не отработает.
      final ep = app.cosyvoiceEndpoint.trim();
      if (ep.isNotEmpty) {
        try {
          await http
              .post(Uri.parse('$ep/unload'))
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      try {
        _proc?.kill();
      } catch (_) {}
      _proc = null;
      state.value = CloneServerState.stopped;
      problem.value = '';
    } finally {
      _busy = false;
    }
  }
}

// ============================ ЖУРНАЛ ============================
// Чтение append-only логов, которые пишет appendLog(...) в <app-data>/logs.
// Один источник на всё приложение: экран журнала «Ноктюрна» и страница
// «Журнал» в настройках (её открывает и рейл Nexus) читают отсюда, а не
// каждый по-своему.

/// Одна строка журнала, разобранная из файла формата `<iso>  <текст>`.
class EvsLogLine {
  const EvsLogLine(this.time, this.source, this.text, this.level);
  final DateTime? time;

  /// Группа фильтра (см. [EvsLogFeed.sources]); подпись — [EvsLogFeed.labelKey].
  final String source;
  final String text;

  /// success | warn | accent | danger — токен цвета, не сам цвет.
  final String level;
}

class EvsLogFeed {
  EvsLogFeed._();

  /// Файл → (группа фильтра, уровень). Ровно те имена, которыми пишет
  /// appendLog(...) по всему проекту, плюс лог установщика обновления.
  static const Map<String, (String, String)> sources = {
    'sidecar': ('voice', 'warn'),
    'commands': ('commands', 'success'),
    'remote': ('remote', 'accent'),
    'chat': ('model', 'accent'),
    'errors': ('errors', 'danger'),
    'update-runner': ('updates', 'accent'),
    'tts-server': ('voice', 'warn'),
  };

  /// Ключ i18n для подписи группы.
  static String labelKey(String source) => switch (source) {
        'voice' => 'ncLogVoice',
        'model' => 'ncLogModel',
        'commands' => 'ncTabCommands',
        'remote' => 'ncLogRemote',
        'updates' => 'ncLogUpdates',
        _ => 'ncLogErrors',
      };

  static String clock(DateTime? t) => t == null
      ? '--:--:--'
      : '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';

  static Future<String> dir() async =>
      '${await appDataRoot()}${io.Platform.pathSeparator}logs';

  /// Свежий срез журнала, новые записи сверху. [tail] — сколько последних строк
  /// брать из каждого файла: файлы дописываются вечно, а на экране нужен хвост.
  static Future<List<EvsLogLine>> load({int tail = 400}) async {
    final out = <EvsLogLine>[];
    try {
      final root = await appDataRoot();
      final sep = io.Platform.pathSeparator;
      for (final e in sources.entries) {
        // update-runner лежит в корне данных, остальные — в logs/.
        final path = e.key == 'update-runner'
            ? '$root$sep${e.key}.log'
            : '$root${sep}logs$sep${e.key}.log';
        final f = io.File(path);
        if (!await f.exists()) continue;
        final all = await f.readAsLines();
        final slice = all.length > tail ? all.sublist(all.length - tail) : all;
        for (final raw in slice) {
          if (raw.trim().isEmpty) continue;
          DateTime? ts;
          var text = raw;
          final sp = raw.indexOf('  ');
          if (sp > 0) {
            ts = DateTime.tryParse(raw.substring(0, sp));
            if (ts != null) text = raw.substring(sp + 2);
          }
          out.add(EvsLogLine(ts, e.value.$1, text, e.value.$2));
        }
      }
    } catch (_) {}
    out.sort((a, b) => (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)));
    return out;
  }

  /// Открыть папку логов в проводнике.
  static Future<void> openFolder() async {
    try {
      final d = await dir();
      if (await io.Directory(d).exists()) await io.Process.run('explorer', [d]);
    } catch (_) {}
  }

  /// Журнал как текст — для кнопки «Копировать».
  static String asText(List<EvsLogLine> lines) => lines
      .map((l) => '${clock(l.time)}  ${l.source}  ${l.text}')
      .join('\n');
}

// ============================ WEB SEARCH ============================
// RAG web search: fetch a few results for a query and format them as a compact
// context block fed to the model, so the assistant can answer with fresh info
// (exchange rates, weather, news…). Provider order: Tavily (key) → Brave (key)
// → keyless DuckDuckGo HTML scrape. Every network call is wrapped so a failure
// just yields an empty result and the model answers as it normally would.
