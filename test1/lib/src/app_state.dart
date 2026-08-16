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
  // Ambient-animation policy: 'full' | 'balanced' | 'saver' (see MotionPolicy).
  String motionMode = 'balanced';
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
  // Остальная выборка Ollama. Та же семантика null: не задано — не отправляем,
  // и решает модель. Ползунок «не задано» выразить не может, поэтому у каждого
  // параметра в настройках есть переключатель «задать».
  double? llmTopP;
  int? llmTopK;
  double? llmRepeatPenalty;
  double? llmMinP;
  String llmKeepAlive = '';
  // Размышление вслух у моделей вроде Qwen3. Ollama кладёт рассуждения в
  // отдельное поле, до пользователя они не доходят — но время съедают целиком.
  // Замер на станции, один и тот же вопрос: 27,7 с с размышлением против 2,3 с
  // без него. Для голосового ассистента это решает, поэтому по умолчанию выкл.
  bool llmThinking = false;
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
  // Push-to-Talk: комбинация из 1–3 клавиш. Хранится virtual-key кодами Windows
  // — именно их читает GetAsyncKeyState в PttWatcher. Подпись лежит рядом, а не
  // выводится из кодов: обратная таблица «код → имя клавиши» жила бы только ради
  // этой строчки и расходилась бы с раскладкой.
  List<int> pttKeys = const [];
  String pttLabel = '';
  String sttLanguage = 'auto'; // 'auto' | 'ru' | 'en'
  String whisperModel = 'small'; // tiny | base | small | medium (sidecar)
  String sttEngine = 'whisper'; // 'whisper' (sidecar) | 'windows' (speech_to_text)
  // Sidecar recognition engine (TZ1): which model the sidecar uses. Distinct
  // from sttEngine above (sidecar-vs-native backend).
  String sttSidecarEngine = 'whisper'; // 'whisper' | 'gigaam' | 'remote'
  // Распознавание на сервере: OpenAI-совместимый эндпоинт
  // POST {url}/v1/audio/transcriptions. Контракт чужой намеренно — его отдают
  // готовые серверы (speaches, whisper.cpp server, vLLM), и свою серверную
  // часть держать не придётся. Захват и VAD всё равно остаются в сайдкаре:
  // микрофон здесь, а не на сервере.
  String sttRemoteUrl = '';
  String sttRemoteModel = 'whisper-1';
  String sttRemoteKey = '';
  // Чем распознавать, когда сервер не отвечает: последний локальный выбор
  // пользователя. Отдельное поле, а не «всегда Whisper»: у выбравшего GigaAM
  // откат на tiny-Whisper был бы молчаливым ухудшением вместо страховки.
  String sttLocalEngine = 'gigaam';
  // Чем распознаётся прямо сейчас — состояние сайдкара, не настройка: в
  // prefs не пишется и в снимок настроек не входит. Нужно, чтобы подписи не
  // врали, когда выбран сервер, а работает локальный движок.
  String sttEngineLive = '';
  // Noise suppression before the VAD (TZ2 block 1). 'light' is the default but
  // needs the GTCRN model; the sidecar fail-safes to off until it's present.
  String denoiseMode = 'light'; // 'off' | 'light' | 'strong'
  int micVadAggr = 3; // webrtcvad aggressiveness 0..3 (higher = stricter / less sensitive)
  // Mic input gain (0.5..4.0). Distinct from micVadAggr: that sets how strictly
  // a frame is judged to be speech, this sets how loud the frame is. The STT
  // pipeline also has an absolute energy gate, which a genuinely quiet mic can
  // never clear no matter how permissive the VAD — gain is the fix for that.
  double micGain = 1.0;
  // Voice post-FX (applied to synthesized/cloned speech in the sidecar).
  bool ttsFxEnabled = false;
  double ttsFxDetune = 0.35;   // chorus/detune double 0..1
  double ttsFxMetallic = 0.22; // flanger+ring 0..1
  double ttsFxReverb = 0.15;   // reverb mix 0..1
  int ttsFxLowpass = 2200;     // low-pass Hz (brightness)
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
  // Показывать ли главное окно сразу после запуска. Раньше это решал сам
  // overlayMode: включён виджет — окно скрыто. Две вещи на одном тумблере, и
  // «окно и виджет вместе» выразить было нечем. Теперь окно и виджет —
  // независимые флаги, а карточка «После запуска показывать» в «Общих» ставит
  // оба разом. Значение по умолчанию повторяет прежнее поведение.
  bool startupShowWindow = false;
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
  // Google Programmable Search: нужен и ключ, и ID созданного движка (cx).
  String googleKey = '';
  String googleCx = '';
  // Yandex Search API: ключ и folderid облака. Ответ приходит XML.
  String yandexKey = '';
  String yandexFolder = '';
  // Какой провайдер использовать: auto — прежнее поведение (перебор тех, у кого
  // есть ключ, и DuckDuckGo как запасной), иначе строго выбранный.
  String searchProvider = 'auto';
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
  // '' = follow the global default (the chat model / selected model) — see
  // effectiveTtsInterpModel. A concrete name pins the interpreter to it.
  String ttsInterpModel = '';
  bool _ttsInterpFellBack = false; // one-shot "fell back to rules" notice guard
  // TTS engine choice (settings TZ §3.2). Piper is the built-in offline engine;
  // CosyVoice is a separate HTTP server (GPU) — selectable only once its
  // endpoint responds. The server isn't deployed yet, so it stays unavailable.
  String ttsEngineChoice = 'piper'; // 'piper' | 'cosyvoice'
  String cosyvoiceEndpoint = '';
  // Интерпретатор для локального сервера синтеза (sidecar/qwen_tts_server.py).
  // Пусто — искать самим: серверу нужен python с torch+CUDA, а он живёт в
  // отдельном venv и в установочный пакет не попадает (torch ~5 ГБ).
  String cloneServerPython = '';
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

  // ---- GPU load control for the clone server (Qwen3-TTS) -----------------
  // There is no driver-level "use N% of the GPU" knob, so load is shaped by
  // four real levers pushed to the server (POST <endpoint>/config): a hard VRAM
  // ceiling, idle unloading (frees VRAM entirely between phrases), a duty-cycle
  // throttle, and a pause flag driven by EVS's own game mode.
  // `cloneGpuProfile` is a preset over the three numeric knobs; editing any of
  // them individually switches it to 'custom'.
  String cloneGpuProfile = 'balanced'; // 'max' | 'balanced' | 'quiet' | 'custom'
  // What happens to the cloned voice while a game is running:
  //   'cache'  — pre-rendered phrases still play from disk (zero GPU), anything
  //              new falls back to Piper (default)
  //   'off'    — clone fully disabled, Piper only
  //   'normal' — keep synthesizing on the GPU (may cost FPS)
  String cloneGpuInGame = 'cache';
  double cloneGpuVramLimitGb = 5; // 0 = uncapped
  int cloneGpuIdleUnloadSec = 120; // 0 = never unload
  double cloneGpuThrottle = 0.25; // 0..1 share of synth time spent idling
  String cloneGpuPrecision = 'auto'; // 'auto' | 'bf16' | 'fp16'

  // Piper voices the user imported themselves (see importCustomVoice).
  List<CustomVoice> customVoices = [];

  // Voice clone (XTTS-v2 on CPU) — a temporary local stand-in for GPU CosyVoice
  // while a graphics card is awaited. The engine ships as a separate downloaded
  // component (`clone`); `cloneSamplePath` is any WAV 6–10 s of the target
  // voice. Fixed phrases (system notifications, command speak-phrases, the
  // acknowledgement library) are pre-rendered into a cache so they play
  // instantly; novel text is synthesized on the fly (~2× on CPU). The cache is
  // engine-agnostic, so it serves CosyVoice too once its server is up.
  bool cloneEnabled = false;
  String cloneSamplePath = '';
  // User-editable extra phrases to pre-render (on top of the built-ins).
  List<String> clonePhraseLib = [];

  // Built-in acknowledgement phrases pre-rendered for a cloned voice so short
  // interjections are instant. Fixed system phrases + command speak-phrases are
  // added on top in clonePhrasesToRender().
  static const List<String> kCloneAckPhrases = [
    'Готово.', 'Слушаю.', 'Секунду.', 'Минуту.', 'Выполняю.',
    'Не расслышал, повтори.', 'Готово, что-нибудь ещё?', 'Хорошо.',
    'Уже делаю.', 'Один момент.',
  ];

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
    motionMode = prefs.getString('motionMode') ?? 'balanced';
    MotionPolicy.setMode(motionMode);
    // Let the splash/first frame animate briefly even in balanced mode.
    MotionPolicy.poke();
    micAutoSend = prefs.getBool('micAutoSend') ?? true;
    micPauseSeconds = prefs.getInt('micPauseSeconds') ?? 3;
    serverUrl = prefs.getString('serverUrl') ?? '';
    savedServers = prefs.getStringList('savedServers') ?? [];
    // Absent key -> null -> parameter is not sent at all (see llmOptions).
    llmNumCtx = prefs.getInt('llmNumCtx');
    llmNumPredict = prefs.getInt('llmNumPredict');
    llmTemperature = prefs.getDouble('llmTemperature');
    llmTopP = prefs.getDouble('llmTopP');
    llmTopK = prefs.getInt('llmTopK');
    llmRepeatPenalty = prefs.getDouble('llmRepeatPenalty');
    llmMinP = prefs.getDouble('llmMinP');
    llmKeepAlive = prefs.getString('llmKeepAlive') ?? '';
    llmThinking = prefs.getBool('llmThinking') ?? false;
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
    pttKeys = (prefs.getString('pttKeys') ?? '')
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .where((v) => v > 0)
        .toList();
    pttLabel = prefs.getString('pttLabel') ?? '';
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
    sttRemoteUrl = prefs.getString('sttRemoteUrl') ?? '';
    sttRemoteModel = prefs.getString('sttRemoteModel') ?? 'whisper-1';
    sttRemoteKey = prefs.getString('sttRemoteKey') ?? '';
    sttLocalEngine = prefs.getString('sttLocalEngine') ??
        (sttSidecarEngine == 'remote' ? 'gigaam' : sttSidecarEngine);
    denoiseMode = prefs.getString('denoiseMode') ?? 'light';
    micVadAggr = prefs.getInt('micVadAggr') ?? 3;
    micGain = prefs.getDouble('micGain') ?? 1.0;
    ttsFxEnabled = prefs.getBool('ttsFxEnabled') ?? false;
    ttsFxDetune = prefs.getDouble('ttsFxDetune') ?? 0.35;
    ttsFxMetallic = prefs.getDouble('ttsFxMetallic') ?? 0.22;
    ttsFxReverb = prefs.getDouble('ttsFxReverb') ?? 0.15;
    ttsFxLowpass = prefs.getInt('ttsFxLowpass') ?? 2200;
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
    // Умолчание берётся из прежнего поведения: окно показывалось ровно тогда,
    // когда виджет был выключен. У существующих установок ничего не меняется.
    startupShowWindow = prefs.getBool('startupShowWindow') ?? !overlayMode;
    overlaySize = prefs.getDouble('overlaySize') ?? 260;
    vizAccent = prefs.getInt('vizAccent') ?? 0xFFCC785C;
    orbSize = prefs.getDouble('orbSize') ?? 200;
    orbSpeed = prefs.getDouble('orbSpeed') ?? 20;
    barCount = prefs.getInt('barCount') ?? 7;
    autoUpdateCheck = prefs.getBool('autoUpdateCheck') ?? true;
    webSearchEnabled = prefs.getBool('webSearchEnabled') ?? false;
    tavilyKey = prefs.getString('tavilyKey') ?? '';
    braveKey = prefs.getString('braveKey') ?? '';
    googleKey = prefs.getString('googleKey') ?? '';
    googleCx = prefs.getString('googleCx') ?? '';
    yandexKey = prefs.getString('yandexKey') ?? '';
    yandexFolder = prefs.getString('yandexFolder') ?? '';
    searchProvider = prefs.getString('searchProvider') ?? 'auto';
    voiceResponses = prefs.getBool('voiceResponses') ?? false;
    announceReady = prefs.getBool('announceReady') ?? true;
    ttsPiperVoice = prefs.getString('ttsPiperVoice') ?? '';
    ttsRate = prefs.getDouble('ttsRate') ?? 1.0;
    ttsVolume = prefs.getDouble('ttsVolume') ?? 1.0;
    ttsInterpEnabled = prefs.getBool('ttsInterpEnabled') ?? true;
    ttsInterpMode = prefs.getString('ttsInterpMode') ?? 'rules';
    ttsInterpModel = prefs.getString('ttsInterpModel') ?? '';
    ttsEngineChoice = prefs.getString('ttsEngineChoice') ?? 'piper';
    cosyvoiceEndpoint = prefs.getString('cosyvoiceEndpoint') ?? '';
    cloneServerPython = prefs.getString('cloneServerPython') ?? '';
    cosyvoiceVoice = prefs.getString('cosyvoiceVoice') ?? '';
    cosyvoiceClonePath = prefs.getString('cosyvoiceClonePath') ?? '';
    cosyvoiceClonePromptText =
        prefs.getString('cosyvoiceClonePromptText') ?? '';
    cosyvoiceSpeed = prefs.getDouble('cosyvoiceSpeed') ?? 1.0;
    cosyvoiceEmotion = prefs.getString('cosyvoiceEmotion') ?? 'neutral';
    cosyvoiceInstruct = prefs.getString('cosyvoiceInstruct') ?? '';
    cosyvoiceDevice = prefs.getString('cosyvoiceDevice') ?? 'cuda';
    cloneGpuProfile = prefs.getString('cloneGpuProfile') ?? 'balanced';
    cloneGpuInGame = prefs.getString('cloneGpuInGame') ?? 'cache';
    cloneGpuVramLimitGb = prefs.getDouble('cloneGpuVramLimitGb') ?? 5;
    cloneGpuIdleUnloadSec = prefs.getInt('cloneGpuIdleUnloadSec') ?? 120;
    cloneGpuThrottle = prefs.getDouble('cloneGpuThrottle') ?? 0.25;
    cloneGpuPrecision = prefs.getString('cloneGpuPrecision') ?? 'auto';
    final cvRaw = prefs.getString('customVoices');
    if (cvRaw != null) {
      try {
        final decoded = jsonDecode(cvRaw);
        if (decoded is List) {
          customVoices = decoded
              .map((e) => CustomVoice.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
    // CPU-XTTS clone disabled: the CPU build was unintelligible, so the app no
    // longer runs it (UI hidden). Forced false regardless of the persisted pref
    // so a previously-enabled machine reverts to Piper on launch. GPU render
    // (Qwen3-TTS) will re-introduce cloning later. Was: prefs.getBool('cloneEnabled').
    cloneEnabled = false;
    cloneSamplePath = prefs.getString('cloneSamplePath') ?? '';
    clonePhraseLib = prefs.getStringList('clonePhraseLib') ?? [];
    activeVoicePreset = prefs.getString('activeVoicePreset') ?? '';
    try {
      final vp = prefs.getString('voicePresets');
      if (vp != null && vp.isNotEmpty) {
        final d = jsonDecode(vp) as Map<String, dynamic>;
        voicePresets = {
          for (final e in d.entries)
            e.key: (e.value as Map).cast<String, dynamic>()
        };
      }
    } catch (_) {}
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
    // Prime the sidecar's retained voice-FX config so it's (re)applied on every
    // connect. Otherwise _ttsFx stays null on a fresh launch (setTtsFx is only
    // ever called from the settings screen), the on-connect handler in
    // SidecarClient sends nothing, and the voice plays with no effects until
    // settings are opened — the "FX resets to normal after restart" bug.
    unawaited(SidecarClient.instance.setTtsFx(ttsFxConfig()));
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
        llmTopP, llmTopK, llmRepeatPenalty, llmMinP,
        llmKeepAlive, llmThinking,
        searchModel, chatModel, apiKey, selectedModel, inferenceMode,
        autostart, minimizeToTray, closeToTray, inputDeviceId, extraMicIds.join(','),
        jsonEncode(deviceDenoise), listenMode, pttKeys.join(','), pttLabel,
        sttLanguage, whisperModel, sttEngine,
        sttSidecarEngine, sttRemoteUrl, sttRemoteModel, sttRemoteKey,
        sttLocalEngine,
        denoiseMode, sttDevice, gameModeFullscreen, gameModeVram,
        gameModeVramEnter, gameModeVramExit, gameModeNotify,
        gameModeExclusions.join(','), cmdMode, wakeWord, stopWords.join(','),
        cmdThreshold, cmdConfirm, cmdEnabled, chatEnabled, vizType, showVizBg,
        showPartial, overlayMode, startupShowWindow, overlaySize, vizAccent,
        orbSize, orbSpeed,
        barCount, autoUpdateCheck, webSearchEnabled, tavilyKey, braveKey,
        googleKey, googleCx, yandexKey, yandexFolder, searchProvider,
        voiceResponses, announceReady, ttsPiperVoice, ttsRate, ttsVolume,
        ttsInterpEnabled, ttsInterpMode, ttsInterpModel, ttsEngineChoice,
        cosyvoiceEndpoint, cosyvoiceVoice, cosyvoiceClonePath,
        cloneServerPython,
        cosyvoiceClonePromptText, cosyvoiceSpeed, cosyvoiceEmotion,
        cosyvoiceInstruct, cosyvoiceDevice,
        cloneGpuProfile, cloneGpuInGame, cloneGpuVramLimitGb,
        cloneGpuIdleUnloadSec, cloneGpuThrottle, cloneGpuPrecision,
        // Every field _restoreSettingsFields() re-reads MUST appear here: a
        // field that restores but isn't snapshotted never flags the draft
        // dirty, so its edits silently revert when the screen closes (that was
        // the "FX sliders don't save" bug — and the clone toggle too).
        motionMode, micVadAggr, micGain,
        ttsFxEnabled, ttsFxDetune, ttsFxMetallic, ttsFxReverb, ttsFxLowpass,
        cloneEnabled, cloneSamplePath, clonePhraseLib.join(','),
        activeVoicePreset, jsonEncode(voicePresets),
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
    await prefs.setString('motionMode', motionMode);
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
    // Тот же приём, что выше: null стирает ключ, иначе значение сохраняется.
    for (final e in <String, Object?>{
      'llmTopP': llmTopP,
      'llmTopK': llmTopK,
      'llmRepeatPenalty': llmRepeatPenalty,
      'llmMinP': llmMinP,
    }.entries) {
      if (e.value == null) {
        await prefs.remove(e.key);
      } else if (e.value is int) {
        await prefs.setInt(e.key, e.value as int);
      } else {
        await prefs.setDouble(e.key, e.value as double);
      }
    }
    await prefs.setString('llmKeepAlive', llmKeepAlive);
    await prefs.setBool('llmThinking', llmThinking);
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
    await prefs.setString('pttKeys', pttKeys.join(','));
    await prefs.setString('pttLabel', pttLabel);
    await prefs.setString('sttLanguage', sttLanguage);
    await prefs.setString('whisperModel', whisperModel);
    await prefs.setString('sttEngine', sttEngine);
    await prefs.setString('sttSidecarEngine', sttSidecarEngine);
    await prefs.setString('sttRemoteUrl', sttRemoteUrl);
    await prefs.setString('sttRemoteModel', sttRemoteModel);
    await prefs.setString('sttRemoteKey', sttRemoteKey);
    await prefs.setString('sttLocalEngine', sttLocalEngine);
    await prefs.setString('denoiseMode', denoiseMode);
    await prefs.setInt('micVadAggr', micVadAggr);
    await prefs.setDouble('micGain', micGain);
    await prefs.setBool('ttsFxEnabled', ttsFxEnabled);
    await prefs.setDouble('ttsFxDetune', ttsFxDetune);
    await prefs.setDouble('ttsFxMetallic', ttsFxMetallic);
    await prefs.setDouble('ttsFxReverb', ttsFxReverb);
    await prefs.setInt('ttsFxLowpass', ttsFxLowpass);
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
    await prefs.setBool('startupShowWindow', startupShowWindow);
    await prefs.setDouble('overlaySize', overlaySize);
    await prefs.setInt('vizAccent', vizAccent);
    await prefs.setDouble('orbSize', orbSize);
    await prefs.setDouble('orbSpeed', orbSpeed);
    await prefs.setInt('barCount', barCount);
    await prefs.setBool('autoUpdateCheck', autoUpdateCheck);
    await prefs.setBool('webSearchEnabled', webSearchEnabled);
    await prefs.setString('tavilyKey', tavilyKey);
    await prefs.setString('braveKey', braveKey);
    await prefs.setString('googleKey', googleKey);
    await prefs.setString('googleCx', googleCx);
    await prefs.setString('yandexKey', yandexKey);
    await prefs.setString('yandexFolder', yandexFolder);
    await prefs.setString('searchProvider', searchProvider);
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
    await prefs.setString('cloneServerPython', cloneServerPython);
    await prefs.setString('cosyvoiceVoice', cosyvoiceVoice);
    await prefs.setString('cosyvoiceClonePath', cosyvoiceClonePath);
    await prefs.setString('cosyvoiceClonePromptText', cosyvoiceClonePromptText);
    await prefs.setDouble('cosyvoiceSpeed', cosyvoiceSpeed);
    await prefs.setString('cosyvoiceEmotion', cosyvoiceEmotion);
    await prefs.setString('cosyvoiceInstruct', cosyvoiceInstruct);
    await prefs.setString('cosyvoiceDevice', cosyvoiceDevice);
    await prefs.setString('cloneGpuProfile', cloneGpuProfile);
    await prefs.setString('cloneGpuInGame', cloneGpuInGame);
    await prefs.setDouble('cloneGpuVramLimitGb', cloneGpuVramLimitGb);
    await prefs.setInt('cloneGpuIdleUnloadSec', cloneGpuIdleUnloadSec);
    await prefs.setDouble('cloneGpuThrottle', cloneGpuThrottle);
    await prefs.setString('cloneGpuPrecision', cloneGpuPrecision);
    await prefs.setString('customVoices',
        jsonEncode(customVoices.map((e) => e.toJson()).toList()));
    await prefs.setBool('cloneEnabled', cloneEnabled);
    await prefs.setString('cloneSamplePath', cloneSamplePath);
    await prefs.setStringList('clonePhraseLib', clonePhraseLib);
    await prefs.setString('activeVoicePreset', activeVoicePreset);
    await prefs.setString('voicePresets', jsonEncode(voicePresets));
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
      // Адрес сервера — раньше выбора движка: setSttEngine отправляет их одним
      // сообщением, но у сайдкара адрес должен быть и при откате настроек.
      unawaited(SidecarClient.instance.setSttRemote(
          url: sttRemoteUrl, model: sttRemoteModel, key: sttRemoteKey));
      unawaited(SidecarClient.instance.setSttEngine(sttSidecarEngine));
    } catch (_) {}
    try {
      unawaited(SidecarClient.instance.setDenoise(denoiseMode));
    } catch (_) {}
    try {
      unawaited(SidecarClient.instance.setVadAggressiveness(micVadAggr));
    } catch (_) {}
    try {
      unawaited(SidecarClient.instance.setMicGain(micGain));
    } catch (_) {}
    try {
      unawaited(SidecarClient.instance.setTtsFx(ttsFxConfig()));
    } catch (_) {}
    try {
      unawaited(applyCloneConfig());
    } catch (_) {}
    _restoreCloneEngineOnce();
    try {
      unawaited(applyCloneServer());
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
    motionMode = prefs.getString('motionMode') ?? 'balanced';
    MotionPolicy.setMode(motionMode);
    // Let the splash/first frame animate briefly even in balanced mode.
    MotionPolicy.poke();
    micAutoSend = prefs.getBool('micAutoSend') ?? true;
    micPauseSeconds = prefs.getInt('micPauseSeconds') ?? 3;
    serverUrl = prefs.getString('serverUrl') ?? '';
    savedServers = prefs.getStringList('savedServers') ?? [];
    apiKey = prefs.getString('apiKey') ?? '';
    llmNumCtx = prefs.getInt('llmNumCtx');
    llmNumPredict = prefs.getInt('llmNumPredict');
    llmTemperature = prefs.getDouble('llmTemperature');
    llmTopP = prefs.getDouble('llmTopP');
    llmTopK = prefs.getInt('llmTopK');
    llmRepeatPenalty = prefs.getDouble('llmRepeatPenalty');
    llmMinP = prefs.getDouble('llmMinP');
    llmKeepAlive = prefs.getString('llmKeepAlive') ?? '';
    llmThinking = prefs.getBool('llmThinking') ?? false;
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
    pttKeys = (prefs.getString('pttKeys') ?? '')
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .where((v) => v > 0)
        .toList();
    pttLabel = prefs.getString('pttLabel') ?? '';
    sttLanguage = prefs.getString('sttLanguage') ?? 'auto';
    whisperModel = prefs.getString('whisperModel') ?? 'small';
    sttEngine = prefs.getString('sttEngine') ?? 'whisper';
    sttSidecarEngine = prefs.getString('sttSidecarEngine') ?? 'whisper';
    sttRemoteUrl = prefs.getString('sttRemoteUrl') ?? '';
    sttRemoteModel = prefs.getString('sttRemoteModel') ?? 'whisper-1';
    sttRemoteKey = prefs.getString('sttRemoteKey') ?? '';
    sttLocalEngine = prefs.getString('sttLocalEngine') ??
        (sttSidecarEngine == 'remote' ? 'gigaam' : sttSidecarEngine);
    denoiseMode = prefs.getString('denoiseMode') ?? 'light';
    micVadAggr = prefs.getInt('micVadAggr') ?? 3;
    micGain = prefs.getDouble('micGain') ?? 1.0;
    ttsFxEnabled = prefs.getBool('ttsFxEnabled') ?? false;
    ttsFxDetune = prefs.getDouble('ttsFxDetune') ?? 0.35;
    ttsFxMetallic = prefs.getDouble('ttsFxMetallic') ?? 0.22;
    ttsFxReverb = prefs.getDouble('ttsFxReverb') ?? 0.15;
    ttsFxLowpass = prefs.getInt('ttsFxLowpass') ?? 2200;
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
    // Умолчание берётся из прежнего поведения: окно показывалось ровно тогда,
    // когда виджет был выключен. У существующих установок ничего не меняется.
    startupShowWindow = prefs.getBool('startupShowWindow') ?? !overlayMode;
    overlaySize = prefs.getDouble('overlaySize') ?? 260;
    vizAccent = prefs.getInt('vizAccent') ?? 0xFFCC785C;
    orbSize = prefs.getDouble('orbSize') ?? 200;
    orbSpeed = prefs.getDouble('orbSpeed') ?? 20;
    barCount = prefs.getInt('barCount') ?? 7;
    autoUpdateCheck = prefs.getBool('autoUpdateCheck') ?? true;
    webSearchEnabled = prefs.getBool('webSearchEnabled') ?? false;
    tavilyKey = prefs.getString('tavilyKey') ?? '';
    braveKey = prefs.getString('braveKey') ?? '';
    googleKey = prefs.getString('googleKey') ?? '';
    googleCx = prefs.getString('googleCx') ?? '';
    yandexKey = prefs.getString('yandexKey') ?? '';
    yandexFolder = prefs.getString('yandexFolder') ?? '';
    searchProvider = prefs.getString('searchProvider') ?? 'auto';
    voiceResponses = prefs.getBool('voiceResponses') ?? false;
    announceReady = prefs.getBool('announceReady') ?? true;
    ttsPiperVoice = prefs.getString('ttsPiperVoice') ?? '';
    ttsRate = prefs.getDouble('ttsRate') ?? 1.0;
    ttsVolume = prefs.getDouble('ttsVolume') ?? 1.0;
    ttsInterpEnabled = prefs.getBool('ttsInterpEnabled') ?? true;
    ttsInterpMode = prefs.getString('ttsInterpMode') ?? 'rules';
    ttsInterpModel = prefs.getString('ttsInterpModel') ?? '';
    ttsEngineChoice = prefs.getString('ttsEngineChoice') ?? 'piper';
    cosyvoiceEndpoint = prefs.getString('cosyvoiceEndpoint') ?? '';
    cloneServerPython = prefs.getString('cloneServerPython') ?? '';
    cosyvoiceVoice = prefs.getString('cosyvoiceVoice') ?? '';
    cosyvoiceClonePath = prefs.getString('cosyvoiceClonePath') ?? '';
    cosyvoiceClonePromptText =
        prefs.getString('cosyvoiceClonePromptText') ?? '';
    cosyvoiceSpeed = prefs.getDouble('cosyvoiceSpeed') ?? 1.0;
    cosyvoiceEmotion = prefs.getString('cosyvoiceEmotion') ?? 'neutral';
    cosyvoiceInstruct = prefs.getString('cosyvoiceInstruct') ?? '';
    cosyvoiceDevice = prefs.getString('cosyvoiceDevice') ?? 'cuda';
    cloneGpuProfile = prefs.getString('cloneGpuProfile') ?? 'balanced';
    cloneGpuInGame = prefs.getString('cloneGpuInGame') ?? 'cache';
    cloneGpuVramLimitGb = prefs.getDouble('cloneGpuVramLimitGb') ?? 5;
    cloneGpuIdleUnloadSec = prefs.getInt('cloneGpuIdleUnloadSec') ?? 120;
    cloneGpuThrottle = prefs.getDouble('cloneGpuThrottle') ?? 0.25;
    cloneGpuPrecision = prefs.getString('cloneGpuPrecision') ?? 'auto';
    final cvRaw = prefs.getString('customVoices');
    if (cvRaw != null) {
      try {
        final decoded = jsonDecode(cvRaw);
        if (decoded is List) {
          customVoices = decoded
              .map((e) => CustomVoice.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
    // CPU-XTTS clone disabled: the CPU build was unintelligible, so the app no
    // longer runs it (UI hidden). Forced false regardless of the persisted pref
    // so a previously-enabled machine reverts to Piper on launch. GPU render
    // (Qwen3-TTS) will re-introduce cloning later. Was: prefs.getBool('cloneEnabled').
    cloneEnabled = false;
    cloneSamplePath = prefs.getString('cloneSamplePath') ?? '';
    clonePhraseLib = prefs.getStringList('clonePhraseLib') ?? [];
    activeVoicePreset = prefs.getString('activeVoicePreset') ?? '';
    try {
      final vp = prefs.getString('voicePresets');
      if (vp != null && vp.isNotEmpty) {
        final d = jsonDecode(vp) as Map<String, dynamic>;
        voicePresets = {
          for (final e in d.entries)
            e.key: (e.value as Map).cast<String, dynamic>()
        };
      }
    } catch (_) {}
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
        if (llmTopP != null) 'top_p': llmTopP,
        if (llmTopK != null) 'top_k': llmTopK,
        if (llmRepeatPenalty != null) 'repeat_penalty': llmRepeatPenalty,
        if (llmMinP != null) 'min_p': llmMinP,
      };

  /// Один сеттер на все параметры выборки: значение или null («по умолчанию
  /// модели»). Отдельные сеттеры на каждый плодили бы одинаковый код.
  void setLlmThinking(bool v) {
    llmThinking = v;
    _save();
    notifyListeners();
  }

  void setLlmOption(String name, num? v) {
    switch (name) {
      case 'temperature':
        llmTemperature = v?.toDouble();
      case 'top_p':
        llmTopP = v?.toDouble();
      case 'top_k':
        llmTopK = v?.toInt();
      case 'repeat_penalty':
        llmRepeatPenalty = v?.toDouble();
      case 'min_p':
        llmMinP = v?.toDouble();
      case 'num_predict':
        llmNumPredict = v?.toInt();
      case 'num_ctx':
        llmNumCtx = v?.toInt();
      default:
        return;
    }
    _save();
    notifyListeners();
  }

  /// Текущее значение параметра выборки или null, если не задан.
  num? llmOption(String name) => switch (name) {
        'temperature' => llmTemperature,
        'top_p' => llmTopP,
        'top_k' => llmTopK,
        'repeat_penalty' => llmRepeatPenalty,
        'min_p' => llmMinP,
        'num_predict' => llmNumPredict,
        'num_ctx' => llmNumCtx,
        _ => null,
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
  // ---- Quick profiles («Быстрые профили») ------------------------------
  // Each profile applies a SUBSET of three settings; an absent key means "leave
  // this one alone". They are data rather than hardcoded switch arms so the user
  // can retune them, and `activeVoicePreset` marks the last one applied — it is
  // cleared the moment any governed setting is changed by hand, so the
  // highlight never claims a profile that no longer reflects reality.
  static const Map<String, Map<String, dynamic>> kDefaultVoicePresets = {
    'fast': {'device': 'cpu', 'denoise': 'light', 'web': false},
    'quality': {'device': 'cuda', 'denoise': 'strong'},
    'search': {'web': true},
    'chat': {'web': false},
  };

  // Overrides only; anything absent falls back to the built-in defaults.
  Map<String, Map<String, dynamic>> voicePresets = {};
  String activeVoicePreset = '';
  bool _applyingPreset = false;

  Map<String, dynamic> presetConfig(String id) =>
      voicePresets[id] ?? kDefaultVoicePresets[id] ?? const {};

  bool get presetsCustomized => voicePresets.isNotEmpty;

  // Human summary of what a profile changes, built from its CURRENT config so
  // an edited profile never shows a stale description.
  String presetDescription(String id) {
    final cfg = presetConfig(id);
    final parts = <String>[];
    final dev = cfg['device'];
    if (dev is String && dev.isNotEmpty) {
      parts.add(t(dev == 'cuda' ? 'presetDevGpu' : 'presetDevCpu'));
    }
    final dn = cfg['denoise'];
    if (dn is String && dn.isNotEmpty) {
      parts.add(t(dn == 'strong'
          ? 'presetDnStrong'
          : dn == 'light'
              ? 'presetDnLight'
              : 'presetDnOff'));
    }
    final web = cfg['web'];
    if (web is bool) parts.add(t(web ? 'presetWebOn' : 'presetWebOff'));
    return parts.isEmpty ? t('presetEmpty') : parts.join(' · ');
  }

  void applyVoicePreset(String id) {
    final cfg = presetConfig(id);
    if (cfg.isEmpty) return;
    _applyingPreset = true;
    final dev = cfg['device'];
    if (dev is String && dev.isNotEmpty) setSttDevice(dev);
    final dn = cfg['denoise'];
    if (dn is String && dn.isNotEmpty) setDenoiseMode(dn);
    final web = cfg['web'];
    if (web is bool) setWebSearchEnabled(web);
    _applyingPreset = false;
    activeVoicePreset = id;
    _save();
    notifyListeners();
  }

  // Called by the setters a profile governs: a manual change means the active
  // profile no longer describes the current state.
  void _presetTouched() {
    if (_applyingPreset || activeVoicePreset.isEmpty) return;
    activeVoicePreset = '';
    _save();
  }

  void setVoicePreset(String id, Map<String, dynamic> cfg) {
    voicePresets[id] = cfg;
    // Editing the active profile invalidates the "applied" mark.
    if (activeVoicePreset == id) activeVoicePreset = '';
    _save();
    notifyListeners();
  }

  void resetVoicePresets() {
    voicePresets = {};
    activeVoicePreset = '';
    _save();
    notifyListeners();
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
    // The clone can be selected while its server is DOWN, and that is the whole
    // point: the pre-rendered phrase cache is only consulted while a CLONING
    // engine is selected, and anything uncached falls back per utterance
    // (Piper, else the system voice). Requiring a live probe here made the
    // cache unreachable exactly when it mattered — and silently, because this
    // returned without a word, so both the engine chip and the "Включить
    // клон-голос" button did nothing at all. A sample is still required: there
    // is nothing to clone or replay without one.
    if (v == 'cosyvoice' &&
        (cosyvoiceEndpoint.trim().isEmpty ||
            cosyvoiceClonePath.trim().isEmpty)) {
      return;
    }
    ttsEngineChoice = v == 'cosyvoice' ? 'cosyvoice' : 'piper';
    _save();
    notifyListeners();
    unawaited(applyCloneServer());
  }

  void setCosyvoiceEndpoint(String v) {
    cosyvoiceEndpoint = v.trim();
    cosyvoiceOnline = null; // must re-check after an address change
    _save();
    notifyListeners();
    unawaited(applyCloneServer());
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
    unawaited(applyCloneServer());
  }

  void setCosyvoiceClonePromptText(String v) {
    cosyvoiceClonePromptText = v;
    _save();
    notifyListeners();
    unawaited(applyCloneServer());
  }

  // ---- Voice clone (XTTS, CPU) ---------------------------------------

  void setCloneEnabled(bool v) {
    cloneEnabled = v;
    _save();
    notifyListeners();
    unawaited(applyCloneConfig());
  }

  void setCloneSamplePath(String v) {
    cloneSamplePath = v;
    _save();
    notifyListeners();
    if (cloneEnabled) unawaited(applyCloneConfig());
  }

  void addClonePhrase(String p) {
    p = p.trim();
    if (p.isEmpty || clonePhraseLib.contains(p)) return;
    clonePhraseLib = [...clonePhraseLib, p];
    _save();
    notifyListeners();
    if (cloneEnabled) unawaited(applyCloneConfig());
  }

  void removeClonePhrase(String p) {
    clonePhraseLib = clonePhraseLib.where((e) => e != p).toList();
    _save();
    notifyListeners();
  }

  // Fixed phrases pre-rendered into the clone cache: the system-spoken lines +
  // every command's speak-phrase (parametric {N} ones skipped) + the built-in
  // acknowledgements + the user's own library. Deduplicated.
  List<String> clonePhrasesToRender() {
    final out = <String>{};
    void add(String? s) {
      final v = (s ?? '').trim();
      if (v.isNotEmpty && !v.contains('{')) out.add(v);
    }

    add(t('readyGreeting'));
    add(t('gmNotifyFullscreen'));
    add(t('gmNotifyVram'));
    add(t('gmNotifyExit'));
    add(t('vaDone'));
    for (final c in voiceCommands) {
      add(c.speakPhrase);
    }
    for (final p in kCloneAckPhrases) {
      add(p);
    }
    for (final p in clonePhraseLib) {
      add(p);
    }
    return out.toList();
  }

  // Push clone config to the sidecar (or hand the engine back to Piper/system
  // when disabled), and pre-render the fixed phrases. The clone component is a
  // heavy on-demand download; ensure() pulls it on first enable.
  bool _cloneApplying = false;
  bool _clonePending = false;

  Future<void> applyCloneConfig() async {
    // Serialize + coalesce: enabling, picking a sample and adding phrases can
    // all fire in quick succession; without this each would kick off its own
    // ~3 GB download. Concurrent calls collapse into one re-apply at the end.
    if (_cloneApplying) {
      _clonePending = true;
      return;
    }
    _cloneApplying = true;
    try {
      await _applyCloneConfigInner();
    } finally {
      _cloneApplying = false;
      if (_clonePending) {
        _clonePending = false;
        unawaited(applyCloneConfig());
      }
    }
  }

  Future<void> _applyCloneConfigInner() async {
    final sc = SidecarClient.instance;
    if (cloneEnabled && cloneSamplePath.isNotEmpty) {
      // AWAIT the component so the clone exe path is valid before we tell the
      // sidecar to switch engine. ensure() returns instantly if it's already
      // present, or resolves only after the ~3 GB download finishes — without
      // awaiting, applyClone ran with an empty exe path, the sidecar fell back
      // to the system voice, and nothing re-applied once the download landed
      // ("выбираю образец — голос старый").
      await ComponentManager.instance.ensure('clone');
      await sc.applyClone(
        enabled: true,
        ref: cloneSamplePath,
        lang: lang == 'en' ? 'en' : 'ru',
        phrases: clonePhrasesToRender(),
      );
      notifyListeners(); // engine status / readiness may have changed
    } else {
      await sc.applyClone(enabled: false);
      final modelId = _voiceModelId(ttsPiperVoice);
      unawaited(sc.setTtsVoice(ttsPiperVoice, modelId: modelId));
    }
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

  // ---- GPU load control (clone server) ---------------------------------

  // Preset → the three numeric knobs. 'custom' keeps whatever is stored.
  static const Map<String, (double vramGb, int idleSec, double throttle)>
      kCloneGpuPresets = {
    // Uncapped, stays resident for 10 min, never throttled.
    'max': (0, 600, 0),
    // Roughly half a 12 GB card, unloads after 2 min, mild duty cycle.
    'balanced': (5, 120, 0.25),
    // Small footprint, drops out of VRAM quickly, heavy duty cycle.
    'quiet': (3, 30, 0.6),
  };

  void setCloneGpuProfile(String v) {
    final preset = kCloneGpuPresets[v];
    cloneGpuProfile = preset == null ? 'custom' : v;
    if (preset != null) {
      cloneGpuVramLimitGb = preset.$1;
      cloneGpuIdleUnloadSec = preset.$2;
      cloneGpuThrottle = preset.$3;
    }
    _save();
    notifyListeners();
    unawaited(pushCloneGpuConfig());
  }

  // Any manual tweak means the profile no longer describes the settings.
  void _markCloneGpuCustom() {
    cloneGpuProfile = 'custom';
  }

  void setCloneGpuInGame(String v) {
    cloneGpuInGame = const {'cache', 'off', 'normal'}.contains(v) ? v : 'cache';
    _save();
    notifyListeners();
    unawaited(pushCloneGpuConfig());
  }

  void setCloneGpuVramLimitGb(double v) {
    cloneGpuVramLimitGb = v < 0 ? 0 : v;
    _markCloneGpuCustom();
    _save();
    notifyListeners();
    unawaited(pushCloneGpuConfig());
  }

  void setCloneGpuIdleUnloadSec(int v) {
    cloneGpuIdleUnloadSec = v < 0 ? 0 : v;
    _markCloneGpuCustom();
    _save();
    notifyListeners();
    unawaited(pushCloneGpuConfig());
  }

  void setCloneGpuThrottle(double v) {
    cloneGpuThrottle = v.clamp(0.0, 1.0);
    _markCloneGpuCustom();
    _save();
    notifyListeners();
    unawaited(pushCloneGpuConfig());
  }

  void setCloneGpuPrecision(String v) {
    cloneGpuPrecision =
        const {'auto', 'bf16', 'fp16'}.contains(v) ? v : 'auto';
    _save();
    notifyListeners();
    unawaited(pushCloneGpuConfig());
  }

  // Convert the GB ceiling into the fraction-of-card the server expects. Needs
  // the real card size, which the sidecar reports; with no reading available we
  // send 0 (uncapped) rather than guessing a wrong fraction.
  double _cloneGpuVramFraction() {
    if (cloneGpuVramLimitGb <= 0) return 0;
    final totalMb = SidecarClient.instance.gpuInfo.value.$3;
    if (totalMb <= 0) return 0;
    final frac = (cloneGpuVramLimitGb * 1024) / totalMb;
    return frac.clamp(0.05, 1.0);
  }

  // Whether the clone server should currently refuse GPU work: the user asked
  // for the clone to stand down while a game is running.
  bool get cloneGpuPausedByGame {
    if (cloneGpuInGame == 'normal') return false;
    return SidecarClient.instance.gameModeStatus.value.$1;
  }

  // Push the GPU-load settings to the clone server. Best-effort: the server is
  // an optional local process, so failures are silent (the engine already falls
  // back to Piper when it's unreachable).
  Future<void> pushCloneGpuConfig() async {
    final base = cosyvoiceEndpoint.trim();
    if (base.isEmpty) return;
    final url = '${base.replaceAll(RegExp(r'/+$'), '')}/config';
    try {
      await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'language': lang == 'en' ? 'English' : 'Russian',
              'precision': cloneGpuPrecision,
              'vram_fraction': _cloneGpuVramFraction(),
              'idle_unload_sec': cloneGpuIdleUnloadSec,
              'throttle': cloneGpuThrottle,
              'paused': cloneGpuPausedByGame,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Server not running / not reachable — nothing to configure.
    }
  }

  // Activate (or stand down) the GPU clone server as the TTS engine. This is
  // what actually switches the sidecar onto the cloning engine — it needs an
  // endpoint AND a voice sample, and it stands down entirely while a game runs
  // if the user chose "off" for game mode.
  // One-time repair for copies stranded by the old auto-revert: until 2.8.1 an
  // unreachable clone server rewrote ttsEngineChoice to 'piper' and persisted
  // it. With no Piper voice installed that means the Windows system voice —
  // and, because the phrase cache is only consulted while a CLONING engine is
  // selected, a fully rendered cache of the user's own voice sat unused with no
  // way back in the UI (the CosyVoice chip was disabled while offline).
  // Restores the clone exactly in that state: clone configured, no Piper voice.
  void _restoreCloneEngineOnce() {
    if (prefs.getBool('cloneEngineRestored') == true) return;
    unawaited(prefs.setBool('cloneEngineRestored', true));
    if (ttsEngineChoice != 'piper' ||
        ttsPiperVoice.trim().isNotEmpty ||
        cosyvoiceEndpoint.trim().isEmpty ||
        cosyvoiceClonePath.trim().isEmpty) {
      return;
    }
    ttsEngineChoice = 'cosyvoice';
    unawaited(prefs.setString('ttsEngineChoice', ttsEngineChoice));
  }

  Future<void> applyCloneServer() async {
    final gameOff = cloneGpuInGame == 'off' &&
        SidecarClient.instance.gameModeStatus.value.$1;
    final on = ttsEngineChoice == 'cosyvoice' &&
        cosyvoiceEndpoint.trim().isNotEmpty &&
        cosyvoiceClonePath.trim().isNotEmpty &&
        !gameOff;
    await SidecarClient.instance.applyCosy(
      enabled: on,
      endpoint: cosyvoiceEndpoint.trim(),
      ref: cosyvoiceClonePath.trim(),
      promptText: cosyvoiceClonePromptText,
      speed: cosyvoiceSpeed,
    );
    if (on) {
      // Pre-render the fixed phrase set so common lines play from cache — the
      // whole point of "cache + Piper" while gaming (zero GPU for known lines).
      SidecarClient.instance.prerender(clonePhrasesToRender());
    }
    await pushCloneGpuConfig();
  }

  // Re-apply when the game mode flips so the server frees (or reclaims) VRAM in
  // step with the game, and the engine is restored afterwards. Wired once from
  // the sidecar bootstrap; a cheap no-op when no clone server is configured.
  bool _cloneGpuGameHooked = false;
  bool? _lastGameActive;
  void hookCloneGpuGameMode() {
    if (_cloneGpuGameHooked) return;
    _cloneGpuGameHooked = true;
    SidecarClient.instance.gameModeStatus.addListener(() {
      final active = SidecarClient.instance.gameModeStatus.value.$1;
      if (active == _lastGameActive) return;
      _lastGameActive = active;
      if (cosyvoiceEndpoint.trim().isEmpty) return;
      unawaited(applyCloneServer());
    });
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
      // Do NOT switch the engine away here. The pre-rendered phrase cache is
      // only consulted while a CLONING engine is active, so auto-reverting to
      // Piper threw away every phrase already rendered in the user's own voice
      // — and with no Piper voice installed that landed on the Windows system
      // voice. Staying on the clone engine keeps cached phrases playing in the
      // cloned voice even with the server down; anything NOT cached falls back
      // per-utterance (Piper, else system voice). The offline state is already
      // visible in the voice status strip.
      if (ttsEngineChoice == 'cosyvoice') {
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
    notifyListeners(); // dropdown selection now (no live text cursor to fight)
  }

  /// The interpreter model actually used: an explicit pick wins, otherwise the
  /// global default — the chat model, then the selected model (skipping local
  /// ones: the interpreter path talks to the HTTP server).
  String get effectiveTtsInterpModel {
    if (ttsInterpModel.trim().isNotEmpty) return ttsInterpModel.trim();
    if (chatModel.trim().isNotEmpty && !isLocalModel(chatModel)) {
      return chatModel.trim();
    }
    if (selectedModel.trim().isNotEmpty && !isLocalModel(selectedModel)) {
      return selectedModel.trim();
    }
    return '';
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
    final model = effectiveTtsInterpModel;
    if (serverUrl.trim().isEmpty || model.isEmpty) return null;
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
      final res = await http
          .post(Uri.parse('$base/api/chat'),
              headers: headers,
              body: jsonEncode({
                'model': model,
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

  // Комбинация Push-to-Talk. Пустой список = «не назначено»: PttWatcher тогда
  // не заводит опрос, а карточка настроек честно об этом пишет.
  void setPttHotkey(List<int> keys, String label) {
    pttKeys = List<int>.unmodifiable(keys);
    pttLabel = label;
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

  // Switch the sidecar recognition engine (whisper | gigaam | remote). Applies
  // live for preview (the card shows loading/ready/error); the choice persists
  // on Save and is resynced to the backend on Save/Cancel via
  // _applySettingsSideEffects.
  static const List<String> kSttSidecarEngines = ['whisper', 'gigaam', 'remote'];

  /// Чем распознавать, пока сервер не отвечает. Настройка видимая — раньше она
  /// выводилась из прошлого выбора и нигде не показывалась.
  void setSttLocalEngine(String v) {
    sttLocalEngine = v == 'whisper' ? 'whisper' : 'gigaam';
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setSttLocalEngine(sttLocalEngine));
  }

  /// Сайдкар сообщил, каким движком распознаёт. Настройку не трогаем: выбор
  /// «на сервере» остаётся выбором пользователя, даже когда сервер молчит —
  /// иначе возврат на сервер пришлось бы делать руками.
  void setSttEngineLive(String v) {
    if (v.isEmpty || v == sttEngineLive) return;
    sttEngineLive = v;
    notifyListeners();
  }

  void setSttSidecarEngine(String v) {
    sttSidecarEngine = kSttSidecarEngines.contains(v) ? v : 'whisper';
    // Выбор локального движка запоминаем отдельно: именно на него откатится
    // распознавание, если сервер не ответит.
    if (sttSidecarEngine != 'remote') sttLocalEngine = sttSidecarEngine;
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setSttEngine(sttSidecarEngine));
  }

  // Адрес/модель/ключ сервера распознавания. Уходят в сайдкар сразу: адрес
  // должен быть у него ДО того, как выберут движок «на сервере», иначе тот
  // переключится на пустой адрес и сразу отвалится.
  void setSttRemoteUrl(String v) {
    sttRemoteUrl = v.trim();
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setSttRemote(
        url: sttRemoteUrl, model: sttRemoteModel, key: sttRemoteKey));
  }

  void setSttRemoteModel(String v) {
    sttRemoteModel = v.trim();
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setSttRemote(
        url: sttRemoteUrl, model: sttRemoteModel, key: sttRemoteKey));
  }

  void setSttRemoteKey(String v) {
    sttRemoteKey = v.trim();
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setSttRemote(
        url: sttRemoteUrl, model: sttRemoteModel, key: sttRemoteKey));
  }

  /// Кнопка «Проверить» у сервера распознавания. Пробу делает сайдкар, а не
  /// приложение: у него уже есть адрес, ключ и та же сетевая обстановка, в
  /// которой пойдут настоящие запросы. Ответ приходит обычным
  /// `stt.engine_status` — карточка читает один сигнал, а не два.
  Future<void> checkSttRemote() async {
    if (sttRemoteUrl.trim().isEmpty) return;
    await SidecarClient.instance.setSttRemote(
        url: sttRemoteUrl, model: sttRemoteModel, key: sttRemoteKey);
    await SidecarClient.instance.checkSttRemote();
  }

  // Switch noise suppression (off | light | strong). Applies live for preview;
  // persists on Save, resynced on Save/Cancel via _applySettingsSideEffects.
  Map<String, dynamic> ttsFxConfig() => {
        'enabled': ttsFxEnabled,
        'highpass': 110,
        'lowpass': ttsFxLowpass,
        'detune': ttsFxDetune,
        'metallic': ttsFxMetallic,
        'reverb': ttsFxReverb,
        'ringHz': 80,
      };

  void setTtsFx({bool? enabled, double? detune, double? metallic, double? reverb, int? lowpass}) {
    if (enabled != null) ttsFxEnabled = enabled;
    if (detune != null) ttsFxDetune = detune;
    if (metallic != null) ttsFxMetallic = metallic;
    if (reverb != null) ttsFxReverb = reverb;
    if (lowpass != null) ttsFxLowpass = lowpass;
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setTtsFx(ttsFxConfig()));
  }

  void applyEdiPreset() {
    ttsFxEnabled = true;
    ttsFxDetune = 0.35;
    ttsFxMetallic = 0.22;
    ttsFxReverb = 0.15;
    ttsFxLowpass = 2200;
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setTtsFx(ttsFxConfig()));
  }

  void setMicVadAggr(int n) {
    micVadAggr = n.clamp(0, 3);
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setVadAggressiveness(micVadAggr));
  }

  void setMicGain(double v) {
    micGain = v.clamp(0.5, 4.0);
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setMicGain(micGain));
  }

  void setDenoiseMode(String v) {
    denoiseMode = (v == 'light' || v == 'strong') ? v : 'off';
    // Remember the choice for the current input device (TZ2 block 8.1) so it
    // sticks per-mic (and is not re-defaulted on the next device switch).
    deviceDenoise[inputDeviceId] = denoiseMode;
    _presetTouched();
    _save();
    notifyListeners();
    unawaited(SidecarClient.instance.setDenoise(denoiseMode));
    unawaited(syncActiveMics());
  }

  // STT compute device (TZ2 block 6). Live preview; persisted on Save.
  void setSttDevice(String v) {
    sttDevice = v == 'cuda' ? 'cuda' : 'cpu';
    _presetTouched();
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

  /// Что показывать сразу после запуска: окно, виджет, оба или ничего. Ставит
  /// сразу два флага, поэтому тумблер «Плавающий виджет» в «Виджетах» никогда
  /// не расходится с этим выбором — он и есть половина этого выбора.
  void setStartupView({required bool window, required bool widget}) {
    startupShowWindow = window;
    _save();
    notifyListeners();
    setOverlayMode(widget); // сам сохранит и поднимет/погасит процесс виджета
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
    _presetTouched();
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

  void setCloneServerPython(String v) {
    cloneServerPython = v.trim();
    _save();
    notifyListeners();
  }

  void setGoogleKey(String v) {
    googleKey = v.trim();
    _save();
    notifyListeners();
  }

  void setGoogleCx(String v) {
    googleCx = v.trim();
    _save();
    notifyListeners();
  }

  void setYandexKey(String v) {
    yandexKey = v.trim();
    _save();
    notifyListeners();
  }

  void setYandexFolder(String v) {
    yandexFolder = v.trim();
    _save();
    notifyListeners();
  }

  void setSearchProvider(String v) {
    searchProvider = WebSearchService.providers.contains(v) ? v : 'auto';
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
  // Custom (user-imported) voices are checked too — they live in the same
  // models dir and load through the same sidecar path.
  String _voiceModelId(String voiceId) {
    for (final s in kAssetModels) {
      if (s.family == 'tts-voice' && s.voiceId == voiceId) return s.id;
    }
    for (final v in customVoices) {
      if (v.voiceId == voiceId) return v.id;
    }
    return '';
  }

  // ---- User-imported Piper voices --------------------------------------

  // Where a bundle's shared pronunciation data can be borrowed from. A raw
  // voice off HuggingFace is just <name>.onnx + <name>.onnx.json, but the
  // sidecar needs tokens.txt AND espeak-ng-data/ beside the model — those ship
  // only inside the packaged (sherpa) bundles. Any already-installed voice has
  // them, and the data is voice-independent, so we reuse it.
  Future<String?> _findEspeakData() async {
    try {
      final root = io.Directory(await modelsDirPath());
      if (!await root.exists()) return null;
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is io.Directory && e.path.endsWith('espeak-ng-data')) {
          return e.path;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _copyDir(io.Directory src, io.Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(recursive: false, followLinks: false)) {
      final name = e.path.split(io.Platform.pathSeparator).last;
      final target = '${dst.path}${io.Platform.pathSeparator}$name';
      if (e is io.Directory) {
        await _copyDir(e, io.Directory(target));
      } else if (e is io.File) {
        await e.copy(target);
      }
    }
  }

  // Build sherpa's tokens.txt ("<token> <id>" per line) from a Piper voice's
  // .onnx.json phoneme_id_map. Returns false if the json isn't a Piper config.
  static Future<bool> _writeTokensFromJson(io.File cfg, String outPath) async {
    try {
      final j = jsonDecode(await cfg.readAsString());
      if (j is! Map) return false;
      final map = j['phoneme_id_map'];
      if (map is! Map || map.isEmpty) return false;
      final lines = <String>[];
      map.forEach((token, ids) {
        final id = (ids is List && ids.isNotEmpty) ? ids.first : ids;
        if (id is num) lines.add('$token ${id.toInt()}');
      });
      if (lines.isEmpty) return false;
      await io.File(outPath).writeAsString('${lines.join('\n')}\n');
      return true;
    } catch (_) {
      return false;
    }
  }

  // Import a Piper voice the user picked. Accepts either a packaged bundle
  // (.tar.bz2 — the sidecar extracts it on first load) or a raw <name>.onnx
  // (its .onnx.json sibling is used to generate tokens.txt, and espeak-ng-data
  // is copied from an installed voice). If the picked .onnx already sits in a
  // complete bundle folder, that whole folder is taken as-is.
  // Returns null on success, or an i18n'd error message.
  Future<String?> importCustomVoice(String srcPath) async {
    try {
      final sep = io.Platform.pathSeparator;
      final src = io.File(srcPath);
      if (!await src.exists()) return t('voiceImportNoFile');
      final fileName = srcPath.split(RegExp(r'[\\/]')).last;
      final lower = fileName.toLowerCase();
      final isTar = lower.endsWith('.tar.bz2');
      final isOnnx = lower.endsWith('.onnx');
      if (!isTar && !isOnnx) return t('voiceImportBadType');

      // Voice id / dir name from the file stem, kept filesystem-safe.
      var stem = fileName
          .replaceAll(RegExp(r'\.tar\.bz2$', caseSensitive: false), '')
          .replaceAll(RegExp(r'\.onnx$', caseSensitive: false), '');
      stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
      if (stem.isEmpty) stem = 'voice';
      var id = 'custom-$stem';
      final models = await modelsDirPath();
      var dir = io.Directory('$models$sep$id');
      var n = 2;
      while (await dir.exists()) {
        id = 'custom-$stem-$n';
        dir = io.Directory('$models$sep$id');
        n++;
      }
      await dir.create(recursive: true);

      if (isTar) {
        await src.copy('${dir.path}$sep$fileName');
      } else {
        final srcDir = src.parent;
        final hasTokens =
            await io.File('${srcDir.path}${sep}tokens.txt').exists();
        final hasData =
            await io.Directory('${srcDir.path}${sep}espeak-ng-data').exists();
        if (hasTokens && hasData) {
          // Already a complete bundle — take the folder wholesale.
          await _copyDir(srcDir, dir);
        } else {
          await src.copy('${dir.path}$sep$fileName');
          final cfg = io.File('$srcPath.json');
          final tokensOk = await cfg.exists()
              ? await _writeTokensFromJson(cfg, '${dir.path}${sep}tokens.txt')
              : false;
          if (await cfg.exists()) {
            await cfg.copy('${dir.path}$sep$fileName.json');
          }
          if (!tokensOk) {
            await dir.delete(recursive: true);
            return t('voiceImportNoTokens');
          }
          final espeak = await _findEspeakData();
          if (espeak == null) {
            await dir.delete(recursive: true);
            return t('voiceImportNoEspeak');
          }
          await _copyDir(
              io.Directory(espeak), io.Directory('${dir.path}${sep}espeak-ng-data'));
        }
      }

      customVoices = [
        ...customVoices,
        CustomVoice(id: id, name: stem, voiceId: id),
      ];
      _save();
      notifyListeners();
      return null;
    } catch (e) {
      return '${t('voiceImportFailed')}: $e';
    }
  }

  Future<void> removeCustomVoice(CustomVoice v) async {
    if (ttsPiperVoice == v.voiceId) setTtsPiperVoice('');
    customVoices = customVoices.where((e) => e.id != v.id).toList();
    _save();
    notifyListeners();
    try {
      final sep = io.Platform.pathSeparator;
      final d = io.Directory('${await modelsDirPath()}$sep${v.id}');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
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
    // Use the value configured on the command (the target the user set in the
    // wizard) first, so running it never depends on hearing a number in speech.
    // That dependency broke both the voice path ("не расслышал число") and the
    // manual test-run (empty utterance). A spoken number still overrides when
    // present and the command has no fixed target.
    var n = cmd.defaultValue ?? NumberWords.extract(utterance);
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

  // Paired phones must persist IMMEDIATELY, never through _save(): pairing
  // happens inside the settings screen, where _save() is deferred until the
  // user presses Save. remoteDevices is also (deliberately) excluded from the
  // settings snapshot, so the draft never went dirty, nothing was ever written,
  // and leaving settings re-read prefs — erasing the just-paired phone from
  // memory too. That is exactly the "phone disappeared after restart" report.
  Future<void> _persistRemoteDevices() async {
    try {
      await prefs.setString('remoteDevices',
          jsonEncode(remoteDevices.map((d) => d.toJson()).toList()));
    } catch (_) {}
  }

  void addRemoteDevice(RemoteDevice d) {
    remoteDevices.add(d);
    _save();
    notifyListeners();
    unawaited(_persistRemoteDevices());
  }

  void removeRemoteDevice(RemoteDevice d) {
    // Unpair = immediate token revocation (§14.7).
    remoteDevices.removeWhere((x) => x.id == d.id);
    _save();
    notifyListeners();
    unawaited(_persistRemoteDevices());
  }

  void renameRemoteDevice(RemoteDevice d, String name) {
    d.name = name.trim();
    _save();
    notifyListeners();
    unawaited(_persistRemoteDevices());
  }

  void setRemoteDevicePerms(RemoteDevice d, {bool? voice, bool? text}) {
    if (voice != null) d.permVoice = voice;
    if (text != null) d.permText = text;
    _save();
    notifyListeners();
    unawaited(_persistRemoteDevices());
  }

  void setRemoteDeviceEnabled(RemoteDevice d, bool v) {
    d.enabled = v;
    _save();
    notifyListeners();
    unawaited(_persistRemoteDevices());
  }

  // Server-side: stamp a device's last activity (no full save churn per request
  // — persisted opportunistically).
  void touchRemoteDevice(RemoteDevice d) {
    d.lastSeen = DateTime.now().toUtc().toIso8601String();
    notifyListeners();
    unawaited(_persistRemoteDevices());
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
  /// A phrase from a paired phone, routed exactly like speech heard here: the
  /// command catalog first, chat only as the fallback. It used to go straight
  /// to the LLM, so phone commands never actually ran anything — and when the
  /// LLM server was unreachable the phone got an error for a command that
  /// needed no model at all.
  ///
  /// `spoken` is true when the command already announced itself on the desktop,
  /// so the caller must not speak the reply a second time.
  Future<({String reply, bool spoken})> runRemoteCommand(String text) async {
    final done = await VoiceAssistant.instance.runRemotePhrase(this, text);
    if (done != null) return (reply: done, spoken: voiceResponses);
    // Commands-only mode: say so instead of silently opening a chat turn.
    if (!chatEnabled) {
      return (reply: '${t('vaCmdNotFound')}: «$text»', spoken: false);
    }
    final service = _llmFactory.current;
    final synthetic = Conversation(id: 'remote-temp', title: '');
    final history = [ChatMessage(role: 'user', content: text)];
    final reply = await service.generateResponse(synthetic, history);
    return (reply: persona.enforceEmojiPolicy(reply).trim(), spoken: false);
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
    // Best-effort scheduler-task cleanup (a leftover disabled task is harmless
    // and not worth a surprise UAC prompt — see tryDeleteElevatedTask).
    if (c.elevated) {
      unawaited(CommandExecutor.instance.tryDeleteElevatedTask(c.value));
    }
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

  // Interface style (Nexus TZ). Applied immediately and outside the settings
  // dirty mechanism, exactly like setThemeMode — the whole shell re-themes on
  // the next build because the skin resolves from appStyle.
  void setAppStyle(AppStyle v) {
    appStyle = v;
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

  void setMotionMode(String v) {
    motionMode = (v == 'full' || v == 'saver') ? v : 'balanced';
    MotionPolicy.setMode(motionMode);
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
    // «Разрешить чат» выключен — до 2.10.3 это держалось только ветками внутри
    // композеров, и стиль «Ноктюрн», добавленный позже, такой ветки не имел:
    // тумблер стоял выключенным, а чат продолжал работать. Гейт здесь — чтобы
    // следующий шелл не смог повторить ту же ошибку. Голосовой путь от этого не
    // страдает: он отсекается раньше, в VoiceAssistant._handle.
    if (!chatEnabled) return '';
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
