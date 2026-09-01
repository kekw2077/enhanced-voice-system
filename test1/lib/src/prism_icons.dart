part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — иконки макета
   --------------------------------------------------------------------------
   В прототипе каждая иконка — это <path d="…"> с обводкой в поле 24×24.
   Material Icons рисуют то же самое по смыслу, но другой рукой: другая
   толщина, другие скругления, другой наклон. Пока они стоят в рейке,
   оболочка ПОХОЖА на макет и не совпадает с ним.

   Поэтому здесь лежит разбор SVG-строки `d` в [Path] и виджет [PrismIcon],
   который её обводит. Контуры скопированы из handoff/design дословно —
   искать их в прототипе проще всего поиском по этому файлу.

   Зачем свой разбор, а не пакет. flutter_svg тянет за собой ещё несколько
   пакетов и загрузку при сборке, а нужен из него ровно один разбор `d` —
   двадцать команд, из которых макет использует девять. Дешевле держать своё.

   Толщина обводки задаётся В ЕДИНИЦАХ viewBox (как `stroke-width` в SVG):
   холст масштабируется целиком, и линия масштабируется вместе с ним — ровно
   как в браузере, где `vector-effect` по умолчанию выключен.
   ========================================================================== */

/// Числа в строке `d`. Знак начинает новое число, поэтому «1 1-2.4» читается
/// как три числа — так же, как их читает браузер.
final RegExp _kPrismNum =
    RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?');

/// Разбор атрибута `d` в [Path].
///
/// Поддержаны все команды, встречающиеся в макете: M/m, L/l, H/h, V/v, C/c,
/// S/s, Q/q, T/t, A/a, Z/z — вместе с неявным повтором (после `M` идущие
/// подряд пары координат означают `L`, после `m` — `l`).
Path prismPath(String d) {
  final path = Path();
  double cx = 0, cy = 0; // текущая точка
  double sx = 0, sy = 0; // начало подконтура, куда возвращает Z
  // Последняя контрольная точка кубики/квадратики — нужна для S и T, которые
  // отражают её относительно текущей точки.
  double? lcx, lcy, lqx, lqy;

  final tokens = RegExp('[MmLlHhVvCcSsQqTtAaZz]|${_kPrismNum.pattern}')
      .allMatches(d)
      .map((m) => m[0]!)
      .toList();

  var i = 0;
  var cmd = 'M';
  double num() => double.parse(tokens[i++]);
  bool moreNumbers() =>
      i < tokens.length && _kPrismNum.matchAsPrefix(tokens[i]) != null;

  while (i < tokens.length) {
    if (!moreNumbers()) {
      cmd = tokens[i++];
      // Z не несёт чисел: закрываем подконтур и идём дальше.
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        cx = sx;
        cy = sy;
        continue;
      }
    }
    final rel = cmd.toLowerCase() == cmd;
    switch (cmd.toUpperCase()) {
      case 'M':
        final x = num(), y = num();
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        path.moveTo(cx, cy);
        sx = cx;
        sy = cy;
        // Неявное продолжение: следующая пара — уже линия.
        cmd = rel ? 'l' : 'L';
        lcx = lcy = lqx = lqy = null;
      case 'L':
        final x = num(), y = num();
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        path.lineTo(cx, cy);
        lcx = lcy = lqx = lqy = null;
      case 'H':
        final x = num();
        cx = rel ? cx + x : x;
        path.lineTo(cx, cy);
        lcx = lcy = lqx = lqy = null;
      case 'V':
        final y = num();
        cy = rel ? cy + y : y;
        path.lineTo(cx, cy);
        lcx = lcy = lqx = lqy = null;
      case 'C':
        final x1 = num(), y1 = num(), x2 = num(), y2 = num();
        final x = num(), y = num();
        final c1x = rel ? cx + x1 : x1, c1y = rel ? cy + y1 : y1;
        final c2x = rel ? cx + x2 : x2, c2y = rel ? cy + y2 : y2;
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        path.cubicTo(c1x, c1y, c2x, c2y, cx, cy);
        lcx = c2x;
        lcy = c2y;
        lqx = lqy = null;
      case 'S':
        final x2 = num(), y2 = num(), x = num(), y = num();
        // Первая контрольная — отражение прошлой второй. Прошлой нет —
        // совпадает с текущей точкой (правило SVG).
        final c1x = lcx == null ? cx : 2 * cx - lcx;
        final c1y = lcy == null ? cy : 2 * cy - lcy;
        final c2x = rel ? cx + x2 : x2, c2y = rel ? cy + y2 : y2;
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        path.cubicTo(c1x, c1y, c2x, c2y, cx, cy);
        lcx = c2x;
        lcy = c2y;
        lqx = lqy = null;
      case 'Q':
        final x1 = num(), y1 = num(), x = num(), y = num();
        final qx = rel ? cx + x1 : x1, qy = rel ? cy + y1 : y1;
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        path.quadraticBezierTo(qx, qy, cx, cy);
        lqx = qx;
        lqy = qy;
        lcx = lcy = null;
      case 'T':
        final x = num(), y = num();
        final qx = lqx == null ? cx : 2 * cx - lqx;
        final qy = lqy == null ? cy : 2 * cy - lqy;
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        path.quadraticBezierTo(qx, qy, cx, cy);
        lqx = qx;
        lqy = qy;
        lcx = lcy = null;
      case 'A':
        final rx = num(), ry = num(), rot = num();
        final large = num() != 0, sweep = num() != 0;
        final x = num(), y = num();
        cx = rel ? cx + x : x;
        cy = rel ? cy + y : y;
        // Флаг sweep в SVG и `clockwise` во Flutter значат одно и то же:
        // у обеих систем координат ось Y смотрит вниз.
        path.arcToPoint(
          Offset(cx, cy),
          radius: Radius.elliptical(rx, ry),
          rotation: rot,
          largeArc: large,
          clockwise: sweep,
        );
        lcx = lcy = lqx = lqy = null;
      default:
        // Неизвестная команда — дальше разбирать нечего, строка испорчена.
        return path;
    }
  }
  return path;
}

