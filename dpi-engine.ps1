<#
.SYNOPSIS
    WinNet-Toolkit DPI Engine v3.2: Автономный контроллер обхода SNI-блокировок
    с верификацией SHA256, централизованным логированием, откатом (Rollback) и автозапуском.
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseDir   = "$env:ProgramData\WinNet-Toolkit"
$script:CoreDir   = "$script:BaseDir\core"
$script:BackupDir = "$script:BaseDir\backup"
$script:ConfigDir = "$script:BaseDir\configs"
$script:LogFile   = "$script:BaseDir\winnet.log"
$script:ListFile  = "$script:CoreDir\targets.txt"

function Write-WinNetLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $logDir = Split-Path -Path $script:LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

    # Ротация лога при достижении 5 МБ
    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 5MB)) {
        Move-Item -Path $script:LogFile -Destination "$script:LogFile.old" -Force
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $script:LogFile -Value "[$timestamp] [$Level] $Message" -Encoding UTF8
}

function Backup-NetworkState {
    [CmdletBinding()]
    param()
    New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
    $backupFile = Join-Path $script:BackupDir "network-backup.json"

    # Идемпотентность: сохраняем только исходное состояние, не перезаписывая существующий снимок
    if (Test-Path $backupFile) {
        Write-WinNetLog "Резервная копия сетевых параметров уже существует." "INFO"
        return
    }

    $activeAdapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } | Select-Object -First 1
    $dnsServers = @()
    if ($activeAdapter) {
        $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $activeAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dnsInfo) { $dnsServers = @($dnsInfo.ServerAddresses) }
    }

    $state = @{
        Timestamp     = (Get-Date).ToString('o')
        InterfaceName = if ($activeAdapter) { $activeAdapter.Name } else { $null }
        DnsServers    = $dnsServers
        ChromeQuic    = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "QuicAllowed" -ErrorAction SilentlyContinue).QuicAllowed
        EdgeQuic      = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "QuicAllowed" -ErrorAction SilentlyContinue).QuicAllowed
        YandexQuic    = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\YandexBrowser" -Name "QuicAllowed" -ErrorAction SilentlyContinue).QuicAllowed
    }

    $state | ConvertTo-Json -Depth 3 | Set-Content -Path $backupFile -Encoding UTF8
    Write-WinNetLog "Исходные сетевые настройки сохранены в $backupFile." "OK"
}

function Restore-NetworkState {
    [CmdletBinding()]
    param()
    $backupFile = Join-Path $script:BackupDir "network-backup.json"
    if (-not (Test-Path $backupFile)) {
        Write-Host "[WARN] Резервная копия не найдена. Сброс DNS на автоматический режим (DHCP)." -ForegroundColor Yellow
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } | Select-Object -First 1
        if ($adapter) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses }
    } else {
        $state = Get-Content -Path $backupFile -Raw | ConvertFrom-Json
        if ($state.InterfaceName) {
            if ($state.DnsServers -and $state.DnsServers.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceAlias $state.InterfaceName -ServerAddresses $state.DnsServers
            } else {
                Set-DnsClientServerAddress -InterfaceAlias $state.InterfaceName -ResetServerAddresses
            }
        }
    }

    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "QuicAllowed" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "QuicAllowed" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\YandexBrowser" -Name "QuicAllowed" -ErrorAction SilentlyContinue
    Clear-DnsClientCache

    Write-WinNetLog "Исходные параметры DNS и политик QUIC восстановлены." "OK"
    Write-Host "[OK] Исходные сетевые параметры и политики браузеров восстановлены." -ForegroundColor Green
}

