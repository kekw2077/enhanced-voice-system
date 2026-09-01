import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../widgets/glass_panel.dart';
import '../widgets/anim_accent.dart';

/// Экран приветствия. Показывается при запуске, пока включён
/// переключатель «Экран приветствия» в настройках.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onOpen, required this.showAtStartup, required this.onToggleStartup});

  final VoidCallback onOpen;
  final bool showAtStartup;
  final ValueChanged<bool> onToggleStartup;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _input = TextEditingController();

  static const _chips = [
    'Что ты умеешь?',
    'Настрой микрофон',
    'Нарисуй обои для рабочего стола',
    'Заведи команду «Сверни всё»',
  ];

  @override
  void dispose() { _input.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GlassPanel(
            radius: EvsRadius.chip,
            padding: const EdgeInsets.fromLTRB(8, 7, 15, 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 26, height: 26,
                decoration: BoxDecoration(gradient: t.accent.badge, borderRadius: BorderRadius.circular(9)),
                alignment: Alignment.center,
                child: const Text('✦', style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Text('EVS · Enhanced Voice System', style: EvsType.label.copyWith(color: p.body, fontSize: 12)),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(EvsRadius.chip)),
                child: Text('v1.2.0', style: EvsType.numeric.copyWith(color: p.sub, fontSize: 10.5)),
              ),
            ]),
          ),
          const SizedBox(height: 26),
          SizedBox(
            width: 900,
            child: Column(children: [
              Text('Ассистент, который',
                  textAlign: TextAlign.center,
                  style: EvsType.hero.copyWith(color: p.txt)),
              FlowingGradientText('живёт на вашем компьютере',
                  textAlign: TextAlign.center,
                  style: EvsType.hero),
            ]),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: 560,
            child: Text(
              'Слышит, отвечает голосом, выполняет команды в системе и рисует картинки. '
              'Без облака — модель работает локально.',
              textAlign: TextAlign.center,
              style: EvsType.bodyText.copyWith(color: p.sub, fontSize: 17, height: 1.5),
            ),
          ),
          const SizedBox(height: 26),
          Container(
            width: 720,
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              gradient: t.accent.badge,
              borderRadius: BorderRadius.circular(29),
              boxShadow: [BoxShadow(color: const Color(0x479B72CB), offset: const Offset(0, 22), blurRadius: 60)],
            ),
            child: GlassPanel(
              radius: 28,
              border: false,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  controller: _input,
                  onSubmitted: (_) => widget.onOpen(),
                  style: EvsType.bodyText.copyWith(color: p.txt, fontSize: 16),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Спросите что угодно',
                    hintStyle: EvsType.bodyText.copyWith(color: p.faint, fontSize: 16),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                    decoration: BoxDecoration(
                      color: p.chip,
                      borderRadius: BorderRadius.circular(EvsRadius.chip),
                      border: Border.all(color: p.stroke),
                    ),
                    child: Text('Локальная модель', style: EvsType.label.copyWith(color: p.body, fontSize: 12)),
                  ),
                  const SizedBox(width: 9),
                  Text('Свой сервер', style: EvsType.label.copyWith(color: p.faint, fontSize: 12)),
                  const Spacer(),
                  GestureDetector(
                    onTap: widget.onOpen,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          gradient: t.accent.badge,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: const Color(0x669B72CB), offset: const Offset(0, 8), blurRadius: 22)],
                        ),
                        child: const Icon(Icons.arrow_upward_rounded, size: 17, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            width: 760,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 10, runSpacing: 10,
              children: [
                for (final c in _chips)
                  GestureDetector(
                    onTap: widget.onOpen,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GlassPanel(
                        radius: EvsRadius.chip,
                        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('✦', style: TextStyle(color: t.accent.a2, fontSize: 12)),
                          const SizedBox(width: 8),
                          Text(c, style: EvsType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          GestureDetector(
            onTap: widget.onOpen,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                decoration: BoxDecoration(
                  color: p.btn,
                  borderRadius: BorderRadius.circular(EvsRadius.chip),
                  boxShadow: const [BoxShadow(color: Color(0x47000000), offset: Offset(0, 12), blurRadius: 32)],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Открыть EVS',
                      style: EvsType.label.copyWith(color: p.btnText, fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 9),
                  Icon(Icons.arrow_forward_rounded, size: 16, color: p.btnText),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => widget.onToggleStartup(!widget.showAtStartup),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 15, height: 15,
                  decoration: BoxDecoration(
                    color: widget.showAtStartup ? Colors.transparent : t.accent.a2,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: widget.showAtStartup ? p.stroke2 : t.accent.a2),
                  ),
                  child: widget.showAtStartup ? null : const Icon(Icons.check, size: 10, color: Colors.white),
                ),
                const SizedBox(width: 9),
                Text('Больше не показывать при запуске',
                    style: EvsType.caption.copyWith(color: p.faint, fontSize: 12.5)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
