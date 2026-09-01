part of '../main.dart';

/* ==========================================================================
   «ПРИЗМА» — экран приветствия
   --------------------------------------------------------------------------
   Раскладка из макета (handoff/design, блок `isOnboard`): марка с версией,
   крупный заголовок с градиентной второй строкой, подпись, поле запроса в
   градиентной рамке, четыре подсказки и белая кнопка «Открыть EVS».

   Экран НЕ декоративный: набранное в поле уходит в тот же `app.sendMessage`,
   что и обычный чат, а нажатая подсказка — тоже, слово в слово. То есть с
   первого экрана можно начать работать, а не «ознакомиться и закрыть».

   Показывается поверх оболочки один раз за запуск и только в «Призме»:
   у трёх других стилей такого экрана в макете нет, и заводить его там было бы
   выдумкой. Галочка внизу пишет `prismWelcome` в настройки — ту же, что стоит
   в разделе «Общие».

   Заставка запуска (ImmersiveSplash) при этом остаётся на месте: она играет
   ДО окна, этот экран — первое, что видно ВНУТРИ окна.
   ========================================================================== */

class PrismWelcome extends StatefulWidget {
  const PrismWelcome({super.key, required this.onDone});

  /// Закрыть приветствие. Строка непустая — её надо отправить в новый чат.
  final void Function(String? send) onDone;

  @override
  State<PrismWelcome> createState() => _PrismWelcomeState();
}

