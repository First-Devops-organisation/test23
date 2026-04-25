# ============================================================
#  Generate Migration Report - Professional summary
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

$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$migCount = @($migLog.PSObject.Properties).Count

# ============================================================
#  Build Professional Markdown Report
# ============================================================
$md = @"
# :rocket: Azure DevOps to GitHub Migration Report

---

## Executive Summary

| | |
|---|---|
| **Date** | $date |
| **Status** | $(if ($validation) { if ($validation.overallResult -eq 'PASS') { ':white_check_mark: **PASSED**' } elseif ($validation.overallResult -eq 'WARN') { ':warning: **PASSED WITH WARNINGS**' } else { ':x: **FAILED**' } } else { ':hourglass: Pending Validation' }) |
| **Items Migrated** | **$migCount** work items |
| **Production Run** | $(if ($config.migration.productionRun) { 'Yes - ADO items tagged' } else { 'No - ADO items unchanged' }) |

---

## Source & Target

| | Source (Azure DevOps) | Target (GitHub) |
|---|---|---|
| **Organization** | ``$($config.source.organization)`` | ``$($config.target.organization)`` |
| **Project / Repo** | ``$($config.source.project)`` | ``$($config.target.repository)`` |
| **Scope** | ``$($config.source.areaPath)`` | Project #$($config.target.projectNumber) |

---


"@

# --- Source Inventory Breakdown ---
if ($inventory) {
    $md += "## Source Inventory`n`n"

    # By Type
    $md += "### Work Items by Type`n`n"
    $md += "| Type | Count | Migrated |`n|---|:---:|:---:|`n"
    foreach ($entry in $inventory.summary.byType.PSObject.Properties) {
        $icon = switch ($entry.Name) {
            "Epic"       { ":purple_circle:" }
            "Feature"    { ":large_blue_circle:" }
            "User Story" { ":green_circle:" }
            "Task"       { ":yellow_circle:" }
            "Bug"        { ":red_circle:" }
            "Issue"      { ":orange_circle:" }
            default      { ":white_circle:" }
        }
        $md += "| $icon $($entry.Name) | $($entry.Value) | :white_check_mark: |`n"
    }
    $md += "| | **$($inventory.summary.totalCount)** | **$migCount** |`n`n"

    # By State
    $md += "### Work Items by State`n`n"
    $md += "| State | Count |`n|---|:---:|`n"
    foreach ($entry in $inventory.summary.byState.PSObject.Properties) {
        $stateIcon = switch ($entry.Name) {
            "New"      { ":new:" }
            "Active"   { ":arrow_forward:" }
            "Resolved" { ":white_check_mark:" }
            "Closed"   { ":lock:" }
            "Done"     { ":white_check_mark:" }
            default    { ":record_button:" }
        }
        $md += "| $stateIcon $($entry.Name) | $($entry.Value) |`n"
    }
    $md += "`n"

    # By Assignee
    if ($inventory.summary.byAssignee) {
        $md += "### Work Items by Assignee`n`n"
        $md += "| Assignee | Count |`n|---|:---:|`n"
        foreach ($entry in $inventory.summary.byAssignee.PSObject.Properties) {
            $md += "| $($entry.Name) | $($entry.Value) |`n"
        }
        $md += "`n"
    }

    $md += "---`n`n"
}

# --- Migration Mapping Table ---
$md += "## Migration Mapping`n`n"
$md += "| ADO ID | GitHub Issue | Link |`n|:---:|:---:|---|`n"
foreach ($prop in $migLog.PSObject.Properties) {
    $adoId = $prop.Name
    $ghData = $prop.Value
    $adoUrl = "https://dev.azure.com/$($config.source.organization)/$($config.source.project)/_workitems/edit/$adoId"
    $md += "| [$adoId]($adoUrl) | #$($ghData.issueNumber) | [View on GitHub]($($ghData.issueUrl)) |`n"
}
$md += "`n---`n`n"

# --- Status Mapping Reference ---
$md += "## Status Mapping Applied`n`n"
$md += "| ADO State | :arrow_right: | GitHub Status |`n|---|:---:|---|`n"
$statusMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\status-mappings.json")
foreach ($entry in $statusMappings.defaultMapping.PSObject.Properties) {
    $md += "| $($entry.Name) | :arrow_right: | **$($entry.Value)** |`n"
}
$md += "`n---`n`n"

# --- Validation Results ---
if ($validation) {
    $md += "## Validation Results`n`n"

    $passCount = @($validation.checks | Where-Object { $_.result -eq "PASS" }).Count
    $failCount = @($validation.checks | Where-Object { $_.result -eq "FAIL" }).Count
    $warnCount = @($validation.checks | Where-Object { $_.result -eq "WARN" }).Count
    $totalChecks = @($validation.checks).Count

    $md += "| Passed | Warnings | Failed | Total |`n|:---:|:---:|:---:|:---:|`n"
    $md += "| :white_check_mark: **$passCount** | :warning: **$warnCount** | :x: **$failCount** | **$totalChecks** |`n`n"

    $md += "### Detailed Checks`n`n"
    $md += "| # | Check | Result | Details |`n|:---:|---|:---:|---|`n"
    $i = 1
    foreach ($c in $validation.checks) {
        $icon = switch ($c.result) { "PASS" { ":white_check_mark:" }; "FAIL" { ":x:" }; "WARN" { ":warning:" }; default { ":grey_question:" } }
        $md += "| $i | $($c.check) | $icon $($c.result) | $($c.detail) |`n"
        $i++
    }
    $md += "`n"

    if ($validation.missingIssues -and @($validation.missingIssues).Count -gt 0) {
        $md += "### :warning: Missing Issues`n`n"
        foreach ($m in $validation.missingIssues) {
            $md += "- ADO #$($m.adoId) :arrow_right: GitHub #$($m.issueNumber) (NOT FOUND)`n"
        }
        $md += "`n"
    }

    $md += "---`n`n"
}

# --- Configuration Summary ---
$md += @"
## Configuration

| Setting | Value |
|---|---|
| Migrate Closed Items | ``$($config.migration.migrateClosedWorkItems)`` |
| Update Assignees | ``$($config.migration.updateAssignedTo)`` |
| Migrate Comments | ``$($config.migration.addAdoComments)`` |
| Migrate Attachments | ``$($config.migration.migrateAttachments)`` |
| Preserve Hierarchy | ``$($config.migration.preserveParentChild)`` |
| Production Run | ``$($config.migration.productionRun)`` |
| Rate Limit | ``$($config.migration.rateLimitDelayMs)ms`` |

### Config Files Used
- ``config/boards-migration-config.json``
- ``config/user-mappings.json``
- ``config/status-mappings.json``
- ``config/workitem-type-mappings.json``

---

> :memo: _Report generated automatically by the boards-migration pipeline._
> :clock1: _Generated at: $date_
"@

# Save report
$reportPath = Join-Path $reportDir "migration-summary.md"
$md | Set-Content -Path $reportPath -Encoding UTF8

Write-Log -Message "Report saved: $reportPath" -Level "SUCCESS"
Write-Log -Message "Migration report generation complete." -Level "SUCCESS"
