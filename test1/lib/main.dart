import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:fllama/fllama.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'local_model_stub.dart' if (dart.library.io) 'local_model_io.dart';

// Kept short now that the animated ImmersiveSplash provides the real
// startup dwell — otherwise boot would be this delay plus the ~1.5s
// animation stacked back to back.
const _minSplashDuration = Duration(milliseconds: 300);

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
    'rename': 'Переименовать',
    'renameChat': 'Переименовать чат',
    'renameChatHint': 'Название чата',
    'msgCopy': 'Копировать',
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
    'themeGray': 'Серая',
    'appStyle': 'Стиль приложения',
    'appStyleDialogTitle': 'Стиль приложения',
    'appStyleStandard': 'Обычный',
    'appStyleGlass': 'Жидкое стекло',
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
        'Управляйте тем, что Mirai запоминает о вас, и сколько контекста диалога видят локальные модели.',
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
    'appName': 'Mirai',
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
    'rename': 'Rename',
    'renameChat': 'Rename chat',
    'renameChatHint': 'Chat name',
    'msgCopy': 'Copy',
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
        "Control what Mirai remembers about you, and how much conversation context local models can see.",
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
    b.writeln('You are Mirai, a helpful AI assistant.');

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
      'You are Mirai, a helpful assistant. Answer naturally and directly.',
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
}

