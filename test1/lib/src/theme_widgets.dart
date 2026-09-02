part of '../main.dart';

/* ============================ ТЕМА / ПРИЛОЖЕНИЕ ============================ */

// Root navigator key — lets background controllers (VoiceAssistant) show
// dialogs without a captured BuildContext.
final GlobalKey<NavigatorState> rootNavKey = GlobalKey<NavigatorState>();

class MiraiApp extends StatelessWidget {
  const MiraiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavKey,
      title: 'Nexus Anima',
      theme: _buildTheme(app.appStyle, app.themeMode, app.prismAccent),
      darkTheme: _buildTheme(app.appStyle, app.themeMode, app.prismAccent),
      themeMode: skinFor(app.appStyle, app.themeMode, accent: app.prismAccent)
                  .pal
                  .brightness ==
              Brightness.light
          ? ThemeMode.light
          : ThemeMode.dark,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        // Combine the OS-level accessibility text scale with the app's own
        // font size setting, instead of discarding the system scale.
        final systemFactor = mq.textScaler.scale(100) / 100;
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(systemFactor * app.fontSize),
          ),
          child: child!,
        );
      },
      // Заставка внутри окна — только когда окна загрузки не было: иначе один и
      // тот же знак Genesis проигрывается дважды подряд, второй раз уже после
      // того, как приложение готово.
      home: BootSplash.instance.replacedInAppSplash
          ? const _RootHome()
          : const ImmersiveSplash(),
    );
  }

  // On iOS, use the system font (San Francisco) — exactly the iOS typography —
  // by NOT forcing a bundled family (Flutter then falls back to the platform
  // default, which is SF on iOS). Apple's SF can't be bundled for other
  // platforms (proprietary), so Android/desktop/web keep the bundled Nunito.
  // «Призма» нарисована на Figtree и берёт её — но ТОЛЬКО она: три других стиля
  // остаются на Nunito и не меняются ни на пиксель.
  String? _appFontFamily(AppStyle style) => animaFontFamily(style);

  ThemeData _buildTheme(AppStyle style, AppThemeMode mode, PrismAccent accent) {
    final skin = skinFor(style, mode, accent: accent);
    final p = skin.pal;
    final scheme = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: p.brightness,
    ).copyWith(
      primary: p.accent,
      surface: p.card2,
      onSurface: p.txt,
    );
    final card = p.card;
    final txtStyle = TextStyle(color: p.txt);
    final prism = style == AppStyle.prism;
    // `--stroke2` макета: контур заметнее обычного, им обведены всплывающие
    // поверхности — они лежат НАД интерфейсом, и их край должен читаться.
    final stroke2 = p.brightness == Brightness.dark
        ? const Color(0x2EFFFFFF)
        : const Color(0xFFB8C2D2);
    final base = ThemeData(
      useMaterial3: true,
      // Both return paths below carry this: copyWith preserves extensions.
      extensions: <ThemeExtension<dynamic>>[
        AppTokens(skin: skin, style: style, accent: accent),
      ],
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      dividerColor: p.stroke,
      fontFamily: _appFontFamily(style),
      fontFamilyFallback: style == AppStyle.prism ? kPrismFontFallback : null,
      // Cover the surfaces that otherwise fall back to Material defaults so the
      // system dialogs / menus / snackbars / tooltips follow the app theme even
      // when a call site doesn't set colours explicitly (TZ3.1 §1.2).
      //
      // «Призма» задаёт им ещё и форму: окно 22, меню 18, подсказка 12, у всех
      // контур `--stroke2`. Правка здесь важнее, чем кажется, — через эти четыре
      // темы проходит КАЖДЫЙ диалог, меню и всплывающая подсказка приложения, и
      // без неё переименование чата или выбор модели открывались бы прямыми
      // углами посреди скруглённого интерфейса.
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: prism
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(color: stroke2),
              )
            : null,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        textStyle: txtStyle,
        shape: prism
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: stroke2),
              )
            : null,
        elevation: prism ? 0 : null,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: txtStyle,
        behavior: SnackBarBehavior.floating,
        shape: prism
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: stroke2),
              )
            : null,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.all(Radius.circular(prism ? 12 : 6)),
          border: prism ? Border.all(color: stroke2) : null,
        ),
        textStyle: txtStyle,
      ),
    );
    if (!prism) return base;
    // Обводка текста. Она нужна не для красоты: в «Призме» под интерфейсом
    // живая аврора, и её светлые полосы проходят прямо под подписями. Любой
    // ОДИН цвет текста на таком фоне где-то теряется — тёмный на светлом
    // месте, светлый на тёмном. Ореол снимает вопрос: буква несёт свой фон с
    // собой и читается над чем угодно. Тень тугая (2px) — это контур, а не
    // свечение, плюс вторая пошире, чтобы буквы отделялись от пятен.
    final halo =
        p.brightness == Brightness.dark ? kPrismHaloDark : kPrismHaloLight;
    return base.copyWith(
      textTheme: _withHalo(base.textTheme, halo),
      primaryTextTheme: _withHalo(base.primaryTextTheme, halo),
    );
  }
}

const List<Shadow> kPrismHaloDark = [
  Shadow(color: Color(0xE6000000), blurRadius: 2),
  Shadow(color: Color(0x8C000000), blurRadius: 5),
];
const List<Shadow> kPrismHaloLight = [
  Shadow(color: Color(0xE6FFFFFF), blurRadius: 2),
  Shadow(color: Color(0x8CFFFFFF), blurRadius: 5),
];

/// Ореол под цвет темы — для мест, где его приходится ставить руками.
List<Shadow> prismHalo(BuildContext c) =>
    _pal(c).brightness == Brightness.dark ? kPrismHaloDark : kPrismHaloLight;

/// Тот же ореол на всех начертаниях темы. Через `textTheme`, а не по месту:
/// `Text` сливает свой стиль с окружающим (`inherit: true`), поэтому поле,
/// которого нет в стиле вызова — а `shadows` не задаёт почти никто, — берётся
/// отсюда. Одна правка вместо сотен.
TextTheme _withHalo(TextTheme t, List<Shadow> s) {
  TextStyle? h(TextStyle? x) => x?.copyWith(shadows: s);
  return t.copyWith(
    displayLarge: h(t.displayLarge),
    displayMedium: h(t.displayMedium),
    displaySmall: h(t.displaySmall),
    headlineLarge: h(t.headlineLarge),
    headlineMedium: h(t.headlineMedium),
    headlineSmall: h(t.headlineSmall),
    titleLarge: h(t.titleLarge),
    titleMedium: h(t.titleMedium),
    titleSmall: h(t.titleSmall),
    bodyLarge: h(t.bodyLarge),
    bodyMedium: h(t.bodyMedium),
    bodySmall: h(t.bodySmall),
    labelLarge: h(t.labelLarge),
    labelMedium: h(t.labelMedium),
    labelSmall: h(t.labelSmall),
  );
}

// Animated startup transition: the Genesis logo (variant 01 of
// genesis/EVS Animations.dc.html — the sign plus the "Enhanced Voice System"
// signature) is born out of the singularity on the sample's own backdrop, then
// cross-fades into the app. Plays once per cold launch; a tap anywhere skips
// straight to the app. The overlay only STARTS once the main window is really on
// screen — with the floating widget enabled (default) the window boots hidden, so
// an unconditional start would play the whole thing to nobody. _RootHome is
// mounted under the overlay the whole time so it's already warm when it clears.
class ImmersiveSplash extends StatefulWidget {
  const ImmersiveSplash({super.key});
  @override
  State<ImmersiveSplash> createState() => _ImmersiveSplashState();
}

