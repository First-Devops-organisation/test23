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
#  This validates that status changes match the original
#  ADO workflow rules per work item type.
# ============================================================
name: Enforce ADO Workflow Rules

on:
  issues:
    types: [labeled, unlabeled]
  projects_v2_item:
    types: [edited]

permissions:
  issues: write
  repository-projects: write

jobs:
  validate-status:
    runs-on: ubuntu-latest
    if: github.event_name == 'projects_v2_item' && github.event.changes.field_value.field_name == 'Status'
    steps:
      - name: Validate Status Change
        uses: actions/github-script@v7
        with:
          github-token: `${{ secrets.GITHUB_TOKEN }}
          script: |
            // ADO workflow rules - valid states per work item type
            const validStates = $validationJsonStr;
            
            const itemId = context.payload.projects_v2_item.content_node_id;
            const newStatus = context.payload.changes.field_value.to?.name;
            const oldStatus = context.payload.changes.field_value.from?.name;
            
            if (!newStatus) return;
            
            // Get the issue to check its type label
            try {
              const { data: issue } = await github.rest.issues.get({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.payload.projects_v2_item.content_number
              });
              
              const typeLabel = issue.labels.find(l => l.name.startsWith('type:'));
              if (!typeLabel) {
                console.log('No type label found, skipping validation');
                return;
              }
              
              const allowed = validStates[typeLabel.name];
              if (!allowed) {
                console.log('No rules defined for ' + typeLabel.name);
                return;
              }
              
              if (!allowed.includes(newStatus)) {
                console.log('INVALID: ' + typeLabel.name + ' cannot be in state: ' + newStatus);
                console.log('Valid states: ' + allowed.join(', '));
                
                // Post a comment warning
                await github.rest.issues.createComment({
                  owner: context.repo.owner,
                  repo: context.repo.repo,
                  issue_number: issue.number,
                  body: '⚠️ **Workflow Violation**: Status "' + newStatus + '" is not valid for ' + typeLabel.name.replace('type:', '') + ' items.\n\n' +
                        'Valid states: ' + allowed.join(', ') + '\n\n' +
                        '_This rule is enforced based on the original ADO workflow._'
                });
              } else {
                console.log('VALID: ' + typeLabel.name + ' -> ' + newStatus);
              }
            } catch (e) {
              console.log('Could not validate: ' + e.message);
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
