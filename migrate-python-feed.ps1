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

        # 4. Use 'pip download' to fetch the package (most reliable way)
        $simpleUrl = "$($baseUrl.Replace('feeds.dev.azure.com', 'pkgs.dev.azure.com').Replace('_apis/packaging/feeds', '_packaging'))/pypi/simple/"
        $authUrl = $simpleUrl.Replace("https://", "https://token:$($AdoPat)@")
        
        Write-Host "       Downloading via pip..." -ForegroundColor DarkGray
        try {
            # Download into the temp directory
            pip download "${pkgName}==${pkgVer}" --index-url $authUrl --dest $tempDir --no-deps --quiet
            
            # Find the file that was just downloaded
            $downloadedFile = Get-ChildItem $tempDir | Where-Object { $_.Name -like "*$pkgVer*" } | Select-Object -First 1
            if ($downloadedFile) {
                $filePath = $downloadedFile.FullName
                Write-Host "       [SUCCESS] Downloaded: $($downloadedFile.Name)" -ForegroundColor DarkGray
            } else {
                throw "File not found after pip download"
            }
        } catch {
            Write-Warning "       [SKIP] Pip could not download version $pkgVer. (Error: $($_.Exception.Message))"
            continue
        }

        # --- 5. Push to GitHub using Twine ---
        Write-Host "       Pushing to GitHub PyPI..." -ForegroundColor Gray
        $ghPyPiUrl = "https://pypi.pkg.github.com/$GitHubOrg/"
        
        # Twine requires username/password. For GitHub, username can be anything (using 'token')
        # We use environment variables for safety
        $env:TWINE_USERNAME = "token"
        $env:TWINE_PASSWORD = $GitHubPat
        $env:TWINE_REPOSITORY_URL = $ghPyPiUrl

        try {
            # --skip-existing is the equivalent of --skip-duplicate for twine
            twine upload $filePath --skip-existing --non-interactive
            Write-Host "       [SUCCESS] Migrated $pkgName $pkgVer" -ForegroundColor Green
        }
        catch {
            Write-Warning "       [FAILED] Could not push ${pkgName} ${pkgVer}: $($_.Exception.Message)"
        }

        Remove-Item $filePath -Force
    }
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== Python Feed Migration Complete! ===" -ForegroundColor Cyan
