// Список изменений в окне обновления.
//
// Ломается это молча и в единственном месте, которое видно пользователю.
// Версия, ссылка, размер и подпись разбираются правильно — обновление ставится,
// проверка целостности проходит, ничего не падает. Пропадает только описание, и
// окно предлагает поставить неизвестно что. Так и вышло: в шапке канала лежит
// комментарий, объясняющий формат, и в нём тег записи написан словами. Для
// регулярного выражения это начало записи, поэтому первый — то есть самый
// свежий — блок начинался внутри комментария и утягивал <description> канала,
// в котором нет ни одного пункта. Все прочие версии разбирались верно, потому
// и не всплывало.
import 'package:evs/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Канал в том виде, в каком он лежит на станции: комментарий-шапка, описание
/// самого канала, потом записи от новой к старой.
String feed(String header) => '''
<?xml version="1.0" encoding="utf-8"?>
<!--
$header
-->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EVS</title>
    <description>EVS desktop (Windows) updates</description>
    <item>
      <title>EVS 2.0.0</title>
      <description><![CDATA[<ul><li>Новое</li><li>Ещё новое</li></ul>]]></description>
      <enclosure url="http://x/EVS-Setup-2.0.0.exe" sparkle:version="2.0.0"
                 sparkle:os="windows" length="10" />
    </item>
    <item>
      <title>EVS 1.0.0</title>
      <description><![CDATA[<ul><li>Старое</li></ul>]]></description>
      <enclosure url="http://x/EVS-Setup-1.0.0.exe" sparkle:version="1.0.0"
                 sparkle:os="windows" length="10" />
    </item>
  </channel>
</rss>
''';

void main() {
  test('описание берётся у самой свежей записи', () {
    expect(AppUpdater.appcastNotes(feed('обычная шапка')),
        ['Новое', 'Ещё новое']);
  });

  test('тег записи, названный в комментарии, не съедает описание', () {
    // Ровно та шапка, что лежала в канале до 2.20.1.
    expect(
      AppUpdater.appcastNotes(
          feed('  WinSparkle picks the newest <item> whose version is greater.')),
      ['Новое', 'Ещё новое'],
    );
  });

  test('мнемоники расшифровываются, а не показываются словами', () {
    final withEntities = feed('шапка').replaceFirst(
        '<li>Новое</li>', '<li>&laquo;Призма&raquo; &mdash; фон&#8230;</li>');
    expect(AppUpdater.appcastNotes(withEntities).first, '«Призма» — фон…');
  });

  test('описание канала не подставляется вместо пропущенного', () {
    final noDesc = feed('шапка').replaceFirst(
        '<description><![CDATA[<ul><li>Новое</li><li>Ещё новое</li></ul>]]></description>',
        '');
    expect(AppUpdater.appcastNotes(noDesc), isEmpty);
  });
}