class _ImmersiveSplashState extends State<ImmersiveSplash>
    with SingleTickerProviderStateMixin {
  // Sample timing: the sign is assembled by 3.5 s, the signature finishes
  // glitching in by ~4.8 s — that's when the cross-fade starts.
  static const Duration _hold = Duration(milliseconds: 4800);

  late final AnimationController _fade; // 0 → 1 = overlay dissolves
  bool _done = false;
  bool _started = false;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() => _done = true);
        }
      });
    if (MotionPolicy.windowShown.value) {
      _begin();
    } else {
      MotionPolicy.windowShown.addListener(_onShown);
    }
  }

  void _onShown() {
    if (!MotionPolicy.windowShown.value) return;
    MotionPolicy.windowShown.removeListener(_onShown);
    if (mounted) setState(_begin);
  }

  void _begin() {
    _started = true;
    _holdTimer = Timer(_hold, () {
      if (mounted) _fade.forward();
    });
  }

  void _skip() {
    if (_done || !_started) return;
    _holdTimer?.cancel();
    if (!_fade.isAnimating) _fade.forward();
  }

  @override
  void dispose() {
    MotionPolicy.windowShown.removeListener(_onShown);
    _holdTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const _RootHome();
    return Stack(
      children: [
        const _RootHome(),
        Positioned.fill(
          child: GestureDetector(
            onTap: _skip,
            child: AnimatedBuilder(
              animation: _fade,
              builder: (context, child) => Opacity(
                opacity: (1 - _fade.value).clamp(0.0, 1.0),
                child: child,
              ),
              child: DecoratedBox(
                decoration: genesisBackdrop,
                child: !_started
                    // Window still hidden: hold the plain brand backdrop so the
                    // logo starts from its very first frame when it appears.
                    ? const SizedBox.expand()
                    : Center(
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final s = math.min(
                              math.min(c.maxWidth * 0.42, c.maxHeight * 0.56),
                              460.0,
                            );
                            return GenesisLogo(
                              size: s,
                              withText: true,
                              gate: MotionGate.none,
                            );
                          },
                        ),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Semantic theme palette. The color helpers below resolve against the active
// AppThemeMode, so the hundreds of `_bg(context)`/`_card(context)`/… call sites
// re-theme automatically. A theme file specifies these 14 roles; everything
// semantic (connection statuses, CPU/RAM/VRAM bars, command-type badges, banner
// tones) is mapped onto the five anchors accent/success/danger/info/warn, so a
// new theme repaints the entire UI — no per-element hardcoded colours.
class _Palette {
  final Color bg; // page background
  final Color card; // primary surface
  final Color card2; // elevated surface / popovers
  final Color txt; // primary text
  final Color sub; // secondary text
  final Color accent; // primary interactive
  final Color stroke; // hairline / border
  final Color body; // light "body" text (secondary-primary)
  final Color faint; // muted / tertiary text
  final Color success; // done / success / connected
  final Color danger; // error
  final Color info; // in-progress / neutral-informational (connecting, loading)
  final Color warn; // caution / attention (no-model, starting)
  final Brightness brightness;
  const _Palette({
    required this.bg,
    required this.card,
    required this.card2,
    required this.txt,
    required this.sub,
    required this.accent,
    required this.stroke,
    required this.body,
    required this.faint,
    required this.success,
    required this.danger,
    required this.info,
    required this.warn,
    required this.brightness,
  });
}

// Dark = the app's shipped palette (canonical current values).
const _Palette _kDark = _Palette(
  bg: Color(0xFF0E0E15),
  card: Color(0xFF1C1C26),
  card2: Color(0xFF15151E),
  txt: Color(0xFFFFFFFF),
  sub: Color(0xFF8A8A95),
  accent: Color(0xFF7C8CF8),
  stroke: Color(0x14FFFFFF),
  body: Color(0xFFD0D4E2),
  faint: Color(0xFF6E7280),
  success: Color(0xFF54E08A),
  danger: Color(0xFFE05D5D),
  info: Color(0xFF5B9DF0),
  warn: Color(0xFFE0B24A),
  brightness: Brightness.dark,
);

// Claude — warm cream editorial palette (claudeDESIGN.md). Light theme: full
// readability needs the color pass (APPLE-THEME-TODO.md).
const _Palette _kClaude = _Palette(
  bg: Color(0xFFFAF9F5),
  card: Color(0xFFEFE9DE),
  card2: Color(0xFFF5F0E8),
  txt: Color(0xFF141413),
  sub: Color(0xFF6C6A64),
  accent: Color(0xFFCC785C),
  stroke: Color(0xFFE6DFD8),
  body: Color(0xFF3D3D3A),
  faint: Color(0xFF8E8B82),
  success: Color(0xFF5DB872),
  danger: Color(0xFFC64545),
  info: Color(0xFF2C6FD6),
  warn: Color(0xFFB8862A),
  brightness: Brightness.light,
);

// Claude — dark editorial palette (claude.ai dark mode): warm charcoal surfaces,
// cream text, the same terracotta accent.
const _Palette _kClaudeDark = _Palette(
  bg: Color(0xFF262624),
  card: Color(0xFF30302E),
  card2: Color(0xFF383735),
  txt: Color(0xFFF2F0E9),
  sub: Color(0xFFA8A69C),
  accent: Color(0xFFD97757),
  stroke: Color(0xFF423F3B),
  body: Color(0xFFE4E1D8),
  faint: Color(0xFF8E8C85),
  success: Color(0xFF5DB872),
  danger: Color(0xFFE0685E),
  info: Color(0xFF5B9DF0),
  warn: Color(0xFFE0B24A),
  brightness: Brightness.dark,
);

_Palette _palFor(AppThemeMode m) {
  switch (m) {
    case AppThemeMode.claude:
      return _kClaude;
    case AppThemeMode.claudeDark:
      return _kClaudeDark;
    case AppThemeMode.dark:
      return _kDark;
  }
}

// ---- Interface-style skins (Nexus TZ §3.3) --------------------------------
// A skin bundles a palette with geometry + flags for one (AppStyle × theme)
// cell. Classic (`standard`) skins wrap the existing `_palFor` palette and mirror
// today's metrics, so the classic UI stays pixel-identical; `nexus` skins swap in
// the Nexus palettes/metrics below. The legacy `_bg/_card/…` helpers keep their
// signatures and just read `pal` from the active skin; anything genuinely new
// (accent2, radii, glow, background glows) reads through `_skin(context)`.
class AnimaSkin {
  // ignore: library_private_types_in_public_api  (single-library project — _Palette never leaves it)
  final _Palette pal; // the 13 colour slots
  final Color accent2; // second stop for accent gradients
  final double radiusCard; // card corner radius
  final double radiusControl; // control corner radius
  final double railWidth; // left nav-rail width (0 = no dedicated rail)
  final bool glow; // soft glows on dots/statuses (dark themes only)
  final double glowIntensity; // 1.0 = reference (Nexus dark); 0.6 = Claude dark
  final List<RadialGradient> bgGlows; // decorative window-background spots
  // «Ноктюрн» (Noctur TZ §3.3): tabs on top instead of a rail, a fixed-height
  // header and a monospace telemetry strip along the bottom. Zero/false in the
  // other styles, so nothing reserves space for them there.
  final double topBarHeight; // 52 (noctur) / 0
  final double statusBarHeight; // 34 (noctur) / 0
  final bool tabsNav; // true → text tabs replace the nav rail
  const AnimaSkin({
    // ignore: library_private_types_in_public_api
    required this.pal,
    required this.accent2,
    required this.radiusCard,
    required this.radiusControl,
    required this.railWidth,
    required this.glow,
    this.glowIntensity = 1.0,
    this.bgGlows = const [],
    this.topBarHeight = 0,
    this.statusBarHeight = 0,
    this.tabsNav = false,
  });
}

/// The active skin, carried down the tree through [ThemeData.extensions].
///
/// The colours are untouched — this is the very [AnimaSkin] `skinFor` has always
/// produced. What changes is how it arrives. `_pal(c)` used to reach for
/// `c.read<AppState>()`, and `read` does not subscribe: a theme change
/// repainted nothing by itself, so every screen had to remember a
/// `context.select` at its top to force the rebuild. Reading through
/// `Theme.of` makes that dependency real and those reminders redundant.
///
/// [lerp] snaps instead of interpolating. ThemeExtension does offer a free
/// cross-fade between themes, but taking it here would change how switching
/// LOOKS on top of changing how it propagates, and only one of those two is a
/// defect. Fading the palette is a later step, on its own.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.skin,
    required this.style,
    required this.accent,
  });

  final AnimaSkin skin;
  final AppStyle style;
  final PrismAccent accent;

  @override
  AppTokens copyWith({AnimaSkin? skin, AppStyle? style, PrismAccent? accent}) =>
      AppTokens(
        skin: skin ?? this.skin,
        style: style ?? this.style,
        accent: accent ?? this.accent,
      );

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) =>
      (other is AppTokens && t >= 0.5) ? other : this;
}

// Nexus palettes (TZ §4–5). Referenced ONLY from `skinFor(nexus, …)`; the
// classic palettes above are never modified, so classic stays untouched.
const _Palette _kNexusDark = _Palette(
  bg: Color(0xFF0B0F1B),
  card: Color(0xFF121A2E),
  card2: Color(0xFF16203A),
  txt: Color(0xFFE8ECFA),
  sub: Color(0xFF8A93B4),
  accent: Color(0xFF5E8BFF),
  stroke: Color(0x248CA0DC),
  body: Color(0xFFC4CBE4),
  faint: Color(0xFF5A6284),
  success: Color(0xFF4ADE80),
  danger: Color(0xFFFF7A7A),
  info: Color(0xFF4FD1FF),
  warn: Color(0xFFFFB454),
  brightness: Brightness.dark,
);

// Nexus · Claude (light): Nexus geometry over the warm Claude palette. glow=false
// (soft shadows instead of glows), white cards on cream.
const _Palette _kNexusClaude = _Palette(
  bg: Color(0xFFFAF9F5),
  card: Color(0xFFFFFFFF),
  card2: Color(0xFFEFE9DE),
  txt: Color(0xFF141413),
  sub: Color(0xFF6C6A64),
  accent: Color(0xFFCC785C),
  stroke: Color(0xFFE6DFD8),
  body: Color(0xFF3D3D3A),
  faint: Color(0xFF8E8B82),
  success: Color(0xFF5DB872),
  danger: Color(0xFFC64545),
  info: Color(0xFF2C6FD6),
  warn: Color(0xFFB8862A),
  brightness: Brightness.light,
);

// Nexus · Claude dark: Nexus geometry over the warm charcoal Claude-dark palette.
const _Palette _kNexusClaudeDark = _Palette(
  bg: Color(0xFF262624),
  card: Color(0xFF30302E),
  card2: Color(0xFF383735),
  txt: Color(0xFFF2F0E9),
  sub: Color(0xFFA8A69C),
  accent: Color(0xFFD97757),
  stroke: Color(0xFF423F3B),
  body: Color(0xFFE4E1D8),
  faint: Color(0xFF8E8C85),
  success: Color(0xFF5DB872),
  danger: Color(0xFFE0685E),
  info: Color(0xFF5B9DF0),
  warn: Color(0xFFE0B24A),
  brightness: Brightness.dark,
);

// Two soft radial spots over the Nexus-dark background (TZ §4): blue at
// (62%, −10%) and violet at (20%, 110%). Alignment maps 0..1 → −1..1.
const List<RadialGradient> _kNexusDarkGlows = [
  RadialGradient(
    center: Alignment(0.24, -1.2),
    radius: 1.1,
    colors: [Color(0x1A5E8BFF), Color(0x005E8BFF)],
  ),
  RadialGradient(
    center: Alignment(-0.6, 1.2),
    radius: 1.1,
    colors: [Color(0x148B7CFF), Color(0x008B7CFF)],
  ),
];

// Claude-dark: same character, dialled to ~0.6 intensity (TZ §5).
const List<RadialGradient> _kNexusClaudeDarkGlows = [
  RadialGradient(
    center: Alignment(0.24, -1.2),
    radius: 1.1,
    colors: [Color(0x14D97757), Color(0x00D97757)],
  ),
  RadialGradient(
    center: Alignment(-0.6, 1.2),
    radius: 1.1,
    colors: [Color(0x0EE0B24A), Color(0x00E0B24A)],
  ),
];

// ---- «Ноктюрн» palettes (Noctur TZ §4) ------------------------------------
// Flat background (no radial spots — that's Nexus), low-chroma semantic slots
// sitting on one perceptual lightness with the accent: colour tells the ROLE
// apart, it doesn't shout. surface = bg + 4 % text, line/line2 = text @ 9/17 %.
const _Palette _kNocturDark = _Palette(
  bg: Color(0xFF161826),
  card: Color(0xFF1E202E), // bg + 4 % text
  card2: Color(0xFF252734), // elevated surface (bg + 7 % text)
  txt: Color(0xFFE9E9ED),
  sub: Color(0xFF9397AB), // dim
  accent: Color(0xFF9184D9),
  stroke: Color(0x17E9E9ED), // text @ 9 %
  body: Color(0xFFC9CBD7),
  faint: Color(0xFF75798C),
  success: Color(0xFF7BB489),
  danger: Color(0xFFCC7F7F),
  info: Color(0xFF6FB3C9), // «говорю»
  warn: Color(0xFFC9A15F), // «слушаю»
  brightness: Brightness.dark,
);

// The neutral light «Ноктюрн» palette of TZ §4.2 (bg #f1f1f6 · accent #6f61c0 …)
// is NOT defined here: the theme axis has no neutral light theme — the only light
// one is Claude, and §4.3 says Claude keeps its own palette under Noctur
// geometry. It goes in the moment a neutral light theme is added.
//
// «Ноктюрн» × Claude (TZ §4.3): the geometry is Noctur's, the palette stays the
// existing Claude one, slot for slot by role — no separate values introduced.
const _Palette _kNocturClaude = _kNexusClaude;
const _Palette _kNocturClaudeDark = _kNexusClaudeDark;

// Shared «Ноктюрн» metrics (TZ §4.4): window 14 · card 10 · control 8–10 ·
// header 52 · telemetry 34. No rail — the tabs in the header do the navigating.
AnimaSkin _nocturSkin(_Palette pal, {required Color accent2, required bool glow}) =>
    AnimaSkin(
      pal: pal,
      accent2: accent2,
      radiusCard: 10,
      radiusControl: 9,
      railWidth: 0,
      glow: glow,
      topBarHeight: 52,
      statusBarHeight: 34,
      tabsNav: true,
    );

// ---- «Призма» (handoff/design) --------------------------------------------
// Шрифты стиля. В Figtree НЕТ кириллицы — 391 глиф, ни одной русской буквы; в
// прототипе это не видно, потому что там `font-family: Figtree, system-ui` и
// весь русский текст молча рисовался системным шрифтом. Поэтому Figtree идёт
// первой (латиница и цифры — точно как в макете), а кириллица подхватывается
// из Nunito, который уже в сборке. Одна строка на смену, если нужен единый
// шрифт на оба алфавита.
const String kPrismFont = 'Figtree';
const List<String> kPrismFontFallback = ['Nunito'];

/// Семейство шрифта по стилю. Вынесено из темы наружу: тот же выбор нужен окну
/// меню трея, у которого своя тема и нет доступа к состоянию приложения.
String? animaFontFamily(AppStyle style) {
  if (defaultTargetPlatform == TargetPlatform.iOS) return null;
  return style == AppStyle.prism ? kPrismFont : 'Nunito';
}

// Моноширинный — числа, метрики, горячие клавиши. Кириллицу имеет (98 глифов),
// так что подмена не нужна.
const String kPrismMono = 'JetBrains Mono';

// Акцентная тройка a1 → a2 → a3: из неё строится КАЖДЫЙ градиент стиля. Она же
// раздаётся в обычные слоты — a2 уходит в `pal.accent`, a3 в `skin.accent2`, —
// поэтому сотни существующих вызовов `_accent(context)` / `_accent2(context)`
// красятся выбранным акцентом без единой правки на местах.
class PrismRamp {
  final Color a1, a2, a3;
  const PrismRamp(this.a1, this.a2, this.a3);

  // linear-gradient(140deg, a1, a2 55%, a3) — кнопки, марка, аватар.
  LinearGradient get badge => LinearGradient(
        begin: const Alignment(-0.9, -1),
        end: const Alignment(0.9, 1),
        colors: [a1, a2, a3],
        stops: const [0, 0.55, 1],
      );

  // linear-gradient(96deg, a1, a2 48%, a3) — заголовки с заливкой текста.
  LinearGradient get sweep => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [a1, a2, a3],
        stops: const [0, 0.48, 1],
      );
}

const Map<PrismAccent, PrismRamp> _kPrismRamps = {
  PrismAccent.google:
      PrismRamp(Color(0xFF3269CE), Color(0xFF7F5AAC), Color(0xFFBC505C)),
  PrismAccent.aurora:
      PrismRamp(Color(0xFF1CACC2), Color(0xFF3F63D1), Color(0xFF8A6FD4)),
  PrismAccent.sunset:
      PrismRamp(Color(0xFFD18A19), Color(0xFFCD5374), Color(0xFF7F5AAC)),
  PrismAccent.mint:
      PrismRamp(Color(0xFF1F9E7A), Color(0xFF3C8CA8), Color(0xFF6D7CC0)),
};

PrismRamp _prismRamp(PrismAccent a) => _kPrismRamps[a] ?? _kPrismRamps.values.first;

// Тройка ДЛЯ ШЕЙДЕРА фона — отдельная от той, что красит оболочку, и это не
// небрежность. Цвета интерфейса приглушены нарочно: по ним идёт белый текст.
// Шейдер же домножает цвет на светимость (`col * lum`), которая почти везде
// меньше единицы, — приглушённый вход выходит из него грязью, а не авророй.
// В прототипе у фона своя палитра, вот она, число в число:
//
//     Индиго     0.66,0.33,0.97 · 0.39,0.40,0.95 · 0.13,0.83,0.93
//     Аквамарин  0.16,0.52,0.78 · 0.20,0.82,0.76 · 0.42,0.40,0.92
//     Закат      0.86,0.34,0.52 · 0.95,0.55,0.32 · 0.62,0.30,0.86
//
// Четвёртой в прототипе нет — «Мята» собрана в том же регистре, чтобы выбор
// акцента не оставлял один вариант без своего неба.
const Map<PrismAccent, PrismRamp> _kPrismAuroraPal = {
  PrismAccent.google:
      PrismRamp(Color(0xFFA854F7), Color(0xFF6366F2), Color(0xFF21D4ED)),
  PrismAccent.aurora:
      PrismRamp(Color(0xFF2985C7), Color(0xFF33D1C2), Color(0xFF6B66EB)),
  PrismAccent.sunset:
      PrismRamp(Color(0xFFDB5785), Color(0xFFF28C52), Color(0xFF9E4DDB)),
  PrismAccent.mint:
      PrismRamp(Color(0xFF1CD999), Color(0xFF3DB3CC), Color(0xFF7378E6)),
};

/// Небо авроры по выбранному акценту.
PrismRamp _prismAuroraPal(PrismAccent a) =>
    _kPrismAuroraPal[a] ?? _kPrismAuroraPal.values.first;

PrismRamp _auroraPal(BuildContext c) => _prismAuroraPal(_tokens(c).accent);

// Активная тройка по контексту — для градиентов оболочки «Призмы».
PrismRamp _ramp(BuildContext c) => _prismRamp(_tokens(c).accent);

// Поверхности «Призмы». ВАЖНО: `card` здесь непрозрачный (`--solid` макета), а
// не полупрозрачное стекло `--card`. Слот `card` уходит в общие диалоги, меню,
// подсказки и снекбары (см. _buildTheme), и полупрозрачная заливка сделала бы
// их сквозными поверх чужих окон. Само стекло живёт в PrismPanel, который
// читает prismGlass, — ровно там, где прототип ставит backdrop-filter.
_Palette _prismDarkPal(PrismRamp r) => _Palette(
      bg: const Color(0xFF07080C),
      card: const Color(0xFF111319),
      card2: const Color(0xFF161922),
      txt: const Color(0xFFF2F4F8),
      // Второстепенный текст СВЕТЛЕЕ, чем задумано в токенах макета, и это
      // вынужденно: в макете он лежит на почти чёрной странице, а здесь под
      // ним живая аврора, и #666C79 на её светлом месте пропадал целиком.
      // Иерархия сохранена — подпись, пояснение и подсказка по-прежнему трёх
      // разных тонов, просто весь ряд поднят.
      sub: const Color(0xFFC6CBD6),
      accent: r.a2,
      stroke: const Color(0x17FFFFFF),
      body: const Color(0xFFDEE2EA),
      faint: const Color(0xFFA9AFBD),
      success: const Color(0xFF34D399),
      danger: const Color(0xFFFF7A7A),
      info: r.a1,
      warn: const Color(0xFFF5B944),
      brightness: Brightness.dark,
    );

_Palette _prismLightPal(PrismRamp r) => _Palette(
      bg: const Color(0xFFEEF2F8),
      card: const Color(0xFFFFFFFF),
      card2: const Color(0xFFF6F8FC),
      txt: const Color(0xFF17181B),
      sub: const Color(0xFF474C57),
      accent: r.a2,
      stroke: const Color(0xFFD2DAE8),
      body: const Color(0xFF33373E),
      faint: const Color(0xFF6B7079),
      // Светлая тема берёт НЕ те же success/danger/warn, что тёмная: зелёный
      // #34D399 и жёлтый #F5B944 на белом почти не читаются.
      success: const Color(0xFF12876A),
      danger: const Color(0xFFC64545),
      info: r.a1,
      warn: const Color(0xFFB8862A),
      brightness: Brightness.light,
    );

// Тёплая тёмная: геометрия и акценты «Призмы» на угольных поверхностях Claude,
// чтобы третья тема осталась тёплой и в этом стиле тоже.
_Palette _prismWarmDarkPal(PrismRamp r) => _Palette(
      bg: const Color(0xFF1A1917),
      card: const Color(0xFF24231F),
      card2: const Color(0xFF2C2A26),
      txt: const Color(0xFFF2F0E9),
      sub: const Color(0xFFCFCCC2),
      accent: r.a2,
      stroke: const Color(0x1FFFFFFF),
      body: const Color(0xFFEAE7DE),
      faint: const Color(0xFFB2AFA6),
      success: const Color(0xFF34D399),
      danger: const Color(0xFFE0685E),
      info: r.a1,
      warn: const Color(0xFFE0B24A),
      brightness: Brightness.dark,
    );

// Геометрия «Призмы» (tokens.json): карточка 20, поле/контрол 13, рейка 232.
// Свечение включено на тёмных темах — оно же красит точки сетки и статусы.
AnimaSkin _prismSkin(_Palette pal, PrismRamp r) => AnimaSkin(
      pal: pal,
      accent2: r.a3,
      radiusCard: 20,
      radiusControl: 13,
      // 262px — ширина рейки в макете. Меньше нельзя: в строку помещаются
      // подпись и горячая клавиша, и на 232 они начинали толкаться.
      railWidth: 262,
      glow: pal.brightness == Brightness.dark,
    );

// Resolve the active (style × theme) skin. Classic wraps `_palFor` unchanged.
// `accent` действует только на «Призму» — единственный стиль, где акцент
// выбирает пользователь; остальные три берут его из палитры темы.
AnimaSkin skinFor(
  AppStyle style,
  AppThemeMode theme, {
  PrismAccent accent = PrismAccent.google,
}) {
  if (style == AppStyle.prism) {
    final r = _prismRamp(accent);
    switch (theme) {
      case AppThemeMode.dark:
        return _prismSkin(_prismDarkPal(r), r);
      case AppThemeMode.claude:
        return _prismSkin(_prismLightPal(r), r);
      case AppThemeMode.claudeDark:
        return _prismSkin(_prismWarmDarkPal(r), r);
    }
  }
  if (style == AppStyle.noctur) {
    switch (theme) {
      case AppThemeMode.dark:
        return _nocturSkin(_kNocturDark,
            accent2: const Color(0xFF6FB3C9), glow: true);
      case AppThemeMode.claude:
        return _nocturSkin(_kNocturClaude,
            accent2: const Color(0xFFE0956B), glow: false);
      case AppThemeMode.claudeDark:
        return _nocturSkin(_kNocturClaudeDark,
            accent2: const Color(0xFFE0B24A), glow: true);
    }
  }
  if (style == AppStyle.nexus) {
    switch (theme) {
      case AppThemeMode.dark:
        return const AnimaSkin(
          pal: _kNexusDark,
          accent2: Color(0xFF8B7CFF),
          radiusCard: 14,
          radiusControl: 10,
          railWidth: 66,
          glow: true,
          bgGlows: _kNexusDarkGlows,
        );
      case AppThemeMode.claude:
        return const AnimaSkin(
          pal: _kNexusClaude,
          accent2: Color(0xFFE0956B),
          radiusCard: 14,
          radiusControl: 10,
          railWidth: 66,
          glow: false,
        );
      case AppThemeMode.claudeDark:
        return const AnimaSkin(
          pal: _kNexusClaudeDark,
          accent2: Color(0xFFE0B24A),
          radiusCard: 14,
          radiusControl: 10,
          railWidth: 66,
          glow: true,
          glowIntensity: 0.6, // ×0.6 of Nexus-dark (TZ §5)
          bgGlows: _kNexusClaudeDarkGlows,
        );
    }
  }
  // Classic: wrap the shipped palette; metrics mirror today's defaults so any
  // future skin-routed radius equals the current value. accent2 is derived so
  // classic-only gradients (unused for now) stay on-theme.
  final p = _palFor(theme);
  return AnimaSkin(
    pal: p,
    accent2: Color.lerp(p.accent, p.info, 0.45) ?? p.accent,
    radiusCard: AnimaRadius.lg, // 18 — matches animaCard's current corner radius
    radiusControl: 10,
    railWidth: 0,
    glow: false,
  );
}

// The active tokens: from the theme where the widget sits under the app's own
// MaterialApp, from AppState otherwise. That fallback is not decoration — the
// floating widget, the tray menu and the update splash are separate windows
// built on their own bare ThemeData, and under them this stays exactly the
// path the code took before.
AppTokens _tokens(BuildContext c) {
  final t = Theme.of(c).extension<AppTokens>();
  if (t != null) return t;
  final app = c.read<AppState>();
  return AppTokens(
    skin: skinFor(app.appStyle, app.themeMode, accent: app.prismAccent),
    style: app.appStyle,
    accent: app.prismAccent,
  );
}

AnimaSkin _skin(BuildContext c) => _tokens(c).skin;

// True when the Nexus interface style is active — lets the shared evs* control
// helpers apply Nexus geometry (surface-lift segments, accent→accent2 toggles,
// info-tinted actives) while the classic style stays byte-for-byte the same.
bool _isNexus(BuildContext c) => _tokens(c).style == AppStyle.nexus;

// True in «Ноктюрн». Deliberately NOT folded into `_isNexus`: Nexus paints card
// headers / actives in the info (cyan) accent, while Noctur keeps everything on
// the single accent (TZ §5.3 — colour marks the state, nothing else), so the
// shared evs* helpers must be able to tell the two apart.
bool _isNoctur(BuildContext c) => _tokens(c).style == AppStyle.noctur;

// True в «Призме». Отдельно от двух выше по той же причине: у неё своя
// геометрия (карточка 20, контрол 13) и свой источник акцента — тройка a1/a2/a3
// вместо одного цвета темы.
bool _isPrism(BuildContext c) => _tokens(c).style == AppStyle.prism;

_Palette _pal(BuildContext c) => _skin(c).pal;

// Canonical surface/text tokens — resolve against the active theme. The
// BuildContext param is kept so the hundreds of call sites stay unchanged.
Color _bg(BuildContext c) => _pal(c).bg;
Color _card(BuildContext c) => _pal(c).card;
Color _txt(BuildContext c) => _pal(c).txt;
Color _sub(BuildContext c) => _pal(c).sub;
Color _body(BuildContext c) => _pal(c).body;
Color _faint(BuildContext c) => _pal(c).faint;
Color _accent(BuildContext c) => _pal(c).accent;
// Second accent stop (Nexus gradients / "thinking" status). Classic derives it
// from the palette, so call sites are safe in either style.
Color _accent2(BuildContext c) => _skin(c).accent2;
Color _stroke(BuildContext c) => _pal(c).stroke;
Color _card2(BuildContext c) => _pal(c).card2;
Color _success(BuildContext c) => _pal(c).success;
Color _danger(BuildContext c) => _pal(c).danger;

// --- Derived semantic tokens ---------------------------------------------
// Computed from the base tokens above, so every theme gets them for free (no
// new _Palette fields). These replace the scattered hardcoded literals that
// were invisible or wrong on the light themes.

// Hairline divider inside cards/lists — fainter than the row `stroke`. Was the
// const white-alpha `_stroke(context)`, invisible on cream.
Color _divider(BuildContext c) => _stroke(c).withValues(alpha: 0.55);

// Muted ALL-CAPS section label (card headers). Was the fixed slate 0xFF8890A8.
Color _sectionLabel(BuildContext c) => _faint(c);

// Readable text/icon on top of an accent fill — black or white by the accent's
// luminance (terracotta/indigo take white; a pale accent takes near-black).
Color _onAccent(BuildContext c) => _accent(c).computeLuminance() > 0.55
    ? const Color(0xFF141413)
    : Colors.white;

// Semantic status colours (info/warn) — tuned per brightness for contrast.
Color _info(BuildContext c) => _pal(c).info;
Color _warn(BuildContext c) => _pal(c).warn;

// Modal barrier behind dialogs/sheets.
Color _scrim(BuildContext c) => Colors.black
    .withValues(alpha: _pal(c).brightness == Brightness.dark ? 0.58 : 0.32);

// Soft theme-aware drop shadow for elevated surfaces (cards/menus/sheets).
List<BoxShadow> _shadow(BuildContext c,
        {double y = 8, double blur = 24, double a = 0.18}) =>
    [
      BoxShadow(
        color: Colors.black.withValues(
            alpha: _pal(c).brightness == Brightness.dark ? a * 1.6 : a),
        blurRadius: blur,
        offset: Offset(0, y),
      )
    ];

// --- Design scales — single source of truth for spacing / radii / type.
// Ad-hoc `fontSize:` and magic paddings migrate onto these per screen.

abstract final class AnimaSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AnimaRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 18;
  static const double pill = 999;
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
}

