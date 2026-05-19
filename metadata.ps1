#Requires -Version 5.1
<#
.SYNOPSIS
    Azure DevOps Metadata Extraction Tool

.DESCRIPTION
    Extracts metadata from ADO projects for repositories, branches, pipelines,
    variable groups, and agent pools. Exports everything to Excel workbooks.

.PARAMETER OrgUrl
    Azure DevOps organization URL (e.g. https://dev.azure.com/myorg)

.PARAMETER Project
    Target ADO project name. Script operates at project scope only.

.PARAMETER Pat
    Personal Access Token. If omitted, falls back to AZURE_DEVOPS_EXT_PAT env var
    or prompts securely.

.PARAMETER OutputDir
    Directory for Excel output files. Defaults to .\ADO-Export

.EXAMPLE
    .\ADO-Metadata-Tool.ps1 -OrgUrl "https://dev.azure.com/myorg" -Project "MyProject"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string]$OrgUrl,
    [Parameter(Mandatory = $false)] [string]$Project,
    [Parameter(Mandatory = $false)] [string]$Pat,
    [Parameter(Mandatory = $false)] [string]$OutputDir = ".\ADO-Export"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:VERSION = "1.1.0"

# ---------------------------------------------------------------------------
# Region: Output helpers
# ---------------------------------------------------------------------------
function Write-Header {
    param([string]$Text)
    Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
    Write-Host "  $Text"       -ForegroundColor Cyan
    Write-Host "$('=' * 60)`n" -ForegroundColor Cyan
}
function Write-Step { param([string]$T) Write-Host "  [>] $T" -ForegroundColor Yellow  }
function Write-Ok   { param([string]$T) Write-Host "  [+] $T" -ForegroundColor Green   }
function Write-Warn { param([string]$T) Write-Host "  [!] $T" -ForegroundColor Magenta }
function Write-Err  { param([string]$T) Write-Host "  [X] $T" -ForegroundColor Red     }
function Write-Info { param([string]$T) Write-Host "  [-] $T" -ForegroundColor Gray    }

# ---------------------------------------------------------------------------
# Region: Dependency checks
# ---------------------------------------------------------------------------
function Assert-Dependencies {
    Write-Step "Checking dependencies..."

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI not found. Install from https://aka.ms/installazurecliwindows"
    }

    # --only-show-errors + 2>&1 is the PS 5.1-safe way to suppress az noise
    $ext = @(az extension list --query "[?name=='azure-devops'].name" --output tsv --only-show-errors 2>&1 |
             Where-Object { $_ -is [string] }) | Select-Object -First 1
    if ($ext -ne "azure-devops") {
        Write-Warn "Installing azure-devops CLI extension..."
        az extension add --name azure-devops --only-show-errors 2>&1 | Out-Null
    }

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Warn "Installing ImportExcel PowerShell module (requires internet)..."
        Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ImportExcel -ErrorAction Stop

    Write-Ok "All dependencies satisfied."
}

