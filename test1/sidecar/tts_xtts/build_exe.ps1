# Freeze the EVS XTTS voice-clone sidecar into a ONEDIR bundle, zip it, and emit
# its sha256 + size into ../../dist/components.json (the 'tts-clone' archive
# component). Onedir (not onefile) so torch doesn't re-extract ~2.5 GB on every
# launch — the app downloads the zip once and extracts it (ComponentManager).
#
#   cd test1\sidecar\tts_xtts
#   .\build_exe.ps1 -ComponentVersion 1
#
# HEAVY: bundles torch + Coqui TTS (~2.5 GB). The XTTS model is NOT bundled; it
# downloads on first load into the app data folder (TTS_HOME).

param(
  [string]$ComponentVersion = "1",
  [string]$Url = "https://github.com/kekw2077/mirai/releases/download/desktop-components/evs_tts.zip"
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$py = Join-Path $here ".venv\Scripts\python.exe"

if (-not (Test-Path $py)) {
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if ($uv) { uv venv --python 3.12 .venv } else { py -3.12 -m venv .venv }
}

$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
  $env:VIRTUAL_ENV = (Resolve-Path ".venv").Path
  uv pip install -r requirements.txt pyinstaller
} else {
  & $py -m pip install -r requirements.txt pyinstaller
}

# --onedir: a folder (evs_tts.exe + _internal\). --collect-all pulls torch/TTS
# data files and dynamic libs.
& $py -m PyInstaller --onedir --noconfirm --name evs_tts `
  --collect-all torch `
  --collect-all TTS `
  --collect-all sounddevice `
  --collect-all soundfile `
  --collect-all transformers `
  --collect-all tokenizers `
  --collect-all ko_speech_tools `
  --collect-all num2words `
  --collect-data trainer `
  --copy-metadata coqui-tts `
  --copy-metadata torch `
  --copy-metadata torchaudio `
  --copy-metadata transformers `
  --copy-metadata tokenizers `
  --copy-metadata numpy `
  --copy-metadata tqdm `
  --copy-metadata regex `
  --copy-metadata requests `
  --copy-metadata packaging `
  --copy-metadata filelock `
  --copy-metadata pyyaml `
  --copy-metadata huggingface-hub `
  --copy-metadata safetensors `
  main.py

$distDir = Join-Path $here "dist\evs_tts"
$exe = Join-Path $distDir "evs_tts.exe"
if (-not (Test-Path $exe)) { Write-Error "PyInstaller did not produce $exe"; exit 1 }

# Zip the CONTENTS of dist\evs_tts\ (so the zip root has evs_tts.exe + _internal).
# Use tar.exe (bsdtar, ships with Windows 10+) — Compress-Archive struggles >2 GB.
$zip = Join-Path $here "dist\evs_tts.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Push-Location $distDir
tar.exe -a -c -f $zip *
Pop-Location
if (-not (Test-Path $zip)) { Write-Error "zip not produced"; exit 1 }

$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $zip).Length
$manifestPath = Join-Path $here "..\..\dist\components.json"
if (Test-Path $manifestPath) {
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
} else {
  $manifest = [pscustomobject]@{ components = [pscustomobject]@{} }
}
if (-not $manifest.components) {
  $manifest | Add-Member -NotePropertyName components -NotePropertyValue ([pscustomobject]@{}) -Force
}
$entry = [pscustomobject]@{
  file = "evs_tts.zip"; exe = "evs_tts.exe"; archive = $true
  version = $ComponentVersion; url = $Url; sha256 = $sha; size = $size
}
$manifest.components | Add-Member -NotePropertyName 'tts-clone' -NotePropertyValue $entry -Force
$manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding utf8

Write-Host "evs_tts.zip  sha256=$sha  size=$size"
Write-Host "Updated $manifestPath (tts-clone v$ComponentVersion, archive)."
Write-Host "Next: gh release upload desktop-components dist\evs_tts.zip --clobber ; commit components.json."
