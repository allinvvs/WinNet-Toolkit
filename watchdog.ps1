<#
.SYNOPSIS
    WinNet-Toolkit Watchdog v3.3: Интеллектуальный фоновый контроллер здоровья и самовосстановления.
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = "$env:ProgramData\WinNet-Toolkit"
. "$InstallDir\dpi-engine.ps1"

# Защита от запуска дублирующих экземпляров через глобальный Mutex
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\WinNetToolkitWatchdog", [ref]$createdNew)
if (-not $createdNew) {
    Write-WinNetLog "Экземпляр Watchdog уже активен. Повторный запуск отменен." "WARN"
    exit 0
}

function Test-TlsGateway {
    [CmdletBinding()]
    param(
        [string]$TargetHost = "discord.com",
        [int]$Port = 443,
        [int]$TimeoutMs = 3500
    )
    $tcp = $null
    $ssl = $null
    $iar = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -or -not $tcp.Connected) {
            return $false
        }
        $tcp.EndConnect($iar)
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs

        # Реальная проверка TLS Handshake (защита от ложноположительного TCP SYN при DPI-сбросе SNI)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false)
        $ssl.AuthenticateAsClient($TargetHost)
        return $ssl.IsAuthenticated
    } catch {
        return $false
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($iar -and $iar.AsyncWaitHandle) { $iar.AsyncWaitHandle.Close() }
        if ($tcp) { $tcp.Dispose() }
    }
}

try {
    Write-WinNetLog "Служба мониторинга Watchdog v3.3 запущена." "INFO"
    $failCount = 0
    $baseDelay = 5

    while ($true) {
        # 1. Проверяем наличие активного сетевого интерфейса (если кабель/Wi-Fi отключён — не дёргаем ядро)
        $hasPhysicalLink = [bool](Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false })
        if (-not $hasPhysicalLink) {
            Start-Sleep -Seconds 15
            continue
        }

        $isEngineRunning = [bool](Get-Process -Name "winws", "mihomo" -ErrorAction SilentlyContinue)

        # 2. Проверяем работу ядра и реальный TLS Handshake
        $tlsHealthy = $false
        if ($isEngineRunning) {
            $tlsHealthy = Test-TlsGateway -TargetHost "discord.com" -Port 443 -TimeoutMs 3500
        }

        if ($isEngineRunning -and $tlsHealthy) {
            if ($failCount -gt 0) {
                Write-WinNetLog "Сетевая связность (TLS) успешно восстановлена." "OK"
            }
            $failCount = 0
            Start-Sleep -Seconds 30
            continue
        }

        # 3. Сбой обнаружен: применяем Exponential Backoff (5с -> 10с -> 20с ... до 300с)
        $failCount++
        $backoff = [Math]::Min(300, $baseDelay * [Math]::Pow(2, [Math]::Min($failCount - 1, 5)))
        Write-WinNetLog "Обнаружен сбой ядра или TLS (попытка #$failCount). Перезапуск через $backoff сек." "WARN"

        Start-Sleep -Seconds $backoff
        Start-DpiEngine -AutoProbe | Out-Null
    }
}
finally {
    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
