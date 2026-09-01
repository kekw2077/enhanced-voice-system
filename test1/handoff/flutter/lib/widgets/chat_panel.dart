import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../models/evs_models.dart';
import 'glass_panel.dart';

/// Правая колонка Центра: шапка чата с меню, лента сообщений, поле ввода.
/// Тот же виджет пригодится на экране «Диалог» — там он просто шире.
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.title,
    required this.meta,
    required this.messages,
    required this.typing,
    required this.contextPercent,
    required this.chatEnabled,
    required this.onSend,
    required this.onToggleChat,
    required this.onClear,
    required this.onDelete,
    required this.onTogglePin,
    required this.pinned,
  });

  final String title, meta;
  final List<ChatMessage> messages;
  final bool typing, chatEnabled, pinned;
  final double contextPercent;
  final ValueChanged<String> onSend;
  final VoidCallback onToggleChat, onClear, onDelete, onTogglePin;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _menu = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _input.text.trim();
    if (t.isEmpty || !widget.chatEnabled) return;
    widget.onSend(t);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final empty = widget.messages.isEmpty && !widget.typing;

    return GlassPanel(
      radius: 26,
      padding: EdgeInsets.zero,
      shadow: true,
      child: Column(children: [
        _header(context),
        Expanded(
          child: empty
              ? _emptyState(context)
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(22),
                  children: [
                    for (var i = 0; i < widget.messages.length; i++) ...[
                      _Bubble(
                        message: widget.messages[i],
                        showActions: widget.messages[i].fromAssistant,
                      ),
                      const SizedBox(height: 15),
                    ],
                    if (widget.typing) const _TypingRow(),
                  ],
                ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 18), child: _composer(context)),
      ]),
    );
  }

  Widget _header(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 19, 22, 19),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.stroke))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title,
                overflow: TextOverflow.ellipsis,
                style: EvsType.label.copyWith(color: p.txt, fontSize: 15.5, fontWeight: FontWeight.w700, letterSpacing: -0.23)),
            const SizedBox(height: 3),
            Text(widget.meta, style: EvsType.numeric.copyWith(color: p.sub, fontSize: 11)),
          ]),
        ),
        const SizedBox(width: 14),
        _MenuButton(
          open: _menu,
          onTap: () => setState(() => _menu = !_menu),
          pinned: widget.pinned,
          onPin: () { setState(() => _menu = false); widget.onTogglePin(); },
          onClear: () { setState(() => _menu = false); widget.onClear(); },
          onDelete: () { setState(() => _menu = false); widget.onDelete(); },
        ),
      ]),
    );
  }

  Widget _emptyState(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              gradient: t.accent.badge,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: p.glowColor, blurRadius: 44)],
            ),
            alignment: Alignment.center,
            child: const Text('✦', style: TextStyle(color: Colors.white, fontSize: 18)),
          ),
          const SizedBox(height: 9),
          Text('Новый чат', style: EvsType.label.copyWith(color: p.txt, fontSize: 14.5)),
          const SizedBox(height: 4),
          SizedBox(
            width: 300,
            child: Text('Напишите запрос или скажите «Привет, EVS» — история начнётся с нуля.',
                textAlign: TextAlign.center,
                style: EvsType.caption.copyWith(color: p.sub, fontSize: 12.5, height: 1.5)),
          ),
        ]),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final on = widget.chatEnabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.fromLTRB(16, 8, 9, 8),
      decoration: BoxDecoration(
        color: on ? p.field : Colors.transparent,
        borderRadius: BorderRadius.circular(EvsRadius.field),
        border: Border.all(color: on ? p.stroke : const Color(0x57F5B944)),
      ),
      child: Row(children: [
        Expanded(
          child: Opacity(
            opacity: on ? 1 : 0.38,
            child: TextField(
              controller: _input,
              enabled: on,
              onSubmitted: (_) => _submit(),
              style: EvsType.bodyText.copyWith(color: p.txt),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: on ? 'Спросите что угодно' : 'Чат отключён — доступны только голосовые команды',
                hintStyle: EvsType.bodyText.copyWith(color: p.faint),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _RoundIcon(
          icon: on ? Icons.chat_bubble_outline : Icons.speaker_notes_off_outlined,
          tooltip: on ? 'Отключить чат' : 'Включить чат',
          onTap: widget.onToggleChat,
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Окно контекста заполнено на ${widget.contextPercent.round()}%',
          child: SizedBox(
            width: 34, height: 34,
            child: CustomPaint(
              painter: _ContextRing(
                percent: widget.contextPercent,
                track: p.chip,
                color: widget.contextPercent > 80 ? EvsPalette.warn : t.accent.a2,
              ),
              child: Center(
                child: Text('${widget.contextPercent.round()}',
                    style: EvsType.numeric.copyWith(color: p.sub, fontSize: 8.5)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Opacity(
          opacity: on ? 1 : 0.38,
          child: GestureDetector(
            onTap: on ? _submit : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                gradient: t.accent.sweep,
                borderRadius: BorderRadius.circular(EvsRadius.chip),
                boxShadow: [BoxShadow(color: const Color(0x579B72CB), offset: const Offset(0, 8), blurRadius: 22)],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.typing ? 'Стоп' : 'Отправить',
                    style: EvsType.label.copyWith(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(width: 7),
                Icon(widget.typing ? Icons.stop_rounded : Icons.arrow_upward_rounded, size: 15, color: Colors.white),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.showActions});
  final ChatMessage message;
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final ai = message.fromAssistant;

    final avatar = Container(
      width: 30, height: 30,
      decoration: BoxDecoration(
        gradient: ai ? LinearGradient(colors: [t.accent.a1, t.accent.a2]) : null,
        color: ai ? null : p.chip,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(ai ? '✦' : 'Я',
          style: EvsType.label.copyWith(color: ai ? Colors.white : p.sub, fontSize: 12, fontWeight: FontWeight.w700)),
    );

    final bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
        decoration: BoxDecoration(
          color: ai ? p.field : null,
          gradient: ai ? null : LinearGradient(colors: [t.accent.a1, t.accent.a2]),
          border: Border.all(color: ai ? p.stroke : Colors.transparent),
          borderRadius: ai
              ? const BorderRadius.only(
                  topLeft: Radius.circular(6), topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20))
              : const BorderRadius.only(
                  topLeft: Radius.circular(20), topRight: Radius.circular(6),
                  bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(message.text, style: EvsType.bodyText.copyWith(color: ai ? p.body : Colors.white, height: 1.55)),
          for (var i = 0; i < message.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 9),
                  child: Text('0${i + 1}', style: EvsType.numeric.copyWith(color: t.accent.a2, fontSize: 11)),
                ),
                Expanded(
                  child: Text(message.steps[i],
                      style: EvsType.bodyText.copyWith(color: ai ? p.body : Colors.white, fontSize: 13.5, height: 1.5)),
                ),
              ]),
            ),
        ]),
      ),
    );

    return Column(
      crossAxisAlignment: ai ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: ai
                ? [avatar, const SizedBox(width: 11), bubble]
                : [bubble, const SizedBox(width: 11), avatar],
          ),
        ),
        if (showActions)
          Padding(
            padding: const EdgeInsets.only(left: 41, top: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: const [
              _MiniAction(Icons.copy_rounded, 'Скопировать'),
              _MiniAction(Icons.volume_up_outlined, 'Озвучить'),
              _MiniAction(Icons.refresh_rounded, 'Переспросить'),
            ]),
          ),
      ],
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction(this.icon, this.tooltip);
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return Tooltip(
      message: tooltip,
      child: SizedBox(width: 28, height: 28, child: Icon(icon, size: 14, color: p.faint)),
    );
  }
}

class _TypingRow extends StatefulWidget {
  const _TypingRow();
  @override
  State<_TypingRow> createState() => _TypingRowState();
}

class _TypingRowState extends State<_TypingRow> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2300))..repeat();

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Row(children: [
      RotationTransition(
        turns: _c,
        child: Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2]),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Text('✦', style: TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ),
      const SizedBox(width: 11),
      AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final shift = _c.value * 2.2 - 1.1;
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment(-1.2 + shift * 2, 0),
              end: Alignment(1.2 + shift * 2, 0),
              colors: [p.faint, p.txt, t.accent.a2, p.faint],
              stops: const [0.18, 0.38, 0.52, 0.74],
            ).createShader(rect),
            child: Text('Думаю…',
                style: EvsType.label.copyWith(color: Colors.white, fontSize: 14)),
          );
        },
      ),
    ]);
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(width: 34, height: 34, child: Icon(icon, size: 16, color: p.sub)),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.open, required this.onTap, required this.pinned,
    required this.onPin, required this.onClear, required this.onDelete});

  final bool open, pinned;
  final VoidCallback onTap, onPin, onClear, onDelete;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return PopupMenuButton<String>(
      tooltip: 'Настройки чата',
      offset: const Offset(0, 42),
      color: p.solid,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.stroke2),
      ),
      constraints: const BoxConstraints(minWidth: 236, maxWidth: 236),
      onSelected: (v) => switch (v) {
        'pin' => onPin(),
        'clear' => onClear(),
        _ => onDelete(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          height: 30,
          child: Text('Текущий чат',
              style: EvsType.section.copyWith(color: p.faint, fontSize: 10)),
        ),
        PopupMenuItem(value: 'pin', child: _row(Icons.push_pin_outlined,
            pinned ? 'Открепить чат' : 'Закрепить чат', p.body)),
        PopupMenuItem(value: 'clear', child: _row(Icons.delete_outline, 'Очистить историю', p.body)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: _row(Icons.delete_forever_outlined, 'Удалить чат', EvsPalette.danger)),
      ],
      child: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: open ? p.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: open ? p.stroke2 : p.stroke),
        ),
        child: Icon(Icons.more_vert_rounded, size: 17, color: open ? p.txt : p.sub),
      ),
    );
  }

  Widget _row(IconData i, String t, Color c) => Row(children: [
        Icon(i, size: 16, color: c),
        const SizedBox(width: 10),
        Text(t, style: EvsType.bodyText.copyWith(color: c, fontSize: 13)),
      ]);
}

class _ContextRing extends CustomPainter {
  _ContextRing({required this.percent, required this.track, required this.color});
  final double percent;
  final Color track, color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    final base = Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = track;
    canvas.drawCircle(c, r, base);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
        2 * math.pi * (percent / 100), false, arc);
  }

  @override
  bool shouldRepaint(_ContextRing old) => old.percent != percent || old.color != color;
}
