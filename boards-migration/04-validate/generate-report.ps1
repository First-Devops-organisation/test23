# ============================================================
#  Generate Migration Report - Human-readable summary
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
$migLogPath = Join-Path $scriptRoot $config.output.migrationLogFile
$validationPath = Join-Path $reportDir "validation-results.json"
$inventoryPath  = Join-Path $reportDir "workitem-inventory.json"

$migLog     = if (Test-Path $migLogPath) { Read-JsonConfig -Path $migLogPath } else { @{} }
$validation = if (Test-Path $validationPath) { Read-JsonConfig -Path $validationPath } else { $null }
$inventory  = if (Test-Path $inventoryPath) { Read-JsonConfig -Path $inventoryPath } else { $null }

$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$migCount = @($migLog.PSObject.Properties).Count

# --- Build Markdown Report ---
$md = @"
# Boards Migration Report

> **Generated**: $date
> **Source**: Azure DevOps — $($config.source.organization) / $($config.source.project)
> **Target**: GitHub — $($config.target.organization) / $($config.target.repository) (Project #$($config.target.projectNumber))

---

## Summary

| Metric | Value |
|--------|-------|
| Total Work Items Migrated | $migCount |
| Source Area Path | ``$($config.source.areaPath)`` |
| Include Closed Items | $($config.migration.migrateClosedWorkItems) |
| Production Run | $($config.migration.productionRun) |

"@

# --- Inventory Summary (if available) ---
if ($inventory) {
    $md += "## Source Inventory`n`n"
    $md += "| Work Item Type | Count |`n|---|---|`n"
    foreach ($entry in $inventory.summary.byType.PSObject.Properties) {
        $md += "| $($entry.Name) | $($entry.Value) |`n"
    }
    $md += "`n"
    $md += "| State | Count |`n|---|---|`n"
    foreach ($entry in $inventory.summary.byState.PSObject.Properties) {
        $md += "| $($entry.Name) | $($entry.Value) |`n"
    }
    $md += "`n"
}

# --- Migration Log Details ---
$md += "## Migrated Items`n`n"
$md += "| ADO ID | GitHub Issue | URL |`n|---|---|---|`n"
foreach ($prop in $migLog.PSObject.Properties) {
    $adoId = $prop.Name
    $ghData = $prop.Value
    $md += "| $adoId | #$($ghData.issueNumber) | [$($ghData.issueUrl)]($($ghData.issueUrl)) |`n"
}
$md += "`n"

# --- Validation Results (if available) ---
if ($validation) {
    $md += "## Validation Results`n`n"
    $md += "**Overall**: $($validation.overallResult)`n`n"
    $md += "| Check | Result | Detail |`n|---|---|---|`n"
    foreach ($c in $validation.checks) {
        $icon = switch ($c.result) { "PASS" { "✅" }; "FAIL" { "❌" }; "WARN" { "⚠️" }; default { "❓" } }
        $md += "| $icon $($c.check) | $($c.result) | $($c.detail) |`n"
    }
    $md += "`n"

    if ($validation.missingIssues -and $validation.missingIssues.Count -gt 0) {
        $md += "### Missing Issues`n`n"
        foreach ($m in $validation.missingIssues) {
            $md += "- ADO #$($m.adoId) → GitHub #$($m.issueNumber) (NOT FOUND)`n"
        }
        $md += "`n"
    }
}

# --- Config Used ---
$md += @"
## Configuration Used

- **User Mappings**: ``config/user-mappings.json``
- **Status Mappings**: ``config/status-mappings.json``
- **Type Mappings**: ``config/workitem-type-mappings.json``
- **Main Config**: ``config/boards-migration-config.json``

---

_Report generated automatically by boards-migration pipeline._
"@

# Save report
$reportPath = Join-Path $reportDir "migration-summary.md"
$md | Set-Content -Path $reportPath -Encoding UTF8

Write-Log -Message "Report saved: $reportPath" -Level "SUCCESS"
Write-Log -Message "Migration report generation complete." -Level "SUCCESS"
