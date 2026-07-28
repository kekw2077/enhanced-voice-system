part of '../main.dart';

/* ========================= ЛОГОТИП GENESIS =========================
   Полный порт образца `genesis/EVS Animations.dc.html` (чистый SVG + CSS)
   в CustomPainter — вариант 01 «Genesis» (знак + подпись «Enhanced Voice
   System») и вариант 05 «Genesis · знак» (тот же знак без подписи).
   Перенесены все слои, кадры, задержки, режимы наложения и фильтры;
   геометрия живёт в исходном viewBox 1024×1024 и масштабируется под любой
   габарит, поэтому один и тот же код рисует и сплеш во всё окно, и значок
   30 px в углу.

   Хронометраж (секунды от старта):
     0.15  вспышка из сингулярности     1.10  доплеровский блик
     0.25  туманность                   1.70  свуши (два больших дуг-мазка)
     0.30  кольцо раскручивается        2.25  орбиты начинают вращение
     0.60  горизонт событий «съедает»    2.64…3.42  глитч-прошивка круга
     0.95  контур кольца                3.30  частицы падают на горизонт
     3.50  подпись + её глитч (вариант 01)
   Дальше — вечный луп: частицы по спирали, дыхание кольца, редкие
   глитч-всплески полос и хроматики. Кольцо остаётся цельным, без разрыва.

   Цвета логотипа — фиксированная палитра бренда, НЕ токены темы: знак
   должен читаться одинаково во всех темах и стилях (это единственное место
   в проекте, где сырые Color(0x…) уместны — как и иконка приложения). */

// ---- Палитра образца ------------------------------------------------------
const Color _genRing1 = Color(0xFFC77BE8); // сиреневый конец градиента кольца
const Color _genRing2 = Color(0xFF9AD9FF); // голубая середина
const Color _genRing3 = Color(0xFFEAF6FF); // почти белый конец
const Color _genNeb1 = Color(0xFF6F58EA); // ядро туманности
const Color _genNeb2 = Color(0xFF8E45D8); // край туманности
const Color _genOrb = Color(0xFFB9E4FF); // орбиты
const Color _genDop = Color(0xFFF2FAFF); // доплеровский блик
const Color _genCore = Color(0xFF050509); // горизонт событий
const Color _genChromA = Color(0xFFFF4FD8); // хроматический призрак (magenta)
const Color _genChromB = Color(0xFF22D3EE); // хроматический призрак (cyan)
// Фон сплеша — тот же, что в образце: body radial-gradient + плоская подложка.
const Color _genBgTop = Color(0xFF12152E);
const Color _genBgBase = Color(0xFF0A0C18);
// Сцена, на которой знак лежит в образце (карточка `.stage`).
const Color _genStage = Color(0xFF07080F);

// Кривые CSS: ease-out / ease-in-out / cubic-bezier(.22,1,.36,1).
const Curve _csEaseOut = Cubic(0, 0, 0.58, 1);
const Curve _csEaseInOut = Cubic(0.42, 0, 0.58, 1);
const Curve _csOutQuint = Cubic(0.22, 1, 0.36, 1);

// Момент «покоя»: кадр, в котором ни одна глитч-дорожка не активна (проверено
// по всем infinite-анимациям образца). На нём замирает знак, когда вечный луп
// запрещён политикой движения (MotionPolicy: balanced в простое / saver).
const double _genRestT = 12.0;
// Конец интро: к этому моменту собран знак (3.9) и отглитчена подпись (5.2).
const double _genIntroEndMark = 4.0;
const double _genIntroEndText = 5.2;

// ---- Хелперы CSS-анимаций -------------------------------------------------

/// Локальный прогресс CSS-анимации в момент [t] (сек). Отрицательная задержка
/// сдвигает фазу вперёд, как в CSS. Конечная анимация ведёт себя как
/// `fill: both` — держит первый кадр до старта и последний после конца.
double _csP(double t, double delay, double dur, {bool infinite = false}) {
  if (dur <= 0) return 1;
  final x = t - delay;
  if (!infinite) return (x / dur).clamp(0.0, 1.0);
  if (x < 0) {
    final p = (x / dur) % 1.0;
    return p == 0 ? 0.0 : p + 1.0;
  }
  return (x / dur) % 1.0;
}

/// Значение дорожки @keyframes при прогрессе [p]. Кадры — (позиция 0..1,
/// значение); [curve] применяется К КАЖДОМУ сегменту, как timing-function в CSS.
double _csKf(List<(double, double)> ks, double p, [Curve curve = Curves.linear]) {
  if (p <= ks.first.$1) return ks.first.$2;
  if (p >= ks.last.$1) return ks.last.$2;
  for (var i = 0; i < ks.length - 1; i++) {
    final a = ks[i];
    final b = ks[i + 1];
    if (p >= a.$1 && p <= b.$1) {
      final span = b.$1 - a.$1;
      final local = span <= 0 ? 1.0 : (p - a.$1) / span;
      return a.$2 + (b.$2 - a.$2) * curve.transform(local.clamp(0.0, 1.0));
    }
  }
  return ks.last.$2;
}

/// То же, но `steps(1, end)`: значение держится от кадра до кадра без
/// интерполяции — так в образце сделаны все глитч-дорожки.
double _csStep(List<(double, double)> ks, double p) {
  var v = ks.first.$2;
  for (final k in ks) {
    if (p < k.$1) break;
    v = k.$2;
  }
  return v;
}

double _genRad(double deg) => deg * math.pi / 180.0;

// ---- Дорожки @keyframes образца -------------------------------------------
// Имена совпадают с CSS, чтобы порт можно было сверять построчно.

