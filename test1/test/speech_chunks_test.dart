// Разрез длинного текста на куски для озвучки.
//
// Проверка нужна не ради полноты: у этой функции есть один способ сломаться
// молча и катастрофически — потерять кусок текста. Синтез отработает, файл
// склеится, длительность будет правдоподобной, и пропажу абзаца человек
// обнаружит, только дослушав пятнадцать минут. Поэтому первый и главный тест
// здесь — сумма кусков равна исходному тексту, слово в слово.
//
// Остальное — границы, на которых легко ошибиться: сокращения («т. д.»),
// пустая строка как твёрдая граница, предложение длиннее любого предела.
import 'dart:io';
import 'dart:typed_data';

import 'package:anima/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Всё, что уцелело от текста после разреза, без учёта того, где стояли
/// пробелы: их нарезка вправе переставить (одиночный перенос строки внутри
/// абзаца становится пробелом), а буквы — нет.
String _letters(String s) => s.replaceAll(RegExp(r'\s+'), '');

void main() {
  group('splitSpeechText', () {
    test('ничего не теряет', () {
      const text = '''
Первое предложение. Второе предложение, чуть длиннее первого! Третье?

Новый абзац начинается здесь. В нём тоже несколько предложений, и одно из
них разорвано переносом строки посреди мысли.

И третий абзац — короткий.''';
      final chunks = splitSpeechText(text, target: 60);
      expect(chunks, isNotEmpty);
      expect(
        _letters(chunks.map((c) => c.text).join(' ')),
        _letters(text),
        reason: 'нарезка обязана сохранить текст целиком',
      );
    });

    test('пустая строка — твёрдая граница абзаца', () {
      const text = 'Короткий первый.\n\nКороткий второй.';
      // Оба абзаца легко умещаются в один кусок по длине — и всё равно должны
      // остаться разными кусками: пустую строку поставил человек.
      final chunks = splitSpeechText(text, target: 1000);
      expect(chunks.length, 2);
      expect(chunks[0].text, 'Короткий первый.');
      expect(chunks[1].text, 'Короткий второй.');
      expect(chunks[1].startsParagraph, isTrue);
    });

    test('внутри абзаца куски не начинают абзац', () {
      final text = List.filled(6, 'Предложение средней длины про запас.')
          .join(' ');
      final chunks = splitSpeechText(text, target: 80);
      expect(chunks.length, greaterThan(1));
      expect(chunks[0].startsParagraph, isTrue);
      expect(chunks.skip(1).every((c) => !c.startsParagraph), isTrue);
    });

    test('не режет по сокращениям', () {
      const text = 'Взяли хлеб, соль и т. д. Потом пошли домой.';
      final chunks = splitSpeechText(text, target: 1000);
      expect(chunks.length, 1);
    });

    test('не режет по десятичной точке', () {
      const text = 'Число 3.14 знают все. И это правда.';
      final chunks = splitSpeechText(text, target: 1000);
      expect(chunks.length, 1);
    });

    test('держится заданной длины', () {
      final text = List.filled(40, 'Ровное предложение из нескольких слов.')
          .join(' ');
      final chunks = splitSpeechText(text, target: 200);
      expect(chunks.length, greaterThan(1));
      // Предел мягкий — кусок добирается целыми предложениями, — но вдвое
      // превышать его он не вправе: на этом стоит расчёт срока ожидания.
      expect(chunks.every((c) => c.text.length <= 400), isTrue,
          reason: 'кусок не должен превышать двойной предел');
    });

    test('рвёт предложение, которое само длиннее двух пределов', () {
      final long = 'Слово ' * 200; // одно «предложение» без точек
      final chunks = splitSpeechText(long.trim(), target: 150);
      expect(chunks.length, greaterThan(1));
      expect(_letters(chunks.map((c) => c.text).join(' ')),
          _letters(long.trim()));
      // Рвать внутри слова нельзя: обрубок движок озвучит как отдельное слово.
      expect(chunks.every((c) => !c.text.startsWith('лово')), isTrue);
    });

    test('пустой текст даёт пустой список', () {
      expect(splitSpeechText('   \n\n  '), isEmpty);
    });

    test('нумерует куски подряд', () {
      final text = List.filled(10, 'Предложение.').join(' ');
      final chunks = splitSpeechText(text, target: 150);
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].index, i);
      }
    });
  });

  group('joinSpeechWavs', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('anima-wav-');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    // Кусок пишем руками, а не движком: тест про склейку, а не про синтез.
    // [extra] подкладывает лишний блок перед data — так пишет soundfile на
    // стороне клон-сервера, и ровно на этом ломается «отрезать первые 44
    // байта».
    Future<String> wav(String name, int frames,
        {int rate = 24000, int bits = 16, bool extra = false}) async {
      final dataLen = frames * (bits ~/ 8);
      final extraLen = extra ? 12 : 0;
      final b = BytesBuilder();
      final head = ByteData(36 + extraLen);
      void tag(int at, String t) {
        for (var i = 0; i < 4; i++) {
          head.setUint8(at + i, t.codeUnitAt(i));
        }
      }

      tag(0, 'RIFF');
      head.setUint32(4, 28 + extraLen + dataLen, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      head.setUint32(16, 16, Endian.little);
      head.setUint16(20, 1, Endian.little);
      head.setUint16(22, 1, Endian.little);
      head.setUint32(24, rate, Endian.little);
      head.setUint32(28, rate * (bits ~/ 8), Endian.little);
      head.setUint16(32, bits ~/ 8, Endian.little);
      head.setUint16(34, bits, Endian.little);
      if (extra) {
        tag(36, 'LIST');
        head.setUint32(40, 4, Endian.little);
        head.setUint32(44, 0, Endian.little);
      }
      b.add(head.buffer.asUint8List());
      final tail = ByteData(8 + dataLen);
      for (var i = 0; i < 4; i++) {
        tail.setUint8(i, 'data'.codeUnitAt(i));
      }
      tail.setUint32(4, dataLen, Endian.little);
      for (var i = 0; i < frames; i++) {
        tail.setInt16(8 + i * 2, 1000, Endian.little);
      }
      b.add(tail.buffer.asUint8List());
      final f = File('${tmp.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(b.takeBytes());
      return f.path;
    }

    SpeechChunk chunk(int i, String path, {bool para = false}) =>
        SpeechChunk(index: i, text: 'кусок $i', startsParagraph: para)
          ..path = path;

    test('склеивает куски и вставляет паузу между абзацами', () async {
      final out = '${tmp.path}${Platform.pathSeparator}out.wav';
      await joinSpeechWavs(
        [
          chunk(0, await wav('a.wav', 2400), para: true),
          chunk(1, await wav('b.wav', 1200), para: true),
        ],
        out,
        paragraphGap: const Duration(milliseconds: 500),
      );
      final b = await File(out).readAsBytes();
      final d = ByteData.sublistView(b);
      expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');
      expect(d.getUint16(22, Endian.little), 1, reason: 'моно');
      expect(d.getUint32(24, Endian.little), 24000, reason: 'частота куска');
      expect(d.getUint16(34, Endian.little), 16, reason: 'разрядность куска');
      // 2400 + пауза 0,5 с (12000 отсчётов) + 1200, по два байта на отсчёт.
      const expected = (2400 + 12000 + 1200) * 2;
      expect(d.getUint32(40, Endian.little), expected, reason: 'длина data');
      expect(d.getUint32(4, Endian.little), 36 + expected,
          reason: 'длина RIFF считается от data');
      expect(b.length, 44 + expected);
    });

    test('без границы абзаца паузы нет', () async {
      final out = '${tmp.path}${Platform.pathSeparator}out.wav';
      await joinSpeechWavs(
        [
          chunk(0, await wav('a.wav', 2400), para: true),
          chunk(1, await wav('b.wav', 1200)),
        ],
        out,
        paragraphGap: const Duration(milliseconds: 500),
      );
      final d = ByteData.sublistView(await File(out).readAsBytes());
      expect(d.getUint32(40, Endian.little), (2400 + 1200) * 2);
    });

    test('читает WAV с лишним блоком перед data', () async {
      final out = '${tmp.path}${Platform.pathSeparator}out.wav';
      await joinSpeechWavs(
        [chunk(0, await wav('a.wav', 2400, extra: true), para: true)],
        out,
        paragraphGap: Duration.zero,
      );
      final d = ByteData.sublistView(await File(out).readAsBytes());
      expect(d.getUint32(40, Endian.little), 2400 * 2,
          reason: 'блок LIST не должен попасть в звук');
    });

    test('куски разного формата склеивать отказывается', () async {
      final out = '${tmp.path}${Platform.pathSeparator}out.wav';
      final parts = [
        chunk(0, await wav('a.wav', 2400), para: true),
        chunk(1, await wav('b.wav', 1200, rate: 16000)),
      ];
      expect(joinSpeechWavs(parts, out), throwsA(isA<Exception>()));
    });
  });

  group('speechDurationEstimate', () {
    test('считает минуты по девятистам знакам', () {
      expect(speechDurationEstimate(900).inSeconds, 60);
      expect(speechDurationEstimate(13500).inMinutes, 15);
    });
  });
}
