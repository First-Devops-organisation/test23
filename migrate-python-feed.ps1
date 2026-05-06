<#
.SYNOPSIS
    Migrates Python (PyPI) packages from Azure Artifacts Feed to GitHub Packages.
#>
param(
    [Parameter(Mandatory = $true)] [string]$AdoOrg,
    [Parameter(Mandatory = $false)] [string]$AdoProject,
    [Parameter(Mandatory = $true)] [string]$AdoFeed,
    [Parameter(Mandatory = $true)] [string]$AdoPat,
    [Parameter(Mandatory = $true)] [string]$GitHubOrg,
    [Parameter(Mandatory = $true)] [string]$GitHubPat
)

$ErrorActionPreference = "Stop"

# --- 1. Clean Organization Name ---
$cleanOrg = $AdoOrg.TrimEnd('/')
if ($cleanOrg -like "*dev.azure.com*") {
    $cleanOrg = $cleanOrg.Split('/')[-1]
}

# --- 2. Setup Auth ---
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$AdoPat"))
$adoHeaders = @{ 
    Authorization = "Basic $base64AdoAuth"
    "X-TFS-FedAuthRedirect" = "Suppress"
}

Write-Host "=== Python Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan

# --- 3. Auto-Discover Feed Location ---
$potentialUrls = @()
if (-not [string]::IsNullOrWhiteSpace($AdoProject)) {
    $potentialUrls += "https://pkgs.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed"
    $potentialUrls += "https://feeds.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed"
}
$potentialUrls += "https://pkgs.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed"
$potentialUrls += "https://feeds.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed"

$baseUrl = $null
$packages = $null

Write-Host "[Step 1] Discovering Feed Location..." -ForegroundColor Gray
foreach ($url in $potentialUrls) {
    try {
        $response = Invoke-RestMethod -Uri "$url/packages?api-version=7.1-preview.1" -Headers $adoHeaders -Method Get
        $packages = $response.value
        $baseUrl = $url
        Write-Host "   [FOUND] Feed discovered at: $url" -ForegroundColor Green
        break
    }
    catch {
        # Continue searching
    }
}

if (-not $baseUrl) {
    Write-Error "Could not connect to the Python feed. Check PAT and Feed Name."
    exit 1
}

# --- 4. Process Packages ---
Write-Host "`n[Step 2] Processing packages..." -ForegroundColor Gray
$tempDir = Join-Path $PSScriptRoot "temp_python_migration"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

foreach ($pkg in $packages) {
    $pkgName = $pkg.name
    Write-Host "`nProcessing Package: $pkgName" -ForegroundColor Yellow

    $versionsUrl = "$baseUrl/packages/$($pkg.id)/versions?api-version=7.1-preview.1"
    $versions = (Invoke-RestMethod -Uri $versionsUrl -Headers $adoHeaders).value
    # Sort versions ascending
    $versions = $versions | Sort-Object { $_.version }

    foreach ($ver in $versions) {
        $pkgVer = $ver.version
        $downloadUrl = $null # CRITICAL: Clear variable for each loop
        Write-Host "   --> Version $pkgVer" -ForegroundColor Gray

        # 4. Use the PyPI 'Simple Index' to find the actual file URL (Avoid pip build errors)
        $normalizedPkgName = $pkgName.ToLower().Replace(".", "-").Replace("_", "-")
        $simpleBase = $baseUrl.Replace("feeds.dev.azure.com", "pkgs.dev.azure.com").Replace("_apis/packaging/feeds", "_packaging")
        $simpleUrl = "$simpleBase/pypi/simple/$normalizedPkgName/"
        
        Write-Host "       Checking Simple Index: $simpleUrl" -ForegroundColor DarkGray
        try {
            $simplePage = Invoke-WebRequest -Uri $simpleUrl -Headers $adoHeaders -UseBasicParsing
            
            # Match <a href="..."> containing the version number. Handles both single and double quotes.
            $pattern = 'href=["'']([^"'']+)["''][^>]*>[^<]*' + [regex]::Escape($pkgVer)
            
            if ($simplePage.Content -match $pattern) {
                $downloadUrl = $matches[1].Split('#')[0]
                if ($downloadUrl -notlike "http*") {
                    $downloadUrl = "$simpleUrl$downloadUrl"
                }
            } else {
                Write-Warning "       [SKIP] Could not find version $pkgVer in Simple Index HTML."
                continue
            }
        } catch {
             Write-Warning "       [SKIP] Could not access Simple Index for $pkgName. (Error: $($_.Exception.Message))"
             continue
        }

        # Determine a generic filename for twine
        $filePath = Join-Path $tempDir "$pkgName-$pkgVer.pkg"
        
        Write-Host "       Downloading from: $downloadUrl" -ForegroundColor DarkGray
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -Headers $adoHeaders
            Write-Host "       [SUCCESS] Downloaded successfully." -ForegroundColor DarkGray
        } catch {
            Write-Warning "       [SKIP] Could not download file. (Error: $($_.Exception.Message))"
            continue
        }

        # --- 5. Push to GitHub using Twine ---
        Write-Host "       Pushing to GitHub PyPI..." -ForegroundColor Gray
        $ghPyPiUrl = "https://pypi.pkg.github.com/$GitHubOrg/"
        
        $env:TWINE_USERNAME = "token"
        $env:TWINE_PASSWORD = $GitHubPat
        $env:TWINE_REPOSITORY_URL = $ghPyPiUrl

        # GitHub Packages does not support --skip-existing. We catch the 409 Conflict manually.
        $twineOutput = twine upload $filePath --non-interactive 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host "       [SUCCESS] Migrated $pkgName $pkgVer" -ForegroundColor Green
        } elseif ($twineOutput -match "409" -or $twineOutput -match "Conflict" -or $twineOutput -match "already exists") {
            Write-Host "       [SKIP] $pkgName $pkgVer already exists on GitHub." -ForegroundColor DarkGray
        } else {
            Write-Warning "       [FAILED] Could not push ${pkgName} ${pkgVer}: $twineOutput"
        }

        Remove-Item $filePath -Force
    }
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== Python Feed Migration Complete! ===" -ForegroundColor Cyan
