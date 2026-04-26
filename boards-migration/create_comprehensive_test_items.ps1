# ============================================================
#  Create Comprehensive Test Items for Enterprise Migration
#  One item per type+state with all fields populated
#  Project : YASH-DevOps-Serverless
#  Area    : POC-Migration
#  Run     : .\create_comprehensive_test_items.ps1
# ============================================================

$ORG     = "https://dev.azure.com/YashTech-DevOps"
$PROJECT = "YASH-DevOps-Serverless"
$AREA    = "YASH-DevOps-Serverless\POC-Migration"

az devops configure --defaults organization=$ORG project=$PROJECT

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Migration Test Suite" -ForegroundColor Cyan
Write-Host "  Comprehensive items with all field types" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

$count = 0
$items = @()

function New-TestItem {
    param(
        [string]$Type,
        [string]$Title,
        [string]$TargetState,
        [string]$Description = "",
        [int]$Priority = 2,
        [string]$Severity = "",
        [string]$Tags = "",
        [int]$StoryPoints = 0,
        [string]$ParentId = ""
    )
    $Script:count++

    Write-Host "[$Script:count] [$Type] State='$TargetState' Priority=$Priority" -ForegroundColor Yellow
    Write-Host "    $Title" -ForegroundColor White

    # Build create command args
    $args = @(
        "boards", "work-item", "create",
        "--title", $Title,
        "--type", $Type,
        "--area", $AREA,
        "--assigned-to", "urvashi.upadhyay@yash.com",
        "--output", "json"
    )

    if ($Description) {
        $args += @("--description", $Description)
    }

    $json = & az @args 2>$null

    if (-not $json) {
        Write-Host "    SKIPPED - type not supported" -ForegroundColor Red
        Write-Host ""
        return $null
    }

    $item = $json | ConvertFrom-Json
    $id = $item.id
    Write-Host "    Created ID: $id" -ForegroundColor Green

    # Set state
    if ($TargetState -and $TargetState -ne "New") {
        az boards work-item update --id $id --state "$TargetState" --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    State: $TargetState" -ForegroundColor Green
        } else {
            Write-Host "    State '$TargetState' not valid for $Type" -ForegroundColor Red
        }
    }

    # Set priority (field update)
    if ($Priority) {
        az boards work-item update --id $id --fields "Microsoft.VSTS.Common.Priority=$Priority" --output none 2>$null
    }

    # Set severity (Bug only)
    if ($Severity) {
        az boards work-item update --id $id --fields "Microsoft.VSTS.Common.Severity=$Severity" --output none 2>$null
        Write-Host "    Severity: $Severity" -ForegroundColor Magenta
    }

    # Set tags
    if ($Tags) {
        az boards work-item update --id $id --fields "System.Tags=$Tags" --output none 2>$null
        Write-Host "    Tags: $Tags" -ForegroundColor DarkCyan
    }

    # Set story points
    if ($StoryPoints -gt 0) {
        az boards work-item update --id $id --fields "Microsoft.VSTS.Scheduling.StoryPoints=$StoryPoints" --output none 2>$null
        Write-Host "    Story Points: $StoryPoints" -ForegroundColor DarkYellow
    }

    Write-Host ""
    return $id
}

function Add-ChildLink {
    param([int]$ParentId, [int]$ChildId)
    az boards work-item relation add --id $ChildId --relation-type "parent" --target-id $ParentId --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Linked child #$ChildId to parent #$ParentId" -ForegroundColor DarkGreen
    }
}

# ============================================================
# EPICS - Top level
# ============================================================
Write-Host "--- EPICS ---" -ForegroundColor Cyan
$epicNew = New-TestItem -Type "Epic" -Title "[ENT] Epic - Platform Modernization" -TargetState "New" -Priority 1 `
    -Description "Modernize the enterprise platform to cloud-native architecture. Includes microservices, containerization, and CI/CD pipeline automation." `
    -Tags "enterprise;migration;cloud" -StoryPoints 40

$epicActive = New-TestItem -Type "Epic" -Title "[ENT] Epic - DevOps Pipeline Automation" -TargetState "Active" -Priority 2 `
    -Description "Implement end-to-end CI/CD pipelines using GitHub Actions. Covers build, test, security scanning, and deployment stages." `
    -Tags "devops;automation;ci-cd" -StoryPoints 30

$epicResolved = New-TestItem -Type "Epic" -Title "[ENT] Epic - Security Compliance" -TargetState "Resolved" -Priority 1 `
    -Description "Ensure all repositories meet SOC2, HIPAA, and ISO 27001 compliance requirements." `
    -Tags "security;compliance" -StoryPoints 25

