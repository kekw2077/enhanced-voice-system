import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:fllama/fllama.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'local_model_stub.dart' if (dart.library.io) 'local_model_io.dart';

const _minSplashDuration = Duration(milliseconds: 1200);

void main() async {
  final startedAt = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(prefs);
  await app.load();

  final elapsed = DateTime.now().difference(startedAt);
  if (elapsed < _minSplashDuration) {
    await Future.delayed(_minSplashDuration - elapsed);
  }

  runApp(ChangeNotifierProvider.value(value: app, child: const MiraiApp()));
}

/* ============================ ЛОКАЛИЗАЦИЯ ============================ */

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'appName': 'Mirai',
    'howCanIHelp': 'Чем могу помочь?',
    'subtitle':
        'Приватный ИИ для письма, планирования, кода и повседневных вопросов.',
    'askAnything': 'Спросите что угодно',
    'summarize': 'Кратко',
    'rewrite': 'Переписать',
    'fixGrammar': 'Грамматика',
    'thinking': 'Думаю…',
    'downloadedModels': 'Доступные модели',
    'manageModels': 'Управление моделями',
    'newChat': 'Новый чат',
    'createImage': 'Создать изображение',
    'createImageHint':
        'Создание изображения — отправьте запрос модели изображений',
    'loadingModels': 'Загрузка моделей…',
    'noModelsFound': 'Модели не найдены',
    'noModelsAvailable': 'Нет доступных моделей',
    'refreshModels': 'Обновить список моделей',
    'mute': 'Выкл. микрофон',
    'unmute': 'Вкл. микрофон',
    'listening': 'Внимательно слушаю…',
    'preparingMic': 'Подключение микрофона…',
    'muted': 'Микрофон выключен',
    'micSettingsTitle': 'Настройки микрофона',
    'micAutoSend': 'Автоотправка после паузы',
    'micAutoSendDesc': 'Сообщение отправится само, как только вы замолчите',
    'micPauseDuration': 'Длительность паузы перед отправкой',
    'send': 'Отправить',
    'speakNaturally':
        'Говорите свободно. Mirai ответит, как только вы сделаете паузу.',
    'conversations': 'Беседы',
    'chats': 'Чаты',
    'chatsDesc':
        'Здесь хранятся ваши недавние диалоги, готовые продолжиться в любой момент.',
    'chatsLabel': 'ЧАТЫ',
    'pinnedLabel': 'ЗАКРЕПЛЁННЫЕ',
    'latestLabel': 'ПОСЛЕДНИЙ',
    'noChatsYet': 'Чатов пока нет',
    'startFresh': 'Начните новый пустой диалог.',
    'recent': 'Недавние',
    'noChatsDesc':
        'Как только вы начнёте общение, история диалогов появится здесь.',
    'startNewChat': 'Начать новый чат',
    'searchChats': 'Поиск по чатам и сообщениям',
    'messages': 'сообщений',
    'pin': 'Закрепить',
    'unpin': 'Открепить',
    'delete': 'Удалить',
    'justNow': 'только что',
    'minAgo': 'мин назад',
    'hAgo': 'ч назад',
    'dAgo': 'дн назад',
    'settings': 'Настройки',
    'settingsDesc':
        'Настройте Mirai, управляйте поведением приложения и просматривайте сведения в одном месте.',
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
    'onDevice': 'на устройстве',
    'downloadModel': 'Скачать',
    'downloadingModel': 'Загрузка…',
    'cancelDownload': 'Отмена',
    'useModel': 'Использовать',
    'modelInUse': 'Используется',
    'deleteModel': 'Удалить',
    'localModelMissing':
        'Файл модели не найден. Скачайте модель ещё раз в разделе «Локальные модели».',
    'deleteLocalModelTitle': 'Удалить модель?',
    'deleteLocalModelBody':
        'Файл модели будет удалён с устройства. Скачать её снова можно в любой момент.',
    'personalization': 'Персонализация',
    'memory': 'Память',
    'language': 'Язык',
    'serverAddress': 'Адрес сервера',
    'showKeyboard': 'Клавиатура при запуске',
    'haptics': 'Виброотклик',
    'themeMode': 'Тема',
    'themeSystem': 'Системная',
    'themeLight': 'Светлая',
    'themeDark': 'Тёмная',
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
    'attachImage': 'Прикрепить изображение',
    'attachFile': 'Прикрепить файл',
    'fileAttached': 'Файл прикреплён',
    'imageAttached': 'Изображение прикреплено',
    'serverError': 'Ошибка сервера',
    'unreachable': 'Не удалось подключиться к серверу',
    'checkAddress': 'Проверьте адрес в настройках.',
    'pers': 'Персонализация',
    'chatPers': 'Настройки этого чата',
    'tabPersonality': 'Личность',
    'tabMemory': 'Память',
    'persDesc': 'Настройте личность, поведение и контекст ассистента под себя.',
    'persPersona': 'Личность и стиль общения',
    'persPreset': 'Готовая персона',
    'preset_friend': 'Лучший друг',
    'preset_mentor': 'Наставник / Коуч',
    'preset_expert': 'Эксперт',
    'preset_creative': 'Креативный партнёр',
    'preset_custom': 'Свой стиль',
    'slidersTitle': 'Черты характера',
    'sl_formality': 'Формальность',
    'sl_empathy': 'Эмпатия',
    'sl_verbosity': 'Детализация',
    'sl_humor': 'Юмор',
    'sl_creativity': 'Креативность',
    'speechStyle': 'Стиль речи',
    'emojiUsage': 'Эмодзи',
    'emoji_never': 'Никогда',
    'emoji_sometimes': 'Иногда',
    'emoji_always': 'Всегда',
    'answerFormat': 'Формат ответов',
    'fmt_plain': 'Обычный текст',
    'fmt_lists': 'Списки',
    'fmt_tables': 'Таблицы где можно',
    'persBehavior': 'Функциональность и поведение',
    'defaultLength': 'Длина ответа по умолчанию',
    'len_short': 'Короткая',
    'len_normal': 'Стандартная',
    'len_long': 'Развёрнутая',
    'proactivity': 'Проактивность',
    'pro_answer': 'Только отвечать',
    'pro_clarify': 'Задавать уточнения',
    'pro_suggest': 'Предлагать темы',
    'useMarkdown': 'Использовать markdown-разметку',
    'memorySection': 'Память и контекст',
    'longMemory': 'Долговременная память',
    'memoryNote': 'Запомни обо мне, что…',
    'persProfile': 'О вас',
    'name': 'Имя',
    'pronouns': 'Местоимения',
    'profession': 'Профессия',
    'interests': 'Интересы и хобби',
    'goals': 'Цели',
    'useMyData': 'Использовать мои данные для ответов',
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
    'persAdvanced': 'Продвинутые настройки',
    'reasoning': 'Стиль мышления',
    'rs_fast': 'Быстрый и интуитивный',
    'rs_step': 'Пошаговое рассуждение',
    'toneTitle': 'Тон в тексте',
    'tone_neutral': 'Нейтральный',
    'tone_sarcastic': 'Саркастичный',
    'tone_melancholic': 'Меланхоличный',
    'tone_excited': 'Восторженный',
    'customPrompt': 'Свой системный промпт',
    'customPromptHint': 'Прямая инструкция ассистенту…',
  },
  'en': {
    'appName': 'Mirai',
    'howCanIHelp': 'How can I help?',
    'subtitle':
        'Private AI for writing, planning, coding, and everyday questions.',
    'askAnything': 'Ask anything',
    'summarize': 'Summarize',
    'rewrite': 'Rewrite',
    'fixGrammar': 'Fix Grammar',
    'thinking': 'Thinking…',
    'downloadedModels': 'Downloaded Models',
    'manageModels': 'Manage Models',
    'newChat': 'New Chat',
    'createImage': 'Create Image',
    'createImageHint': 'Create Image — send a request to an image model',
    'loadingModels': 'Loading models…',
    'noModelsFound': 'No models found',
    'noModelsAvailable': 'No models available',
    'refreshModels': 'Refresh model list',
    'mute': 'Mute',
    'unmute': 'Unmute',
    'listening': 'Listening carefully…',
    'preparingMic': 'Connecting microphone…',
    'muted': 'Muted',
    'micSettingsTitle': 'Microphone settings',
    'micAutoSend': 'Auto-send after pause',
    'micAutoSendDesc': 'The message sends itself as soon as you go quiet',
    'micPauseDuration': 'Pause duration before sending',
    'send': 'Send',
    'speakNaturally':
        'Speak naturally. Mirai will respond as soon as you pause.',
    'conversations': 'Conversations',
    'chats': 'Chats',
    'chatsDesc':
        'Your recent work lives here, ready to resume whenever you are.',
    'chatsLabel': 'CHATS',
    'pinnedLabel': 'PINNED',
    'latestLabel': 'LATEST',
    'noChatsYet': 'No chats yet',
    'startFresh': 'Start fresh with an empty thread.',
    'recent': 'Recent',
    'noChatsDesc':
        'Once you start chatting, your local conversation history will show up here.',
    'startNewChat': 'Start New Chat',
    'searchChats': 'Search chats and messages',
    'messages': 'messages',
    'pin': 'Pin',
    'unpin': 'Unpin',
    'delete': 'Delete',
    'justNow': 'just now',
    'minAgo': 'm ago',
    'hAgo': 'h ago',
    'dAgo': 'd ago',
    'settings': 'Settings',
    'settingsDesc':
        'Personalize Mirai, manage device behavior, and review the app details in one place.',
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
    'onDevice': 'on-device',
    'downloadModel': 'Download',
    'downloadingModel': 'Downloading…',
    'cancelDownload': 'Cancel',
    'useModel': 'Use',
    'modelInUse': 'In use',
    'deleteModel': 'Delete',
    'localModelMissing':
        'Model file not found. Download it again from the Local models screen.',
    'deleteLocalModelTitle': 'Delete this model?',
    'deleteLocalModelBody':
        'The model file will be removed from your device. You can download it again anytime.',
    'personalization': 'Personalization',
    'memory': 'Memory',
    'language': 'Language',
    'serverAddress': 'Server address',
    'showKeyboard': 'Show keyboard on launch',
    'haptics': 'Haptics',
    'themeMode': 'Theme',
    'themeSystem': 'System',
    'themeLight': 'Light',
    'themeDark': 'Dark',
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
    'attachImage': 'Attach image',
    'attachFile': 'Attach file',
    'fileAttached': 'File attached',
    'imageAttached': 'Image attached',
    'serverError': 'Server error',
    'unreachable': 'Could not reach the server',
    'checkAddress': 'Check the address in Settings.',
    'pers': 'Personalization',
    'chatPers': 'This chat\'s settings',
    'tabPersonality': 'Personality',
    'tabMemory': 'Memory',
    'persDesc': "Tailor the assistant's personality, behavior and context.",
    'persPersona': 'Character & vibe',
    'persPreset': 'Persona preset',
    'preset_friend': 'Best friend',
    'preset_mentor': 'Mentor / Coach',
    'preset_expert': 'Expert',
    'preset_creative': 'Creative partner',
    'preset_custom': 'Custom',
    'slidersTitle': 'Character traits',
    'sl_formality': 'Formality',
    'sl_empathy': 'Empathy',
    'sl_verbosity': 'Detail',
    'sl_humor': 'Humor',
    'sl_creativity': 'Creativity',
    'speechStyle': 'Speech style',
    'emojiUsage': 'Emoji',
    'emoji_never': 'Never',
    'emoji_sometimes': 'Sometimes',
    'emoji_always': 'Always',
    'answerFormat': 'Answer format',
    'fmt_plain': 'Plain text',
    'fmt_lists': 'Lists',
    'fmt_tables': 'Tables when possible',
    'persBehavior': 'Functionality & behavior',
    'defaultLength': 'Default answer length',
    'len_short': 'Short',
    'len_normal': 'Standard',
    'len_long': 'Detailed',
    'proactivity': 'Proactivity',
    'pro_answer': 'Answer only',
    'pro_clarify': 'Ask clarifying questions',
    'pro_suggest': 'Suggest related topics',
    'useMarkdown': 'Use markdown formatting',
    'memorySection': 'Memory & context',
    'longMemory': 'Long-term memory',
    'memoryNote': 'Remember about me that…',
    'persProfile': 'About you',
    'name': 'Name',
    'pronouns': 'Pronouns',
    'profession': 'Profession',
    'interests': 'Interests & hobbies',
    'goals': 'Goals',
    'useMyData': 'Use my data to improve answers',
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
    'persAdvanced': 'Advanced',
    'reasoning': 'Reasoning style',
    'rs_fast': 'Fast & intuitive',
    'rs_step': 'Step-by-step reasoning',
    'toneTitle': 'Text tone',
    'tone_neutral': 'Neutral',
    'tone_sarcastic': 'Sarcastic',
    'tone_melancholic': 'Melancholic',
    'tone_excited': 'Excited',
    'customPrompt': 'Custom system prompt',
    'customPromptHint': 'Direct instruction to the assistant…',
  },
};

