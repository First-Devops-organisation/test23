<#
.SYNOPSIS
    Sets up GitHub deployment environments for multiple repositories from a CSV file.

.DESCRIPTION
    Reads a CSV file containing repository configurations and creates/updates
    GitHub environments with deployment branch policies and optional reviewer gates.
    Supports dry-run mode, detailed logging, retry logic, and generates a summary report.

.PARAMETER GHOrg
    The GitHub organization name (applies to all repos in the CSV).

.PARAMETER CsvPath
    Path to the CSV configuration file. Default: repos.csv in the same directory.

.PARAMETER DryRun
    If set, validates the CSV and shows what would be done WITHOUT making any API calls.

.PARAMETER MaxRetries
    Number of retries for failed API calls. Default: 2.

.PARAMETER LogPath
    Path to write the log file. Default: setup-env-multi-<timestamp>.log in TEMP.

.EXAMPLE
    # Dry-run first to validate
    .\setup-env-multi.ps1 -GHOrg "My-Org" -DryRun

    # Execute for real
    .\setup-env-multi.ps1 -GHOrg "My-Org" -CsvPath ".\repos.csv"

    # With custom log path
    .\setup-env-multi.ps1 -GHOrg "My-Org" -LogPath "C:\logs\env-setup.log"
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GHOrg,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath = (Join-Path $PSScriptRoot "repos.csv"),

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 5)]
    [int]$MaxRetries = 2,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $env:TEMP "setup-env-multi-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")
)

# ==============================================================================
# STRICT MODE & ERROR PREFERENCES
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# LOGGING
# ==============================================================================
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp] [$Level] $Message"

    # Console colors
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "DarkGray" }
    }

    Write-Host $logEntry -ForegroundColor $color

    # Append to log file
    $logEntry | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# ==============================================================================
# GH CLI WRAPPER WITH RETRY
# ==============================================================================
function Invoke-GhApi {
    param (
        [string]$Method,
        [string]$Endpoint,
        [string]$InputFile = $null
    )

    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        try {
            $args = @("api", "-X", $Method, $Endpoint, "--header", "Accept: application/vnd.github+json")
            if ($InputFile) {
                $args += @("--input", $InputFile)
            }

            $result = & gh @args 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                return $result
            }

            # Specific error handling
            $resultStr = $result -join "`n"
            if ($resultStr -match "404|Not Found") {
                throw "Resource not found: $Endpoint"
            }
            if ($resultStr -match "422|Validation Failed") {
                throw "Validation error on $Endpoint -- check input payload"
            }

            throw "gh api returned exit code $exitCode : $resultStr"
        }
        catch {
            if ($attempt -le $MaxRetries) {
                $waitSeconds = [math]::Pow(2, $attempt)  # Exponential backoff: 2s, 4s, 8s
                Write-Log "Attempt $attempt failed for $Method $Endpoint. Retrying in ${waitSeconds}s... ($_)" -Level "WARN"
                Start-Sleep -Seconds $waitSeconds
            }
            else {
                throw $_
            }
        }
    }
}

# ==============================================================================
# REVIEWER LOOKUP (CACHED)
# ==============================================================================
$script:UserIdCache = @{}

function Get-GitHubUserId {
    param ([string]$Username)

    if ($script:UserIdCache.ContainsKey($Username)) {
        return $script:UserIdCache[$Username]
    }

    $userId = (gh api "users/$Username" --jq '.id' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $userId) {
        $script:UserIdCache[$Username] = [int]$userId
        Write-Log "  Resolved $Username -> ID $userId" -Level "DEBUG"
        return [int]$userId
    }

    Write-Log "  Could not resolve username '$Username' -- skipping" -Level "WARN"
    return $null
}

