<#
.SYNOPSIS
    Enables GitHub Advanced Security features on migrated repositories.
.DESCRIPTION
    Enables Dependabot alerts, Dependabot security updates, CodeQL code scanning,
    secret scanning, and push protection across all repos in the org.
    Critical for SOC 2 compliance in bank environments.
.PARAMETER ConfigFile
    Path to migration-config.json
.PARAMETER EnableCodeQL
    Create default CodeQL workflow files
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [switch]$EnableCodeQL
)

$ErrorActionPreference = "Stop"

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$ghOrg = $config.target.organization
$ghPat = if ($config.target.pat) { $config.target.pat } else { $env:GH_PAT }

$headers = @{
    Authorization          = "Bearer $ghPat"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

Write-Host "=== Enable GHAS (GitHub Advanced Security) ===" -ForegroundColor Cyan

# --- Get all repos ---
$page = 1
$allRepos = @()
do {
    $repos = Invoke-RestMethod -Uri "https://api.github.com/orgs/$ghOrg/repos?per_page=100&page=$page" -Headers $headers
    $allRepos += $repos
    $page++
} while ($repos.Count -eq 100)

Write-Host "Processing $($allRepos.Count) repositories..." -ForegroundColor Yellow

$results = @()

foreach ($repo in $allRepos) {
    $repoName = $repo.name
    Write-Host "`n  $repoName" -ForegroundColor Yellow

    $repoResult = @{ Repo = $repoName }

    # --- 1. Enable GHAS (required for private/internal repos) ---
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$repoName" `
            -Headers $headers -Method Patch -ContentType "application/json" `
            -Body (@{ security_and_analysis = @{
                        advanced_security = @{ status = "enabled" }
                    } } | ConvertTo-Json -Depth 5) | Out-Null
        Write-Host "    [OK] GHAS enabled" -ForegroundColor Green
        $repoResult.GHAS = "enabled"
    }
    catch {
        Write-Warning "    GHAS enable failed (may require enterprise license): $_"
        $repoResult.GHAS = "failed"
    }

    # --- 2. Enable Dependabot Alerts ---
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$repoName/vulnerability-alerts" `
            -Headers $headers -Method Put | Out-Null
        Write-Host "    [OK] Dependabot alerts enabled" -ForegroundColor Green
        $repoResult.Dependabot = "enabled"
    }
    catch {
        Write-Warning "    Dependabot alerts failed: $_"
        $repoResult.Dependabot = "failed"
    }

    # --- 3. Enable Secret Scanning ---
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$repoName" `
            -Headers $headers -Method Patch -ContentType "application/json" `
            -Body (@{ security_and_analysis = @{
                        secret_scanning = @{ status = "enabled" }
                        secret_scanning_push_protection = @{ status = "enabled" }
                    } } | ConvertTo-Json -Depth 5) | Out-Null
        Write-Host "    [OK] Secret scanning + push protection enabled" -ForegroundColor Green
        $repoResult.SecretScanning = "enabled"
        $repoResult.PushProtection = "enabled"
    }
    catch {
        Write-Warning "    Secret scanning failed: $_"
        $repoResult.SecretScanning = "failed"
    }

    # --- 4. Enable CodeQL (create workflow file) ---
    if ($EnableCodeQL) {
        # Detect primary language
        try {
            $languages = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$repoName/languages" -Headers $headers
            $primaryLang = ($languages.PSObject.Properties | Sort-Object { $_.Value } -Descending | Select-Object -First 1).Name

            $codeqlLanguage = switch ($primaryLang) {
                "C#"         { "csharp" }
                "JavaScript" { "javascript-typescript" }
                "TypeScript" { "javascript-typescript" }
                "Python"     { "python" }
                "Java"       { "java-kotlin" }
                "Kotlin"     { "java-kotlin" }
                "Go"         { "go" }
                "Ruby"       { "ruby" }
                "Swift"      { "swift" }
                "C"          { "c-cpp" }
                "C++"        { "c-cpp" }
                default      { $null }
            }

            if ($codeqlLanguage) {
                Write-Host "    Primary language: $primaryLang → CodeQL: $codeqlLanguage" -ForegroundColor Gray

                # Enable default setup via API
                try {
                    Invoke-RestMethod `
                        -Uri "https://api.github.com/repos/$ghOrg/$repoName/code-scanning/default-setup" `
                        -Headers $headers -Method Patch -ContentType "application/json" `
                        -Body (@{ state = "configured"; languages = @($codeqlLanguage) } | ConvertTo-Json) | Out-Null
                    Write-Host "    [OK] CodeQL default setup enabled" -ForegroundColor Green
                    $repoResult.CodeQL = "enabled ($codeqlLanguage)"
                }
                catch {
                    Write-Warning "    CodeQL default setup failed: $_"
                    $repoResult.CodeQL = "failed"
                }
            }
            else {
                Write-Host "    No supported CodeQL language detected ($primaryLang)" -ForegroundColor Gray
                $repoResult.CodeQL = "unsupported language"
            }
        }
        catch {
            Write-Warning "    Could not detect language: $_"
            $repoResult.CodeQL = "error"
        }
    }

    $results += [PSCustomObject]$repoResult
}

# --- Summary ---
Write-Host "`n=== GHAS Enablement Summary ===" -ForegroundColor Cyan
$ghasOk = ($results | Where-Object { $_.GHAS -eq "enabled" }).Count
$depOk = ($results | Where-Object { $_.Dependabot -eq "enabled" }).Count
$ssOk = ($results | Where-Object { $_.SecretScanning -eq "enabled" }).Count

Write-Host "GHAS:           $ghasOk / $($results.Count)" -ForegroundColor $(if ($ghasOk -eq $results.Count) { "Green" } else { "Yellow" })
Write-Host "Dependabot:     $depOk / $($results.Count)" -ForegroundColor $(if ($depOk -eq $results.Count) { "Green" } else { "Yellow" })
Write-Host "Secret Scanning: $ssOk / $($results.Count)" -ForegroundColor $(if ($ssOk -eq $results.Count) { "Green" } else { "Yellow" })

$csvFile = "./output/ghas-enablement-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "`nResults saved to: $csvFile" -ForegroundColor Green
