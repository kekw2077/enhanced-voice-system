# Mirai — Desktop (Windows) версия: инструкция для рабочей сессии

Полный свод особенностей **десктоп-ветки (`desktop`, только Windows)**. Читать вместе с [CLAUDE.md](CLAUDE.md) (там общая архитектура проекта и правила мобильной ветки). Если что-то противоречит — для десктоп-сессии приоритет у **этого** файла. Этот файл существует **только на ветке `desktop`** (в `main` его нет и быть не должно).

## 0. Самое первое — убедись, что ты в нужном месте

- Десктоп-ветка живёт в **отдельном git worktree**: `C:\Files\vs code\mirai-desktop` (Flutter-проект — в подпапке `test1`). Мобильная ветка `main` — в `C:\Files\vs code\test v0.1\test1`. Оба worktree делят одну общую историю/`.git`.
- Проверь ветку: `git branch --show-current` → должно быть `desktop`. Если нет — ты, скорее всего, не в том worktree; работай из `C:\Files\vs code\mirai-desktop`.
- Правки десктопа делай в worktree десктопа, чтобы случайно не задеть мобильную рабочую копию.

## 1. Назначение ветки и правила синхронизации (критично)

- `desktop` — независимая линия разработки **только под Windows-десктоп**. Создана от `main` на коммите 2.13.2+41. Сюда идут изменения, которых **не должно быть на мобильных версиях**.
- **Никогда не мёржить `desktop → main`** и не cherry-pick'ить коммиты из `desktop` в `main` — иначе Windows-правки утекут в мобильную сборку. Поток только в одну сторону.
- Общий фикс, нужный обеим платформам, делается в `main`, затем переносится сюда: `git merge main` или `git cherry-pick <sha>` (это разрешённое направление).
- **Никакого мобильного деплоя с `desktop`:** ни `shorebird release`/`shorebird patch`, ни запуска `ios-altstore.yml`, ни GitHub Release с APK. Всё это привязано к `main`.
- Можно свободно менять `pubspec.yaml`, версию, зависимости, UI — это не влияет на мобильную ветку (пока не уходит в `main`).

## 2. Сборка и запуск (Windows)

```bash
flutter run -d windows            # запуск/отладка на десктопе
flutter build windows             # релизная сборка → build\windows\x64\runner\Release\mirai.exe
flutter build windows --debug     # дебаг-сборка для смоука → ...\Debug\mirai.exe
flutter analyze                   # линт/типы
```

- Смоук-проверка: собрать debug, запустить `mirai.exe`, убедиться, что не падает.
- Android-окружение (NDK, Gradle, junction `C:\Android\sdk`) для десктопа **не нужно** — это всё про мобильную сборку.

## 3. Версии и changelog

- Веди **отдельно** от мобильной линии. Мобильные `kChangelog` (в `lib/main.dart`), `CHANGELOG.md` и схема версий из памяти относятся к `main`.
- Сейчас десктоп синхронизирован с `main` на **2.14.2+44** (после merge `main → desktop`).
- Если нужна своя десктоп-версия/история — **спроси у пользователя**, как её вести, не повторяй мобильную автоматически.

## 4. Архитектура — как в `main`

- Почти весь код в одном файле `test1/lib/main.dart` (~8700+ строк), сознательно не разбит на модули. Ключевые классы (`AppState`, `ChatScreen`/`_ChatScreenState`, `ILLMService`/`LocalLLMService`/`RemoteLLMService`/`LLMServiceFactory`, `kLocalModels`, `Personalization`, RP-классы и т.д.) — см. CLAUDE.md.
- Два режима инференса те же: **удалённый HTTP** (Ollama/OpenAI-совместимый) и **локальный on-device** через `fllama` (llama.cpp/GGUF). На Windows `fllama` собирает llama.cpp через CMake при первой сборке, бинарь кэшируется в `~/.cache/fllama/<hash>/` (вне `.dart_tool` — переживает `flutter clean`).
- Используемый `fllama` — Telosnex/fllama, git-зависимость, закреплена на конкретный commit SHA в `pubspec.yaml` (не публикуется на pub.dev). Ограничения пакета (нет полей `stop`/`mirostat`/`tfs_z`/`typical_p`, нет API выгрузки модели и catchable-OOM) — те же, что описаны в CLAUDE.md.

## 5. Десктоп-специфичные особенности и подводные камни

