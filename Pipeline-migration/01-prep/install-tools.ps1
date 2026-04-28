# <#
# .SYNOPSIS
#     Installs all required tools for the ADO-to-GitHub migration accelerator.
# .DESCRIPTION
#     Checks for and installs: GitHub CLI, GEI extension, Actions Importer,
#     git-sizer, gitleaks, git-filter-repo, and Docker.
# #>
# [CmdletBinding()]
# param()

# $ErrorActionPreference = "Continue"

# Write-Host "=== Migration Tooling Installer ===" -ForegroundColor Cyan

# $tools = @(
#     @{
#         Name       = "GitHub CLI (gh)"
#         Command    = "gh"
#         InstallCmd = "winget install --id GitHub.cli -e"
#         Url        = "https://cli.github.com"
#     },
#     @{
#         Name       = "Git"
#         Command    = "git"
#         InstallCmd = "winget install --id Git.Git -e"
#         Url        = "https://git-scm.com"
#     },
#     @{
#         Name       = "Docker Desktop"
#         Command    = "docker"
#         InstallCmd = "winget install --id Docker.DockerDesktop -e"
#         Url        = "https://www.docker.com/products/docker-desktop"
#     },
#     @{
#         Name       = "Python (for git-filter-repo)"
#         Command    = "python"
#         InstallCmd = "winget install --id Python.Python.3.12 -e"
#         Url        = "https://python.org"
#     },
#     @{
#         Name       = "git-sizer"
#         Command    = "git-sizer"
#         InstallCmd = $null
#         Url        = "https://github.com/github/git-sizer/releases"
#     },
#     @{
#         Name       = "gitleaks"
#         Command    = "gitleaks"
#         InstallCmd = "winget install --id Gitleaks.Gitleaks -e"
#         Url        = "https://github.com/gitleaks/gitleaks/releases"
#     }
# )

# $results = @()

# foreach ($tool in $tools) {
#     $cmd = Get-Command $tool.Command -ErrorAction SilentlyContinue
#     if ($cmd) {
#         $version = ""
#         try { $version = & $tool.Command --version 2>&1 | Select-Object -First 1 } catch { }
#         Write-Host "[OK] $($tool.Name): $version" -ForegroundColor Green
#         $results += @{ Tool = $tool.Name; Status = "Installed"; Version = $version }
#     }
#     else {
#         Write-Host "[MISSING] $($tool.Name)" -ForegroundColor Red
#         if ($tool.InstallCmd) {
#             Write-Host "  Install: $($tool.InstallCmd)" -ForegroundColor Yellow
#         }
#         else {
#             Write-Host "  Download from: $($tool.Url)" -ForegroundColor Yellow
#         }
#         $results += @{ Tool = $tool.Name; Status = "Missing"; InstallCmd = $tool.InstallCmd; Url = $tool.Url }
#     }
# }

# # --- Python packages ---
# Write-Host "`n--- Python Packages ---" -ForegroundColor Cyan
# $pythonPackages = @("git-filter-repo")
# foreach ($pkg in $pythonPackages) {
#     $installed = pip show $pkg 2>&1
#     if ($LASTEXITCODE -eq 0) {
#         Write-Host "[OK] $pkg" -ForegroundColor Green
#     }
#     else {
#         Write-Host "[MISSING] $pkg — Install: pip install $pkg" -ForegroundColor Red
#     }
# }

# # --- GH Extensions ---
# Write-Host "`n--- GitHub CLI Extensions ---" -ForegroundColor Cyan
# $ghExtensions = @(
#     @{ Name = "gh-ado2gh"; Repo = "github/gh-ado2gh" },
#     @{ Name = "gh-actions-importer"; Repo = "github/gh-actions-importer" }
# )

# $gh = Get-Command gh -ErrorAction SilentlyContinue
# if ($gh) {
#     $installedExts = gh extension list 2>&1

