# Mirai

A Flutter chat client for LLMs, with remote (Ollama/OpenAI-compatible) and on-device inference.
Mirai — кросс-платформенный чат-клиент для LLM на Flutter, с поддержкой как удалённых серверов, так и полностью локального инференса на устройстве (без интернета).

## Возможности

This project is a starting point for a Flutter application.
- **Удалённый режим** — подключение к любому Ollama или OpenAI-совместимому API (свой сервер, локальная сеть и т.п.).
- **Локальный режим** — инференс прямо на устройстве через [fllama](https://github.com/Telosnex/fllama) (llama.cpp, GGUF-модели), полностью офлайн. Каталог моделей разбит на тиры по мощности устройства:
  - **Лёгкие**: Qwen2.5 0.5B, Llama 3.2 1B
  - **Средние**: Qwen2.5 1.5B/3B, Gemma 2 2B, Phi-3 Mini 4K
  - **Мощные**: Mistral 7B v0.3, Qwen2.5 7B, Llama 3.1 8B
- Несколько диалогов с историей, поиском и закреплением.
- Голосовой ввод.
- Персонализация ассистента (тон, формальность, юмор, многословность, эмодзи и т.п.) — глобально или индивидуально для каждого чата.
- Память и профиль «о вас» (заметки, имя, интересы, запретные темы) — тоже глобально или по чатам.
- Светлая/тёмная тема, RU/EN интерфейс.

A few resources to get you started if this is your first Flutter project:
## Платформы

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)
Android, iOS, macOS, Windows, Linux, Web. Активно тестируется в первую очередь на Android.

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
## Обновления

- Крупные изменения (новые разрешения, нативные зависимости) — полный APK через [GitHub Releases](https://github.com/kekw2077/mirai/releases).
- Обычные правки кода — через [Shorebird Code Push](https://shorebird.dev/) в фоне, без переустановки приложения.

## Сборка из исходников

```bash
flutter pub get
flutter run -d <device-id>          # debug-запуск
flutter build apk --release         # релизный APK (Android)
```

Подробности архитектуры и окружения сборки — в [CLAUDE.md](CLAUDE.md).
