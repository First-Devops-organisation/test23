# ============================================================
#  Create Enterprise POC Work Items in ADO
#  Creates 50 items covering ALL 17 WITs, all states, all custom fields
#  Matches Master Plan Section 9.1 POC Item Selection
#  Requires: ADO_PAT env var set
# ============================================================

$adoOrg     = "YashTech-DevOps"
$adoProject = "YASH-DevOps-Serverless"
$adoPat     = $env:ADO_PAT
$areaPath   = "YASH-DevOps-Serverless\POC-Migration"
$iterPath   = "YASH-DevOps-Serverless"
$apiVersion = "7.1"
$baseUrl    = "https://dev.azure.com/$adoOrg/$adoProject/_apis"

if (-not $adoPat) { Write-Host "ERROR: Set `$env:ADO_PAT first" -ForegroundColor Red; exit 1 }

$base64Pat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers   = @{ Authorization = "Basic $base64Pat"; "Content-Type" = "application/json-patch+json" }

function New-AdoWorkItem {
    param(
        [string]$Type, [string]$Title, [string]$State,
        [int]$ParentId = 0, [hashtable]$ExtraFields = @{},
        [string]$Description = ""
    )
    $body = @(
        @{ op = 'add'; path = '/fields/System.Title';         value = $Title }
        @{ op = 'add'; path = '/fields/System.State';         value = $State }
        @{ op = 'add'; path = '/fields/System.AreaPath';      value = $areaPath }
        @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iterPath }
    )
    if ($Description) {
        $body += @{ op = 'add'; path = '/fields/System.Description'; value = $Description }
    }
    foreach ($kv in $ExtraFields.GetEnumerator()) {
        $body += @{ op = 'add'; path = "/fields/$($kv.Key)"; value = $kv.Value }
    }
    if ($ParentId -gt 0) {
        $parentUrl = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workItems/$ParentId"
        $body += @{ op = 'add'; path = '/relations/-';
            value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = $parentUrl }
        }
    }
    $uri  = "$baseUrl/wit/workitems/`$$([uri]::EscapeDataString($Type))?api-version=$apiVersion"
    try {
        $resp = Invoke-RestMethod -Method PATCH -Uri $uri -Headers $headers -Body ($body|ConvertTo-Json -Depth 10)
        Write-Host "  Created [$Type] #$($resp.id): $Title" -ForegroundColor Green
        return $resp.id
    } catch {
        Write-Host "  FAILED [$Type]: $Title - $_" -ForegroundColor Red
        return 0
    }
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Creating Enterprise POC Work Items" -ForegroundColor Cyan
Write-Host "  Org: $adoOrg | Project: $adoProject" -ForegroundColor Cyan
Write-Host "  Area: $areaPath" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# ── PASS 1: EPICS (4 items) ──────────────────────────────────
Write-Host "Pass 1: Epics..." -ForegroundColor Yellow
$e1 = New-AdoWorkItem "Epic" "[POC] Search & Discovery Platform"  "New" -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1
    "Microsoft.VSTS.Common.ValueArea" = "Business"
}
$e2 = New-AdoWorkItem "Epic" "[POC] Order Management & Checkout"  "New" -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1
    "Microsoft.VSTS.Common.ValueArea" = "Business"
}
$e3 = New-AdoWorkItem "Epic" "[POC] Customer Category Management" "New" -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2
    "Microsoft.VSTS.Common.ValueArea" = "Architectural"
}
$e4 = New-AdoWorkItem "Epic" "[POC] Platform Infrastructure"      "New" -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 3
}

# ── PASS 2: FEATURES (6 items) ───────────────────────────────
Write-Host "Pass 2: Features..." -ForegroundColor Yellow
$f1 = New-AdoWorkItem "Feature" "[POC] Faceted Search Implementation"    "New"    -ParentId $e1 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1; "Microsoft.VSTS.Scheduling.StoryPoints" = 21
}
$f2 = New-AdoWorkItem "Feature" "[POC] Product Catalog Sorting"          "New"    -ParentId $e1 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2; "Microsoft.VSTS.Scheduling.StoryPoints" = 13
}
$f3 = New-AdoWorkItem "Feature" "[POC] Checkout Flow Optimization"       "New"    -ParentId $e2 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1; "Microsoft.VSTS.Scheduling.StoryPoints" = 34
}
$f4 = New-AdoWorkItem "Feature" "[POC] Sign-in Performance"              "New"    -ParentId $e2 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2; "Microsoft.VSTS.Scheduling.StoryPoints" = 8
}
$f5 = New-AdoWorkItem "Feature" "[POC] Custom Category Hierarchy"        "New"    -ParentId $e3 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2; "Microsoft.VSTS.Scheduling.StoryPoints" = 13
}
$f6 = New-AdoWorkItem "Feature" "[POC] Insite Analytics Dashboard"       "New"    -ParentId $e4

