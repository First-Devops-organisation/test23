# ============================================================
#  Validate Mappings - Pre-flight check before migration
#  Phase: 02-prep
#  Validates all config files and GitHub connectivity
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$reportsDir = Join-Path $PSScriptRoot "..\reports"
$logsDir    = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
if (-not (Test-Path $logsDir))    { New-Item -ItemType Directory -Path $logsDir    -Force | Out-Null }
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\ado-helpers.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"

$config = Read-JsonConfig -Path $ConfigPath
$logDir = Join-Path $scriptRoot $config.output.logDir

Initialize-Log -LogPath (Join-Path $logDir "validate-mappings-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 2a: Validate Mappings"

$errors   = @()
$warnings = @()

# --- 1. Validate Config File Structure ---
Write-Log -Message "Checking config structure..." -Level "INFO"
$requiredFields = @("source.organization", "source.project", "source.areaPath", "target.organization", "target.repository", "target.projectNumber")
foreach ($field in $requiredFields) {
    $parts = $field -split '\.'
    $val = $config
    foreach ($p in $parts) { $val = $val.$p }
    if ([string]::IsNullOrEmpty($val)) {
        $errors += "Missing required config field: $field"
    }
}

# --- 2. Validate PATs ---
Write-Log -Message "Checking PAT availability..." -Level "INFO"
$adoPat = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }
$ghPat  = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }

if ([string]::IsNullOrEmpty($adoPat)) { $errors += "ADO PAT not set. Set env:ADO_PAT or config." }
if ([string]::IsNullOrEmpty($ghPat))  { $errors += "GitHub PAT not set. Set env:GH_PAT or config." }

# --- 3. Test ADO Connectivity ---
if ($adoPat) {
    Write-Log -Message "Testing ADO connectivity..." -Level "INFO"
    try {
        $testIds = Get-AdoWorkItemIds -Org $config.source.organization -Project $config.source.project `
            -AreaPath $config.source.areaPath -IncludeClosed $false -Pat $adoPat
        Write-Log -Message "ADO connection OK. Found $($testIds.Count) active work items." -Level "SUCCESS"
    } catch {
        $errors += "ADO connection failed: $_"
    }
}

# --- 4. Test GitHub Connectivity ---
if ($ghPat) {
    Write-Log -Message "Testing GitHub connectivity..." -Level "INFO"
    $ghOrg  = $config.target.organization
    $ghRepo = $config.target.repository
    $ghProjNum = $config.target.projectNumber
    # Read with explicit string cast to handle null/empty PSCustomObject properties
    $ghProjectOwner = [string]$config.target.projectOwner
    $ghProjectOwnerType = [string]$config.target.projectOwnerType
    # Fallback defaults
    if ([string]::IsNullOrEmpty($ghProjectOwner)) { $ghProjectOwner = $ghOrg }
    if ([string]::IsNullOrEmpty($ghProjectOwnerType)) { $ghProjectOwnerType = "user" }
    Write-Log -Message "Project owner: $ghProjectOwner | Type: $ghProjectOwnerType | Number: $ghProjNum" -Level "INFO"

    # Test repo access
    try {
        $headers = Get-GhRestHeaders -Pat $ghPat
        Invoke-RestMethod -Uri "https://api.github.com/repos/$ghOrg/$ghRepo" -Headers $headers | Out-Null
        Write-Log -Message "GitHub repo access OK: $ghOrg/$ghRepo" -Level "SUCCESS"
    } catch {
        $errors += "Cannot access GitHub repo $ghOrg/$ghRepo`: $_"
    }

    # Test project access
    try {
        $projectId = Get-GhProjectId -Owner $ghProjectOwner -ProjectNumber $ghProjNum -Pat $ghPat -OwnerType $ghProjectOwnerType
        if ($projectId) {
            Write-Log -Message "GitHub Project #$ghProjNum accessible (ID: $projectId)" -Level "SUCCESS"

            # Validate status field options
            $fields = Get-GhProjectFields -ProjectId $projectId -Pat $ghPat
            $statusField = $fields | Where-Object { $_.__typename -eq "ProjectV2SingleSelectField" -and $_.name -eq "Status" }
            if ($statusField) {
                $ghStatusOptions = $statusField.options | ForEach-Object { $_.name }
                Write-Log -Message "GitHub Status options: $($ghStatusOptions -join ', ')" -Level "INFO"

                # Check that mapped statuses exist in GitHub
                $statusMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\status-mappings.json")
                $mappedValues = $statusMappings.defaultMapping.PSObject.Properties.Value | Sort-Object -Unique
                foreach ($val in $mappedValues) {
                    if ($val -notin $ghStatusOptions) {
                        $errors += "Mapped status '$val' not found in GitHub Project Status options. Available: $($ghStatusOptions -join ', ')"
                    }
                }
            } else {
                $warnings += "No 'Status' single-select field found in GitHub Project. Status will not be set."
            }
        } else {
            $errors += "GitHub Project #$ghProjNum not found or not accessible"
        }
    } catch {
        $errors += "GitHub Project access failed: $_"
    }
}

# --- 5. Validate User Mappings ---
Write-Log -Message "Checking user mappings..." -Level "INFO"
$userMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\user-mappings.json")
$emptyMappings = $userMappings.mappings | Where-Object { [string]::IsNullOrEmpty($_.githubUsername) }
if ($emptyMappings.Count -gt 0) {
    $names = ($emptyMappings | ForEach-Object { $_.adoDisplayName }) -join ', '
    $warnings += "Users without GitHub mapping ($($emptyMappings.Count)): $names"
}

# --- 6. Validate Work Item Type Mappings ---
Write-Log -Message "Checking work item type mappings..." -Level "INFO"
$typeMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\workitem-type-mappings.json")
foreach ($type in $config.filters.workItemTypes) {
    if (-not $typeMappings.types.$type) {
        $errors += "Work item type '$type' in filters but no mapping in workitem-type-mappings.json"
    }
}

# --- Results ---
Write-LogSection "Validation Results"

if ($warnings.Count -gt 0) {
    Write-Log -Message "WARNINGS ($($warnings.Count)):" -Level "WARN"
    foreach ($w in $warnings) { Write-Log -Message "  ⚠ $w" -Level "WARN" }
}

if ($errors.Count -gt 0) {
    Write-Log -Message "ERRORS ($($errors.Count)):" -Level "ERROR"
    foreach ($e in $errors) { Write-Log -Message "  ✗ $e" -Level "ERROR" }
    Write-Log -Message "Validation FAILED. Fix errors before migration." -Level "ERROR"
    exit 1
} else {
    Write-Log -Message "All validations PASSED. Ready to proceed." -Level "SUCCESS"
}