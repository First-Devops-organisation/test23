# ============================================================
#  Snapshot ADO Data - Pre-Migration Backup
#  Phase: 00-extract
#  Creates a full JSON snapshot of all work items before migration
#  tags anything. Enables rollback comparison.
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"

$config     = Read-JsonConfig -Path $ConfigPath
$adoOrg     = $config.source.organization
$adoProject = $config.source.project
$areaPath   = $config.source.areaPath
$adoPat     = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$logDir     = Join-Path $scriptRoot $config.output.logDir

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

Initialize-Log -LogPath (Join-Path $logDir "snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 0: Pre-Migration Data Snapshot"

# Create timestamped snapshot directory
$snapshotDir = Join-Path $scriptRoot "snapshots\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

Write-Log -Message "Snapshot directory: $snapshotDir" -Level "INFO"
Write-Log -Message "Source: $adoOrg / $adoProject / $areaPath" -Level "INFO"

# --- Query all work item IDs ---
Write-Log -Message "Querying all work items (including closed)..." -Level "INFO"
$allIds = Get-AdoWorkItemIds -Org $adoOrg -Project $adoProject -AreaPath $areaPath -IncludeClosed $true -Pat $adoPat
Write-Log -Message "Found $($allIds.Count) work items to snapshot" -Level "SUCCESS"

if ($allIds.Count -eq 0) {
    Write-Log -Message "No work items found. Check area path." -Level "WARN"
    exit 0
}

# --- Batch fetch using workitemsbatch API (200 at a time) ---
$headers = Get-AdoAuthHeaders -Pat $adoPat
$batchSize = 200
$totalBatches = [math]::Ceiling($allIds.Count / $batchSize)
$snapshotItems = @()

for ($i = 0; $i -lt $allIds.Count; $i += $batchSize) {
    $batchNum = [math]::Floor($i / $batchSize) + 1
    $batch = @($allIds[$i..([math]::Min($i + $batchSize - 1, $allIds.Count - 1))])

    Write-Log -Message "Fetching batch $batchNum of $totalBatches ($($batch.Count) items)..." -Level "INFO"

    $batchBody = @{
        ids      = $batch
        fields   = @()  # empty = ALL fields
        '$expand' = "All"
    } | ConvertTo-Json -Depth 5

    $uri = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workitemsbatch?api-version=7.1"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $batchBody -ContentType "application/json"
        if ($resp.value) {
            $snapshotItems += $resp.value
        }
        # Save individual batch file for large datasets
        $batchPath = Join-Path $snapshotDir "batch-$($batchNum.ToString('D4')).json"
        $resp | ConvertTo-Json -Depth 20 | Set-Content -Path $batchPath -Encoding UTF8
    } catch {
        Write-Log -Message "Batch $batchNum failed: $_" -Level "ERROR"
    }
    Start-Sleep -Milliseconds 200
}

# --- Save snapshot manifest ---
$manifest = @{
    snapshotDate    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    adoOrganization = $adoOrg
    adoProject      = $adoProject
    areaPath        = $areaPath
    totalItems      = $snapshotItems.Count
    totalBatches    = $totalBatches
    itemIds         = $allIds
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $snapshotDir "manifest.json") -Encoding UTF8

# --- Copy existing migration log if present (for resume comparison) ---
$migLogPath = Join-Path $scriptRoot $config.output.migrationLogFile
if (Test-Path $migLogPath) {
    Copy-Item $migLogPath (Join-Path $snapshotDir "migration-log-pre.json")
    Write-Log -Message "Copied existing migration log to snapshot" -Level "INFO"
}

Write-LogSection "Snapshot Complete"
Write-Log -Message "Items captured: $($snapshotItems.Count)" -Level "SUCCESS"
Write-Log -Message "Snapshot location: $snapshotDir" -Level "SUCCESS"
Write-Log -Message "Use this snapshot to verify data integrity after migration." -Level "INFO"
