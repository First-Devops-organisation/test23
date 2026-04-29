<#
.SYNOPSIS
    Migrates Azure DevOps Wiki content to GitHub repository wiki.
.DESCRIPTION
    Clones the ADO wiki (which is a Git repo), transforms internal links,
    and pushes to the GitHub repo's wiki. ADO wiki is a Git repository under the hood.
.PARAMETER AdoOrgUrl
    Azure DevOps organization URL
.PARAMETER AdoProject
    ADO project name
.PARAMETER AdoPat
    ADO PAT
.PARAMETER GitHubOrg
    Target GitHub org
.PARAMETER GitHubRepo
    Target GitHub repo
.PARAMETER GitHubPat
    GitHub PAT
.PARAMETER OutputDir
    Temp directory for wiki processing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdoOrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$AdoProject,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $true)]
    [string]$GitHubPat,

    [string]$OutputDir = "./tmp/wiki"
)

$ErrorActionPreference = "Stop"

$adoOrg = ($AdoOrgUrl -replace "https://dev.azure.com/", "").TrimEnd("/")

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host "=== Wiki Migration: $AdoProject ===" -ForegroundColor Cyan

# --- Step 1: Clone ADO Wiki ---
Write-Host "1. Cloning ADO Wiki..." -ForegroundColor Yellow

# ADO project wikis have a specific repo name format
$wikiRepoName = "$AdoProject.wiki"
$wikiCloneUrl = "https://$AdoPat@dev.azure.com/$adoOrg/$AdoProject/_git/$wikiRepoName"
$wikiDir = Join-Path $OutputDir "ado-wiki"

if (Test-Path $wikiDir) { Remove-Item -Recurse -Force $wikiDir }

try {
    git clone $wikiCloneUrl $wikiDir 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Clone failed" }
    Write-Host "   Wiki cloned successfully" -ForegroundColor Green
}
catch {
    Write-Warning "Could not clone project wiki. It may not exist or may be a code wiki."
    Write-Host "Attempting to find code wikis via API..." -ForegroundColor Gray

    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
    $headers = @{ Authorization = "Basic $base64Auth" }
    $wikisUrl = "$AdoOrgUrl/$AdoProject/_apis/wiki/wikis?api-version=7.1"

    try {
        $wikis = (Invoke-RestMethod -Uri $wikisUrl -Headers $headers).value
        Write-Host "   Found $($wikis.Count) wiki(s):" -ForegroundColor Gray
        foreach ($wiki in $wikis) {
            Write-Host "     - $($wiki.name) (Type: $($wiki.type))" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "   No wikis found for this project." -ForegroundColor Yellow
    }

    Write-Host "   Skipping wiki migration." -ForegroundColor Yellow
    exit 0
}

# --- Step 2: Transform Links ---
Write-Host "2. Transforming internal links..." -ForegroundColor Yellow

$mdFiles = Get-ChildItem -Path $wikiDir -Filter "*.md" -Recurse
$linkTransformCount = 0

foreach ($mdFile in $mdFiles) {
    $content = Get-Content $mdFile.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $original = $content

    # Transform ADO wiki links: /ProjectName/_wiki/wikis/... → relative links
    $content = $content -replace "\(/[^)]*/_wiki/wikis/[^/]+/\d+/([^)]+)\)", '($1)'

    # Replace %2D with - (ADO encodes hyphens in wiki page names)
    $content = $content -replace "%2D", "-"

    # Replace %20 with - (GitHub wiki uses dashes for spaces)
    $content = $content -replace "%20", "-"

    # Fix ADO-style attachments links
    $content = $content -replace "!\[([^\]]*)\]\(/.attachments/([^)]+)\)", '![$1](/.attachments/$2)'

    if ($content -ne $original) {
        $content | Set-Content $mdFile.FullName -NoNewline
        $linkTransformCount++
    }
}

Write-Host "   Transformed links in $linkTransformCount files" -ForegroundColor Green

# --- Step 3: Handle Attachments ---
Write-Host "3. Processing attachments..." -ForegroundColor Yellow
$attachDir = Join-Path $wikiDir ".attachments"
if (Test-Path $attachDir) {
    $attachCount = (Get-ChildItem $attachDir -Recurse -File).Count
    Write-Host "   Found $attachCount attachments" -ForegroundColor Gray
}
else {
    Write-Host "   No attachments directory found" -ForegroundColor Gray
}

# --- Step 4: Initialize GitHub Wiki ---
Write-Host "4. Pushing to GitHub Wiki..." -ForegroundColor Yellow

# GitHub wikis must be initialized first (create at least one page via UI or API)
Write-Host "   NOTE: GitHub wiki must be enabled on the repo first." -ForegroundColor Yellow
Write-Host "   Go to https://github.com/$GitHubOrg/$GitHubRepo/wiki and create the first page." -ForegroundColor Yellow

$ghWikiUrl = "https://$GitHubPat@github.com/$GitHubOrg/$GitHubRepo.wiki.git"
$ghWikiDir = Join-Path $OutputDir "gh-wiki"

if (Test-Path $ghWikiDir) { Remove-Item -Recurse -Force $ghWikiDir }

try {
    git clone $ghWikiUrl $ghWikiDir 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not clone GitHub wiki. Initialize it first via the GitHub UI." }
}
catch {
    Write-Warning $_
    Write-Host "Create the GitHub wiki first, then re-run this script." -ForegroundColor Red
    exit 1
}

# Copy ADO wiki content to GitHub wiki
$filesToCopy = Get-ChildItem -Path $wikiDir -Recurse -File | Where-Object { $_.FullName -notmatch "\.git[\\/]" }
foreach ($file in $filesToCopy) {
    $relativePath = $file.FullName.Substring($wikiDir.Length + 1)
    $destPath = Join-Path $ghWikiDir $relativePath
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item $file.FullName $destPath -Force
}

# Commit and push
Push-Location $ghWikiDir
git add -A
git commit -m "Migrated wiki from Azure DevOps ($AdoProject)" 2>&1
git push origin master 2>&1
Pop-Location

Write-Host "   Wiki pushed to GitHub" -ForegroundColor Green

# --- Summary ---
Write-Host "`n=== Wiki Migration Summary ===" -ForegroundColor Cyan
Write-Host "Pages migrated: $($mdFiles.Count)" -ForegroundColor Green
Write-Host "Links transformed: $linkTransformCount" -ForegroundColor Green
Write-Host "Wiki URL: https://github.com/$GitHubOrg/$GitHubRepo/wiki" -ForegroundColor Green

Write-Host "`n=== LIMITATIONS ===" -ForegroundColor Yellow
Write-Host @"
- Wiki page order/hierarchy may differ (GitHub uses alphabetical)
- Mermaid diagrams may need syntax adjustments
- ADO-specific macros (TOC, query results) will not render
- Page revision history is preserved in Git but not in GitHub wiki UI
- Nested page structure may flatten (GitHub wiki is flat with sidebar)
"@ -ForegroundColor Gray

# Cleanup
if (Test-Path $OutputDir) { Remove-Item -Recurse -Force $OutputDir -ErrorAction SilentlyContinue }
