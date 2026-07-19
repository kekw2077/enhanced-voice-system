part of '../main.dart';

class ChatScreen extends StatefulWidget {
  // When true, the screen is embedded inside the desktop shell (DesktopHome):
  // it drops its own drawer (the desktop sidebar replaces it) and renders the
  // desktop top bar instead of the mobile one. The composer, message list and
  // empty/hero state are reused unchanged.
  final bool desktop;
  const ChatScreen({super.key, this.desktop = false});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  bool _sending = false;
  final List<String> _pendingAttachments = [];
  // id of the assistant message currently being edited inline (its bubble
  // shows a text field instead of the text), plus its editing controller.
  String? _editingMessageId;
  final _editController = TextEditingController();

  // Desktop sidecar voice input (Whisper STT via the Python sidecar).
  bool _scListening = false;
  StreamSubscription<String>? _scPartialSub;
  StreamSubscription<String>? _scFinalSub;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    if (widget.desktop) {
      _scPartialSub = SidecarClient.instance.partial.listen((t) {
        if (mounted && _scListening) _controller.text = t;
      });
      _scFinalSub = SidecarClient.instance.finalText.listen(_onVoiceFinal);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final app = context.read<AppState>();
      // Warn once if the last run crashed loading a local model (we've since
      // switched away from it so the app could start).
      if (app.lastModelCrash != null) {
        final name = app.modelDisplayName(app.lastModelCrash!, withSuffix: false);
        app.lastModelCrash = null;
        showAppSnackBar(context, '${app.t('modelCrashWarn')} $name');
      }
      // Preload the current chat's local model so the "preparing model"
      // screen shows on open (no-op for remote / already-warmed models).
      unawaited(app.warmUpModelFor(app.current));
      if (app.showKeyboardOnLaunch) {
        _inputFocus.requestFocus();
      }
      // First-run: offer the AI command-suggestion wizard (Ф1 §1.4). Awaited so
      // it doesn't stack on top of the "what's new" dialog below.
      await _maybeOfferCommandOnboarding(app);
      if (!mounted) return;
      final entry = await app.consumeWhatsNew();
      if (!mounted || entry == null) return;
      showDialog(
        context: context,
        builder: (dialogContext) => _AppDialog(
          title: Text('${app.t('whatsNewTitle')} ${entry.version}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final change in entry.changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('•  $change'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(app.t('gotIt')),
            ),
          ],
        ),
      );
    });
  }

  // First-launch onboarding for the AI command wizard (Ф1 §1.4). Offers once,
  // on Windows only, when no app-launch commands exist yet. Accepting opens the
  // existing suggestion wizard; either choice marks the offer as seen so it
  // never reappears (the wizard stays reachable from the commands screen).
  Future<void> _maybeOfferCommandOnboarding(AppState app) async {
    if (!app.shouldOfferCommandOnboarding) return;
    app.markCommandOnboardingSeen();
    final accept = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: Text(app.t('cmdOnboardTitle')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(app.t('cmdOnboardBody')),
            const SizedBox(height: 12),
            Text(
              app.t('cmdSuggestPrivacy'),
              style: TextStyle(fontSize: 12, color: _faint(context)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(app.t('later')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(app.t('cmdOnboardYes')),
          ),
        ],
      ),
    );
    if (accept != true || !mounted) return;
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _SuggestCommandsDialog(app),
    );
    if (n != null && n > 0 && mounted) {
      showAppSnackBar(
          context, app.t('cmdSuggestSaved').replaceAll('{n}', '$n'));
    }
  }

  @override
  void dispose() {
    _scPartialSub?.cancel();
    _scFinalSub?.cancel();
    if (_scListening) SidecarClient.instance.sttStop();
    _controller.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  // Desktop voice button: use the sidecar's Whisper STT when connected,
  // otherwise fall back to the existing speech_to_text VoiceScreen.
  // The input-bar mic button was removed (the mic already listens for commands
  // continuously), so this is currently unreferenced — kept so the VoiceScreen
  // dictation flow can be re-exposed without rebuilding it.
  // ignore: unused_element
  void _desktopVoice() {
    final sc = SidecarClient.instance;
    if (sc.status.value != SidecarStatus.connected || !sc.sttAvailable) {
      _openVoice();
      return;
    }
    final app = context.read<AppState>();
    if (_scListening) {
      sc.sttStop();
      setState(() => _scListening = false);
    } else {
      sc.sttStart(app.effectiveSttLanguage, prompt: app.sttBiasPrompt);
      setState(() => _scListening = true);
    }
  }

  // Final transcript from the sidecar: if it matches a voice command, run it
  // (with spoken feedback); otherwise drop it into the input and auto-send.
  void _onVoiceFinal(String text) {
    if (!mounted || !_scListening) return;
    final app = context.read<AppState>();
    SidecarClient.instance.sttStop();
    setState(() => _scListening = false);
    final t = text.trim();
    if (t.isEmpty) return;
    if (app.voiceCommands.isNotEmpty) {
      final cmd = CommandExecutor.instance.match(t, app.voiceCommands);
      if (cmd != null) {
        _controller.clear();
        if (cmd.type == VoiceCommandType.appVolume) {
          // Parametric: read the number from the spoken phrase `t`.
          app.applyAppVolume(cmd, t).then((r) {
            if (!mounted) return;
            if (SidecarClient.instance.ttsAvailable) {
              SidecarClient.instance.speak(r.$2);
            }
            showAppSnackBar(context, r.$2);
          });
          return;
        }
        CommandExecutor.instance.execute(cmd);
        if (SidecarClient.instance.ttsAvailable) {
          SidecarClient.instance.speak(app.t('cmdRunOk'));
        }
        showAppSnackBar(context, '${app.t('cmdRunOk')}: ${cmd.phrase}');
        return;
      }
    }
    _controller.text = t;
    if (app.micAutoSend) _send(t);
  }

  // Regenerate the last assistant reply (drops it, generates a fresh one).
  Future<void> _regenerate() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final conv = app.current;
    if (conv == null || _sending || app.isGenerating) return;
    app.buzz();
    setState(() => _sending = true);
    await app.regenerateLastReply(conv);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  // Continue the story: generate another assistant turn from the current
  // context, without the user typing a reply.
  Future<void> _continue() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final conv = app.current;
    if (conv == null || _sending || app.isGenerating) return;
    app.buzz();
    setState(() => _sending = true);
    await app.continueReply(conv);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _startEdit(ChatMessage m) {
    setState(() {
      _editingMessageId = m.id;
      _editController.text = m.content;
    });
  }

  void _cancelEdit() {
    setState(() => _editingMessageId = null);
  }

  void _saveEdit(ChatMessage m) {
    final app = context.read<AppState>();
    final conv = app.current;
    if (conv != null) app.editMessage(conv, m, _editController.text);
    setState(() => _editingMessageId = null);
  }

  static const _imageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  ];

  bool _isImageAttachment(String path) =>
      _imageExtensions.contains(path.split('.').last.toLowerCase());

  // Mirai never actually sends image bytes to either backend today (local
  // GGUF requests and the Ollama request body both only carry text), so a
  // remote model is treated the same as a non-vision one here regardless of
  // what it nominally supports server-side.
  bool _modelSupportsVision(AppState app) {
    if (!app.isLocalModel(app.selectedModel)) return false;
    return app.localSpecFor(app.selectedModel)?.isVisionCapable ?? false;
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        setState(() => _pendingAttachments.add(file.path!));
        if (mounted) {
          final app = context.read<AppState>();
          showAppSnackBar(context, app.t('fileAttached'));
        }
      }
    }
  }

  Future<void> _send([String? preset]) async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final text = (preset ?? _controller.text).trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) ||
        _sending ||
        app.isModelLoading) {
      return;
    }
    app.buzz();
    _controller.clear();
    final attachments = List<String>.from(_pendingAttachments);
    setState(() {
      _sending = true;
      _pendingAttachments.clear();
    });
    await app.sendMessage(text, attachments: attachments);
    if (!mounted) return;
    setState(() => _sending = false);
    _scrollDown();
  }

  void _scrollDown() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openModelMenu() {
    if (!mounted) return;
    final app = context.read<AppState>();
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _ModelMenu(
        onManage: () {
          Navigator.pop(context);
          _openSettings();
        },
        onNewChat: () {
          Navigator.pop(context);
          app.newChat();
          if (mounted) setState(() {});
        },
        onCreateImage: () {
          Navigator.pop(context);
          if (!mounted) return;
          showAppSnackBar(context, app.t('createImageHint'));
        },
      ),
    );
  }

  void _openSettings() {
    if (!mounted) return;
    if (widget.desktop) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DesktopSettings()),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: _scrim(context),
      builder: (_) => const SettingsSheet(),
    );
  }

  // Desktop top bar (mockup): model pill on the left, an online status badge,
  // and a profile button on the right. The settings entry lives in the
  // sidebar (DesktopHome), so it is not repeated here.
  Widget _desktopTopBar(AppState app) {
    final lockedModel = app.current?.rpModeEnabled == true
        ? app.current?.rpConfig?.lockedModel
        : null;
    final isLocal = app.isLocalModel(lockedModel ?? app.selectedModel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 24, 12),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {
              app.buzz();
              if (lockedModel != null) {
                showAppSnackBar(context, app.t('rpModelLockedToast'));
                return;
              }
              _openModelMenu();
            },
            child: _modelBubbleWrap(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      app.loadingModels
                          ? app.t('loadingModels')
                          : app.modelDisplayName(
                              lockedModel ?? app.selectedModel,
                              withSuffix: false,
                            ),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _txt(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    lockedModel != null
                        ? Icons.lock_outline
                        : Icons.keyboard_arrow_down,
                    color: _sub(context),
                    size: lockedModel != null ? 16 : 20,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          _updateReadyPill(app),
          _vaIndicator(app),
          // Per-chat personalization / roleplay settings are intentionally not
          // exposed on desktop — the assistant is configured globally in
          // DesktopSettings («Личность и память»).
          _desktopStatusBadge(app, isLocal),
        ],
      ),
    );
  }

  // "Update ready — restart" pill (Discord-style): appears once the new
  // installer is downloaded and verified; clicking applies it silently and
  // relaunches the app on the new version.
  Widget _updateReadyPill(AppState app) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: AppUpdater.instance.status,
      builder: (_, st, __) {
        if (st != UpdateStatus.ready) return const SizedBox.shrink();
        return InkWell(
          borderRadius: BorderRadius.circular(21),
          onTap: () => AppUpdater.instance.applyAndRestart(),
          child: _vaPill(
              Icons.system_update_alt,
              '${app.t('updReadyShort')} ${AppUpdater.instance.availableVersion} · ${app.t('updRestart')}',
              _success(context)),
        );
      },
    );
  }

  // Voice-assistant status pill in the top bar. Only shown when the user turned
  // on always-listening (wake-word mode). Reflects the real state: STT offline,
  // listening (+ last heard phrase), thinking, or running.
  Widget _vaIndicator(AppState app) {
    if (app.cmdMode != 'wakeword' || app.sttEngine != 'whisper') {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<SidecarStatus>(
      valueListenable: SidecarClient.instance.status,
      builder: (_, sc, __) {
        if (sc != SidecarStatus.connected) {
          return _vaPill(
              Icons.mic_off, app.t('vaSttOffline'), const Color(0xFFE0985D));
        }
        return ValueListenableBuilder<VaState>(
          valueListenable: VoiceAssistant.instance.state,
          builder: (_, s, __) {
            final (label, color) = switch (s) {
              VaState.armed => (app.t('vaArmed'), _info(context)),
              VaState.thinking => (app.t('vaThinking'), _success(context)),
              VaState.running => (app.t('vaRunning'), _warn(context)),
              _ => (app.t('vaListening'), _accent(context)),
            };
            if (s == VaState.listening || s == VaState.idle) {
              // Flash a bright "wake word heard!" state for ~2.5 s so the
              // trigger is unmistakable, then fall back to the plain status.
              // We deliberately do NOT surface the raw transcript here — it
              // lingered and cluttered the pill with mis-heard phrases.
              return ValueListenableBuilder<bool>(
                valueListenable: VoiceAssistant.instance.wakeActive,
                builder: (_, woke, __) {
                  if (woke) {
                    return _vaPill(
                        Icons.check_circle,
                        '«${app.wakeWord}» — ${app.t('vaWakeHeard')}',
                        _success(context));
                  }
                  return _vaPill(Icons.graphic_eq, label, color);
                },
              );
            }
            return _vaPill(Icons.graphic_eq, label, color);
          },
        );
      },
    );
  }

  Widget _vaPill(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Color.lerp(color, _txt(context), 0.4)!,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  // Colour for a connection status (dot + tint + border).
  Color _statusColor(BuildContext context, ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => _success(context),
        ConnectionStatus.connecting => _info(context),
        ConnectionStatus.noModel => _warn(context),
        ConnectionStatus.disconnected => _faint(context),
        ConnectionStatus.error => _danger(context),
      };

  String _statusText(AppState app, ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => app.t('statusConnected'),
        ConnectionStatus.connecting => app.t('statusConnecting'),
        ConnectionStatus.noModel => app.t('statusNoModel'),
        ConnectionStatus.disconnected => app.t('statusDisconnected'),
        ConnectionStatus.error => app.t('statusError'),
      };

  Widget _desktopStatusBadge(AppState app, bool isLocal) {
    final status = app.connectionStatus;
    final color = _statusColor(context, status);
    final label = status == ConnectionStatus.connected
        ? '${isLocal ? app.t('statusLocalModel') : app.t('statusRemoteModel')} · ${app.t('statusConnected')}'
        : _statusText(app, status);
    final textColor = Color.lerp(color, _txt(context), 0.45)!;
    return InkWell(
      borderRadius: BorderRadius.circular(21),
      onTap: () => _showConnectionDialog(app, status, isLocal),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: color, blurRadius: 9, spreadRadius: 1),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.info_outline,
                size: 14, color: color.withValues(alpha: 0.55)),
          ],
        ),
      ),
    );
  }

  void _showConnectionDialog(
      AppState app, ConnectionStatus status, bool isLocal) {
    if (!mounted) return;
    final isRemote = !isLocal && !app.isLocalModel(app.selectedModel);
    final modelName = app.selectedModel.isEmpty
        ? app.t('statusNoModel')
        : app.modelDisplayName(app.selectedModel, withSuffix: false);
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 92,
                  child: Text(k, style: TextStyle(color: _sub(context)))),
              Expanded(
                  child: Text(v,
                      style: TextStyle(
                          color: _txt(context),
                          fontWeight: FontWeight.w600))),
            ],
          ),
        );
    showDialog(
      context: context,
      builder: (dctx) => _AppDialog(
        title: Text(app.t('statusTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: _statusColor(context, status))),
              const SizedBox(width: 8),
              Text(_statusText(app, status),
                  style: TextStyle(
                      color: _txt(context), fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            row(app.t('modelField'), modelName),
            if (isRemote)
              row(app.t('serverField'),
                  app.serverUrl.isEmpty ? '—' : app.serverUrl),
            if (status == ConnectionStatus.error && app.modelsError != null) ...[
              const SizedBox(height: 10),
              Text(app.modelsError!,
                  style: const TextStyle(
                      color: Color(0xFFE05A6A), fontSize: 13, height: 1.4)),
            ],
          ],
        ),
        actions: [
          if (isRemote)
            TextButton(
              onPressed: () {
                Navigator.pop(dctx);
                app.fetchModels();
              },
              child: Text(app.t('retry')),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(app.t('gotIt')),
          ),
        ],
      ),
    );
  }

  void _openChatPersonalization() {
    if (!mounted) return;
    final app = context.read<AppState>();
    if (app.current == null) app.newChat();
    openPersonalization(context, conversation: app.current);
  }

  void _openVoice() async {
    if (!mounted) return;
    final result = await Navigator.of(context).push<(String, bool)>(
      MaterialPageRoute(builder: (_) => const VoiceScreen()),
    );
    if (!mounted || result == null) return;
    final (text, autoSend) = result;
    if (text.trim().isEmpty) return;
    if (autoSend) {
      _send(text);
    } else {
      _controller.text = text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conv = app.current;
    final hasMessages = conv != null && conv.messages.isNotEmpty;

    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: SafeArea(
        top: !widget.desktop,
        child: Column(
          children: [
            widget.desktop ? _desktopTopBar(app) : _topBar(app),
            if (app.isModelLoading) _modelLoadingCard(app),
            Expanded(
              child: hasMessages ? _messageList(conv, app) : _emptyState(app),
            ),
            if (app.showPromptChips && !hasMessages) _promptChips(app),
            if (conv != null &&
                conv.rpModeEnabled &&
                conv.rpConfig != null &&
                RPMemoryManager.checkContextThreshold(
                  conv.messages,
                  conv.rpConfig!,
                ))
              _compressionBanner(conv, app),
            _inputBar(app),
          ],
        ),
      ),
    );

    // Desktop shell provides its own sidebar (DesktopHome) instead of the
    // mobile edge-swipe drawer, and a transparent scaffold so the shell's
    // gradient background shows through.
    if (widget.desktop) {
      return Scaffold(backgroundColor: Colors.transparent, body: body);
    }

    return Scaffold(
      backgroundColor: _bg(context),
      // Full-width left drawer holds the chat list — opened by an edge swipe
      // (the old top-bar chats button is gone). Drawer keeps the OS status
      // bar visible (not immersive); its content uses its own SafeArea.
      drawerEdgeDragWidth: 56,
      // Opening the drawer must drop any text-field focus, otherwise the
      // keyboard (from the chat input or the drawer's search field) stays up
      // over the drawer with no way to dismiss it.
      onDrawerChanged: (opened) {
        if (opened) FocusManager.instance.primaryFocus?.unfocus();
      },
      drawer: Drawer(
        width: MediaQuery.of(context).size.width,
        backgroundColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: const ConversationsSheet(embedded: true),
      ),
      body: body,
    );
  }

  // Top "Preparing <model>" card with an indeterminate bar, shown while the
  // local model warms up (see AppState.warmUpModelFor).
  Widget _modelLoadingCard(AppState app) {
    final spec = app.loadingModelKey != null
        ? app.localSpecFor(app.loadingModelKey!)
        : null;
    final label = spec != null
        ? '${app.t('preparingModel')} ${spec.shortName}'
        : app.t('preparingModel');
    final row = Row(
      children: [
        Icon(Icons.auto_awesome, size: 18, color: _sub(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _txt(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: _sub(context).withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation(_accent(context)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: _glassCard(
        context,
        radius: 16,
        alpha: 0.6,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: row,
      ),
    );
  }

  Widget _topBar(AppState app) {
    final lockedModel = app.current?.rpModeEnabled == true
        ? app.current?.rpConfig?.lockedModel
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          _circleBtn(Icons.settings_outlined, _openSettings),
          const SizedBox(width: 8),
          // Centered between the two buttons but hugging the model name (not
          // stretched full-width); long names still ellipsize within the
          // available space.
          Expanded(
            child: Center(
              child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                app.buzz();
                if (lockedModel != null) {
                  showAppSnackBar(context, app.t('rpModelLockedToast'));
                  return;
                }
                _openModelMenu();
              },
              child: _modelBubbleWrap(
                child: Opacity(
                  opacity: lockedModel != null ? 0.6 : 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (app.loadingModels) ...[
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            app.t('loadingModels'),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _sub(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ] else ...[
                        Flexible(
                          child: Text(
                            app.isModelLoading
                                ? app.t('loadingShort')
                                : app.modelDisplayName(
                                    lockedModel ?? app.selectedModel,
                                    withSuffix: false,
                                  ),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _txt(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          lockedModel != null
                              ? Icons.lock_outline
                              : Icons.keyboard_arrow_down,
                          color: _txt(context),
                          size: lockedModel != null ? 18 : 24,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            ),
          ),
          const SizedBox(width: 8),
          _circleBtn(Icons.manage_accounts_outlined, _openChatPersonalization),
        ],
      ),
    );
  }

  // Input-bar surface: translucent blurred in glass style, solid card
  // otherwise. Sits inside the AnimatedBorder, so no border of its own here.
  Widget _inputSurface({required Widget child}) {
    const pad = EdgeInsets.symmetric(horizontal: 4, vertical: 4);
    if (_isGlass(context)) {
      return GlassSurface(
        borderRadius: BorderRadius.circular(20),
        padding: pad,
        child: child,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _card(context),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: pad,
      child: child,
    );
  }

  // Outer wrapper for the model-name bubble: a translucent blurred pill in
  // glass style, the bordered solid pill otherwise.
  Widget _modelBubbleWrap({required Widget child}) {
    const pad = EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    if (_isGlass(context)) {
      return GlassSurface(
        borderRadius: BorderRadius.circular(20),
        padding: pad,
        child: child,
      );
    }
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _sub(context).withValues(alpha: 0.3)),
      ),
      child: child,
    );
  }

  Widget _circleBtn(
    IconData icon,
    VoidCallback onTap, {
    bool active = false,
    String? tooltip,
  }) {
    final iconWidget = Icon(
      icon,
      color: active ? _accent(context) : _txt(context),
      size: 22,
    );
    // Glass style (non-active) → translucent blurred circle; active state
    // keeps its blue tint in both styles. Standard style → the original
    // solid circle.
    final Widget face = (_isGlass(context) && !active)
        ? GlassSurface(
            circle: true,
            child: SizedBox(width: 48, height: 48, child: Center(child: iconWidget)),
          )
        : Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? _accent(context)
                    : _sub(context).withValues(alpha: 0.3),
                width: active ? 1.5 : 1,
              ),
              color: active
                  ? _accent(context).withValues(alpha: 0.18)
                  : _card(context).withValues(alpha: 0.4),
            ),
            child: iconWidget,
          );
    final btn = InkResponse(
      onTap: () {
        if (!mounted) return;
        context.read<AppState>().buzz();
        onTap();
      },
      radius: 28,
      child: face,
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  Widget _emptyState(AppState app) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Voice visualization on the home screen, gated by settings
            // (vizType 'none' or showVizBg off hides it; waves/bars currently
            // render as the sphere).
            if (app.showVizBg && app.vizType != 'none') ...[
              const SizedBox(height: 20),
              // vizType picks the hero visualization; all react to the real
              // combined voice level (mic + assistant speech).
              if (app.vizType == 'bars')
                const EvsBarsViz(width: 360, height: 150)
              else if (app.vizType == 'waves')
                const EvsRingViz(size: 220)
              else if (app.vizType == 'orb')
                const EvsLiveViz(kind: 'orb', maxSize: 320)
              else if (app.vizType == 'lkbars')
                const EvsLiveViz(kind: 'lkbars', maxSize: 340)
              else if (app.vizType == 'wave3d')
                const EvsWaveViz(
                    kind: 'wave3d', size: 320, fadeEdges: true, reactive: true)
              else if (app.vizType == 'waveflat')
                const EvsWaveViz(
                    kind: 'waveflat', size: 320, fadeEdges: true, reactive: true)
              else
                ParticleSphere(
                  size: 200,
                  color: _vizColor(context),
                  scattered: keyboardOpen,
                  soundLevel: VoiceLevels.instance.tts,
                ),
            ],
            const SizedBox(height: 20),
            const _SttReadinessBanner(),
            Text(
              app.isModelLoading ? app.t('gettingReady') : app.t('howCanIHelp'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _txt(context),
                fontSize: 28,
                fontWeight: FontWeight.w700,
                // The hero sits directly over the visualization; a soft halo
                // keeps it legible whatever the viz is doing underneath.
                shadows: _overTextShadows(context),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                app.isModelLoading
                    ? app.t('loadingYourModel')
                    : app.t('subtitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _sub(context),
                  fontSize: 14,
                  height: 1.4,
                  shadows: _overTextShadows(context),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _messageList(Conversation conv, AppState app) {
    // In RP mode the assistant message is already a real (possibly still
    // empty) entry in conv.messages from the moment generation starts (see
    // AppState._generateAssistantReply), so the synthetic placeholder below
    // would otherwise show a second "thinking" bubble alongside it.
    final showSyntheticPlaceholder = _sending && !conv.rpModeEnabled;
    if (app.isGenerating && conv.rpModeEnabled) {
      // Keep the growing reply in view as it streams in, the same way
      // _send() already does once for the non-streaming reply.
      _scrollDown();
    }
    final busy = _sending || app.isGenerating;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: conv.messages.length + (showSyntheticPlaceholder ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= conv.messages.length) {
          return _bubble(
            ChatMessage(role: 'assistant', content: ''),
            thinking: true,
          );
        }
        final m = conv.messages[i];
        final isStreamingPlaceholder =
            app.isGenerating &&
            conv.rpModeEnabled &&
            i == conv.messages.length - 1 &&
            m.role == 'assistant' &&
            m.content.isEmpty;
        // Action bar (edit / regenerate / continue) under the last assistant
        // reply when idle.
        final showActions =
            !busy &&
            i == conv.messages.length - 1 &&
            m.role == 'assistant' &&
            m.content.isNotEmpty;
        return _bubble(
          m,
          thinking: isStreamingPlaceholder,
          showActions: showActions,
        );
      },
    );
  }

  Widget _bubble(
    ChatMessage m, {
    bool thinking = false,
    bool showActions = false,
  }) {
    final isUser = m.role == 'user';
    final editing = _editingMessageId == m.id;
    final fg = _onAccent(context);
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      decoration: BoxDecoration(
        color: isUser ? Theme.of(context).colorScheme.primary : null,
        gradient: isUser
            ? null
            : _accentGradient(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.attachments.isNotEmpty)
            ...m.attachments.map(
              (a) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.attach_file,
                      size: 14,
                      color: fg.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        a.split('/').last,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.75),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (thinking)
            const _ThinkingDots()
          else if (editing)
            _editBubbleBody(m)
          else if (m.content.isNotEmpty)
            Text(
              m.content,
              style: EvsType.body.copyWith(color: fg),
            ),
        ],
      ),
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          thinking || editing
              ? bubble
              : GestureDetector(
                  onLongPressStart: (d) =>
                      _showMessageActions(m, d.globalPosition),
                  child: bubble,
                ),
          if (showActions && !editing) _messageActionsBar(m),
        ],
      ),
    );
  }

  // Inline editor shown inside an assistant bubble in place of its text.
  Widget _editBubbleBody(ChatMessage m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: _editController,
          autofocus: true,
          minLines: 1,
          maxLines: 12,
          style: EvsType.body.copyWith(color: _onAccent(context)),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _cancelEdit,
              style: TextButton.styleFrom(
                foregroundColor: _onAccent(context).withValues(alpha: 0.7),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: Text(context.read<AppState>().t('cancel')),
            ),
            TextButton(
              onPressed: () => _saveEdit(m),
              style: TextButton.styleFrom(
                foregroundColor: _onAccent(context),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: Text(context.read<AppState>().t('save')),
            ),
          ],
        ),
      ],
    );
  }

  // Edit / regenerate / continue controls under the last assistant reply.
  Widget _messageActionsBar(ChatMessage m) {
    final app = context.read<AppState>();
    Widget btn(IconData icon, String tooltip, VoidCallback onTap) {
      return IconButton(
        icon: Icon(icon, size: 18, color: _txt(context)),
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(),
      );
    }

    Widget sep() => Container(
      width: 1,
      height: 20,
      color: _sub(context).withValues(alpha: 0.25),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.edit_outlined, app.t('msgEdit'), () => _startEdit(m)),
        sep(),
        btn(Icons.refresh, app.t('msgRegenerate'), _regenerate),
        sep(),
        btn(Icons.fast_forward, app.t('msgContinue'), _continue),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6, left: 2),
      child: _isGlass(context)
          ? GlassSurface(borderRadius: BorderRadius.circular(18), child: row)
          : Container(
              decoration: BoxDecoration(
                color: _card(context).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(18),
              ),
              child: row,
            ),
    );
  }

  void _showMessageActions(ChatMessage m, Offset globalPosition) async {
    final app = context.read<AppState>();
    final conv = app.current;
    final isPinned = conv != null && conv.pinnedMessageIds.contains(m.id);
    final String? selected;
    if (_isGlass(context)) {
      selected = await showGlassMenu(
        context,
        position: globalPosition,
        menuWidth: 260,
        items: [
          GlassMenuItem('copy', app.t('msgCopy'), icon: Icons.copy_outlined),
          GlassMenuItem(
            'compose',
            app.t('msgUseInComposer'),
            icon: Icons.edit_note_outlined,
          ),
          GlassMenuItem(
            'remember',
            app.t('msgRemember'),
            icon: Icons.psychology_alt_outlined,
          ),
          GlassMenuItem(
            'forget',
            app.t('msgForgetMemory'),
            icon: Icons.delete_outline,
            color: Colors.redAccent,
          ),
          GlassMenuItem(
            'pin',
            isPinned ? app.t('msgUnpinContext') : app.t('msgPinContext'),
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          ),
        ],
      );
    } else {
      selected = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          globalPosition.dx,
          globalPosition.dy,
          globalPosition.dx,
          globalPosition.dy,
        ),
        color: _card(context),
        items: [
          _menuItem('copy', Icons.copy_outlined, app.t('msgCopy')),
          _menuItem(
            'compose',
            Icons.edit_note_outlined,
            app.t('msgUseInComposer'),
          ),
          _menuItem(
            'remember',
            Icons.psychology_alt_outlined,
            app.t('msgRemember'),
          ),
          _menuItem(
            'forget',
            Icons.delete_outline,
            app.t('msgForgetMemory'),
            color: Colors.redAccent,
          ),
          _menuItem(
            'pin',
            isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            isPinned ? app.t('msgUnpinContext') : app.t('msgPinContext'),
          ),
        ],
      );
    }
    if (selected == null || !mounted) return;
    String? toast;
    switch (selected) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.content));
        toast = app.t('msgCopied');
        break;
      case 'compose':
        _controller.text = m.content;
        _inputFocus.requestFocus();
        break;
      case 'remember':
        final effectivePersona = conv?.persona ?? app.persona;
        if (effectivePersona.askBeforeRemembering) {
          final confirmed = await _pickMemoryCategory(app);
          if (confirmed != true || !mounted) break;
        }
        app.rememberMessageContent(m.content);
        toast = app.t('msgRemembered');
        break;
      case 'forget':
        app.forgetMessageMemory(m.content);
        toast = app.t('msgForgotten');
        break;
      case 'pin':
        if (conv != null) {
          app.toggleMessagePin(conv, m);
          toast = isPinned ? app.t('msgUnpinned') : app.t('msgPinned');
        }
        break;
    }
    if (toast != null && mounted) {
      showAppSnackBar(context, toast);
    }
  }

  Future<bool?> _pickMemoryCategory(AppState app) {
    const categories = [
      'memCatPreference',
      'memCatProfile',
      'memCatProject',
      'memCatOther',
    ];
    var selected = categories.first;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => _AppDialog(
          backgroundColor: _card(context),
          title: Text(
            app.t('chooseMemoryCategory'),
            style: TextStyle(color: _txt(context)),
          ),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final cat in categories)
                ChoiceChip(
                  label: Text(app.t(cat)),
                  selected: selected == cat,
                  labelStyle: TextStyle(
                    color: selected == cat ? Colors.white : _txt(context),
                    fontWeight: FontWeight.w500,
                  ),
                  selectedColor: _accent(context),
                  backgroundColor: _bg(context).withValues(alpha: 0.4),
                  side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
                  onSelected: (_) => setDialogState(() => selected = cat),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(app.t('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(app.t('save')),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? _txt(context)),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color ?? _txt(context))),
        ],
      ),
    );
  }

  Widget _promptChips(AppState app) {
    final chips = [
      (app.t('summarize'), Icons.edit_outlined),
      (app.t('rewrite'), Icons.auto_awesome),
      (app.t('fixGrammar'), Icons.spellcheck),
    ];
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final c in chips)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ActionChip(
                onPressed: () => _send('${c.$1}: '),
                backgroundColor: _card(context).withValues(alpha: 0.6),
                side: BorderSide(color: _sub(context).withValues(alpha: 0.2)),
                avatar: Icon(c.$2, size: 18, color: _txt(context)),
                label: Text(
                  c.$1,
                  style: TextStyle(
                    color: _txt(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _compressionBanner(Conversation conv, AppState app) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: _glassCard(
        context,
        radius: 14,
        alpha: 0.6,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, color: _sub(context), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              app.t('rpContextFull'),
              style: TextStyle(color: _txt(context), fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: app.isCompressingContext
                ? null
                : () => app.compressRpContext(conv),
            child: app.isCompressingContext
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _sub(context),
                    ),
                  )
                : Text(app.t('rpCompressButton')),
          ),
        ],
        ),
      ),
    );
  }

  // Image attachments get an actual thumbnail (matches the reference
  // screenshot); non-image files keep the old filename chip, since there's
  // nothing meaningful to preview for those.
  Widget _attachmentPreviewRow(AppState app) {
    final showVisionWarning =
        _pendingAttachments.any(_isImageAttachment) &&
        !_modelSupportsVision(app);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _pendingAttachments.map((a) {
              return _isImageAttachment(a)
                  ? _imageAttachmentThumb(a)
                  : _fileAttachmentChip(a);
            }).toList(),
          ),
          if (showVisionWarning) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_outlined,
                  size: 14,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    app.t('imageNotSupportedWarning'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _imageAttachmentThumb(String path) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: attachmentThumbnail(path, size: 72),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => setState(() => _pendingAttachments.remove(path)),
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fileAttachmentChip(String path) {
    return Chip(
      avatar: const Icon(Icons.attach_file, size: 16),
      label: Text(
        path.split('/').last,
        style: TextStyle(fontSize: 12, color: _txt(context)),
      ),
      onDeleted: () => setState(() => _pendingAttachments.remove(path)),
      backgroundColor: _bg(context).withValues(alpha: 0.4),
      side: BorderSide(color: _sub(context).withValues(alpha: 0.3)),
    );
  }

  Widget _inputBar(AppState app) {
    // Commands-only mode: text chat is disabled — show a locked bar (voice
    // push-to-talk stays so commands still work).
    if (!app.chatEnabled) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
        child: _inputSurface(
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(Icons.lock_outline, size: 18, color: _sub(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(app.t('chatDisabledHint'),
                    style: TextStyle(color: _sub(context), fontSize: 14)),
              ),
              const SizedBox(width: 14),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      child: AnimatedBorder(
        radius: 20,
        strokeWidth: 2,
        child: _inputSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_pendingAttachments.isNotEmpty)
                _attachmentPreviewRow(app),
              Row(
                children: [
              // Кнопка добавления с анимированной обводкой
              _buildAnimatedBtn(
                onTap: () {
                  app.buzz();
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: Colors.transparent,
                    barrierColor: _scrim(context),
                    isScrollControlled: true,
                    builder: (_) => _RecentAttachSheet(
                      onPick: (path) =>
                          setState(() => _pendingAttachments.add(path)),
                      onPickFile: _pickFile,
                    ),
                  );
                },
                icon: Icons.add,
              ),
              const SizedBox(width: 4),
              // Поле ввода
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _inputFocus,
                  enabled: !app.isModelLoading,
                  style: TextStyle(color: _txt(context), fontSize: 16),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: app.isModelLoading
                        ? app.t('preparingModel')
                        : app.t('askAnything'),
                    hintStyle: TextStyle(color: _sub(context), fontSize: 16),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              // Кнопка отправки (фиксированный размер, чтобы не "скакать"
              // между обычным и состоянием отправки)
              Builder(
                builder: (context) {
                  final hasContent =
                      _controller.text.trim().isNotEmpty ||
                      _pendingAttachments.isNotEmpty;
                  final canStop =
                      app.isGenerating && (app.current?.rpModeEnabled ?? false);
                  return Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: canStop
                          ? Colors.redAccent
                          : hasContent
                          ? kSendActiveColor
                          : _txt(context).withValues(alpha: 0.1),
                    ),
                    child: canStop
                        ? IconButton(
                            onPressed: () {
                              app.buzz();
                              app.cancelGeneration();
                            },
                            tooltip: app.t('stopGeneration'),
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white,
                            ),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          )
                        : _sending
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: hasContent
                                  ? Colors.white
                                  : _txt(context),
                            ),
                          )
                        : IconButton(
                            onPressed: () => _send(),
                            icon: Icon(
                              Icons.arrow_upward,
                              color: hasContent ? Colors.white : _txt(context),
                            ),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                  );
                },
              ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedBtn({
    required VoidCallback onTap,
    required IconData icon,
  }) {
    final iconWidget = Icon(icon, color: _txt(context), size: 20);
    return AnimatedBorder(
      radius: 20,
      strokeWidth: 2,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: _isGlass(context)
              ? GlassSurface(
                  circle: true,
                  padding: const EdgeInsets.all(8),
                  child: iconWidget,
                )
              : Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _card(context),
                    shape: BoxShape.circle,
                  ),
                  child: iconWidget,
                ),
        ),
      ),
    );
  }
}

