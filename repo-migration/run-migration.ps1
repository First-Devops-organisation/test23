
# Accept parameters, but allow fallback to config file for unset values
param (
    [string]$MigrationType = "pipeline", # 'pipeline' or 'repo'
    [string]$ConfigFile = "",
    [string]$AdoOrg = "",
    [string]$AdoProject = "",
    [string]$AdoPat = $env:ADO_PAT,
    [string]$GitHubPat = $env:GH_PAT
)

# Read config file if present
$configPath = if ($ConfigFile) { $ConfigFile } else { "./pipeline-migration/config/migration-config.json" }
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
} else {
    $config = @{}
}

# Prefer param/env, fallback to config file
$AdoOrg = if ($AdoOrg) { $AdoOrg } elseif ($env:ADO_ORG) { $env:ADO_ORG } elseif ($config.ADO_ORG) { $config.ADO_ORG } else { "" }
$AdoProject = if ($AdoProject) { $AdoProject } elseif ($env:ADO_PROJECT) { $env:ADO_PROJECT } elseif ($config.ADO_PROJECT) { $config.ADO_PROJECT } else { "" }
$AdoPat = if ($AdoPat) { $AdoPat } elseif ($env:ADO_PAT) { $env:ADO_PAT } elseif ($config.ADO_PAT) { $config.ADO_PAT } else { "" }
$GitHubPat = if ($GitHubPat) { $GitHubPat } elseif ($env:GH_PAT) { $env:GH_PAT } elseif ($config.GH_PAT) { $config.GH_PAT } else { "" }


# Check for required secrets
if (-not $AdoPat) {
    Write-Error "The ADO_PAT value is not set. Please set it in your variable group, pipeline, or config file."
    exit 1
}
if (-not $GitHubPat) {
    Write-Error "The GH_PAT value is not set. Please set it in your variable group, pipeline, or config file."
    exit 1
}

Write-Host "Migration type selected: $MigrationType"
Write-Host "ADO Org: $AdoOrg"
Write-Host "ADO Project: $AdoProject"
Write-Host "Config File: $ConfigFile"

if ($MigrationType -eq "pipeline") {
    Write-Host "Running pipeline migration script..."
    . ./pipeline-migration/run-migration.ps1 -ConfigFile $ConfigFile -AdoOrg $AdoOrg -AdoProject $AdoProject -AdoPat $AdoPat -GitHubPat $GitHubPat
    Write-Host "Pipeline migration completed."
}
elseif ($MigrationType -eq "repo") {
    Write-Host "Running repo migration script..."
    . ./repo-migration/run-migration.ps1 -ConfigFile $ConfigFile -AdoOrg $AdoOrg -AdoProject $AdoProject -AdoPat $AdoPat -GitHubPat $GitHubPat
    Write-Host "Repo migration completed."
}
else {
    Write-Error "Unknown migration type: $MigrationType. Use 'pipeline' or 'repo'."
    exit 1
}