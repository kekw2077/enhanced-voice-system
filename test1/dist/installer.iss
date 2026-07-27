; Inno Setup script for EVS (Windows desktop).
; Packages the Flutter release build into a single EVS-Setup-X.Y.Z.exe that
; WinSparkle (auto_updater) can download and run silently to update the app.
;
; Build prerequisites:
;   1. flutter build windows --release
;   2. Install Inno Setup 6 (https://jrsoftware.org/isdl.php)
;   3. iscc dist\installer.iss /DAppVersion=1.0.0
;      (or set MyAppVersion below and just run `iscc dist\installer.iss`)
;
; Output: dist\out\EVS-Setup-<version>.exe

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define MyAppName "EVS"
#define MyAppExeName "evs.exe"
#define MyAppPublisher "EVS"
; Stable upgrade GUID — keep constant across versions so installs upgrade
; in place instead of stacking side by side.
#define MyAppId "{{0DFA2B71-CBB9-43E0-B602-9F6DDC25D839}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
; Silent in-app updates pass /DIR="<running folder>" so the installer overwrites
; the copy the user actually runs (portable E:\EVS, a manual folder, or the
; default AppData location). Without this, Inno reuses the directory recorded in
; the registry for this AppId from a prior install and ignores /DIR — which left
; the running copy un-updated and the update looping. Let /DIR win every time.
UsePreviousAppDir=no
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=out
OutputBaseFilename=EVS-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; EVS branding: dark banner strip + header badge, both built from the app icon
; (dist/wizard-banner.bmp, dist/wizard-small.bmp). Inno themes only these images
; — the wizard chrome itself follows Windows, by design.
WizardImageFile=wizard-banner.bmp
WizardSmallImageFile=wizard-small.bmp
WizardImageStretch=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user install by default (installs to %LocalAppData%\Programs\EVS, no UAC).
; Silent in-app updates run the installer in the same non-elevated context, so
; there is no elevation prompt per update. An admin can still pick an all-users
; install via the dialog or /ALLUSERS.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
; In-app updates: if EVS is still running when files are copied, close it via
; Restart Manager instead of failing (the app normally exits itself first).
CloseApplications=force
RestartApplications=no
; Named mutex the running app holds (CreateMutexW in main.dart) so Setup can
; reliably detect a live instance during a silent in-app update.
AppMutex=EVS-SingleInstance-Mutex

[Code]
// The in-app updater (AppUpdater.applyAndRestart) launches this installer with
// /VERYSILENT ... /RELAUNCH=1 and exits; this relaunches the new version after
// the silent install so the update feels like a plain restart (Discord-style).
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

// ---- Optional module downloads (Inno 6.1+ built-in, no plugins) -----------
//
// Files land exactly where the app already looks for them, so the app's own
// logic finishes the job and nothing here has to duplicate it:
//   * sidecar  -> userdata\components\evs_sidecar.zip.new
//                 (ComponentManager.applyStagedUpdates verifies the sha256 and
//                  extracts it on the next launch — the same tested path used
//                  for background engine updates)
//   * models   -> userdata\models\<id>\<file>  (plain files, no extraction)
//
// A silent in-app update passes /VERYSILENT, where no component page is shown
// and nothing is downloaded — updates keep working exactly as before.
var
  DownloadPage: TDownloadWizardPage;

function OnDownloadProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  Result := True;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(
    SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc),
    @OnDownloadProgress);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Gigaam, Sherpa: String;
  Queued: Boolean;
