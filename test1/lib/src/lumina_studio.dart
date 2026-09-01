part of '../main.dart';

// «Nexus Lumina» — вид генератора картинок по присланному макету.
//
// От прежней студии отличается только раскладкой: слева рейка разделов, справа
// панель настроек, посередине холст, внизу строка запроса. Ни одной новой
// возможности здесь не заводится — всё, что тут есть, уже работало в
// `StudioPanel`, просто было свалено в одну колонку под строкой ввода. Смысл
// перекладки в том, что настройки генерации перестают конкурировать за место
// с результатами: там их девять групп, и в узкой колонке они выталкивали
// картинки за нижний край.
//
// Цвета — только через токены темы, как и везде в проекте: макет светлый, но
// приложение живёт в четырёх темах, и прибивать его палитру гвоздями значило бы
// сломать три из них.
enum LuminaTab { create, gallery }

class LuminaStudio extends StatefulWidget {
  const LuminaStudio({super.key, this.embedded = false});

  /// Студия открыта ВНУТРИ оболочки, а не отдельным окном. Тогда своя полоса
  /// заголовка и своя заливка фона не нужны — их уже нарисовала оболочка, и
  /// вторая пара выглядела бы окном в окне. Умолчание оставляет прежний вид,
  /// поэтому три остальных стиля не меняются.
  final bool embedded;

  @override
  State<LuminaStudio> createState() => _LuminaStudioState();
}

/// Одна работа в очереди: что просили, с какими настройками и что вышло.
///
/// Настройки лежат ЗДЕСЬ, а не читаются из окна в момент счёта: пока станция
/// считает первый кадр, человек уже правит размер и стиль под второй, и
/// заглядывать в окно означало бы посчитать первый кадр чужими настройками.
class _LuminaJob {
  _LuminaJob({required this.prompt, required this.body});
  final String prompt;
  final Map<String, dynamic> body;
  String? path;
  String? error;
  bool running = false;
  bool done = false;
}

class _LuminaStudioState extends State<LuminaStudio> {
  final _prompt = TextEditingController();
  final _negative = TextEditingController();
  final _scroll = ScrollController();
  final List<_LuminaJob> _items = [];
  // Крутится ли сейчас разбор очереди. Не то же самое, что «идёт кадр»:
  // разбор живёт, пока в очереди есть хоть одна несделанная работа.
  bool _pumping = false;

  LuminaTab _tab = LuminaTab.create;
  bool _busy = false;

  int get _waiting =>
      _items.where((j) => !j.done && !j.running).length;

  // Настройки кадра. Те же, что были в прежней студии, и с тем же смыслом.
  int _imgW = 1024;
  int _imgH = 1024;
  int _steps = 28;
  double _cfg = 5;
  String _sampler = 'euler_a';
  double _face = 0.4;
  double _hires = 0;

  String _model = '';
  bool _modelDistilled = false;
  Map<String, dynamic>? _modelNote;
  List<ImageLoraPick> _loras = const [];

  (int, int) _progress = (0, 0);
  Timer? _progressTimer;

  // Галерея: то, что уже лежит на диске. Читается с диска, а не из ленты —
  // лента живёт одну сессию, а файлы остаются.
  List<io.File>? _gallery;

  bool get _negativeWorks => !_modelDistilled && _cfg > 1;

  // Родные размеры кадра. Все девять названы авторами модели; произвольные
  // пропорции дают вытянутые лица и лишние руки, потому список закрытый.
  static const List<(int, int, String)> _sizes = [
    (1024, 1024, '1:1'),
    (896, 1152, '7:9'),
    (832, 1216, '2:3'),
    (768, 1344, '4:7'),
    (1152, 896, '9:7'),
    (1216, 832, '3:2'),
    (1344, 768, '7:4'),
  ];