#     foreach ($ext in $ghExtensions) {
#         if ($installedExts -match $ext.Name) {
#             Write-Host "[OK] $($ext.Name)" -ForegroundColor Green
#         }
#         else {
#             Write-Host "[MISSING] $($ext.Name) — Installing..." -ForegroundColor Yellow
#             gh extension install $ext.Repo 2>&1
#             if ($LASTEXITCODE -eq 0) {
#                 Write-Host "  Installed $($ext.Name)" -ForegroundColor Green
#             }
#             else {
#                 Write-Host "  Failed to install $($ext.Name). Run manually: gh extension install $($ext.Repo)" -ForegroundColor Red
#             }
#         }
#     }

#     # --- Pull latest actions-importer Docker image ---
#     if ($installedExts -match "gh-actions-importer") {
#         Write-Host "`nPulling latest actions-importer image..." -ForegroundColor Yellow
#         gh actions-importer update 2>&1
#         if ($LASTEXITCODE -eq 0) {
#             Write-Host "[OK] actions-importer image updated" -ForegroundColor Green
#         }
#         else {
#             Write-Host "[WARN] Failed to update actions-importer image. Ensure Docker is running." -ForegroundColor Red
#         }
#     }
# }
# else {
#     Write-Host "[SKIP] Cannot check GH extensions — GitHub CLI not installed" -ForegroundColor Yellow
# }

# # --- PAT Configuration Reminder ---
# Write-Host "`n=== Token Configuration ===" -ForegroundColor Cyan
# Write-Host @"
# Create the following Personal Access Tokens:

# 1. Azure DevOps PAT (https://dev.azure.com/YOUR_ORG/_usersSettings/tokens)
#    Scopes: Code (Read), Build (Read & Execute), Release (Read), 
#            Work Items (Read), Project & Team (Read), Graph (Read)

# 2. GitHub PAT (https://github.com/settings/tokens)
#    Scopes: repo, admin:org, workflow, read:packages
#    For GEI: Also needs 'read:enterprise' if enterprise-level migration

# Store tokens securely. NEVER commit them to repos.
# Set as environment variables:
#   `$env:ADO_PAT = 'your-ado-pat'
#   `$env:GH_PAT = 'your-github-pat'
# "@ -ForegroundColor Gray

# Write-Host "`nTooling check complete." -ForegroundColor Cyan



#Added new for token only


<#
.SYNOPSIS
    Installs all required tools for the ADO-to-GitHub migration accelerator.
.DESCRIPTION
    Checks for and installs: GitHub CLI, GEI extension, Actions Importer,
    git-sizer, gitleaks, git-filter-repo, and Docker.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Host "=== Migration Tooling Installer ===" -ForegroundColor Cyan

$tools = @(
    @{
        Name       = "GitHub CLI (gh)"
        Command    = "gh"
        InstallCmd = "winget install --id GitHub.cli -e"
        Url        = "https://cli.github.com"
    },
    @{
        Name       = "Git"
        Command    = "git"
        InstallCmd = "winget install --id Git.Git -e"
        Url        = "https://git-scm.com"
    },
    @{
        Name       = "Docker Desktop"
        Command    = "docker"
        InstallCmd = "winget install --id Docker.DockerDesktop -e"
        Url        = "https://www.docker.com/products/docker-desktop"
    },
    @{
        Name       = "Python (for git-filter-repo)"
        Command    = "python"
        InstallCmd = "winget install --id Python.Python.3.12 -e"
        Url        = "https://python.org"
    },
    @{
        Name       = "git-sizer"
        Command    = "git-sizer"
        InstallCmd = $null
        Url        = "https://github.com/github/git-sizer/releases"
    },
    @{
        Name       = "gitleaks"
        Command    = "gitleaks"
        InstallCmd = "winget install --id Gitleaks.Gitleaks -e"
        Url        = "https://github.com/gitleaks/gitleaks/releases"
    }
)

$results = @()

