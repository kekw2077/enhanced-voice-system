import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

// Portable data root: all app data (downloaded engines, models, logs, prefs,
// icon cache) lives in "<exeDir>\userdata" whenever that folder is writable —
// so everything sits next to the program (movable, off the system drive if the
// app is installed there). If the install folder isn't writable (e.g. Program
// Files without admin), we fall back to the roaming AppData support dir (the
// original behaviour). Resolved once and cached.
// NB: the subfolder is "userdata", NOT "data" — Flutter's own "data" folder
// (app.so, flutter_assets) sits next to the exe and must not be mixed with it.
String? _dataRootCache;
Future<String> appDataRoot() async {
  final cached = _dataRootCache;
  if (cached != null) return cached;
  // Escape hatch / dev+test override: EVS_PORTABLE=0 forces the AppData store,
  // =1 forces portable (skips the writability probe). Unset = auto.
  final override = Platform.environment['EVS_PORTABLE']?.trim().toLowerCase();
  final forceOff = override == '0' || override == 'false' || override == 'no';
  final forceOn = override == '1' || override == 'true' || override == 'yes';
  String root;
  try {
    if (forceOff) {
      root = (await getApplicationSupportDirectory()).path;
    } else {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final portable = Directory('$exeDir${Platform.pathSeparator}userdata');
      await portable.create(recursive: true);
      if (!forceOn) {
        // Probe writability (Program Files without admin throws here).
        final probe = File('${portable.path}${Platform.pathSeparator}.wtest');
        await probe.writeAsString('ok');
        await probe.delete();
      }
      root = portable.path;
    }
  } catch (_) {
    root = (await getApplicationSupportDirectory()).path;
  }
  _dataRootCache = root;
  return root;
}

// The legacy (pre-portable) data location — always the roaming AppData support
// dir. Used only to migrate existing data into the portable root once.
Future<String> legacyDataRoot() async =>
    (await getApplicationSupportDirectory()).path;

Future<String> localModelsDirPath() async {
  final root = await appDataRoot();
  final modelsDir = Directory('$root/local_models');
  if (!await modelsDir.exists()) await modelsDir.create(recursive: true);
  return modelsDir.path;
}

// Asset models (STT / denoise / TTS voices) live one dir per id under
// <root>/models/<id>/ — separate from the GGUF local_models above.
Future<String> modelsDirPath() async {
  final root = await appDataRoot();
  final dir = Directory('$root/models');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir.path;
}

Future<String> updateDownloadPath(String fileName) async {
  final root = await appDataRoot();
  return '$root/$fileName';
}

// Directory for on-demand downloaded components (sidecar exe, TTS engine).
Future<String> componentsDirPath() async {
  final root = await appDataRoot();
  final c = Directory('$root/components');
  if (!await c.exists()) await c.create(recursive: true);
  return c.path;
}

