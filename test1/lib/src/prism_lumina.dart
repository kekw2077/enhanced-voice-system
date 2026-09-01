part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — части экрана Nexus Lumina
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/design, блок `isImg`): слева панель 404px с
   параметрами, справа холст 392px и история сеткой по четыре.

   Здесь лежит только ФОРМА: чипы выбора, шахматный холст, сетка истории.
   Состояние и вся работа остаются в [_LuminaStudioState] — тот же `_submit`,
   та же очередь, те же модели и довески. Своей копии логики тут нет ни строки,
   иначе через месяц студия и её «призменный» вид разошлись бы.

   Что в макете названо иначе, чем есть на самом деле:

   • «Скачать HD» и «Апскейл 4×» поверх холста. Скачивать нечего — кадр уже
     лежит файлом на диске, а апскейл у нас не действие после кадра, а
     параметр ДО него (`_hires`). Поэтому на их месте «Открыть папку» и
     «Удалить»: то, что действительно можно сделать с готовым кадром.

   • Разрешение. В макете три квадрата 512/768/1024, у SDXL — семь родных
     размеров, и произвольные пропорции дают вытянутые лица. Список остаётся
     закрытым, а вид у чипов макетный.
   ========================================================================== */

/// Ряд чипов выбора из макета: выбранный залит акцентной тройкой, остальные —
/// подложкой поля с контуром. Растягиваются поровну, как `flex:1` в макете.
class PrismChoiceChips<T> extends StatelessWidget {
  const PrismChoiceChips({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.perRow = 3,
    this.mono = true,
  });

  /// (значение, подпись).
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// Сколько чипов в ряду. В макете три; больше вариантов — просто больше
  /// рядов, а не мельче чипы.
  final int perRow;

  /// Числа и размеры — моноширинным, как в макете; слова — обычным.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < options.length; i += perRow) {
      final slice = options.sublist(
          i, math.min(i + perRow, options.length));
      rows.add(Row(
        children: [
          for (var j = 0; j < perRow; j++) ...[
            if (j > 0) const SizedBox(width: 8),
            // Недостающие места в последнем ряду остаются пустыми: иначе
            // последний чип растягивался бы вдвое и читался как выбранный.
            Expanded(
              child: j < slice.length
                  ? _PrismChip(
                      label: slice[j].$2,
                      selected: slice[j].$1 == value,
                      mono: mono,
                      onTap: () => onChanged(slice[j].$1),
                    )
                  : const SizedBox(height: 38),
            ),
          ],
        ],
      ));
      if (i + perRow < options.length) rows.add(const SizedBox(height: 8));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

class _PrismChip extends StatefulWidget {
  const _PrismChip({
    required this.label,
    required this.selected,
    required this.mono,
    required this.onTap,
  });
  final String label;
  final bool selected, mono;
  final VoidCallback onTap;

