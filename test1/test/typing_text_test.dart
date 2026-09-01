// Появление ответа: пришедшее сразу на своём месте, но проступает.
//
// Проверка нужна потому, что ломается это тихо и в обе стороны. Стоит начать
// придерживать текст хоть на кадр — и вернётся то, из-за чего всё
// переделывалось: недописанное слово скачет между строками, а с ним дёргается
// весь абзац. Пропадёт прозрачность — вернутся рывки кусками. Ни того, ни
// другого не видно иначе как глазами на живой генерации, а тест ловит сразу.
import 'package:evs/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(color: Color(0xFFFFFFFF), fontSize: 14, height: 1.45);

Text _text(WidgetTester t) => t.widget<Text>(find.byType(Text));

/// Весь текст на экране — вместе с тем, что ещё проступает.
String _plain(WidgetTester t) {
  final w = _text(t);
  return w.textSpan?.toPlainText() ?? w.data ?? '';
}

List<TextSpan> _spans(WidgetTester t) {
  final out = <TextSpan>[];
  _text(t).textSpan?.visitChildren((s) {
    if (s is TextSpan && (s.text ?? '').isNotEmpty) out.add(s);
    return true;
  });
  return out;
}

/// Прозрачность последнего куска: 1 — проступил полностью.
double _tailAlpha(WidgetTester t) {
  final s = _spans(t);
  return s.isEmpty ? 1.0 : (s.last.style?.color?.a ?? 1.0);
}

Widget _wrap(String text) => Directionality(
      textDirection: TextDirection.ltr,
      // Цвет и размер заданы явно: иначе виджет полезет за палитрой в AppState,
      // а проверяем мы здесь появление текста, а не оформление.
      child: EvsTypingText(text, style: _style),
    );

void main() {
  const head = 'Ответ начинается';
  const full = '$head и продолжается дальше, уже второй строкой.';

  testWidgets('готовый ответ показывается целиком и сразу', (t) async {
    await t.pumpWidget(_wrap(full));
    expect(_plain(t), full);
    expect(_tailAlpha(t), 1.0, reason: 'ничего не проступает');
  });

  testWidgets('пришедший кусок сразу занимает своё место', (t) async {
    // Главное свойство: текст не придерживается ни на кадр, поэтому переносы
    // строк посчитаны сразу и дальше не двигаются.
    await t.pumpWidget(_wrap(head));
    await t.pumpWidget(_wrap(full));
    expect(_plain(t), full);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('пришедший кусок проступает, а не выскакивает', (t) async {
    await t.pumpWidget(_wrap(head));
    await t.pumpWidget(_wrap(full));
    expect(_tailAlpha(t), lessThan(0.2), reason: 'сначала почти прозрачный');

    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 150));
    final mid = _tailAlpha(t);
    expect(mid, greaterThan(0.2), reason: 'на середине уже виден');
    expect(mid, lessThan(1.0), reason: 'но ещё не проступил до конца');
    expect(_plain(t), full, reason: 'текст всё это время на месте целиком');

    await t.pump(const Duration(milliseconds: 300));
    expect(_tailAlpha(t), 1.0, reason: 'проступил до конца');
    expect(_plain(t), full);
  });

  testWidgets('чужой текст не проявляется заново', (t) async {
    // Список диалогов сдвинулся, и на месте живого ответа оказался совсем
    // другой: его надо показать как есть, а не проявлять.
    await t.pumpWidget(_wrap(head));
    await t.pumpWidget(_wrap(full));
    expect(_tailAlpha(t), lessThan(0.2));

    await t.pumpWidget(_wrap('Совершенно другое сообщение.'));
    expect(_plain(t), 'Совершенно другое сообщение.');
    expect(_tailAlpha(t), 1.0);
  });

  group('просвет между абзацами', () {
    testWidgets('пустая строка ниже строки текста', (t) async {
      await t.pumpWidget(_wrap('Первый абзац.\n\nВторой абзац.'));
      expect(_plain(t), 'Первый абзац.\n\nВторой абзац.',
          reason: 'структура текста не меняется — меняется только высота');

      final gaps = _spans(t)
          .where((s) => s.text == '\n' && s.style?.fontSize != null)
          .toList();
      expect(gaps, hasLength(1), reason: 'один просвет на один разрыв абзаца');
      expect(gaps.single.style!.fontSize, lessThan(_style.fontSize! * 0.7),
          reason: 'иначе это обычная пустая строка, из-за которой всё и затеяно');
    });

    testWidgets('три перевода строки дают тот же просвет, что и два',
        (t) async {
      await t.pumpWidget(_wrap('Первый.\n\n\n\nВторой.'));
      expect(_plain(t), 'Первый.\n\nВторой.');
    });
  });
}
