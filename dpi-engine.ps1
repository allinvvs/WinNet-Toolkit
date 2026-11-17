<#
.SYNOPSIS
    WinNet-Toolkit DPI Engine: Собственный контроллер обхода SNI-блокировок на базе официального ядра bol-van/zapret.
.DESCRIPTION
    Загружает только чистые бинарные файлы ядра (winws.exe + WinDivert) из официального репозитория,
    формирует собственный список доменов для Telegram, YouTube и Discord и управляет службой десинхронизации.
#>

$script:CoreDir = "$env:LOCALAPPDATA\WinNet-Toolkit\core"
$script:ListFile = "$script:CoreDir\targets.txt"

function Initialize-DpiCore {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Force -Path $script:CoreDir | Out-Null

    # 1. Формируем собственный чистый список доменов для 3 сервисов
    $domains = @(
        "telegram.org", "t.me", "telegram.me", "tdesktop.com", "telegra.ph", "telesco.pe", "cdn-telegram.org",
        "youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "youtu.be", "googleapis.com",
        "discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media"
    )
    Set-Content -Path $script:ListFile -Value ($domains -join "`r`n") -Encoding ASCII

    # 2. Проверяем наличие чистого ядра winws.exe
    if (-not (Test-Path "$script:CoreDir\winws.exe")) {
        Write-Host "[1/2] Скачиваем чистое ядро из официального репозитория bol-van/zapret..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ "User-Agent" = "WinNet-Toolkit" }
        $release = Invoke-RestMethod -Uri "https://github.com" -Headers $headers
        $asset = $release.assets | Where-Object { $_.name -like "*win64.zip" -or $_.name -like "*.zip" } | Select-Object -First 1

        if (-not $asset) {
            Write-Warning "Не удалось получить ссылку через GitHub API. Скачайте релиз с ://github.com вручную в $script:CoreDir"
            return
        }

        $zipPath = "$env:TEMP\zapret_core.zip"
        $extractPath = "$env:TEMP\zapret_extract"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # Извлекаем только 3 нужных системных файла ядра без чужих батников
        $needed = @("winws.exe", "WinDivert.dll", "WinDivert64.sys")
        Get-ChildItem -Path $extractPath -Recurse -File | Where-Object { $_.Name -in $needed } | ForEach-Object {
            Copy-Item $_.FullName -Destination "$script:CoreDir\$($_.Name)" -Force
        }

        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[2/2] Чистое ядро winws.exe установлено в $script:CoreDir" -ForegroundColor Green
    } else {
        Write-Host "[OK] Ядро winws.exe и список доменов готовы." -ForegroundColor Green
    }
}

function Start-DpiEngine {
    [CmdletBinding()]
    param()

    if (-not (Test-Path "$script:CoreDir\winws.exe")) {
        Initialize-DpiCore
    }

    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Собственная стратегия десинхронизации TLS (разделение SNI-пакета и маскировка)
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
    Write-Host "[ACTIVE] Твой собственный DPI-движок запущен в фоне (Telegram + YouTube + Discord)!" -ForegroundColor Green
}

function Stop-DpiEngine {
    [CmdletBinding()]
    param()
    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Write-Host "[STOPPED] DPI-движок остановлен." -ForegroundColor Yellow
}