/* ============================ МОДЕЛИ ДАННЫХ ============================ */

class ChatMessage {
  final String role;
  final String content;
  final DateTime time;
  final List<String> attachments;
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? time,
    List<String>? attachments,
  }) : time = time ?? DateTime.now(),
       attachments = attachments ?? [];

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'time': time.toIso8601String(),
    'attachments': attachments,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
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

  Conversation({
    required this.id,
    required this.title,
    this.pinned = false,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.persona,
  }) : updatedAt = updatedAt ?? DateTime.now(),
       messages = messages ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'pinned': pinned,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'persona': persona?.toJson(),
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

  String buildSystemPrompt() {
    final b = StringBuffer();
    b.writeln('You are Mirai, a helpful AI assistant.');

    String lvl(double v) => v < 0.33 ? 'low' : (v < 0.66 ? 'medium' : 'high');
    b.writeln(
      'Style: formality ${lvl(formality)}, empathy ${lvl(empathy)}, '
      'verbosity ${lvl(verbosity)}, humor ${lvl(humor)}, creativity ${lvl(creativity)}.',
    );

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
      final prof = <String>[];
      if (name.isNotEmpty) prof.add('name: $name');
      if (pronouns.isNotEmpty) prof.add('pronouns: $pronouns');
      if (profession.isNotEmpty) prof.add('profession: $profession');
      if (interests.isNotEmpty) prof.add('interests: $interests');
      if (goals.isNotEmpty) prof.add('goals: $goals');
      if (location.isNotEmpty) prof.add('location: $location');
      if (prof.isNotEmpty) {
        b.writeln('User profile (use it naturally): ${prof.join('; ')}.');
      }
      b.writeln(
        'Explain things at a ${knowledgeLevel.replaceFirst('kl_', '')} level.',
      );
    }

    if (longMemory && memoryNote.isNotEmpty) {
      b.writeln('Remember about the user: $memoryNote');
    }

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
    b.writeln('You are Mirai, a helpful assistant. Answer naturally and directly.');
    if (defaultLength == 'len_short') {
      b.writeln('Keep answers short.');
    } else if (defaultLength == 'len_long') {
      b.writeln('Give detailed answers.');
    }
    // Only written when they differ from the default — one extra plain
    // sentence per setting is fine, it's the dense multi-attribute "Style:
    // formality X, empathy Y, ..." line above that small models choke on.
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
}

/* ============================ ЛОКАЛЬНЫЕ МОДЕЛИ ============================ */

enum LocalModelTier { light, mid, high }

class LocalModelSpec {
  final String id;
  final String displayName;
  final int sizeBytes;
  final String url;
  final String fileName;
  final LocalModelTier tier;

  const LocalModelSpec({
    required this.id,
    required this.displayName,
    required this.sizeBytes,
    required this.url,
    required this.fileName,
    required this.tier,
  });

  String get modelKey => 'local:$id';
}

