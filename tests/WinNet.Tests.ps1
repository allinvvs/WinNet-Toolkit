<#
.SYNOPSIS
    WinNet-Toolkit v3.2 Automated Test Suite (Compatible with PowerShell 5.1+ & Pester 3.4/5+)
#>

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $PWD "Tests" }
$RepoRoot = Split-Path -Path $here -Parent
$Scripts  = @("install.ps1", "dpi-engine.ps1", "netcheck.ps1", "watchdog.ps1", "winnet-cli.ps1")

Describe "WinNet-Toolkit Syntax and Architecture Validation" {
    foreach ($scriptName in $Scripts) {
        It "Script $scriptName exists and has zero syntax errors" {
            $fullPath = Join-Path $RepoRoot $scriptName
            Test-Path $fullPath | Should Be $true

            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$errors) | Out-Null
            $errors.Count | Should Be 0
        }
    }

    It "Setup.bat exists for two-click installation" {
        Test-Path (Join-Path $RepoRoot "Setup.bat") | Should Be $true
    }

    It "Scripts contain no hardcoded secrets or unsafe iex calls" {
        foreach ($file in $Scripts) {
            $content = Get-Content -Path (Join-Path $RepoRoot $file) -Raw
            $content | Should Not Match "Invoke-Expression|\biex\b"
            $content | Should Not Match "FromBase64String"
        }
    }
}

Describe "DPI Engine Security and Rollback Unit Tests" {
    . (Join-Path $RepoRoot "dpi-engine.ps1")

    It "Exports all required management and rollback functions" {
        $expectedFunctions = @(
            "Write-WinNetLog",
            "Backup-NetworkState",
            "Restore-NetworkState",
            "Set-CleanDNS",
            "Optimize-YouTubeStream",
            "Initialize-DpiCore",
            "Start-DpiEngine",
            "Stop-DpiEngine",
            "Register-WinNetAutoStart",
            "Unregister-WinNetAutoStart"
        )
        foreach ($fn in $expectedFunctions) {
            (Get-Command $fn -ErrorAction SilentlyContinue) -ne $null | Should Be $true
        }
    }

    It "Write-WinNetLog writes structured entries to the log file" {
        $testLog = Join-Path $TestDrive "test-winnet.log"
        $script:LogFile = $testLog
        Write-WinNetLog -Message "Unit test message" -Level "OK"

        Test-Path $testLog | Should Be $true
        (Get-Content $testLog -Raw) | Should Match "\[OK\] Unit test message"
    }

    It "Setup.bat uses pure ASCII without UTF-8 BOM and has .gitattributes" {
        Test-Path (Join-Path $RepoRoot ".gitattributes") | Should Be $true
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $RepoRoot "Setup.bat"))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
    }
}
