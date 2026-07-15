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

## БЛОКЕР релиза: ключ подписи

`dsa_pub.pem` вшит в exe (`windows/runner/Runner.rc:68`, `DSAPub DSAPEM`), и
WinSparkle проверяет им подпись каждого обновления. `dsa_priv.pem` git-ignored и
остался на старой машине.

- **Нужно:** скопировать `dsa_priv.pem` со старой машины в `test1\dsa_priv.pem`.
- **Нельзя** сгенерировать новый: у всех установленных копий EVS зашит старый
  публичный ключ → они отвергнут обновление и станут неапгрейдимыми навсегда.
  Смена ключа возможна только с раздачей новой сборки вне апдейтера.

## Что сделано (всё закоммичено и запушено)

| Коммит | Содержание |
|---|---|
| `338a94b` | EVS 2.0.0 — большой патч из 3 ТЗ (релиз `desktop-v2.0.0`, компонент сайдкара v8) |
| `18c166b` | Фиксы 2.0.1: сайдкар onedir (onnxruntime), whisper-retry, masonry, бейдж движка, движок/модель UX, `fadeEdges` у волны |
| `306597e` | Волна перекрашивается по состоянию ассистента (`accent` в пейнтерах + `reactive` у `EvsWaveViz`) |
| `6342a31` | Раскладка настроек 1/2/3 колонки по ширине (ТЗ «Настройки» §5) |

`flutter analyze` — чисто.

## Баги 2.0.0 и их причины (для контекста)

1. **GigaAM/денойз/Piper падают** (`ORT Version 1.17.1`, «light denoise model not
   found»). Причина: onefile-сборка сваливает все DLL в одну папку, а sherpa-onnx и
   faster-whisper несут РАЗНЫЕ `onnxruntime.dll` → грузится не тот. Фикс (в `18c166b`):
   `--onedir + zip` в `build_exe.ps1`. **Сайдкар v9 ещё НЕ пересобран и не залит.**
2. **Whisper «Unable to open file 'model.bin'»** — гонка прогрева с докачкой.
   Фикс (в `18c166b`): ретрай в `_ensure_model` (4×2с).
3-6. Раскладка / бейдж / движок-модель / края волны — исправлены (см. таблицу выше).

## Что осталось для выпуска 2.0.1

1. **Пересобрать сайдкар v9** (venv уже готов):
   ```powershell
   cd test1\sidecar
   .\build_exe.ps1 -ComponentVersion 9
   ```
   Проверить фрозен-zip: распаковать, запустить `evs_sidecar.exe`, убедиться что в
   `ready.capabilities` piper/gigaam создают сессии (нет ORT-ошибки). Затем:
   ```powershell
   gh release upload desktop-components dist\evs_sidecar.zip --repo kekw2077/mirai --clobber
   gh release delete-asset desktop-components evs_sidecar.exe --repo kekw2077/mirai --yes
   ```
   Закоммитить обновлённый `test1/dist/components.json` (sidecar → archive v9).
   Сейчас в нём ещё v8 / onefile `evs_sidecar.exe`.
2. **Выпустить приложение 2.0.1** (нужен `dsa_priv.pem`):
   - `pubspec.yaml`: `2.0.0+19` → `2.0.1+20` (сейчас ещё 2.0.0+19).
   - Запись в `kChangelog` (main.dart) + `<item>` в `test1/dist/appcast.xml`
     (сейчас последний item — 2.0.0).
   - `flutter build windows --release` (сверить FileVersion exe == 2.0.1).
   - `& "C:\Users\ART\AppData\Local\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=2.0.1 dist\installer.iss`
     → `dist\out\EVS-Setup-2.0.1.exe`.
   - `.\dist\sign_update.ps1 .\dist\out\EVS-Setup-2.0.1.exe` → length + sha256 +
     dsaSignature → вписать в новый `<item>` appcast.
   - `gh release create desktop-v2.0.1 dist\out\EVS-Setup-2.0.1.exe --repo kekw2077/mirai --title "EVS 2.0.1" --notes "..."`.
   - Закоммитить pubspec + main.dart + appcast + components.json, запушить.

## Два ТЗ — новая работа (НЕ входит в 2.0.1)

Лежат в корне репозитория, **untracked** (в git их нет): `EVS_settings_TZ.md`,
`EVS_new_features_TZ.md`. Это масштаб минорного релиза (2.1.0), не хотфикса.

### ТЗ «Настройки» (`EVS_settings_TZ.md`) — идём по приоритетам §13
- [x] **§5 Раскладка** — masonry 1/2/3 колонки (`6342a31`).
- [ ] **§3.1 «Модель и инференс»** ← *следующий по приоритету*. Переиспользовать:
  `AppState.serverUrl`/`apiKey`/`models`/`selectedModel`, геттер `baseUrl`,
  `/api/tags` (уже дёргается: проверка связи ~main.dart:3930, обновление списка
  ~5649), секция `_modelCards` (~15355). Не хватает: модели **по режиму**
  (поиск/чат, дефолты `qwen3-search`/`qwen3-chat`), параметры инференса
  (`num_ctx`/`num_predict`/`temperature`/`keep_alive`) под «Дополнительно» и их
  проброс в `options` запроса (пустое поле → параметр НЕ слать). В коде сейчас
  0 упоминаний `num_ctx`/`keep_alive`.
- [ ] §3.2 «Озвучка» — Piper/CosyVoice, интерпретатор (правила/`qwen3-interp`),
  клонирование, скорость/эмоция. Блокер: сервер CosyVoice не развёрнут → по ТЗ
  показывать движок недоступным.
- [ ] §6 сквозные (динамические списки, прогрессивное раскрытие, пресеты).
- [ ] §11 схема `prefs.json` (`llm.*`, `tts.*`) + миграция.
- [ ] §12 edge-cases.
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
