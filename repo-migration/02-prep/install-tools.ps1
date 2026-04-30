<#
.SYNOPSIS
    Installs and validates all tools required for repo migration.
.DESCRIPTION
    Checks for: git, gh CLI, gh-gei extension, git-sizer, gitleaks, git-filter-repo.
    Installs missing tools where possible (via winget, gh extension install, pip).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tools = @(
    @{ Name = "git";              Command = "git --version";                       Install = "winget install Git.Git" }
    @{ Name = "gh";               Command = "gh --version";                        Install = "winget install GitHub.cli" }
    @{ Name = "gh-gei";           Command = "gh gei --help";                       Install = "gh extension install github/gh-gei" }
    @{ Name = "git-sizer";        Command = "git-sizer --version";                 Install = "Download from https://github.com/github/git-sizer/releases" }
    @{ Name = "gitleaks";         Command = "gitleaks version";                     Install = "winget install Gitleaks.Gitleaks" }
    @{ Name = "git-filter-repo";  Command = "git filter-repo --version";            Install = "pip install git-filter-repo" }
)

Write-Host "=== Checking required tools ===" -ForegroundColor Cyan

$missing = @()
foreach ($tool in $tools) {
    Write-Host -NoNewline "  $($tool.Name)... "
    try {
        $output = Invoke-Expression $tool.Command 2>&1
        $version = ($output | Select-Object -First 1).ToString().Trim()
        Write-Host "OK ($version)" -ForegroundColor Green
    }
    catch {
        Write-Host "MISSING" -ForegroundColor Red
        $missing += $tool
    }
}

if ($missing.Count -gt 0) {
    Write-Host "`n=== Missing tools ===" -ForegroundColor Yellow
    foreach ($m in $missing) {
        Write-Host "  $($m.Name): $($m.Install)"
    }
    Write-Host "`nInstall missing tools? (Only automated installs will run)" -ForegroundColor Yellow
    $confirm = Read-Host "Proceed? [y/N]"
    if ($confirm -eq 'y') {
        foreach ($m in $missing) {
            Write-Host "`nInstalling $($m.Name)..." -ForegroundColor Cyan
            try {
                Invoke-Expression $m.Install
                Write-Host "  Installed $($m.Name)" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Failed to install $($m.Name): $_. Install manually: $($m.Install)"
            }
        }
    }
}
else {
    Write-Host "`nAll tools installed!" -ForegroundColor Green
}

# â”€â”€ Validate GEI auth â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`n=== Checking environment variables ===" -ForegroundColor Cyan
$envVars = @("ADO_PAT", "GH_PAT")
foreach ($var in $envVars) {
    $val = [Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrWhiteSpace($val)) {
        Write-Host "  $var : NOT SET" -ForegroundColor Red
    }
    else {
        Write-Host "  $var : Set ($($val.Length) chars)" -ForegroundColor Green
    }
}

Write-Host "`nDone. Ensure all tools are green and env vars are set before proceeding."


