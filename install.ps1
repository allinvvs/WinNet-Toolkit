<#
.SYNOPSIS
    WinNet-Toolkit v4.0 Hardened Installer
.DESCRIPTION
    Идемпотентный защищённый установщик:
    - Локальное развёртывание из распакованного архива с автоимпортом .yaml / .conf
    - Удалённое развёртывание в изолированную GUID-директорию с обязательной SHA256-верификацией
    - Установка жёстких ACL-прав на C:\ProgramData\WinNet-Toolkit (защита от LPE и утечки конфигов)
    - Независимая от OneDrive регистрация в системном PATH
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoMenu,
    [switch]$AllowUnverified
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 1. Проверка привилегий (Auto-Elevation) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[WARN] Требуются права Администратора для настройки системного PATH и сетевого стека." -ForegroundColor Yellow
    if ($PSCommandPath) {
        $elevateArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($NoMenu) { $elevateArgs += " -NoMenu" }
        Start-Process -FilePath "powershell.exe" -ArgumentList $elevateArgs -Verb RunAs
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

# --- 3. Определение режима установки (Локальный vs Сетевой) ---
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

    $profileFiles = @(Get-ChildItem -Path $SourceDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml', '.yml', '.conf') })
    if ($profileFiles.Count -gt 0) {
        foreach ($profFile in $profileFiles) {
            Copy-Item -Path $profFile.FullName -Destination (Join-Path $ConfigDir $profFile.Name) -Force
            Write-Host "  [+] Импортирован профиль маршрутизации: $($profFile.Name)" -ForegroundColor Green
        }
    }
} else {
    Write-Host "[INFO] Режим защищённой сетевой загрузки из репозитория GitHub..." -ForegroundColor Cyan
    $headers = @{ "User-Agent" = "WinNet-Toolkit-Installer/3.3" }
    $stageDir = Join-Path $env:TEMP ("winnet_stage_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    try {
        $checksumMap = @{}
        try {
            $manifestRaw = Invoke-RestMethod -Uri "$RepoBase/checksums.sha256" -Headers $headers -TimeoutSec 10
            foreach ($line in ($manifestRaw -split "`n")) {
                if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$') {
                    $checksumMap[$matches[2].Trim()] = $matches[1].ToUpperInvariant()
                }
            }
        } catch {
            if (-not $AllowUnverified) {
                throw "SECURITY ABORT: Не удалось загрузить манифест контрольных сумм checksums.sha256. Используйте локальный архив релиза."
            }
            Write-Host "[WARN] Проверка SHA256 отключена флагом -AllowUnverified." -ForegroundColor DarkYellow
        }

        foreach ($mod in $Modules) {
            $tmpFile  = Join-Path $stageDir $mod
            $destFile = Join-Path $InstallDir $mod
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
        }
    } finally {
        Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 4. Регистрация глобальных CLI-точек входа ---
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

$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$BinDir", "Machine")
}
if ($env:Path -notlike "*$BinDir*") {
    $env:Path = "$env:Path;$BinDir"
}

# --- 5. Дублирующая привязка в $PROFILE ---
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

# --- 6. Подключение ядра и установка жёстких ACL-прав на каталог ---
if (Test-Path "$InstallDir\dpi-engine.ps1") {
    . "$InstallDir\dpi-engine.ps1"
    Set-StrictFolderAcl -TargetPath $InstallDir
}

Write-Host "`n============================================================" -ForegroundColor DarkCyan
Write-Host "[ГОТОВО] WinNet-Toolkit v4.0 установлен в: $InstallDir" -ForegroundColor Green
Write-Host "Доступные команды (в любом окне CMD / PowerShell): winnet | netcheck" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor DarkCyan

# --- 7. Автоматическая настройка "из коробки" в 2 клика ---
if (-not $NoMenu -and [Environment]::UserInteractive) {
    Write-Host "[AUTO] Выполняется автоматическая настройка соединения..." -ForegroundColor Cyan
    Set-CleanDNS
    Optimize-YouTubeStream
    if (Start-DpiEngine -AutoProbe) {
        Register-WinNetAutoStart
    }
    Write-Host "`n[SUCCESS] Интернет полностью настроен! Можете открывать YouTube, Discord и Telegram.`n" -ForegroundColor Green

    $cliScript = Join-Path $InstallDir "winnet-cli.ps1"
    if (Test-Path $cliScript) {
        & $cliScript
    }
}

