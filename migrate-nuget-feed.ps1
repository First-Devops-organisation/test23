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
$base64AdoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$adoHeaders = @{ 
    Authorization = "Basic $base64AdoAuth"
    "X-TFS-FedAuthRedirect" = "Suppress"
}

Write-Host "=== NuGet Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan

# --- 3. Auto-Discover Feed Location ---
$potentialUrls = @()
if ($AdoProject) {
    $potentialUrls += "https://pkgs.dev.azure.com/$cleanOrg/$AdoProject/_apis/packaging/feeds/$AdoFeed"
}
$potentialUrls += "https://pkgs.dev.azure.com/$cleanOrg/_apis/packaging/feeds/$AdoFeed"

$baseUrl = $null
$packages = $null

Write-Host "[Step 1] Discovering Feed Location..." -ForegroundColor Gray
foreach ($url in $potentialUrls) {
    try {
        Write-Host "   Trying: $url" -ForegroundColor DarkGray
        $response = Invoke-RestMethod -Uri "$url/packages?api-version=7.1-preview.1" -Headers $adoHeaders -Method Get
        $packages = $response.value
        $baseUrl = $url
        Write-Host "   [FOUND] Feed discovered at this location!" -ForegroundColor Green
        break
    }
    catch {
        Write-Host "   [SKIP] Not found or unauthorized at this URL." -ForegroundColor DarkGray
    }
}

if (-not $baseUrl) {
    Write-Host "`n[ERROR] Could not connect to the feed at any location." -ForegroundColor Red
    Write-Host "Please verify:" -ForegroundColor Yellow
    Write-Host "1. Your PAT has 'Packaging (Read)' scope." -ForegroundColor White
    Write-Host "2. The Feed Name '$AdoFeed' is exactly correct (case-sensitive)." -ForegroundColor White
    Write-Host "3. You have 'Reader' or 'Collaborator' permission on the feed itself." -ForegroundColor White
    exit 1
}

# --- 4. Process Packages ---
Write-Host "   Found $($packages.Count) packages in feed." -ForegroundColor Green

# Temp Dir
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

        # Download URL matches the base URL we discovered
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
