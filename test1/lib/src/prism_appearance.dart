part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — блок «Внешний вид» в настройках
   --------------------------------------------------------------------------
   Раскладка из макета (блок `c.isAppearance`): тема и фон — карточками с
   живым превью, акцент, анимация градиента, панели и сетка точек — пилюлями,
   под каждой группой строка-пояснение, что выбранный вариант делает.

   Обычными строками (`evsRow`) это НЕ рисуется намеренно. Выбор оформления —
   единственное место в настройках, где важно, как вариант ВЫГЛЯДИТ, а не как
   он называется: «Аврора» и «Шейдер» словами не различить, а превью различает
   их с одного взгляда. Поэтому здесь свои карточки, а не общая строка.

   Значения выбранного — из макета: контур `--a2`, заливка `--accsoft`, кольцо
   `0 0 0 1px --a2`. У акцента иначе: там кружок и так цветной, поэтому
   выбранный отмечается свечением вокруг него, а не заливкой пилюли.
   ========================================================================== */

/// Заголовок группы: мелкий, в разрядку, верхним регистром.
Widget _prismGroup(BuildContext context, String title, Widget body,
    {String? hint}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PrismSectionLabel(title, size: 10.5),
        const SizedBox(height: 11),
        body,
        if (hint != null) ...[
          const SizedBox(height: 9),
          Text(hint,
              style: TextStyle(
                  fontSize: 11.5, height: 1.45, color: _faint(context))),
        ],
      ],
    ),
  );
}

/// Пилюля выбора. [dot] — кружок слева (акцент, анимация градиента).
class PrismChoicePill extends StatefulWidget {
  const PrismChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot,
    this.glowWhenSelected = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? dot;

  /// Отмечать выбранный свечением, а не заливкой. Так в макете помечен акцент:
  /// заливать пилюлю под цветным кружком нечем — она и так пёстрая.
  final bool glowWhenSelected;

  @override
  State<PrismChoicePill> createState() => _PrismChoicePillState();
}

class _PrismChoicePillState extends State<PrismChoicePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final r = _ramp(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: widget.dot == null
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
              : const EdgeInsets.fromLTRB(11, 10, 15, 10),
          decoration: BoxDecoration(
            color: widget.glowWhenSelected
                ? (on || _hover ? _prismChip(context) : Colors.transparent)
                : (on
                    ? _prismAccentSoft(context)
                    : (_hover ? _prismHover(context) : _prismField(context))),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.glowWhenSelected
                  ? (on ? _prismStroke2(context) : _stroke(context))
                  : (on ? r.a2 : _stroke(context)),
            ),
            boxShadow: on && !widget.glowWhenSelected
                ? [BoxShadow(color: r.a2, blurRadius: 0, spreadRadius: 1)]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.dot != null) ...[
                widget.dot!,
                const SizedBox(width: 10),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: on || _hover ? _txt(context) : _body(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Карточка выбора с превью: картинка сверху, подпись и галочка снизу.
class PrismPreviewCard extends StatefulWidget {
  const PrismPreviewCard({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.preview,
    this.previewHeight = 56,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget preview;
  final double previewHeight;

  @override
  State<PrismPreviewCard> createState() => _PrismPreviewCardState();
}

class _PrismPreviewCardState extends State<PrismPreviewCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final r = _ramp(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: on
                ? _prismAccentSoft(context)
                : (_hover ? _prismHover(context) : _prismField(context)),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: on ? r.a2 : _stroke(context)),
            // Кольцо в один пиксель поверх рамки — `0 0 0 1px var(--a2)`.
            boxShadow:
                on ? [BoxShadow(color: r.a2, spreadRadius: 1)] : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: widget.previewHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: widget.preview,
                ),
              ),
              const SizedBox(height: 11),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _txt(context)),
                    ),
                  ),
                  if (on)
                    Icon(Icons.check, size: 14, color: r.a2),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Превью темы: подложка, две полоски текста и цветное пятно в углу.
class _PrismThemePreview extends StatelessWidget {
  const _PrismThemePreview({required this.mode});
  final AppThemeMode mode;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final pal = skinFor(AppStyle.prism, mode, accent: app.prismAccent).pal;
    final dark = pal.brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF141E32);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: pal.bg)),
        Positioned(
          right: -14,
          bottom: -22,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 11, sigmaY: 11),
            child: Container(
              width: 60,
              height: 44,
              decoration: BoxDecoration(
                color: _prismRamp(app.prismAccent).a2,
                borderRadius: BorderRadius.circular(30),
              ),
            ),
          ),
        ),
        Positioned(
          left: 9,
          top: 9,
          child: _bar(ink, 0.5, 9, 52),
        ),
        Positioned(
          left: 9,
          top: 24,
          child: _bar(ink, 0.2, 7, 86),
        ),
      ],
    );
  }

  Widget _bar(Color ink, double alpha, double h, double w) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: ink.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(5),
        ),
      );
}

