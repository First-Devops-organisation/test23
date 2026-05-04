# ============================================================
#  Python Board Injector
#  Phase: 06-build-board
#  Injects the Python Migrator to auto-create GitHub Project V2
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config\boards-migration-config.json",
    [string]$LogPath = "$PSScriptRoot\reports\migration-log.json"
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

. "$scriptRoot\helpers\logging.ps1"

Write-LogSection "Phase 6: Build Board (Python Injector)"

if (-not (Test-Path $LogPath)) {
    Write-Log -Message "No migration log found at $LogPath. Cannot build board." -Level "WARN"
    exit 0
}

# 1. Read Pipeline Configuration
$config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$adoOrg = $config.source.organization
$adoProject = $config.source.project
$adoPat = if ($config.source.pat -match '^\$\(') { $env:ADO_PAT } else { $config.source.pat }

$ghOrg = $config.target.organization
$ghRepo = $config.target.repository
$ghPat = if ($config.target.pat -match '^\$\(') { $env:GH_PAT } else { $config.target.pat }
$ghOwnerType = $config.target.projectOwnerType
if ([string]::IsNullOrWhiteSpace($ghOwnerType)) { $ghOwnerType = "org" }

# 2. Generate .env file
$pythonDir = Join-Path $scriptRoot "python-migrator"
$envPath = Join-Path $pythonDir ".env"
$envContent = @"
ADO_ORG=$adoOrg
ADO_PROJECT=$adoProject
ADO_PAT=$adoPat

GITHUB_TOKEN=$ghPat
GITHUB_OWNER=$ghOrg
GITHUB_REPO=$ghRepo
GITHUB_ORG=$ghOrg
GITHUB_OWNER_TYPE=$ghOwnerType
"@
Set-Content -Path $envPath -Value $envContent
Write-Log -Message "Generated .env for Python Migrator" -Level "INFO"

# 3. Translate migration-log.json -> migration_progress.json
$pipelineLog = Get-Content -Raw $LogPath | ConvertFrom-Json
$migratedHash = @{}

foreach ($prop in $pipelineLog.PSObject.Properties) {
    # pipeline_log has: "4379": { "issueNumber": 859, ... }
    # python script needs: "4379": 859
    $adoIdStr = $prop.Name
    $ghNum = $prop.Value.issueNumber
    if ($ghNum) {
        $migratedHash[$adoIdStr] = $ghNum
    }
}

$progressObj = @{
    migrated = $migratedHash
    projects = @{}
}

$progressPath = Join-Path $pythonDir "migration_progress.json"
$progressObj | ConvertTo-Json -Depth 10 | Set-Content -Path $progressPath
Write-Log -Message "Generated migration_progress.json ($($migratedHash.Count) items)" -Level "INFO"

# 4. Run the Python Migrator
Write-Log -Message "Installing Python requirements..." -Level "INFO"
Set-Location -Path $pythonDir
pip install -r requirements.txt -q

Write-Log -Message "Running Python GraphQL Board Injector..." -Level "INFO"
python migrate.py --board-only --skip-sprints --skip-relations --skip-queries --skip-delivery-plans

Write-Log -Message "Phase 6 Complete!" -Level "SUCCESS"