// Type scale. Colour is intentionally omitted — apply a token at the call site,
// e.g. `AnimaType.body.copyWith(color: _txt(context))`. Family comes from
// ThemeData (Nunito), so it is not set here.
abstract final class AnimaType {
  static const TextStyle display =
      TextStyle(fontSize: 30, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -0.3);
  static const TextStyle title =
      TextStyle(fontSize: 20, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: -0.2);
  static const TextStyle heading =
      TextStyle(fontSize: 16, height: 1.25, fontWeight: FontWeight.w700);
  static const TextStyle sectionLabel = TextStyle(
      fontSize: 11.5, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: 0.6);
  static const TextStyle body =
      TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w400);
  static const TextStyle bodyStrong =
      TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600);
  static const TextStyle label =
      TextStyle(fontSize: 13.5, height: 1.3, fontWeight: FontWeight.w600);
  static const TextStyle control =
      TextStyle(fontSize: 12.5, height: 1.2, fontWeight: FontWeight.w600);
  static const TextStyle caption =
      TextStyle(fontSize: 12, height: 1.4, fontWeight: FontWeight.w400);
  static const TextStyle mono =
      TextStyle(fontSize: 12.5, height: 1.4, fontFamily: 'monospace');
}

// Two-stop gradient derived from the theme accent — replaces the hardcoded
// blue/violet gradients on the assistant bubble, primary buttons and toggles so
// they follow each theme's accent (terracotta on Claude, blue on Apple, …).
List<Color> _accentGradientOf(BuildContext c) {
  final a = _accent(c);
  return [Color.lerp(a, Colors.white, 0.22)!, a];
}

LinearGradient _accentGradient(BuildContext c) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _accentGradientOf(c),
    );

// Subtle overlay fill / hairline that used to be a hardcoded white alpha (tuned
// for the dark shell). White-on-white is invisible on the light themes, so flip
// to a black alpha there — same visual weight on both.
Color _overlayFill(BuildContext c, double a) =>
    (_pal(c).brightness == Brightness.dark ? Colors.white : Colors.black)
        .withValues(alpha: a);

// Hero-visualization mark colour: light marks on dark themes, the theme accent
// (dark enough to read) on the light themes — the same rule ParticleSphere
// already applies inline.
Color _vizColor(BuildContext c) =>
    _pal(c).brightness == Brightness.dark ? Colors.white : _accent(c);

// Soft halo so text stays legible when it sits directly over a visualization or
// media (hero title/subtitle, the dark VoiceScreen). Dark halo on dark themes,
// light halo on light — either way it lifts the glyphs off the busy backdrop.
List<Shadow> _overTextShadows(BuildContext c) {
  final halo =
      (_pal(c).brightness == Brightness.dark ? Colors.black : Colors.white)
          .withValues(alpha: 0.6);
  return [
    Shadow(color: halo, blurRadius: 14),
    Shadow(color: halo, blurRadius: 5),
  ];
}

// Liquid Glass was removed — only the standard style ships. Kept as a no-op so
// the (now dead) glass branches at call sites still compile and render the
// standard path. TODO: physically prune those branches in a later cleanup.
bool _isGlass(BuildContext c) => false;

// Outer panel for bottom sheets / the chats drawer: a translucent blurred
// surface in glass style, a solid one otherwise. `rounded` controls the top
// corners (off for the full-height embedded chats drawer).
Widget _sheetSurface(
  BuildContext context, {
  bool rounded = true,
  Color? solid,
  required Widget child,
}) {
  final radius = rounded
      ? const BorderRadius.vertical(top: Radius.circular(24))
      : BorderRadius.zero;
  if (_isGlass(context)) {
    return GlassSurface(borderRadius: radius, child: child);
  }
  return Container(
    decoration: BoxDecoration(color: solid ?? _bg(context), borderRadius: radius),
    child: child,
  );
}

