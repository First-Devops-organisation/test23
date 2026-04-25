# ============================================================
#  Setup GitHub Labels - Creates all required labels in the repo
#  Phase: 02-prep
#  Idempotent: skips labels that already exist
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\boards-migration-config.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path $PSScriptRoot -Parent

. "$scriptRoot\helpers\logging.ps1"
. "$scriptRoot\helpers\github-helpers.ps1"

$config = Read-JsonConfig -Path $ConfigPath
$ghOrg  = $config.target.organization
$ghRepo = $config.target.repository
$ghPat  = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }
$logDir = Join-Path $scriptRoot $config.output.logDir

Initialize-Log -LogPath (Join-Path $logDir "setup-labels-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Write-LogSection "Phase 2b: Setup GitHub Labels"

$typeMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\workitem-type-mappings.json")
$mainConfig   = $config

$created = 0; $skipped = 0

# --- Work Item Type Labels ---
Write-Log -Message "Creating work item type labels..." -Level "INFO"
foreach ($prop in $typeMappings.types.PSObject.Properties) {
    $type = $prop.Value
    Ensure-GhLabel -Org $ghOrg -Repo $ghRepo -Name $type.githubLabel -Color $type.labelColor `
        -Description $type.labelDescription -Pat $ghPat
    $created++
    Start-Sleep -Milliseconds 500
}

# --- Additional Labels (e.g., 'migrated') ---
if ($typeMappings.additionalLabels) {
    foreach ($prop in $typeMappings.additionalLabels.PSObject.Properties) {
        $label = $prop.Value
        Ensure-GhLabel -Org $ghOrg -Repo $ghRepo -Name $prop.Name -Color $label.color `
            -Description $label.description -Pat $ghPat
        $created++
        Start-Sleep -Milliseconds 500
    }
}

# --- Priority Labels ---
Write-Log -Message "Creating priority labels..." -Level "INFO"
$priorityColors = @{
    "priority:critical" = "B60205"
    "priority:high"     = "D93F0B"
    "priority:medium"   = "FBCA04"
    "priority:low"      = "0E8A16"
}
foreach ($entry in $mainConfig.priorityMapping.PSObject.Properties) {
    $labelName = $entry.Value
    $color = if ($priorityColors[$labelName]) { $priorityColors[$labelName] } else { "EDEDED" }
    Ensure-GhLabel -Org $ghOrg -Repo $ghRepo -Name $labelName -Color $color `
        -Description "Priority level from ADO" -Pat $ghPat
    $created++
    Start-Sleep -Milliseconds 500
}

# --- Severity Labels ---
Write-Log -Message "Creating severity labels..." -Level "INFO"
$severityColors = @{
    "severity:critical" = "B60205"
    "severity:high"     = "D93F0B"
    "severity:medium"   = "FBCA04"
    "severity:low"      = "0E8A16"
}
foreach ($entry in $mainConfig.severityMapping.PSObject.Properties) {
    $labelName = $entry.Value
    $color = if ($severityColors[$labelName]) { $severityColors[$labelName] } else { "EDEDED" }
    Ensure-GhLabel -Org $ghOrg -Repo $ghRepo -Name $labelName -Color $color `
        -Description "Severity level from ADO" -Pat $ghPat
    $created++
    Start-Sleep -Milliseconds 500
}

# --- Area Path Labels ---
Write-Log -Message "Creating area path labels..." -Level "INFO"
foreach ($entry in $mainConfig.areaPathMapping.PSObject.Properties) {
    Ensure-GhLabel -Org $ghOrg -Repo $ghRepo -Name $entry.Value -Color "C5DEF5" `
        -Description "Area path: $($entry.Key)" -Pat $ghPat
    $created++
    Start-Sleep -Milliseconds 500
}

# --- Invite Mapped Users as Collaborators (optional - for personal repos/POCs) ---
# In enterprise GitHub orgs, users are already org members and have repo access.
# Set "inviteCollaborators": true in config only for personal account POCs.
if ($config.migration.inviteCollaborators -eq $true) {
    Write-Log -Message "Inviting mapped users as collaborators (inviteCollaborators=true)..." -Level "INFO"
    $userMappings = Read-JsonConfig -Path (Join-Path $scriptRoot "config\user-mappings.json")
    $invited = 0
    $uniqueUsers = $userMappings.mappings | ForEach-Object { $_.githubUsername } | Sort-Object -Unique | Where-Object { $_ }
    foreach ($ghUser in $uniqueUsers) {
        if ($ghUser -eq $ghOrg) {
            Write-Log -Message "'$ghUser' is repo owner - skipping" -Level "DEBUG"
            continue
        }
        Invite-GhCollaborator -Org $ghOrg -Repo $ghRepo -Username $ghUser -Pat $ghPat -Permission "push"
        $invited++
        Start-Sleep -Milliseconds 500
    }
    Write-Log -Message "Collaborator invitations sent: $invited users" -Level "SUCCESS"
} else {
    Write-Log -Message "Collaborator invitations skipped (inviteCollaborators=false). Users must already have repo access." -Level "INFO"
}

Write-Log -Message "Label setup complete. Processed $created labels." -Level "SUCCESS"
