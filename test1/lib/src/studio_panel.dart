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
  const StudioPanel({super.key, required this.mode, this.embedded = false});
  final StudioMode mode;

  /// Открыта внутри оболочки, а не отдельным окном: тогда полосу заголовка и
  /// кнопку «Закрыть» рисовать не надо — закрывать нечего, экран уже часть
  /// окна. Умолчание сохраняет прежний вид для остальных стилей.
  final bool embedded;

  @override
  State<StudioPanel> createState() => _StudioPanelState();
}

/// Предел длины текста для озвучки. Не украшение: синтез в файл ждёт ответа
/// сайдкара не дольше 120 секунд (`renderTtsToFile`), и текст, который не
/// успевает синтезироваться, возвращается пустой строкой без объяснения.
/// Пять тысяч знаков — примерно полчаса речи, дальше упирается уже движок.
const int _kPrismSpeechLimit = 5000;

// Одна карточка в ленте: что просили, что получилось, и файл на диске.
class _StudioItem {
  _StudioItem({required this.prompt, this.voice = '', this.busy = false});
  final String prompt;

  /// Каким голосом озвучено. В списке последних озвучек это первая строка:
  /// два одинаковых текста разными голосами иначе не различить.
  final String voice;

  /// Когда поставлено. Нужно списку — он показывает «2 мин», «3 ч».
  final DateTime at = DateTime.now();
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

  // Картинки: размер кадра и число шагов. Размеры — родные для SDXL: сеть
  // училась на кадрах площадью около миллиона пикселей, и произвольные
  // пропорции дают вытянутые лица и лишние руки. Шаги — сколько раз модель
  // уточняет кадр: меньше двадцати заметно грубее, после сорока разница уже
  // не окупает ожидания.
  int _imgW = 1024;
  int _imgH = 1024;
  int _steps = 28;
  bool _hintsOpen = false;

  // Сила подсказки (CFG) — насколько жёстко модель держится запроса. Умолчание
  // diffusers — 7,5, но авторы чекпоинтов этой ветки рекомендуют около пяти: на
  // 7,5 картинка «пережарена», контуры резче, цвета грубее. Сэмплер — способ
  // обхода шагов; у SDXL авторы почти всегда называют Euler a.
  double _cfg = 5;
  String _sampler = 'euler_a';

  // Негативный запрос — чего в кадре быть не должно. Отдельное поле, а не
  // приписка к основному: модель считает его вторым проходом и сравнивает
  // результаты, поэтому смешивать их нельзя.
  final _negative = TextEditingController();

  // Свой образец голоса — на один сеанс, не трогая настройки. Пусто — берётся
  // тот, что выбран в «Голосе ассистента». Так можно послушать чужой голос или
  // сравнить два, не переписывая рабочую настройку и не возвращая её потом.
  String _cloneOverride = '';

  // Какая модель считает картинки. Имя файла чекпоинта на сервере, а не
  // «красивое» название: одно и то же семейство раздают под десятком имён, и
  // единственное, что однозначно указывает на веса, — имя файла.
  String _model = '';

  /// Включённые довески. Живут в настройках, а не только в этом окне: выбор
  /// довесков — часть рабочей обстановки, и терять его при закрытии окна так же
  /// обидно, как терять выбранную модель.
  List<ImageLoraPick> _loras = const [];

  /// Сила второго прохода по лицу; 0 — не делать.
  double _face = 0.4;

  /// Ускоренная ли выбранная модель и что о ней известно от авторов.
  bool _modelDistilled = false;
  Map<String, dynamic>? _modelNote;

  /// Негативный запрос действует, только когда модель сравнивает кадр с ним —
  /// а это происходит при силе подсказки больше единицы. У ускоренных моделей
  /// сила равна единице по устройству, и поле надо гасить, а не делать вид.
  bool get _negativeWorks => !_modelDistilled && _cfg > 1;

  // Ход генерации: шаг из скольких. Кадр считается больше минуты, и молчаливое
  // ожидание неотличимо от зависания — поэтому спрашиваем сервер, где он.
  (int, int) _progress = (0, 0);
  Timer? _progressTimer;