function Set-CleanDNS {
    [CmdletBinding()]
    param()
    Backup-NetworkState
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } | Select-Object -First 1
    if (-not $adapter) {
        Write-Host "[ERROR] Активный физический сетевой адаптер не обнаружен." -ForegroundColor Red
        Write-WinNetLog "Сбой Set-CleanDNS: активный адаптер не найден." "ERROR"
        return
    }

    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888")
    Clear-DnsClientCache
    Write-WinNetLog "Публичные DNS (IPv4 + IPv6) применены для адаптера $($adapter.Name)." "OK"
    Write-Host "[OK] Публичные DNS (IPv4 + IPv6) установлены для интерфейса: $($adapter.Name)" -ForegroundColor Green
}

function Optimize-YouTubeStream {
    [CmdletBinding()]
    param()
    Backup-NetworkState
    $regPaths = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
        "HKLM:\SOFTWARE\Policies\YandexBrowser"
    )

    foreach ($path in $regPaths) {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "QuicAllowed" -Value 0 -Type DWord
    }

    Write-WinNetLog "Политика QuicAllowed=0 применена для Chromium-браузеров." "OK"
    Write-Host "[OK] Политика QuicAllowed=0 применена. Перезапустите браузер для вступления в силу." -ForegroundColor Green
}

function Initialize-DpiCore {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Force -Path $script:CoreDir | Out-Null

    # 1. Формирование актуального списка целевых доменов (Telegram, YouTube, Discord)
    $domains = @(
        "telegram.org", "t.me", "telegram.me", "tdesktop.com", "telegra.ph", "telesco.pe", "cdn-telegram.org",
        "youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "youtu.be", "googleapis.com",
        "discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media"
    )
    Set-Content -Path $script:ListFile -Value ($domains -join "`r`n") -Encoding ASCII

    if ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll")) {
        return $true
    }

    # 2. Целевой локальный поиск бинарников ядра
    $searchPaths = @("C:\zapret", "D:\zapret", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:LOCALAPPDATA\WinNet-Toolkit\core") | Where-Object { Test-Path $_ }
    $localWinws = $searchPaths | ForEach-Object {
        Get-ChildItem -Path $_ -Filter "winws.exe" -Recurse -ErrorAction SilentlyContinue
    } | Select-Object -First 1

    if ($localWinws) {
        $srcFolder = $localWinws.DirectoryName
        Get-ChildItem -Path $srcFolder -File | Where-Object { $_.Extension -in @(".exe", ".dll", ".sys", ".bin") } | ForEach-Object {
            Copy-Item $_.FullName -Destination "$script:CoreDir\$($_.Name)" -Force
        }
        if ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll")) {
            Write-WinNetLog "Бинарные файлы ядра скопированы из $srcFolder." "OK"
            Write-Host "[OK] Ядро и зависимости скопированы из $srcFolder" -ForegroundColor Green
            return $true
        }
    }

    # 3. Загрузка из официального репозитория GitHub с верификацией SHA256
    Write-Host "[INFO] Загрузка ядра из официального репозитория bol-van/zapret..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "WinNet-Toolkit/3.2" }
    $apiUrl = "https://github.com"

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*win64.zip" -or $_.name -like "*.zip" } | Select-Object -First 1
        $shaAsset = $release.assets | Where-Object { $_.name -like "*sha256*" } | Select-Object -First 1

        if (-not $asset) { throw "Установочный архив не найден в последнем релизе." }

        $zipPath = "$env:TEMP\zapret_core.zip"
        $extractPath = "$env:TEMP\zapret_extract"

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -TimeoutSec 30 -UseBasicParsing

        # Верификация SHA256 контрольной суммы
        if ($shaAsset) {
            $shaContent = Invoke-RestMethod -Uri $shaAsset.browser_download_url -Headers $headers -TimeoutSec 10
            $expectedLine = ($shaContent -split "`n") | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
            if ($expectedLine -match '([a-fA-F0-9]{64})') {
                $expectedHash = $matches.ToUpperInvariant()
                $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($actualHash -ne $expectedHash) {
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Write-WinNetLog "SECURITY ALERT: Несовпадение SHA256 для $($asset.name)." "ERROR"
                    throw "Нарушена целостность архива (SHA256 mismatch)."
                }
                Write-WinNetLog "SHA256 верификация ядра пройдена: $actualHash" "OK"
            }
        }

        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $binDir = (Get-ChildItem -Path $extractPath -Filter "winws.exe" -Recurse | Select-Object -First 1).DirectoryName
        if ($binDir) {
            Get-ChildItem -Path $binDir -File | Where-Object { $_.Extension -in @(".exe", ".dll", ".sys", ".bin") } | ForEach-Object {
                Copy-Item $_.FullName -Destination "$script:CoreDir\$($_.Name)" -Force
            }
        }
        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-WinNetLog "Ошибка загрузки ядра: $($_.Exception.Message)" "ERROR"
        Write-Warning "Ошибка загрузки ядра: $($_.Exception.Message)"
    }

    return ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll"))
}

