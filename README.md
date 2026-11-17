# WinNet-Toolkit

Инженерный набор утилит на PowerShell для диагностики сетевой трассы, аудита блокировок на уровне DNS и TLS Handshake (SNI), оптимизации сетевого стека Windows и генерации правил раздельного туннелирования (Split Tunneling).

## Архитектура решения
1. **Диагностика (`netcheck`)** — проверка внешнего IP/ISP, обнаружение DNS-спуфинга, проверка TLS Handshake для веб-сервисов и замер задержки (Ping).
2. **Оптимизация клиента (`Optimize-YouTubeStream`, `Set-CleanDNS`)** — перевод основного сетевого интерфейса на чистые DNS (`1.1.1.1` / `8.8.8.8`) и отключение протокола QUIC (`QuicAllowed = 0`) в Chromium-браузерах для предотвращения деградации видеопотока YouTube.
3. **Маршрутизация (`Export-SplitRoutes`)** — генерация JSON-правил для локальных маршрутизаторов на базе **Sing-box** (Hiddify / v2rayN): трафик РФ и игры идут напрямую (`direct`), а **Telegram, YouTube и Discord** направляются в защищенный туннель (`proxy`).

## Быстрый старт

```powershell
git clone https://github.com
cd WinNet-Toolkit
. .\netcheck.ps1

# Запуск полной диагностики
netcheck

# Генерация правил раздельного туннелирования
Export-SplitRoutes
```
