<#
.SYNOPSIS
    WinNet-Toolkit DPI Engine v1.1: Автономный контроллер обхода SNI-блокировок.
#>

$script:CoreDir = "$env:LOCALAPPDATA\WinNet-Toolkit\core"
$script:ListFile = "$script:CoreDir\targets.txt"

function Initialize-DpiCore {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Force -Path $script:CoreDir | Out-Null

    # 1. Генерируем чистый список целевых доменов (Telegram, YouTube, Discord)
    $domains = @(
        "telegram.org", "t.me", "telegram.me", "tdesktop.com", "telegra.ph", "telesco.pe", "cdn-telegram.org",
        "youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "youtu.be", "googleapis.com",
        "discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media"
    )
    Set-Content -Path $script:ListFile -Value ($domains -join "`r`n") -Encoding ASCII

    $needed = @("winws.exe", "WinDivert.dll", "WinDivert64.sys")
    if (Test-Path "$script:CoreDir\winws.exe") {
        return $true
    }

    # 2. Сначала ищем чистое ядро локально на диске C:\ (если уже есть скачанные архивы/папки)
    Write-Host "[1/2] Поиск чистого ядра winws.exe локально на ПК..." -ForegroundColor Cyan
    $localWinws = Get-ChildItem -Path "C:\" -Filter "winws.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($localWinws) {
        $srcFolder = $localWinws.DirectoryName
        foreach ($f in $needed) {
            if (Test-Path "$srcFolder\$f") {
                Copy-Item "$srcFolder\$f" -Destination "$script:CoreDir\$f" -Force
            }
        }
        if (Test-Path "$script:CoreDir\winws.exe") {
            Write-Host "[OK] Чистое ядро скопировано из $srcFolder в изолированную среду!" -ForegroundColor Green
            return $true
        }
    }

    # 3. Если локально нет — скачиваем напрямую с официального GitHub (защита от обрезания URL)
    Write-Host "[2/2] Скачиваем чистое ядро из официального репозитория bol-van/zapret..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "WinNet-Toolkit" }
    $s = [char]47
    $apiUrl = [string]::Format("https:{0}{0}://github.com{0}repos{0}bol-van{0}zapret{0}releases{0}latest", $s)

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*win64.zip" -or $_.name -like "*.zip" } | Select-Object -First 1
        $zipPath = "$env:TEMP\zapret_core.zip"
        $extractPath = "$env:TEMP\zapret_extract"

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        Get-ChildItem -Path $extractPath -Recurse -File | Where-Object { $_.Name -in $needed } | ForEach-Object {
            Copy-Item $_.FullName -Destination "$script:CoreDir\$($_.Name)" -Force
        }
        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Ошибка загрузки ядра: $_"
    }

    return (Test-Path "$script:CoreDir\winws.exe")
}

function Start-DpiEngine {
    [CmdletBinding()]
    param()

    if (-not (Initialize-DpiCore)) {
        Write-Host "[ERROR] Ядро winws.exe не найдено. Запуск отменен." -ForegroundColor Red
        return
    }

    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $argsList = @(
        "--wf-tcp=80,443",
        "--wf-udp=443,50000-65535",
        "--filter-tcp=443",
        "--hostlist=`"$script:ListFile`"",
        "--dpi-desync=split2",
        "--dpi-desync-split-pos=1",
        "--dpi-desync-fooling=badseq",
        "--new",
        "--filter-udp=443",
        "--hostlist=`"$script:ListFile`"",
        "--dpi-desync=fake",
        "--dpi-desync-repeats=6"
    )

    Start-Process -FilePath "$script:CoreDir\winws.exe" -ArgumentList $argsList -WindowStyle Hidden
    Start-Sleep -Seconds 1

    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
        Write-Host "[ACTIVE] Твой собственный DPI-движок запущен в фоне (Telegram + YouTube + Discord)!" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Процесс winws.exe не удержался в памяти (возможно, требуется запуск от имени Администратора или блокирует антивирус)." -ForegroundColor Red
    }
}

function Stop-DpiEngine {
    [CmdletBinding()]
    param()
    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Write-Host "[STOPPED] DPI-движок остановлен." -ForegroundColor Yellow
}
