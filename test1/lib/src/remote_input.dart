part of '../main.dart';

class RemoteDevice {
  final String id;
  String name;
  final String token;
  bool permVoice;
  bool permText;
  bool enabled;
  String lastSeen;
  RemoteDevice({
    required this.id,
    required this.name,
    required this.token,
    this.permVoice = true,
    this.permText = true,
    this.enabled = true,
    this.lastSeen = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'token': token,
        'voice': permVoice,
        'text': permText,
        'enabled': enabled,
        'last_seen': lastSeen,
      };

  factory RemoteDevice.fromJson(Map<String, dynamic> j) => RemoteDevice(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        token: j['token'] as String? ?? '',
        permVoice: j['voice'] as bool? ?? true,
        permText: j['text'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        lastSeen: j['last_seen'] as String? ?? '',
      );
}

// Local HTTP listener that accepts remote commands from paired phones over
// Tailscale/LAN (TZ §14). Bound to all local interfaces (not port-forwarded to
// the internet — that's the user's router). Auth is a per-device bearer token
// issued during pairing; a short-lived one-time code gates pairing itself.
//
// Endpoints:
//   GET  /               -> {ok:true, name:"EVS"}                (discovery)
//   POST /pair    {code, name?}                 -> {device_id, token}
//   POST /command/text  (Bearer) {text}         -> {reply}
//   POST /command/voice (Bearer) audio/* body   -> {text, reply}
//        (WAV or raw 16 kHz mono PCM16; or JSON {audio:<base64>, format})
class RemoteInputServer {
  RemoteInputServer._();
  static final RemoteInputServer instance = RemoteInputServer._();

  io.HttpServer? _server;
  AppState? _app;
  String? _pairCode;
  DateTime? _pairExpires;
  final _rnd = math.Random.secure();

  bool get running => _server != null;

  Future<void> start(AppState app) async {
    _app = app;
    await stop();
    try {
      _server = await io.HttpServer.bind(
          io.InternetAddress.anyIPv4, app.remoteInputPort, shared: true);
      _server!.listen(_handle, onError: (_) {});
      unawaited(appendLog('remote', 'listening on :${app.remoteInputPort}'));
    } catch (e) {
      _server = null;
      unawaited(
          appendLog('remote', 'bind failed on :${app.remoteInputPort}: $e'));
      VizOverlayServer.instance.note(app.t('remotePortBusy'), kind: 'err');
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  // Fresh one-time pairing code with a 5-minute TTL (§14.2).
  String newPairCode() {
    final a = (1000 + _rnd.nextInt(9000)).toString();
    final b = (10 + _rnd.nextInt(90)).toString();
    _pairCode = '$a-$b';
    _pairExpires = DateTime.now().add(const Duration(minutes: 5));
    return _pairCode!;
  }

  String? get activePairCode =>
      (_pairExpires != null && DateTime.now().isBefore(_pairExpires!))
          ? _pairCode
          : null;

  String _newToken() {
    final b = List<int>.generate(24, (_) => _rnd.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }

  Future<Map<String, dynamic>> _readJson(io.HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    if (body.trim().isEmpty) return {};
    final d = jsonDecode(body);
    return d is Map ? d.cast<String, dynamic>() : {};
  }

  Future<List<int>> _readBytes(io.HttpRequest req) async {
    final chunks = <int>[];
    await for (final c in req) {
      chunks.addAll(c);
    }
    return chunks;
  }

  void _send(io.HttpRequest req, Map<String, dynamic> body, {int status = 200}) {
    req.response
      ..statusCode = status
      ..headers.contentType = io.ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }

  String? _bearer(io.HttpRequest req) {
    final h = req.headers.value('authorization') ?? '';
    return h.toLowerCase().startsWith('bearer ') ? h.substring(7).trim() : null;
  }

  Future<void> _handle(io.HttpRequest req) async {
    final app = _app;
    if (app == null) {
      _send(req, {'error': 'not_ready'}, status: 503);
      return;
    }
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/') {
        _send(req, {'ok': true, 'name': 'EVS'});
        return;
      }
      if (req.method == 'POST' && path == '/pair') {
        final body = await _readJson(req);
        final code = (body['code'] ?? '').toString().trim();
        if (activePairCode == null || code != activePairCode) {
          _send(req, {'error': 'invalid_code'}, status: 401);
          return;
        }
        _pairCode = null; // one-time
        final dev = RemoteDevice(
          id: 'd${_rnd.nextInt(1 << 32)}',
          name: (body['name'] ?? 'Телефон').toString().trim(),
          token: _newToken(),
        );
        app.addRemoteDevice(dev);
        _send(req, {'device_id': dev.id, 'token': dev.token});
        return;
      }
      // Authorized endpoints.
      final dev = app.remoteDeviceByToken(_bearer(req) ?? '');
      if (dev == null || !dev.enabled) {
        _send(req, {'error': 'unauthorized'}, status: 401);
        return;
      }
      app.touchRemoteDevice(dev);
      if (req.method == 'POST' && path == '/command/text') {
        if (!dev.permText) {
          _send(req, {'error': 'forbidden'}, status: 403);
          return;
        }
        final body = await _readJson(req);
        final text = (body['text'] ?? '').toString().trim();
        if (text.isEmpty) {
          _send(req, {'error': 'empty'}, status: 400);
          return;
        }
        final reply = await app.runRemoteCommand(text);
        // Speak on the desktop unless the phone asked for text only (§14.5).
        if (app.remoteResponseTarget != 'phone_text') {
          final say = await app.interpretForTts(reply);
          SidecarClient.instance.speak(say,
              rate: app.ttsRate, volume: app.ttsVolume);
        }
        _send(req, {'reply': reply});
        return;
      }
      if (req.method == 'POST' && path == '/command/voice') {
        if (!dev.permVoice) {
          _send(req, {'error': 'forbidden'}, status: 403);
          return;
        }
        // Accept either a raw audio body (Content-Type audio/*, WAV or raw
        // 16 kHz mono PCM16) or a JSON envelope {audio:<base64>, format}. The
        // audio is decoded + recognized by the sidecar, then the resulting
        // text takes the same path as /command/text.
        final ctype = req.headers.contentType?.mimeType ?? '';
        String b64;
        String fmt;
        if (ctype == 'application/json') {
          final j = await _readJson(req);
          b64 = (j['audio'] ?? '').toString();
          fmt = (j['format'] ?? 'wav').toString();
        } else {
          final bytes = await _readBytes(req);
          if (bytes.isEmpty) {
            _send(req, {'error': 'empty'}, status: 400);
            return;
          }
          b64 = base64.encode(bytes);
          // RIFF magic ⇒ WAV; otherwise assume raw 16 kHz mono PCM16.
          fmt = (bytes.length >= 4 &&
                  bytes[0] == 0x52 &&
                  bytes[1] == 0x49 &&
                  bytes[2] == 0x46 &&
                  bytes[3] == 0x46)
              ? 'wav'
              : 'pcm16';
        }
        if (b64.isEmpty) {
          _send(req, {'error': 'empty'}, status: 400);
          return;
        }
        final text =
            await SidecarClient.instance.transcribeAudio(b64, format: fmt);
        if (text.isEmpty) {
          // Nothing recognized (silence, decode failure, or sidecar down).
          _send(req, {'error': 'stt_failed', 'text': '', 'reply': ''},
              status: 422);
          return;
        }
        final reply = await app.runRemoteCommand(text);
        if (app.remoteResponseTarget != 'phone_text') {
          final say = await app.interpretForTts(reply);
          SidecarClient.instance
              .speak(say, rate: app.ttsRate, volume: app.ttsVolume);
        }
        _send(req, {'text': text, 'reply': reply});
        return;
      }
      _send(req, {'error': 'not_found'}, status: 404);
    } catch (e) {
      try {
        _send(req, {'error': 'server_error'}, status: 500);
      } catch (_) {}
    }
  }
}

// Non-loopback IPv4 addresses of this machine, so the UI can show where a phone
// should connect (Tailscale 100.x, LAN 192.168/10.x). Tailscale addresses are
// surfaced first — that's the reliable path across networks.
Future<List<String>> localAddresses() async {
  final out = <String>[];
  try {
    for (final ni
        in await io.NetworkInterface.list(type: io.InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
  } catch (_) {}
  out.sort((a, b) {
    final ta = a.startsWith('100.') ? 0 : 1;
    final tb = b.startsWith('100.') ? 0 : 1;
    return ta != tb ? ta - tb : a.compareTo(b);
  });
  return out;
}

enum VoiceCommandType { app, file, url, shell, system, media, appVolume }

class VoiceCommand {
  String phrase;
  VoiceCommandType type;
  String value;
  // Optional phrase spoken (TTS) when the command runs — e.g. "Открываю Яндекс
  // Музыку". Only spoken when voice responses are enabled. Empty = say the
  // generic "done" line instead.
  String speakPhrase;
  // Parametric fields for VoiceCommandType.appVolume (new-features Ф2). `value`
  // holds the app's display name; `process` the audio-session exe. `phrase` is
  // a template with {N} (e.g. "громкость на {N}"). action is one of
  // set/increase/decrease/mute/unmute. defaultValue applies when the utterance
  // names no number; argMin/argMax bound and clamp it.
  String process;
  String action;
  int? defaultValue;
  int argMin;
  int argMax;
  // Launch through a pre-authorized Task Scheduler task (created once with a
  // single UAC consent) so admin-only apps start without the confirmation
  // window. See CommandExecutor.ensureElevatedTask.
  bool elevated;
  VoiceCommand({
    required this.phrase,
    required this.type,
    required this.value,
    this.speakPhrase = '',
    this.process = '',
    this.action = 'set',
    this.defaultValue,
    this.argMin = 0,
    this.argMax = 100,
    this.elevated = false,
  });

  Map<String, dynamic> toJson() => {
        'phrase': phrase,
        'type': type.name,
        'value': value,
        if (speakPhrase.isNotEmpty) 'speak': speakPhrase,
        if (elevated) 'elevated': true,
        if (type == VoiceCommandType.appVolume) ...{
          'process': process,
          'action': action,
          if (defaultValue != null) 'default': defaultValue,
          'min': argMin,
          'max': argMax,
        },
      };

  factory VoiceCommand.fromJson(Map<String, dynamic> j) => VoiceCommand(
        phrase: j['phrase'] as String? ?? '',
        type: VoiceCommandType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => VoiceCommandType.app,
        ),
        value: j['value'] as String? ?? '',
        speakPhrase: j['speak'] as String? ?? '',
        elevated: j['elevated'] == true,
        process: j['process'] as String? ?? '',
        action: j['action'] as String? ?? 'set',
        defaultValue: (j['default'] as num?)?.toInt(),
        argMin: (j['min'] as num?)?.toInt() ?? 0,
        argMax: (j['max'] as num?)?.toInt() ?? 100,
      );
}

// One launchable program in the add-command picker.
class ProgramEntry {
  final String name;
  // Command value: a .lnk/.exe path (classic) or "shell:AppsFolder\<AppID>"
  // (Microsoft Store / UWP). CommandExecutor.execute launches both.
  final String value;
  // Key for the icon cache: the .lnk/.exe path, or "uwp:<AppID>".
  final String iconSource;
  const ProgramEntry(this.name, this.value, this.iconSource);
}

// Enumerate installed programs: classic apps from the Start Menu (.lnk, both
// all-users and per-user trees) PLUS Microsoft Store / UWP apps (Get-StartApps,
// AppIDs containing "!"). De-duplicated by name, sorted. CommandExecutor
// resolves .lnk shortcuts and launches UWP via shell:AppsFolder.
Future<List<ProgramEntry>> listInstalledPrograms() async {
  final out = <String, ProgramEntry>{}; // name -> entry (dedupe by name)
  final roots = <String>[];
  final programData = io.Platform.environment['ProgramData'];
  final appData = io.Platform.environment['APPDATA'];
  if (programData != null) {
    roots.add('$programData\\Microsoft\\Windows\\Start Menu\\Programs');
  }
  if (appData != null) {
    roots.add('$appData\\Microsoft\\Windows\\Start Menu\\Programs');
  }
  bool isNoise(String name) {
    final lower = name.toLowerCase();
    return lower.contains('uninstall') ||
        lower.contains('удал') ||
        lower.contains('readme') ||
        lower.contains('license');
  }

  for (final root in roots) {
    final dir = io.Directory(root);
    if (!await dir.exists()) continue;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! io.File) continue;
        final path = e.path;
        if (!path.toLowerCase().endsWith('.lnk')) continue;
        var name = path.split(io.Platform.pathSeparator).last;
        name = name.substring(0, name.length - 4); // drop ".lnk"
        if (isNoise(name)) continue;
        out.putIfAbsent(name, () => ProgramEntry(name, path, path));
      }
    } catch (_) {}
  }

  // Microsoft Store / UWP / PWA apps via Get-StartApps. Include AUMIDs (with
  // "!") AND packaged/PWA entries whose AppID is a bare id (no backslash, not a
  // {GUID}\path, not an auto-generated system entry). The latter catches Store
  // PWAs like Yandex Music (AppID "Yandex", no "!"). Classic {GUID}\path apps
  // are already covered by the .lnk scan, so they're excluded here.
  try {
    final res = await io.Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        // Force UTF-8 output so Cyrillic app names aren't mojibake (PowerShell
        // otherwise writes the OEM codepage, which we'd misdecode).
        '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
            r"Get-StartApps | Where-Object { $_.AppID -like '*!*' -or "
            r"($_.AppID -notlike '*\*' -and $_.AppID -notlike '{*' -and "
            r"$_.AppID -notlike 'Microsoft.AutoGenerated*') } | "
            'Select-Object Name,AppID | ConvertTo-Json -Compress'
      ],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 12));
    if (res.exitCode == 0) {
      // Drop anything (BOM/whitespace) before the JSON starts, then parse.
      var jsonStr = res.stdout as String;
      final start = jsonStr.indexOf(RegExp(r'[\[{]'));
      if (start > 0) jsonStr = jsonStr.substring(start);
      final decoded = jsonDecode(jsonStr.trim());
      final items = decoded is List ? decoded : [decoded];
      for (final it in items) {
        if (it is! Map) continue;
        final name = (it['Name'] ?? '').toString().trim();
        final appId = (it['AppID'] ?? '').toString().trim();
        if (name.isEmpty || appId.isEmpty || isNoise(name)) continue;
        out.putIfAbsent(
            name,
            () => ProgramEntry(
                name, 'shell:AppsFolder\\$appId', 'uwp:$appId'));
      }
    }
  } catch (_) {}

  final list = out.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

