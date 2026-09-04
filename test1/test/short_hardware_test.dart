// Короткие имена железа. Ломается молча: строка просто не влезает в карточку и
// теряет хвост — ровно ту часть, ради которой имя и показывают.
import 'package:flutter_test/flutter_test.dart';
import 'package:anima/main.dart';

void main() {
  group('короткое имя железа', () {
    test('у AMD отрезается число ядер, слово Processor и сам вендор', () {
      expect(animaShortHardware('AMD Ryzen 9 5900X 12-Core Processor'),
          'Ryzen 9 5900X');
      expect(animaShortHardware('AMD Ryzen 5 7500F 6-Core Processor'),
          'Ryzen 5 7500F');
    });

    test('у Intel отрезаются значки, частота и вендор', () {
      expect(animaShortHardware('Intel(R) Core(TM) i7-12700K CPU @ 3.60GHz'),
          'Core i7-12700K');
    });

    test('вендор уходит только когда марка называет его сама', () {
      expect(animaShortHardware('NVIDIA GeForce RTX 3060'),
          'GeForce RTX 3060');
      expect(animaShortHardware('AMD Radeon'), 'Radeon');
      // «AMD GPU» — вендор и есть всё имя, убирать его нельзя.
      expect(animaShortHardware('AMD GPU'), 'AMD GPU');
    });

    test('пустое остаётся пустым, лишние пробелы уходят', () {
      expect(animaShortHardware(''), '');
      expect(animaShortHardware('  AMD   Ryzen 5   '), 'Ryzen 5');
    });
  });
}
