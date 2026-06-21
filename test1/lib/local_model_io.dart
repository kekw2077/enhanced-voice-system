import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

Future<String> localModelsDirPath() async {
  final dir = await getApplicationSupportDirectory();
  final modelsDir = Directory('${dir.path}/local_models');
  if (!await modelsDir.exists()) await modelsDir.create(recursive: true);
  return modelsDir.path;
}

Future<bool> localModelFileExists(String path) => File(path).exists();

Future<void> deleteLocalModelFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

class DownloadCancelled implements Exception {}

Future<void> downloadFileWithProgress(
  String url,
  String destPath,
  void Function(int received, int total) onProgress,
  bool Function() isCancelled,
) async {
  final client = http.Client();
  final tmpPath = '$destPath.part';
  try {
    final res = await client.send(http.Request('GET', Uri.parse(url)));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = File(tmpPath).openWrite();
    try {
      await for (final chunk in res.stream) {
        if (isCancelled()) throw DownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.close();
    }
    await File(tmpPath).rename(destPath);
  } catch (e) {
    final partial = File(tmpPath);
    if (await partial.exists()) await partial.delete();
    rethrow;
  } finally {
    client.close();
  }
}
