import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../data/evs_data.dart';
import '../widgets/glass_panel.dart';
import '../widgets/controls.dart';

/// Экран «Nexus Sonora» — синтез речи.
/// Слева вкладки, параметры голоса и текст, справа волна и история озвучек.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _text = TextEditingController(
      text: 'Нейроконфигурация загружена. Задержка звукового конвейера '
          'на этом устройстве — восемнадцать миллисекунд.');

  String _tab = 'Системный';
  double _rate = 1, _pitch = 0.95, _vol = 85;
  bool _speaking = false;

  @override
  void dispose() { _text.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassPanel(
              radius: 18,
              padding: const EdgeInsets.all(5),
              child: Row(children: [
                for (final tab in ['Системный', 'Клон голоса'])
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _tab = tab),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: AnimatedContainer(
                          duration: EvsMotion.hover,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _tab == tab ? p.hover : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(tab, style: EvsType.label.copyWith(
                              color: _tab == tab ? p.txt : p.sub, fontSize: 13)),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.all(22),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const SectionLabel('Голос'),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: p.field,
                      borderRadius: BorderRadius.circular(EvsRadius.chip),
                      border: Border.all(color: p.stroke),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_tab == 'Системный' ? 'Системный голос' : 'Clone-Echo v3',
                          style: EvsType.label.copyWith(color: p.txt, fontSize: 12.5)),
                      const SizedBox(width: 9),
                      Icon(Icons.keyboard_arrow_down_rounded, size: 15, color: p.txt),
                    ]),
                  ),
                ]),
                const SizedBox(height: 17),
                LabeledSlider(label: 'Скорость речи', display: '${_rate.toStringAsFixed(2)}×',
                    value: _rate, min: 0.5, max: 2, step: 0.05, onChanged: (v) => setState(() => _rate = v)),
                const SizedBox(height: 17),
                LabeledSlider(label: 'Тон голоса', display: _pitch.toStringAsFixed(2),
                    value: _pitch, min: 0.5, max: 1.5, step: 0.05, onChanged: (v) => setState(() => _pitch = v)),
                const SizedBox(height: 17),
                LabeledSlider(label: 'Громкость', display: '${_vol.round()}%',
                    value: _vol, min: 0, max: 100, step: 1, onChanged: (v) => setState(() => _vol = v)),
              ]),
            ),
            const SizedBox(height: 16),
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.all(22),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Текст для озвучки'),
                const SizedBox(height: 14),
                EvsField(controller: _text, lines: 5, radius: 18, fontSize: 14),
                const SizedBox(height: 14),
                Row(children: [
                  Text('${_text.text.length} / 5000',
                      style: EvsType.numeric.copyWith(color: p.faint, fontSize: 11.5)),
                  const Spacer(),
                  GradientButton(
                    label: _speaking ? 'Остановить' : 'Озвучить',
                    icon: _speaking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    fontSize: 13.5,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                    onTap: () => setState(() => _speaking = !_speaking),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
        const SizedBox(width: 18),
        SizedBox(
          width: 320,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Волна'),
                const SizedBox(height: 15),
                SizedBox(height: 96, child: _Waveform(active: _speaking)),
                const SizedBox(height: 15),
                Row(children: [
                  Text(_speaking ? 'озвучивает' : 'ожидание',
                      style: EvsType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
                  const Spacer(),
                  Text('48 кГц · 16 бит', style: EvsType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
                ]),
              ]),
            ),
            const SizedBox(height: 16),
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Последние озвучки'),
                const SizedBox(height: 13),
                for (var i = 0; i < ttsHistory.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    decoration: BoxDecoration(
                      color: p.field,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: p.stroke),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(9)),
                        child: Icon(Icons.play_arrow_rounded, size: 13, color: t.accent.a2),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ttsHistory[i].voice, style: EvsType.label.copyWith(color: p.txt, fontSize: 12.5)),
                          const SizedBox(height: 2),
                          Text(ttsHistory[i].text,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: EvsType.caption.copyWith(color: p.faint, fontSize: 11)),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Text(ttsHistory[i].time, style: EvsType.numeric.copyWith(color: p.faint, fontSize: 10)),
                    ]),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Тридцать полосок, каждая со своей задержкой — CSS animation:bar.
class _Waveform extends StatefulWidget {
  const _Waveform({required this.active});
  final bool active;

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1050))..repeat(reverse: true);

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < 30; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: Builder(builder: (context) {
                final base = 0.24 + math.sin(i / 2.2).abs() * 0.70;
                final phase = widget.active ? (_c.value + i * 0.055) % 1.0 : 1.0;
                final scale = widget.active ? 0.18 + phase * 0.82 : 1.0;
                return FractionallySizedBox(
                  heightFactor: (base * scale).clamp(0.06, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [t.accent.a1, t.accent.a3],
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }
}
