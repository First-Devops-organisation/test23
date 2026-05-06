# ============================================================
#  Field-Coverage Test Items
#  Creates ONE item per work item type with ALL fields filled
#  Purpose: Validate every field migrates correctly
#  Run: .\create_field_test_items.ps1 -AdoPat "PAT" -AdoOrg "MyOrg" -AdoProject "MyProject"
# ============================================================
param(
    [Parameter(Mandatory)][string]$AdoPat,
    [Parameter(Mandatory)][string]$AdoOrg,
    [Parameter(Mandatory)][string]$AdoProject,
    [Parameter(Mandatory)][string]$AreaPath,
    [string]$IterationPath  = "",     # defaults to project root if blank
    [string]$AssignedTo     = ""      # leave blank to not assign
)

$ORG     = $AdoOrg
$PROJECT = $AdoProject
$AREA    = $AreaPath
$ITER    = if ($IterationPath) { $IterationPath } else { $AdoProject }

$b64     = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$headers = @{ Authorization = "Basic $b64"; "Content-Type" = "application/json-patch+json" }

$createdItems = [System.Collections.Generic.List[PSCustomObject]]::new()

function New-AdoItem {
    param([string]$Type, [string]$Title, [array]$ExtraFields)
    $allFields = @(
        @{ op="add"; path="/fields/System.Title";         value=$Title }
        @{ op="add"; path="/fields/System.AreaPath";      value=$AREA  }
        @{ op="add"; path="/fields/System.IterationPath"; value=$ITER  }
        @{ op="add"; path="/fields/System.Tags";          value="field-test; migration-test; poc" }
    )
    if ($AssignedTo) { $allFields += @{ op="add"; path="/fields/System.AssignedTo"; value=$AssignedTo } }
    if ($ExtraFields) { $allFields += $ExtraFields }
    $body    = $allFields | ConvertTo-Json -Depth 10
    $typeEnc = [Uri]::EscapeDataString($Type)
    $uri     = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/`$$typeEnc`?api-version=7.1"
    try {
        $r = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
        Write-Host "  OK [$Type] #$($r.id) - $Title" -ForegroundColor Green
        return $r
    } catch {
        Write-Host "  FAILED [$Type]: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Set-AdoState {
    param([int]$Id, [string]$State)
    $body = @(@{ op="add"; path="/fields/System.State"; value=$State }) | ConvertTo-Json -Depth 5
    $uri  = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/${Id}?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null }
    catch { Write-Host "    WARN: State '$State' failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Add-AdoLink {
    param([int]$SourceId, [int]$TargetId, [string]$RelType, [string]$Comment)
    $body = @(@{
        op    = "add"
        path  = "/relations/-"
        value = @{
            rel        = $RelType
            url        = "https://dev.azure.com/$ORG/_apis/wit/workitems/$TargetId"
            attributes = @{ comment = $Comment }
        }
    }) | ConvertTo-Json -Depth 10
    $uri = "https://dev.azure.com/$ORG/$PROJECT/_apis/wit/workitems/${SourceId}?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null; return $true }
    catch { Write-Host "    WARN: Link failed: $_" -ForegroundColor Yellow; return $false }
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Field-Coverage Test Item Creator" -ForegroundColor Cyan
Write-Host "  Project: $PROJECT | Area: $AREA" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ── Pre-declare all HTML content as variables (avoids parse errors) ─
$htmlEpicDesc     = "<b>Epic Description</b><p>This epic covers full cloud migration scope including ADO to GitHub migration.</p>"
$htmlFeatureDesc  = "<p>Feature to set up API Gateway with OAuth2, JWT, and rate limiting for all partner integrations.</p>"
$htmlStoryDesc    = "<p>As a developer, I want OAuth2 login so I can access protected APIs securely without managing passwords.</p>"
$htmlStoryAC      = "<ul><li>OAuth2 flow works end-to-end</li><li>Token refresh implemented</li><li>Error states handled gracefully</li><li>Tokens expire after configured TTL</li></ul>"
$htmlTaskDesc     = "<p>Implement the /oauth/token endpoint using Azure AD B2C. Include refresh token rotation and PKCE support.</p>"
$htmlBugRepro     = "<ol><li>Log in via OAuth2</li><li>Wait 290 seconds</li><li>Make API call</li><li>Observe 401 Unauthorized error</li></ol>"
$htmlBugSysInfo   = "<p>OS: Windows 11 Pro 23H2<br>Browser: Chrome 124.0.6367.62<br>API Version: v2.3.1<br>Environment: DEV</p>"
$htmlTestPlanDesc = "<p>Covers all regression tests for the API Gateway feature in Sprint 3. Includes auth, rate limiting, and error handling.</p>"
$htmlTestSuiteDesc= "<p>All test cases covering OAuth2 token flows: login, refresh, expiry, and revocation.</p>"
$htmlTestCaseDesc = "<p>Verify that expired tokens are refreshed correctly without requiring the user to log in again.</p>"
$htmlStepsTC      = "<steps id='0'><step id='1' type='ActionStep'><parameterizedString>Navigate to the application login page</parameterizedString><parameterizedString>Login page loads successfully</parameterizedString></step><step id='2' type='ActionStep'><parameterizedString>Submit valid credentials</parameterizedString><parameterizedString>JWT access token is issued with correct expiry</parameterizedString></step><step id='3' type='ActionStep'><parameterizedString>Wait for token to expire then call API</parameterizedString><parameterizedString>New token is automatically refreshed, API returns 200</parameterizedString></step></steps>"
$htmlSharedDesc   = "<p>Reusable login steps used across multiple test cases in the authentication test suite.</p>"
$htmlSharedSteps  = "<steps id='0'><step id='1' type='ActionStep'><parameterizedString>Open browser and navigate to app URL</parameterizedString><parameterizedString>Login page is displayed</parameterizedString></step><step id='2' type='ActionStep'><parameterizedString>Enter valid username and password and click Login</parameterizedString><parameterizedString>User is authenticated and redirected to dashboard</parameterizedString></step></steps>"
$htmlIssueDesc    = "<p>The DEV environment is missing the wildcard SSL certificate causing all HTTPS calls to fail with SSL_ERROR_RX_RECORD_TOO_LONG.</p>"
$htmlImpDesc      = "<p>Blocked: Azure AD B2C tenant has not been provisioned by the IT Security team. ETA is 5 business days. All OAuth2 work is blocked.</p>"
$htmlCRDesc       = "<p>Business partner SLA requires API rate limits to increase from 100 to 500 requests per minute. Current limit causes SLA breaches during peak hours.</p>"
$htmlUatDesc      = "<p>UAT sign-off session for the complete API Gateway feature set before production deployment. All stakeholders must attend.</p>"

# ── 1. EPIC ──────────────────────────────────────────────────
Write-Host "`n[1/13] Creating EPIC..." -ForegroundColor Magenta
$epic = New-AdoItem -Type "Epic" -Title "[FIELD-TEST] Epic - Cloud Migration Initiative" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";                   value=$htmlEpicDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";       value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";      value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Risk";           value="2 - Medium" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.TargetDate"; value="2025-12-31T00:00:00Z" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StartDate";  value="2025-06-01T00:00:00Z" }
)
if ($epic) {
    Set-AdoState -Id $epic.id -State "Active"
    $createdItems.Add([PSCustomObject]@{ Type="Epic"; Id=$epic.id; Title=$epic.fields.'System.Title'; State="Active" })
}

