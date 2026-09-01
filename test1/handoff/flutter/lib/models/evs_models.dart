import 'package:flutter/material.dart';

/// Состояние ассистента. Цвета и подписи один-в-один из прототипа (HEX/STATES).
enum VoiceState { idle, listening, thinking, speaking }

extension VoiceStateInfo on VoiceState {
  String get label => switch (this) {
        VoiceState.idle => 'Ожидание',
        VoiceState.listening => 'Слушаю…',
        VoiceState.thinking => 'Думаю…',
        VoiceState.speaking => 'Говорю',
      };

  String get hint => switch (this) {
        VoiceState.idle => 'Нажмите на шар или скажите wake-фразу',
        VoiceState.listening => 'Слушаю — говорите',
        VoiceState.thinking => 'Думаю над ответом',
        VoiceState.speaking => 'Отвечаю голосом',
      };

  /// Основной цвет состояния.
  Color get c1 => switch (this) {
        VoiceState.idle => const Color(0xFF5C6478),
        VoiceState.listening => const Color(0xFF3B7BE8),
        VoiceState.thinking => const Color(0xFF7F5AAC),
        VoiceState.speaking => const Color(0xFF1F9E7A),
      };

  /// Второй цвет — уходит в градиенты шара и колец.
  Color get c2 => switch (this) {
        VoiceState.idle => const Color(0xFF7C8399),
        VoiceState.listening => const Color(0xFFC0568F),
        VoiceState.thinking => const Color(0xFF3269CE),
        VoiceState.speaking => const Color(0xFF3C8CA8),
      };

  bool get isIdle => this == VoiceState.idle;

  VoiceState get next => VoiceState.values[(index + 1) % VoiceState.values.length];
}

/// Сообщение в ленте. [steps] — нумерованные пункты внутри ответа.
class ChatMessage {
  const ChatMessage({required this.text, required this.fromAssistant, this.steps = const []});
  final String text;
  final bool fromAssistant;
  final List<String> steps;
}

/// Строка загрузки подсистемы.
class HwMetric {
  const HwMetric(this.name, this.value, this.fraction);
  final String name;
  final String value;
  final double fraction; // 0..1
}
