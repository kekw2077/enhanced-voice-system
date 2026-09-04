// Строка железа в карточке «Система» должна помещаться целиком.
//
// У _PrismMetric имя стоит во Flexible с maxLines: 1 и многоточием: слишком
// длинное имя не ломает вёрстку, оно молча теряет хвост — «AMD Radeon RX 9060
// X…». Ширина колонки в «Призме» фиксированная (376 минус отступы карточки),
// поэтому влезает имя или нет, известно заранее и меряется здесь, а не глазами
// на готовой сборке.
//
// Замер решает и спор про вендора: «Видеокарта · AMD Radeon RX 9060 XT» — это
// 231,1 пикселя при 232 доступных, впритык до пикселя. Без «AMD» (его срезает
// animaShortHardware, когда марка называет вендора сама) — 199,1 и запас в
// треть строки.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima/main.dart';

// Колонка «Призмы» — 376, PrismPanel съедает по 22 с каждой стороны, между
// именем и числом ещё 10 (SizedBox в _PrismMetric).
const double _content = 376 - 22 * 2;
const double _gap = 10;

Future<void> _font(String family, String file) async {
  final bytes = await File('assets/fonts/$file').readAsBytes();
  await (FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes)))))
      .load();
}

double _width(String text, TextStyle style) {
  final tp = TextPainter(
      text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
    ..layout();
  return tp.width;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _font(kPrismFont, 'Figtree-VariableFont_wght.ttf');
    await _font('Nunito', 'Nunito-VariableFont_wght.ttf');
    await _font(kPrismMono, 'JetBrainsMono-VariableFont_wght.ttf');
  });

  // Те же стили, что у _PrismMetric: имя — 13 обычным шрифтом, число — 12,5
  // моноширинным полужирным.
  final nameStyle = PrismType.body.copyWith(
      fontSize: 13,
      fontFamily: kPrismFont,
      fontFamilyFallback: kPrismFontFallback);
  final valueStyle = PrismType.numeric.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      fontFamilyFallback: kPrismFontFallback);

  void fits(String label, String hardware, String value) {
    final name = '$label · ${animaShortHardware(hardware)}';
    final left = _content - _gap - _width(value, valueStyle);
    final got = _width(name, nameStyle);
    expect(got, lessThanOrEqualTo(left),
        reason: '«$name» — $got пикселей при $left доступных');
  }

  group('строка железа влезает в карточку «Система»', () {
    // Числа берутся самые широкие из возможных: у моноширинного шрифта все
    // цифры одной ширины, поэтому «15.9 / 16 ГБ» — предел для карты на 16 ГБ,
    // а «100%» — для загрузки процессора.
    test('видеокарта станции', () {
      fits('Видеокарта', 'AMD Radeon RX 9060 XT', '15.9 / 16 ГБ');
    });

    test('процессор станции', () {
      fits('Процессор', 'AMD Ryzen 5 7500F 6-Core Processor', '100%');
    });

    test('видеокарта этого компьютера', () {
      fits('Видеокарта', 'NVIDIA GeForce RTX 3060', '11.9 / 12 ГБ');
    });
  });
}