// Toggle: a true iOS CupertinoSwitch in glass style, the green Material
// Switch otherwise. Same green on/off semantics in both.
Widget _iosSwitch(
  BuildContext context,
  bool value,
  ValueChanged<bool> onChanged,
) {
  if (_isGlass(context)) {
    return CupertinoSwitch(
      value: value,
      activeTrackColor: const Color(0xFF34C759),
      onChanged: onChanged,
    );
  }
  return Switch(
    value: value,
    activeThumbColor: Colors.white,
    activeTrackColor: const Color(0xFF34C759),
    onChanged: onChanged,
  );
}

// Card-like surface used across screens (stat tiles, chat tiles, model
// cards, etc.). Glass mode → translucent blurred surface; standard mode →
// the original solid translucent _card fill (so standard is unchanged).
Widget _glassCard(
  BuildContext context, {
  required Widget child,
  double radius = 18,
  EdgeInsetsGeometry? padding,
  double alpha = 0.5,
}) {
  if (_isGlass(context)) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(radius),
      padding: padding,
      child: child,
    );
  }
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: _card(context).withValues(alpha: alpha),
      borderRadius: BorderRadius.circular(radius),
    ),
    child: child,
  );
}

class GlassMenuItem {
  final String value;
  final String label;
  final IconData? icon;
  final Color? color;
  const GlassMenuItem(this.value, this.label, {this.icon, this.color});
}

