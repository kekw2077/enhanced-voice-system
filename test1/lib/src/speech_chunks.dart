part of '../main.dart';

/* ==========================================================================
   Длинный текст для озвучки: как он режется на куски и как куски снова
   становятся одним файлом.
   --------------------------------------------------------------------------
   Зачем резать. Синтез берёт текст целиком и держит его в своём внимании: чем
   длиннее кусок, тем дальше к концу уплывают голос и темп, а на очень длинном
   модель начинает терять предложения. Плюс чисто счётный довод: один запрос на
   пятнадцать минут речи не укладывается ни в один срок ожидания, и оборвётся
   он целиком — вместе со всем, что успел насчитать. Пятнадцать кусков по
   минуте обрываются по одному, и переделать надо один.

   Третье, ради чего это писалось: ход работы. У сайдкара нет ни шагов, ни
   процентов — `tts_engine.render` синтезирует одним вызовом и молчит до
   конца. Куски дают честную долю: «седьмой из восемнадцати» — не выдумка, а
   пересчитанные файлы на диске.

   Где границы. Пустая строка в тексте — граница твёрдая: абзац человек ставит
   сам, и разрывать его молча нельзя. Внутри абзаца режем по концам
   предложений, набирая куски примерно до заданной длины. Внутри слова не
   режем никогда.
   ========================================================================== */

/// Знаков в минуте русской речи при обычном темпе — около девятисот. Число
/// приблизительное и служит ровно одному: сказать «это примерно столько-то
/// минут» ДО того, как человек нажмёт и уйдёт ждать.
const int kSpeechCharsPerMinute = 900;

/// Длина куска по умолчанию и границы ползунка. Умолчание — компромисс:
/// короче куски — ровнее голос, но больше швов на склейке; длиннее — наоборот.
const int kSpeechChunkDefault = 500;
const int kSpeechChunkMin = 150;
const int kSpeechChunkMax = 1200;

/// Оценка длительности речи по числу знаков.
Duration speechDurationEstimate(int chars) =>
    Duration(seconds: (chars * 60 / kSpeechCharsPerMinute).round());

enum SpeechChunkState { waiting, running, done, failed }

/// Один кусок текста и всё, что с ним случилось.
class SpeechChunk {
  SpeechChunk({
    required this.index,
    required this.text,
    required this.startsParagraph,
  });

  final int index;
  final String text;

  /// Кусок открывает новый абзац. В склейке перед ним ставится пауза: без неё
  /// абзацы слипаются в один поток, и на слух текст теряет строение.
  final bool startsParagraph;

  SpeechChunkState state = SpeechChunkState.waiting;

  /// Готовый кусок на диске. Живёт до склейки, а переживает её только если
  /// человек попросил оставить куски отдельными файлами.
  String? path;
  String? error;
  Duration took = Duration.zero;
}

// --------------------------------------------------------------------------
// Разрез
// --------------------------------------------------------------------------

/// Конец предложения: знак, закрывающая кавычка или скобка после него, пробел.
final RegExp _sentenceBreak = RegExp(r'([.!?…]+)([»"”\)\]]*)(\s+)');

/// Чем должно начинаться следующее предложение, чтобы точка перед ним была
/// концом, а не серединой сокращения: заглавной, цифрой, кавычкой или тире.
final RegExp _sentenceStart = RegExp(r'^[«"“\(\[\-—0-9A-ZА-ЯЁ]');

/// Сокращения вроде «т. д.», «г.», «им.»: точка в них не конец предложения.
/// Признак простой — последнее слово перед точкой в одну-две строчные буквы.
/// Словарь сокращений тут не заводим: он всё равно был бы неполон, а цена
/// ошибки здесь — лишний шов между кусками, а не поломка.
bool _looksAbbrev(String before) {
  final m = RegExp(r'([A-Za-zА-Яа-яЁё]+)$').firstMatch(before);
  if (m == null) return false;
  final w = m.group(1)!;
  return w.length <= 2 && w == w.toLowerCase();
}

/// Абзац на предложения.
List<String> _sentences(String para) {
  final out = <String>[];
  var start = 0;
  for (final m in _sentenceBreak.allMatches(para)) {
    final endOfSentence = m.start + m.group(1)!.length + m.group(2)!.length;
    final rest = para.substring(m.end);
    if (rest.isEmpty) continue;
    if (!_sentenceStart.hasMatch(rest)) continue;
    if (_looksAbbrev(para.substring(start, m.start))) continue;
    final s = para.substring(start, endOfSentence).trim();
    if (s.isEmpty) continue;
    out.add(s);
    start = m.end;
  }
  final tail = para.substring(start).trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}