  void _watchProgress(AppState app) {
    _progressTimer?.cancel();
    final url = app.imageServerUrl.trim();
    if (url.isEmpty) return;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 900), (t) async {
      if (!mounted || !_busy) {
        t.cancel();
        return;
      }
      try {
        final r = await http
            .get(Uri.parse('$url/progress'))
            .timeout(const Duration(seconds: 3));
        if (r.statusCode != 200 || !mounted) return;
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final step = (j['step'] as num?)?.toInt() ?? 0;
        final total = (j['total'] as num?)?.toInt() ?? 0;
        setState(() => _progress = (step, total));
      } catch (_) {
        // Сервер старой версии или не отвечает — просто не показываем шкалу.
      }
    });
  }

  // Подсказки для запроса. Модель этой ветки понимает не предложения, а теги
  // через запятую — и по ним же её обучали. Человеку это неочевидно: пишешь
  // «девушка с синими волосами ночью в городе» и получаешь мутную картинку,
  // хотя нужные слова знаешь. Поэтому подсказки не украшение, а способ
  // объяснить формат, не заставляя читать документацию.
  //
  // Порядок групп — не произвольный, а тот, которому модель обучена:
  // «кто в кадре, персонаж, из какой серии, рейтинг, всё остальное, и В КОНЦЕ
  // теги качества». Раньше качество стояло первой группой — это была моя
  // ошибка, а не мелочь оформления: у модели порядок тегов значащий.
  static const List<(String, List<String>)> _promptHints = [
    ('studioHintSubject',
        ['1girl', '1boy', 'solo', 'looking at viewer', 'portrait', 'close-up', 'face focus', 'upper body', 'full body']),
    ('studioHintRating',
        ['safe', 'sensitive']),
    ('studioHintScene',
        ['city', 'indoors', 'outdoors', 'forest', 'cyberpunk', 'detailed background']),
    ('studioHintLight',
        ['night', 'day', 'sunset', 'neon lights', 'backlighting', 'depth of field']),
    ('studioHintYear',
        ['year 2010', 'year 2018', 'year 2024']),
    ('studioHintQuality',
        ['masterpiece', 'best quality', 'absurdres', 'very aesthetic']),
    ('studioHintScore',
        ['high score', 'great score', 'good score']),
  ];

  void _appendTag(String tag) {
    final t = _input.text.trimRight();
    final sep = t.isEmpty ? '' : (t.endsWith(',') ? ' ' : ', ');
    _input.text = '$t$sep$tag';
    _input.selection =
        TextSelection.collapsed(offset: _input.text.length);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    if (widget.mode == StudioMode.image) {
      // Видеокарта на станции одна, и языковая модель на ней не помещается
      // рядом с генератором картинок. Освобождаем её на время работы студии;
      // возврат — в dispose().
      unawaited(GpuArbiter.instance.takeForImages(context.read<AppState>()));
      final app = context.read<AppState>();
      _loras = decodeLoraPicks(app.imageLoras);
      _face = app.imageFacePass;
      unawaited(_loadModels());
    }
  }

  /// Какая модель стоит на сервере. Спрашиваем сервер, а не верим настройке:
  /// настройка могла остаться от модели, которую уже удалили, и тогда
  /// генерация упала бы с «нет файла модели», а в окне красовалось бы
  /// исправное имя.
  Future<void> _loadModels() async {
    final app = context.read<AppState>();
    final c = ImageModelsClient(app.imageServerUrl);
    if (!c.ready) return;
    try {
      var r = await c.list();
      if (await c.fillKnownNotes(r.items)) r = await c.list();
      if (!mounted) return;
      final want = app.imageModel.trim();
      final known = r.items.any((m) => m.name == want);
      final name = known ? want : r.current;
      final info = r.items.where((m) => m.name == name).firstOrNull;
      setState(() {
        _model = name;
        _modelDistilled = info?.distilled ?? false;
        _modelNote = info?.note;
      });
      if (!known && r.current.isNotEmpty) app.setImageModel(r.current);
    } catch (_) {
      // Сервер старой версии или недоступен — строка модели просто не появится,
      // а генерация пойдёт как раньше: сервер возьмёт свою умолчательную.
    }
  }

  Future<void> _openModels(AppState app) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ImageModelsSheet(app: app),
    );
    if (mounted) await _loadModels();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _input.dispose();
    _negative.dispose();
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
    final item = _StudioItem(
      prompt: text,
      voice: widget.mode == StudioMode.image
          ? ''
          : _voices(app)
              .firstWhere((v) => v.$1 == _voice,
                  orElse: () => ('assistant', app.t('studioVoiceAssistant')))
              .$2,
      busy: true,
    );
    setState(() {
      _items.add(item);
      _busy = true;
      _input.clear();
    });
    _scrollDown();
    try {
      final path = widget.mode == StudioMode.image
          ? await (() { _watchProgress(app); return _generateImage(app, text); })()
          : await _renderSpeech(app, text);
      item.path = path;
    } catch (e) {
      item.error = '$e';
    } finally {
      item.busy = false;
      _progressTimer?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = (0, 0);
        });
      }
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
              'who': 'desktop',
              'model': _model.isNotEmpty ? _model : app.imageModel,
              'steps': _steps,
              'width': _imgW,
              'height': _imgH,
              'cfg': _cfg,
              'sampler': _sampler,
              if (_face > 0) 'face': _face,
              if (_loras.isNotEmpty)
                'loras': [
                  for (final l in _loras)
                    {'name': l.name, 'weight': l.weight},
                ],
              // Пустое поле — не «нет запрета», а «возьми свой обычный»: у
              // сервера есть отрицательный запрос по умолчанию, и он лучше
              // пустого. Отправляем только то, что человек написал сам.
              if (_negativeWorks && _negative.text.trim().isNotEmpty)
                'negative': _negative.text.trim(),
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
  Future<void> _pickCloneSample() async {
    final res = await FilePicker.pickFiles();
    final p = res?.files.single.path;
    if (p != null && p.isNotEmpty) setState(() => _cloneOverride = p);
  }

  Future<String?> _renderSpeech(AppState app, String text) async {
    if (_voice == 'clone') return _renderClone(app, text);
    final dir = await _studioDir();
    final path =
        '$dir${io.Platform.pathSeparator}voice-${DateTime.now().millisecondsSinceEpoch}.wav';
    // Синтезируем в ФАЙЛ, а не проговариваем. Раньше здесь звук уходил прямо
    // в колонки и исчезал: студия писала «проговорено вслух», сохранять было
    // нечего, и кнопке «показать в папке» нечего было показывать. Теперь любой
    // голос — и ассистента, и Piper — оставляет файл, как и клон.
    if (_voice == 'assistant') {
      final out = await SidecarClient.instance
          .renderTtsToFile(text, path, rate: app.ttsRate);
      if (out.isEmpty) throw Exception(app.t('studioRenderFailed'));
      return out;
    }
    final spec = kAssetModels.firstWhere(
      (s) => s.family == 'tts-voice' && s.voiceId == _voice,
      orElse: () => throw Exception(app.t('studioVoiceGone')),
    );
    final voiceDir = await SidecarClient.instance.voiceDirFor(spec.id);
    final out = await SidecarClient.instance.renderTtsToFile(text, path,
        voiceId: spec.voiceId!, voiceDir: voiceDir, rate: app.ttsRate);
    if (out.isEmpty) throw Exception(app.t('studioRenderFailed'));
    return out;
  }

  Future<String> _renderClone(AppState app, String text) async {
    final ep = app.cosyvoiceEndpoint.trim();
    if (ep.isEmpty) throw Exception(app.t('studioNoClone'));
    final ref = _cloneOverride.isNotEmpty
        ? _cloneOverride
        : app.cosyvoiceClonePath.trim();
    if (ref.isEmpty || !await io.File(ref).exists()) {
      throw Exception(app.t('studioNoSample'));
    }
    // Тот же запрос, что шлёт сайдкар (CosyVoiceEngine): те же поля и тот же
    // порядок — сервер один и тот же, второй диалект заводить незачем.
    final boundary = '----animaStudio${DateTime.now().microsecondsSinceEpoch}';
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

  // ------------------------------------------------------------------------
  // «ПРИЗМА» — раскладка макета для Nexus Sonora
  // ------------------------------------------------------------------------

  /// Экран озвучки из прототипа: слева вкладки, голос с ползунками и текст,
  /// справа волна и последние озвучки.
  ///
  /// Поля и работа — те же, что у остальных стилей: `_voice`, `_voices`,
  /// `_input`, `_submit`, `_renderSpeech`. Добавлено ровно одно действие,
  /// которого у студии не было: «Озвучить» — сказать вслух прямо сейчас.
  /// Без него панель «Волна» была бы мёртвой: сохранение в файл идёт молча.
  Widget _prismSonora(AppState app) {
    final cloneReady = app.cosyvoiceEndpoint.trim().isNotEmpty;
    final onSystem = _voice != 'clone';
    final voices = _voices(app);
    final voiceLabel = voices
        .firstWhere((v) => v.$1 == _voice,
            orElse: () => ('assistant', app.t('studioVoiceAssistant')))
        .$2;
    final text = _input.text.trim();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PrismTabsStrip<bool>(
                  tabs: [
                    (true, app.t('prismTabSystemVoices')),
                    (false, app.t('prismTabClone')),
                  ],
                  value: onSystem,
                  // Вкладка клона недоступна, пока адрес сервера не задан:
                  // выбрать голос, которого нет, — тупик без объяснения.
                  disabled:
                      cloneReady ? const {} : {false: app.t('prismCloneOff')},
                  onChanged: (sys) => setState(
                      () => _voice = sys ? 'assistant' : 'clone'),
                ),
                const SizedBox(height: 16),
                PrismPanel(
                  radius: 26,
                  padding: const EdgeInsets.all(22),
                  shadow: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          PrismSectionLabel(app.t('prismVoice')),
                          const Spacer(),
                          Flexible(
                            child: PrismPickPill(
                              label: voiceLabel,
                              onTap: () => unawaited(_prismPickVoice(app)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 17),
                      PrismLabeledSlider(
                        label: app.t('ttsRate'),
                        display: '${app.ttsRate.toStringAsFixed(2)}×',
                        value: app.ttsRate,
                        min: 0.5,
                        max: 2,
                        step: 0.05,
                        onChanged: app.setTtsRate,
                      ),
                      const SizedBox(height: 17),
                      PrismLabeledSlider(
                        label: app.t('ttsVolume'),
                        display: '${(app.ttsVolume * 100).round()}%',
                        value: app.ttsVolume,
                        min: 0,
                        max: 1,
                        step: 0.01,
                        onChanged: app.setTtsVolume,
                      ),
                      // Образец для клона — только на своей вкладке: на
                      // системных голосах его брать неоткуда и незачем.
                      if (_voice == 'clone') ...[
                        const SizedBox(height: 17),
                        PrismSectionLabel(app.t('studioPickSample'),
                            size: 10.5),
                        const SizedBox(height: 9),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _cloneOverride.isEmpty
                                    ? (app.cosyvoiceClonePath.trim().isEmpty
                                        ? app.t('studioNoSample')
                                        : app.cosyvoiceClonePath
                                            .split(io.Platform.pathSeparator)
                                            .last)
                                    : _cloneOverride
                                        .split(io.Platform.pathSeparator)
                                        .last,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: PrismType.caption.copyWith(
                                    fontSize: 11.5, color: _sub(context)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            _PrismGhostButton(
                              label: app.t('studioPickSample'),
                              d: PrismIcons.doc,
                              onTap: _pickCloneSample,
                            ),
                            if (_cloneOverride.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              _PrismGhostButton(
                                label: app.t('studioSampleReset'),
                                d: PrismIcons.remove,
                                onTap: () =>
                                    setState(() => _cloneOverride = ''),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PrismPanel(
                  radius: 26,
                  padding: const EdgeInsets.all(22),
                  shadow: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PrismSectionLabel(app.t('prismSpeechText')),
                      const SizedBox(height: 14),
                      PrismField(
                        controller: _input,
                        hint: app.t('studioText'),
                        lines: 5,
                        radius: 18,
                        fontSize: 14,
                        maxLength: _kPrismSpeechLimit,
                        // Счётчик под полем должен считать по мере набора.
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            '${_input.text.characters.length} / '
                            '$_kPrismSpeechLimit',
                            style: PrismType.numeric.copyWith(
                                color: _faint(context), fontSize: 11.5),
                          ),
                          const Spacer(),
                          // Сохранение в файл — то, ради чего студия и есть:
                          // озвучка остаётся на диске.
                          _PrismGhostButton(
                            label: app.t('prismSaveToFile'),
                            d: PrismIcons.doc,
                            onTap: _busy || text.isEmpty
                                ? null
                                : () => unawaited(_submit()),
                          ),
                          const SizedBox(width: 10),
                          ValueListenableBuilder<double>(
                            valueListenable: VoiceLevels.instance.tts,
                            builder: (context, level, _) {
                              final speaking = level > 0.001;
                              return PrismGradientButton(
                                label: speaking
                                    ? app.t('prismSpeakStop')
                                    : app.t('prismSpeakNow'),
                                d: speaking
                                    ? PrismIcons.stop
                                    : PrismIcons.play,
                                fontSize: 13.5,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 12),
                                onTap: speaking
                                    ? SidecarClient.instance.stopSpeaking
                                    : (text.isEmpty
                                        ? null
                                        : () => SidecarClient.instance.speak(
                                              text,
                                              rate: app.ttsRate,
                                              volume: app.ttsVolume,
                                            )),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 18),
        SizedBox(
          width: 320,
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PrismWavePanel(rendering: _busy),
                const SizedBox(height: 16),
                PrismPanel(
                  radius: 26,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
                  shadow: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PrismSectionLabel(app.t('prismSpeechRecent')),
                      const SizedBox(height: 13),
                      if (_items.isEmpty)
                        Text(app.t('studioSpeechHint'),
                            style: PrismType.caption
                                .copyWith(color: _faint(context)))
                      else
                        for (final it in _items.reversed) ...[
                          PrismSpeechRow(
                            voice: it.voice.isEmpty
                                ? app.t('studioVoiceAssistant')
                                : it.voice,
                            text: it.prompt,
                            time: prismAgo(app, it.at),
                            busy: it.busy,
                            error: it.error,
                            // Нажатие открывает файл в папке — послушать его
                            // нечем: своего проигрывателя у программы нет, а
                            // говорит она через движок, а не файлом.
                            onTap: () {
                              final p = it.path;
                              if (p == null) return;
                              unawaited(io.Process.start(
                                  'explorer.exe', ['/select,$p'],
                                  runInShell: true));
                            },
                          ),
                          const SizedBox(height: 9),
                        ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Выбор голоса из того же списка, что и чипы в остальных стилях.
  Future<void> _prismPickVoice(AppState app) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx + box.size.width - 320,
        origin.dy + 150,
        16,
        0,
      ),
      items: [
        for (final v in _voices(app))
          PopupMenuItem<String>(
            value: v.$1,
            child: Row(
              children: [
                if (v.$1 == _voice)
                  PrismIcon(PrismIcons.spark,
                      size: 14, stroke: 2, color: _ramp(context).a2)
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 10),
                Text(v.$2, style: TextStyle(color: _txt(context))),
              ],
            ),
          ),
      ],
    );
    if (picked != null && mounted) setState(() => _voice = picked);
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
    // «Призма» раскладывает озвучку по макету. Картинки в этом стиле идут
    // через LuminaStudio со своей раскладкой, поэтому здесь только речь.
    if (_isPrism(context) && widget.embedded && !image) {
      return _prismSonora(app);
    }
    final body = Column(
          children: [
            if (!widget.embedded) const _WindowTitleBar(),
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
                if (_items.any((i) => !i.busy)) ...[
                  animaGhostButton(context, app.t('studioDropAll'),
                      Icons.delete_sweep_outlined,
                      onTap: () => unawaited(_dropAll(app))),
                  const SizedBox(width: 8),
                ],
                if (!widget.embedded)
                  animaGhostButton(context, app.t('close'), Icons.close,
                      onTap: () => Navigator.of(context).maybePop()),
              ]),
            ),
            if (image) _serverHint(app),
            // «Призма» кладёт ленту и строку ввода на стеклянные плитки, как в
            // макете; остальные стили оставляют их прямо на плоскости окна.
            Expanded(
              child: Padding(
                padding: _isPrism(context)
                    ? const EdgeInsets.fromLTRB(18, 0, 18, 0)
                    : EdgeInsets.zero,
                child: animaStudioPane(
                  context,
                  padding: EdgeInsets.zero,
                  child: _feed(app, image),
                ),
              ),
            ),
            if (_isPrism(context)) const SizedBox(height: 16),
            Padding(
              padding: _isPrism(context)
                  ? const EdgeInsets.fromLTRB(18, 0, 18, 18)
                  : EdgeInsets.zero,
              child: animaStudioPane(
                context,
                padding: EdgeInsets.zero,
                child: _composer(app, image),
              ),
            ),
          ],
        );
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: _bg(context),
      body: animaShellBackdrop(context, body),
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
              Text(
                  _progress.$2 > 0
                      ? '${app.t('studioWorking')} ${_progress.$1}/${_progress.$2}'
                      : app.t('studioWorking'),
                  style: TextStyle(fontSize: 12, color: _sub(context))),
              if (_progress.$2 > 0) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (_progress.$1 / _progress.$2).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: _stroke(context),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(_accent(context)),
                    ),
                  ),
                ),
              ],
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
              // Открываем ПАПКУ и подсвечиваем в ней файл, а не сам файл.
              // Запуск файла отдал бы его проигрывателю или просмотрщику по
              // умолчанию, а нужно обычно другое: показать, где он лежит, чтобы
              // скопировать или перетащить. Ключ /select именно для этого.
              animaGhostButton(context, app.t('studioOpen'), Icons.folder_open,
                  onTap: () => unawaited(io.Process.start(
                      'explorer.exe', ['/select,${it.path!}'],
                      runInShell: false))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(it.path!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: _faint(context))),
              ),
              _dropButton(app, it),
            ]),
          ]
          else if (!it.busy) ...[
            // Неудачная попытка тоже занимает место в ленте — убрать её должно
            // быть можно тем же движением, что и удачную.
            const SizedBox(height: 6),
            Align(
                alignment: Alignment.centerRight,
                child: _dropButton(app, it)),
          ],
        ],
      ),
    );
  }

  // Убрать одну работу из ленты вместе с файлом. Файл стирается сразу и без
  // переспроса: карточки копятся быстро, каждая — полтора мегабайта, и лишний
  // диалог на каждую превратил бы уборку в работу. Отменить нечего, но и
  // потерять нечего — то же самое можно сгенерировать снова.
  Widget _dropButton(AppState app, _StudioItem it) => IconButton(
        tooltip: app.t('studioDrop'),
        icon: Icon(Icons.delete_outline, size: 17, color: _faint(context)),
        onPressed: () => unawaited(_drop(it)),
      );

  Future<void> _drop(_StudioItem it) async {
    final p = it.path;
    if (p != null) {
      try {
        await io.File(p).delete();
      } catch (_) {
        // Файл уже убрали руками — карточку всё равно снимаем.
      }
    }
    if (mounted) setState(() => _items.remove(it));
  }

  Future<void> _dropAll(AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: _card2(context),
        title: Text(app.t('studioDropAll'),
            style: TextStyle(color: _txt(context), fontSize: 16)),
        content: Text(app.t('studioDropAllAsk'),
            style: TextStyle(color: _body(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(app.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(app.t('delete'),
                  style: TextStyle(color: _danger(context)))),
        ],
      ),
    );
    if (ok != true) return;
    for (final it in List<_StudioItem>.from(_items)) {
      if (!it.busy) await _drop(it);
    }
  }

  Widget _composer(AppState app, bool image) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: Column(children: [
        if (image) ...[
          _modelBar(app),
          Row(children: [
            animaGhostButton(
                context,
                app.t(_hintsOpen ? 'studioHintsHide' : 'studioHints'),
                _hintsOpen ? Icons.expand_less : Icons.lightbulb_outline,
                onTap: () => setState(() => _hintsOpen = !_hintsOpen)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(app.t('studioHintsWhy'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ),
          ]),
          if (_hintsOpen) ...[
            const SizedBox(height: 8),
            for (final g in _promptHints) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(app.t(g.$1),
                    style: TextStyle(fontSize: 11, color: _sub(context))),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in g.$2)
                    _chip(tag, false, () => _appendTag(tag)),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(app.t('studioSize'),
                  style: TextStyle(fontSize: 12, color: _sub(context))),
              for (final s in const [
                (1024, 1024, 'studioSizeSquare'),
                (832, 1216, 'studioSizePortrait'),
                (1216, 832, 'studioSizeLandscape'),
                (896, 1152, 'studioSizePortrait'),
                (1152, 896, 'studioSizeLandscape'),
                (768, 1344, 'studioSizePortrait'),
                (1344, 768, 'studioSizeLandscape'),
              ])
                _chip(
                    '${app.t(s.$3)}  ${s.$1}x${s.$2}',
                    _imgW == s.$1 && _imgH == s.$2,
                    () => setState(() {
                          _imgW = s.$1;
                          _imgH = s.$2;
                        })),
              const SizedBox(width: 12),
              Text(app.t('studioSteps'),
                  style: TextStyle(fontSize: 12, color: _sub(context))),
              for (final n in const [20, 25, 28, 40])
                _chip('$n', _steps == n, () => setState(() => _steps = n)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: app.t('studioCfgDesc'),
                child: Text(app.t('studioCfg'),
                    style: TextStyle(fontSize: 12, color: _sub(context))),
              ),
              for (final v in const [1.0, 3.0, 5.0, 7.0, 9.0])
                _chip(v == 1 ? app.t('studioCfgOff') : '${v.toInt()}',
                    _cfg == v, () => setState(() => _cfg = v)),
              const SizedBox(width: 12),
              Tooltip(
                message: app.t('studioSamplerDesc'),
                child: Text(app.t('studioSampler'),
                    style: TextStyle(fontSize: 12, color: _sub(context))),
              ),
              for (final s in const [
                ('euler_a', 'Euler a'),
                ('euler', 'Euler'),
                ('dpmpp_2m', 'DPM++ 2M'),
                ('dpmpp_2m_karras', 'DPM++ 2M Karras'),
              ])
                _chip(s.$2, _sampler == s.$1,
                    () => setState(() => _sampler = s.$1)),
              const SizedBox(width: 12),
              Tooltip(
                message: app.t('studioFaceDesc'),
                child: Text(app.t('studioFace'),
                    style: TextStyle(fontSize: 12, color: _sub(context))),
              ),
              for (final v in const [0.0, 0.3, 0.4, 0.5])
                _chip(v == 0 ? app.t('studioFaceOff') : v.toStringAsFixed(1),
                    _face == v, () {
                  setState(() => _face = v);
                  app.setImageFacePass(v);
                }),
            ],
          ),
          const SizedBox(height: 8),
          _loraBar(app),
          const SizedBox(height: 10),
        ],
        if (!image) ...[
          if (_voice == 'clone') ...[
            Row(children: [
              animaGhostButton(context, app.t('studioPickSample'),
                  Icons.audiotrack_outlined, onTap: _pickCloneSample),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _cloneOverride.isEmpty
                      ? (app.cosyvoiceClonePath.trim().isEmpty
                          ? app.t('studioNoSample')
                          : '${app.t('studioSampleFromSettings')}: '
                              '${app.cosyvoiceClonePath.split(io.Platform.pathSeparator).last}')
                      : _cloneOverride.split(io.Platform.pathSeparator).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: _sub(context)),
                ),
              ),
              if (_cloneOverride.isNotEmpty)
                IconButton(
                  tooltip: app.t('studioSampleReset'),
                  icon: Icon(Icons.close, size: 16, color: _faint(context)),
                  onPressed: () => setState(() => _cloneOverride = ''),
                ),
            ]),
            const SizedBox(height: 10),
          ],
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
          animaGhostButton(context, app.t(image ? 'studioGo' : 'studioSay'),
              image ? Icons.auto_awesome : Icons.play_arrow,
              onTap: _busy ? null : () => unawaited(_submit())),
        ]),
        if (image) ...[
          const SizedBox(height: 8),
          _negativeField(app),
        ],
      ]),
    );
  }

  // Чего в кадре быть не должно. Поле гаснет не «на всякий случай», а когда
  // запрос действительно не участвует в счёте: модель сравнивает кадр с
  // негативным запросом только при силе подсказки больше единицы. Показывать
  // живое поле, которое никуда не идёт, — хуже, чем не показывать вовсе.
  Widget _negativeField(AppState app) {
    final on = _negativeWorks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: on ? 1 : 0.45,
          child: TextField(
            controller: _negative,
            enabled: on,
            maxLines: 2,
            minLines: 1,
            style: TextStyle(fontSize: 12.5, color: _txt(context)),
            decoration: InputDecoration(
              hintText: app.t('studioNegative'),
              hintStyle: TextStyle(color: _faint(context), fontSize: 12.5),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: _overlayFill(context, 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _stroke(context)),
              ),
            ),
          ),
        ),
        if (!on)
          Padding(
            padding: const EdgeInsets.only(top: 5, left: 2),
            child: Text(
                app.t(_modelDistilled
                    ? 'studioNegativeDistilled'
                    : 'studioNegativeOffCfg'),
                style: TextStyle(fontSize: 11, color: _warn(context))),
          ),
      ],
    );
  }

  // Какая модель считает и чем её сменить. Строка постоянная, а не пункт в
  // меню: на результат модель влияет сильнее любого другого переключателя в
  // этом окне, и знать её надо ДО того, как нажал «Создать», — иначе фотореализм
  // с аниме-подсказками объясняется только опытным путём.
  Widget _modelBar(AppState app) {
    if (app.imageServerUrl.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(Icons.layers_outlined, size: 15, color: _faint(context)),
        const SizedBox(width: 8),
        Text('${app.t('studioModel')}:',
            style: TextStyle(fontSize: 12, color: _sub(context))),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            _model.isEmpty
                ? app.t('studioModelUnknown')
                : ImageModelInfo(_model, 0).title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _txt(context)),
          ),
        ),
        const SizedBox(width: 10),
        // Подсказки по модели. Кнопка есть всегда, даже когда сведений нет:
        // «сведений нет» — тоже ответ, и лучше сказать его прямо, чем прятать
        // кнопку и оставлять человека гадать, куда она делась.
        IconButton(
          tooltip: app.t('imgNoteTitle'),
          icon: Icon(Icons.help_outline,
              size: 17,
              color: _modelNote == null ? _faint(context) : _accent(context)),
          onPressed: _model.isEmpty ? null : () => unawaited(_openNote(app)),
        ),
        animaGhostButton(context, app.t('studioModelManage'), Icons.tune,
            onTap: () => unawaited(_openModels(app))),
      ]),
    );
  }

  // Довески: что включено и чем это менять. Строка на виду, а не в меню —
  // включённый довесок меняет каждый кадр, и забытый по невнимательности
  // объясняет «почему всё вдруг стало другим» чаще всего остального.
  Widget _loraBar(AppState app) {
    if (app.imageServerUrl.trim().isEmpty) return const SizedBox.shrink();
    return Row(children: [
      Icon(Icons.extension_outlined, size: 15, color: _faint(context)),
      const SizedBox(width: 8),
      Text('${app.t('imgLorasTitle')}:',
          style: TextStyle(fontSize: 12, color: _sub(context))),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          _loras.isEmpty
              ? app.t('imgLoraNone')
              : _loras
                  .map((l) =>
                      '${ImageModelInfo(l.name, 0).title} x${l.weight.toStringAsFixed(2)}')
                  .join(',  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: _loras.isEmpty ? FontWeight.w400 : FontWeight.w600,
              color: _loras.isEmpty ? _faint(context) : _txt(context)),
        ),
      ),
      const SizedBox(width: 10),
      animaGhostButton(context, app.t('imgLoraPick'), Icons.extension_outlined,
          onTap: () => unawaited(_openLoras(app))),
    ]);
  }

  Future<void> _openLoras(AppState app) async {
    final res = await showDialog<List<ImageLoraPick>>(
      context: context,
      builder: (_) => ImageLorasSheet(app: app, picked: _loras),
    );
    if (res == null || !mounted) return;
    setState(() => _loras = res);
    app.setImageLoras(encodeLoraPicks(res));
  }

  Future<void> _openNote(AppState app) async {
    final apply = await showDialog<bool>(
      context: context,
      builder: (_) => ImageModelNoteSheet(
          app: app, model: _model, note: _modelNote),
    );
    if (apply == true) _applyNote(app);
  }

  /// Поставить то, что рекомендуют авторы модели. Только названное ими: если в
  /// карточке нет силы подсказки — не трогаем силу, а не подставляем «обычную».
  void _applyNote(AppState app) {
    final n = _modelNote;
    if (n == null) return;
    setState(() {
      final cfg = (n['cfg'] as num?)?.toDouble();
      if (cfg != null) _cfg = cfg;
      final steps = (n['steps'] as num?)?.toInt();
      if (steps != null) _steps = steps;
      final s = (n['sampler'] ?? '').toString();
      if (s.isNotEmpty) _sampler = s;
      final sizes = n['sizes'];
      if (sizes is List && sizes.isNotEmpty && sizes.first is List) {
        final f = sizes.first as List;
        if (f.length >= 2) {
          _imgW = (f[0] as num).toInt();
          _imgH = (f[1] as num).toInt();
        }
      }
      final neg = (n['negative'] ?? '').toString();
      if (neg.isNotEmpty && _negative.text.trim().isEmpty) {
        _negative.text = neg;
      }
    });
    showAppSnackBar(context, app.t('imgNoteApplied'));
  }

  Widget _voiceChip(AppState app, String id, String label) =>
      _chip(label, _voice == id, () => setState(() => _voice = id));

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
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

