# ============================================================
#  Phase 6: Post-Migration Enrichment
#  Adds the 6 features missing from the core migration:
#
#  1. "Blocks / Blocked By" → Typed GitHub issue comments
#  2. "Related" links      → Typed GitHub issue comments
#  3. ADO Saved Queries    → GITHUB_FILTERS.md cheatsheet
#  4. Delivery Plans       → ROADMAP.md + timeline.csv
#  5. Mermaid Gantt Chart  → timeline.mmd
#  6. Critical Path        → critical_path.json
#
#  Run AFTER migrate-workitems.ps1 completes.
#  Reads migration-log.json to know which items were migrated.
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath      = "$PSScriptRoot\..\config\boards-migration-config.json",
    [string]$MigrationLogPath = "$PSScriptRoot\..\reports\migration-log.json",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"

# --- Load config ---
$config      = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$adoOrg      = $config.source.organization
$adoProject  = $config.source.project
$adoPat      = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$ghOrg       = $config.target.organization
$ghRepo      = $config.target.repository
$ghPat       = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }
$reportDir   = Join-Path $scriptRoot $config.output.reportDir

if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

Initialize-Log -LogPath (Join-Path $scriptRoot "logs" "enrich-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 6: Post-Migration Enrichment"

# --- Load migration log ---
if (-not (Test-Path $MigrationLogPath)) {
    Write-Log -Message "Migration log not found at $MigrationLogPath. Run migrate-workitems.ps1 first." -Level "ERROR"
    exit 1
}
$migLog   = Get-Content -Raw $MigrationLogPath | ConvertFrom-Json
$adoToGh  = @{}   # adoId -> ghIssueNumber
foreach ($prop in $migLog.PSObject.Properties) {
    if ($prop.Value.issueNumber) {
        $adoToGh[$prop.Name] = $prop.Value.issueNumber
    }
}
Write-Log -Message "Loaded $($adoToGh.Count) migrated items from migration log." -Level "INFO"

$adoHeaders = Get-AdoAuthHeaders -Pat $adoPat
$ghHeaders  = Get-GhRestHeaders  -Pat $ghPat

# ============================================================
#  FEATURE 1 & 2: Blocks / Blocked By / Related Comments
# ============================================================
Write-LogSection "Feature 1+2: Dependency & Related Comments"

$relTypes = @{
    "System.LinkTypes.Dependency-Reverse" = @{ label = "Blocked by";  emoji = "🚧" }
    "System.LinkTypes.Dependency-Forward" = @{ label = "Blocks";      emoji = "⛔" }
    "System.LinkTypes.Related"            = @{ label = "Related to";  emoji = "🔗" }
}

$relLinksCreated = 0
$relLinksFailed  = 0

foreach ($adoId in $adoToGh.Keys) {
    $ghSrcNum = $adoToGh[$adoId]

    # Fetch work item relations from ADO
    $wiUri  = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workitems/${adoId}?`$expand=relations&api-version=7.1"
    $wiData = try { Invoke-RestMethod -Uri $wiUri -Method GET -Headers $adoHeaders } catch { $null }
    if (-not $wiData -or -not $wiData.relations) { continue }

    foreach ($rel in $wiData.relations) {
        $relType = $rel.rel
        if (-not $relTypes.ContainsKey($relType)) { continue }

        # Extract target ADO ID from URL
        $targetAdoId = $null
        try {
            if ($rel.url -match '/workitems?/(\d+)$' -or $rel.url -match '/workItems/(\d+)$') {
                $targetAdoId = $Matches[1]
            }
        } catch { continue }
        if (-not $targetAdoId) { continue }

        # Only link if target was also migrated
        $ghTgtNum = $adoToGh[$targetAdoId]
        if (-not $ghTgtNum) { continue }

        $relInfo     = $relTypes[$relType]
        $commentBody = "$($relInfo.emoji) **$($relInfo.label):** #$ghTgtNum`n`n_Migrated relationship from Azure DevOps (ADO#$adoId → ADO#$targetAdoId)_"

        if ($DryRun) {
            Write-Log -Message "  [DRY RUN] GH#$ghSrcNum $($relInfo.label) GH#$ghTgtNum" -Level "INFO"
            continue
        }

        try {
            Add-GhIssueComment -Org $ghOrg -Repo $ghRepo -IssueNumber $ghSrcNum -Body $commentBody -Pat $ghPat | Out-Null
            Write-Log -Message "  GH#$ghSrcNum $($relInfo.label) GH#$ghTgtNum ✓" -Level "SUCCESS"
            $relLinksCreated++
            Start-Sleep -Milliseconds 800
        } catch {
            Write-Log -Message "  Failed GH#$ghSrcNum $($relInfo.label) GH#$ghTgtNum : $_" -Level "WARN"
            $relLinksFailed++
        }
    }
}

Write-Log -Message "Dependency/Related comments: $relLinksCreated created, $relLinksFailed failed." -Level "INFO"

# ============================================================
#  FEATURE 3: ADO Saved Queries → GITHUB_FILTERS.md
# ============================================================
Write-LogSection "Feature 3: Saved Query → GitHub Filter Guide"

# WIQL field/value to GitHub label mappings
$wiqlFieldMap = @{
    "System.State" = @{
        "Active"      = 'state:active'
        "Closed"      = 'state:closed'
        "Resolved"    = 'state:resolved'
        "Done"        = 'state:done'
        "In Progress" = 'state:in-progress'
        "New"         = 'state:new'
        "Removed"     = 'state:removed'
    }
    "System.WorkItemType" = @{
        "Bug"        = 'type:bug'
        "Task"       = 'type:task'
        "User Story" = 'type:story'
        "Feature"    = 'type:feature'
        "Epic"       = 'type:epic'
    }
    "Microsoft.VSTS.Common.Priority" = @{
        "1" = 'priority:critical'
        "2" = 'priority:high'
        "3" = 'priority:medium'
        "4" = 'priority:low'
    }
}

function Convert-WiqlToGhFilter {
    param([string]$Wiql)
    $labels = [System.Collections.Generic.List[string]]::new()
    $pattern = '\[([^\]]+)\]\s*(=|<>|CONTAINS)\s*[''"]([^''"]+)[''"]'
    $matches = [regex]::Matches($Wiql, $pattern, 'IgnoreCase')
    foreach ($m in $matches) {
        $field = $m.Groups[1].Value
        $op    = $m.Groups[2].Value
        $val   = $m.Groups[3].Value
        if ($op -eq '<>') { continue }  # skip negations
        if ($wiqlFieldMap.ContainsKey($field) -and $wiqlFieldMap[$field].ContainsKey($val)) {
            $labels.Add($wiqlFieldMap[$field][$val]) | Out-Null
        } elseif ($field -eq 'System.Tags') {
            $labels.Add("tag:$($val.ToLower())") | Out-Null
        } elseif ($field -eq 'System.AreaPath') {
            $labels.Add("area:$($val.ToLower() -replace ' ', '-')") | Out-Null
        }
    }
    return $labels | Select-Object -Unique
}

# Fetch saved queries from ADO
$queryUri = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/queries?`$depth=2&api-version=7.1"
$queryData = try { Invoke-RestMethod -Uri $queryUri -Method GET -Headers $adoHeaders } catch { $null }

$filterLines = @(
    "# GitHub Issue Search Guide",
    "",
    "This guide maps your Azure DevOps saved queries to GitHub issue searches.",
    "Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    "",
    "---",
    ""
)

$queryCount = 0
if ($queryData -and $queryData.value) {
    $queue = [System.Collections.Queue]::new()
    foreach ($q in $queryData.value) { $queue.Enqueue($q) }

    while ($queue.Count -gt 0) {
        $q = $queue.Dequeue()
        if ($q.isFolder) {
            foreach ($child in $q.children) { $queue.Enqueue($child) }
            continue
        }
        $qName = $q.name
        $qWiql = $q.wiql
        $ghLabels = if ($qWiql) { Convert-WiqlToGhFilter -Wiql $qWiql } else { @() }
        $searchExpr = if ($ghLabels.Count -gt 0) {
            ($ghLabels | ForEach-Object { "label:`"$_`"" }) -join " "
        } else {
            "_No direct label equivalent — review manually_"
        }

        $filterLines += "## $qName"
        $filterLines += ""
        if ($qWiql) {
            $filterLines += "**Original WIQL:**"
            $filterLines += '```sql'
            $filterLines += $qWiql
            $filterLines += '```'
            $filterLines += ""
        }
        $filterLines += "**GitHub Search:**"
        $filterLines += "``$searchExpr``"
        $filterLines += ""
        $filterLines += "---"
        $filterLines += ""
        $queryCount++
    }
}

if ($queryCount -eq 0) {
    $filterLines += "_No saved queries found in this ADO project._"
    $filterLines += ""
    $filterLines += "## Common GitHub Searches"
    $filterLines += ""
    $filterLines += "| What you want | GitHub Search |"
    $filterLines += "|---|---|"
    $filterLines += "| All open bugs | ``is:open label:\"type:bug\"`` |"
    $filterLines += "| Active user stories | ``is:open label:\"type:story\" label:\"state:active\"`` |"
    $filterLines += "| Critical priority | ``is:open label:\"priority:critical\"`` |"
    $filterLines += "| Assigned to me | ``is:open assignee:@me`` |"
    $filterLines += "| Current sprint | ``is:open milestone:\"Sprint X\"`` |"
    $filterLines += "| Unassigned bugs | ``is:open label:\"type:bug\" no:assignee`` |"
}

$filtersPath = Join-Path $reportDir "GITHUB_FILTERS.md"
$filterLines -join "`n" | Set-Content -Path $filtersPath -Encoding UTF8
Write-Log -Message "Saved query filter guide: $filtersPath ($queryCount queries)" -Level "SUCCESS"

# ============================================================
#  FEATURE 4 + 5 + 6: Delivery Plans → ROADMAP.md + Gantt + Critical Path
# ============================================================
Write-LogSection "Feature 4+5+6: Delivery Plans, Roadmap & Gantt Chart"

$planUri  = "https://dev.azure.com/$adoOrg/$adoProject/_apis/work/plans?api-version=7.1"
$planData = try { Invoke-RestMethod -Uri $planUri -Method GET -Headers $adoHeaders } catch { $null }
$plans    = if ($planData -and $planData.value) { $planData.value } else { @() }

Write-Log -Message "Found $($plans.Count) delivery plan(s)." -Level "INFO"

# --- ROADMAP.md ---
$roadmapLines = @(
    "# Delivery Roadmap",
    "",
    "Migrated from Azure DevOps Delivery Plans.",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    "",
    "> **Note:** For visual timeline, open `timeline.mmd` in any Mermaid viewer or GitHub.",
    ""
)

# --- timeline.mmd (Mermaid Gantt) ---
$ganttLines = @(
    "gantt",
    "    title Delivery Plan Timeline",
    "    dateFormat YYYY-MM-DD",
    "    axisFormat %b %Y",
    ""
)

# --- critical_path.json ---
$criticalItems = [System.Collections.Generic.List[hashtable]]::new()

# --- timeline.csv ---
$csvRows = [System.Collections.Generic.List[PSCustomObject]]::new()

$today = Get-Date

foreach ($plan in $plans) {
    $planId   = $plan.id
    $planName = $plan.name

    $planDetailUri = "https://dev.azure.com/$adoOrg/$adoProject/_apis/work/plans/$planId`?api-version=7.1"
    $planDetail    = try { Invoke-RestMethod -Uri $planDetailUri -Method GET -Headers $adoHeaders } catch { $null }

    $roadmapLines += "## $planName"
    $roadmapLines += ""
    $roadmapLines += "| Work Item | GitHub Issue | Type | Start | End | Status |"
    $roadmapLines += "|---|---|---|---|---|---|"

    $ganttLines += "    section $planName"

    $itemsFound = 0

    if ($planDetail -and $planDetail.cardRowsPagedList) {
        foreach ($row in $planDetail.cardRowsPagedList) {
            foreach ($card in $row.cards) {
                $wi        = $card.workItem
                $adoItemId = "$($wi.id)"
                $wiTitle   = $wi.title
                $wiType    = $wi.type
                $wiState   = $card.status
                $startDate = if ($card.startDate) { ([datetime]$card.startDate).ToString("yyyy-MM-dd") } else { $null }
                $endDate   = if ($card.endDate)   { ([datetime]$card.endDate).ToString("yyyy-MM-dd")   } else { $null }
                $ghNum     = $adoToGh[$adoItemId]
                $ghLink    = if ($ghNum) { "[#$ghNum](https://github.com/$ghOrg/$ghRepo/issues/$ghNum)" } else { "Not migrated" }

                $roadmapLines += "| $($wiTitle.Substring(0, [Math]::Min(50, $wiTitle.Length))) | $ghLink | $wiType | $($startDate ?? 'TBD') | $($endDate ?? 'TBD') | $wiState |"

                # Gantt entry
                if ($startDate -and $endDate) {
                    $taskType = switch ($wiState) {
                        "Done"        { "done, " }
                        "Completed"   { "done, " }
                        "In Progress" { "active, " }
                        "Active"      { "active, " }
                        default       { "" }
                    }
                    $safeTitle = ($wiTitle -replace '[,:"]', '') .Substring(0, [Math]::Min(40, $wiTitle.Length))
                    $ganttItemId = if ($ghNum) { "GH#$ghNum" } else { "ADO#$adoItemId" }
                    $ganttLines += "    $safeTitle ($ganttItemId) : $taskType$startDate, $endDate"
                }

                # CSV row
                $csvRows.Add([PSCustomObject]@{
                    ADO_ID       = $adoItemId
                    GitHub_Issue = if ($ghNum) { "#$ghNum" } else { "N/A" }
                    Title        = $wiTitle
                    Type         = $wiType
                    Start_Date   = $startDate ?? ""
                    End_Date     = $endDate ?? ""
                    Status       = $wiState
                    Plan         = $planName
                }) | Out-Null

                # Critical path: in-progress items where end date is near or past
                if ($wiState -in @("In Progress", "Active") -and $endDate) {
                    $daysLeft = ([datetime]$endDate - $today).Days
                    $urgency  = if ($daysLeft -lt 0) { "overdue" } elseif ($daysLeft -lt 7) { "critical" } else { "high" }
                    $criticalItems.Add(@{
                        adoId      = $adoItemId
                        ghIssue    = if ($ghNum) { "#$ghNum" } else { "N/A" }
                        title      = $wiTitle
                        plan       = $planName
                        endDate    = $endDate
                        daysLeft   = $daysLeft
                        urgency    = $urgency
                    }) | Out-Null
                }

                $itemsFound++
            }
        }
    }

    if ($itemsFound -eq 0) {
        $roadmapLines += "| _(No items in this plan)_ | — | — | — | — | — |"
    }
    $roadmapLines += ""
    $ganttLines    += ""
}

# If no delivery plans found, generate helpful placeholder
if ($plans.Count -eq 0) {
    $roadmapLines += "> No Delivery Plans found in ADO. If you have Delivery Plans, ensure your PAT has the 'Work Items (read)' scope."
    $roadmapLines += ""
    $ganttLines    += "    section No plans found"
    $ganttLines    += "    No data : 2024-01-01, 2024-12-31"
}

# --- Write ROADMAP.md ---
$roadmapPath = Join-Path $reportDir "ROADMAP.md"
$roadmapLines -join "`n" | Set-Content -Path $roadmapPath -Encoding UTF8
Write-Log -Message "ROADMAP.md → $roadmapPath" -Level "SUCCESS"

# --- Write timeline.mmd ---
$ganttPath = Join-Path $reportDir "timeline.mmd"
$ganttLines -join "`n" | Set-Content -Path $ganttPath -Encoding UTF8
Write-Log -Message "Mermaid Gantt chart → $ganttPath" -Level "SUCCESS"

# --- Write timeline.csv ---
$csvPath = Join-Path $reportDir "timeline.csv"
if ($csvRows.Count -gt 0) {
    $csvRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Timeline CSV → $csvPath ($($csvRows.Count) rows)" -Level "SUCCESS"
} else {
    "ADO_ID,GitHub_Issue,Title,Type,Start_Date,End_Date,Status,Plan" | Set-Content -Path $csvPath -Encoding UTF8
    Write-Log -Message "Timeline CSV → $csvPath (empty - no delivery plan data)" -Level "INFO"
}

# --- Write critical_path.json ---
$cpPath   = Join-Path $reportDir "critical_path.json"
$cpSorted = $criticalItems | Sort-Object { @("overdue","critical","high").IndexOf($_.urgency) }
$cpSorted | ConvertTo-Json -Depth 10 | Set-Content -Path $cpPath -Encoding UTF8
Write-Log -Message "Critical path → $cpPath ($($criticalItems.Count) items)" -Level "SUCCESS"

# ============================================================
#  FINAL SUMMARY
# ============================================================
Write-LogSection "Phase 6 Complete"
Write-Log -Message "Relation comments   : $relLinksCreated created" -Level "SUCCESS"
Write-Log -Message "Query filter guide  : $filtersPath"             -Level "SUCCESS"
Write-Log -Message "Roadmap             : $roadmapPath"             -Level "SUCCESS"
Write-Log -Message "Mermaid Gantt       : $ganttPath"               -Level "SUCCESS"
Write-Log -Message "Timeline CSV        : $csvPath"                 -Level "SUCCESS"
Write-Log -Message "Critical Path       : $cpPath ($($criticalItems.Count) items flagged)" -Level "SUCCESS"
Write-Log -Message ""                                                -Level "INFO"
Write-Log -Message "All 6 enrichment features complete! ✅"          -Level "SUCCESS"