/// Превью фона: подложка, размытое свечение и точки поверх.
class _PrismBgPreview extends StatelessWidget {
  const _PrismBgPreview({required this.kind});
  final PrismBackground kind;

  @override
  Widget build(BuildContext context) {
    final r = _ramp(context);
    final a = _auroraPal(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
            color: kind == PrismBackground.off
                ? _prismChip(context)
                : const Color(0xFF0B0D13)),
        if (kind == PrismBackground.spots)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.56, 1.4),
                  radius: 0.9,
                  colors: [r.a1, r.a2.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        // Аврора: полосы света снизу, той же яркой тройкой, какой её красит
        // сам шейдер, — иначе карточка обещает одно, а включается другое.
        if (kind == PrismBackground.shader)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final (c, at, w) in [
                  (a.a2, -0.62, 0.42),
                  (a.a1, -0.05, 0.5),
                  (a.a3, 0.58, 0.36),
                ])
                  Align(
                    alignment: Alignment(at, 1.15),
                    child: FractionallySizedBox(
                      widthFactor: w,
                      heightFactor: 1.5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [c, c.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        // Сетка точек поверх — она рисуется на любом фоне, и превью должно
        // это показывать, иначе «Без фона» выглядит как «без всего».
        CustomPaint(
          painter: _PrismDotsPreviewPainter(
            color: Colors.white.withValues(
                alpha: kind == PrismBackground.off ? 0.18 : 0.28),
          ),
        ),
      ],
    );
  }
}

class _PrismDotsPreviewPainter extends CustomPainter {
  _PrismDotsPreviewPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var y = 3.0; y < size.height; y += 7) {
      for (var x = 3.0; x < size.width; x += 7) {
        canvas.drawCircle(Offset(x, y), 0.8, p);
      }
    }
  }

  @override
  bool shouldRepaint(_PrismDotsPreviewPainter old) => old.color != color;
}

/// Кружок акцента: та же тройка, что красит оболочку.
class _PrismAccentDot extends StatelessWidget {
  const _PrismAccentDot({required this.accent, required this.glow});
  final PrismAccent accent;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final r = _prismRamp(accent);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [r.a1, r.a2, r.a3],
        ),
        boxShadow: glow
            ? [BoxShadow(color: r.a2.withValues(alpha: 0.6), blurRadius: 14)]
            : null,
      ),
    );
  }
}

/// Кружок анимации градиента — он и есть образец: крутится ровно так, как
/// будет крутиться оформление, если выбрать этот вариант.
class _PrismAnimDot extends StatefulWidget {
  const _PrismAnimDot({
    required this.mode,
    required this.glow,
    this.speed,
  });
  final PrismAnim mode;
  final bool glow;

  /// Скорость, которую показывает ЭТОТ кружок. Пусто — берётся выбранная.
  /// В строке выбора скорости у каждой пилюли своя, иначе четыре образца
  /// крутились бы одинаково и выбирать было бы не из чего.
  final PrismAnimSpeed? speed;

  @override
  State<_PrismAnimDot> createState() => _PrismAnimDotState();
}

