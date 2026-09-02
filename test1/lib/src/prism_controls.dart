part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — свои элементы управления
   --------------------------------------------------------------------------
   Порт handoff/flutter/lib/widgets/controls.dart. Это НЕ замена общим
   evs*-хелперам: те остаются единственными для классики, Nexus и «Ноктюрна».
   Здесь лежит то, чего у них нет по форме — тумблер-таблетка с белым бегунком,
   сегменты в подложке, ползунок с градиентной дорожкой, поле со своей рамкой
   и кнопка, залитая акцентной тройкой.

   Правило прежнее: форма — отсюда, ПОВЕДЕНИЕ — из общих функций. Кнопка
   отправки зовёт тот же `app.sendMessage`, тумблер чата — тот же
   `app.setChatEnabled`. Ни одной своей копии логики.
   ========================================================================== */

/// Типографика стиля. Отдельно от [AnimaType]: у макета свой шрифт, свои размеры
/// и отрицательный трекинг, пересчитанный из `em` в логические пиксели
/// (`letterSpacing = em × fontSize`, см. handoff/GUIDE.md).
abstract final class PrismType {
  static const TextStyle title = TextStyle(
      fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.44, height: 1.2);
  static const TextStyle heading = TextStyle(
      fontSize: 15.5, fontWeight: FontWeight.w700, letterSpacing: -0.23);
  static const TextStyle section = TextStyle(
      fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.05);
  static const TextStyle body = TextStyle(fontSize: 14, height: 1.5);
  static const TextStyle label =
      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);
  static const TextStyle caption = TextStyle(fontSize: 11.5, height: 1.4);
  static const TextStyle numeric =
      TextStyle(fontSize: 10.5, fontFamily: kPrismMono);
}

/// Подложка полей и чипов. В токенах это `--field` и `--chip` — полупрозрачные
/// накладки, которые на светлой теме темнят, а на тёмной высветляют.
Color _prismField(BuildContext c) => _pal(c).brightness == Brightness.dark
    ? const Color(0x09FFFFFF)
    : const Color(0x09121E37);

Color _prismChip(BuildContext c) => _pal(c).brightness == Brightness.dark
    ? const Color(0x0FFFFFFF)
    : const Color(0x0E121E37);

/// `--stroke2`: контур посильнее обычного. Им обведены всплывающие меню и
/// плитка под курсором — там, где рамка должна отделять, а не намекать.
Color _prismStroke2(BuildContext c) => _pal(c).brightness == Brightness.dark
    ? const Color(0x2EFFFFFF)
    : const Color(0xFFB8C2D2);

Color _prismHover(BuildContext c) => _pal(c).brightness == Brightness.dark
    ? const Color(0x12FFFFFF)
    : const Color(0x12121E37);