// Glass-styled context menu (used in glass mode instead of PopupMenuButton /
// showMenu, which can't backdrop-blur). Positions a GlassSurface near the
// anchor [position] (a global point), clamped on-screen, over a dismissible
// barrier. Returns the tapped item's value, or null if dismissed.
Future<String?> showGlassMenu(
  BuildContext context, {
  required Offset position,
  required List<GlassMenuItem> items,
  double menuWidth = 220,
}) {
  final size = MediaQuery.of(context).size;
  final menuHeight = items.length * 50.0 + 8;
  var left = position.dx;
  if (left + menuWidth > size.width - 8) left = size.width - 8 - menuWidth;
  if (left < 8) left = 8;
  var top = position.dy;
  if (top + menuHeight > size.height - 8) top = size.height - 8 - menuHeight;
  if (top < 8) top = 8;
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.08),
    transitionDuration: const Duration(milliseconds: 130),
    pageBuilder: (ctx, _, _) {
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: menuWidth,
            child: GlassSurface(
              borderRadius: BorderRadius.circular(16),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      InkWell(
                        onTap: () => Navigator.pop(ctx, items[i].value),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              if (items[i].icon != null) ...[
                                Icon(
                                  items[i].icon,
                                  size: 20,
                                  color: items[i].color ?? _txt(ctx),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(
                                  items[i].label,
                                  style: TextStyle(
                                    color: items[i].color ?? _txt(ctx),
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (i != items.length - 1)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: _sub(ctx).withValues(alpha: 0.14),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (ctx, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

// App-wide toast: a centered floating pill instead of the default full-width
// white SnackBar at the bottom edge. Glass mode → blurred glass pill;
// standard → solid rounded pill.
void showAppSnackBar(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.of(context);
  // Прежнее сообщение убирается сразу, а не досиживает свою очередь. Иначе два
  // одинаковых текста подряд оказываются на экране одновременно, и Flutter
  // ругается: у снекбара Hero-метка собрана из его текста, а две одинаковые
  // метки в одном поддереве запрещены («multiple heroes share the same tag»).
  messenger.hideCurrentSnackBar();
  final label = Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(color: _txt(context), fontSize: 14),
  );
  const pad = EdgeInsets.symmetric(horizontal: 18, vertical: 12);
  final pill = _isGlass(context)
      ? GlassSurface(
          borderRadius: BorderRadius.circular(18),
          padding: pad,
          child: label,
        )
      : Container(
          padding: pad,
          decoration: BoxDecoration(
            color: _card(context),
            borderRadius: BorderRadius.circular(18),
          ),
          child: label,
        );
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      // Форму задаём здесь, а не оставляем теме. У «Призмы» в snackBarTheme
      // прописан контур `--stroke2` — он и рисовался вокруг сообщения второй,
      // пустой плашкой: цвет подложки мы уже погасили, а рамка от него не
      // зависит и оставалась висеть по краю прозрачного прямоугольника.
      shape: const RoundedRectangleBorder(side: BorderSide.none),
      duration: const Duration(seconds: 2),
      content: Center(child: pill),
    ),
  );
}

// Opens the chat/personalization settings screen (normal opaque page). In
// glass style the screen gives itself an ambient colored backdrop so its
// glass tabs/cards read — see PersonalizationScreen.build.
void openPersonalization(
  BuildContext context, {
  Conversation? conversation,
  int initialTab = 0,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PersonalizationScreen(
        conversation: conversation,
        initialTab: initialTab,
      ),
    ),
  );
}

// Reusable translucent blurred surface for the Liquid Glass style. A real
// backdrop blur (so content behind shows through), a translucent fill tuned
// per brightness, and a soft top-left specular border. Used by the chat
// chrome (top bar, input bar, circle buttons), sheets, and cards when the
// glass style is on. Blur sigma is kept modest on purpose — stacking many
// BackdropFilters is expensive on weak devices.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final bool circle;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.blur = 18,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.white.withValues(alpha: 0.55);
    final highlight = dark
        ? Colors.white.withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.7);
    final shade = dark
        ? Colors.black.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.06);
    final clip = circle ? BorderRadius.circular(999) : borderRadius;
    return ClipRRect(
      borderRadius: clip,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: clip,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(highlight.withValues(alpha: 0.10), fill),
                fill,
                Color.alphaBlend(shade, fill),
              ],
            ),
            border: Border.all(color: highlight, width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

// Soft ambient colored glow used as the backdrop for glass screens (e.g. the
// chat-settings tabs), so the translucent glass surfaces above have a
// non-uniform background to refract. Three big blurred color blobs over the
// theme background.
class AmbientGlow extends StatelessWidget {
  const AmbientGlow({super.key});

  Widget _blob(Color c, double size) => ImageFiltered(
    imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final a = dark ? 0.55 : 0.30;
    return Container(
      color: _bg(context),
      child: Stack(
        children: [
          Positioned(
            left: -50,
            top: 140,
            child: _blob(const Color(0xFF3C78FF).withValues(alpha: a), 360),
          ),
          Positioned(
            right: -40,
            top: 120,
            child: _blob(const Color(0xFF9B5AFF).withValues(alpha: a), 320),
          ),
          Positioned(
            left: 150,
            top: 180,
            child: _blob(const Color(0xFF28C8B4).withValues(alpha: a), 240),
          ),
        ],
      ),
    );
  }
}

// Dialog that adopts the Liquid Glass look (translucent blurred surface) when
// the glass style is on, and the normal solid AlertDialog otherwise. Mirrors
// the AlertDialog API (title/content/actions/backgroundColor) so call sites
// are a drop-in swap.
class _AppDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  const _AppDialog({
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!_isGlass(context)) {
      return AlertDialog(
        title: title,
        content: content,
        actions: actions,
        backgroundColor: backgroundColor ?? _card(context),
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(28),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              DefaultTextStyle.merge(
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
                child: title!,
              ),
            if (title != null && content != null) const SizedBox(height: 14),
            if (content != null)
              Flexible(child: SingleChildScrollView(child: content!)),
            if (actions != null && actions!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class GlassTab {
  final String label;
  final IconData icon;
  const GlassTab({required this.label, required this.icon});
}

// Liquid Glass (iOS 26) segmented control: a frosted capsule with a floating
// active pill that slides between tabs. Ported from the project's reference
// design; label/icon colors adapt to the theme so it works on light too.
class LiquidGlassTabs extends StatelessWidget {
  const LiquidGlassTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    this.height = 58,
    this.accent = const Color(0xFF2F8DFF),
    this.blurSigma = 18,
    this.animationDuration = const Duration(milliseconds: 320),
  });

  final List<GlassTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final double height;
  final Color accent;
  final double blurSigma;
  final Duration animationDuration;

  @override
  Widget build(BuildContext context) {
    final radius = height / 2;
    const pad = 5.0;
    final pillRadius = radius - pad;
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: const EdgeInsets.all(pad),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.05),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: _ActivePill(
                    count: tabs.length,
                    index: selectedIndex,
                    radius: pillRadius,
                    duration: animationDuration,
                    accent: accent,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(pillRadius),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [
                            Colors.white.withValues(alpha: 0.12),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: _LiquidTabLabels(
                    tabs: tabs,
                    selectedIndex: selectedIndex,
                    onChanged: onChanged,
                    accent: accent,
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

class _ActivePill extends StatelessWidget {
  const _ActivePill({
    required this.count,
    required this.index,
    required this.radius,
    required this.duration,
    required this.accent,
  });

  final int count;
  final int index;
  final double radius;
  final Duration duration;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final align = count <= 1 ? 0.0 : (index / (count - 1)) * 2 - 1;
    final glassTop = Color.lerp(Colors.white, accent, 0.10)!;
    final glassBottom = Color.lerp(Colors.white, accent, 0.18)!;
    return AnimatedAlign(
      alignment: Alignment(align, 0),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: FractionallySizedBox(
        widthFactor: 1 / count,
        heightFactor: 1,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                glassTop.withValues(alpha: 0.60),
                glassBottom.withValues(alpha: 0.30),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.50),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.18),
                blurRadius: 1,
                offset: const Offset(0, -1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiquidTabLabels extends StatelessWidget {
  const _LiquidTabLabels({
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    required this.accent,
  });

  final List<GlassTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final idle = _sub(context);
    return Row(
      children: List.generate(tabs.length, (i) {
        final selected = i == selectedIndex;
        return Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(i),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tabs[i].icon,
                    size: 18,
                    color: selected ? accent : idle,
                  ),
                  const SizedBox(width: 8),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: selected ? _txt(context) : idle,
                    ),
                    child: Text(tabs[i].label),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

/* ============================ СФЕРА ИЗ ЧАСТИЦ ============================ */

class ParticleSphere extends StatefulWidget {
  final double size;
  final Color color;
  final bool dense;
  final bool active;
  final bool scattered;
  // Splash "immersion" progress (0..1): the sphere swells toward the viewer
  // and its particles stream smoothly outward along their own radial
  // direction while fading — "flying into" the sphere. Distinct from
  // `scattered`, which is the chaotic keyboard-scatter. Driven externally by
  // ImmersiveSplash's controller, not the internal disperse animation.
  final double immerse;
  // Optional live microphone level (smoothed, 0..1) — when provided, the
  // sphere's pulse, particle brightness, and jitter speed react to it.
  final ValueListenable<double>? soundLevel;
  const ParticleSphere({
    super.key,
    this.size = 220,
    this.color = Colors.white,
    this.dense = false,
    this.active = false,
    this.scattered = false,
    this.immerse = 0.0,
    this.soundLevel,
  });

  @override
  State<ParticleSphere> createState() => _ParticleSphereState();
}

class _ParticleSphereState extends State<ParticleSphere>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AnimationController _disperseCtrl;
  late final AmbientMotion _ambient;
  late final List<_P> _points;

  @override
  void initState() {
    super.initState();
    // Hundreds of particles repainted every frame — by far the heaviest ambient
    // loop, so it only spins while MotionPolicy allows it.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    _ambient = AmbientMotion(_ctrl);
    _disperseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: widget.scattered ? 1.0 : 0.0,
    );
    final rnd = math.Random(7);
    final count = widget.dense ? 560 : 300;
    _points = List.generate(count, (_) {
      final u = rnd.nextDouble();
      final v = rnd.nextDouble();
      final theta = 2 * math.pi * u;
      final phi = math.acos(2 * v - 1);
      return _P(
        theta,
        phi,
        0.6 + rnd.nextDouble() * 1.8,
        rnd.nextDouble(),
        0.25 + rnd.nextDouble() * 0.85,
      );
    });
  }

  @override
  void didUpdateWidget(ParticleSphere old) {
    super.didUpdateWidget(old);
    if (widget.scattered != old.scattered) {
      if (widget.scattered) {
        _disperseCtrl.forward();
      } else {
        _disperseCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ambient.dispose();
    _ctrl.dispose();
    _disperseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final soundLevel = widget.soundLevel;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: soundLevel == null
            ? Listenable.merge([_ctrl, _disperseCtrl])
            : Listenable.merge([_ctrl, _disperseCtrl, soundLevel]),
        builder: (_, __) => CustomPaint(
          painter: _SpherePainter(
            _points,
            _ctrl.value,
            widget.color,
            widget.active,
            Curves.easeOutCubic.transform(_disperseCtrl.value),
            soundLevel?.value ?? 0.0,
            widget.immerse,
          ),
        ),
      ),
    );
  }
}

class _P {
  final double theta, phi, radius, seed, brightness;
  _P(this.theta, this.phi, this.radius, this.seed, this.brightness);
}

class _SpherePainter extends CustomPainter {
  final List<_P> points;
  final double t;
  final Color color;
  final bool active;
  final double disperse;
  // Smoothed microphone level, 0 (silence) .. 1 (loud). Only meaningful
  // while [active] is true; drives extra pulse, brightness and per-particle
  // jitter on top of the constant idle rotation/breathing.
  final double level;
  // Splash immersion 0..1 — sphere swells past the viewer and particles
  // stream smoothly outward (radially) while fading. See ParticleSphere.immerse.
  final double immerse;
  _SpherePainter(
    this.points,
    this.t,
    this.color,
    this.active,
    this.disperse,
    this.level,
    this.immerse,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseR = size.width / 2 * 0.92;
    final imm = immerse.clamp(0.0, 1.0);
    // The sphere balloons toward the viewer as immersion ramps up (quadratic
    // for an accelerating "fly-in"); every particle rides this larger radius
    // outward along its own direction, so they stream past the edges smoothly
    // instead of scattering randomly.
    final R = baseR * (1 + imm * imm * 6);
    final rotY = t * 2 * math.pi;
    // React to sound whenever a level is present — previously this was gated on
    // `active` (the voice screen's listening flag), which only that screen set,
    // so every other sphere ignored its soundLevel and sat static during
    // speech. `active` still enables the idle breathing pulse on its own.
    final reactive = level.clamp(0.0, 1.0);
    final pulse = (active || reactive > 0.01)
        ? (0.92 + 0.08 * math.sin(t * 2 * math.pi * 3) + reactive * 0.22)
        : 1.0;
    // Louder input makes particles jitter faster around their resting spot.
    final jitterPhase = t * 2 * math.pi * (8 + reactive * 30);

    if (disperse < 1.0) {
      final glow = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(
              alpha: 0.18 * (1 - disperse) * (1 - imm) * (1 + reactive),
            ),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: R));
      canvas.drawCircle(center, R, glow);
    }

    final paint = Paint();
    for (final p in points) {
      double x = math.sin(p.phi) * math.cos(p.theta);
      double y = math.sin(p.phi) * math.sin(p.theta);
      double z = math.cos(p.phi);

      final cx = x * math.cos(rotY) + z * math.sin(rotY);
      final cz = -x * math.sin(rotY) + z * math.cos(rotY);
      x = cx;
      z = cz;

      final scale = (z + 1.5) / 2.5;
      double px = center.dx + x * R * pulse;
      double py = center.dy + y * R * pulse;

      if (reactive > 0) {
        final jitterAngle = jitterPhase + p.seed * 2 * math.pi;
        final jitterDist = reactive * p.radius * 2.4 * p.seed;
        px += math.cos(jitterAngle) * jitterDist;
        py += math.sin(jitterAngle) * jitterDist;
      }

      if (disperse > 0) {
        final dirAngle = p.seed * 2 * math.pi * 5.3;
        final dist = (0.5 + p.seed * 2.2) * R * disperse;
        px += math.cos(dirAngle) * dist;
        py += math.sin(dirAngle) * dist;
      }

      final opacity =
          ((0.25 + 0.75 * scale) *
                  p.brightness *
                  (1 - disperse) *
                  (1 - imm) *
                  (1 + reactive * 0.6))
              .clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(
        Offset(px, py),
        p.radius *
            scale *
            (1 - disperse * 0.3) *
            (1 + imm * 0.8) *
            (1 + reactive * 0.35),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpherePainter old) => true;
}

/* ============================ АНИМИРОВАННАЯ ОБВОДКА (УЛУЧШЕННАЯ) ============================ */

class GradientBorderPainter extends CustomPainter {
  final Animation<double> animation;
  final double radius;
  final double strokeWidth;
  final bool enabled;

  GradientBorderPainter({
    required this.animation,
    this.radius = 30,
    this.strokeWidth = 2,
    this.enabled = true,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !enabled) return;
    final rect = Offset.zero & size;

    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.blue.withValues(alpha: 0.8),
          Colors.purple.withValues(alpha: 0.8),
          Colors.blue.withValues(alpha: 0.8),
        ],
        transform: GradientRotation(animation.value * 2 * math.pi),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    // Stroke is centered on the full bounds (not inset), so half of it
    // bleeds outside the canvas where the opaque child can't cover it —
    // that's the only part of the ring that ends up visible.
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant GradientBorderPainter oldDelegate) => true;
}

// A soft, blurred halo of the same rotating border gradient, painted wider
// and behind the crisp ring so light appears to scatter inward from the
// edges toward the center instead of stopping sharply at the border line.
class BorderGlowPainter extends CustomPainter {
  final Animation<double> animation;
  final double radius;
  final double strokeWidth;
  final double blurSigma;

  BorderGlowPainter({
    required this.animation,
    this.radius = 30,
    this.strokeWidth = 50,
    this.blurSigma = 35,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.blue.withValues(alpha: 0.4),
          Colors.purple.withValues(alpha: 0.4),
          Colors.blue.withValues(alpha: 0.4),
        ],
        transform: GradientRotation(animation.value * 2 * math.pi),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma)
      ..isAntiAlias = true;

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant BorderGlowPainter oldDelegate) => true;
}

const kAccentGradientColors = [Color(0xFF4FACFE), Color(0xFF2F6BFF)];
const kSendActiveColor = Color(0xFF1ED760);

class GradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const GradientSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final trackRadius = Radius.circular(trackRect.height / 2);
    final activeTrackRadius = Radius.circular(
      (trackRect.height + additionalActiveTrackHeight) / 2,
    );

    final inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? Colors.white12;
    context.canvas.drawRRect(
      RRect.fromLTRBR(
        thumbCenter.dx,
        trackRect.top,
        trackRect.right,
        trackRect.bottom,
        trackRadius,
      ),
      inactivePaint,
    );

    final activeRect = RRect.fromLTRBR(
      trackRect.left,
      trackRect.top - (additionalActiveTrackHeight / 2),
      thumbCenter.dx,
      trackRect.bottom + (additionalActiveTrackHeight / 2),
      activeTrackRadius,
    );
    final activePaint = Paint()
      ..shader = const LinearGradient(
        colors: kAccentGradientColors,
      ).createShader(activeRect.outerRect);
    context.canvas.drawRRect(activeRect, activePaint);
  }
}

class AnimatedBorder extends StatefulWidget {
  final Widget child;
  final double radius;
  final double strokeWidth;
  final bool enabled;

  const AnimatedBorder({
    super.key,
    required this.child,
    this.radius = 28,
    this.strokeWidth = 2,
    this.enabled = true,
  });

  @override
  State<AnimatedBorder> createState() => _AnimatedBorderState();
}

class _AnimatedBorderState extends State<AnimatedBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AmbientMotion _ambient;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _ambient = AmbientMotion(_ctrl);
  }

  @override
  void dispose() {
    _ambient.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: _sub(context).withValues(alpha: 0.3),
            width: widget.strokeWidth,
          ),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      );
    }
    return RepaintBoundary(
      child: Padding(
        // Reserves room for the half of the stroke that bleeds outside the
        // painted bounds (see GradientBorderPainter) so it isn't clipped.
        padding: EdgeInsets.all(widget.strokeWidth / 2),
        child: CustomPaint(
          painter: GradientBorderPainter(
            animation: _ctrl,
            radius: widget.radius,
            strokeWidth: widget.strokeWidth,
            enabled: widget.enabled,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/* ============================ ГЛАВНЫЙ ЭКРАН ============================ */

/* ======================= EVS DESKTOP UI (Windows) =======================
   Desktop shell from the EVS mockups (evs_ui.html / evs_s*.html): a left
   sidebar (history + System/Mic widgets) plus the existing chat screen
   embedded on the right (ChatScreen(desktop: true)), so the animated
   composer, the particle orb and all send/voice logic are reused as-is. */

// Mockup palette: violet accent + blue→purple→pink gradient on near-black.
const Color _animaGMid = Color(0xFF8855CC);
// ---- Ambient-motion policy -------------------------------------------------
// The always-looping decorative animations (particle sphere, animated borders,
// idle visualizer sweeps) were the app's single biggest idle cost: several 60fps
// CustomPainter repaints running whether or not anything was happening —
// measured at ~1.3 cores with the app sitting idle. They are now gated centrally
// so they only run when they actually convey something.
//
//   full     — always animate (the old behaviour)
//   balanced — animate only while the assistant is active AND the window is
//              visible; otherwise hold a static frame (default)
//   saver    — never run ambient loops
//
// Activity-driven visuals (levels reacting to speech) keep updating regardless;
// this only governs the decorative loops.
class MotionPolicy {
  MotionPolicy._();

  /// Whether ambient loops may run right now.
  static final ValueNotifier<bool> ambient = ValueNotifier<bool>(true);

  /// Гейт для анимаций ПЕРЕДНЕГО ПЛАНА — тех, что сами по себе являются
  /// содержимым экрана, а не украшением фона: кольцо-визуализатор «Ноктюрна»
  /// и знак Genesis на странице «О программе». Они идут, пока окно на экране,
  /// и не ждут активности ассистента: замереть в упор на смысловом центре
  /// экрана — это выглядит поломкой, а не экономией. Гасит их только «Экономная»
  /// и скрытое окно.
  static final ValueNotifier<bool> foreground = ValueNotifier<bool>(true);

  /// Whether the main window is really on screen. With the floating widget
  /// enabled (default) the app boots with the window HIDDEN, so anything that
  /// must be *seen* to make sense — the startup splash above all — waits for
  /// this instead of starting at process start.
  static final ValueNotifier<bool> windowShown = ValueNotifier<bool>(true);

  static String _mode = 'balanced';
  static bool _visible = true;
  static bool _active = false;

  static String get mode => _mode;

  static void setMode(String m) {
    _mode = (m == 'full' || m == 'saver') ? m : 'balanced';
    _recompute();
  }

  static void setWindowVisible(bool v) {
    if (_visible == v) return;
    _visible = v;
    windowShown.value = v;
    _recompute();
  }

  /// The assistant is listening / thinking / speaking.
  static void setActive(bool a) {
    if (_active == a) return;
    _active = a;
    _recompute();
  }

  // Any activity signal marks the app active and schedules a decay back to
  // idle; the grace period keeps animations from flickering off between
  // consecutive spoken sentences.
  static Timer? _decay;
  static void poke() {
    _decay?.cancel();
    _decay = Timer(const Duration(seconds: 4), () => setActive(false));
    setActive(true);
  }

  /// Wire the activity sources once at startup: assistant speech level, the
  /// voice-assistant state machine, wake-word hits and a loud microphone.
  /// Plain continuous wake-word listening does NOT count as activity — that is
  /// exactly the idle state the balanced mode is meant to quiet down.
  static void bindSignals() {
    VoiceLevels.instance.tts.addListener(() {
      if (VoiceLevels.instance.tts.value > 0.001) poke();
    });
    VoiceAssistant.instance.state.addListener(() {
      switch (VoiceAssistant.instance.state.value) {
        case VaState.armed:
        case VaState.thinking:
        case VaState.running:
          poke();
        case VaState.idle:
        case VaState.listening:
          break;
      }
    });
    VoiceAssistant.instance.wakeActive.addListener(() {
      if (VoiceAssistant.instance.wakeActive.value) poke();
    });
    MicMeter.instance.level.addListener(() {
      if (MicMeter.instance.level.value > 0.06) poke();
    });
  }

  static void _recompute() {
    // Never animate an invisible window, whatever the mode.
    final v = switch (_mode) {
      'full' => _visible,
      'saver' => false,
      _ => _visible && _active,
    };
    if (ambient.value != v) ambient.value = v;
    final f = _mode == 'saver' ? false : _visible;
    if (foreground.value != f) foreground.value = f;
  }
}

/// Какой гейт [MotionPolicy] держит анимацию.
enum MotionGate {
  /// Фоновое украшение: только пока движение разрешено целиком
  /// ([MotionPolicy.ambient]) — по умолчанию это «пока ассистент активен».
  ambient,

  /// Содержимое экрана ([MotionPolicy.foreground]): идёт, пока окно видно;
  /// гасит только «Экономная».
  foreground,

  /// Ничем не гасится (заставка запуска, окно установки обновления).
  none,
}

/// Binds an [AnimationController] to [MotionPolicy]: repeats while its gate
/// allows motion, holds the current frame otherwise. Dispose with the State.
class AmbientMotion {
  AmbientMotion(this._c, {this.gate = MotionGate.ambient}) {
    _flag.addListener(_sync);
    _sync();
  }
  final AnimationController _c;
  final MotionGate gate;

  ValueNotifier<bool> get _flag => gate == MotionGate.foreground
      ? MotionPolicy.foreground
      : MotionPolicy.ambient;

  void _sync() {
    if (gate == MotionGate.none || _flag.value) {
      if (!_c.isAnimating) _c.repeat();
    } else if (_c.isAnimating) {
      _c.stop();
    }
  }

  void dispose() => _flag.removeListener(_sync);
}

// Tint a colour toward white (positive) or black (negative) by `amount`.
// The shell/rail gradients are DERIVED from the theme background with this, so
// every dark theme keeps the same "radial highlight, darker edges" character in
// its own hue — previously they were hardcoded navy, which made the warm Claude
// dark theme fall back to the plain dark theme's cold background.
Color _shade(Color base, double amount) => amount >= 0
    ? Color.alphaBlend(Colors.white.withValues(alpha: amount), base)
    : Color.alphaBlend(Colors.black.withValues(alpha: -amount), base);

// Shell window background: a radial highlight over the themed background on dark
// themes; on the light themes (apple/claude) a flat themed page background so
// the whole shell reads as light instead of a dark plate.
BoxDecoration _animaShellBg(BuildContext c) {
  final p = _pal(c);
  // «Ноктюрн» differs from Nexus by the LAYOUT, not the palette, and its
  // background is deliberately flat — no radial highlight, no glow spots
  // (Noctur TZ §4.1).
  if (_isNoctur(c)) return BoxDecoration(color: p.bg);
  // «Призма» рисует свой фон отдельным слоем (пятна или шейдер), и радиальный
  // высвет под ним дал бы два источника света в одном окне.
  if (_isPrism(c)) return BoxDecoration(color: p.bg);
  if (p.brightness != Brightness.dark) return BoxDecoration(color: p.bg);
  return BoxDecoration(
    gradient: RadialGradient(
      center: const Alignment(0.2, -0.7),
      radius: 1.2,
      colors: [_shade(p.bg, 0.05), p.bg, _shade(p.bg, -0.28)],
      stops: const [0.0, 0.45, 1.0],
    ),
  );
}

/// Одна область студии (рейка · холст · параметры). В классике, Nexus и
/// «Ноктюрне» это просто содержимое с разделительной линией сбоку; в «Призме» —
/// самостоятельная стеклянная панель, потому что макет расставляет их именно
/// так: три плитки на фоне, а не три колонки одной плоскости.
///
/// [divider] — с какой стороны рисовать линию в остальных стилях. В «Призме»
/// она не рисуется вовсе: у панели уже есть свой контур.
Widget animaStudioPane(
  BuildContext context, {
  required Widget child,
  required EdgeInsets padding,
  double? width,
  BorderSide? left,
  BorderSide? right,
}) {
  if (_isPrism(context)) {
    final pane = PrismPanel(
      radius: 26,
      padding: padding,
      shadow: true,
      child: child,
    );
    return width == null ? pane : SizedBox(width: width, child: pane);
  }
  return Container(
    width: width,
    padding: padding,
    decoration: BoxDecoration(
      border: Border(
        left: left ?? BorderSide.none,
        right: right ?? BorderSide.none,
      ),
    ),
    child: child,
  );
}

/// Подложка ОКНА целиком. Три стиля обходятся заливкой из [_animaShellBg];
/// «Призме» нужны ещё два слоя под интерфейсом — фон-аврора и сетка точек, —
/// а декорация их дать не может. Поэтому все окна (главное, настройки, обе
/// студии) заворачивают содержимое сюда, а не в голый Container: иначе стиль
/// был бы только в главном окне, а настройки открывались бы плоскими.
///
/// Порядок слоёв тот же и обязателен: фон → сетка точек → интерфейс.
Widget animaShellBackdrop(BuildContext context, Widget child) {
  if (!_isPrism(context)) {
    return Container(decoration: _animaShellBg(context), child: child);
  }
  return Container(
    color: _bg(context),
    child: Stack(
      children: [
        const Positioned.fill(child: _PrismBackdrop()),
        const Positioned.fill(child: _PrismDotGrid()),
        Positioned.fill(child: child),
      ],
    ),
  );
}

// Left nav rail / sidebar background: a subtly darker vertical gradient of the
// themed background on dark themes, a flat themed card surface on light.
BoxDecoration _animaRailBg(BuildContext c) {
  final p = _pal(c);
  // «Призма»: рейка прозрачная, отделена только волосяной линией — ровно как
  // боковое меню оболочки. Заливка здесь закрыла бы фон-аврору, и окно
  // настроек выглядело бы вырезанным из другого приложения.
  if (_isPrism(c)) {
    return BoxDecoration(
      border: Border(right: BorderSide(color: p.stroke)),
    );
  }
  return BoxDecoration(
    border: Border(right: BorderSide(color: _stroke(c))),
    gradient: p.brightness == Brightness.dark
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_shade(p.bg, -0.12), _shade(p.bg, -0.28)],
          )
        : null,
    color: p.brightness == Brightness.dark ? null : _card(c),
  );
}

// The brand mark: the Genesis sign (variant 05 of genesis/EVS Animations.dc.html)
// — a live CustomPainter, not a bitmap. Every mount replays the sign's own
// entrance (flash → ring → event horizon → doppler flare → orbits → swooshes →
// glitch), then it keeps breathing with the sample's endless loop for as long as
// MotionPolicy allows it. Keeps a `const` constructor so the existing
// `const _AnimaLogoMark(...)` call sites stay valid unchanged.
//
// [gate] — чем гасится вечный луп. Марка в углу окна остаётся фоновым
// украшением (MotionGate.ambient), а знак на странице «О программе» — это сам
// экран, туда идёт MotionGate.foreground: страницу открывают ради него.
class _AnimaLogoMark extends StatelessWidget {
  final double size;
  final MotionGate gate;
  const _AnimaLogoMark({this.size = 30, this.gate = MotionGate.ambient});

  @override
  Widget build(BuildContext context) => GenesisLogo(size: size, gate: gate);
}


Widget animaCard(
  BuildContext context, {
  required IconData icon,
  required String title,
  required List<Widget> rows,
}) {
  // «Призма»: карточка — стеклянная панель с одним заголовком в разрядку.
  // Ни рамки под шапкой, ни цветного квадрата с иконкой: в макете карточки
  // разделены воздухом, а не линиями, и иконка внутри карточки там не
  // встречается ни разу. Строки при этом те же самые — animaRow сам знает, как
  // выглядеть в этом стиле.
  if (_isPrism(context)) {
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismSectionLabel(title, size: 10.5),
          const SizedBox(height: 12),
          ...rows,
        ],
      ),
    );
  }
  return Container(
    decoration: BoxDecoration(
      // Card corner radius comes from the active skin: 18 (classic) / 14 (Nexus).
      borderRadius: BorderRadius.circular(_skin(context).radiusCard),
      color: _overlayFill(context, 0.033),
      border: Border.all(color: _stroke(context)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 13, 18, 11),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _divider(context))),
          ),
          child: Row(
            children: [
              Builder(builder: (context) {
                // Nexus card headers use the info (cyan) accent (§5.3); classic
                // keeps the primary accent.
                final hc = _isNexus(context) ? _info(context) : _accent(context);
                return Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    borderRadius: AnimaRadius.rSm,
                    color: hc.withValues(alpha: 0.15),
                  ),
                  child: Icon(icon, size: 13, color: hc),
                );
              }),
              const SizedBox(width: 9),
              Text(title.toUpperCase(),
                  style:
                      AnimaType.sectionLabel.copyWith(color: _sectionLabel(context))),
            ],
          ),
        ),
        ...rows,
      ],
    ),
  );
}