// Вспышка: scale .2 → 26, прозрачность 0 → 1 (15 %) → 0.
const _kfFlashScale = <(double, double)>[(0.0, 0.2), (1.0, 26.0)];
const _kfFlashOp = <(double, double)>[(0.0, 0.0), (0.15, 1.0), (1.0, 0.0)];
// Туманность: opacity 0→1, scale .25→1.
const _kfNebScale = <(double, double)>[(0.0, 0.25), (1.0, 1.0)];
// Свуши: opacity 0 → .5 (25 %) → .5, штрих прорисовывается dashoffset 1400→0.
const _kfSwOp = <(double, double)>[(0.0, 0.0), (0.25, 0.5), (1.0, 0.5)];
const _kfSwDash = <(double, double)>[(0.0, 1400.0), (1.0, 0.0)];
// Доплер: dashoffset 360→0, opacity 0 → 1 (30 %) → 1.
const _kfDopDash = <(double, double)>[(0.0, 360.0), (1.0, 0.0)];
const _kfDopOp = <(double, double)>[(0.0, 0.0), (0.3, 1.0), (1.0, 1.0)];
// Дыхание кольца после сборки: 0 → .32 → 0.
const _kfPulse = <(double, double)>[(0.0, 0.0), (0.5, 0.32), (1.0, 0.0)];
// Дрожание группы (bhJit) и мерцание (bhFlick) в момент глитча.
const _kfJitX = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, 9.0), (0.64, -7.0), (0.66, 4.0),
  (0.68, -9.0), (0.70, 0.0), (0.74, 0.0), (0.76, 6.0), (0.78, -5.0),
  (0.80, 0.0), (1.0, 0.0),
];
const _kfJitY = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, -4.0), (0.64, 3.0), (0.66, 6.0),
  (0.68, -2.0), (0.70, 0.0), (0.74, 0.0), (0.76, 2.0), (0.78, -3.0),
  (0.80, 0.0), (1.0, 0.0),
];
const _kfFlick = <(double, double)>[
  (0.0, 1.0), (0.60, 1.0), (0.62, 0.5), (0.64, 1.0), (0.72, 0.72),
  (0.74, 1.0), (1.0, 1.0),
];
// Хроматические призраки кольца.
const _kfChromAOp = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, 0.85), (0.66, 0.55), (0.70, 0.8),
  (0.74, 0.45), (0.79, 0.0), (1.0, 0.0),
];
const _kfChromAX = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, -16.0), (0.66, 11.0), (0.70, -9.0),
  (0.74, 7.0), (0.79, 0.0), (1.0, 0.0),
];
const _kfChromAY = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, 2.0), (0.66, -3.0), (0.70, 4.0),
  (0.74, 0.0), (0.79, 0.0), (1.0, 0.0),
];
const _kfChromBOp = _kfChromAOp;
const _kfChromBX = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, 16.0), (0.66, -11.0), (0.70, 9.0),
  (0.74, -7.0), (0.79, 0.0), (1.0, 0.0),
];
const _kfChromBY = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.62, -2.0), (0.66, 3.0), (0.70, -4.0),
  (0.74, 0.0), (0.79, 0.0), (1.0, 0.0),
];
// Две полосы-среза в момент интро-глитча.
const _kfSliceOp = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.61, 0.9), (0.63, 0.0), (0.67, 0.75),
  (0.69, 0.0), (0.75, 0.6), (0.77, 0.0), (1.0, 0.0),
];
const _kfSliceX = <(double, double)>[
  (0.0, 0.0), (0.60, 0.0), (0.61, -22.0), (0.67, 18.0), (0.75, -12.0),
  (0.77, 0.0), (1.0, 0.0),
];
// Тряска всего знака (bhShake / bhShake2) — вечный луп.
const _kfShakeX = <(double, double)>[
  (0.0, 0.0), (0.299, 0.0), (0.30, 10.0), (0.307, -8.0), (0.314, 5.0),
  (0.321, -10.0), (0.328, 0.0), (0.719, 0.0), (0.72, -11.0),
  (0.726, 7.0), (0.733, -5.0), (0.74, 0.0), (1.0, 0.0),
];
const _kfShakeY = <(double, double)>[
  (0.0, 0.0), (0.299, 0.0), (0.30, -4.0), (0.307, 3.0), (0.314, 6.0),
  (0.321, -2.0), (0.328, 0.0), (0.719, 0.0), (0.72, 3.0), (0.726, -5.0),
  (0.733, 4.0), (0.74, 0.0), (1.0, 0.0),
];
const _kfShake2X = <(double, double)>[
  (0.0, 0.0), (0.439, 0.0), (0.44, -9.0), (0.446, 8.0), (0.453, -6.0),
  (0.46, 0.0), (0.829, 0.0), (0.83, 11.0), (0.836, -7.0), (0.842, 4.0),
  (0.849, 0.0), (1.0, 0.0),
];
const _kfShake2Y = <(double, double)>[
  (0.0, 0.0), (0.439, 0.0), (0.44, 5.0), (0.446, -3.0), (0.453, -5.0),
  (0.46, 0.0), (0.829, 0.0), (0.83, 2.0), (0.836, -4.0), (0.842, 5.0),
  (0.849, 0.0), (1.0, 0.0),
];
// Широкие глитч-полосы (bhBigA…D) — вечный луп, две вспышки за цикл.
const _kfBigAOp = <(double, double)>[
  (0.0, 0.0), (0.299, 0.0), (0.30, 0.85), (0.309, 0.0), (0.316, 0.6),
  (0.324, 0.0), (0.719, 0.0), (0.72, 0.7), (0.728, 0.0), (0.734, 0.5),
  (0.74, 0.0), (1.0, 0.0),
];
const _kfBigAX = <(double, double)>[
  (0.0, 0.0), (0.299, 0.0), (0.30, -26.0), (0.316, 20.0), (0.324, 0.0),
  (0.719, 0.0), (0.72, 24.0), (0.734, -18.0), (0.74, 0.0), (1.0, 0.0),
];
const _kfBigBOp = <(double, double)>[
  (0.0, 0.0), (0.302, 0.0), (0.303, 0.7), (0.312, 0.0), (0.32, 0.45),
  (0.328, 0.0), (0.722, 0.0), (0.723, 0.6), (0.73, 0.0), (0.736, 0.4),
  (0.742, 0.0), (1.0, 0.0),
];
const _kfBigBX = <(double, double)>[
  (0.0, 0.0), (0.302, 0.0), (0.303, 22.0), (0.32, -16.0), (0.328, 0.0),
  (0.722, 0.0), (0.723, -20.0), (0.736, 14.0), (0.742, 0.0), (1.0, 0.0),
];
const _kfBigCOp = <(double, double)>[
  (0.0, 0.0), (0.439, 0.0), (0.44, 0.8), (0.448, 0.0), (0.454, 0.55),
  (0.461, 0.0), (0.829, 0.0), (0.83, 0.65), (0.837, 0.0), (0.843, 0.45),
  (0.85, 0.0), (1.0, 0.0),
];
const _kfBigCX = <(double, double)>[
  (0.0, 0.0), (0.439, 0.0), (0.44, 24.0), (0.454, -18.0), (0.461, 0.0),
  (0.829, 0.0), (0.83, -22.0), (0.843, 16.0), (0.85, 0.0), (1.0, 0.0),
];
const _kfBigDOp = <(double, double)>[
  (0.0, 0.0), (0.442, 0.0), (0.443, 0.6), (0.45, 0.0), (0.457, 0.4),
  (0.463, 0.0), (0.832, 0.0), (0.833, 0.55), (0.84, 0.0), (0.846, 0.35),
  (0.852, 0.0), (1.0, 0.0),
];
const _kfBigDX = <(double, double)>[
  (0.0, 0.0), (0.442, 0.0), (0.443, -20.0), (0.457, 14.0), (0.463, 0.0),
  (0.832, 0.0), (0.833, 18.0), (0.846, -12.0), (0.852, 0.0), (1.0, 0.0),
];
// Короткие «блипы» — четыре дорожки, по четыре вспышки за цикл в разных точках.
const _kfBlip1Op = <(double, double)>[
  (0.0, 0.0), (0.059, 0.0), (0.06, 0.7), (0.072, 0.0), (0.228, 0.0),
  (0.23, 0.5), (0.24, 0.0), (0.478, 0.0), (0.48, 0.65), (0.491, 0.0),
  (0.768, 0.0), (0.77, 0.45), (0.78, 0.0), (1.0, 0.0),
];
const _kfBlip1X = <(double, double)>[
  (0.0, -170.0), (0.228, 215.0), (0.478, -60.0), (0.768, 140.0), (1.0, 140.0),
];
const _kfBlip1Y = <(double, double)>[
  (0.0, -250.0), (0.228, 80.0), (0.478, 300.0), (0.768, -120.0), (1.0, -120.0),
];
const _kfBlip2Op = <(double, double)>[
  (0.0, 0.0), (0.119, 0.0), (0.12, 0.55), (0.131, 0.0), (0.348, 0.0),
  (0.35, 0.7), (0.36, 0.0), (0.588, 0.0), (0.59, 0.4), (0.602, 0.0),
  (0.878, 0.0), (0.88, 0.6), (0.89, 0.0), (1.0, 0.0),
];
const _kfBlip2X = <(double, double)>[
  (0.0, 230.0), (0.348, -240.0), (0.588, 70.0), (0.878, -120.0), (1.0, -120.0),
];
const _kfBlip2Y = <(double, double)>[
  (0.0, -180.0), (0.348, 40.0), (0.588, 250.0), (0.878, -300.0), (1.0, -300.0),
];
const _kfBlip3Op = <(double, double)>[
  (0.0, 0.0), (0.039, 0.0), (0.04, 0.5), (0.05, 0.0), (0.288, 0.0),
  (0.29, 0.75), (0.301, 0.0), (0.658, 0.0), (0.66, 0.45), (0.67, 0.0),
  (0.908, 0.0), (0.91, 0.6), (0.922, 0.0), (1.0, 0.0),
];
const _kfBlip3X = <(double, double)>[
  (0.0, -280.0), (0.288, 90.0), (0.658, 260.0), (0.908, -40.0), (1.0, -40.0),
];
const _kfBlip3Y = <(double, double)>[
  (0.0, 150.0), (0.288, -320.0), (0.658, 210.0), (0.908, -60.0), (1.0, -60.0),
];
const _kfBlip4Op = <(double, double)>[
  (0.0, 0.0), (0.169, 0.0), (0.17, 0.65), (0.181, 0.0), (0.408, 0.0),
  (0.41, 0.4), (0.42, 0.0), (0.708, 0.0), (0.71, 0.7), (0.721, 0.0),
  (0.948, 0.0), (0.95, 0.5), (0.96, 0.0), (1.0, 0.0),
];
const _kfBlip4X = <(double, double)>[
  (0.0, 60.0), (0.408, -210.0), (0.708, 180.0), (0.948, -90.0), (1.0, -90.0),
];
const _kfBlip4Y = <(double, double)>[
  (0.0, 330.0), (0.408, -90.0), (0.708, 20.0), (0.948, -230.0), (1.0, -230.0),
];
// Падение частицы на горизонт событий: сдвиг по Y, масштаб, прозрачность.
const _kfFallY = <(double, double)>[(0.0, -352.0), (0.90, -203.0), (1.0, -188.0)];
const _kfFallS = <(double, double)>[(0.0, 1.0), (0.90, 0.5), (1.0, 0.12)];
const _kfFallOp = <(double, double)>[
  (0.0, 0.0), (0.12, 1.0), (0.72, 0.95), (0.90, 0.6), (1.0, 0.0),
];
const _kfFall2Y = <(double, double)>[(0.0, -410.0), (0.92, -205.0), (1.0, -189.0)];
const _kfFall2S = <(double, double)>[(0.0, 1.1), (0.92, 0.45), (1.0, 0.1)];
const _kfFall2Op = <(double, double)>[
  (0.0, 0.0), (0.15, 0.85), (0.80, 0.75), (0.92, 0.45), (1.0, 0.0),
];