begin
  Result := True;
  if CurPageID <> wpReady then Exit;
  Queued := False;

  Gigaam := 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16/resolve/main/';
  Sherpa := 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/';

  DownloadPage.Clear;
  if WizardIsComponentSelected('sidecar') then
  begin
    DownloadPage.Add('https://github.com/kekw2077/enhanced-voice-system/releases/download/desktop-components/evs_sidecar.zip', 'evs_sidecar.zip.new', '');
    Queued := True;
  end;
  if WizardIsComponentSelected('gigaam') then
  begin
    DownloadPage.Add(Gigaam + 'encoder.int8.onnx', 'gigaam__encoder.int8.onnx', '');
    DownloadPage.Add(Gigaam + 'decoder.onnx',      'gigaam__decoder.onnx', '');
    DownloadPage.Add(Gigaam + 'joiner.onnx',       'gigaam__joiner.onnx', '');
    DownloadPage.Add(Gigaam + 'tokens.txt',        'gigaam__tokens.txt', '');
    Queued := True;
  end;
  if WizardIsComponentSelected('denoise') then
  begin
    DownloadPage.Add(Sherpa + 'dpdfnet_baseline.onnx', 'denoise__dpdfnet_baseline.onnx', '');
    Queued := True;
  end;

  if not Queued then Exit;

  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
    except
      // Never fail the install over a download: the app can fetch any missing
      // piece itself later, so just tell the user and carry on.
      SuppressibleMsgBox(
        'Не удалось загрузить дополнительные модули:'#13#10 +
        GetExceptionMessage + #13#10#13#10 +
        'EVS установится, а недостающее можно будет скачать в самом приложении.',
        mbInformation, MB_OK, IDOK);
    end;
  finally
    DownloadPage.Hide;
  end;
end;

// Move whatever downloaded into the app's data folders. Runs after the files
// are copied, so {app} exists.
procedure MoveDownloaded;
var
  Comp, Models, Giga, Den: String;
begin
  // A silent in-app update shows no component page and downloads nothing,
  // so there is nothing to move — and the component flags would still read
  // as the default type, which must not be acted on here.
  if WizardSilent then Exit;
  Comp := ExpandConstant('{app}\userdata\components');
  Models := ExpandConstant('{app}\userdata\models');
  Giga := Models + '\gigaam-v3';
  Den := Models + '\denoise-df';

  if WizardIsComponentSelected('sidecar') then
  begin
    ForceDirectories(Comp);
    CopyFile(ExpandConstant('{tmp}\evs_sidecar.zip.new'), Comp + '\evs_sidecar.zip.new', False);
  end;
  if WizardIsComponentSelected('gigaam') then
  begin
    ForceDirectories(Giga);
    CopyFile(ExpandConstant('{tmp}\gigaam__encoder.int8.onnx'), Giga + '\encoder.int8.onnx', False);
    CopyFile(ExpandConstant('{tmp}\gigaam__decoder.onnx'),      Giga + '\decoder.onnx', False);
    CopyFile(ExpandConstant('{tmp}\gigaam__joiner.onnx'),       Giga + '\joiner.onnx', False);
    CopyFile(ExpandConstant('{tmp}\gigaam__tokens.txt'),        Giga + '\tokens.txt', False);
  end;
  if WizardIsComponentSelected('denoise') then
  begin
    ForceDirectories(Den);
    CopyFile(ExpandConstant('{tmp}\denoise__dpdfnet_baseline.onnx'), Den + '\dpdfnet_baseline.onnx', False);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then MoveDownloaded;
end;

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

; Optional modules fetched DURING setup (see the [Code] download page). Nothing
; here is bundled in the installer itself — it stays ~16 MB. Anything left
; unchecked can still be downloaded later from inside the app, exactly as
; before; the installer is a convenience, not the only path.
; Piper voices are deliberately NOT offered here.
[Types]
Name: "full";    Description: "Полная (движок + распознавание + шумоподавление)"
Name: "compact"; Description: "Обычная (только голосовой движок)"
Name: "minimal"; Description: "Минимальная (без загрузок)"
Name: "custom";  Description: "Выборочная"; Flags: iscustom

[Components]
Name: "sidecar"; Description: "Голосовой движок (обязателен для голоса), ~110 МБ"; Types: full compact custom
Name: "gigaam";  Description: "Распознавание речи GigaAM-v3 (офлайн, русский), ~230 МБ"; Types: full
Name: "denoise"; Description: "Шумоподавление DeepFilterNet, ~9 МБ"; Types: full

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The Flutter release output (evs.exe + flutter DLLs + data\ + plugin DLLs).
; The Python sidecar (evs_sidecar.exe, ~95 MB) is NOT bundled — it's downloaded
; on demand into the app data folder (see ComponentManager / dist/components.json),
; keeping the installer small.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "evs_sidecar.exe"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Interactive install: offer to launch at the end.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
; Silent in-app update: relaunch the new version automatically (/RELAUNCH=1).
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: ShouldRelaunch
