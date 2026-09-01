import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../data/evs_data.dart';
import '../data/settings_data.dart';
import '../models/evs_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/controls.dart';
import '../widgets/voice_orb.dart';
import '../widgets/viz_visual.dart';

/// Экран «Настройки»: слева 11 разделов, справа страницы и карточки.
/// Значения живут в одной карте [_cfg] — ключ строки → значение.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onOpenCommands, this.initialConfig = const {}, this.onConfigChanged});

  final VoidCallback? onOpenCommands;
  /// Сохранённые значения строк (EvsPrefs.config).
  final Map<String, Object> initialConfig;
  /// Вызывается при каждом изменении строки — сюда вешается сохранение.
  final void Function(String key, Object value)? onConfigChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _section = 'app';
  final Map<String, String> _page = {};
  late final Map<String, Object> _cfg = {...widget.initialConfig};
  String _logTag = 'Все';
  String _vizStyle = 'Сфера';
  VoiceState _vstate = VoiceState.listening;

  SetSection get _sec => settingsSections.firstWhere((s) => s.id == _section);
  SetPage get _pg {
    final id = _page[_section] ?? _sec.pages.first.id;
    return _sec.pages.firstWhere((p) => p.id == id, orElse: () => _sec.pages.first);
  }

  Object? _val(SetRow r) => (r.key != null && _cfg.containsKey(r.key)) ? _cfg[r.key] : r.value;
  void _set(String key, Object v) {
    setState(() => _cfg[key] = v);
    widget.onConfigChanged?.call(key, v);
  }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 252, child: _sidebar(context)),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_sec.title,
                      style: EvsType.label.copyWith(color: p.txt, fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.42)),
                  const SizedBox(height: 3),
                  Text(_sec.subtitle, style: EvsType.caption.copyWith(color: p.sub, fontSize: 12.5)),
                ]),
              ),
              if (_sec.pages.length > 1) _pageTabs(context),
            ]),
            const SizedBox(height: 16),
            for (final c in _pg.cards) ...[
              _card(context, c),
              const SizedBox(height: 16),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _sidebar(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(12),
      shadow: true,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < settingsSections.length; i++)
          Builder(builder: (context) {
            final s = settingsSections[i];
            final on = s.id == _section;
            return GestureDetector(
              onTap: () => setState(() => _section = s.id),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: EvsMotion.hover,
                  margin: const EdgeInsets.only(bottom: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: on ? p.hover : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: on ? p.stroke : Colors.transparent),
                  ),
                  child: Row(children: [
                    SizedBox(
                      width: 13,
                      child: Text('${i < 9 ? '0' : ''}${i + 1}',
                          style: EvsType.numeric.copyWith(color: p.faint, fontSize: 9.5)),
                    ),
                    const SizedBox(width: 10),
                    Icon(s.icon, size: 16, color: on ? p.txt : p.sub),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: EvsType.label.copyWith(color: on ? p.txt : p.sub, fontSize: 12.8)),
                    ),
                  ]),
                ),
              ),
            );
          }),
      ]),
    );
  }

  Widget _pageTabs(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return GlassPanel(
      radius: 16,
      padding: const EdgeInsets.all(4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final pg in _sec.pages)
          GestureDetector(
            onTap: () => setState(() => _page[_section] = pg.id),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: EvsMotion.hover,
                margin: const EdgeInsets.only(left: 3),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: pg.id == _pg.id ? p.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: pg.id == _pg.id ? t.accent.a2 : Colors.transparent),
                ),
                child: Text(pg.title,
                    style: EvsType.label.copyWith(color: pg.id == _pg.id ? p.txt : p.sub, fontSize: 12.5)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _card(BuildContext context, SetCard c) {
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(c.title, size: 10.5),
        const SizedBox(height: 12),
        for (final r in c.rows) ...[_row(context, r), const SizedBox(height: 12)],
        if (c.kind == CardKind.models) for (final m in c.items) ...[_model(context, m), const SizedBox(height: 12)],
        if (c.kind == CardKind.widget) _widgetCard(context),
        if (c.kind == CardKind.log) _logCard(context),
      ]),
    );
  }

  Widget _row(BuildContext context, SetRow r) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final v = _val(r);
    final toggled = r.kind == RowKind.toggle && v == true;

    Widget? control;
    switch (r.kind) {
      case RowKind.toggle:
        control = EvsToggle(value: v == true, onChanged: (nv) => _set(r.key!, nv));
      case RowKind.segmented:
        control = EvsSegmented(
          options: r.options,
          value: v as String,
          onChanged: (nv) => _set(r.key!, nv),
        );
      case RowKind.value:
        control = Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(12)),
          child: Text('$v', style: EvsType.numeric.copyWith(color: p.body, fontSize: 12.5)),
        );
      case RowKind.text:
        control = SizedBox(
          width: 256,
          child: TextFormField(
            initialValue: '$v',
            onChanged: (nv) { _cfg[r.key!] = nv; widget.onConfigChanged?.call(r.key!, nv); },
            style: EvsType.numeric.copyWith(color: p.body, fontSize: 12.5),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: p.solid,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: p.stroke)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: p.stroke)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: t.accent.a2)),
            ),
          ),
        );
      case RowKind.hotkey:
        control = Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(11)),
            child: Text('$v', style: EvsType.numeric.copyWith(color: p.body, fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.stroke2),
            ),
            child: Text('Назначить', style: EvsType.label.copyWith(color: p.txt, fontSize: 12)),
          ),
        ]);
      case RowKind.button:
        control = GestureDetector(
          onTap: r.name == 'Каталог команд' ? widget.onOpenCommands : null,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: r.danger ? const Color(0x1AFF7A7A) : p.chip,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: r.danger ? const Color(0x66FF7A7A) : p.stroke2),
              ),
              child: Text(r.button!,
                  style: EvsType.label.copyWith(color: r.danger ? EvsPalette.danger : p.txt, fontSize: 12.5)),
            ),
          ),
        );
      case RowKind.slider:
        final d = (v as num).toDouble();
        control = Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(11)),
          child: Text('${r.decimals > 0 ? d.toStringAsFixed(r.decimals) : d.round()}${r.unit}',
              style: EvsType.numeric.copyWith(color: p.txt, fontSize: 12.5, fontWeight: FontWeight.w700)),
        );
      case RowKind.area:
        control = null;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: toggled
            ? LinearGradient(colors: [p.accentStrong, Colors.transparent],
                begin: Alignment.centerLeft, end: Alignment.centerRight, stops: const [0, 0.88])
            : null,
        color: toggled ? null : p.field,
        borderRadius: BorderRadius.circular(18),
        border: Border(
          left: BorderSide(color: toggled ? t.accent.a2 : p.stroke, width: toggled ? 3 : 1),
          top: BorderSide(color: toggled ? p.accentLine : p.stroke),
          right: BorderSide(color: toggled ? p.accentLine : p.stroke),
          bottom: BorderSide(color: toggled ? p.accentLine : p.stroke),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(r.name, style: EvsType.label.copyWith(color: p.txt, fontSize: 13.5)),
              if (r.sub.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(r.sub, style: EvsType.caption.copyWith(color: p.faint, fontSize: 11.5, height: 1.45)),
              ],
            ]),
          ),
          const Spacer(),
          if (control != null) Flexible(child: Align(alignment: Alignment.centerRight, child: control)),
        ]),
        if (r.kind == RowKind.slider) ...[
          const SizedBox(height: 11),
          EvsSlider(
            value: (v as num).toDouble(),
            min: r.min, max: r.max, step: r.step,
            onChanged: (nv) => _set(r.key!, nv),
          ),
        ],
        if (r.kind == RowKind.area) ...[
          const SizedBox(height: 11),
          TextFormField(
            initialValue: '$v',
            maxLines: 3,
            onChanged: (nv) { _cfg[r.key!] = nv; widget.onConfigChanged?.call(r.key!, nv); },
            style: EvsType.bodyText.copyWith(color: p.body, fontSize: 13, height: 1.5),
            decoration: InputDecoration(
              filled: true,
              fillColor: p.solid,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.stroke)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.stroke)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: t.accent.a2)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _model(BuildContext context, ModelItem m) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final active = m.status == 'Активна';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        gradient: active
            ? LinearGradient(colors: [p.accentSoft, Colors.transparent],
                begin: Alignment.centerLeft, end: Alignment.centerRight, stops: const [0, 0.88])
            : null,
        color: active ? null : p.field,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: active ? p.accentLine : p.stroke),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(m.name, style: EvsType.label.copyWith(color: p.txt, fontSize: 13.5)),
              const SizedBox(width: 9),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(EvsRadius.chip)),
                child: Text(m.status,
                    style: EvsType.label.copyWith(
                        fontSize: 10, fontWeight: FontWeight.w700,
                        color: m.statusColor(EvsPalette.ok, t.accent.a2, p.faint))),
              ),
            ]),
            const SizedBox(height: 3),
            Text(m.sub, style: EvsType.caption.copyWith(color: p.faint, fontSize: 11.5)),
          ]),
        ),
        const SizedBox(width: 14),
        Text(m.size, style: EvsType.numeric.copyWith(color: p.faint, fontSize: 11)),
        const SizedBox(width: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: p.stroke2),
          ),
          child: Text(m.action, style: EvsType.label.copyWith(color: p.txt, fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _widgetCard(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _vstate.isIdle ? p.stroke : _vstate.c1.withOpacity(0.42)),
        ),
        child: Row(children: [
          SizedBox(width: 96, height: 96, child: VizVisual(style: _vizStyle, state: _vstate, size: 96)),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_vstate.hint,
                  style: EvsType.label.copyWith(
                      color: _vstate.isIdle ? p.txt : _vstate.c1, fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 11),
              Wrap(spacing: 7, runSpacing: 7, children: [
                for (final s in VoiceState.values)
                  GestureDetector(
                    onTap: () => setState(() => _vstate = s),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: s == _vstate ? s.c1.withOpacity(0.18) : Colors.transparent,
                          borderRadius: BorderRadius.circular(EvsRadius.chip),
                          border: Border.all(color: s == _vstate ? s.c1.withOpacity(0.5) : p.stroke),
                        ),
                        child: Text(
                          switch (s) {
                            VoiceState.idle => 'Ожидание',
                            VoiceState.listening => 'Слушает',
                            VoiceState.thinking => 'Думает',
                            VoiceState.speaking => 'Говорит',
                          },
                          style: EvsType.label.copyWith(fontSize: 12, color: s == _vstate ? s.c1 : p.sub),
                        ),
                      ),
                    ),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.55,
        children: [
          for (final v in vizStyles)
            GestureDetector(
              onTap: () => setState(() => _vizStyle = v),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: v == _vizStyle ? p.accentSoft : p.field,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: v == _vizStyle ? t.accent.a2 : p.stroke),
                  ),
                  child: Column(children: [
                    Expanded(child: _VizPreview(style: v)),
                    const SizedBox(height: 9),
                    Text(v, style: EvsType.label.copyWith(color: v == _vizStyle ? p.txt : p.sub, fontSize: 12)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    ]);
  }

  Widget _logCard(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final lines = <LogEntry>[
      LogEntry('12:04:31', 'Модель', 'llama-3.1-8b загружена в память · 5.4 ГБ', EvsPalette.ok),
      LogEntry('12:04:29', 'Голос', 'whisper-large-v3 · движок распознавания готов', t.accent.a1),
      LogEntry('12:03:58', 'Команды', '«Открой браузер» → chrome.exe выполнено', t.accent.a2),
      LogEntry('12:01:12', 'Обновления', 'Проверка обновлений: установлена последняя версия', p.sub),
      LogEntry('11:58:40', 'Ошибки', 'Сервер распознавания не отвечает, распознаю локально', EvsPalette.warn),
      LogEntry('11:57:03', 'Телефон', 'Устройство 192.168.0.31 отключилось', p.sub),
      LogEntry('11:56:22', 'Голос', 'Клон Clone-Echo v3 обновлён · 86 МБ', t.accent.a1),
      LogEntry('11:50:07', 'Модель', 'Тепловой предел нейропроцессора · 79 °C', EvsPalette.warn),
    ];
    final shown = _logTag == 'Все' ? lines : lines.where((l) => l.tag == _logTag).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final f in logTags)
          GestureDetector(
            onTap: () => setState(() => _logTag = f),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: EvsMotion.hover,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: f == _logTag ? p.accentSoft : p.field,
                  borderRadius: BorderRadius.circular(EvsRadius.chip),
                  border: Border.all(color: f == _logTag ? p.accentLine : p.stroke),
                ),
                child: Text(f, style: EvsType.label.copyWith(color: f == _logTag ? p.txt : p.sub, fontSize: 12)),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 14),
      for (final l in shown)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.time, style: EvsType.numeric.copyWith(color: p.faint, fontSize: 11)),
            const SizedBox(width: 12),
            Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(color: l.color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Text(l.text, style: EvsType.bodyText.copyWith(color: p.body, fontSize: 12.5, height: 1.4))),
          ]),
        ),
    ]);
  }
}