// ---- Таблицы элементов образца -------------------------------------------

// Частица: длительность/задержка вращения, направление, радиусы, цвет,
// размытие, вариант падения, длительность/задержка падения.
class _GenParticle {
  final double spinDur, spinDelay;
  final bool rev;
  final double rx, ry;
  final Color color;
  final double blur;
  final bool fall2;
  final double fallDur, fallDelay;
  const _GenParticle(this.spinDur, this.spinDelay, this.rev, this.rx, this.ry,
      this.color, this.blur, this.fall2, this.fallDur, this.fallDelay);
}

// 18 частиц, падающих по спирали на горизонт событий (вечный луп образца).
const List<_GenParticle> _genParticles = [
  _GenParticle(9.2, -1.9, false, 5.6, 2.2, _genRing1, 7, false, 5.2, -5.7),
  _GenParticle(9.7, -7.1, false, 4.9, 2.2, _genRing3, 4, true, 7.7, -7.8),
  _GenParticle(11.9, -12.4, false, 4.8, 1.8, _genRing1, 4, false, 5.3, -2.2),
  _GenParticle(9.2, -13.8, true, 10.5, 5.0, _genOrb, 7, true, 3.9, -2.5),
  _GenParticle(16.0, -0.9, false, 6.5, 2.1, _genRing1, 4, false, 5.8, -1.7),
  _GenParticle(13.6, -1.7, false, 7.3, 3.3, _genRing2, 4, true, 4.8, -3.9),
  _GenParticle(10.4, -5.7, false, 6.2, 2.1, _genRing3, 7, false, 6.8, 0.0),
  _GenParticle(15.5, -9.5, true, 4.5, 1.9, _genOrb, 4, true, 4.3, -2.3),
  _GenParticle(15.4, -12.3, false, 5.3, 2.0, _genRing2, 4, false, 6.1, -1.0),
  _GenParticle(16.8, -9.0, false, 6.5, 2.8, _genOrb, 7, true, 5.6, -1.2),
  _GenParticle(7.2, -12.9, false, 4.7, 2.1, _genRing3, 4, false, 5.0, -0.8),
  _GenParticle(8.3, -2.7, true, 6.8, 2.2, _genOrb, 4, true, 4.1, -1.2),
  _GenParticle(16.9, -1.4, false, 5.6, 2.1, _genRing2, 7, false, 6.7, -4.8),
  _GenParticle(9.2, -1.8, false, 5.0, 1.8, _genRing3, 4, true, 5.8, -3.1),
  _GenParticle(14.3, -8.1, false, 6.7, 3.0, _genRing2, 4, false, 8.1, -5.2),
  _GenParticle(13.3, -7.5, true, 5.9, 2.4, _genRing2, 7, true, 4.0, 0.0),
  _GenParticle(11.5, -0.6, false, 4.9, 1.6, _genRing2, 4, false, 7.8, -1.4),
  _GenParticle(15.5, -12.3, false, 4.3, 2.0, _genRing3, 4, true, 6.6, -4.8),
];

// Глитч-полоса: прямоугольник в user-координатах, цвет, дорожки, тайминг.
class _GenBand {
  final double x, y, w, h;
  final Color color;
  final List<(double, double)> op, tx;
  final double dur, delay;
  final bool infinite;
  const _GenBand(this.x, this.y, this.w, this.h, this.color, this.op, this.tx,
      this.dur, this.delay, this.infinite);
}

// Две полосы-среза интро + семь широких полос вечного лупа.
const List<_GenBand> _genBands = [
  _GenBand(300, 452, 424, 26, _genRing3, _kfSliceOp, _kfSliceX, 3.9, 0.3, false),
  _GenBand(300, 600, 424, 14, _genRing2, _kfSliceOp, _kfSliceX, 3.9, 0.45, false),
  _GenBand(300, 446, 424, 26, _genRing3, _kfBigAOp, _kfBigAX, 13.0, 4.2, true),
  _GenBand(300, 478, 424, 22, _genRing3, _kfBigCOp, _kfBigCX, 9.4, 6.8, true),
  _GenBand(306, 558, 412, 10, _genRing1, _kfBigDOp, _kfBigDX, 9.4, 6.8, true),
  _GenBand(316, 642, 392, 14, _genRing2, _kfBigCOp, _kfBigCX, 9.4, 6.8, true),
  _GenBand(300, 592, 424, 16, _genRing2, _kfBigBOp, _kfBigBX, 13.0, 4.2, true),
  _GenBand(318, 352, 388, 11, _genRing1, _kfBigBOp, _kfBigBX, 13.0, 4.2, true),
  _GenBand(312, 694, 400, 9, _genRing3, _kfBigAOp, _kfBigAX, 13.0, 4.2, true),
];

// Короткий блип: прямоугольник, цвет, набор дорожек, тайминг.
class _GenBlip {
  final double x, y, w, h;
  final Color color;
  final List<(double, double)> op, tx, ty;
  final double dur, delay;
  const _GenBlip(this.x, this.y, this.w, this.h, this.color, this.op, this.tx,
      this.ty, this.dur, this.delay);
}

const List<_GenBlip> _genBlips = [
  _GenBlip(292, 268, 104, 3, _genRing3, _kfBlip1Op, _kfBlip1X, _kfBlip1Y, 7.4, 3.40),
  _GenBlip(214, 402, 96, 18, _genRing2, _kfBlip2Op, _kfBlip2X, _kfBlip2Y, 9.1, 3.77),
  _GenBlip(336, 512, 108, 6, _genRing1, _kfBlip3Op, _kfBlip3X, _kfBlip3Y, 6.6, 4.14),
  _GenBlip(262, 618, 92, 22, _genOrb, _kfBlip4Op, _kfBlip4X, _kfBlip4Y, 10.4, 4.51),
  _GenBlip(318, 726, 100, 9, _genRing3, _kfBlip1Op, _kfBlip1X, _kfBlip1Y, 8.3, 4.88),
  _GenBlip(388, 352, 88, 4, _genRing2, _kfBlip2Op, _kfBlip2X, _kfBlip2Y, 11.7, 5.25),
  _GenBlip(240, 566, 112, 14, _genRing1, _kfBlip3Op, _kfBlip3X, _kfBlip3Y, 9.8, 5.62),
  _GenBlip(300, 468, 96, 7, _genOrb, _kfBlip4Op, _kfBlip4X, _kfBlip4Y, 7.9, 5.99),
  _GenBlip(356, 672, 84, 11, _genRing3, _kfBlip1Op, _kfBlip1X, _kfBlip1Y, 12.6, 6.36),
  _GenBlip(268, 318, 100, 2, _genRing2, _kfBlip2Op, _kfBlip2X, _kfBlip2Y, 6.9, 6.73),
];

