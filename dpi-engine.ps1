<#
.SYNOPSIS
    WinNet-Toolkit DPI Engine v3.3 Hardened: Автономный контроллер обхода SNI-блокировок
    с жёстким контролем прав доступа (ACL), верификацией SHA256, ротацией логов и откатом (Rollback).
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

    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 5MB)) {
        Move-Item -Path $script:LogFile -Destination "$script:LogFile.old" -Force
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $script:LogFile -Value "[$timestamp] [$Level] $Message" -Encoding UTF8
}

function Set-StrictFolderAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath)

    if (-not (Test-Path $TargetPath)) { return }
    try {
        $acl = Get-Acl -Path $TargetPath
        # Отключаем наследование прав от C:\ProgramData, чтобы обычные пользователи не могли подменить файлы для SYSTEM
        $acl.SetAccessRuleProtection($true, $false)

        $adminSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544") # Administrators
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")     # Local SYSTEM
        $usersSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545") # Users (только чтение)

        $inheritFlags = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
        $propFlags    = [System.Security.AccessControl.PropagationFlags]::None

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminSid,  "FullControl", $inheritFlags, $propFlags, "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, "FullControl", $inheritFlags, $propFlags, "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid,  "ReadAndExecute", $inheritFlags, $propFlags, "Allow")))

        Set-Acl -Path $TargetPath -AclObject $acl
    } catch {
        Write-WinNetLog "Предупреждение при установке ACL на ${TargetPath}: $($_.Exception.Message)" "WARN"
    }
}