$epicClosed = New-TestItem -Type "Epic" -Title "[ENT] Epic - Legacy System Retirement" -TargetState "Closed" -Priority 3 `
    -Description "Decommission legacy on-premise servers after successful cloud migration." `
    -Tags "legacy;retirement" -StoryPoints 15

# ============================================================
# FEATURES - Under Epics
# ============================================================
Write-Host "--- FEATURES ---" -ForegroundColor Cyan
$featNew = New-TestItem -Type "Feature" -Title "[ENT] Feature - Container Orchestration (K8s)" -TargetState "New" -Priority 2 `
    -Description "Set up Kubernetes clusters for microservice deployment. Includes Helm charts, ingress, and monitoring." `
    -Tags "kubernetes;containers" -StoryPoints 13

$featActive = New-TestItem -Type "Feature" -Title "[ENT] Feature - GitHub Actions Workflows" -TargetState "Active" -Priority 1 `
    -Description "Create reusable workflow templates for build, test, deploy across all repositories." `
    -Tags "github-actions;workflows" -StoryPoints 8

$featResolved = New-TestItem -Type "Feature" -Title "[ENT] Feature - Code Scanning (GHAS)" -TargetState "Resolved" -Priority 2 `
    -Description "Enable GitHub Advanced Security code scanning, secret scanning, and Dependabot for all repos." `
    -Tags "ghas;security;scanning" -StoryPoints 5

$featClosed = New-TestItem -Type "Feature" -Title "[ENT] Feature - SSO Integration" -TargetState "Closed" -Priority 1 `
    -Description "Integrate Azure AD SSO with GitHub Enterprise for unified identity management." `
    -Tags "sso;identity" -StoryPoints 3

# Link features to epics
if ($epicNew -and $featNew) { Add-ChildLink -ParentId $epicNew -ChildId $featNew }
if ($epicActive -and $featActive) { Add-ChildLink -ParentId $epicActive -ChildId $featActive }
if ($epicResolved -and $featResolved) { Add-ChildLink -ParentId $epicResolved -ChildId $featResolved }
if ($epicClosed -and $featClosed) { Add-ChildLink -ParentId $epicClosed -ChildId $featClosed }

# ============================================================
# USER STORIES - Under Features
# ============================================================
Write-Host "--- USER STORIES ---" -ForegroundColor Cyan
$storyNew = New-TestItem -Type "User Story" -Title "[ENT] Story - Configure Helm Charts for API Gateway" -TargetState "New" -Priority 2 `
    -Description "As a DevOps engineer, I want to create Helm charts for the API Gateway service so that deployment is repeatable and version-controlled." `
    -Tags "helm;api-gateway" -StoryPoints 5

$storyActive = New-TestItem -Type "User Story" -Title "[ENT] Story - Build Reusable CI Template" -TargetState "Active" -Priority 1 `
    -Description "As a developer, I want a reusable GitHub Actions CI template so that all repos follow the same build and test standards." `
    -Tags "ci;template;reusable" -StoryPoints 8

$storyResolved = New-TestItem -Type "User Story" -Title "[ENT] Story - Enable Secret Scanning" -TargetState "Resolved" -Priority 2 `
    -Description "As a security engineer, I want secret scanning enabled on all repos so that leaked credentials are detected immediately." `
    -Tags "secrets;scanning" -StoryPoints 3

$storyClosed = New-TestItem -Type "User Story" -Title "[ENT] Story - Configure SAML SSO" -TargetState "Closed" -Priority 3 `
    -Description "As an IT admin, I want SAML SSO configured with Azure AD so that all users authenticate through our identity provider." `
    -Tags "saml;sso;azure-ad" -StoryPoints 2

# Link stories to features
if ($featNew -and $storyNew) { Add-ChildLink -ParentId $featNew -ChildId $storyNew }
if ($featActive -and $storyActive) { Add-ChildLink -ParentId $featActive -ChildId $storyActive }
if ($featResolved -and $storyResolved) { Add-ChildLink -ParentId $featResolved -ChildId $storyResolved }
if ($featClosed -and $storyClosed) { Add-ChildLink -ParentId $featClosed -ChildId $storyClosed }

# ============================================================
# TASKS - Under Stories
# ============================================================
Write-Host "--- TASKS ---" -ForegroundColor Cyan
$taskNew = New-TestItem -Type "Task" -Title "[ENT] Task - Write Dockerfile for API Gateway" -TargetState "New" -Priority 3 `
    -Description "Create multi-stage Dockerfile for the API Gateway service. Must use Alpine base image." `
    -Tags "docker;api" -StoryPoints 2

$taskActive = New-TestItem -Type "Task" -Title "[ENT] Task - Create workflow_call template" -TargetState "Active" -Priority 1 `
    -Description "Build the reusable workflow using workflow_call trigger with matrix strategy for multi-platform builds." `
    -Tags "workflow;template" -StoryPoints 3

