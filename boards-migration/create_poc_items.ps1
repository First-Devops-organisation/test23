# ============================================================
#  Migration POC - Full Work Item Creator
#  Project : YASH-DevOps-Serverless
#  Area    : POC-Migration
#  Run     : .\create_poc_items.ps1
# ============================================================

$ORG     = "https://dev.azure.com/YashTech-DevOps"
$PROJECT = "YASH-DevOps-Serverless"
$AREA    = "YASH-DevOps-Serverless\POC-Migration"

$USERS = @(
    "ankit.panwar@yash.com",
    "urvashi.upadhyay@yash.com",
    "varsha.patil@yash.com",
    "akash.kamble@yash.com"
)

az devops configure --defaults organization=$ORG project=$PROJECT

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " POC Work Item Creator - YASH-DevOps-Serverless" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# ── Pick a random user from the list ────────────────────────
function Get-RandomUser {
    return $USERS | Get-Random
}

# ── Create one work item then add 2 comments ────────────────
function New-WorkItem {
    param(
        [string]$Type,
        [string]$Title,
        [string]$Comment1,
        [string]$Comment2
    )

    $assignee = Get-RandomUser
    Write-Host ">>> [$Type]" -ForegroundColor Yellow
    Write-Host "    Title    : $Title" -ForegroundColor White
    Write-Host "    Assignee : $assignee" -ForegroundColor Gray

    $json = az boards work-item create `
        --title "$Title" `
        --type "$Type" `
        --area "$AREA" `
        --assigned-to "$assignee" `
        --output json 2>$null

    if (-not $json) {
        Write-Host "    SKIPPED - type not in this process template" -ForegroundColor Red
        Write-Host ""
        return
    }

    $item = $json | ConvertFrom-Json
    $id   = $item.id
    Write-Host "    Created ID : $id" -ForegroundColor Green

    az boards work-item update --id $id --discussion "$Comment1" --output none 2>$null
    Write-Host "    Comment 1 added" -ForegroundColor DarkGray

    az boards work-item update --id $id --discussion "$Comment2" --output none 2>$null
    Write-Host "    Comment 2 added" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
# EPIC
# ============================================================
New-WorkItem `
    -Type "Epic" `
    -Title "[POC] Epic - eCommerce Platform Modernization" `
    -Comment1 "Starting this epic to track the full platform migration. All teams please review scope before Sprint 1." `
    -Comment2 "Confirmed with leadership. This is P0 for Q2. Please align the project stories under this epic."

# ============================================================
# FEATURE
# ============================================================
New-WorkItem `
    -Type "Feature" `
    -Title "[POC] Feature - Faceted Search and Stock Filter" `
    -Comment1 "Feature scoped to include PLP stock filter and manufacturer display. Mockups shared in Confluence." `
    -Comment2 "QA team please ensure regression suite covers all filter combinations. Edge case is zero stock items."

# ============================================================
# USER STORY
# ============================================================
New-WorkItem `
    -Type "User Story" `
    -Title "[POC] Story - Show inventory status on Product List Page" `
    -Comment1 "AC: Given user is on PLP when stock is 0 then show Out of Stock badge. Verified with Varsha." `
    -Comment2 "Dev complete. Moving to Release Testing. Akash please pick up QA on this by EOD Thursday."

# ============================================================
# TASK
# ============================================================
New-WorkItem `
    -Type "Task" `
    -Title "[POC] Task - Add inventory API call to PLP component" `
    -Comment1 "API endpoint is /api/v2/inventory with SKU param. Auth header required. Postman collection is in repo." `
    -Comment2 "Done. PR raised number 342. Needs 2 approvals before merge. Linked to parent story."

# ============================================================
# BUG
# ============================================================
New-WorkItem `
    -Type "Bug" `
    -Title "[POC] Bug - Login page takes 8 seconds on first load" `
    -Comment1 "Reproduced on Chrome 124 and Edge 121. Not reproducible on Firefox. Auth token fetch is blocking render." `
    -Comment2 "Root cause is synchronous token validation on page load. Fix is async with loading state. ETA 2 days."

# ============================================================
# TEST PLAN
# ============================================================
New-WorkItem `
    -Type "Test Plan" `
    -Title "[POC] Test Plan - Release 2.0 Full Regression" `
    -Comment1 "Test plan covers 47 test cases across Search Cart Checkout and Auth modules. Owner is Varsha." `
    -Comment2 "Execution starts Sprint 6 Day 3. Any blockers raise in the qa-channel immediately."

# ============================================================
# TEST SUITE
# ============================================================
New-WorkItem `
    -Type "Test Suite" `
    -Title "[POC] Test Suite - Search and Filter Regression" `
    -Comment1 "Suite has 12 test cases. All parameterized. Data set A for smoke run, Data set B for full regression." `
    -Comment2 "Last run 11 of 12 passed. Failing TC-047 is the zero stock edge case. Fix in progress by Akash."

# ============================================================
# TEST CASE
# ============================================================
New-WorkItem `
    -Type "Test Case" `
    -Title "[POC] Test Case - Verify Out of Stock badge on PLP" `
    -Comment1 "Steps: 1 Navigate to PLP. 2 Filter by category. 3 Verify badge shows on items with stock zero." `
    -Comment2 "PASSED in staging environment. Ready for prod smoke test after next deployment."

# ============================================================
# ISSUE
# ============================================================
New-WorkItem `
    -Type "Issue" `
    -Title "[POC] Issue - Default shipping service returns 404" `
    -Comment1 "Ticket INC0129686. Affects 3 percent of checkout sessions. Started after deploy on Apr 15. Logs in Splunk." `
    -Comment2 "Hotfix deployed to staging. Monitoring for 24 hours before prod push. Ankit to approve prod deployment."

# ============================================================
# IMPEDIMENT
# ============================================================
New-WorkItem `
    -Type "Impediment" `
    -Title "[POC] Impediment - Azure AI Foundry access pending IT approval" `
    -Comment1 "Request submitted Apr 10. IT ticket CHG0041122. Blocking 3 stories in Sprint 5. Escalated to manager." `
    -Comment2 "Approval received. Access granted to Urvashi and Varsha. Akash please re-attempt Foundry workspace setup."

# ============================================================
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " All POC items created successfully!" -ForegroundColor Green
Write-Host ""
Write-Host " Go to: https://dev.azure.com/YashTech-DevOps/YASH-DevOps-Serverless" -ForegroundColor White
Write-Host " Boards > Work Items > Filter by Area = POC-Migration" -ForegroundColor White
Write-Host "====================================================" -ForegroundColor Cyan