// ---- AI voice-command suggestions (new-features Ф1) ----

// One AI-proposed command in the confirmation screen: an app from the real scan
// (its path is authoritative — the model never touches it), a proposed, editable
// phrase, whether it's selected, and whether the phrase collides.
class CmdSuggestion {
  final ProgramEntry program;
  String phrase;
  bool selected;
  bool collides;
  final int usage;
  CmdSuggestion(this.program, this.phrase,
      {this.selected = true, this.collides = false, this.usage = 0});
}

// Windows UserAssist run-counts keyed by normalized app name (leaf without
// .exe/.lnk, lowercased). Best-effort: {} on any failure, and the caller falls
// back to alphabetical order (Ф1 §1.5a / §1.8). Uses PowerShell -EncodedCommand
// (base64 UTF-16LE) so the script needs no shell-quoting.
Future<Map<String, int>> readUsageScores() async {
  if (!io.Platform.isWindows) return {};
  const ps = r'''
$ErrorActionPreference='SilentlyContinue'
function R13($s){ -join ($s.ToCharArray()|%{ $c=[int][char]$_
  if($c-ge65-and$c-le90){[char](65+($c-65+13)%26)}
  elseif($c-ge97-and$c-le122){[char](97+($c-97+13)%26)}else{[char]$c} }) }
$guids='{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}','{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}'
$out=@{}
foreach($g in $guids){
  $k="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\$g\Count"
  if(-not(Test-Path $k)){continue}
  $p=Get-Item $k
  foreach($n in $p.GetValueNames()){
    if([string]::IsNullOrEmpty($n)){continue}
    $d=R13 $n; $data=$p.GetValue($n); $c=0
    if($data -is [byte[]] -and $data.Length -ge 8){$c=[BitConverter]::ToUInt32($data,4)}
    $leaf=($d -split '[\\/]')[-1] -replace '\.(exe|lnk)$',''
    $leaf=$leaf.ToLower().Trim()
    if($leaf){ if(-not $out.ContainsKey($leaf) -or $out[$leaf]-lt $c){$out[$leaf]=$c} }
  }
}
$out.GetEnumerator()|%{ "$($_.Key)`t$($_.Value)" }
''';
  try {
    final units = ps.codeUnits;
    final b = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      b[i * 2] = units[i] & 0xff;
      b[i * 2 + 1] = (units[i] >> 8) & 0xff;
    }
    final r = await io.Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64.encode(b),
    ]).timeout(const Duration(seconds: 12));
    final map = <String, int>{};
    for (final line in (r.stdout as String).split('\n')) {
      final parts = line.trim().split('\t');
      if (parts.length == 2) {
        final n = int.tryParse(parts[1].trim());
        if (n != null) map[parts[0].trim()] = n;
      }
    }
    return map;
  } catch (_) {
    return {};
  }
}

