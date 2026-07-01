# Freeze the EVS XTTS voice-clone sidecar into evs_tts.exe, then emit its
# sha256 + size into ../../dist/components.json (the 'tts-clone' component).
#
#   cd test1\sidecar\tts_xtts
#   .\build_exe.ps1 -ComponentVersion 1
#
# HEAVY: bundles torch + Coqui TTS. The frozen exe is large (multi-GB) and
# PyInstaller may need extra hidden imports for torch — adjust below if the
# frozen exe fails to import something at runtime. The XTTS model is NOT
# bundled; it downloads on first load into the app data folder (TTS_HOME).

param(
  [string]$ComponentVersion = "1",
  [string]$Url = "https://github.com/kekw2077/mirai/releases/download/desktop-components/evs_tts.exe"
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

# torch + TTS bring large data files and many dynamic libs / hidden submodules.
& $py -m PyInstaller --onefile --noconfirm --name evs_tts `
  --collect-all torch `
  --collect-all TTS `
  --collect-all sounddevice `
  --collect-all soundfile `
  --collect-all transformers `
  --collect-all tokenizers `
  --collect-data trainer `
  --copy-metadata coqui-tts `
  main.py

$exe = Join-Path $here "dist\evs_tts.exe"
if (-not (Test-Path $exe)) { Write-Error "PyInstaller did not produce $exe"; exit 1 }

$sha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $exe).Length
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
  file = "evs_tts.exe"; version = $ComponentVersion; url = $Url; sha256 = $sha; size = $size
}
$manifest.components | Add-Member -NotePropertyName 'tts-clone' -NotePropertyValue $entry -Force
$manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding utf8

Write-Host "evs_tts.exe  sha256=$sha  size=$size"
Write-Host "Updated $manifestPath (tts-clone v$ComponentVersion)."
Write-Host "Next: gh release upload desktop-components dist\evs_tts.exe --clobber ; commit components.json."
