# Установка сервера OrehTV на Windows с Docker Desktop одной командой (PowerShell):
#   irm https://raw.githubusercontent.com/chuck-uz/OrehTV/main/install.ps1 | iex
# Что делает: проверяет Docker Desktop, кладёт файлы в %USERPROFILE%\OrehTV (или $env:TVOREH_DIR), по желанию
# скачивает снимок базы раздач (~2,5 ГБ), запускает контейнеры, печатает адрес и код мастера.
# На Windows автопоиск сервера с телевизора не работает (нет host-сети в Docker Desktop) — адрес вводится в приложении.
$ErrorActionPreference = "Stop"
$Repo = if ($env:OREHTV_REPO) { $env:OREHTV_REPO } else { "chuck-uz/OrehTV" }
$Raw = "https://raw.githubusercontent.com/$Repo/main"
$Dir = if ($env:TVOREH_DIR) { $env:TVOREH_DIR } else { Join-Path $env:USERPROFILE "OrehTV" }
$Files = @("docker-compose.yml", "Caddyfile", ".env.example", "jacred/config/init.yaml")

function Say($t) { Write-Host "`n$t" -ForegroundColor White }
function Die($t) { Write-Host "`nОшибка: $t" -ForegroundColor Red; exit 1 }

Say "OrehTV — установка сервера"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Die "нужен Docker Desktop: https://www.docker.com/products/docker-desktop/ (после установки запустите его и повторите)" }
try { docker info *> $null } catch { Die "Docker Desktop не запущен" }
if ($LASTEXITCODE -ne 0) { Die "Docker Desktop не запущен" }
$mem = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
if ($mem -lt 3500) { Die "нужно не меньше 4 ГБ памяти, сейчас $mem МБ" }
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$free = [math]::Round((Get-PSDrive (Split-Path -Qualifier $Dir).TrimEnd(':')).Free / 1GB)
if ($free -lt 15) { Die "нужно не меньше 15 ГБ свободно на диске $Dir, сейчас $free ГБ" }
$portDefault = 80
if (Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue) { $portDefault = 8080; Write-Host "Порт 80 занят — сервер будет на 8080 (можно поменять в $Dir\.env)." }

Say "Файлы → $Dir"
Set-Location $Dir
foreach ($d in @("data", "secrets", "jacred\config", "jacred\data", "torrserver")) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
foreach ($f in $Files) {
  $dest = Join-Path $Dir ($f -replace "/", "\")
  if (Test-Path $dest) { Copy-Item $dest "$dest.pre-$(Get-Date -Format yyyyMMdd)" -Force }
  Invoke-WebRequest -UseBasicParsing "$Raw/$f" -OutFile $dest
}
if (-not (Test-Path ".env")) {
  $tz = try { (Get-TimeZone).Id } catch { "UTC" }
  @"
# OrehTV — настройки сервера. Пароль админки и ключи задаются в мастере (http://<адрес>/setup) и в админке.
PORT=$portDefault
TZ=UTC
SERVER_NAME=$env:COMPUTERNAME
UPDATES_CHANNEL=release
"@ | Set-Content -Encoding ascii ".env"
}

if (-not (Test-Path "jacred\data\masterDb.bz")) {
  Say "База раздач"
  Write-Host "Без снимка база соберётся сама примерно за сутки (всё это время поиск неполный). Снимок — около 2,5 ГБ."
  $ans = Read-Host "Скачать снимок базы? [Y/n]"
  if ($ans -ne "n" -and $ans -ne "N") {
    $rels = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=30"
    $snap = $rels | Where-Object { $_.tag_name -like "jacred-base-*" } | Select-Object -First 1
    if (-not $snap) { Write-Host "Снимка на витрине пока нет — база соберётся сама." } else {
      $tmp = Join-Path $env:TEMP "orehtv-snapshot"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
      $parts = $snap.assets | Where-Object { $_.name -like "jacred-base.tar.part*" } | Sort-Object name
      $n = 0
      foreach ($a in $parts) { $n++; Write-Host "часть ${n}: $($a.name)"; Invoke-WebRequest -UseBasicParsing $a.browser_download_url -OutFile (Join-Path $tmp $a.name) }
      Say "Распаковка снимка ($($snap.tag_name))"
      $joined = Join-Path $tmp "jacred-base.tar"
      cmd /c "copy /b `"$tmp\jacred-base.tar.part*`" `"$joined`"" | Out-Null
      tar -xf $joined -C "jacred\data"
      Remove-Item -Recurse -Force $tmp
    }
  }
}

$code = -join ((1..6) | ForEach-Object { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[(Get-Random -Maximum 32)] })
[IO.File]::WriteAllText((Join-Path $Dir "data\setup-code"), $code)
Say "Запуск контейнеров (первый раз — скачивание образов, несколько минут)"
docker compose pull -q
docker compose up -d
if ($LASTEXITCODE -ne 0) { Die "контейнеры не запустились — смотрите: docker compose logs" }
$port = (Get-Content .env | Where-Object { $_ -match "^PORT=" }) -replace "PORT=", ""
$ok = $false
for ($i = 0; $i -lt 30 -and -not $ok; $i++) { try { Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/health" *> $null; $ok = $true } catch { Start-Sleep 2 } }
if (-not $ok) { Die "сервер не поднялся — смотрите: docker compose logs api" }

$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)" } | Select-Object -ExpandProperty IPAddress -First 3
$suffix = if ($port -eq "80") { "" } else { ":$port" }
Say "Готово"
Write-Host "Сервер работает. Откройте в браузере мастер первого запуска:"
foreach ($ip in $ips) { Write-Host "    http://$ip$suffix/setup" }
Write-Host "Код мастера:  $code"
Write-Host ""
Write-Host "Потом поставьте приложение на телевизор (APK из https://github.com/$Repo/releases) и введите адрес сервера:"
foreach ($ip in $ips) { Write-Host "    $ip$suffix" }
Write-Host "Ноутбук как сервер: отключите сон при питании от сети, иначе сервер будет пропадать."
