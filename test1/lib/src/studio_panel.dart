part of '../main.dart';

// Студия: генерация картинок и озвучка текста. Одно окно на два режима —
// отличаются они только тем, что уходит на сервер и что возвращается, а
// оболочка, лента результатов и строка ввода общие.
//
// Открывается во весь экран из рейки (`_NexusRail`) тем же приёмом, что и
// настройки: обычный маршрут поверх главного окна.
enum StudioMode { image, speech }

/// Полоса наверху окна: видеокарта отдана под картинки, часть возможностей
/// сейчас не работает. Постоянная, а не всплывающая — всплывающее исчезает
/// через пару секунд, а ограничение живёт всё время, пока открыта студия.
class GpuNoticeBar extends StatelessWidget {
  const GpuNoticeBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: GpuArbiter.instance.notice,
      builder: (_, text, __) {
        if (text == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          color: _warn(context).withValues(alpha: 0.16),
          child: Row(children: [
            Icon(Icons.info_outline, size: 16, color: _warn(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12.5, color: _body(context))),
            ),
          ]),
        );
      },
    );
  }
}

class StudioPanel extends StatefulWidget {
  const StudioPanel({super.key, required this.mode});
  final StudioMode mode;

  @override
  State<StudioPanel> createState() => _StudioPanelState();
}

// Одна карточка в ленте: что просили, что получилось, и файл на диске.
class _StudioItem {
  _StudioItem({required this.prompt, this.busy = false});
  final String prompt;
  String? path;
  String? error;
  bool busy;
}

