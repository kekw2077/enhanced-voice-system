import 'package:flutter/widgets.dart';

Future<String> localModelsDirPath() async {
  throw UnsupportedError('Local models are not supported on this platform.');
}

Future<String> updateDownloadPath(String fileName) async {
  throw UnsupportedError('App updates are not supported on this platform.');
}

Future<void> installApk(String path) async {
  throw UnsupportedError('App updates are not supported on this platform.');
}

Future<bool> localModelFileExists(String path) async => false;

Widget attachmentThumbnail(String path, {double size = 72, BoxFit fit = BoxFit.cover}) {
  return SizedBox(width: size, height: size);
}

Future<void> deleteLocalModelFile(String path) async {}

class DownloadCancelled implements Exception {}

Future<void> downloadFileWithProgress(
  String url,
  String destPath,
  void Function(int received, int total) onProgress,
  bool Function() isCancelled,
) async {
  throw UnsupportedError('Local models are not supported on this platform.');
}