  @override
  State<_PrismChip> createState() => _PrismChipState();
}

class _PrismChipState extends State<_PrismChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: on
                ? LinearGradient(
                    begin: const Alignment(-1, -0.2),
                    end: const Alignment(1, 0.2),
                    colors: [_ramp(context).a1, _ramp(context).a2],
                  )
                : null,
            color: on
                ? null
                : (_hover ? _prismHover(context) : _prismField(context)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: on ? Colors.transparent : _stroke(context)),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFamily: widget.mono ? kPrismMono : null,
              color: on ? Colors.white : _body(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// Диагональная шахматка холста — CSS
/// `repeating-linear-gradient(135deg, var(--field) 0 10px, transparent 10px 20px)`.
///
/// Рисуется поворотом холста на 45°: тогда полосы становятся обычными
/// вертикальными лентами, и считать наклон для каждой точки не нужно.
class _PrismCheckerPainter extends CustomPainter {
  _PrismCheckerPainter({required this.color, this.band = 10});
  final Color color;
  final double band;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(math.pi / 4);
    final d = math.sqrt(size.width * size.width + size.height * size.height);
    for (var x = -d; x < d; x += band * 2) {
      canvas.drawRect(Rect.fromLTWH(x, -d, band, d * 2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PrismCheckerPainter old) =>
      old.color != color || old.band != band;
}

/// Холст: шахматная подложка, поверх — кадр, ход работы или подсказка.
/// Высота 392px, скругление 20 — из макета.
class PrismCanvasFrame extends StatelessWidget {
  const PrismCanvasFrame({
    super.key,
    required this.state,
    required this.progress,
    required this.hint,
    this.image,
    this.error,
    this.actions = const [],
    this.height = 392,
  });

  /// Строка состояния моноширинным: «генерация · шаг 12 из 28», «готово»,
  /// «ожидание задачи».
  final String state;

  /// Доля выполненного, 0…1. Ноль прячет полосу — она не должна стоять пустой.
  final double progress;

  /// Что написано под полосой, пока кадра нет.
  final String hint;

  final io.File? image;
  final String? error;

  /// Пилюли поверх кадра слева сверху.
  final List<Widget> actions;

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _stroke(context)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _PrismCheckerPainter(color: _prismField(context)),
            ),
            if (image != null)
              Image.file(image!, fit: BoxFit.contain)
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state,
                        textAlign: TextAlign.center,
                        style: PrismType.numeric.copyWith(
                          color: _faint(context),
                          fontSize: 11,
                          letterSpacing: 0.66,
                        ),
                      ),
                      if (progress > 0) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 196,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Stack(
                              children: [
                                Container(
                                    height: 4, color: _prismChip(context)),
                                Positioned.fill(
                                  child: AnimatedFractionallySizedBox(
                                    duration:
                                        const Duration(milliseconds: 500),
                                    alignment: Alignment.centerLeft,
                                    widthFactor: progress.clamp(0.0, 1.0),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                          _ramp(context).a1,
                                          _ramp(context).a3,
                                        ]),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      SizedBox(
                        width: 280,
                        child: Text(
                          error ?? hint,
                          textAlign: TextAlign.center,
                          style: PrismType.body.copyWith(
                            fontSize: 12,
                            color: error == null
                                ? _sub(context)
                                : _danger(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (actions.isNotEmpty)
              Positioned(
                left: 14,
                top: 14,
                child: Row(
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 7),
                      actions[i],
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Пилюля поверх холста. Первая — акцентная, остальные — на подложке чипа.
class PrismCanvasPill extends StatelessWidget {
  const PrismCanvasPill({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary, danger;

  @override
  Widget build(BuildContext context) {
    final fg = primary
        ? Colors.white
        : (danger ? _danger(context) : _body(context));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            gradient: primary
                ? LinearGradient(
                    colors: [_ramp(context).a1, _ramp(context).a2])
                : null,
            color: primary ? null : _prismChip(context),
            borderRadius: BorderRadius.circular(999),
            border: primary
                ? null
                : Border.all(color: _stroke(context)),
          ),
          child: Text(
            label,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
          ),
        ),
      ),
    );
  }
}

/// Сетка истории: четыре плитки в ряд, квадратные, со скруглением 16 — как в
/// макете. Плитки настоящие: это файлы, лежащие в каталоге студии.
class PrismHistoryGrid extends StatelessWidget {
  const PrismHistoryGrid({
    super.key,
    required this.files,
    required this.onOpen,
    required this.onDelete,
    this.columns = 4,
  });

  final List<io.File>? files;
  final ValueChanged<io.File> onOpen;
  final ValueChanged<io.File> onDelete;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    if (files == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(app.t('prismCollecting'),
            style: PrismType.caption.copyWith(color: _faint(context))),
      );
    }
    if (files!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(app.t('luminaGalleryEmpty'),
            style: PrismType.caption.copyWith(color: _faint(context))),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: files!.length,
      itemBuilder: (_, i) => _PrismHistoryTile(
        file: files![i],
        onOpen: () => onOpen(files![i]),
        onDelete: () => onDelete(files![i]),
      ),
    );
  }
}

class _PrismHistoryTile extends StatefulWidget {
  const _PrismHistoryTile({
    required this.file,
    required this.onOpen,
    required this.onDelete,
  });
  final io.File file;
  final VoidCallback onOpen, onDelete;

  @override
  State<_PrismHistoryTile> createState() => _PrismHistoryTileState();
}

class _PrismHistoryTileState extends State<_PrismHistoryTile> {
  bool _hover = false;

  /// Размер кадра подписью, как в макете. Не читаем файл отдельно: снимок всё
  /// равно раскодируется для показа, и поток картинки сообщает размеры даром.
  String? _size;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = FileImage(widget.file);
    _stream?.removeListener(_listener!);
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() => _size = '${info.image.width}×${info.image.height}');
    }, onError: (_, __) {});
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: _hover ? _prismStroke2(context) : _stroke(context)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _PrismCheckerPainter(
                      color: _prismField(context), band: 8),
                ),
                Image.file(widget.file, fit: BoxFit.cover),
                // Подпись читается только на своей подложке: под ней кадр
                // любого цвета, и белым по белому её не видно.
                if (_size != null)
                  Positioned(
                    right: 7,
                    bottom: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0x8C000000),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        _size!,
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontFamily: kPrismMono,
                          color: Color(0xFFE8EAF0),
                        ),
                      ),
                    ),
                  ),
                if (_hover)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Tooltip(
                      message: app.t('studioDrop'),
                      child: GestureDetector(
                        onTap: widget.onDelete,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: const Color(0x8C000000),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          alignment: Alignment.center,
                          child: PrismIcon(PrismIcons.trash,
                              size: 14,
                              stroke: 2,
                              color: _danger(context)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
