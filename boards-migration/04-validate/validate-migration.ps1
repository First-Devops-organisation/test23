# ============================================================
#  Validate Migration - Post-migration comparison
#  Phase: 04-validate
#  Compares ADO source vs GitHub target for completeness
# ============================================================# ============================================================
#  Validate Migration - Post-migration comparison
#  Phase: 04-validate
#  Compares ADO source vs GitHub target for completeness
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$reportsDir = Join-Path $PSScriptRoot "..\reports"
$logsDir    = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
if (-not (Test-Path $logsDir))    { New-Item -ItemType Directory -Path $logsDir    -Force | Out-Null }
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"

$config    = Read-JsonConfig -Path $ConfigPath
$adoOrg    = $config.source.organization
$adoProject = $config.source.project
$areaPath  = $config.source.areaPath
$adoPat    = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$ghOrg     = $config.target.organization
$ghRepo    = $config.target.repository
$ghPat     = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }
$reportDir = Join-Path $scriptRoot $config.output.reportDir
$logDir    = Join-Path $scriptRoot $config.output.logDir
$migLogPath = Join-Path $scriptRoot $config.output.migrationLogFile

Initialize-Log -LogPath (Join-Path $logDir "validate-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 4: Validate Migration"

# --- Load migration log ---
if (-not (Test-Path $migLogPath)) {
    Write-Log -Message "Migration log not found - this is expected for dry runs." -Level "WARN"
    Write-Log -Message "Skipping detailed validation. Run real migration first." -Level "WARN"
    Write-Log -Message "Validate phase complete (dry run - no migration log to validate)." -Level "SUCCESS"
    exit 0
}
$migLog = Read-JsonConfig -Path $migLogPath

# --- Count ADO work items ---
Write-Log -Message "Counting ADO work items..." -Level "INFO"
$adoIds = Get-AdoWorkItemIds -Org $adoOrg -Project $adoProject -AreaPath $areaPath `
    -IncludeClosed $config.migration.migrateClosedWorkItems -Pat $adoPat
$adoCount = $adoIds.Count
Write-Log -Message "ADO work items: $adoCount" -Level "INFO"

# --- Count migrated items ---
$migratedCount = $migLog.PSObject.Properties.Count
Write-Log -Message "Migrated items in log: $migratedCount" -Level "INFO"

# --- Validation checks ---
$checks = @()

# Check 1: Total count match
$countMatch = $adoCount -eq $migratedCount
$checks += @{
    check  = "Work Item Count Match"
    result = if ($countMatch) { "PASS" } else { "FAIL" }
    adoValue = $adoCount
    ghValue  = $migratedCount
    detail = "ADO: $adoCount | Migrated: $migratedCount"
}

# Check 2: Verify each migrated item exists in GitHub
Write-Log -Message "Verifying GitHub issues exist..." -Level "INFO"
$missingIssues = @()
$verifiedCount = 0
$headers = Get-GhRestHeaders -Pat $ghPat

foreach ($prop in $migLog.PSObject.Properties) {
    $adoId = $prop.Name
    $ghData = $prop.Value
    $issueNum = $ghData.issueNumber

    try {
        $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$issueNum"
        $issue = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $verifiedCount++
    } catch {
        $missingIssues += @{ adoId = $adoId; issueNumber = $issueNum }
    }
    Start-Sleep -Milliseconds 200
}

$checks += @{
    check  = "GitHub Issues Exist"
    result = if ($missingIssues.Count -eq 0) { "PASS" } else { "FAIL" }
    detail = "Verified: $verifiedCount | Missing: $($missingIssues.Count)"
}

# Check 3: Spot-check comments (sample 5 items)
Write-Log -Message "Spot-checking comments on sample items..." -Level "INFO"
$sampleSize = [math]::Min(5, $migLog.PSObject.Properties.Count)
$sampleProps = $migLog.PSObject.Properties | Select-Object -First $sampleSize
$commentMismatches = @()

foreach ($prop in $sampleProps) {
    $adoId = [int]$prop.Name
    $ghIssueNum = $prop.Value.issueNumber

    # ADO comment count
    $adoComments = Get-AdoWorkItemComments -Org $adoOrg -Project $adoProject -WorkItemId $adoId -Pat $adoPat
    $adoCommentCount = if ($adoComments) { $adoComments.Count } else { 0 }

    # GitHub comment count
    try {
        $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$ghIssueNum/comments?per_page=100"
        $ghComments = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $ghCommentCount = $ghComments.Count
    } catch { $ghCommentCount = 0 }

    # GitHub has extra comments (metadata, attachments) so gh >= ado
    if ($ghCommentCount -lt $adoCommentCount) {
        $commentMismatches += @{ adoId = $adoId; adoComments = $adoCommentCount; ghComments = $ghCommentCount }
    }
    Start-Sleep -Milliseconds 300
}

$checks += @{
    check  = "Comments Migrated (sample)"
    result = if ($commentMismatches.Count -eq 0) { "PASS" } else { "WARN" }
    detail = "Checked $sampleSize items. Mismatches: $($commentMismatches.Count)"
}

# Check 4: Labels exist on migrated issues
Write-Log -Message "Checking labels on sample issues..." -Level "INFO"
$labelIssues = @()
foreach ($prop in $sampleProps) {
    $ghIssueNum = $prop.Value.issueNumber
    try {
        $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$ghIssueNum"
        $issue = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $hasTypeLabel = $issue.labels | Where-Object { $_.name -in @("epic","feature","user-story","task","bug","issue","impediment","test-plan","test-suite","test-case") }
        if (-not $hasTypeLabel) { $labelIssues += $ghIssueNum }
    } catch { }
    Start-Sleep -Milliseconds 200
}

$checks += @{
    check  = "Type Labels Present (sample)"
    result = if ($labelIssues.Count -eq 0) { "PASS" } else { "WARN" }
    detail = "Issues without type label: $($labelIssues.Count)"
}

# Check 5: ADO items tagged (if production run)
if ($config.migration.productionRun) {
    Write-Log -Message "Checking ADO tags..." -Level "INFO"
    $untagged = @()
    foreach ($prop in $sampleProps) {
        $adoId = [int]$prop.Name
        $details = Get-AdoWorkItemDetails -Org $adoOrg -Project $adoProject -WorkItemId $adoId -Pat $adoPat
        if ($details -and $details.fields.'System.Tags' -notmatch 'copied-to-github') {
            $untagged += $adoId
        }
        Start-Sleep -Milliseconds 200
    }
    $checks += @{
        check  = "ADO Tagged as Migrated"
        result = if ($untagged.Count -eq 0) { "PASS" } else { "WARN" }
        detail = "Untagged items in sample: $($untagged.Count)"
    }
}

# --- Build validation report ---
$passCount = ($checks | Where-Object { $_.result -eq "PASS" }).Count
$failCount = ($checks | Where-Object { $_.result -eq "FAIL" }).Count
$warnCount = ($checks | Where-Object { $_.result -eq "WARN" }).Count

$report = @{
    generatedAt    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    overallResult  = if ($failCount -gt 0) { "FAIL" } elseif ($warnCount -gt 0) { "WARN" } else { "PASS" }
    checks         = $checks
    summary        = @{ pass = $passCount; fail = $failCount; warn = $warnCount }
    missingIssues  = $missingIssues
    commentMismatches = $commentMismatches
}

Save-Report -Data $report -ReportPath (Join-Path $reportDir "validation-results.json")

# --- Print results ---
Write-LogSection "Validation Results"
foreach ($c in $checks) {
    $icon = switch ($c.result) { "PASS" { "✅" }; "FAIL" { "❌" }; "WARN" { "⚠️" } }
    $lvl  = switch ($c.result) { "PASS" { "SUCCESS" }; "FAIL" { "ERROR" }; "WARN" { "WARN" } }
    Write-Log -Message "$icon $($c.check): $($c.result) — $($c.detail)" -Level $lvl
}

Write-Log -Message "Overall: $($report.overallResult) (Pass: $passCount | Fail: $failCount | Warn: $warnCount)" -Level $(if ($failCount -gt 0) { "ERROR" } else { "SUCCESS" })

if ($failCount -gt 0) { exit 1 }

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$reportsDir = Join-Path $PSScriptRoot "..\reports"
$logsDir    = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
if (-not (Test-Path $logsDir))    { New-Item -ItemType Directory -Path $logsDir    -Force | Out-Null }
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"

$config    = Read-JsonConfig -Path $ConfigPath
$adoOrg    = $config.source.organization
$adoProject = $config.source.project
$areaPath  = $config.source.areaPath
$adoPat    = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$ghOrg     = $config.target.organization
$ghRepo    = $config.target.repository
$ghPat     = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }
$reportDir = Join-Path $scriptRoot $config.output.reportDir
$logDir    = Join-Path $scriptRoot $config.output.logDir
$migLogPath = Join-Path $scriptRoot $config.output.migrationLogFile

Initialize-Log -LogPath (Join-Path $logDir "validate-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 4: Validate Migration"

# --- Load migration log ---
if (-not (Test-Path $migLogPath)) {
    Write-Log -Message "Migration log not found: $migLogPath" -Level "ERROR"
    exit 1
}
$migLog = Read-JsonConfig -Path $migLogPath

# --- Count ADO work items ---
Write-Log -Message "Counting ADO work items..." -Level "INFO"
$adoIds = Get-AdoWorkItemIds -Org $adoOrg -Project $adoProject -AreaPath $areaPath `
    -IncludeClosed $config.migration.migrateClosedWorkItems -Pat $adoPat
$adoCount = $adoIds.Count
Write-Log -Message "ADO work items: $adoCount" -Level "INFO"

# --- Count migrated items ---
$migratedCount = $migLog.PSObject.Properties.Count
Write-Log -Message "Migrated items in log: $migratedCount" -Level "INFO"

# --- Validation checks ---
$checks = @()

# Check 1: Total count match
$countMatch = $adoCount -eq $migratedCount
$checks += @{
    check  = "Work Item Count Match"
    result = if ($countMatch) { "PASS" } else { "FAIL" }
    adoValue = $adoCount
    ghValue  = $migratedCount
    detail = "ADO: $adoCount | Migrated: $migratedCount"
}

# Check 2: Verify each migrated item exists in GitHub
Write-Log -Message "Verifying GitHub issues exist..." -Level "INFO"
$missingIssues = @()
$verifiedCount = 0
$headers = Get-GhRestHeaders -Pat $ghPat

foreach ($prop in $migLog.PSObject.Properties) {
    $adoId = $prop.Name
    $ghData = $prop.Value
    $issueNum = $ghData.issueNumber

    try {
        $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$issueNum"
        $issue = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $verifiedCount++
    } catch {
        $missingIssues += @{ adoId = $adoId; issueNumber = $issueNum }
    }
    Start-Sleep -Milliseconds 200
}

$checks += @{
    check  = "GitHub Issues Exist"
    result = if ($missingIssues.Count -eq 0) { "PASS" } else { "FAIL" }
    detail = "Verified: $verifiedCount | Missing: $($missingIssues.Count)"
}

# Check 3: Spot-check comments (sample 5 items)
Write-Log -Message "Spot-checking comments on sample items..." -Level "INFO"
$sampleSize = [math]::Min(5, $migLog.PSObject.Properties.Count)
$sampleProps = $migLog.PSObject.Properties | Select-Object -First $sampleSize
$commentMismatches = @()

foreach ($prop in $sampleProps) {
    $adoId = [int]$prop.Name
    $ghIssueNum = $prop.Value.issueNumber

    # ADO comment count
    $adoComments = Get-AdoWorkItemComments -Org $adoOrg -Project $adoProject -WorkItemId $adoId -Pat $adoPat
    $adoCommentCount = if ($adoComments) { $adoComments.Count } else { 0 }

    # GitHub comment count
    try {
        $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$ghIssueNum/comments?per_page=100"
        $ghComments = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $ghCommentCount = $ghComments.Count
    } catch { $ghCommentCount = 0 }

    # GitHub has extra comments (metadata, attachments) so gh >= ado
    if ($ghCommentCount -lt $adoCommentCount) {
        $commentMismatches += @{ adoId = $adoId; adoComments = $adoCommentCount; ghComments = $ghCommentCount }
    }
    Start-Sleep -Milliseconds 300
}

$checks += @{
    check  = "Comments Migrated (sample)"
    result = if ($commentMismatches.Count -eq 0) { "PASS" } else { "WARN" }
    detail = "Checked $sampleSize items. Mismatches: $($commentMismatches.Count)"
}

# Check 4: Labels exist on migrated issues
Write-Log -Message "Checking labels on sample issues..." -Level "INFO"
$labelIssues = @()
foreach ($prop in $sampleProps) {
    $ghIssueNum = $prop.Value.issueNumber
    try {
        $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/issues/$ghIssueNum"
        $issue = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $hasTypeLabel = $issue.labels | Where-Object { $_.name -in @("epic","feature","user-story","task","bug","issue","impediment","test-plan","test-suite","test-case") }
        if (-not $hasTypeLabel) { $labelIssues += $ghIssueNum }
    } catch { }
    Start-Sleep -Milliseconds 200
}

$checks += @{
    check  = "Type Labels Present (sample)"
    result = if ($labelIssues.Count -eq 0) { "PASS" } else { "WARN" }
    detail = "Issues without type label: $($labelIssues.Count)"
}

# Check 5: ADO items tagged (if production run)
if ($config.migration.productionRun) {
    Write-Log -Message "Checking ADO tags..." -Level "INFO"
    $untagged = @()
    foreach ($prop in $sampleProps) {
        $adoId = [int]$prop.Name
        $details = Get-AdoWorkItemDetails -Org $adoOrg -Project $adoProject -WorkItemId $adoId -Pat $adoPat
        if ($details -and $details.fields.'System.Tags' -notmatch 'copied-to-github') {
            $untagged += $adoId
        }
        Start-Sleep -Milliseconds 200
    }
    $checks += @{
        check  = "ADO Tagged as Migrated"
        result = if ($untagged.Count -eq 0) { "PASS" } else { "WARN" }
        detail = "Untagged items in sample: $($untagged.Count)"
    }
}

# --- Build validation report ---
$passCount = ($checks | Where-Object { $_.result -eq "PASS" }).Count
$failCount = ($checks | Where-Object { $_.result -eq "FAIL" }).Count
$warnCount = ($checks | Where-Object { $_.result -eq "WARN" }).Count

$report = @{
    generatedAt    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    overallResult  = if ($failCount -gt 0) { "FAIL" } elseif ($warnCount -gt 0) { "WARN" } else { "PASS" }
    checks         = $checks
    summary        = @{ pass = $passCount; fail = $failCount; warn = $warnCount }
    missingIssues  = $missingIssues
    commentMismatches = $commentMismatches
}

Save-Report -Data $report -ReportPath (Join-Path $reportDir "validation-results.json")

# --- Print results ---
Write-LogSection "Validation Results"
foreach ($c in $checks) {
    $icon = switch ($c.result) { "PASS" { "✅" }; "FAIL" { "❌" }; "WARN" { "⚠️" } }
    $lvl  = switch ($c.result) { "PASS" { "SUCCESS" }; "FAIL" { "ERROR" }; "WARN" { "WARN" } }
    Write-Log -Message "$icon $($c.check): $($c.result) — $($c.detail)" -Level $lvl
}

Write-Log -Message "Overall: $($report.overallResult) (Pass: $passCount | Fail: $failCount | Warn: $warnCount)" -Level $(if ($failCount -gt 0) { "ERROR" } else { "SUCCESS" })

if ($failCount -gt 0) { exit 1 }