function Start-DpiEngine {
    [CmdletBinding()]
    param()

    if (-not (Initialize-DpiCore)) {
        Write-Host "[ERROR] Не найдены файлы ядра (winws.exe / cygwin1.dll). Запуск отменен." -ForegroundColor Red
        Write-WinNetLog "Запуск DPI-движка отменен: отсутствуют бинарные файлы." "ERROR"
        return $false
    }

    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    $argsList = @(
        "--wf-tcp=80,443",
        "--wf-udp=443,50000-65535",
        "--filter-tcp=443",
        "--hostlist=`"$script:ListFile`"",
        "--dpi-desync=fake,multisplit",
        "--dpi-desync-split-pos=1,midsld",
        "--dpi-desync-split-seqovl=1",
        "--dpi-desync-fooling=badseq,md5sig",
        "--dpi-desync-repeats=6",
        "--new",
        "--filter-udp=443",
        "--hostlist=`"$script:ListFile`"",
        "--dpi-desync=fake",
        "--dpi-desync-repeats=6",
        "--new",
        "--filter-udp=50000-65535",
        "--filter-l7=discord,stun",
        "--dpi-desync=fake",
        "--dpi-desync-repeats=6"
    )

    Start-Process -FilePath "$script:CoreDir\winws.exe" -ArgumentList $argsList -WorkingDirectory $script:CoreDir -WindowStyle Hidden
    Start-Sleep -Seconds 1

    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
        Write-WinNetLog "DPI-движок (winws.exe) успешно запущен." "OK"
        Write-Host "[ACTIVE] Ядро активно и работает в фоне (Telegram, YouTube, Discord)." -ForegroundColor Green
        return $true
    } else {
        Write-WinNetLog "Процесс winws.exe аварийно завершился при старте." "ERROR"
        Write-Host "[ERROR] Процесс winws.exe завершился при старте." -ForegroundColor Red
        return $false
    }
}

function Stop-DpiEngine {
    [CmdletBinding()]
    param()
    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Write-WinNetLog "DPI-движок остановлен пользователем." "INFO"
    Write-Host "[STOPPED] Ядро остановлено." -ForegroundColor Yellow
}

function Register-WinNetAutoStart {
    [CmdletBinding()]
    param()
    $taskName = "WinNet-Toolkit-Watchdog"
    $scriptPath = "$script:BaseDir\watchdog.ps1"

    if (-not (Test-Path $scriptPath)) {
        Write-Host "[ERROR] Модуль watchdog.ps1 не найден по пути $scriptPath." -ForegroundColor Red
        return
    }

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Write-WinNetLog "Задача автозапуска '$taskName' зарегистрирована и запущена." "OK"
    Write-Host "[OK] Автозапуск и фоновый мониторинг включены." -ForegroundColor Green
}

function Unregister-WinNetAutoStart {
    [CmdletBinding()]
    param()
    Unregister-ScheduledTask -TaskName "WinNet-Toolkit-Watchdog" -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
    Write-WinNetLog "Задача автозапуска удалена, фоновый мониторинг отключен." "INFO"
    Write-Host "[OK] Автозапуск отключен, фоновые процессы остановлены." -ForegroundColor Yellow
}