// --- модели генератора -----------------------------------------------------

/// Один чекпоинт на сервере генерации.
class ImageModelInfo {
  const ImageModelInfo(this.name, this.size,
      {this.distilled = false, this.note});
  final String name;
  final int size;

  /// Ускоренная модель (turbo/lightning и родня). У них сила подсказки равна
  /// единице, а при ней негативный запрос не участвует в счёте вовсе. Признак
  /// — догадка сервера по имени файла, и подаём мы его именно так.
  final bool distilled;

  /// Рекомендации авторов, как их напечатали в карточке модели: сила
  /// подсказки, число шагов, сэмплер, родные размеры кадра. Пусто — сведений
  /// нет, и выдумывать их за авторов мы не станем.
  final Map<String, dynamic>? note;

  /// Человеческое имя. Файл называется так, как его выложили, и читать это
  /// неудобно; но и «угадывать» настоящее название модели по имени файла
  /// нельзя — соврём в половине случаев. Поэтому только убираем расширение и
  /// разделители, оставляя остальное как есть.
  String get title {
    var s = name;
    for (final e in const ['.safetensors', '.ckpt']) {
      if (s.toLowerCase().endsWith(e)) {
        s = s.substring(0, s.length - e.length);
      }
    }
    return s.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  }
}

/// Ход скачивания модели на станцию.
typedef ImagePullState = ({
  bool running,
  String name,
  int done,
  int total,
  String error,
  // Прервали руками. Отдельным признаком, а не сравнением текста ошибки:
  // отмена — это не отказ, и сообщать о ней как об отказе незачем.
  bool cancelled,
});

