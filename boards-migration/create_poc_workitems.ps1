# create-poc-workitems.ps1
# Run from the boards-migration/ directory
# Requires: ADO_PAT env var set, PowerShell 7+

$adoOrg     = "your-organisation"
$adoProject = "BunzlEcom-GHA-POC"
$adoPat     = $env:ADO_PAT
$apiVersion = "7.1"
$baseUrl    = "https://dev.azure.com/$adoOrg/$adoProject/_apis"

# Base64 encode PAT for Basic auth
$base64Pat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers   = @{ Authorization = "Basic $base64Pat"; "Content-Type" = "application/json-patch+json" }

# Helper: create a work item
function New-AdoWorkItem {
  param([string]$Type, [string]$Title, [string]$State, [int]$ParentId = 0,
        [string]$AreaPath = $adoProject, [string]$IterPath = $adoProject,
        [hashtable]$ExtraFields = @{})
  $body = @(
    @{ op = 'add'; path = '/fields/System.Title';         value = $Title }
    @{ op = 'add'; path = '/fields/System.State';         value = $State }
    @{ op = 'add'; path = '/fields/System.AreaPath';      value = $AreaPath }
    @{ op = 'add'; path = '/fields/System.IterationPath'; value = $IterPath }
  )
  foreach ($kv in $ExtraFields.GetEnumerator()) {
    $body += @{ op = 'add'; path = "/fields/$($kv.Key)"; value = $kv.Value }
  }
  if ($ParentId -gt 0) {
    $parentUrl = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workItems/$ParentId"
    $body += @{ op = 'add'; path = '/relations/-';
      value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = $parentUrl }
    }
  }
  $uri  = "$baseUrl/wit/workitems/`$$Type`?api-version=$apiVersion"
  $resp = Invoke-RestMethod -Method PATCH -Uri $uri -Headers $headers -Body ($body|ConvertTo-Json -Depth 10)
  Write-Host "Created [$Type] #$($resp.id): $Title"
  return $resp.id
}

# ── Create in hierarchy order ─────────────────────────────────────

# Pass 1: Epics
$e1 = New-AdoWorkItem "Epic"    "[POC-EPIC-01] Search & Discovery Platform"      "New"
$e2 = New-AdoWorkItem "Epic"    "[POC-EPIC-02] Order Management & Checkout"      "Active"
$e3 = New-AdoWorkItem "Epic"    "[POC-EPIC-03] Customer Category Management"     "Closed"
$e4 = New-AdoWorkItem "Epic"    "[POC-EPIC-04] Platform & Infrastructure"        "Removed"

# Pass 2: Features (parent = Epic)
$f1 = New-AdoWorkItem "Feature" "[POC-FT-01] Faceted Search Implementation"      "New"       -ParentId $e1
$f2 = New-AdoWorkItem "Feature" "[POC-FT-02] Product Catalog Sorting"            "Active"    -ParentId $e1
$f3 = New-AdoWorkItem "Feature" "[POC-FT-03] Checkout Flow"                      "Active"    -ParentId $e2
$f4 = New-AdoWorkItem "Feature" "[POC-FT-04] Change Request: Performance"        "New"       -ParentId $e2
$f5 = New-AdoWorkItem "Feature" "[POC-FT-05] Custom Category Hierarchy"          "Closed"    -ParentId $e3
$f6 = New-AdoWorkItem "Feature" "[POC-FT-06] Removed Feature: Insite Analytics"  "Removed"   -ParentId $e4

# Pass 3: PBIs / Stories / CRs (parent = Feature)
$p1 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-01] Faceted Search: Stock/Non-Stock"  "Committed" -ParentId $f1
$p2 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-02] Skip stop-words in search"        "Done"      -ParentId $f1
$p3 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-03] Catalog sort: recently purchased" "New"       -ParentId $f2
$p4 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-04] Provide PO number with order"     "Done"      -ParentId $f3
$p5 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-05] Sticky layout on checkout page"   "Done"      -ParentId $f3
$cr1= New-AdoWorkItem "Change Request"       "[POC-CR-01] Performance: Sign-in Page"         "New"       -ParentId $f4
$p6 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-06] Create custom category"           "Done"      -ParentId $f5
$p7 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-07] Delete customer category"         "Done"      -ParentId $f5
$p8 = New-AdoWorkItem "Product Backlog Item" "[POC-PBI-08] Insite Analytics (Removed)"       "Removed"   -ParentId $f6

