# Nexus Anima — карта проекта

Голосовой ассистент для **Windows**: постоянное прослушивание со словом-активатором,
голосовые команды, чат с языковой моделью (своя станция или локальный инференс),
студии генерации картинок и озвучки, плавающий виджет с визуализацией голоса.
Тяжёлые вычисления уходят на домашнюю станцию с видеокартой.

## Координаты

| Что | Где |
|---|---|
| Рабочая копия | `f:\flutter\mirai`, Flutter-проект в подпапке `test1/` |
| Ветка | `evs-main` |
| Remote `evs` | `github.com/kekw2077/enhanced-voice-system` — рабочий репозиторий |
| Remote `origin` | `github.com/kekw2077/mirai` — **мобильная линия, отдельный проект**: туда не пушить, оттуда не мержить |
| Версия | `pubspec.yaml`, сейчас `3.2.4+114` |
| Имена | продукт **Nexus Anima**, exe `anima.exe`, пакет `anima`, короткое имя Anima. Слово-активатор по умолчанию — «Anima» |

Ветки `main` и `desktop` в этой копии остались от прежней схемы, когда мобильная и
десктопная линии жили в одном репозитории. Мобильная разработка переехала в свой
репозиторий; здесь **только Windows**, и инструкции про Android/Shorebird/APK к этой
работе не относятся (их архив — [docs/archive/](docs/archive/)).

## Правило №1: одна библиотека, 38 частей

`lib/main.dart` — точка входа: 39 импортов, 38 директив `part`, `main()`. Каждый
`lib/src/*.dart` начинается с `part of '../main.dart';`.

**Новые `import` в части не добавлять** — все импорты живут в `main.dart`, части их
наследуют. Смысл в приватности: в Dart она на уровне библиотеки, а библиотека тут
одна, поэтому `_`-классы видны между файлами.

## Карта кода

### Запуск и состояние

| Файл | Что внутри |
|---|---|
| [lib/main.dart](lib/main.dart) | импорты, `part`-директивы, `main()` |
| [lib/src/bootstrap.dart](lib/src/bootstrap.dart) | single-instance, восстановление окна, portable-prefs, процессы оверлея и заставки, подметание осиротевших `anima_sidecar.exe`/`evs_sidecar.exe` |
| [lib/src/app_state.dart](lib/src/app_state.dart) | `AppState` — главное хранилище (provider + `shared_preferences`). Самый большой файл, 5210 строк |
| [lib/src/models.dart](lib/src/models.dart) | дата-классы, `enum AppStyle { standard, nexus, noctur, prism }`, `kChangelog` — история версий для экрана «Что нового» |
| [lib/src/llm_services.dart](lib/src/llm_services.dart) | `ILLMService`/`LocalLLMService`/`RemoteLLMService`, `VoiceInterpreter`, `TokenCounter` |

### Оболочки — четыре стиля

| Файл | Что внутри |
|---|---|
| [lib/src/shell_common.dart](lib/src/shell_common.dart) | общее для classic · Nexus · «Ноктюрн» |
| [lib/src/desktop_home.dart](lib/src/desktop_home.dart) | главный экран стилей `standard`/`nexus`, боковая панель |
| [lib/src/noctur_shell.dart](lib/src/noctur_shell.dart) | «Ноктюрн»: шапка с вкладками, кольцо, строка телеметрии |
| [lib/src/prism_shell.dart](lib/src/prism_shell.dart) | «Призма» — четвёртая оболочка по макету `handoff/design` |
| `lib/src/prism_*.dart` (11 файлов) | части «Призмы»: [hub](lib/src/prism_hub.dart) «Центр», [chat](lib/src/prism_chat.dart) «Диалог», [commands](lib/src/prism_commands.dart), [modules](lib/src/prism_modules.dart), [appearance](lib/src/prism_appearance.dart), [welcome](lib/src/prism_welcome.dart), [lumina](lib/src/prism_lumina.dart) и [sonora](lib/src/prism_sonora.dart) — формы студий, [orb](lib/src/prism_orb.dart), [controls](lib/src/prism_controls.dart), [icons](lib/src/prism_icons.dart) |
| [lib/src/tray_menu.dart](lib/src/tray_menu.dart) | меню в трее — своим окном, а не системным |

«Призма» держит только **форму**; логика студий остаётся в `studio_panel.dart`.

### Экраны

