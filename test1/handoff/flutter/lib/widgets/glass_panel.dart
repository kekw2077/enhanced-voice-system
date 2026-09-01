import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';

/// Панель со стеклом. Замена CSS-паре
/// background: var(--card); backdrop-filter: blur(var(--blur));
///
/// Важно: BackdropFilter дорогой. При EvsGlass.solid и EvsGlass.off
/// фильтр не создаётся вовсе — так же, как прототип обнуляет --blur.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = EvsRadius.card,
    this.padding = const EdgeInsets.all(16),
    this.border = true,
    this.shadow = false,
    this.color,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool border;
  final bool shadow;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final r = BorderRadius.circular(radius);

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? t.card,
        borderRadius: r,
        border: border ? Border.all(color: p.stroke, width: 1) : null,
      ),
      child: child,
    );

    if (t.blur > 0) {
      content = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: t.blur / 2, sigmaY: t.blur / 2),
        child: content,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: r, boxShadow: shadow ? p.shadow : null),
      child: ClipRRect(borderRadius: r, child: content),
    );
  }
}

/// Круглая «таблетка»: чипы, кнопки навигации, теги.
class EvsChip extends StatelessWidget {
  const EvsChip({super.key, required this.label, this.selected = false, this.onTap, this.leading});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: EvsMotion.hover,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? p.accentSoft : p.field,
          borderRadius: BorderRadius.circular(EvsRadius.chip),
          border: Border.all(color: selected ? t.accent.a2 : p.stroke),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (leading != null) Padding(padding: const EdgeInsets.only(right: 8), child: leading!),
          Text(label, style: EvsType.label.copyWith(color: selected ? p.txt : p.body)),
        ]),
      ),
    );
  }
}

/// Текст, залитый акцентным градиентом (CSS background-clip: text).
class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, required this.style, this.gradient});
  final String text;
  final TextStyle style;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final g = gradient ?? EvsTheme.of(context).accent.sweep;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => g.createShader(rect),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}
