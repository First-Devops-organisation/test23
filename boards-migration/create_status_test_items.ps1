# ============================================================
#  Create Status Test Items - One per state
#  Tests auto-sync of ADO states to GitHub Project statuses
#  Project : YASH-DevOps-Serverless
#  Area    : POC-Migration
#  Run     : .\create_status_test_items.ps1
# ============================================================

$ORG     = "https://dev.azure.com/YashTech-DevOps"
$PROJECT = "YASH-DevOps-Serverless"
$AREA    = "YASH-DevOps-Serverless\POC-Migration"

az devops configure --defaults organization=$ORG project=$PROJECT

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Status Test Items - Testing Auto-Sync" -ForegroundColor Cyan
Write-Host " One item per state" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

$count = 0

function New-StatusItem {
    param([string]$Type, [string]$Title, [string]$TargetState)
    $Script:count++

    Write-Host "[$Script:count] [$Type] State='$TargetState'" -ForegroundColor Yellow
    Write-Host "    $Title" -ForegroundColor White

    $json = az boards work-item create `
        --title "$Title" `
        --type "$Type" `
        --area "$AREA" `
        --assigned-to "urvashi.upadhyay@yash.com" `
        --output json 2>$null

    if (-not $json) {
        Write-Host "    SKIPPED - type not supported" -ForegroundColor Red
        Write-Host ""
        return
    }

    $item = $json | ConvertFrom-Json
    $id = $item.id
    Write-Host "    Created ID: $id" -ForegroundColor Green

    # Set state if not the default 'New'
    if ($TargetState -and $TargetState -ne "New") {
        $result = az boards work-item update --id $id --state "$TargetState" --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    State set: $TargetState" -ForegroundColor Green
        } else {
            Write-Host "    State '$TargetState' not valid for $Type - kept default" -ForegroundColor Red
        }
    } else {
        Write-Host "    State: New (default)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ============================================================
# EPIC states: New, Active, Resolved, Closed, Removed
# ============================================================
New-StatusItem -Type "Epic" -Title "[STATUS] Epic - New State" -TargetState "New"
New-StatusItem -Type "Epic" -Title "[STATUS] Epic - Active State" -TargetState "Active"
New-StatusItem -Type "Epic" -Title "[STATUS] Epic - Resolved State" -TargetState "Resolved"
New-StatusItem -Type "Epic" -Title "[STATUS] Epic - Closed State" -TargetState "Closed"

# ============================================================
# USER STORY states: New, Active, Resolved, Closed, Removed
# ============================================================
New-StatusItem -Type "User Story" -Title "[STATUS] Story - New State" -TargetState "New"
New-StatusItem -Type "User Story" -Title "[STATUS] Story - Active State" -TargetState "Active"
New-StatusItem -Type "User Story" -Title "[STATUS] Story - Resolved State" -TargetState "Resolved"

# ============================================================
# TASK states: New, Active, Closed
# ============================================================
New-StatusItem -Type "Task" -Title "[STATUS] Task - New State" -TargetState "New"
New-StatusItem -Type "Task" -Title "[STATUS] Task - Active State" -TargetState "Active"

# ============================================================
# BUG states: New, Active, Resolved, Closed
# ============================================================
New-StatusItem -Type "Bug" -Title "[STATUS] Bug - New State" -TargetState "New"
New-StatusItem -Type "Bug" -Title "[STATUS] Bug - Active State" -TargetState "Active"
New-StatusItem -Type "Bug" -Title "[STATUS] Bug - Resolved State" -TargetState "Resolved"

# ============================================================
# FEATURE states: New, Active, Resolved, Closed
# ============================================================
New-StatusItem -Type "Feature" -Title "[STATUS] Feature - New State" -TargetState "New"
New-StatusItem -Type "Feature" -Title "[STATUS] Feature - Active State" -TargetState "Active"

# ============================================================
# ISSUE states: Active, Closed
# ============================================================
New-StatusItem -Type "Issue" -Title "[STATUS] Issue - Active State" -TargetState "Active"

# ============================================================
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Created $count status test items!" -ForegroundColor Green
Write-Host ""
Write-Host " Expected GitHub Project Status dropdown:" -ForegroundColor White
Write-Host "   New, Active, Resolved, Closed" -ForegroundColor Yellow
Write-Host ""
Write-Host " Each item should keep its EXACT ADO state" -ForegroundColor White
Write-Host " in the GitHub Project Status field." -ForegroundColor White
Write-Host "====================================================" -ForegroundColor Cyan