# Pass 4: Tasks & Bugs (parent = PBI / Feature / standalone)
$t1 = New-AdoWorkItem "Task" "[POC-T-01] Create stock filter UI component"   "To Do"      -ParentId $p1 -ExtraFields @{"Microsoft.VSTS.Common.Activity"="Development"}
$t2 = New-AdoWorkItem "Task" "[POC-T-02] API: Add stock status to product"   "Done"       -ParentId $p1
$b1 = New-AdoWorkItem "Bug"  "[POC-B-01] Faceted filter resets on pagination" "Active"    -ParentId $p1 -ExtraFields @{"Microsoft.VSTS.Common.Severity"="2 - High"}
$t3 = New-AdoWorkItem "Task" "[POC-T-03] Implement stop-word filter"          "Done"       -ParentId $p2
$t4 = New-AdoWorkItem "Task" "[POC-T-04] Sort: recently purchased (backend)"  "To Do"      -ParentId $p3
$t5 = New-AdoWorkItem "Task" "[POC-T-05] Sort: recently purchased (UI)"       "To Do"      -ParentId $p3
$t6 = New-AdoWorkItem "Task" "[POC-T-06] Add PO number field to checkout"     "Done"       -ParentId $p4
$t7 = New-AdoWorkItem "Task" "[POC-T-07] Validate PO number format"           "Done"       -ParentId $p4
$t8 = New-AdoWorkItem "Task" "[POC-T-08] Sticky order summary sidebar"        "Done"       -ParentId $p5
$b2 = New-AdoWorkItem "Bug"  "[POC-B-02] Incorrect CarrierCode sent to API"   "Done"       -ParentId $p4 -ExtraFields @{"Microsoft.VSTS.Common.Severity"="1 - Critical"}
$b3 = New-AdoWorkItem "Bug"  "[POC-B-03] Incorrect Terms Flag sent to API"    "Done"       -ParentId $p4 -ExtraFields @{"Microsoft.VSTS.Common.Severity"="1 - Critical"}
$t9 = New-AdoWorkItem "Task" "[POC-T-09] Profile sign-in page load time"      "To Do"      -ParentId $cr1
$t10= New-AdoWorkItem "Task" "[POC-T-10] API: get customer categories"        "Done"       -ParentId $p6
$t11= New-AdoWorkItem "Task" "[POC-T-11] UI: category hierarchy"              "Done"       -ParentId $p6
$t12= New-AdoWorkItem "Task" "[POC-T-12] UI: add products to category"        "Done"       -ParentId $p6
$t13= New-AdoWorkItem "Task" "[POC-T-13] Delete category API endpoint"        "Done"       -ParentId $p7
$uat1=New-AdoWorkItem "UAT Review" "[POC-UAT-01] UAT: Custom category delete" "Done"       -ParentId $p7

# Pass 5: Test hierarchy (standalone — not under Epics)
$tp1 = New-AdoWorkItem "Test Plan"  "[POC-TP-01] Release 1.1.X Regression"   "Active"
$ts1 = New-AdoWorkItem "Test Suite" "[POC-TS-01] Search Functionality Suite"  "In Planning" -ParentId $tp1
$tc1 = New-AdoWorkItem "Test Case"  "[POC-TC-01] Verify faceted filter"       "Design"      -ParentId $ts1
$tc2 = New-AdoWorkItem "Test Case"  "[POC-TC-02] Verify stop-word skip"       "Design"      -ParentId $ts1
$ts2 = New-AdoWorkItem "Test Suite" "[POC-TS-02] Checkout Suite"              "In Planning" -ParentId $tp1
$tc3 = New-AdoWorkItem "Test Case"  "[POC-TC-03] Verify PO number submission" "Design"      -ParentId $ts2

# Pass 6: Standalone items (no parent — edge cases)
$an1 = New-AdoWorkItem "Analysis"  "[POC-AN-01] Perf analysis: Sign-in"       "Committed"
$imp1= New-AdoWorkItem "Impediment" "[POC-IMP-01] Blocked: API credentials"   "Open"
$t14 = New-AdoWorkItem "Task"       "[POC-T-14] STANDALONE: Migrate images"   "Blocked"

Write-Host "✅ All POC work items created successfully."
Write-Host "Epic IDs: $e1, $e2, $e3, $e4"
Write-Host "Total items: 48 (add 2 more manually with rich HTML + attachments)"
