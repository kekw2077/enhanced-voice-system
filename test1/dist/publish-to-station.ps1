# Выложить обновление EVS на свою станцию вместо GitHub.
#
#     .\dist\publish-to-station.ps1 -Version 2.16.1
#     .\dist\publish-to-station.ps1 -Version 2.16.1 -WithSidecar   # + движок 112 МБ
#
# Кладёт на станцию установщик, канал обновлений и список компонентов, ПЕРЕПИСАВ
# в них ссылки на адрес станции. Без этой перезаписи получилось бы бессмысленное:
# список читается по локальной сети, а файлы по нему всё равно качаются с GitHub.
#
# Подпись установщика не трогается и не пересоздаётся: она считается по самому
# файлу, а не по месту хранения, и переносится вместе с ним.
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Host_ = "npc",                       # имя из ~/.ssh/config
  [string]$BaseUrl = "http://100.79.130.7:8099",# что писать В ФАЙЛАХ
  [string]$Remote = "/home/art/evs-updates/files",
  [switch]$WithSidecar
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host " [x] $m" -ForegroundColor Red; exit 1 }

$setup = Join-Path $here "out\EVS-Setup-$Version.exe"
if (-not (Test-Path $setup)) { Die "Нет установщика: $setup" }
$appcast = Join-Path $here "appcast.xml"
$components = Join-Path $here "components.json"

# --- канал обновлений: ссылки на установщики -> станция ----------------------
Say "готовлю appcast"
$xml = Get-Content $appcast -Raw
$xml = [regex]::Replace(
  $xml,
  'https://github\.com/[^"]*?/releases/download/[^"/]+/(EVS-Setup-[^"]+\.exe)',
  { param($m) "$BaseUrl/$($m.Groups[1].Value)" })
$tmpAppcast = Join-Path $env:TEMP "appcast-station.xml"
Set-Content $tmpAppcast $xml -Encoding UTF8 -NoNewline

# --- список компонентов: ссылка на движок -> станция -------------------------
Say "готовлю список компонентов"
$json = Get-Content $components -Raw
$json = [regex]::Replace(
  $json,
  'https://github\.com/[^"]*?/releases/download/[^"/]+/(evs_sidecar\.zip)',
  { param($m) "$BaseUrl/$($m.Groups[1].Value)" })
$tmpComponents = Join-Path $env:TEMP "components-station.json"
Set-Content $tmpComponents $json -Encoding UTF8 -NoNewline

# --- отправка ----------------------------------------------------------------
Say "отправляю установщик ($([math]::Round((Get-Item $setup).Length/1MB)) МБ)"
scp -q $setup "${Host_}:${Remote}/"
scp -q $tmpAppcast "${Host_}:${Remote}/appcast.xml"
scp -q $tmpComponents "${Host_}:${Remote}/components.json"

if ($WithSidecar) {
  $zip = Join-Path $root "sidecar\dist\evs_sidecar.zip"
  if (-not (Test-Path $zip)) { Die "Нет движка: $zip (соберите build_exe.ps1)" }
  Say "отправляю движок ($([math]::Round((Get-Item $zip).Length/1MB)) МБ) — это надолго"
  scp -q $zip "${Host_}:${Remote}/"
}

# --- проверка, что выложенное действительно отдаётся -------------------------
Say "проверяю"
$ok = $true
foreach ($n in @("appcast.xml", "components.json", "EVS-Setup-$Version.exe")) {
  try {
    $r = Invoke-WebRequest "$BaseUrl/$n" -Method Head -TimeoutSec 20
    "  {0,-28} HTTP {1}  {2} байт" -f $n, $r.StatusCode, (@($r.Headers.'Content-Length')[0])
  } catch { "  {0,-28} НЕ ОТДАЁТСЯ: {1}" -f $n, $_.Exception.Message; $ok = $false }
}
# Ссылки внутри файлов важнее самих файлов: если тут остался github.com, значит
# перезапись не сработала и станция раздаёт указатели в интернет.
$feed = (Invoke-WebRequest "$BaseUrl/appcast.xml" -TimeoutSec 20).Content
if ($feed -match 'github\.com[^"]*EVS-Setup') { "  [x] в appcast остались ссылки на GitHub"; $ok = $false }
else { "  [v] ссылки в appcast ведут на станцию" }

if ($ok) { Say "готово. В EVS: «О приложении» → «Сервер обновлений» -> $BaseUrl" }
else { Die "выложено не полностью" }
