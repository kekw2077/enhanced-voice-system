import 'dart:async';
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../widgets/glass_panel.dart';
import '../widgets/controls.dart';

/// Экран «Nexus Lumina» — генерация изображений.
/// Слева параметры, справа холст результата и история.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  final _prompt = TextEditingController(
      text: 'ретро-пульт управления, светящиеся экраны, мягкий голографический свет, '
          'палитра синий-циан, объёмный воздух, 16:9');
  final _negative = TextEditingController(text: 'плохая анатомия, низкое разрешение, водяные знаки');

  double _steps = 28, _cfg = 7.5, _progress = 0;
  int _res = 1024;
  bool _generating = false;
  Timer? _tick;

  @override
  void dispose() {
    _prompt.dispose();
    _negative.dispose();
    _tick?.cancel();
    super.dispose();
  }

  void _generate() {
    if (_generating) {
      _tick?.cancel();
      setState(() { _generating = false; _progress = 0; });
      return;
    }
    setState(() { _generating = true; _progress = 0; });
    _tick = Timer.periodic(const Duration(milliseconds: 220), (t) {
      setState(() {
        _progress += 0.045;
        if (_progress >= 1) { _progress = 1; _generating = false; t.cancel(); }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 404,
          child: GlassPanel(
            radius: 26,
            padding: const EdgeInsets.all(22),
            shadow: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionLabel('Описание', size: 10.5),
              const SizedBox(height: 8),
              EvsField(controller: _prompt, lines: 4, radius: 18),
              const SizedBox(height: 16),
              const SectionLabel('Исключить', size: 10.5),
              const SizedBox(height: 8),
              EvsField(controller: _negative, fontSize: 13),
              const SizedBox(height: 16),
              LabeledSlider(
                label: 'Шаги сэмплирования',
                display: '${_steps.round()}',
                value: _steps, min: 10, max: 60, step: 1,
                onChanged: (v) => setState(() => _steps = v),
              ),
              const SizedBox(height: 16),
              LabeledSlider(
                label: 'Сила подсказки (CFG)',
                display: _cfg.toStringAsFixed(1),
                value: _cfg, min: 1, max: 14, step: 0.5,
                onChanged: (v) => setState(() => _cfg = v),
              ),
              const SizedBox(height: 16),
              const SectionLabel('Разрешение', size: 10.5),
              const SizedBox(height: 9),
              Row(children: [
                for (final r in [512, 768, 1024]) ...[
                  if (r != 512) const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _res = r),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: AnimatedContainer(
                          duration: EvsMotion.hover,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: _res == r ? LinearGradient(colors: [t.accent.a1, t.accent.a2]) : null,
                            color: _res == r ? null : p.field,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _res == r ? Colors.transparent : p.stroke),
                          ),
                          child: Text('$r×$r',
                              style: EvsType.numeric.copyWith(
                                  color: _res == r ? Colors.white : p.sub, fontSize: 12.5, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 16),
              GradientButton(
                label: _generating ? 'Остановить' : 'Сгенерировать',
                onTap: _generate,
                radius: 18,
                fontSize: 14.5,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.all(14),
              shadow: true,
              child: Container(
                height: 392,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: p.stroke),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(children: [
                    Positioned.fill(child: CustomPaint(painter: _HatchPainter(color: p.field, gap: 10))),
                    Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_generating ? 'ГЕНЕРАЦИЯ…' : 'ОЖИДАНИЕ ЗАПРОСА',
                            style: EvsType.numeric.copyWith(color: p.faint, fontSize: 11, letterSpacing: 0.66)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 196,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Stack(children: [
                              Container(height: 4, color: p.chip),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 500),
                                height: 4,
                                width: 196 * _progress,
                                decoration: BoxDecoration(gradient: LinearGradient(colors: [t.accent.a1, t.accent.a3])),
                              ),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 280,
                          child: Text('Здесь появится результат — сюда же можно перетащить референс',
                              textAlign: TextAlign.center,
                              style: EvsType.bodyText.copyWith(color: p.sub, fontSize: 12)),
                        ),
                      ]),
                    ),
                    Positioned(
                      left: 14, top: 14,
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2]),
                            borderRadius: BorderRadius.circular(EvsRadius.chip),
                          ),
                          child: Text('Скачать HD',
                              style: EvsType.label.copyWith(color: Colors.white, fontSize: 11.5)),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                          decoration: BoxDecoration(
                            color: p.chip,
                            borderRadius: BorderRadius.circular(EvsRadius.chip),
                            border: Border.all(color: p.stroke),
                          ),
                          child: Text('Апскейл 4×', style: EvsType.label.copyWith(color: p.body, fontSize: 11.5)),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassPanel(
              radius: 26,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              shadow: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('История'),
                const SizedBox(height: 12),
                Row(children: [
                  for (final h in ['1024²', '1024²', '768²', '512²']) ...[
                    if (h != '1024²' || true) const SizedBox(width: 0),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: p.stroke),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Stack(children: [
                                Positioned.fill(child: CustomPaint(painter: _HatchPainter(color: p.field, gap: 8))),
                                Positioned(
                                  right: 9, bottom: 9,
                                  child: Text(h, style: EvsType.numeric.copyWith(color: p.faint, fontSize: 9.5)),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Косая штриховка — замена CSS repeating-linear-gradient.
class _HatchPainter extends CustomPainter {
  _HatchPainter({required this.color, required this.gap});
  final Color color;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = gap..style = PaintingStyle.stroke;
    final step = gap * 2;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}
