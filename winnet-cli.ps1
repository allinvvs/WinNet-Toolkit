<#
.SYNOPSIS
    WinNet-Toolkit CLI v3.2: Интерактивная консоль управления.
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest

$InstallDir = "$env:ProgramData\WinNet-Toolkit"
. "$InstallDir\dpi-engine.ps1"
. "$InstallDir\netcheck.ps1"

function Show-WinNetMenu {
    Clear-Host
    $winwsState = if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) { "ACTIVE" } else { "STOPPED" }
    $taskObj    = Get-ScheduledTask -TaskName "WinNet-Toolkit-Watchdog" -ErrorAction SilentlyContinue
    $wdState    = if ($taskObj -and $taskObj.State -ne 'Disabled') { "ENABLED" } else { "DISABLED" }
    $configs    = @(Get-ChildItem -Path "$InstallDir\configs" -File -ErrorAction SilentlyContinue)

    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "               WinNet-Toolkit v3.2 Control Panel            " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "  DPI-ядро: [$winwsState]  |  Автозапуск Watchdog: [$wdState]" -ForegroundColor Gray
    if ($configs.Count -gt 0) {
        Write-Host "  Импортированные профили: $($configs.Name -join ', ')" -ForegroundColor Green
    }
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [1] Автонастройка в 1 клик (DNS + YouTube + DPI + Автозапуск)"
    Write-Host "  [2] Запустить диагностику сети (netcheck)"
    Write-Host "  [3] Запустить / Перезапустить DPI-ядро"
    Write-Host "  [4] Остановить DPI-ядро"
    Write-Host "  [5] Настроить чистые DNS (1.1.1.1 / 8.8.8.8) и QUIC"
    Write-Host "  [6] Включить автозапуск и фоновый Watchdog"
    Write-Host "  [7] Отключить автозапуск Watchdog"
    Write-Host "  [8] Открыть папку с импортированными профилями (.yaml/.conf)"
    Write-Host "  [9] Откатить все изменения сети (Rollback)"
    Write-Host "  [0] Выход"
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

while ($true) {
    Show-WinNetMenu
    $choice = Read-Host "`nВыберите действие [0-9]"

    switch ($choice) {
        "1" {
            Set-CleanDNS
            Optimize-YouTubeStream
            if (Start-DpiEngine) {
                Register-WinNetAutoStart
            }
            Pause
        }
        "2" { Invoke-NetCheck; Pause }
        "3" { Start-DpiEngine | Out-Null; Pause }
        "4" { Stop-DpiEngine; Pause }
        "5" { Set-CleanDNS; Optimize-YouTubeStream; Pause }
        "6" { Register-WinNetAutoStart; Pause }
        "7" { Unregister-WinNetAutoStart; Pause }
        "8" {
            if (Test-Path "$InstallDir\configs") {
                Start-Process "explorer.exe" -ArgumentList "$InstallDir\configs"
            }
        }
        "9" {
            Unregister-WinNetAutoStart
            Restore-NetworkState
            Pause
        }
        "0" { exit 0 }
        default { Write-Host "[WARN] Некорректный выбор." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}
