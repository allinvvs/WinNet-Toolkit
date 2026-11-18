<#
.SYNOPSIS
    WinNet-Toolkit CLI v3.4: Интерактивная консоль управления с автопроверкой прав, AutoProbe и просмотром логов.
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Проверка прав Администратора (Auto-Elevation при запуске из обычной консоли)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSCommandPath) {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit 0
    } else {
        Write-Warning "Запустите консоль от имени Администратора для управления сетевыми параметрами."
        exit 1
    }
}

$InstallDir = "$env:ProgramData\WinNet-Toolkit"
. "$InstallDir\dpi-engine.ps1"
. "$InstallDir\netcheck.ps1"

function Wait-UserKey {
    Write-Host ""
    Read-Host "Нажмите Enter для возврата в меню" | Out-Null
}

function Show-WinNetMenu {
    Clear-Host
    $winwsState = if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) { "ACTIVE" } else { "STOPPED" }
    $taskObj    = Get-ScheduledTask -TaskName "WinNet-Toolkit-Watchdog" -ErrorAction SilentlyContinue
    $wdState    = if ($taskObj -and $taskObj.State -ne 'Disabled') { "ENABLED" } else { "DISABLED" }
    $configs    = @(Get-ChildItem -Path "$InstallDir\configs" -File -ErrorAction SilentlyContinue)

    $presetFile = Join-Path $InstallDir "active-preset.txt"
    $presetInfo = if (Test-Path $presetFile) {
        $idx = [int](Get-Content $presetFile -Raw).Trim() + 1
        "Preset #$idx"
    } else {
        "Auto"
    }

    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "               WinNet-Toolkit v3.4 Control Panel            " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "  DPI-ядро: [$winwsState ($presetInfo)]  |  Watchdog: [$wdState]" -ForegroundColor Gray
    if ($configs.Count -gt 0) {
        Write-Host "  Импортированные профили: $($configs.Name -join ', ')" -ForegroundColor Green
    }
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [1] Автонастройка в 1 клик (DNS + YouTube + AutoProbe + Watchdog)"
    Write-Host "  [2] Запустить диагностику сети (netcheck)"
    Write-Host "  [3] Запустить / Переподобрать стратегию DPI-ядра (AutoProbe)"
    Write-Host "  [4] Остановить DPI-ядро"
    Write-Host "  [5] Настроить чистые DNS (IPv4 + IPv6) и QUIC"
    Write-Host "  [6] Включить автозапуск и фоновый Watchdog"
    Write-Host "  [7] Отключить автозапуск Watchdog"
    Write-Host "  [8] Открыть папку с импортированными профилями (.yaml/.conf)"
    Write-Host "  [9] Откатить все изменения сети (Rollback)"
    Write-Host "  [L] Показать последние записи журнала (winnet.log)"
    Write-Host "  [0] Выход"
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

while ($true) {
    Show-WinNetMenu
    $choice = (Read-Host "`nВыберите действие [0-9, L]").Trim().ToUpperInvariant()

    try {
        switch ($choice) {
            "1" {
                Set-CleanDNS
                Optimize-YouTubeStream
                if (Start-DpiEngine -AutoProbe) {
                    Register-WinNetAutoStart
                }
                Wait-UserKey
            }
            "2" { Invoke-NetCheck; Wait-UserKey }
            "3" { Start-DpiEngine -AutoProbe | Out-Null; Wait-UserKey }
            "4" { Stop-DpiEngine; Wait-UserKey }
            "5" { Set-CleanDNS; Optimize-YouTubeStream; Wait-UserKey }
            "6" { Register-WinNetAutoStart; Wait-UserKey }
            "7" { Unregister-WinNetAutoStart; Wait-UserKey }
            "8" {
                if (Test-Path "$InstallDir\configs") {
                    Start-Process "explorer.exe" -ArgumentList "$InstallDir\configs"
                }
            }
            "9" {
                Unregister-WinNetAutoStart
                Restore-NetworkState
                Wait-UserKey
            }
            "L" {
                $logPath = "$InstallDir\winnet.log"
                Write-Host "`n--- Последние 20 записей журнала ---" -ForegroundColor Cyan
                if (Test-Path $logPath) {
                    Get-Content -Path $logPath -Tail 20
                } else {
                    Write-Host "[INFO] Журнал пока пуст." -ForegroundColor Gray
                }
                Wait-UserKey
            }
            "0" { exit 0 }
            default { Write-Host "[WARN] Некорректный выбор." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    } catch {
        Write-Host "`n[ERROR] Ошибка выполнения операции: $($_.Exception.Message)" -ForegroundColor Red
        Write-WinNetLog "Ошибка в интерактивном меню (пункт $choice): $($_.Exception.Message)" "ERROR"
        Wait-UserKey
    }
}
