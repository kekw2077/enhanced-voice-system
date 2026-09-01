// Числа на экране переводчика: разбор того, что пишет чужая программа.
//
// Проверка нужна потому, что ломается это молча. Экран показывает проценты и
// график, а данные для них пишет другой процесс в свой файл — и любая разница
// в форме этого файла превращается не в ошибку, а в ноль на видном месте.
// Одна такая уже случилась: процентиль пустого ряда — это NaN, у которого нет
// записи в JSON, и весь файл состояния из-за него не писался вовсе.
import 'package:anima/main.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CznStatus', () {
    test('читает покрытие по разным текстам, а не по записям базы', () {
      // Одна и та же фраза лежит в базе под каждым ключом игры, и перевод у
      // неё общий: по записям та же база читается как 41 %, по текстам — 91 %.
      const status = CznStatus({
        'textTotal': 80310,
        'textTranslated': 73169,
        'baseTotal': 179996,
      });

      expect(status.textTotal, 80310);
      expect(status.textTranslated, 73169);
    });

    test('задержка без единого кадра — это не ноль, а «не мерили»', () {
      const measured = CznStatus({'changeToDrawMedianMs': 42.5});
      const fresh = CznStatus({'changeToDrawMedianMs': null});

      expect(measured.medianMs, 42.5);
      expect(fresh.medianMs, isNull);
      expect(const CznStatus({}).p95Ms, isNull);
    });

    test('файл от версии постарше читается в той части, что в нём есть', () {
      // Обновляются программы порознь, и статус без разбивки по источникам не
      // должен ронять экран — он должен показывать то, что в нём написано.
      const old = CznStatus({'attached': true, 'window': 'Chaos Zero Nightmare'});

      expect(old.attached, isTrue);
      expect(old.window, 'Chaos Zero Nightmare');
      expect(old.session, isEmpty);
      expect(old.history, isEmpty);
      expect(old.textTotal, 0);
    });

    test('разбивка по источникам и дни приходят разобранными', () {
      const status = CznStatus({
        'session': {'cache': 10, 'exact': 5, 'loose': 3, 'miss': 2},
        'history': [
          {'day': '2026-08-29', 'resolved': 100, 'misses': 4},
          {'day': '2026-08-30', 'resolved': 250, 'misses': 1},
        ],
      });

      expect(status.session['loose'], 3);
      expect(status.history, hasLength(2));
      expect(status.history.first.day, '2026-08-29');
      expect(status.history.last.resolved, 250);
    });

    test('мусор вместо чисел не роняет разбор', () {
      const broken = CznStatus({
        'session': 'нет тут карты',
        'history': 42,
        'textTotal': 'много',
      });

      expect(broken.session, isEmpty);
      expect(broken.history, isEmpty);
      expect(broken.textTotal, 0);
    });
  });

  group('CznPoint', () {
    test('точка дня разбирается и считает долю', () {
      final point = CznPoint.parse('2026-08-30|73169|80310')!;

      expect(point.day, '2026-08-30');
      expect(point.translated, 73169);
      expect(point.pending, 7141);
      expect(point.share, closeTo(0.911, 0.001));
    });

    test('нечитаемая точка выбрасывается, а не портит график', () {
      // Список переживает смену формата: одна испорченная запись не должна
      // уносить с собой всю историю.
      expect(CznPoint.parse('мусор'), isNull);
      expect(CznPoint.parse('2026-08-30|x|y'), isNull);
      expect(CznPoint.parse('2026-08-30|1'), isNull);
    });

    test('пустая база не делит на ноль', () {
      expect(CznPoint.parse('2026-08-30|0|0')!.share, 0);
    });
  });

  group('оформление чисел', () {
    test('разряды разделены неразрывным пробелом', () {
      expect(evsThousands(73169), '73 169');
      expect(evsThousands(999), '999');
      expect(evsThousands(1000000), '1 000 000');
      expect(evsThousands(0), '0');
    });

    test('цвет подложки читается в обеих записях', () {
      expect(cznParseColor('#FFF2E8'), const Color(0xFFFFF2E8));
      expect(cznParseColor('141014'), const Color(0xFF141014));
      expect(cznParseColor('#80141014'), const Color(0x80141014));
    });

    test('недонабранный цвет ничего не красит', () {
      // Поле правят руками: половина значения не должна превращаться в цвет.
      expect(cznParseColor('#FF'), isNull);
      expect(cznParseColor(''), isNull);
      expect(cznParseColor('#ZZZZZZ'), isNull);
    });
  });
}
