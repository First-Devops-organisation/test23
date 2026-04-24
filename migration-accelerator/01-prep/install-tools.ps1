<#
.SYNOPSIS
    Installs all required tools for the ADO-to-GitHub migration accelerator.
.DESCRIPTION
    Checks for and installs: GitHub CLI, GEI extension, Actions Importer,
    git-sizer, gitleaks, git-filter-repo, and Docker.
    Supports both Windows (winget) and Linux (apt/curl) environments.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Host "=== Migration Tooling Installer ===" -ForegroundColor Cyan

$isLinux = $IsLinux -or ($PSVersionTable.Platform -eq "Unix") -or (Test-Path "/usr/bin/apt-get")
$isWindows = -not $isLinux

Write-Host "Platform: $(if ($isLinux) { 'Linux' } else { 'Windows' })" -ForegroundColor Gray

# ============================================================================
# Helper: Install a tool if missing
# ============================================================================
function Install-ToolIfMissing {
    param(
        [string]$Name,
        [string]$Command,
        [scriptblock]$LinuxInstall,
        [string]$WingetId,
        [string]$Url
    )

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = ""
        try { $version = & $Command --version 2>&1 | Select-Object -First 1 } catch { }
        Write-Host "[OK] $Name : $version" -ForegroundColor Green
        return $true
    }

    Write-Host "[MISSING] $Name — Installing..." -ForegroundColor Yellow

    if ($isLinux -and $LinuxInstall) {
        try {
            & $LinuxInstall
            # Verify installation
            $cmd = Get-Command $Command -ErrorAction SilentlyContinue
            if ($cmd) {
                Write-Host "[OK] $Name installed successfully" -ForegroundColor Green
                return $true
            }
            else {
                Write-Host "[FAIL] $Name installation did not produce '$Command' in PATH" -ForegroundColor Red
                return $false
            }
        }
        catch {
            Write-Host "[FAIL] $Name installation error: $_" -ForegroundColor Red
            return $false
        }
    }
    elseif ($isWindows -and $WingetId) {
        try {
            winget install --id $WingetId -e --accept-package-agreements --accept-source-agreements 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] $Name installed via winget" -ForegroundColor Green
                return $true
            }
        }
        catch {
            Write-Host "[FAIL] winget install failed for $Name : $_" -ForegroundColor Red
        }
    }

    Write-Host "[FAIL] Could not auto-install $Name. Download from: $Url" -ForegroundColor Red
    return $false
}

# ============================================================================
# 1. Git
# ============================================================================
Install-ToolIfMissing -Name "Git" -Command "git" `
    -LinuxInstall { sudo apt-get update -qq; sudo apt-get install -y -qq git } `
    -WingetId "Git.Git" `
    -Url "https://git-scm.com"

# ============================================================================
# 2. GitHub CLI
# ============================================================================
Install-ToolIfMissing -Name "GitHub CLI (gh)" -Command "gh" `
    -LinuxInstall {
        # Official GitHub CLI install for Linux
        sudo mkdir -p -m 755 /etc/apt/keyrings 2>$null
        $keyringPath = "/etc/apt/keyrings/githubcli-archive-keyring.gpg"
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee $keyringPath > /dev/null
        sudo chmod go+r $keyringPath
        "deb [arch=$(dpkg --print-architecture) signed-by=$keyringPath] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq gh
    } `
    -WingetId "GitHub.cli" `
    -Url "https://cli.github.com"

# ============================================================================
# 3. Python (for git-filter-repo)
# ============================================================================
$pythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" }
             elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
             else { $null }

if ($pythonCmd) {
    $pyVer = & $pythonCmd --version 2>&1 | Select-Object -First 1
    Write-Host "[OK] Python: $pyVer" -ForegroundColor Green
}
else {
    Write-Host "[MISSING] Python — Installing..." -ForegroundColor Yellow
    if ($isLinux) {
        sudo apt-get update -qq
        sudo apt-get install -y -qq python3 python3-pip
    }
    elseif ($isWindows) {
        winget install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements 2>&1
    }
    $pythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }
}

