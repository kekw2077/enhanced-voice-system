import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../data/evs_data.dart';
import '../widgets/glass_panel.dart';
import '../widgets/controls.dart';

/// Экран «Команды»: слева разделы, справа каталог фраз и медиа-шорткаты.
class CommandsScreen extends StatefulWidget {
  const CommandsScreen({super.key});

  @override
  State<CommandsScreen> createState() => _CommandsScreenState();
}

class _CommandsScreenState extends State<CommandsScreen> {
  final _commands = defaultCommands();
  String _tab = 'catalog';

  static const _tabs = [
    ['exec', 'Выполнение'],
    ['catalog', 'Каталог команд'],
    ['safe', 'Безопасность'],
  ];

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 230,
          child: GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(14),
            shadow: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              for (final tab in _tabs)
                GestureDetector(
                  onTap: () => setState(() => _tab = tab[0]),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: AnimatedContainer(
                      duration: EvsMotion.hover,
                      margin: const EdgeInsets.only(bottom: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: _tab == tab[0] ? p.hover : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(tab[1],
                          style: EvsType.label.copyWith(color: _tab == tab[0] ? p.txt : p.sub, fontSize: 13)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.all(22),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Каталог команд',
                          style: EvsType.label.copyWith(color: p.txt, fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text('Фраза → действие в системе. Работают и при выключенном чате.',
                          style: EvsType.caption.copyWith(color: p.sub, fontSize: 12)),
                    ]),
                  ),
                  const SizedBox(width: 14),
                  const GradientButton(label: 'Добавить команду', icon: Icons.add_rounded,
                      padding: EdgeInsets.symmetric(horizontal: 17, vertical: 10), fontSize: 12.5),
                ]),
                const SizedBox(height: 14),
                for (var i = 0; i < _commands.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _CommandRow(
                    command: _commands[i],
                    onToggle: () => setState(() => _commands[i].enabled = !_commands[i].enabled),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 16),
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SectionLabel('Медиа-шорткаты'),
                const SizedBox(height: 18),
                Wrap(spacing: 18, runSpacing: 12, children: [
                  for (final s in mediaShortcuts)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: p.field,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: p.stroke),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(s[0], style: EvsType.numeric.copyWith(color: t.accent.a2, fontSize: 11.5)),
                        const SizedBox(width: 9),
                        Text(s[1], style: EvsType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
                      ]),
                    ),
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command, required this.onToggle});
  final VoiceCommand command;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final on = command.enabled;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        gradient: on
            ? LinearGradient(colors: [p.accentStrong, Colors.transparent],
                begin: Alignment.centerLeft, end: Alignment.centerRight, stops: const [0, 0.88])
            : null,
        color: on ? null : p.field,
        borderRadius: BorderRadius.circular(20),
        border: Border(
          left: BorderSide(color: on ? t.accent.a2 : p.stroke, width: on ? 3 : 1),
          top: BorderSide(color: on ? p.accentLine : p.stroke),
          right: BorderSide(color: on ? p.accentLine : p.stroke),
          bottom: BorderSide(color: on ? p.accentLine : p.stroke),
        ),
      ),
      child: Row(children: [
        SizedBox(width: 210, child: _cell(context, 'фраза', '«${command.phrase}»', bold: true)),
        const SizedBox(width: 18),
        SizedBox(width: 150, child: _cell(context, 'действие', command.action)),
        const SizedBox(width: 18),
        Expanded(child: _cell(context, 'цель', command.target, mono: true)),
        const SizedBox(width: 18),
        EvsToggle(value: on, onChanged: (_) => onToggle()),
      ]),
    );
  }

  Widget _cell(BuildContext context, String label, String value, {bool bold = false, bool mono = false}) {
    final p = EvsTheme.of(context).palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label.toUpperCase(), style: EvsType.section.copyWith(color: p.faint, fontSize: 10)),
      const SizedBox(height: 4),
      Text(value,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: (mono ? EvsType.numeric : EvsType.bodyText).copyWith(
              color: bold ? p.txt : p.body,
              fontSize: bold ? 14 : 13,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
    ]);
  }
}