/* ==================== ЗНАК (вариант 05 / ядро варианта 01) ==================== */

class _GenesisMarkPainter extends CustomPainter {
  _GenesisMarkPainter({
    required this.t,
    required this.refPx,
    this.stage = _genStage,
  });

  /// Секунды с начала анимации.
  final double t;

  /// Цвет сцены под знаком. В образце знак лежит на почти чёрной подложке, и
  /// глитч смешивается с НЕЙ: полосы-срезы идут в режиме overlay, который на
  /// тёмном гаснет и вспыхивает только там, где пересекает светлое кольцо. На
  /// прозрачном слое overlay пропускает источник целиком, и полосы светились бы
  /// поперёк всего круга — чего в образце нет. Поэтому знак несёт свою сцену
  /// сам: диск цвета [stage], сходящий на прозрачность к краю туманности (так
  /// знак остаётся вставляемым в любую поверхность, включая угол главного
  /// экрана 30 px).
  final Color stage;

  /// Ширина, под которую в образце посчитаны CSS-пиксели внешней тряски
  /// (`bhShake` живёт на самом <svg>, поэтому его сдвиги — в пикселях
  /// отрисовки, а не в user-единицах viewBox).
  final double refPx;

  static const double _vb = 1024.0;
  static const Offset _c = Offset(512, 512);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / _vb; // user-единицы → пиксели
    canvas.save();
    // Внешняя тряска: в образце она на <svg>, т.е. в пикселях отрисовки.
    final shakeP = _csP(t, 4.2, 13.0, infinite: true);
    final shakeK = size.width / refPx;
    canvas.translate(
      _csStep(_kfShakeX, shakeP) * shakeK,
      _csStep(_kfShakeY, shakeP) * shakeK,
    );
    canvas.scale(k);
    // Вторая тряска + дрожание/мерцание группы — уже в user-единицах.
    final shake2P = _csP(t, 6.8, 9.4, infinite: true);
    canvas.translate(_csStep(_kfShake2X, shake2P), _csStep(_kfShake2Y, shake2P));
    final jitP = _csP(t, 0.3, 3.9);
    canvas.translate(_csStep(_kfJitX, jitP), _csStep(_kfJitY, jitP));
    final flick = _csStep(_kfFlick, jitP);

    // Все слои — в одном слое композитинга: режимы screen/overlay у глитча
    // должны смешиваться с самим знаком, а не с фоном приложения.
    canvas.saveLayer(
      const Rect.fromLTWH(-_vb, -_vb, _vb * 3, _vb * 3),
      Paint()..color = Colors.white.withValues(alpha: flick.clamp(0.0, 1.0)),
    );

    _stagePlate(canvas);
    _nebula(canvas);
    _swooshes(canvas);
    _orbits(canvas);
    _ring(canvas);
    _horizon(canvas);
    _ringOutline(canvas);
    _doppler(canvas);
    _chroma(canvas);
    _bands(canvas);
    _blips(canvas);
    _particles(canvas);
    _breath(canvas);
    _flash(canvas);