foreach ($tool in $tools) {
    $cmd = Get-Command $tool.Command -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = ""
        try { $version = & $tool.Command --version 2>&1 | Select-Object -First 1 } catch { }
        Write-Host "[OK] $($tool.Name): $version" -ForegroundColor Green
        $results += @{ Tool = $tool.Name; Status = "Installed"; Version = $version }
    }
    else {
        Write-Host "[MISSING] $($tool.Name)" -ForegroundColor Red
        if ($tool.InstallCmd) {
            Write-Host "  Install: $($tool.InstallCmd)" -ForegroundColor Yellow
        }
        else {
            Write-Host "  Download from: $($tool.Url)" -ForegroundColor Yellow
        }
        $results += @{ Tool = $tool.Name; Status = "Missing"; InstallCmd = $tool.InstallCmd; Url = $tool.Url }
    }
}

# --- Python packages ---
Write-Host "`n--- Python Packages ---" -ForegroundColor Cyan
$pythonPackages = @("git-filter-repo")
foreach ($pkg in $pythonPackages) {
    $installed = pip show $pkg 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] $pkg" -ForegroundColor Green
    }
    else {
        Write-Host "[MISSING] $pkg — Install: pip install $pkg" -ForegroundColor Red
    }
}

# --- GH Extensions ---
Write-Host "`n--- GitHub CLI Extensions ---" -ForegroundColor Cyan
$ghExtensions = @(
    @{ Name = "gh-ado2gh"; Repo = "github/gh-ado2gh" },
    @{ Name = "gh-actions-importer"; Repo = "github/gh-actions-importer" }
)

$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($gh) {
    # Auto-authenticate if token is available in environment
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GH_PAT }
    if ($token) {
        Write-Host "Authenticating GitHub CLI..." -ForegroundColor Gray
        echo $token | gh auth login --with-token 2>&1 | Out-Null
    }

    $installedExts = gh extension list 2>&1

    foreach ($ext in $ghExtensions) {
        if ($installedExts -match $ext.Name) {
            Write-Host "[OK] $($ext.Name)" -ForegroundColor Green
        }
        else {
            Write-Host "[MISSING] $($ext.Name) — Installing..." -ForegroundColor Yellow
            gh extension install $ext.Repo 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Installed $($ext.Name)" -ForegroundColor Green
            }
            else {
                Write-Host "  Failed to install $($ext.Name). Run manually: gh extension install $($ext.Repo)" -ForegroundColor Red
            }
        }
    }

    # --- Pull latest actions-importer Docker image ---
    if ($installedExts -match "gh-actions-importer") {
        Write-Host "`nPulling latest actions-importer image..." -ForegroundColor Yellow
        gh actions-importer update 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] actions-importer image updated" -ForegroundColor Green
        }
        else {
            Write-Host "[WARN] Failed to update actions-importer image. Ensure Docker is running." -ForegroundColor Red
        }
    }
}
else {
    Write-Host "[SKIP] Cannot check GH extensions — GitHub CLI not installed" -ForegroundColor Yellow
}

# --- PAT Configuration Reminder ---
Write-Host "`n=== Token Configuration ===" -ForegroundColor Cyan
Write-Host @"
Create the following Personal Access Tokens:

1. Azure DevOps PAT (https://dev.azure.com/YOUR_ORG/_usersSettings/tokens)
   Scopes: Code (Read), Build (Read & Execute), Release (Read), 
           Work Items (Read), Project & Team (Read), Graph (Read)

2. GitHub PAT (https://github.com/settings/tokens)
   Scopes: repo, admin:org, workflow, read:packages
   For GEI: Also needs 'read:enterprise' if enterprise-level migration

Store tokens securely. NEVER commit them to repos.
Set as environment variables:
  `$env:ADO_PAT = 'your-ado-pat'
  `$env:GH_PAT = 'your-github-pat'
"@ -ForegroundColor Gray

Write-Host "`nTooling check complete." -ForegroundColor Cyan