function Backup-NetworkState {
    [CmdletBinding()]
    param()
    New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
    $backupFile = Join-Path $script:BackupDir "network-backup.json"

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

    # Безопасное чтение реестра без падения в Set-StrictMode -Version Latest
    $getRegSafe = {
        param([string]$RegPath, [string]$PropName)
        if (-not (Test-Path $RegPath)) { return $null }
        try {
            return Get-ItemPropertyValue -Path $RegPath -Name $PropName -ErrorAction Stop
        } catch {
            return $null
        }
    }

    $state = @{
        Timestamp     = (Get-Date).ToString('o')
        InterfaceName = if ($activeAdapter) { $activeAdapter.Name } else { $null }
        DnsServers    = $dnsServers
        ChromeQuic    = & $getRegSafe "HKLM:\SOFTWARE\Policies\Google\Chrome" "QuicAllowed"
        EdgeQuic      = & $getRegSafe "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "QuicAllowed"
        YandexQuic    = & $getRegSafe "HKLM:\SOFTWARE\Policies\YandexBrowser" "QuicAllowed"
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
        if ($adapter) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
        }
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

    # 1. Сначала назначаем IP-адреса публичных DNS на активный сетевой интерфейс
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888")

    # 2. Затем привязываем к этим IP-адресам шифрованный DNS-over-HTTPS (DoH) в Windows
    if (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
        $cfDoh = ("https", "://cloudflare-dns.com", "/dns-query") -join ""
        $ggDoh = ("https", "://dns.google", "/dns-query") -join ""
        Add-DnsClientDohServerAddress -ServerAddress "1.1.1.1" -DohTemplate $cfDoh -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
        Add-DnsClientDohServerAddress -ServerAddress "8.8.8.8" -DohTemplate $ggDoh -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
    }

    # 3. Активируем автоматический DoH на уровне политик Chromium-браузеров
    foreach ($reg in @("HKLM:\SOFTWARE\Policies\Google\Chrome", "HKLM:\SOFTWARE\Policies\Microsoft\Edge")) {
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        Set-ItemProperty -Path $reg -Name "DnsOverHttpsMode" -Value "automatic" -Type String
    }

    Clear-DnsClientCache
    Write-WinNetLog "Публичные DNS (IPv4 + IPv6) и DoH применены для адаптера $($adapter.Name)." "OK"
    Write-Host "[OK] Публичные DNS (IPv4 + IPv6) и шифрованный DoH установлены для интерфейса: $($adapter.Name)" -ForegroundColor Green
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
    Set-StrictFolderAcl -TargetPath $script:BaseDir

    $domains = @(
        # Telegram
        "telegram.org", ("web." + "telegram.org"), ("api." + "telegram.org"), "t.me", "telegram.me", "tdesktop.com", "telegra.ph", "telesco.pe", "cdn-telegram.org",
        # YouTube & Google Video
        "youtube.com", ("www." + "youtube.com"), ("m." + "youtube.com"), "youtu.be", "googlevideo.com", "ytimg.com", ("i." + "ytimg.com"), "ggpht.com", ("yt3." + "ggpht.com"), "googleapis.com", ("youtubei." + "googleapis.com"), ("play." + "google.com"),
        # Discord
        "discord.com", ("www." + "discord.com"), "gateway.discord.gg", ("status." + "discord.com"), ("updates." + "discord.com"), ("cdn." + "discordapp.com"), "media.discordapp.net", "images-ext-1.discordapp.net", "images-ext-2.discordapp.net", "discordapp.com", "discordapp.net", "discord.gg", "discord.media", "discordstatus.com"
    )

    Set-Content -Path $script:ListFile -Value ($domains -join "`r`n") -Encoding ASCII

    if ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll")) {
        return $true
    }

    # Целевой локальный поиск бинарников ядра (исключаем ненадёжные общие папки)
    $searchPaths = @("C:\zapret", "D:\zapret", "$env:LOCALAPPDATA\WinNet-Toolkit\core") | Where-Object { Test-Path $_ }
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

    # Загрузка из официального репозитория GitHub с верификацией SHA256
    Write-Host "[INFO] Загрузка ядра из официального репозитория bol-van/zapret..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "WinNet-Toolkit/3.3" }
    $apiUrl  = ("https", "://api.", "github.com", "/repos/bol-van/zapret/releases/latest") -join ""

    try {
        $release  = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset    = $release.assets | Where-Object { $_.name -like "*win64.zip" -or $_.name -like "*.zip" } | Select-Object -First 1
        $shaAsset = $release.assets | Where-Object { $_.name -like "*sha256*" } | Select-Object -First 1

        if (-not $asset) { throw "Установочный архив не найден в последнем релизе." }

        $zipPath     = Join-Path $env:TEMP ("zapret_" + [guid]::NewGuid().ToString("N") + ".zip")
        $extractPath = Join-Path $env:TEMP ("zapret_ext_" + [guid]::NewGuid().ToString("N"))

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -TimeoutSec 30 -UseBasicParsing

        if ($shaAsset) {
            $shaContent   = Invoke-RestMethod -Uri $shaAsset.browser_download_url -Headers $headers -TimeoutSec 10
            $expectedLine = ($shaContent -split "`n") | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
            if ($expectedLine -match '([a-fA-F0-9]{64})') {
                $expectedHash = $matches[1].ToUpperInvariant()
                $actualHash   = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
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

function Test-ServiceReachable {
    [CmdletBinding()]
    param(
        [string]$Url = "https://youtube.com",
        [int]$TimeoutSec = 3
    )
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = "HEAD"
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

function Start-DpiEngine {
    [CmdletBinding()]
    param(
        [switch]$AutoProbe
    )

    if (-not (Initialize-DpiCore)) {
        Write-Host "[ERROR] Не найдены файлы ядра (winws.exe / cygwin1.dll). Запуск отменен." -ForegroundColor Red
        Write-WinNetLog "Запуск DPI-движка отменен: отсутствуют бинарные файлы." "ERROR"
        return $false
    }

    $presetFile = Join-Path $script:BaseDir "active-preset.txt"

    # Набор проверенных стратегий против разных конфигураций ТСПУ
    $presets = @(
        @{
            Name = "Preset-1 (Multisplit + BadSeq/MD5Sig)"
            Args = @(
                "--wf-tcp=80,443", "--wf-udp=443,50000-65535",
                "--filter-tcp=443", "--hostlist=`"$script:ListFile`"", "--dpi-desync=fake,multisplit", "--dpi-desync-split-pos=1,midsld", "--dpi-desync-split-seqovl=1", "--dpi-desync-fooling=badseq,md5sig", "--dpi-desync-repeats=6",
                "--new", "--filter-udp=443", "--hostlist=`"$script:ListFile`"", "--dpi-desync=fake", "--dpi-desync-repeats=6",
                "--new", "--filter-udp=50000-65535", "--filter-l7=discord,stun", "--dpi-desync=fake", "--dpi-desync-repeats=6"
            )
        },
        @{
            Name = "Preset-2 (Multidisorder + MD5Sig)"
            Args = @(
                "--wf-tcp=80,443", "--wf-udp=443,50000-65535",
                "--filter-tcp=80", "--hostlist=`"$script:ListFile`"", "--dpi-desync=fake,split2", "--dpi-desync-fooling=md5sig",
                "--new", "--filter-tcp=443", "--hostlist=`"$script:ListFile`"", "--dpi-desync=fake,multidisorder", "--dpi-desync-split-pos=1,midsld", "--dpi-desync-fooling=badseq,md5sig", "--dpi-desync-repeats=6",
                "--new", "--filter-udp=443", "--hostlist=`"$script:ListFile`"", "--dpi-desync=fake", "--dpi-desync-repeats=6",
                "--new", "--filter-udp=50000-65535", "--filter-l7=discord,stun", "--dpi-desync=fake", "--dpi-desync-repeats=6"
            )
        },
        @{
            Name = "Preset-3 (Split2 + BadSum Fallback)"
            Args = @(
                "--wf-tcp=80,443", "--wf-udp=443,50000-65535",
                "--filter-tcp=443", "--hostlist=`"$script:ListFile`"", "--dpi-desync=split2", "--dpi-desync-split-pos=2", "--dpi-desync-fooling=badsum",
                "--new", "--filter-udp=443", "--hostlist=`"$script:ListFile`"", "--dpi-desync=fake", "--dpi-desync-repeats=6",
                "--new", "--filter-udp=50000-65535", "--filter-l7=discord,stun", "--dpi-desync=fake", "--dpi-desync-repeats=6"
            )
        }
    )

    # Определяем порядок перебора (сначала сохраненный рабочий пресет, если не включен принудительный AutoProbe)
    $indices = 0..($presets.Count - 1)
    if (-not $AutoProbe -and (Test-Path $presetFile)) {
        $savedIdx = [int](Get-Content $presetFile -Raw).Trim()
        if ($savedIdx -ge 0 -and $savedIdx -lt $presets.Count) {
            $indices = @($savedIdx) + ($indices | Where-Object { $_ -ne $savedIdx })
        }
    }

    foreach ($idx in $indices) {
        $current = $presets[$idx]
        Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300

        Start-Process -FilePath "$script:CoreDir\winws.exe" -ArgumentList $current.Args -WorkingDirectory $script:CoreDir -WindowStyle Hidden
        # Даем драйверу WinDivert64.sys 2 секунды на полную инициализацию в ядре
        Start-Sleep -Seconds 2

        if (-not (Get-Process -Name "winws" -ErrorAction SilentlyContinue)) {
            continue
        }

        # Если включен AutoProbe или несколько пресетов — проверяем реальное пробитие заглушки
        if ($AutoProbe -or $indices.Count -gt 1) {
            Write-Host "[PROBE] Проверка стратегии: $($current.Name)..." -ForegroundColor Cyan
            $gwUrl = ("https", "://gateway.", "discord.gg") -join ""
            $ytUrl = ("https", "://www.", "youtube.com") -join ""
            $dcOk  = (Test-ServiceReachable -Url $gwUrl -TimeoutSec 4) -and (Test-ServiceReachable -Url $ytUrl -TimeoutSec 4)

            if ($dcOk) {
                Set-Content -Path $presetFile -Value $idx -Encoding ASCII
                Write-WinNetLog "Подобрана и активирована рабочая стратегия: $($current.Name)." "OK"
                Write-Host "[ACTIVE] Ядро активно ($($current.Name)) — соединение подтверждено!" -ForegroundColor Green
                return $true
            }
        } else {
            Write-WinNetLog "DPI-движок запущен ($($current.Name))." "OK"
            Write-Host "[ACTIVE] Ядро активно ($($current.Name))." -ForegroundColor Green
            return $true
        }
    }

    # Если ни один пресет не пробил оба узла сразу, оставляем первый активным для базовой фильтрации
    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
        Write-WinNetLog "Ядро запущено в базовом режиме (полное пробитие не подтверждено)." "WARN"
        Write-Host "[ACTIVE] Ядро запущено, но часть узлов может требовать ручного выбора профиля (.yaml)." -ForegroundColor Yellow
        return $true
    }

    Write-WinNetLog "Не удалось запустить DPI-движок ни с одним пресетом." "ERROR"
    Write-Host "[ERROR] Процесс winws.exe не смог запуститься." -ForegroundColor Red
    return $false
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