    canvas.restore();
    canvas.restore();
  }

  // Градиент кольца: userSpaceOnUse (330,700) → (700,330). Прозрачность
  // приходится вмешивать в сами стопы: у Paint с shader поле color не
  // применяется вообще, поэтому «..color = white.withValues(alpha:)» здесь
  // молча ничего не делал бы.
  Shader _ringShader([double alpha = 1]) => LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [
          _genRing1.withValues(alpha: alpha),
          _genRing2.withValues(alpha: alpha),
          _genRing3.withValues(alpha: alpha),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(const Rect.fromLTRB(330, 330, 700, 700));

  // 0. Сцена образца (см. [stage]): проявляется вместе с туманностью, чтобы у
  // первого кадра не было тёмного диска до вспышки.
  void _stagePlate(Canvas canvas) {
    final op = _csKf(const [(0.0, 0.0), (1.0, 1.0)], _csP(t, 0.15, 0.6),
        _csEaseOut);
    if (op <= 0.001) return;
    canvas.drawCircle(
      _c,
      442,
      Paint()
        ..shader = RadialGradient(
          colors: [
            stage.withValues(alpha: op),
            stage.withValues(alpha: op),
            stage.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.74, 1.0],
        ).createShader(Rect.fromCircle(center: _c, radius: 442)),
    );
  }

  // 1. Туманность: радиальный градиент r=430, opacity 0→1, scale .25→1.
  void _nebula(Canvas canvas) {
    final p = _csP(t, 0.25, 0.9);
    final op = _csKf(const [(0.0, 0.0), (1.0, 1.0)], p, _csEaseOut);
    if (op <= 0.001) return;
    final s = _csKf(_kfNebScale, p, _csEaseOut);
    canvas.save();
    canvas.translate(_c.dx, _c.dy);
    canvas.scale(s);
    canvas.translate(-_c.dx, -_c.dy);
    final rect = Rect.fromCircle(center: _c, radius: 430);
    canvas.drawCircle(
      _c,
      430,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _genNeb1.withValues(alpha: 0.5 * op),
            _genNeb2.withValues(alpha: 0.22 * op),
            _genNeb2.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rect),
    );
    canvas.restore();
  }

  // 2. Два свуша r=464: штрих прорисовывается от начала пути.
  void _swooshes(Canvas canvas) {
    void sw(double delay, double startDeg) {
      final p = _csP(t, delay, 0.8);
      final op = _csKf(_kfSwOp, p, _csEaseInOut);
      if (op <= 0.001) return;
      const totalDeg = 168.0;
      final len = 464 * _genRad(totalDeg);
      final drawn =
          ((1400 - _csKf(_kfSwDash, p, _csEaseInOut)) / len).clamp(0.0, 1.0);
      if (drawn <= 0) return;
      canvas.drawPath(
        Path()
          ..addArc(Rect.fromCircle(center: _c, radius: 464), _genRad(startDeg),
              _genRad(totalDeg * drawn)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..shader = _ringShader(op),
      );
    }

    sw(1.7, 141.0); // M151.4,804 A464 … 804,151.4
    sw(1.85, -39.0); // M872.6,220 A464 … 220,872.6
  }

  // 3. Две орбитальные дуги под мягким размытием, медленно вращаются навстречу.
  void _orbits(Canvas canvas) {
    void orb({
      required double r,
      required double startDeg,
      required double sweepDeg,
      required double width,
      required double baseOp,
      required double introDelay,
      required double fromDeg,
      required double spinDur,
      required double spinDelay,
      required bool rev,
    }) {
      final ip = _csP(t, introDelay, 0.9);
      final op = baseOp * _csKf(const [(0.0, 0.0), (1.0, 1.0)], ip, _csOutQuint);
      if (op <= 0.001) return;
      final intro = _csKf([(0.0, fromDeg), (1.0, 0.0)], ip, _csOutQuint);
      // Вращение стартует со своей задержкой и дальше идёт вечно.
      final spin = t < spinDelay
          ? 0.0
          : _csP(t, spinDelay, spinDur, infinite: true) * 360.0 * (rev ? -1 : 1);
      canvas.save();
      canvas.translate(_c.dx, _c.dy);
      canvas.rotate(_genRad(intro + spin));
      canvas.translate(-_c.dx, -_c.dy);
      canvas.drawPath(
        Path()
          ..addArc(Rect.fromCircle(center: _c, radius: r), _genRad(startDeg),
              _genRad(sweepDeg)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = _genOrb.withValues(alpha: op)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.restore();
    }

    orb(
      r: 212, startDeg: 155, sweepDeg: -130, width: 6, baseOp: 0.55,
      introDelay: 1.35, fromDeg: -130, spinDur: 16, spinDelay: 2.25, rev: false,
    );
    orb(
      r: 224, startDeg: 210, sweepDeg: 120, width: 5, baseOp: 0.3,
      introDelay: 1.5, fromDeg: 130, spinDur: 21, spinDelay: 2.4, rev: true,
    );
  }

  // 4. Кольцо r=186 со свечением: раскручивается из точки (scale 0→1, −120°).
  void _ring(Canvas canvas) {
    final p = _csP(t, 0.3, 0.75);
    final op = _csKf(const [(0.0, 0.0), (1.0, 1.0)], p, _csOutQuint);
    if (op <= 0.001) return;
    final s = _csKf(const [(0.0, 0.0), (1.0, 1.0)], p, _csOutQuint);
    final rot = _csKf(const [(0.0, -120.0), (1.0, 0.0)], p, _csOutQuint);
    canvas.save();
    canvas.translate(_c.dx, _c.dy);
    canvas.rotate(_genRad(rot));
    canvas.scale(s);
    canvas.translate(-_c.dx, -_c.dy);
    // filter fGlow = размытие 20 + исходный контур поверх.
    canvas.drawCircle(
      _c,
      186,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 13
        ..shader = _ringShader(op)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );
    canvas.drawCircle(
      _c,
      186,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 13
        ..shader = _ringShader(op),
    );
    canvas.restore();
  }

  // 5. Горизонт событий: чёрный диск r=177, вырастает из центра.
  void _horizon(Canvas canvas) {
    final s = _csKf(const [(0.0, 0.0), (1.0, 1.0)], _csP(t, 0.6, 0.6), _csEaseOut);
    if (s <= 0.001) return;
    canvas.drawCircle(_c, 177 * s, Paint()..color = _genCore);
  }

  // 6. Тонкий контур кольца r=181 (проявляется до .9).
  void _ringOutline(Canvas canvas) {
    final op = _csKf(const [(0.0, 0.0), (1.0, 0.9)], _csP(t, 0.95, 0.4), _csEaseOut);
    if (op <= 0.001) return;
    canvas.drawCircle(
      _c,
      181,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..shader = _ringShader(op),
    );
  }

  // 7. Доплеровский блик r=179: прорисовывается по дуге снизу.
  void _doppler(Canvas canvas) {
    final p = _csP(t, 1.1, 0.7);
    final op = _csKf(_kfDopOp, p, _csEaseInOut);
    if (op <= 0.001) return;
    const totalDeg = -110.0;
    final len = 179 * _genRad(totalDeg.abs());
    final drawn =
        ((360 - _csKf(_kfDopDash, p, _csEaseInOut)) / len).clamp(0.0, 1.0);
    if (drawn <= 0) return;
    final path = Path()
      ..addArc(Rect.fromCircle(center: _c, radius: 179), _genRad(145),
          _genRad(totalDeg * drawn));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = _genDop.withValues(alpha: op);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..color = _genDop.withValues(alpha: op)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );
    canvas.drawPath(path, paint);
  }

  // 8. Хроматические призраки кольца (screen) в момент глитча.
  void _chroma(Canvas canvas) {
    final p = _csP(t, 0.3, 3.9);
    void ghost(Color color, List<(double, double)> op, List<(double, double)> tx,
        List<(double, double)> ty) {
      final o = _csStep(op, p);
      if (o <= 0.001) return;
      canvas.save();
      canvas.translate(_csStep(tx, p), _csStep(ty, p));
      canvas.drawCircle(
        _c,
        186,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..blendMode = BlendMode.screen
          ..color = color.withValues(alpha: o),
      );
      canvas.restore();
    }

    ghost(_genChromA, _kfChromAOp, _kfChromAX, _kfChromAY);
    ghost(_genChromB, _kfChromBOp, _kfChromBX, _kfChromBY);
  }

  // 9. Глитч-полосы (overlay): прошивают круг, не разрывая кольцо.
  void _bands(Canvas canvas) {
    for (final b in _genBands) {
      final p = _csP(t, b.delay, b.dur, infinite: b.infinite);
      final op = _csStep(b.op, p);
      if (op <= 0.001) continue;
      canvas.save();
      canvas.translate(_csStep(b.tx, p), 0);
      canvas.drawRect(
        Rect.fromLTWH(b.x, b.y, b.w, b.h),
        Paint()
          ..blendMode = BlendMode.overlay
          ..color = b.color.withValues(alpha: op),
      );
      canvas.restore();
    }
  }

  // 10. Блипы (overlay): короткие вспышки в случайных точках.
  void _blips(Canvas canvas) {
    for (final b in _genBlips) {
      final p = _csP(t, b.delay, b.dur, infinite: true);
      final op = _csStep(b.op, p);
      if (op <= 0.001) continue;
      canvas.save();
      canvas.translate(_csKf(b.tx, p), _csKf(b.ty, p));
      canvas.drawRect(
        Rect.fromLTWH(b.x, b.y, b.w, b.h),
        Paint()
          ..blendMode = BlendMode.overlay
          ..color = b.color.withValues(alpha: op),
      );
      canvas.restore();
    }
  }

  // 11. Вечный луп: размытые частицы по спирали падают на горизонт и гаснут.
  void _particles(Canvas canvas) {
    final gate = _csKf(const [(0.0, 0.0), (1.0, 0.9)], _csP(t, 3.3, 1.2), _csEaseOut);
    if (gate <= 0.001) return;
    for (final pt in _genParticles) {
      final fp = _csP(t, pt.fallDelay, pt.fallDur, infinite: true);
      final op = (pt.fall2 ? _csKf(_kfFall2Op, fp) : _csKf(_kfFallOp, fp)) * gate;
      if (op <= 0.003) continue;
      final dy = pt.fall2 ? _csKf(_kfFall2Y, fp) : _csKf(_kfFallY, fp);
      final s = pt.fall2 ? _csKf(_kfFall2S, fp) : _csKf(_kfFallS, fp);
      final spin = _csP(t, pt.spinDelay, pt.spinDur, infinite: true) *
          360.0 *
          (pt.rev ? -1 : 1);
      canvas.save();
      canvas.translate(_c.dx, _c.dy);
      canvas.rotate(_genRad(spin));
      canvas.translate(0, dy);
      canvas.scale(s);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: pt.rx * 2, height: pt.ry * 2),
        Paint()
          ..color = pt.color.withValues(alpha: op.clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, pt.blur / s),
      );
      canvas.restore();
    }
  }

  // 12. Дыхание: широкий размытый ореол кольца, 3.6 с, вечно.
  void _breath(Canvas canvas) {
    if (t < 3.2) return;
    final op = _csKf(_kfPulse, _csP(t, 3.2, 3.6, infinite: true), _csEaseInOut);
    if (op <= 0.001) return;
    canvas.drawCircle(
      _c,
      186,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = _genRing2.withValues(alpha: op)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
  }

  // 13. Вспышка из сингулярности — самый первый кадр, поверх всего.
  void _flash(Canvas canvas) {
    final p = _csP(t, 0.15, 0.8);
    final op = _csKf(_kfFlashOp, p, _csEaseOut);
    if (op <= 0.001) return;
    final s = _csKf(_kfFlashScale, p, _csEaseOut);
    canvas.drawCircle(
      _c,
      8 * s,
      Paint()..color = Colors.white.withValues(alpha: op),
    );
  }

  @override
  bool shouldRepaint(_GenesisMarkPainter old) =>
      old.t != t || old.refPx != refPx;
}