class _StudioPanelState extends State<StudioPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_StudioItem> _items = [];
  bool _busy = false;

  // Озвучка: чем говорить. 'assistant' — текущий голос ассистента (что выбрано
  // в настройках), 'clone' — клон через CosyVoice, остальное — id Piper-голоса.
  String _voice = 'assistant';

  @override
  void initState() {
    super.initState();
    if (widget.mode == StudioMode.image) {
      // Видеокарта на станции одна, и языковая модель на ней не помещается
      // рядом с генератором картинок. Освобождаем её на время работы студии;
      // возврат — в dispose().
      unawaited(GpuArbiter.instance.takeForImages(context.read<AppState>()));
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    if (widget.mode == StudioMode.image) {
      // Именно здесь, а не по кнопке «Закрыть»: окно закрывают и клавишей Esc,
      // и крестиком, и переключением стиля — во всех случаях модели должны
      // вернуться, иначе ассистент останется немым до перезапуска.
      unawaited(GpuArbiter.instance.release());
    }
    super.dispose();
  }

  Future<String> _studioDir() async {
    final root = await appDataRoot();
    final dir = io.Directory('$root${io.Platform.pathSeparator}studio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    });
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final item = _StudioItem(prompt: text, busy: true);
    setState(() {
      _items.add(item);
      _busy = true;
      _input.clear();
    });
    _scrollDown();
    try {
      final path = widget.mode == StudioMode.image
          ? await _generateImage(app, text)
          : await _renderSpeech(app, text);
      item.path = path;
    } catch (e) {
      item.error = '$e';
    } finally {
      item.busy = false;
      if (mounted) setState(() => _busy = false);
      _scrollDown();
    }
  }

  Future<String> _generateImage(AppState app, String prompt) async {
    final url = app.imageServerUrl.trim();
    if (url.isEmpty) throw Exception(app.t('studioNoServer'));
    final res = await http
        .post(Uri.parse('$url/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'prompt': prompt,
              'model': app.imageModel,
              'steps': 28,
              'width': 1024,
              'height': 1024,
            }))
        .timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final dir = await _studioDir();
    final name = 'img-${DateTime.now().millisecondsSinceEpoch}.png';
    final file = io.File('$dir${io.Platform.pathSeparator}$name');
    await file.writeAsBytes(res.bodyBytes);
    return file.path;
  }

  // Озвучка. Клон отдаёт файл — его сервер возвращает WAV, и это единственный
  // путь, по которому у нас на руках оказываются байты звука. Остальные голоса
  // живут внутри сайдкара и умеют только проговорить вслух: файла для них не
  // будет, и в интерфейсе об этом сказано прямо, а не подсунута мёртвая кнопка.
  Future<String?> _renderSpeech(AppState app, String text) async {
    if (_voice == 'clone') return _renderClone(app, text);
    if (_voice == 'assistant') {
      SidecarClient.instance
          .speak(text, rate: app.ttsRate, volume: app.ttsVolume);
      return null;
    }
    final spec = kAssetModels.firstWhere(
      (s) => s.family == 'tts-voice' && s.voiceId == _voice,
      orElse: () => throw Exception(app.t('studioVoiceGone')),
    );
    await SidecarClient.instance
        .previewTtsVoice(spec.voiceId!, spec.id, text, rate: app.ttsRate);
    return null;
  }

  Future<String> _renderClone(AppState app, String text) async {
    final ep = app.cosyvoiceEndpoint.trim();
    if (ep.isEmpty) throw Exception(app.t('studioNoClone'));
    final ref = app.cosyvoiceClonePath.trim();
    if (ref.isEmpty || !await io.File(ref).exists()) {
      throw Exception(app.t('studioNoSample'));
    }
    // Тот же запрос, что шлёт сайдкар (CosyVoiceEngine): те же поля и тот же
    // порядок — сервер один и тот же, второй диалект заводить незачем.
    final boundary = '----evsStudio${DateTime.now().microsecondsSinceEpoch}';
    final parts = <List<int>>[];
    void field(String name, String value) {
      parts.add(utf8.encode('--$boundary'));
      parts.add(utf8.encode('Content-Disposition: form-data; name="$name"\r\n'));
      parts.add(utf8.encode(value));
    }

    field('tts_text', text);
    field('prompt_text', app.cosyvoiceClonePromptText);
    field('speed', app.cosyvoiceSpeed.toString());
    parts.add(utf8.encode('--$boundary'));
    parts.add(utf8.encode('Content-Disposition: form-data; name="prompt_wav"; '
        'filename="ref.wav"\r\nContent-Type: audio/wav\r\n'));
    parts.add(await io.File(ref).readAsBytes());
    parts.add(utf8.encode('--$boundary--'));
    final body = <int>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) body.addAll(utf8.encode('\r\n'));
      body.addAll(parts[i]);
    }
    body.addAll(utf8.encode('\r\n'));

    final res = await http
        .post(Uri.parse('$ep/inference_zero_shot'),
            headers: {
              'Content-Type': 'multipart/form-data; boundary=$boundary'
            },
            body: body)
        .timeout(const Duration(minutes: 5));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final dir = await _studioDir();
    final name = 'voice-${DateTime.now().millisecondsSinceEpoch}.wav';
    final file = io.File('$dir${io.Platform.pathSeparator}$name');
    await file.writeAsBytes(res.bodyBytes);
    return file.path;
  }

  List<(String id, String label)> _voices(AppState app) {
    final out = <(String, String)>[
      ('assistant', app.t('studioVoiceAssistant')),
      if (app.cosyvoiceEndpoint.trim().isNotEmpty)
        ('clone', app.t('studioVoiceClone')),
    ];
    for (final s in kAssetModels) {
      if (s.family == 'tts-voice' && s.voiceId != null &&
          (app.assetInstalled(s.id))) {
        out.add((s.voiceId!, s.name));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final image = widget.mode == StudioMode.image;
    return Scaffold(
      backgroundColor: _bg(context),
      body: Container(
        decoration: _evsShellBg(context),
        child: Column(
          children: [
            const _WindowTitleBar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 10),
              child: Row(children: [
                Icon(image ? Icons.image_outlined : Icons.record_voice_over_outlined,
                    size: 20, color: _accent(context)),
                const SizedBox(width: 10),
                Text(app.t(image ? 'studioImages' : 'studioSpeech'),
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: _txt(context))),
                const Spacer(),
                evsGhostButton(context, app.t('close'), Icons.close,
                    onTap: () => Navigator.of(context).maybePop()),
              ]),
            ),
            if (image) _serverHint(app),
            Expanded(child: _feed(app, image)),
            _composer(app, image),
          ],
        ),
      ),
    );
  }

  // Пока адрес не задан, окно не притворяется рабочим.
  Widget _serverHint(AppState app) {
    if (app.imageServerUrl.trim().isNotEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _warn(context).withValues(alpha: 0.12),
        border: Border.all(color: _warn(context).withValues(alpha: 0.4)),
      ),
      child: Text(app.t('studioNoServerHint'),
          style: TextStyle(fontSize: 12.5, color: _body(context))),
    );
  }

  Widget _feed(AppState app, bool image) {
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(app.t(image ? 'studioImagesHint' : 'studioSpeechHint'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: _faint(context))),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
      itemCount: _items.length,
      itemBuilder: (_, i) => _resultCard(app, _items[i], image),
    );
  }

  Widget _resultCard(AppState app, _StudioItem it, bool image) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: _card(context),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(it.prompt,
              style: TextStyle(fontSize: 13, color: _body(context))),
          const SizedBox(height: 10),
          if (it.busy)
            Row(children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text(app.t('studioWorking'),
                  style: TextStyle(fontSize: 12, color: _sub(context))),
            ])
          else if (it.error != null)
            Text(it.error!,
                style: TextStyle(fontSize: 12, color: _danger(context)))
          else if (it.path != null && image)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(io.File(it.path!), fit: BoxFit.contain),
            )
          else
            Text(app.t(it.path == null ? 'studioSpoken' : 'studioSaved'),
                style: TextStyle(fontSize: 12, color: _success(context))),
          if (it.path != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              // Тем же способом, что и «открыть папку моделей» в настройках:
              // explorer сам выберет, чем открыть файл.
              evsGhostButton(context, app.t('studioOpen'), Icons.open_in_new,
                  onTap: () => unawaited(io.Process.start(
                      'explorer.exe', [it.path!],
                      runInShell: false))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(it.path!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: _faint(context))),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _composer(AppState app, bool image) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: Column(children: [
        if (!image) ...[
          Row(children: [
            Text(app.t('studioVoice'),
                style: TextStyle(fontSize: 12, color: _sub(context))),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final v in _voices(app))
                    _voiceChip(app, v.$1, v.$2),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 10),
        ],
        Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              maxLines: image ? 3 : 5,
              minLines: 1,
              onSubmitted: (_) => unawaited(_submit()),
              style: TextStyle(fontSize: 13.5, color: _txt(context)),
              decoration: InputDecoration(
                hintText: app.t(image ? 'studioPrompt' : 'studioText'),
                hintStyle: TextStyle(color: _faint(context)),
                filled: true,
                fillColor: _overlayFill(context, 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          evsGhostButton(context, app.t(image ? 'studioGo' : 'studioSay'),
              image ? Icons.auto_awesome : Icons.play_arrow,
              onTap: _busy ? null : () => unawaited(_submit())),
        ]),
      ]),
    );
  }

  Widget _voiceChip(AppState app, String id, String label) {
    final active = _voice == id;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _voice = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: active
              ? _accent(context).withValues(alpha: 0.16)
              : _overlayFill(context, 0.05),
          border: Border.all(
              color: active ? _accent(context) : _stroke(context)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? _accent(context) : _body(context))),
      ),
    );
  }
}