/// Превью стилей визуализации — эквивалент CSS-градиентов из прототипа.
class _VizPreview extends StatelessWidget {
  const _VizPreview({required this.style});
  final String style;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final a = t.accent;
    final p = t.palette;

    Decoration d;
    switch (style) {
      case 'Сфера':
        d = BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: RadialGradient(center: const Alignment(-0.16, -0.28),
              colors: [a.a1, a.a2, a.a3], stops: const [0, 0.6, 1]),
        );
      case 'Волны':
        d = BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: RadialGradient(center: const Alignment(0, 1.6), radius: 1.2,
              colors: [a.a1, a.a1.withOpacity(0)], stops: const [0, 0.68]),
        );
      case 'Siri Orb':
        d = BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: SweepGradient(colors: [a.a1, a.a2, a.a3, a.a1]),
        );
      case 'Нет':
        d = BoxDecoration(borderRadius: BorderRadius.circular(11), color: p.chip);
      default:
        // Бары, Полоски, Волны 3D, Поле частиц — полосы разной частоты.
        final gap = style == 'Бары' ? 10.0 : style == 'Полоски' ? 7.0 : 12.0;
        final w = style == 'Бары' ? 4.0 : style == 'Полоски' ? 2.0 : 3.0;
        return ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: CustomPaint(size: Size.infinite, painter: _StripePainter(
              color: style == 'Полоски' ? a.a1 : a.a2, gap: gap, width: w,
              angle: style == 'Волны 3D' ? 118 : 90)),
        );
    }
    return DecoratedBox(decoration: d);
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter({required this.color, required this.gap, required this.width, required this.angle});
  final Color color;
  final double gap, width, angle;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = width;
    if (angle == 90) {
      for (var x = 0.0; x < size.width; x += gap) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
    } else {
      for (var x = -size.height; x < size.width + size.height; x += gap) {
        canvas.drawLine(Offset(x, 0), Offset(x + size.height * 0.53, size.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}