  // Подсказки для запроса — в том порядке, которому обучена модель: кто в
  // кадре, рейтинг, место, свет, год, и В КОНЦЕ качество и оценки.
  static const List<(String, List<String>)> _hints = [
    ('studioHintSubject', [
      '1girl', '1boy', 'solo', 'looking at viewer', 'portrait', 'close-up',
      'face focus', 'upper body', 'full body'
    ]),
    ('studioHintRating', ['safe', 'sensitive']),
    ('studioHintScene', [
      'city', 'indoors', 'outdoors', 'forest', 'cyberpunk',
      'detailed background'
    ]),
    ('studioHintLight', [
      'night', 'day', 'sunset', 'neon lights', 'backlighting',
      'depth of field'
    ]),
    ('studioHintYear', ['year 2010', 'year 2018', 'year 2024']),
    ('studioHintQuality',
        ['masterpiece', 'best quality', 'absurdres', 'very aesthetic']),
    ('studioHintScore', ['high score', 'great score', 'good score']),
  ];

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    // Видеокарта на станции одна, и языковая модель на ней не помещается рядом
    // с генератором. Освобождаем на время работы окна; возврат — в dispose().
    unawaited(GpuArbiter.instance.takeForImages(app));
    _loras = decodeLoraPicks(app.imageLoras);
    _face = app.imageFacePass;
    _hires = app.imageHires;
    unawaited(_loadModels());
    // Каталог читаем сразу: в «Призме» история стоит на экране всегда, а не
    // за вкладкой, и пустая сетка при открытии выглядела бы как «ничего нет».
    unawaited(_loadGallery());
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _prompt.dispose();
    _negative.dispose();
    _scroll.dispose();
    unawaited(GpuArbiter.instance.release());
    super.dispose();
  }

  // --- данные ---------------------------------------------------------------

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
      await _syncLoras(app, c);
    } catch (_) {
      // Сервер недоступен или старой версии — строка модели просто не появится.
    }
  }

  /// Выкинуть из выбора довески, которых на станции больше нет.
  ///
  /// Без этого удалённый на станции довесок остаётся в настройках приложения и
  /// уходит в КАЖДЫЙ запрос: сервер честно отвечает «нет довеска», генерация
  /// падает, и так до тех пор, пока человек сам не догадается открыть окно
  /// довесков. Отказ при этом выглядит необъяснимым — довеска он уже не видит.
  Future<void> _syncLoras(AppState app, ImageModelsClient c) async {
    if (_loras.isEmpty) return;
    try {
      final r = await c.loras();
      final alive =
          _loras.where((p) => r.items.any((i) => i.name == p.name)).toList();
      if (alive.length == _loras.length || !mounted) return;
      setState(() => _loras = alive);
      app.setImageLoras(encodeLoraPicks(alive));
    } catch (_) {
      // Сервер не ответил — оставляем как есть, сверимся при следующем заходе.
    }
  }

  Future<String> _studioDir() async {
    final root = await appDataRoot();
    final dir = io.Directory('$root${io.Platform.pathSeparator}studio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> _loadGallery() async {
    try {
      final dir = io.Directory(await _studioDir());
      final files = await dir
          .list()
          .where((e) => e is io.File && e.path.toLowerCase().endsWith('.png'))
          .cast<io.File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      if (mounted) setState(() => _gallery = files);
    } catch (_) {
      if (mounted) setState(() => _gallery = const []);
    }
  }

  // --- генерация ------------------------------------------------------------

  void _watchProgress(AppState app) {
    _progressTimer?.cancel();
    final url = app.imageServerUrl.trim();
    if (url.isEmpty) return;
    _progressTimer =
        Timer.periodic(const Duration(milliseconds: 900), (t) async {
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
        setState(() => _progress = (
              (j['step'] as num?)?.toInt() ?? 0,
              (j['total'] as num?)?.toInt() ?? 0,
            ));
      } catch (_) {
        // Сервер старой версии — просто не показываем шкалу.
      }
    });
  }

  /// Снимок настроек на момент отправки — то, что уедет на станцию.
  Map<String, dynamic> _bodyFor(AppState app, String prompt) => {
        'prompt': prompt,
        // Тем же именем, что и заявка на карту под разговор: свою заявку
        // ждать не надо, а чужую — надо.
        'who': 'desktop',
        'model': _model.isNotEmpty ? _model : app.imageModel,
        'steps': _steps,
        'width': _imgW,
        'height': _imgH,
        'cfg': _cfg,
        'sampler': _sampler,
        if (_face > 0) 'face': _face,
        if (_hires > 0) 'hires': _hires,
        if (_negativeWorks && _negative.text.trim().isNotEmpty)
          'negative': _negative.text.trim(),
        if (_loras.isNotEmpty)
          'loras': [
            for (final l in _loras) {'name': l.name, 'weight': l.weight},
          ],
      };

  /// Поставить работу в очередь. Поле сразу освобождается: пока станция
  /// считает, можно набрать следующий запрос и поменять под него настройки.
  Future<void> _submit() async {
    final app = context.read<AppState>();
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _items.add(_LuminaJob(prompt: text, body: _bodyFor(app, text)));
      _prompt.clear();
      _tab = LuminaTab.create;
    });
    _scrollDown();
    await _pump(app);
  }

  /// Разбор очереди — по одной работе за раз. Карта на станции одна, и второй
  /// одновременный запрос всё равно встал бы там в очередь; здесь очередь
  /// видна человеку и её можно разобрать.
  Future<void> _pump(AppState app) async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (mounted) {
        final job =
            _items.where((j) => !j.done && !j.running).firstOrNull;
        if (job == null) break;
        setState(() {
          job.running = true;
          _busy = true;
        });
        _watchProgress(app);
        try {
          job.path = await _send(app, job);
        } catch (e) {
          // Довесок могли удалить с другой машины уже после отправки. Разбирать
          // это руками человеку незачем: выкидываем пропавший из выбора и из
          // самой работы и считаем ещё раз — один раз, чтобы отказ не стал
          // петлёй.
          if ('$e'.contains('нет довеска') &&
              await _dropMissingLoras(app, job)) {
            try {
              job.path = await _send(app, job);
            } catch (e2) {
              job.error = '$e2';
            }
          } else {
            job.error = '$e';
          }
        } finally {
          job.running = false;
          job.done = true;
          _progressTimer?.cancel();
          // Свежий кадр должен появиться в истории сам: она читается с диска,
          // а не из ленты, и без этого отставала бы на одну работу.
          unawaited(_loadGallery());
          if (mounted) {
            setState(() {
              _busy = _items.any((j) => !j.done);
              _progress = (0, 0);
            });
          }
          _scrollDown();
        }
      }
    } finally {
      _pumping = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Убрать из работы довески, которых на станции больше нет. Возвращает
  /// true, если что-то убрали и повтор имеет смысл.
  ///
  /// Убираем ПОИМЁННО, а не весь набор: если из двух довесков исчез один,
  /// второй ни в чём не виноват, и терять его — значит посчитать не то, о чём
  /// просили.
  Future<bool> _dropMissingLoras(AppState app, _LuminaJob job) async {
    final picked = job.body['loras'];
    if (picked is! List || picked.isEmpty) return false;
    try {
      final c = ImageModelsClient(app.imageServerUrl);
      final r = await c.loras();
      final alive = picked
          .where((e) =>
              e is Map && r.items.any((i) => i.name == (e['name'] ?? '')))
          .toList();
      if (alive.length == picked.length) return false;
      if (alive.isEmpty) {
        job.body.remove('loras');
      } else {
        job.body['loras'] = alive;
      }
      await _syncLoras(app, c);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _send(AppState app, _LuminaJob job) async {
    final url = app.imageServerUrl.trim();
    if (url.isEmpty) throw Exception(app.t('studioNoServer'));
    final res = await http
        .post(Uri.parse('$url/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(job.body))
        .timeout(const Duration(minutes: 20));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final dir = await _studioDir();
    final name = 'img-${DateTime.now().millisecondsSinceEpoch}.png';
    final file = io.File('$dir${io.Platform.pathSeparator}$name');
    await file.writeAsBytes(res.bodyBytes);
    return file.path;
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    });
  }

  void _appendTag(String tag) {
    final t = _prompt.text.trimRight();
    final sep = t.isEmpty ? '' : (t.endsWith(',') ? ' ' : ', ');
    _prompt.text = '$t$sep$tag';
    _prompt.selection =
        TextSelection.collapsed(offset: _prompt.text.length);
    setState(() {});
  }

  Future<void> _drop(_LuminaJob it) async {
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

  void _reveal(String path) => unawaited(io.Process.start(
      'explorer.exe', ['/select,$path'],
      runInShell: false));

  // --- сборка ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // «Призма» раскладывает студию по макету: параметры слева, холст справа.
    // Полосу заголовка и предупреждение о карте там рисует сама оболочка.
    if (_isPrism(context) && widget.embedded) return _prismLumina(app);
    final body = Column(children: [
      if (!widget.embedded) const _WindowTitleBar(),
      const GpuNoticeBar(),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _rail(app),
          // Промежуток только в «Призме»: там области — отдельные плитки, и без
          // зазора они слипаются в одну. В остальных стилях их разделяет линия,
          // и лишний воздух разорвал бы сплошную плоскость окна.
          if (_isPrism(context)) const SizedBox(width: 16),
          Expanded(
            child: evsStudioPane(
              context,
              padding: EdgeInsets.zero,
              child: _centre(app),
            ),
          ),
          if (_isPrism(context)) const SizedBox(width: 16),
          _params(app),
        ]),
      ),
    ]);
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: _bg(context),
      body: evsShellBackdrop(context, body),
    );
  }

  // ------------------------------------------------------------------------
  // «ПРИЗМА» — раскладка макета
  // ------------------------------------------------------------------------

  /// Экран Nexus Lumina из прототипа: слева панель параметров на 404px, справа
  /// холст и история сеткой по четыре.
  ///
  /// Поля, очередь и вся работа — те же, что у остальных стилей: `_prompt`,
  /// `_negative`, `_steps`, `_cfg`, `_submit`, `_pump`. Отличается только
  /// расстановка, поэтому новая кнопка в этой панели сразу работает везде.
  ///
  /// Чего в макете нет, а здесь есть: сэмплер, второй проход по лицу,
  /// увеличение, модель и довески. Всё это уже было у студии, и выкидывать
  /// рабочие настройки ради сходства с картинкой — плохой обмен; они лежат в
  /// той же панели, ниже, тем же видом.
  Widget _prismLumina(AppState app) {
    // Что показывает холст. Пока станция считает — ход работы; когда посчитала
    // — последний готовый кадр.
    _LuminaJob? busy;
    _LuminaJob? last;
    for (final j in _items) {
      if (j.running) busy = j;
      if (j.done) last = j;
    }
    final image = busy == null && last?.path != null
        ? io.File(last!.path!)
        : null;
    final error = busy == null ? last?.error : null;

    final steps = _progress.$2;
    final state = busy != null
        ? (steps > 0
            ? '${app.t('studioWorking')} · ${_progress.$1}/$steps'
            : app.t('studioWorking'))
        : last?.path != null
            ? '${app.t('prismGenDone')} · '
                '${last!.body['width']}×${last.body['height']}'
            : _waiting > 0
                ? '${app.t('luminaQueue')}: $_waiting'
                : app.t('prismGenIdle');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 404, child: _prismParams(app)),
        const SizedBox(width: 18),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PrismPanel(
                  radius: 26,
                  padding: const EdgeInsets.all(14),
                  shadow: true,
                  child: PrismCanvasFrame(
                    state: state,
                    progress: busy != null && steps > 0
                        ? _progress.$1 / steps
                        : 0,
                    hint: app.t('prismCanvasHint'),
                    image: image,
                    error: error,
                    actions: image == null
                        ? const []
                        : [
                            PrismCanvasPill(
                              label: app.t('studioOpen'),
                              primary: true,
                              onTap: () => _reveal(last!.path!),
                            ),
                            PrismCanvasPill(
                              label: app.t('studioDrop'),
                              danger: true,
                              onTap: () => unawaited(_drop(last!)),
                            ),
                          ],
                  ),
                ),
                const SizedBox(height: 16),
                PrismPanel(
                  radius: 26,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  shadow: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          PrismSectionLabel(app.t('prismHistory')),
                          const Spacer(),
                          if (_gallery != null)
                            Text('${_gallery!.length}',
                                style: PrismType.numeric.copyWith(
                                    color: _faint(context), fontSize: 11)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      PrismHistoryGrid(
                        files: _gallery,
                        onOpen: (f) => _reveal(f.path),
                        onDelete: (f) async {
                          try {
                            await f.delete();
                          } catch (_) {
                            // Уже удалён — просто перечитаем каталог.
                          }
                          await _loadGallery();
                        },
                      ),
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

  /// Левая панель: описание, исключения, ползунки, разрешение и остальные
  /// настройки, а внизу кнопка. Порядок первых пяти блоков — из макета.
  Widget _prismParams(AppState app) {
    return PrismPanel(
      radius: 26,
      // Справа поля меньше на дорожку полосы прокрутки — она рисуется у
      // правого края области прокрутки ПОВЕРХ содержимого, и без этой полосы
      // ложилась прямо на подписи. Сумма отступов справа осталась прежней.
      padding: const EdgeInsets.fromLTRB(22, 22, 8, 22),
      shadow: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(right: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PrismSectionLabel(app.t('prismDescribe'), size: 10.5),
            const SizedBox(height: 8),
            PrismField(
              controller: _prompt,
              hint: app.t('studioPrompt'),
              lines: 4,
              radius: 18,
              fontSize: 13.5,
              onSubmitted: (_) => unawaited(_submit()),
            ),
            const SizedBox(height: 16),
            PrismSectionLabel(app.t('prismExclude'), size: 10.5),
            const SizedBox(height: 8),
            // Негативный запрос действует только когда модель сравнивает кадр
            // с ним. У ускоренных моделей сила равна единице по устройству —
            // поле гасится, а не делает вид, что работает.
            Opacity(
              opacity: _negativeWorks ? 1 : 0.45,
              child: PrismField(
                controller: _negative,
                hint: app.t('studioNegative'),
                enabled: _negativeWorks,
                radius: 16,
                fontSize: 13,
              ),
            ),
            if (!_negativeWorks) ...[
              const SizedBox(height: 6),
              Text(
                app.t(_modelDistilled
                    ? 'studioNegativeDistilled'
                    : 'studioNegativeOffCfg'),
                style: PrismType.caption
                    .copyWith(fontSize: 11, color: _warn(context)),
              ),
            ],
            const SizedBox(height: 18),
            PrismLabeledSlider(
              label: app.t('prismStepsLabel'),
              display: '$_steps',
              value: _steps.toDouble(),
              min: 10,
              max: 60,
              step: 1,
              onChanged: (v) => setState(() => _steps = v.round()),
            ),
            const SizedBox(height: 16),
            PrismLabeledSlider(
              label: app.t('prismCfgLabel'),
              display: _cfg.toStringAsFixed(1),
              value: _cfg,
              min: 1,
              max: 14,
              step: 0.5,
              onChanged: (v) => setState(() => _cfg = v),
            ),
            const SizedBox(height: 18),
            PrismSectionLabel(app.t('prismResolution'), size: 10.5),
            const SizedBox(height: 9),
            PrismChoiceChips<(int, int)>(
              options: [
                for (final s in _sizes) ((s.$1, s.$2), '${s.$1}×${s.$2}'),
              ],
              value: (_imgW, _imgH),
              onChanged: (v) => setState(() {
                _imgW = v.$1;
                _imgH = v.$2;
              }),
            ),
            const SizedBox(height: 18),
            PrismSectionLabel(app.t('studioSampler'), size: 10.5),
            const SizedBox(height: 9),
            PrismChoiceChips<String>(
              perRow: 2,
              mono: false,
              options: const [
                ('euler_a', 'Euler a'),
                ('euler', 'Euler'),
                ('dpmpp_2m', 'DPM++ 2M'),
                ('dpmpp_2m_karras', 'DPM++ 2M K'),
              ],
              value: _sampler,
              onChanged: (v) => setState(() => _sampler = v),
            ),
            const SizedBox(height: 18),
            PrismSectionLabel(app.t('studioFace'), size: 10.5),
            const SizedBox(height: 9),
            PrismChoiceChips<double>(
              perRow: 4,
              options: [
                (0.0, app.t('studioFaceOff')),
                (0.3, '0.3'),
                (0.4, '0.4'),
                (0.5, '0.5'),
              ],
              value: _face,
              onChanged: (v) {
                setState(() => _face = v);
                app.setImageFacePass(v);
              },
            ),
            const SizedBox(height: 18),
            PrismSectionLabel(app.t('studioHires'), size: 10.5),
            const SizedBox(height: 9),
            PrismChoiceChips<double>(
              perRow: 3,
              options: [
                (0.0, app.t('studioFaceOff')),
                (1.5, '1.5×'),
                (2.0, '2×'),
              ],
              value: _hires,
              onChanged: (v) {
                setState(() => _hires = v);
                app.setImageHires(v);
              },
            ),
            const SizedBox(height: 18),
            PrismSectionLabel(app.t('studioModel'), size: 10.5),
            const SizedBox(height: 9),
            _prismPickRow(
              _model.isEmpty
                  ? app.t('studioModelUnknown')
                  : ImageModelInfo(_model, 0).title,
              () => unawaited(_openModels(app)),
            ),
            const SizedBox(height: 16),
            PrismSectionLabel(app.t('imgLorasTitle'), size: 10.5),
            const SizedBox(height: 9),
            _prismPickRow(
              _loras.isEmpty
                  ? app.t('imgLoraNone')
                  : _loras
                      .map((l) =>
                          '${ImageModelInfo(l.name, 0).title} ×${l.weight.toStringAsFixed(2)}')
                      .join(', '),
              () => unawaited(_openLoras(app)),
            ),
            const SizedBox(height: 20),
            PrismGradientButton(
              label: app.t('studioGo'),
              d: PrismIcons.spark,
              radius: 18,
              fontSize: 14.5,
              expand: true,
              padding: const EdgeInsets.symmetric(vertical: 15),
              // Пока станция считает, кнопка живая: работы встают в очередь,
              // и это единственный способ поставить вторую.
              onTap: () => unawaited(_submit()),
            ),
            if (_waiting > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${app.t('luminaQueue')}: $_waiting',
                textAlign: TextAlign.center,
                style: PrismType.numeric
                    .copyWith(color: _faint(context), fontSize: 10.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Строка выбора: значение слева, шеврон справа. Так в макете выглядит
  /// выбор голоса; здесь тем же видом открываются модель и довески.
  Widget _prismPickRow(String value, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: _prismField(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _stroke(context)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: PrismType.label
                      .copyWith(color: _body(context), fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 8),
              PrismIcon(PrismIcons.chevronDown,
                  size: 13, stroke: 2.2, color: _faint(context)),
            ],
          ),
        ),
      ),
    );
  }

  // Рейка разделов. Узкая и всегда на виду: переключение между «создать» и
  // «галереей» — самое частое движение в этом окне.
  Widget _rail(AppState app) {
    return evsStudioPane(
      context,
      width: 208,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      right: BorderSide(color: _stroke(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.auto_awesome, size: 18, color: _accent(context)),
          const SizedBox(width: 9),
          Text('Nexus Lumina',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _txt(context))),
        ]),
        const SizedBox(height: 22),
        _railItem(app, Icons.auto_fix_high, 'luminaCreate',
            _tab == LuminaTab.create, () => setState(() => _tab = LuminaTab.create)),
        _railItem(app, Icons.photo_library_outlined, 'luminaGallery',
            _tab == LuminaTab.gallery, () {
          setState(() => _tab = LuminaTab.gallery);
          unawaited(_loadGallery());
        }),
        const SizedBox(height: 8),
        Divider(color: _stroke(context), height: 18),
        _railAction(app, Icons.layers_outlined, 'studioModelManage',
            () => unawaited(_openModels(app))),
        _railAction(app, Icons.extension_outlined, 'imgLorasTitle',
            () => unawaited(_openLoras(app))),
        _railAction(app, Icons.help_outline, 'imgNoteTitle',
            () => unawaited(_openNote(app))),
        const Spacer(),
        // Что сейчас считает. Не украшение: модель влияет на результат сильнее
        // любого переключателя справа.
        Text(app.t('studioModel').toUpperCase(),
            style: TextStyle(
                fontSize: 10, letterSpacing: 0.6, color: _faint(context))),
        const SizedBox(height: 4),
        Text(
            _model.isEmpty
                ? app.t('studioModelUnknown')
                : ImageModelInfo(_model, 0).title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: _txt(context))),
        // Внутри оболочки закрывать нечего — студия там вкладка, а не окно,
        // и кнопка либо не сработала бы, либо схлопнула бы всю оболочку.
        if (!widget.embedded) ...[
          const SizedBox(height: 10),
          evsGhostButton(context, app.t('close'), Icons.close,
              onTap: () => Navigator.of(context).maybePop()),
        ],
      ]),
    );
  }

  Widget _railItem(AppState app, IconData icon, String key, bool active,
      VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: active
                ? _accent(context).withValues(alpha: 0.14)
                : Colors.transparent,
          ),
          child: Row(children: [
            Icon(icon,
                size: 17,
                color: active ? _accent(context) : _faint(context)),
            const SizedBox(width: 10),
            Text(app.t(key),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? _accent(context) : _body(context))),
          ]),
        ),
      ),
    );
  }

  Widget _railAction(
          AppState app, IconData icon, String key, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 16, color: _faint(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(app.t(key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: _sub(context))),
              ),
            ]),
          ),
        ),
      );

  Widget _centre(AppState app) {
    return Column(children: [
      Expanded(
        child: _tab == LuminaTab.gallery ? _galleryView(app) : _feed(app),
      ),
      if (_tab == LuminaTab.create) _composer(app),
    ]);
  }

  Widget _feed(AppState app) {
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_outlined,
                  size: 34, color: _faint(context)),
              const SizedBox(height: 14),
              Text(app.t('luminaReady'),
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: _txt(context))),
              const SizedBox(height: 8),
              Text(app.t('studioImagesHint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: _faint(context))),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
      itemCount: _items.length,
      itemBuilder: (_, i) => _resultCard(app, _items[i]),
    );
  }

  Widget _resultCard(AppState app, _LuminaJob it) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _card(context),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(it.prompt, style: TextStyle(fontSize: 12.5, color: _body(context))),
        const SizedBox(height: 10),
        if (!it.done && !it.running)
          Row(children: [
            Icon(Icons.schedule, size: 15, color: _faint(context)),
            const SizedBox(width: 8),
            Text(app.t('luminaQueued'),
                style: TextStyle(fontSize: 12, color: _sub(context))),
            const Spacer(),
            evsGhostButton(context, app.t('luminaDrop'), Icons.close,
                onTap: () => setState(() => _items.remove(it))),
          ])
        else if (it.running)
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
        else if (it.path != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(io.File(it.path!), fit: BoxFit.contain),
          ),
        if (it.done) ...[
          const SizedBox(height: 8),
          Row(children: [
            if (it.path != null) ...[
              evsGhostButton(context, app.t('studioOpen'), Icons.folder_open,
                  onTap: () => _reveal(it.path!)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(it.path!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: _faint(context))),
              ),
            ] else
              const Spacer(),
            IconButton(
              tooltip: app.t('studioDrop'),
              icon:
                  Icon(Icons.delete_outline, size: 17, color: _faint(context)),
              onPressed: () => unawaited(_drop(it)),
            ),
          ]),
        ],
      ]),
    );
  }

  // Галерея — то, что лежит на диске, а не то, что нагенерировано за сеанс.
  Widget _galleryView(AppState app) {
    final files = _gallery;
    if (files == null) {
      return const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (files.isEmpty) {
      return Center(
        child: Text(app.t('luminaGalleryEmpty'),
            style: TextStyle(fontSize: 13, color: _faint(context))),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: files.length,
      itemBuilder: (_, i) {
        final f = files[i];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _reveal(f.path),
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(f, fit: BoxFit.cover),
            ),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                tooltip: app.t('studioDrop'),
                icon: Icon(Icons.delete_outline,
                    size: 16, color: _danger(context)),
                onPressed: () async {
                  try {
                    await f.delete();
                  } catch (_) {
                    // Уже удалён — просто перечитаем каталог.
                  }
                  await _loadGallery();
                },
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _composer(AppState app) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _stroke(context))),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _prompt,
              maxLines: 3,
              minLines: 1,
              onSubmitted: (_) => unawaited(_submit()),
              style: TextStyle(fontSize: 13.5, color: _txt(context)),
              decoration: _deco(app.t('studioPrompt')),
            ),
          ),
          const SizedBox(width: 10),
          Column(mainAxisSize: MainAxisSize.min, children: [
            evsGhostButton(context, app.t('studioGo'), Icons.auto_awesome,
                onTap: () => unawaited(_submit())),
            if (_waiting > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${app.t('luminaQueue')}: $_waiting',
                    style: TextStyle(fontSize: 10.5, color: _faint(context))),
              ),
          ]),
        ]),
        const SizedBox(height: 8),
        Opacity(
          opacity: _negativeWorks ? 1 : 0.45,
          child: TextField(
            controller: _negative,
            enabled: _negativeWorks,
            maxLines: 2,
            minLines: 1,
            style: TextStyle(fontSize: 12.5, color: _txt(context)),
            decoration: _deco(app.t('studioNegative')),
          ),
        ),
        if (!_negativeWorks)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  app.t(_modelDistilled
                      ? 'studioNegativeDistilled'
                      : 'studioNegativeOffCfg'),
                  style: TextStyle(fontSize: 11, color: _warn(context))),
            ),
          ),
        const SizedBox(height: 10),
        // Теги-подсказки прямо под строкой: модель читает теги через запятую,
        // а не предложения, и по подсказкам это видно сразу.
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final g in _hints)
                for (final tag in g.$2)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _chip(tag, false, () => _appendTag(tag)),
                  ),
            ],
          ),
        ),
      ]),
    );
  }

  InputDecoration _deco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _faint(context), fontSize: 12.5),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        filled: true,
        fillColor: _overlayFill(context, 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: _stroke(context)),
        ),
      );

  // Панель настроек. Ровно те же девять групп, что были в прежней студии, —
  // но в своей колонке, где они не отбирают место у результатов.
  Widget _params(AppState app) {
    return evsStudioPane(
      context,
      width: 268,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      left: BorderSide(color: _stroke(context)),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.tune, size: 17, color: _accent(context)),
              const SizedBox(width: 9),
              Text(app.t('luminaParams'),
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _txt(context))),
            ]),
            const SizedBox(height: 18),
            _group(app, 'studioSize', [
              for (final s in _sizes)
                _chip('${s.$3}  ${s.$1}x${s.$2}',
                    _imgW == s.$1 && _imgH == s.$2, () {
                  setState(() {
                    _imgW = s.$1;
                    _imgH = s.$2;
                  });
                }),
            ]),
            _group(app, 'studioSteps', [
              for (final n in const [20, 25, 28, 40])
                _chip('$n', _steps == n, () => setState(() => _steps = n)),
            ]),
            _group(app, 'studioCfg', [
              for (final v in const [1.0, 3.0, 5.0, 7.0, 9.0])
                _chip(v == 1 ? app.t('studioCfgOff') : '${v.toInt()}',
                    _cfg == v, () => setState(() => _cfg = v)),
            ], desc: 'studioCfgDesc'),
            _group(app, 'studioSampler', [
              for (final s in const [
                ('euler_a', 'Euler a'),
                ('euler', 'Euler'),
                ('dpmpp_2m', 'DPM++ 2M'),
                ('dpmpp_2m_karras', 'DPM++ 2M K'),
              ])
                _chip(s.$2, _sampler == s.$1,
                    () => setState(() => _sampler = s.$1)),
            ], desc: 'studioSamplerDesc'),
            _group(app, 'studioFace', [
              for (final v in const [0.0, 0.3, 0.4, 0.5])
                _chip(v == 0 ? app.t('studioFaceOff') : v.toStringAsFixed(1),
                    _face == v, () {
                  setState(() => _face = v);
                  app.setImageFacePass(v);
                }),
            ], desc: 'studioFaceDesc'),
            _group(app, 'studioHires', [
              for (final v in const [0.0, 1.5, 2.0])
                _chip(v == 0 ? app.t('studioFaceOff') : '${v}x', _hires == v,
                    () {
                  setState(() => _hires = v);
                  app.setImageHires(v);
                }),
            ], desc: 'studioHiresDesc'),
            const SizedBox(height: 4),
            Text(app.t('imgLorasTitle').toUpperCase(),
                style: TextStyle(
                    fontSize: 10, letterSpacing: 0.6, color: _faint(context))),
            const SizedBox(height: 6),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => unawaited(_openLoras(app)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: _overlayFill(context, 0.05),
                  border: Border.all(color: _stroke(context)),
                ),
                child: Text(
                  _loras.isEmpty
                      ? app.t('imgLoraNone')
                      : _loras
                          .map((l) =>
                              '${ImageModelInfo(l.name, 0).title} x${l.weight.toStringAsFixed(2)}')
                          .join(', '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: _body(context)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(AppState app, String labelKey, List<Widget> chips,
      {String? desc}) {
    final label = Text(app.t(labelKey).toUpperCase(),
        style:
            TextStyle(fontSize: 10, letterSpacing: 0.6, color: _faint(context)));
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        desc == null
            ? label
            : Tooltip(message: app.t(desc), child: label),
        const SizedBox(height: 7),
        Wrap(spacing: 6, runSpacing: 6, children: chips),
      ]),
    );
  }

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
          border:
              Border.all(color: active ? _accent(context) : _stroke(context)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? _accent(context) : _body(context))),
      ),
    );
  }

  // --- окна -----------------------------------------------------------------

  Future<void> _openModels(AppState app) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ImageModelsSheet(app: app),
    );
    if (mounted) await _loadModels();
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
      builder: (_) =>
          ImageModelNoteSheet(app: app, model: _model, note: _modelNote),
    );
    if (apply != true) return;
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
    if (mounted) showAppSnackBar(context, app.t('imgNoteApplied'));
  }
}
