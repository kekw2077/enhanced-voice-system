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
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=out
OutputBaseFilename=EVS-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
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

[Code]
// The in-app updater (AppUpdater.applyAndRestart) launches this installer with
// /VERYSILENT ... /RELAUNCH=1 and exits; this relaunches the new version after
// the silent install so the update feels like a plain restart (Discord-style).
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The Flutter release output (evs.exe + flutter DLLs + data\ + plugin DLLs).
; The Python sidecar (evs_sidecar.exe, ~95 MB) and the XTTS voice-clone engine
; are NOT bundled — they're downloaded on demand into the app data folder (see
; ComponentManager / dist/components.json), keeping the installer small.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "evs_sidecar.exe,evs_tts.exe"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Interactive install: offer to launch at the end.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
; Silent in-app update: relaunch the new version automatically (/RELAUNCH=1).
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: ShouldRelaunch
