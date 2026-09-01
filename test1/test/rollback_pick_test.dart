// Выбор версии для отката.
//
// Проверка нужна потому, что промах здесь не выглядит поломкой. Откат не
// откажет и не упадёт — он молча поставит не ту версию: соседнюю сверху,
// саму себя, или самую древнюю запись канала. Заметить это можно только по
// номеру в «О программе», уже после перезапуска.
//
// Отдельно проверяется сравнение по числам, а не по строкам: в канале живут
// и 2.9.3, и 2.27.0, и лексикографически второе меньше первого.
import 'dart:io';

import 'package:anima/main.dart';
import 'package:flutter_test/flutter_test.dart';

String item(String v) => '''
    <item>
      <title>EVS $v</title>
      <description><![CDATA[<ul><li>x</li></ul>]]></description>
      <enclosure url="http://x/EVS-Setup-$v.exe" sparkle:version="$v"
                 sparkle:os="windows" length="10" />
    </item>
''';

String feed(List<String> versions) => '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EVS</title>
${versions.map(item).join()}
  </channel>
</rss>
''';

void main() {
  group('версия для отката', () {
    test('берётся ближайшая снизу, а не самая старая', () {
      final xml = feed(['2.27.0', '2.26.0', '2.25.0']);
      expect(AppUpdater.previousVersionFor(xml, '2.27.0'), '2.26.0');
    });

    test('сравнение числовое, а не по алфавиту', () {
      // Лексикографически "2.9.3" больше "2.27.0" — и откат ушёл бы вперёд.
      final xml = feed(['2.27.0', '2.9.3', '2.10.0']);
      expect(AppUpdater.previousVersionFor(xml, '2.27.0'), '2.10.0');
    });

    test('своя версия не считается предыдущей', () {
      final xml = feed(['2.27.0', '2.26.0']);
      expect(AppUpdater.previousVersionFor(xml, '2.26.0'), isNull);
    });

    test('версии новее текущей не выбираются', () {
      final xml = feed(['3.0.0', '2.28.0']);
      expect(AppUpdater.previousVersionFor(xml, '2.28.0'), isNull);
    });

    test('порядок записей в канале не важен', () {
      final xml = feed(['2.25.0', '2.27.0', '2.26.0']);
      expect(AppUpdater.previousVersionFor(xml, '2.27.0'), '2.26.0');
    });

    test('номер сборки не мешает', () {
      final xml = feed(['2.27.0', '2.26.0']);
      expect(AppUpdater.previousVersionFor(xml, '2.27.0+107'), '2.26.0');
    });

    test('пустой канал не откатывает никуда', () {
      expect(AppUpdater.previousVersionFor(feed(const []), '2.27.0'), isNull);
    });

    test('на настоящем канале выбирает вторую сверху', () {
      // Против живого файла, а не только синтетики: разбор этого канала уже
      // ломался однажды на его же шапке-комментарии, и синтетический канал
      // такого не покажет.
      final f = File('dist/appcast.xml');
      if (!f.existsSync()) return;
      final xml = f.readAsStringSync();
      final versions = RegExp('sparkle:version="([^"]+)"')
          .allMatches(xml)
          .map((m) => m.group(1)!)
          .toSet()
          .toList()
        ..sort((a, b) {
          final pa = a.split('.').map(int.parse).toList();
          final pb = b.split('.').map(int.parse).toList();
          for (var i = 0; i < 3; i++) {
            if (pa[i] != pb[i]) return pb[i] - pa[i];
          }
          return 0;
        });
      expect(versions.length, greaterThan(2));
      expect(AppUpdater.previousVersionFor(xml, versions.first), versions[1]);
    });
  });
}