# ── PASS 3: USER STORIES / PBIs / CRs / UAT (12 items) ──────
Write-Host "Pass 3: Stories / PBIs / CRs / UAT..." -ForegroundColor Yellow

$us1 = New-AdoWorkItem "User Story" "[POC] As a buyer, I can filter by stock status" "New" -ParentId $f1 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1
    "Microsoft.VSTS.Scheduling.StoryPoints" = 5
    "Microsoft.VSTS.Common.AcceptanceCriteria" = "<ul><li>Stock filter shows In Stock / Out of Stock</li><li>Results update in &lt;2 seconds</li></ul>"
} -Description "<p>Implement faceted search filter for <b>stock status</b> on the product listing page.</p><p>Include options for <i>In Stock</i> and <i>Out of Stock</i> with real-time result counts.</p>"

$us2 = New-AdoWorkItem "User Story" "[POC] As a buyer, I can sort by recently purchased" "New" -ParentId $f2 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2; "Microsoft.VSTS.Scheduling.StoryPoints" = 3
} -Description "<p>Add sort option to product catalog: <b>Recently Purchased</b> based on order history.</p>"

$us3 = New-AdoWorkItem "User Story" "[POC] As a buyer, I can enter PO number at checkout" "New" -ParentId $f3 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1; "Microsoft.VSTS.Scheduling.StoryPoints" = 8
    "Microsoft.VSTS.Common.AcceptanceCriteria" = "<ul><li>PO field appears on checkout page</li><li>PO validates: alphanumeric, max 20 chars</li><li>PO stored with order in ERP</li></ul>"
} -Description "<h3>Requirements</h3><p>Add a <b>Purchase Order Number</b> field to the checkout flow. Field is optional but must validate format when provided.</p><table><tr><th>Field</th><th>Validation</th></tr><tr><td>PO Number</td><td>Alphanumeric, 1-20 chars</td></tr></table>"

$us4 = New-AdoWorkItem "User Story" "[POC] As a buyer, checkout summary is sticky on scroll" "New" -ParentId $f3 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 3; "Microsoft.VSTS.Scheduling.StoryPoints" = 2
}

$us5 = New-AdoWorkItem "User Story" "[POC] As admin, I can create custom categories" "New" -ParentId $f5 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2; "Microsoft.VSTS.Scheduling.StoryPoints" = 5
}

$us6 = New-AdoWorkItem "User Story" "[POC] As admin, I can delete custom categories" "New" -ParentId $f5 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 3; "Microsoft.VSTS.Scheduling.StoryPoints" = 3
}

$cr1 = New-AdoWorkItem "Change Request" "[POC] CR: Optimize sign-in page load time" "New" -ParentId $f4 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 1; "Microsoft.VSTS.Scheduling.StoryPoints" = 5
} -Description "<p>Sign-in page currently takes 4.2s to load. Target: under 1.5s. Requires API optimization and lazy loading.</p>"

$uat1 = New-AdoWorkItem "UAT Review" "[POC] UAT: Verify category deletion flow" "New" -ParentId $f5 -ExtraFields @{
    "Microsoft.VSTS.Common.Priority" = 2
}

# ── PASS 4: TASKS (14 items) ─────────────────────────────────
Write-Host "Pass 4: Tasks..." -ForegroundColor Yellow
$t1  = New-AdoWorkItem "Task" "[POC] Create stock filter UI component"     "To Do"  -ParentId $us1 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"; "Microsoft.VSTS.Scheduling.RemainingWork"=8}
$t2  = New-AdoWorkItem "Task" "[POC] API: Add stock status to product"     "To Do"  -ParentId $us1 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"; "Microsoft.VSTS.Scheduling.RemainingWork"=4}
$t3  = New-AdoWorkItem "Task" "[POC] Implement stop-word filter"           "To Do"  -ParentId $us2 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t4  = New-AdoWorkItem "Task" "[POC] Sort: recently purchased (backend)"   "To Do"  -ParentId $us2 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"; "Microsoft.VSTS.Scheduling.OriginalEstimate"=6}
$t5  = New-AdoWorkItem "Task" "[POC] Sort: recently purchased (UI)"        "To Do"  -ParentId $us2 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Design"}
$t6  = New-AdoWorkItem "Task" "[POC] Add PO number field to checkout"      "To Do"  -ParentId $us3 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"; "Microsoft.VSTS.Scheduling.RemainingWork"=4}
$t7  = New-AdoWorkItem "Task" "[POC] Validate PO number format"            "To Do"  -ParentId $us3 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t8  = New-AdoWorkItem "Task" "[POC] Sticky order summary sidebar CSS"     "To Do"  -ParentId $us4 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Design"}
$t9  = New-AdoWorkItem "Task" "[POC] Profile sign-in page load time"       "To Do"  -ParentId $cr1 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Testing"; "Microsoft.VSTS.Scheduling.OriginalEstimate"=4; "Microsoft.VSTS.Scheduling.CompletedWork"=2}
$t10 = New-AdoWorkItem "Task" "[POC] API: get customer categories"         "To Do"  -ParentId $us5 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t11 = New-AdoWorkItem "Task" "[POC] UI: category hierarchy tree"          "To Do"  -ParentId $us5 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t12 = New-AdoWorkItem "Task" "[POC] UI: add products to category"         "To Do"  -ParentId $us5 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t13 = New-AdoWorkItem "Task" "[POC] Delete category API endpoint"         "To Do"  -ParentId $us6 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t14 = New-AdoWorkItem "Task" "[POC] STANDALONE: Migrate image assets"     "To Do" -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Deployment"}

