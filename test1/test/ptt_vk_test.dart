// Карта «клавиша → virtual-key код Windows» — единственное место, где ошибка
// не видна глазом: Push-to-Talk просто никогда не сработает. Коды сверены с
// заголовком WinUser.h.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:evs/main.dart';

void main() {
  test('модификаторы сводятся к общему коду, левый и правый одинаково', () {
    expect(pttVkFor(PhysicalKeyboardKey.controlLeft), 0x11);
    expect(pttVkFor(PhysicalKeyboardKey.controlRight), 0x11);
    expect(pttVkFor(PhysicalKeyboardKey.shiftLeft), 0x10);
    expect(pttVkFor(PhysicalKeyboardKey.shiftRight), 0x10);
    expect(pttVkFor(PhysicalKeyboardKey.altLeft), 0x12);
    expect(pttVkFor(PhysicalKeyboardKey.altRight), 0x12);
  });

  test('обычные клавиши берут код из uni_platform', () {
    expect(pttVkFor(PhysicalKeyboardKey.keyG), 0x47);
    expect(pttVkFor(PhysicalKeyboardKey.keyV), 0x56);
    expect(pttVkFor(PhysicalKeyboardKey.space), 0x20);
    expect(pttVkFor(PhysicalKeyboardKey.digit1), 0x31);
    expect(pttVkFor(PhysicalKeyboardKey.f13), 0x7C);
    expect(pttVkFor(PhysicalKeyboardKey.capsLock), 0x14);
    expect(pttVkFor(PhysicalKeyboardKey.backquote), 0xC0);
  });

  test('подписи — то, что написано на клавише', () {
    expect(pttKeyLabel(PhysicalKeyboardKey.controlLeft), 'Ctrl');
    expect(pttKeyLabel(PhysicalKeyboardKey.shiftRight), 'Shift');
    expect(pttKeyLabel(PhysicalKeyboardKey.metaLeft), 'Win');
    expect(pttKeyLabel(PhysicalKeyboardKey.keyG), 'G');
    expect(pttKeyLabel(PhysicalKeyboardKey.digit1), '1');
    expect(pttKeyLabel(PhysicalKeyboardKey.f13), 'F13');
    expect(pttKeyLabel(PhysicalKeyboardKey.space), 'Space');
  });
}