const List<LocalModelSpec> kLocalModels = [
  // Лёгкие — слабые/старые телефоны (32-бит ARM, мало ОЗУ)
  LocalModelSpec(
    id: 'qwen2.5-0.5b',
    displayName: 'Qwen2.5 0.5B Instruct',
    sizeBytes: 491400032,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.light,
  ),
  LocalModelSpec(
    id: 'llama-3.2-1b',
    displayName: 'Llama 3.2 1B Instruct',
    sizeBytes: 807694464,
    url:
        'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
    tier: LocalModelTier.light,
  ),
  // Средние — современные смартфоны среднего класса (например, Honor 70)
  LocalModelSpec(
    id: 'qwen2.5-1.5b',
    displayName: 'Qwen2.5 1.5B Instruct',
    sizeBytes: 1117320736,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.mid,
  ),
  LocalModelSpec(
    id: 'gemma2-2b',
    displayName: 'Gemma 2 2B Instruct',
    sizeBytes: 1708582752,
    url:
        'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf?download=true',
    fileName: 'gemma-2-2b-it-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
  ),
  LocalModelSpec(
    id: 'qwen2.5-3b',
    displayName: 'Qwen2.5 3B Instruct',
    sizeBytes: 2104932768,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.mid,
  ),
  LocalModelSpec(
    id: 'phi-3-mini-4k',
    displayName: 'Phi-3 Mini 4K Instruct',
    sizeBytes: 2393231072,
    url:
        'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf?download=true',
    fileName: 'Phi-3-mini-4k-instruct-q4.gguf',
    tier: LocalModelTier.mid,
  ),
  // Мощные — флагманы с большим запасом ОЗУ (например, iPhone 15 Pro Max)
  LocalModelSpec(
    id: 'mistral-7b-v0.3',
    displayName: 'Mistral 7B Instruct v0.3',
    sizeBytes: 4372812000,
    url:
        'https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf?download=true',
    fileName: 'Mistral-7B-Instruct-v0.3-Q4_K_M.gguf',
    tier: LocalModelTier.high,
  ),
  LocalModelSpec(
    id: 'qwen2.5-7b',
    displayName: 'Qwen2.5 7B Instruct',
    sizeBytes: 4683074240,
    url:
        'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    tier: LocalModelTier.high,
  ),
  LocalModelSpec(
    id: 'llama-3.1-8b',
    displayName: 'Llama 3.1 8B Instruct',
    sizeBytes: 4920739232,
    url:
        'https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
    tier: LocalModelTier.high,
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

/* ============================ СОСТОЯНИЕ ============================ */

enum AppThemeMode { system, light, dark }

class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  AppState(this.prefs);

  final _uuid = const Uuid();

  String lang = 'ru';
  String t(String key) => _i18n[lang]?[key] ?? _i18n['en']?[key] ?? key;

  AppThemeMode themeMode = AppThemeMode.system;
  bool haptics = true;
  bool showKeyboardOnLaunch = false;
  bool showPromptChips = true;
  double fontSize = 1.0;
  bool micAutoSend = true;
  int micPauseSeconds = 3;

  String serverUrl = '';
  String apiKey = '';
  List<String> models = [];
  String selectedModel = '';
  bool loadingModels = false;
  String? modelsError;

  Set<String> downloadedLocalModelIds = {};
  final Map<String, double> localDownloadProgress = {};
  final Set<String> _cancelledLocalDownloads = {};

  bool checkingForUpdate = false;
  String? updateCheckError;
  String? updateAvailableVersion;
  String? _updateApkUrl;
  double? updateDownloadProgress;
  String? lastSeenVersion;

  Personalization persona = Personalization();

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

  bool get isDarkMode {
    switch (themeMode) {
      case AppThemeMode.dark:
        return true;
      case AppThemeMode.light:
        return false;
      case AppThemeMode.system:
        final brightness =
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
        return brightness == Brightness.dark;
    }
  }

  Future<void> load() async {
    lang = prefs.getString('lang') ?? 'ru';
    final tm = prefs.getString('themeMode') ?? 'system';
    themeMode = AppThemeMode.values.firstWhere(
      (e) => e.name == tm,
      orElse: () => AppThemeMode.system,
    );
    haptics = prefs.getBool('haptics') ?? true;
    showKeyboardOnLaunch = prefs.getBool('showKeyboardOnLaunch') ?? false;
    showPromptChips = prefs.getBool('showPromptChips') ?? true;
    fontSize = prefs.getDouble('fontSize') ?? 1.0;
    micAutoSend = prefs.getBool('micAutoSend') ?? true;
    micPauseSeconds = prefs.getInt('micPauseSeconds') ?? 3;
    serverUrl = prefs.getString('serverUrl') ?? '';
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
    lastSeenVersion = prefs.getString('lastSeenVersion');

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

  Future<void> _save() async {
    await prefs.setString('lang', lang);
    await prefs.setString('themeMode', themeMode.name);
    await prefs.setBool('haptics', haptics);
    await prefs.setBool('showKeyboardOnLaunch', showKeyboardOnLaunch);
    await prefs.setBool('showPromptChips', showPromptChips);
    await prefs.setDouble('fontSize', fontSize);
    await prefs.setBool('micAutoSend', micAutoSend);
    await prefs.setInt('micPauseSeconds', micPauseSeconds);
    await prefs.setString('serverUrl', serverUrl);
    await prefs.setString('apiKey', apiKey);
    await prefs.setStringList('models', models);
    await prefs.setString('selectedModel', selectedModel);
    await prefs.setStringList(
      'downloadedLocalModelIds',
      downloadedLocalModelIds.toList(),
    );
    await prefs.setString('persona', jsonEncode(persona.toJson()));
    await prefs.setString(
      'conversations',
      jsonEncode(conversations.map((c) => c.toJson()).toList()),
    );
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
    _save();
    notifyListeners();
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

  String modelDisplayName(String modelKey) {
    if (modelKey.isEmpty) return t('noModelsAvailable');
    final spec = localSpecFor(modelKey);
    if (spec == null) return modelKey;
    return '${spec.displayName} (${t('onDevice')})';
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
    List<int> parse(String v) => v
        .split('+')
        .first
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
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
      final res = await http.get(Uri.parse(
          'https://api.github.com/repos/$_updateRepo/releases/latest'));
      if (res.statusCode == 404) {
        return; // no releases published yet — not an error
      }
      if (res.statusCode != 200) {
        updateCheckError = t('updateCheckFailed');
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String?) ?? '';
      final remoteVersion = tag.startsWith('v') ? tag.substring(1) : tag;
      final assets = (data['assets'] as List?) ?? [];
      String? apkUrl;
      for (final a in assets) {
        final name = (a['name'] as String?) ?? '';
        if (name.toLowerCase().endsWith('.apk')) {
          apkUrl = a['browser_download_url'] as String?;
          break;
        }
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
      await downloadFileWithProgress(
        url,
        path,
        (received, total) {
          updateDownloadProgress = total > 0 ? received / total : null;
          notifyListeners();
        },
        () => false,
      );
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

  void deleteChat(Conversation c) {
    conversations.remove(c);
    if (current == c) current = null;
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

  Future<String> _sendLocalMessage(Conversation conv) async {
    final spec = localSpecFor(selectedModel);
    if (spec == null) return t('localModelMissing');
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return t('localModelMissing');

    final effectivePersona = conv.persona ?? persona;
    // Only the weakest (light-tier) models reliably break down on the full
    // multi-directive prompt — mid/high tier local models are capable
    // instruct models in their own right and should get full
    // personalization, same as remote models.
    final systemPrompt = spec.tier == LocalModelTier.light
        ? effectivePersona.buildLocalSystemPrompt()
        : effectivePersona.buildSystemPrompt();

    final messages = <Message>[
      Message(Role.system, systemPrompt),
      ...conv.messages.map(
        (m) => Message(
          m.role == 'user' ? Role.user : Role.assistant,
          m.content.isNotEmpty
              ? m.content
              : '[Attached files: ${m.attachments.join(', ')}]',
        ),
      ),
    ];

    final completer = Completer<String>();
    try {
      await fllamaChat(
        OpenAiRequest(
          messages: messages,
          modelPath: modelPath,
          // fllama hardcodes n_parallel=4 natively and ignores nParallel on
          // native platforms, splitting contextSize into 4 slots internally
          // (n_ctx_seq = n_ctx / 4). Requesting 4x gives ~2048 usable tokens.
          contextSize: 8192,
          maxTokens: 512,
          temperature: 0.7,
        ),
        (response, openaiJson, done) {
          if (done && !completer.isCompleted) completer.complete(response);
        },
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete('${t('unreachable')} ($e)');
      }
    }
    return completer.future;
  }

  Future<String> sendMessage(
    String text, {
    List<String> attachments = const [],
  }) async {
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

    String reply;
    if (selectedModel.isEmpty) {
      reply = t('noModelsAvailable');
    } else if (isLocalModel(selectedModel)) {
      reply = await _sendLocalMessage(conv);
    } else {
      try {
        final headers = {'Content-Type': 'application/json'};
        if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';

        final msgs = <Map<String, dynamic>>[
          {
            'role': 'system',
            'content': (conv.persona ?? persona).buildSystemPrompt(),
          },
          ...conv.messages.map(
            (m) => {
              'role': m.role,
              'content': m.content.isNotEmpty
                  ? m.content
                  : '[Attached files: ${m.attachments.join(', ')}]',
            },
          ),
        ];

        final res = await http
            .post(
              Uri.parse('$baseUrl/api/chat'),
              headers: headers,
              body: jsonEncode({
                'model': selectedModel,
                'stream': false,
                'messages': msgs,
              }),
            )
            .timeout(const Duration(seconds: 60));

        if (res.statusCode == 200) {
          try {
            final data = jsonDecode(res.body);
            if (data is Map<String, dynamic>) {
              reply = _extractContent(data) ?? '—';
            } else {
              reply = '—';
            }
          } catch (_) {
            reply = '—';
          }
        } else {
          reply = '${t('serverError')} ${res.statusCode}: ${res.body}';
        }
      } catch (e) {
        reply = '${t('unreachable')} $baseUrl.\n($e)\n\n${t('checkAddress')}';
      }
    }

    conv.messages.add(ChatMessage(role: 'assistant', content: reply.trim()));
    conv.updatedAt = DateTime.now();
    _save();
    notifyListeners();
    return reply;
  }
}

/* ============================ ТЕМА / ПРИЛОЖЕНИЕ ============================ */

class MiraiApp extends StatelessWidget {
  const MiraiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mirai',
      theme: _buildTheme(false),
      darkTheme: _buildTheme(true),
      themeMode: _getThemeMode(app.themeMode),
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
      home: const ChatScreen(),
    );
  }

  ThemeMode _getThemeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  ThemeData _buildTheme(bool dark) {
    final scheme = dark
        ? const ColorScheme.dark(
            primary: Color(0xFF7C8CF8),
            surface: Color(0xFF15151E),
          )
        : const ColorScheme.light(
            primary: Color(0xFF2F6BFF),
            surface: Color(0xFFF2F3F7),
          );
    final bg = dark ? const Color(0xFF0E0E15) : const Color(0xFFFFFFFF);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: 'Roboto',
    );
  }
}

Color _bg(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF0E0E15)
    : Colors.white;
Color _card(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF1C1C26)
    : const Color(0xFFEDEEF3);
Color _txt(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white : Colors.black;
Color _sub(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF8A8A95)
    : const Color(0xFF6B6B72);

/* ============================ СФЕРА ИЗ ЧАСТИЦ ============================ */

class ParticleSphere extends StatefulWidget {
  final double size;
  final Color color;
  final bool dense;
  final bool active;
  final bool scattered;
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
  _SpherePainter(
    this.points,
    this.t,
    this.color,
    this.active,
    this.disperse,
    this.level,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final R = size.width / 2 * 0.92;
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
            color.withValues(alpha: 0.18 * (1 - disperse) * (1 + reactive)),
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
                  (1 + reactive * 0.6))
              .clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(
        Offset(px, py),
        p.radius * scale * (1 - disperse * 0.3) * (1 + reactive * 0.35),
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

const kAccentGradientColors = [Color(0xFF4FACFE), Color(0xFF2F6BFF)];

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

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  bool _sending = false;
  final List<String> _pendingAttachments = [];
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final app = context.read<AppState>();
      if (app.showKeyboardOnLaunch) {
        _inputFocus.requestFocus();
      }
      final entry = await app.consumeWhatsNew();
      if (!mounted || entry == null) return;
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
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

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        setState(() => _pendingAttachments.add(file.path!));
        if (mounted) {
          final app = context.read<AppState>();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(app.t('fileAttached'))));
        }
      }
    }
  }

  Future<void> _pickImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      setState(() => _pendingAttachments.add(file.path));
      if (mounted) {
        final app = context.read<AppState>();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(app.t('imageAttached'))));
      }
    }
  }

  Future<void> _send([String? preset]) async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final text = (preset ?? _controller.text).trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) || _sending) return;
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(app.t('createImageHint'))));
        },
      ),
    );
  }

  void _openSettings() {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SettingsSheet(),
    );
  }

  void _openConversations() {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ConversationsSheet(),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openChatPersonalization() {
    if (!mounted) return;
    final app = context.read<AppState>();
    if (app.current == null) app.newChat();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PersonalizationScreen(conversation: app.current),
      ),
    );
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

    return Scaffold(
      backgroundColor: _bg(context),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(app),
            Expanded(
              child: hasMessages ? _messageList(conv) : _emptyState(app),
            ),
            if (app.showPromptChips && !hasMessages) _promptChips(app),
            if (_pendingAttachments.isNotEmpty) _attachmentBar(app),
            _inputBar(app),
          ],
        ),
      ),
    );
  }

  Widget _topBar(AppState app) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          _circleBtn(Icons.settings_outlined, _openSettings),
          const Spacer(),
          Flexible(
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                app.buzz();
                _openModelMenu();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
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
                          app.modelDisplayName(app.selectedModel),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _txt(context),
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(Icons.keyboard_arrow_down, color: _txt(context)),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          _circleBtn(Icons.manage_accounts_outlined, _openChatPersonalization),
          const SizedBox(width: 8),
          _circleBtn(Icons.chat_bubble_outline, _openConversations),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return InkResponse(
      onTap: () {
        if (!mounted) return;
        context.read<AppState>().buzz();
        onTap();
      },
      radius: 28,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _sub(context).withValues(alpha: 0.3)),
          color: _card(context).withValues(alpha: 0.4),
        ),
        child: Icon(icon, color: _txt(context), size: 22),
      ),
    );
  }

  Widget _emptyState(AppState app) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 20),
            ParticleSphere(
              size: 200,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : const Color(0xFF2F6BFF),
              scattered: keyboardOpen,
            ),
            const SizedBox(height: 20),
            Text(
              app.t('howCanIHelp'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _txt(context),
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                app.t('subtitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _messageList(Conversation conv) {
    final app = context.read<AppState>();
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: conv.messages.length + (_sending ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= conv.messages.length) {
          return _bubble(
            ChatMessage(role: 'assistant', content: app.t('thinking')),
          );
        }
        return _bubble(conv.messages[i]);
      },
    );
  }

  Widget _bubble(ChatMessage m) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primary
              : _card(context),
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
                        color: isUser ? Colors.white70 : _sub(context),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          a.split('/').last,
                          style: TextStyle(
                            color: isUser ? Colors.white70 : _sub(context),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (m.content.isNotEmpty)
              Text(
                m.content,
                style: TextStyle(
                  color: isUser ? Colors.white : _txt(context),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
          ],
        ),
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

  Widget _attachmentBar(AppState app) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: _pendingAttachments.map((a) {
          return Chip(
            avatar: const Icon(Icons.attach_file, size: 16),
            label: Text(
              a.split('/').last,
              style: TextStyle(fontSize: 12, color: _txt(context)),
            ),
            onDeleted: () => setState(() => _pendingAttachments.remove(a)),
            backgroundColor: _card(context),
            side: BorderSide(color: _sub(context).withValues(alpha: 0.3)),
          );
        }).toList(),
      ),
    );
  }

  Widget _inputBar(AppState app) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      child: AnimatedBorder(
        radius: 20,
        strokeWidth: 2,
        child: Container(
          decoration: BoxDecoration(
            color: _card(context),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              // Кнопка добавления с анимированной обводкой
              _buildAnimatedBtn(
                onTap: () {
                  app.buzz();
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: _card(context),
                    builder: (_) => _attachMenu(app),
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
                  style: TextStyle(color: _txt(context), fontSize: 16),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: app.t('askAnything'),
                    hintStyle: TextStyle(color: _sub(context), fontSize: 16),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              // Кнопка голосового ввода с анимированной обводкой
              _buildAnimatedBtn(onTap: _openVoice, icon: Icons.graphic_eq),
              const SizedBox(width: 4),
              // Кнопка отправки (фиксированный размер, чтобы не "скакать"
              // между обычным и состоянием отправки)
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _txt(context).withValues(alpha: 0.1),
                ),
                child: _sending
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _txt(context),
                        ),
                      )
                    : IconButton(
                        onPressed: () => _send(),
                        icon: Icon(Icons.arrow_upward, color: _txt(context)),
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
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
    return AnimatedBorder(
      radius: 20,
      strokeWidth: 2,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _card(context),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _txt(context), size: 20),
          ),
        ),
      ),
    );
  }

  Widget _attachMenu(AppState app) {
    return SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: Icon(
              Icons.add_photo_alternate_outlined,
              color: _txt(context),
            ),
            title: Text(
              app.t('attachImage'),
              style: TextStyle(color: _txt(context)),
            ),
            onTap: () {
              Navigator.pop(context);
              _pickImage();
            },
          ),
          ListTile(
            leading: Icon(Icons.attach_file, color: _txt(context)),
            title: Text(
              app.t('attachFile'),
              style: TextStyle(color: _txt(context)),
            ),
            onTap: () {
              Navigator.pop(context);
              _pickFile();
            },
          ),
        ],
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
                color: const Color(0xFF1C1C26),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
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
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        if (app.loadingModels)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          )
                        else
                          InkWell(
                            onTap: () {
                              app.buzz();
                              app.fetchModels();
                            },
                            child: const Icon(
                              Icons.refresh,
                              color: Colors.white54,
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
                                style: const TextStyle(
                                  color: Colors.white38,
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
                                          ? Colors.white
                                          : Colors.white24,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        app.modelDisplayName(m),
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
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
                  const Divider(
                    color: Colors.white12,
                    indent: 20,
                    endIndent: 20,
                  ),
                  _menuItem(
                    Icons.inventory_2_outlined,
                    app.t('manageModels'),
                    onManage,
                  ),
                  _menuItem(Icons.edit_outlined, app.t('newChat'), onNewChat),
                  _menuItem(null, app.t('createImage'), onCreateImage),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem(IconData? icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 14),
            ] else
              const SizedBox(width: 34),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 18),
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
  bool _listening = false;
  bool _manualStop = false;
  String _recognized = '';
  Timer? _autoSendTimer;
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

  Future<void> _init() async {
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
    if (_available && !_muted) _listen();
    if (mounted) setState(() {});
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
    if (stoppedNaturally &&
        _recognized.trim().isNotEmpty &&
        context.read<AppState>().micAutoSend) {
      _scheduleAutoSend();
    }
  }

  // speech_to_text reports raw, platform-dependent decibel-ish values (the
  // exact range differs between Android and iOS) rather than a normalized
  // level. Clamp to a generous range, map to 0..1, then smooth so the
  // sphere reacts to the trend of the volume rather than every noisy tick.
  void _onSoundLevel(double level) {
    final normalized = ((level + 2) / 12).clamp(0.0, 1.0);
    _soundLevel.value += (normalized - _soundLevel.value) * 0.35;
  }

  // Recognition already waited out `pauseFor` of silence before stopping;
  // this extra beat just lets the user see the final transcript before we navigate away.
  void _scheduleAutoSend() {
    _autoSendTimer?.cancel();
    _autoSendTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.pop(context, (_recognized, true));
    });
  }

  void _listen() {
    if (!mounted) return;
    final app = context.read<AppState>();
    _autoSendTimer?.cancel();
    _speech
        .listen(
          onResult: (r) {
            if (mounted) setState(() => _recognized = r.recognizedWords);
          },
          onSoundLevelChange: _onSoundLevel,
          listenOptions: stt.SpeechListenOptions(
            listenMode: stt.ListenMode.dictation,
            pauseFor: Duration(seconds: app.micPauseSeconds),
            localeId: app.lang == 'ru' ? 'ru_RU' : 'en_US',
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
      if (_listenRetries >= _maxListenRetries) return;
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
    _listenWatchdog?.cancel();
    setState(() => _muted = !_muted);
    if (_muted) {
      _manualStop = true;
      _speech.stop();
    } else {
      _listenRetries = 0;
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
                        if (_speech.isListening) {
                          _speech.changePauseFor(Duration(seconds: s));
                        }
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
                      onTap: () => Navigator.pop(context, (_recognized, false)),
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
              Container(
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
                    const Icon(Icons.mic, color: Color(0xFF7C83FD)),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _recognized.isEmpty
                            ? (_muted
                                  ? app.t('muted')
                                  : (_listening
                                        ? app.t('listening')
                                        : app.t('preparingMic')))
                            : _recognized,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (app.micAutoSend)
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 30),
                  child: Text(
                    app.t('speakNaturally'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 16),
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
  const ConversationsSheet({super.key});
  @override
  State<ConversationsSheet> createState() => _ConversationsSheetState();
}

class _ConversationsSheetState extends State<ConversationsSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
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

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: _bg(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
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
        ),
      ),
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
      child: Container(
        height: 150,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _card(context).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
        ),
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
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4FACFE), Color(0xFF2F6BFF)],
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
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: _card(context).withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(20),
      ),
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
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: kAccentGradientColors,
                    ),
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

  Widget _chatTile(Conversation c, AppState app) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      child: Material(
        color: _card(context).withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
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
          trailing: PopupMenuButton<String>(
            color: _card(context),
            icon: Icon(Icons.more_vert, color: _sub(context)),
            onSelected: (v) {
              if (v == 'pin') app.togglePin(c);
              if (v == 'delete') app.deleteChat(c);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'pin',
                child: Text(
                  c.pinned ? app.t('unpin') : app.t('pin'),
                  style: TextStyle(color: _txt(context)),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  app.t('delete'),
                  style: TextStyle(color: _txt(context)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchField(AppState app) {
    return TextField(
      style: TextStyle(color: _txt(context)),
      onChanged: (v) => setState(() => _query = v),
      decoration: InputDecoration(
        hintText: app.t('searchChats'),
        hintStyle: TextStyle(color: _sub(context)),
        prefixIcon: Icon(Icons.search, color: _sub(context)),
        filled: true,
        fillColor: _card(context).withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
      ),
    );
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

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: _bg(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
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
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const Spacer(),
                  Text(
                    app.t('settings'),
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
                    app.t('settingsDesc'),
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionLabel(app.t('sectionApp')),
                  _group([
                    _nav(
                      context,
                      Icons.inventory_2_outlined,
                      app.t('manageModelsItem'),
                      trailing: _badge('${app.models.length}'),
                      onTap: () => _openManageModels(context),
                    ),
                    _nav(
                      context,
                      Icons.download_for_offline_outlined,
                      app.t('localModelsItem'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LocalModelsScreen(),
                        ),
                      ),
                    ),
                    _nav(
                      context,
                      Icons.language,
                      app.t('language'),
                      trailing: Text(
                        app.lang == 'ru' ? app.t('russian') : app.t('english'),
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openLanguage(context),
                    ),
                    _nav(
                      context,
                      Icons.dns_outlined,
                      app.t('serverAddress'),
                      onTap: () => _openServerSettings(context),
                    ),
                    _nav(
                      context,
                      Icons.person_outline,
                      app.t('personalization'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PersonalizationScreen(),
                        ),
                      ),
                    ),
                    _nav(
                      context,
                      Icons.psychology_outlined,
                      app.t('memory'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const PersonalizationScreen(initialTab: 1),
                        ),
                      ),
                    ),
                    _nav(
                      context,
                      Icons.text_fields,
                      app.t('fontSize'),
                      trailing: Text(
                        '${app.fontSize.toStringAsFixed(1)}x',
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openFontSizeDialog(context),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  _sectionLabel(app.t('sectionTheme')),
                  _group([
                    _nav(
                      context,
                      Icons.palette_outlined,
                      app.t('themeMode'),
                      trailing: Text(
                        app.themeMode == AppThemeMode.system
                            ? app.t('themeSystem')
                            : app.themeMode == AppThemeMode.light
                            ? app.t('themeLight')
                            : app.t('themeDark'),
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openThemeDialog(context),
                    ),
                    _switch(
                      context,
                      Icons.vibration,
                      app.t('haptics'),
                      app.haptics,
                      (v) => app.setHaptics(v),
                    ),
                    _switch(
                      context,
                      Icons.keyboard_alt_outlined,
                      app.t('showKeyboard'),
                      app.showKeyboardOnLaunch,
                      (v) => app.setShowKeyboard(v),
                    ),
                    _switch(
                      context,
                      Icons.auto_awesome,
                      app.t('showChips'),
                      app.showPromptChips,
                      (v) => app.setShowChips(v),
                    ),
                    _danger(context, app),
                  ]),
                  const SizedBox(height: 24),
                  _sectionLabel(app.t('sectionAbout')),
                  _group([
                    _updateRow(context, app),
                    _nav(
                      context,
                      Icons.info_outline,
                      app.t('aboutVersion'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AboutVersionScreen(),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String s) => Builder(
    builder: (context) => Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        s,
        style: TextStyle(
          color: _sub(context),
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  Widget _group(List<Widget> children) => Builder(
    builder: (context) => Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
      child: Material(
        color: _card(context).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        child: Column(children: children),
      ),
    ),
  );

  Widget _badge(String s) => Container(
    padding: const EdgeInsets.all(8),
    decoration: const BoxDecoration(
      color: Colors.white24,
      shape: BoxShape.circle,
    ),
    child: Text(s, style: const TextStyle(color: Colors.white)),
  );

  Widget _updateRow(BuildContext context, AppState app) {
    String title = app.t('checkForUpdates');
    Widget? trailing;
    VoidCallback? onTap;

    if (app.updateDownloadProgress != null) {
      final p = app.updateDownloadProgress!;
      title = app.t('downloadingUpdate');
      trailing = Text(p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : '…',
          style: TextStyle(color: _sub(context)));
    } else if (app.checkingForUpdate) {
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (app.updateAvailableVersion != null) {
      title = '${app.t('updateAvailable')} ${app.updateAvailableVersion}';
      trailing = const Icon(Icons.download, color: Colors.green);
      onTap = () => app.downloadAndInstallUpdate();
    } else {
      onTap = () async {
        await app.checkForUpdates();
        if (!context.mounted) return;
        final version = app.updateAvailableVersion;
        final error = app.updateCheckError;
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(app.t('checkForUpdates')),
            content: Text(
              error ??
                  (version != null
                      ? '${app.t('updateAvailable')} $version'
                      : app.t('upToDate')),
            ),
            actions: version != null && error == null
                ? [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(app.t('later')),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        app.downloadAndInstallUpdate();
                      },
                      child: Text(app.t('downloadUpdateNow')),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(app.t('gotIt')),
                    ),
                  ],
          ),
        );
      };
    }

    return _nav(context, Icons.system_update_outlined, title,
        trailing: trailing, onTap: onTap);
  }

  Widget _nav(
    BuildContext c,
    IconData icon,
    String label, {
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: _txt(c)),
      title: Text(label, style: TextStyle(color: _txt(c), fontSize: 18)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) trailing,
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: _sub(c)),
        ],
      ),
    );
  }

  Widget _switch(
    BuildContext c,
    IconData icon,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      value: value,
      activeThumbColor: Colors.white,
      activeTrackColor: const Color(0xFF34C759),
      onChanged: (v) {
        c.read<AppState>().buzz();
        onChanged(v);
      },
      secondary: Icon(icon, color: _txt(c)),
      title: Text(label, style: TextStyle(color: _txt(c), fontSize: 18)),
    );
  }

  Widget _danger(BuildContext c, AppState app) {
    return ListTile(
      onTap: () => showDialog(
        context: c,
        builder: (_) => AlertDialog(
          backgroundColor: _card(c),
          title: Text(app.t('deleteHistory'), style: TextStyle(color: _txt(c))),
          content: Text(app.t('cantUndo'), style: TextStyle(color: _sub(c))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(app.t('cancel')),
            ),
            TextButton(
              onPressed: () {
                app.deleteAll();
                Navigator.pop(c);
              },
              child: Text(
                app.t('delete'),
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
      leading: const Icon(Icons.delete_outline, color: Colors.red),
      title: Text(
        app.t('deleteHistory'),
        style: const TextStyle(color: Colors.red, fontSize: 18),
      ),
    );
  }

  void _openFontSizeDialog(BuildContext context) {
    final app = context.read<AppState>();
    double tempSize = app.fontSize;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card(context),
        title: Text(app.t('fontSize'), style: TextStyle(color: _txt(context))),
        content: StatefulBuilder(
          builder: (ctx, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${tempSize.toStringAsFixed(1)}x',
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackShape: const GradientSliderTrackShape(),
                  thumbColor: const Color(0xFF2F6BFF),
                ),
                child: Slider(
                  value: tempSize,
                  min: 0.7,
                  max: 1.5,
                  divisions: 16,
                  label: '${tempSize.toStringAsFixed(1)}x',
                  onChanged: (v) => setDialogState(() => tempSize = v),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'A',
                    style: TextStyle(color: _sub(context), fontSize: 12),
                  ),
                  Text(
                    'A',
                    style: TextStyle(color: _sub(context), fontSize: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              app.setFontSize(tempSize);
              Navigator.pop(context);
            },
            child: Text(app.t('save')),
          ),
        ],
      ),
    );
  }

  void _openThemeDialog(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card(context),
        title: Text(app.t('themeMode'), style: TextStyle(color: _txt(context))),
        content: RadioGroup<AppThemeMode>(
          groupValue: app.themeMode,
          onChanged: (v) {
            if (v != null) {
              app.setThemeMode(v);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in [
                (AppThemeMode.system, app.t('themeSystem')),
                (AppThemeMode.light, app.t('themeLight')),
                (AppThemeMode.dark, app.t('themeDark')),
              ])
                RadioListTile<AppThemeMode>(
                  value: entry.$1,
                  activeColor: const Color(0xFF2F8DFF),
                  title: Text(entry.$2, style: TextStyle(color: _txt(context))),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openLanguage(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('languageDialogTitle'),
          style: TextStyle(color: _txt(context)),
        ),
        content: RadioGroup<String>(
          groupValue: app.lang,
          onChanged: (v) {
            if (v != null) {
              app.setLang(v);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in [
                ['ru', app.t('russian')],
                ['en', app.t('english')],
              ])
                RadioListTile<String>(
                  value: l[0],
                  activeColor: const Color(0xFF2F8DFF),
                  title: Text(l[1], style: TextStyle(color: _txt(context))),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openServerSettings(BuildContext context) {
    final app = context.read<AppState>();
    final urlCtrl = TextEditingController(text: app.serverUrl);
    final keyCtrl = TextEditingController(text: app.apiKey);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('serverDialogTitle'),
          style: TextStyle(color: _txt(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              style: TextStyle(color: _txt(context)),
              decoration: InputDecoration(
                labelText: app.t('serverUrlLabel'),
                hintText: app.t('serverUrlHint'),
                hintStyle: TextStyle(color: _sub(context), fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyCtrl,
              style: TextStyle(color: _txt(context)),
              obscureText: true,
              decoration: InputDecoration(labelText: app.t('apiKeyOptional')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              app.setServer(urlCtrl.text.trim(), keyCtrl.text.trim());
              Navigator.pop(context);
            },
            child: Text(app.t('save')),
          ),
        ],
      ),
    );
  }

  void _openManageModels(BuildContext context) {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: _card(context),
      isScrollControlled: true,
      builder: (_) => Consumer<AppState>(
        builder: (ctx, app, child) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    app.t('manageModelsItem'),
                    style: TextStyle(
                      color: _txt(ctx),
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {
                      app.fetchModels();
                    },
                    icon: Icon(Icons.refresh, color: _txt(ctx)),
                    tooltip: app.t('refreshModels'),
                  ),
                ],
              ),
              if (app.loadingModels)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(),
                ),
              ...app.models.map(
                (m) => ListTile(
                  leading: Icon(
                    app.isLocalModel(m)
                        ? Icons.download_for_offline_outlined
                        : Icons.inventory_2_outlined,
                    color: _txt(ctx),
                  ),
                  title: Text(
                    app.modelDisplayName(m),
                    style: TextStyle(color: _txt(ctx)),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () {
                      final spec = app.localSpecFor(m);
                      if (spec != null) {
                        app.deleteLocalModel(spec);
                      } else {
                        app.removeModel(m);
                      }
                    },
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      style: TextStyle(color: _txt(ctx)),
                      decoration: InputDecoration(
                        hintText: app.t('addModelHint'),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.add, color: _txt(ctx)),
                    onPressed: () {
                      app.addModel(ctrl.text);
                      ctrl.clear();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/* ============================ ИСТОРИЯ ИЗМЕНЕНИЙ (ЭКРАН) ============================ */

class AboutVersionScreen extends StatelessWidget {
  const AboutVersionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: _bg(context),
      appBar: AppBar(
        backgroundColor: _bg(context),
        elevation: 0,
        foregroundColor: _txt(context),
        title: Text(app.t('aboutVersion'),
            style:
                TextStyle(color: _txt(context), fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final entry in kChangelog)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _card(context).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.version,
                      style: TextStyle(
                          color: _txt(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  for (final change in entry.changes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ',
                              style: TextStyle(color: _sub(context))),
                          Expanded(
                            child: Text(change,
                                style: TextStyle(
                                    color: _sub(context),
                                    fontSize: 14,
                                    height: 1.4)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/* ============================ ЛОКАЛЬНЫЕ МОДЕЛИ (ЭКРАН) ============================ */

class LocalModelsScreen extends StatelessWidget {
  const LocalModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: _bg(context),
      appBar: AppBar(
        backgroundColor: _bg(context),
        elevation: 0,
        foregroundColor: _txt(context),
        title: Text(
          app.t('localModelsTitle'),
          style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            app.t('localModelsDesc'),
            style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 20),
          for (final (i, tier) in LocalModelTier.values.indexed) ...[
            if (kLocalModels.any((m) => m.tier == tier)) ...[
              _tierHeader(context, app, tier, showDivider: i > 0),
              for (final spec in kLocalModels.where((m) => m.tier == tier))
                _modelCard(context, app, spec),
            ],
          ],
        ],
      ),
    );
  }

  Widget _tierHeader(
    BuildContext context,
    AppState app,
    LocalModelTier tier, {
    required bool showDivider,
  }) {
    final (titleKey, descKey) = switch (tier) {
      LocalModelTier.light => ('tierLight', 'tierLightDesc'),
      LocalModelTier.mid => ('tierMid', 'tierMidDesc'),
      LocalModelTier.high => ('tierHigh', 'tierHighDesc'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showDivider) ...[
            Divider(color: _sub(context).withValues(alpha: 0.25), height: 17),
          ],
          Text(
            app.t(titleKey),
            style: TextStyle(
              color: _txt(context),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            app.t(descKey),
            style: TextStyle(color: _sub(context), fontSize: 12),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _modelCard(BuildContext context, AppState app, LocalModelSpec spec) {
    final downloaded = app.downloadedLocalModelIds.contains(spec.id);
    final progress = app.localDownloadProgress[spec.id];
    final isSelected = app.selectedModel == spec.modelKey;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _card(context).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.memory, color: _txt(context), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _txt(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                if (progress != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      minHeight: 4,
                    ),
                  )
                else
                  Text(
                    formatBytes(spec.sizeBytes),
                    style: TextStyle(color: _sub(context), fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (progress != null) ...[
            Text(
              '${(progress * 100).toStringAsFixed(0)}%',
              style: TextStyle(color: _sub(context), fontSize: 12),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: app.t('cancelDownload'),
              onPressed: () => app.cancelLocalModelDownload(spec.id),
              icon: const Icon(Icons.close, size: 18),
            ),
          ] else if (!downloaded) ...[
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: app.t('downloadModel'),
              onPressed: () => app.downloadLocalModel(spec),
              icon: const Icon(Icons.download),
            ),
          ] else ...[
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: isSelected ? app.t('modelInUse') : app.t('useModel'),
              onPressed: isSelected
                  ? null
                  : () {
                      app.selectModel(spec.modelKey);
                      Navigator.pop(context);
                    },
              icon: Icon(
                isSelected ? Icons.check_circle : Icons.play_arrow,
                color: isSelected ? Colors.green : null,
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: app.t('deleteModel'),
              onPressed: () => _confirmDelete(context, app, spec),
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 20,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, AppState app, LocalModelSpec spec) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(app.t('deleteLocalModelTitle')),
        content: Text(app.t('deleteLocalModelBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              app.deleteLocalModel(spec);
              Navigator.pop(ctx);
            },
            child: Text(
              app.t('deleteModel'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}

/* ============================ ЭКРАН ПЕРСОНАЛИЗАЦИИ ============================ */

class PersonalizationScreen extends StatefulWidget {
  final Conversation? conversation;
  final int initialTab;
  const PersonalizationScreen({
    super.key,
    this.conversation,
    this.initialTab = 0,
  });
  @override
  State<PersonalizationScreen> createState() => _PersonalizationScreenState();
}

class _PersonalizationScreenState extends State<PersonalizationScreen> {
  late Personalization p;
  late int _tab;
  late final TextEditingController _custom;
  late final TextEditingController _memory;
  late final TextEditingController _name;
  late final TextEditingController _pronouns;
  late final TextEditingController _profession;
  late final TextEditingController _interests;
  late final TextEditingController _goals;
  late final TextEditingController _location;
  late final TextEditingController _avoid;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    p = (widget.conversation?.persona ?? app.persona).clone();
    _tab = widget.initialTab;
    _custom = TextEditingController(text: p.customPrompt);
    _memory = TextEditingController(text: p.memoryNote);
    _name = TextEditingController(text: p.name);
    _pronouns = TextEditingController(text: p.pronouns);
    _profession = TextEditingController(text: p.profession);
    _interests = TextEditingController(text: p.interests);
    _goals = TextEditingController(text: p.goals);
    _location = TextEditingController(text: p.location);
    _avoid = TextEditingController(text: p.avoidTopics);
  }

  @override
  void dispose() {
    _custom.dispose();
    _memory.dispose();
    _name.dispose();
    _pronouns.dispose();
    _profession.dispose();
    _interests.dispose();
    _goals.dispose();
    _location.dispose();
    _avoid.dispose();
    super.dispose();
  }

  void _save() {
    p.customPrompt = _custom.text;
    p.memoryNote = _memory.text;
    p.name = _name.text;
    p.pronouns = _pronouns.text;
    p.profession = _profession.text;
    p.interests = _interests.text;
    p.goals = _goals.text;
    p.location = _location.text;
    p.avoidTopics = _avoid.text;
    final app = context.read<AppState>();
    if (widget.conversation != null) {
      app.saveConversationPersona(widget.conversation!, p);
    } else {
      app.savePersona(p);
    }
    Navigator.pop(context);
  }

  String tr(String k) => context.read<AppState>().t(k);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: _bg(context),
      appBar: AppBar(
        backgroundColor: _bg(context),
        elevation: 0,
        foregroundColor: _txt(context),
        title: Text(
          widget.conversation != null
              ? app.t('chatPers')
              : app.t('pers'),
          style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              app.t('done'),
              style: const TextStyle(
                color: Color(0xFF2F8DFF),
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _topTab(
                  icon: Icons.person_outline,
                  label: app.t('tabPersonality'),
                  selected: _tab == 0,
                  onTap: () => setState(() => _tab = 0),
                ),
              ),
              Expanded(
                child: _topTab(
                  icon: Icons.psychology_outlined,
                  label: app.t('tabMemory'),
                  selected: _tab == 1,
                  onTap: () => setState(() => _tab = 1),
                ),
              ),
            ],
          ),
          Container(height: 1, color: _sub(context).withValues(alpha: 0.15)),
          Expanded(
            child: _tab == 0 ? _personalityTab(app) : _memoryTab(app),
          ),
        ],
      ),
    );
  }

  Widget _topTab({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? const Color(0xFF2F8DFF) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: selected ? const Color(0xFF2F8DFF) : _sub(context),
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: selected ? _txt(context) : _sub(context),
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _personalityTab(AppState app) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          app.t('persDesc'),
          style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 20),

          _section(app.t('persPersona')),
          _card2(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(app.t('persPreset')),
                _chipsSelect(
                  options: const [
                    'preset_friend',
                    'preset_mentor',
                    'preset_expert',
                    'preset_creative',
                    'preset_custom',
                  ],
                  value: p.preset,
                  onSelect: (v) => setState(() {
                    if (v == 'preset_custom') {
                      p.preset = v;
                    } else {
                      p.applyPreset(v);
                    }
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card2(
            child: Column(
              children: [
                _slider(
                  app.t('sl_formality'),
                  p.formality,
                  (v) => setState(() {
                    p.formality = v;
                    p.preset = 'preset_custom';
                  }),
                ),
                _slider(
                  app.t('sl_empathy'),
                  p.empathy,
                  (v) => setState(() {
                    p.empathy = v;
                    p.preset = 'preset_custom';
                  }),
                ),
                _slider(
                  app.t('sl_verbosity'),
                  p.verbosity,
                  (v) => setState(() {
                    p.verbosity = v;
                    p.preset = 'preset_custom';
                  }),
                ),
                _slider(
                  app.t('sl_humor'),
                  p.humor,
                  (v) => setState(() {
                    p.humor = v;
                    p.preset = 'preset_custom';
                  }),
                ),
                _slider(
                  app.t('sl_creativity'),
                  p.creativity,
                  (v) => setState(() {
                    p.creativity = v;
                    p.preset = 'preset_custom';
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card2(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(app.t('emojiUsage')),
                _chipsSelect(
                  options: const [
                    'emoji_never',
                    'emoji_sometimes',
                    'emoji_always',
                  ],
                  value: p.emoji,
                  onSelect: (v) => setState(() => p.emoji = v),
                ),
                const SizedBox(height: 12),
                _label(app.t('answerFormat')),
                _chipsSelect(
                  options: const ['fmt_plain', 'fmt_lists', 'fmt_tables'],
                  value: p.answerFormat,
                  onSelect: (v) => setState(() => p.answerFormat = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          _section(app.t('persBehavior')),
          _card2(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(app.t('defaultLength')),
                _chipsSelect(
                  options: const ['len_short', 'len_normal', 'len_long'],
                  value: p.defaultLength,
                  onSelect: (v) => setState(() => p.defaultLength = v),
                ),
                const SizedBox(height: 12),
                _label(app.t('proactivity')),
                _chipsSelect(
                  options: const ['pro_answer', 'pro_clarify', 'pro_suggest'],
                  value: p.proactivity,
                  onSelect: (v) => setState(() => p.proactivity = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card2(
            child: Column(
              children: [
                _switchRow(
                  app.t('useMarkdown'),
                  p.useMarkdown,
                  (v) => setState(() => p.useMarkdown = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          _section(app.t('persAdvanced')),
          _card2(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(app.t('reasoning')),
                _chipsSelect(
                  options: const ['rs_fast', 'rs_step'],
                  value: p.reasoning,
                  onSelect: (v) => setState(() => p.reasoning = v),
                ),
                const SizedBox(height: 12),
                _label(app.t('toneTitle')),
                _chipsSelect(
                  options: const [
                    'tone_neutral',
                    'tone_sarcastic',
                    'tone_melancholic',
                    'tone_excited',
                  ],
                  value: p.tone,
                  onSelect: (v) => setState(() => p.tone = v),
                ),
                const SizedBox(height: 12),
                _label(app.t('customPrompt')),
                _field(_custom, app.t('customPromptHint'), maxLines: 4),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      );
  }

  Widget _memoryTab(AppState app) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _section(app.t('memorySection')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _switchRow(
                app.t('longMemory'),
                p.longMemory,
                (v) => setState(() => p.longMemory = v),
              ),
              const SizedBox(height: 8),
              _field(_memory, app.t('memoryNote'), maxLines: 3),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('persProfile')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_name, app.t('name')),
              _field(_pronouns, app.t('pronouns')),
              _field(_profession, app.t('profession')),
              _field(_interests, app.t('interests')),
              _field(_goals, app.t('goals')),
              _field(_location, app.t('location')),
              const SizedBox(height: 4),
              _switchRow(
                app.t('useMyData'),
                p.useMyData,
                (v) => setState(() => p.useMyData = v),
              ),
              const SizedBox(height: 8),
              _label(app.t('knowledgeLevel')),
              _chipsSelect(
                options: const ['kl_beginner', 'kl_student', 'kl_expert'],
                value: p.knowledgeLevel,
                onSelect: (v) => setState(() => p.knowledgeLevel = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('persSafety')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_avoid, app.t('avoidTopics'), maxLines: 2),
              const SizedBox(height: 8),
              _label(app.t('contentFilter')),
              _chipsSelect(
                options: const ['cf_strict', 'cf_balanced', 'cf_off'],
                value: p.contentFilter,
                onSelect: (v) => setState(() => p.contentFilter = v),
              ),
              const SizedBox(height: 4),
              _switchRow(
                app.t('warnUncertain'),
                p.warnUncertain,
                (v) => setState(() => p.warnUncertain = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _section(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 4),
    child: Text(
      s,
      style: TextStyle(
        color: _txt(context),
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _card2({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _card(context).withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(18),
    ),
    child: child,
  );

  Widget _label(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      s,
      style: TextStyle(
        color: _sub(context),
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: _txt(context), fontSize: 15)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackShape: const GradientSliderTrackShape(),
            thumbColor: const Color(0xFF2F6BFF),
          ),
          child: Slider(value: value, onChanged: onChanged),
        ),
      ],
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: _txt(context), fontSize: 16),
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: Colors.white,
          activeTrackColor: const Color(0xFF34C759),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String hint, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        style: TextStyle(color: _txt(context)),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: _sub(context)),
          filled: true,
          fillColor: _bg(context).withValues(alpha: 0.4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
          ),
        ),
      ),
    );
  }

  Widget _chipsSelect({
    required List<String> options,
    required String value,
    required ValueChanged<String> onSelect,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          ChoiceChip(
            label: Text(tr(o)),
            selected: value == o,
            labelStyle: TextStyle(
              color: value == o ? Colors.white : _txt(context),
              fontWeight: FontWeight.w500,
            ),
            selectedColor: const Color(0xFF2F8DFF),
            backgroundColor: _bg(context).withValues(alpha: 0.4),
            side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
            onSelected: (_) => onSelect(o),
          ),
      ],
    );
  }
}