# ---------------------------------------------------------------------------
# Region: Authentication & configuration
# ---------------------------------------------------------------------------
function Initialize-Config {
    Write-Header "ADO Metadata Tool v$($script:VERSION)  Configuration"

    if (-not $script:OrgUrl) {
        $script:OrgUrl = Read-Host "  Enter ADO Organization URL (e.g. https://dev.azure.com/myorg)"
    }
    $script:OrgUrl = $script:OrgUrl.TrimEnd('/')

    if (-not $script:Project) {
        $script:Project = Read-Host "  Enter ADO Project name"
    }

    if (-not $script:Pat) { $script:Pat = $env:AZURE_DEVOPS_EXT_PAT }
    if (-not $script:Pat) {
        $securePat      = Read-Host "  Enter Personal Access Token (hidden)" -AsSecureString
        $bstr           = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
        $script:Pat     = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $env:AZURE_DEVOPS_EXT_PAT = $script:Pat

    Write-Step "Configuring az devops defaults (project scope only)..."
    az devops configure --defaults "organization=$($script:OrgUrl)" "project=$($script:Project)" `
        --only-show-errors 2>&1 | Out-Null
    Write-Ok "Connected: $($script:Project) @ $($script:OrgUrl)"

    if (-not (Test-Path $script:OutputDir)) {
        New-Item -ItemType Directory -Path $script:OutputDir | Out-Null
    }
    Write-Ok "Output directory: $(Resolve-Path $script:OutputDir)"
}

# ---------------------------------------------------------------------------
# Region: Core helper  az CLI wrapper
# ---------------------------------------------------------------------------
function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs an az CLI command and returns parsed JSON.
    .NOTES
        IMPORTANT: the parameter is named $CliArgs, NOT $Args.
        $Args is a PowerShell automatic variable. If you name a param $Args and
        then splat @Args, PowerShell resolves @Args to the *automatic* variable
        (empty inside a named-param function), so az receives no subcommand and
        throws "arguments required: _command_package".
    #>
    param([string[]]$CliArgs)

    $result = az @CliArgs --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = @($result | Where-Object { $_ -is [string] }) -join " "
        throw "az CLI error (exit $LASTEXITCODE): $msg"
    }
    # Filter out any stray stderr strings before deserialising
    $json = @($result | Where-Object { $_ -is [string] }) -join "`n"
    return $json | ConvertFrom-Json
}

function Get-Timestamp  { return (Get-Date -Format "yyyyMMdd_HHmmss") }
function Get-ExcelPath  { param([string]$Base) return Join-Path (Resolve-Path $script:OutputDir) "${Base}_$(Get-Timestamp).xlsx" }

# ---------------------------------------------------------------------------
# Region: EXTRACTION  Repositories
# ---------------------------------------------------------------------------
function Get-RepoMetadata {
    Write-Step "Fetching repositories..."
    $repos = Invoke-AzCli @("repos","list","--project",$script:Project)

    # @() forces array even when az returns a single object (1 repo in project)
    $rows = @(foreach ($r in $repos) {
        [PSCustomObject]@{
            Id            = $r.id
            Name          = $r.name
            DefaultBranch = $r.defaultBranch -replace "refs/heads/",""
            Size_KB       = [math]::Round($r.size / 1KB, 1)
            IsDisabled    = $r.isDisabled
            RemoteUrl     = $r.remoteUrl
            WebUrl        = $r.webUrl
            Project       = $r.project.name
            Visibility    = if ($r.project.visibility) { $r.project.visibility } else { "N/A" }
        }
    })
    Write-Ok "Found $($rows.Count) repositories."
    return $rows
}

# ---------------------------------------------------------------------------
# Region: EXTRACTION  Branches
# ---------------------------------------------------------------------------
function Get-BranchMetadata {
    param([string]$RepoName)
    Write-Step "Fetching branches for repo: $RepoName..."
    try {
        $branches = Invoke-AzCli @("repos","ref","list","--repository",$RepoName,"--filter","heads/")
    } catch {
        Write-Warn "Could not retrieve branches for $RepoName  $_"
        return @()
    }

    # @()  a repo with a single branch returns a scalar, not an array
    $rows = @(foreach ($b in $branches) {
        [PSCustomObject]@{
            Repository   = $RepoName
            BranchName   = $b.name -replace "refs/heads/",""
            ObjectId     = $b.objectId
            CreatorEmail = if ($b.creator)    { $b.creator.uniqueName    } else { "" }
            IsLocked     = $b.isLocked
            IsLockedBy   = if ($b.isLockedBy) { $b.isLockedBy.uniqueName } else { "" }
        }
    })
    return $rows
}

function Get-AllBranchMetadata {
    $repos = Invoke-AzCli @("repos","list","--project",$script:Project)
    # @() again  single repo returns scalar from foreach
    $all   = @(foreach ($r in $repos) { Get-BranchMetadata -RepoName $r.name })
    Write-Ok "Found $($all.Count) branches across $(@($repos).Count) repositories."
    return $all
}

# ---------------------------------------------------------------------------
# Region: EXTRACTION  Build Pipelines
# ---------------------------------------------------------------------------
function Get-PipelineMetadata {
    Write-Step "Fetching build pipelines..."
    $pipelines = Invoke-AzCli @("pipelines","list","--project",$script:Project)

    $rows = @(foreach ($p in $pipelines) {
        try   { $detail = Invoke-AzCli @("pipelines","show","--id",$p.id,"--project",$script:Project) }
        catch { $detail = $p }

        [PSCustomObject]@{
            Id            = $p.id
            Name          = $p.name
            Type          = if ($detail.process)  { $detail.process.type  } else { "N/A" }
            QueueStatus   = $p.queueStatus
            AgentPoolName = if ($detail.queue)     { $detail.queue.name   } else { "N/A" }
            Repository    = if ($detail.repository){ $detail.repository.name } else { "N/A" }
            DefaultBranch = if ($detail.repository){ $detail.repository.defaultBranch -replace "refs/heads/","" } else { "N/A" }
            YamlPath      = if ($detail.process -and $detail.process.yamlFilename) { $detail.process.yamlFilename } else { "N/A" }
            CreatedDate   = $p.createdDate
            AuthoredBy    = if ($p.authoredBy)    { $p.authoredBy.uniqueName } else { "N/A" }
        }
    })
    Write-Ok "Found $($rows.Count) build pipelines."
    return $rows
}

# ---------------------------------------------------------------------------
# Region: EXTRACTION  Release Pipelines (REST  az CLI has no coverage)
# ---------------------------------------------------------------------------
function Get-ReleasePipelineMetadata {
    Write-Step "Fetching release pipelines..."
    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:Pat)"))
        $headers = @{ Authorization = "Basic $encoded"; "Content-Type" = "application/json" }
        $proj    = [Uri]::EscapeDataString($script:Project)
        $uri     = "$($script:OrgUrl)/$proj/_apis/release/definitions?api-version=7.1"
        $defs    = (Invoke-RestMethod -Uri $uri -Headers $headers -Method GET).value
    } catch {
        Write-Warn "Could not fetch release pipelines: $_"
        return @()
    }

    $rows = @(foreach ($d in $defs) {
        [PSCustomObject]@{
            Id                = $d.id
            Name              = $d.name
            CreatedBy         = $d.createdBy.uniqueName
            CreatedOn         = $d.createdOn
            ModifiedBy        = $d.modifiedBy.uniqueName
            ModifiedOn        = $d.modifiedOn
            ReleaseNameFormat = $d.releaseNameFormat
            Environments      = (@($d.environments) | ForEach-Object { $_.name }) -join ", "
        }
    })
    Write-Ok "Found $($rows.Count) release pipelines."
    return $rows
}

