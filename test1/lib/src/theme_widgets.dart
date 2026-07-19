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
      title: 'EVS',
      theme: _buildTheme(app.themeMode),
      darkTheme: _buildTheme(app.themeMode),
      themeMode: _palFor(app.themeMode).brightness == Brightness.light
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
      home: const ImmersiveSplash(),
    );
  }

  // On iOS, use the system font (San Francisco) — exactly the iOS typography —
  // by NOT forcing a bundled family (Flutter then falls back to the platform
  // default, which is SF on iOS). Apple's SF can't be bundled for other
  // platforms (proprietary), so Android/desktop/web keep the bundled Nunito.
  String? get _appFontFamily =>
      defaultTargetPlatform == TargetPlatform.iOS ? null : 'Nunito';

  ThemeData _buildTheme(AppThemeMode mode) {
    final p = _palFor(mode);
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
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      dividerColor: p.stroke,
      fontFamily: _appFontFamily,
      // Cover the surfaces that otherwise fall back to Material defaults so the
      // system dialogs / menus / snackbars / tooltips follow the app theme even
      // when a call site doesn't set colours explicitly (TZ3.1 §1.2).
      dialogTheme: DialogThemeData(backgroundColor: card),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        textStyle: txtStyle,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: txtStyle,
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: card,
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        textStyle: txtStyle,
      ),
    );
  }
}

// Animated startup transition: the particle sphere (same one shown on the
// empty chat screen) swells toward the viewer and dissolves smoothly as the
// chat reveals behind it — "flying into" the sphere. Plays once per cold
// launch; a tap anywhere skips straight to the chat. The native static-orb
// splash is the instant first frame before this; ChatScreen is mounted under
// the overlay the whole time so it's already warm when the overlay clears.
class ImmersiveSplash extends StatefulWidget {
  const ImmersiveSplash({super.key});
  @override
  State<ImmersiveSplash> createState() => _ImmersiveSplashState();
}

class _ImmersiveSplashState extends State<ImmersiveSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _skip() {
    if (_done) return;
    _ctrl.stop();
    setState(() => _done = true);
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
              animation: _ctrl,
              builder: (context, _) {
                final t = _ctrl.value;
                // Brief hold, then ramp immersion; the whole overlay fades
                // out over the last third so the chat shows through.
                final immerse = t < 0.15 ? 0.0 : ((t - 0.15) / 0.85);
                final fade = (1 - ((t - 0.7) / 0.3)).clamp(0.0, 1.0);
                return Opacity(
                  opacity: fade,
                  child: Container(
                    color: _bg(context),
                    alignment: Alignment.center,
                    child: ParticleSphere(
                      size: 240,
                      dense: true,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : const Color(0xFF2F6BFF),
                      immerse: Curves.easeIn.transform(
                        immerse.clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                );
              },
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

_Palette _pal(BuildContext c) => _palFor(c.read<AppState>().themeMode);

// Canonical surface/text tokens — resolve against the active theme. The
// BuildContext param is kept so the hundreds of call sites stay unchanged.
Color _bg(BuildContext c) => _pal(c).bg;
Color _card(BuildContext c) => _pal(c).card;
Color _txt(BuildContext c) => _pal(c).txt;
Color _sub(BuildContext c) => _pal(c).sub;
Color _body(BuildContext c) => _pal(c).body;
Color _faint(BuildContext c) => _pal(c).faint;
Color _accent(BuildContext c) => _pal(c).accent;
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

abstract final class EvsSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class EvsRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 18;
  static const double pill = 999;
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
}

// Type scale. Colour is intentionally omitted — apply a token at the call site,
// e.g. `EvsType.body.copyWith(color: _txt(context))`. Family comes from
// ThemeData (Nunito), so it is not set here.
abstract final class EvsType {
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
  late final List<_P> _points;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
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
    final reactive = active ? level.clamp(0.0, 1.0) : 0.0;
    final pulse = active
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

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
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
const Color _evsGMid = Color(0xFF8855CC);
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
BoxDecoration _evsShellBg(BuildContext c) {
  final p = _pal(c);
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

// Left nav rail / sidebar background: a subtly darker vertical gradient of the
// themed background on dark themes, a flat themed card surface on light.
BoxDecoration _evsRailBg(BuildContext c) {
  final p = _pal(c);
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

// The conic-gradient "bead" logo used across desktop screens.
// The brand mark: the new logo (assets/icon/icon.png) with a one-shot entrance
// animation that replays each time the widget mounts (fade + scale-overshoot +
// slight spin-settle), then holds static. Keeps a `const` constructor so the
// existing `const _EvsLogoMark(...)` call sites stay valid unchanged.
class _EvsLogoMark extends StatefulWidget {
  final double size;
  const _EvsLogoMark({this.size = 30});
  @override
  State<_EvsLogoMark> createState() => _EvsLogoMarkState();
}

class _EvsLogoMarkState extends State<_EvsLogoMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<double> _spin;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 720));
    _fade = CurvedAnimation(
        parent: _ctrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOut));
    _scale = Tween<double>(begin: 0.55, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _spin = Tween<double>(begin: -0.45, end: 0.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Opacity(
        opacity: _fade.value.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: _spin.value,
          child: Transform.scale(scale: _scale.value, child: child),
        ),
      ),
      child: Image.asset(
        'assets/icon/icon.png',
        width: widget.size,
        height: widget.size,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}


Widget evsCard(
  BuildContext context, {
  required IconData icon,
  required String title,
  required List<Widget> rows,
}) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: EvsRadius.rLg,
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
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: EvsRadius.rSm,
                  color: _accent(context).withValues(alpha: 0.15),
                ),
                child: Icon(icon, size: 13, color: _accent(context)),
              ),
              const SizedBox(width: 9),
              Text(title.toUpperCase(),
                  style:
                      EvsType.sectionLabel.copyWith(color: _sectionLabel(context))),
            ],
          ),
        ),
        ...rows,
      ],
    ),
  );
}

