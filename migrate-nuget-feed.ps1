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

# --- 2. Setup Multiple Auth Strategies ---
$auth1 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$AdoPat"))
$auth2 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("user:$AdoPat"))

$strategies = @(
    @{ name = "Standard (:PAT)"; headers = @{ Authorization = "Basic $auth1"; "User-Agent" = "Mozilla/5.0"; "X-TFS-FedAuthRedirect" = "Suppress" } },
    @{ name = "Alt (user:PAT)"; headers = @{ Authorization = "Basic $auth2"; "User-Agent" = "Mozilla/5.0"; "X-TFS-FedAuthRedirect" = "Suppress" } }
)

Write-Host "=== NuGet Feed Migration: $AdoFeed -> $GitHubOrg ===" -ForegroundColor Cyan

# --- 3. Auto-Discover Feed Location & Auth Strategy ---
# We try both pkgs. and feeds. subdomains
$domains = @("pkgs.dev.azure.com", "feeds.dev.azure.com")
$potentialPaths = @()
if (-not [string]::IsNullOrWhiteSpace($AdoProject)) {
    $potentialPaths += "$AdoProject/_apis/packaging/feeds/$AdoFeed"
}
$potentialPaths += "_apis/packaging/feeds/$AdoFeed"

$baseUrl = $null
$packages = $null
$winningHeaders = $null

Write-Host "[Step 1] Discovering Feed & Auth Strategy..." -ForegroundColor Gray

foreach ($domain in $domains) {
    foreach ($path in $potentialPaths) {
        $url = "https://$domain/$cleanOrg/$path"
        Write-Host "`n   Checking Location: $url" -ForegroundColor DarkGray
        
        foreach ($strategy in $strategies) {
            try {
                Write-Host "      Trying Strategy: $($strategy.name)" -ForegroundColor DarkGray
                $testUrl = "$url/packages?api-version=7.1-preview.1"
                $response = Invoke-RestMethod -Uri $testUrl -Headers $strategy.headers -Method Get
                
                $packages = $response.value
                $baseUrl = $url
                $winningHeaders = $strategy.headers
                Write-Host "      [SUCCESS] Authenticated and found feed!" -ForegroundColor Green
                break
            }
            catch {
                # Silently continue to next strategy
            }
        }
        if ($baseUrl) { break }
    }
    if ($baseUrl) { break }
}

if (-not $baseUrl) {
    Write-Host "`n[ERROR] All 4 authentication attempts failed." -ForegroundColor Red
    Write-Host "DEBUG INFO:" -ForegroundColor Yellow
    Write-Host " - Org: $cleanOrg"
    Write-Host " - Feed: $AdoFeed"
    Write-Host " - PAT Length: $($AdoPat.Length)"
    Write-Error "Please check if your Organization Name '$cleanOrg' is exactly correct in your variables."
    exit 1
}

# --- 4. Process Packages ---
Write-Host "`n[Step 2] Processing packages..." -ForegroundColor Gray
Write-Host "   Found $($packages.Count) packages in feed." -ForegroundColor Green

$tempDir = Join-Path $PSScriptRoot "temp_nuget_migration"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

foreach ($pkg in $packages) {
    $pkgName = $pkg.name
    Write-Host "`nProcessing Package: $pkgName" -ForegroundColor Yellow

    $versionsUrl = "$baseUrl/packages/$($pkg.id)/versions?api-version=7.1-preview.1"
    $versions = (Invoke-RestMethod -Uri $versionsUrl -Headers $winningHeaders).value

    foreach ($ver in $versions) {
        $pkgVer = $ver.version
        $fileName = "$pkgName.$pkgVer.nupkg"
        $filePath = Join-Path $tempDir $fileName

        Write-Host "   --> Version $pkgVer" -ForegroundColor Gray

        $downloadUrl = "$baseUrl/nuget/packages/$pkgName/versions/$pkgVer/content"

        Write-Host "       Downloading..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -Headers $winningHeaders

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
