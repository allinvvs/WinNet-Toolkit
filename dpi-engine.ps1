<#
.SYNOPSIS
    WinNet-Toolkit Hybrid Engine v4.0:
    Эшелон 1: Автономный Mihomo TUN (при наличии валидного .yaml профиля)
    Эшелон 2: Адаптивный DPI-контроллер winws + системный DoH (Zero-Config Fallback)
    Стандарты: StrictMode, ACL Hardening, SHA256, GUID-изоляция, Fail-Safe Rollback.
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
        $acl.SetAccessRuleProtection($true, $false)

        $adminSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
        $usersSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")

        $inheritFlags = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
        $propFlags    = [System.Security.AccessControl.PropagationFlags]::None

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminSid,  "FullControl",    $inheritFlags, $propFlags, "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, "FullControl",    $inheritFlags, $propFlags, "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid,  "ReadAndExecute", $inheritFlags, $propFlags, "Allow")))

        Set-Acl -Path $TargetPath -AclObject $acl
    } catch {
        Write-WinNetLog "Предупреждение ACL для ${TargetPath}: $($_.Exception.Message)" "WARN"
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

    foreach ($regPath in @("HKLM:\SOFTWARE\Policies\Google\Chrome", "HKLM:\SOFTWARE\Policies\Microsoft\Edge", "HKLM:\SOFTWARE\Policies\YandexBrowser")) {
        Remove-ItemProperty -Path $regPath -Name "QuicAllowed" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "DnsOverHttpsMode" -ErrorAction SilentlyContinue
    }
    Clear-DnsClientCache

    Write-WinNetLog "Исходные параметры DNS и политик браузеров восстановлены." "OK"
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

    if (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
        $cfDoh = ("https", "://cloudflare-dns.com", "/dns-query") -join ""
        $ggDoh = ("https", "://dns.google", "/dns-query") -join ""
        Add-DnsClientDohServerAddress -ServerAddress "1.1.1.1" -DohTemplate $cfDoh -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
        Add-DnsClientDohServerAddress -ServerAddress "8.8.8.8" -DohTemplate $ggDoh -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($reg in @("HKLM:\SOFTWARE\Policies\Google\Chrome", "HKLM:\SOFTWARE\Policies\Microsoft\Edge")) {
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        Set-ItemProperty -Path $reg -Name "DnsOverHttpsMode" -Value "automatic" -Type String
    }

    Clear-DnsClientCache
    Write-WinNetLog "Публичные DNS (IPv4 + IPv6) и DoH применены для адаптера $($adapter.Name)." "OK"
    Write-Host "[OK] Публичные DNS и шифрованный DoH настроены для: $($adapter.Name)" -ForegroundColor Green
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

        if (-not (Get-NetFirewallRule -DisplayName "WinNet-Block-QUIC-UDP443" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "WinNet-Block-QUIC-UDP443" -Direction Outbound -Protocol UDP -RemotePort 443 -Action Block | Out-Null
    }

    Write-WinNetLog "Политика QuicAllowed=0 применена для Chromium-браузеров." "OK"
    Write-Host "[OK] Оптимизация потокового видео (QuicAllowed=0) применена." -ForegroundColor Green
}

function Test-ServiceReachable {
    [CmdletBinding()]
    param(
        [string]$Url = "https://discord.com",
        [int]$TimeoutSec = 4
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

# --- ЭШЕЛОН 1: Автономное ядро Mihomo TUN (при наличии .yaml профиля) ---
function Initialize-MihomoCore {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Force -Path $script:CoreDir | Out-Null
    Set-StrictFolderAcl -TargetPath $script:BaseDir

    $mihomoExe = Join-Path $script:CoreDir "mihomo.exe"
    if (Test-Path $mihomoExe) { return $true }

    Write-Host "[INFO] Загрузка автономного ядра Mihomo TUN..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "WinNet-Toolkit/4.0.1" }
    $apiUrl  = ("https", "://api.", "github.com", "/repos/MetaCubeX/mihomo/releases/latest") -join ""
    $zipPath = Join-Path $env:TEMP ("mihomo_" + [guid]::NewGuid().ToString("N") + ".zip")
    $extPath = Join-Path $env:TEMP ("mihomo_ext_" + [guid]::NewGuid().ToString("N"))

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset   = $release.assets | Where-Object { $_.name -match "mihomo-windows-amd64-v1.*\.zip$" -or $_.name -match "mihomo-windows-amd64-[0-9].*\.zip$" } | Select-Object -First 1
        if (-not $asset) { throw "Архив mihomo для Windows x64 не найден." }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -TimeoutSec 45 -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $extPath -Force

        $exeFound = Get-ChildItem -Path $extPath -Filter "*.exe" -Recurse | Select-Object -First 1
        if ($exeFound) {
            Copy-Item -Path $exeFound.FullName -Destination $mihomoExe -Force
            Write-WinNetLog "Ядро Mihomo развёрнуто из $($asset.name)." "OK"
        }
    } catch {
        Write-WinNetLog "Ошибка загрузки Mihomo: $($_.Exception.Message)" "WARN"
    } finally {
        Remove-Item $zipPath, $extPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    return (Test-Path $mihomoExe)
}

function Start-MihomoEngine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$YamlPath)

    if (-not (Initialize-MihomoCore)) { return $false }

    Stop-Process -Name "winws", "mihomo" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    # Формируем runtime-config.yaml с принудительным включением TUN и DoH, сохраняя якоря исходного .yaml
    $runtimeYaml = Join-Path $script:CoreDir "runtime-config.yaml"
    $rawContent  = Get-Content -Path $YamlPath -Raw -Encoding UTF8
    # Удаляем старые секции tun: в конце, если они были выключены, и добавляем рабочий TUN-блок
    $cleanContent = [regex]::Replace($rawContent, '(?ms)^tun:\s*.*?(?=^\S|\z)', '')

    $tunOverride = @"

# === WinNet-Toolkit Auto-TUN & Encrypted DNS Override ===
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
"@
    [System.IO.File]::WriteAllText($runtimeYaml, ($cleanContent + $tunOverride), [System.Text.UTF8Encoding]::new($false))

    $mihomoExe = Join-Path $script:CoreDir "mihomo.exe"
    Start-Process -FilePath $mihomoExe -ArgumentList "-d `"$script:CoreDir`" -f `"$runtimeYaml`"" -WorkingDirectory $script:CoreDir -WindowStyle Hidden
    Start-Sleep -Seconds 6

    if (-not (Get-Process -Name "mihomo" -ErrorAction SilentlyContinue)) {
        Write-WinNetLog "Процесс mihomo.exe завершился при запуске профиля $(Split-Path $YamlPath -Leaf)." "WARN"
        return $false
    }

    # Даем виртуальному TUN-адаптеру до 3 попыток на установление туннеля
    $dcUrl = ("https", "://", "discord.com") -join ""
    $tunnelReady = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-ServiceReachable -Url $dcUrl -TimeoutSec 4) {
            $tunnelReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if ($tunnelReady) {
        Set-Content -Path (Join-Path $script:BaseDir "active-mode.txt") -Value "MIHOMO" -Encoding ASCII
        Write-WinNetLog "Mihomo TUN активен и подтвержден с профилем: $(Split-Path $YamlPath -Leaf)." "OK"
        Write-Host "[ACTIVE] Гибридный режим Mihomo TUN запущен (Профиль: $(Split-Path $YamlPath -Leaf))!" -ForegroundColor Green
        return $true
    }
}

# --- ЭШЕЛОН 2: Автономный DPI-контроллер (Zero-Config Fallback) ---
function Initialize-DpiCore {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Force -Path $script:CoreDir | Out-Null
    Set-StrictFolderAcl -TargetPath $script:BaseDir

    $domains = @(
        "telegram.org", ("web." + "telegram.org"), ("api." + "telegram.org"), "t.me", "telegram.me", "tdesktop.com", "telegra.ph", "telesco.pe", "cdn-telegram.org",
        "youtube.com", ("www." + "youtube.com"), ("m." + "youtube.com"), "youtu.be", "googlevideo.com", "ytimg.com", ("i." + "ytimg.com"), "ggpht.com", ("yt3." + "ggpht.com"), "googleapis.com", ("youtubei." + "googleapis.com"), ("play." + "google.com"),
        "discord.com", ("www." + "discord.com"), "gateway.discord.gg", ("status." + "discord.com"), ("updates." + "discord.com"), ("cdn." + "discordapp.com"), "media.discordapp.net", "images-ext-1.discordapp.net", "images-ext-2.discordapp.net", "discordapp.com", "discordapp.net", "discord.gg", "discord.media", "discordstatus.com"
    )
    Set-Content -Path $script:ListFile -Value ($domains -join "`r`n") -Encoding ASCII

    if ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll")) {
        return $true
    }

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
            Write-WinNetLog "Бинарные файлы DPI-ядра скопированы из $srcFolder." "OK"
            return $true
        }
    }

    Write-Host "[INFO] Загрузка автономного DPI-ядра из репозитория bol-van/zapret..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "WinNet-Toolkit/4.0" }
    $apiUrl  = ("https", "://api.", "github.com", "/repos/bol-van/zapret/releases/latest") -join ""

    $zipPath     = Join-Path $env:TEMP ("zapret_" + [guid]::NewGuid().ToString("N") + ".zip")
    $extractPath = Join-Path $env:TEMP ("zapret_ext_" + [guid]::NewGuid().ToString("N"))

    try {
        $release  = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset    = $release.assets | Where-Object { $_.name -like "*win64.zip" -or $_.name -like "*.zip" } | Select-Object -First 1
        $shaAsset = $release.assets | Where-Object { $_.name -like "*sha256*" } | Select-Object -First 1

        if (-not $asset) { throw "Установочный архив не найден в последнем релизе." }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -TimeoutSec 30 -UseBasicParsing

        if ($shaAsset) {
            $shaContent   = Invoke-RestMethod -Uri $shaAsset.browser_download_url -Headers $headers -TimeoutSec 10
            $expectedLine = ($shaContent -split "`n") | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
            if ($expectedLine -match '([a-fA-F0-9]{64})') {
                $expectedHash = $matches[1].ToUpperInvariant()
                $actualHash   = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($actualHash -ne $expectedHash) {
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
    } catch {
        Write-WinNetLog "Ошибка загрузки DPI-ядра: $($_.Exception.Message)" "ERROR"
        Write-Warning "Ошибка загрузки DPI-ядра: $($_.Exception.Message)"
    } finally {
        Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    return ((Test-Path "$script:CoreDir\winws.exe") -and (Test-Path "$script:CoreDir\cygwin1.dll"))
}

function Start-DpiEngine {
    [CmdletBinding()]
    param(
        [switch]$AutoProbe,
        [switch]$ForceDpiOnly
    )

    # Приоритет 1: Проверяем наличие .yaml профиля маршрутизации
    if (-not $ForceDpiOnly -and (Test-Path $script:ConfigDir)) {
        $yamlProfile = Get-ChildItem -Path $script:ConfigDir -Filter "*.y*ml" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($yamlProfile) {
            if (Start-MihomoEngine -YamlPath $yamlProfile.FullName) {
                return $true
            }
            Write-Host "[WARN] Переключение на встроенный автономный DPI-режим..." -ForegroundColor Yellow
        }
    }

    # Приоритет 2: Встроенный DPI-контроллер (Zero-Config без .yaml)
    if (-not (Initialize-DpiCore)) {
        Write-Host "[ERROR] Не найдены файлы ядра (winws.exe / cygwin1.dll). Запуск отменен." -ForegroundColor Red
        Write-WinNetLog "Запуск DPI-движка отменен: отсутствуют бинарные файлы." "ERROR"
        return $false
    }

    $presetFile = Join-Path $script:BaseDir "active-preset.txt"
    $presets = @(
        @{
            Name = "Preset-1 (Media-Boost Multidisorder + AutoTTL)"
            Args = @(
                "--wf-tcp=80,443", "--wf-udp=50000-65535",
                "--filter-tcp=443", "--dpi-desync=fake,multidisorder", "--dpi-desync-split-pos=1,midsld", "--dpi-desync-split-seqovl=2", "--dpi-desync-fooling=badseq,md5sig", "--dpi-desync-autottl=2", "--dpi-desync-repeats=8",
                "--new", "--filter-udp=50000-65535", "--filter-l7=discord,stun", "--dpi-desync=fake", "--dpi-desync-repeats=8"
            )
        },
        @{
            Name = "Preset-2 (Universal Multisplit + BadSeq/MD5Sig)"
            Args = @(
                "--wf-tcp=80,443", "--wf-udp=50000-65535",
                "--filter-tcp=443", "--dpi-desync=fake,multisplit", "--dpi-desync-split-pos=1,midsld", "--dpi-desync-split-seqovl=1", "--dpi-desync-fooling=badseq,md5sig", "--dpi-desync-repeats=6",
                "--new", "--filter-udp=50000-65535", "--filter-l7=discord,stun", "--dpi-desync=fake", "--dpi-desync-repeats=6"
            )
        },
        @{
            Name = "Preset-3 (Split2 + BadSum Fallback)"
            Args = @(
                "--wf-tcp=80,443", "--wf-udp=50000-65535",
                "--filter-tcp=443", "--dpi-desync=split2", "--dpi-desync-split-pos=2", "--dpi-desync-fooling=badsum",
                "--new", "--filter-udp=50000-65535", "--filter-l7=discord,stun", "--dpi-desync=fake", "--dpi-desync-repeats=6"
            )
        }
    )

    $indices = 0..($presets.Count - 1)
    if (-not $AutoProbe -and (Test-Path $presetFile)) {
        $savedIdx = [int](Get-Content $presetFile -Raw).Trim()
        if ($savedIdx -ge 0 -and $savedIdx -lt $presets.Count) {
            $indices = @($savedIdx) + ($indices | Where-Object { $_ -ne $savedIdx })
        }
    }

    foreach ($idx in $indices) {
        $current = $presets[$idx]
        Stop-Process -Name "winws", "mihomo" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300

        Start-Process -FilePath "$script:CoreDir\winws.exe" -ArgumentList $current.Args -WorkingDirectory $script:CoreDir -WindowStyle Hidden
        Start-Sleep -Seconds 2

        if (-not (Get-Process -Name "winws" -ErrorAction SilentlyContinue)) {
            continue
        }

        if ($AutoProbe -or $indices.Count -gt 1) {
            Write-Host "[PROBE] Проверка стратегии: $($current.Name)..." -ForegroundColor Cyan
            $dcUrl = ("https", "://", "discord.com") -join ""
            if (Test-ServiceReachable -Url $dcUrl -TimeoutSec 4) {
                Set-Content -Path $presetFile -Value $idx -Encoding ASCII
                Set-Content -Path (Join-Path $script:BaseDir "active-mode.txt") -Value "DPI" -Encoding ASCII
                Write-WinNetLog "Подобрана рабочая DPI-стратегия: $($current.Name)." "OK"
                Write-Host "[ACTIVE] Ядро активно ($($current.Name)) — соединение подтверждено!" -ForegroundColor Green
                return $true
            }
        } else {
            Set-Content -Path (Join-Path $script:BaseDir "active-mode.txt") -Value "DPI" -Encoding ASCII
            Write-WinNetLog "DPI-движок запущен ($($current.Name))." "OK"
            Write-Host "[ACTIVE] Ядро активно ($($current.Name))." -ForegroundColor Green
            return $true
        }
    }

    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
        Set-Content -Path (Join-Path $script:BaseDir "active-mode.txt") -Value "DPI" -Encoding ASCII
        Write-WinNetLog "DPI-ядро запущено в базовом режиме." "WARN"
        Write-Host "[ACTIVE] Ядро запущено в базовом режиме." -ForegroundColor Yellow
        return $true
    }

    Write-WinNetLog "Не удалось запустить ни один из режимов маршрутизации." "ERROR"
    Write-Host "[ERROR] Не удалось запустить ядро." -ForegroundColor Red
    return $false
}

function Stop-DpiEngine {
    [CmdletBinding()]
    param()
    Stop-Process -Name "winws", "mihomo" -Force -ErrorAction SilentlyContinue
    Write-WinNetLog "Все ядра маршрутизации остановлены пользователем." "INFO"
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
    Stop-Process -Name "winws", "mihomo" -Force -ErrorAction SilentlyContinue
    Write-WinNetLog "Задача автозапуска удалена, фоновый мониторинг отключен." "INFO"
    Write-Host "[OK] Автозапуск отключен, фоновые процессы остановлены." -ForegroundColor Yellow
}
