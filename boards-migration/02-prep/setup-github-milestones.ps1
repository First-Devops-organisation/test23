# ============================================================
#  Phase 2: Setup GitHub Milestones
#  Extracts unique Sprints/Iterations from ADO work items
#  and creates corresponding Milestones in GitHub.
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"

$config = Read-JsonConfig -Path $ConfigPath
$adoOrg = $config.source.organization
$adoProject = $config.source.project
$ghOrg = $config.target.organization
$ghRepo = $config.target.repository

$adoPat = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$ghPat  = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }

Initialize-Log -LogPath (Join-Path $scriptRoot $config.output.logDir "setup-milestones-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 2: Setup GitHub Milestones"

Write-Log -Message "Querying ADO for work items to find unique iterations..." -Level "INFO"
$areaPath = $config.source.areaPath
$allIds = Get-AdoWorkItemIds -Org $adoOrg -Project $adoProject -AreaPath $areaPath -IncludeClosed $true -Pat $adoPat

if (-not $allIds -or $allIds.Count -eq 0) {
    Write-Log -Message "No ADO items found. Exiting." -Level "WARN"
    exit 0
}

Write-Log -Message "Fetching details for $($allIds.Count) items to extract Iteration Paths..." -Level "INFO"
$iterations = @{}

# Batch fetch to get iteration paths quickly
$headers = Get-AdoAuthHeaders -Pat $adoPat
$batchSize = 200

for ($i = 0; $i -lt $allIds.Count; $i += $batchSize) {
    $batch = @($allIds[$i..([math]::Min($i + $batchSize - 1, $allIds.Count - 1))])
    $batchBody = @{ ids = $batch; fields = @("System.IterationPath") } | ConvertTo-Json -Depth 5
    $uri = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workitemsbatch?api-version=7.1"
    
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $batchBody -ContentType "application/json"
        if ($resp.value) {
            foreach ($item in $resp.value) {
                $iterPath = $item.fields.'System.IterationPath'
                if ($iterPath) {
                    # Use the last part of the path as the milestone title (e.g. "Sprint 1" from "Project\Sprint 1")
                    $milestoneTitle = ($iterPath -split '\\')[-1]
                    $iterations[$milestoneTitle] = $iterPath
                }
            }
        }
    } catch {
        Write-Log -Message "Failed to fetch batch for iterations: $_" -Level "WARN"
    }
}

Write-Log -Message "Found $($iterations.Count) unique iterations in ADO." -Level "SUCCESS"

if ($iterations.Count -eq 0) {
    Write-Log -Message "No iterations to create." -Level "INFO"
    exit 0
}

# --- Fetch existing GitHub Milestones ---
Write-Log -Message "Fetching existing GitHub milestones..." -Level "INFO"
$ghHeaders = Get-GhRestHeaders -Pat $ghPat
$existingMilestones = @{}

$page = 1
do {
    $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/milestones?state=all&per_page=100&page=$page"
    $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers $ghHeaders
    if ($resp) {
        foreach ($ms in $resp) {
            $existingMilestones[$ms.title] = $ms
        }
    }
    $page++
} while ($resp -and $resp.Count -eq 100)

Write-Log -Message "Found $($existingMilestones.Count) existing milestones in GitHub." -Level "INFO"

# --- Create missing milestones ---
$createdCount = 0
foreach ($milestoneTitle in $iterations.Keys) {
    if ($existingMilestones.ContainsKey($milestoneTitle)) {
        Write-Log -Message "Milestone already exists: $milestoneTitle" -Level "DEBUG"
        continue
    }

    $body = @{
        title = $milestoneTitle
        description = "Migrated from ADO Iteration: $($iterations[$milestoneTitle])"
    } | ConvertTo-Json -Depth 5

    $uri = "https://api.github.com/repos/$ghOrg/$ghRepo/milestones"
    try {
        $newMs = Invoke-RestMethod -Uri $uri -Method POST -Headers $ghHeaders -Body $body
        Write-Log -Message "Created Milestone: $milestoneTitle (#$($newMs.number))" -Level "SUCCESS"
        $createdCount++
    } catch {
        Write-Log -Message "Failed to create milestone '$milestoneTitle': $_" -Level "ERROR"
    }
}

Write-LogSection "Milestone Setup Complete"
Write-Log -Message "Newly created: $createdCount" -Level "SUCCESS"