class SuggestionEngine {
  static String normalizeName(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\.(exe|lnk)$'), '').trim();

  // Filter out installers/updaters/uninstallers and EVS itself before anything
  // is shown or sent to the model (§1.8).
  static final RegExp _junk = RegExp(
      r'(uninstall|установка|удал|setup|installer|updater|обновлen|crash|report|helper|redist|vcredist)',
      caseSensitive: false);
  static bool isJunk(ProgramEntry p) {
    final n = p.name.toLowerCase();
    if (n == 'evs' || p.value.toLowerCase().contains('evs.exe')) return true;
    return _junk.hasMatch(n);
  }

  static int scoreFor(ProgramEntry p, Map<String, int> usage) {
    final byName = usage[normalizeName(p.name)];
    if (byName != null) return byName;
    // Fall back to the exe basename of the launch target.
    final v = p.value.toLowerCase();
    final slash = v.lastIndexOf(RegExp(r'[\\/]'));
    final leaf = normalizeName(slash >= 0 ? v.substring(slash + 1) : v);
    return usage[leaf] ?? 0;
  }

  static String fallbackPhrase(String name) {
    var n = name.trim();
    // Drop a trailing version/edition tail so "открой" reads naturally.
    n = n.replaceAll(RegExp(r'\s*\d[\d.]*$'), '').trim();
    return 'открой ${n.toLowerCase()}';
  }

  // Prompt the model to return ONLY JSON {name: [phrases]}. Names only — never
  // paths (§1.3).
  static String buildPrompt(List<String> names) =>
      'Для каждого приложения из списка предложи 1–3 коротких естественных '
      'русских голосовых фразы для его запуска. Фразы должны быть разными и не '
      'пересекаться между приложениями. Ответь ТОЛЬКО валидным JSON, без пояснений '
      'и разметки: {"Google Chrome": ["открой хром", "браузер"]}\n\n'
      'Список приложений: ${jsonEncode(names)}';

  // Defensive parse: tolerate ```-fences and surrounding prose, extract the
  // first {...} block, coerce to {name: [phrases]}. Null on failure.
  static Map<String, List<String>>? parseModelJson(String raw) {
    try {
      var s = raw.trim();
      s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '').replaceAll('```', '');
      final start = s.indexOf('{');
      final end = s.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final decoded = jsonDecode(s.substring(start, end + 1));
      if (decoded is! Map) return null;
      final out = <String, List<String>>{};
      decoded.forEach((k, v) {
        if (v is List) {
          final phrases = v
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (phrases.isNotEmpty) out[k.toString()] = phrases;
        } else if (v is String && v.trim().isNotEmpty) {
          out[k.toString()] = [v.trim()];
        }
      });
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  // Assign a unique phrase per suggestion and flag any that still collide with an
  // existing command or an earlier suggestion (§1.8). Mutates in place.
  static void resolveCollisions(
      List<CmdSuggestion> sugg, List<VoiceCommand> existing) {
    final taken = <String>{
      for (final c in existing) c.phrase.trim().toLowerCase(),
    };
    for (final s in sugg) {
      final p = s.phrase.trim().toLowerCase();
      if (p.isEmpty || taken.contains(p)) {
        s.collides = true;
      } else {
        taken.add(p);
        s.collides = false;
      }
    }
  }
}

// Remote-input settings panel (TZ §14): enable the listener, port, connection
// address + pairing QR, response target, and the paired-device list. Stateful
// for the port field, the async local-address lookup and the transient pairing
// code. Device data lives on AppState, so the surrounding watch() rebuilds this
// when a phone pairs or is edited.
class _RemoteInputPanel extends StatefulWidget {
  const _RemoteInputPanel(this.app);
  final AppState app;
  @override
  State<_RemoteInputPanel> createState() => _RemoteInputPanelState();
}

class _RemoteInputPanelState extends State<_RemoteInputPanel> {
  late final TextEditingController _port =
      TextEditingController(text: widget.app.remoteInputPort.toString());
  List<String> _addrs = [];
  String? _pairCode;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _loadAddrs();
  }

  Future<void> _loadAddrs() async {
    final a = await localAddresses();
    if (mounted) setState(() => _addrs = a);
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  String get _primaryAddr => _addrs.isNotEmpty ? _addrs.first : '127.0.0.1';

  void _newCode() {
    setState(() => _pairCode = RemoteInputServer.instance.newPairCode());
  }

  // Payload the phone app scans: everything it needs to pair in one QR.
  String _qrData() => jsonEncode({
        'host': _primaryAddr,
        'port': app.remoteInputPort,
        if (_pairCode != null) 'code': _pairCode,
      });

  String _deviceStatus(RemoteDevice d) {
    if (d.lastSeen.isEmpty) return app.t('remoteNever');
    final t = DateTime.tryParse(d.lastSeen);
    if (t == null) return app.t('remoteNever');
    final diff = DateTime.now().toUtc().difference(t.toUtc());
    if (diff.inSeconds < 120) return app.t('remoteOnline');
    final mins = diff.inMinutes;
    final human = mins < 60
        ? '$mins м назад'
        : mins < 1440
            ? '${mins ~/ 60} ч назад'
            : '${mins ~/ 1440} дн назад';
    return '${app.t('remoteLastSeen')} $human';
  }

  @override
  Widget build(BuildContext context) {
    final on = app.remoteInputEnabled;
    final running = RemoteInputServer.instance.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        evsRow(context, 
          label: app.t('remoteEnable'),
          desc: app.t('remoteEnableDesc'),
          control: evsToggle(context, on, app.setRemoteInputEnabled),
        ),
        if (on) ...[
          // Status + port.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(children: [
              Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: running
                          ? _success(context)
                          : _danger(context))),
              const SizedBox(width: 7),
              Text(running ? app.t('remoteServerOn') : app.t('remoteServerOff'),
                  style: TextStyle(
                      fontSize: 12,
                      color: running
                          ? _success(context)
                          : _danger(context))),
            ]),
          ),
          evsRow(context, 
            label: app.t('remotePort'),
            control: SizedBox(
              width: 90,
              child: _RemoteField(
                controller: _port,
                onChanged: (v) {
                  final p = int.tryParse(v.trim());
                  if (p != null && p > 0 && p < 65536) app.setRemoteInputPort(p);
                },
              ),
            ),
          ),
          // Connection addresses.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Text(app.t('remoteAddress'),
                style: TextStyle(
                    fontSize: 12.5, color: _body(context))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in _addrs)
                  Text('$a:${app.remoteInputPort}',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                          color: _sub(context))),
                if (_addrs.isEmpty)
                  Text('127.0.0.1:${app.remoteInputPort}',
                      style: TextStyle(
                          fontSize: 12.5, color: _faint(context))),
              ],
            ),
          ),
          evsRow(context, 
            stacked: true,
            label: app.t('remoteResponse'),
            control: evsSegmentedWide<String>(context, [
              ('desktop_tts', app.t('remoteRespDesktop')),
              ('phone_text', app.t('remoteRespPhone')),
              ('both', app.t('remoteRespBoth')),
            ], app.remoteResponseTarget, app.setRemoteResponseTarget),
          ),
          Divider(color: _stroke(context), height: 20),
          _addPhoneSection(),
          Divider(color: _stroke(context), height: 20),
          _devicesSection(),
        ],
      ],
    );
  }

  Widget _addPhoneSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(app.t('remoteCardAdd'),
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _body(context))),
        ),
        if (_pairCode == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: evsAddButton(context, app.t('remoteCardAdd'), _newCode),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8)),
                  child: QrImageView(
                    data: _qrData(),
                    size: 120,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.t('remotePairCode'),
                          style: TextStyle(
                              fontSize: 12, color: _sub(context))),
                      const SizedBox(height: 2),
                      SelectableText(_pairCode!,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                              color: _txt(context))),
                      const SizedBox(height: 6),
                      Text(app.t('remotePairHint'),
                          style: TextStyle(
                              fontSize: 11.5, color: _faint(context))),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: _newCode,
                        borderRadius: BorderRadius.circular(8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.refresh,
                              size: 14, color: _sub(context)),
                          const SizedBox(width: 5),
                          Text(app.t('remoteNewCode'),
                              style: TextStyle(
                                  fontSize: 12, color: _sub(context))),
                        ]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _devicesSection() {
    final devs = app.remoteDevices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(app.t('remoteCardDevices'),
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _body(context))),
        ),
        if (devs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(app.t('remoteNoDevices'),
                style: TextStyle(fontSize: 12.5, color: _faint(context))),
          ),
        for (final d in devs) _deviceRow(d),
      ],
    );
  }

  Widget _deviceRow(RemoteDevice d) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.03),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.smartphone, size: 15, color: _sub(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(d.name.isEmpty ? 'Телефон' : d.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
            ),
            Text(_deviceStatus(d),
                style: TextStyle(fontSize: 11, color: _faint(context))),
            const SizedBox(width: 8),
            evsToggle(context, d.enabled, (v) => app.setRemoteDeviceEnabled(d, v)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _permChip(app.t('remotePermVoice'), d.permVoice,
                (v) => app.setRemoteDevicePerms(d, voice: v)),
            const SizedBox(width: 8),
            _permChip(app.t('remotePermText'), d.permText,
                (v) => app.setRemoteDevicePerms(d, text: v)),
            const Spacer(),
            InkWell(
              onTap: () => app.removeRemoteDevice(d),
              borderRadius: BorderRadius.circular(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.link_off, size: 13, color: Color(0xFFE08080)),
                const SizedBox(width: 4),
                Text(app.t('remoteUnpair'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFE08080))),
              ]),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _permChip(String label, bool on, ValueChanged<bool> onTap) {
    return InkWell(
      onTap: () => onTap(!on),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: on ? const Color(0x2654E08A) : _overlayFill(context, 0.04),
          border: Border.all(
              color: on ? _success(context) : _stroke(context)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(on ? Icons.check : Icons.close,
              size: 12,
              color: on ? _success(context) : _faint(context)),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: on ? _body(context) : _faint(context))),
        ]),
      ),
    );
  }
}

