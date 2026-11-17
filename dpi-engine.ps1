<#
.SYNOPSIS
    WinNet-Toolkit DPI Engine v1.2: Автономный контроллер обхода SNI-блокировок.
#>

$script:CoreDir = "$env:LOCALAPPDATA\WinNet-Toolkit\core"
$script:ListFile = "$script:CoreDir\targets.txt"

function Initialize-DpiCore {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Force -Path $script:CoreDir | Out-Null

    # 1. Генерируем чистый список доменов (Telegram, YouTube, Discord)
    $domains = @(
        "telegram.org", "t.me", "telegram.me", "tdesktop.com", "telegra.ph", "telesco.pe", "cdn-telegram.org",
        "youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "youtu.be", "googleapis.com",
        "discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media"
    )
    Set-Content -Path $script:ListFile -Value ($domains -join "`r`n") -Encoding ASCII

    # Проверяем наличие всех бинарников ядра (включая cygwin1.dll)
    if ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll")) {
        return $true
    }

    # 2. Быстрый целевой поиск ядра (без сканирования всего диска C:\)
    $searchPaths = @("C:\zapret", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:LOCALAPPDATA") | Where-Object { Test-Path $_ }
    $localWinws = $searchPaths | ForEach-Object {
        Get-ChildItem -Path $_ -Filter "winws.exe" -Recurse -ErrorAction SilentlyContinue
    } | Select-Object -First 1

    if ($localWinws) {
        $srcFolder = $localWinws.DirectoryName
        # Копируем сам winws.exe, драйвер WinDivert64.sys и все нужные .dll (cygwin1.dll, WinDivert.dll)
        Get-ChildItem -Path $srcFolder -File | Where-Object { $_.Extension -in @(".exe", ".dll", ".sys", ".bin") } | ForEach-Object {
            Copy-Item $_.FullName -Destination "$script:CoreDir\$($_.Name)" -Force
        }
        if ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll")) {
            Write-Host "[OK] Чистое ядро и зависимости скопированы из $srcFolder" -ForegroundColor Green
            return $true
        }
    }

    # 3. Загрузка с официального GitHub (если локально не найдено)
    Write-Host "[INFO] Скачиваем ядро из официального репозитория bol-van/zapret..." -ForegroundColor Cyan
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

        $binDir = (Get-ChildItem -Path $extractPath -Filter "winws.exe" -Recurse | Select-Object -First 1).DirectoryName
        if ($binDir) {
            Get-ChildItem -Path $binDir -File | Where-Object { $_.Extension -in @(".exe", ".dll", ".sys", ".bin") } | ForEach-Object {
                Copy-Item $_.FullName -Destination "$script:CoreDir\$($_.Name)" -Force
            }
        }
        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Ошибка загрузки ядра: $_"
    }

    return ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll"))
}

function Start-DpiEngine {
    [CmdletBinding()]
    param()

    if (-not (Initialize-DpiCore)) {
        Write-Host "[ERROR] Не найдены файлы ядра (winws.exe / cygwin1.dll). Запуск отменен." -ForegroundColor Red
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

    Start-Process -FilePath "$script:CoreDir\winws.exe" -ArgumentList $argsList -WorkingDirectory $script:CoreDir -WindowStyle Hidden
    Start-Sleep -Seconds 1

    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
        Write-Host "[ACTIVE] Твой собственный DPI-движок запущен и работает в фоне (Telegram + YouTube + Discord)!" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Процесс winws.exe завершился при старте." -ForegroundColor Red
    }
}

function Stop-DpiEngine {
    [CmdletBinding()]
    param()
    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Write-Host "[STOPPED] DPI-движок остановлен." -ForegroundColor Yellow
}
