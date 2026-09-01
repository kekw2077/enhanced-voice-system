part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — четвёртая оболочка (handoff/design)
   --------------------------------------------------------------------------
   Стекло, сетка точек под курсором, фон-аврора и акцент из трёх цветов.
   Эталон — handoff/design/EVS Interface.dc.html; токены — handoff/tokens.

   Порядок слоёв менять нельзя: фон → сетка точек → интерфейс. Первые два
   лежат под IgnorePointer, весь UI кликается поверх них.

   Три вещи, которые здесь сделаны не так, как в макете, и почему:

   • Поверхность. У прототипа `--card` полупрозрачная, и панель = цвет +
     backdrop-filter. В приложении слот `card` уходит ещё и в диалоги, меню и
     подсказки (см. _buildTheme), поэтому непрозрачным он обязан остаться.
     Стекло живёт отдельно — в [PrismPanel], который читает prismGlass.

   • Движение. Прототип крутит фон и сетку вечно. Здесь оба слоя подчиняются
     MotionPolicy: фон — как украшение (ambient, по умолчанию только пока
     ассистент активен), сетка — пока курсор над окном и режим не «Экономия».
     Иначе девять тысяч точек считали бы физику 60 раз в секунду в пустом окне.

   • Навигация. В рейке ровно семь пунктов — столько же, сколько в макете, а не
     весь список evsAppActions, из которого строят меню три другие оболочки.
     Ничего при этом не потеряно: остальные точки входа лежат там, куда их
     кладёт сам макет — архив кнопкой под списком диалогов, журнал карточкой
     на «Модулях», модели внутри настроек. Заводя новую функцию, ищите ей
     такое же место, а не восьмую строку в рейке.
   ========================================================================== */

// --------------------------------------------------------------------------
// СТЕКЛО
// --------------------------------------------------------------------------

/// Заливка панели под выбранный режим стекла. Значения — из tokens.css
/// ([data-glass] × [data-theme]).
Color _prismCardFill(BuildContext c) {
  final dark = _pal(c).brightness == Brightness.dark;
  return switch (c.read<AppState>().prismGlass) {
    PrismGlass.off || PrismGlass.glass =>
      dark ? const Color(0x0BFFFFFF) : const Color(0x70FFFFFF),
    PrismGlass.frost =>
      dark ? const Color(0xA8161922) : const Color(0xC2FFFFFF),
    PrismGlass.solid =>
      dark ? const Color(0xF20E1016) : const Color(0xFFFFFFFF),
  };
}

/// Радиус размытия под панелью. `off` и `solid` дают ноль — и тогда
/// [PrismPanel] не создаёт BackdropFilter вовсе. Это и есть режим для слабых
/// видеокарт: фильтр стоит дорого не тем, что размывает, а тем, что заставляет
/// движок отдельно растеризовать всё, что под ним.
///
/// Сигма вдвое меньше CSS-радиуса: у Flutter и у браузера разные единицы, 26px
/// блюра в прототипе — это sigma 13 здесь.
double _prismBlur(BuildContext c) => switch (c.read<AppState>().prismGlass) {
      PrismGlass.off => 0,
      PrismGlass.glass => 13,
      PrismGlass.frost => 8,
      PrismGlass.solid => 0,
    };

/// Стеклянная панель. Замена CSS-паре
/// `background: var(--card); backdrop-filter: blur(var(--blur))`.
///
/// Не вкладывайте панели друг в друга: каждый BackdropFilter — это отдельный
/// проход растеризации по всему, что под ним, и вложенные они перемножаются.
class PrismPanel extends StatelessWidget {
  const PrismPanel({
    super.key,
    required this.child,
    this.radius,
    this.padding = const EdgeInsets.all(16),
    this.border = true,
    this.shadow = false,
    this.color,
  });

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry padding;
  final bool border;
  final bool shadow;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? _skin(context).radiusCard);
    final blur = _prismBlur(context);

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? _prismCardFill(context),
        borderRadius: r,
        border: border ? Border.all(color: _stroke(context)) : null,
      ),
      child: child,
    );

    if (blur > 0) {
      content = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow ? _prismShadow(context) : null,
      ),
      child: ClipRRect(borderRadius: r, child: content),
    );
  }
}

// Тень панели. В макете это `--sh: 0 24px 64px rgba(0,0,0,.5)`, и там она
// незаметна: панели лежат на почти чёрной странице, а аврора светит далеко
// внизу. Здесь аврора идёт прямо под ними, и тень в половину чёрного при
// размытии в 64 точки становилась ТЁМНЫМ ПРЯМОУГОЛЬНИКОМ вокруг каждой
// карточки — на светлом фоне видно каждый её пиксель. Оставлена вдвое слабее
// и чуть короче: на тёмных местах она по-прежнему даёт глубину, на светлых
// перестала рисовать коробку.
List<BoxShadow> _prismShadow(BuildContext c) =>
    _pal(c).brightness == Brightness.dark
        ? const [
            BoxShadow(
                color: Color(0x47000000), offset: Offset(0, 16), blurRadius: 40)
          ]
        : const [
            BoxShadow(
                color: Color(0x29192D55),
                offset: Offset(0, 20),
                blurRadius: 44),
            BoxShadow(
                color: Color(0x12192D55), offset: Offset(0, 2), blurRadius: 6),
          ];

/// Что именно оживляет [PrismAnimated] — от роли зависит период. Значения
/// взяты из макета: `--anmA` у фона, `--anmT` у заголовков, `--anmL` у марки.
enum PrismAnimRole { backdrop, title }

/// Оживляет акцентный градиент поддерева выбранной анимацией
/// (`prismAnim`: дыхание, перелив, пульс или ничего).
///
/// Один фильтр на слой. Вкладывать их друг в друга нельзя — фильтры
/// перемножаются, а растеризация идёт на каждом уровне.
class PrismAnimated extends StatefulWidget {
  const PrismAnimated({
    super.key,
    required this.child,
    required this.role,
    // Гейт переднего плана, а не окружения. Под гейтом окружения «Анимация
    // градиента» в режиме «Умные» (он по умолчанию) стояла всё время, пока
    // ассистент молчит, — то есть почти всегда, — и настройка выглядела
    // сломанной: её переключаешь, а на экране ничего. Это не украшение фона,
    // а выбранный вид оформления; гасит его только «Экономная».
    this.gate = MotionGate.foreground,
  });

  final Widget child;
  final PrismAnimRole role;
  final MotionGate gate;

  @override
  State<PrismAnimated> createState() => _PrismAnimatedState();
}

