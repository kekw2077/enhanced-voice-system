import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import 'glass_panel.dart';
import 'dot_grid.dart';
import 'aurora_background.dart';

/// Оболочка окна: фон → сетка точек → боковое меню + шапка + содержимое.
/// Порядок слоёв тот же, что в прототипе, и его лучше не менять:
/// фон и сетка не перехватывают клики, весь UI лежит поверх.
class EvsShell extends StatelessWidget {
  const EvsShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    required this.items,
    required this.current,
    required this.onSelect,
    this.actions = const [],
  });

  final String title, subtitle;
  final Widget child;
  final List<EvsNavItem> items;
  final String current;
  final ValueChanged<String> onSelect;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    return Container(
      color: p.bg,
      child: Stack(children: [
        const Positioned.fill(child: EvsBackgroundLayer()),
        const Positioned.fill(child: DotGrid()),
        Positioned.fill(
          child: Row(children: [
            _Sidebar(items: items, current: current, onSelect: onSelect),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _Header(title: title, subtitle: subtitle, actions: actions),
                Expanded(child: child),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class EvsNavItem {
  const EvsNavItem(this.id, this.label, this.icon, this.shortcut);
  final String id, label, shortcut;
  final IconData icon;
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.items, required this.current, required this.onSelect});
  final List<EvsNavItem> items;
  final String current;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Container(
      width: 232,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(border: Border(right: BorderSide(color: p.stroke))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(gradient: t.accent.badge, borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: const Text('✦', style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
          const SizedBox(width: 10),
          Text('EVS', style: EvsType.label.copyWith(color: p.txt, fontSize: 14)),
        ]),
        const SizedBox(height: 22),
        for (final it in items) ...[
          _NavRow(item: it, selected: it.id == current, onTap: () => onSelect(it.id)),
          const SizedBox(height: 4),
        ],
        const Spacer(),
      ]),
    );
  }
}

class _NavRow extends StatefulWidget {
  const _NavRow({required this.item, required this.selected, required this.onTap});
  final EvsNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: EvsMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: on ? p.accentSoft : (_hover ? p.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(EvsRadius.tile),
            border: Border.all(color: on ? t.accent.a2.withOpacity(0.5) : Colors.transparent),
          ),
          child: Row(children: [
            Icon(widget.item.icon, size: 17, color: on ? p.txt : p.sub),
            const SizedBox(width: 11),
            Expanded(child: Text(widget.item.label,
                style: EvsType.label.copyWith(color: on ? p.txt : p.body))),
            Text(widget.item.shortcut, style: EvsType.numeric.copyWith(color: p.faint)),
          ]),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle, required this.actions});
  final String title, subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(26, 20, 20, 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.stroke))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: EvsType.title.copyWith(color: p.txt)),
            const SizedBox(height: 3),
            Text(subtitle, style: EvsType.caption.copyWith(color: p.sub)),
          ]),
        ),
        ...actions,
      ]),
    );
  }
}