// Small bordered text field matching the settings look (used by the remote panel).
class _RemoteField extends StatelessWidget {
  const _RemoteField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _overlayFill(context, 0.04),
        border: Border.all(color: _stroke(context)),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: 12.5, color: _body(context)),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

// AI voice-command suggestion review (Ф1 §1.7). Loads suggestions, lets the user
// tick apps, edit each phrase (with live collision checking), and saves the
// selected ones. Paths shown are read-only — they come from the scan, not the
// model. Pops the number saved, or null on cancel.
class _SuggestCommandsDialog extends StatefulWidget {
  const _SuggestCommandsDialog(this.app);
  final AppState app;
  @override
  State<_SuggestCommandsDialog> createState() => _SuggestCommandsDialogState();
}

class _SuggestCommandsDialogState extends State<_SuggestCommandsDialog> {
  List<CmdSuggestion>? _sugg; // null = loading
  final Map<CmdSuggestion, TextEditingController> _ctrls = {};
  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await app.buildCommandSuggestions();
    if (!mounted) return;
    for (final x in s) {
      _ctrls[x] = TextEditingController(text: x.phrase);
    }
    _deselectColliding(s);
    setState(() => _sugg = s);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // A colliding phrase can't be saved (§1.8: don't silently save a clash), so it
  // is unchecked and its box disabled until the phrase is edited to be unique.
  void _deselectColliding(List<CmdSuggestion> s) {
    for (final x in s) {
      if (x.collides) x.selected = false;
    }
  }

