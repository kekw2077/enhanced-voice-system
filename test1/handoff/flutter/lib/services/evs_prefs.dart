import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../evs_theme.dart';
import '../evs_tokens.dart';

/// Хранение настроек между запусками. В pubspec: shared_preferences: ^2.3.2
///
///   final prefs = await EvsPrefs.load();
///   runApp(EvsApp(initial: prefs.theme, builder: ...));
///   // при изменении: prefs.saveTheme(next); prefs.setValue('vad', 'Высокая');
class EvsPrefs {
  EvsPrefs._(this._p);
  final SharedPreferences _p;

  static Future<EvsPrefs> load() async => EvsPrefs._(await SharedPreferences.getInstance());

  static const _kTheme = 'evs.theme';
  static const _kAccent = 'evs.accent';
  static const _kGlass = 'evs.glass';
  static const _kBackground = 'evs.background';
  static const _kDots = 'evs.dots';
  static const _kAnim = 'evs.anim';
  static const _kWelcome = 'evs.welcome';
  static const _cfgPrefix = 'evs.cfg.';

  EvsThemeData get theme => EvsThemeData(
        brightness: _p.getString(_kTheme) == 'light' ? Brightness.light : Brightness.dark,
        accent: EvsAccent.all.firstWhere((a) => a.id == _p.getString(_kAccent), orElse: () => EvsAccent.google),
        glass: _enum(EvsGlass.values, _p.getString(_kGlass), EvsGlass.glass),
        background: _enum(EvsBackground.values, _p.getString(_kBackground), EvsBackground.aurora),
        dots: _enum(EvsDotMode.values, _p.getString(_kDots), EvsDotMode.push),
        anim: _enum(EvsAnim.values, _p.getString(_kAnim), EvsAnim.breathe),
      );

  Future<void> saveTheme(EvsThemeData d) async {
    await _p.setString(_kTheme, d.brightness == Brightness.light ? 'light' : 'dark');
    await _p.setString(_kAccent, d.accent.id);
    await _p.setString(_kGlass, d.glass.name);
    await _p.setString(_kBackground, d.background.name);
    await _p.setString(_kDots, d.dots.name);
    await _p.setString(_kAnim, d.anim.name);
  }

  bool get showWelcome => _p.getBool(_kWelcome) ?? true;
  Future<void> setShowWelcome(bool v) => _p.setBool(_kWelcome, v);

  /// Значения строк настроек — та самая карта _cfg из SettingsScreen.
  Map<String, Object> get config {
    final out = <String, Object>{};
    for (final k in _p.getKeys()) {
      if (!k.startsWith(_cfgPrefix)) continue;
      final v = _p.get(k);
      if (v != null) out[k.substring(_cfgPrefix.length)] = v;
    }
    return out;
  }

  Future<void> setValue(String key, Object v) async {
    final k = _cfgPrefix + key;
    if (v is bool) return _p.setBool(k, v);
    if (v is int) return _p.setInt(k, v);
    if (v is double) return _p.setDouble(k, v);
    await _p.setString(k, v.toString());
  }

  Future<void> clearConfig() async {
    for (final k in _p.getKeys().where((k) => k.startsWith(_cfgPrefix))) {
      await _p.remove(k);
    }
  }

  static T _enum<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.firstWhere((e) => e.name == name, orElse: () => fallback);
}
