// Рендер мастер-иконки из того же кода, что рисует знак в приложении:
//   flutter test test/genesis_icon_test.dart
// Кладёт assets/icon/icon.png (1024, прозрачный фон, кадр покоя без глитча).
// Дальше `python assets/icon/gen_evs_icon.py` пересобирает из него .ico и web.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:evs/main.dart';

void main() {
  testWidgets('render app icon master', (tester) async {
    await tester.runAsync(() async {
      const size = 1024.0;
      // Поля под иконку: в образце свуши почти касаются края кадра, а иконку
      // системы обрезают (адаптивные иконки Android — заметно), поэтому знак
      // ужат до 88 % холста.
      const art = size * 0.88;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.translate((size - art) / 2, (size - art) / 2);
      // Момент, в который молчат ВСЕ вечные дорожки образца: тряски, широкие
      // полосы и все десять блипов. На 12.0 с (кадр покоя самого знака) блип
      // ловится ровно во вспышке и печатается прямоугольником на ядре.
      paintGenesisMark(canvas, const Size.square(art), 13.0, refPx: art);
      final img = await rec.endRecording().toImage(size.round(), size.round());
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('assets/icon/icon.png').writeAsBytesSync(png!.buffer.asUint8List());

      // Второй мастер — для .ico (трей и exe). В кадре 16 px кольцо занимает
      // 18 % холста и просто теряется, поэтому знак берётся крупнее: свуши
      // уходят за пределы кадра целиком (их радиус больше диагонали), а
      // туманность заливает фон — получается плотная плитка с кольцом.
      final rec2 = ui.PictureRecorder();
      final c2 = Canvas(rec2);
      // 1.7×: свуши уходят за кадр целиком, кольцо занимает ~62 % ширины и
      // читается на 16 px, а подложка знака успевает сойти на прозрачность к
      // углам — иконка не превращается в тёмный квадрат на светлой панели.
      const zoom = 1.7;
      c2.translate(size / 2, size / 2);
      c2.scale(zoom);
      c2.translate(-size / 2, -size / 2);
      paintGenesisMark(c2, const Size.square(size), 13.0, refPx: size);
      final img2 = await rec2.endRecording().toImage(size.round(), size.round());
      final png2 = await img2.toByteData(format: ui.ImageByteFormat.png);
      File('assets/icon/icon_tray.png')
          .writeAsBytesSync(png2!.buffer.asUint8List());
    });
  });
}