  void _onEdit(CmdSuggestion s, String v) {
    s.phrase = v;
    SuggestionEngine.resolveCollisions(_sugg!, app.voiceCommands);
    _deselectColliding(_sugg!);
    setState(() {});
  }

  void _save() {
    final chosen = _sugg!.where((s) => s.selected && !s.collides).toList();
    for (final s in chosen) {
      app.addVoiceCommand(VoiceCommand(
        phrase: s.phrase.trim(),
        type: VoiceCommandType.app,
        value: s.program.value, // authoritative path from the scan
      ));
    }
    Navigator.pop(context, chosen.length);
  }

  @override
  Widget build(BuildContext context) {
    final sugg = _sugg;
    return AlertDialog(
      backgroundColor: _card2(context),
      title: Text(app.t('cmdSuggestTitle'),
          style: TextStyle(color: _txt(context), fontSize: 17)),
      content: SizedBox(
        width: 470,
        height: 470,
        child: sugg == null
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(height: 14),
                  Text(app.t('cmdSuggestScanning'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _sub(context), fontSize: 13)),
                ]),
              )
            : sugg.isEmpty
                ? Center(
                    child: Text(app.t('cmdSuggestEmpty'),
                        style: TextStyle(color: _faint(context))))
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Icon(Icons.lock_outline,
                            size: 14, color: _faint(context)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(app.t('cmdSuggestPrivacy'),
                              style: TextStyle(
                                  fontSize: 11.5, color: _faint(context))),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: sugg.length,
                        itemBuilder: (_, i) => _row(sugg[i]),
                      ),
                    ),
                  ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(app.t('cancel')),
        ),
        if (sugg != null && sugg.isNotEmpty)
          TextButton(
            onPressed: sugg.any((s) => s.selected && !s.collides) ? _save : null,
            child: Text(app.t('cmdSuggestSaveSel')),
          ),
      ],
    );
  }

  Widget _badge(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: color.withValues(alpha: 0.14),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      );

  Widget _row(CmdSuggestion s) {
    final isStore = s.program.value.toLowerCase().startsWith('shell:appsfolder');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(6, 8, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: _overlayFill(context, 0.03),
        border: Border.all(
            color: s.collides ? const Color(0xFFE0685E) : _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
              width: 26,
              height: 26,
              child: Checkbox(
                value: s.selected,
                onChanged:
                    s.collides ? null : (v) => setState(() => s.selected = v ?? false),
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: _faint(context)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(s.program.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _body(context))),
            ),
            if (s.usage > 0) _badge(app.t('cmdSuggestFreq'), _success(context)),
            if (isStore) _badge('Store', const Color(0xFF7BA0E0)),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 2, right: 2),
            child: TextField(
              controller: _ctrls[s],
              onChanged: (v) => _onEdit(s, v),
              style: TextStyle(fontSize: 12.5, color: _body(context)),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: _overlayFill(context, 0.04),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _stroke(context)),
                ),
              ),
            ),
          ),
          if (s.collides)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 3),
              child: Text(app.t('cmdSuggestCollision'),
                  style: const TextStyle(fontSize: 11, color: Color(0xFFE0685E))),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 3),
            child: Text(
              isStore ? 'Microsoft Store' : s.program.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: _faint(context)),
            ),
          ),
        ],
      ),
    );
  }
}

