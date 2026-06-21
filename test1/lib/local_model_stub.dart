Future<String> localModelsDirPath() async {
  throw UnsupportedError('Local models are not supported on this platform.');
}

Future<bool> localModelFileExists(String path) async => false;

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
