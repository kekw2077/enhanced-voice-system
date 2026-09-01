import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../evs_tokens.dart';
import '../evs_theme.dart';
import '../models/evs_models.dart';
import 'viz_visual.dart';

/// Плавающий виджет — визуализация в маленьком прозрачном окне поверх
/// остальных. Двойной клик возвращает в чат, перетаскивание двигает окно.
///
/// Само окно создаётся снаружи. На десктопе через window_manager:
///
///   await windowManager.ensureInitialized();
///   await windowManager.waitUntilReadyToShow(
///     const WindowOptions(
///       size: Size(200, 200),
///       backgroundColor: Colors.transparent,
///       titleBarStyle: TitleBarStyle.hidden,
///       skipTaskbar: true,
///       alwaysOnTop: true,
///     ), () async {
///       await windowManager.setAsFrameless();
///       await windowManager.setHasShadow(false);
///       await windowManager.show();
///     });
///
/// и runApp(FloatingWidgetApp(...)). В pubspec: window_manager: ^0.4.2
class FloatingWidget extends StatefulWidget {
  const FloatingWidget({
    super.key,
    required this.state,
    this.style = 'Сфера',
    this.size = FloatingSize.medium,
    this.onOpenChat,
    this.onDragStart,
    this.onTap,
  });

  final VoiceState state;
  final String style;
  final FloatingSize size;
  final VoidCallback? onOpenChat, onDragStart, onTap;

  @override
  State<FloatingWidget> createState() => _FloatingWidgetState();
}

enum FloatingSize { small, medium, large }

extension FloatingSizeValue on FloatingSize {
  double get px => switch (this) {
        FloatingSize.small => 108,
        FloatingSize.medium => 156,
        FloatingSize.large => 216,
      };

  String get label => switch (this) {
        FloatingSize.small => 'Маленький',
        FloatingSize.medium => 'Средний',
        FloatingSize.large => 'Большой',
      };

  static FloatingSize fromLabel(String s) => switch (s) {
        'Маленький' => FloatingSize.small,
        'Большой' => FloatingSize.large,
        _ => FloatingSize.medium,
      };
}

class _FloatingWidgetState extends State<FloatingWidget> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);
    final p = t.palette;
    final s = widget.size.px;
    final st = widget.state;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onOpenChat,
        onPanStart: (_) => widget.onDragStart?.call(),
        child: SizedBox(
          width: s,
          height: s,
          child: Stack(alignment: Alignment.center, children: [
            // Подложка появляется только под курсором — иначе виджет
            // висит на рабочем столе одной визуализацией.
            AnimatedOpacity(
              duration: EvsMotion.hover,
              opacity: _hover ? 1 : 0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(s / 2),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.card,
                      shape: BoxShape.circle,
                      border: Border.all(color: p.stroke),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(s * 0.08),
              child: VizVisual(style: widget.style, state: st, size: s * 0.84),
            ),
            AnimatedPositioned(
              duration: EvsMotion.hover,
              bottom: _hover ? 10 : -20,
              child: AnimatedOpacity(
                duration: EvsMotion.hover,
                opacity: _hover ? 1 : 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: p.solid, borderRadius: BorderRadius.circular(EvsRadius.chip)),
                  child: Text(st.label,
                      style: EvsType.label.copyWith(fontSize: 10.5, color: st.isIdle ? p.sub : st.c1)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Готовое приложение для окна виджета — то, что передаётся в runApp
/// во втором entry point (например lib/main_widget.dart).
class FloatingWidgetApp extends StatelessWidget {
  const FloatingWidgetApp({super.key, required this.state, this.style = 'Сфера',
    this.size = FloatingSize.medium, this.onOpenChat});

  final VoiceState state;
  final String style;
  final FloatingSize size;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) => EvsApp(
        builder: (context) => Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: FloatingWidget(state: state, style: style, size: size, onOpenChat: onOpenChat),
          ),
        ),
      );
}
