part of '../main.dart';

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
  int micVadAggr = 3; // webrtcvad aggressiveness 0..3 (higher = stricter / less sensitive)
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
    micVadAggr = prefs.getInt('micVadAggr') ?? 3;
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
    await prefs.setInt('micVadAggr', micVadAggr);
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
      unawaited(SidecarClient.instance.setVadAggressiveness(micVadAggr));
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
    micVadAggr = prefs.getInt('micVadAggr') ?? 3;
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
  void setMicVadAggr(int n) {
    micVadAggr = n.clamp(0, 3);
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setVadAggressiveness(micVadAggr));
  }

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

  static const _updateRepo = 'kekw2077/enhanced-voice-system';

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