// RP-mode chats lock in whichever model was selected the first time RP
// turned on for them (Conversation.rpConfig.lockedModel) — once locked, that
// chat keeps using it regardless of whatever AppState.selectedModel is set
// to globally afterwards. Non-RP chats always just follow the global model.
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
    final spec = app.localSpecFor(_effectiveModelFor(app, conv));
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
    final systemPrompt = rpActive
        ? RPMemoryManager.buildSystemPrompt(conv)
        : (spec.tier == LocalModelTier.light
                  ? effectivePersona.buildLocalSystemPrompt()
                  : effectivePersona.buildSystemPrompt()) +
              conv.pinnedContextBlock();
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
    final maxLocalContextSize = spec?.maxLocalContextSize ?? 4096;
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
    try {
      await fllamaChat(_buildRequest(conv, modelPath, messages), (
        response,
        openaiJson,
        done,
      ) {
        if (done && !completer.isCompleted) completer.complete(response);
      });
    } catch (e) {
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
      try {
        final requestId = await fllamaChat(
          _buildRequest(conv, modelPath, messages),
          (response, openaiJson, done) {
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
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> stopGeneration() async {
    final id = _activeRequestId;
    if (id != null) fllamaCancelInference(id);
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
    final systemPrompt = rpActive
        ? RPMemoryManager.buildSystemPrompt(conv)
        : (conv.persona ?? app.persona).buildSystemPrompt() +
              conv.pinnedContextBlock();
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

  // RP mode forwards RPSamplingConfig/stopSequences as Ollama's `options`;
  // non-RP requests are left exactly as before (server defaults).
  Map<String, dynamic> _buildBody(
    Conversation conv,
    List<ChatMessage> history,
    bool stream,
  ) {
    final body = <String, dynamic>{
      'model': _effectiveModelFor(app, conv),
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
    }
    return body;
  }

  @override
  Future<String> generateResponse(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    try {
      final headers = {'Content-Type': 'application/json'};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final res = await http
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
      return '${app.t('unreachable')} ${app.baseUrl}.\n($e)\n\n${app.t('checkAddress')}';
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

enum AppThemeMode { system, light, dark, gray }

// Visual style of the app's chrome, orthogonal to AppThemeMode: `standard`
// keeps the existing solid surfaces, `liquidGlass` swaps them for
// translucent blurred (iOS 26 "Liquid Glass") surfaces over whatever theme
// is active. See GlassSurface / _isGlass.
enum AppStyle { standard, liquidGlass }

class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  AppState(this.prefs);

  final _uuid = const Uuid();

  String lang = 'ru';
  String t(String key) => _i18n[lang]?[key] ?? _i18n['en']?[key] ?? key;

  AppThemeMode themeMode = AppThemeMode.system;
  AppStyle appStyle = AppStyle.standard;
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

  // Live-streaming generation (RP mode only — see sendMessage/Conversation.
  // rpModeEnabled). isGenerating drives the Stop Generation button; the
  // cancel callback is whatever the active backend (fllama/HTTP) needs to
  // actually interrupt itself.
  bool isGenerating = false;
  void Function()? _cancelGeneration;
  void cancelGeneration() => _cancelGeneration?.call();

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
      case AppThemeMode.gray:
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
    await prefs.setString('appStyle', appStyle.name);
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

    if (conv.rpModeEnabled) {
      return _sendMessageStreaming(conv, text);
    }

    final rawReply = selectedModel.isEmpty
        ? t('noModelsAvailable')
        : await _llmFactory.current.generateResponse(conv, conv.messages);
    final reply = (conv.persona ?? persona).enforceEmojiPolicy(rawReply);

    conv.messages.add(ChatMessage(role: 'assistant', content: reply.trim()));
    conv.updatedAt = DateTime.now();
    _save();
    notifyListeners();
    unawaited(_autoSaveMemoryFromExchange(conv, text, reply.trim()));
    return reply;
  }

  // RP-mode path: the assistant message is added (empty) up front and
  // grown in place as chunks arrive, instead of waiting for the full reply
  // — see Conversation.rpModeEnabled. `history` is a snapshot of the
  // conversation taken before that placeholder is appended, so it isn't
  // sent back to the model as part of its own context.
  Future<String> _sendMessageStreaming(
    Conversation conv,
    String userText,
  ) async {
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
        if (conv.rpModeEnabled && conv.rpConfig != null) {
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
    unawaited(
      _autoSaveMemoryFromExchange(
        conv,
        userText,
        assistantMessage.content.trim(),
      ),
    );
    return assistantMessage.content;
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
    final spec = localSpecFor(selectedModel);
    if (spec == null) return 'NONE';
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return 'NONE';

    final completer = Completer<String>();
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
        if (done && !completer.isCompleted) completer.complete(response);
      },
    );
    return completer.future;
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
      darkTheme: app.themeMode == AppThemeMode.gray
          ? _buildGrayTheme()
          : _buildTheme(true),
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
      home: const ImmersiveSplash(),
    );
  }

  ThemeMode _getThemeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
      case AppThemeMode.gray:
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
      fontFamily: 'Nunito',
    );
  }

  // Neutral charcoal/gray dark palette (iOS-style grouped dark colors)
  // instead of the default dark theme's blue-tinted background.
  ThemeData _buildGrayTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF7C8CF8),
        surface: Color(0xFF1C1C1E),
      ),
      scaffoldBackgroundColor: const Color(0xFF000000),
      fontFamily: 'Nunito',
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
    if (_done) return const ChatScreen();
    return Stack(
      children: [
        const ChatScreen(),
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

bool _isGrayMode(BuildContext c) =>
    c.read<AppState>().themeMode == AppThemeMode.gray;

Color _bg(BuildContext c) {
  if (Theme.of(c).brightness != Brightness.dark) return Colors.white;
  return _isGrayMode(c) ? const Color(0xFF000000) : const Color(0xFF0E0E15);
}

Color _card(BuildContext c) {
  if (Theme.of(c).brightness != Brightness.dark) {
    return const Color(0xFFEDEEF3);
  }
  return _isGrayMode(c) ? const Color(0xFF1C1C1E) : const Color(0xFF1C1C26);
}
Color _txt(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white : Colors.black;
Color _sub(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF8A8A95)
    : const Color(0xFF6B6B72);

bool _isGlass(BuildContext c) =>
    c.read<AppState>().appStyle == AppStyle.liquidGlass;

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

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(app.t('fileAttached'))));
        }
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
      // Full-width left drawer holds the chat list — opened by an edge swipe
      // (the old top-bar chats button is gone). Drawer keeps the OS status
      // bar visible (not immersive); its content uses its own SafeArea.
      drawerEdgeDragWidth: 56,
      drawer: Drawer(
        width: MediaQuery.of(context).size.width,
        backgroundColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: const ConversationsSheet(embedded: true),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: Column(
            children: [
              _topBar(app),
              Expanded(
                child: hasMessages
                    ? _messageList(conv, app)
                    : _emptyState(app),
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
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                app.buzz();
                if (lockedModel != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(app.t('rpModelLockedToast')),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  return;
                }
                _openModelMenu();
              },
              child: _modelBubbleWrap(
                child: Opacity(
                  opacity: lockedModel != null ? 0.6 : 1,
                  child: Row(
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
                            app.modelDisplayName(
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
      color: active ? const Color(0xFF2F6BFF) : _txt(context),
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
                    ? const Color(0xFF2F6BFF)
                    : _sub(context).withValues(alpha: 0.3),
                width: active ? 1.5 : 1,
              ),
              color: active
                  ? const Color(0xFF2F6BFF).withValues(alpha: 0.18)
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

  Widget _messageList(Conversation conv, AppState app) {
    // In RP mode the assistant message is already a real (possibly still
    // empty) entry in conv.messages from the moment generation starts (see
    // AppState._sendMessageStreaming), so the synthetic placeholder below
    // would otherwise show a second "thinking" bubble alongside it.
    final showSyntheticPlaceholder = _sending && !conv.rpModeEnabled;
    if (app.isGenerating && conv.rpModeEnabled) {
      // Keep the growing reply in view as it streams in, the same way
      // _send() already does once for the non-streaming reply.
      _scrollDown();
    }
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
        return _bubble(m, thinking: isStreamingPlaceholder);
      },
    );
  }

  Widget _bubble(ChatMessage m, {bool thinking = false}) {
    final isUser = m.role == 'user';
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
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: kAccentGradientColors,
              ),
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
                    const Icon(
                      Icons.attach_file,
                      size: 14,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        a.split('/').last,
                        style: const TextStyle(
                          color: Colors.white70,
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
          else if (m.content.isNotEmpty)
            Text(
              m.content,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.4,
              ),
            ),
        ],
      ),
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: thinking
          ? bubble
          : GestureDetector(
              onLongPressStart: (d) => _showMessageActions(m, d.globalPosition),
              child: bubble,
            ),
    );
  }

  void _showMessageActions(ChatMessage m, Offset globalPosition) async {
    final app = context.read<AppState>();
    final conv = app.current;
    final isPinned = conv != null && conv.pinnedMessageIds.contains(m.id);
    final selected = await showMenu<String>(
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(toast), duration: const Duration(seconds: 2)),
      );
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
        builder: (dialogContext, setDialogState) => AlertDialog(
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
                  selectedColor: const Color(0xFF2F8DFF),
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
                    color: picked ? const Color(0xFF2F8DFF) : Colors.black38,
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
              color: selected ? const Color(0xFF2F8DFF) : _sub(context),
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
      height: 16,
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
                  offset: Offset(0, -6 * lift),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.6 + 0.4 * lift),
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

  Widget _continueCard(Conversation c, AppState app) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF2F6BFF).withValues(alpha: 0.28),
            const Color(0xFF15151E).withValues(alpha: 0.05),
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
    );
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
      trailing: PopupMenuButton<String>(
        color: _isGlass(context)
            ? _card(context).withValues(alpha: 0.85)
            : _card(context),
        icon: Icon(Icons.more_vert, color: _sub(context)),
        onSelected: (v) {
          if (v == 'rename') _promptRename(c, app);
          if (v == 'pin') app.togglePin(c);
          if (v == 'delete') app.deleteChat(c);
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'rename',
            child: Text(
              app.t('rename'),
              style: TextStyle(color: _txt(context)),
            ),
          ),
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
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
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
    );
  }

  // Rename dialog for a chat. Pre-fills the current title; saving an empty
  // title is a no-op (keeps the old one).
  void _promptRename(Conversation c, AppState app) {
    final ctrl = TextEditingController(text: c.title);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _isGlass(context)
            ? _card(context).withValues(alpha: 0.9)
            : _card(context),
        title: Text(app.t('renameChat'), style: TextStyle(color: _txt(context))),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: InputDecoration(
            hintText: app.t('renameChatHint'),
            hintStyle: TextStyle(color: _sub(context)),
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

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => _sheetSurface(
        context,
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
                    app.t('settings'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
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
                    // The separate "Personalization" entry that used to open
                    // straight to the (now-hidden) "Личность" tab is removed
                    // for now — "Memory" below is the only remaining
                    // PersonalizationScreen entry point from Settings.
                    _nav(
                      context,
                      Icons.psychology_outlined,
                      app.t('memory'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const PersonalizationScreen(initialTab: 0),
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
                        switch (app.themeMode) {
                          AppThemeMode.system => app.t('themeSystem'),
                          AppThemeMode.light => app.t('themeLight'),
                          AppThemeMode.dark => app.t('themeDark'),
                          AppThemeMode.gray => app.t('themeGray'),
                        },
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openThemeDialog(context),
                    ),
                    _nav(
                      context,
                      Icons.tune,
                      app.t('appStyle'),
                      trailing: Text(
                        switch (app.appStyle) {
                          AppStyle.standard => app.t('appStyleStandard'),
                          AppStyle.liquidGlass => app.t('appStyleGlass'),
                        },
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openAppStyleDialog(context),
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
                  const SizedBox(height: 20),
                  Center(child: _versionFootnote(context)),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionFootnote(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox.shrink();
        return Text(
          'Mirai v${info.version} (${info.buildNumber})',
          style: TextStyle(color: _sub(context), fontSize: 12),
        );
      },
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
    builder: (context) => _isGlass(context)
        ? GlassSurface(
            borderRadius: BorderRadius.circular(20),
            child: Material(
              type: MaterialType.transparency,
              child: Column(children: children),
            ),
          )
        : Container(
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
      trailing = Text(
        p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : '…',
        style: TextStyle(color: _sub(context)),
      );
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

    return _nav(
      context,
      Icons.system_update_outlined,
      title,
      trailing: trailing,
      onTap: onTap,
    );
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
    void handle(bool v) {
      c.read<AppState>().buzz();
      onChanged(v);
    }

    return ListTile(
      onTap: () => handle(!value),
      leading: Icon(icon, color: _txt(c)),
      title: Text(label, style: TextStyle(color: _txt(c), fontSize: 18)),
      trailing: _iosSwitch(c, value, handle),
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
                (AppThemeMode.gray, app.t('themeGray')),
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

  void _openAppStyleDialog(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('appStyleDialogTitle'),
          style: TextStyle(color: _txt(context)),
        ),
        content: RadioGroup<AppStyle>(
          groupValue: app.appStyle,
          onChanged: (v) {
            if (v != null) {
              app.setAppStyle(v);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in [
                (AppStyle.standard, app.t('appStyleStandard')),
                (AppStyle.liquidGlass, app.t('appStyleGlass')),
              ])
                RadioListTile<AppStyle>(
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
        title: Text(
          app.t('aboutVersion'),
          style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
        ),
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
                  Text(
                    entry.version,
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final change in entry.changes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ', style: TextStyle(color: _sub(context))),
                          Expanded(
                            child: Text(
                              change,
                              style: TextStyle(
                                color: _sub(context),
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
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
              _tierHeader(
                context,
                app,
                tier,
                showDivider: LocalModelTier.values
                    .take(i)
                    .any((t) => kLocalModels.any((m) => m.tier == t)),
              ),
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
      LocalModelTier.roleplay => ('tierRoleplay', 'tierRoleplayDesc'),
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
      child: _glassCard(
        context,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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

  // Third "Roleplay" tab — only relevant/shown for a conversation with
  // rpModeEnabled, mirrors the same clone-while-editing pattern as `p`.
  late RPSessionConfig rp;
  late final TextEditingController _rpUserName;
  late final TextEditingController _rpUserDesc;
  late final TextEditingController _rpAiName;
  late final TextEditingController _rpSystemPrompt;
  late final TextEditingController _rpScenario;
  late final TextEditingController _rpStopSeq;

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

    rp = (widget.conversation?.rpConfig ?? RPSessionConfig()).clone();
    _rpUserName = TextEditingController(text: rp.userCharacterName);
    _rpUserDesc = TextEditingController(text: rp.userCharacterDescription);
    _rpAiName = TextEditingController(text: rp.aiCharacterName);
    _rpSystemPrompt = TextEditingController(text: rp.systemPrompt);
    _rpScenario = TextEditingController(text: rp.scenario);
    _rpStopSeq = TextEditingController();
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
    _rpUserName.dispose();
    _rpUserDesc.dispose();
    _rpAiName.dispose();
    _rpSystemPrompt.dispose();
    _rpScenario.dispose();
    _rpStopSeq.dispose();
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
    if (widget.conversation != null) {
      rp.userCharacterName = _rpUserName.text;
      rp.userCharacterDescription = _rpUserDesc.text;
      rp.aiCharacterName = _rpAiName.text;
      rp.systemPrompt = _rpSystemPrompt.text;
      rp.scenario = _rpScenario.text;
      app.saveConversationRpConfig(widget.conversation!, rp);
    }
    Navigator.pop(context);
  }

  // The roleplay switch lives inside the tab itself now (no more header
  // button) -- toggling it mutates the live conv.rpModeEnabled/rpConfig
  // right away via AppState.toggleRpMode, so the locked-model snapshot it
  // may just have taken needs copying into our editing clone `rp` too,
  // otherwise _save() would overwrite it with `rp`'s stale defaults.
  void _toggleRp(bool _) {
    final conv = widget.conversation;
    if (conv == null) return;
    final app = context.read<AppState>();
    app.toggleRpMode(conv);
    setState(() {
      rp.lockedModel = conv.rpConfig?.lockedModel;
      rp.contextWindowLimit =
          conv.rpConfig?.contextWindowLimit ?? rp.contextWindowLimit;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(conv.rpModeEnabled ? app.t('rpModeOn') : app.t('rpModeOff')),
        duration: const Duration(seconds: 2),
      ),
    );
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
          widget.conversation != null ? app.t('chatPers') : app.t('pers'),
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
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            // "Личность" (_personalityTab) is temporarily disabled — the
            // user's testing on an up-to-date build still found no
            // observable change in model behavior from these sliders, so
            // it's hidden from the tab row rather than fixed-in-place again.
            // The tab body, its state (`p`), and _save() are left fully
            // intact below; re-enabling is just adding its _topTab back and
            // restoring the `0 => _personalityTab(app)` switch case.
            //
            // "Ролевая игра" is shown next to "Память" whenever this screen
            // is opened from a chat, regardless of whether RP mode is
            // currently on for it -- the on/off switch now lives inside the
            // tab itself (see _toggleRp), so the tab needs to be reachable
            // before RP is turned on, not just after.
            if (widget.conversation != null)
              Row(
                children: [
                  Expanded(
                    child: _topTab(
                      icon: Icons.psychology_outlined,
                      label: app.t('tabMemory'),
                      selected: _tab == 0,
                      onTap: () => setState(() => _tab = 0),
                    ),
                  ),
                  Expanded(
                    child: _topTab(
                      icon: Icons.badge_outlined,
                      label: app.t('tabRoleplay'),
                      selected: _tab == 1,
                      onTap: () => setState(() => _tab = 1),
                    ),
                  ),
                ],
              ),
            if (widget.conversation != null)
              Container(height: 1, color: _sub(context).withValues(alpha: 0.15)),
            Expanded(
              child: switch (_tab) {
                1 when widget.conversation != null => _roleplayTab(app),
                _ => _memoryTab(app),
              },
            ),
          ],
        ),
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

  // Unreferenced while the "Личность" tab is hidden from build() above —
  // kept intact (not deleted) so it can come back with a one-line revert.
  // ignore: unused_element
  Widget _personalityTab(AppState app) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _heroHeader(app.t('tabPersonality'), app.t('persDesc')),

        _section(app.t('persPersona')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('persPreset'), desc: app.t('persPresetDesc')),
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
                desc: app.t('sl_formalityDesc'),
              ),
              _slider(
                app.t('sl_empathy'),
                p.empathy,
                (v) => setState(() {
                  p.empathy = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_empathyDesc'),
              ),
              _slider(
                app.t('sl_verbosity'),
                p.verbosity,
                (v) => setState(() {
                  p.verbosity = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_verbosityDesc'),
              ),
              _slider(
                app.t('sl_humor'),
                p.humor,
                (v) => setState(() {
                  p.humor = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_humorDesc'),
              ),
              _slider(
                app.t('sl_creativity'),
                p.creativity,
                (v) => setState(() {
                  p.creativity = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_creativityDesc'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('emojiUsage'), desc: app.t('emojiUsageDesc')),
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
              _label(app.t('answerFormat'), desc: app.t('answerFormatDesc')),
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
              _label(app.t('defaultLength'), desc: app.t('defaultLengthDesc')),
              _chipsSelect(
                options: const ['len_short', 'len_normal', 'len_long'],
                value: p.defaultLength,
                onSelect: (v) => setState(() => p.defaultLength = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('proactivity'), desc: app.t('proactivityDesc')),
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
              _iconSwitchRow(
                icon: Icons.notes_outlined,
                title: app.t('useMarkdown'),
                desc: app.t('useMarkdownDesc'),
                value: p.useMarkdown,
                onChanged: (v) => setState(() => p.useMarkdown = v),
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
              _label(app.t('reasoning'), desc: app.t('reasoningDesc')),
              _chipsSelect(
                options: const ['rs_fast', 'rs_step'],
                value: p.reasoning,
                onSelect: (v) => setState(() => p.reasoning = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('toneTitle'), desc: app.t('toneTitleDesc')),
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
              _label(app.t('customPrompt'), desc: app.t('customPromptDesc')),
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
        _heroHeader(app.t('tabMemory'), app.t('memoryDesc')),
        _section(app.t('memorySection')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconSwitchRow(
                icon: Icons.psychology_alt_outlined,
                title: app.t('longMemory'),
                desc: app.t('longMemoryDesc'),
                value: p.longMemory,
                onChanged: (v) => setState(() => p.longMemory = v),
              ),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 17),
              _iconSwitchRow(
                icon: Icons.auto_awesome_outlined,
                title: app.t('autoSaveMemories'),
                desc: app.t('autoSaveMemoriesDesc'),
                value: p.autoSaveMemories,
                onChanged: (v) => setState(() => p.autoSaveMemories = v),
              ),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 17),
              _iconSwitchRow(
                icon: Icons.help_outline,
                title: app.t('askBeforeRemembering'),
                desc: app.t('askBeforeRememberingDesc'),
                value: p.askBeforeRemembering,
                onChanged: (v) => setState(() => p.askBeforeRemembering = v),
              ),
              const SizedBox(height: 12),
              _field(_memory, app.t('memoryNote'), maxLines: 3),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 25),
              // RP chats get their own "Лимит контекста" control on the
              // Roleplay tab, which doubles as the local model's real
              // context allocation (see LocalLLMService._buildRequest) --
              // showing both here and there was the exact "two controls for
              // the same thing" confusion this note exists to resolve.
              widget.conversation?.rpModeEnabled == true
                  ? _infoCard(
                      icon: Icons.tune,
                      title: app.t('contextSize'),
                      desc: app.t('contextSizeMovedToRp'),
                    )
                  : _contextSizeControl(app),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 25),
              _destructiveActionRow(
                icon: Icons.delete_outline,
                title: app.t('deleteAllMemories'),
                desc: app.t('deleteAllMemoriesDesc'),
                onTap: () => _confirmDeleteAllMemories(context, app),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('savedMemoriesSection')),
        _card2(
          child: p.savedMemories.isEmpty
              ? Text(
                  app.t('noSavedMemories'),
                  style: TextStyle(color: _sub(context), fontSize: 14),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final mem in p.savedMemories)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                mem,
                                style: TextStyle(
                                  color: _txt(context),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              icon: const Icon(
                                Icons.close,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              onPressed: () =>
                                  setState(() => p.savedMemories.remove(mem)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        if (widget.conversation != null) ...[
          const SizedBox(height: 20),
          _section(app.t('pinnedMessagesSection')),
          _card2(
            child: widget.conversation!.pinnedMessageIds.isEmpty
                ? Text(
                    app.t('noPinnedMessages'),
                    style: TextStyle(color: _sub(context), fontSize: 14),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final msg in widget.conversation!.messages.where(
                        (m) => widget.conversation!.pinnedMessageIds.contains(
                          m.id,
                        ),
                      ))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  msg.content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _txt(context),
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                icon: const Icon(
                                  Icons.push_pin,
                                  size: 18,
                                  color: Color(0xFF2F8DFF),
                                ),
                                onPressed: () => setState(() {
                                  app.toggleMessagePin(
                                    widget.conversation!,
                                    msg,
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
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
              const SizedBox(height: 8),
              _iconSwitchRow(
                icon: Icons.badge_outlined,
                title: app.t('useMyData'),
                desc: app.t('useMyDataDesc'),
                value: p.useMyData,
                onChanged: (v) => setState(() => p.useMyData = v),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              _iconSwitchRow(
                icon: Icons.warning_amber_outlined,
                title: app.t('warnUncertain'),
                desc: app.t('warnUncertainDesc'),
                value: p.warnUncertain,
                onChanged: (v) => setState(() => p.warnUncertain = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _infoCard(
          icon: Icons.lock_outline,
          title: app.t('localDataTitle'),
          desc: app.t('localDataDesc'),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _roleplayTab(AppState app) {
    final conv = widget.conversation;
    final rpOn = conv?.rpModeEnabled ?? false;
    final lockedModel = rp.lockedModel;
    final isLocal = lockedModel != null && app.isLocalModel(lockedModel);
    final localSpec = lockedModel != null ? app.localSpecFor(lockedModel) : null;
    final localMax = localSpec?.maxLocalContextSize ?? 8192;
    final contextOptions = isLocal
        ? const [2048, 4096, 8192].where((v) => v <= localMax).toList()
        : const [4096, 16384, 32768];
    final safeContextOptions = contextOptions.isEmpty
        ? [localMax]
        : contextOptions;
    final displayContextLimit = safeContextOptions.contains(rp.contextWindowLimit)
        ? rp.contextWindowLimit
        : safeContextOptions.last;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _heroHeader(app.t('tabRoleplay'), app.t('rpDesc')),
        _card2(
          child: _iconSwitchRow(
            icon: Icons.auto_awesome_outlined,
            title: app.t('rpMode'),
            desc: app.t('rpEnableDesc'),
            value: rpOn,
            onChanged: conv == null ? (_) {} : _toggleRp,
          ),
        ),
        const SizedBox(height: 20),
        if (lockedModel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: _infoCard(
              icon: Icons.lock_outline,
              title: app.t('rpModelLocked'),
              desc: app.modelDisplayName(lockedModel),
            ),
          ),
        _section(app.t('rpMyCharacter'), app.t('rpMyCharacterDesc')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_rpUserName, app.t('rpUserName')),
              const SizedBox(height: 12),
              _label(
                app.t('rpUserDescription'),
                desc: app.t('rpUserDescriptionDesc'),
              ),
              _field(_rpUserDesc, app.t('rpUserDescriptionHint'), maxLines: 4),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpAiRole'), app.t('rpAiRoleDesc')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_rpAiName, app.t('rpAiName')),
              const SizedBox(height: 12),
              _label(app.t('systemPrompt'), desc: app.t('systemPromptDesc')),
              _field(_rpSystemPrompt, app.t('rpSystemPromptHint'), maxLines: 6),
              const SizedBox(height: 10),
              _infoCard(
                icon: Icons.info_outline,
                title: app.t('rpPlaceholderExampleTitle'),
                desc: app.t('rpPlaceholderExample'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpScenarioSection')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('scenario'), desc: app.t('scenarioDesc')),
              _field(_rpScenario, app.t('rpScenarioHint'), maxLines: 4),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpSampling')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sliderRange(
                app.t('rpTemperature'),
                rp.sampling.temperature,
                0.0,
                isLocal ? 1.5 : 2.0,
                (v) => setState(() => rp.sampling.temperature = v),
                format: (v) => v.toStringAsFixed(2),
                desc: app.t('rpTemperatureDesc'),
              ),
              _sliderRange(
                app.t('rpTopP'),
                rp.sampling.topP,
                0.0,
                1.0,
                (v) => setState(() => rp.sampling.topP = v),
                format: (v) => v.toStringAsFixed(2),
                desc: app.t('rpTopPDesc'),
              ),
              _sliderRange(
                app.t('rpRepetitionPenalty'),
                rp.sampling.repetitionPenalty,
                1.0,
                1.5,
                (v) => setState(() => rp.sampling.repetitionPenalty = v),
                format: (v) => v.toStringAsFixed(2),
                desc: app.t('rpRepetitionPenaltyDesc'),
              ),
              const SizedBox(height: 8),
              _label(app.t('rpMaxTokens'), desc: app.t('rpMaxTokensDesc')),
              _quickChips(
                const [150, 300, 600, 1000],
                rp.sampling.maxResponseTokens,
                (v) => setState(() => rp.sampling.maxResponseTokens = v),
                labelFor: (v) => switch (v) {
                  150 => app.t('rpPresetShort'),
                  300 => app.t('rpPresetMedium'),
                  600 => app.t('rpPresetLong'),
                  1000 => app.t('rpPresetEpic'),
                  _ => '$v',
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpLorebook')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconSwitchRow(
                icon: Icons.notes_outlined,
                title: app.t('rpLorebookEnable'),
                desc: app.t('rpLorebookDesc'),
                value: rp.isLorebookEnabled,
                onChanged: (v) => setState(() => rp.isLorebookEnabled = v),
              ),
              if (rp.isLorebookEnabled) ...[
                Divider(color: _sub(context).withValues(alpha: 0.25), height: 25),
                _lorebookEditor(app),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpStopSequences'), app.t('rpStopSequencesDesc')),
        _card2(child: _stopSequenceInput(app)),
        const SizedBox(height: 20),
        _section(app.t('rpContextWindow'), app.t('rpContextWindowDesc')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _quickChips(
                safeContextOptions,
                displayContextLimit,
                (v) => setState(() => rp.contextWindowLimit = v),
              ),
              if (isLocal && localSpec != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${app.t('contextSizeMaxFor')} ${localSpec.shortName}: $localMax',
                  style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _lorebookEditor(AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in rp.lorebook)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _bg(context).withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: entry.keywords,
                          style: TextStyle(color: _txt(context), fontSize: 13),
                          decoration: InputDecoration(
                            hintText: app.t('rpLorebookKeywords'),
                            hintStyle: TextStyle(
                              color: _sub(context),
                              fontSize: 13,
                            ),
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => entry.keywords = v,
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        icon: const Icon(
                          Icons.close,
                          size: 18,
                          color: Colors.redAccent,
                        ),
                        onPressed: () => setState(() => rp.lorebook.remove(entry)),
                      ),
                    ],
                  ),
                  TextFormField(
                    initialValue: entry.content,
                    maxLines: 3,
                    style: TextStyle(color: _txt(context), fontSize: 13),
                    decoration: InputDecoration(
                      hintText: app.t('rpLorebookContent'),
                      hintStyle: TextStyle(color: _sub(context), fontSize: 13),
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => entry.content = v,
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          onPressed: () => setState(() => rp.lorebook.add(LoreEntry())),
          icon: const Icon(Icons.add, size: 18),
          label: Text(app.t('rpLorebookAddEntry')),
        ),
      ],
    );
  }

  Widget _stopSequenceInput(AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rp.stopSequences.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final seq in rp.stopSequences)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _bg(context).withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _sub(context).withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          seq,
                          style: TextStyle(color: _txt(context), fontSize: 13),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () =>
                              setState(() => rp.stopSequences.remove(seq)),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: _sub(context),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        TextField(
          controller: _rpStopSeq,
          style: TextStyle(color: _txt(context), fontSize: 14),
          decoration: InputDecoration(
            hintText: app.t('rpStopSequenceHint'),
            hintStyle: TextStyle(color: _sub(context), fontSize: 14),
            isDense: true,
            filled: true,
            fillColor: _bg(context).withValues(alpha: 0.3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) {
            final trimmed = v.trim();
            if (trimmed.isEmpty) return;
            setState(() {
              rp.stopSequences.add(trimmed);
              _rpStopSeq.clear();
            });
          },
        ),
      ],
    );
  }

  Widget _sliderRange(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String Function(double)? format,
    String? desc,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: _txt(context), fontSize: 15),
                ),
              ),
              Text(
                format != null ? format(value) : value.toStringAsFixed(2),
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (desc != null) ...[
            const SizedBox(height: 2),
            Text(
              desc,
              style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
            ),
            const SizedBox(height: 4),
          ],
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackShape: const GradientSliderTrackShape(),
              thumbColor: const Color(0xFF2F6BFF),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickChips(
    List<int> values,
    int current,
    ValueChanged<int> onSelect, {
    String Function(int)? labelFor,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          ChoiceChip(
            label: Text(labelFor != null ? labelFor(v) : '$v'),
            selected: current == v,
            labelStyle: TextStyle(
              color: current == v ? Colors.white : _txt(context),
              fontWeight: FontWeight.w500,
            ),
            selectedColor: const Color(0xFF2F8DFF),
            backgroundColor: _bg(context).withValues(alpha: 0.4),
            side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
            onSelected: (_) => onSelect(v),
          ),
      ],
    );
  }

  Widget _heroHeader(String title, String desc) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: _txt(context),
            fontSize: 30,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          desc,
          style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
        ),
      ],
    ),
  );

  Widget _destructiveActionRow({
    required IconData icon,
    required String title,
    required String desc,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.redAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteAllMemories(BuildContext context, AppState app) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('deleteAllMemories'),
          style: TextStyle(color: _txt(context)),
        ),
        content: Text(
          app.t('deleteAllMemoriesConfirm'),
          style: TextStyle(color: _sub(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              setState(() => p.savedMemories.clear());
              Navigator.pop(dialogContext);
            },
            child: Text(
              app.t('delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconSwitchRow({
    required IconData icon,
    required String title,
    required String desc,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _sub(context), size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _iosSwitch(context, value, onChanged),
      ],
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return _glassCard(
      context,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF2F8DFF).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFF2F8DFF), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _txt(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: TextStyle(
                    color: _sub(context),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _contextSizeControl(AppState app) {
    const step = 512;
    const minSize = 512;
    // Adaptive per-model ceiling instead of a flat 4096: an RP chat follows
    // its locked model, everything else follows whatever's selected
    // globally right now — same resolution LocalLLMService uses to build
    // the actual request, so the slider can never promise more context than
    // the model (and the fllama ×4 multiplier) can really deliver.
    final modelKey = widget.conversation != null
        ? _effectiveModelFor(app, widget.conversation!)
        : app.selectedModel;
    final spec = app.localSpecFor(modelKey);
    final maxSize = spec?.maxLocalContextSize ?? 4096;
    final displaySize = p.localContextSize < minSize
        ? minSize
        : (p.localContextSize > maxSize ? maxSize : p.localContextSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('contextSize'),
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$displaySize',
              style: TextStyle(
                color: _sub(context),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _stepBtn(
              Icons.remove,
              displaySize > minSize
                  ? () => setState(() => p.localContextSize = displaySize - step)
                  : null,
            ),
            const SizedBox(width: 10),
            _stepBtn(
              Icons.add,
              displaySize < maxSize
                  ? () => setState(() => p.localContextSize = displaySize + step)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tr('contextSizeDesc'),
          style: TextStyle(color: _sub(context), fontSize: 13, height: 1.3),
        ),
        if (spec != null) ...[
          const SizedBox(height: 4),
          Text(
            '${app.t('contextSizeMaxFor')} ${spec.shortName}: $maxSize',
            style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
          ),
        ],
      ],
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _bg(context).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _sub(context).withValues(alpha: 0.2)),
        ),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null
              ? _sub(context).withValues(alpha: 0.4)
              : _txt(context),
        ),
      ),
    );
  }

  Widget _section(String s, [String? desc]) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s,
          style: TextStyle(
            color: _txt(context),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (desc != null) ...[
          const SizedBox(height: 4),
          Text(
            desc,
            style: TextStyle(color: _sub(context), fontSize: 13, height: 1.3),
          ),
        ],
      ],
    ),
  );

  Widget _card2({required Widget child}) => _isGlass(context)
      ? GlassSurface(
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.all(16),
          child: child,
        )
      : Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _card(context).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(18),
          ),
          child: child,
        );

  Widget _label(String s, {String? desc}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s,
          style: TextStyle(
            color: _sub(context),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (desc != null) ...[
          const SizedBox(height: 2),
          Text(
            desc,
            style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
          ),
        ],
      ],
    ),
  );

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    String? desc,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: _txt(context), fontSize: 15)),
        if (desc != null) ...[
          const SizedBox(height: 2),
          Text(
            desc,
            style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
          ),
        ],
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
