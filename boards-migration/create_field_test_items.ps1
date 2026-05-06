# ============================================================
#  Field-Coverage Test Items
#  Creates ONE item per work item type with ALL fields filled
#  Purpose: Validate every field migrates correctly
#  Run: .\create_field_test_items.ps1 -AdoPat "YOUR_PAT"
# ============================================================
param(
    [Parameter(Mandatory)][string]$AdoPat
)

$ORG     = "YashTech-DevOps"
$PROJECT = "YASH-DevOps-Serverless"
$AREA    = "YASH-DevOps-Serverless\POC-Migration"
$ITER    = "YASH-DevOps-Serverless\Serverless_S3"

$b64     = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers = @{ Authorization = "Basic $b64"; "Content-Type" = "application/json-patch+json" }

$createdItems = [System.Collections.Generic.List[PSCustomObject]]::new()

function New-AdoItem {
    param([string]$Type, [string]$Title, [array]$Fields)
    $body = (@(
        @{ op="add"; path="/fields/System.Title";         value=$Title }
        @{ op="add"; path="/fields/System.AreaPath";      value=$AREA  }
        @{ op="add"; path="/fields/System.IterationPath"; value=$ITER  }
        @{ op="add"; path="/fields/System.AssignedTo";    value="urvashi.upadhyay@yash.com" }
        @{ op="add"; path="/fields/System.Tags";          value="field-test; migration-test; poc" }
    ) + $Fields) | ConvertTo-Json -Depth 10

    $typeEnc = [Uri]::EscapeDataString($Type)
    $uri     = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/`$$typeEnc`?api-version=7.1"
    try {
        $r = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
        Write-Host "  ✅ [$Type] #$($r.id) — $Title" -ForegroundColor Green
        return $r
    } catch {
        Write-Host "  ❌ [$Type] FAILED: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Set-AdoState {
    param([int]$Id, [string]$State, [string]$Reason="")
    $fields = @(@{ op="add"; path="/fields/System.State"; value=$State })
    if ($Reason) { $fields += @{ op="add"; path="/fields/System.Reason"; value=$Reason } }
    $body = $fields | ConvertTo-Json -Depth 5
    $uri  = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/$Id`?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null }
    catch { Write-Host "    ⚠️  State '$State' failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Link-Parent {
    param([int]$ChildId, [int]$ParentId)
    $body = @(@{
        op    = "add"
        path  = "/relations/-"
        value = @{
            rel        = "System.LinkTypes.Hierarchy-Reverse"
            url        = "https://dev.azure.com/$ORG/_apis/wit/workitems/$ParentId"
            attributes = @{ comment = "Field test parent link" }
        }
    }) | ConvertTo-Json -Depth 10
    $uri = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/$ChildId`?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null }
    catch { Write-Host "    ⚠️  Parent link failed: $_" -ForegroundColor Yellow }
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Field-Coverage Test Item Creator" -ForegroundColor Cyan
Write-Host "  Project: $PROJECT | Area: $AREA" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ── 1. EPIC ──────────────────────────────────────────────────
Write-Host "`n[1/13] Creating EPIC..." -ForegroundColor Magenta
$epic = New-AdoItem -Type "Epic" -Title "[FIELD-TEST] Epic — Cloud Migration Initiative" -Fields @(
    @{ op="add"; path="/fields/System.Description";                    value="<b>Epic Description</b><p>This epic covers full cloud migration scope.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";        value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";       value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Risk";            value="2 - Medium" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.TargetDate";  value="2025-12-31T00:00:00Z" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StartDate";   value="2025-06-01T00:00:00Z" }
)
if ($epic) {
    Set-AdoState -Id $epic.id -State "Active"
    $createdItems.Add([PSCustomObject]@{ Type="Epic"; Id=$epic.id; Title=$epic.fields.'System.Title'; State="Active" })
}

# ── 2. FEATURE ───────────────────────────────────────────────
Write-Host "`n[2/13] Creating FEATURE..." -ForegroundColor Magenta
$feature = New-AdoItem -Type "Feature" -Title "[FIELD-TEST] Feature — API Gateway Setup" -Fields @(
    @{ op="add"; path="/fields/System.Description";                    value="<p>Feature to set up API Gateway with OAuth2 and rate limiting.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";        value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";       value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Risk";            value="1 - High" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.TargetDate";  value="2025-09-30T00:00:00Z" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StartDate";   value="2025-06-15T00:00:00Z" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.Effort";      value=21 }
)
if ($feature) {
    Set-AdoState -Id $feature.id -State "Active"
    if ($epic) { Link-Parent -ChildId $feature.id -ParentId $epic.id }
    $createdItems.Add([PSCustomObject]@{ Type="Feature"; Id=$feature.id; Title=$feature.fields.'System.Title'; State="Active" })
}

# ── 3. USER STORY ─────────────────────────────────────────────
Write-Host "`n[3/13] Creating USER STORY..." -ForegroundColor Magenta
$story = New-AdoItem -Type "User Story" -Title "[FIELD-TEST] User Story — As a developer I can authenticate via OAuth2" -Fields @(
    @{ op="add"; path="/fields/System.Description";                                value="<p>As a developer, I want OAuth2 login so I can access protected APIs securely.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.AcceptanceCriteria";          value="<ul><li>OAuth2 flow works end-to-end</li><li>Token refresh implemented</li><li>Error states handled</li></ul>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";                    value=2 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";                   value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StoryPoints";             value=8 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.OriginalEstimate";        value=16 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.RemainingWork";           value=4 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.CompletedWork";           value=12 }
)
if ($story) {
    Set-AdoState -Id $story.id -State "Active"
    if ($feature) { Link-Parent -ChildId $story.id -ParentId $feature.id }
    $createdItems.Add([PSCustomObject]@{ Type="User Story"; Id=$story.id; Title=$story.fields.'System.Title'; State="Active" })
}

# ── 4. TASK ───────────────────────────────────────────────────
Write-Host "`n[4/13] Creating TASK..." -ForegroundColor Magenta
$task = New-AdoItem -Type "Task" -Title "[FIELD-TEST] Task — Implement OAuth2 token endpoint" -Fields @(
    @{ op="add"; path="/fields/System.Description";                         value="<p>Implement the <code>/oauth/token</code> endpoint using Azure AD B2C.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";             value=2 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Activity";             value="Development" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.OriginalEstimate"; value=8 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.RemainingWork";    value=2 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.CompletedWork";    value=6 }
)
if ($task) {
    Set-AdoState -Id $task.id -State "Active"
    if ($story) { Link-Parent -ChildId $task.id -ParentId $story.id }
    $createdItems.Add([PSCustomObject]@{ Type="Task"; Id=$task.id; Title=$task.fields.'System.Title'; State="Active" })
}

# ── 5. BUG ────────────────────────────────────────────────────
Write-Host "`n[5/13] Creating BUG..." -ForegroundColor Magenta
$bug = New-AdoItem -Type "Bug" -Title "[FIELD-TEST] Bug — OAuth token expires 10s early due to clock skew" -Fields @(
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.ReproSteps";          value="<ol><li>Log in via OAuth</li><li>Wait 290 seconds</li><li>Make API call — receives 401</li></ol>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.SystemInfo";          value="Windows 11, Chrome 124, API v2.3" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";         value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Severity";         value="1 - Critical" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";        value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StoryPoints";  value=3 }
)
if ($bug) {
    Set-AdoState -Id $bug.id -State "Active"
    if ($story) { Link-Parent -ChildId $bug.id -ParentId $story.id }
    $createdItems.Add([PSCustomObject]@{ Type="Bug"; Id=$bug.id; Title=$bug.fields.'System.Title'; State="Active" })
}

# ── 6. TEST PLAN ──────────────────────────────────────────────
Write-Host "`n[6/13] Creating TEST PLAN..." -ForegroundColor Magenta
$testPlan = New-AdoItem -Type "Test Plan" -Title "[FIELD-TEST] Test Plan — API Gateway Sprint 3 Regression" -Fields @(
    @{ op="add"; path="/fields/System.Description"; value="<p>Covers all regression tests for the API Gateway feature in Sprint 3.</p>" }
)
if ($testPlan) {
    $createdItems.Add([PSCustomObject]@{ Type="Test Plan"; Id=$testPlan.id; Title=$testPlan.fields.'System.Title'; State="Active" })
}

# ── 7. TEST SUITE ─────────────────────────────────────────────
Write-Host "`n[7/13] Creating TEST SUITE..." -ForegroundColor Magenta
$testSuite = New-AdoItem -Type "Test Suite" -Title "[FIELD-TEST] Test Suite — OAuth2 Authentication Tests" -Fields @(
    @{ op="add"; path="/fields/System.Description"; value="<p>All test cases covering OAuth2 token flows.</p>" }
)
if ($testSuite) {
    $createdItems.Add([PSCustomObject]@{ Type="Test Suite"; Id=$testSuite.id; Title=$testSuite.fields.'System.Title'; State="In Planning" })
}

# ── 8. TEST CASE ──────────────────────────────────────────────
Write-Host "`n[8/13] Creating TEST CASE..." -ForegroundColor Magenta
$testCase = New-AdoItem -Type "Test Case" -Title "[FIELD-TEST] Test Case — Verify OAuth2 token refresh flow" -Fields @(
    @{ op="add"; path="/fields/System.Description";              value="<p>Verify that expired tokens are refreshed correctly without re-login.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";  value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.AutomationStatus"; value="Not Automated" }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.Steps";        value='<steps id="0"><step id="1" type="ActionStep"><parameterizedString>Navigate to login</parameterizedString><parameterizedString>Login page loads</parameterizedString></step><step id="2" type="ActionStep"><parameterizedString>Submit credentials</parameterizedString><parameterizedString>Token issued</parameterizedString></step></steps>' }
)
if ($testCase) {
    Set-AdoState -Id $testCase.id -State "Ready"
    $createdItems.Add([PSCustomObject]@{ Type="Test Case"; Id=$testCase.id; Title=$testCase.fields.'System.Title'; State="Ready" })
}

# ── 9. SHARED STEPS ───────────────────────────────────────────
Write-Host "`n[9/13] Creating SHARED STEPS..." -ForegroundColor Magenta
$sharedSteps = New-AdoItem -Type "Shared Steps" -Title "[FIELD-TEST] Shared Steps — Common Login Procedure" -Fields @(
    @{ op="add"; path="/fields/System.Description"; value="<p>Reusable login steps used across multiple test cases.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.Steps"; value='<steps id="0"><step id="1" type="ActionStep"><parameterizedString>Open browser and navigate to app</parameterizedString><parameterizedString>Login page displayed</parameterizedString></step><step id="2" type="ActionStep"><parameterizedString>Enter username and password</parameterizedString><parameterizedString>User is authenticated</parameterizedString></step></steps>' }
)
if ($sharedSteps) {
    $createdItems.Add([PSCustomObject]@{ Type="Shared Steps"; Id=$sharedSteps.id; Title=$sharedSteps.fields.'System.Title'; State="Active" })
}

# ── 10. ISSUE ────────────────────────────────────────────────
Write-Host "`n[10/13] Creating ISSUE..." -ForegroundColor Magenta
$issue = New-AdoItem -Type "Issue" -Title "[FIELD-TEST] Issue — Dev environment missing SSL certificate" -Fields @(
    @{ op="add"; path="/fields/System.Description";             value="<p>The DEV environment is missing the wildcard SSL cert causing HTTPS failures.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=2 }
)
if ($issue) {
    Set-AdoState -Id $issue.id -State "Active"
    $createdItems.Add([PSCustomObject]@{ Type="Issue"; Id=$issue.id; Title=$issue.fields.'System.Title'; State="Active" })
}

# ── 11. IMPEDIMENT ───────────────────────────────────────────
Write-Host "`n[11/13] Creating IMPEDIMENT..." -ForegroundColor Magenta
$impediment = New-AdoItem -Type "Impediment" -Title "[FIELD-TEST] Impediment — Waiting for Azure AD B2C tenant provisioning" -Fields @(
    @{ op="add"; path="/fields/System.Description";             value="<p>Blocked: Azure AD B2C tenant not yet provisioned by IT. ETA 1 week.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=1 }
)
if ($impediment) {
    Set-AdoState -Id $impediment.id -State "Open"
    $createdItems.Add([PSCustomObject]@{ Type="Impediment"; Id=$impediment.id; Title=$impediment.fields.'System.Title'; State="Open" })
}

# ── 12. CHANGE REQUEST ───────────────────────────────────────
Write-Host "`n[12/13] Creating CHANGE REQUEST..." -ForegroundColor Magenta
$cr = New-AdoItem -Type "Change Request" -Title "[FIELD-TEST] Change Request — Upgrade API rate limit from 100 to 500 req/min" -Fields @(
    @{ op="add"; path="/fields/System.Description";             value="<p>Business requires rate limit increase from 100 to 500 requests/min for partner integrations.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=2 }
)
if ($cr) {
    Set-AdoState -Id $cr.id -State "Active"
    $createdItems.Add([PSCustomObject]@{ Type="Change Request"; Id=$cr.id; Title=$cr.fields.'System.Title'; State="Active" })
}

# ── 13. UAT REVIEW ───────────────────────────────────────────
Write-Host "`n[13/13] Creating UAT REVIEW..." -ForegroundColor Magenta
$uat = New-AdoItem -Type "UAT Review" -Title "[FIELD-TEST] UAT Review — API Gateway End-to-End Sign-Off" -Fields @(
    @{ op="add"; path="/fields/System.Description";             value="<p>UAT sign-off session for the API Gateway feature before production deployment.</p>" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=1 }
)
if ($uat) {
    Set-AdoState -Id $uat.id -State "New"
    $createdItems.Add([PSCustomObject]@{ Type="UAT Review"; Id=$uat.id; Title=$uat.fields.'System.Title'; State="New" })
}

# ── Add Dependency Links (Blocks/Blocked By) ─────────────────
if ($bug -and $task) {
    Write-Host "`nAdding dependency: BUG blocks TASK..." -ForegroundColor Cyan
    $depBody = @(@{
        op    = "add"; path = "/relations/-"
        value = @{
            rel        = "System.LinkTypes.Dependency-Forward"
            url        = "https://dev.azure.com/$ORG/_apis/wit/workitems/$($task.id)"
            attributes = @{ comment = "Bug must be fixed before task can complete" }
        }
    }) | ConvertTo-Json -Depth 10
    $uri = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/$($bug.id)?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $depBody | Out-Null; Write-Host "  ✅ Blocks link added" -ForegroundColor Green }
    catch { Write-Host "  ⚠️  Blocks link failed" -ForegroundColor Yellow }
}

if ($story -and $feature) {
    Write-Host "Adding Related link: USER STORY related to FEATURE..." -ForegroundColor Cyan
    $relBody = @(@{
        op    = "add"; path = "/relations/-"
        value = @{
            rel        = "System.LinkTypes.Related"
            url        = "https://dev.azure.com/$ORG/_apis/wit/workitems/$($feature.id)"
            attributes = @{ comment = "Related field test link" }
        }
    }) | ConvertTo-Json -Depth 10
    $uri = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/$($story.id)?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $relBody | Out-Null; Write-Host "  ✅ Related link added" -ForegroundColor Green }
    catch { Write-Host "  ⚠️  Related link failed" -ForegroundColor Yellow }
}

# ── Final Summary ─────────────────────────────────────────────
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "  CREATED ITEMS — Cross-Check List" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
$createdItems | Format-Table Type, Id, State, Title -AutoSize

Write-Host "`nADO Links to verify:" -ForegroundColor Yellow
foreach ($item in $createdItems) {
    Write-Host "  [$($item.Type)] #$($item.Id) → https://dev.azure.com/$ORG/$PROJECT/_workitems/edit/$($item.Id)" -ForegroundColor White
}

Write-Host "`n✅ Done! $($createdItems.Count) test items created." -ForegroundColor Green
Write-Host "Now run the migration pipeline to validate every field." -ForegroundColor Cyan