# ── 2. FEATURE ───────────────────────────────────────────────
Write-Host "`n[2/13] Creating FEATURE..." -ForegroundColor Magenta
$feature = New-AdoItem -Type "Feature" -Title "[FIELD-TEST] Feature - API Gateway Setup" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";                   value=$htmlFeatureDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";       value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";      value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Risk";           value="1 - High" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.TargetDate"; value="2025-09-30T00:00:00Z" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StartDate";  value="2025-06-15T00:00:00Z" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.Effort";     value=21 }
)
if ($feature) {
    Set-AdoState -Id $feature.id -State "Active"
    if ($epic) { Add-AdoLink -SourceId $feature.id -TargetId $epic.id -RelType "System.LinkTypes.Hierarchy-Reverse" -Comment "Feature under Epic" | Out-Null }
    $createdItems.Add([PSCustomObject]@{ Type="Feature"; Id=$feature.id; Title=$feature.fields.'System.Title'; State="Active" })
}

# ── 3. USER STORY ─────────────────────────────────────────────
Write-Host "`n[3/13] Creating USER STORY..." -ForegroundColor Magenta
$story = New-AdoItem -Type "User Story" -Title "[FIELD-TEST] User Story - Developer OAuth2 Authentication" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";                           value=$htmlStoryDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.AcceptanceCriteria";     value=$htmlStoryAC }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";               value=2 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";              value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StoryPoints";        value=8 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.OriginalEstimate";   value=16 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.RemainingWork";      value=4 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.CompletedWork";      value=12 }
)
if ($story) {
    Set-AdoState -Id $story.id -State "Active"
    if ($feature) { Add-AdoLink -SourceId $story.id -TargetId $feature.id -RelType "System.LinkTypes.Hierarchy-Reverse" -Comment "Story under Feature" | Out-Null }
    $createdItems.Add([PSCustomObject]@{ Type="User Story"; Id=$story.id; Title=$story.fields.'System.Title'; State="Active" })
}

