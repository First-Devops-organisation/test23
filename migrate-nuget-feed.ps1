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

# --- 1. Debug: Show incoming values ---
Write-Host "=== Migration Diagnostics ===" -ForegroundColor Yellow
Write-Host "  Raw AdoOrg: $AdoOrg"
Write-Host "  Raw AdoProject: '$AdoProject'"
Write-Host "  Raw AdoFeed: $AdoFeed"
Write-Host "  Raw GH Org: $GitHubOrg"
Write-Host "  PAT Length: $($AdoPat.Length) chars"
Write-Host "=============================" -ForegroundColor Yellow

# --- 2. Clean Organization Name ---
$cleanOrg = $AdoOrg.TrimEnd('/')
if ($cleanOrg -like "*dev.azure.com*") {
    $cleanOrg = $cleanOrg.Split('/')[-1]
}

# --- 3. Setup Auth ---
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ 
    Authorization = "Basic $base64AdoAuth"
    "X-TFS-FedAuthRedirect" = "Suppress"
}

Write-Host "`n=== NuGet Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan

# --- 4. Auto-Discover Feed Location ---
$potentialUrls = @()
if (-not [string]::IsNullOrWhiteSpace($AdoProject)) {
    $potentialUrls += "https://pkgs.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed"
}
$potentialUrls += "https://pkgs.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed"

$baseUrl = $null
$packages = $null

Write-Host "[Step 1] Discovering Feed Location..." -ForegroundColor Gray
foreach ($url in $potentialUrls) {
    try {
        Write-Host "   Checking: $url" -ForegroundColor DarkGray
        $response = Invoke-RestMethod -Uri "$url/packages?api-version=7.1-preview.1" -Headers $adoHeaders -Method Get
        $packages = $response.value
        $baseUrl = $url
        Write-Host "   [FOUND] Feed discovered at this location!" -ForegroundColor Green
        break
    }
    catch {
        Write-Host "   [SKIP] Not found or unauthorized at this URL. (Status: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

if (-not $baseUrl) {
    Write-Host "`n[ERROR] Could not connect to the feed at any location." -ForegroundColor Red
    Write-Host "Possibility 1: The PAT scope 'Packaging (Read)' is missing." -ForegroundColor Yellow
    Write-Host "Possibility 2: The Feed Name '$AdoFeed' is wrong." -ForegroundColor Yellow
    Write-Host "Possibility 3: You have no access to the feed settings." -ForegroundColor Yellow
    exit 1
}

# --- 5. Process Packages ---
Write-Host "   Found $($packages.Count) packages in feed." -ForegroundColor Green

$tempDir = Join-Path $PSScriptRoot "temp_nuget_migration"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

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

        $downloadUrl = "$baseUrl/nuget/packages/$pkgName/versions/$pkgVer/content"
        Write-Host "       Downloading..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -Headers $adoHeaders

        # Push to GitHub
        Write-Host "       Pushing to GitHub Packages..." -ForegroundColor Gray
        $ghSourceUrl = "https://nuget.pkg.github.com/$GitHubOrg/index.json"
        
        try {
            dotnet nuget push $filePath --source $ghSourceUrl --api-key $GitHubPat --skip-duplicate
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
