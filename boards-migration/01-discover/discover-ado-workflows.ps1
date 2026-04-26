# ============================================================
#  Discover ADO Workflow Rules per Work Item Type
#  Queries ADO for valid states & transitions per type
#  Output: reports/ado-workflow-rules.json
#  Run: .\discover-ado-workflows.ps1
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"

$config = Read-JsonConfig -Path $ConfigPath
$adoOrg     = $config.source.organization
$adoProject = $config.source.project
$adoPat     = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$reportDir  = Join-Path $scriptRoot $config.output.reportDir
$logDir     = Join-Path $scriptRoot $config.output.logDir

if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

Initialize-Log -LogPath (Join-Path $logDir "discover-workflows-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Discovering ADO Workflow Rules"

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$headers = @{ Authorization = "Basic $base64Auth"; "Content-Type" = "application/json" }

$workItemTypes = $config.filters.workItemTypes

$workflows = @{}

foreach ($witType in $workItemTypes) {
    Write-Log -Message "Querying workflow for: $witType" -Level "INFO"
    
    # Get states for this work item type
    $statesUrl = "https://dev.azure.com/$adoOrg/$adoProject/_apis/wit/workitemtypes/$($witType -replace ' ','%20')/states?api-version=7.1"
    
    try {
        $response = Invoke-RestMethod -Uri $statesUrl -Headers $headers -Method Get
        
        $states = @()
        foreach ($state in $response.value) {
            $states += @{
                name     = $state.name
                color    = $state.color
                category = $state.category  # Proposed, InProgress, Resolved, Completed, Removed
                order    = $state.order
            }
        }
        
        # Sort by order
        $states = $states | Sort-Object { $_.order }
        
        # Build valid transitions from category flow
        # ADO categories define the natural flow: Proposed → InProgress → Resolved → Completed
        $categoryOrder = @{
            "Proposed"   = 1
            "InProgress" = 2
            "Resolved"   = 3
            "Completed"  = 4
            "Removed"    = 5
        }
        
        $transitions = @{}
        foreach ($fromState in $states) {
            $validTargets = @()
            foreach ($toState in $states) {
                if ($fromState.name -ne $toState.name) {
                    $validTargets += $toState.name
                }
            }
            $transitions[$fromState.name] = $validTargets
        }
        
        $workflows[$witType] = @{
            states      = $states
            stateNames  = @($states | ForEach-Object { $_.name })
            transitions = $transitions
            categories  = @{}
        }
        
        # Group states by category
        foreach ($state in $states) {
            $cat = $state.category
            if (-not $workflows[$witType].categories[$cat]) {
                $workflows[$witType].categories[$cat] = @()
            }
            $workflows[$witType].categories[$cat] += $state.name
        }
        
        Write-Log -Message "  $witType`: $($states.Count) states - $(($states | ForEach-Object { $_.name }) -join ', ')" -Level "INFO"
        
    } catch {
        Write-Log -Message "  Failed to query $witType states: $($_.Exception.Message)" -Level "WARN"
        continue
    }
    
    Start-Sleep -Milliseconds 200
}

# Save workflow rules
$workflowReport = @{
    generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    organization = $adoOrg
    project = $adoProject
    workItemTypes = $workflows
}

$outputPath = Join-Path $reportDir "ado-workflow-rules.json"
$workflowReport | ConvertTo-Json -Depth 10 | Set-Content -Path $outputPath -Encoding UTF8
Write-Log -Message "Workflow rules saved: $outputPath" -Level "SUCCESS"

# Generate GitHub Actions workflow file
Write-LogSection "Generating GitHub Actions Workflow"

# Build state validation map for the action
$stateValidation = @{}
foreach ($witType in $workflows.Keys) {
    $labelKey = "type:$($witType.ToLower() -replace ' ','-')"
    $stateValidation[$labelKey] = $workflows[$witType].stateNames
}

$ghWorkflowDir = Join-Path $reportDir "github-workflows"
if (-not (Test-Path $ghWorkflowDir)) { New-Item -ItemType Directory -Path $ghWorkflowDir -Force | Out-Null }

# Generate the workflow YAML
$validationRules = ""
foreach ($label in ($stateValidation.Keys | Sort-Object)) {
    $validStates = $stateValidation[$label] -join "', '"
    $validationRules += @"

          # $label
          if (`${{ contains(github.event.projects_v2_item.content_node_id, '') }}) {
            # Valid states for $label : $($stateValidation[$label] -join ', ')
          }
"@
}

# Build the state-to-label validation JSON
$validationJson = @{}
foreach ($label in $stateValidation.Keys) {
    $validationJson[$label] = $stateValidation[$label]
}
$validationJsonStr = $validationJson | ConvertTo-Json -Compress

$workflowYaml = @"
# ============================================================
#  Enforce ADO Workflow Rules on GitHub Project
#  Auto-generated from ADO workflow discovery
#  
#  Validates that project item statuses match the original
#  ADO workflow rules per work item type.
#
#  Triggers:
#    - Manual run (workflow_dispatch)
#    - Daily schedule (catches violations)
#    - On issue label changes
#
#  For org repos: add projects_v2_item trigger for real-time
# ============================================================
name: Enforce ADO Workflow Rules

on:
  workflow_dispatch:
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM UTC
  issues:
    types: [labeled]

permissions:
  issues: write
  repository-projects: read

env:
  PROJECT_NUMBER: 2
  PROJECT_OWNER: Urvashi773

jobs:
  validate-workflow-rules:
    runs-on: ubuntu-latest
    steps:
      - name: Validate All Project Items
        uses: actions/github-script@v7
        with:
          github-token: `${{ secrets.GITHUB_TOKEN }}
          script: |
            // ADO workflow rules - valid states per work item type
            const validStates = $validationJsonStr;

            const projectNumber = parseInt(process.env.PROJECT_NUMBER);
            const projectOwner = process.env.PROJECT_OWNER;

            // Query project items with their status and linked issue
            const query = ``
              query(`$projectOwner: String!, `$projectNumber: Int!, `$cursor: String) {
                user(login: `$projectOwner) {
                  projectV2(number: `$projectNumber) {
                    items(first: 100, after: `$cursor) {
                      pageInfo { hasNextPage endCursor }
                      nodes {
                        fieldValueByName(name: "Status") {
                          ... on ProjectV2ItemFieldSingleSelectValue { name }
                        }
                        content {
                          ... on Issue {
                            number
                            title
                            labels(first: 20) {
                              nodes { name }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            ``;

            let violations = [];
            let cursor = null;
            let totalChecked = 0;

            do {
              const result = await github.graphql(query, {
                projectOwner,
                projectNumber,
                cursor
              });

              const items = result.user.projectV2.items;

              for (const item of items.nodes) {
                if (!item.content || !item.content.number) continue;

                const status = item.fieldValueByName?.name;
                if (!status) continue;

                const labels = item.content.labels.nodes.map(l => l.name);
                const typeLabel = labels.find(l => l.startsWith('type:'));
                if (!typeLabel) continue;

                const allowed = validStates[typeLabel];
                if (!allowed || allowed.length === 0) continue;

                totalChecked++;

                if (!allowed.includes(status)) {
                  violations.push({
                    issue: item.content.number,
                    title: item.content.title,
                    type: typeLabel,
                    status: status,
                    allowed: allowed
                  });
                }
              }

              cursor = items.pageInfo.hasNextPage ? items.pageInfo.endCursor : null;
            } while (cursor);

            console.log('Checked ' + totalChecked + ' items, found ' + violations.length + ' violations');

            // Post comments on violations
            for (const v of violations) {
              console.log('VIOLATION: #' + v.issue + ' (' + v.type + ') has status "' + v.status + '" but valid states are: ' + v.allowed.join(', '));

              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: v.issue,
                body: ':warning: **Workflow Violation**: Status "' + v.status + '" is not valid for **' + v.type.replace('type:', '') + '** items.\n\n' +
                      '**Valid states:** ' + v.allowed.join(', ') + '\n\n' +
                      '_This rule is enforced based on the original Azure DevOps workflow._'
              });
            }

            if (violations.length === 0) {
              console.log('All items comply with ADO workflow rules!');
            }
"@

$ghWorkflowPath = Join-Path $ghWorkflowDir "enforce-workflow-rules.yml"
$workflowYaml | Set-Content -Path $ghWorkflowPath -Encoding UTF8
Write-Log -Message "GitHub Actions workflow saved: $ghWorkflowPath" -Level "SUCCESS"

# Generate a summary
Write-LogSection "Workflow Discovery Summary"
foreach ($witType in ($workflows.Keys | Sort-Object)) {
    $wf = $workflows[$witType]
    Write-Log -Message "$witType : $($wf.stateNames -join ' -> ')" -Level "INFO"
}

Write-Log -Message "" -Level "INFO"
Write-Log -Message "To install the workflow in your GitHub repo:" -Level "INFO"
Write-Log -Message "  1. Copy enforce-workflow-rules.yml to .github/workflows/" -Level "INFO"
Write-Log -Message "  2. Commit and push to main branch" -Level "INFO"
Write-Log -Message "  3. Invalid status changes will get a warning comment on the issue" -Level "INFO"