class _PrismWelcomeState extends State<PrismWelcome>
    with SingleTickerProviderStateMixin {
  final _input = TextEditingController();

  /// `animation: rise .4s ease both` из макета — появление снизу с проявлением.
  late final AnimationController _rise = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  )..forward();

  @override
  void dispose() {
    _input.dispose();
    _rise.dispose();
    super.dispose();
  }

  void _send() {
    final t = _input.text.trim();
    widget.onDone(t.isEmpty ? null : t);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Material(
      color: _bg(context),
      child: Stack(
        children: [
          // Тот же фон и та же сетка, что у оболочки: приветствие — это первый
          // экран программы, а не отдельное окно с другим оформлением.
          const Positioned.fill(child: _PrismBackdrop()),
          const Positioned.fill(child: _PrismDotGrid()),
          // Окно без рамки: за приветствие тоже надо иметь возможность взяться.
          const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
          Positioned(
            right: 0,
            top: 0,
            child: Row(
              children: [
                _WinBtn(Icons.remove, () => windowManager.minimize()),
                _WinBtn(Icons.close, () => windowManager.close(), danger: true),
              ],
            ),
          ),
          Positioned.fill(
            child: FadeTransition(
              opacity: _rise,
              child: AnimatedBuilder(
                animation: _rise,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, 10 * (1 - Curves.easeOut.transform(_rise.value))),
                  child: child,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(40),
                  child: Center(child: _content(app)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(AppState app) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _brand(app),
        const SizedBox(height: 26),
        _headline(app),
        const SizedBox(height: 26),
        _composer(app),
        const SizedBox(height: 26),
        _chips(app),
        const SizedBox(height: 26),
        _finish(app),
      ],
    );
  }

  /// Марка с названием и версией — таблетка на стекле.
  Widget _brand(AppState app) {
    return PrismPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(8, 7, 15, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Знак — существующая анимация EVS, а не свой значок: марка у
          // программы одна на все экраны.
          const _EvsLogoMark(size: 26),
          const SizedBox(width: 10),
          Text(
            app.t('prismWelcomeBrand'),
            style: PrismType.label
                .copyWith(color: _body(context), fontSize: 12),
          ),
          const SizedBox(width: 10),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: _prismChip(context),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                snap.data == null ? '—' : 'v${snap.data!.version}',
                style: PrismType.numeric
                    .copyWith(color: _sub(context), fontSize: 10.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Заголовок: первая строка обычная, вторая залита акцентной тройкой.
  Widget _headline(AppState app) {
    // 64px в макете — при узком окне столько не влезает, поэтому размер
    // считается от ширины и вниз не проваливается ниже читаемого.
    final w = MediaQuery.sizeOf(context).width;
    final size = w < 900 ? math.max(34.0, w / 20) : 64.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                app.t('prismWelcomeTitle1'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size,
                  height: 1.02,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -size * 0.045,
                  color: _txt(context),
                ),
              ),
              PrismGradientText(
                app.t('prismWelcomeTitle2'),
                style: TextStyle(
                  fontSize: size,
                  height: 1.02,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -size * 0.045,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            app.t('prismWelcomeSub'),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 17, height: 1.5, color: _sub(context)),
          ),
        ),
      ],
    );
  }

  /// Поле запроса в градиентной рамке в 1px — так это сделано в макете
  /// (внешний блок залит градиентом, внутренний перекрывает его собой).
  Widget _composer(AppState app) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Container(
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          gradient: _ramp(context).badge,
          borderRadius: BorderRadius.circular(29),
          boxShadow: [
            BoxShadow(
              color: _ramp(context).a2.withValues(alpha: 0.28),
              offset: const Offset(0, 22),
              blurRadius: 60,
            ),
          ],
        ),
        child: PrismPanel(
          radius: 28,
          border: false,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _input,
                autofocus: true,
                onSubmitted: (_) => _send(),
                style: TextStyle(fontSize: 16, color: _txt(context)),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  hintText: app.t('prismWelcomeAsk'),
                  hintStyle:
                      TextStyle(fontSize: 16, color: _faint(context)),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  // Где считает модель. Не выбор из воздуха: подсвечен
                  // сегодняшний `inferenceMode`, а нажатие на второй ведёт
                  // туда, где его меняют по-настоящему, — в настройки моделей.
                  _modePill(app, app.t('prismWhereLocal'),
                      app.inferenceMode == 'local'),
                  const SizedBox(width: 9),
                  _modePill(app, app.t('prismWelcomeOwnServer'),
                      app.inferenceMode != 'local'),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _send,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: _ramp(context).badge,
                          boxShadow: [
                            BoxShadow(
                              color: _ramp(context)
                                  .a2
                                  .withValues(alpha: 0.4),
                              offset: const Offset(0, 8),
                              blurRadius: 22,
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const PrismIcon(PrismIcons.send,
                            size: 17, stroke: 2.2, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modePill(AppState app, String label, bool active) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          // Навигатор берём ДО закрытия приветствия: onDone убирает этот
          // экран из дерева, и context после него уже недействителен.
          final nav = Navigator.of(context);
          widget.onDone(null);
          nav.push(MaterialPageRoute<void>(
            builder: (_) => const DesktopSettings(initialPage: _Pages.llmConn),
          ));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: active ? _prismChip(context) : null,
            borderRadius: BorderRadius.circular(999),
            border: active ? Border.all(color: _stroke(context)) : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: active ? _body(context) : _faint(context),
            ),
          ),
        ),
      ),
    );
  }

  /// Подсказки. Нажатая уходит в чат тем же путём, что и набранная руками, —
  /// это не ярлык «посмотреть», а начатый разговор.
  Widget _chips(AppState app) {
    const keys = [
      'prismWelcomeChip1',
      'prismWelcomeChip2',
      'prismWelcomeChip3',
      'prismWelcomeChip4',
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: [
          for (final k in keys)
            _WelcomeChip(
              label: app.t(k),
              onTap: () => widget.onDone(app.t(k)),
            ),
        ],
      ),
    );
  }

  Widget _finish(AppState app) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => widget.onDone(null),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
              decoration: BoxDecoration(
                color: _prismBtn(context),
                borderRadius: BorderRadius.circular(999),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x47000000),
                      offset: Offset(0, 12),
                      blurRadius: 32),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    app.t('prismWelcomeOpen'),
                    // Кнопка светлая — тёмный текст без тёмной обводки.
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _prismBtnFg(context),
                      shadows: const [],
                    ),
                  ),
                  const SizedBox(width: 9),
                  PrismIcon(PrismIcons.forward,
                      size: 16, stroke: 2.2, color: _prismBtnFg(context)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => app.setPrismWelcome(!app.prismWelcome),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    color: app.prismWelcome ? null : _ramp(context).a2,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: app.prismWelcome
                          ? _prismStroke2(context)
                          : _ramp(context).a2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: app.prismWelcome
                      ? null
                      : const Icon(Icons.check,
                          size: 11, color: Colors.white),
                ),
                const SizedBox(width: 9),
                Text(
                  app.t('prismWelcomeDontShow'),
                  style:
                      TextStyle(fontSize: 12.5, color: _faint(context)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _WelcomeChip extends StatefulWidget {
  const _WelcomeChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_WelcomeChip> createState() => _WelcomeChipState();
}

class _WelcomeChipState extends State<_WelcomeChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: PrismPanel(
          radius: 999,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          color: _hover ? _prismHover(context) : null,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: _hover ? _txt(context) : _body(context),
            ),
          ),
        ),
      ),
    );
  }
}
