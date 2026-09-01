# Как переносить

## Что уже сделано

Перенесено всё: токены, оболочка, оба фона, сетка точек, восемь экранов,
плавающий виджет, семь стилей визуализации, анимации и хранение настроек.
Осталось подключить настоящие данные вместо демонстрационных.

Порядок слоёв в `app_shell.dart` менять нельзя: фон → сетка точек → интерфейс.
Фон и сетка не перехватывают клики, весь UI лежит поверх.

## Соответствие CSS → Flutter

| В прототипе | В Dart |
|---|---|
| `var(--card)` + `backdrop-filter: blur(var(--blur))` | `GlassPanel` (ClipRRect + BackdropFilter) |
| `border: 1px solid var(--stroke)` | `Border.all(color: p.stroke)` |
| `border-radius: 999px` | `BorderRadius.circular(EvsRadius.chip)` |
| `linear-gradient(140deg, a1, a2 55%, a3)` | `accent.badge` |
| `background-clip: text` | `GradientText` (ShaderMask, BlendMode.srcIn) |
| `box-shadow: var(--sh)` | `palette.shadow` |
| `transition: .18s` | `AnimatedContainer(duration: EvsMotion.hover)` |
| `@keyframes breathe` (hue-rotate) | `AnimationController` + `ColorFilter.matrix`, либо просто опустить |
| `display: flex; gap: 12px` | `Row/Column` + `SizedBox`, или `Wrap(spacing: 12)` |
| `canvas` сетки точек | `DotGrid` (CustomPainter + Ticker) |
| WebGL-фон | `shaders/aurora.frag` + `FragmentProgram.fromAsset` |

## Где будет больно

**Стекло.** `BackdropFilter` в Flutter дорогой, особенно если панелей много и
они вложены друг в друга. Правила: один `BackdropFilter` на панель, не
вкладывать их, на слабых машинах предлагать режим «Плотное» — он не создаёт
фильтр вовсе. Сигма в Flutter примерно вдвое меньше CSS-радиуса, поэтому в
`GlassPanel` стоит `blur / 2`.

**Шейдер.** `FragmentProgram.fromAsset` работает на Impeller (Flutter 3.10+).
На вебе шейдеры собираются иначе и медленнее — там разумно оставить режим
«Аврора» с размытыми пятнами. Порядок uniform-ов в `_ShaderPainter` жёстко
привязан к порядку объявления в `.frag`: если добавите uniform в середину,
поправьте индексы.

**Сетка точек.** При шаге 15px на экране 1920×1080 получается около 9 тысяч
точек. Режим `push` пересчитывает физику каждый кадр — это нормально, но
`setState` на каждом тике перестраивает дерево. Если начнёт тормозить,
переведите отрисовку на `CustomPainter` с `repaint: Listenable` вместо
`setState`. Режим `glow` уже группирует точки по уровням яркости —
12 вызовов кисти вместо 9 тысяч.

**Шрифты.** Figtree и JetBrains Mono. Проще всего `google_fonts`, но для
десктопа без интернета лучше положить `.ttf` в `assets/fonts` — заготовка
в `pubspec.snippet.yaml`. Веса нужны: 400, 500, 600, 700, 800.

**Отрицательный трекинг.** В CSS `letter-spacing: -.045em` относительный, в
Flutter — абсолютный, в логических пикселях. В `EvsType` он уже пересчитан
под конкретные размеры; при смене размера шрифта пересчитывайте:
`letterSpacing = em × fontSize`.

**Прокрутка.** У прототипа тонкий скроллбар 7px. Во Flutter это
`ScrollbarTheme` с `thickness: 7` и `radius: Radius.circular(8)`.

## Про анимации

`anim_accent.dart` даёт три вещи: `BreatheFilter` (поворот оттенка у
поддерева), `FlowingGradientText` (текучий градиент по тексту) и
`PulseScale`. Все три смотрят на `EvsThemeData.anim` и при `EvsAnim.off`
не создают контроллер — это и есть режим «Экономия» из настроек.

Поворот оттенка стоит один `ColorFilter` на слой. Не вкладывайте
`BreatheFilter` друг в друга: фильтры перемножаются, а растеризация
происходит на каждом уровне.

## Про плавающий виджет

Окно создаётся в `main_widget.dart` через `window_manager`: без рамки, без
тени, поверх всех, мимо панели задач. Обмен состоянием между главным окном и
окном виджета — через `desktop_multi_window` или свой сокет; в макете
состояние просто передаётся параметром.

В `main_example.dart` виджет для наглядности показан внутри главного окна,
в правом нижнем углу. В настоящем приложении эту вставку надо убрать.

## Чего в прототипе нет и что надо решить самим

- Реальная работа с микрофоном, моделью, генерацией картинок.
- Системный трей, автозапуск, глобальная горячая клавиша — на десктопе это
  `tray_manager`, `launch_at_startup`, `hotkey_manager`.

## Если что-то непонятно

Прототип — источник правды по любому вопросу об оформлении. Все значения в нём
заданы прямо в разметке, искать по названию элемента проще всего поиском по
файлу `design/EVS Interface.dc.html`.