Widget evsRow(BuildContext context, {
  required String label,
  String? desc,
  required Widget control,
  bool stacked = false,
}) {
  final labelCol = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: EvsType.label.copyWith(color: _body(context))),
      if (desc != null) ...[
        const SizedBox(height: 2),
        Text(desc, style: EvsType.caption.copyWith(color: _sub(context))),
      ],
    ],
  );
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
// the available width (used with `evsRow(context, stacked: true)`). Replaces the
// right-aligned Wrap that folded 3–4 options into a cramped floating block.
Widget evsSegmentedWide<T>(
  BuildContext context,
  List<(T, String)> options,
  T value,
  ValueChanged<T> onChanged,
) {
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
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: options[i].$1 == value
                      ? _accent(context).withValues(alpha: 0.22)
                      : Colors.transparent,
                  border: Border.all(
                    color: options[i].$1 == value
                        ? _accent(context).withValues(alpha: 0.45)
                        : Colors.transparent,
                  ),
                ),
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

Widget evsSegmented<T>(
  BuildContext context,
  List<(T, String)> options,
  T value,
  ValueChanged<T> onChanged,
) {
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
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: o.$1 == value
                    ? _accent(context).withValues(alpha: 0.22)
                    : Colors.transparent,
                border: Border.all(
                  color: o.$1 == value
                      ? _accent(context).withValues(alpha: 0.45)
                      : Colors.transparent,
                ),
              ),
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

Widget evsToggle(BuildContext context, bool value, ValueChanged<bool> onChanged) {
  return GestureDetector(
    onTap: () => onChanged(!value),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 42,
      height: 23,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: value ? _accentGradient(context) : null,
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
Widget evsSelectButton(BuildContext context, String label, {double minWidth = 148, VoidCallback? onTap}) {
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

Widget evsGhostButton(BuildContext context, String label, IconData icon, {VoidCallback? onTap}) {
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
          Text(label, style: EvsType.control.copyWith(color: _sub(context))),
        ],
      ),
    ),
  );
}

Widget evsSlider(BuildContext context, {
  required double value,
  required double min,
  required double max,
  int? divisions,
  required String label,
  required ValueChanged<double> onChanged,
}) {
  // Up to 210px wide, but shrinks to fit narrow cards (no fixed width that
  // would overflow inside evsRow's bounded control slot).
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
            activeColor: _accent(context),
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
Widget evsNamedSlider(BuildContext context, {
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
          data: const SliderThemeData(
            trackHeight: 4,
            overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
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
Widget evsRadioCard(BuildContext context, {
  required bool selected,
  required String title,
  required String desc,
  required VoidCallback onTap,
  Widget? extra,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: selected ? _accent(context).withValues(alpha: 0.1) : _overlayFill(context, 0.03),
        border: Border.all(
            color: selected ? _accent(context).withValues(alpha: 0.3) : _stroke(context)),
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
                  color: selected ? _accent(context) : _faint(context), width: 2),
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: _accent(context)))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: EvsType.label.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? _txt(context) : _body(context))),
                const SizedBox(height: 2),
                Text(desc,
                    style: EvsType.caption
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

Widget evsAddButton(BuildContext context, String label, VoidCallback onTap,
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

Widget evsDangerButton(BuildContext context, String label, VoidCallback onTap) {
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
          style: EvsType.label
              .copyWith(fontSize: 13, fontWeight: FontWeight.w700, color: d)),
    ),
  );
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
  const _WindowTitleBar();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
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