/// Разобранные контуры живут по одному на строку: [prismPath] звался бы на
/// каждой перерисовке рейки, а в шестерёнке настроек полторы сотни чисел.
final Map<String, Path> _prismPathCache = {};
Path _prismCachedPath(String d) => _prismPathCache[d] ??= prismPath(d);

/// Иконка макета: контур `d` в поле 24×24, обведённый текущим цветом.
///
/// [progress] меньше единицы рисует контур не целиком — это `stroke-dasharray`
/// из прототипа, которым он «прочерчивает» иконку выбранного пункта.
class PrismIcon extends StatelessWidget {
  const PrismIcon(
    this.d, {
    super.key,
    this.size = 17,
    this.color,
    this.stroke = 1.85,
    this.progress = 1,
    this.fill = false,
  });

  final String d;
  final double size;
  final Color? color;

  /// Толщина в единицах viewBox, как `stroke-width` в SVG.
  final double stroke;

  /// Доля прочерченного контура, 0…1.
  final double progress;

  /// Залить, а не обвести. В макете так нарисован только треугольник «играть».
  final bool fill;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _PrismIconPainter(
          path: _prismCachedPath(d),
          color: color ?? IconTheme.of(context).color ?? _txt(context),
          stroke: stroke,
          progress: progress,
          fill: fill,
        ),
      ),
    );
  }
}

class _PrismIconPainter extends CustomPainter {
  _PrismIconPainter({
    required this.path,
    required this.color,
    required this.stroke,
    required this.progress,
    required this.fill,
  });

  final Path path;
  final Color color;
  final double stroke, progress;
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = fill ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    if (progress >= 1 || fill) {
      canvas.drawPath(path, paint);
    } else if (progress > 0) {
      // Каждый подконтур прочерчивается своей долей — иначе иконка из трёх
      // штрихов рисовалась бы по одному, а в макете они идут разом.
      for (final metric in path.computeMetrics()) {
        canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PrismIconPainter old) =>
      old.path != path ||
      old.color != color ||
      old.stroke != stroke ||
      old.progress != progress ||
      old.fill != fill;
}

/// Контуры из макета. Имена — по смыслу, значения скопированы дословно;
/// сверять с прототипом поиском по строке.
abstract final class PrismIcons {
  // --- Рейка -------------------------------------------------------------
  static const hub = 'M4 10.4 12 4l8 6.4M6.3 9.2V20h11.4V9.2';
  static const chat =
      'M20.5 12a8.5 8.5 0 0 1-12.3 7.6L4 21l1.4-4.2A8.5 8.5 0 1 1 20.5 12Z';
  static const commands = 'M6 8.5 9.5 12 6 15.5M12.5 15.5H18';
  static const modules = 'M3 13h3.6l2.6-7.4 3.7 13 2.6-5.6H21';
  // Переводчик: два слоя друг за другом — оригинал и наложенный на него
  // перевод, с пометкой на каждом.
  static const czn =
      'M3.6 5.4h8.6v8.6H3.6Z'
      'M11.8 10h8.6v8.6h-8.6Z'
      'M6.2 9.7h3.4'
      'M14.4 14.3h3.4M16.1 12.6v3.4';
  static const lumina =
      'M9.4 6.4l1.75 4.35 4.35 1.75-4.35 1.75L9.4 18.6l-1.75-4.35L3.3 12.5l4.35-1.75L9.4 6.4Z'
      'M17.9 3.2l.8 2.05 2.05.8-2.05.8-.8 2.05-.8-2.05-2.05-.8 2.05-.8.8-2.05Z'
      'M18.4 13l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7.7-1.8Z';
  static const mic =
      'M12 3.2a2.9 2.9 0 0 1 2.9 2.9v4.5a2.9 2.9 0 0 1-5.8 0V6.1A2.9 2.9 0 0 1 12 3.2Z'
      'M5.9 11a6.1 6.1 0 0 0 12.2 0M12 17.3V21';
  static const settings =
      'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM19.2 14.8a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1.03 1.55V21a2 2 0 0 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.56 1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.55-1.03H3a2 2 0 0 1 0-4h.1A1.7 1.7 0 0 0 4.66 8.8a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34H9a1.7 1.7 0 0 0 1.03-1.55V3a2 2 0 0 1 4 0v.1a1.7 1.7 0 0 0 1.03 1.55 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87V9a1.7 1.7 0 0 0 1.55 1.03H21a2 2 0 0 1 0 4h-.1a1.7 1.7 0 0 0-1.55 1.03Z';