// Crash sentinel for native local-model loads (fllama can hard-crash the whole
// process, which Dart can't catch). We write this file right before calling
// into fllama and delete it right after; if it survives to the next launch, the
// previous load crashed and we must not auto-load that model again.
Future<File> _modelLoadingFlagFile() async {
  final root = await appDataRoot();
  return File('$root/model_loading.lock');
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

// Append-only diagnostics logs (<app-data>/logs/<name>.log): commands.log,
// chat.log, errors.log. Best-effort — logging must never break the app.
Future<void> appendLog(String name, String line) async {
  try {
    final root = await appDataRoot();
    final logs = Directory('$root/logs');
    if (!await logs.exists()) await logs.create(recursive: true);
    final f = File('${logs.path}/$name.log');
    await f.writeAsString(
      '${DateTime.now().toIso8601String()}  $line\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

Future<void> installApk(String path) async {
  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done) {
    throw Exception(result.message);
  }
}

// ---------------------------------------------------------------------------
// Portable-mode: move existing heavy data (downloaded engines, models, logs)
// from the legacy AppData location into the portable root once, so a user who
// wanted "everything next to the program" doesn't keep it split. Best-effort:
// a same-drive rename is instant; cross-drive (throws) is left as-is (the
// sidecar re-downloads, logs start fresh) rather than blocking startup with a
// multi-GB copy. Must run BEFORE componentsDirPath/localModelsDirPath create
// the destination subfolders.
Future<void> migrateHeavyDataIfPortable() async {
  try {
    final root = await appDataRoot();
    final legacy = await legacyDataRoot();
    if (root == legacy) return; // not portable — nothing to move
    for (final sub in const ['components', 'local_models', 'logs']) {
      final src = Directory('$legacy${Platform.pathSeparator}$sub');
      if (!await src.exists()) continue;
      final dst = Directory('$root${Platform.pathSeparator}$sub');
      if (await dst.exists()) {
        final entries = await dst.list().toList();
        if (entries.isNotEmpty) continue; // already has data
        try {
          await dst.delete(); // empty placeholder — clear it for the rename
        } catch (_) {
          continue;
        }
      }
      try {
        await src.rename(dst.path); // fast same-drive move
      } catch (_) {
        // Cross-drive/locked — leave legacy in place (re-download / fresh logs).
      }
    }
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// App-icon cache for the add-command program picker. Icons are extracted (once)
// to <root>/icon-cache/<hash>.png via PowerShell and loaded as plain files.
String _stableHash(String s) {
  var h = 0x811c9dc5; // FNV-1a 32-bit — stable across runs (unlike hashCode)
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

Future<String> _iconCacheDir() async {
  final root = await appDataRoot();
  final d = Directory('$root/icon-cache');
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

// Extract icons for [sources] (a .lnk/.exe path, or "uwp:<AppID>") into the
// cache and return a map source -> cached PNG path for those that resolved.
// Best-effort: anything that fails just keeps the fallback icon in the UI.
Future<Map<String, String>> buildProgramIcons(List<String> sources) async {
  final result = <String, String>{};
  if (!Platform.isWindows || sources.isEmpty) return result;
  final dir = await _iconCacheDir();
  final missing = <Map<String, String>>[];
  for (final s in sources) {
    final out = '$dir${Platform.pathSeparator}${_stableHash(s)}.png';
    if (await File(out).exists()) {
      result[s] = out;
    } else {
      missing.add({'src': s, 'out': out});
    }
  }
  if (missing.isEmpty) return result;
  try {
    final jobsFile = File('$dir${Platform.pathSeparator}_jobs.json');
    await jobsFile.writeAsString(jsonEncodeSimple(missing));
    final scriptFile = File('$dir${Platform.pathSeparator}_extract.ps1');
    await scriptFile.writeAsString(_iconExtractScript);
    await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
        jobsFile.path,
      ],
    ).timeout(const Duration(seconds: 40));
  } catch (_) {}
  for (final j in missing) {
    final out = j['out']!;
    if (await File(out).exists()) result[j['src']!] = out;
  }
  return result;
}

// Tiny JSON array encoder for [{src,out}] (avoids importing dart:convert here).
String jsonEncodeSimple(List<Map<String, String>> rows) {
  String esc(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"');
  final items = rows
      .map((r) => '{"src":"${esc(r['src']!)}","out":"${esc(r['out']!)}"}')
      .join(',');
  return '[$items]';
}

const String _iconExtractScript = r'''
param([string]$JobsPath)
try { Add-Type -AssemblyName System.Drawing } catch {}
$shell = New-Object -ComObject WScript.Shell
$jobs = Get-Content -Raw -LiteralPath $JobsPath | ConvertFrom-Json
foreach ($j in $jobs) {
  try {
    $src = $j.src; $out = $j.out
    if ($src -like 'uwp:*') {
      $aumid = $src.Substring(4)
      $pfn = $aumid.Split('!')[0]
      $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $pfn } | Select-Object -First 1
      if (-not $pkg) { continue }
      $loc = $pkg.InstallLocation
      $manifest = Join-Path $loc 'AppxManifest.xml'
      if (-not (Test-Path -LiteralPath $manifest)) { continue }
      $raw = Get-Content -Raw -LiteralPath $manifest
      $logo = $null
      $mm = [regex]::Match($raw, 'Square44x44Logo="([^"]+)"')
      if ($mm.Success) { $logo = $mm.Groups[1].Value }
      if (-not $logo) { $mm = [regex]::Match($raw, '<Logo>([^<]+)</Logo>'); if ($mm.Success) { $logo = $mm.Groups[1].Value } }
      if (-not $logo) { continue }
      $logo = $logo -replace '/','\'
      $logoPath = Join-Path $loc $logo
      $dir = Split-Path $logoPath
      $base = [System.IO.Path]::GetFileNameWithoutExtension($logoPath)
      $ext = [System.IO.Path]::GetExtension($logoPath)
      $cand = Get-ChildItem -LiteralPath $dir -Filter "$base*$ext" -ErrorAction SilentlyContinue |
        Sort-Object { if ($_.Name -match 'scale-200') {0} elseif ($_.Name -match 'scale-100') {1} elseif ($_.Name -match 'targetsize-44') {2} else {3} } |
        Select-Object -First 1
      if ($cand) { Copy-Item -LiteralPath $cand.FullName -Destination $out -Force }
      elseif (Test-Path -LiteralPath $logoPath) { Copy-Item -LiteralPath $logoPath -Destination $out -Force }
    } else {
      $target = $src
      if ($src.ToLower().EndsWith('.lnk')) {
        $sc = $shell.CreateShortcut($src)
        if ($sc.TargetPath) { $target = $sc.TargetPath }
      }
      if (-not (Test-Path -LiteralPath $target)) { continue }
      $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($target)
      if ($ico) {
        $bmp = $ico.ToBitmap()
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose(); $ico.Dispose()
      }
    }
  } catch {}
}
''';

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
