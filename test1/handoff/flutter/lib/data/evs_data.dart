import 'package:flutter/material.dart';

/// Демонстрационные данные из прототипа. В настоящем приложении
/// каждый список приходит из своего источника — здесь они собраны в одном
/// месте, чтобы экраны выглядели ровно так же, как в макете.

class ChatThread {
  const ChatThread(this.id, this.title, this.meta, {this.pinned = false, this.yesterday = false});
  final int id;
  final String title, meta;
  final bool pinned, yesterday;
}

const chatThreads = <ChatThread>[
  ChatThread(1, 'Локальная нейроархитектура', 'только что · 24 реплики', pinned: true),
  ChatThread(2, 'Промпты для генерации сцен', '2 часа назад'),
  ChatThread(3, 'Оптимизация голосовых триггеров', '5 часов назад'),
  ChatThread(4, 'Сборка XTTS под Windows', 'вчера, 21:40', yesterday: true),
];

class VoiceCommand {
  VoiceCommand(this.phrase, this.action, this.target, this.enabled);
  final String phrase, action, target;
  bool enabled;
}

List<VoiceCommand> defaultCommands() => [
      VoiceCommand('Открой браузер', 'Выполнить shell', 'chrome.exe', true),
      VoiceCommand('Включи плейлист для кода', 'Медиа-триггер', 'spotify://playlist', true),
      VoiceCommand('Следующий трек', 'Медиа-команда', 'системный микшер', false),
      VoiceCommand('Сверни всё', 'Горячая клавиша', 'Win + D', true),
    ];

const mediaShortcuts = <List<String>>[
  ['⌘←', 'Предыдущий трек'],
  ['⌘␣', 'Плей / пауза'],
  ['⌘→', 'Следующий трек'],
  ['⌘⇧M', 'Выключить микрофон'],
];

class ModuleRow {
  const ModuleRow(this.name, this.value, {this.bar, this.accent = false});
  final String name, value;
  final double? bar;
  final bool accent;
}

class ModuleCard {
  const ModuleCard(this.name, this.status, this.statusColor, this.rows);
  final String name, status;
  final Color statusColor;
  final List<ModuleRow> rows;
}

class LogEntry {
  const LogEntry(this.time, this.tag, this.text, this.color);
  final String time, tag, text;
  final Color color;
}

const logTags = ['Все', 'Голос', 'Модель', 'Команды', 'Телефон', 'Обновления', 'Ошибки'];

class TtsHistoryItem {
  const TtsHistoryItem(this.voice, this.text, this.time);
  final String voice, text, time;
}

const ttsHistory = <TtsHistoryItem>[
  TtsHistoryItem('Clone-Echo v3', 'Нейроконфигурация загружена…', '1 м'),
  TtsHistoryItem('Системный голос', 'Тепловой предел на нейропроцессоре', '30 м'),
  TtsHistoryItem('Clone-Echo v3', 'Отчёт по телеметрии за сутки', '2 ч'),
];

/// Стили визуализации виджета. Второй элемент — как рисовать превью;
/// в Dart это разбирается в widgets/viz_preview.dart.
const vizStyles = <String>[
  'Сфера', 'Волны', 'Бары', 'Siri Orb', 'Полоски', 'Волны 3D', 'Поле частиц', 'Нет',
];
