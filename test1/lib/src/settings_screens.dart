part of '../main.dart';

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => _sheetSurface(
        context,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _sub(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const Spacer(),
                  Text(
                    app.t('settings'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close, color: _txt(context)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    app.t('settings'),
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    app.t('settingsDesc'),
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionLabel(app.t('sectionApp')),
                  _group([
                    _nav(
                      context,
                      Icons.inventory_2_outlined,
                      app.t('manageModelsItem'),
                      trailing: _badge('${app.models.length}'),
                      onTap: () => _openManageModels(context),
                    ),
                    _nav(
                      context,
                      Icons.download_for_offline_outlined,
                      app.t('localModelsItem'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LocalModelsScreen(),
                        ),
                      ),
                    ),
                    _nav(
                      context,
                      Icons.language,
                      app.t('language'),
                      trailing: Text(
                        app.lang == 'ru' ? app.t('russian') : app.t('english'),
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openLanguage(context),
                    ),
                    _nav(
                      context,
                      Icons.dns_outlined,
                      app.t('serverAddress'),
                      onTap: () => _openServerSettings(context),
                    ),
                    // The separate "Personalization" entry that used to open
                    // straight to the (now-hidden) "Личность" tab is removed
                    // for now — "Memory" below is the only remaining
                    // PersonalizationScreen entry point from Settings.
                    _nav(
                      context,
                      Icons.psychology_outlined,
                      app.t('memory'),
                      onTap: () => openPersonalization(context, initialTab: 0),
                    ),
                    _nav(
                      context,
                      Icons.text_fields,
                      app.t('fontSize'),
                      trailing: Text(
                        '${app.fontSize.toStringAsFixed(1)}x',
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openFontSizeDialog(context),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  _sectionLabel(app.t('sectionTheme')),
                  _group([
                    _nav(
                      context,
                      Icons.palette_outlined,
                      app.t('themeMode'),
                      trailing: Text(
                        app.t('themeDark'),
                        style: TextStyle(color: _sub(context)),
                      ),
                      onTap: () => _openThemeDialog(context),
                    ),
                    _switch(
                      context,
                      Icons.vibration,
                      app.t('haptics'),
                      app.haptics,
                      (v) => app.setHaptics(v),
                    ),
                    _switch(
                      context,
                      Icons.keyboard_alt_outlined,
                      app.t('showKeyboard'),
                      app.showKeyboardOnLaunch,
                      (v) => app.setShowKeyboard(v),
                    ),
                    _switch(
                      context,
                      Icons.auto_awesome,
                      app.t('showChips'),
                      app.showPromptChips,
                      (v) => app.setShowChips(v),
                    ),
                    _danger(context, app),
                  ]),
                  const SizedBox(height: 24),
                  _sectionLabel(app.t('sectionAbout')),
                  _group([
                    _updateRow(context, app),
                    _nav(
                      context,
                      Icons.info_outline,
                      app.t('aboutVersion'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AboutVersionScreen(),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 20),
                  Center(child: _versionFootnote(context)),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionFootnote(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox.shrink();
        return Text(
          'EVS v${info.version} (${info.buildNumber})',
          style: TextStyle(color: _sub(context), fontSize: 12),
        );
      },
    );
  }

  Widget _sectionLabel(String s) => Builder(
    builder: (context) => Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        s,
        style: TextStyle(
          color: _sub(context),
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  Widget _group(List<Widget> children) => Builder(
    builder: (context) {
      // Thin inset separators between rows (iOS grouped-list look), matching
      // the dividers in the chat row's context menu.
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i++) {
        rows.add(children[i]);
        if (i != children.length - 1) {
          rows.add(
            Divider(
              height: 1,
              thickness: 1,
              indent: 16,
              color: _sub(context).withValues(alpha: 0.12),
            ),
          );
        }
      }
      final column = Column(mainAxisSize: MainAxisSize.min, children: rows);
      return _isGlass(context)
          ? GlassSurface(
              borderRadius: BorderRadius.circular(20),
              child: Material(type: MaterialType.transparency, child: column),
            )
          : Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Material(
                color: _card(context).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                child: column,
              ),
            );
    },
  );

  Widget _badge(String s) => Container(
    padding: const EdgeInsets.all(8),
    decoration: const BoxDecoration(
      color: Colors.white24,
      shape: BoxShape.circle,
    ),
    child: Text(s, style: const TextStyle(color: Colors.white)),
  );

  Widget _updateRow(BuildContext context, AppState app) {
    String title = app.t('checkForUpdates');
    Widget? trailing;
    VoidCallback? onTap;

    if (app.updateDownloadProgress != null) {
      final p = app.updateDownloadProgress!;
      title = app.t('downloadingUpdate');
      trailing = Text(
        p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : '…',
        style: TextStyle(color: _sub(context)),
      );
    } else if (app.checkingForUpdate) {
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (app.updateAvailableVersion != null) {
      title = '${app.t('updateAvailable')} ${app.updateAvailableVersion}';
      trailing = const Icon(Icons.download, color: Colors.green);
      onTap = () => app.downloadAndInstallUpdate();
    } else {
      onTap = () async {
        await app.checkForUpdates();
        if (!context.mounted) return;
        final version = app.updateAvailableVersion;
        final error = app.updateCheckError;
        showDialog(
          context: context,
          builder: (dialogContext) => _AppDialog(
            title: Text(app.t('checkForUpdates')),
            content: Text(
              error ??
                  (version != null
                      ? '${app.t('updateAvailable')} $version'
                      : app.t('upToDate')),
            ),
            actions: version != null && error == null
                ? [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(app.t('later')),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        app.downloadAndInstallUpdate();
                      },
                      child: Text(app.t('downloadUpdateNow')),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(app.t('gotIt')),
                    ),
                  ],
          ),
        );
      };
    }

    return _nav(
      context,
      Icons.system_update_outlined,
      title,
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _nav(
    BuildContext c,
    IconData icon,
    String label, {
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: _txt(c)),
      title: Text(label, style: TextStyle(color: _txt(c), fontSize: 18)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) trailing,
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: _sub(c)),
        ],
      ),
    );
  }

  Widget _switch(
    BuildContext c,
    IconData icon,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    void handle(bool v) {
      c.read<AppState>().buzz();
      onChanged(v);
    }

    return ListTile(
      onTap: () => handle(!value),
      leading: Icon(icon, color: _txt(c)),
      title: Text(label, style: TextStyle(color: _txt(c), fontSize: 18)),
      trailing: _iosSwitch(c, value, handle),
    );
  }

  Widget _danger(BuildContext c, AppState app) {
    return ListTile(
      onTap: () => showDialog(
        context: c,
        builder: (_) => _AppDialog(
          backgroundColor: _card(c),
          title: Text(app.t('deleteHistory'), style: TextStyle(color: _txt(c))),
          content: Text(app.t('cantUndo'), style: TextStyle(color: _sub(c))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(app.t('cancel')),
            ),
            TextButton(
              onPressed: () {
                app.deleteAll();
                Navigator.pop(c);
              },
              child: Text(
                app.t('delete'),
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
      leading: const Icon(Icons.delete_outline, color: Colors.red),
      title: Text(
        app.t('deleteHistory'),
        style: const TextStyle(color: Colors.red, fontSize: 18),
      ),
    );
  }

  void _openFontSizeDialog(BuildContext context) {
    final app = context.read<AppState>();
    double tempSize = app.fontSize;
    showDialog(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(app.t('fontSize'), style: TextStyle(color: _txt(context))),
        content: StatefulBuilder(
          builder: (ctx, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${tempSize.toStringAsFixed(1)}x',
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackShape: const GradientSliderTrackShape(),
                  thumbColor: _accent(context),
                ),
                child: Slider(
                  value: tempSize,
                  min: 0.7,
                  max: 1.5,
                  divisions: 16,
                  label: '${tempSize.toStringAsFixed(1)}x',
                  onChanged: (v) => setDialogState(() => tempSize = v),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'A',
                    style: TextStyle(color: _sub(context), fontSize: 12),
                  ),
                  Text(
                    'A',
                    style: TextStyle(color: _sub(context), fontSize: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              app.setFontSize(tempSize);
              Navigator.pop(context);
            },
            child: Text(app.t('save')),
          ),
        ],
      ),
    );
  }

  void _openThemeDialog(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(app.t('themeMode'), style: TextStyle(color: _txt(context))),
        content: RadioGroup<AppThemeMode>(
          groupValue: app.themeMode,
          onChanged: (v) {
            if (v != null) {
              app.setThemeMode(v);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in [
                (AppThemeMode.dark, app.t('themeDark')),
                (AppThemeMode.claude, app.t('themeClaude')),
                (AppThemeMode.claudeDark, app.t('themeClaudeDark')),
              ])
                RadioListTile<AppThemeMode>(
                  value: entry.$1,
                  activeColor: _accent(context),
                  title: Text(entry.$2, style: TextStyle(color: _txt(context))),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openLanguage(BuildContext context) {
    final app = context.read<AppState>();
    showDialog(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('languageDialogTitle'),
          style: TextStyle(color: _txt(context)),
        ),
        content: RadioGroup<String>(
          groupValue: app.lang,
          onChanged: (v) {
            if (v != null) {
              app.setLang(v);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in [
                ['ru', app.t('russian')],
                ['en', app.t('english')],
              ])
                RadioListTile<String>(
                  value: l[0],
                  activeColor: _accent(context),
                  title: Text(l[1], style: TextStyle(color: _txt(context))),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openServerSettings(BuildContext context) {
    final app = context.read<AppState>();
    final urlCtrl = TextEditingController(text: app.serverUrl);
    final keyCtrl = TextEditingController(text: app.apiKey);
    showDialog(
      context: context,
      builder: (_) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('serverDialogTitle'),
          style: TextStyle(color: _txt(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              style: TextStyle(color: _txt(context)),
              decoration: InputDecoration(
                labelText: app.t('serverUrlLabel'),
                hintText: app.t('serverUrlHint'),
                hintStyle: TextStyle(color: _sub(context), fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyCtrl,
              style: TextStyle(color: _txt(context)),
              obscureText: true,
              decoration: InputDecoration(labelText: app.t('apiKeyOptional')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              app.setServer(urlCtrl.text.trim(), keyCtrl.text.trim());
              Navigator.pop(context);
            },
            child: Text(app.t('save')),
          ),
        ],
      ),
    );
  }

  void _openManageModels(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => Consumer<AppState>(
        builder: (ctx, app, child) => _AppDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  app.t('manageModelsItem'),
                  style: TextStyle(
                    color: _txt(ctx),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => app.fetchModels(),
                icon: Icon(Icons.refresh, color: _txt(ctx)),
                tooltip: app.t('refreshModels'),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (app.loadingModels)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(),
                ),
              ...app.models.map(
                (m) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    app.isLocalModel(m)
                        ? Icons.download_for_offline_outlined
                        : Icons.inventory_2_outlined,
                    color: _txt(ctx),
                  ),
                  title: Text(
                    app.modelDisplayName(m),
                    style: TextStyle(color: _txt(ctx)),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () {
                      final spec = app.localSpecFor(m);
                      if (spec != null) {
                        app.deleteLocalModel(spec);
                      } else {
                        app.removeModel(m);
                      }
                    },
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      style: TextStyle(color: _txt(ctx)),
                      decoration: InputDecoration(
                        hintText: app.t('addModelHint'),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.add, color: _txt(ctx)),
                    onPressed: () {
                      app.addModel(ctrl.text);
                      ctrl.clear();
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(app.t('done')),
            ),
          ],
        ),
      ),
    );
  }
}

/* ============================ ИСТОРИЯ ИЗМЕНЕНИЙ (ЭКРАН) ============================ */

class AboutVersionScreen extends StatelessWidget {
  const AboutVersionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: _bg(context),
      appBar: AppBar(
        backgroundColor: _bg(context),
        elevation: 0,
        foregroundColor: _txt(context),
        title: Text(
          app.t('aboutVersion'),
          style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final entry in kChangelog)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _card(context).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.version,
                    style: TextStyle(
                      color: _txt(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final change in entry.changes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ', style: TextStyle(color: _sub(context))),
                          Expanded(
                            child: Text(
                              change,
                              style: TextStyle(
                                color: _sub(context),
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/* ============================ ЛОКАЛЬНЫЕ МОДЕЛИ (ЭКРАН) ============================ */

class LocalModelsScreen extends StatelessWidget {
  const LocalModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: _bg(context),
      appBar: AppBar(
        backgroundColor: _bg(context),
        elevation: 0,
        foregroundColor: _txt(context),
        title: Text(
          app.t('localModelsTitle'),
          style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            app.t('localModelsDesc'),
            style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 20),
          for (final (i, tier) in LocalModelTier.values.indexed) ...[
            if (kLocalModels.any((m) => m.tier == tier)) ...[
              _tierHeader(
                context,
                app,
                tier,
                showDivider: LocalModelTier.values
                    .take(i)
                    .any((t) => kLocalModels.any((m) => m.tier == t)),
              ),
              for (final spec in kLocalModels.where((m) => m.tier == tier))
                _modelCard(context, app, spec),
            ],
          ],
        ],
      ),
    );
  }

  Widget _tierHeader(
    BuildContext context,
    AppState app,
    LocalModelTier tier, {
    required bool showDivider,
  }) {
    final (titleKey, descKey) = switch (tier) {
      LocalModelTier.light => ('tierLight', 'tierLightDesc'),
      LocalModelTier.mid => ('tierMid', 'tierMidDesc'),
      LocalModelTier.high => ('tierHigh', 'tierHighDesc'),
      LocalModelTier.roleplay => ('tierRoleplay', 'tierRoleplayDesc'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showDivider) ...[
            Divider(color: _sub(context).withValues(alpha: 0.25), height: 17),
          ],
          Text(
            app.t(titleKey),
            style: TextStyle(
              color: _txt(context),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            app.t(descKey),
            style: TextStyle(color: _sub(context), fontSize: 12),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _modelCard(BuildContext context, AppState app, LocalModelSpec spec) {
    final downloaded = app.downloadedLocalModelIds.contains(spec.id);
    final progress = app.localDownloadProgress[spec.id];
    final isSelected = app.selectedModel == spec.modelKey;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: _glassCard(
        context,
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
        children: [
          Icon(Icons.memory, color: _txt(context), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _txt(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                if (progress != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      minHeight: 4,
                    ),
                  )
                else
                  Text(
                    formatBytes(spec.sizeBytes),
                    style: TextStyle(color: _sub(context), fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (progress != null) ...[
            Text(
              '${(progress * 100).toStringAsFixed(0)}%',
              style: TextStyle(color: _sub(context), fontSize: 12),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: app.t('cancelDownload'),
              onPressed: () => app.cancelLocalModelDownload(spec.id),
              icon: const Icon(Icons.close, size: 18),
            ),
          ] else if (!downloaded) ...[
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: app.t('downloadModel'),
              onPressed: () => app.downloadLocalModel(spec),
              icon: const Icon(Icons.download),
            ),
          ] else ...[
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: isSelected ? app.t('modelInUse') : app.t('useModel'),
              onPressed: isSelected
                  ? null
                  : () {
                      app.selectModel(spec.modelKey);
                      Navigator.pop(context);
                    },
              icon: Icon(
                isSelected ? Icons.check_circle : Icons.play_arrow,
                color: isSelected ? Colors.green : null,
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: app.t('deleteModel'),
              onPressed: () => _confirmDelete(context, app, spec),
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 20,
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, AppState app, LocalModelSpec spec) {
    showDialog(
      context: context,
      builder: (ctx) => _AppDialog(
        title: Text(app.t('deleteLocalModelTitle')),
        content: Text(app.t('deleteLocalModelBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              app.deleteLocalModel(spec);
              Navigator.pop(ctx);
            },
            child: Text(
              app.t('deleteModel'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}

/* ============================ ЭКРАН ПЕРСОНАЛИЗАЦИИ ============================ */

class PersonalizationScreen extends StatefulWidget {
  final Conversation? conversation;
  final int initialTab;
  const PersonalizationScreen({
    super.key,
    this.conversation,
    this.initialTab = 0,
  });
  @override
  State<PersonalizationScreen> createState() => _PersonalizationScreenState();
}

class _PersonalizationScreenState extends State<PersonalizationScreen> {
  late Personalization p;
  late int _tab;
  late final TextEditingController _custom;
  late final TextEditingController _memory;
  late final TextEditingController _name;
  late final TextEditingController _pronouns;
  late final TextEditingController _profession;
  late final TextEditingController _interests;
  late final TextEditingController _goals;
  late final TextEditingController _location;
  late final TextEditingController _avoid;

  // Third "Roleplay" tab — only relevant/shown for a conversation with
  // rpModeEnabled, mirrors the same clone-while-editing pattern as `p`.
  late RPSessionConfig rp;
  late final TextEditingController _rpUserName;
  late final TextEditingController _rpUserDesc;
  late final TextEditingController _rpAiName;
  late final TextEditingController _rpSystemPrompt;
  late final TextEditingController _rpScenario;
  late final TextEditingController _rpStopSeq;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    p = (widget.conversation?.persona ?? app.persona).clone();
    _tab = widget.initialTab;
    _custom = TextEditingController(text: p.customPrompt);
    _memory = TextEditingController(text: p.memoryNote);
    _name = TextEditingController(text: p.name);
    _pronouns = TextEditingController(text: p.pronouns);
    _profession = TextEditingController(text: p.profession);
    _interests = TextEditingController(text: p.interests);
    _goals = TextEditingController(text: p.goals);
    _location = TextEditingController(text: p.location);
    _avoid = TextEditingController(text: p.avoidTopics);

    rp = (widget.conversation?.rpConfig ?? RPSessionConfig()).clone();
    _rpUserName = TextEditingController(text: rp.userCharacterName);
    _rpUserDesc = TextEditingController(text: rp.userCharacterDescription);
    _rpAiName = TextEditingController(text: rp.aiCharacterName);
    _rpSystemPrompt = TextEditingController(text: rp.systemPrompt);
    _rpScenario = TextEditingController(text: rp.scenario);
    _rpStopSeq = TextEditingController();
  }

  @override
  void dispose() {
    _custom.dispose();
    _memory.dispose();
    _name.dispose();
    _pronouns.dispose();
    _profession.dispose();
    _interests.dispose();
    _goals.dispose();
    _location.dispose();
    _avoid.dispose();
    _rpUserName.dispose();
    _rpUserDesc.dispose();
    _rpAiName.dispose();
    _rpSystemPrompt.dispose();
    _rpScenario.dispose();
    _rpStopSeq.dispose();
    super.dispose();
  }

  void _save() {
    p.customPrompt = _custom.text;
    p.memoryNote = _memory.text;
    p.name = _name.text;
    p.pronouns = _pronouns.text;
    p.profession = _profession.text;
    p.interests = _interests.text;
    p.goals = _goals.text;
    p.location = _location.text;
    p.avoidTopics = _avoid.text;
    final app = context.read<AppState>();
    if (widget.conversation != null) {
      app.saveConversationPersona(widget.conversation!, p);
    } else {
      app.savePersona(p);
    }
    if (widget.conversation != null) {
      rp.userCharacterName = _rpUserName.text;
      rp.userCharacterDescription = _rpUserDesc.text;
      rp.aiCharacterName = _rpAiName.text;
      rp.systemPrompt = _rpSystemPrompt.text;
      rp.scenario = _rpScenario.text;
      app.saveConversationRpConfig(widget.conversation!, rp);
    }
    Navigator.pop(context);
  }

  // The roleplay switch lives inside the tab itself now (no more header
  // button) -- toggling it mutates the live conv.rpModeEnabled/rpConfig
  // right away via AppState.toggleRpMode, so the locked-model snapshot it
  // may just have taken needs copying into our editing clone `rp` too,
  // otherwise _save() would overwrite it with `rp`'s stale defaults.
  void _toggleRp(bool _) {
    final conv = widget.conversation;
    if (conv == null) return;
    final app = context.read<AppState>();
    app.toggleRpMode(conv);
    setState(() {
      rp.lockedModel = conv.rpConfig?.lockedModel;
      rp.contextWindowLimit =
          conv.rpConfig?.contextWindowLimit ?? rp.contextWindowLimit;
    });
    showAppSnackBar(
      context,
      conv.rpModeEnabled ? app.t('rpModeOn') : app.t('rpModeOff'),
    );
  }

  String tr(String k) => context.read<AppState>().t(k);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final glass = _isGlass(context);
    // The "Личность" (_personalityTab) tab stays hidden; its body/state/_save
    // are intact for a one-line revert. "Ролевая игра" sits next to "Память"
    // whenever opened from a chat (the on/off switch lives inside the tab).
    final hasTabs = widget.conversation != null;
    final Widget tabsArea = glass
        // Liquid Glass: a floating-pill segmented control (see LiquidGlassTabs).
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: LiquidGlassTabs(
              selectedIndex: _tab,
              onChanged: (i) => setState(() => _tab = i),
              accent: _accent(context),
              tabs: [
                GlassTab(label: app.t('tabMemory'), icon: Icons.memory),
                GlassTab(
                  label: app.t('tabRoleplay'),
                  icon: Icons.badge_outlined,
                ),
              ],
            ),
          )
        // Standard: the underline tabs.
        : Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _topTab(
                      icon: Icons.psychology_outlined,
                      label: app.t('tabMemory'),
                      selected: _tab == 0,
                      onTap: () => setState(() => _tab = 0),
                    ),
                  ),
                  Expanded(
                    child: _topTab(
                      icon: Icons.badge_outlined,
                      label: app.t('tabRoleplay'),
                      selected: _tab == 1,
                      onTap: () => setState(() => _tab = 1),
                    ),
                  ),
                ],
              ),
              Container(
                height: 1,
                color: _sub(context).withValues(alpha: 0.15),
              ),
            ],
          );

    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        children: [
          if (hasTabs) tabsArea,
          Expanded(
            child: switch (_tab) {
              1 when hasTabs => _roleplayTab(app),
              _ => _memoryTab(app),
            },
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: _bg(context),
      // Glass mode draws an ambient colored backdrop behind a transparent app
      // bar so the glass tabs/cards have something to refract; standard mode
      // is the plain opaque screen.
      extendBodyBehindAppBar: glass,
      appBar: AppBar(
        backgroundColor: glass ? Colors.transparent : _bg(context),
        elevation: 0,
        foregroundColor: _txt(context),
        title: Text(
          widget.conversation != null ? app.t('chatPers') : app.t('pers'),
          style: TextStyle(color: _txt(context), fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              app.t('done'),
              style: TextStyle(
                color: _accent(context),
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      body: glass
          ? Stack(
              children: [
                const Positioned.fill(child: AmbientGlow()),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(top: kToolbarHeight),
                    child: content,
                  ),
                ),
              ],
            )
          : content,
    );
  }

  Widget _topTab({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? _accent(context) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: selected ? _accent(context) : _sub(context),
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: selected ? _txt(context) : _sub(context),
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Unreferenced while the "Личность" tab is hidden from build() above —
  // kept intact (not deleted) so it can come back with a one-line revert.
  // ignore: unused_element
  Widget _personalityTab(AppState app) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _heroHeader(app.t('tabPersonality'), app.t('persDesc')),

        _section(app.t('persPersona')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('persPreset'), desc: app.t('persPresetDesc')),
              _chipsSelect(
                options: const [
                  'preset_friend',
                  'preset_mentor',
                  'preset_expert',
                  'preset_creative',
                  'preset_custom',
                ],
                value: p.preset,
                onSelect: (v) => setState(() {
                  if (v == 'preset_custom') {
                    p.preset = v;
                  } else {
                    p.applyPreset(v);
                  }
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card2(
          child: Column(
            children: [
              _slider(
                app.t('sl_formality'),
                p.formality,
                (v) => setState(() {
                  p.formality = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_formalityDesc'),
              ),
              _slider(
                app.t('sl_empathy'),
                p.empathy,
                (v) => setState(() {
                  p.empathy = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_empathyDesc'),
              ),
              _slider(
                app.t('sl_verbosity'),
                p.verbosity,
                (v) => setState(() {
                  p.verbosity = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_verbosityDesc'),
              ),
              _slider(
                app.t('sl_humor'),
                p.humor,
                (v) => setState(() {
                  p.humor = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_humorDesc'),
              ),
              _slider(
                app.t('sl_creativity'),
                p.creativity,
                (v) => setState(() {
                  p.creativity = v;
                  p.preset = 'preset_custom';
                }),
                desc: app.t('sl_creativityDesc'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('emojiUsage'), desc: app.t('emojiUsageDesc')),
              _chipsSelect(
                options: const [
                  'emoji_never',
                  'emoji_sometimes',
                  'emoji_always',
                ],
                value: p.emoji,
                onSelect: (v) => setState(() => p.emoji = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('answerFormat'), desc: app.t('answerFormatDesc')),
              _chipsSelect(
                options: const ['fmt_plain', 'fmt_lists', 'fmt_tables'],
                value: p.answerFormat,
                onSelect: (v) => setState(() => p.answerFormat = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        _section(app.t('persBehavior')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('defaultLength'), desc: app.t('defaultLengthDesc')),
              _chipsSelect(
                options: const ['len_short', 'len_normal', 'len_long'],
                value: p.defaultLength,
                onSelect: (v) => setState(() => p.defaultLength = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('proactivity'), desc: app.t('proactivityDesc')),
              _chipsSelect(
                options: const ['pro_answer', 'pro_clarify', 'pro_suggest'],
                value: p.proactivity,
                onSelect: (v) => setState(() => p.proactivity = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card2(
          child: Column(
            children: [
              _iconSwitchRow(
                icon: Icons.notes_outlined,
                title: app.t('useMarkdown'),
                desc: app.t('useMarkdownDesc'),
                value: p.useMarkdown,
                onChanged: (v) => setState(() => p.useMarkdown = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        _section(app.t('persAdvanced')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('reasoning'), desc: app.t('reasoningDesc')),
              _chipsSelect(
                options: const ['rs_fast', 'rs_step'],
                value: p.reasoning,
                onSelect: (v) => setState(() => p.reasoning = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('toneTitle'), desc: app.t('toneTitleDesc')),
              _chipsSelect(
                options: const [
                  'tone_neutral',
                  'tone_sarcastic',
                  'tone_melancholic',
                  'tone_excited',
                ],
                value: p.tone,
                onSelect: (v) => setState(() => p.tone = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('customPrompt'), desc: app.t('customPromptDesc')),
              _field(_custom, app.t('customPromptHint'), maxLines: 4),
            ],
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _memoryTab(AppState app) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _heroHeader(app.t('tabMemory'), app.t('memoryDesc')),
        _section(app.t('memorySection')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconSwitchRow(
                icon: Icons.psychology_alt_outlined,
                title: app.t('longMemory'),
                desc: app.t('longMemoryDesc'),
                value: p.longMemory,
                onChanged: (v) => setState(() => p.longMemory = v),
              ),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 17),
              _iconSwitchRow(
                icon: Icons.auto_awesome_outlined,
                title: app.t('autoSaveMemories'),
                desc: app.t('autoSaveMemoriesDesc'),
                value: p.autoSaveMemories,
                onChanged: (v) => setState(() => p.autoSaveMemories = v),
              ),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 17),
              _iconSwitchRow(
                icon: Icons.help_outline,
                title: app.t('askBeforeRemembering'),
                desc: app.t('askBeforeRememberingDesc'),
                value: p.askBeforeRemembering,
                onChanged: (v) => setState(() => p.askBeforeRemembering = v),
              ),
              const SizedBox(height: 12),
              _field(_memory, app.t('memoryNote'), maxLines: 3),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 25),
              // RP chats get their own "Лимит контекста" control on the
              // Roleplay tab, which doubles as the local model's real
              // context allocation (see LocalLLMService._buildRequest) --
              // showing both here and there was the exact "two controls for
              // the same thing" confusion this note exists to resolve.
              widget.conversation?.rpModeEnabled == true
                  ? _infoCard(
                      icon: Icons.tune,
                      title: app.t('contextSize'),
                      desc: app.t('contextSizeMovedToRp'),
                    )
                  : _contextSizeControl(app),
              Divider(color: _sub(context).withValues(alpha: 0.25), height: 25),
              _destructiveActionRow(
                icon: Icons.delete_outline,
                title: app.t('deleteAllMemories'),
                desc: app.t('deleteAllMemoriesDesc'),
                onTap: () => _confirmDeleteAllMemories(context, app),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('savedMemoriesSection')),
        _card2(
          child: p.savedMemories.isEmpty
              ? Text(
                  app.t('noSavedMemories'),
                  style: TextStyle(color: _sub(context), fontSize: 14),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final mem in p.savedMemories)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                mem,
                                style: TextStyle(
                                  color: _txt(context),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              icon: const Icon(
                                Icons.close,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              onPressed: () =>
                                  setState(() => p.savedMemories.remove(mem)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        if (widget.conversation != null) ...[
          const SizedBox(height: 20),
          _section(app.t('pinnedMessagesSection')),
          _card2(
            child: widget.conversation!.pinnedMessageIds.isEmpty
                ? Text(
                    app.t('noPinnedMessages'),
                    style: TextStyle(color: _sub(context), fontSize: 14),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final msg in widget.conversation!.messages.where(
                        (m) => widget.conversation!.pinnedMessageIds.contains(
                          m.id,
                        ),
                      ))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  msg.content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _txt(context),
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                icon: Icon(
                                  Icons.push_pin,
                                  size: 18,
                                  color: _accent(context),
                                ),
                                onPressed: () => setState(() {
                                  app.toggleMessagePin(
                                    widget.conversation!,
                                    msg,
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
        const SizedBox(height: 20),
        _section(app.t('persProfile')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_name, app.t('name')),
              _field(_pronouns, app.t('pronouns')),
              _field(_profession, app.t('profession')),
              _field(_interests, app.t('interests')),
              _field(_goals, app.t('goals')),
              _field(_location, app.t('location')),
              const SizedBox(height: 8),
              _iconSwitchRow(
                icon: Icons.badge_outlined,
                title: app.t('useMyData'),
                desc: app.t('useMyDataDesc'),
                value: p.useMyData,
                onChanged: (v) => setState(() => p.useMyData = v),
              ),
              const SizedBox(height: 12),
              _label(app.t('knowledgeLevel')),
              _chipsSelect(
                options: const ['kl_beginner', 'kl_student', 'kl_expert'],
                value: p.knowledgeLevel,
                onSelect: (v) => setState(() => p.knowledgeLevel = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('persSafety')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_avoid, app.t('avoidTopics'), maxLines: 2),
              const SizedBox(height: 8),
              _label(app.t('contentFilter')),
              _chipsSelect(
                options: const ['cf_strict', 'cf_balanced', 'cf_off'],
                value: p.contentFilter,
                onSelect: (v) => setState(() => p.contentFilter = v),
              ),
              const SizedBox(height: 12),
              _iconSwitchRow(
                icon: Icons.warning_amber_outlined,
                title: app.t('warnUncertain'),
                desc: app.t('warnUncertainDesc'),
                value: p.warnUncertain,
                onChanged: (v) => setState(() => p.warnUncertain = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _infoCard(
          icon: Icons.lock_outline,
          title: app.t('localDataTitle'),
          desc: app.t('localDataDesc'),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _roleplayTab(AppState app) {
    final conv = widget.conversation;
    final rpOn = conv?.rpModeEnabled ?? false;
    final lockedModel = rp.lockedModel;
    final isLocal = lockedModel != null && app.isLocalModel(lockedModel);
    final localSpec = lockedModel != null ? app.localSpecFor(lockedModel) : null;
    // Capped by device RAM too (see AppState.ramContextCeiling) so the option
    // list drops sizes that would OOM-crash on this phone.
    final localMax = math.min(
      localSpec?.maxLocalContextSize ?? 8192,
      app.ramContextCeiling,
    );
    final contextOptions = isLocal
        ? const [
            2048,
            4096,
            8192,
            16384,
            32768,
          ].where((v) => v <= localMax).toList()
        : const [4096, 16384, 32768];
    final safeContextOptions = contextOptions.isEmpty
        ? [localMax]
        : contextOptions;
    final displayContextLimit = safeContextOptions.contains(rp.contextWindowLimit)
        ? rp.contextWindowLimit
        : safeContextOptions.last;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _heroHeader(app.t('tabRoleplay'), app.t('rpDesc')),
        _card2(
          child: _iconSwitchRow(
            icon: Icons.auto_awesome_outlined,
            title: app.t('rpMode'),
            desc: app.t('rpEnableDesc'),
            value: rpOn,
            onChanged: conv == null ? (_) {} : _toggleRp,
          ),
        ),
        const SizedBox(height: 20),
        if (lockedModel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: _infoCard(
              icon: Icons.lock_outline,
              title: app.t('rpModelLocked'),
              desc: app.modelDisplayName(lockedModel),
            ),
          ),
        _section(app.t('rpMyCharacter'), app.t('rpMyCharacterDesc')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_rpUserName, app.t('rpUserName')),
              const SizedBox(height: 12),
              _label(
                app.t('rpUserDescription'),
                desc: app.t('rpUserDescriptionDesc'),
              ),
              _field(_rpUserDesc, app.t('rpUserDescriptionHint'), maxLines: 4),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpAiRole'), app.t('rpAiRoleDesc')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(_rpAiName, app.t('rpAiName')),
              const SizedBox(height: 12),
              _label(app.t('systemPrompt'), desc: app.t('systemPromptDesc')),
              _field(_rpSystemPrompt, app.t('rpSystemPromptHint'), maxLines: 6),
              const SizedBox(height: 10),
              _infoCard(
                icon: Icons.info_outline,
                title: app.t('rpPlaceholderExampleTitle'),
                desc: app.t('rpPlaceholderExample'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpScenarioSection')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(app.t('scenario'), desc: app.t('scenarioDesc')),
              _field(_rpScenario, app.t('rpScenarioHint'), maxLines: 4),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpSampling')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sliderRange(
                app.t('rpTemperature'),
                rp.sampling.temperature,
                0.0,
                isLocal ? 1.5 : 2.0,
                (v) => setState(() => rp.sampling.temperature = v),
                format: (v) => v.toStringAsFixed(2),
                desc: app.t('rpTemperatureDesc'),
              ),
              _sliderRange(
                app.t('rpTopP'),
                rp.sampling.topP,
                0.0,
                1.0,
                (v) => setState(() => rp.sampling.topP = v),
                format: (v) => v.toStringAsFixed(2),
                desc: app.t('rpTopPDesc'),
              ),
              _sliderRange(
                app.t('rpRepetitionPenalty'),
                rp.sampling.repetitionPenalty,
                1.0,
                1.5,
                (v) => setState(() => rp.sampling.repetitionPenalty = v),
                format: (v) => v.toStringAsFixed(2),
                desc: app.t('rpRepetitionPenaltyDesc'),
              ),
              const SizedBox(height: 8),
              _label(app.t('rpMaxTokens'), desc: app.t('rpMaxTokensDesc')),
              _quickChips(
                const [150, 300, 600, 1000],
                rp.sampling.maxResponseTokens,
                (v) => setState(() => rp.sampling.maxResponseTokens = v),
                labelFor: (v) => switch (v) {
                  150 => app.t('rpPresetShort'),
                  300 => app.t('rpPresetMedium'),
                  600 => app.t('rpPresetLong'),
                  1000 => app.t('rpPresetEpic'),
                  _ => '$v',
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpLorebook')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconSwitchRow(
                icon: Icons.notes_outlined,
                title: app.t('rpLorebookEnable'),
                desc: app.t('rpLorebookDesc'),
                value: rp.isLorebookEnabled,
                onChanged: (v) => setState(() => rp.isLorebookEnabled = v),
              ),
              if (rp.isLorebookEnabled) ...[
                Divider(color: _sub(context).withValues(alpha: 0.25), height: 25),
                _lorebookEditor(app),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        _section(app.t('rpStopSequences'), app.t('rpStopSequencesDesc')),
        _card2(child: _stopSequenceInput(app)),
        const SizedBox(height: 20),
        _section(app.t('rpContextWindow'), app.t('rpContextWindowDesc')),
        _card2(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _quickChips(
                safeContextOptions,
                displayContextLimit,
                (v) => setState(() => rp.contextWindowLimit = v),
              ),
              if (isLocal && localSpec != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${app.t('contextSizeMaxFor')} ${localSpec.shortName}: $localMax',
                  style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _lorebookEditor(AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in rp.lorebook)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _bg(context).withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: entry.keywords,
                          style: TextStyle(color: _txt(context), fontSize: 13),
                          decoration: InputDecoration(
                            hintText: app.t('rpLorebookKeywords'),
                            hintStyle: TextStyle(
                              color: _sub(context),
                              fontSize: 13,
                            ),
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => entry.keywords = v,
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        icon: const Icon(
                          Icons.close,
                          size: 18,
                          color: Colors.redAccent,
                        ),
                        onPressed: () => setState(() => rp.lorebook.remove(entry)),
                      ),
                    ],
                  ),
                  TextFormField(
                    initialValue: entry.content,
                    maxLines: 3,
                    style: TextStyle(color: _txt(context), fontSize: 13),
                    decoration: InputDecoration(
                      hintText: app.t('rpLorebookContent'),
                      hintStyle: TextStyle(color: _sub(context), fontSize: 13),
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => entry.content = v,
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          onPressed: () => setState(() => rp.lorebook.add(LoreEntry())),
          icon: const Icon(Icons.add, size: 18),
          label: Text(app.t('rpLorebookAddEntry')),
        ),
      ],
    );
  }

  Widget _stopSequenceInput(AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rp.stopSequences.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final seq in rp.stopSequences)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _bg(context).withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _sub(context).withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          seq,
                          style: TextStyle(color: _txt(context), fontSize: 13),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () =>
                              setState(() => rp.stopSequences.remove(seq)),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: _sub(context),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        TextField(
          controller: _rpStopSeq,
          style: TextStyle(color: _txt(context), fontSize: 14),
          decoration: InputDecoration(
            hintText: app.t('rpStopSequenceHint'),
            hintStyle: TextStyle(color: _sub(context), fontSize: 14),
            isDense: true,
            filled: true,
            fillColor: _bg(context).withValues(alpha: 0.3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) {
            final trimmed = v.trim();
            if (trimmed.isEmpty) return;
            setState(() {
              rp.stopSequences.add(trimmed);
              _rpStopSeq.clear();
            });
          },
        ),
      ],
    );
  }

  Widget _sliderRange(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String Function(double)? format,
    String? desc,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: _txt(context), fontSize: 15),
                ),
              ),
              Text(
                format != null ? format(value) : value.toStringAsFixed(2),
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (desc != null) ...[
            const SizedBox(height: 2),
            Text(
              desc,
              style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
            ),
            const SizedBox(height: 4),
          ],
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackShape: const GradientSliderTrackShape(),
              thumbColor: _accent(context),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickChips(
    List<int> values,
    int current,
    ValueChanged<int> onSelect, {
    String Function(int)? labelFor,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          ChoiceChip(
            label: Text(labelFor != null ? labelFor(v) : '$v'),
            selected: current == v,
            labelStyle: TextStyle(
              color: current == v ? Colors.white : _txt(context),
              fontWeight: FontWeight.w500,
            ),
            selectedColor: _accent(context),
            backgroundColor: _bg(context).withValues(alpha: 0.4),
            side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
            onSelected: (_) => onSelect(v),
          ),
      ],
    );
  }

  Widget _heroHeader(String title, String desc) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: _txt(context),
            fontSize: 30,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          desc,
          style: TextStyle(color: _sub(context), fontSize: 15, height: 1.4),
        ),
      ],
    ),
  );

  Widget _destructiveActionRow({
    required IconData icon,
    required String title,
    required String desc,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.redAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      color: _sub(context),
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteAllMemories(BuildContext context, AppState app) {
    showDialog(
      context: context,
      builder: (dialogContext) => _AppDialog(
        backgroundColor: _card(context),
        title: Text(
          app.t('deleteAllMemories'),
          style: TextStyle(color: _txt(context)),
        ),
        content: Text(
          app.t('deleteAllMemoriesConfirm'),
          style: TextStyle(color: _sub(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(app.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              setState(() => p.savedMemories.clear());
              Navigator.pop(dialogContext);
            },
            child: Text(
              app.t('delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconSwitchRow({
    required IconData icon,
    required String title,
    required String desc,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _sub(context), size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _iosSwitch(context, value, onChanged),
      ],
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return _glassCard(
      context,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _accent(context).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _accent(context), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _txt(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: TextStyle(
                    color: _sub(context),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _contextSizeControl(AppState app) {
    const step = 512;
    const minSize = 512;
    // Adaptive per-model ceiling instead of a flat 4096: an RP chat follows
    // its locked model, everything else follows whatever's selected
    // globally right now — same resolution LocalLLMService uses to build
    // the actual request, so the slider can never promise more context than
    // the model (and the fllama ×4 multiplier) can really deliver.
    final modelKey = widget.conversation != null
        ? _effectiveModelFor(app, widget.conversation!)
        : app.selectedModel;
    final spec = app.localSpecFor(modelKey);
    // Cap by the smaller of the model's native ceiling and the device-RAM-safe
    // ceiling, so the control can never offer a size that OOM-crashes.
    final maxSize = math.min(spec?.maxLocalContextSize ?? 4096, app.ramContextCeiling);
    final displaySize = p.localContextSize < minSize
        ? minSize
        : (p.localContextSize > maxSize ? maxSize : p.localContextSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('contextSize'),
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$displaySize',
              style: TextStyle(
                color: _sub(context),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _stepBtn(
              Icons.remove,
              displaySize > minSize
                  ? () => setState(() => p.localContextSize = displaySize - step)
                  : null,
            ),
            const SizedBox(width: 10),
            _stepBtn(
              Icons.add,
              displaySize < maxSize
                  ? () => setState(() => p.localContextSize = displaySize + step)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tr('contextSizeDesc'),
          style: TextStyle(color: _sub(context), fontSize: 13, height: 1.3),
        ),
        if (spec != null) ...[
          const SizedBox(height: 4),
          Text(
            '${app.t('contextSizeMaxFor')} ${spec.shortName}: $maxSize',
            style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
          ),
          // Surface the device-RAM ceiling only when it's the binding limit,
          // so the user understands why the max is lower than the model's
          // native context window.
          if (app.ramContextCeiling < spec.maxLocalContextSize) ...[
            const SizedBox(height: 2),
            Text(
              '${app.t('contextSizeMaxForDevice')}: ${app.ramContextCeiling}',
              style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
            ),
          ],
        ],
      ],
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _bg(context).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _sub(context).withValues(alpha: 0.2)),
        ),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null
              ? _sub(context).withValues(alpha: 0.4)
              : _txt(context),
        ),
      ),
    );
  }

  Widget _section(String s, [String? desc]) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s,
          style: TextStyle(
            color: _txt(context),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (desc != null) ...[
          const SizedBox(height: 4),
          Text(
            desc,
            style: TextStyle(color: _sub(context), fontSize: 13, height: 1.3),
          ),
        ],
      ],
    ),
  );

  Widget _card2({required Widget child}) => _isGlass(context)
      ? GlassSurface(
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.all(16),
          child: child,
        )
      : Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _card(context).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(18),
          ),
          child: child,
        );

  Widget _label(String s, {String? desc}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s,
          style: TextStyle(
            color: _sub(context),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (desc != null) ...[
          const SizedBox(height: 2),
          Text(
            desc,
            style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
          ),
        ],
      ],
    ),
  );

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    String? desc,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: _txt(context), fontSize: 15)),
        if (desc != null) ...[
          const SizedBox(height: 2),
          Text(
            desc,
            style: TextStyle(color: _sub(context), fontSize: 12, height: 1.3),
          ),
        ],
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackShape: const GradientSliderTrackShape(),
            thumbColor: _accent(context),
          ),
          child: Slider(value: value, onChanged: onChanged),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String hint, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        style: TextStyle(color: _txt(context)),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: _sub(context)),
          filled: true,
          fillColor: _bg(context).withValues(alpha: 0.4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
          ),
        ),
      ),
    );
  }

  Widget _chipsSelect({
    required List<String> options,
    required String value,
    required ValueChanged<String> onSelect,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          ChoiceChip(
            label: Text(tr(o)),
            selected: value == o,
            labelStyle: TextStyle(
              color: value == o ? Colors.white : _txt(context),
              fontWeight: FontWeight.w500,
            ),
            selectedColor: _accent(context),
            backgroundColor: _bg(context).withValues(alpha: 0.4),
            side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
            onSelected: (_) => onSelect(o),
          ),
      ],
    );
  }
}