  // --- Шапка и общее -----------------------------------------------------
  static const plus = 'M12 5v14M5 12h14';
  static const search = 'M20 20l-3.2-3.2M18 11a7 7 0 1 1-14 0 7 7 0 0 1 14 0Z';
  static const back = 'M14.5 5.5 8 12l6.5 6.5';
  static const forward = 'M5 12h14M13 6l6 6-6 6';
  static const dots = 'M12 6.4h.01M12 12h.01M12 17.6h.01';
  static const moon = 'M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z';
  static const sun =
      'M12 4.5v-2M12 21.5v-2M4.5 12h-2M21.5 12h-2M6.3 6.3 4.9 4.9M19.1 19.1l-1.4-1.4'
      'M17.7 6.3l1.4-1.4M4.9 19.1l1.4-1.4M16.2 12a4.2 4.2 0 1 1-8.4 0 4.2 4.2 0 0 1 8.4 0Z';
  static const refresh = 'M20 12a8 8 0 1 1-2.4-5.7M20 4.5V10h-5.5';
  static const chevronDown = 'm6 9 6 6 6-6';
  static const play = 'M8 5.5v13l11-6.5-11-6.5Z';
  static const send = 'M12 20V5M5.6 11.4 12 5l6.4 6.4';
  static const stop = 'M6.5 6.5h11v11h-11z';
  static const lock = 'M7 10.5V8a5 5 0 0 1 10 0v2.5M5.5 10.5h13V20h-13z';
  static const spark =
      'M12 3.6 13.9 9l5.4 1.9-5.4 1.9L12 18.2 10.1 12.8 4.7 10.9 10.1 9 12 3.6Z';
  static const info = 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17ZM12 10.8v5.7M12 7.6h.01';

  // --- Действия над сообщением (порядок из ACT в макете) ------------------
  static const copy = 'M9 9h9.5v11H9zM6 15H4.5V4H15v1.6';
  static const edit =
      'M4.5 19.5h4l10-10a2.4 2.4 0 0 0-3.4-3.4l-10 10v3.4ZM13.5 7.5l3 3';
  static const regenerate = 'M20 12a8 8 0 1 1-2.4-5.7M20 4.5V10h-5.5';
  static const continueOn = 'M5 6l7 6-7 6zM14 6l7 6-7 6';
  static const remove = 'M5 7h14M9.5 7V4.5h5V7M7 7l1 13h8l1-13';

  // --- Меню чата ---------------------------------------------------------
  static const pin = 'M9.5 4.5h5l-.7 5.2 3 2.6H7.2l3-2.6-.7-5.2ZM12 12.3V20';
  static const clear =
      'M4.5 8.5h15M9 8.5V6a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 6v2.5M10 12.5v5M14 12.5v5';
  static const trash =
      'M5.5 7.5h13l-1 12.5h-11l-1-12.5ZM9 7.5V5.6A1.6 1.6 0 0 1 10.6 4h2.8A1.6 1.6 0 0 1 15 5.6v1.9';

  // --- Разделы настроек --------------------------------------------------
  static const general = 'M4 7h9M17 7h3M4 17h5M13 17h7M13 4.6v4.8M9 14.6v4.8';
  static const speaker =
      'M4.5 9.5h3l4-3.5v12l-4-3.5h-3zM15.2 9.2a4 4 0 0 1 0 5.6M18 6.4a8 8 0 0 1 0 11.2';
  static const image = 'M4.5 6.5h15v11h-15zM6 16.2l4-3.9 3 2.9 2.4-1.9 3.1 3.6';
  static const chip =
      'M6.5 6.5h11v11h-11zM10 3.5v3M14 3.5v3M10 17.5v3M14 17.5v3M3.5 10h3M3.5 14h3M17.5 10h3M17.5 14h3';
  static const doc = 'M6.5 4.5h8L18 8v11.5H6.5zM9 11h6M9 14.5h6';
  static const phone =
      'M8.5 3.5h7A1.5 1.5 0 0 1 17 5v14a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 7 19V5a1.5 1.5 0 0 1 1.5-1.5ZM10.5 17.4h3';
  static const person =
      'M12 12.6a3.6 3.6 0 1 0 0-7.2 3.6 3.6 0 0 0 0 7.2ZM5 20.2c.9-3.3 3.6-5.1 7-5.1s6.1 1.8 7 5.1';
}