# ==============================================================================
# ENVIRONMENT SETUP (SINGLE REPO + ENV)
# ==============================================================================
function Set-GitHubEnvironment {
    param (
        [string]$Org,
        [string]$Repo,
        [string]$EnvName,
        [string]$BranchName,
        [string[]]$Reviewers,
        [int]$WaitTimer
    )

    $repoSlug = "$Org/$Repo"
    Write-Log "--- Setting up '$EnvName' on $repoSlug ---"

    # 1. Build reviewer list
    $reviewerObjects = @()
    foreach ($username in $Reviewers) {
        if ([string]::IsNullOrWhiteSpace($username)) { continue }
        $userId = Get-GitHubUserId -Username $username.Trim()
        if ($userId) {
            $reviewerObjects += @{ type = "User"; id = $userId }
        }
    }

    # 2. Build environment config
    $envConfig = @{
        wait_timer               = $WaitTimer
        deployment_branch_policy = @{
            protected_branches      = $false
            custom_branch_policies  = $true
        }
    }

    if ($reviewerObjects.Count -gt 0) {
        $envConfig["reviewers"] = $reviewerObjects
    }

    # 3. Write JSON without BOM (avoids 400 errors)
    $envJson     = $envConfig | ConvertTo-Json -Depth 5
    $envJsonFile = Join-Path $env:TEMP "env-config-$Repo-$EnvName.json"
    [System.IO.File]::WriteAllText($envJsonFile, $envJson)
    Write-Log "  Payload: $envJson" -Level "DEBUG"

    # 4. Create / Update environment
    if (-not $DryRun) {
        Invoke-GhApi -Method "PUT" -Endpoint "repos/$repoSlug/environments/$EnvName" -InputFile $envJsonFile
        Write-Log "  Environment '$EnvName' applied" -Level "SUCCESS"
    }
    else {
        Write-Log "  [DRY-RUN] Would PUT repos/$repoSlug/environments/$EnvName" -Level "INFO"
    }

    # 5. Clean existing branch policies (avoid duplicates on re-run)
    if (-not $DryRun) {
        Write-Log "  Cleaning old branch policies..." -Level "DEBUG"
        $existing = gh api "repos/$repoSlug/environments/$EnvName/deployment-branch-policies" --jq '.branch_policies[].id' 2>$null
        foreach ($policyId in $existing) {
            if ([string]::IsNullOrWhiteSpace($policyId)) { continue }
            Invoke-GhApi -Method "DELETE" -Endpoint "repos/$repoSlug/environments/$EnvName/deployment-branch-policies/$policyId"
            Write-Log "  Deleted old policy $policyId" -Level "DEBUG"
        }
    }

    # 6. Add branch deployment rule
    $branchJson     = @{ name = $BranchName } | ConvertTo-Json
    $branchJsonFile = Join-Path $env:TEMP "branch-config-$Repo-$EnvName.json"
    [System.IO.File]::WriteAllText($branchJsonFile, $branchJson)

    if (-not $DryRun) {
        Invoke-GhApi -Method "POST" -Endpoint "repos/$repoSlug/environments/$EnvName/deployment-branch-policies" -InputFile $branchJsonFile
        Write-Log "  Branch locked to '$BranchName'" -Level "SUCCESS"
    }
    else {
        Write-Log "  [DRY-RUN] Would lock branch to '$BranchName'" -Level "INFO"
    }

    # 7. Cleanup temp files
    Remove-Item $envJsonFile    -ErrorAction SilentlyContinue
    Remove-Item $branchJsonFile -ErrorAction SilentlyContinue
}

