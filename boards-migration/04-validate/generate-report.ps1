# ============================================================
#  Generate Migration Report - Professional Enterprise Report
#  Phase: 04-validate
#  Input:  reports/migration-log.json, reports/validation-results.json
#  Output: reports/migration-summary.md
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"

$config    = Read-JsonConfig -Path $ConfigPath
$reportDir = Join-Path $scriptRoot $config.output.reportDir
$logDir    = Join-Path $scriptRoot $config.output.logDir

Initialize-Log -LogPath (Join-Path $logDir "report-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Generating Migration Summary Report"

# Load data files
$migLogPath     = Join-Path $scriptRoot $config.output.migrationLogFile
$validationPath = Join-Path $reportDir "validation-results.json"
$inventoryPath  = Join-Path $reportDir "workitem-inventory.json"
$analysisPath   = Join-Path $reportDir "board-analysis.json"

$migLog     = if (Test-Path $migLogPath)     { Read-JsonConfig -Path $migLogPath } else { @{} }
$validation = if (Test-Path $validationPath) { Read-JsonConfig -Path $validationPath } else { $null }
$inventory  = if (Test-Path $inventoryPath)  { Read-JsonConfig -Path $inventoryPath } else { $null }
$analysis   = if (Test-Path $analysisPath)   { Read-JsonConfig -Path $analysisPath } else { $null }

$date     = Get-Date -Format "dd MMM yyyy, hh:mm tt"
$migCount = @($migLog.PSObject.Properties).Count
$adoCount = if ($inventory) { $inventory.summary.totalCount } else { $migCount }

# Determine validation status
$statusText = "Pending"
if ($validation) {
    if     ($validation.overallResult -eq 'PASS') { $statusText = "PASSED" }
    elseif ($validation.overallResult -eq 'WARN') { $statusText = "PASSED WITH WARNINGS" }
    else   { $statusText = "FAILED" }
}

$successRate = if ($adoCount -gt 0) { [math]::Round(($migCount / $adoCount) * 100, 1) } else { 0 }

# ============================================================
# Build Report Lines
# ============================================================
$lines = [System.Collections.Generic.List[string]]::new()

function Add($text) { $lines.Add($text) }
function Blank() { $lines.Add("") }

# ── TITLE ────────────────────────────────────────────────────
Add "# Azure DevOps to GitHub - Migration Report"
Blank
Add "---"
Blank
Blank

# ── EXECUTIVE SUMMARY ────────────────────────────────────────
Add "## 1. Executive Summary"
Blank
Add "This report summarizes the migration of work items from **Azure DevOps Boards** to **GitHub Issues and Projects**."
Add "The migration was executed using an automated pipeline with validation checks."
Blank

Add "| | |"
Add "|:--|:--|"
Add "| **Date** | $date |"
Add "| **Validation Result** | **$statusText** |"
Add "| **Success Rate** | **$successRate%** ($migCount of $adoCount items) |"
Add "| **Production Run** | $(if ($config.migration.productionRun) { 'Yes - ADO items tagged as migrated' } else { 'No - Dry run mode' }) |"
Blank
Add "---"
Blank
Blank

# ── SOURCE AND TARGET ────────────────────────────────────────
Add "## 2. Source and Target"
Blank

Add "### Source - Azure DevOps"
Blank
Add "| Field | Value |"
Add "|:--|:--|"
Add "| Organization | ``$($config.source.organization)`` |"
Add "| Project | ``$($config.source.project)`` |"
Add "| Area Path | ``$($config.source.areaPath)`` |"
Blank

Add "### Target - GitHub"
Blank
Add "| Field | Value |"
Add "|:--|:--|"
Add "| Owner | ``$($config.target.organization)`` |"
Add "| Repository | ``$($config.target.repository)`` |"
Add "| Project Board | #$($config.target.projectNumber) |"
Add "| Owner Type | ``$($config.target.projectOwnerType)`` |"
Blank
Add "---"
Blank
Blank

# ── MIGRATION STATISTICS ─────────────────────────────────────
if ($inventory) {
    Add "## 3. Migration Statistics"
    Blank

    Add "### 3.1 Work Items by Type"
    Blank
    Add "| Work Item Type | Count | Migrated |"
    Add "|:--|:--:|:--:|"
    foreach ($entry in $inventory.summary.byType.PSObject.Properties) {
        Add "| $($entry.Name) | $($entry.Value) | Yes |"
    }
    Add "| **TOTAL** | **$adoCount** | **$migCount** |"
    Blank
    Blank

    Add "### 3.2 Work Items by State"
    Blank
    Add "| Current State | Count |"
    Add "|:--|:--:|"
    foreach ($entry in $inventory.summary.byState.PSObject.Properties) {
        Add "| $($entry.Name) | $($entry.Value) |"
    }
    Blank
    Blank

    if ($inventory.summary.byAssignee) {
        Add "### 3.3 Work Items by Assignee"
        Blank
        Add "| ADO Assignee | Items Assigned |"
        Add "|:--|:--:|"
        foreach ($entry in $inventory.summary.byAssignee.PSObject.Properties) {
            Add "| $($entry.Name) | $($entry.Value) |"
        }
        Blank
    }

    Add "---"
    Blank
    Blank
}

# ── MIGRATION DETAILS ────────────────────────────────────────
$sectionNum = if ($inventory) { "4" } else { "3" }
Add "## $sectionNum. Migration Details"
Blank
Add "Each ADO work item was migrated as a GitHub Issue with labels, comments, attachments, and project status."
Blank

Add "| # | ADO ID | ADO Link | GitHub Issue | GitHub Link |"
Add "|:--:|:--:|:--|:--:|:--|"
$row = 1
foreach ($prop in $migLog.PSObject.Properties) {
    $adoId = $prop.Name
    $ghData = $prop.Value
    $adoUrl = "https://dev.azure.com/$($config.source.organization)/$($config.source.project)/_workitems/edit/$adoId"
    Add "| $row | $adoId | [Open in ADO]($adoUrl) | #$($ghData.issueNumber) | [Open in GitHub]($($ghData.issueUrl)) |"
    $row++
}
Blank
Add "---"
Blank
Blank

# ── STATUS MAPPING ───────────────────────────────────────────
$sectionNum2 = [int]$sectionNum + 1
Add "## $sectionNum2. Status Mapping Reference"
Blank
Add "The following state mapping was applied to set the GitHub Project status field."
Blank

Add "| ADO State | GitHub Project Status |"
Add "|:--|:--|"
$statusMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\status-mappings.json")
foreach ($entry in $statusMappings.defaultMapping.PSObject.Properties) {
    Add "| $($entry.Name) | $($entry.Value) |"
}
Blank
Add "---"
Blank
Blank

# ── VALIDATION RESULTS ───────────────────────────────────────
$sectionNum3 = [int]$sectionNum + 2
if ($validation) {
    Add "## $sectionNum3. Validation Results"
    Blank

    $passCount = @($validation.checks | Where-Object { $_.result -eq "PASS" }).Count
    $failCount = @($validation.checks | Where-Object { $_.result -eq "FAIL" }).Count
    $warnCount = @($validation.checks | Where-Object { $_.result -eq "WARN" }).Count
    $totalChecks = @($validation.checks).Count

    Add "**$passCount** of **$totalChecks** checks passed. **$warnCount** warning(s). **$failCount** failure(s)."
    Blank

    Add "| # | Validation Check | Result | Details |"
    Add "|:--:|:--|:--:|:--|"
    $i = 1
    foreach ($c in $validation.checks) {
        $result = $c.result
        Add "| $i | $($c.check) | **$result** | $($c.detail) |"
        $i++
    }
    Blank

    if ($validation.missingIssues -and @($validation.missingIssues).Count -gt 0) {
        Blank
        Add "### Missing Issues"
        Blank
        foreach ($m in $validation.missingIssues) {
            Add "- ADO #$($m.adoId) was mapped to GitHub #$($m.issueNumber) but the issue was not found."
        }
        Blank
    }

    Add "---"
    Blank
    Blank
}

# ── CONFIGURATION ────────────────────────────────────────────
$sectionNum4 = [int]$sectionNum + 3
Add "## $sectionNum4. Pipeline Configuration"
Blank
Add "Settings used for this migration run."
Blank

Add "| Parameter | Value |"
Add "|:--|:--|"
Add "| Migrate Closed Work Items | $($config.migration.migrateClosedWorkItems) |"
Add "| Update Assignees | $($config.migration.updateAssignedTo) |"
Add "| Migrate Comments | $($config.migration.addAdoComments) |"
Add "| Migrate Attachments | $($config.migration.migrateAttachments) |"
Add "| Preserve Parent-Child Links | $($config.migration.preserveParentChild) |"
Add "| Production Run | $($config.migration.productionRun) |"
Add "| Rate Limit Delay | $($config.migration.rateLimitDelayMs) ms |"
Add "| Batch Size | $($config.migration.batchSize) |"
Add "| Retry Count | $($config.migration.retryCount) |"
Blank
Blank

Add "### Configuration Files"
Blank
Add "| File | Purpose |"
Add "|:--|:--|"
Add "| ``boards-migration-config.json`` | Main configuration - source, target, migration settings |"
Add "| ``user-mappings.json`` | ADO identity to GitHub username mapping |"
Add "| ``status-mappings.json`` | ADO state to GitHub project status mapping |"
Add "| ``workitem-type-mappings.json`` | Work item type to GitHub label mapping and migration order |"
Blank
Add "---"
Blank
Blank

# ── FOOTER ───────────────────────────────────────────────────
Add "*Report generated automatically by the Azure DevOps to GitHub migration pipeline.*"
Blank
Add "*Generated on: $date*"

# ============================================================
# Save report
# ============================================================
$reportContent = $lines -join "`n"
$reportPath = Join-Path $reportDir "migration-summary.md"
$reportContent | Set-Content -Path $reportPath -Encoding UTF8

Write-Log -Message "Report saved: $reportPath" -Level "SUCCESS"
Write-Log -Message "Migration report generation complete." -Level "SUCCESS"
