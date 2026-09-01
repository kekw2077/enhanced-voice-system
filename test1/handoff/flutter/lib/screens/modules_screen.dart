import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../data/evs_data.dart';
import '../widgets/glass_panel.dart';
import '../widgets/controls.dart';

/// Экран «Модули»: три карточки подсистем, график загрузки процессора
/// за последние 60 секунд и журнал справа.
class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key});

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  double _cpu = 34, _vram = 71, _temp = 68, _tps = 45.8;
  int _lat = 18;
  bool _auto = true;
  Timer? _timer;
  final _rnd = math.Random();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1700), (_) {
      if (!_auto) return;
      setState(() {
        _cpu = _j(_cpu, 7, 12, 92);
        _vram = _j(_vram, 3, 52, 96);
        _temp = _j(_temp, 1.5, 52, 79);
        _tps = _j(_tps, 2.5, 28, 62);
        _lat = _j(_lat.toDouble(), 2, 11, 34).round();
      });
    });
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  double _j(double v, double amp, double lo, double hi) =>
      (v + (_rnd.nextDouble() - 0.5) * amp * 2).clamp(lo, hi);

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    final modules = [
      ModuleCard('Нейросеть', 'подключена', EvsPalette.ok, [
        ModuleRow('Видеопамять', '${(_vram / 100 * 16).toStringAsFixed(1)} ГБ', bar: _vram / 100),
        ModuleRow('Температура ядра', '${_temp.round()}°C', bar: (_temp - 40) / 50),
        ModuleRow('Скорость генерации', '${_tps.toStringAsFixed(1)} ток/с', accent: true),
      ]),
      ModuleCard('Синтез речи', 'активен', EvsPalette.ok, [
        ModuleRow('Задержка', '$_lat мс', bar: _lat / 40),
        const ModuleRow('Аудиокэш', '1.2 МБ', bar: 0.26),
        const ModuleRow('Голос', 'Clone-Echo v3', accent: true),
      ]),
      const ModuleCard('Распознавание', 'прогрев', EvsPalette.warn, [
        ModuleRow('Точность', '98.4%', bar: 0.98),
        ModuleRow('Буфер', '84 МБ', bar: 0.44),
        ModuleRow('Модель', 'whisper-large-v3', accent: true),
      ]),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SectionLabel('Состояние подсистем'),
          const Spacer(),
          Text('Автообновление', style: EvsType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
          const SizedBox(width: 10),
          EvsToggle(value: _auto, onChanged: (v) => setState(() => _auto = v)),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: () => setState(() => _cpu = _j(_cpu, 20, 12, 92)),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: p.field,
                  borderRadius: BorderRadius.circular(EvsRadius.chip),
                  border: Border.all(color: p.stroke),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.refresh_rounded, size: 14, color: p.txt),
                  const SizedBox(width: 8),
                  Text('Обновить', style: EvsType.label.copyWith(color: p.txt, fontSize: 12.5)),
                ]),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < modules.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: _ModuleCardView(card: modules[i])),
          ],
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: GlassPanel(
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Text('Загрузка процессора',
                      style: EvsType.label.copyWith(color: p.txt, fontSize: 14.5, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('последние 60 с', style: EvsType.numeric.copyWith(color: p.faint, fontSize: 11)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  height: 120,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _SparkPainter(cpu: _cpu, a1: t.accent.a1, a2: t.accent.a2, a3: t.accent.a3),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 300,
            child: GlassPanel(
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Журнал'),
                const SizedBox(height: 11),
                for (final l in [
                  LogEntry('только что', '', 'Модель llama-3.1-8b загружена в память', EvsPalette.ok),
                  LogEntry('3 мин назад', '', 'Команда «Открой браузер» выполнена', t.accent.a1),
                  LogEntry('18 мин назад', '', 'Достигнут тепловой предел на нейропроцессоре', EvsPalette.warn),
                  LogEntry('1 ч назад', '', 'Клон голоса Clone-Echo v3 обновлён', t.accent.a2),
                ]) ...[
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(color: l.color, shape: BoxShape.circle)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.text, style: EvsType.bodyText.copyWith(color: p.body, fontSize: 12.5, height: 1.4)),
                        const SizedBox(height: 2),
                        Text(l.time, style: EvsType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 11),
                ],
              ]),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _ModuleCardView extends StatelessWidget {
  const _ModuleCardView({required this.card});
  final ModuleCard card;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.all(20),
      shadow: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(card.name,
                style: EvsType.label.copyWith(color: p.txt, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          Container(width: 6, height: 6,
              decoration: BoxDecoration(color: card.statusColor, shape: BoxShape.circle, boxShadow: [
                BoxShadow(color: card.statusColor, blurRadius: 8),
              ])),
          const SizedBox(width: 6),
          Text(card.status, style: EvsType.label.copyWith(color: card.statusColor, fontSize: 11)),
        ]),
        const SizedBox(height: 15),
        for (var i = 0; i < card.rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 15),
          _row(context, card.rows[i]),
        ],
      ]),
    );
  }

  Widget _row(BuildContext context, ModuleRow r) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(r.name, style: EvsType.bodyText.copyWith(color: p.sub, fontSize: 12)),
        const Spacer(),
        Text(r.value, style: EvsType.numeric.copyWith(
            color: r.accent ? t.accent.a2 : p.txt, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ]),
      if (r.bar != null) ...[
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(children: [
            Container(height: 4, color: p.chip),
            LayoutBuilder(builder: (context, c) => AnimatedContainer(
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeInOutCubic,
              height: 4,
              width: c.maxWidth * r.bar!.clamp(0.0, 1.0),
              decoration: BoxDecoration(gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2])),
            )),
          ]),
        ),
      ],
    ]);
  }
}

/// График: та же формула, что в прототипе — две синусоиды плюс текущая загрузка.
class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.cpu, required this.a1, required this.a2, required this.a3});
  final double cpu;
  final Color a1, a2, a3;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = <Offset>[];
    for (var i = 0; i < 40; i++) {
      final v = 50 + math.sin(i / 2.4) * 22 + math.sin(i / 1.1) * 10 + (i == 39 ? (cpu - 50) * 0.5 : 0);
      pts.add(Offset(i / 39 * size.width, size.height - v.clamp(6, 104) / 110 * size.height));
    }

    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final pt in pts.skip(1)) line.lineTo(pt.dx, pt.dy);

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(fill, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [a2.withOpacity(0.28), a2.withOpacity(0)],
      ).createShader(Offset.zero & size));

    canvas.drawPath(line, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..shader = LinearGradient(colors: [a1, a3]).createShader(Offset.zero & size));
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.cpu != cpu;
}