# ── 4. TASK ───────────────────────────────────────────────────
Write-Host "`n[4/13] Creating TASK..." -ForegroundColor Magenta
$task = New-AdoItem -Type "Task" -Title "[FIELD-TEST] Task - Implement OAuth2 Token Endpoint" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";                          value=$htmlTaskDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";              value=2 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Activity";              value="Development" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.OriginalEstimate";  value=8 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.RemainingWork";     value=2 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.CompletedWork";     value=6 }
)
if ($task) {
    Set-AdoState -Id $task.id -State "Active"
    if ($story) { Add-AdoLink -SourceId $task.id -TargetId $story.id -RelType "System.LinkTypes.Hierarchy-Reverse" -Comment "Task under Story" | Out-Null }
    $createdItems.Add([PSCustomObject]@{ Type="Task"; Id=$task.id; Title=$task.fields.'System.Title'; State="Active" })
}

# ── 5. BUG ────────────────────────────────────────────────────
Write-Host "`n[5/13] Creating BUG..." -ForegroundColor Magenta
$bug = New-AdoItem -Type "Bug" -Title "[FIELD-TEST] Bug - OAuth Token Expires 10s Early Due to Clock Skew" -ExtraFields @(
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.ReproSteps";         value=$htmlBugRepro }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.SystemInfo";         value=$htmlBugSysInfo }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";        value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Severity";        value="1 - Critical" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.ValueArea";       value="Business" }
    @{ op="add"; path="/fields/Microsoft.VSTS.Scheduling.StoryPoints"; value=3 }
)
if ($bug) {
    Set-AdoState -Id $bug.id -State "Active"
    if ($story) { Add-AdoLink -SourceId $bug.id -TargetId $story.id -RelType "System.LinkTypes.Hierarchy-Reverse" -Comment "Bug under Story" | Out-Null }
    $createdItems.Add([PSCustomObject]@{ Type="Bug"; Id=$bug.id; Title=$bug.fields.'System.Title'; State="Active" })
}

# ── 6. TEST PLAN ──────────────────────────────────────────────
Write-Host "`n[6/13] Creating TEST PLAN..." -ForegroundColor Magenta
$testPlan = New-AdoItem -Type "Test Plan" -Title "[FIELD-TEST] Test Plan - API Gateway Sprint 3 Regression" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description"; value=$htmlTestPlanDesc }
)
if ($testPlan) {
    $createdItems.Add([PSCustomObject]@{ Type="Test Plan"; Id=$testPlan.id; Title=$testPlan.fields.'System.Title'; State="Active" })
}

# ── 7. TEST SUITE ─────────────────────────────────────────────
Write-Host "`n[7/13] Creating TEST SUITE..." -ForegroundColor Magenta
$testSuite = New-AdoItem -Type "Test Suite" -Title "[FIELD-TEST] Test Suite - OAuth2 Authentication Tests" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description"; value=$htmlTestSuiteDesc }
)
if ($testSuite) {
    $createdItems.Add([PSCustomObject]@{ Type="Test Suite"; Id=$testSuite.id; Title=$testSuite.fields.'System.Title'; State="In Planning" })
}

# ── 8. TEST CASE ──────────────────────────────────────────────
Write-Host "`n[8/13] Creating TEST CASE..." -ForegroundColor Magenta
$testCase = New-AdoItem -Type "Test Case" -Title "[FIELD-TEST] Test Case - Verify OAuth2 Token Refresh Flow" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";                  value=$htmlTestCaseDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority";      value=1 }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.AutomationStatus"; value="Not Automated" }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.Steps";            value=$htmlStepsTC }
)
if ($testCase) {
    Set-AdoState -Id $testCase.id -State "Ready"
    $createdItems.Add([PSCustomObject]@{ Type="Test Case"; Id=$testCase.id; Title=$testCase.fields.'System.Title'; State="Ready" })
}