class _PrismAnimatedState extends State<PrismAnimated>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  AmbientMotion? _gate;
  PrismAnim? _mode;
  PrismAnimSpeed? _speed;

  Duration _period(PrismAnim m) => switch (widget.role) {
        // Фон: breathe 17s · hueflow 24s · pulsebr 6s.
        PrismAnimRole.backdrop => switch (m) {
            PrismAnim.breathe => const Duration(seconds: 17),
            PrismAnim.flow => const Duration(seconds: 24),
            PrismAnim.pulse => const Duration(seconds: 6),
            PrismAnim.off => const Duration(seconds: 1),
          },
        // Заголовки: breathesoft 13s · flowpos 9s · pulsebr 4.6s.
        PrismAnimRole.title => switch (m) {
            PrismAnim.breathe => const Duration(seconds: 13),
            PrismAnim.flow => const Duration(seconds: 9),
            PrismAnim.pulse => const Duration(milliseconds: 4600),
            PrismAnim.off => const Duration(seconds: 1),
          },
      };

  void _sync(PrismAnim m, PrismAnimSpeed sp) {
    if (_mode == m && _speed == sp) return;
    _mode = m;
    _speed = sp;
    _gate?.dispose();
    _c?.dispose();
    _gate = null;
    _c = null;
    // «Без анимации» не создаёт контроллер вовсе — это и есть его смысл.
    if (m == PrismAnim.off) return;
    // Скорость делит период: множитель 2.5 означает «в два с половиной раза
    // быстрее макета», а не «другая анимация».
    final ms = (_period(m).inMilliseconds / prismAnimFactor(sp)).round();
    _c = AnimationController(
        vsync: this, duration: Duration(milliseconds: ms));
    _gate = AmbientMotion(_c!, gate: widget.gate);
  }

  @override
  void dispose() {
    _gate?.dispose();
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, PrismAnim>((a) => a.prismAnim);
    final speed =
        context.select<AppState, PrismAnimSpeed>((a) => a.prismAnimSpeed);
    _sync(mode, speed);
    final c = _c;
    if (c == null) return widget.child;
    return AnimatedBuilder(
      animation: c,
      builder: (context, child) => ColorFiltered(
        colorFilter: prismAnimFilter(mode, c.value),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Кадр CSS-анимации: доля периода, поворот оттенка, насыщенность, яркость.
typedef _PrismFrame = (double at, double hue, double sat, double bri);

/// Фильтр анимации в фазе [t] (0…1) — ключевые кадры макета один в один.
///
/// Раньше здесь стоял синус по одному свойству, и настройка почти ничего не
/// меняла на глаз: «Дыхание» и «Перелив» отличались только размахом поворота
/// оттенка, а насыщенность — то, из-за чего в макете фон и кажется живым, — не
/// трогалась вовсе. Теперь каждый вариант ведёт себя как своя `@keyframes`:
/// у «Дыхания» кадры несимметричны (+13° и ярче на трети периода, −11° и
/// глуше на двух третях), «Перелив» линейно водит оттенок вдвое шире при
/// постоянно поднятой насыщенности, «Пульс» прибавляет к яркости насыщенность.
ColorFilter prismAnimFilter(PrismAnim mode, double t) => switch (mode) {
      // @keyframes breathe — saturate/hue-rotate, ease-in-out между кадрами.
      PrismAnim.breathe => _prismFrames(t, const [
          (0.00, 0.0, 1.00, 1.00),
          (0.33, 13.0, 1.24, 1.00),
          (0.66, -11.0, 0.90, 1.00),
          (1.00, 0.0, 1.00, 1.00),
        ], ease: true),
      // @keyframes hueflow — linear, насыщенность держится на 1.18.
      PrismAnim.flow => _prismFrames(t, const [
          (0.00, -28.0, 1.18, 1.00),
          (0.50, 28.0, 1.18, 1.00),
          (1.00, -28.0, 1.18, 1.00),
        ]),
      // @keyframes pulsebr — brightness 1→1.2 вместе с saturate 1→1.34.
      PrismAnim.pulse => _prismFrames(t, const [
          (0.00, 0.0, 1.00, 1.00),
          (0.50, 0.0, 1.34, 1.20),
          (1.00, 0.0, 1.00, 1.00),
        ], ease: true),
      PrismAnim.off => const ColorFilter.matrix(<double>[
          1, 0, 0, 0, 0,
          0, 1, 0, 0, 0,
          0, 0, 1, 0, 0,
          0, 0, 0, 1, 0,
        ]),
    };

/// Значение кадров [frames] в фазе [t], собранное в одну матрицу. [ease] —
/// `animation-timing-function: ease-in-out` между соседними кадрами; без него
/// переход линейный, как у `hueflow`.
ColorFilter _prismFrames(double t, List<_PrismFrame> frames,
    {bool ease = false}) {
  var i = 0;
  while (i < frames.length - 2 && t > frames[i + 1].$1) {
    i++;
  }
  final a = frames[i], b = frames[i + 1];
  final span = b.$1 - a.$1;
  var k = span <= 0 ? 0.0 : ((t - a.$1) / span).clamp(0.0, 1.0);
  if (ease) k = Curves.easeInOut.transform(k);
  double mix(double x, double y) => x + (y - x) * k;
  // Порядок как в CSS: яркость, затем насыщенность, затем поворот оттенка.
  return ColorFilter.matrix(prismMatMul(
    prismHueMatrix(mix(a.$2, b.$2)),
    prismMatMul(
      prismSaturateMatrix(mix(a.$3, b.$3)),
      prismBrightnessMatrix(mix(a.$4, b.$4)),
    ),
  ));
}

/// Текст, залитый акцентным градиентом (CSS `background-clip: text`).
///
/// Живёт по той же настройке, что и фон: «Перелив» двигает саму заливку
/// (`flowpos` в макете), «Дыхание» и «Пульс» — красят её фильтром.
class PrismGradientText extends StatefulWidget {
  const PrismGradientText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  State<PrismGradientText> createState() => _PrismGradientTextState();
}

class _PrismGradientTextState extends State<PrismGradientText>
    with SingleTickerProviderStateMixin {
  // `flowpos 9s` из макета. Длительность правится на лету: «Скорость» делит
  // её, и заливка заголовка идёт вровень с фоном, а не своим ходом.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );
  late final AmbientMotion _gate =
      AmbientMotion(_c, gate: MotionGate.foreground);

  @override
  void dispose() {
    _gate.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, PrismAnim>((a) => a.prismAnim);
    final speed =
        context.select<AppState, PrismAnimSpeed>((a) => a.prismAnimSpeed);
    final want = Duration(
        milliseconds: (9000 / prismAnimFactor(speed)).round());
    if (_c.duration != want) {
      _c.duration = want;
      if (_c.isAnimating) _c.repeat();
    }
    // Ореол СНИМАЕТСЯ: заголовок закрашивается градиентом через srcIn, а тот
    // красит всё, что нарисовала надпись, — вместе с тенью. Получалась не
    // обводка, а градиентная клякса вокруг букв. Ореол вернём отдельным слоем
    // ПОД маской, где градиент до него не дотянется.
    final text = Text(
      widget.text,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      style: widget.style.copyWith(color: Colors.white, shadows: const []),
    );

    if (mode == PrismAnim.flow) {
      // Заливка шириной 220% едет вбок и возвращается — цвета перетекают,
      // а буквы стоят на месте.
      return _haloed(
        AnimatedBuilder(
          animation: _c,
          builder: (context, child) => ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (rect) {
              final w = rect.width * 2.2;
              final dx = rect.left - (_c.value * w * 0.55);
              return _ramp(context).sweep.createShader(
                  Rect.fromLTWH(dx, rect.top, w, rect.height),
                  textDirection: TextDirection.ltr);
            },
            child: child,
          ),
          child: text,
        ),
        context,
      );
    }

    final plain = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => _ramp(context).sweep.createShader(rect),
      child: text,
    );
    return _haloed(
        mode == PrismAnim.off
            ? plain
            : PrismAnimated(role: PrismAnimRole.title, child: plain),
        context);
  }

  /// Обводка под градиентной надписью. Прозрачная копия текста рисует ОДНИ
  /// тени — буквы её не закрывают, а маска сверху их не трогает.
  Widget _haloed(Widget masked, BuildContext context) => Stack(
        children: [
          Text(
            widget.text,
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            style: widget.style.copyWith(
                color: Colors.transparent, shadows: prismHalo(context)),
          ),
          masked,
        ],
      );
}

// --------------------------------------------------------------------------
// ФОН
// --------------------------------------------------------------------------

/// Фоновый слой: пятна, шейдер или ничего. Оба движущихся варианта — фоновое
/// украшение, поэтому идут под гейтом ambient и в «Экономии» не создаются.
class _PrismBackdrop extends StatelessWidget {
  const _PrismBackdrop();

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, PrismBackground>(
      (a) => a.prismBackground,
    );
    return switch (mode) {
      PrismBackground.off => const SizedBox.expand(),
      PrismBackground.spots =>
        const PrismAnimated(role: PrismAnimRole.backdrop, child: _PrismSpots()),
      // Шейдер БЕЗ «Анимации градиента» — так в макете: `--anmA` висит там
      // только на авроре, у холста шейдера её нет вовсе. И правильно: шейдер
      // движется сам, у него собственное время в расчёте, и крутить оттенок
      // поверх значило бы гонять два движения друг через друга.
      //
      // Шейдер собирается асинхронно и только на Impeller; пока программа не
      // загрузилась (и если не загрузится вовсе) на экране те же пятна, а не
      // пустой фон.
      PrismBackground.shader => const _PrismShaderAurora(),
    };
  }
}

/// Прозрачность фона: на светлой теме пятна приглушены вдвое, иначе они
/// съедают контраст текста (tokens.css → --aurora-opacity).
double _prismBackdropOpacity(BuildContext c) =>
    _pal(c).brightness == Brightness.dark ? 0.9 : 0.5;

