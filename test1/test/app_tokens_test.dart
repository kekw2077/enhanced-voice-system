// Токены темы: контракт класса, который раздаёт цвет всему интерфейсу.
//
// Проверка нужна потому, что оба метода ThemeExtension легко написать так, что
// анализатор промолчит, а интерфейс сломается тихо. copyWith, возвращающий сам
// объект, компилируется без единого замечания — и тема просто перестаёт
// меняться. Ровно эта ошибка лежит в шаблоне из «anima project».
import 'package:evs/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppTokens', () {
    final dark = AppTokens(
      skin: skinFor(AppStyle.prism, AppThemeMode.dark),
      style: AppStyle.prism,
      accent: PrismAccent.google,
    );
    final light = AppTokens(
      skin: skinFor(AppStyle.prism, AppThemeMode.claude),
      style: AppStyle.prism,
      accent: PrismAccent.aurora,
    );

    test('copyWith меняет названное и сохраняет остальное', () {
      final t = dark.copyWith(accent: PrismAccent.mint);
      expect(t.accent, PrismAccent.mint);
      expect(t.style, dark.style);
      expect(identical(t.skin, dark.skin), isTrue);
    });

    test('copyWith без аргументов ничего не теряет', () {
      final t = dark.copyWith();
      expect(t.style, dark.style);
      expect(t.accent, dark.accent);
      expect(identical(t.skin, dark.skin), isTrue);
    });

    test('lerp переключает тему разом, а не смешивает', () {
      // Снимок, а не переливание: пока меняется только способ доставки темы,
      // а не то, как выглядит переключение.
      expect(identical(dark.lerp(light, 0.0), dark), isTrue);
      expect(identical(dark.lerp(light, 0.49), dark), isTrue);
      expect(identical(dark.lerp(light, 0.5), light), isTrue);
      expect(identical(dark.lerp(light, 1.0), light), isTrue);
    });

    test('lerp переживает чужое расширение', () {
      expect(identical(dark.lerp(null, 1.0), dark), isTrue);
    });

    test('каждая пара стиля и темы даёт свою палитру', () {
      // Страховка на переименование и на правку skinFor: набор скинов не
      // должен схлопнуться в один незаметно для глаза.
      final seen = <String>{};
      for (final style in AppStyle.values) {
        for (final mode in AppThemeMode.values) {
          final pal = skinFor(style, mode).pal;
          seen.add('${pal.bg.toARGB32()}:${pal.txt.toARGB32()}:'
              '${pal.accent.toARGB32()}');
        }
      }
      expect(seen.length, greaterThan(1));
    });
  });
}
