param (
    [string]$MigrationType = "pipeline", # 'pipeline' or 'repo'
    [string]$ConfigFile = "",
    [string]$AdoOrg = "",
    [string]$AdoProject = "",
    [string]$AdoPat = $env:ADO_PAT,
    [string]$GitHubPat = $env:GH_PAT
)

if (-not $AdoPat) {
    Write-Error "The ADO_PAT environment variable is not set. Please set it in your variable group or pipeline."
    exit 1
}
if (-not $GitHubPat) {
    Write-Error "The GH_PAT environment variable is not set. Please set it in your variable group or pipeline."
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