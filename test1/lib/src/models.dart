part of '../main.dart';

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
  ChangelogEntry('2.4.0', [
    'Клон голоса (XTTS) — временный локальный клонировщик, работает на процессоре без видеокарты. В разделе «Движок озвучки» включите «Клон голоса», выберите образец WAV 6–10 секунд — и ассистент отвечает этим голосом. Отдельный тяжёлый компонент (~3–4 ГБ, torch + модель) догружается один раз при включении.',
    'Заготовка фраз: системные фразы и озвучка команд заранее «пред-рендерятся» в клонированном голосе и звучат мгновенно; новый длинный текст синтезируется на ходу. Можно добавлять свои фразы. Кэш общий для всех движков — CosyVoice подхватит его, когда появится сервер на видеокарте.',
    'Поверх клона можно наложить Voice FX (например, пресет «EDI»).',
  ]),
  ChangelogEntry('2.3.3', [
    'Эффект голоса (Voice FX) для синтеза и клона: расстройка-дубль, «металлик», реверб и срез верхов — с пресетом «EDI» (синтетический ИИ-голос) и слайдерами в разделе голоса. Накладывается на озвучку в реальном времени.',
  ]),
  ChangelogEntry('2.3.2', [
    'Чувствительность микрофона: в разделе распознавания появился выбор строгости определения речи — ниже строгость, тем на более тихую и дальнюю речь реагирует микрофон (применяется при следующем запуске прослушивания).',
    'Нейтральные серые подписи и вторичный текст теперь следуют теме — на светлой Claude тёплые вместо холодно-серых.',
  ]),
  ChangelogEntry('2.3.1', [
    'EVS переведён в собственный репозиторий проекта — автообновления теперь приходят оттуда. Для вас ничего не меняется: обновление скачается и применится как обычно.',
  ]),
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
