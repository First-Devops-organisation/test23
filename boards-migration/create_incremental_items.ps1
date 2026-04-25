# ============================================================
#  Create ADDITIONAL POC Work Items for Incremental Testing
#  Project : YASH-DevOps-Serverless
#  Area    : POC-Migration
#  Run     : .\create_incremental_items.ps1
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
Write-Host " Incremental POC Items - YASH-DevOps-Serverless" -ForegroundColor Cyan
Write-Host " These items will be picked up by the NEXT pipeline" -ForegroundColor Cyan
Write-Host " run with resume=true (incremental migration)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

function Get-RandomUser { return $USERS | Get-Random }

function New-WorkItem {
    param([string]$Type, [string]$Title, [string]$State, [string]$Comment1, [string]$Comment2)
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
        Write-Host "    SKIPPED - type not supported" -ForegroundColor Red
        Write-Host ""
        return
    }

    $item = $json | ConvertFrom-Json
    $id   = $item.id
    Write-Host "    Created ID : $id" -ForegroundColor Green

    # Set state if not default
    if ($State -and $State -ne "New") {
        az boards work-item update --id $id --state "$State" --output none 2>$null
        Write-Host "    State set  : $State" -ForegroundColor DarkGray
    }

    if ($Comment1) {
        az boards work-item update --id $id --discussion "$Comment1" --output none 2>$null
        Write-Host "    Comment 1 added" -ForegroundColor DarkGray
    }
    if ($Comment2) {
        az boards work-item update --id $id --discussion "$Comment2" --output none 2>$null
        Write-Host "    Comment 2 added" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ============================================================
# NEW WORK ITEMS FOR INCREMENTAL TEST
# ============================================================

New-WorkItem `
    -Type "Epic" `
    -Title "[INC] Epic - Cloud Infrastructure Migration to Azure" `
    -State "Active" `
    -Comment1 "Kicking off cloud infra migration. All teams must submit their resource inventory by Sprint 2." `
    -Comment2 "Architecture review completed. Approved by CTO. Budget allocated for Q3."

New-WorkItem `
    -Type "Feature" `
    -Title "[INC] Feature - CI/CD Pipeline Automation with GitHub Actions" `
    -State "Active" `
    -Comment1 "Feature covers migration from Azure Pipelines to GitHub Actions for all microservices." `
    -Comment2 "POC completed for 3 services. Remaining 12 services to be migrated in Sprint 4-6."

New-WorkItem `
    -Type "User Story" `
    -Title "[INC] Story - As a developer I want automated PR checks so code quality is enforced" `
    -Comment1 "AC: PR must pass linting, unit tests, and security scan before merge is allowed." `
    -Comment2 "Implementation done. PR template added. CODEOWNERS file configured."

New-WorkItem `
    -Type "Bug" `
    -Title "[INC] Bug - API Gateway returns 503 under high load" `
    -State "Active" `
    -Comment1 "Reproduced at 500 concurrent requests. Connection pool exhausted. Logs attached." `
    -Comment2 "Root cause: max pool size was 10. Increased to 100. Load test passed at 2000 concurrent."

New-WorkItem `
    -Type "Task" `
    -Title "[INC] Task - Configure Terraform remote state in Azure Storage" `
    -Comment1 "Storage account created. Container name: tfstate. Access key stored in Key Vault." `
    -Comment2 "Terraform init successful. State file migrated from local to remote. PR #178 merged."

# ============================================================
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " 5 new incremental items created!" -ForegroundColor Green
Write-Host ""
Write-Host " Now run the pipeline with:" -ForegroundColor White
Write-Host "   dryRun  = false" -ForegroundColor Yellow
Write-Host "   resume  = true   (default)" -ForegroundColor Yellow
Write-Host ""
Write-Host " Expected result:" -ForegroundColor White
Write-Host "   - 10 existing items: SKIPPED (already migrated)" -ForegroundColor DarkGray
Write-Host "   - 5 new items:       MIGRATED" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
