part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — экран «Команды»
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/flutter/lib/screens/commands_screen.dart):
   каталог карточками-строками и панель медиа-шорткатов под ним.

   Данные и действия — настоящие, те же, что у вкладки команд в «Ноктюрне»:
     список      → app.voiceCommands
     добавить    → _AddCommandWizard
     править     → тот же мастер с initial
     запустить   → CommandExecutor.instance.execute
     удалить     → app.removeVoiceCommand
     подсказать  → _SuggestCommandsDialog

   Тумблер в строке — настоящий: у VoiceCommand есть поле `enabled`, и
   выключенную команду сопоставитель фраз пропускает целиком
   (`_matchCommand` в sidecar_client.dart). Выключенная строка гаснет, но
   остаётся: выключить на время и потерять настройку — разные вещи.

   Рядом с тумблером оставлено меню «…» с остальными действиями — запустить,
   править, удалить. В макете его нет, но и удалять команду там нечем.
   ========================================================================== */

class _PrismCommands extends StatefulWidget {
  const _PrismCommands();
  @override
  State<_PrismCommands> createState() => _PrismCommandsState();
}

class _PrismCommandsState extends State<_PrismCommands> {
  final _search = TextEditingController();
  VoiceCommandType? _filter;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add(AppState app) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app),
    );
    if (cmd != null) app.addVoiceCommand(cmd);
  }

  Future<void> _edit(AppState app, VoiceCommand c) async {
    final cmd = await showDialog<VoiceCommand>(
      context: context,
      builder: (_) => _AddCommandWizard(app: app, initial: c),
    );
    if (cmd != null) app.replaceVoiceCommand(c, cmd);
  }

  Future<void> _suggest(AppState app) async {
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _SuggestCommandsDialog(app),
    );
    if (n != null && n > 0 && mounted) {
      showAppSnackBar(context, app.t('cmdSuggestSaved').replaceAll('{n}', '$n'));
    }
  }

  Future<void> _rowMenu(AppState app, VoiceCommand c, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      color: _card(context),
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(value: 'edit', child: Text(app.t('ncEdit'))),
        PopupMenuItem(value: 'run', child: Text(app.t('run'))),
        PopupMenuItem(
          value: 'delete',
          child: Text(app.t('delete'),
              style: TextStyle(color: _danger(context))),
        ),
      ],
    );
    if (!mounted) return;
    if (v == 'edit') await _edit(app, c);
    if (v == 'delete') app.removeVoiceCommand(c);
    if (v == 'run') {
      final ok = await CommandExecutor.instance.execute(c);
      if (mounted) {
        showAppSnackBar(context, ok ? app.t('cmdRunOk') : app.t('cmdRunFail'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final q = _search.text.trim().toLowerCase();
    // Медиа-команды вынесены в свою панель, как в макете, поэтому из общего
    // каталога их убираем: одна и та же строка в двух списках сразу заставляет
    // гадать, какая из них настоящая.
    final all = app.voiceCommands
        .where((c) => _filter == null || c.type == _filter)
        .where((c) =>
            q.isEmpty ||
            c.phrase.toLowerCase().contains(q) ||
            c.value.toLowerCase().contains(q))
        .toList();
    final media =
        all.where((c) => c.type == VoiceCommandType.media).toList();
    final rest =
        all.where((c) => c.type != VoiceCommandType.media).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _catalogue(context, app, rest),
          if (media.isNotEmpty) ...[
            const SizedBox(height: 16),
            _media(context, app, media),
          ],
          const SizedBox(height: 16),
          _links(context, app),
        ],
      ),
    );
  }

  Widget _catalogue(
      BuildContext context, AppState app, List<VoiceCommand> items) {
    return PrismPanel(
      radius: 26,
      padding: const EdgeInsets.all(22),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(app.t('pgCmdCatalog'),
                        style: PrismType.label.copyWith(
                            color: _txt(context),
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(app.t('prismCatalogSub'),
                        style: PrismType.caption
                            .copyWith(color: _sub(context), fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              _PrismGhostButton(
                d: PrismIcons.spark,
                label: app.t('cmdSuggest'),
                onTap: () => unawaited(_suggest(app)),
              ),
              const SizedBox(width: 10),
              PrismGradientButton(
                label: app.t('cmdAdd'),
                icon: Icons.add_rounded,
                fontSize: 12.5,
                padding:
                    const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
                onTap: () => unawaited(_add(app)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 240,
                child: PrismField(
                  controller: _search,
                  hint: app.t('ncSearch'),
                  onSubmitted: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _tag(context, app.t('ncAll'), null),
                    for (final t in VoiceCommandType.values)
                      _tag(context, _prismTypeLabel(app, t), t),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Text(
                app.t('cmdEmpty'),
                textAlign: TextAlign.center,
                style: PrismType.body.copyWith(color: _faint(context)),
              ),
            )
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _PrismCommandRow(
                command: items[i],
                onMenu: (at) => unawaited(_rowMenu(app, items[i], at)),
                onEdit: () => unawaited(_edit(app, items[i])),
              ),
            ],
        ],
      ),
    );
  }

  Widget _tag(BuildContext context, String label, VoiceCommandType? t) {
    final on = _filter == t;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _filter = t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: on ? _prismAccentSoft(context) : _prismField(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: on ? _ramp(context).a2 : _stroke(context)),
          ),
          child: Text(label,
              style: PrismType.label.copyWith(
                  fontSize: 12,
                  color: on ? _txt(context) : _sub(context))),
        ),
      ),
    );
  }

  Widget _media(
      BuildContext context, AppState app, List<VoiceCommand> items) {
    return PrismPanel(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrismSectionLabel(app.t('prismMediaShortcuts')),
          const SizedBox(height: 18),
          Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              for (final c in items)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: _prismField(context),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _stroke(context)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(c.value,
                          style: PrismType.numeric.copyWith(
                              color: _ramp(context).a2, fontSize: 11.5)),
                      const SizedBox(width: 9),
                      Text(c.phrase,
                          style: PrismType.body.copyWith(
                              color: _body(context), fontSize: 12.5)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Две оставшиеся вкладки макета («Выполнение» и «Безопасность») — это
  /// страницы настроек, а не отдельные экраны. Ведём прямо туда, а не заводим
  /// им третью копию тех же переключателей.
  Widget _links(BuildContext context, AppState app) {
    void open(String page) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DesktopSettings(initialPage: page)),
        );
    return Row(
      children: [
        _PrismGhostButton(
          d: PrismIcons.play,
          label: app.t('pgCmdExec'),
          onTap: () => open(_Pages.cmdExec),
        ),
        const SizedBox(width: 10),
        _PrismGhostButton(
          d: PrismIcons.lock,
          label: app.t('pgCmdSecurity'),
          onTap: () => open(_Pages.cmdSecurity),
        ),
      ],
    );
  }
}

