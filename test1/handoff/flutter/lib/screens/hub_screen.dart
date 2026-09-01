import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../models/evs_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/voice_orb.dart';
import '../widgets/chat_panel.dart';

/// Экран «Центр». Слева состояние ассистента и загрузка подсистем,
/// справа — активный чат. Разметка повторяет прототип:
/// левая колонка 376px (минимум 308), правая тянется, минимум 404.
class HubScreen extends StatefulWidget {
  const HubScreen({super.key});

  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  VoiceState _state = VoiceState.listening;
  bool _typing = false;
  bool _chatEnabled = true;
  bool _pinned = true;
  String _chatTitle = 'Локальная нейроархитектура';

  double _cpu = 34, _vram = 71, _gpu = 88, _tps = 45.8, _ctx = 38;
  int _lat = 18;

  Timer? _metrics, _reply;
  final _rnd = math.Random();

  final List<ChatMessage> _messages = [
    const ChatMessage(
      text: 'Как поднять локальную модель и связать её с моим Python-контроллером?',
      fromAssistant: false,
    ),
    const ChatMessage(
      text: 'Чтобы развернуть модель локально:',
      fromAssistant: true,
      steps: [
        'Поднимите llama.cpp или Ollama как backend-сервер.',
        'Сделайте Python-сервис, который ходит в него по HTTP.',
        'Проброс голоса: Whisper на вход, XTTS на выход.',
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    // Живые числа. В настоящем приложении сюда придут реальные метрики.
    _metrics = Timer.periodic(const Duration(milliseconds: 1700), (_) {
      setState(() {
        _cpu = _jitter(_cpu, 7, 12, 92);
        _vram = _jitter(_vram, 3, 52, 96);
        _gpu = _jitter(_gpu, 6, 40, 99);
        _tps = _jitter(_tps, 2.5, 28, 62);
        _lat = _jitter(_lat.toDouble(), 2, 11, 34).round();
      });
    });
  }

  @override
  void dispose() {
    _metrics?.cancel();
    _reply?.cancel();
    super.dispose();
  }

  double _jitter(double v, double amp, double lo, double hi) =>
      (v + (_rnd.nextDouble() - 0.5) * amp * 2).clamp(lo, hi);

  void _send(String text) {
    setState(() {
      _messages.add(ChatMessage(text: text, fromAssistant: false));
      _typing = true;
      _state = VoiceState.thinking;
    });
    _reply?.cancel();
    _reply = Timer(const Duration(milliseconds: 1900), () {
      if (!mounted) return;
      setState(() {
        _typing = false;
        _state = VoiceState.speaking;
        _messages.add(const ChatMessage(
          text: 'Принято. Локальный стек отвечает: модель держит контекст, '
              'распознавание слушает, синтез готов озвучить ответ.',
          fromAssistant: true,
        ));
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 900;
      final left = _leftColumn(context);
      final right = _chat(context);
      if (narrow) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(children: [left, const SizedBox(height: 18), SizedBox(height: 520, child: right)]),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 376, child: left),
          const SizedBox(width: 18),
          Expanded(child: right),
        ]),
      );
    });
  }

  Widget _chat(BuildContext context) => ChatPanel(
        title: _chatTitle,
        meta: '${_messages.length} сообщений · локальная модель',
        messages: _messages,
        typing: _typing,
        contextPercent: _ctx,
        chatEnabled: _chatEnabled,
        pinned: _pinned,
        onSend: _send,
        onToggleChat: () => setState(() => _chatEnabled = !_chatEnabled),
        onTogglePin: () => setState(() => _pinned = !_pinned),
        onClear: () => setState(() {
          _reply?.cancel();
          _messages.clear();
          _typing = false;
          _state = VoiceState.idle;
        }),
        onDelete: () => setState(() {
          _reply?.cancel();
          _messages.clear();
          _typing = false;
          _pinned = false;
          _state = VoiceState.idle;
          _chatTitle = 'Новый чат';
        }),
      );

  Widget _leftColumn(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _assistantCard(context),
          const SizedBox(height: 18),
          _subsystemsCard(context),
        ],
      );

  Widget _assistantCard(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final s = _state;
    final idle = s.isIdle;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          ...p.shadow,
          if (!idle) BoxShadow(color: s.c1.withOpacity(0.2), blurRadius: 46),
        ],
      ),
      child: GlassPanel(
        radius: 26,
        padding: const EdgeInsets.all(22),
        color: t.card,
        child: Column(children: [
          Row(children: [
            Text('Ассистент', style: EvsType.section.copyWith(color: p.faint, fontSize: 11)),
            const Spacer(),
            AnimatedContainer(
              duration: const Duration(milliseconds: 450),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: idle ? p.chip : s.c1.withOpacity(0.16),
                borderRadius: BorderRadius.circular(EvsRadius.chip),
              ),
              child: Text(s.label,
                  style: EvsType.label.copyWith(fontSize: 11, color: idle ? p.sub : s.c1)),
            ),
          ]),
          const SizedBox(height: 14),
          VoiceOrb(state: s, onTap: () => setState(() => _state = s.next)),
          const SizedBox(height: 14),
          Text(s.hint,
              textAlign: TextAlign.center,
              style: EvsType.label.copyWith(
                  fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.5,
                  color: idle ? p.txt : s.c1)),
          const SizedBox(height: 5),
          Text('Скажите «Привет, EVS» или нажмите пробел',
              textAlign: TextAlign.center,
              style: EvsType.caption.copyWith(color: p.sub, fontSize: 12.5)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: p.field,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.stroke),
            ),
            child: Row(children: [
              Container(width: 6, height: 6,
                  decoration: const BoxDecoration(color: EvsPalette.ok, shape: BoxShape.circle)),
              const SizedBox(width: 9),
              Text('онлайн', style: EvsType.numeric.copyWith(color: p.sub, fontSize: 11)),
              const Spacer(),
              Text('$_lat мс · ${_tps.toStringAsFixed(1)} ток/с',
                  style: EvsType.numeric.copyWith(color: p.sub, fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _subsystemsCard(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final metrics = [
      HwMetric('Процессор · 24 ядра', '${_cpu.round()}%', _cpu / 100),
      HwMetric('Видеопамять', '${(_vram / 100 * 16).toStringAsFixed(1)} / 16 ГБ', _vram / 100),
      HwMetric('Графика', '${_gpu.round()}%', _gpu / 100),
    ];

    return GlassPanel(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Подсистемы', style: EvsType.section.copyWith(color: p.faint, fontSize: 11)),
        const SizedBox(height: 15),
        for (var i = 0; i < metrics.length; i++) ...[
          if (i > 0) const SizedBox(height: 15),
          _MetricRow(metric: metrics[i]),
        ],
      ]),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.metric});
  final HwMetric metric;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(metric.name, style: EvsType.bodyText.copyWith(color: p.body, fontSize: 13)),
        const Spacer(),
        Text(metric.value, style: EvsType.numeric.copyWith(color: p.txt, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 7),
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(children: [
          Container(height: 5, color: p.chip),
          LayoutBuilder(builder: (context, c) => AnimatedContainer(
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOutCubic,
            height: 5,
            width: c.maxWidth * metric.fraction.clamp(0.0, 1.0),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2]),
              borderRadius: BorderRadius.circular(5),
            ),
          )),
        ]),
      ),
    ]);
  }
}
