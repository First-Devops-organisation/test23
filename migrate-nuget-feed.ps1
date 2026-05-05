<#
.SYNOPSIS
    Migrates NuGet packages from Azure Artifacts Feed to GitHub Packages.
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
# Packaging API sometimes prefers basic auth with a clear 'Basic' prefix
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ 
    Authorization = "Basic $base64AdoAuth"
    "X-TFS-FedAuthRedirect" = "Suppress" # Prevents redirecting to login page on 401
}

# --- 3. Create Temp Directory ---
$tempDir = Join-Path $PSScriptRoot "temp_nuget_migration"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

Write-Host "=== NuGet Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan
Write-Host "   ADO Org: $cleanOrg" -ForegroundColor Gray

# --- 4. Construct Base URL ---
$baseUrl = if ($AdoProject) { 
    "https://pkgs.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed"
} else {
    "https://pkgs.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed"
}

# --- 5. Get List of Packages ---
Write-Host "[Step 1] Fetching package list from ADO..." -ForegroundColor Gray
$packagesUrl = "$baseUrl/packages?api-version=7.1-preview.1"

try {
    $packagesResponse = Invoke-RestMethod -Uri $packagesUrl -Headers $adoHeaders -Method Get
    $packages = $packagesResponse.value
}
catch {
    Write-Host "`n[ERROR] Authentication Failed (401)." -ForegroundColor Red
    Write-Host "1. Please check that your ADO_PAT has 'Packaging (Read)' scope enabled." -ForegroundColor Yellow
    Write-Host "2. Current Org used: $cleanOrg" -ForegroundColor White
    Write-Host "3. URL attempted: $packagesUrl" -ForegroundColor White
    Write-Error "Migration stopped due to authentication failure."
    exit 1
}

Write-Host "   Found $($packages.Count) packages in feed." -ForegroundColor Green

foreach ($pkg in $packages) {
    $pkgName = $pkg.name
    Write-Host "`nProcessing Package: $pkgName" -ForegroundColor Yellow

    $versionsUrl = "$baseUrl/packages/$($pkg.id)/versions?api-version=7.1-preview.1"
    $versions = (Invoke-RestMethod -Uri $versionsUrl -Headers $adoHeaders).value

    foreach ($ver in $versions) {
        $pkgVer = $ver.version
        $fileName = "$pkgName.$pkgVer.nupkg"
        $filePath = Join-Path $tempDir $fileName

        Write-Host "   --> Version $pkgVer" -ForegroundColor Gray

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

        Remove-Item $filePath -Force
    }
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== Feed Migration Complete! ===" -ForegroundColor Cyan
