import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';

/// Мелкие элементы управления, встречающиеся на всех экранах.

/// Заголовок блока: 10.5–11px, жирный, разрядка, верхний регистр.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.size = 11});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: EvsType.section.copyWith(color: EvsTheme.of(context).palette.faint, fontSize: size),
      );
}

/// Переключатель 46×26 с белым бегунком.
class EvsToggle extends StatelessWidget {
  const EvsToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 46, height: 26,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: value ? LinearGradient(colors: [t.accent.a1, t.accent.a2]) : null,
            color: value ? null : t.palette.chip,
            borderRadius: BorderRadius.circular(EvsRadius.chip),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20, height: 20,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x4D000000), offset: Offset(0, 2), blurRadius: 6)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Сегменты в подложке — выбор одного из нескольких коротких вариантов.
class EvsSegmented extends StatelessWidget {
  const EvsSegmented({super.key, required this.options, required this.value, required this.onChanged, this.compact = false});
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(13)),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 3, runSpacing: 3,
        children: [
          for (final o in options)
            GestureDetector(
              onTap: () => onChanged(o),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: EvsMotion.hover,
                  padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: o == value ? p.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: o == value ? t.accent.a2 : Colors.transparent),
                  ),
                  child: Text(o, style: EvsType.label.copyWith(fontSize: 12, color: o == value ? p.txt : p.sub)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ползунок: дорожка 5px, градиентная заливка, белый кружок 14px.
class EvsSlider extends StatelessWidget {
  const EvsSlider({super.key, required this.value, required this.min, required this.max, required this.onChanged, this.step});
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
    final t = EvsTheme.of(context);
    final p = t.palette;
    final frac = ((value - min) / (max - min)).clamp(0.0, 1.0);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return GestureDetector(
        onTapDown: (e) => _emit(e.localPosition.dx, w),
        onHorizontalDragUpdate: (e) => _emit(e.localPosition.dx, w),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            height: 20,
            child: Stack(alignment: Alignment.centerLeft, children: [
              Container(
                height: 5,
                decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(5)),
              ),
              Container(
                height: 5,
                width: w * frac,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2]),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              Positioned(
                left: (w * frac - 7).clamp(0.0, w - 14),
                child: Container(
                  width: 14, height: 14,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Color(0x59000000), offset: Offset(0, 2), blurRadius: 8)],
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

/// Строка «подпись — значение — ползунок», как на экранах картинок и голоса.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({super.key, required this.label, required this.display,
    required this.value, required this.min, required this.max, required this.onChanged, this.step});

  final String label, display;
  final double value, min, max;
  final double? step;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(label, style: EvsType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
        const Spacer(),
        Text(display, style: EvsType.numeric.copyWith(color: p.txt, fontSize: 12.5, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 9),
      EvsSlider(value: value, min: min, max: max, step: step, onChanged: onChanged),
    ]);
  }
}

/// Кнопка-таблетка с акцентным градиентом.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.icon, this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10), this.radius = EvsRadius.chip, this.fontSize = 13});

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double radius, fontSize;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            gradient: t.accent.sweep,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [BoxShadow(color: const Color(0x579B72CB), offset: const Offset(0, 8), blurRadius: 22)],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 7)],
            Text(label, style: EvsType.label.copyWith(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// Поле ввода в стиле EVS: подложка --field, рамка --stroke.
class EvsField extends StatelessWidget {
  const EvsField({super.key, required this.controller, this.hint, this.lines = 1, this.mono = false, this.radius = 16, this.fontSize = 13.5});
  final TextEditingController controller;
  final String? hint;
  final int lines;
  final bool mono;
  final double radius, fontSize;

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return TextField(
      controller: controller,
      maxLines: lines,
      style: (mono ? EvsType.numeric : EvsType.bodyText).copyWith(color: p.body, fontSize: fontSize, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: EvsType.bodyText.copyWith(color: p.faint, fontSize: fontSize),
        filled: true,
        fillColor: p.field,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: lines > 1 ? 14 : 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.stroke)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.stroke)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: EvsTheme.of(context).accent.a2)),
      ),
    );
  }
}