Widget animaRow(BuildContext context, {
  required String label,
  String? desc,
  required Widget control,
  bool stacked = false,
  Widget? below,
  bool? active,
}) {
  final prism = _isPrism(context);
  final labelCol = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: prism
            ? TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: _txt(context))
            : AnimaType.label.copyWith(color: _body(context)),
      ),
      if (desc != null) ...[
        SizedBox(height: prism ? 3 : 2),
        Text(
          desc,
          style: prism
              ? TextStyle(
                  fontSize: 11.5, height: 1.45, color: _faint(context))
              : AnimaType.caption.copyWith(color: _sub(context)),
        ),
      ],
    ],
  );
  // «Призма»: строка — отдельная карточка со своей рамкой и подложкой, а не
  // просто отступ между подписью и полем. Подпись слева, выбор справа; ярус
  // «подпись сверху, выбор во всю ширину» здесь не используется вовсе — в
  // макете таких строк нет, и от него страница вытягивалась вдвое.
  //
  // Включённая строка подсвечивается: акцентная заливка, акцентный контур и
  // трёхточечная полоса у левого края (`inset 3px 0 0 var(--a2)` в макете).
  // Что считать включённым, спрашиваем у самого элемента: тумблер знает своё
  // значение, и просить его отдельным параметром на каждой из сотен строк
  // значило бы разойтись с ним на первой же забытой.
  if (_isPrism(context)) {
    final on = active ?? (control is PrismToggle ? control.value : false);
    final r = _ramp(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          gradient: on
              ? LinearGradient(
                  begin: const Alignment(-1, -0.35),
                  end: const Alignment(1, 0.35),
                  colors: [
                    r.a2.withValues(alpha: _prismDark(context) ? 0.26 : 0.28),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.88],
                )
              : null,
          color: on ? null : _prismField(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: on ? r.a2.withValues(alpha: 0.42) : _stroke(context)),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // Доли 54/46 — из макета, и обе ДОЛЖНЫ быть тугими.
                    // С Flexible подпись сжималась до своей ширины, остаток
                    // уходил в конец строки, а выбор уезжал за ней к середине
                    // карточки — Align внутри выравнивал его по правому краю
                    // пустоты, а не карточки.
                    Expanded(flex: 54, child: labelCol),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 46,
                      child: Align(
                          alignment: Alignment.centerRight, child: control),
                    ),
                  ],
                ),
                if (below != null) ...[
                  const SizedBox(height: 11),
                  below,
                ],
              ],
            ),
            if (on)
              Positioned(
                left: -16,
                top: -14,
                bottom: -14,
                child: Container(width: 3, color: r.a2),
              ),
          ],
        ),
      ),
    );
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: _stroke(context))),
    ),
    // Stacked: label on top, control full-width below (used for wide
    // segmented selectors so they don't fold into a floating block). Inline:
    // label left, control bounded on the right.
    child: stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              labelCol,
              const SizedBox(height: 11),
              control,
            ],
          )
        : Row(
            children: [
              Expanded(flex: 3, child: labelCol),
              const SizedBox(width: 12),
              // Bound the control so a long select can't squeeze the label.
              Flexible(
                flex: 2,
                child: Align(alignment: Alignment.centerRight, child: control),
              ),
            ],
          ),
  );
}

// Full-width segmented selector: equal-width pills in a single row that fills
// the available width (used with `animaRow(context, stacked: true)`). Replaces the
// right-aligned Wrap that folded 3–4 options into a cramped floating block.
// Active-segment decoration for the segmented controls. Classic: accent-tinted
// fill + border. Nexus (§5.4): the active pill lifts to the surface colour with
// a soft shadow (no accent wash), matching the mockup's "raised tab" look.
BoxDecoration _segActiveDeco(BuildContext context, bool selected, bool nexus) {
  if (!selected) {
    return BoxDecoration(borderRadius: BorderRadius.circular(8));
  }
  if (nexus) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      color: _pal(context).card2,
      boxShadow: [
        BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 1)),
      ],
    );
  }
  return BoxDecoration(
    borderRadius: BorderRadius.circular(8),
    color: _accent(context).withValues(alpha: 0.22),
    border: Border.all(color: _accent(context).withValues(alpha: 0.45)),
  );
}

Widget animaSegmentedWide<T>(
  BuildContext context,
  List<(T, String)> options,
  T value,
  ValueChanged<T> onChanged,
) {
  // «Призма» рисует сегменты своей формой: подложка чипа, выбранный — мягкой
  // акцентной заливкой с контуром акцента.
  if (_isPrism(context)) {
    return PrismSegmented<T>(
        options: options, value: value, onChanged: onChanged);
  }
  final nexus = _isNexus(context);
  return Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(11),
      color: _overlayFill(context, 0.055),
      border: Border.all(color: _stroke(context)),
    ),
    child: Row(
      children: [
        for (int i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(options[i].$1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                alignment: Alignment.center,
                decoration: _segActiveDeco(context, options[i].$1 == value, nexus),
                child: Text(options[i].$2,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: options[i].$1 == value
                            ? _txt(context)
                            : _sub(context))),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

Widget animaSegmented<T>(
  BuildContext context,
  List<(T, String)> options,
  T value,
  ValueChanged<T> onChanged,
) {
  if (_isPrism(context)) {
    return PrismSegmented<T>(
        options: options, value: value, onChanged: onChanged, compact: true);
  }
  final nexus = _isNexus(context);
  return Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(11),
      color: _overlayFill(context, 0.055),
      border: Border.all(color: _stroke(context)),
    ),
    // Wrap (not Row) so the options flow onto a second line in narrow cards
    // instead of overflowing.
    child: Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.end,
      children: [
        for (final o in options)
          GestureDetector(
            onTap: () => onChanged(o.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: _segActiveDeco(context, o.$1 == value, nexus),
              child: Text(o.$2,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: o.$1 == value
                          ? _txt(context)
                          : _sub(context))),
            ),
          ),
      ],
    ),
  );
}

Widget animaToggle(BuildContext context, bool value, ValueChanged<bool> onChanged) {
  // «Призма»: таблетка 46x26 с белым бегунком и градиентом акцентной тройки.
  if (_isPrism(context)) {
    return PrismToggle(value: value, onChanged: onChanged);
  }
  final skin = _skin(context);
  // «Ноктюрн» (§5.9): плоский тумблер 36×20 — контур accent и заливка accent
  // @ 22 % во включённом, без градиента и белой шайбы. Инструмент, не iOS.
  if (_isNoctur(context)) {
    final a = skin.pal.accent;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 36,
        height: 20,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: value ? a.withValues(alpha: 0.22) : Colors.transparent,
          border: Border.all(color: value ? a : skin.pal.stroke),
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? a : skin.pal.faint,
          ),
        ),
      ),
    );
  }
  // Nexus (§5.4): the "on" fill is an accent→accent2 gradient; classic keeps its
  // accent→light-accent one.
  final onGradient = _isNexus(context)
      ? LinearGradient(colors: [skin.pal.accent, skin.accent2])
      : _accentGradient(context);
  return GestureDetector(
    onTap: () => onChanged(!value),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 42,
      height: 23,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: value ? onGradient : null,
        color: value ? null : _overlayFill(context, 0.12),
        border: Border.all(
            color: value ? Colors.transparent : _stroke(context)),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.all(2),
      child: Container(
        width: 17,
        height: 17,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
      ),
    ),
  );
}

// Dropdown-styled display button (non-functional placeholder for stub selects).
Widget animaSelectButton(BuildContext context, String label, {double minWidth = 148, VoidCallback? onTap}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      constraints: BoxConstraints(minWidth: minWidth),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.06),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _body(context))),
          ),
          const SizedBox(width: 7),
          Icon(Icons.keyboard_arrow_down, size: 16, color: _faint(context)),
        ],
      ),
    ),
  );
}

Widget animaGhostButton(BuildContext context, String label, IconData icon, {VoidCallback? onTap}) {
  // «Призма»: таблетка с подложкой поля и контуром — второстепенное действие
  // рядом с настоящей кнопкой не должно спорить с ней заливкой.
  if (_isPrism(context)) {
    return _PrismGhostButton(
        icon: icon, label: label, onTap: onTap ?? () {});
  }
  return GestureDetector(
    onTap: onTap,
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.042),
        border: Border.all(color: _stroke(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: _sub(context)),
          const SizedBox(width: 6),
          Text(label, style: AnimaType.control.copyWith(color: _sub(context))),
        ],
      ),
    ),
  );
}

Widget animaSlider(BuildContext context, {
  required double value,
  required double min,
  required double max,
  int? divisions,
  required String label,
  required ValueChanged<double> onChanged,
}) {
  // «Призма»: дорожка 5px с градиентной заливкой и белым кружком. Значение
  // моноширинным справа — как в макете.
  if (_isPrism(context)) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Row(
        children: [
          Expanded(
            child: PrismSlider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              step: divisions == null || divisions == 0
                  ? null
                  : (max - min) / divisions,
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 48,
            child: Text(label,
                textAlign: TextAlign.right,
                style: PrismType.numeric.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _txt(context))),
          ),
        ],
      ),
    );
  }
  // Up to 210px wide, but shrinks to fit narrow cards (no fixed width that
  // would overflow inside animaRow's bounded control slot).
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 210),
    child: Row(
      children: [
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            // Nexus tracks the same info accent its nav/controls use (§5.4);
            // classic keeps the original accent untouched.
            activeColor: _isNexus(context) ? _info(context) : _accent(context),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 46,
          child: Text(label,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _accent(context))),
        ),
      ],
    ),
  );
}