/// Аврора макета: три размытых пятна, свисающих за нижний край экрана.
///
/// Разметка перенесена число в число:
///
///     a1  left −14%   bottom −36%   72%×94%   blur 92px    dr1 24s
///     a2  right −12%  bottom −40%   76%×98%   blur 100px   dr2 29s
///     a3  left 28%    bottom −50%   50%×86%   blur 116px   dr1 34s назад
///                                             прозрачность .62
///
/// Главное здесь — ПОЛОЖЕНИЕ, и именно оно раньше было потеряно. Пятна
/// выкладывались через `Align`, а он отмеряет долю от СВОБОДНОГО места; при
/// высоте пятна в 94% свободного места почти нет, поэтому все три вставали
/// посреди окна и сливались в один ровный налёт без низа и верха. В макете они
/// висят ЗА нижним краем: видна только верхушка свечения, поднимающаяся со
/// дна, — отсюда и вся картинка.
///
/// Одно сознательное упрощение: размытие общее (sigma 50) вместо трёх своих
/// (92/100/116 CSS-точек = sigma 46/50/58). Три полноэкранных размытия на
/// кадр — это втрое дороже, а разброс в шесть единиц сигмы под радиальным
/// затуханием не виден.
class _PrismSpots extends StatefulWidget {
  const _PrismSpots();
  @override
  State<_PrismSpots> createState() => _PrismSpotsState();
}

