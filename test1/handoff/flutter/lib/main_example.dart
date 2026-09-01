import 'package:flutter/material.dart';
import 'evs_theme.dart';
import 'evs_tokens.dart';
import 'services/evs_prefs.dart';
import 'models/evs_models.dart';
import 'widgets/app_shell.dart';
import 'widgets/floating_widget.dart';
import 'screens/hub_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/commands_screen.dart';
import 'screens/modules_screen.dart';
import 'screens/images_screen.dart';
import 'screens/voice_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/welcome_screen.dart';

/// Точка входа: настройки читаются с диска, затем экран приветствия
/// и оболочка с семью экранами.
Future<void> main() async {
  final prefs = await EvsPrefs.load();
  runApp(EvsApp(
    initial: prefs.theme,
    onChanged: prefs.saveTheme,
    builder: (_) => EvsRoot(prefs: prefs),
  ));
}

const _nav = [
  EvsNavItem('hub', 'Центр', Icons.home_outlined, '⌘1'),
  EvsNavItem('chat', 'Диалог', Icons.chat_bubble_outline, '⌘2'),
  EvsNavItem('cmd', 'Команды', Icons.terminal_outlined, '⌘3'),
  EvsNavItem('mon', 'Модули', Icons.monitor_heart_outlined, '⌘4'),
  EvsNavItem('img', 'Nexus Lumina', Icons.auto_awesome_outlined, '⌘5'),
  EvsNavItem('tts', 'Nexus Sonora', Icons.mic_none_rounded, '⌘6'),
  EvsNavItem('set', 'Настройки', Icons.tune, '⌘,'),
];

const _titles = {
  'hub': ['Центр управления', 'Одно окно на весь ассистент: голос, диалог и подсистемы'],
  'chat': ['Диалог', 'Приватный ИИ для письма, планирования, кода и повседневных вопросов'],
  'cmd': ['Голосовые команды', 'Фразы, которые управляют компьютером'],
  'mon': ['Модули', 'Состояние нейросети, распознавания и синтеза'],
  'img': ['Nexus Lumina', 'Генерация изображений локальной моделью'],
  'tts': ['Nexus Sonora', 'Синтез речи и клон голоса'],
  'set': ['Настройки', '11 разделов: от микрофона до приватности'],
};

class EvsRoot extends StatefulWidget {
  const EvsRoot({super.key, required this.prefs});
  final EvsPrefs prefs;

  @override
  State<EvsRoot> createState() => _EvsRootState();
}

class _EvsRootState extends State<EvsRoot> {
  String _screen = 'hub';
  late bool _showWelcome = widget.prefs.showWelcome;
  late final Map<String, Object> _cfg = widget.prefs.config;

  bool get _floating => _cfg['float'] != false;
  String get _vizStyle => (_cfg['vizstyle'] as String?) ?? 'Сфера';

  @override
  Widget build(BuildContext context) {
    final t = EvsTheme.of(context);

    if (_showWelcome) {
      return Container(
        color: t.palette.bg,
        child: WelcomeScreen(
          onOpen: () => setState(() => _showWelcome = false),
          showAtStartup: widget.prefs.showWelcome,
          onToggleStartup: (v) {
            widget.prefs.setShowWelcome(v);
            setState(() {});
          },
        ),
      );
    }

    final title = _titles[_screen]!;
    final shell = EvsShell(
      title: title[0],
      subtitle: title[1],
      items: _nav,
      current: _screen,
      onSelect: (id) => setState(() => _screen = id),
      actions: [
        IconButton(
          tooltip: 'Сменить тему',
          icon: Icon(t.brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
          color: t.palette.sub,
          onPressed: () => EvsTheme.set(context, t.copyWith(
              brightness: t.brightness == Brightness.dark ? Brightness.light : Brightness.dark)),
        ),
      ],
      child: switch (_screen) {
        'hub' => const HubScreen(),
        'chat' => const ChatScreen(),
        'cmd' => const CommandsScreen(),
        'mon' => const ModulesScreen(),
        'img' => const ImagesScreen(),
        'tts' => const VoiceScreen(),
        _ => SettingsScreen(
            initialConfig: _cfg,
            onConfigChanged: (k, v) {
              widget.prefs.setValue(k, v);
              setState(() => _cfg[k] = v);
            },
            onOpenCommands: () => setState(() => _screen = 'cmd'),
          ),
      },
    );

    // В настоящем приложении виджет живёт в отдельном окне (см. main_widget.dart).
    // Здесь он показан внутри главного окна, чтобы было видно, как выглядит.
    if (!_floating) return shell;
    return Stack(children: [
      shell,
      Positioned(
        right: 26, bottom: 26,
        child: FloatingWidget(
          state: VoiceState.listening,
          style: _vizStyle,
          size: FloatingSizeValue.fromLabel((_cfg['floatsz'] as String?) ?? 'Средний'),
          onOpenChat: () => setState(() => _screen = 'chat'),
        ),
      ),
    ]);
  }
}
