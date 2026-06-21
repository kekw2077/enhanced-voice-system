# Alice AI — описание проекта

Flutter-приложение «Alice AI» — чат-клиент для LLM с поддержкой удалённых серверов (Ollama/OpenAI-совместимый API) и локального инференса прямо на устройстве (без интернета).

- Git repo root: `C:\Files\vs code\test v0.1` (проект Flutter лежит в подпапке `test1`)
- GitHub remote: `https://github.com/kekw2077/test-v0.1`
- Основная ветка: `main`
- Package name: `alice_ai`, отображаемое имя приложения: **Alice AI**

## Архитектура

Почти весь код в одном файле: [lib/main.dart](lib/main.dart) (~4100 строк). Это осознанно — проект не разбит на модули.

Ключевые классы (см. `grep -n "^class " lib/main.dart`):
- `AppState extends ChangeNotifier` — главное хранилище состояния (provider), персистится через `shared_preferences`. Содержит: язык интерфейса, тему, настройки голосового ввода, `serverUrl`/`apiKey`/список `models`/`selectedModel`, персонализацию (`Personalization persona`), список диалогов (`Conversation`), а также всё, что касается локальных моделей (`downloadedLocalModelIds`, `localDownloadProgress`).
- `ChatMessage`, `Conversation` — модель данных чата.
- `Personalization` — системный промпт/настройки поведения ассистента.
- `LocalModelSpec` / `kLocalModels` — захардкоженный каталог GGUF-моделей для локального инференса.
- `ChatScreen` / `_ChatScreenState` — основной экран чата.
- `VoiceScreen` / `_VoiceScreenState` — экран голосового ввода (на базе `speech_to_text`).
- `SettingsSheet`, `LocalModelsScreen`, `MemoryScreen`, `PersonalizationScreen`, `ConversationsSheet` — вспомогательные экраны/шторки настроек.
- `_ModelMenu` — пикер модели (показывает и удалённые модели с сервера, и локальные).

Локализация: простой словарь `_i18n['ru']`/`_i18n['en']` внутри `main.dart`, доступ через `app.t('key')`. Язык переключается в настройках, по умолчанию `ru`.

## Два режима инференса

1. **Удалённый (HTTP)** — `AppState.sendMessage()` шлёт запрос на `serverUrl` (Ollama/OpenAI-совместимый эндпоинт), это исходный и основной режим.
2. **Локальный (on-device LLM)** — добавлен позже через библиотеку **`fllama`** (обёртка над llama.cpp, GGUF-модели). В `sendMessage()` есть ветвление: если `isLocalModel(selectedModel)` (строка модели начинается с `local:`), вызывается `_sendLocalMessage()`, который грузит модель по локальному пути и стримит ответ через `fllamaChat(OpenAiRequest, callback)`.
   - Каталог моделей зашит в код (`kLocalModels`): TinyLlama-1.1B-Chat (Q4_K_M, ~0.67ГБ) и Qwen2.5-1.5B-Instruct (Q4_K_M, ~1.12ГБ), оба с HuggingFace.
   - Экран **«Локальные модели»** (`LocalModelsScreen`, доступен из настроек) — скачать/отменить/удалить/выбрать модель, с прогресс-баром.
   - Хранение скачанных файлов — через `path_provider`, путь определяется платформо-зависимым шимом: [lib/local_model_io.dart](lib/local_model_io.dart) (реальная реализация, `dart:io`) / [lib/local_model_stub.dart](lib/local_model_stub.dart) (веб-стаб), выбираются условным импортом `import 'local_model_stub.dart' if (dart.library.io) 'local_model_io.dart';` — это нужно специально из-за `path_provider`, который не собирается под Web напрямую.

### Важное про сам пакет `fllama`

Существуют ДВА разных пакета с одним именем:
- пакет `fllama` на pub.dev (автор `xuegao-tzx`) — низкоуровневый, Android/iOS/HarmonyOS только, **не тот**, что используется здесь.
- настоящий используемый пакет — **Telosnex/fllama** (`https://github.com/Telosnex/fllama`), даёт `fllamaChat(OpenAiRequest, callback)` (OpenAI-style streaming API). Не опубликован на pub.dev, подключён как git-зависимость в `pubspec.yaml`, закреплён на конкретный commit SHA (не `main`, для воспроизводимости).
- Собирается из исходников через Dart **native assets / hooks build system** (`hook/build.dart` + `native_toolchain_cmake`), компилирует llama.cpp через CMake при первой сборке под нужную платформу/архитектуру. Скомпилированная `.so`/`.dll` кэшируется в `~/.cache/fllama/<hash>/` — это ВНЕ `.dart_tool`, поэтому переживает `flutter clean`.