| Файл | Что внутри |
|---|---|
| [lib/src/chat_screen.dart](lib/src/chat_screen.dart) | чат |
| [lib/src/voice_screen.dart](lib/src/voice_screen.dart) | голосовой ввод (распознавание), `ConversationsSheet` |
| [lib/src/desktop_settings.dart](lib/src/desktop_settings.dart) | все карточки настроек, 9014 строк — самый большой экран |
| [lib/src/settings_screens.dart](lib/src/settings_screens.dart) | «О программе», локальные модели, персонализация |
| [lib/src/studio_panel.dart](lib/src/studio_panel.dart) | **обе студии**: `StudioMode { image, speech }` — генерация картинок и озвучка текста в одном состоянии |
| [lib/src/lumina_studio.dart](lib/src/lumina_studio.dart) | «Nexus Lumina» — вид студии картинок |
| [lib/src/relay_panel.dart](lib/src/relay_panel.dart) | экран канала (Nexus Relay) |
| [lib/src/czn_translator.dart](lib/src/czn_translator.dart) | переводчик игры поверх стороннего приложения |

### Голос, десктоп, оформление

| Файл | Что внутри |
|---|---|
| [lib/src/sidecar_client.dart](lib/src/sidecar_client.dart) | `SidecarClient` — запуск и разговор с Python-движком, `VoiceAssistant` (wake-word, Push-to-Talk) |
| [lib/src/voice_viz.dart](lib/src/voice_viz.dart) | `VoiceLevels`, визуализации волны/полос/кольца, виджет-оверлей |
| [lib/src/speech_chunks.dart](lib/src/speech_chunks.dart) | нарезка длинного текста на куски под озвучку (14 тестов) |
| [lib/src/desktop_integration.dart](lib/src/desktop_integration.dart) | `CommandExecutor`, `SystemMonitor`, `ProcessJob`, `CloneServer`, `DesktopIntegration` (трей/горячие клавиши/окно), `PttWatcher`, `EvsLogFeed` и **`GpuArbiter`** — см. ниже |
| [lib/src/remote_input.dart](lib/src/remote_input.dart) | сервер удалённого ввода, каталог голосовых команд, мастер добавления |
| [lib/src/updater_and_web.dart](lib/src/updater_and_web.dart) | `AppUpdater` (WinSparkle), `WebSearchService`, `ComponentManager` |
| [lib/src/relay_client.dart](lib/src/relay_client.dart) | клиент агента канала — см. [nexus_relay/CLAUDE.md](nexus_relay/CLAUDE.md) |
| [lib/src/theme_widgets.dart](lib/src/theme_widgets.dart) | **дизайн-система**: палитры, токены, шкалы, `evs*`-хелперы, `MotionPolicy`/`AmbientMotion` |
| [lib/src/genesis_logo.dart](lib/src/genesis_logo.dart) | логотип Genesis кодом, а не картинкой |
| [lib/src/i18n.dart](lib/src/i18n.dart) | словарь `ru`/`en`, доступ через `app.t('ключ')` |

**Цвета — только через токены** (`_bg`/`_card`/`_txt`/`_accent`/`_stroke`/…). Сырые
`Color(0x…)` в виджетах не писать; исключение — фиксированная палитра логотипа.
Вечный `..repeat()` не заводить: декоративная анимация оборачивается в
`AmbientMotion`, иначе она крутится и на фоне.

## Движок (sidecar) — Python

Отдельный процесс, в релизе `anima_sidecar.exe`, в разработке `python sidecar/main.py`.
Приложение читает из его вывода строку `ANIMA_SIDECAR_READY <порт>` (и старую
`EVS_SIDECAR_READY`) — иначе останется вообще без голоса. Движок — **скачиваемый
компонент** со своим циклом выпуска (`dist/components.json`), в установщик не входит.