// Step-by-step "add command" wizard: pick a category (program / file / site /
// system / media) → choose the value (installed-program list, file picker, URL,
// or a system/media action) → enter the trigger phrase. Pops the built
// VoiceCommand, or null on cancel.
class _AddCommandWizard extends StatefulWidget {
  final AppState app;
  // When set, the wizard opens in EDIT mode: pre-filled and jumps straight to
  // the phrase step; "Save" returns the updated command.
  final VoiceCommand? initial;
  const _AddCommandWizard({required this.app, this.initial});
  @override
  State<_AddCommandWizard> createState() => _AddCommandWizardState();
}

class _AddCommandWizardState extends State<_AddCommandWizard> {
  int _step = 0; // 0 = category, 1 = value, 2 = phrase
  VoiceCommandType? _type;
  String _value = '';
  String _valueLabel = ''; // human-friendly summary
  final _phraseCtrl = TextEditingController();
  final _speakCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  List<ProgramEntry>? _programs; // null = loading
  String _progFilter = '';
  final Map<String, String> _iconPaths = {}; // iconSource -> cached PNG path
  // App-volume (appVolume) wizard state.
  List<Map<String, dynamic>>? _sessions; // null = loading active audio sessions
  String _avProcess = '';
  String _avAction = 'set';
  final _avDefaultCtrl = TextEditingController();
  // Elevated launch (no UAC prompt) via a pre-authorized scheduler task.
  bool _elevated = false;
  bool _creatingTask = false;