class _PrismAnimDotState extends State<_PrismAnimDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _period(widget.mode),
  );
  late final AmbientMotion _gate =
      AmbientMotion(_c, gate: MotionGate.foreground);

  static Duration _period(PrismAnim m) => switch (m) {
        PrismAnim.breathe => const Duration(milliseconds: 6000),
        PrismAnim.flow => const Duration(milliseconds: 3400),
        PrismAnim.pulse => const Duration(milliseconds: 2400),
        PrismAnim.off => const Duration(seconds: 1),
      };

  @override
  void dispose() {
    _gate.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == PrismAnim.off) return _dot(context, 1);
    // Образец идёт с той же скоростью, что и оформление: иначе кружок обещает
    // одно, а после нажатия видно другое. Периоды у него свои — он маленький,
    // и макетные семнадцать секунд на нём просто не читались бы.
    final sp = widget.speed ??
        context.select<AppState, PrismAnimSpeed>((a) => a.prismAnimSpeed);
    final want = Duration(
        milliseconds:
            (_period(widget.mode).inMilliseconds / prismAnimFactor(sp)).round());
    if (_c.duration != want) {
      _c.duration = want;
      if (_c.isAnimating) _c.repeat();
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => _dot(context, _c.value),
    );
  }

  Widget _dot(BuildContext context, double t) {
    final r = _ramp(context);
    Widget dot = Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [r.a1, r.a2, r.a3],
          stops: const [0, 0.52, 1],
          // «Перелив» двигает точку отсчёта градиента — CSS в макете двигает
          // background-position у полосы шириной 220%.
          transform: widget.mode == PrismAnim.flow
              ? GradientRotation(t * 2 * math.pi)
              : null,
        ),
        boxShadow: widget.glow
            ? [BoxShadow(color: r.a2.withValues(alpha: 0.6), blurRadius: 14)]
            : null,
      ),
    );
    // Кружок красится ТЕМ ЖЕ фильтром, что и оформление: разойдись эти две
    // формулы, и образец в настройках обещал бы одно, а на экране шло другое.
    // «Перелив» из фильтра исключён — он двигает саму заливку, выше.
    if (widget.mode != PrismAnim.flow) {
      dot = ColorFiltered(
        colorFilter: prismAnimFilter(widget.mode, t),
        child: dot,
      );
    }
    return dot;
  }
}

/// Карточка «Внешний вид» стиля целиком.
class PrismAppearanceCard extends StatelessWidget {
  const PrismAppearanceCard({super.key, this.onWelcome});

  /// Показать экран приветствия прямо сейчас. Пусто — ссылки не будет:
  /// в окне настроек показывать его некуда, оболочки под ним нет.
  final VoidCallback? onWelcome;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PrismPanel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      shadow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismSectionLabel(app.t('prismLook'), size: 10.5),
          const SizedBox(height: 16),

          // --- Тема ---------------------------------------------------------
          _prismGroup(
            context,
            app.t('themeMode'),
            Row(
              children: [
                for (final m in AppThemeMode.values) ...[
                  if (m != AppThemeMode.values.first) const SizedBox(width: 12),
                  Expanded(
                    child: PrismPreviewCard(
                      label: app.t(switch (m) {
                        AppThemeMode.dark => 'themeDark',
                        AppThemeMode.claude => 'themeClaude',
                        AppThemeMode.claudeDark => 'themeClaudeDark',
                      }),
                      selected: app.themeMode == m,
                      onTap: () => app.setThemeMode(m),
                      preview: _PrismThemePreview(mode: m),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // --- Акцент -------------------------------------------------------
          _prismGroup(
            context,
            app.t('prismAccent'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (a, key) in const [
                  (PrismAccent.google, 'prismAccentGoogle'),
                  (PrismAccent.aurora, 'prismAccentAurora'),
                  (PrismAccent.sunset, 'prismAccentSunset'),
                  (PrismAccent.mint, 'prismAccentMint'),
                ])
                  PrismChoicePill(
                    label: app.t(key),
                    selected: app.prismAccent == a,
                    glowWhenSelected: true,
                    dot: _PrismAccentDot(
                        accent: a, glow: app.prismAccent == a),
                    onTap: () => app.setPrismAccent(a),
                  ),
              ],
            ),
            hint: app.t('prismAccentDesc'),
          ),

          // --- Анимация градиента -------------------------------------------
          _prismGroup(
            context,
            app.t('prismAnim'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (m, key) in const [
                  (PrismAnim.breathe, 'prismAnimBreathe'),
                  (PrismAnim.flow, 'prismAnimFlow'),
                  (PrismAnim.pulse, 'prismAnimPulse'),
                  (PrismAnim.off, 'prismAnimOff'),
                ])
                  PrismChoicePill(
                    label: app.t(key),
                    selected: app.prismAnim == m,
                    glowWhenSelected: true,
                    dot: _PrismAnimDot(mode: m, glow: app.prismAnim == m),
                    onTap: () => app.setPrismAnim(m),
                  ),
              ],
            ),
            hint: app.t(switch (app.prismAnim) {
              PrismAnim.breathe => 'prismAnimBreatheDesc',
              PrismAnim.flow => 'prismAnimFlowDesc',
              PrismAnim.pulse => 'prismAnimPulseDesc',
              PrismAnim.off => 'prismAnimOffDesc',
            }),
          ),

          // --- Скорость анимации --------------------------------------------
          // Показывается только когда есть чему идти: у «Без анимации» скорость
          // ничего не значит, и строка выбора, которая ни на что не влияет,
          // хуже отсутствующей.
          if (app.prismAnim != PrismAnim.off)
            _prismGroup(
              context,
              app.t('prismAnimSpeed'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final (sp, key) in const [
                    (PrismAnimSpeed.calm, 'prismAnimSpeedCalm'),
                    (PrismAnimSpeed.normal, 'prismAnimSpeedNormal'),
                    (PrismAnimSpeed.fast, 'prismAnimSpeedFast'),
                    (PrismAnimSpeed.rapid, 'prismAnimSpeedRapid'),
                  ])
                    PrismChoicePill(
                      label: app.t(key),
                      selected: app.prismAnimSpeed == sp,
                      glowWhenSelected: true,
                      dot: _PrismAnimDot(
                          mode: app.prismAnim,
                          speed: sp,
                          glow: app.prismAnimSpeed == sp),
                      onTap: () => app.setPrismAnimSpeed(sp),
                    ),
                ],
              ),
              hint: app.t('prismAnimSpeedDesc'),
            ),