## Платформы и сборка

Поддерживаемые таргеты: Android, iOS, macOS, Windows, Linux, Web (папки соответствующие есть в репо). Реальное тестирование в этом проекте велось в первую очередь **на Android-телефоне по USB** (Huawei DLI-TL20, Android 7.0 / API 24, 32-бит ARM armeabi-v7a — это нижняя граница `minSdkVersion=24` у Flutter).

### Android-окружение на машине разработки (Windows)

- Android SDK кастомно установлен в `C:\Android\sdk` (НЕ дефолтный путь `%LOCALAPPDATA%\Android\Sdk`).
- `native_toolchain_c`'s NDK resolver на Windows плохо находит SDK по нестандартным путям/переменным окружения, поэтому сделан **directory junction**: `C:\Users\<user>\AppData\Local\Android\Sdk` → `C:\Android\sdk` (через `New-Item -ItemType Junction`, без админ-прав). Без этого падает `Found no Android NDK in [...]` / `Bad state: No element`.
- `android/gradle.properties`: `android.builtInKotlin=false` и `android.newDsl=false` — это дефолты, которые сам Flutter-мигратор прописывает для существующих проектов при переходе на AGP 9. **Не включать** `android.builtInKotlin=true` — это ломает `flutter_plugin_android_lifecycle` (он самостоятельно подключает `org.jetbrains.kotlin.android`, что запрещено в режиме built-in Kotlin).
- `android/build.gradle.kts` содержит точечный фикс: плагин `file_picker` 11.0.2 при AGP 9+ сам не подключает Kotlin-плагин (рассчитывая на built-in Kotlin), но раз `builtInKotlin=false`, его Kotlin-исходники не компилируются → ошибка `FilePickerPlugin cannot find symbol`. Фикс — явно применить `org.jetbrains.kotlin.android` только для `file_picker` через `subprojects { if (project.name == "file_picker") apply(plugin = ...) }`.
- `AndroidManifest.xml` обязательно содержит: `INTERNET` (нужен и для HTTP-чата, и для скачивания моделей), `RECORD_AUDIO` + `BLUETOOTH`/`BLUETOOTH_ADMIN`/`BLUETOOTH_CONNECT` (нужны `speech_to_text`), плюс `<queries>` с `android.speech.RecognitionService` (обязательно для targetSdk 30+). Без этих разрешений голосовой ввод тихо зависает на «подключение микрофона».
- На устройствах без Google Play Services (многие Huawei) распознавание речи **зависит от сети** — без интернета/Wi-Fi голосовой ввод не работает или работает нестабильно. Это не баг приложения.
- Если Gradle-демон падает с `Gradle build daemon disappeared unexpectedly` во время тяжёлой нативной CMake-компиляции (частое явление при первой компиляции fllama под несколько ABI) — обычно достаточно `cd android && ./gradlew --stop`, затем повторить сборку.

### Иконка приложения

Генерируется через `flutter_launcher_icons` (dev-зависимость, секция `flutter_launcher_icons:` в `pubspec.yaml`). Исходник — [assets/icon/icon.png](assets/icon/icon.png) (1024×1024, с альфа-прозрачностью в углах для закруглённых углов на платформах без автоматического маскирования иконок). Для iOS включён `remove_alpha_ios: true` (Apple запрещает альфа-канал в иконках). После любой замены исходника — `dart run flutter_launcher_icons`.

## Известные особенности / риски

- Сборка release APK компилирует fllama для нескольких ABI (arm64-v8a, armeabi-v7a, x86_64) последовательно — каждая занимает по 2-3 минуты, итоговая сборка может занимать 10+ минут.
- На 32-битных ARM устройствах (armeabi-v7a) нативная сборка llama.cpp пропускает ARM64-специфичные оптимизации (видно в логе: `Non-ARM64 Android build (armeabi-v7a) - skipping ARM optimizations`) — ожидаемо медленнее, чем на arm64.
- Release-сборка пока подписывается debug-ключом (`signingConfig = signingConfigs.getByName("debug")` в `android/app/build.gradle.kts`) — нормально для побочной установки (sideload) на другие телефоны, но не для публикации в Play Store.

## Полезные команды

```bash
flutter analyze                       # проверка типов/линт
flutter run -d windows                # быстрый прогон на десктопе (без нужды в Android-окружении)
flutter devices                       # список устройств, включая телефон по USB
flutter run -d <device-id>            # debug-сборка + установка на устройство
flutter build apk --release           # релизный APK для ручной установки (build/app/outputs/flutter-apk/app-release.apk)
cd android && ./gradlew --stop        # сбросить зависший/сломанный Gradle-демон
```