// Full-width labelled slider (Style/Generation cards in the mockups).
Widget animaNamedSlider(BuildContext context, {
  required String label,
  String? desc,
  required double value,
  double min = 0,
  double max = 1,
  String? valueLabel,
  String? left,
  String? right,
  required ValueChanged<double> onChanged,
}) {
  return Container(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: _stroke(context))),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _body(context))),
            if (valueLabel != null)
              Text(valueLabel,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: _accent(context))),
          ],
        ),
        if (desc != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(desc,
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
          ),
        SliderTheme(
          // «Ноктюрн» (§4.4): дорожка слайдера 3 px против обычных 4.
          data: SliderThemeData(
            trackHeight: _isNoctur(context) ? 3 : 4,
            overlayShape:
                const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: _accent(context),
            inactiveColor: _overlayFill(context, 0.10),
            onChanged: onChanged,
          ),
        ),
        if (left != null || right != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(left ?? '',
                  style: TextStyle(fontSize: 11, color: _faint(context))),
              Text(right ?? '',
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ],
          ),
      ],
    ),
  );
}

// Selectable connection-mode card (Model section).
Widget animaRadioCard(BuildContext context, {
  required bool selected,
  required String title,
  required String desc,
  required VoidCallback onTap,
  Widget? extra,
}) {
  // Nexus radio-options (§5.5) use the info accent; classic keeps the primary.
  final acc = _isNexus(context) ? _info(context) : _accent(context);
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: selected ? acc.withValues(alpha: 0.1) : _overlayFill(context, 0.03),
        border: Border.all(
            color: selected ? acc.withValues(alpha: 0.35) : _stroke(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected ? acc : _faint(context), width: 2),
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: acc))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: AnimaType.label.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? _txt(context) : _body(context))),
                const SizedBox(height: 2),
                Text(desc,
                    style: AnimaType.caption
                        .copyWith(height: 1.35, color: _sub(context))),
                if (extra != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: extra,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget animaAddButton(BuildContext context, String label, VoidCallback onTap,
    {IconData icon = Icons.add, bool small = false}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 12 : 16, vertical: small ? 4 : 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _accent(context).withValues(alpha: 0.15),
        border: Border.all(color: _accent(context).withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: small ? 12 : 13, color: _accent(context)),
          const SizedBox(width: 7),
          Text(label,
              style: TextStyle(
                  fontSize: small ? 12 : 13,
                  fontWeight: FontWeight.w700,
                  color: _accent(context))),
        ],
      ),
    ),
  );
}

Widget animaDangerButton(BuildContext context, String label, VoidCallback onTap) {
  final d = _danger(context);
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: d.withValues(alpha: 0.12),
        border: Border.all(color: d.withValues(alpha: 0.32)),
      ),
      child: Text(label,
          style: AnimaType.label
              .copyWith(fontSize: 13, fontWeight: FontWeight.w700, color: d)),
    ),
  );
}

/// Доля одного целого: сегменты одной полосой плюс подписи с числами.
///
/// Стилевых цветов внутри нет — цвет каждого сегмента приходит снаружи из
/// токенов (`_success`/`_accent`/`_warn`), поэтому полоса одинаково читается
/// во всех оболочках и подхватит будущую пятую. Нули пропускаются: сегмент
/// нулевой ширины рисовался бы как щель между соседями и читался бы как
/// разделитель.
class AnimaMeterPart {
  const AnimaMeterPart(this.label, this.value, this.color);
  final String label;
  final num value;
  final Color color;
}

Widget animaMeter(
  BuildContext context,
  List<AnimaMeterPart> parts, {
  double height = 10,
  bool legend = true,
  String Function(num)? format,
}) {
  final shown = [for (final p in parts) if (p.value > 0) p];
  final total = shown.fold<double>(0, (sum, p) => sum + p.value);
  final fmt = format ?? animaThousands;

  final bar = ClipRRect(
    borderRadius: BorderRadius.circular(height / 2),
    child: SizedBox(
      height: height,
      child: total <= 0
          ? ColoredBox(color: _stroke(context))
          : Row(
              // Обязательно stretch: у Row поперечное ограничение нежёсткое, а
              // ColoredBox без ребёнка берёт наименьший допустимый размер —
              // то есть нулевую высоту. Полоса была на месте и была невидима.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in shown)
                  Expanded(
                    // flex целочисленный, поэтому доли берутся в тысячных: на
                    // 68 000 строк округление до процентов съело бы сегмент в
                    // несколько сотен строк целиком.
                    flex: math.max(1, (p.value / total * 1000).round()),
                    child: ColoredBox(color: p.color),
                  ),
              ],
            ),
    ),
  );

  if (!legend || shown.isEmpty) return bar;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      bar,
      const SizedBox(height: 9),
      Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          for (final p in shown)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: p.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${p.label} · ${fmt(p.value)}',
                  style: AnimaType.caption.copyWith(color: _sub(context)),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

/// Ряд чисел графиком: линия с заливкой либо столбики.
///
/// Столбики для того, что случилось в отдельный день (их можно пересчитать
/// глазами), линия — для величины, которая тянется во времени. Шкала снизу
/// всегда от нуля: график перевода, начатый от 60 %, показывал бы рывок там,
/// где на самом деле прибавили полпроцента.
Widget animaTrend(
  BuildContext context, {
  required List<double> values,
  bool bars = false,
  Color? color,
  double height = 64,
  double? maxValue,
  String? caption,
}) {
  final tint = color ?? _accent(context);

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: height,
        child: values.isEmpty
            ? Center(
                child: Text('—',
                    style: AnimaType.caption.copyWith(color: _faint(context))))
            : CustomPaint(
                painter: _AnimaTrendPainter(
                  values: values,
                  bars: bars,
                  color: tint,
                  grid: _stroke(context),
                  top: maxValue,
                ),
              ),
      ),
      if (caption != null && caption.isNotEmpty) ...[
        const SizedBox(height: 7),
        Text(caption,
            style: AnimaType.caption.copyWith(color: _faint(context), fontSize: 11)),
      ],
    ],
  );
}

class _AnimaTrendPainter extends CustomPainter {
  _AnimaTrendPainter({
    required this.values,
    required this.bars,
    required this.color,
    required this.grid,
    this.top,
  });

  final List<double> values;
  final bool bars;
  final Color color;
  final Color grid;
  final double? top;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 0) return;

    var ceiling = top ?? values.reduce(math.max);
    // Ровный ноль или один и тот же ноль во всех точках: рисуем шкалу до
    // единицы, чтобы линия легла по низу, а не прыгала по середине от шума.
    if (ceiling <= 0) ceiling = 1;

    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), line);

    double y(double v) =>
        size.height * (1 - (v / ceiling).clamp(0.0, 1.0));

    if (bars) {
      // Зазор пропорционален столбику, но не тоньше половины пикселя: на
      // трёх неделях столбики узкие, и фиксированный зазор съел бы их.
      final step = size.width / values.length;
      final gap = math.min(3.0, step * 0.3);
      final paint = Paint()..color = color;
      for (var i = 0; i < values.length; i++) {
        final left = i * step + gap / 2;
        final width = math.max(1.0, step - gap);
        final topY = math.min(y(values[i]), size.height - 1);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(left, topY, left + width, size.height),
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          paint,
        );
      }
      return;
    }

    final step = values.length > 1 ? size.width / (values.length - 1) : 0.0;
    Offset at(int i) => Offset(i * step, y(values[i]));

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }

    // Единственная точка линией не рисуется — ставим засечку, иначе первый
    // день измерений выглядел бы как «данных нет».
    if (values.length == 1) {
      canvas.drawCircle(Offset(size.width / 2, y(values[0])), 2.5,
          Paint()..color = color);
      return;
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_AnimaTrendPainter old) =>
      old.bars != bars ||
      old.color != color ||
      old.top != top ||
      !listEquals(old.values, values);
}

/// Число с разрядами через неразрывный пробел: 68 123, а не 68123.
String animaThousands(num value) {
  final digits = value.round().abs().toString();
  final out = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}

// App version line for the About section (real data via package_info_plus).
class _VersionText extends StatelessWidget {
  const _VersionText();
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final info = snap.data;
        final text =
            info == null ? '—' : '${info.version} · build ${info.buildNumber}';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _accent(context).withValues(alpha: 0.12),
            border: Border.all(color: _accent(context).withValues(alpha: 0.25)),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _accent(context))),
        );
      },
    );
  }
}

// Custom frameless-window title bar: a draggable region + minimize / maximize
// / close controls (the native Windows title bar is hidden via window_manager).
class _WindowTitleBar extends StatelessWidget {
  const _WindowTitleBar({this.title});

  /// Заголовок страницы, открытой поверх главного экрана. Задан — слева
  /// появляется возврат.
  ///
  /// Без него выйти со страницы нечем: в полосе стоят только кнопки окна, и
  /// единственная, похожая на выход, закрывает всё приложение. Не по
  /// `canPop()`, хотя так вышло бы само: настройки открываются тем же
  /// способом и уже носят собственную стрелку, и вторая рядом с ней была бы
  /// хуже, чем ни одной.
  final String? title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          if (title != null) ...[
            _WinBtn(Icons.arrow_back, () => Navigator.of(context).maybePop(),
                iconSize: 15),
            Text(title!,
                style: AnimaType.label
                    .copyWith(fontSize: 12.5, color: _sub(context))),
          ],
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          // Toggle the floating widget (separate transparent always-on-top
          // window with the voice visualization).
          Tooltip(
            message: context.read<AppState>().t('ovlEnter'),
            child: _WinBtn(Icons.picture_in_picture_alt_outlined, () {
              final app = context.read<AppState>();
              app.setOverlayMode(!app.overlayMode);
            }, iconSize: 14),
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
      ),
    );
  }
}

class _WinBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final double iconSize;
  const _WinBtn(this.icon, this.onTap, {this.danger = false, this.iconSize = 16});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 36,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: danger
              ? _danger(context).withValues(alpha: 0.20)
              : _stroke(context),
          child: Center(
              child: Icon(icon, size: iconSize, color: _sub(context))),
        ),
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  final String label;
  const _KeyCap(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: _overlayFill(context, 0.08),
          border: Border.all(color: _stroke(context)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _body(context),
                fontFamily: 'monospace')),
      );
}

class _KeySep extends StatelessWidget {
  const _KeySep();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text('+', style: TextStyle(fontSize: 11, color: _faint(context))),
      );
}


/// Кольцо заполнения контекста — рядом с кнопкой отправки.
///
/// Показывает не «сколько написано», а сколько осталось до того, как модель
/// начнёт забывать начало разговора. Переполнение контекста не выглядит как
/// ошибка: Ollama молча отрезает самое старое, и человек замечает это лишь по
/// тому, что ассистент вдруг перестал помнить, о чём шла речь, — а иногда
/// теряет и системную подсказку, то есть характер. Кольцо делает приближение
/// к этому пределу видимым заранее.
class AnimaContextGauge extends StatelessWidget {
  const AnimaContextGauge({
    super.key,
    required this.used,
    required this.limit,
    this.size = 18,
    this.hint,
  });

  final int used;
  final int limit;
  final double size;

  /// Подсказка при наведении. Собирается снаружи, чтобы виджет не зависел от
  /// переводов и оставался пригодным в любом стиле.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final fill = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    // Цвет — из палитры текущего стиля, поэтому кольцо не выбивается из
    // оформления. Ближе к пределу уходит в предупреждающий: это единственное
    // место, где цвет несёт смысл, а не украшает.
    final base = _accent(context);
    final color = fill < 0.75
        ? base
        : Color.lerp(base, const Color(0xFFE0682F),
            ((fill - 0.75) / 0.25).clamp(0.0, 1.0))!;
    final ring = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ContextRingPainter(
          fill: fill,
          track: _stroke(context),
          color: color,
        ),
      ),
    );
    if (hint == null || hint!.isEmpty) return ring;
    return Tooltip(
      message: hint!,
      waitDuration: const Duration(milliseconds: 300),
      child: ring,
    );
  }
}

/// Кольцо для текущего чата. Отдельная функция, чтобы три стиля интерфейса
/// собирали его одинаково и считали заполнение один раз, а не дважды.
Widget animaContextGauge(BuildContext context, AppState app) {
  final (used, limit) = app.contextUsage(app.current);
  if (app.current == null) return const SizedBox.shrink();
  return AnimaContextGauge(
    used: used,
    limit: limit,
    hint: app.contextHint(app.current),
  );
}

class _ContextRingPainter extends CustomPainter {
  _ContextRingPainter({
    required this.fill,
    required this.track,
    required this.color,
  });

  final double fill;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.16;
    final rect = Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    if (fill <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    // От двенадцати часов по часовой стрелке — как читается любая шкала.
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fill, false, arc);
  }

  @override
  bool shouldRepaint(_ContextRingPainter old) =>
      old.fill != fill || old.color != color || old.track != track;
}

// Ход рассуждения модели — свёрнутым блоком над ответом.
//
// Свёрнут по умолчанию намеренно: рассуждение бывает длиннее самого ответа, и
// развёрнутое оно топит собой то, за чем пришли. Показывается только когда
// модель его действительно прислала — просто включённый режим размышлений
// ничего не рисует, потому что не всякая модель их отдаёт отдельным полем.
class AnimaThinkingBlock extends StatefulWidget {
  const AnimaThinkingBlock({super.key, required this.text, required this.live});
  final String text;
  // Пока ответ ещё набирается, заголовок говорит «думает», а не «думал».
  final bool live;

  @override
  State<AnimaThinkingBlock> createState() => _AnimaThinkingBlockState();
}