/// Подпись типа команды. Те же слова, что в настройках и в «Ноктюрне».
String _prismTypeLabel(AppState app, VoiceCommandType t) => switch (t) {
      VoiceCommandType.app => app.t('typeApp'),
      VoiceCommandType.file => app.t('typeFile'),
      VoiceCommandType.url => app.t('typeWeb'),
      VoiceCommandType.shell => 'Shell',
      VoiceCommandType.system => app.t('typeSystem'),
      VoiceCommandType.media => app.t('typeMedia'),
      VoiceCommandType.appVolume => app.t('typeAppVolume'),
    };

/// Цвет типа — тот же слот, что у значка типа в настройках: приложение красится
/// акцентом, сайт — успехом, системное — опасностью.
Color _prismTypeColor(BuildContext c, VoiceCommandType t) => switch (t) {
      VoiceCommandType.app => _accent(c),
      VoiceCommandType.file => _info(c),
      VoiceCommandType.url => _success(c),
      VoiceCommandType.shell => _warn(c),
      VoiceCommandType.system => _danger(c),
      VoiceCommandType.media => _warn(c),
      VoiceCommandType.appVolume => _info(c),
    };

/// Строка каталога: фраза · действие · цель. Под курсором левый край
/// подсвечивается акцентом — в макете этим отмечена включённая команда, здесь
/// это отклик на наведение, потому что выключенных команд не бывает.
class _PrismCommandRow extends StatefulWidget {
  const _PrismCommandRow({
    required this.command,
    required this.onMenu,
    required this.onEdit,
  });
  final VoiceCommand command;
  final ValueChanged<Offset> onMenu;
  final VoidCallback onEdit;

  @override
  State<_PrismCommandRow> createState() => _PrismCommandRowState();
}

class _PrismCommandRowState extends State<_PrismCommandRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final c = widget.command;
    final r = _ramp(context);
    final typeColor = _prismTypeColor(context, c.type);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onEdit,
        onSecondaryTapDown: (e) => widget.onMenu(e.globalPosition),
        // Рамка ОДИНАКОВОЙ толщины по всем сторонам, а акцентный край — отдельной
        // полоской внутри. В макете у строки левая сторона 3px при остальных 1px
        // и скругление 20; Flutter такую пару не рисует — скругление разрешено
        // только для равномерной рамки, — и вся строка молча исчезала под
        // курсором: заливка была, содержимого не было.
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: c.enabled ? 1 : 0.45,
          child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding:
                    const EdgeInsets.fromLTRB(21, 15, 18, 15),
                decoration: BoxDecoration(
                  gradient: _hover
                      ? LinearGradient(
                          colors: [
                            r.a2.withValues(alpha: 0.18),
                            Colors.transparent,
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: const [0, 0.88],
                        )
                      : null,
                  color: _hover ? null : _prismField(context),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _stroke(context)),
                ),
                child: Row(
            children: [
              SizedBox(
                width: 210,
                child: _cell(context, app.t('prismCellPhrase'), '«${c.phrase}»',
                    bold: true),
              ),
              const SizedBox(width: 18),
              SizedBox(
                width: 150,
                child: _cell(context, app.t('prismCellAction'),
                    _prismTypeLabel(app, c.type),
                    color: typeColor),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: _cell(context, app.t('prismCellTarget'),
                    c.value.isEmpty ? '—' : c.value,
                    mono: true),
              ),
              const SizedBox(width: 18),
              Builder(
                builder: (btnCtx) => PrismRoundIcon(
                  icon: Icons.more_horiz_rounded,
                  tooltip: app.t('evsMore'),
                  onTap: () {
                    final box = btnCtx.findRenderObject() as RenderBox?;
                    widget.onMenu(box == null
                        ? Offset.zero
                        : box.localToGlobal(
                            box.size.bottomLeft(Offset.zero)));
                  },
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: c.enabled
                    ? app.t('prismCmdOn')
                    : app.t('prismCmdOff'),
                child: PrismToggle(
                  value: c.enabled,
                  onChanged: (v) => app.setVoiceCommandEnabled(c, v),
                ),
              ),
            ],
                ),
              ),
              // Акцентный край. Отдельным слоем поверх — так он не спорит со
              // скруглением рамки и появляется плавно вместе с наведением.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: _hover ? 3 : 0,
                  color: r.a2,
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    String label,
    String value, {
    bool bold = false,
    bool mono = false,
    Color? color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(),
            style: PrismType.section
                .copyWith(color: _faint(context), fontSize: 10)),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (mono ? PrismType.numeric : PrismType.body).copyWith(
            color: color ?? (bold ? _txt(context) : _body(context)),
            fontSize: bold ? 14 : 13,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
