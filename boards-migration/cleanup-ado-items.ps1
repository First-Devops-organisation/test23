# ============================================================
#  Cleanup ADO Work Items in POC-Migration Area
#  Deletes ALL work items under the specified area path
#  Run: .\cleanup-ado-items.ps1
# ============================================================

$ORG     = "https://dev.azure.com/YashTech-DevOps"
$PROJECT = "YASH-DevOps-Serverless"
$AREA    = "YASH-DevOps-Serverless\POC-Migration"

az devops configure --defaults organization=$ORG project=$PROJECT

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  ADO Cleanup - Delete all items in $AREA" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# Query all work items in the area path
$wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.AreaPath] UNDER '$AREA' ORDER BY [System.Id]"
$result = az boards query --wiql $wiql --output json 2>$null | ConvertFrom-Json

if (-not $result -or $result.Count -eq 0) {
    Write-Host "No work items found in $AREA. Already clean!" -ForegroundColor Green
    exit 0
}

$ids = @($result | ForEach-Object { $_.id })
Write-Host "Found $($ids.Count) work items to delete" -ForegroundColor Yellow
Write-Host ""

$deleted = 0
foreach ($id in $ids) {
    $item = az boards work-item show --id $id --output json 2>$null | ConvertFrom-Json
    $title = if ($item) { $item.fields.'System.Title' } else { "Unknown" }
    $type = if ($item) { $item.fields.'System.WorkItemType' } else { "?" }
    
    az boards work-item delete --id $id --yes --destroy --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        $deleted++
        Write-Host "  Deleted #$id [$type]: $title" -ForegroundColor DarkGray
    } else {
        # Try without --destroy (some orgs don't allow permanent delete)
        az boards work-item delete --id $id --yes --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $deleted++
            Write-Host "  Recycled #$id [$type]: $title" -ForegroundColor DarkGray
        } else {
            Write-Host "  FAILED #$id [$type]: $title" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Deleted $deleted / $($ids.Count) items from ADO" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
