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
; Allow a non-admin per-user install too (WinSparkle relaunches the installer
; in the same context the app runs as).
PrivilegesRequiredOverridesAllowed=dialog
; --- WinSparkle silent-update support ---
; WinSparkle launches the downloaded installer with these flags, so the update
; runs without prompting and relaunches EVS afterwards.
[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The entire Flutter release output (evs.exe + flutter DLLs + data\ + plugin DLLs).
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Relaunch EVS after install/update. /SILENT updates won't show this checkbox,
; but WinSparkle passes the flag so the app restarts.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
