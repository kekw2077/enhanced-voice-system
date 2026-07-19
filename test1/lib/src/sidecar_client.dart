part of '../main.dart';

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
  int _vadAggr = 3; // webrtcvad aggressiveness 0..3 (higher = stricter / less sensitive)
  Map<String, dynamic>? _ttsFx; // voice post-FX config
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
    _send({'type': 'stt.config', 'model': _sttModel, 'vad': _vadAggr});
    if (_ttsFx != null) _send({'type': 'tts.config', 'fx': _ttsFx});
    if (_cloneEnabled) unawaited(_pushClone());
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
                'xtts': te['xtts'] == true,
                'cosyvoice': te['cosyvoice'] == true,
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
          // Clone phrase-cache pre-render progress (done/total + phase).
          case 'tts.prerender':
            prerenderProgress.value = (
              (m['done'] as num?)?.toInt() ?? 0,
              (m['total'] as num?)?.toInt() ?? 0,
              m['state'] as String? ?? '',
            );
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
  Future<void> setVadAggressiveness(int n) async {
    _vadAggr = n.clamp(0, 3);
    _send({'type': 'stt.config', 'vad': _vadAggr});
  }

  Future<void> setTtsFx(Map<String, dynamic> fx) async {
    _ttsFx = fx;
    _send({'type': 'tts.config', 'fx': fx});
  }

  // ---- Voice clone (XTTS) — engine-agnostic phrase cache, shared with
  // CosyVoice. State is retained so a reconnect re-applies it. -------------
  bool _cloneEnabled = false;
  String _cloneRef = '';
  String _cloneLang = 'ru';
  List<String> _clonePhrases = const [];
  // (done, total, state) where state is 'start' | '' | 'done' | 'skip' | 'error'.
  final ValueNotifier<(int, int, String)> prerenderProgress =
      ValueNotifier((0, 0, ''));

  Future<String> _cloneCacheDir() async {
    final sep = io.Platform.pathSeparator;
    final models = await modelsDirPath();
    final parent = io.Directory(models).parent.path;
    final dir = '$parent${sep}clone_cache';
    try {
      await io.Directory(dir).create(recursive: true);
    } catch (_) {}
    return dir;
  }

  Future<String> _voiceFingerprint(String path) async {
    try {
      final st = await io.File(path).stat();
      final base = path.split(io.Platform.pathSeparator).last;
      return '${base}_${st.size}_${st.modified.millisecondsSinceEpoch}'
          .hashCode
          .toRadixString(16);
    } catch (_) {
      return 'na';
    }
  }

  // Configure the voice-clone engine (or hand back to Piper when disabled) and
  // pre-render the fixed phrases into the shared cache. `ref` is a WAV sample.
  Future<void> applyClone({
    required bool enabled,
    String ref = '',
    String lang = 'ru',
    List<String> phrases = const [],
  }) async {
    _cloneEnabled = enabled;
    _cloneRef = ref;
    _cloneLang = lang;
    _clonePhrases = phrases;
    await _pushClone();
  }

  Future<void> _pushClone() async {
    if (_cloneEnabled && _cloneRef.isNotEmpty) {
      final exe = await ComponentManager.instance.installedPath('clone') ?? '';
      final cacheDir = await _cloneCacheDir();
      final fp = await _voiceFingerprint(_cloneRef);
      _send({
        'type': 'tts.config',
        'cache_dir': cacheDir,
        'voice_fp': fp,
        'clone': {'exe': exe, 'ref': _cloneRef, 'lang': _cloneLang},
        'engine': 'xtts',
      });
      if (_clonePhrases.isNotEmpty) {
        _send({'type': 'tts.prerender', 'phrases': _clonePhrases});
      }
    } else {
      // Hand the active engine back to Piper (which itself falls back to the
      // system voice when no Piper voice is installed).
      _send({'type': 'tts.config', 'engine': 'piper'});
    }
  }

  // Configure a CosyVoice HTTP server as a cloning engine sharing the SAME
  // phrase cache. Untested until a GPU server is up; a no-op without an
  // endpoint, so it's safe to call unconditionally.
  Future<void> applyCosy({
    required bool enabled,
    String endpoint = '',
    String ref = '',
    String promptText = '',
    double speed = 1.0,
  }) async {
    if (enabled && endpoint.isNotEmpty && ref.isNotEmpty) {
      final cacheDir = await _cloneCacheDir();
      final fp = await _voiceFingerprint(ref);
      _send({
        'type': 'tts.config',
        'cache_dir': cacheDir,
        'voice_fp': fp,
        'cosy': {
          'endpoint': endpoint,
          'ref': ref,
          'prompt': promptText,
          'speed': speed,
        },
        'engine': 'cosyvoice',
      });
    }
  }

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
      if (phrase.contains('{n}')) {
        // Parametric template ("громкость на {N}"): {N} is a NUMBER slot, not a
        // literal token — "громкость на 30" must match it. Score on the literal
        // words only; the value itself is read from the utterance when the
        // command runs (NumberWords.extract, falling back to defaultValue).
        // Without this the "{n}" token was never present in what the user said,
        // the token-subset test failed and the command was "not found".
        final literal = _norm(phrase.replaceAll('{n}', ' '));
        final pTokens = literal.split(' ').where((e) => e.isNotEmpty).toSet();
        if (pTokens.isNotEmpty && pTokens.every(tTokens.contains)) {
          // A spoken number makes it a definite match; without one the command
          // still runs on its configured default, so keep it a strong match.
          s = NumberWords.extract(text) != null ? 1.0 : 0.9;
        } else {
          s = _ratio(t, literal);
        }
      } else if (t == phrase) {
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