// Mirrors the iOS Messages attachment drawer: a draggable sheet with a grid
// of recent photos up top and a row of source tabs at the bottom. Only
// Gallery/File are kept — Gift/Wallet/Location/Checklist don't map to
// anything this app does.
class _RecentAttachSheet extends StatefulWidget {
  final ValueChanged<String> onPick;
  final VoidCallback onPickFile;
  const _RecentAttachSheet({required this.onPick, required this.onPickFile});

  @override
  State<_RecentAttachSheet> createState() => _RecentAttachSheetState();
}

class _RecentAttachSheetState extends State<_RecentAttachSheet> {
  List<AssetEntity> _assets = [];
  bool _loading = true;
  bool _denied = false;
  final Set<String> _pickedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) {
        if (mounted) {
          setState(() {
            _loading = false;
            _denied = true;
          });
        }
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      final assets = albums.isEmpty
          ? <AssetEntity>[]
          : await albums.first.getAssetListPaged(page: 0, size: 60);
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
      });
    } catch (_) {
      // photo_manager has no implementation on this platform (Windows,
      // Linux and Web aren't supported) — fall back to the same "no
      // access" state so the user can still attach via the file picker.
      if (mounted) {
        setState(() {
          _loading = false;
          _denied = true;
        });
      }
    }
  }

  Future<void> _onTapAsset(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null || !mounted) return;
    setState(() => _pickedIds.add(asset.id));
    widget.onPick(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return _sheetSurface(
          context,
          solid: _card(context),
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
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    const SizedBox(width: 40),
                    Expanded(
                      child: Text(
                        app.t('recentPhotos'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _txt(context),
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: _txt(context)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody(scrollController, app)),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _attachTab(
                        Icons.photo_outlined,
                        app.t('attachTabGallery'),
                        selected: true,
                        onTap: () {},
                      ),
                      _attachTab(
                        Icons.attach_file,
                        app.t('attachTabFile'),
                        selected: false,
                        onTap: () {
                          Navigator.pop(context);
                          widget.onPickFile();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(ScrollController scrollController, AppState app) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            app.t('photoAccessDenied'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _sub(context)),
          ),
        ),
      );
    }
    if (_assets.isEmpty) {
      return Center(
        child: Text(
          app.t('noRecentPhotos'),
          style: TextStyle(color: _sub(context)),
        ),
      );
    }
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _assets.length,
      itemBuilder: (_, i) {
        final asset = _assets[i];
        final picked = _pickedIds.contains(asset.id);
        return GestureDetector(
          onTap: () => _onTapAsset(asset),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FutureBuilder<Uint8List?>(
                  future: asset.thumbnailDataWithSize(
                    const ThumbnailSize.square(200),
                  ),
                  builder: (_, snap) {
                    if (snap.data == null) {
                      return Container(color: _bg(context));
                    }
                    return Image.memory(snap.data!, fit: BoxFit.cover);
                  },
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: picked ? _accent(context) : Colors.black38,
                    border: Border.all(color: Colors.white70, width: 1.2),
                  ),
                  child: picked
                      ? const Icon(Icons.check, size: 13, color: Colors.white)
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _attachTab(
    IconData icon,
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: selected ? _accent(context) : _sub(context),
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? _txt(context) : _sub(context),
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Three dots bouncing in a left-to-right wave, replacing a static "thinking…"
// label in the assistant's placeholder bubble while a reply is generating.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              // Stagger each dot's phase so they crest one after another
              // instead of all bobbing in lockstep.
              final phase = (_ctrl.value + i * 0.18) % 1.0;
              final lift = math.sin(phase * math.pi).clamp(0.0, 1.0);
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
                child: Transform.translate(
                  // Bob symmetrically around the bubble's vertical center
                  // (rest sits slightly below center, peak slightly above)
                  // instead of only travelling upward.
                  offset: Offset(0, 3 - 6 * lift),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _txt(context).withValues(alpha: 0.6 + 0.4 * lift),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/* ============================ МЕНЮ ВЫБОРА МОДЕЛИ ============================ */

class _ModelMenu extends StatelessWidget {
  final VoidCallback onManage;
  final VoidCallback onNewChat;
  final VoidCallback onCreateImage;
  const _ModelMenu({
    required this.onManage,
    required this.onNewChat,
    required this.onCreateImage,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Stack(
      children: [
        Positioned(
          top: 70,
          left: MediaQuery.of(context).size.width * 0.14,
          right: MediaQuery.of(context).size.width * 0.14,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              decoration: BoxDecoration(
                color: _card(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _stroke(context)),
                boxShadow: _shadow(context, y: 12, blur: 32),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      children: [
                        Text(
                          app.t('downloadedModels'),
                          style: TextStyle(
                            color: _sub(context),
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        if (app.loadingModels)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _sub(context),
                            ),
                          )
                        else
                          InkWell(
                            onTap: () {
                              app.buzz();
                              app.fetchModels();
                            },
                            child: Icon(
                              Icons.refresh,
                              color: _sub(context),
                              size: 18,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (app.models.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              child: Text(
                                app.modelsError ?? app.t('noModelsFound'),
                                style: TextStyle(
                                  color: _faint(context),
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          for (final m in app.models)
                            InkWell(
                              onTap: () {
                                app.buzz();
                                app.selectModel(m);
                                Navigator.pop(context);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      app.selectedModel == m
                                          ? Icons.check
                                          : Icons.circle_outlined,
                                      color: app.selectedModel == m
                                          ? _txt(context)
                                          : _faint(context),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        app.modelDisplayName(m),
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: _txt(context),
                                          fontSize: 18,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    color: _stroke(context),
                    indent: 20,
                    endIndent: 20,
                  ),
                  _menuItem(
                    context,
                    Icons.inventory_2_outlined,
                    app.t('manageModels'),
                    onManage,
                  ),
                  _menuItem(
                      context, Icons.edit_outlined, app.t('newChat'), onNewChat),
                  _menuItem(
                      context, null, app.t('createImage'), onCreateImage),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem(
      BuildContext context, IconData? icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: _txt(context), size: 20),
              const SizedBox(width: 14),
            ] else
              const SizedBox(width: 34),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _txt(context), fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