/* ==================== ПОДПИСЬ (вариант 01) ==================== */

// Дорожки подписи: тряски/варп блока, дрожание и мерцание в момент выхода,
// хроматические двойники, побуквенные вспышки и полосы-срезы.
const _kfTxJitX = <(double, double)>[
  (0.0, 0.0), (0.08, 7.0), (0.16, -6.0), (0.24, 4.0), (0.32, -8.0),
  (0.40, 3.0), (0.48, -4.0), (0.56, 0.0), (1.0, 0.0),
];
const _kfTxJitY = <(double, double)>[
  (0.0, 0.0), (0.08, -3.0), (0.16, 2.0), (0.24, 4.0), (0.32, -2.0),
  (0.40, 1.0), (0.48, 2.0), (0.56, 0.0), (1.0, 0.0),
];
const _kfTxFlick = <(double, double)>[
  (0.0, 0.0), (0.06, 1.0), (0.10, 0.25), (0.14, 1.0), (0.26, 0.4),
  (0.30, 1.0), (0.44, 0.6), (0.48, 1.0), (1.0, 1.0),
];
const _kfTxChromAOp = <(double, double)>[
  (0.0, 0.0), (0.06, 0.9), (0.18, 0.6), (0.30, 0.8), (0.42, 0.4),
  (0.54, 0.0), (1.0, 0.0),
];
const _kfTxChromAX = <(double, double)>[
  (0.0, 0.0), (0.06, -13.0), (0.18, 9.0), (0.30, -7.0), (0.42, 5.0),
  (0.54, 0.0), (1.0, 0.0),
];
const _kfTxChromAY = <(double, double)>[
  (0.0, 0.0), (0.06, 2.0), (0.18, -2.0), (0.30, 3.0), (0.42, 0.0),
  (0.54, 0.0), (1.0, 0.0),
];
const _kfTxChromBX = <(double, double)>[
  (0.0, 0.0), (0.06, 13.0), (0.18, -9.0), (0.30, 7.0), (0.42, -5.0),
  (0.54, 0.0), (1.0, 0.0),
];
const _kfTxChromBY = <(double, double)>[
  (0.0, 0.0), (0.06, -2.0), (0.18, 2.0), (0.30, -3.0), (0.42, 0.0),
  (0.54, 0.0), (1.0, 0.0),
];
const _kfTxShakeX = <(double, double)>[
  (0.0, 0.0), (0.379, 0.0), (0.38, 9.0), (0.386, -7.0), (0.393, 5.0),
  (0.40, 0.0), (0.889, 0.0), (0.89, -9.0), (0.897, 6.0), (0.904, 0.0),
  (1.0, 0.0),
];
const _kfTxShakeY = <(double, double)>[
  (0.0, 0.0), (0.379, 0.0), (0.38, -3.0), (0.386, 3.0), (0.393, 4.0),
  (0.40, 0.0), (0.889, 0.0), (0.89, 2.0), (0.897, -4.0), (0.904, 0.0),
  (1.0, 0.0),
];
const _kfTxShake2X = <(double, double)>[
  (0.0, 0.0), (0.219, 0.0), (0.22, -8.0), (0.227, 7.0), (0.235, 0.0),
  (0.669, 0.0), (0.67, 10.0), (0.678, -6.0), (0.686, 0.0), (1.0, 0.0),
];
const _kfTxShake2Y = <(double, double)>[
  (0.0, 0.0), (0.219, 0.0), (0.22, 4.0), (0.227, -3.0), (0.235, 0.0),
  (0.669, 0.0), (0.67, 2.0), (0.678, -4.0), (0.686, 0.0), (1.0, 0.0),
];
// txWarp: skewX + масштаб блока подписи.
const _kfTxWarpSkew = <(double, double)>[
  (0.0, 0.0), (0.379, 0.0), (0.38, -13.0), (0.388, 8.0), (0.396, 0.0),
  (0.669, 0.0), (0.67, 11.0), (0.678, -7.0), (0.686, 0.0), (0.889, 0.0),
  (0.89, -9.0), (0.898, 0.0), (1.0, 0.0),
];
const _kfTxWarpSx = <(double, double)>[
  (0.0, 1.0), (0.379, 1.0), (0.38, 1.05), (0.388, 1.0), (0.669, 1.0),
  (0.678, 1.04), (0.686, 1.0), (1.0, 1.0),
];
const _kfTxWarpSy = <(double, double)>[
  (0.0, 1.0), (0.379, 1.0), (0.388, 0.92), (0.396, 1.0), (0.889, 1.0),
  (0.89, 1.1), (0.898, 1.0), (1.0, 1.0),
];
// Побуквенные вспышки (bhLtr1…4).
const _kfLtr1Op = <(double, double)>[
  (0.0, 0.0), (0.118, 0.0), (0.119, 0.95), (0.126, 0.7), (0.133, 0.0),
  (0.568, 0.0), (0.569, 0.85), (0.577, 0.0), (1.0, 0.0),
];
const _kfLtr1Dx = <(double, double)>[
  (0.0, 0.0), (0.119, 0.0), (0.126, 0.0), (0.569, 2.0), (0.577, 0.0), (1.0, 0.0),
];
const _kfLtr1Dy = <(double, double)>[
  (0.0, 0.0), (0.119, -3.0), (0.126, 2.0), (0.133, 0.0), (0.569, 3.0),
  (0.577, 0.0), (1.0, 0.0),
];
const _kfLtr1Skew = <(double, double)>[
  (0.0, 0.0), (0.119, -16.0), (0.126, 10.0), (0.133, 0.0), (0.569, 12.0),
  (0.577, 0.0), (1.0, 0.0),
];
const _kfLtr2Op = <(double, double)>[
  (0.0, 0.0), (0.278, 0.0), (0.279, 0.9), (0.287, 0.6), (0.294, 0.0),
  (0.748, 0.0), (0.749, 0.8), (0.756, 0.0), (1.0, 0.0),
];
const _kfLtr2Dx = <(double, double)>[
  (0.0, 0.0), (0.749, -3.0), (0.756, 0.0), (1.0, 0.0),
];
const _kfLtr2Dy = <(double, double)>[
  (0.0, 0.0), (0.279, 3.0), (0.287, -2.0), (0.294, 0.0), (0.749, -2.0),
  (0.756, 0.0), (1.0, 0.0),
];
const _kfLtr2Skew = <(double, double)>[
  (0.0, 0.0), (0.279, 14.0), (0.287, 0.0), (0.749, -11.0), (0.756, 0.0),
  (1.0, 0.0),
];
const _kfLtr3Op = <(double, double)>[
  (0.0, 0.0), (0.418, 0.0), (0.419, 0.95), (0.425, 0.5), (0.434, 0.0),
  (0.888, 0.0), (0.889, 0.75), (0.898, 0.0), (1.0, 0.0),
];
const _kfLtr3Dx = <(double, double)>[
  (0.0, 0.0), (0.889, 3.0), (0.898, 0.0), (1.0, 0.0),
];
const _kfLtr3Dy = <(double, double)>[
  (0.0, 0.0), (0.419, -4.0), (0.425, 1.0), (0.434, 0.0), (0.889, 2.0),
  (0.898, 0.0), (1.0, 0.0),
];
const _kfLtr3Skew = <(double, double)>[
  (0.0, 0.0), (0.419, 9.0), (0.425, 0.0), (0.889, -13.0), (0.898, 0.0),
  (1.0, 0.0),
];
const _kfLtr4Op = <(double, double)>[
  (0.0, 0.0), (0.068, 0.0), (0.069, 0.85), (0.076, 0.6), (0.084, 0.0),
  (0.638, 0.0), (0.639, 0.9), (0.648, 0.0), (1.0, 0.0),
];
const _kfLtr4Dx = <(double, double)>[
  (0.0, 0.0), (0.639, -2.0), (0.648, 0.0), (1.0, 0.0),
];
const _kfLtr4Dy = <(double, double)>[
  (0.0, 0.0), (0.069, 2.0), (0.076, -3.0), (0.084, 0.0), (0.639, 3.0),
  (0.648, 0.0), (1.0, 0.0),
];
const _kfLtr4Skew = <(double, double)>[
  (0.0, 0.0), (0.069, -10.0), (0.076, 7.0), (0.084, 0.0), (0.639, 15.0),
  (0.648, 0.0), (1.0, 0.0),
];
// Полосы-срезы по подписи.
const _kfTxBand1Op = <(double, double)>[
  (0.0, 0.0), (0.138, 0.0), (0.139, 0.75), (0.147, 0.0), (0.388, 0.0),
  (0.389, 0.6), (0.397, 0.0), (0.728, 0.0), (0.729, 0.5), (0.738, 0.0),
  (1.0, 0.0),
];
const _kfTxBand1X = <(double, double)>[
  (0.0, 0.0), (0.139, -14.0), (0.388, 11.0), (0.728, -8.0), (0.738, 0.0),
  (1.0, 0.0),
];
const _kfTxBand2Op = <(double, double)>[
  (0.0, 0.0), (0.268, 0.0), (0.269, 0.65), (0.278, 0.0), (0.558, 0.0),
  (0.559, 0.5), (0.568, 0.0), (0.888, 0.0), (0.889, 0.45), (0.899, 0.0),
  (1.0, 0.0),
];
const _kfTxBand2X = <(double, double)>[
  (0.0, 0.0), (0.269, 13.0), (0.558, -10.0), (0.888, 7.0), (0.899, 0.0),
  (1.0, 0.0),
];

