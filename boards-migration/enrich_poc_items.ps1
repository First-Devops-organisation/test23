# ============================================================
#  Phase 0 Enrichment: Update existing POC items with full field data
#  Adds: diverse states, iteration paths, ALL custom fields
#  Adds: comments with images, related links, 6 extra items to reach 50
# ============================================================

$adoOrg     = "YashTech-DevOps"
$adoProject = "YASH-DevOps-Serverless"
$adoPat     = $env:ADO_PAT
$areaPath   = "YASH-DevOps-Serverless\POC-Migration"
$apiVersion = "7.1"
$baseUrl    = "https://dev.azure.com/$adoOrg/$adoProject/_apis"

if (-not $adoPat) { Write-Host "ERROR: Set `$env:ADO_PAT first" -ForegroundColor Red; exit 1 }

$base64Pat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers   = @{ Authorization = "Basic $base64Pat"; "Content-Type" = "application/json-patch+json" }

function Update-WorkItem {
    param([int]$Id, [hashtable]$Fields)
    $body = @()
    foreach ($kv in $Fields.GetEnumerator()) {
        $body += @{ op = 'add'; path = "/fields/$($kv.Key)"; value = $kv.Value }
    }
    $json = ConvertTo-Json -InputObject @($body) -Depth 5
    $uri  = "$baseUrl/wit/workitems/$($Id)?api-version=$apiVersion"
    try {
        Invoke-RestMethod -Method PATCH -Uri $uri -Headers $headers -Body $json | Out-Null
        Write-Host "  OK #$Id" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL #$Id : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Add-Comment {
    param([int]$Id, [string]$Text)
    $commentHeaders = @{ Authorization = "Basic $base64Pat"; "Content-Type" = "application/json" }
    $body = @{ text = $Text } | ConvertTo-Json
    $uri  = "$baseUrl/wit/workitems/$Id/comments?api-version=7.1-preview.4"
    try {
        Invoke-RestMethod -Method POST -Uri $uri -Headers $commentHeaders -Body $body | Out-Null
        Write-Host "  Comment added to #$Id" -ForegroundColor Cyan
    } catch {
        Write-Host "  Comment FAIL #$Id : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Add-RelatedLink {
    param([int]$SourceId, [int]$TargetId, [string]$LinkType = "System.LinkTypes.Related")
    $body = @(
        @{
            op = 'add'; path = '/relations/-'
            value = @{
                rel = $LinkType
                url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workItems/$TargetId"
            }
        }
    )
    $json = ConvertTo-Json -InputObject @($body) -Depth 5
    $uri  = "$baseUrl/wit/workitems/$($SourceId)?api-version=$apiVersion"
    try {
        Invoke-RestMethod -Method PATCH -Uri $uri -Headers $headers -Body $json | Out-Null
        Write-Host "  Linked #$SourceId -> #$TargetId ($LinkType)" -ForegroundColor DarkGreen
    } catch {
        Write-Host "  Link FAIL: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-WorkItem {
    param([string]$Type, [string]$Title, [string]$State, [int]$ParentItem = 0, [hashtable]$ExtraFields = @{}, [string]$Description = "")
    $body = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
        @{ op = 'add'; path = '/fields/System.State'; value = $State }
        @{ op = 'add'; path = '/fields/System.AreaPath'; value = $areaPath }
    )
    if ($Description) { $body += @{ op = 'add'; path = '/fields/System.Description'; value = $Description } }
    foreach ($kv in $ExtraFields.GetEnumerator()) { $body += @{ op = 'add'; path = "/fields/$($kv.Key)"; value = $kv.Value } }
    if ($ParentItem -gt 0) {
        $body += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workItems/$ParentItem" } }
    }
    $uri = "$baseUrl/wit/workitems/`$$([uri]::EscapeDataString($Type))?api-version=$apiVersion"
    try {
        $resp = Invoke-RestMethod -Method PATCH -Uri $uri -Headers $headers -Body (ConvertTo-Json -InputObject @($body) -Depth 10)
        Write-Host "  Created [$Type] #$($resp.id): $Title" -ForegroundColor Green
        return $resp.id
    } catch {
        Write-Host "  FAIL [$Type] $Title : $($_.Exception.Message)" -ForegroundColor Red
        return 0
    }
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Phase 0: Enriching POC Items for Full Fidelity" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# ── BATCH 1: Update STATES on existing items ─────────────────
Write-Host "--- Batch 1: Diversifying States ---" -ForegroundColor Yellow

# Stories: mix of states
Update-WorkItem 4330 @{ "System.State" = "Active" }
Update-WorkItem 4331 @{ "System.State" = "Active" }
Update-WorkItem 4332 @{ "System.State" = "Resolved" }
Update-WorkItem 4333 @{ "System.State" = "Closed" }
Update-WorkItem 4335 @{ "System.State" = "Closed" }

# Bugs: mix
Update-WorkItem 4336 @{ "System.State" = "Active" }
Update-WorkItem 4337 @{ "System.State" = "Active" }
Update-WorkItem 4338 @{ "System.State" = "Resolved" }
Update-WorkItem 4340 @{ "System.State" = "Closed" }

# Tasks: mix
Update-WorkItem 4350 @{ "System.State" = "Active" }
Update-WorkItem 4351 @{ "System.State" = "Closed" }
Update-WorkItem 4352 @{ "System.State" = "Active" }
Update-WorkItem 4353 @{ "System.State" = "Active" }
Update-WorkItem 4355 @{ "System.State" = "Closed" }
Update-WorkItem 4356 @{ "System.State" = "Closed" }
Update-WorkItem 4357 @{ "System.State" = "Closed" }
Update-WorkItem 4358 @{ "System.State" = "Active" }
Update-WorkItem 4359 @{ "System.State" = "Closed" }
Update-WorkItem 4360 @{ "System.State" = "Closed" }

# ── BATCH 2: Set ITERATION PATHS ─────────────────────────────
Write-Host "--- Batch 2: Setting Iteration Paths ---" -ForegroundColor Yellow

Update-WorkItem 4320 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4321 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4324 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4325 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4326 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4327 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4328 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4330 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4331 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4332 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4333 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4334 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 3" }
Update-WorkItem 4335 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 3" }
Update-WorkItem 4336 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4350 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4351 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1" }
Update-WorkItem 4352 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4353 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4355 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2" }
Update-WorkItem 4356 @{ "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 3" }

# ── BATCH 3: Populate ALL custom fields ──────────────────────
Write-Host "--- Batch 3: Populating ALL Custom Fields ---" -ForegroundColor Yellow

# Epics: ValueArea, Tags
Update-WorkItem 4320 @{ "Microsoft.VSTS.Common.ValueArea" = "Business"; "System.Tags" = "search;discovery;platform" }
Update-WorkItem 4321 @{ "Microsoft.VSTS.Common.ValueArea" = "Business"; "System.Tags" = "order;checkout;ecommerce" }
Update-WorkItem 4322 @{ "Microsoft.VSTS.Common.ValueArea" = "Architectural"; "System.Tags" = "category;taxonomy;admin" }
Update-WorkItem 4323 @{ "Microsoft.VSTS.Common.ValueArea" = "Architectural"; "System.Tags" = "infrastructure;platform" }

# Features: Story Points + ValueArea
Update-WorkItem 4327 @{ "Microsoft.VSTS.Scheduling.StoryPoints" = 5; "Microsoft.VSTS.Common.ValueArea" = "Business" }
Update-WorkItem 4329 @{ "Microsoft.VSTS.Scheduling.StoryPoints" = 2; "Microsoft.VSTS.Common.ValueArea" = "Architectural" }

# Stories with FULL field population
Update-WorkItem 4330 @{
    "Microsoft.VSTS.Scheduling.StoryPoints" = 5
    "Microsoft.VSTS.Common.ValueArea" = "Business"
    "System.Tags" = "search;filter;stock;PIM"
}
Update-WorkItem 4331 @{
    "Microsoft.VSTS.Scheduling.StoryPoints" = 3
    "Microsoft.VSTS.Common.ValueArea" = "Business"
    "System.Tags" = "catalog;sorting;UX"
}
Update-WorkItem 4332 @{
    "Microsoft.VSTS.Scheduling.StoryPoints" = 8
    "Microsoft.VSTS.Common.ValueArea" = "Business"
    "System.Tags" = "checkout;PO-number;ERP"
}
Update-WorkItem 4334 @{
    "Microsoft.VSTS.Scheduling.StoryPoints" = 5
    "Microsoft.VSTS.Common.ValueArea" = "Architectural"
    "System.Tags" = "admin;category;taxonomy"
}

# Tasks with time tracking fields
Update-WorkItem 4350 @{
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 8
    "Microsoft.VSTS.Scheduling.CompletedWork" = 3
    "Microsoft.VSTS.Scheduling.RemainingWork" = 5
}
Update-WorkItem 4351 @{
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 4
    "Microsoft.VSTS.Scheduling.CompletedWork" = 4
    "Microsoft.VSTS.Scheduling.RemainingWork" = 0
}
Update-WorkItem 4352 @{
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 6
    "Microsoft.VSTS.Scheduling.CompletedWork" = 2
    "Microsoft.VSTS.Scheduling.RemainingWork" = 4
}
Update-WorkItem 4355 @{
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 4
    "Microsoft.VSTS.Scheduling.CompletedWork" = 4
    "Microsoft.VSTS.Scheduling.RemainingWork" = 0
}
Update-WorkItem 4357 @{
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 3
    "Microsoft.VSTS.Scheduling.CompletedWork" = 3
    "Microsoft.VSTS.Scheduling.RemainingWork" = 0
}

# Bugs with severity + tags
Update-WorkItem 4336 @{ "System.Tags" = "search;filter;pagination;regression" }
Update-WorkItem 4337 @{ "System.Tags" = "carrier;ERP;critical;P1" }
Update-WorkItem 4338 @{ "System.Tags" = "terms;checkout;guest;critical" }
Update-WorkItem 4339 @{ "System.Tags" = "mobile;responsive;category" }

# ── BATCH 4: Add COMMENTS with images ────────────────────────
Write-Host "--- Batch 4: Adding Comments ---" -ForegroundColor Yellow

Add-Comment 4330 "<p><b>Design Review Notes</b></p><p>Discussed the faceted filter UX with the team. Agreed on:</p><ul><li>Filter panel on left sidebar</li><li>Real-time count badges next to each option</li><li>Clear all button at the top</li></ul><p>See wireframe: <img src='https://via.placeholder.com/400x300.png?text=Faceted+Filter+Wireframe' alt='wireframe'/></p>"

Add-Comment 4330 "<p>Updated acceptance criteria after sprint review. Added performance requirement: filter results must update in less than 2 seconds.</p>"

Add-Comment 4332 "<p><b>API Integration Notes</b></p><p>The PO number field maps to ERP field <code>CustomerPO</code>. Validation rules:</p><table><tr><th>Rule</th><th>Value</th></tr><tr><td>Max Length</td><td>20</td></tr><tr><td>Pattern</td><td>Alphanumeric + dashes</td></tr></table><p>Screenshot of current checkout: <img src='https://via.placeholder.com/600x400.png?text=Checkout+Flow+Screenshot' alt='checkout'/></p>"

Add-Comment 4336 "<p><b>Bug Analysis</b></p><p>Root cause identified: the pagination component resets the URL query parameters, which clears the active filter state.</p><p>Fix: Use React context or URL state management (e.g., <code>useSearchParams</code>) to persist filter selections.</p><p>Impact: affects all faceted search pages</p>"

Add-Comment 4337 "<p><b>Hotfix Deployed</b></p><p>CarrierCode mapping was incorrect for LTL shipments. Fixed in commit <code>abc123f</code>.</p><p>Before/After: <img src='https://via.placeholder.com/500x200.png?text=CarrierCode+Fix+Before+After' alt='fix'/></p>"

Add-Comment 4338 "<p>Confirmed: guest checkout flow bypasses the terms acceptance flag entirely. This is a <b>compliance risk</b> - all orders must have terms accepted.</p><p>Legal team notified. Setting priority to P1.</p>"

Add-Comment 4341 "<p><b>Test Plan Coverage</b></p><p>This plan covers:<br/>- Search regression (12 cases)<br/>- Checkout regression (8 cases)<br/>- Category management (5 cases)</p><p>Execution schedule: Sprint 2 hardening week</p>"

# ── BATCH 5: Add RELATED and PREDECESSOR links ───────────────
Write-Host "--- Batch 5: Adding Cross-Links ---" -ForegroundColor Yellow

# Related: Bug is related to Story
Add-RelatedLink 4336 4330  # Bug filter reset is related to Story filter by stock
Add-RelatedLink 4337 4332  # Bug CarrierCode is related to Story PO number (same checkout area)
Add-RelatedLink 4338 4332  # Bug terms flag is related to Story PO number (checkout)

# Predecessor: Story depends on Feature
Add-RelatedLink 4331 4325 "System.LinkTypes.Dependency-Reverse"  # Story sort depends on Feature catalog sort
Add-RelatedLink 4334 4328 "System.LinkTypes.Dependency-Reverse"  # Story create category depends on Feature hierarchy
Add-RelatedLink 4332 4326 "System.LinkTypes.Dependency-Reverse"  # Story PO number depends on Feature checkout flow

# ── BATCH 6: Create 6 additional items to reach 50 ───────────
Write-Host "--- Batch 6: Creating 6 More Items (Target: 50) ---" -ForegroundColor Yellow

$n1 = New-WorkItem "User Story" "[POC] As a buyer, search skips stop-words" "Resolved" -ParentItem 4324 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 3; "Microsoft.VSTS.Scheduling.StoryPoints" = 2
    "Microsoft.VSTS.Common.ValueArea" = "Business"
    "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1"
} -Description "<p>Search queries should skip common stop-words (the, and, or, is) to improve result relevance.</p>"

$n2 = New-WorkItem "Task" "[POC] Write unit tests for stock filter" "Closed" -ParentItem 4330 -ExtraFields @{
    "Microsoft.VSTS.Common.Activity" = "Testing"
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 4
    "Microsoft.VSTS.Scheduling.CompletedWork" = 4
    "Microsoft.VSTS.Scheduling.RemainingWork" = 0
    "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 1"
}

$n3 = New-WorkItem "Task" "[POC] Performance test checkout flow" "Active" -ParentItem 4332 -ExtraFields @{
    "Microsoft.VSTS.Common.Activity" = "Testing"
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 6
    "Microsoft.VSTS.Scheduling.CompletedWork" = 1
    "Microsoft.VSTS.Scheduling.RemainingWork" = 5
    "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2"
}

$n4 = New-WorkItem "Bug" "[POC] Slow search response on large catalogs" "Active" -ExtraFields @{
    "Microsoft.VSTS.Common.Severity" = "2 - High"; "Microsoft.VSTS.Common.Priority" = 2
    "System.Tags" = "performance;search;regression"
    "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 2"
} -Description "<h3>Repro Steps</h3><ol><li>Navigate to product listing with 10K+ SKUs</li><li>Type a search query</li><li>Wait for results</li></ol><h3>Expected</h3><p>Results in under 2 seconds</p><h3>Actual</h3><p>Takes 8-12 seconds on catalogs with 10K+ products</p>"

$n5 = New-WorkItem "Task" "[POC] Configure CDN for product images" "New" -ParentItem 4323 -ExtraFields @{
    "Microsoft.VSTS.Common.Activity" = "Deployment"
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 8
    "Microsoft.VSTS.Scheduling.RemainingWork" = 8
    "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 3"
}

$n6 = New-WorkItem "Task" "[POC] Document API endpoints for categories" "Closed" -ParentItem 4334 -ExtraFields @{
    "Microsoft.VSTS.Common.Activity" = "Documentation"
    "Microsoft.VSTS.Scheduling.OriginalEstimate" = 3
    "Microsoft.VSTS.Scheduling.CompletedWork" = 3
    "Microsoft.VSTS.Scheduling.RemainingWork" = 0
    "System.IterationPath" = "YASH-DevOps-Serverless\Sprint 3"
}

# ── DONE ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Phase 0 Enrichment Complete!" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  States updated: 18 items now have diverse states"
Write-Host "  Iteration paths: 20 items across Sprint 1/2/3"
Write-Host "  Custom fields: Story Points, ValueArea, Activity, Estimates, Tags"
Write-Host "  Comments: 7 rich comments with HTML/images added"
Write-Host "  Related links: 3 pairs linked"
Write-Host "  Predecessor links: 3 dependency pairs"
Write-Host "  New items: 6 created (total should be ~50)"
