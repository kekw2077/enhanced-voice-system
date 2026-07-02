import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

Future<String> localModelsDirPath() async {
  final dir = await getApplicationSupportDirectory();
  final modelsDir = Directory('${dir.path}/local_models');
  if (!await modelsDir.exists()) await modelsDir.create(recursive: true);
  return modelsDir.path;
}

Future<String> updateDownloadPath(String fileName) async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}/$fileName';
}

// Directory for on-demand downloaded components (sidecar exe, TTS engine).
Future<String> componentsDirPath() async {
  final dir = await getApplicationSupportDirectory();
  final c = Directory('${dir.path}/components');
  if (!await c.exists()) await c.create(recursive: true);
  return c.path;
}

// Crash sentinel for native local-model loads (fllama can hard-crash the whole
// process, which Dart can't catch). We write this file right before calling
// into fllama and delete it right after; if it survives to the next launch, the
// previous load crashed and we must not auto-load that model again.
Future<File> _modelLoadingFlagFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/model_loading.lock');
}

Future<void> setModelLoadingFlag(String modelKey) async {
  try {
    await (await _modelLoadingFlagFile()).writeAsString(modelKey);
  } catch (_) {}
}

Future<String?> readModelLoadingFlag() async {
  try {
    final f = await _modelLoadingFlagFile();
    return await f.exists() ? (await f.readAsString()).trim() : null;
  } catch (_) {
    return null;
  }
}

Future<void> clearModelLoadingFlag() async {
  try {
    final f = await _modelLoadingFlagFile();
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

Future<void> installApk(String path) async {
  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done) {
    throw Exception(result.message);
  }
}

Future<bool> localModelFileExists(String path) => File(path).exists();

Widget attachmentThumbnail(String path, {double size = 72, BoxFit fit = BoxFit.cover}) {
  return Image.file(File(path), width: size, height: size, fit: fit);
}

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