          // --- Панели -------------------------------------------------------
          _prismGroup(
            context,
            app.t('prismGlass'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (g, key) in const [
                  (PrismGlass.glass, 'prismGlassGlass'),
                  (PrismGlass.frost, 'prismGlassFrost'),
                  (PrismGlass.solid, 'prismGlassSolid'),
                ])
                  PrismChoicePill(
                    label: app.t(key),
                    selected: app.prismGlass == g,
                    onTap: () => app.setPrismGlass(g),
                  ),
              ],
            ),
            hint: app.t(switch (app.prismGlass) {
              PrismGlass.frost => 'prismGlassFrostDesc',
              PrismGlass.solid || PrismGlass.off => 'prismGlassSolidDesc',
              PrismGlass.glass => 'prismGlassGlassDesc',
            }),
          ),

          // --- Фон ----------------------------------------------------------
          _prismGroup(
            context,
            app.t('prismBackground'),
            Row(
              children: [
                for (final (b, key) in const [
                  (PrismBackground.spots, 'prismBackgroundSpots'),
                  (PrismBackground.shader, 'prismBackgroundShader'),
                  (PrismBackground.off, 'prismBackgroundOff'),
                ]) ...[
                  if (b != PrismBackground.spots) const SizedBox(width: 12),
                  Expanded(
                    child: PrismPreviewCard(
                      label: app.t(key),
                      selected: app.prismBackground == b,
                      previewHeight: 52,
                      onTap: () => app.setPrismBackground(b),
                      preview: _PrismBgPreview(kind: b),
                    ),
                  ),
                ],
              ],
            ),
            hint: app.t(switch (app.prismBackground) {
              PrismBackground.spots => 'prismBackgroundSpotsDesc',
              PrismBackground.shader => 'prismBackgroundShaderDesc',
              PrismBackground.off => 'prismBackgroundOffDesc',
            }),
          ),

          // --- Сетка точек --------------------------------------------------
          _prismGroup(
            context,
            app.t('prismDots'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (d, key) in const [
                  (PrismDots.push, 'prismDotsPush'),
                  (PrismDots.glow, 'prismDotsGlow'),
                  (PrismDots.off, 'prismDotsOff'),
                ])
                  PrismChoicePill(
                    label: app.t(key),
                    selected: app.prismDots == d,
                    onTap: () => app.setPrismDots(d),
                  ),
              ],
            ),
            hint: app.t(switch (app.prismDots) {
              PrismDots.push => 'prismDotsPushDesc',
              PrismDots.glow => 'prismDotsGlowDesc',
              PrismDots.off => 'prismDotsOffDesc',
            }),
          ),

          // Галочка приветствия — обычной строкой: это переключатель, а не
          // выбор оформления, и превью ему не нужно.
          evsRow(
            context,
            label: app.t('prismWelcomeSetting'),
            desc: app.t('prismWelcomeSettingDesc'),
            control:
                evsToggle(context, app.prismWelcome, app.setPrismWelcome),
          ),

          if (onWelcome != null)
            Align(
              alignment: Alignment.centerLeft,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onWelcome,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        app.t('prismShowWelcome'),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _ramp(context).a1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      PrismIcon(PrismIcons.forward,
                          size: 14, stroke: 2.2, color: _ramp(context).a1),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