class _PrismSpotsState extends State<_PrismSpots>
    with SingleTickerProviderStateMixin {
  // Один тикер на три разных периода. Его длина — общее кратное 24, 29 и 34
  // секунд, поэтому каждое пятно проходит целое число своих кругов и на стыке
  // не дёргается. Гейт прежний, окружения: это полноэкранный слой под
  // размытием, он честно дорогой, и «Экономия» должна его усмирять. Сама
  // «Анимация градиента» при этом идёт всегда — она снаружи, в PrismAnimated.
  static const _cycle = 11832; // 24·493 = 29·408 = 34·348

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: _cycle),
  );
  late final AmbientMotion _ambient = AmbientMotion(_c);

  @override
  void dispose() {
    _ambient.dispose();
    _c.dispose();
    super.dispose();
  }

  /// Фаза пятна с периодом [period] секунд.
  double _phase(double period) => (_c.value * _cycle / period) % 1.0;

  /// `ease-in-out` между кадрами 0 → 50% → 100%, как в CSS: обе половины
  /// сглаживаются отдельно, поэтому в середине нет излома.
  double _swing(double p) =>
      Curves.easeInOut.transform(p < 0.5 ? p * 2 : (1 - p) * 2);

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: Opacity(
          opacity: _prismBackdropOpacity(context),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth, h = c.maxHeight;
                return AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    // dr1: сдвиг (+6%, −6%) и рост до 1.16.
                    final k1 = _swing(_phase(24));
                    // dr2: сдвиг (−7%, +5%), масштаб 1.1 → 1.
                    final k2 = _swing(_phase(29));
                    // dr1 задом наперёд — то же движение, встречной фазой.
                    final k3 = _swing(1 - _phase(34));
                    return Stack(
                      children: [
                        Positioned(
                          left: -0.14 * w,
                          bottom: -0.36 * h,
                          width: 0.72 * w,
                          height: 0.94 * h,
                          child: _spot(r.a1,
                              dx: 0.06 * k1, dy: -0.06 * k1, scale: 1 + 0.16 * k1),
                        ),
                        Positioned(
                          right: -0.12 * w,
                          bottom: -0.40 * h,
                          width: 0.76 * w,
                          height: 0.98 * h,
                          child: _spot(r.a2,
                              dx: -0.07 * k2, dy: 0.05 * k2, scale: 1.1 - 0.1 * k2),
                        ),
                        Positioned(
                          left: 0.28 * w,
                          bottom: -0.50 * h,
                          width: 0.50 * w,
                          height: 0.86 * h,
                          child: _spot(r.a3,
                              dx: 0.06 * k3,
                              dy: -0.06 * k3,
                              scale: 1 + 0.16 * k3,
                              opacity: 0.62),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Одно пятно: круг с радиальной заливкой, гаснущей к 62% радиуса. Сдвиг —
  /// доля СВОЕГО размера, как проценты в CSS-трансформации, масштаб — от
  /// центра.
  Widget _spot(
    Color c, {
    required double dx,
    required double dy,
    required double scale,
    double opacity = 1,
  }) {
    return Opacity(
      opacity: opacity,
      child: FractionallySizedBox(
        widthFactor: 1,
        heightFactor: 1,
        child: LayoutBuilder(
          builder: (context, b) => Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..translateByDouble(dx * b.maxWidth, dy * b.maxHeight, 0, 1)
              ..scaleByDouble(scale, scale, 1, 1),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [c, c.withValues(alpha: 0)],
                  stops: const [0, 0.62],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Шейдерная аврора: shaders/prism_aurora.frag.
///
/// Порядок uniform-ов жёстко привязан к порядку объявления в .frag —
/// setFloat(0..11) идёт ровно так, как там написано. Добавите uniform в
/// середину — поправьте индексы здесь.
class _PrismShaderAurora extends StatefulWidget {
  const _PrismShaderAurora();
  @override
  State<_PrismShaderAurora> createState() => _PrismShaderAuroraState();
}

class _PrismShaderAuroraState extends State<_PrismShaderAurora>
    with SingleTickerProviderStateMixin {
  FragmentShader? _shader;
  // Время шейдера держится в ValueNotifier, а не в setState: перерисовать надо
  // один CustomPaint, а не поддерево. Тикер поднимается только когда гейт
  // разрешает движение — в «Экономии» шейдер стоит на кадре, а не крутится.
  final ValueNotifier<double> _time = ValueNotifier(0);
  late final Ticker _ticker = createTicker(_tick);
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Гейт ПЕРЕДНЕГО плана, а не окружения. На «Умных» окружение гаснет, как
    // только ассистент затихает, — и выбранный пользователем фон замирал сам
    // собой, а через минуту так же сам собой оживал. Со стороны это выглядит
    // поломкой, а не экономией: аврора здесь не украшение поверх экрана, это
    // и есть экран. Гасит её «Экономия» и свёрнутое окно — как «Ноктюрну»
    // кольцо и знак Genesis на странице «О программе».
    MotionPolicy.foreground.addListener(_syncTicker);
  }

  Future<void> _load() async {
    try {
      final program =
          await FragmentProgram.fromAsset('shaders/prism_aurora.frag');
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
      _syncTicker();
    } catch (_) {
      // Шейдеры собираются не везде (веб, старый бэкенд): молча остаёмся на
      // пятнах — фон не та вещь, ради которой стоит показывать ошибку.
      if (mounted) setState(() => _failed = true);
    }
  }

  void _syncTicker() {
    final want = _shader != null && MotionPolicy.foreground.value;
    if (want && !_ticker.isTicking) {
      _ticker.start();
    } else if (!want && _ticker.isTicking) {
      _ticker.stop();
    }
  }

  void _tick(Duration d) => _time.value = d.inMilliseconds / 1000;

  @override
  void dispose() {
    MotionPolicy.foreground.removeListener(_syncTicker);
    _ticker.dispose();
    _time.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _shader;
    if (s == null || _failed) return const _PrismSpots();
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRect(
          child: Opacity(
            opacity: _prismShaderOpacity(context),
            // Порядок обвязки — как в прототипе: сначала холст растянут на
            // 116% (`inset:-8%`), потом `filter: blur(8px) saturate(1.12)`.
            // Оболочка снаружи, содержимое внутри, поэтому читается снизу.
            child: ColorFiltered(
              colorFilter: _kPrismAuroraSaturate,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: Transform.scale(
                  scale: 1.16,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _PrismShaderPainter(
                      shader: s,
                      time: _time,
                      pal: _auroraPal(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `saturate(1.12)` из прототипа матрицей. Коэффициенты яркости — те, что
/// подставляет сам CSS-фильтр (0.213 / 0.715 / 0.072), иначе оттенки поедут.
const ColorFilter _kPrismAuroraSaturate = ColorFilter.matrix(<double>[
  1.09444, -0.08580, -0.00864, 0, 0, //
  -0.02556, 1.03420, -0.00864, 0, 0, //
  -0.02556, -0.08580, 1.11136, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Шейдер в прототипе — сам фон страницы, во всю силу, и глушить его нечем и
/// незачем. Здесь так же на тёмной теме. На светлой аврора остаётся, но вполсилы:
/// по фону идёт тёмный текст, и полная заливка съела бы его.
double _prismShaderOpacity(BuildContext c) =>
    _pal(c).brightness == Brightness.dark ? 1 : 0.5;

class _PrismShaderPainter extends CustomPainter {
  _PrismShaderPainter({
    required this.shader,
    required this.time,
    required this.pal,
  }) : super(repaint: time);

  final FragmentShader shader;
  final ValueNotifier<double> time;
  final PrismRamp pal;

  @override
  void paint(Canvas canvas, Size size) {
    void rgb(int at, Color c) {
      shader.setFloat(at, c.r);
      shader.setFloat(at + 1, c.g);
      shader.setFloat(at + 2, c.b);
    }

    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time.value);
    rgb(3, pal.a1);
    rgb(6, pal.a2);
    rgb(9, pal.a3);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_PrismShaderPainter old) =>
      old.shader != shader || old.pal != pal;
}

// --------------------------------------------------------------------------
// СЕТКА ТОЧЕК
// --------------------------------------------------------------------------

/// Где сейчас курсор в окне, в глобальных координатах, или null — курсор
/// вышел за окно.
///
/// Сетка точек лежит ПОД интерфейсом, и её собственный MouseRegion видел
/// курсор только в просветах между панелями: рейка, шапка и карточки
/// непрозрачны для проверки попадания и забирали событие себе. Поэтому
/// координаты собирает отдельный слой ПОВЕРХ всего — прозрачный для нажатий
/// (translucent), то есть ничего не перехватывающий, — а сетка их читает.
final ValueNotifier<Offset?> prismPointer = ValueNotifier<Offset?>(null);

/// Прозрачный слой поверх интерфейса: следит за курсором и за нажатиями.
/// Кладётся последним в стопку оболочки. Он `translucent` — сам в проверке
/// попадания участвует, но её не съедает: и наведение, и нажатие доходят до
/// интерфейса под ним, кнопки работают как ни в чём не бывало.
class PrismPointerWatcher extends StatelessWidget {
  const PrismPointerWatcher({super.key});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) =>
          prismTap.value = (prismTap.value.$1 + 1, e.position),
      child: MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onHover: (e) => prismPointer.value = e.position,
        onExit: (_) => prismPointer.value = null,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Последнее нажатие в окне: номер по порядку и место. Номер нужен, чтобы два
/// нажатия подряд в одну точку считались двумя событиями, а не одним.
final ValueNotifier<(int, Offset)> prismTap =
    ValueNotifier<(int, Offset)>((0, Offset.zero));

/// Волна, расходящаяся кольцом от точки. В прототипе их две породы: от
/// нажатия (живёт 1600 мс, идёт быстро и во всю силу) и от движения курсора
/// (900 мс, вдвое медленнее и слабее) — вторая и создаёт тот самый след,
/// который тянется за мышью.
class _PrismRipple {
  _PrismRipple(this.at, {required this.life, required this.speed, required this.amp});
  final Offset at;
  final double life, speed, amp;
  double t = 0;
  double get ring => t * speed;
  bool get dead => t >= life;
}

/// Сетка точек. Пересобрана по прототипу (`Dot Grid.dc.html`), потому что
/// прежняя расходилась с ним по существу, а не в мелочах:
///
/// • Смещение там МГНОВЕННОЕ и ограниченное: `dx = (v/d) * b * push`, где
///   push = 9 пикселей. Здесь была пружина с накоплением скорости — за
///   несколько кадров точка улетала на десятки пикселей, и «отталкивание»
///   получалось втрое сильнее задуманного.
/// • Режим влиял только на РИСОВАНИЕ: смещение считалось всегда, поэтому в
///   «Свечении» точки продолжали разбегаться.
/// • Волн не было вовсе. А в прототипе именно они делают всю работу: кольцо
///   от каждого нажатия и цепочка колец вслед за движением мыши.
/// • «Свечение» — это не только яркость. Точка РАСТЁТ: радиус `dot*(1+b*1.9)`,
///   почти втрое у самого курсора. Без роста режим и выглядел вяло.
///
/// Считается и рисуется в [CustomPainter] с `repaint: Listenable`, а не через
/// setState на каждом кадре: точек тысячи, и перестраивать ради них поддерево
/// шестьдесят раз в секунду незачем.
class _PrismDotGrid extends StatefulWidget {
  const _PrismDotGrid();

  // Шаг сетки. В прототипе 14; здесь 18 — при 14 на 1920x1080 выходит больше
  // десяти тысяч точек, и каждый кадр пришлось бы считать их все. На глаз
  // разница невелика, потому что рисунок держат не отдельные точки, а пятно
  // вокруг курсора.
  static const spacing = 18.0;

  // Радиус влияния курсора (`reach` в прототипе) и предел смещения (`push`).
  static const reach = 210.0;
  static const push = 9.0;

  // Размер точки в покое; у курсора она вырастает до `dot * 2.9`.
  static const dot = 1.1;

  @override
  State<_PrismDotGrid> createState() => _PrismDotGridState();
}

/// Сколько уровней яркости. Столько же, сколько в прототипе (LV = 14): точки
/// разбираются по уровням и каждый рисуется ОДНОЙ кистью, поэтому кадр стоит
/// четырнадцать вызовов вместо тысяч. Заодно уровень задаёт и размер точки —
/// в прототипе размер непрерывный, но при четырнадцати ступенях разницы не
/// видно, а рисование дешевеет на порядок.
const int _kPrismLevels = 14;

class _PrismDotGridState extends State<_PrismDotGrid>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<int> _frame = ValueNotifier(0);

  // Точки лежат «структурой массивов», а не списком объектов: на каждый кадр
  // здесь проход по всем тысячам, и три плоских массива обходятся заметно
  // дешевле, чем столько же ссылок на объекты.
  Float32List _px = Float32List(0), _py = Float32List(0);
  int _count = 0;
  Size _size = Size.zero;

  final List<_PrismRipple> _ripples = [];
  Offset _target = const Offset(-1e5, -1e5); // куда курсор пришёл
  Offset _at = const Offset(-1e5, -1e5); // где он «догоняется»
  Offset _lastEmit = Offset.zero;
  double _travel = 0; // сколько прошёл курсор с прошлой волны
  bool _hovering = false;
  int _lastTap = 0;
  Duration _prev = Duration.zero;
  double _phase = 0; // фаза фоновой ряби
  // Номер раскладки. Нужен, чтобы кадр, посчитанный НЕ тикером (первый показ,
  // смена размера, смена режима), тоже дошёл до холста: тикер в покое спит, и
  // без этого номера художник не увидел бы причины перерисоваться.
  int _revision = 0;

  // Готовые к рисованию уровни: смещённые точки, разложенные по яркости.
  late final List<List<Offset>> _levels =
      List.generate(_kPrismLevels, (_) => <Offset>[]);

  @override
  void initState() {
    super.initState();
    MotionPolicy.foreground.addListener(_syncTicker);
    MotionPolicy.ambient.addListener(_syncTicker);
    prismPointer.addListener(_onPointer);
    prismTap.addListener(_onTap);
  }

  @override
  void dispose() {
    MotionPolicy.foreground.removeListener(_syncTicker);
    MotionPolicy.ambient.removeListener(_syncTicker);
    prismPointer.removeListener(_onPointer);
    prismTap.removeListener(_onTap);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  RenderBox? get _box {
    final b = context.findRenderObject() as RenderBox?;
    return (b != null && b.hasSize) ? b : null;
  }

  /// Курсор приходит в координатах окна — переводим в свои.
  void _onPointer() {
    final g = prismPointer.value;
    if (g == null) {
      _hovering = false;
      _target = const Offset(-1e5, -1e5);
      _syncTicker();
      return;
    }
    final box = _box;
    if (box == null) return;
    final local = box.globalToLocal(g);
    if (!_hovering) {
      _at = local;
      _lastEmit = local;
      _travel = 0;
    }
    _target = local;
    _hovering = true;
    _syncTicker();
  }

  /// Нажатие пускает кольцо — в любом режиме, включая «Свечение»: там оно не
  /// толкает точки, а разгорается по ним. Именно этого в прежней сетке и не
  /// хватало.
  void _onTap() {
    final (seq, g) = prismTap.value;
    if (seq == _lastTap) return;
    _lastTap = seq;
    if (context.read<AppState>().prismDots == PrismDots.off) return;
    final box = _box;
    if (box == null) return;
    _emit(box.globalToLocal(g), life: 1600, speed: 0.62, amp: 1);
    _syncTicker();
  }

  void _emit(Offset at, {required double life, required double speed, required double amp}) {
    _ripples.add(_PrismRipple(at, life: life, speed: speed, amp: amp));
    // Больше дюжины колец разом на глаз уже не различить, а считать их нужно
    // для каждой точки — поэтому старые уходят.
    if (_ripples.length > 12) _ripples.removeAt(0);
  }

  /// Двигаться стоит, пока курсор в окне, пока живы волны или пока «Всегда»
  /// разрешает фоновую рябь. Иначе тикер спит и пустое окно не стоит ничего.
  void _syncTicker() {
    final want = MotionPolicy.foreground.value &&
        (_hovering || _ripples.isNotEmpty || MotionPolicy.ambient.value);
    if (want && !_ticker.isTicking) {
      _prev = Duration.zero;
      _ticker.start();
    } else if (!want && _ticker.isTicking) {
      _ticker.stop();
    }
  }

  void _build(Size s) {
    if (s == _size) return;
    _size = s;
    const sp = _PrismDotGrid.spacing;
    final cols = (s.width / sp).floor() + 2;
    final rows = (s.height / sp).floor() + 2;
    final offX = (s.width - (cols - 1) * sp) / 2;
    final offY = (s.height - (rows - 1) * sp) / 2;
    _count = cols * rows;
    _px = Float32List(_count);
    _py = Float32List(_count);
    var i = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++, i++) {
        _px[i] = offX + c * sp;
        _py[i] = offY + r * sp;
      }
    }
  }

  void _tick(Duration now) {
    final dtMs = _prev == Duration.zero
        ? 16.0
        : ((now - _prev).inMicroseconds / 1000.0).clamp(0.0, 48.0);
    _prev = now;

    // Курсор догоняется, а не прыгает: свет слегка тянется за мышью, как в
    // прототипе (там та же доля 0.55 с поправкой на длину кадра).
    final k = 1 - math.pow(0.001, dtMs / 1000).toDouble();
    if (_hovering) {
      _at = Offset(
        _at.dx + (_target.dx - _at.dx) * k * 0.55,
        _at.dy + (_target.dy - _at.dy) * k * 0.55,
      );
      // След за движением: каждые 30 пикселей пути — новое кольцо.
      _travel += (_target - _lastEmit).distance;
      _lastEmit = _target;
      if (_travel > 30) {
        _travel = 0;
        _emit(_target, life: 900, speed: 0.3, amp: 0.8);
      }
    }

    for (var i = _ripples.length - 1; i >= 0; i--) {
      _ripples[i].t += dtMs;
      if (_ripples[i].dead) _ripples.removeAt(i);
    }

    final idle = MotionPolicy.ambient.value;
    if (idle) _phase += dtMs * 0.0007;

    _paintFrame(idle);
    _frame.value++;
    if (!_hovering && _ripples.isEmpty && !idle) _syncTicker();
  }

  /// Раскладка точек по уровням яркости — то же, что `frame()` в прототипе.
  void _paintFrame(bool idle) {
    _revision++;
    for (final l in _levels) {
      l.clear();
    }
    final push = context.read<AppState>().prismDots == PrismDots.push;
    const reach = _PrismDotGrid.reach;
    const reach2 = reach * reach;
    final ax = _at.dx, ay = _at.dy;

    for (var i = 0; i < _count; i++) {
      final x = _px[i], y = _py[i];
      var b = 0.0, dx = 0.0, dy = 0.0;

      if (_hovering) {
        final vx = x - ax, vy = y - ay;
        final d2 = vx * vx + vy * vy;
        if (d2 < reach2) {
          final d = math.sqrt(d2);
          if (d > 0.0001) {
            final t = 1 - d / reach;
            b = t * t * (3 - 2 * t); // smoothstep, как в прототипе
            if (push) {
              final s = b * _PrismDotGrid.push;
              dx = vx / d * s;
              dy = vy / d * s;
            }
          }
        }
      }

      for (var j = 0; j < _ripples.length; j++) {
        final rp = _ripples[j];
        final rx = x - rp.at.dx, ry = y - rp.at.dy;
        final ring = rp.ring;
        // Кольцо узкое: за 120px от его радиуса вклад уже неразличим, и целую
        // точку можно пропустить, не считая ни корня, ни экспоненты.
        if (rx.abs() > ring + 120 || ry.abs() > ring + 120) continue;
        final d = math.sqrt(rx * rx + ry * ry);
        final off = d - ring;
        if (off.abs() > 120) continue;
        final g = math.exp(-off * off / 2600) * (1 - rp.t / rp.life) * rp.amp;
        if (g > b) b = g;
        if (push && g > 0.02 && d > 0.0001) {
          final s = g * _PrismDotGrid.push * 1.25;
          dx += rx / d * s;
          dy += ry / d * s;
        }
      }

      if (idle) {
        final iw = 0.5 + 0.5 * math.sin(x * 0.011 + y * 0.017 + _phase);
        final v = iw * iw * 0.14;
        if (v > b) b = v;
      }

      final lv = b <= 0
          ? 0
          : math.min(_kPrismLevels - 1, 1 + (b * (_kPrismLevels - 1)).floor());
      _levels[lv].add(Offset(x + dx, y + dy));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, PrismDots>((a) => a.prismDots);
    if (mode == PrismDots.off) return const SizedBox.expand();

    final p = _pal(context);
    final base = p.brightness == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF1E3764);

    // Своего MouseRegion у сетки нет: и курсор, и нажатия приходят от
    // [PrismPointerWatcher] поверх интерфейса — только он видит их и над
    // панелями тоже.
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, c) {
            _build(Size(c.maxWidth, c.maxHeight));
            // Пока тикер спит, раскладку считаем здесь: иначе при первом
            // показе сетки не было бы вовсе (кадр никто не посчитал), а после
            // смены режима точки так и остались бы разбежавшимися.
            if (!_ticker.isTicking) _paintFrame(MotionPolicy.ambient.value);
            return CustomPaint(
              size: Size.infinite,
              painter: _PrismDotPainter(
                levels: _levels,
                revision: _revision,
                repaint: _frame,
                base: base,
                accent: _accent(context),
                baseAlpha: p.brightness == Brightness.dark ? 0.18 : 0.16,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PrismDotPainter extends CustomPainter {
  _PrismDotPainter({
    required this.levels,
    required this.revision,
    required Listenable repaint,
    required this.base,
    required this.accent,
    required this.baseAlpha,
  }) : super(repaint: repaint);

  final List<List<Offset>> levels;
  final int revision;
  final Color base, accent;
  final double baseAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    // Круглые точки одним вызовом на уровень: `drawPoints` с круглым концом
    // штриха рисует именно круги, а толщина штриха и есть диаметр. Отсюда и
    // разбор по уровням — внутри уровня и цвет, и размер общие.
    for (var i = 0; i < levels.length; i++) {
      final pts = levels[i];
      if (pts.isEmpty) continue;
      final t = i == 0 ? 0.0 : i / (levels.length - 1);
      final paint = Paint()
        ..color = Color.lerp(base, accent, t * 0.85)!
            .withValues(alpha: baseAlpha + (0.95 - baseAlpha) * t)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = _PrismDotGrid.dot * 2 * (1 + t * 1.9);
      canvas.drawPoints(PointMode.points, pts, paint);
    }
  }

  // Точки пересчитываются каждый кадр и приходят через `repaint`, поэтому
  // сравнивать здесь нужно только то, что меняется помимо них.
  @override
  bool shouldRepaint(_PrismDotPainter old) =>
      old.revision != revision ||
      old.base != base ||
      old.accent != accent ||
      old.baseAlpha != baseAlpha;
}

// --------------------------------------------------------------------------
// ОБОЛОЧКА
// --------------------------------------------------------------------------

/// Экраны рейки. Ровно те семь, что перечислены в макете (NAV), плюс журнал:
/// в прототипе он лежит карточкой внутри настроек, здесь у него уже был свой
/// экран — открывается из карточки «Журнал» на «Модулях».
enum _PrismScreen {
  hub,
  chat,
  commands,
  modules,
  images,
  speech,
  relay,
  czn,
  settings,
  log
}

/// Пункт рейки: экран, контур иконки, подпись и горячая клавиша.
///
/// В макете клавиши подписаны как ⌘1…⌘6 — прототип рисовали на маке. EVS
/// живёт на Windows, поэтому здесь Ctrl, и клавиши не просто нарисованы:
/// [_PrismHomeState] действительно их слушает. Подпись, за которой ничего не
/// происходит, хуже отсутствующей.
class _PrismNavItem {
  const _PrismNavItem(this.screen, this.d, this.label, this.key, this.digit);
  final _PrismScreen screen;
  final String d, label, key;
  final LogicalKeyboardKey digit;
}

List<_PrismNavItem> _prismNav(AppState app) => [
      _PrismNavItem(_PrismScreen.hub, PrismIcons.hub, app.t('prismHub'),
          'Ctrl 1', LogicalKeyboardKey.digit1),
      _PrismNavItem(_PrismScreen.chat, PrismIcons.chat, app.t('prismNavChat'),
          'Ctrl 2', LogicalKeyboardKey.digit2),
      _PrismNavItem(_PrismScreen.commands, PrismIcons.commands,
          app.t('ncTabCommands'), 'Ctrl 3', LogicalKeyboardKey.digit3),
      _PrismNavItem(_PrismScreen.modules, PrismIcons.modules,
          app.t('prismModules'), 'Ctrl 4', LogicalKeyboardKey.digit4),
      _PrismNavItem(_PrismScreen.images, PrismIcons.lumina,
          app.t('prismNavLumina'), 'Ctrl 5', LogicalKeyboardKey.digit5),
      _PrismNavItem(_PrismScreen.speech, PrismIcons.mic,
          app.t('prismNavSonora'), 'Ctrl 6', LogicalKeyboardKey.digit6),
      // «Сеть» стоит после подсистем не случайно: это такая же
      // наблюдаемая подсистема, только живёт она не на этом
      // компьютере, а на станции.
      _PrismNavItem(_PrismScreen.relay, PrismIcons.spark,
          app.t('prismNavRelay'), 'Ctrl 7', LogicalKeyboardKey.digit7),
      // Переводчик игры — подсистема того же рода, что «Сеть»: наблюдаемая,
      // с собственным процессом и своим состоянием.
      _PrismNavItem(_PrismScreen.czn, PrismIcons.czn,
          app.t('prismNavCzn'), 'Ctrl 8', LogicalKeyboardKey.digit8),
      _PrismNavItem(_PrismScreen.settings, PrismIcons.settings,
          app.t('settings'), 'Ctrl 9', LogicalKeyboardKey.digit9),
    ];

/// Как встроенные настройки просят оболочку показать приветствие. Ссылку на
/// себя оболочка кладёт сюда, пока живёт: настройки — её экран, но напрямую
/// достучаться до её состояния им нечем, а тащить ради одной ссылки провайдер
/// через полтысячи строк настроек — хуже.
VoidCallback? prismShowWelcomeHook;

/// Приветствие показывается ОДИН раз за запуск программы, а не при каждой
/// сборке оболочки: переключение стиля туда-обратно не должно снова открывать
/// первый экран.
bool _prismWelcomeShown = false;

class _PrismHome extends StatefulWidget {
  const _PrismHome();
  @override
  State<_PrismHome> createState() => _PrismHomeState();
}

class _PrismHomeState extends State<_PrismHome> {
  _PrismScreen _screen = _PrismScreen.hub;

  /// Запрос из поля поиска в шапке. Живёт здесь, а не в экране диалога:
  /// поле стоит в шапке оболочки, а фильтрует список на экране, и общий
  /// владелец у них один — оболочка.
  final _search = TextEditingController();

  /// Какой пункт рейки только что нажали. Его иконка прочерчивается заново —
  /// это `drawline` из макета. Сбрасывается по окончании анимации.
  _PrismScreen? _flash;

  /// Открыт ли экран приветствия.
  bool _welcome = false;

  void _go(_PrismScreen s) {
    if (_screen == s) return;
    // Уходя из настроек с несохранёнными правками, спрашиваем — тем же
    // диалогом, каким спрашивает окно настроек. Без этого правки пропадали бы
    // молча: экран настроек уничтожается переключением пункта рейки, а его
    // dispose() черновик отменяет.
    if (_screen == _PrismScreen.settings) {
      final app = context.read<AppState>();
      if (app.settingsDirty || app.settingsApplying) {
        unawaited(_leaveSettings(app, s));
        return;
      }
    }
    _apply(s);
  }

  void _apply(_PrismScreen s) {
    setState(() {
      _screen = s;
      _flash = s;
      // Поиск относится к списку диалогов; уходя с него, запрос гасим, иначе
      // человек возвращается к отфильтрованному списку без видимой причины.
      if (s != _PrismScreen.chat) _search.clear();
    });
  }

  Future<void> _leaveSettings(AppState app, _PrismScreen s) async {
    final choice = await showEvsSettingsExitPrompt(context, app);
    if (!mounted) return;
    if (choice == 'save') {
      await app.commitSettingsEdit();
    } else if (choice == 'discard') {
      await app.cancelSettingsEdit();
    } else {
      return; // «Остаться» или закрыли мимо кнопок — черновик цел.
    }
    if (mounted) _apply(s);
  }

  @override
  void dispose() {
    prismShowWelcomeHook = null;
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (!_prismWelcomeShown && context.read<AppState>().prismWelcome) {
      _prismWelcomeShown = true;
      _welcome = true;
    }
    prismShowWelcomeHook = () {
      if (mounted) setState(() => _welcome = true);
    };
    // «Что нового» после обновления: диалог живёт внутри ChatScreen у классики,
    // и каждая оболочка без него обязана показать его сама (тот же вызов в
    // _NexusHomeState и _NocturHomeState).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final app = context.read<AppState>();
      final entry = await app.consumeWhatsNew();
      if (!mounted || entry == null) return;
      unawaited(showDialog<void>(
        context: context,
        builder: (_) => _NocturWhatsNew(entry),
      ));
    });
  }

  /// Закрыть приветствие. Непустая строка — начать ею новый разговор тем же
  /// путём, каким его начинает обычный композер.
  void _closeWelcome(String? send) {
    final app = context.read<AppState>();
    setState(() {
      _welcome = false;
      if (send != null && send.trim().isNotEmpty) {
        _screen = _PrismScreen.chat;
        _flash = _PrismScreen.chat;
      }
    });
    if (send != null && send.trim().isNotEmpty) {
      app.newChat();
      unawaited(app.sendMessage(send.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    final app = context.read<AppState>();

    if (_welcome) return PrismWelcome(onDone: _closeWelcome);

    // Смена экрана — короткое растворение, как переход между стилями: резкая
    // подмена целой панели поверх живого фона читается как мигание.
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      // Своя раскладка вместо стандартной. Стандартная кладёт экраны в
      // Stack(alignment: center) с рыхлыми ограничениями — короткий экран
      // сжимался по содержимому и повисал ПОСЕРЕДИНЕ окна. Виднее всего это
      // было на «Командах» без единой команды: каталог уезжал вниз, хотя
      // должен стоять вверху. Тугие ограничения и верхний край это снимают.
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.topLeft,
        children: [...previous, if (current != null) current],
      ),
      child: KeyedSubtree(
        key: ValueKey(_screen),
        child: switch (_screen) {
          _PrismScreen.hub => const _PrismHub(),
          _PrismScreen.chat => _PrismChat(query: _search.text),
          _PrismScreen.modules => _PrismModules(onLog: () => _go(_PrismScreen.log)),
          _PrismScreen.commands => const _PrismCommands(),
          _PrismScreen.log => const EvsLogTab(),
          _PrismScreen.images => const LuminaStudio(embedded: true),
          _PrismScreen.relay => const RelayPanel(embedded: true),
                  _PrismScreen.czn => const CznPanel(embedded: true),
          _PrismScreen.speech =>
            const StudioPanel(mode: StudioMode.speech, embedded: true),
          // Настройки — полноценный экран оболочки: те же одиннадцать
          // разделов и те же строки, что в окне, в раскладке макета.
          _PrismScreen.settings => const DesktopSettings(embedded: true),
        },
      ),
    );

    // Горячие клавиши рейки. Ctrl+1…7 — те самые подписи, что нарисованы в
    // пунктах; Ctrl+, — привычная клавиша настроек на всех платформах.
    final bindings = <ShortcutActivator, VoidCallback>{
      for (final n in _prismNav(app))
        SingleActivator(n.digit, control: true): () => _go(n.screen),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
          _go(_PrismScreen.settings),
    };

    return Scaffold(
      backgroundColor: _bg(context),
      body: CallbackShortcuts(
        bindings: bindings,
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              // Порядок обязателен: фон → сетка → интерфейс.
              const Positioned.fill(child: _PrismBackdrop()),
              const Positioned.fill(child: _PrismDotGrid()),
              Positioned.fill(
                child: Row(
                  children: [
                    _PrismRail(
                      current: _screen,
                      flash: _flash,
                      onGo: _go,
                      onFlashDone: () {
                        if (mounted) setState(() => _flash = null);
                      },
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _PrismHeader(
                            current: _screen,
                            search: _search,
                            onSearch: () {
                              _go(_PrismScreen.chat);
                              setState(() {});
                            },
                            onBack: _screen == _PrismScreen.hub
                                ? null
                                : () => _go(_PrismScreen.hub),
                            onSettings: () => _go(_PrismScreen.settings),
                          ),
                          // GpuNoticeBar только там, где студия его сама не
                          // рисует: внутри Lumina он уже есть, и две одинаковые
                          // полосы подряд — это не предупреждение, а шум.
                          if (_screen != _PrismScreen.images)
                            const GpuNoticeBar(),
                          // Поля экрана — из макета: 24px сверху, 28px по бокам
                          // и снизу. Свои отступы экраны не заводят, иначе они
                          // складывались бы с этими.
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                              child: content,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Наблюдатель за курсором лежит ПОВЕРХ всего: только оттуда
              // видно мышь и над панелями. Он translucent — нажатия проходят
              // сквозь него к интерфейсу, ничего не перехватывая.
              const Positioned.fill(child: PrismPointerWatcher()),
            ],
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------
// РЕЙКА
// --------------------------------------------------------------------------

/// Боковое меню на 262px — как в макете. Стеклянная подложка, марка сверху,
/// сплошная кнопка «Новый чат», семь пунктов с горячими клавишами и карточка
/// состояния модели внизу.
///
/// Пунктов ровно семь, как в прототипе. То, что в приложении есть сверх них,
/// лежит там же, куда его кладёт макет: архив — кнопкой под списком диалогов,
/// модели и журнал — внутри настроек и на «Модулях». Ни одна функция не
/// потеряна, но и лишней строки в рейке нет.
class _PrismRail extends StatelessWidget {
  const _PrismRail({
    required this.current,
    required this.flash,
    required this.onGo,
    required this.onFlashDone,
  });

  final _PrismScreen current;
  final _PrismScreen? flash;
  final ValueChanged<_PrismScreen> onGo;
  final VoidCallback onFlashDone;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final blur = _prismBlur(context);

    Widget body = Container(
      width: _skin(context).railWidth,
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 20),
      decoration: BoxDecoration(
        color: _prismCardFill(context),
        border: Border(right: BorderSide(color: _stroke(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Марка тянет окно за собой: своей полосы заголовка слева нет, а
          // взяться за окно в этом углу — первое, что пробуют.
          DragToMoveArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
              child: Row(
                children: [
                  // Знак — существующая анимация EVS, та же, что в трёх других
                  // оболочках. Своего значка стиль не заводит: марка у
                  // программы одна.
                  // Гейт переднего плана, а не окружения: марка — постоянная
                  // часть рейки, и в режиме «Умные» она замирала, как только
                  // ассистент затихал. Знак приложения, стоящий столбом,
                  // читается как зависшая программа, а не как экономия.
                  const _EvsLogoMark(size: 36, gate: MotionGate.foreground),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'EVS',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: _txt(context),
                          ),
                        ),
                        const SizedBox(height: 1),
                        _PrismRailCaption(app: app),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _PrismNewChatButton(onDone: () => onGo(_PrismScreen.chat)),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final n in _prismNav(app))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: _PrismNavRow(
                      item: n,
                      selected: n.screen == current,
                      flash: n.screen == flash,
                      onFlashDone: onFlashDone,
                      onTap: () => onGo(n.screen),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _PrismRailStatus(),
        ],
      ),
    );

    if (blur > 0) {
      body = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: body,
        ),
      );
    }
    return body;
  }
}

/// Подпись под маркой: состояние ассистента и то, где считает модель.
/// В макете здесь написано «Готов · локально» — оба слова здесь настоящие.
class _PrismRailCaption extends StatelessWidget {
  const _PrismRailCaption({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: NexusPipeline.instance,
      builder: (context, _) {
        final stage = NexusPipeline.instance.stage;
        final state = switch (stage) {
          'listening' => app.t('vaListening'),
          'thinking' => app.t('vaThinking'),
          'speaking' => app.t('nxSpeaking'),
          _ => app.t('nxIdle'),
        };
        return Text(
          '$state · ${_prismWhere(app)}'.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.9,
            color: _faint(context),
          ),
        );
      },
    );
  }
}

/// Где считает модель, одним словом. Из inferenceMode — того же поля, которым
/// пользуются настройки моделей.
String _prismWhere(AppState app) => switch (app.inferenceMode) {
      'local' => app.t('prismWhereLocal'),
      'localServer' => app.t('prismWhereStation'),
      _ => app.t('prismWhereCloud'),
    };

/// Сплошная кнопка «Новый чат» — `--btn` / `--btnx` из токенов: на тёмной теме
/// белая с чёрным текстом, на светлой наоборот.
class _PrismNewChatButton extends StatefulWidget {
  const _PrismNewChatButton({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_PrismNewChatButton> createState() => _PrismNewChatButtonState();
}

class _PrismNewChatButtonState extends State<_PrismNewChatButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () {
          app.buzz();
          app.newChat();
          widget.onDone();
        },
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _hover ? 0.9 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _prismBtn(context),
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x38000000),
                    offset: Offset(0, 6),
                    blurRadius: 18),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PrismIcon(PrismIcons.plus,
                    size: 16, stroke: 2.2, color: _prismBtnFg(context)),
                const SizedBox(width: 9),
                Text(
                  app.t('newChat'),
                  // Без ореола: кнопка светлая, текст на ней тёмный, и тёмная
                  // обводка вокруг тёмных букв читается как грязь, а не как
                  // контур. Ореол нужен там, где под текстом аврора.
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _prismBtnFg(context),
                    shadows: const [],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Карточка под рейкой: состояние связи, из чего собран ассистент и сколько
/// съедено окна контекста. Все четыре строки — настоящие; та, для которой нет
/// данных, не рисуется.
class _PrismRailStatus extends StatelessWidget {
  const _PrismRailStatus();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final (label, dot) = switch (app.connectionStatus) {
      ConnectionStatus.connected => (app.t('prismNeuralOn'), _success(context)),
      ConnectionStatus.connecting => (app.t('statusConnecting'), _info(context)),
      ConnectionStatus.noModel => (app.t('statusNoModel'), _warn(context)),
      _ => (app.t('statusDisconnected'), _danger(context)),
    };

    // Из чего собран ассистент — модель, распознавание, синтез. Ровно те две
    // моноширинные строки, что стоят в макете, только не выдуманные.
    final model = app.selectedModel.isEmpty
        ? app.t('statusNoModel')
        : evsShortModel(app.selectedModel);
    final (tts, _) = evsTtsEngineLabel(app);
    final stt = sttEngineLabel(app);

    final (used, limit) = app.contextUsage(app.current);
    final pct = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: _prismField(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dot,
                  boxShadow: [BoxShadow(color: dot, blurRadius: 9)],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _txt(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            '${_prismWhere(app)} · $model\n$stt · $tts',
            style: PrismType.numeric.copyWith(
              color: _faint(context),
              fontSize: 10.5,
              height: 1.6,
            ),
          ),
          // Полоса окна контекста появляется, только когда предел известен:
          // на пустой полосе нечего показывать, а нарисованная в ноль читается
          // как «контекст свободен», чего мы не знаем.
          if (limit > 0) ...[
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Stack(
                children: [
                  Container(height: 5, color: _prismChip(context)),
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: pct,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            _ramp(context).a1,
                            _ramp(context).a2,
                          ]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Text(app.t('prismCtxWindow'),
                    style: PrismType.numeric
                        .copyWith(color: _faint(context), fontSize: 10.5)),
                const Spacer(),
                Text('${(pct * 100).round()}%',
                    style: PrismType.numeric
                        .copyWith(color: _faint(context), fontSize: 10.5)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Строка рейки. Выбранная залита градиентом от акцента в прозрачность и
/// обведена рамкой изнутри — так это сделано в макете (`inset 0 0 0 1px`).
/// При переходе иконка прочерчивается заново: это `drawline` из прототипа.
class _PrismNavRow extends StatefulWidget {
  const _PrismNavRow({
    required this.item,
    required this.selected,
    required this.flash,
    required this.onTap,
    required this.onFlashDone,
  });

  final _PrismNavItem item;
  final bool selected, flash;
  final VoidCallback onTap, onFlashDone;

  @override
  State<_PrismNavRow> createState() => _PrismNavRowState();
}

class _PrismNavRowState extends State<_PrismNavRow>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  // 600 мс, а не 1700 из макета: там значок прочерчивается на статичной
  // странице и его разглядывают, здесь он мелькает при переходе — и полторы
  // секунды успевали надоесть раньше, чем экран сменился.
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    value: 1,
  );

  @override
  void didUpdateWidget(_PrismNavRow old) {
    super.didUpdateWidget(old);
    if (widget.flash && !old.flash) {
      _draw.forward(from: 0).whenComplete(widget.onFlashDone);
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final lit = on || _hover;
    final fg = lit ? _txt(context) : _sub(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            color: on ? null : (_hover ? _prismHover(context) : null),
            gradient: on
                ? LinearGradient(
                    begin: const Alignment(-1, -0.2),
                    end: const Alignment(1, 0.2),
                    colors: [
                      _prismAccentSoft(context),
                      _prismAccentSoft(context).withValues(alpha: 0),
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: on ? _stroke(context) : Colors.transparent),
          ),
          child: Row(
            children: [
              AnimatedBuilder(
                animation: _draw,
                builder: (context, _) => PrismIcon(
                  widget.item.d,
                  size: 17,
                  progress: _draw.value,
                  // Пока иконка прочерчивается, она горит акцентом — в макете
                  // это `neon`. Дальше возвращается к цвету строки.
                  color: Color.lerp(_ramp(context).a1, fg, _draw.value),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.item.key,
                style: PrismType.numeric
                    .copyWith(color: _faint(context), fontSize: 10.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------
// ШАПКА
// --------------------------------------------------------------------------

/// Шапка на 86px: назад, название с подписью, пилюля состояния, поиск по
/// диалогам, переключатель темы и шестерёнка — всё, как в макете.
///
/// Одно добавлено сверх прототипа: кнопки окна. Макет рисовали в браузере, где
/// рамку даёт сама вкладка; у EVS окно без рамки, и свернуть его больше нечем.
class _PrismHeader extends StatelessWidget {
  const _PrismHeader({
    required this.current,
    required this.search,
    required this.onSearch,
    required this.onBack,
    required this.onSettings,
  });

  final _PrismScreen current;
  final TextEditingController search;
  final VoidCallback onSearch;
  final VoidCallback? onBack;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Заголовок называет ТЕКУЩИЙ экран. У диалога это имя чата — оно меняется
    // само и говорит больше, чем слово «Диалог».
    final (title, sub) = switch (current) {
      _PrismScreen.hub => (app.t('prismHubTitle'), app.t('prismHubSub')),
      _PrismScreen.chat => (
          app.current?.title ?? app.t('newChat'),
          app.t('prismChatSub'),
        ),
      _PrismScreen.modules => (app.t('prismModules'), app.t('prismModulesSub')),
      _PrismScreen.commands =>
        (app.t('prismCommandsTitle'), app.t('prismCommandsSub')),
      _PrismScreen.log => (app.t('nxNavLog'), app.t('prismLogSub')),
      _PrismScreen.images =>
        (app.t('prismNavLumina'), app.t('prismImagesSub')),
      _PrismScreen.speech =>
        (app.t('prismNavSonora'), app.t('prismSpeechSub')),
      _PrismScreen.relay => (app.t('prismNavRelay'), app.t('relaySub')),
      _PrismScreen.czn => (app.t('prismNavCzn'), app.t('cznSub')),
      _PrismScreen.settings => (app.t('settings'), app.t('prismSettingsSub')),
    };

    final blur = _prismBlur(context);

    Widget body = Container(
      height: 86,
      padding: const EdgeInsets.only(left: 28),
      decoration: BoxDecoration(
        color: _prismCardFill(context),
        border: Border(bottom: BorderSide(color: _stroke(context))),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          // Поиск уходит первым: на узком окне название экрана важнее.
          final wide = c.maxWidth > 940;
          return Row(
            children: [
              if (onBack != null) ...[
                _PrismSquareButton(
                  d: PrismIcons.back,
                  tooltip: app.t('prismBack'),
                  onTap: onBack!,
                ),
                const SizedBox(width: 20),
              ],
              Expanded(
                child: DragToMoveArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Название залито акцентной тройкой — `background-clip:
                      // text` из макета.
                      PrismGradientText(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.69,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: _sub(context)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              const _PrismStateChip(),
              if (wide) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 216,
                  child: _PrismHeaderSearch(
                      controller: search, onChanged: onSearch),
                ),
              ],
              const SizedBox(width: 12),
              const _PrismThemeButton(),
              const SizedBox(width: 8),
              _PrismSquareButton(
                d: PrismIcons.settings,
                tooltip: app.t('settings'),
                onTap: onSettings,
              ),
              const SizedBox(width: 14),
              // Кнопки окна — единственное, чего в макете нет и без чего окно
              // без рамки не закрыть.
              Container(width: 1, height: 22, color: _stroke(context)),
              const SizedBox(width: 4),
              Tooltip(
                message: app.t('ovlEnter'),
                child: _WinBtn(Icons.picture_in_picture_alt_outlined,
                    () => app.setOverlayMode(!app.overlayMode),
                    iconSize: 14),
              ),
              _WinBtn(Icons.remove, () => windowManager.minimize()),
              _WinBtn(Icons.crop_square, () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              }, iconSize: 13),
              _WinBtn(Icons.close, () => windowManager.close(), danger: true),
            ],
          );
        },
      ),
    );

    if (blur > 0) {
      body = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: body,
        ),
      );
    }
    return body;
  }
}

/// Пилюля состояния справа от названия: точка со свечением и слово. Цвет и
/// подпись — те же, что у карточки ассистента в «Центре».
class _PrismStateChip extends StatelessWidget {
  const _PrismStateChip();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return AnimatedBuilder(
      animation: Listenable.merge([
        NexusPipeline.instance,
        VoiceAssistant.instance.state,
        VoiceAssistant.instance.wakeActive,
      ]),
      builder: (context, _) {
        final stage = NexusPipeline.instance.stage;
        final idle = stage == 'idle';
        final (label, color) = _prismStatus(context, app, stage);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 450),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: idle
                ? _prismChip(context)
                : color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: idle
                    ? _stroke(context)
                    : color.withValues(alpha: 0.42)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: idle ? _faint(context) : color,
                  boxShadow: idle
                      ? null
                      : [BoxShadow(color: color, blurRadius: 9)],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: idle ? _sub(context) : color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Поиск по диалогам. Фильтрует список на экране «Диалог» — тот самый, что
/// открывается по нажатию.
class _PrismHeaderSearch extends StatelessWidget {
  const _PrismHeaderSearch({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 15),
      decoration: BoxDecoration(
        color: _prismField(context),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        children: [
          PrismIcon(PrismIcons.search,
              size: 15, stroke: 1.9, color: _faint(context)),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              style: TextStyle(fontSize: 12.5, color: _body(context)),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: app.t('prismSearchChats'),
                hintStyle:
                    TextStyle(fontSize: 12.5, color: _faint(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Переключатель темы. Иконка меняется вместе с темой и прочерчивается при
/// каждом переключении — это `drawline` из макета.
class _PrismThemeButton extends StatefulWidget {
  const _PrismThemeButton();
  @override
  State<_PrismThemeButton> createState() => _PrismThemeButtonState();
}

class _PrismThemeButtonState extends State<_PrismThemeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dark = _pal(context).brightness == Brightness.dark;
    return _PrismSquareButton(
      // Тёмная тема показывает луну, светлая — солнце: значок называет
      // ТЕКУЩЕЕ, как в макете.
      d: dark ? PrismIcons.moon : PrismIcons.sun,
      tooltip: app.t('themeMode'),
      progress: _draw,
      onTap: () {
        // У приложения три темы, у макета две. Переключаем по яркости: из
        // любой тёмной в светлую и обратно в основную тёмную.
        app.setThemeMode(dark ? AppThemeMode.claude : AppThemeMode.dark);
        _draw.forward(from: 0);
      },
    );
  }
}

/// Квадратная кнопка шапки 40×40 с радиусом 13 — форма из макета.
class _PrismSquareButton extends StatefulWidget {
  const _PrismSquareButton({
    required this.d,
    required this.tooltip,
    required this.onTap,
    this.progress,
  });

  final String d;
  final String tooltip;
  final VoidCallback onTap;

  /// Прочерчивание контура, если кнопке это нужно (переключатель темы).
  final Animation<double>? progress;

  @override
  State<_PrismSquareButton> createState() => _PrismSquareButtonState();
}

class _PrismSquareButtonState extends State<_PrismSquareButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final icon = PrismIcon(
      widget.d,
      size: 17,
      stroke: 1.9,
      color: _hover ? _txt(context) : _sub(context),
      progress: widget.progress?.value ?? 1,
    );
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _hover ? _prismHover(context) : _prismField(context),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: _stroke(context)),
            ),
            alignment: Alignment.center,
            child: widget.progress == null
                ? icon
                : AnimatedBuilder(
                    animation: widget.progress!,
                    builder: (context, _) => PrismIcon(
                      widget.d,
                      size: 17,
                      stroke: 1.9,
                      color: _hover ? _txt(context) : _sub(context),
                      progress: widget.progress!.value,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