const String _genesisWordmark = 'Enhanced Voice System';

// Побуквенные вспышки: индекс символа в подписи, цвет, дорожки, тайминг.
class _GenLetter {
  final int index;
  final Color color;
  final List<(double, double)> op, dx, dy, skew;
  final double dur, delay;
  const _GenLetter(this.index, this.color, this.op, this.dx, this.dy, this.skew,
      this.dur, this.delay);
}

const List<_GenLetter> _genLetters = [
  _GenLetter(1, _genRing2, _kfLtr2Op, _kfLtr2Dx, _kfLtr2Dy, _kfLtr2Skew, 7.5, 5.9),
  _GenLetter(4, _genRing1, _kfLtr3Op, _kfLtr3Dx, _kfLtr3Dy, _kfLtr3Skew, 8.8, 6.5),
  _GenLetter(6, _genOrb, _kfLtr4Op, _kfLtr4Dx, _kfLtr4Dy, _kfLtr4Skew, 10.2, 7.1),
  _GenLetter(9, _genRing3, _kfLtr1Op, _kfLtr1Dx, _kfLtr1Dy, _kfLtr1Skew, 11.6, 7.7),
  _GenLetter(12, _genRing2, _kfLtr2Op, _kfLtr2Dx, _kfLtr2Dy, _kfLtr2Skew, 12.9, 8.3),
  _GenLetter(17, _genRing1, _kfLtr3Op, _kfLtr3Dx, _kfLtr3Dy, _kfLtr3Skew, 14.3, 9.0),
  _GenLetter(19, _genOrb, _kfLtr4Op, _kfLtr4Dx, _kfLtr4Dy, _kfLtr4Skew, 15.7, 9.6),
];

// Полоса поверх подписи: доли от габарита блока, высота в CSS-px образца.
class _GenTxBand {
  final double left, top, width, height;
  final Color color;
  final List<(double, double)> op, tx;
  final double dur, delay;
  const _GenTxBand(this.left, this.top, this.width, this.height, this.color,
      this.op, this.tx, this.dur, this.delay);
}

const List<_GenTxBand> _genTxBands = [
  _GenTxBand(0.06, 0.22, 0.22, 4, _genRing3, _kfTxBand1Op, _kfTxBand1X, 8.3, 5.2),
  _GenTxBand(0.42, 0.58, 0.18, 3, _genRing2, _kfTxBand2Op, _kfTxBand2X, 6.9, 5.6),
  _GenTxBand(0.64, 0.34, 0.26, 5, _genRing1, _kfTxBand1Op, _kfTxBand1X, 10.1, 6.0),
  _GenTxBand(0.22, 0.72, 0.20, 3, _genOrb, _kfTxBand2Op, _kfTxBand2X, 12.4, 6.5),
  _GenTxBand(0.50, 0.08, 0.24, 4, _genRing3, _kfTxBand1Op, _kfTxBand1X, 14.7, 7.1),
];

/// Подпись «Enhanced Voice System» с тем же глитчем, что в образце: градиентный
/// основной слой, два хроматических двойника в режиме screen, побуквенные
/// вспышки, полосы-срезы, тряска и варп блока.
class _GenesisTextPainter extends CustomPainter {
  _GenesisTextPainter({
    required this.t,
    required this.fontSize,
    required this.fontFamily,
  });

  final double t;
  final double fontSize;
  final String fontFamily;

  /// Кегль подписи в образце — 12.5 px; сдвиги её дорожек заданы в тех же
  /// пикселях, поэтому масштабируются вместе с кеглем.
  double get _k => fontSize / 12.5;
  double get _tracking => fontSize * 0.14;