class _AnimaThinkingBlockState extends State<AnimaThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(children: [
                Icon(Icons.psychology_outlined,
                    size: 15, color: _faint(context)),
                const SizedBox(width: 8),
                Text(app.t(widget.live ? 'thinkingLive' : 'thinkingDone'),
                    style: TextStyle(fontSize: 12, color: _sub(context))),
                const Spacer(),
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: _faint(context)),
              ]),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
              child: SelectableText(
                widget.text.trim(),
                style: TextStyle(
                    fontSize: 12, height: 1.45, color: _faint(context)),
              ),
            ),
        ],
      ),
    );
  }
}

// Пары «слово + значок» для ожидания ответа.
//
// Одно и то же слово, висящее минуту, само становится частью неподвижной
// картинки: глаз перестаёт его читать и снова не может отличить работу от
// зависания. Поэтому слов несколько, и каждое приходит со своим значком —
// меняется вся метка целиком, а не текст под неподвижной звёздочкой.
class AnimaWaitPhrase {
  const AnimaWaitPhrase(this.key, this.icon);

  /// Ключ перевода, а не готовая строка: слова живут в `i18n.dart` рядом с
  /// остальными и переводятся там же, а не прячутся в коде виджета.
  final String key;
  final IconData icon;
}

const List<AnimaWaitPhrase> kEvsWaitPhrases = <AnimaWaitPhrase>[
  AnimaWaitPhrase('nxWaiting', Icons.auto_awesome),
  AnimaWaitPhrase('nxWaitThink', Icons.psychology_alt),
  AnimaWaitPhrase('nxWaitWeigh', Icons.balance),
  AnimaWaitPhrase('nxWaitGather', Icons.bubble_chart),
  AnimaWaitPhrase('nxWaitWords', Icons.edit_note),
  AnimaWaitPhrase('nxWaitDig', Icons.manage_search),
  AnimaWaitPhrase('nxWaitSort', Icons.segment),
  AnimaWaitPhrase('nxWaitGears', Icons.autorenew),
];

// Надпись «думает», по которой пробегает блик, — вместо трёх точек.
//
// Смысл не в украшении: пока ответ ещё не начал набираться, единственный
// признак жизни — это движение. Три статичные точки от зависшего окна не
// отличить, а бегущий блик отличить можно.
//
// Контроллер обязательно через `AmbientMotion` — правило проекта: вечный
// `repeat()` останавливается, когда окно не видно, иначе он крутит кадры в
// фоне и греет карту впустую.
class AnimaShimmerLabel extends StatefulWidget {
  const AnimaShimmerLabel({
    super.key,
    this.phrases = kEvsWaitPhrases,
    this.period = const Duration(milliseconds: 3400),
  });

  /// Пул фраз. Одна фраза в списке — метка просто не меняется.
  final List<AnimaWaitPhrase> phrases;

  /// Как часто меняется слово. Три с половиной секунды — примерно столько
  /// нужно, чтобы фразу прочитали и не успели устать; смена раз в секунду
  /// мельтешит и отвлекает от того, чего ждут.
  final Duration period;

  @override
  State<AnimaShimmerLabel> createState() => _AnimaShimmerLabelState();
}

class _AnimaShimmerLabelState extends State<AnimaShimmerLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));
  late final AmbientMotion _motion =
      AmbientMotion(_c, gate: MotionGate.foreground);
  final math.Random _rnd = math.Random();
  Timer? _turn;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _motion; // подписка на гейт
    // Начинаем со случайной фразы, а не всегда с первой: иначе каждый ответ
    // начинался бы одним и тем же словом, и пул был бы виден только тем, кто
    // ждёт дольше трёх секунд.
    if (widget.phrases.isNotEmpty) _i = _rnd.nextInt(widget.phrases.length);
    _turn = Timer.periodic(widget.period, (_) => _next());
  }

  void _next() {
    final n = widget.phrases.length;
    if (!mounted || n < 2) return;
    // Пока окно не на экране, слова не меняем: смена, которую никто не видит,
    // всё равно перерисовывает кадр — тот же довод, что и у гейта движения.
    if (!MotionPolicy.foreground.value) return;
    var j = _rnd.nextInt(n - 1);
    if (j >= _i) j++; // любое, кроме текущего: повтор читается как заминка
    setState(() => _i = j);
  }

  @override
  void dispose() {
    _turn?.cancel();
    _motion.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.phrases.isEmpty) return const SizedBox.shrink();
    final base = _faint(context);
    final lit = _accent(context);
    final p = widget.phrases[_i.clamp(0, widget.phrases.length - 1)];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _icon(p, lit),
      const SizedBox(width: 8),
      AnimatedSize(
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOut,
        alignment: Alignment.centerLeft,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          // Слова разной длины: выравниваем по левому краю, иначе на время
          // пересменки обе фразы стоят по центру и надпись дёргается вбок.
          layoutBuilder: (cur, prev) => Stack(
            alignment: Alignment.centerLeft,
            children: [...prev, if (cur != null) cur],
          ),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 0.4), end: Offset.zero)
                  .animate(anim),
              child: child,
            ),
          ),
          child: _sweep(context.read<AppState>().t(p.key), base, lit),
        ),
      ),
    ]);
  }

  // Значок дышит в такт блику — один и тот же контроллер на полтора оборота в
  // секунду, поэтому метка читается как одно живое целое, а не как две
  // независимые анимации, случайно оказавшиеся рядом.
  Widget _icon(AnimaWaitPhrase p, Color lit) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final b = math.sin(_c.value * 2 * math.pi); // −1…1
        return Transform.scale(
          scale: 1 + 0.10 * b,
          child: Transform.rotate(
            angle: 0.12 * b,
            child: Opacity(opacity: 0.72 + 0.28 * ((b + 1) / 2), child: child),
          ),
        );
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: anim,
            child: RotationTransition(
              turns: Tween<double>(begin: -0.3, end: 0).animate(anim),
              child: child,
            ),
          ),
        ),
        child: Icon(p.icon,
            key: ValueKey<String>(p.key),
            size: 14,
            color: lit.withValues(alpha: 0.9)),
      ),
    );
  }

  Widget _sweep(String text, Color base, Color lit) {
    return AnimatedBuilder(
      key: ValueKey<String>(text),
      animation: _c,
      builder: (_, __) {
        // Блик шириной в треть надписи проходит слева направо и уходит за
        // край: остановки в конце нет, поэтому движение читается как
        // непрерывное, а не как дёрганый цикл.
        final t = _c.value * 1.6 - 0.3;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [base, lit, base],
            stops: [
              (t - 0.18).clamp(0.0, 1.0),
              t.clamp(0.0, 1.0),
              (t + 0.18).clamp(0.0, 1.0),
            ],
          ).createShader(r),
          // Без ореола: под маской srcIn он превратился бы в размытое пятно
          // того же градиента вокруг букв. Надпись лежит на панели, где фон
          // ровный, и обводка ей не нужна.
          child: Text(text,
              style: AnimaType.body.copyWith(
                  fontSize: 13,
                  color: base,
                  letterSpacing: 0.2,
                  shadows: const [])),
        );
      },
    );
  }
}

// Ответ, появляющийся на глазах: пришедшее сразу занимает своё место, но
// проступает, а не выскакивает.
//
// Первая попытка выдавала ответ ровным потоком знаков — и это оказалось хуже
// рывков, из-за которых затевалось. Со знаком меняется перенос строк:
// недописанное слово перескакивает на следующую строку и обратно, за ним
// дёргается весь абзац, и на глаз это мерцание, а не набор. Придерживать текст
// вообще нельзя, пока он течёт в готовый абзац.
//
// Поэтому текст больше не задерживается ни на кадр: пришедший кусок сразу
// занимает своё окончательное место — но прозрачным, и проступает за треть
// секунды. Переносы посчитаны сразу и дальше не меняются, двигается только
// прозрачность, а плавность даёт она, а не темп выдачи.
class AnimaTypingText extends StatefulWidget {
  const AnimaTypingText(this.text,
      {super.key,
      this.style,
      this.selectable = false,
      this.fade = const Duration(milliseconds: 320)});

  final String text;
  final TextStyle? style;
  final bool selectable;

  /// За сколько проступает пришедший кусок.
  final Duration fade;

  @override
  State<AnimaTypingText> createState() => _AnimaTypingTextState();
}

/// Кусок, который ещё проступает: текст до [end] и сколько ему осталось.
///
/// Время считается остатком, а не отметкой о рождении: у тикера отсчёт
/// начинается заново после каждой остановки, и абсолютные отметки, взятые до
/// неё, после превращались бы в чепуху.
class _AnimaFadeRun {
  _AnimaFadeRun(this.end, this.left);
  final int end;
  double left;
}

class _AnimaTypingTextState extends State<AnimaTypingText>
    with SingleTickerProviderStateMixin {
  // Тикер заводится ТОЛЬКО когда есть чему проступать, и никак не лениво: у
  // готовых сообщений (а их в переписке подавляющее большинство) первым
  // обращением к ленивому полю оказывался бы `dispose`, а `createTicker` на
  // разбираемом узле лезет за `TickerMode` вверх по дереву и падает.
  Ticker? _tick;
  bool _fresh = false; // первый кадр после запуска — только точка отсчёта
  Duration _last = Duration.zero;

  /// До какого места текст уже проступил полностью.
  int _settled = 0;
  final List<_AnimaFadeRun> _runs = <_AnimaFadeRun>[];

  @override
  void initState() {
    super.initState();
    // То, что уже есть при рождении виджета, показываем как есть: проявлять
    // ответ, который человек читал минуту назад (прокрутка, смена темы), —
    // это сбой, а не анимация.
    _settled = widget.text.length;
  }

  void _run() {
    final t = _tick ??= createTicker(_frame);
    if (t.isActive) return;
    _last = Duration.zero;
    _fresh = true;
    t.start();
  }

  @override
  void didUpdateWidget(AnimaTypingText old) {
    super.didUpdateWidget(old);
    if (widget.text == old.text) return;
    final grew = widget.text.length > old.text.length &&
        widget.text.startsWith(old.text);
    if (!grew) {
      // Текст сменился не дописыванием, а целиком — список сдвинулся, открыли
      // другой диалог, ответ причесали после конца. Показываем сразу.
      _runs.clear();
      _settled = widget.text.length;
      _tick?.stop();
      return;
    }
    _runs.add(_AnimaFadeRun(
        widget.text.length, widget.fade.inMicroseconds / 1e6));
    // Куски приходят чаще, чем проступают, и их набирается с десяток — это
    // нормально и даёт мягкий хвост. Но если модель сыплет мелко и часто,
    // счёт кускам знать меру должен код, а не удача.
    while (_runs.length > 24) {
      _settled = _runs.removeAt(0).end;
    }
    _run();
  }

  @override
  void dispose() {
    // Сначала остановить, потом убрать: живой тикер на разборе — это не утечка,
    // а падение отладочной сборки (assert(!isActive) во фреймворке). Ответ,
    // который ещё проступает, закрыть окном можно в любой момент.
    _tick
      ?..stop()
      ..dispose();
    super.dispose();
  }

  void _frame(Duration now) {
    if (_fresh) {
      _fresh = false;
      _last = now;
      return;
    }
    var dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (dt <= 0) return;
    if (dt > 0.5) dt = 0.5; // вернулись из паузы: простой не засчитываем
    // Окно спрятали — досказываем сразу: проявлять в невидимом окне незачем.
    if (!MotionPolicy.foreground.value) dt = 1e9;
    for (final r in _runs) {
      r.left -= dt;
    }
    while (_runs.isNotEmpty && _runs.first.left <= 0) {
      _settled = _runs.removeAt(0).end;
    }
    if (_runs.isEmpty) _tick?.stop();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? AnimaType.body;
    final n = widget.text.length;
    final settled = _settled.clamp(0, n);
    // Пустая строка между абзацами — своим размером, а не размером текста.
    final thin = TextStyle(fontSize: (style.fontSize ?? 14) * 0.45, height: 1);
    final spans = <TextSpan>[];
    if (_runs.isEmpty || settled >= n) {
      _write(spans, widget.text, null, thin);
    } else {
      final base = style.color ?? _txt(context);
      final total = widget.fade.inMicroseconds / 1e6;
      _write(spans, widget.text.substring(0, settled), null, thin);
      var from = settled;
      for (final r in _runs) {
        final to = r.end.clamp(from, n);
        if (to <= from) continue;
        // Плавно к концу, а не рывком в начале: линейное проявление заметно
        // «включается», и в потоке кусков это читается как мигание.
        final k =
            Curves.easeOut.transform((1 - (r.left / total)).clamp(0.0, 1.0));
        _write(spans, widget.text.substring(from, to),
            TextStyle(color: base.withValues(alpha: k)), thin);
        from = to;
      }
      if (from < n) _write(spans, widget.text.substring(from), null, thin);
    }
    final rich = TextSpan(style: style, children: spans);
    return widget.selectable ? SelectableText.rich(rich) : Text.rich(rich);
  }

  static final RegExp _gapRe = RegExp(r'\n{2,}');

  // Абзацы модель разделяет двумя переводами строки, и пустая строка получает
  // высоту обычной строки текста. В ответе из трёх коротких фраз воздуха от
  // этого выходит больше, чем самих фраз.
  //
  // Убрать перевод нельзя — абзацы слипнутся в кашу. Поэтому пустой строке
  // даётся собственный размер: она остаётся пустой строкой (перенос, отступ,
  // структура — всё на месте), но занимает не полторы высоты текста, а треть.
  // Заодно сходятся к одному просвету и три перевода подряд, и пять: модели
  // ставят их как придётся, а на экране разницы быть не должно.
  void _write(
      List<TextSpan> out, String text, TextStyle? style, TextStyle thin) {
    if (text.isEmpty) return;
    var i = 0;
    for (final m in _gapRe.allMatches(text)) {
      if (m.start > i) {
        out.add(TextSpan(text: text.substring(i, m.start), style: style));
      }
      out.add(TextSpan(text: '\n', style: style)); // конец абзаца
      out.add(TextSpan(
          text: '\n',
          style: style == null ? thin : thin.merge(style))); // сам просвет
      i = m.end;
    }
    if (i < text.length) {
      out.add(TextSpan(text: text.substring(i), style: style));
    }
  }
}
