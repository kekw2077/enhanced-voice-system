import 'package:flutter/material.dart';
import 'evs_tokens.dart';

/// Живые настройки оформления: тема, акцент, матовость, фон, сетка точек.
/// Прототип держит их в состоянии верхнего компонента — здесь то же самое
/// через InheritedWidget, чтобы любой экран мог прочитать EvsTheme.of(context).

enum EvsBackground { aurora, shader, off }
enum EvsDotMode { push, glow, off }
enum EvsAnim { breathe, flow, pulse, off }

@immutable
class EvsThemeData {
  const EvsThemeData({
    this.brightness = Brightness.dark,
    this.accent = EvsAccent.google,
    this.glass = EvsGlass.glass,
    this.background = EvsBackground.aurora,
    this.dots = EvsDotMode.push,
    this.anim = EvsAnim.breathe,
  });

  final Brightness brightness;
  final EvsAccent accent;
  final EvsGlass glass;
  final EvsBackground background;
  final EvsDotMode dots;
  final EvsAnim anim;

  EvsPalette get palette => brightness == Brightness.dark ? EvsPalette.dark : EvsPalette.light;
  Color get card => glass.card(brightness);
  double get blur => glass.blur;

  EvsThemeData copyWith({Brightness? brightness, EvsAccent? accent, EvsGlass? glass,
      EvsBackground? background, EvsDotMode? dots, EvsAnim? anim}) =>
      EvsThemeData(
        brightness: brightness ?? this.brightness,
        accent: accent ?? this.accent,
        glass: glass ?? this.glass,
        background: background ?? this.background,
        dots: dots ?? this.dots,
        anim: anim ?? this.anim,
      );

  /// Material-тема, чтобы стандартные виджеты не выбивались из палитры.
  ThemeData toMaterial() {
    final p = palette;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: p.bg,
      fontFamily: EvsType.ui,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent.a2,
        brightness: brightness,
        surface: p.solid,
        error: EvsPalette.danger,
      ),
      textTheme: TextTheme(
        displayLarge: EvsType.hero.copyWith(color: p.txt),
        titleLarge: EvsType.title.copyWith(color: p.txt),
        bodyMedium: EvsType.bodyText.copyWith(color: p.body),
        labelMedium: EvsType.label.copyWith(color: p.body),
      ),
      dividerColor: p.stroke,
      splashFactory: NoSplash.splashFactory,
    );
  }
}

class EvsTheme extends InheritedWidget {
  const EvsTheme({super.key, required this.data, required this.onChanged, required super.child});

  final EvsThemeData data;
  final ValueChanged<EvsThemeData> onChanged;

  static EvsThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EvsTheme>()?.data ?? const EvsThemeData();

  static void set(BuildContext context, EvsThemeData next) =>
      context.findAncestorWidgetOfExactType<EvsTheme>()?.onChanged(next);

  @override
  bool updateShouldNotify(EvsTheme old) => old.data != data;
}

/// Обёртка приложения: держит настройки и раздаёт их вниз.
class EvsApp extends StatefulWidget {
  const EvsApp({super.key, required this.builder, this.initial = const EvsThemeData(), this.onChanged});
  final WidgetBuilder builder;
  final EvsThemeData initial;
  /// Вызывается при каждом изменении оформления — сюда вешается сохранение.
  final ValueChanged<EvsThemeData>? onChanged;

  @override
  State<EvsApp> createState() => _EvsAppState();
}

class _EvsAppState extends State<EvsApp> {
  late EvsThemeData _data = widget.initial;

  @override
  Widget build(BuildContext context) => EvsTheme(
        data: _data,
        onChanged: (next) {
          setState(() => _data = next);
          widget.onChanged?.call(next);
        },
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _data.toMaterial(),
          home: Builder(builder: widget.builder),
        ),
      );
}