/// Поворот оттенка на [deg] градусов — CSS `filter: hue-rotate(Ndeg)`.
///
/// Матрица стандартная (та же, что в спецификации фильтров SVG): поворот в
/// плоскости, перпендикулярной серой оси. Один такой фильтр на слой, вкладывать
/// их друг в друга нельзя — растеризация происходит на каждом уровне.
List<double> prismHueMatrix(double deg) {
  final rad = deg * math.pi / 180;
  final c = math.cos(rad), sn = math.sin(rad);
  return <double>[
    0.213 + c * 0.787 - sn * 0.213, 0.715 - c * 0.715 - sn * 0.715,
    0.072 - c * 0.072 + sn * 0.928, 0, 0,
    0.213 - c * 0.213 + sn * 0.143, 0.715 + c * 0.285 + sn * 0.140,
    0.072 - c * 0.072 - sn * 0.283, 0, 0,
    0.213 - c * 0.213 - sn * 0.787, 0.715 - c * 0.715 + sn * 0.715,
    0.072 + c * 0.928 + sn * 0.072, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

ColorFilter prismHueFilter(double deg) =>
    ColorFilter.matrix(prismHueMatrix(deg));

/// Яркость: CSS `filter: brightness(k)`.
List<double> prismBrightnessMatrix(double k) => <double>[
      k, 0, 0, 0, 0,
      0, k, 0, 0, 0,
      0, 0, k, 0, 0,
      0, 0, 0, 1, 0,
    ];

ColorFilter prismBrightnessFilter(double k) =>
    ColorFilter.matrix(prismBrightnessMatrix(k));

/// Насыщенность: CSS `filter: saturate(k)`.
List<double> prismSaturateMatrix(double k) {
  const lr = 0.213, lg = 0.715, lb = 0.072;
  return <double>[
    lr + (1 - lr) * k, lg - lg * k, lb - lb * k, 0, 0,
    lr - lr * k, lg + (1 - lg) * k, lb - lb * k, 0, 0,
    lr - lr * k, lg - lg * k, lb + (1 - lb) * k, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

ColorFilter prismSaturateFilter(double k) =>
    ColorFilter.matrix(prismSaturateMatrix(k));

/// Две цветовые матрицы, сложенные в одну: сначала [first], потом [second] —
/// тот же порядок, в котором CSS читает `filter: brightness() saturate()`.
///
/// Нужно затем, что кадр макета меняет сразу два-три свойства, а вкладывать
/// один ColorFiltered в другой нельзя: каждый уровень — отдельная растеризация
/// всего поддерева. Матрицы аффинные, поэтому их можно просто перемножить и
/// отдать движку одним фильтром.
List<double> prismMatMul(List<double> second, List<double> first) {
  final out = List<double>.filled(20, 0);
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 5; j++) {
      // Пятый столбец — свободный член: к нему добавляется свой сдвиг.
      var v = j == 4 ? second[i * 5 + 4] : 0.0;
      for (var k = 0; k < 4; k++) {
        v += second[i * 5 + k] * first[k * 5 + j];
      }
      out[i * 5 + j] = v;
    }
  }
  return out;
}

/// Тёмная ли сейчас тема. Отдельным именем, потому что спрашивают это в
/// «Призме» на каждом шагу: у токенов два набора значений, светлый и тёмный.
bool _prismDark(BuildContext c) => _pal(c).brightness == Brightness.dark;

/// `--btn` / `--btnx`: сплошная кнопка-таблетка («Новый чат» в рейке). На
/// тёмной теме белая с почти чёрным текстом, на светлой — наоборот. Контраст
/// в обеих одинаковый, поэтому кнопка одинаково громкая в любой теме.
Color _prismBtn(BuildContext c) => _pal(c).brightness == Brightness.dark
    ? const Color(0xFFFFFFFF)
    : const Color(0xFF17181B);

Color _prismBtnFg(BuildContext c) => _pal(c).brightness == Brightness.dark
    ? const Color(0xFF0A0B0E)
    : const Color(0xFFFFFFFF);

/// Мягкая акцентная заливка выбранного (`--accent-soft`). Строится из активной
/// тройки, поэтому следует за выбранным акцентом.
Color _prismAccentSoft(BuildContext c) =>
    _ramp(c).a2.withValues(alpha: _pal(c).brightness == Brightness.dark ? 0.16 : 0.20);

/// Заголовок блока: мелкий, жирный, в разрядку, верхним регистром.
class PrismSectionLabel extends StatelessWidget {
  const PrismSectionLabel(this.text, {super.key, this.size = 11});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: PrismType.section
            .copyWith(color: _faint(context), fontSize: size),
      );
}

/// Тумблер 46×26 с белым бегунком и градиентом во включённом состоянии.
class PrismToggle extends StatelessWidget {
  const PrismToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 46,
          height: 26,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: value ? LinearGradient(colors: [r.a1, r.a2]) : null,
            color: value ? null : _prismChip(context),
            borderRadius: BorderRadius.circular(999),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: Color(0x4D000000),
                      offset: Offset(0, 2),
                      blurRadius: 6)
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Сегменты в подложке — выбор одного из нескольких коротких вариантов.
/// Обобщён по значению, чтобы принимать перечисления так же, как строки:
/// у настроек «Призмы» варианты — это enum, а не подписи.
class PrismSegmented<T> extends StatelessWidget {
  const PrismSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.compact = false,
    this.fill = false,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool compact;

  /// Занять всю ширину, поделив её между вариантами поровну. Нужно в строках
  /// настроек, где подпись сверху, а выбор — во всю строку под ней: без этого
  /// подложка растягивается, а варианты жмутся к правому краю пустой полосы.
  final bool fill;

  Widget _pill(BuildContext context, T v, String label, {bool wide = false}) {
    final on = v == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(
              horizontal: wide ? 6 : (compact ? 10 : 13), vertical: 7),
          alignment: wide ? Alignment.center : null,
          decoration: BoxDecoration(
            color: on ? _prismAccentSoft(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: on ? _ramp(context).a2 : Colors.transparent),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: wide ? TextAlign.center : null,
            style: PrismType.label.copyWith(
              fontSize: 12,
              color: on ? _txt(context) : _sub(context),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _prismChip(context),
        borderRadius: BorderRadius.circular(13),
      ),
      child: fill
          ? Row(
              children: [
                for (var i = 0; i < options.length; i++) ...[
                  if (i > 0) const SizedBox(width: 3),
                  Expanded(
                      child: _pill(context, options[i].$1, options[i].$2,
                          wide: true)),
                ],
              ],
            )
          : Wrap(
              alignment: WrapAlignment.end,
              spacing: 3,
              runSpacing: 3,
              children: [
                for (final (v, label) in options) _pill(context, v, label),
              ],
            ),
    );
  }
}

/// Ползунок: дорожка 5px, градиентная заливка, белый кружок 14px.
class PrismSlider extends StatelessWidget {
  const PrismSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step,
  });

  final double value, min, max;
  final double? step;
  final ValueChanged<double> onChanged;

  void _emit(double dx, double width) {
    var v = min + (dx / width).clamp(0.0, 1.0) * (max - min);
    if (step != null && step! > 0) v = (v / step!).round() * step!;
    onChanged(v.clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    final frac = max <= min ? 0.0 : ((value - min) / (max - min)).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (e) => _emit(e.localPosition.dx, w),
            onHorizontalDragUpdate: (e) => _emit(e.localPosition.dx, w),
            child: SizedBox(
              height: 20,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: _prismChip(context),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  Container(
                    height: 5,
                    width: w * frac,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [r.a1, r.a2]),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  Positioned(
                    left: (w * frac - 7).clamp(0.0, math.max(0.0, w - 14)),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                              color: Color(0x59000000),
                              offset: Offset(0, 2),
                              blurRadius: 8)
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Строка «подпись — значение — ползунок».
class PrismLabeledSlider extends StatelessWidget {
  const PrismLabeledSlider({
    super.key,
    required this.label,
    required this.display,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step,
  });

  final String label, display;
  final double value, min, max;
  final double? step;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(label,
                style: PrismType.body
                    .copyWith(color: _body(context), fontSize: 12.5)),
            const Spacer(),
            Text(display,
                style: PrismType.numeric.copyWith(
                    color: _txt(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 9),
        PrismSlider(
            value: value, min: min, max: max, step: step, onChanged: onChanged),
      ],
    );
  }
}

/// Кнопка-таблетка, залитая акцентной тройкой. Свечение под ней берётся из
/// среднего цвета тройки, а не из константы, иначе на «Мяте» под зелёной
/// кнопкой светилось бы фиолетовым.
class PrismGradientButton extends StatelessWidget {
  const PrismGradientButton({
    super.key,
    required this.label,
    this.icon,
    this.d,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    this.radius = 999,
    this.fontSize = 13,
    this.trailingIcon = false,
    this.expand = false,
  });

  final String label;
  final IconData? icon;

  /// Контур знака из макета — предпочтительнее [icon]: у прототипа свои
  /// иконки, и Material-набор рядом с ними виден сразу. См. [PrismIcons].
  final String? d;

  /// Растянуться на всю ширину и выровнять содержимое по центру — так кнопка
  /// «Создать» стоит в панели параметров макета.
  final bool expand;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double radius, fontSize;

  /// Знак справа от подписи (кнопка отправки), а не слева.
  final bool trailingIcon;

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    final on = onTap != null;
    final glyph = d != null
        ? PrismIcon(d!, size: 15, stroke: 2.1, color: Colors.white)
        : (icon == null ? null : Icon(icon, size: 15, color: Colors.white));
    return Opacity(
      opacity: on ? 1 : 0.38,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              gradient: r.sweep,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                  color: r.a2.withValues(alpha: 0.34),
                  offset: const Offset(0, 8),
                  blurRadius: 22,
                )
              ],
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment:
                  expand ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (glyph != null && !trailingIcon) ...[
                  glyph,
                  const SizedBox(width: 7),
                ],
                Text(label,
                    style: PrismType.label.copyWith(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w700)),
                if (glyph != null && trailingIcon) ...[
                  const SizedBox(width: 7),
                  glyph,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Поле ввода: подложка `--field`, рамка `--stroke`, акцент по фокусу.
class PrismField extends StatelessWidget {
  const PrismField({
    super.key,
    required this.controller,
    this.hint,
    this.lines = 1,
    this.mono = false,
    this.radius = 16,
    this.fontSize = 13.5,
    this.enabled = true,
    this.onSubmitted,
    this.onChanged,
    this.maxLength,
  });

  final TextEditingController controller;
  final String? hint;
  final int lines;
  final bool mono, enabled;
  final double radius, fontSize;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  /// Предел длины. Счётчик Material прячем: в макете он стоит своей строкой
  /// под полем, моноширинным, и второй бы с ним спорил.
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    final base = mono ? PrismType.numeric : PrismType.body;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: c),
        );
    return TextField(
      controller: controller,
      maxLines: lines,
      enabled: enabled,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      maxLength: maxLength,
      buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
          null,
      style: base.copyWith(color: _body(context), fontSize: fontSize, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            PrismType.body.copyWith(color: _faint(context), fontSize: fontSize),
        filled: true,
        fillColor: _prismField(context),
        contentPadding: EdgeInsets.symmetric(
            horizontal: 16, vertical: lines > 1 ? 14 : 12),
        border: border(_stroke(context)),
        enabledBorder: border(_stroke(context)),
        focusedBorder: border(_ramp(context).a2),
      ),
    );
  }
}

/// Круглая кнопка-иконка без заливки — для мелких действий в шапке и композере.
class PrismRoundIcon extends StatefulWidget {
  const PrismRoundIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.danger = false,
    this.size = 34,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active, danger;
  final double size;

  @override
  State<PrismRoundIcon> createState() => _PrismRoundIconState();
}

class _PrismRoundIconState extends State<PrismRoundIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color fg = widget.onTap == null
        ? _faint(context)
        : widget.danger
            ? _danger(context)
            : widget.active
                ? _ramp(context).a2
                : (_hover ? _txt(context) : _sub(context));
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hover && widget.onTap != null
                  ? _prismHover(context)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(widget.icon, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}
