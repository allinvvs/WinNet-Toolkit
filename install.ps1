<#
.SYNOPSIS
    WinNet-Toolkit v3.2 Enterprise/Geek Installer
.DESCRIPTION
    Идемпотентный установщик с поддержкой:
    - Локального развертывания (из D:\WinNet-Toolkit или любой распакованной папки)
    - Удаленного развертывания с верификацией SHA256
    - Автоматического обнаружения и импорта пользовательских .yaml и .conf профилей
    - Независимой от OneDrive регистрации в системном PATH и PowerShell $PROFILE
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 1. Проверка привилегий (Auto-Elevation при необходимости) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[WARN] Требуются права Администратора для настройки системного PATH и сетевого стека." -ForegroundColor Yellow
    if ($PSCommandPath) {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit 0
    } else {
        throw "Перезапустите терминал от имени Администратора (Win + X -> Терминал (Администратор))."
    }
}

# --- 2. Конфигурация путей ---
$InstallDir = "$env:ProgramData\WinNet-Toolkit"
$BinDir     = "$InstallDir\bin"
$ConfigDir  = "$InstallDir\configs"
$BackupDir  = "$InstallDir\backup"
$RepoBase   = ("https", "://raw.", "githubusercontent.com", "/allinvvs/WinNet-Toolkit/main") -join ""
$Modules    = @("netcheck.ps1", "dpi-engine.ps1", "watchdog.ps1", "winnet-cli.ps1")

New-Item -ItemType Directory -Force -Path $InstallDir, $BinDir, $ConfigDir, $BackupDir | Out-Null

# --- 3. Определение режима установки (Локальный из $PSScriptRoot vs Удаленный) ---
$SourceDir = if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "netcheck.ps1"))) { $PSScriptRoot } else { $null }

if ($SourceDir) {
    Write-Host "[INFO] Режим локальной установки из: $SourceDir" -ForegroundColor Cyan
    foreach ($mod in $Modules) {
        $srcFile = Join-Path $SourceDir $mod
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination (Join-Path $InstallDir $mod) -Force
            Write-Host "  [+] Модуль развернут: $mod" -ForegroundColor Gray
        }
    }

    # Автоматический поиск и импорт пользовательских .yaml (Clash/Mihomo) и .conf (AmneziaWG/WG)
    $profileFiles = @(Get-ChildItem -Path $SourceDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml', '.yml', '.conf') })
    if ($profileFiles.Count -gt 0) {
        foreach ($profFile in $profileFiles) {
            Copy-Item -Path $profFile.FullName -Destination (Join-Path $ConfigDir $profFile.Name) -Force
            Write-Host "  [+] Импортирован профиль маршрутизации: $($profFile.Name)" -ForegroundColor Green
        }
    }
} else {
    Write-Host "[INFO] Режим сетевой загрузки из репозитория GitHub..." -ForegroundColor Cyan
    $headers = @{ "User-Agent" = "WinNet-Toolkit-Installer/3.2" }

    $checksumMap = @{}
    try {
        $manifestRaw = Invoke-RestMethod -Uri "$RepoBase/checksums.sha256" -Headers $headers -TimeoutSec 10
        foreach ($line in ($manifestRaw -split "`n")) {
            if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$') {
                $checksumMap[$matches[2].Trim()] = $matches[1].ToUpperInvariant()
            }
        }
    } catch {
        Write-Host "[WARN] Манифест checksums.sha256 недоступен в ветке, включена базовая проверка целостности." -ForegroundColor DarkYellow
    }

    foreach ($mod in $Modules) {
        $tmpFile  = Join-Path $env:TEMP "winnet_$mod"
        $destFile = Join-Path $InstallDir $mod
        try {
            Invoke-WebRequest -Uri "$RepoBase/$mod" -OutFile $tmpFile -Headers $headers -TimeoutSec 15 -UseBasicParsing
            if ((Get-Item $tmpFile).Length -lt 100) { throw "Файл $mod пуст или поврежден." }

            if ($checksumMap.ContainsKey($mod)) {
                $actualHash = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($actualHash -ne $checksumMap[$mod]) {
                    throw "CRITICAL SECURITY ALERT: SHA256 mismatch для $mod! Ожидался: $($checksumMap[$mod]), получен: $actualHash"
                }
                Write-Host "  [SHA256 OK] $mod" -ForegroundColor Green
            }

            Move-Item -Path $tmpFile -Destination $destFile -Force
            Write-Host "  [+] Модуль загружен: $mod" -ForegroundColor Gray
        } catch {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            if ($mod -in @("netcheck.ps1", "dpi-engine.ps1")) { throw }
            Write-Host "  [!] Опциональный модуль $mod пропущен: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

# --- 4. Регистрация глобальных CLI-точек входа (независимо от OneDrive и $PROFILE) ---
$winnetWrapper = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\winnet-cli.ps1" %*
"@
$netcheckWrapper = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\netcheck.ps1" %*
"@

Set-Content -Path (Join-Path $BinDir "winnet.cmd") -Value $winnetWrapper -Encoding ASCII
Set-Content -Path (Join-Path $BinDir "netcheck.cmd") -Value $netcheckWrapper -Encoding ASCII

# Идемпотентное добавление в системный PATH
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$BinDir", "Machine")
}
if ($env:Path -notlike "*$BinDir*") {
    $env:Path = "$env:Path;$BinDir"
}

# --- 5. Дублирующая привязка в $PROFILE для совместимости со старыми сессиями ---
$prof = $PROFILE.CurrentUserAllHosts
$profDir = Split-Path -Path $prof -Parent
if (-not (Test-Path $profDir)) { New-Item -ItemType Directory -Path $profDir -Force | Out-Null }
if (-not (Test-Path $prof)) { New-Item -ItemType File -Path $prof -Force | Out-Null }

$profileContent = Get-Content -Path $prof -Raw -ErrorAction SilentlyContinue
if ($profileContent -notmatch [regex]::Escape($InstallDir)) {
    $loaderBlock = @"

# WinNet-Toolkit Loader
if (Test-Path "$InstallDir\dpi-engine.ps1") { . "$InstallDir\dpi-engine.ps1" }
"@
    Add-Content -Path $prof -Value $loaderBlock -Encoding UTF8
}

# --- 6. Активация в текущей сессии ---
if (Test-Path "$InstallDir\dpi-engine.ps1") {
    . "$InstallDir\dpi-engine.ps1"
}

Write-Host "`n============================================================" -ForegroundColor DarkCyan
Write-Host "[ГОТОВО] WinNet-Toolkit v3.2 установлен в: $InstallDir" -ForegroundColor Green
Write-Host "Доступные команды (в любом окне CMD / PowerShell): winnet | netcheck" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor DarkCyan

# --- 7. Автоматический запуск панели управления при интерактивной установке ---
$cliScript = Join-Path $InstallDir "winnet-cli.ps1"
if ([Environment]::UserInteractive -and (Test-Path $cliScript)) {
    & $cliScript
}