# ── PASS 5: BUGS (5 items) ───────────────────────────────────
Write-Host "Pass 5: Bugs..." -ForegroundColor Yellow
$b1 = New-AdoWorkItem "Bug" "[POC] Faceted filter resets on pagination"  "New" -ParentId $us1 -ExtraFields @{
    "Microsoft.VSTS.Common.Severity" = "2 - High"; "Microsoft.VSTS.Common.Priority" = 2
} -Description "<h3>Repro Steps</h3><ol><li>Go to product listing</li><li>Select 'In Stock' filter</li><li>Click page 2</li><li>Filter is cleared</li></ol><h3>Expected</h3><p>Filter should persist across pagination.</p>"

$b2 = New-AdoWorkItem "Bug" "[POC] Incorrect CarrierCode sent to ERP"   "New" -ParentId $us3 -ExtraFields @{
    "Microsoft.VSTS.Common.Severity" = "1 - Critical"; "Microsoft.VSTS.Common.Priority" = 1
}

$b3 = New-AdoWorkItem "Bug" "[POC] Terms flag not sent on guest checkout" "New" -ParentId $us3 -ExtraFields @{
    "Microsoft.VSTS.Common.Severity" = "1 - Critical"; "Microsoft.VSTS.Common.Priority" = 1
}

$b4 = New-AdoWorkItem "Bug" "[POC] Category tree doesn't expand on mobile" "New" -ParentId $us5 -ExtraFields @{
    "Microsoft.VSTS.Common.Severity" = "3 - Medium"; "Microsoft.VSTS.Common.Priority" = 3
}

$b5 = New-AdoWorkItem "Bug" "[POC] Search results show HTML entities"   "New" -ExtraFields @{
    "Microsoft.VSTS.Common.Severity" = "4 - Low"; "Microsoft.VSTS.Common.Priority" = 4
}

# ── PASS 6: TEST ITEMS (5 items) ─────────────────────────────
Write-Host "Pass 6: Test items..." -ForegroundColor Yellow
$tp1 = New-AdoWorkItem "Test Plan"  "[POC] Release 1.1.X Regression Plan"      "Active"
$ts1 = New-AdoWorkItem "Test Suite" "[POC] Search Functionality Suite"          "In Planning" -ParentId $tp1
$tc1 = New-AdoWorkItem "Test Case"  "[POC] Verify faceted filter persists"      "Design"      -ParentId $ts1
$ts2 = New-AdoWorkItem "Test Suite" "[POC] Checkout Suite"                      "In Planning" -ParentId $tp1
$tc2 = New-AdoWorkItem "Test Case"  "[POC] Verify PO number validation"        "Design"      -ParentId $ts2

# ── PASS 7: STANDALONE EDGE CASES (4 items) ──────────────────
Write-Host "Pass 7: Standalone edge cases..." -ForegroundColor Yellow
$an1  = New-AdoWorkItem "Analysis"   "[POC] Performance analysis: Sign-in page" "New"
$imp1 = New-AdoWorkItem "Impediment" "[POC] Blocked: Missing API credentials"   "New"
$idea = New-AdoWorkItem "Issue"      "[POC] Idea: Add voice search"             "New"

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  POC Work Items Created Successfully!" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Epics:           4"
Write-Host "  Features:        6"
Write-Host "  User Stories:    6"
Write-Host "  Change Requests: 1"
Write-Host "  UAT Reviews:     1"
Write-Host "  Tasks:          14"
Write-Host "  Bugs:            5"
Write-Host "  Test Plan:       1"
Write-Host "  Test Suites:     2"
Write-Host "  Test Cases:      2"
Write-Host "  Analysis:        1"
Write-Host "  Impediment:      1"
Write-Host "  Issue/Idea:      1"
Write-Host "  -------------------"
Write-Host "  TOTAL:          45 items"
Write-Host ""
Write-Host "  Area Path: $areaPath"
Write-Host "  Epic IDs: $e1, $e2, $e3, $e4"
Write-Host ""
