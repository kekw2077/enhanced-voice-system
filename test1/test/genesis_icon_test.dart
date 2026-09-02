// Рендер мастер-иконки из того же кода, что рисует знак в приложении:
//   flutter test test/genesis_icon_test.dart
// Кладёт assets/icon/icon.png (1024, прозрачный фон, кадр покоя без глитча).
// Дальше `python assets/icon/gen_evs_icon.py` пересобирает из него .ico и web.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima/main.dart';

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

      // Второй мастер — для .ico (трей и exe).
      //
      // Здесь знак идёт БЕЗ фона. Подложка и туманность делали из иконки
      // тёмную плитку: на панели задач рядом с чужими значками она читалась не
      // как знак покрупнее, а как знак поменьше — плитка съедала поля, которые
      // у соседей отданы самому рисунку.
      //
      // Снять фон можно только потому, что кадр покоя: полосы глитча идут в
      // режиме overlay и на прозрачном слое светились бы поперёк всего круга,
      // но на 13-й секунде они молчат.
      final rec2 = ui.PictureRecorder();
      final c2 = Canvas(rec2);
      // 2.1×: кольцо (r=186 при поле 1024, плюс свечение) занимает около 87 %
      // ширины — заметно крупнее прежних 36 %, но поля остаются, и на краю
      // ничего не срезается. Свуши и орбиты уходят за кадр почти целиком; на
      // 40 px, а это настоящий размер значка, их всё равно не видно.
      const zoom = 2.1;
      c2.translate(size / 2, size / 2);
      c2.scale(zoom);
      c2.translate(-size / 2, -size / 2);
      paintGenesisMark(c2, const Size.square(size), 13.0,
          refPx: size, backdrop: false);
      final img2 = await rec2.endRecording().toImage(size.round(), size.round());
      final png2 = await img2.toByteData(format: ui.ImageByteFormat.png);
      File('assets/icon/icon_tray.png')
          .writeAsBytesSync(png2!.buffer.asUint8List());
    });
  });
}