# ============================================================================
# 4. gitleaks
# ============================================================================
Install-ToolIfMissing -Name "gitleaks" -Command "gitleaks" `
    -LinuxInstall {
        # Download gitleaks release for Linux
        $headers = @{ "User-Agent" = "migration-accelerator" }
        # Use GH_TOKEN if available to avoid rate limits
        $ghToken = $env:GH_TOKEN
        if ($ghToken) {
            $headers["Authorization"] = "Bearer $ghToken"
        }

        $version = ""
        try {
            $releaseUrl = "https://api.github.com/repos/gitleaks/gitleaks/releases/latest"
            $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers
            $version = $release.tag_name -replace "^v", ""
        }
        catch {
            Write-Host "  API rate limited, using known version..." -ForegroundColor Yellow
            $version = "8.21.2"
        }

        $arch = "x64"
        try { if ((uname -m) -eq "aarch64") { $arch = "arm64" } } catch {}

        # Try multiple naming conventions
        $attempts = @(
            "gitleaks_${version}_linux_${arch}.tar.gz",
            "gitleaks_${version}_linux_x86_64.tar.gz",
            "gitleaks_${version}_linux_amd64.tar.gz"
        )

        $downloaded = $false
        foreach ($assetName in $attempts) {
            $downloadUrl = "https://github.com/gitleaks/gitleaks/releases/download/v${version}/${assetName}"
            Write-Host "  Trying: $downloadUrl" -ForegroundColor Gray
            try {
                $tmpFile = "/tmp/gitleaks.tar.gz"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpFile -UseBasicParsing -ErrorAction Stop
                sudo tar -xzf $tmpFile -C /usr/local/bin gitleaks
                sudo chmod +x /usr/local/bin/gitleaks
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                $downloaded = $true
                Write-Host "  Downloaded gitleaks $version" -ForegroundColor Green
                break
            }
            catch {
                Write-Host "  Not found, trying next..." -ForegroundColor Gray
            }
        }

        if (-not $downloaded) {
            throw "Could not download gitleaks for Linux"
        }
    } `
    -WingetId "Gitleaks.Gitleaks" `
    -Url "https://github.com/gitleaks/gitleaks/releases"

# ============================================================================
# 5. git-filter-repo (Python package)
# ============================================================================
Write-Host "`n--- Python Packages ---" -ForegroundColor Cyan

$pipCmd = if (Get-Command pip3 -ErrorAction SilentlyContinue) { "pip3" }
          elseif (Get-Command pip -ErrorAction SilentlyContinue) { "pip" }
          else { $null }

if (-not $pipCmd) {
    Write-Host "[MISSING] pip — attempting install..." -ForegroundColor Yellow
    if ($isLinux) {
        sudo apt-get install -y -qq python3-pip 2>&1 | Out-Null
        $pipCmd = "pip3"
    }
}

$pythonPackages = @("git-filter-repo")
foreach ($pkg in $pythonPackages) {
    $installed = & $pipCmd show $pkg 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] $pkg" -ForegroundColor Green
    }
    else {
        Write-Host "[MISSING] $pkg — Installing..." -ForegroundColor Yellow
        & $pipCmd install $pkg 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] $pkg installed" -ForegroundColor Green
        }
        else {
            Write-Host "[FAIL] Could not install $pkg. Run: $pipCmd install $pkg" -ForegroundColor Red
        }
    }
}

# ============================================================================
# 6. git-sizer
# ============================================================================
Install-ToolIfMissing -Name "git-sizer" -Command "git-sizer" `
    -LinuxInstall {
        $releaseUrl = "https://api.github.com/repos/github/git-sizer/releases/latest"
        $headers = @{ "User-Agent" = "migration-accelerator" }
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers
        $assetName = "git-sizer-linux-amd64"
        $asset = $release.assets | Where-Object { $_.name -like "*linux*amd64*" }

        if ($asset) {
            $downloadUrl = $asset.browser_download_url
            Write-Host "  Downloading git-sizer..." -ForegroundColor Gray
            $tmpFile = "/tmp/git-sizer.zip"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpFile -UseBasicParsing
            sudo unzip -o $tmpFile -d /usr/local/bin 2>&1 | Out-Null
            sudo chmod +x /usr/local/bin/git-sizer
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
        else {
            throw "Could not find git-sizer release asset for Linux"
        }
    } `
    -WingetId $null `
    -Url "https://github.com/github/git-sizer/releases"

# ============================================================================
# 7. Docker (check only — typically pre-installed on CI agents)
# ============================================================================
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $dockerVer = docker --version 2>&1 | Select-Object -First 1
    Write-Host "[OK] Docker: $dockerVer" -ForegroundColor Green
}
else {
    Write-Host "[WARN] Docker not found — required for Actions Importer only" -ForegroundColor Yellow
    Write-Host "  Install: https://www.docker.com/products/docker-desktop" -ForegroundColor Gray
}

# ============================================================================
# 8. GitHub CLI Extensions
# ============================================================================
Write-Host "`n--- GitHub CLI Extensions ---" -ForegroundColor Cyan
$ghExtensions = @(
    @{ Name = "gh-ado2gh"; Repo = "github/gh-ado2gh" },
    @{ Name = "gh-actions-importer"; Repo = "github/gh-actions-importer" }
)

$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($gh) {
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

# ============================================================================
# Summary
# ============================================================================
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

Write-Host "`nTooling installation complete." -ForegroundColor Cyan
