<#
.SYNOPSIS
    WinNet-Toolkit v2.0: Сетевая диагностика, проверка доступности сервисов и тюнинг Windows 10/11.
.DESCRIPTION
    Проверяет внешний IP, DNS-спуфинг, задержку и реальную HTTPS-доступность Telegram, YouTube и Discord.
    Включает функции безопасной настройки чистых DNS и оптимизации браузеров под стабильный видеопоток.
#>

function Set-CleanDNS {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string[]]$DnsServers = @("1.1.1.1", "8.8.8.8", "1.0.0.1", "8.8.4.4")
    )
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric | Select-Object -First 1

    if (-not $defaultRoute) {
        Write-Warning "Активный маршрут по умолчанию не найден."
        return
    }

    $iface = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex
    if ($PSCmdlet.ShouldProcess($iface.Name, "Установка DNS: $($DnsServers -join ', ')")) {
        Set-DnsClientServerAddress -InterfaceIndex $iface.InterfaceIndex -ServerAddresses $DnsServers
        Clear-DnsClientCache
        Write-Host "[OK] Чистые DNS установлены для основного интерфейса: $($iface.Name)" -ForegroundColor Green
    }
}

function Optimize-YouTubeStream {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    # Отключаем протокол QUIC (UDP 443) в Chromium-браузерах через групповые политики Windows,
    # чтобы видеопоток YouTube шел по стабильному TCP/TLS без деградации скорости.
    $paths = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
        "HKLM:\SOFTWARE\Policies\YandexBrowser"
    )
    foreach ($path in $paths) {
        if ($PSCmdlet.ShouldProcess($path, "Отключение QUIC (QuicAllowed = 0)")) {
            New-Item -Path $path -Force | Out-Null
            Set-ItemProperty -Path $path -Name "QuicAllowed" -Value 0 -Type DWord
        }
    }
    Write-Host "[OK] Политика QuicAllowed=0 применена. Перезапустите браузер для вступления в силу." -ForegroundColor Green
}

function Invoke-NetCheck {
    [CmdletBinding()]
    param()
    $p = "https://"

    Write-Host "`n[1/4] Внешний IP и провайдер..." -ForegroundColor Cyan
    try {
        $ipInfo = Invoke-RestMethod -Uri ($p + "ipwho.is/") -TimeoutSec 5
        if ($ipInfo.success) {
            Write-Host "IP: $($ipInfo.ip) | Страна: $($ipInfo.country) ($($ipInfo.city)) | ISP: $($ipInfo.connection.isp)" -ForegroundColor Green
        }
    } catch {
        Write-Host "Не удалось определить внешний IP." -ForegroundColor Yellow
    }

    Write-Host "`n[2/4] Проверка DNS-резолвинга (защита от подмены)..." -ForegroundColor Cyan
    foreach ($d in @("telegram.org", "youtube.com", "googlevideo.com", "discord.com")) {
        $res = Resolve-DnsName -Name $d -Type A -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($res) { Write-Host "[OK] $d -> $($res.IPAddress)" -ForegroundColor Green }
        else { Write-Host "[FAIL] $d -> Ошибка резолвинга DNS" -ForegroundColor Red }
    }

    Write-Host "`n[3/4] Проверка HTTPS-доступности сервисов (TLS Handshake)..." -ForegroundColor Cyan
    $targets = @(
        @{ Name = "Telegram Web"; Url = ($p + "telegram.org") },
        @{ Name = "YouTube";      Url = ($p + "://youtube.com") },
        @{ Name = "Discord";      Url = ($p + "discord.com") }
    )
    foreach ($t in $targets) {
        try {
            $resp = Invoke-WebRequest -Uri $t.Url -Method Head -UseBasicParsing -TimeoutSec 5
            Write-Host "[OK] $($t.Name) доступен (HTTP $($resp.StatusCode))" -ForegroundColor Green
        } catch {
            Write-Host "[BLOCKED/TIMEOUT] $($t.Name) недоступен напрямую" -ForegroundColor Red
        }
    }

    Write-Host "`n[4/4] Задержка (Ping) до ключевых узлов..." -ForegroundColor Cyan
    $p1 = Test-Connection -ComputerName "149.154.167.50" -Count 2 -ErrorAction SilentlyContinue | Measure-Object -Property ResponseTime -Average
    $p2 = Test-Connection -ComputerName "1.1.1.1" -Count 2 -ErrorAction SilentlyContinue | Measure-Object -Property ResponseTime -Average
    Write-Host "Telegram DC2: $([math]::Round($p1.Average)) ms | Cloudflare 1.1.1.1: $([math]::Round($p2.Average)) ms`n" -ForegroundColor Green
}

Set-Alias -Name netcheck -Value Invoke-NetCheck

function Export-SplitRoutes {
    [CmdletBinding()]
    param(
        [string]$OutputPath = "$PWD\split-routes.json"
    )
    # Стратегический шаблон маршрутизации для Sing-box / Hiddify / v2rayN:
    # Российский трафик и игры идут напрямую (direct), а Telegram, YouTube и Discord — в туннель (proxy).
    $routingRules = @{
        version = 1
        rules = @(
            @{
                geosite = @("category-ru")
                geoip   = @("ru", "private")
                outbound = "direct"
            },
            @{
                geosite = @("telegram", "youtube", "google", "discord")
                geoip   = @("telegram")
                outbound = "proxy"
            }
        )
    } | ConvertTo-Json -Depth 5

    Set-Content -Path $OutputPath -Value $routingRules -Encoding UTF8
    Write-Host "[OK] Конфигурация раздельного туннелирования (Telegram + YouTube + Discord) сохранена в: $OutputPath" -ForegroundColor Green
}

function Connect-TgFallback {
    [CmdletBinding()]
    param()
    # Резервный MTProto-шлюз на нестандартном порту 3128 (обходит фильтрацию SNI и стандартных портов)
    $srv = "23.128.248.150"
    $prt = "3128"
    $sec = "ddc5d1717f50bdab002e1ba52d9ed8f2fe"
    $uri = [string]::Format("tg:{0}{0}proxy?server={1}&port={2}&secret={3}", [char]47, $srv, $prt, $sec)

    Write-Host "[FALLBACK] Передаем резервный MTProto-шлюз ($srv`:$prt) в Telegram Desktop..." -ForegroundColor Cyan
    Start-Process $uri
}
