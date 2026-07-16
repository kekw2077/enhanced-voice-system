# EVS — статус работы, где остановились

Обновлено: 2026-07-15. Ветка: `desktop`. Репозиторий `kekw2077/mirai`.

> **Читай это первым и верь git'у, а не памяти.** Прошлая редакция этого файла
> говорила «код готов, но НЕ закоммичен — синхронизировать!», хотя на деле всё
> было закоммичено и запушено (`18c166b`). Из-за этого следующая сессия заново
> переписала те же фиксы и чуть не устроила конфликтный мерж. **Перед любой
> работой: `git fetch origin && git log --oneline -5 origin/desktop`.**

## Машина

Разработка переехала на **основной ПК** (пользователь `ART`, репозиторий
`f:\flutter\mirai`, Flutter-проект в `test1`). Старая машина (`korne`) больше не
используется. Тулинг здесь:

- git — **есть** (в отличие от старой машины).
- `gh` — `C:\Program Files\GitHub CLI\gh.exe` (2.96.0). **НЕ авторизован** → `gh auth login`.
- ISCC (Inno Setup 6.7.3) — `C:\Users\ART\AppData\Local\Programs\Inno Setup 6\ISCC.exe`.
- openssl — из состава Git (`C:\Program Files\Git\usr\bin\openssl.exe`), `sign_update.ps1` находит сам.
- Sidecar venv — `test1\sidecar\.venv` на **Python 3.12.10** (3.14 не подходит: нет
  колёс sherpa-onnx/ctranslate2). Стоят sherpa-onnx 1.13.4, faster-whisper 1.2.1,
  pyinstaller 6.21.0, nvidia-ml-py; `py_compile` всех исходников проходит.
- **`test1\dsa_priv.pem` — ОТСУТСТВУЕТ.** ← единственный блокер релиза, см. ниже.

## Ключ подписи — на месте

`test1\dsa_priv.pem` перенесён со старой машины и **проверен**: производный от
него публичный ключ совпадает с `dsa_pub.pem` байт в байт, а тот вшит в exe
(`windows/runner/Runner.rc:68`, `DSAPub DSAPEM`) и используется WinSparkle для
проверки подписи каждого обновления.

- Лежит под `.gitignore` (`test1/.gitignore:53`) — в git не попадает. **Не клади
  его в корень репозитория**: там `.gitignore` из `test1/` не действует, и
  секрет уедет в публичный репозиторий.
- **Нельзя** сгенерировать новый: у всех установленных копий зашит старый
  публичный ключ → они отвергнут обновление и станут неапгрейдимыми навсегда.
- Резервная копия обязательна.

## Что сделано (всё закоммичено и запушено)

| Коммит | Содержание |
|---|---|
| `338a94b` | EVS 2.0.0 — большой патч из 3 ТЗ (релиз `desktop-v2.0.0`, компонент сайдкара v8) |
| `18c166b` | Фиксы 2.0.1: сайдкар onedir (onnxruntime), whisper-retry, masonry, бейдж движка, движок/модель UX, `fadeEdges` у волны |
| `306597e` | Волна перекрашивается по состоянию ассистента (`accent` в пейнтерах + `reactive` у `EvsWaveViz`) |
| `6342a31` | Раскладка настроек 1/2/3 колонки по ширине (ТЗ «Настройки» §5) |
| `4716277` | Сайдкар v9 (onedir zip) — реальный фикс GigaAM/денойза/Piper |
| `9d16d3f` | **Релиз 2.0.1**: pubspec 2.0.1+20, changelog, appcast |

`flutter analyze` — чисто.

