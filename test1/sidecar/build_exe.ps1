# Freeze the EVS sidecar into a single evs_sidecar.exe and copy it next to the
# built app, where SidecarClient looks for it in release builds.
#
#   cd test1\sidecar
#   .\build_exe.ps1            # -> dist\evs_sidecar.exe, copied to Release
#   .\build_exe.ps1 -Config Debug
#
# Needs Python 3.12 (faster-whisper / ctranslate2 / webrtcvad lack 3.14 wheels).
# Reuses .venv if present; otherwise creates it with uv (preferred) or the
# py launcher. uv-installed 3.12 has no `py -3.12` entry, so uv is tried first.

param([string]$Config = "Release")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$py = Join-Path $here ".venv\Scripts\python.exe"

if (-not (Test-Path $py)) {
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if ($uv) {
    Write-Host "Creating venv (uv, Python 3.12)..."
    uv venv --python 3.12 .venv
  } else {
    Write-Host "Creating venv (py -3.12)..."
    py -3.12 -m venv .venv
  }
}

# Install deps. Prefer uv (fast) into the venv; fall back to the venv's pip.
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
  $env:VIRTUAL_ENV = (Resolve-Path ".venv").Path
  uv pip install -r requirements.txt pyinstaller
} else {
  & $py -m pip install --upgrade pip
  & $py -m pip install -r requirements.txt pyinstaller
}

# --collect-all pulls each library's data files, dynamic libs and hidden
# submodules (PyAV/ctranslate2 DLLs, sounddevice's portaudio, pyttsx3's sapi5
# driver). The Whisper model itself is NOT bundled — faster-whisper downloads it
# on first use into the HF cache.
& $py -m PyInstaller --onefile --noconfirm --name evs_sidecar `
  --collect-all faster_whisper `
  --collect-all ctranslate2 `
  --collect-all onnxruntime `
  --collect-all av `
  --collect-all webrtcvad `
  --collect-all sounddevice `
  --collect-all pyttsx3 `
  --hidden-import comtypes `
  main.py

$dest = Join-Path $here "..\build\windows\x64\runner\$Config"
if (Test-Path $dest) {
  Copy-Item ".\dist\evs_sidecar.exe" $dest -Force
  Write-Host "Copied evs_sidecar.exe -> $dest"
} else {
  Write-Host "Build output '$dest' not found. Build the Flutter app first (flutter build windows --release), then re-run."
}
