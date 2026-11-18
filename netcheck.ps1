<#
.SYNOPSIS
    WinNet-Toolkit Diagnostics v3.2: Комплексный аудит сетевого стека Windows 10/11.
.DESCRIPTION
    Выполняет 5-ступенчатую диагностику:
    1. Проверка статуса локальных модулей (DPI-движок, Watchdog, импортированные .yaml/.conf профили).
    2. Определение внешнего IP-адреса и провайдера (ISP) по HTTPS.
    3. Аудит DNS-резолвинга и защиты от спуфинга.
    4. Проверка реального TLS Handshake до Telegram, YouTube и Discord.
    5. Замер сетевой задержки (Ping) до контрольных узлов.
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseDir   = "$env:ProgramData\WinNet-Toolkit"
$script:ConfigDir = "$script:BaseDir\configs"

# Подгружаем базовые функции (Set-CleanDNS, Optimize-YouTubeStream, Rollback), если модуль развернут
$dpiModule = Join-Path $script:BaseDir "dpi-engine.ps1"
if (Test-Path $dpiModule) {
    . $dpiModule
}

function Invoke-NetCheck {
    [CmdletBinding()]
    param()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host "`n================ WinNet-Toolkit Diagnostics v3.2 ================" -ForegroundColor DarkCyan

    # --- Блок 1: Аудит локальных контуров защиты ---
    Write-Host "`n[1/5] Статус локальных модулей и маршрутизации..." -ForegroundColor Cyan
    $winwsProc = Get-Process -Name "winws" -ErrorAction SilentlyContinue
    if ($winwsProc) {
        Write-Host "[ACTIVE] DPI-ядро (winws.exe): запущено (PID: $($winwsProc.Id))" -ForegroundColor Green
    } else {
        Write-Host "[INACTIVE] DPI-ядро (winws.exe): остановлено" -ForegroundColor Yellow
    }

    $watchdogTask = Get-ScheduledTask -TaskName "WinNet-Toolkit-Watchdog" -ErrorAction SilentlyContinue
    if ($watchdogTask -and $watchdogTask.State -ne 'Disabled') {
        Write-Host "[ACTIVE] Фоновый Watchdog (автозапуск): активен ($($watchdogTask.State))" -ForegroundColor Green
    } else {
        Write-Host "[INACTIVE] Фоновый Watchdog (автозапуск): не настроен" -ForegroundColor DarkYellow
    }

    $tunAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Meta|Clash|wintun|Amnezia|WireGuard" -and $_.Status -eq "Up" } | Select-Object -First 1
    if ($tunAdapter) {
        Write-Host "[ACTIVE] Виртуальный TUN-адаптер: $($tunAdapter.Name) ($($tunAdapter.InterfaceDescription))" -ForegroundColor Green
    }

    if (Test-Path $script:ConfigDir) {
        $profiles = @(Get-ChildItem -Path $script:ConfigDir -File -ErrorAction SilentlyContinue)
        if ($profiles.Count -gt 0) {
            Write-Host "[OK] Импортированные профили ($($profiles.Count)): $($profiles.Name -join ', ')" -ForegroundColor Green
        }
    }

    # --- Блок 2: Внешний IP и провайдер ---
    Write-Host "`n[2/5] Внешний IP и провайдер..." -ForegroundColor Cyan
    try {
        $ipInfo = Invoke-RestMethod -Uri "https://ipwho.is" -TimeoutSec 5
        if ($ipInfo.success) {
            Write-Host "[OK] IP: $($ipInfo.ip) | Страна: $($ipInfo.country) ($($ipInfo.city)) | ISP: $($ipInfo.connection.isp)" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Сервис определения IP вернул некорректный ответ." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[WARN] Не удалось определить внешний IP (таймаут или блокировка)." -ForegroundColor Yellow
    }

    # --- Блок 3: Проверка DNS-резолвинга ---
    Write-Host "`n[3/5] Проверка DNS-резолвинга..." -ForegroundColor Cyan
    $dnsFailed = $false
    foreach ($domain in @("telegram.org", "youtube.com", "googlevideo.com", "discord.com")) {
        $res = Resolve-DnsName -Name $domain -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.QueryType -eq 'A' } | Select-Object -First 1
        if ($res) {
            Write-Host "[OK] $domain -> $($res.IPAddress)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $domain -> Ошибка резолвинга DNS" -ForegroundColor Red
            $dnsFailed = $true
        }
    }
    if ($dnsFailed) {
        Write-Host "  -> Рекомендация: выполните Set-CleanDNS (пункт 3 в меню winnet)." -ForegroundColor DarkYellow
    }

    # --- Блок 4: Проверка HTTPS-доступности (TLS Handshake) ---
    Write-Host "`n[4/5] Проверка HTTPS-доступности сервисов (TLS Handshake)..." -ForegroundColor Cyan
    $targets = @(
        @{ Name = "Telegram Web"; Url = "https://telegram.org" },
        @{ Name = "YouTube";      Url = "https://youtube.com" },
        @{ Name = "Discord";      Url = "https://discord.com" }
    )
    $tlsFailed = $false
    foreach ($t in $targets) {
        try {
            $resp = Invoke-WebRequest -Uri $t.Url -Method Head -UseBasicParsing -TimeoutSec 5
            Write-Host "[OK] $($t.Name) доступен (HTTP $($resp.StatusCode))" -ForegroundColor Green
        } catch {
            Write-Host "[BLOCKED/TIMEOUT] $($t.Name) недоступен напрямую" -ForegroundColor Red
            $tlsFailed = $true
        }
    }
    if ($tlsFailed -and -not $winwsProc -and -not $tunAdapter) {
        Write-Host "  -> Рекомендация: запустите DPI-ядро командой Start-DpiEngine (пункт 1 в меню winnet)." -ForegroundColor DarkYellow
    }

    # --- Блок 5: Замер задержки (Ping) ---
    Write-Host "`n[5/5] Задержка (Ping) до ключевых узлов..." -ForegroundColor Cyan
    $p1 = Test-Connection -ComputerName "149.154.167.50" -Count 2 -ErrorAction SilentlyContinue | Measure-Object -Property ResponseTime -Average
    $p2 = Test-Connection -ComputerName "1.1.1.1" -Count 2 -ErrorAction SilentlyContinue | Measure-Object -Property ResponseTime -Average

    $tgPing = if ($p1.Count -gt 0) { "$([math]::Round($p1.Average)) ms" } else { "Timeout" }
    $cfPing = if ($p2.Count -gt 0) { "$([math]::Round($p2.Average)) ms" } else { "Timeout" }
    Write-Host "[INFO] Telegram DC2: $tgPing | Cloudflare 1.1.1.1: $cfPing`n" -ForegroundColor Green
}

function Export-SplitRoutes {
    [CmdletBinding()]
    param(
        [string]$OutputPath = "$PWD\split-routes.json"
    )
    $routingRules = @{
        version = 1
        rules = @(
            @{
                geosite  = @("category-ru")
                geoip    = @("ru", "private")
                outbound = "direct"
            },
            @{
                geosite  = @("telegram", "youtube", "google", "discord")
                geoip    = @("telegram")
                outbound = "proxy"
            }
        )
    } | ConvertTo-Json -Depth 5

    Set-Content -Path $OutputPath -Value $routingRules -Encoding UTF8
    Write-Host "[OK] Конфигурация раздельного туннелирования сохранена в: $OutputPath" -ForegroundColor Green
}

Set-Alias -Name netcheck -Value Invoke-NetCheck

# Автоматический запуск диагностики при прямом вызове скрипта (через netcheck.cmd)
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-NetCheck
}