# ---------------------------------------------------------------------------
# Region: EXTRACTION  Variable Groups & Variables
# ---------------------------------------------------------------------------
function Get-VariableGroupMetadata {
    Write-Step "Fetching variable groups..."
    $groups = Invoke-AzCli @("pipelines","variable-group","list","--project",$script:Project)

    $groupRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $varRows   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($g in $groups) {
        # @() around Get-Member so .Count is safe when only 1 variable exists
        $members      = @($g.variables | Get-Member -MemberType NoteProperty)
        $varCount     = $members.Count
        $varNames     = $members | Select-Object -ExpandProperty Name

        $groupRows.Add([PSCustomObject]@{
            GroupId       = $g.id
            GroupName     = $g.name
            Description   = $g.description
            Type          = $g.type
            IsShared      = $g.isShared
            VariableCount = $varCount
            CreatedBy     = if ($g.createdBy)  { $g.createdBy.uniqueName  } else { "" }
            CreatedOn     = $g.createdOn
            ModifiedBy    = if ($g.modifiedBy) { $g.modifiedBy.uniqueName } else { "" }
            ModifiedOn    = $g.modifiedOn
        })

        foreach ($varName in $varNames) {
            $v = $g.variables.$varName
            $varRows.Add([PSCustomObject]@{
                GroupId      = $g.id
                GroupName    = $g.name
                VariableName = $varName
                Value        = if ($v.isSecret) { "*** (secret)" } else { $v.value }
                IsSecret     = $v.isSecret
            })
        }
    }

    Write-Ok "Found $($groupRows.Count) variable groups with $($varRows.Count) variables."
    return @{ Groups = $groupRows.ToArray(); Variables = $varRows.ToArray() }
}