/// Разговор с сервером генерации про его модели. Отдельным классом, а не
/// разбором JSON внутри виджета: список нужен в двух местах — в самой студии
/// (какая модель считает) и в окне управления (какие вообще есть).
///
/// Скачивание идёт НА СТАНЦИИ, а не через компьютер: файл в семь гигабайт
/// незачем гонять по домашней сети дважды. Побочное следствие приятное —
/// закрытое приложение скачивание не прерывает, а открытое снова показывает
/// его ход с того места, где оно сейчас.
class ImageModelsClient {
  ImageModelsClient(String base) : _base = base.trim();
  final String _base;

  bool get ready => _base.isNotEmpty;

  Future<({List<ImageModelInfo> items, String current, int free})> list() async {
    final j = await _get('/models');
    final items = <ImageModelInfo>[];
    for (final m in (j['items'] as List? ?? const [])) {
      if (m is! Map) continue;
      items.add(ImageModelInfo(
        (m['name'] ?? '').toString(),
        (m['size'] as num?)?.toInt() ?? 0,
        distilled: m['distilled'] == true,
        note: m['note'] is Map
            ? Map<String, dynamic>.from(m['note'] as Map)
            : null,
      ));
    }
    return (
      items: items,
      current: (j['current'] ?? '').toString(),
      free: (j['free'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> select(String name) => _post('/models/select', {'model': name});

  Future<void> remove(String name) => _post('/models/delete', {'model': name});

  Future<void> pull(String url, String name, {Map<String, dynamic>? note}) =>
      _post('/models/pull',
          {'url': url, 'name': name, if (note != null) 'note': note});

  Future<void> setNote(String name, Map<String, dynamic>? note) =>
      _post('/models/note', {'model': name, 'note': note});

  Future<({List<ImageLoraInfo> items, int free})> loras() async {
    final j = await _get('/loras');
    final items = <ImageLoraInfo>[];
    for (final m in (j['items'] as List? ?? const [])) {
      if (m is! Map) continue;
      items.add(ImageLoraInfo(
          (m['name'] ?? '').toString(), (m['size'] as num?)?.toInt() ?? 0));
    }
    return (items: items, free: (j['free'] as num?)?.toInt() ?? 0);
  }

  Future<void> pullLora(String url, String name) =>
      _post('/loras/pull', {'url': url, 'name': name});

  Future<void> deleteLora(String name) =>
      _post('/loras/delete', {'name': name});

  /// Приложить сведения к моделям, которые мы знаем по имени файла, но у
  /// которых на станции их ещё нет. Нужно для чекпоинтов, положенных туда до
  /// того, как сведения вообще появились: иначе кнопка подсказок молчала бы
  /// про модель, о которой мы всё знаем.
  Future<bool> fillKnownNotes(List<ImageModelInfo> items) async {
    var changed = false;
    for (final m in items) {
      if (m.note != null) continue;
      for (final p in kImageModelPresets) {
        if (p.file != m.name) continue;
        try {
          await setNote(m.name, p.note);
          changed = true;
        } catch (_) {
          // Сервер старой версии — просто останемся без подсказок.
        }
        break;
      }
    }
    return changed;
  }

  Future<void> cancelPull() => _post('/models/pull/cancel', const {});

  Future<ImagePullState> pullState() async {
    final j = await _get('/models/pull');
    return (
      running: j['running'] == true,
      name: (j['name'] ?? '').toString(),
      done: (j['done'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
      error: (j['error'] ?? '').toString(),
      cancelled: j['cancel'] == true,
    );
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await http
        .get(Uri.parse('$_base$path'))
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> _post(String path, Map<String, Object?> body) async {
    final r = await http
        .post(Uri.parse('$_base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 200) return;
    // Сервер отвечает кодом, а не фразой: язык интерфейса знает приложение,
    // а не станция.
    var code = '';
    try {
      code = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['error'] ?? '')
          .toString();
    } catch (_) {
      // Ответ не разобрался — останется голый код состояния, тоже разговор.
    }
    throw Exception(code.isEmpty ? 'HTTP ${r.statusCode}' : code);
  }
}

/// Готовые ссылки. Все проверены запросом с самой станции и отдаются без
/// токена; Civitai сюда попасть не может — там для скачивания нужен личный
/// токен, и чужой в ссылке не сработает.
const List<({String title, String about, String file, String url, int size, Map<String, dynamic> note})>
    kImageModelPresets = [
  (
    title: 'Animagine XL 4.0 Opt',
    about: 'imgPresetAnime',
    file: 'animagine-xl-4.0-opt.safetensors',
    url: 'https://huggingface.co/cagliostrolab/animagine-xl-4.0/resolve/main/'
        'animagine-xl-4.0-opt.safetensors',
    size: 6938350040,
    note: {
      'prompt_style': 'tags',
      'cfg': 5.0,
      'cfg_range': '4–7',
      'steps': 28,
      'steps_range': '25–28',
      'sampler': 'euler_a',
      'sizes': [
        [1024, 1024],
        [832, 1216],
        [1216, 832],
      ],
      'quality': ['masterpiece', 'best quality', 'very aesthetic', 'absurdres'],
      'negative': 'lowres, bad anatomy, bad hands, text, error, missing '
          'fingers, extra digit, fewer digits, cropped, worst quality, low '
          'quality, low score, bad score, average score, signature, watermark, '
          'username, blurry',
      'source': 'https://huggingface.co/cagliostrolab/animagine-xl-4.0',
    },
  ),
  (
    title: 'Illustrious XL v0.1',
    about: 'imgPresetIllustrious',
    file: 'Illustrious-XL-v0.1.safetensors',
    url: 'https://huggingface.co/OnomaAIResearch/'
        'Illustrious-xl-early-release-v0/resolve/main/'
        'Illustrious-XL-v0.1.safetensors',
    size: 6938040760,
    note: {
      'prompt_style': 'tags',
      'cfg': 6.0,
      'cfg_range': '5–7.5',
      'steps': 28,
      'steps_range': '20–28',
      'sampler': 'euler_a',
      'sizes': [
        [1024, 1024],
        [832, 1216],
        [1216, 832],
      ],
      'quality': ['masterpiece', 'best quality', 'good quality'],
      'negative': 'worst quality, bad quality, lowres, bad anatomy, bad hands, '
          'text, watermark, signature, cropped',
      'source':
          'https://huggingface.co/OnomaAIResearch/Illustrious-xl-early-release-v0',
      'tip': 'Авторы просят не злоупотреблять тегами кадрирования — '
          '«close-up», «upside-down», «cowboy shot»: они конфликтуют между '
          'собой и путают модель.',
    },
  ),
  (
    title: 'Juggernaut XL v9',
    about: 'imgPresetPhoto',
    file: 'Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors',
    url: 'https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/'
        'Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors',
    size: 7105348188,
    note: {
      'prompt_style': 'words',
      'cfg': 5.0,
      'cfg_range': '3–7, ниже — реалистичнее',
      'steps': 35,
      'steps_range': '30–40',
      'sampler': 'dpmpp_2m_karras',
      'sizes': [
        [832, 1216],
        [1216, 832],
        [1024, 1024],
      ],
      'quality': ['photo', 'photorealistic', 'detailed skin', 'sharp focus'],
      'negative': 'cartoon, anime, painting, drawing, illustration, lowres, '
          'blurry, bad anatomy, extra fingers, watermark, signature',
      'source': 'https://huggingface.co/RunDiffusion/Juggernaut-XL-v9',
    },
  ),
  (
    title: 'SDXL Base 1.0',
    about: 'imgPresetBase',
    file: 'sd_xl_base_1.0.safetensors',
    url: 'https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/'
        'resolve/main/sd_xl_base_1.0.safetensors',
    size: 6938078334,
    note: {
      'prompt_style': 'words',
      'steps': 40,
      'sizes': [
        [1024, 1024],
      ],
      'source':
          'https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0',
      'tip': 'Авторы не называют ни силы подсказки, ни сэмплера — в карточке '
          'только пример на 40 шагов. Остальное оставлено на общих значениях, '
          'а не придумано за них.',
    },
  ),
];


/// Окно управления моделями генератора. Открывается и из студии, и из
/// настроек — сервер один, и второго списка заводить незачем.
class ImageModelsSheet extends StatefulWidget {
  const ImageModelsSheet({super.key, required this.app});
  final AppState app;

  @override
  State<ImageModelsSheet> createState() => _ImageModelsSheetState();
}

class _ImageModelsSheetState extends State<ImageModelsSheet> {
  AppState get app => widget.app;
  late final ImageModelsClient _c = ImageModelsClient(app.imageServerUrl);

  List<ImageModelInfo>? _items; // null — ещё спрашиваем
  String _current = '';
  int _free = 0;
  String _error = '';
  bool _busy = false;
  bool _addOpen = false;

  final _url = TextEditingController();
  final _name = TextEditingController();
  ImagePullState? _pull;
  Timer? _pullTimer;

  // Видели ли мы загрузку живой в ЭТОМ окне. Сервер помнит итог последней
  // загрузки сколько угодно долго, и без этого признака окно при открытии
  // показывало чужой давний итог — например «отменено» от загрузки, которую
  // прервали час назад и о которой человек уже не помнит.
  bool _sawPull = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Скачивание живёт на станции и переживает закрытие окна — поэтому
    // спрашиваем о нём сразу, а не только после нажатия кнопки.
    _watchPull();
  }

  @override
  void dispose() {
    _pullTimer?.cancel();
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!_c.ready) {
      setState(() {
        _items = const [];
        _error = app.t('imgModelsNoServer');
      });
      return;
    }
    try {
      var r = await _c.list();
      if (await _c.fillKnownNotes(r.items)) r = await _c.list();
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _current = r.current;
        _free = r.free;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = '$e';
      });
    }
  }

  void _watchPull() {
    _pullTimer?.cancel();
    if (!_c.ready) return;
    _pullTimer = Timer.periodic(const Duration(milliseconds: 1200), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      try {
        final p = await _c.pullState();
        if (!mounted) return;
        final wasRunning = _pull?.running ?? false;
        if (p.running) _sawPull = true;
        setState(() => _pull = p);
        // Докачалось — список пополнился, надо перечитать. И остановиться:
        // опрашивать сервер вхолостую, пока окно открыто, незачем.
        if (wasRunning && !p.running) {
          t.cancel();
          await _refresh();
        }
      } catch (_) {
        t.cancel();
      }
    });
  }

  Future<void> _act(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
      await _refresh();
    } catch (e) {
      if (mounted) showAppSnackBar(context, _explain('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Коды сервера — в человеческие фразы.
  String _explain(String raw) {
    if (raw.contains('exists')) return app.t('imgModelsErrExists');
    if (raw.contains('bad url')) return app.t('imgModelsErrUrl');
    if (raw.contains('bad name')) return app.t('imgModelsErrName');
    if (raw.contains('busy')) return app.t('imgModelsErrBusy');
    return raw.replaceFirst('Exception: ', '');
  }

  Future<void> _select(ImageModelInfo m) => _act(() async {
        await _c.select(m.name);
        app.setImageModel(m.name);
        if (mounted) showAppSnackBar(context, app.t('imgModelsSwitchHint'));
      });

  Future<void> _delete(ImageModelInfo m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: _card2(context),
        title: Text(app.t('imgModelsDelete'),
            style: TextStyle(color: _txt(context), fontSize: 16)),
        content: Text('${m.title}\n\n${app.t('imgModelsDeleteAsk')}',
            style: TextStyle(color: _body(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(app.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(app.t('delete'),
                  style: TextStyle(color: _danger(context)))),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() => _c.remove(m.name));
  }

  Future<void> _startPull(String url, String name,
          [Map<String, dynamic>? note]) =>
      _act(() async {
        await _c.pull(url, name, note: note);
        // Загрузку начали отсюда — её итог показать обязаны, даже если она
        // сорвётся раньше первого опроса и «живой» мы её не застанем.
        _sawPull = true;
        _watchPull();
      });

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Row(children: [
        Icon(Icons.layers_outlined, size: 18, color: _accent(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(app.t('imgModelsTitle'),
              style: TextStyle(color: _txt(context), fontSize: 16)),
        ),
        if (_free > 0)
          Text('${app.t('imgModelsFree')} ${formatBytes(_free)}',
              style: TextStyle(fontSize: 11.5, color: _faint(context))),
      ]),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (items == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 26),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                )
              else if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(_error,
                      style:
                          TextStyle(fontSize: 12.5, color: _danger(context))),
                )
              else if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(app.t('imgModelsEmpty'),
                      style: TextStyle(fontSize: 12.5, color: _sub(context))),
                )
              else
                for (final m in items) _modelRow(m),
              if (_pull?.running == true) _pullRow(),
              if (_sawPull &&
                  _pull != null &&
                  _pull!.error.isNotEmpty &&
                  !_pull!.cancelled &&
                  !_pull!.running)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${app.t('imgModelsPullFail')}: ${_pull!.error}',
                      style: TextStyle(fontSize: 12, color: _danger(context))),
                ),
              const SizedBox(height: 6),
              Divider(color: _stroke(context), height: 20),
              _addSection(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(app.t('close'))),
      ],
    );
  }

  Widget _modelRow(ImageModelInfo m) {
    final active = m.name == _current;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: active
            ? _accent(context).withValues(alpha: 0.10)
            : _overlayFill(context, 0.04),
        border:
            Border.all(color: active ? _accent(context) : _stroke(context)),
      ),
      child: Row(children: [
        Icon(active ? Icons.check_circle : Icons.circle_outlined,
            size: 16, color: active ? _accent(context) : _faint(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _txt(context))),
              Text('${m.name}  ·  ${formatBytes(m.size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ],
          ),
        ),
        IconButton(
          tooltip: app.t('imgNoteTitle'),
          icon: Icon(Icons.help_outline,
              size: 17,
              color: m.note == null ? _faint(context) : _accent(context)),
          onPressed: () => unawaited(showDialog<bool>(
              context: context,
              builder: (_) =>
                  ImageModelNoteSheet(app: app, model: m.name, note: m.note))),
        ),
        if (!active)
          animaGhostButton(context, app.t('imgModelsUse'), Icons.play_arrow,
              onTap: _busy ? null : () => unawaited(_select(m))),
        const SizedBox(width: 6),
        IconButton(
          tooltip: app.t('imgModelsDelete'),
          icon: Icon(Icons.delete_outline, size: 17, color: _faint(context)),
          onPressed: _busy ? null : () => unawaited(_delete(m)),
        ),
      ]),
    );
  }

  Widget _pullRow() {
    final p = _pull!;
    final v = p.total > 0 ? (p.done / p.total).clamp(0.0, 1.0) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _info(context).withValues(alpha: 0.10),
        border: Border.all(color: _info(context).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('${app.t('imgModelsPulling')}: ${p.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: _body(context))),
            ),
            Text(
                p.total > 0
                    ? '${formatBytes(p.done)} / ${formatBytes(p.total)}'
                    : formatBytes(p.done),
                style: TextStyle(fontSize: 11.5, color: _sub(context))),
            const SizedBox(width: 8),
            animaGhostButton(context, app.t('imgModelsCancel'), Icons.stop,
                onTap: () => unawaited(_act(() => _c.cancelPull()))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 4,
              backgroundColor: _stroke(context),
              valueColor: AlwaysStoppedAnimation<Color>(_info(context)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addSection() {
    final running = _pull?.running == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          animaGhostButton(
              context,
              app.t(_addOpen ? 'imgModelsAddHide' : 'imgModelsAdd'),
              _addOpen ? Icons.expand_less : Icons.download_outlined,
              onTap: () => setState(() => _addOpen = !_addOpen)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(app.t('imgModelsAddWhere'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: _faint(context))),
          ),
        ]),
        if (_addOpen) ...[
          const SizedBox(height: 10),
          Text(app.t('imgModelsReady'),
              style: TextStyle(fontSize: 12, color: _sub(context))),
          const SizedBox(height: 6),
          for (final p in kImageModelPresets) _presetRow(p, running),
          const SizedBox(height: 10),
          Text(app.t('imgModelsOwn'),
              style: TextStyle(fontSize: 12, color: _sub(context))),
          const SizedBox(height: 6),
          TextField(
            controller: _url,
            style: TextStyle(fontSize: 12.5, color: _txt(context)),
            decoration: _fieldDeco(app.t('imgModelsUrl')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            style: TextStyle(fontSize: 12.5, color: _txt(context)),
            decoration: _fieldDeco(app.t('imgModelsName')),
          ),
          const SizedBox(height: 8),
          Row(children: [
            animaGhostButton(context, app.t('imgModelsPull'), Icons.download,
                onTap: running || _busy ? null : _startOwnPull),
            const SizedBox(width: 10),
            Expanded(
              child: Text(app.t('imgModelsUrlDesc'),
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ),
          ]),
        ],
      ],
    );
  }

  void _startOwnPull() {
    final u = _url.text.trim();
    if (u.isEmpty) return;
    var n = _name.text.trim();
    if (n.isEmpty) {
      // Имя из адреса: у прямых ссылок последний кусок пути и есть имя файла.
      final segs = Uri.tryParse(u)?.pathSegments ?? const <String>[];
      n = segs.isEmpty ? '' : segs.last;
    }
    unawaited(_startPull(u, n));
  }

  Widget _presetRow(
      ({
        String title,
        String about,
        String file,
        String url,
        int size,
        Map<String, dynamic> note
      }) p,
      bool running) {
    final have = (_items ?? const []).any((m) => m.name == p.file);
    final noRoom = _free > 0 && _free < p.size;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${p.title}  ·  ${formatBytes(p.size)}',
                  style: TextStyle(fontSize: 12.5, color: _txt(context))),
              Text(app.t(p.about),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (have)
          Text(app.t('imgModelsHave'),
              style: TextStyle(fontSize: 11.5, color: _success(context)))
        else if (noRoom)
          Text(app.t('imgModelsNoRoom'),
              style: TextStyle(fontSize: 11.5, color: _warn(context)))
        else
          animaGhostButton(context, app.t('imgModelsPull'), Icons.download,
              onTap: running || _busy
                  ? null
                  : () => unawaited(_startPull(p.url, p.file, p.note))),
      ]),
    );
  }

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _faint(context), fontSize: 12.5),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: true,
        fillColor: _overlayFill(context, 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: _stroke(context)),
        ),
      );
}