### 5.1 Определение ОЗУ / потолок контекста — ВАЖНО
- В коде есть авто-ограничение размера контекста локальной модели под ОЗУ: `AppState.deviceRamMb` + геттер `AppState.ramContextCeiling`, ОЗУ читается плагином `system_info_plus` (`SystemInfoPlus.physicalMemory`, в МБ).
- **`system_info_plus` поддерживает только Android/iOS, не Windows.** На Windows вызов отвалится (обёрнут в try/catch в `_detectDeviceRam()`), `deviceRamMb` останется `null`, и `ramContextCeiling` вернёт **жёсткие 4096** независимо от реального объёма ОЗУ.
- Для ПК (где обычно много ОЗУ) это занижено. Если нужно поднять — варианты **строго на ветке `desktop`**:
  - читать ОЗУ напрямую без плагина: на Windows через PowerShell/WMIC (`dart:io` `Process.run`) или Win32 `GlobalMemoryStatusEx` (через `dart:ffi`);
  - либо просто поднять/убрать потолок на десктопе (увеличить значение в `ramContextCeiling`, когда `deviceRamMb == null`, или развязать логику под Windows через `Platform.isWindows`).
- Места применения потолка (если меняешь логику — поправь во всех трёх): `_contextSizeControl` (вкладка «Память»), `_roleplayTab` (опции контекста RP), `LocalLLMService._buildRequest` (защитный клэмп самого запроса). Эффективный максимум = `min(spec.maxLocalContextSize, app.ramContextCeiling)`.
- Это типичное «только для десктопа» изменение — делать на `desktop`, в `main` не нести.

### 5.2 Что из мобильного НЕ применяется к Windows
- Android NDK junction, сборка `fllama` под несколько ABI (arm64/armeabi-v7a/x86_64), `flutter_native_splash`, иконки через `flutter_launcher_icons` для iOS/Android, AltStore, Shorebird, подпись debug-ключом — всё это про мобильную сборку, на десктоп не распространяется.
- Веб-стабы (`local_model_stub.dart` + условные импорты `import '...stub.dart' if (dart.library.io) '...io.dart'`) на десктопе некритичны (`dart:io` доступен), но если правишь общий код — не ломай существующую кросс-сборку без нужды.

### 5.3 UI на Windows
- `BackdropFilter`/glassmorphism (стиль **Liquid Glass**) на Windows работает штатно (`GlassSurface`, `_AppDialog`, `_glassCard` и т.п.).
- Переключатели: `_iosSwitch` → `CupertinoSwitch` в стиле Liquid Glass / зелёный Material `Switch` в обычном стиле — оба рендерятся Flutter'ом, на Windows выглядят так же, как на мобильных.
- Шрифт: глобальный `fontFamily` — **Nunito** (asset, не `google_fonts`). Системный iOS-шрифт (San Francisco) включается только на iOS (`defaultTargetPlatform == TargetPlatform.iOS`), на Windows всегда Nunito.
- Голосовой ввод: на Windows используется `SpeechToTextWindowsPlugin` (виден в логах запуска). Поведение распознавания на Windows может отличаться от Android/iOS.

## 6. Что сейчас в коде (на момент синхронизации, 2.14.2+44)
- Экран **«Подготовка модели»**: при открытии чата с локальной моделью (или её выборе) модель прогревается, поле ввода блокируется до готовности (`AppState.warmUpModelFor`, `isModelLoading`).
- Все всплывающие окна в стеклянном стиле — **Liquid Glass** (`_AppDialog`); окно **«Управление моделями»** открывается по центру экрана (`showDialog` + `_AppDialog`), а не выезжает снизу.
- Авто-лимит контекста под ОЗУ (см. 5.1 — **на Windows пока даёт 4096**).
- Тема «Liquid Glass» (бывш. «Жидкое стекло» — переименована).

## 7. Чек-лист перед коммитом на `desktop`
- [ ] `git branch --show-current` == `desktop` (работаешь в worktree `C:\Files\vs code\mirai-desktop`).
- [ ] Не запускал мобильный деплой (Shorebird / iOS Actions / GitHub Release APK).
- [ ] Не мёржишь и не cherry-pick'ишь в `main` (только `main → desktop`).
- [ ] `flutter analyze` чисто; по возможности `flutter build windows` + запуск без падений.
- [ ] Версию/changelog десктопа согласовал с пользователем (отдельно от мобильной линии).