# ── 9. SHARED STEPS ───────────────────────────────────────────
Write-Host "`n[9/13] Creating SHARED STEPS..." -ForegroundColor Magenta
$sharedSteps = New-AdoItem -Type "Shared Steps" -Title "[FIELD-TEST] Shared Steps - Common Login Procedure" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";      value=$htmlSharedDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.TCM.Steps"; value=$htmlSharedSteps }
)
if ($sharedSteps) {
    $createdItems.Add([PSCustomObject]@{ Type="Shared Steps"; Id=$sharedSteps.id; Title=$sharedSteps.fields.'System.Title'; State="Active" })
}

# ── 10. ISSUE ────────────────────────────────────────────────
Write-Host "`n[10/13] Creating ISSUE..." -ForegroundColor Magenta
$issue = New-AdoItem -Type "Issue" -Title "[FIELD-TEST] Issue - Dev Environment Missing SSL Certificate" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";             value=$htmlIssueDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=2 }
)
if ($issue) {
    Set-AdoState -Id $issue.id -State "Active"
    $createdItems.Add([PSCustomObject]@{ Type="Issue"; Id=$issue.id; Title=$issue.fields.'System.Title'; State="Active" })
}

# ── 11. IMPEDIMENT ───────────────────────────────────────────
Write-Host "`n[11/13] Creating IMPEDIMENT..." -ForegroundColor Magenta
$impediment = New-AdoItem -Type "Impediment" -Title "[FIELD-TEST] Impediment - Waiting for Azure AD B2C Tenant Provisioning" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";             value=$htmlImpDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=1 }
)
if ($impediment) {
    Set-AdoState -Id $impediment.id -State "Open"
    $createdItems.Add([PSCustomObject]@{ Type="Impediment"; Id=$impediment.id; Title=$impediment.fields.'System.Title'; State="Open" })
}

# ── 12. CHANGE REQUEST ───────────────────────────────────────
Write-Host "`n[12/13] Creating CHANGE REQUEST..." -ForegroundColor Magenta
$cr = New-AdoItem -Type "Change Request" -Title "[FIELD-TEST] Change Request - Increase API Rate Limit to 500 req/min" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";             value=$htmlCRDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=2 }
)
if ($cr) {
    Set-AdoState -Id $cr.id -State "Active"
    $createdItems.Add([PSCustomObject]@{ Type="Change Request"; Id=$cr.id; Title=$cr.fields.'System.Title'; State="Active" })
}

# ── 13. UAT REVIEW ───────────────────────────────────────────
Write-Host "`n[13/13] Creating UAT REVIEW..." -ForegroundColor Magenta
$uat = New-AdoItem -Type "UAT Review" -Title "[FIELD-TEST] UAT Review - API Gateway End-to-End Sign-Off" -ExtraFields @(
    @{ op="add"; path="/fields/System.Description";             value=$htmlUatDesc }
    @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=1 }
)
if ($uat) {
    Set-AdoState -Id $uat.id -State "New"
    $createdItems.Add([PSCustomObject]@{ Type="UAT Review"; Id=$uat.id; Title=$uat.fields.'System.Title'; State="New" })
}

# ── Dependency: BUG blocks TASK ──────────────────────────────
if ($bug -and $task) {
    Write-Host "`nAdding Blocks link: BUG blocks TASK..." -ForegroundColor Cyan
    $ok = Add-AdoLink -SourceId $bug.id -TargetId $task.id -RelType "System.LinkTypes.Dependency-Forward" -Comment "Bug must be fixed before task can complete"
    if ($ok) { Write-Host "  OK: Blocks link added" -ForegroundColor Green }
}

# ── Related: STORY related to FEATURE ───────────────────────
if ($story -and $feature) {
    Write-Host "Adding Related link: STORY related to FEATURE..." -ForegroundColor Cyan
    $ok = Add-AdoLink -SourceId $story.id -TargetId $feature.id -RelType "System.LinkTypes.Related" -Comment "Story is related to the parent feature"
    if ($ok) { Write-Host "  OK: Related link added" -ForegroundColor Green }
}

# ── Final Summary ─────────────────────────────────────────────
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "  CREATED ITEMS - Cross-Check List" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
$createdItems | Format-Table Type, Id, State -AutoSize

Write-Host "`nADO URLs to verify each item:" -ForegroundColor Yellow
foreach ($item in $createdItems) {
    Write-Host "  [$($item.Type)] #$($item.Id) -> https://dev.azure.com/$ORG/$PROJECT/_workitems/edit/$($item.Id)" -ForegroundColor White
}

Write-Host "`nDone! $($createdItems.Count) test items created." -ForegroundColor Green
Write-Host "Run the migration pipeline on area 'POC-Migration' to validate all fields." -ForegroundColor Cyan
