import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'models/evs_models.dart';
import 'widgets/floating_widget.dart';

/// Второй entry point — окно плавающего виджета.
/// Запуск: flutter run -t lib/main_widget.dart
///
/// В настоящем приложении окно создаётся из основного процесса
/// (desktop_multi_window или свой канал), а состояние ассистента
/// приходит по сокету/каналу и подставляется в FloatingWidget.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(180, 180),
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
      skipTaskbar: true,
      alwaysOnTop: true,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(false);
      await windowManager.setIgnoreMouseEvents(false);
      await windowManager.show();
    },
  );

  runApp(const _WidgetApp());
}

class _WidgetApp extends StatefulWidget {
  const _WidgetApp();

  @override
  State<_WidgetApp> createState() => _WidgetAppState();
}

class _WidgetAppState extends State<_WidgetApp> {
  VoiceState _state = VoiceState.idle;

  @override
  Widget build(BuildContext context) => FloatingWidgetApp(
        state: _state,
        style: 'Сфера',
        size: FloatingSize.medium,
        onOpenChat: () => windowManager.hide(),
      );
}
