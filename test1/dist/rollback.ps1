# Вернуть EVS на предыдущую версию, не запуская само приложение.
#
#     .\dist\rollback.ps1                  # что вообще доступно на станции
#     .\dist\rollback.ps1 -Version 2.26.0  # поставить её поверх текущей
#
# Нужен там, где кнопка в настройках не поможет: приложение не стартует, окно
# не рисуется, или сломано ровно то место, где эта кнопка живёт. Работает по
# тем же файлам, что и обновление — станция хранит каждый выложенный
# установщик, и старые никуда не деваются.
#
# Каталог установки не угадывается и не спрашивается: его записал Inno в свой
# ключ удаления, оттуда и берётся. Данные (userdata) лежат ВНУТРИ этого
# каталога, а установщик трогает только свои файлы — настройки, диалоги и
# скачанные модели откат переживают.
param(
  [string]$Version,
  [string]$BaseUrl = "http://100.79.130.7:8099",
  [string]$Dir,
  [switch]$All          # показать и те версии, установщиков которых уже нет
)
$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host " [x] $m" -ForegroundColor Red; exit 1 }

# --- куда ставить -----------------------------------------------------------
# AppId из installer.iss; в Inno двойная скобка означает одинарную, а ключ
# удаления — это AppId с суффиксом _is1.
$key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{0DFA2B71-CBB9-43E0-B602-9F6DDC25D839}_is1"
$installed = ""
if (-not $Dir) {
  if (-not (Test-Path $key)) { Die "EVS не установлен для этого пользователя. Укажите -Dir вручную." }
  $p = Get-ItemProperty $key
  $Dir = $p.InstallLocation.TrimEnd([char]92)
  $installed = $p.DisplayVersion
}
if (-not (Test-Path $Dir)) { Die "Нет каталога: $Dir" }
if ($installed) { Say "каталог: $Dir (сейчас стоит $installed)" } else { Say "каталог: $Dir" }

# --- что есть на станции ----------------------------------------------------
Say "читаю канал обновлений"
try {
  $xml = (Invoke-WebRequest "$BaseUrl/appcast.xml" -UseBasicParsing -TimeoutSec 20).Content
} catch {
  Die "Станция недоступна ($BaseUrl): $($_.Exception.Message)"
}
$versions = [regex]::Matches($xml, 'sparkle:version="([^"]+)"') |
  ForEach-Object { $_.Groups[1].Value } |
  Select-Object -Unique |
  Sort-Object { [version]($_.Split([char]43)[0]) } -Descending

# Канал помнит всю историю, а станция хранит файлы лишь с некоторого места:
# старые записи в нём указывают на установщики, которых там уже нет. Список
# файлов берётся из индекса каталога, одним запросом, чтобы не выяснять это
#404-й посреди отката.
$onStation = @()
try {
  $index = (Invoke-WebRequest "$BaseUrl/" -UseBasicParsing -TimeoutSec 20).Content
  $onStation = [regex]::Matches($index, "EVS-Setup-([0-9.]+)[.]exe") |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
} catch {
  Say "индекс станции не читается — проверю наличие файла при скачивании"
}

if (-not $Version) {
  # По умолчанию только то, что реально можно поставить. Канал помнит сотню
  # версий, но это инструмент на плохой день — длинный список в нём мешает.
  Say "доступно (сверху новое):"
  $gone = 0
  foreach ($v in $versions) {
    $here = ($onStation.Count -eq 0) -or ($onStation -contains $v)
    if ($v -eq $installed) { Write-Host "    $v   <- стоит сейчас" -ForegroundColor Yellow }
    elseif ($here) { Write-Host "    $v" }
    elseif ($All) { Write-Host "    $v   (файла на станции нет)" -ForegroundColor DarkGray }
    else { $gone++ }
  }
  if ($gone -gt 0) {
    Write-Host "    ... и ещё $gone в канале, но их установщиков на станции нет (-All покажет)" -ForegroundColor DarkGray
  }
  Write-Host ""
  Write-Host "Запустите снова с -Version <номер>." -ForegroundColor Cyan
  exit 0
}
if ($versions -notcontains $Version) { Die "В канале нет версии $Version" }
if ($Version -eq $installed) { Die "Версия $Version уже установлена" }
if ($onStation.Count -gt 0 -and $onStation -notcontains $Version) {
  Die "Версия $Version есть в канале, но её установщика нет на станции"
}

# --- забрать и проверить ----------------------------------------------------
$setup = Join-Path $env:TEMP "EVS-Setup-$Version.exe"
Say "качаю установщик $Version"
try {
  Invoke-WebRequest "$BaseUrl/EVS-Setup-$Version.exe" -OutFile $setup -UseBasicParsing -TimeoutSec 900
} catch {
  Die "Не скачался EVS-Setup-$Version.exe: $($_.Exception.Message)"
}

# Хеш берётся из той же записи канала. Идти назад — не повод доверять файлу
# меньше, чем при обновлении.
$block = ($xml -split "<item>") |
  Where-Object { $_ -match ("sparkle:version=" + [char]34 + [regex]::Escape($Version) + [char]34) } |
  Select-Object -First 1
$sha = ""
if ($block -and $block -match 'evs:sha256="([0-9a-fA-F]{64})"') { $sha = $Matches[1] }
if ($sha) {
  $got = (Get-FileHash $setup -Algorithm SHA256).Hash
  if ($got -ne $sha.ToUpper()) { Die "Хеш не совпал: канал $($sha.ToUpper()), файл $got" }
  Say "хеш совпал"
} else {
  Say "в канале нет хеша для $Version — ставлю без проверки"
}

# --- закрыть, поставить, поднять --------------------------------------------
# Оба набора имён: если откат делается С переименованной сборки НА старую,
# закрыть нужно новые имена, а поднять — те, что принесёт установщик.
Say "закрываю EVS"
foreach ($n in "evs", "evs_widget", "evs_menu", "evs_sidecar",
               "anima", "anima_widget", "anima_menu", "anima_sidecar") {
  Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

Say "ставлю $Version в $Dir"
$pr = Start-Process $setup -Wait -PassThru -ArgumentList @(
  "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/DIR=$Dir")
if ($pr.ExitCode -ne 0) { Die "Установщик вернул код $($pr.ExitCode)" }

$exe = Join-Path $Dir "evs.exe"
if (-not (Test-Path $exe)) { $exe = Join-Path $Dir "anima.exe" }
if (Test-Path $exe) {
  Say "готово, запускаю $Version"
  Start-Process $exe
} else {
  Say "готово, но exe в $Dir не найден — запустите вручную"
}