/// Что авторы модели советуют ставить. Сведения не наши: они взяты из карточки
/// модели на HuggingFace и лежат на станции рядом с весами отдельным файлом —
/// приходят и уходят вместе с моделью. Если их нет, окно так и говорит, а не
/// подсовывает «общие» значения под видом авторских.
class ImageModelNoteSheet extends StatelessWidget {
  const ImageModelNoteSheet(
      {super.key, required this.app, required this.model, this.note});
  final AppState app;
  final String model;
  final Map<String, dynamic>? note;

  static const Map<String, String> samplerNames = {
    'euler_a': 'Euler a',
    'euler': 'Euler',
    'dpmpp_2m': 'DPM++ 2M',
    'dpmpp_2m_karras': 'DPM++ 2M Karras',
    'ddim': 'DDIM',
  };

  @override
  Widget build(BuildContext context) {
    final n = note;
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Row(children: [
        Icon(Icons.help_outline, size: 18, color: _accent(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(ImageModelInfo(model, 0).title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _txt(context), fontSize: 16)),
        ),
      ]),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: n == null ? _nothing(context) : _known(context, n),
        ),
      ),
      actions: [
        if (n != null)
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.t('imgNoteApply'))),
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(app.t('close'))),
      ],
    );
  }

  Widget _nothing(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.t('imgNoteNone'),
                style: TextStyle(fontSize: 12.5, color: _body(context))),
            const SizedBox(height: 10),
            Text(app.t('imgNoteWhere'),
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
          ],
        ),
      );

  Widget _known(BuildContext context, Map<String, dynamic> n) {
    final rows = <Widget>[];

    void add(String label, String value) {
      if (value.trim().isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: _sub(context))),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 12.5, color: _txt(context))),
          ),
        ]),
      ));
    }

    final style = (n['prompt_style'] ?? '').toString();
    if (style.isNotEmpty) {
      add(app.t('imgNoteStyle'),
          app.t(style == 'tags' ? 'imgNoteStyleTags' : 'imgNoteStyleWords'));
    }
    final cfg = (n['cfg'] as num?)?.toDouble();
    final cfgRange = (n['cfg_range'] ?? '').toString();
    if (cfg != null || cfgRange.isNotEmpty) {
      add(app.t('studioCfg'),
          [
            if (cfg != null) _num(cfg),
            if (cfgRange.isNotEmpty) '($cfgRange)',
          ].join(' '));
    }
    final steps = (n['steps'] as num?)?.toInt();
    final stepsRange = (n['steps_range'] ?? '').toString();
    if (steps != null || stepsRange.isNotEmpty) {
      add(app.t('studioSteps'),
          [
            if (steps != null) '$steps',
            if (stepsRange.isNotEmpty) '($stepsRange)',
          ].join(' '));
    }
    final sampler = (n['sampler'] ?? '').toString();
    if (sampler.isNotEmpty) {
      add(app.t('studioSampler'), samplerNames[sampler] ?? sampler);
    }
    final sizes = n['sizes'];
    if (sizes is List && sizes.isNotEmpty) {
      add(
          app.t('studioSize'),
          sizes
              .whereType<List>()
              .where((s) => s.length >= 2)
              .map((s) => '${s[0]}x${s[1]}')
              .join(',  '));
    }
    final quality = n['quality'];
    if (quality is List && quality.isNotEmpty) {
      add(app.t('imgNoteQuality'), quality.join(', '));
    }
    final neg = (n['negative'] ?? '').toString();
    if (neg.isNotEmpty) add(app.t('studioNegative'), neg);

    final tip = (n['tip'] ?? '').toString();
    final source = (n['source'] ?? '').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...rows,
        if (tip.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(tip, style: TextStyle(fontSize: 12, color: _body(context))),
        ],
        const SizedBox(height: 12),
        Text(
            source.isEmpty
                ? app.t('imgNoteWhere')
                : '${app.t('imgNoteFrom')} $source',
            style: TextStyle(fontSize: 11, color: _faint(context))),
      ],
    );
  }

  /// 5.0 показываем как «5», 7.5 — как «7.5».
  String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

