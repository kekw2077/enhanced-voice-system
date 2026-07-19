part of '../main.dart';

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