### Важная поправка к диагнозу
Прошлая редакция утверждала, что GigaAM, денойз и Piper падали по одной причине —
конфликту `onnxruntime.dll`. Это подтвердилось: после onedir-пересборки все три
поднялись. Но в ходе проверки всплыла ловушка API: у `stt.config` поле
`denoise_dir` — это **корень моделей**, а не папка денойза (`stt_engine._dfn_path()`
сам дописывает `denoise-df/dpdfnet_baseline.onnx`), тогда как `gigaam_dir` и
`voice_dir` — наоборот, конкретные папки. Передашь `denoise_dir` как папку —
получишь «strong denoise model not found» и решишь, что баг не починен.

## Баги 2.0.0 и их причины (для контекста)

1. **GigaAM/денойз/Piper падают** (`ORT Version 1.17.1`, «light denoise model not
   found»). Причина: onefile-сборка сваливает все DLL в одну папку, а sherpa-onnx и
   faster-whisper несут РАЗНЫЕ `onnxruntime.dll` → грузится не тот. Фикс (в `18c166b`):
   `--onedir + zip` в `build_exe.ps1`. **Сайдкар v9 ещё НЕ пересобран и не залит.**
2. **Whisper «Unable to open file 'model.bin'»** — гонка прогрева с докачкой.
   Фикс (в `18c166b`): ретрай в `_ensure_model` (4×2с).
3-6. Раскладка / бейдж / движок-модель / края волны — исправлены (см. таблицу выше).

## 2.0.1 — ВЫПУЩЕН (2026-07-16)

Релиз: https://github.com/kekw2077/mirai/releases/tag/desktop-v2.0.1
Сайдкар: компонент **v9** (`evs_sidecar.zip`, onedir) в релизе `desktop-components`.

Проверено вживую после публикации:
- фид appcast отдаёт `EVS 2.0.1`; ссылка на инсталлятор → HTTP 200, 15 898 077 Б
  (совпадает с подписанной длиной);
- `components.json` отдаёт sidecar v9; ссылка на zip → HTTP 200, 112 336 796 Б;
- фрозен-сайдкар v9 прогнан на РЕАЛЬНЫХ скачанных моделях по его WS-протоколу:
  GigaAM `ready`, DeepFilterNet `ready`, Piper `ready`, ORT-ошибок в stderr нет.

**Осталось по мелочи:** удалить с релиза `desktop-components` старый onefile-ассет
`evs_sidecar.exe` — он намеренно оставлен на время кэша raw.githubusercontent
(~5 мин), чтобы клиент со старым `components.json` не получил 404. Сейчас уже
можно:
```powershell
gh release delete-asset desktop-components evs_sidecar.exe --repo kekw2077/mirai --yes
```

### Как выпускать следующий патч
1. `pubspec.yaml` — поднять версию; запись в `kChangelog` (main.dart).
2. `flutter build windows --release` (сверить FileVersion exe).
3. `& "C:\Users\ART\AppData\Local\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=X.Y.Z dist\installer.iss`
   → `dist\out\EVS-Setup-X.Y.Z.exe`.
4. `.\dist\sign_update.ps1 .\dist\out\EVS-Setup-X.Y.Z.exe` → length + sha256 +
   dsaSignature → новый `<item>` в начало `dist/appcast.xml`.
5. `gh release create desktop-vX.Y.Z dist\out\EVS-Setup-X.Y.Z.exe --repo kekw2077/mirai ...`
6. Коммит pubspec + main.dart + appcast. **Порядок важен:** сначала релиз, потом
   коммит appcast — иначе клиенты полезут за файлом, которого ещё нет.
   Коммит appcast и есть «включить обновление» для всех.

Сайдкар версионируется независимо от приложения: `build_exe.ps1 -ComponentVersion N`
обновляет `dist/components.json` (sha256+size), затем `gh release upload
desktop-components ... --clobber` и коммит `components.json`. Подпись DSA
компоненту не нужна — он проверяется по sha256.

## Два ТЗ — новая работа (НЕ входит в 2.0.1)

Лежат в корне репозитория, **untracked** (в git их нет): `EVS_settings_TZ.md`,
`EVS_new_features_TZ.md`. Это масштаб минорного релиза (2.1.0), не хотфикса.