$taskClosed = New-TestItem -Type "Task" -Title "[ENT] Task - Verify SSO login flow" -TargetState "Closed" -Priority 2 `
    -Description "Test the SAML SSO login flow end-to-end. Verify MFA prompt, group mappings, and session timeout." `
    -Tags "testing;sso" -StoryPoints 1

# Link tasks to stories
if ($storyNew -and $taskNew) { Add-ChildLink -ParentId $storyNew -ChildId $taskNew }
if ($storyActive -and $taskActive) { Add-ChildLink -ParentId $storyActive -ChildId $taskActive }
if ($storyClosed -and $taskClosed) { Add-ChildLink -ParentId $storyClosed -ChildId $taskClosed }

# ============================================================
# BUGS - With Priority + Severity
# ============================================================
Write-Host "--- BUGS ---" -ForegroundColor Cyan
$bugNew = New-TestItem -Type "Bug" -Title "[ENT] Bug - Container crash on high memory" -TargetState "New" -Priority 1 `
    -Description "API Gateway container crashes when memory exceeds 512MB. OOMKilled in K8s events. Needs resource limits tuning." `
    -Tags "bug;crash;memory" -Severity "1 - Critical" -StoryPoints 5

$bugActive = New-TestItem -Type "Bug" -Title "[ENT] Bug - Workflow fails on fork PRs" -TargetState "Active" -Priority 2 `
    -Description "CI workflow fails with 'Resource not accessible by integration' when triggered from fork PRs. Need to use pull_request_target." `
    -Tags "bug;workflow;forks" -Severity "2 - High" -StoryPoints 3

$bugResolved = New-TestItem -Type "Bug" -Title "[ENT] Bug - Secret scan false positive on test data" -TargetState "Resolved" -Priority 3 `
    -Description "Secret scanning flags test fixture API keys as real secrets. Need to add secret scanning exclusion pattern." `
    -Tags "bug;false-positive;secrets" -Severity "3 - Medium" -StoryPoints 2

$bugClosed = New-TestItem -Type "Bug" -Title "[ENT] Bug - SSO session timeout too short" -TargetState "Closed" -Priority 4 `
    -Description "Users are logged out after 15 minutes of inactivity. Need to increase session timeout to 8 hours for developer experience." `
    -Tags "bug;sso;ux" -Severity "4 - Low" -StoryPoints 1

# ============================================================
# ISSUES
# ============================================================
Write-Host "--- ISSUES ---" -ForegroundColor Cyan
$issueActive = New-TestItem -Type "Issue" -Title "[ENT] Issue - License compliance review needed" -TargetState "Active" -Priority 2 `
    -Description "Several dependencies use AGPL license which is not approved for our enterprise use. Need legal review before production release." `
    -Tags "compliance;legal;license"

# ============================================================
# ADD COMMENTS TO SOME ITEMS
# ============================================================
Write-Host "--- ADDING COMMENTS ---" -ForegroundColor Cyan
$commentItems = @($epicActive, $featActive, $storyActive, $bugNew, $bugActive)
foreach ($cid in $commentItems) {
    if ($cid) {
        az boards work-item update --id $cid --discussion "Initial triage: Reviewed in sprint planning. This item is prioritized for the current iteration." --output none 2>$null
        az boards work-item update --id $cid --discussion "Update: Team has started implementation. Blocked on infrastructure provisioning - ETA 2 days." --output none 2>$null
        Write-Host "    Added 2 comments to #$cid" -ForegroundColor DarkGray
    }
}

# ============================================================
Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Created $count comprehensive test items!" -ForegroundColor Green
Write-Host ""
Write-Host "  Types: Epic, Feature, User Story, Task, Bug, Issue" -ForegroundColor White
Write-Host "  States: New, Active, Resolved, Closed" -ForegroundColor White
Write-Host "  Fields: Priority, Severity, Tags, Story Points" -ForegroundColor White
Write-Host "  Links: Parent-Child hierarchy (Epic->Feature->Story->Task)" -ForegroundColor White
Write-Host "  Comments: 2 per active item" -ForegroundColor White
Write-Host ""
Write-Host "  Expected in GitHub Project:" -ForegroundColor Yellow
Write-Host "    Custom Fields:" -ForegroundColor Yellow
Write-Host "      ADO Status   = New, Active, Resolved, Closed" -ForegroundColor Yellow
Write-Host "      Priority     = P1-Critical .. P4-Low" -ForegroundColor Yellow
Write-Host "      Severity     = 1-Critical .. 4-Low" -ForegroundColor Yellow
Write-Host "      Story Points = numeric values" -ForegroundColor Yellow
Write-Host "      ADO ID       = original work item number" -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Cyan
