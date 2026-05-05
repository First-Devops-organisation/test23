<#
.SYNOPSIS
    Migrates NuGet packages from Azure Artifacts Feed to GitHub Packages.
.PARAMETER AdoOrg
    Azure DevOps Organization name.
.PARAMETER AdoFeed
    Source Feed Name or ID.
.PARAMETER AdoPat
    ADO PAT with Packaging (Read) scope.
.PARAMETER GitHubOrg
    Target GitHub Organization name.
.PARAMETER GitHubPat
    GitHub PAT with write:packages scope.
#>
param(
    [Parameter(Mandatory = $true)] [string]$AdoOrg,
    [Parameter(Mandatory = $true)] [string]$AdoFeed,
    [Parameter(Mandatory = $true)] [string]$AdoPat,
    [Parameter(Mandatory = $true)] [string]$GitHubOrg,
    [Parameter(Mandatory = $true)] [string]$GitHubPat
)

$ErrorActionPreference = "Stop"

# --- 1. Setup Auth ---
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ Authorization = "Basic $base64AdoAuth" }

# --- 2. Create Temp Directory ---
$tempDir = Join-Path $PSScriptRoot "temp_nuget_migration"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

Write-Host "=== NuGet Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan

# --- 3. Get List of Packages ---
Write-Host "[Step 1] Fetching package list from ADO..." -ForegroundColor Gray
$packagesUrl = "https://pkgs.dev.azure.com/$AdoOrg/_apis/packaging/feeds/$AdoFeed/packages?api-version=7.1-preview.1"
$packages = (Invoke-RestMethod -Uri $packagesUrl -Headers $adoHeaders).value

Write-Host "   Found $($packages.Count) packages in feed." -ForegroundColor Green

foreach ($pkg in $packages) {
    $pkgName = $pkg.name
    Write-Host "`nProcessing Package: $pkgName" -ForegroundColor Yellow

    # Get all versions for this package
    $versionsUrl = "https://pkgs.dev.azure.com/$AdoOrg/_apis/packaging/feeds/$AdoFeed/packages/$($pkg.id)/versions?api-version=7.1-preview.1"
    $versions = (Invoke-RestMethod -Uri $versionsUrl -Headers $adoHeaders).value

    foreach ($ver in $versions) {
        $pkgVer = $ver.version
        $fileName = "$pkgName.$pkgVer.nupkg"
        $filePath = Join-Path $tempDir $fileName

        Write-Host "   --> Version $pkgVer" -ForegroundColor Gray

        # --- 4. Download .nupkg ---
        $downloadUrl = "https://pkgs.dev.azure.com/$AdoOrg/_apis/packaging/feeds/$AdoFeed/nuget/packages/$pkgName/versions/$pkgVer/content"
        Write-Host "       Downloading..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -Headers $adoHeaders

        # --- 5. Push to GitHub ---
        Write-Host "       Pushing to GitHub Packages..." -ForegroundColor Gray
        
        # Add GitHub as a source if not exists
        # NOTE: Using --api-key for GitHub requires the PAT
        $ghSourceUrl = "https://nuget.pkg.github.com/$GitHubOrg/index.json"
        
        try {
            dotnet nuget push $filePath `
                --source $ghSourceUrl `
                --api-key $GitHubPat `
                --skip-duplicate
            
            Write-Host "       [SUCCESS] Migrated $fileName" -ForegroundColor Green
        }
        catch {
            Write-Warning "       [FAILED] Could not push ${fileName}: $($_.Exception.Message)"
        }

        # Cleanup file after push to save space
        Remove-Item $filePath -Force
    }
}

# Cleanup
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== Feed Migration Complete! ===" -ForegroundColor Cyan