  bool get _isEdit => widget.initial != null;
  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    final it = widget.initial;
    if (it != null) {
      _type = it.type;
      _value = it.value;
      _valueLabel = it.value;
      _phraseCtrl.text = it.phrase;
      _speakCtrl.text = it.speakPhrase;
      _avProcess = it.process;
      _avAction = it.action;
      _avDefaultCtrl.text = it.defaultValue?.toString() ?? '';
      _elevated = it.elevated;
      _step = 2; // straight to the phrase step; user can go Back to re-pick
    }
  }

  @override
  void dispose() {
    _phraseCtrl.dispose();
    _speakCtrl.dispose();
    _urlCtrl.dispose();
    _avDefaultCtrl.dispose();
    super.dispose();
  }

  static const _cats = <(VoiceCommandType, String, IconData)>[
    (VoiceCommandType.app, 'cmdWizProgram', Icons.apps),
    (VoiceCommandType.file, 'cmdWizFile', Icons.insert_drive_file_outlined),
    (VoiceCommandType.url, 'cmdWizSite', Icons.language),
    (VoiceCommandType.system, 'cmdWizSystem', Icons.settings_suggest_outlined),
    (VoiceCommandType.media, 'cmdWizMedia', Icons.music_note_outlined),
    (VoiceCommandType.appVolume, 'cmdWizVolume', Icons.volume_up_outlined),
  ];

  Future<void> _pickCategory(VoiceCommandType t) async {
    setState(() {
      _type = t;
      _value = '';
      _valueLabel = '';
    });
    if (t == VoiceCommandType.app) {
      setState(() {
        _programs = null;
        _step = 1;
      });
      final progs = await listInstalledPrograms();
      if (mounted) setState(() => _programs = progs);
      // Extract real app icons in the background; fill them in as they arrive.
      final map =
          await buildProgramIcons(progs.map((e) => e.iconSource).toList());
      if (mounted && map.isNotEmpty) setState(() => _iconPaths.addAll(map));
    } else if (t == VoiceCommandType.file) {
      await _pickFileValue();
    } else if (t == VoiceCommandType.appVolume) {
      // Default the phrase template so the {N} slot is discoverable.
      if (_phraseCtrl.text.trim().isEmpty) _phraseCtrl.text = 'громкость на {N}';
      setState(() {
        _sessions = null;
        _step = 1;
      });
      await _loadSessions();
    } else {
      setState(() => _step = 1);
    }
  }

  Future<void> _loadSessions() async {
    final s = await SidecarClient.instance.listAudioSessions();
    if (mounted) setState(() => _sessions = s);
  }

  Future<void> _pickFileValue() async {
    try {
      final res = await FilePicker.pickFiles();
      final p = res?.files.single.path;
      if (p != null && p.isNotEmpty && mounted) {
        setState(() {
          _value = p;
          _valueLabel = p.split(io.Platform.pathSeparator).last;
          _step = 2;
        });
      }
    } catch (_) {}
  }

  void _chooseValue(String value, String label) {
    setState(() {
      _value = value;
      _valueLabel = label;
      _step = 2;
    });
  }

  // Elevation only makes sense for things that actually launch a process.
  bool get _canElevate =>
      _type == VoiceCommandType.app ||
      _type == VoiceCommandType.file ||
      _type == VoiceCommandType.shell;

  Future<void> _finish() async {
    if (_creatingTask) return;
    final phrase = _phraseCtrl.text.trim();
    if (phrase.isEmpty || _type == null || _value.trim().isEmpty) return;
    if (_type == VoiceCommandType.appVolume) {
      if (_avProcess.trim().isEmpty) return;
      final def = int.tryParse(_avDefaultCtrl.text.trim());
      Navigator.pop(
          context,
          VoiceCommand(
            phrase: phrase,
            type: VoiceCommandType.appVolume,
            value: _value.trim(), // display name
            speakPhrase: _speakCtrl.text.trim(),
            process: _avProcess.trim(),
            action: _avAction,
            defaultValue: def,
          ));
      return;
    }
    final cmd = VoiceCommand(
      phrase: phrase,
      type: _type!,
      value: _value.trim(),
      speakPhrase: _speakCtrl.text.trim(),
      elevated: _elevated && _canElevate,
    );
    // The old task is stale once elevation is turned off or the target changed.
    final old = widget.initial;
    if (old != null &&
        old.elevated &&
        (!cmd.elevated || old.value.trim() != cmd.value)) {
      unawaited(CommandExecutor.instance.tryDeleteElevatedTask(old.value));
    }
    if (cmd.elevated) {
      // One UAC consent while the wizard shows a spinner; on refusal/failure
      // the command is still saved, just with the normal (prompting) launch.
      setState(() => _creatingTask = true);
      final ok = await CommandExecutor.instance.ensureElevatedTask(cmd);
      if (!mounted) return;
      setState(() => _creatingTask = false);
      if (!ok) {
        cmd.elevated = false;
        showAppSnackBar(context, app.t('cmdElevatedFailed'));
      }
    }
    if (!mounted) return;
    Navigator.pop(context, cmd);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card2(context),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      title: Row(children: [
        if (_step > 0)
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.arrow_back, color: _txt(context), size: 20),
            onPressed: () => setState(() => _step -= 1),
          ),
        if (_step > 0) const SizedBox(width: 8),
        Expanded(
          child: Text(_stepTitle(),
              style: TextStyle(color: _txt(context), fontSize: 17)),
        ),
      ]),
      content: SizedBox(width: 380, child: _stepBody()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(app.t('cancel')),
        ),
        if (_step == 1 && _type == VoiceCommandType.appVolume)
          TextButton(
            onPressed: _avProcess.trim().isEmpty
                ? null
                : () => setState(() => _step = 2),
            child: Text(app.t('next')),
          ),
        if (_step == 2)
          TextButton(
            onPressed: _finish,
            child: Text(_isEdit ? app.t('save') : app.t('add')),
          ),
      ],
    );
  }

  // Step 1 for app-volume: pick a currently-playing app (from the sidecar's live
  // audio sessions — §2.4), the action, and a fallback value.
  Widget _volumeStep() {
    final sessions = _sessions;
    const actions = <(String, String)>[
      ('set', 'volActSet'),
      ('increase', 'volActInc'),
      ('decrease', 'volActDec'),
      ('mute', 'volActMute'),
      ('unmute', 'volActUnmute'),
    ];
    return SizedBox(
      height: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(app.t('volPickApp'),
                  style: TextStyle(
                      fontSize: 13, color: _body(context))),
            ),
            IconButton(
              tooltip: app.t('refreshModelsBtn'),
              icon: Icon(Icons.refresh, size: 18, color: _sub(context)),
              onPressed: () {
                setState(() => _sessions = null);
                _loadSessions();
              },
            ),
          ]),
          const SizedBox(height: 4),
          Expanded(
            child: sessions == null
                ? const Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : sessions.isEmpty
                    ? Center(
                        child: Text(app.t('volNoSessions'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5, color: _faint(context))))
                    : ListView(
                        children: [
                          for (final s in sessions)
                            _sessionTile(
                              (s['process'] ?? '').toString(),
                              (s['display_name'] ?? '').toString(),
                              (s['volume'] as num?)?.toDouble(),
                            ),
                        ],
                      ),
          ),
          const SizedBox(height: 8),
          Text(app.t('volAction'),
              style: TextStyle(fontSize: 12.5, color: _sub(context))),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in actions)
                ChoiceChip(
                  label: Text(app.t(a.$2), style: const TextStyle(fontSize: 12)),
                  selected: _avAction == a.$1,
                  onSelected: (_) => setState(() => _avAction = a.$1),
                  backgroundColor: const Color(0xFF20202B),
                  selectedColor: const Color(0xFF3A3550),
                  labelStyle: TextStyle(color: _body(context)),
                ),
            ],
          ),
          // A fallback value only makes sense for the numeric actions.
          if (_avAction == 'set' ||
              _avAction == 'increase' ||
              _avAction == 'decrease') ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(app.t('volDefault'),
                    style: TextStyle(
                        fontSize: 12.5, color: _body(context))),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _avDefaultCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 12.5, color: _body(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: app.t('llmDefaultHint'),
                    hintStyle:
                        TextStyle(fontSize: 12, color: _faint(context)),
                    filled: true,
                    fillColor: _overlayFill(context, 0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _stroke(context)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _stroke(context)),
                    ),
                  ),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _sessionTile(String process, String display, double? vol) {
    final selected = _avProcess.toLowerCase() == process.toLowerCase();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() {
        _avProcess = process;
        _value = display.isNotEmpty ? display : process;
        _valueLabel = _value;
      }),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected
              ? const Color(0x263A7BE0)
              : _overlayFill(context, 0.03),
          border: Border.all(
              color: selected ? _accent(context) : _stroke(context)),
        ),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: selected ? const Color(0xFF7BA0E0) : _faint(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(display.isNotEmpty ? display : process,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: _body(context))),
                Text(process,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: _faint(context))),
              ],
            ),
          ),
          if (vol != null)
            Text('${(vol * 100).round()}%',
                style: TextStyle(fontSize: 11.5, color: _sub(context))),
        ]),
      ),
    );
  }

  String _stepTitle() {
    if (_step == 0) return app.t('cmdWizType');
    if (_step == 2) return app.t('cmdWizPhrase');
    switch (_type) {
      case VoiceCommandType.app:
        return app.t('cmdWizPickProgram');
      case VoiceCommandType.url:
        return app.t('cmdWizSite');
      case VoiceCommandType.system:
        return app.t('cmdWizSystem');
      case VoiceCommandType.media:
        return app.t('cmdWizMedia');
      case VoiceCommandType.appVolume:
        return app.t('cmdWizVolume');
      default:
        return app.t('cmdAdd');
    }
  }

  Widget _stepBody() {
    if (_step == 0) return _categoryStep();
    if (_step == 2) return _phraseStep();
    switch (_type) {
      case VoiceCommandType.appVolume:
        return _volumeStep();
      case VoiceCommandType.app:
        return _programStep();
      case VoiceCommandType.url:
        return _urlStep();
      case VoiceCommandType.system:
        return _actionStep(const [
          ('lock', 'sysLock', Icons.lock_outline),
          ('sleep', 'sysSleep', Icons.bedtime_outlined),
          ('vol up', 'sysVolUp', Icons.volume_up),
          ('vol down', 'sysVolDown', Icons.volume_down),
          ('mute', 'sysMute', Icons.volume_off),
        ]);
      case VoiceCommandType.media:
        return _actionStep(const [
          ('play', 'mediaPlay', Icons.play_arrow),
          ('next', 'mediaNext', Icons.skip_next),
          ('prev', 'mediaPrev', Icons.skip_previous),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _categoryStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (type, key, icon) in _cats)
          _wizTile(icon, app.t(key), () => _pickCategory(type)),
      ],
    );
  }

  // Real app icon (from the PowerShell-built cache) when available, else a
  // neutral fallback. UWP entries use "uwp:" iconSource; classic use the path.
  Widget _progIcon(ProgramEntry p) {
    final path = _iconPaths[p.iconSource];
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Image.file(io.File(path),
            width: 22,
            height: 22,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _progIconFallback(p)),
      );
    }
    return _progIconFallback(p);
  }

  Widget _progIconFallback(ProgramEntry p) => Icon(
        p.iconSource.startsWith('uwp:') ? Icons.storefront : Icons.launch,
        size: 18,
        color: _accent(context),
      );

  Widget _programStep() {
    final progs = _programs;
    return SizedBox(
      height: 360,
      child: Column(
        children: [
          TextField(
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF7A8090)),
              hintText: app.t('cmdWizSearch'),
              hintStyle: TextStyle(color: _faint(context), fontSize: 13),
            ),
            onChanged: (v) => setState(() => _progFilter = v.toLowerCase()),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _pickFileValue,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(app.t('cmdWizPickExe')),
            ),
          ),
          Expanded(
            child: progs == null
                ? const Center(child: CircularProgressIndicator())
                : Builder(builder: (_) {
                    final filtered = _progFilter.isEmpty
                        ? progs
                        : progs
                            .where((p) =>
                                p.name.toLowerCase().contains(_progFilter))
                            .toList();
                    if (filtered.isEmpty) {
                      return Center(
                          child: Text(app.t('cmdWizNoPrograms'),
                              style: TextStyle(color: _faint(context))));
                    }
                    return ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final p = filtered[i];
                        return ListTile(
                          dense: true,
                          leading: _progIcon(p),
                          title: Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: _body(context), fontSize: 13)),
                          onTap: () => _chooseValue(p.value, p.name),
                        );
                      },
                    );
                  }),
          ),
        ],
      ),
    );
  }

  Widget _urlStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _urlCtrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: const InputDecoration(hintText: 'https://…'),
          onSubmitted: (_) => _confirmUrl(),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _confirmUrl,
            child: Text(app.t('next')),
          ),
        ),
      ],
    );
  }

  void _confirmUrl() {
    var u = _urlCtrl.text.trim();
    if (u.isEmpty) return;
    if (!u.contains('://')) u = 'https://$u';
    _chooseValue(u, u);
  }

  Widget _actionStep(List<(String, String, IconData)> actions) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (value, key, icon) in actions)
          _wizTile(icon, app.t(key), () => _chooseValue(value, app.t(key))),
      ],
    );
  }

  Widget _phraseStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _overlayFill(context, 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(Icons.bolt, size: 15, color: _accent(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _valueLabel.isNotEmpty ? _valueLabel : _value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _sub(context), fontSize: 12.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _phraseCtrl,
          autofocus: true,
          style: TextStyle(color: _txt(context)),
          decoration: InputDecoration(
            labelText: app.t('cmdWizPhrase'),
            hintText: app.t('cmdWizPhraseHint'),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _finish(),
        ),
        // Parametric volume commands: spell out how {N} relates to the value
        // field on the previous step, otherwise "громкость на {N}" reads like a
        // literal phrase you have to say verbatim.
        if (_type == VoiceCommandType.appVolume)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(app.t('cmdWizVolHint'),
                style: TextStyle(fontSize: 11.5, color: _faint(context))),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _speakCtrl,
          style: TextStyle(color: _txt(context)),
          decoration: InputDecoration(
            labelText: app.t('cmdWizSpeak'),
            hintText: app.t('cmdWizSpeakHint'),
            prefixIcon: const Icon(Icons.volume_up_outlined,
                size: 18, color: Color(0xFF7A8090)),
          ),
          onSubmitted: (_) => _finish(),
        ),
        // Elevated launch (skip the per-launch UAC prompt) — only for command
        // types that actually start a process.
        if (_canElevate) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.shield_outlined, size: 16, color: _sub(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.t('cmdElevated'),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _body(context))),
                  Text(app.t('cmdElevatedDesc'),
                      style:
                          TextStyle(fontSize: 11, color: _faint(context))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_creatingTask)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              evsToggle(context, _elevated,
                  (v) => setState(() => _elevated = v)),
          ]),
        ],
      ],
    );
  }

  Widget _wizTile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _overlayFill(context, 0.04),
          border: Border.all(color: _stroke(context)),
        ),
        child: Row(children: [
          Icon(icon, size: 19, color: _accent(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: _body(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          Icon(Icons.chevron_right, size: 18, color: _faint(context)),
        ]),
      ),
    );
  }
}

// Recognition-test panel: speak and see exactly how the recognizer transcribes
// your phrase (to design a trigger phrase). Reuses the shared sidecar STT
// streams; only drives STT itself if the always-on assistant isn't already
// listening — so it never breaks the assistant.

/* ---- shared desktop-settings building blocks (mockup styling) ---- */