| Файл | Что внутри |
|---|---|
| [sidecar/main.py](sidecar/main.py) | точка входа, IPC, сборка всего вместе |
| [sidecar/stt_engine.py](sidecar/stt_engine.py) | распознавание: микрофон, VAD, шумодав + три движка — `WhisperEngine`, `GigaAmEngine` (только CPU), `RemoteSttEngine` (чужой сервер по контракту OpenAI) |
| [sidecar/tts_engine.py](sidecar/tts_engine.py) | синтез: очередь воспроизведения + сменные движки (Piper, системный, клон-серверы) |
| [sidecar/qwen_tts_server.py](sidecar/qwen_tts_server.py) | клон-голос **на видеокарте** (Qwen3-TTS). Один и тот же файл работает и на компьютере под CUDA, и в контейнере станции под ROCm |
| [sidecar/xtts_server.py](sidecar/xtts_server.py) | клон-голос **на видеокарте** (XTTS-v2) для живых ответов, тот же HTTP-контракт. Заменил MOSS-TTS на процессоре: 0,5 с против 9,3 с на короткой фразе, 2,7 ГБ видеопамяти |
| [sidecar/gamemode.py](sidecar/gamemode.py) | игровой режим: снять модели с видеокарты |
| [sidecar/bus_filter.py](sidecar/bus_filter.py), [journal.py](sidecar/journal.py), [procwatch.py](sidecar/procwatch.py) | шина событий: фильтр правил, журнал, сторож процессов |
| [sidecar/audio_out.py](sidecar/audio_out.py), [app_audio.py](sidecar/app_audio.py) | устройства вывода и громкость отдельных программ |
| [sidecar/gpu.py](sidecar/gpu.py), [intent.py](sidecar/intent.py), [clone_worker.py](sidecar/clone_worker.py) | видеокарта, сопоставление фраз с командами, рабочий процесс клонирования |

## Станция `npc`

Ubuntu 24.04, AMD Radeon (Navi 44, 16 ГБ), доступ `ssh npc` (Tailscale `100.79.130.7`,
в локальной сети `192.168.50.50`). Всё, что тяжелее ноутбука, живёт там в контейнерах.

| Контейнер | Порт | Что делает |
|---|---|---|
| `evs-qwen` | 8760 | клон-голос Qwen3-TTS на видеокарте (студия озвучки) |
| `evs-image` | 8770 | генерация картинок (Animagine XL) **и арбитр видеокарты** |
| `evs-stt` | 9876 | распознавание GigaAM |
| `ollama` | 11434 | языковая модель (`gemma-chat`, семейство gemma3:12b) |
| `evs-updates` | 8099 | раздача обновлений приложения (nginx) |
| `evs-netwatch` | — | замер потерь пакетов по хопам, пишет `/data/netwatch.csv` — диагностика для Nexus Relay |
| `nexus-ntfy`, `homeassistant`, `mosquitto`, `music-assistant` | — | умный дом, к ассистенту отношения не имеют |

Выкладка серверов — скриптами `server/*/deploy-*.sh`: их копируют на станцию и
запускают там. Каждый заканчивается **настоящей проверкой** (синтез прогоняется через
распознавание), а не «сервер ответил 200».

### Видеокарта одна — отсюда арбитр

Замерено: карта 16 304 МБ, вхолостую занято ~960. Языковая модель `gemma3:12b` — около
9 000, клон-голос — около 4 000 (на длинной фразе до 8 000), генератор картинок — около
7 000. Втроём не помещаются никогда, вдвоём — впритык.

- **`GpuArbiter`** в [lib/src/desktop_integration.dart](lib/src/desktop_integration.dart):
  `takeForImages`/`release` и `takeForVoice`/`releaseVoice` — студия при открытии снимает
  языковую модель с карты, при закрытии выгружает свою модель и возвращает языковую.
  Полоса-предупреждение (`GpuNoticeBar`) живёт в оболочках, поэтому видна и после
  закрытия студии.
- **Заявка на карту** со стороны разговора: `holdForChat`/`releaseChat` → `POST /gpu/hold`
  на `evs-image`. Сервер картинок ждёт конца чужого кадра, а не выдёргивает модель.
- **`free_gpu()`** в `server/image/server.py` просит соседей освободиться перед загрузкой
  весов: Ollama — запросом с `keep_alive: 0`, синтез — `POST /unload`.
- Если после выгрузки память не вернулась, сервер синтеза **уходит на перезапуск**
  (`STUCK_VRAM`, порог 1 ГБ, настраивается `EVS_TTS_STUCK_MB`). Изнутри процесса живые
  тензоры не отнять, а «выгружен» обязано означать свободную карту.
- `OLLAMA_KEEP_ALIVE=30m` в `/home/art/home-assistant_ai/docker-compose.yml` на станции.
  Значение `-1` держало модель на карте вечно и приводило к зависанию станции.

## Выпуск

Обновления идут **не через GitHub**, а со станции. Подробности —
[dist/README.md](dist/README.md), коротко:

