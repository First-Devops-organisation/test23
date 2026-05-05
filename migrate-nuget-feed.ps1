<#
.SYNOPSIS
    Migrates NuGet packages from Azure Artifacts Feed to GitHub Packages.
.PARAMETER AdoOrg
    Azure DevOps Organization name or URL.
.PARAMETER AdoProject
    Azure DevOps Project name (optional for Org-scoped feeds).
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
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ Authorization = "Basic $base64AdoAuth" }

# --- 3. Create Temp Directory ---
$tempDir = Join-Path $PSScriptRoot "temp_nuget_migration"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

Write-Host "=== NuGet Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan
Write-Host "   ADO Org: $cleanOrg" -ForegroundColor Gray
if ($AdoProject) { Write-Host "   ADO Project: $AdoProject" -ForegroundColor Gray }

# --- 4. Construct Base URL ---
# If project is provided, use project-scoped URL, otherwise Org-scoped
$baseUrl = if ($AdoProject) { 
    "https://pkgs.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed"
} else {
    "https://pkgs.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed"
}

# --- 5. Get List of Packages ---
Write-Host "[Step 1] Fetching package list from ADO..." -ForegroundColor Gray
$packagesUrl = "$baseUrl/packages?api-version=7.1-preview.1"

try {
    $packagesResponse = Invoke-RestMethod -Uri $packagesUrl -Headers $adoHeaders
    $packages = $packagesResponse.value
}
catch {
    Write-Error "Failed to connect to ADO Packaging API. Error: $($_.Exception.Message)"
    Write-Host "Try checking if the feed is Project-scoped or Org-scoped." -ForegroundColor Yellow
    exit 1
}

Write-Host "   Found $($packages.Count) packages in feed." -ForegroundColor Green

foreach ($pkg in $packages) {
    $pkgName = $pkg.name
    Write-Host "`nProcessing Package: $pkgName" -ForegroundColor Yellow

    # Get all versions for this package
    $versionsUrl = "$baseUrl/packages/$($pkg.id)/versions?api-version=7.1-preview.1"
    $versions = (Invoke-RestMethod -Uri $versionsUrl -Headers $adoHeaders).value

    foreach ($ver in $versions) {
        $pkgVer = $ver.version
        $fileName = "$pkgName.$pkgVer.nupkg"
        $filePath = Join-Path $tempDir $fileName

        Write-Host "   --> Version $pkgVer" -ForegroundColor Gray

        # --- 6. Download .nupkg ---
        # Note: Download URL format also changes for project-scoped feeds
        $downloadUrl = if ($AdoProject) {
            "https://pkgs.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed/nuget/packages/$pkgName/versions/$pkgVer/content"
        } else {
            "https://pkgs.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed/nuget/packages/$pkgName/versions/$pkgVer/content"
        }

        Write-Host "       Downloading..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -Headers $adoHeaders

        # --- 7. Push to GitHub ---
        Write-Host "       Pushing to GitHub Packages..." -ForegroundColor Gray
        $ghSourceUrl = "https://nuget.pkg.github.com/$GitHubOrg/index.json"
        
        try {
            dotnet nuget push $filePath `
                --source $ghSourceUrl `
                --api-key $GitHubPat `
                --skip-duplicate
            
            Write-Host "       [SUCCESS] Migrated ${fileName}" -ForegroundColor Green
        }
        catch {
            Write-Warning "       [FAILED] Could not push ${fileName}: $($_.Exception.Message)"
        }

        # Cleanup file after push
        Remove-Item $filePath -Force
    }
}

# Cleanup
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== Feed Migration Complete! ===" -ForegroundColor Cyan