### ТЗ «Настройки» (`EVS_settings_TZ.md`) — идём по приоритетам §13
- [x] **§5 Раскладка** — masonry 1/2/3 колонки (`6342a31`).
- [x] **§3.1 «Модель и инференс»** — готово, тремя коммитами:
  - `0e6c153` — параметры инференса `num_ctx`/`num_predict`/`temperature`/
    `keep_alive` (`_LlmAdvancedCard`, свёрнут по умолчанию). Пустое поле → ключ
    удаляется из prefs → параметр не шлётся (`AppState.llmOptions()`).
    **`keep_alive` — top-level поле запроса Ollama, НЕ в `options`** (§11 кладёт
    его под `llm.options`, но это схема хранения, не формат провода). Проброс —
    `RemoteLLMService._buildBody`, только не-RP путь.
  - `3bc05a1` — «Проверить соединение» / «Обновить список» (`_ConnCheckRow`).
    Переиспользует `AppState.fetchModels()` — он и есть GET `/api/tags` и уже
    классифицирует исход (`unreachable`/`noModelsFound`), т.е. edge-cases §12.
  - `b097b3a` — модель по режиму (`searchModel`/`chatModel`, `_ModelModeCard`).
    Пусто = глобальная модель. «Режим поиска» = ход, где подтянут
    `pendingWebContext` (единственный search-сигнал в приложении). Резолвер
    `AppState.modelForTurn()`; override применяется только если модель есть в
    `app.models` (иначе фолбэк, без 404), пропавшая помечается ⚠ (§12).
  - Смоук-прогон `flutter run -d windows`: 0 render-исключений. Глазами карточки
    не кликал (нельзя автоматизировать GUI) — стоит открыть Настройки → Модели.
- [ ] §3.2 «Озвучка» ← *следующий*. Piper/CosyVoice, интерпретатор
  (правила/`qwen3-interp`), клонирование, скорость/эмоция. Блокер: сервер
  CosyVoice не развёрнут → по ТЗ показывать движок недоступным. Уже есть:
  `ttsPiperVoice`/`ttsRate`/`ttsVolume`, TTS-движок сайдкара (`tts_engine.py`,
  Piper/pyttsx3), карточки «Голос ассистента» на экране «Голосовой ввод».
- [ ] §6 сквозные (динамические списки, прогрессивное раскрытие, пресеты).
- [ ] §11 схема `prefs.json` (`llm.*`, `tts.*`) + миграция. NB: EVS хранит
  настройки через `shared_preferences` плоскими ключами (не вложенный JSON из
  §11) — при реализации либо маппить в плоские ключи, либо не ломать текущий
  персист. Уже сделанное (`llm*`, `searchModel`, `chatModel`) — плоскими ключами.
- [ ] §12 edge-cases (частично закрыто §3.1: unreachable / no models / missing model).
- [ ] §14 «Телефоны и удалённый ввод» (HTTP+WS слушатель, QR-сопряжение, токены).

### ТЗ «Новые функции» (`EVS_new_features_TZ.md`)
- [ ] Ф1 ИИ-подбор голосовых команд. Скан приложений (UWP/AUMID) **уже есть** —
  переиспользовать, не переделывать. Нужно: UserAssist-частота, промпт в локальную
  Ollama (только имена, пути НЕ слать — модель их галлюцинирует), защитный JSON-
  парсинг, экран подтверждения, разрешение коллизий, фолбэк без модели.
- [ ] Ф2 Громкость приложения голосом («громкость на 30»). **Ничего нет**, `pycaw`
  даже не в `requirements.txt`. Делать как общий механизм «команда с параметром {N}».

## Ещё не проверено вживую (нужно железо пользователя)
GPU/CUDA (RTX 3060), VRAM-триггер игрового режима, 2 физических микрофона +
арбитраж, NVIDIA Broadcast. Логика покрыта юнит-тестами; проверить на ПК.
