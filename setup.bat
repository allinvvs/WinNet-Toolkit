@echo off
title WinNet-Toolkit Installer

:: Check for Administrator privileges without parentheses blocks
net session >nul 2>&1
if %errorlevel% equ 0 goto :RUN_INSTALL

echo [INFO] Requesting Administrator privileges (UAC)...
powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:RUN_INSTALL
cd /d "%~dp0"
echo [INFO] Starting WinNet-Toolkit deployment from %~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if %errorlevel% neq 0 (
    echo [ERROR] Installation failed with exit code %errorlevel%.
    pause
)
exit /b