// --- довески LoRA ----------------------------------------------------------

/// Довесок на диске станции.
class ImageLoraInfo {
  const ImageLoraInfo(this.name, this.size);
  final String name;
  final int size;

  String get title => ImageModelInfo(name, 0).title;
}

/// Один включённый довесок с его весом.
typedef ImageLoraPick = ({String name, double weight});

/// Разбор и сборка набора довесков для хранения в настройках. Формат — тот же
/// JSON, что уходит на сервер: второго представления не заводим, чтобы не
/// пришлось держать их в согласии.
List<ImageLoraPick> decodeLoraPicks(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map && (e['name'] ?? '').toString().isNotEmpty)
          (
            name: e['name'].toString(),
            weight: (e['weight'] as num?)?.toDouble() ?? 1.0,
          ),
    ];
  } catch (_) {
    return const [];
  }
}

String encodeLoraPicks(List<ImageLoraPick> picks) => jsonEncode([
      for (final p in picks) {'name': p.name, 'weight': p.weight},
    ]);

/// Окно довесков: что лежит на станции, что включено и с каким весом.
class ImageLorasSheet extends StatefulWidget {
  const ImageLorasSheet({super.key, required this.app, required this.picked});
  final AppState app;
  final List<ImageLoraPick> picked;

  @override
  State<ImageLorasSheet> createState() => _ImageLorasSheetState();
}

