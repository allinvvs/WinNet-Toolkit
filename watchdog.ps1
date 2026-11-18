<#
.SYNOPSIS
    WinNet-Toolkit Watchdog v3.2: Фоновый мониторинг и самовосстановление соединения.
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

try {
    Write-WinNetLog "Служба мониторинга Watchdog запущена." "INFO"
    $failCount = 0
    $baseDelay = 5

    while ($true) {
        $isEngineRunning = [bool](Get-Process -Name "winws" -ErrorAction SilentlyContinue)
        $isTunUp         = [bool](Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Meta|Clash|wintun|Amnezia|WireGuard" -and $_.Status -eq "Up" })

        # Проверка TCP-связности с внешним шлюзом (Discord Gateway)
        $gatewayReachable = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect("discord.com", 443, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(3000, $false) -and $tcp.Connected) {
                $gatewayReachable = $true
            }
            $tcp.Close()
        } catch {
            $gatewayReachable = $false
        }

        if (($isEngineRunning -or $isTunUp) -and $gatewayReachable) {
            if ($failCount -gt 0) {
                Write-WinNetLog "Сетевая связность восстановлена." "OK"
            }
            $failCount = 0
            Start-Sleep -Seconds 30
            continue
        }

        # Сбой обнаружен: применяем Exponential Backoff (5с -> 10с -> 20с ... до 300с)
        $failCount++
        $backoff = [Math]::Min(300, $baseDelay * [Math]::Pow(2, [Math]::Min($failCount - 1, 5)))
        Write-WinNetLog "Обнаружен сбой связи (попытка #$failCount). Перезапуск ядра через $backoff сек." "WARN"

        Start-Sleep -Seconds $backoff
        Start-DpiEngine | Out-Null
    }
}
finally {
    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
