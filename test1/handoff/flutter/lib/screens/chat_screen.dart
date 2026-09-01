import 'dart:async';
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../data/evs_data.dart';
import '../models/evs_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/controls.dart';
import '../widgets/anim_accent.dart';

/// Экран «Диалог». Слева лента во всю ширину с приветственным заголовком,
/// справа колонка 286px со списком чатов.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _reply;

  int _active = 1;
  final Set<int> _pinned = {1};
  final Set<int> _hidden = {};
  bool _typing = false;
  bool _chatEnabled = true;
  double _ctx = 38;

  final List<ChatMessage> _messages = [
    const ChatMessage(text: 'Как поднять локальную модель и связать её с моим Python-контроллером?', fromAssistant: false),
    const ChatMessage(text: 'Чтобы развернуть модель локально:', fromAssistant: true, steps: [
      'Поднимите llama.cpp или Ollama как backend-сервер.',
      'Сделайте Python-сервис, который проксирует запросы на localhost:11434.',
      'Отдавайте ответ потоком — озвучка начнётся, не дожидаясь конца.',
    ]),
    const ChatMessage(text: 'А озвучку можно на своём голосе?', fromAssistant: false),
    const ChatMessage(
      text: 'Да. Клон голоса живёт в разделе «Голос ассистента»: 30 секунд записи — '
          'и XTTS собирает профиль. Дальше он подставляется в любой ответ.',
      fromAssistant: true,
    ),
  ];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _reply?.cancel();
    super.dispose();
  }

  void _send() {
    final t = _input.text.trim();
    if (t.isEmpty || !_chatEnabled) return;
    setState(() {
      _messages.add(ChatMessage(text: t, fromAssistant: false));
      _typing = true;
      _input.clear();
    });
    _reply?.cancel();
    _reply = Timer(const Duration(milliseconds: 1900), () {
      if (!mounted) return;
      setState(() {
        _typing = false;
        _messages.add(const ChatMessage(
          text: 'Принято. Локальный стек отвечает: модель держит контекст, '
              'распознавание слушает, синтез готов озвучить ответ.',
          fromAssistant: true,
        ));
      });
    });
  }

  Future<void> _rename(ChatThread c) async {
    final ctrl = TextEditingController(text: c.title);
    final p = EvsTheme.of(context).palette;
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.solid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: p.stroke2),
        ),
        title: Text('Переименовать чат', style: EvsType.label.copyWith(color: p.txt, fontSize: 15)),
        content: SizedBox(width: 320, child: EvsField(controller: ctrl)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Отмена', style: EvsType.label.copyWith(color: p.sub, fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text('Сохранить', style: EvsType.label.copyWith(color: p.txt, fontSize: 13)),
          ),
        ],
      ),
    );
    if (next != null && next.isNotEmpty) setState(() => _renamed[c.id] = next);
  }

  final Map<int, String> _renamed = {};

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: _feed(context)),
        const SizedBox(width: 18),
        SizedBox(width: 286, child: _threads(context)),
      ]),
    );
  }

  Widget _feed(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return GlassPanel(
      radius: 26,
      padding: EdgeInsets.zero,
      shadow: true,
      child: Column(children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(26, 26, 26, 8),
            children: [
              FlowingGradientText('Чем могу помочь?',
                  style: EvsType.hero.copyWith(fontSize: 28, letterSpacing: -0.98)),
              const SizedBox(height: 6),
              SizedBox(
                width: 520,
                child: Text('Приватный ИИ для письма, планирования, кода и повседневных вопросов.',
                    style: EvsType.bodyText.copyWith(color: p.sub, fontSize: 13.5)),
              ),
              const SizedBox(height: 23),
              for (final m in _messages) ...[
                _MessageRow(message: m),
                const SizedBox(height: 15),
              ],
              if (_typing) _TypingHint(color: p.sub),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
          child: _chatEnabled ? _composer(context) : _disabledBar(context),
        ),
      ]),
    );
  }

  Widget _disabledBar(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.stroke2, style: BorderStyle.solid),
      ),
      child: Row(children: [
        Icon(Icons.lock_outline, size: 17, color: p.sub),
        const SizedBox(width: 12),
        Expanded(child: Text('Чат отключён — работают только голосовые команды',
            style: EvsType.bodyText.copyWith(color: p.sub, fontSize: 13))),
        GestureDetector(
          onTap: () => setState(() => _chatEnabled = true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            decoration: BoxDecoration(color: p.btn, borderRadius: BorderRadius.circular(EvsRadius.chip)),
            child: Text('Включить чат',
                style: EvsType.label.copyWith(color: p.btnText, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _composer(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 9, 8),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(EvsRadius.field),
        border: Border.all(color: p.stroke),
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _input,
            onSubmitted: (_) => _send(),
            style: EvsType.bodyText.copyWith(color: p.txt),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Спросите что угодно',
              hintStyle: EvsType.bodyText.copyWith(color: p.faint),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('${_ctx.round()}', style: EvsType.numeric.copyWith(color: p.sub, fontSize: 8.5)),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () => setState(() => _chatEnabled = false),
          child: SizedBox(width: 34, height: 34, child: Icon(Icons.chat_bubble_outline, size: 16, color: p.sub)),
        ),
        const SizedBox(width: 4),
        GradientButton(label: _typing ? 'Стоп' : 'Отправить', icon: _typing ? Icons.stop_rounded : Icons.arrow_upward_rounded, onTap: _send),
      ]),
    );
  }

  Widget _threads(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final live = chatThreads.where((c) => !_hidden.contains(c.id)).toList();
    final groups = <String, List<ChatThread>>{
      'Закреплено': live.where((c) => _pinned.contains(c.id)).toList(),
      'Сегодня': live.where((c) => !_pinned.contains(c.id) && !c.yesterday).toList(),
      'Вчера': live.where((c) => !_pinned.contains(c.id) && c.yesterday).toList(),
    };

    return GlassPanel(
      radius: 26,
      padding: const EdgeInsets.all(20),
      shadow: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SectionLabel('Диалоги'),
          const Spacer(),
          Text('${live.length}', style: EvsType.numeric.copyWith(color: p.faint, fontSize: 11)),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: ListView(children: [
            for (final g in groups.entries)
              if (g.value.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 8, 2, 2),
                  child: SectionLabel(g.key, size: 10.5),
                ),
                for (final c in g.value) _threadTile(context, c),
              ],
          ]),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.field,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.stroke),
          ),
          alignment: Alignment.center,
          child: Text('Архив чатов', style: EvsType.label.copyWith(color: p.sub, fontSize: 12.5)),
        ),
      ]),
    );
  }

  Widget _threadTile(BuildContext context, ChatThread c) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final on = c.id == _active;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: () => setState(() => _active = c.id),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: EvsMotion.hover,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              gradient: on
                  ? LinearGradient(colors: [p.accentSoft, Colors.transparent],
                      begin: Alignment.centerLeft, end: Alignment.centerRight)
                  : null,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: on ? p.stroke : Colors.transparent),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_renamed[c.id] ?? c.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: EvsType.label.copyWith(color: on ? p.txt : p.body, fontSize: 13)),
                  const SizedBox(height: 3),
                  Text(c.meta, style: EvsType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
                ]),
              ),
              _ThreadMenu(
                pinned: _pinned.contains(c.id),
                onPin: () => setState(() =>
                    _pinned.contains(c.id) ? _pinned.remove(c.id) : _pinned.add(c.id)),
                onRename: () => _rename(c),
                onClear: () => setState(() => _messages.clear()),
                onDelete: () => setState(() {
                  _hidden.add(c.id);
                  _pinned.remove(c.id);
                  if (_active == c.id) {
                    final left = chatThreads.where((x) => !_hidden.contains(x.id));
                    _active = left.isEmpty ? -1 : left.first.id;
                    _messages.clear();
                  }
                }),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});
  final ChatMessage message;

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
              ? const BorderRadius.only(topLeft: Radius.circular(6), topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20))
              : const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(6),
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
                Expanded(child: Text(message.steps[i],
                    style: EvsType.bodyText.copyWith(color: ai ? p.body : Colors.white, fontSize: 13.5, height: 1.5))),
              ]),
            ),
        ]),
      ),
    );

    return Column(
      crossAxisAlignment: ai ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.55),
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
              children: ai ? [avatar, const SizedBox(width: 11), bubble] : [bubble, const SizedBox(width: 11), avatar]),
        ),
        if (ai)
          Padding(
            padding: const EdgeInsets.only(left: 41, top: 7),
            child: Wrap(spacing: 4, children: [
              for (final a in const [
                ['Копировать', 'copy'], ['Редактировать', 'edit'],
                ['Перегенерировать', 'refresh'], ['Продолжить', 'next'], ['Удалить', 'delete'],
              ])
                _TextAction(label: a[0]),
            ]),
          ),
      ],
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label});
  final String label;

  static const _icons = {
    'Копировать': Icons.copy_rounded,
    'Редактировать': Icons.edit_outlined,
    'Перегенерировать': Icons.refresh_rounded,
    'Продолжить': Icons.fast_forward_rounded,
    'Удалить': Icons.delete_outline,
  };

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_icons[label], size: 13, color: p.faint),
          const SizedBox(width: 6),
          Text(label, style: EvsType.caption.copyWith(color: p.faint, fontSize: 11.5, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

class _TypingHint extends StatelessWidget {
  const _TypingHint({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    return Row(children: [
      Container(
        width: 30, height: 30,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2]),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: const Text('✦', style: TextStyle(color: Colors.white, fontSize: 13)),
      ),
      const SizedBox(width: 11),
      Text('Думаю…', style: EvsType.label.copyWith(color: color, fontSize: 14)),
    ]);
  }
}

/// Меню «⋮» у чата в списке: закрепить, переименовать, очистить, удалить.
class _ThreadMenu extends StatelessWidget {
  const _ThreadMenu({required this.pinned, required this.onPin,
    required this.onRename, required this.onClear, required this.onDelete});

  final bool pinned;
  final VoidCallback onPin, onRename, onClear, onDelete;

  @override
  Widget build(BuildContext context) {
    final p = EvsTheme.of(context).palette;
    return PopupMenuButton<String>(
      tooltip: 'Действия с чатом',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 30),
      color: p.solid,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.stroke2),
      ),
      constraints: const BoxConstraints(minWidth: 224, maxWidth: 224),
      onSelected: (v) => switch (v) {
        'pin' => onPin(),
        'rename' => onRename(),
        'clear' => onClear(),
        _ => onDelete(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'pin', child: _row(context, Icons.push_pin_outlined,
            pinned ? 'Открепить' : 'Закрепить', p.body)),
        PopupMenuItem(value: 'rename', child: _row(context, Icons.edit_outlined, 'Переименовать', p.body)),
        PopupMenuItem(value: 'clear', child: _row(context, Icons.delete_outline, 'Очистить историю', p.body)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: _row(context, Icons.delete_forever_outlined, 'Удалить чат', EvsPalette.danger)),
      ],
      child: SizedBox(width: 24, height: 24, child: Icon(Icons.more_vert_rounded, size: 14, color: p.faint)),
    );
  }

  Widget _row(BuildContext context, IconData i, String t, Color c) => Row(children: [
        Icon(i, size: 16, color: c),
        const SizedBox(width: 10),
        Text(t, style: EvsType.bodyText.copyWith(color: c, fontSize: 13)),
      ]);
}