class _ImageLorasSheetState extends State<ImageLorasSheet> {
  AppState get app => widget.app;
  late final ImageModelsClient _c = ImageModelsClient(app.imageServerUrl);

  List<ImageLoraInfo>? _items;
  late List<ImageLoraPick> _picked = List.of(widget.picked);
  int _free = 0;
  String _error = '';
  bool _busy = false;
  bool _addOpen = false;

  final _url = TextEditingController();
  final _name = TextEditingController();
  ImagePullState? _pull;
  Timer? _pullTimer;
  bool _sawPull = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _watchPull();
  }

  @override
  void dispose() {
    _pullTimer?.cancel();
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!_c.ready) {
      setState(() {
        _items = const [];
        _error = app.t('imgModelsNoServer');
      });
      return;
    }
    try {
      final r = await _c.loras();
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _free = r.free;
        _error = '';
        // Довесок могли удалить с другой машины — держать его включённым
        // значит обещать то, чего на станции уже нет.
        _picked = _picked
            .where((p) => r.items.any((i) => i.name == p.name))
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = '$e';
      });
    }
  }

  void _watchPull() {
    _pullTimer?.cancel();
    if (!_c.ready) return;
    _pullTimer = Timer.periodic(const Duration(milliseconds: 1200), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      try {
        final p = await _c.pullState();
        if (!mounted) return;
        final was = _pull?.running ?? false;
        if (p.running) _sawPull = true;
        setState(() => _pull = p);
        if (was && !p.running) {
          t.cancel();
          await _refresh();
        }
      } catch (_) {
        t.cancel();
      }
    });
  }

  Future<void> _act(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
      await _refresh();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '$e'.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _on(String name) => _picked.any((p) => p.name == name);

  double _weight(String name) =>
      _picked.firstWhere((p) => p.name == name,
          orElse: () => (name: name, weight: 0.8)).weight;

  void _toggle(ImageLoraInfo m) {
    setState(() {
      if (_on(m.name)) {
        _picked.removeWhere((p) => p.name == m.name);
      } else {
        _picked.add((name: m.name, weight: 0.8));
      }
    });
  }

  void _setWeight(String name, double v) {
    setState(() {
      final i = _picked.indexWhere((p) => p.name == name);
      if (i >= 0) _picked[i] = (name: name, weight: v);
    });
  }

  Future<void> _delete(ImageLoraInfo m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: _card2(context),
        title: Text(app.t('imgLoraDelete'),
            style: TextStyle(color: _txt(context), fontSize: 16)),
        content: Text('${m.title}\n\n${app.t('imgLoraDeleteAsk')}',
            style: TextStyle(color: _body(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(app.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(app.t('delete'),
                  style: TextStyle(color: _danger(context)))),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() async {
      await _c.deleteLora(m.name);
      _picked.removeWhere((p) => p.name == m.name);
      // Сразу, а не по «Применить»: удаление — не черновик, и файла на станции
      // уже нет. Останься он в настройках — каждая следующая генерация падала
      // бы с «нет довеска».
      app.setImageLoras(encodeLoraPicks(_picked));
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Row(children: [
        Icon(Icons.extension_outlined, size: 18, color: _accent(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(app.t('imgLorasTitle'),
              style: TextStyle(color: _txt(context), fontSize: 16)),
        ),
        if (_free > 0)
          Text('${app.t('imgModelsFree')} ${formatBytes(_free)}',
              style: TextStyle(fontSize: 11.5, color: _faint(context))),
      ]),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(app.t('imgLorasWhat'),
                    style: TextStyle(fontSize: 11.5, color: _faint(context))),
              ),
              if (items == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 26),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                )
              else if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(_error,
                      style:
                          TextStyle(fontSize: 12.5, color: _danger(context))),
                )
              else if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(app.t('imgLorasEmpty'),
                      style: TextStyle(fontSize: 12.5, color: _sub(context))),
                )
              else
                for (final m in items) _loraRow(m),
              if (_pull?.running == true) _pullRow(),
              if (_sawPull &&
                  _pull != null &&
                  _pull!.error.isNotEmpty &&
                  !_pull!.cancelled &&
                  !_pull!.running)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${app.t('imgModelsPullFail')}: ${_pull!.error}',
                      style: TextStyle(fontSize: 12, color: _danger(context))),
                ),
              const SizedBox(height: 6),
              Divider(color: _stroke(context), height: 20),
              _addSection(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, widget.picked),
            child: Text(app.t('cancel'))),
        TextButton(
            onPressed: () => Navigator.pop(context, _picked),
            child: Text(app.t('apply'))),
      ],
    );
  }

  Widget _loraRow(ImageLoraInfo m) {
    final on = _on(m.name);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: on
            ? _accent(context).withValues(alpha: 0.10)
            : _overlayFill(context, 0.04),
        border: Border.all(color: on ? _accent(context) : _stroke(context)),
      ),
      child: Column(
        children: [
          Row(children: [
            InkWell(
              onTap: () => _toggle(m),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                    on ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                    color: on ? _accent(context) : _faint(context)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _txt(context))),
                  Text('${m.name}  ·  ${formatBytes(m.size)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: _faint(context))),
                ],
              ),
            ),
            IconButton(
              tooltip: app.t('imgLoraDelete'),
              icon: Icon(Icons.delete_outline, size: 17, color: _faint(context)),
              onPressed: _busy ? null : () => unawaited(_delete(m)),
            ),
          ]),
          if (on)
            Row(children: [
              SizedBox(
                width: 62,
                child: Text(app.t('imgLoraWeight'),
                    style: TextStyle(fontSize: 11.5, color: _sub(context))),
              ),
              Expanded(
                child: Slider(
                  value: _weight(m.name).clamp(0.0, 1.5),
                  min: 0,
                  max: 1.5,
                  divisions: 30,
                  activeColor: _accent(context),
                  onChanged: (v) => _setWeight(m.name, v),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(_weight(m.name).toStringAsFixed(2),
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11.5, color: _txt(context))),
              ),
            ]),
        ],
      ),
    );
  }

  Widget _pullRow() {
    final p = _pull!;
    final v = p.total > 0 ? (p.done / p.total).clamp(0.0, 1.0) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _info(context).withValues(alpha: 0.10),
        border: Border.all(color: _info(context).withValues(alpha: 0.4)),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Text('${app.t('imgModelsPulling')}: ${p.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: _body(context))),
          ),
          Text(
              p.total > 0
                  ? '${formatBytes(p.done)} / ${formatBytes(p.total)}'
                  : formatBytes(p.done),
              style: TextStyle(fontSize: 11.5, color: _sub(context))),
          const SizedBox(width: 8),
          animaGhostButton(context, app.t('imgModelsCancel'), Icons.stop,
              onTap: () => unawaited(_act(() => _c.cancelPull()))),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: v,
            minHeight: 4,
            backgroundColor: _stroke(context),
            valueColor: AlwaysStoppedAnimation<Color>(_info(context)),
          ),
        ),
      ]),
    );
  }

  Widget _addSection() {
    final running = _pull?.running == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          animaGhostButton(
              context,
              app.t(_addOpen ? 'imgModelsAddHide' : 'imgLoraAdd'),
              _addOpen ? Icons.expand_less : Icons.download_outlined,
              onTap: () => setState(() => _addOpen = !_addOpen)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(app.t('imgLoraWhere'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: _faint(context))),
          ),
        ]),
        if (_addOpen) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _url,
            style: TextStyle(fontSize: 12.5, color: _txt(context)),
            decoration: _fieldDeco(app.t('imgModelsUrl')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            style: TextStyle(fontSize: 12.5, color: _txt(context)),
            decoration: _fieldDeco(app.t('imgModelsName')),
          ),
          const SizedBox(height: 8),
          Row(children: [
            animaGhostButton(context, app.t('imgModelsPull'), Icons.download,
                onTap: running || _busy ? null : _startPull),
            const SizedBox(width: 10),
            Expanded(
              child: Text(app.t('imgLoraUrlDesc'),
                  style: TextStyle(fontSize: 11, color: _faint(context))),
            ),
          ]),
        ],
      ],
    );
  }

  void _startPull() {
    final u = _url.text.trim();
    if (u.isEmpty) return;
    var n = _name.text.trim();
    if (n.isEmpty) {
      final segs = Uri.tryParse(u)?.pathSegments ?? const <String>[];
      n = segs.isEmpty ? '' : segs.last;
    }
    unawaited(_act(() async {
      await _c.pullLora(u, n);
      _sawPull = true;
      _watchPull();
    }));
  }

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _faint(context), fontSize: 12.5),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: true,
        fillColor: _overlayFill(context, 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: _stroke(context)),
        ),
      );
}