1. Поднять `version:` в `pubspec.yaml`.
2. `flutter build windows --release`
3. `& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" dist\installer.iss /DAppVersion=X.Y.Z`
   → `dist\out\NexusAnima-Setup-X.Y.Z.exe`
4. `.\dist\sign_update.ps1 .\dist\out\NexusAnima-Setup-X.Y.Z.exe` — печатает подпись, длину и sha256.
5. Добавить `<item>` **первым** в `dist/appcast.xml` со всеми тремя числами.
6. `.\dist\publish-to-station.ps1 -Version X.Y.Z` — кладёт установщик на станцию и
   переписывает ссылки в `appcast.xml`/`components.json` на её адрес.

Пересобрали exe — подпись, длина и sha256 в `appcast.xml` устарели. Не обновить их =
WinSparkle молча откажется ставить обновление. Откат — `dist/rollback.ps1`.

### Заметки к выпуску пишутся один раз

Источник один — `<description>` записи в `dist/appcast.xml`. Оттуда они расходятся:

| Куда | Как попадают |
|---|---|
| окно обновления («вот что вы сейчас поставите») | разбор канала при проверке обновлений |
| **история внутри программы**: окно «Что нового», список изменений в настройках, «О программе» | тот же разбор, `AppUpdater.parseHistory` → `AppState.changelog` |
| [CHANGELOG.md](CHANGELOG.md) — журнал в репозитории | переносится руками, шаг 7 выпуска |

Канал сохраняется на диск (`<userdata>/updates/appcast-history.xml`) при каждой удачной
проверке и поднимается оттуда при запуске — история открывается без сети и до первой
проверки. Пока канал ни разу не прочитан, показывается встроенный `kChangelog` из
[lib/src/models.dart](lib/src/models.dart): он отстал на 2.19.1 и оставлен **только как
запасной** — пополнять его не нужно.

Так было не всегда: до этого история читалась из `kChangelog`, и, поскольку его
перестали пополнять после 2.19.1, окно «Что нового» не показывалось ни разу за 47
выпусков — оно не находило своей версии в списке. Разбор канала прикрыт тестами в
[test/appcast_notes_test.dart](test/appcast_notes_test.dart): ломается он молча, а
видно это только на одном экране.

## Имена: что понимает оба и что переименовывать нельзя

Переименование EVS → Nexus Anima (2 сентября 2026) намеренно **не доведено до конца**.

Читаются **оба** имени, старое не удалять: маркер `EVS_SIDECAR_READY`, имя движка
`evs_sidecar.exe`, переменные `EVS_QWEN_CACHE`/`EVS_USERDATA`, установщик `EVS-Setup-*`.

**Не переименовывать никогда:**

- `evs:sha256` в `appcast.xml` — каждая установленная сборка ищет этот литерал;
- `AppId` в `dist/installer.iss` — GUID связывает установку Anima с заменяемой EVS;
- мьютекс `EVS-SingleInstance-Mutex` — иначе запустятся две копии на один микрофон;
- `elevatedTaskName` → папка `EVS\cmd_*` в планировщике задач.

## Данные — только на диске установки

Ничего не писать на `C:`. Корень данных портативный — `<папка установки>\userdata`;
кэши моделей пиннятся явно (`pin_cache_to` в `qwen_tts_server.py`). Непрочитанная
переменная окружения не даёт ошибки — она молча уводит 4 ГБ весов на системный диск.

## Проверки

```powershell
flutter analyze lib/src/имя.dart      # быстрее, чем весь проект
flutter test                          # 13 файлов тестов в test/
flutter run -d windows                # прогон вживую
python -m py_compile sidecar\файл.py  # синтаксис движка перед выкладкой
```

Тесты покрывают то, что ломается молча: нарезку длинного текста (`speech_chunks_test`),
слово-активатор, разбор заметок к выпуску, числительные, выбор отката, иконку.

## Что легко нарушить

- **Новое ведёт в существующее.** Новая кнопка, вкладка или стиль ссылаются на готовую
  функцию, а не заводят вторую реализацию рядом. Если новое противоречит существующей
  настройке — это вопрос к пользователю, а не повод выбрать самому.
- **Путь запуска.** Готовность = движок ответил `ready`; всё, что стоит между стартом и
  этим моментом, платится временем запуска. Сеть туда уже попадала трижды.
- **Выбор пользователя не переписывать.** `sttSidecarEngine` — это выбор, `sttEngineLive` —
  что работает сейчас. Подписи читают второе, настройка остаётся первой.