# ==============================================================================
# MAIN
# ==============================================================================
function Main {
    Write-Log "=========================================="
    Write-Log "  Multi-Repo Environment Setup"
    Write-Log "=========================================="
    Write-Log "Org      : $GHOrg"
    Write-Log "CSV      : $CsvPath"
    Write-Log "Log      : $LogPath"
    Write-Log "Dry-Run  : $DryRun"
    Write-Log "Retries  : $MaxRetries"
    Write-Log ""

    # ---- Pre-flight checks ----
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Log "GitHub CLI (gh) is not installed or not in PATH." -Level "ERROR"
        exit 1
    }

    # Verify authentication
    $authStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Not authenticated with gh CLI. Run 'gh auth login' first." -Level "ERROR"
        Write-Log $($authStatus -join "`n") -Level "ERROR"
        exit 1
    }
    Write-Log "gh CLI authenticated OK" -Level "SUCCESS"

    # Validate CSV exists
    if (-not (Test-Path $CsvPath)) {
        Write-Log "CSV file not found: $CsvPath" -Level "ERROR"
        exit 1
    }

    # ---- Parse CSV ----
    $rawLines = Get-Content $CsvPath | Where-Object {
        $_.Trim() -ne "" -and -not $_.TrimStart().StartsWith("#")
    }

    # Expect a header row
    $header = $rawLines[0]
    $dataLines = $rawLines | Select-Object -Skip 1

    if ($dataLines.Count -eq 0) {
        Write-Log "CSV file has no data rows." -Level "WARN"
        exit 0
    }

    Write-Log "Found $($dataLines.Count) environment configuration(s) to process." -Level "INFO"
    Write-Log ""

    # ---- Process each row ----
    $results = @()     # Track pass/fail per row
    $rowIndex = 0

    foreach ($line in $dataLines) {
        $rowIndex++
        $fields = $line.Split(",")

        # Validate minimum columns
        if ($fields.Count -lt 3) {
            Write-Log "Row $rowIndex -- Skipping malformed row (need at least 3 columns): $line" -Level "WARN"
            $results += [PSCustomObject]@{ Row=$rowIndex; Repo=$line; Env="?"; Status="SKIPPED"; Error="Malformed row" }
            continue
        }

        $repo       = $fields[0].Trim()
        $envName    = $fields[1].Trim()
        $branch     = $fields[2].Trim()
        $reviewers  = if ($fields.Count -ge 4 -and $fields[3].Trim()) { $fields[3].Trim().Split("|") } else { @() }
        $waitTimer  = if ($fields.Count -ge 5 -and $fields[4].Trim()) { [int]$fields[4].Trim() } else { 0 }

        # Validate required fields
        if ([string]::IsNullOrWhiteSpace($repo) -or [string]::IsNullOrWhiteSpace($envName) -or [string]::IsNullOrWhiteSpace($branch)) {
            Write-Log "Row $rowIndex -- Missing required field(s). Skipping." -Level "WARN"
            $results += [PSCustomObject]@{ Row=$rowIndex; Repo=$repo; Env=$envName; Status="SKIPPED"; Error="Missing required field" }
            continue
        }

        Write-Log ""
        Write-Log "=== Row $rowIndex / $($dataLines.Count): $repo [$envName] ==="

        try {
            Set-GitHubEnvironment `
                -Org        $GHOrg `
                -Repo       $repo `
                -EnvName    $envName `
                -BranchName $branch `
                -Reviewers  $reviewers `
                -WaitTimer  $waitTimer

            $status = if ($DryRun) { "DRY-RUN OK" } else { "SUCCESS" }
            $results += [PSCustomObject]@{ Row=$rowIndex; Repo=$repo; Env=$envName; Status=$status; Error="" }
        }
        catch {
            Write-Log "Row $rowIndex -- FAILED: $_" -Level "ERROR"
            $results += [PSCustomObject]@{ Row=$rowIndex; Repo=$repo; Env=$envName; Status="FAILED"; Error=$_.ToString() }
            # Continue to next row -- don't abort the whole batch
        }
    }

    # ---- Summary Report ----
    Write-Log ""
    Write-Log "=========================================="
    Write-Log "  SUMMARY REPORT"
    Write-Log "=========================================="

    $successCount = ($results | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $failedCount  = ($results | Where-Object { $_.Status -eq "FAILED" }).Count
    $skippedCount = ($results | Where-Object { $_.Status -eq "SKIPPED" }).Count

    Write-Log "Total: $($results.Count)  |  Success: $successCount  |  Failed: $failedCount  |  Skipped: $skippedCount"
    Write-Log ""

    # Table output
    $results | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ -Level "INFO" }

    # Log file location
    Write-Log "Full log saved to: $LogPath" -Level "INFO"

    # Exit code
    if ($failedCount -gt 0) {
        Write-Log "Completed with $failedCount failure(s)." -Level "WARN"
        exit 1
    }

    Write-Log "All environments configured successfully!" -Level "SUCCESS"
    exit 0
}

# Run
Main
