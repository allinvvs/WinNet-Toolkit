@echo off
chcp 65001 >nul
title WinNet-Toolkit v3.2 Setup

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [INFO] Запрос прав администратора...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