# ---------------------------------------------------------------------------
# Region: EXTRACTION  Agent Queues & Agents (project-scoped)
# ---------------------------------------------------------------------------
function Get-AgentMetadata {
    Write-Step "Fetching agent queues and agents (project-scoped)..."

    # az pipelines queue list = project-scoped; pool list = org-scoped (rejects --project)
    $queues = Invoke-AzCli @("pipelines","queue","list","--project",$script:Project)

    $poolRows    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $agentRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seenPoolIds = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($q in $queues) {
        $pool   = $q.pool
        $poolId = [int]$pool.id

        $poolRows.Add([PSCustomObject]@{
            QueueId      = $q.id
            QueueName    = $q.name
            PoolId       = $poolId
            PoolName     = $pool.name
            PoolType     = $pool.poolType
            IsHosted     = $pool.isHosted
            ProjectScoped = ($null -ne $q.projectId)
        })

        # Fetch agents once per pool (multiple queues can share a pool)
        if (-not $seenPoolIds.Add($poolId)) { continue }

        try {
            $agents = Invoke-AzCli @("pipelines","agent","list","--pool-id",$poolId,"--include-capabilities")
            foreach ($a in $agents) {
                $agentRows.Add([PSCustomObject]@{
                    PoolId            = $poolId
                    PoolName          = $pool.name
                    AgentId           = $a.id
                    AgentName         = $a.name
                    Status            = $a.status
                    Enabled           = $a.enabled
                    Version           = $a.version
                    OSDescription     = $a.osDescription
                    ComputerName      = if ($a.systemCapabilities) { $a.systemCapabilities.'Agent.ComputerName' } else { "" }
                    LastSeen          = $a.lastAliveTime
                    ProvisioningState = if ($a.provisioningState) { $a.provisioningState } else { "N/A" }
                })
            }
        } catch {
            Write-Warn "Could not list agents for pool '$($pool.name)' (id=$poolId): $_"
        }
    }

    Write-Ok "Found $($poolRows.Count) queue(s) / $($seenPoolIds.Count) unique pool(s) with $($agentRows.Count) agent(s)."
    return @{ Pools = $poolRows.ToArray(); Agents = $agentRows.ToArray() }
}

# ---------------------------------------------------------------------------
# Region: Excel Export
# ---------------------------------------------------------------------------
function Export-ToExcel {
    param(
        [hashtable]$Data,
        [string]$FilePath
    )
    Write-Step "Writing Excel workbook: $FilePath"

    $keys = @($Data.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $sheet = $keys[$i]
        # @() here: if the stored value is a single object (not array), .Count would throw
        $rows  = @($Data[$sheet])

        if ($rows.Count -eq 0) {
            Write-Info "Skipping empty sheet: $sheet"
            continue
        }

        $params = @{
            Path          = $FilePath
            WorksheetName = $sheet
            AutoSize      = $true
            AutoFilter    = $true
            FreezeTopRow  = $true
            BoldTopRow    = $true
        }
        if ($i -gt 0) { $params['Append'] = $true }

        $rows | Export-Excel @params
        Write-Ok "Sheet '$sheet' written ($($rows.Count) rows)."
    }
}

