// Разбор числа в голосовой команде: «громкость на 30» и «громкость на тридцать»
// должны давать одно и то же.
//
// Проверка нужна потому, что ломается это незаметно. Команда с шаблоном {N}
// продолжает опознаваться и выполняться — просто ставит не тот уровень или
// падает на значение по умолчанию, а человек слышит «готово» и думает, что
// сработало.
import 'package:anima/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('число цифрами', () {
    test('обычная команда', () {
      expect(NumberWords.extract('громкость на 30'), 30);
      expect(NumberWords.extract('поставь громкость 5'), 5);
      expect(NumberWords.extract('громкость 100'), 100);
    });

    test('со знаком процента', () {
      expect(NumberWords.extract('громкость на 45%'), 45);
      expect(NumberWords.extract('громкость 70 процентов'), 70);
    });
  });

  group('число прописью', () {
    test('единицы и десятки', () {
      expect(NumberWords.extract('громкость на тридцать'), 30);
      expect(NumberWords.extract('громкость на пять'), 5);
      expect(NumberWords.extract('громкость девяносто'), 90);
    });

    test('составные числа складываются', () {
      expect(NumberWords.extract('громкость сорок пять'), 45);
      expect(NumberWords.extract('поставь громкость двадцать три'), 23);
    });

    test('сто', () {
      expect(NumberWords.extract('громкость сто'), 100);
      expect(NumberWords.extract('громкость на ста процентах'), 100);
    });

    test('падежные формы — так и говорят вслух', () {
      // Именительным падежом список не обходится: «до тридцати», «на сорока».
      expect(NumberWords.extract('громкость до тридцати'), 30);
      expect(NumberWords.extract('громкость до пятидесяти'), 50);
      expect(NumberWords.extract('убавь до десяти'), 10);
      expect(NumberWords.extract('громкость до девяноста'), 90);
    });

    test('служебные слова внутри числительного не обрывают счёт', () {
      expect(NumberWords.extract('громкость на сорок пять процентов'), 45);
    });
  });

  group('когда числа нет', () {
    test('пусто — значит null, и команда возьмёт своё значение', () {
      expect(NumberWords.extract('громкость'), isNull);
      expect(NumberWords.extract(''), isNull);
      expect(NumberWords.extract('сделай потише'), isNull);
    });
  });
}
