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
  [switch]$WithSidecar,
  [int]$Keep = 2                                # сколько установщиков хранить
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host " [x] $m" -ForegroundColor Red; exit 1 }

# Имя установщика сменилось вместе с именем программы; старое остаётся
# рабочим, потому что на станции лежат релизы обоих поколений.
$setup = @("NexusAnima-Setup-$Version.exe", "EVS-Setup-$Version.exe") |
  ForEach-Object { Join-Path $here "out\$_" } |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $setup) { Die "Нет установщика для $Version в $here\out" }
$setupName = Split-Path $setup -Leaf
$appcast = Join-Path $here "appcast.xml"
$components = Join-Path $here "components.json"

# --- канал обновлений: ссылки на установщики -> станция ----------------------
Say "готовлю appcast"
$xml = Get-Content $appcast -Raw
$xml = [regex]::Replace(
  $xml,
  'https://github[.]com/[^"]*?/releases/download/[^"/]+/((?:NexusAnima|EVS)-Setup-[^"]+[.]exe)',
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
foreach ($n in @("appcast.xml", "components.json", $setupName)) {
  try {
    $r = Invoke-WebRequest "$BaseUrl/$n" -Method Head -TimeoutSec 20
    "  {0,-28} HTTP {1}  {2} байт" -f $n, $r.StatusCode, (@($r.Headers.'Content-Length')[0])
  } catch { "  {0,-28} НЕ ОТДАЁТСЯ: {1}" -f $n, $_.Exception.Message; $ok = $false }
}
# Ссылки внутри файлов важнее самих файлов: если тут остался github.com, значит
# перезапись не сработала и станция раздаёт указатели в интернет.
$feed = (Invoke-WebRequest "$BaseUrl/appcast.xml" -TimeoutSec 20).Content
if ($feed -match 'github[.]com[^"]*-Setup-') { "  [x] в appcast остались ссылки на GitHub"; $ok = $false }
else { "  [v] ссылки в appcast ведут на станцию" }

if (-not $ok) { Die "выложено не полностью" }

# --- чистка ------------------------------------------------------------------
# Каталог растёт на установщик за релиз и за полгода набирает под гигабайт.
# Хранить нужно ровно столько, сколько требуется откату: текущую версию и ту,
# на которую он уводит. Ниже двух опускаться нельзя — откатываться станет не на
# что, ни кнопкой в настройках, ни через rollback.ps1.
#
# Чистка идёт ПОСЛЕ проверки: пока не подтвердилось, что новое действительно
# отдаётся, старое трогать нельзя. Удаляются только файлы строгого вида
# <имя>-Setup-<версия>.exe — appcast.xml, components.json и движок под шаблон не
# попадают ни при каких условиях.
if ($Keep -lt 2) { $Keep = 2 }
$files = @(ssh $Host_ "ls -1 $Remote | grep -E '^(NexusAnima|EVS)-Setup-[0-9.]+[.]exe$'") |
  Where-Object { $_ }
if ($files.Count -gt $Keep) {
  $sorted = $files | Sort-Object {
    [version](($_ -replace '^(NexusAnima|EVS)-Setup-', '') -replace '[.]exe$', '')
  } -Descending
  $doomed = @($sorted | Select-Object -Skip $Keep)
  Say "чищу станцию: оставляю $Keep, удаляю $($doomed.Count)"
  foreach ($f in $doomed) { Write-Host "    $f" -ForegroundColor DarkGray }
  $list = ($doomed | ForEach-Object { "'$Remote/$_'" }) -join ' '
  ssh $Host_ "rm -f $list"
  Say "оставлены: $(($sorted | Select-Object -First $Keep) -join ', ')"
}

Say "готово. В EVS: «О приложении» → «Сервер обновлений» -> $BaseUrl"