/// Слишком длинное предложение: режем по внутренним знакам, а если их нет — по
/// пробелам. Внутри слова не режем никогда: движок озвучит обрубок как
/// отдельное слово, и шов станет слышен.
List<String> _fitSentence(String s, int limit, int hard) {
  if (s.length <= hard) return [s];
  final out = <String>[];
  var rest = s;
  while (rest.length > hard) {
    var cut = -1;
    for (final m in RegExp(r'[,;:—–]\s').allMatches(rest)) {
      if (m.end > limit) break;
      cut = m.end;
    }
    if (cut <= 0) {
      cut = rest.lastIndexOf(' ', math.min(limit, rest.length - 1));
      // Одно слово длиннее предела — редкость (ссылка, набор цифр). Режем по
      // пределу: потерять его целиком хуже, чем разорвать.
      if (cut <= 0) cut = limit;
    }
    out.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

/// Разрезать текст на куски примерно по [target] знаков.
///
/// Пустая строка в тексте — граница твёрдая: так человек управляет разрезом
/// сам, не трогая ползунок. Внутри абзаца куски набираются целыми
/// предложениями и рвутся только там, где предложение само длиннее двух
/// пределов.
List<SpeechChunk> splitSpeechText(String raw,
    {int target = kSpeechChunkDefault}) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.isEmpty) return const [];
  final limit = target < kSpeechChunkMin
      ? kSpeechChunkMin
      : (target > kSpeechChunkMax ? kSpeechChunkMax : target);
  final hard = limit * 2;
  final out = <SpeechChunk>[];

  for (final p in text.split(RegExp(r'\n[ \t]*\n+'))) {
    // Одиночные переносы внутри абзаца — перенос строки, а не пауза: в речи их
    // нет, и склеивать их надо пробелом.
    final para = p.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');
    if (para.isEmpty) continue;
    var first = true;
    final buf = StringBuffer();

    void flush() {
      final s = buf.toString().trim();
      buf.clear();
      if (s.isEmpty) return;
      out.add(SpeechChunk(
          index: out.length, text: s, startsParagraph: first));
      first = false;
    }

    for (final sentence in _sentences(para)) {
      for (final piece in _fitSentence(sentence, limit, hard)) {
        if (buf.isNotEmpty && buf.length + 1 + piece.length > limit) flush();
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(piece);
        if (buf.length >= limit) flush();
      }
    }
    flush();
  }
  return out;
}

// --------------------------------------------------------------------------
// Склейка
// --------------------------------------------------------------------------

/// Разобранный WAV: формат и сырые отсчёты.
class _Wav {
  _Wav(this.format, this.channels, this.rate, this.bits, this.data);
  final int format, channels, rate, bits;
  final Uint8List data;

  int get blockAlign => channels * (bits ~/ 8);

  /// Склеивать можно только одинаковое. Куски приходят от одного движка с
  /// одними настройками, так что расхождение — признак того, что голос
  /// сменили посреди партии, и молча портить файл нельзя.
  bool sameShapeAs(_Wav o) =>
      format == o.format &&
      channels == o.channels &&
      rate == o.rate &&
      bits == o.bits;
}

/// Читаем WAV по-настоящему, обходя блоки, а не отрезая «первые 44 байта»:
/// soundfile на стороне клон-сервера пишет ещё и блок LIST, и заголовок у него
/// длиннее сорока четырёх.
_Wav _readWav(Uint8List b, String whose) {
  if (b.length < 12 ||
      String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
    throw FormatException('$whose: это не WAV');
  }
  final d = ByteData.sublistView(b);
  int? format, channels, rate, bits;
  Uint8List? data;
  var at = 12;
  while (at + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(at, at + 4));
    final size = d.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ' && body + 16 <= b.length) {
      format = d.getUint16(body, Endian.little);
      channels = d.getUint16(body + 2, Endian.little);
      rate = d.getUint32(body + 4, Endian.little);
      bits = d.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      data = Uint8List.sublistView(b, body, math.min(body + size, b.length));
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  if (format == null || data == null) {
    throw FormatException('$whose: в WAV нет fmt или data');
  }
  return _Wav(format, channels!, rate!, bits!, data);
}

/// Заголовок PCM-WAV на 44 байта. Разрядность и формат берём у кусков, а не
/// назначаем: клон отдаёт шестнадцать бит, Piper тоже, но привязываться к
/// этому — значит испортить файл в тот день, когда движок сменит формат.
Uint8List _wavHeader(_Wav w, int dataLen) {
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + dataLen, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, w.format, Endian.little);
  h.setUint16(22, w.channels, Endian.little);
  h.setUint32(24, w.rate, Endian.little);
  h.setUint32(28, w.rate * w.blockAlign, Endian.little);
  h.setUint16(32, w.blockAlign, Endian.little);
  h.setUint16(34, w.bits, Endian.little);
  tag(36, 'data');
  h.setUint32(40, dataLen, Endian.little);
  return h.buffer.asUint8List();
}

/// Собрать готовые куски в один файл [out].
///
/// [paragraphGap] — тишина перед куском, открывающим новый абзац. Ноль здесь
/// законен: кому-то нужна сплошная дорожка без пауз.
Future<void> joinSpeechWavs(
  List<SpeechChunk> chunks,
  String out, {
  Duration paragraphGap = const Duration(milliseconds: 300),
}) async {
  final ready = [for (final c in chunks) if (c.path != null) c];
  if (ready.isEmpty) throw Exception('нечего склеивать: готовых кусков нет');

  _Wav? shape;
  final body = BytesBuilder(copy: false);
  for (var i = 0; i < ready.length; i++) {
    final c = ready[i];
    final w = _readWav(
        await io.File(c.path!).readAsBytes(), 'кусок ${c.index + 1}');
    if (shape == null) {
      shape = w;
    } else if (!shape.sameShapeAs(w)) {
      throw Exception('куски записаны по-разному: '
          '${shape.rate} Гц/${shape.bits} бит против ${w.rate}/${w.bits}');
    }
    if (i > 0 && c.startsParagraph && paragraphGap > Duration.zero) {
      final frames =
          (shape.rate * paragraphGap.inMilliseconds / 1000).round();
      body.add(Uint8List(frames * shape.blockAlign));
    }
    body.add(w.data);
  }

  final data = body.takeBytes();
  // Пишем потоком, а не одним списком: пятнадцать минут речи — это под сорок
  // мегабайт, и лишняя копия их в памяти ни к чему.
  final sink = io.File(out).openWrite();
  sink.add(_wavHeader(shape!, data.length));
  sink.add(data);
  await sink.flush();
  await sink.close();
}