function Invoke-ExportAll {
    Write-Header "Full Extraction  All Components"

    $repos     = Get-RepoMetadata
    $branches  = Get-AllBranchMetadata
    $pipelines = Get-PipelineMetadata
    $releases  = Get-ReleasePipelineMetadata
    $varData   = Get-VariableGroupMetadata
    $agentData = Get-AgentMetadata

    $outFile = Get-ExcelPath "ADO_Metadata_$($script:Project -replace '\s','_')"

    $sheets = [ordered]@{
        "Repositories"      = $repos
        "Branches"          = $branches
        "Build Pipelines"   = $pipelines
        "Release Pipelines" = $releases
        "Variable Groups"   = $varData.Groups
        "Variables"         = $varData.Variables
        "Agent Queues"      = $agentData.Pools
        "Agents"            = $agentData.Agents
    }

    Export-ToExcel -Data $sheets -FilePath $outFile
    Write-Ok "Export complete: $outFile"
}

function Invoke-ExportSingle {
    Write-Host "`n  Select component to export:"
    Write-Host "  1. Repositories"
    Write-Host "  2. Branches"
    Write-Host "  3. Build Pipelines"
    Write-Host "  4. Release Pipelines"
    Write-Host "  5. Variable Groups & Variables"
    Write-Host "  6. Agent Queues & Agents"
    $choice = Read-Host "  Choice [1-6]"

    switch ($choice) {
        "1" {
            $data = Get-RepoMetadata
            Export-ToExcel -Data @{ Repositories = $data } -FilePath (Get-ExcelPath "Repositories")
        }
        "2" {
            $data = Get-AllBranchMetadata
            Export-ToExcel -Data @{ Branches = $data } -FilePath (Get-ExcelPath "Branches")
        }
        "3" {
            $data = Get-PipelineMetadata
            Export-ToExcel -Data @{ "Build Pipelines" = $data } -FilePath (Get-ExcelPath "BuildPipelines")
        }
        "4" {
            $data = Get-ReleasePipelineMetadata
            Export-ToExcel -Data @{ "Release Pipelines" = $data } -FilePath (Get-ExcelPath "ReleasePipelines")
        }
        "5" {
            $d = Get-VariableGroupMetadata
            Export-ToExcel -Data ([ordered]@{ "Variable Groups" = $d.Groups; Variables = $d.Variables }) `
                           -FilePath (Get-ExcelPath "VariableGroups")
        }
        "6" {
            $d = Get-AgentMetadata
            Export-ToExcel -Data ([ordered]@{ "Agent Queues" = $d.Pools; Agents = $d.Agents }) `
                           -FilePath (Get-ExcelPath "Agents")
        }
        default { Write-Warn "Invalid choice." }
    }
}

# ---------------------------------------------------------------------------
# Region: Menus
# ---------------------------------------------------------------------------
function Show-ExtractMenu {
    do {
        Write-Header "Extract Metadata"
        Write-Host "  1. Extract ALL components (single workbook)"
        Write-Host "  2. Extract a single component"
        Write-Host "  0. Back`n"
        $choice = Read-Host "  Choice"
        switch ($choice) {
            "1" { Invoke-ExportAll }
            "2" { Invoke-ExportSingle }
            "0" { return }
            default { Write-Warn "Invalid choice." }
        }
    } while ($true)
}

function Show-MainMenu {
    do {
        Write-Header "ADO Metadata Tool  Project: $($script:Project)"
        Write-Host "  1. Extract metadata"
        Write-Host "  2. Reconfigure (switch project / org)"
        Write-Host "  0. Exit`n"
        $choice = Read-Host "  Choice"
        switch ($choice) {
            "1" { Show-ExtractMenu }
            "2" {
                $script:OrgUrl  = ""
                $script:Project = ""
                $script:Pat     = ""
                Initialize-Config
            }
            "0" { Write-Ok "Goodbye."; return }
            default { Write-Warn "Invalid choice, please try again." }
        }
    } while ($true)
}

# ---------------------------------------------------------------------------
# Region: Entry point
# ---------------------------------------------------------------------------
try {
    $script:OrgUrl    = $OrgUrl
    $script:Project   = $Project
    $script:Pat       = $Pat
    $script:OutputDir = $OutputDir

    Assert-Dependencies
    Initialize-Config
    Show-MainMenu
}
catch {
    Write-Err "Fatal error: $_"
    Write-Err $_.ScriptStackTrace
    exit 1
}