  TextStyle get _style => TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: _tracking,
        height: 1.0,
      );

  TextPainter _tp(String s, Color color, {Shader? shader}) => TextPainter(
        text: TextSpan(
          text: s,
          style: shader == null
              ? _style.copyWith(color: color)
              : _style.copyWith(foreground: Paint()..shader = shader),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  // Раскладка по символам: как inline-block спаны в образце (каждый символ —
  // своя ячейка с трекингом после неё). Подпись латинская, поэтому посимвольный
  // split безопасен.
  List<double> _advances(String s) =>
      [for (final ch in s.split('')) _tp(ch, const Color(0xFFFFFFFF)).width];

  static Size measure(String fontFamily, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(
        text: _genesisWordmark.toUpperCase(),
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: fontSize * 0.14,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return Size(tp.width, tp.height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final up = _genesisWordmark.toUpperCase();
    canvas.save();
    // Тряски и варп блока подписи (в CSS-px образца → масштабируем на кегль).
    final sp = _csP(t, 5.4, 11.3, infinite: true);
    final sp2 = _csP(t, 6.1, 7.7, infinite: true);
    canvas.translate(
      (_csStep(_kfTxShakeX, sp) + _csStep(_kfTxShake2X, sp2)) * _k,
      (_csStep(_kfTxShakeY, sp) + _csStep(_kfTxShake2Y, sp2)) * _k,
    );
    final skew = _csStep(_kfTxWarpSkew, sp);
    final sx = _csStep(_kfTxWarpSx, sp);
    final sy = _csStep(_kfTxWarpSy, sp);
    if (skew != 0 || sx != 1 || sy != 1) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.transform((Matrix4.diagonal3Values(sx, sy, 1)
            ..multiply(Matrix4.skewX(_genRad(skew))))
          .storage);
      canvas.translate(-size.width / 2, -size.height / 2);
    }

    // Выход подписи: дрожание + мерцание, 1.5 с с 3.5 с.
    final jp = _csP(t, 3.5, 1.5);
    canvas.translate(_csStep(_kfTxJitX, jp) * _k, _csStep(_kfTxJitY, jp) * _k);
    final flick = _csStep(_kfTxFlick, jp);
    // Появление основного слоя (bhFade .3s 3.5s).
    final fade = _csKf(const [(0.0, 0.0), (1.0, 1.0)], _csP(t, 3.5, 0.3), _csEaseOut);
    if (fade <= 0.001) {
      canvas.restore();
      return;
    }

    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Colors.white.withValues(alpha: (flick * fade).clamp(0.0, 1.0)),
    );

    // Хроматические двойники (screen).
    void ghost(Color color, List<(double, double)> op, List<(double, double)> tx,
        List<(double, double)> ty) {
      final o = _csStep(op, jp);
      if (o <= 0.001) return;
      final tp = TextPainter(
        text: TextSpan(text: up, style: _style.copyWith(color: color.withValues(alpha: o))),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.saveLayer(Offset.zero & size, Paint()..blendMode = BlendMode.screen);
      tp.paint(canvas, Offset(_csStep(tx, jp) * _k, _csStep(ty, jp) * _k));
      canvas.restore();
    }

    ghost(_genChromA, _kfTxChromAOp, _kfTxChromAX, _kfTxChromAY);
    ghost(_genChromB, _kfTxChromAOp, _kfTxChromBX, _kfTxChromBY);

    // Основной слой: градиент 100° по образцу.
    final grad = const LinearGradient(
      begin: Alignment(-1.0, -0.17), // ≈ linear-gradient(100deg, …)
      end: Alignment(1.0, 0.17),
      colors: [_genRing1, _genRing2, _genRing3],
      stops: [0.0, 0.55, 1.0],
    ).createShader(Offset.zero & size);
    _tp(up, Colors.white, shader: grad).paint(canvas, Offset.zero);

    // Побуквенные вспышки: считаем позиции символов той же раскладкой.
    final chars = up.split('');
    final adv = _advances(up);
    for (final l in _genLetters) {
      if (l.index >= adv.length) continue;
      final p = _csP(t, l.delay, l.dur, infinite: true);
      final o = _csStep(l.op, p);
      if (o <= 0.001) continue;
      var x = 0.0;
      for (var i = 0; i < l.index; i++) {
        x += adv[i] + _tracking;
      }
      final ch = chars[l.index];
      canvas.save();
      canvas.translate(x + _csStep(l.dx, p) * _k, _csStep(l.dy, p) * _k);
      final sk = _csStep(l.skew, p);
      if (sk != 0) canvas.transform(Matrix4.skewX(_genRad(sk)).storage);
      canvas.saveLayer(
          Rect.fromLTWH(-fontSize, -fontSize, fontSize * 4, fontSize * 4),
          Paint()..blendMode = BlendMode.screen);
      _tp(ch, l.color.withValues(alpha: o)).paint(canvas, Offset.zero);
      canvas.restore();
      canvas.restore();
    }

    // Полосы-срезы (overlay).
    for (final b in _genTxBands) {
      final p = _csP(t, b.delay, b.dur, infinite: true);
      final o = _csStep(b.op, p);
      if (o <= 0.001) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * b.left + _csStep(b.tx, p) * _k,
          size.height * b.top,
          size.width * b.width,
          b.height * _k,
        ),
        Paint()
          ..blendMode = BlendMode.overlay
          ..color = b.color.withValues(alpha: o),
      );
    }

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GenesisTextPainter old) =>
      old.t != t || old.fontSize != fontSize || old.fontFamily != fontFamily;
}

/* ==================== ВИДЖЕТЫ ==================== */

/// Логотип Genesis. [withText] = вариант 01 (знак + подпись), иначе вариант 05
/// (чистый знак — иконка приложения, «О программе», угол главного экрана).
///
/// Интро (≈3.5 с) проигрывается при каждом монтировании; дальше идёт вечный луп
/// образца (частицы, дыхание, редкие глитч-всплески), но только если это
/// разрешает [MotionPolicy] — иначе знак замирает на «чистом» кадре без глитча.
/// [loop] = false вообще отключает луп (замирает сразу после интро).
class GenesisLogo extends StatefulWidget {
  const GenesisLogo({
    super.key,
    this.size = 30,
    this.withText = false,
    this.loop = true,
    this.ambientGated = true,
    this.stage = _genStage,
    this.onIntroDone,
  });

  final double size;
  final bool withText;
  final bool loop;
  final bool ambientGated;

  /// Цвет собственной сцены знака — см. [_GenesisMarkPainter.stage]. По
  /// умолчанию подложка образца.
  final Color stage;
  final VoidCallback? onIntroDone;

  @override
  State<GenesisLogo> createState() => _GenesisLogoState();
}

class _GenesisLogoState extends State<GenesisLogo>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _t = ValueNotifier<double>(0);
  bool _introDone = false;

  double get _introEnd =>
      widget.withText ? _genIntroEndText : _genIntroEndMark;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    if (widget.ambientGated) MotionPolicy.ambient.addListener(_syncAmbient);
  }

  void _tick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    if (!_introDone && t >= _introEnd) {
      _introDone = true;
      widget.onIntroDone?.call();
      // Интро отыграно — дальше луп только если он разрешён.
      if (!_loopAllowed) {
        _t.value = _genRestT;
        _ticker.stop();
        return;
      }
    }
    _t.value = t;
  }

  bool get _loopAllowed =>
      widget.loop && (!widget.ambientGated || MotionPolicy.ambient.value);

  // Политика движения переключилась — на ходу останавливаем/возобновляем луп.
  void _syncAmbient() {
    if (!mounted || !_introDone) return;
    if (_loopAllowed) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
      _t.value = _genRestT;
    }
  }

  @override
  void dispose() {
    if (widget.ambientGated) MotionPolicy.ambient.removeListener(_syncAmbient);
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final mark = ValueListenableBuilder<double>(
      valueListenable: _t,
      builder: (_, t, __) => CustomPaint(
        size: Size.square(s),
        painter: _GenesisMarkPainter(
          t: t,
          refPx: widget.withText ? 320 : 300,
          stage: widget.stage,
        ),
      ),
    );
    if (!widget.withText) return SizedBox.square(dimension: s, child: mark);

    // Вариант 01: знак, зазор 6 px образца и подпись 12.5 px под ним.
    final fontSize = s * 12.5 / 320;
    final gap = s * 6 / 320;
    // Образец набран Space Grotesk; в проекте своя шрифтовая пара, поэтому
    // подпись идёт бандлед-шрифтом приложения (см. pubspec: Nunito).
    const font = 'Nunito';
    final textSize = _GenesisTextPainter.measure(font, fontSize);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: s, child: mark),
        SizedBox(height: gap),
        ValueListenableBuilder<double>(
          valueListenable: _t,
          builder: (_, t, __) => CustomPaint(
            size: textSize,
            painter: _GenesisTextPainter(
                t: t, fontSize: fontSize, fontFamily: font),
          ),
        ),
      ],
    );
  }
}

/// Рисует ОДИН кадр знака в момент [t] (сек от старта) — точка входа для
/// отрисовки логотипа без виджетов и тикера: офлайн-сверка кадров с
/// html-образцом, экспорт статичного кадра в картинку.
void paintGenesisMark(Canvas canvas, Size size, double t, {double refPx = 300}) =>
    _GenesisMarkPainter(t: t, refPx: refPx).paint(canvas, size);

/// То же для подписи «Enhanced Voice System» (вариант 01). [size] — габарит
/// блока подписи, см. [genesisSignatureSize].
void paintGenesisSignature(Canvas canvas, Size size, double t, double fontSize,
        {String fontFamily = 'Nunito'}) =>
    _GenesisTextPainter(t: t, fontSize: fontSize, fontFamily: fontFamily)
        .paint(canvas, size);

/// Габарит блока подписи при кегле [fontSize].
Size genesisSignatureSize(double fontSize, {String fontFamily = 'Nunito'}) =>
    _GenesisTextPainter.measure(fontFamily, fontSize);

/// Фон сплеша — та же подложка, что в образце (радиальный подсвет сверху на
/// почти чёрном). Логотип фиксированный, поэтому и фон под ним фиксированный.
BoxDecoration get genesisBackdrop => const BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0.0, -1.0),
        radius: 1.1,
        colors: [_genBgTop, _genBgBase],
        stops: [0.0, 0.55],
      ),
    );
