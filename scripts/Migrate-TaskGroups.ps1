#Requires -Version 5.1
<#
.SYNOPSIS
    The main orchestrator script to discover, convert, and migrate Azure DevOps Task Groups to GitHub.
.DESCRIPTION
    Ties discovery and conversion steps together, executes git commands to push to a 
    GitHub repository, creates a Pull Request, and generates a detailed Markdown migration report.
.PARAMETER AdoOrganization
    Azure DevOps Organization name or full URL.
.PARAMETER AdoProject
    Azure DevOps Project name.
.PARAMETER AdoPat
    Azure DevOps Personal Access Token (PAT).
.PARAMETER GitHubOrg
    Target GitHub organization or username.
.PARAMETER GitHubRepo
    Target GitHub repository name.
.PARAMETER GitHubPat
    GitHub Personal Access Token (PAT) with repo and workflow scopes.
.PARAMETER OutputMode
    Output mode: 'composite-action' or 'workflow'. Defaults to 'composite-action'.
.PARAMETER Filter
    Wildcard name filter for task groups to discover (e.g. '*deploy*'). Defaults to '*'.
.PARAMETER DryRun
    If set, discovers and converts task groups locally but does not push to GitHub or create PRs.
.PARAMETER ConfigFile
    Path to the task-mapping.json config file.
.PARAMETER OutputDir
    Base directory for outputs. Defaults to '..\output'.
.PARAMETER BranchName
    Git branch name for the migration. Defaults to 'migrate/ado-taskgroups'.
.EXAMPLE
    .\Migrate-TaskGroups.ps1 -AdoOrganization "myorg" -AdoProject "myproj" -AdoPat "xxxx" -DryRun
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AdoOrganization,

    [Parameter(Mandatory = $true)]
    [string]$AdoProject,

    [Parameter(Mandatory = $true)]
    [string]$AdoPat,

    [Parameter(Mandatory = $false)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $false)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $false)]
    [string]$GitHubPat,

    [Parameter(Mandatory = $false)]
    [ValidateSet("composite-action", "workflow")]
    [string]$OutputMode = "composite-action",

    [Parameter(Mandatory = $false)]
    [string]$Filter = "*",

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "$PSScriptRoot\..\config\task-mapping.json",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "$PSScriptRoot\..\output",

    [Parameter(Mandatory = $false)]
    [string]$BranchName = "migrate/ado-taskgroups",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)


Write-Host "==========================================================================" -ForegroundColor Magenta
Write-Host "       Azure DevOps Task Group → GitHub Actions Migration Orchestrator     " -ForegroundColor Magenta
Write-Host "==========================================================================" -ForegroundColor Magenta
Write-Host "[+] Local Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
    
    # Normalize paths
    $OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
    $DiscoveredDir = Join-Path $OutputDir "discovered"
    $MigratedDir = Join-Path $OutputDir "migrated"

    $DiscoverScript = Join-Path $PSScriptRoot "Discover-TaskGroups.ps1"
    $ConvertScript = Join-Path $PSScriptRoot "Convert-TaskGroup.ps1"

    if (-not (Test-Path $DiscoverScript)) {
        Write-Error "[-] Discovery script not found: $DiscoverScript"
        return
    }

    if (-not (Test-Path $ConvertScript)) {
        Write-Error "[-] Conversion script not found: $ConvertScript"
        return
    }

# ---------------------------------------------------------
# PHASE 1: DISCOVERY
# ---------------------------------------------------------
    Write-Host "`n[+] PHASE 1: Running Task Group Discovery..." -ForegroundColor Yellow
    
    $DiscoverParams = @{
        Organization = $AdoOrganization
        Project      = $AdoProject
        Pat          = $AdoPat
        OutputDir    = $DiscoveredDir
        Filter       = $Filter
        ConfigFile   = $ConfigFile
    }

    try {
        & $DiscoverScript @DiscoverParams
    } catch {
        Write-Error "[-] Discovery failed: $_"
        return
    }

    $ReportPath = Join-Path $DiscoveredDir "..\discovery-report.json"
    $ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
    if (-not (Test-Path $ReportPath)) {
        Write-Error "[-] Discovery report not generated. Aborting."
        return
    }

    $DiscoveryReport = Get-Content $ReportPath -Raw | ConvertFrom-Json
    if ($DiscoveryReport.totalTaskGroups -eq 0) {
        Write-Host "[!] No task groups found matching filter '$Filter'. Done." -ForegroundColor Yellow
        return
    }

    # ---------------------------------------------------------
    # PHASE 2: CONVERSION
    # ---------------------------------------------------------
    Write-Host "`n[+] PHASE 2: Running Task Group Conversion..." -ForegroundColor Yellow

    $ConversionLogs = @()
    $AllWarnings = @()
    
    foreach ($tg in $DiscoveryReport.taskGroups) {
        $JsonFile = Join-Path $DiscoveredDir $tg.file
        
        $ConvertParams = @{
            InputFile  = $JsonFile
            ConfigFile = $ConfigFile
            OutputDir  = $MigratedDir
            OutputMode = $OutputMode
        }

        try {
            $Log = & $ConvertScript @ConvertParams
            if ($null -ne $Log) {
                $ConversionLogs += $Log
                if ($Log.warnings) {
                    $AllWarnings += $Log.warnings
                }
            }
        } catch {
            Write-Host "  [-] Failed to convert $($tg.name): $_" -ForegroundColor Red
            $ConversionLogs += [PSCustomObject]@{
                taskGroupName = $tg.name
                outputFile    = ""
                outputMode    = $OutputMode
                warnings      = @("Exception: $_")
                status        = "Failed"
            }
        }
    }

    # ---------------------------------------------------------
    # PHASE 3: PUSH TO GITHUB (If not DryRun)
    # ---------------------------------------------------------
    $PushSuccess = $false
    $PrUrl = ""

    if (-not $DryRun) {
        Write-Host "`n[+] PHASE 3: Pushing Migrated Actions to GitHub..." -ForegroundColor Yellow

        if ([string]::IsNullOrEmpty($GitHubOrg) -or [string]::IsNullOrEmpty($GitHubRepo) -or [string]::IsNullOrEmpty($GitHubPat)) {
            Write-Error "[-] GitHub Organization, Repository, and PAT are required when not running in DryRun mode."
        } else {
            # Setup git authentication & workspace
            $TempGitDir = Join-Path $OutputDir "temp-git-clone"
            if (Test-Path $TempGitDir) {
                Remove-Item -Recurse -Force $TempGitDir | Out-Null
            }
            New-Item -ItemType Directory -Path $TempGitDir -Force | Out-Null

            $RepoUrl = "https://x-access-token:$GitHubPat@github.com/$GitHubOrg/$GitHubRepo.git"
            
            try {
                Write-Host "[+] Cloning GitHub repo $GitHubOrg/$GitHubRepo..." -ForegroundColor Cyan
                git clone $RepoUrl $TempGitDir

                if ($LASTEXITCODE -eq 0) {
                    $PrevDir = Get-Location
                    Set-Location $TempGitDir

                    # Configure Git Identity
                    git config user.name "ADO Migration Bot"
                    git config user.email "ado-migration-bot@noreply.github.com"

                    # Checkout branch
                    Write-Host "[+] Creating feature branch '$BranchName'..." -ForegroundColor Cyan
                    git checkout -b $BranchName

                    # Copy migrated workflows
                    if ($OutputMode -eq "composite-action") {
                        foreach ($log in $ConversionLogs) {
                            if ($log.status -ne "Failed" -and (Test-Path $log.outputFile)) {
                                $ActionSlug = [System.IO.Path]::GetFileNameWithoutExtension($log.outputFile).Replace("-action", "")
                                $TargetActionDir = ".github/actions/$ActionSlug"
                                New-Item -ItemType Directory -Path $TargetActionDir -Force | Out-Null
                                Copy-Item $log.outputFile (Join-Path $TargetActionDir "action.yml") -Force
                            }
                        }
                    } else {
                        $TargetWorkflowDir = ".github/workflows"
                        New-Item -ItemType Directory -Path $TargetWorkflowDir -Force | Out-Null
                        foreach ($log in $ConversionLogs) {
                            if ($log.status -ne "Failed" -and (Test-Path $log.outputFile)) {
                                $FileName = [System.IO.Path]::GetFileName($log.outputFile)
                                Copy-Item $log.outputFile (Join-Path $TargetWorkflowDir $FileName) -Force
                            }
                        }
                    }

                    # Add & Commit
                    git add .github/
                    git commit -m "chore: migrate ADO task groups to GitHub Actions [automated]"

                    Write-Host "[+] Pushing branch '$BranchName' to origin..." -ForegroundColor Cyan
                    git push origin $BranchName --force

                    if ($LASTEXITCODE -eq 0) {
                        $PushSuccess = $true
                        Write-Host "[+] Workflows successfully pushed to GitHub branch!" -ForegroundColor Green

                        # Create a Pull Request via GitHub API
                        Write-Host "[+] Creating Pull Request on GitHub..." -ForegroundColor Cyan
                        $PrBody = @{
                            title = "Migrate ADO Task Groups to GitHub Actions"
                            body  = "This is an automated pull request containing converted Azure DevOps Task Groups migrated into GitHub Actions reusable components.`n`n### Migrated Task Groups:`n"
                        }
                        foreach ($log in $ConversionLogs) {
                            $PrBody.body += "- **$($log.taskGroupName)** ($($log.status))`n"
                        }

                        $PrBodyJson = $PrBody | ConvertTo-Json
                        $PrApiUrl = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/pulls"
                        
                        $PrHeaders = @{
                            "Authorization" = "token $GitHubPat"
                            "Accept"        = "application/vnd.github.v3+json"
                        }

                        $PrRequestData = @{
                            title = $PrBody.title
                            head  = $BranchName
                            base  = "main"
                            body  = $PrBody.body
                        } | ConvertTo-Json

                        try {
                            $PrResponse = Invoke-RestMethod -Uri $PrApiUrl -Headers $PrHeaders -Method Post -Body $PrRequestData -ContentType "application/json"
                            $PrUrl = $PrResponse.html_url
                            Write-Host "[+] Pull Request created successfully! URL: $PrUrl" -ForegroundColor Green
                        } catch {
                            Write-Warning "[-] Failed to automatically create Pull Request: $_"
                        }
                    } else {
                        Write-Error "[-] Failed to push branch to remote GitHub repository."
                    }

                    # Clean up directory change
                    Set-Location $PrevDir
                } else {
                    Write-Error "[-] Failed to clone GitHub repository."
                }
            } catch {
                Write-Error "[-] Git push execution failed: $_"
            }
        }
    } else {
        Write-Host "`n[+] PHASE 3: DryRun mode is active. Skipping GitHub push." -ForegroundColor Yellow
    }

    # ---------------------------------------------------------
    # PHASE 4: GENERATE REPORT
    # ---------------------------------------------------------
    Write-Host "`n[+] PHASE 4: Generating Migration Report..." -ForegroundColor Yellow

    $ReportMdPath = Join-Path $OutputDir "migration-report.md"
    $ReportMdBuilder = [System.Text.StringBuilder]::new()

    $ReportMdBuilder.AppendLine("# ADO Task Group Migration to GitHub Actions Report") | Out-Null
    $ReportMdBuilder.AppendLine("Generated on: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) (Local Time)") | Out-Null
    $ReportMdBuilder.AppendLine() | Out-Null

    $ReportMdBuilder.AppendLine("## Migration Status Summary") | Out-Null
    $ReportMdBuilder.AppendLine("| Task Group Name | Status | Output Mode | Warnings | Output File |") | Out-Null
    $ReportMdBuilder.AppendLine("| --- | --- | --- | --- | --- |") | Out-Null
    foreach ($log in $ConversionLogs) {
        $WarnCount = if ($log.warnings) { ($log.warnings | Measure-Object).Count } else { 0 }
        $ReportMdBuilder.AppendLine("| $($log.taskGroupName) | $($log.status) | $($log.outputMode) | $WarnCount | $([System.IO.Path]::GetFileName($log.outputFile)) |") | Out-Null
    }
    $ReportMdBuilder.AppendLine() | Out-Null

    if ($AllWarnings.Count -gt 0) {
        $ReportMdBuilder.AppendLine("## ⚠️ Unmapped / Manual Tasks Requiring Attention") | Out-Null
        $ReportMdBuilder.AppendLine("The following tasks were not fully mapped to GitHub Actions and need manual configuration:") | Out-Null
        foreach ($warn in $AllWarnings) {
            $ReportMdBuilder.AppendLine("- [ ] $warn") | Out-Null
        }
        $ReportMdBuilder.AppendLine() | Out-Null
    }

    if ($null -ne $DiscoveryReport.unmappedTaskTypes -and $DiscoveryReport.unmappedTaskTypes.Count -gt 0) {
        $ReportMdBuilder.AppendLine("## Unmapped Task Types Found") | Out-Null
        $ReportMdBuilder.AppendLine('You can add mapping definitions for these task types in your `config/task-mapping.json` file:') | Out-Null
        foreach ($type in $DiscoveryReport.unmappedTaskTypes) {
            $ReportMdBuilder.AppendLine('- `' + $type + '`') | Out-Null
        }
        $ReportMdBuilder.AppendLine() | Out-Null
    }

    $ReportMdBuilder.AppendLine("## Next Steps Checklist") | Out-Null
    $ReportMdBuilder.AppendLine("- [ ] Review the generated workflows or composite actions in the `output/migrated/` folder.") | Out-Null
    $ReportMdBuilder.AppendLine("- [ ] Configure target secrets in your GitHub repository setting corresponding to variable placeholders.") | Out-Null
    $ReportMdBuilder.AppendLine("- [ ] Test the migrated workflows on a feature branch inside your target GitHub environment.") | Out-Null
    if ($PrUrl) {
        $ReportMdBuilder.AppendLine("- [ ] Review and merge the Pull Request created at: $PrUrl") | Out-Null
    }
    $ReportMdBuilder.AppendLine() | Out-Null

    $ReportMdBuilder.ToString() | Set-Content -Path $ReportMdPath -Encoding UTF8
    Write-Host "[+] Detailed migration report written to $ReportMdPath" -ForegroundColor Green

    # Output final console summary
    Write-Host "`n================ MIGRATION COMPLETE ================" -ForegroundColor Green
    Write-Host "  [OK] Task Groups Discovered: $($DiscoveryReport.totalTaskGroups)" -ForegroundColor Green
    Write-Host "  [OK] Task Groups Converted:  $($ConversionLogs.Count)" -ForegroundColor Green
    if ($AllWarnings.Count -gt 0) {
        Write-Host "  [WARN] Warnings Encountered:  $($AllWarnings.Count)" -ForegroundColor Yellow
    }
    if ($PrUrl) {
        Write-Host "  [OK] Pull Request Created:   $PrUrl" -ForegroundColor Green
    }
    Write-Host "=====================================================" -ForegroundColor Green

Write-Host "[+] Migration orchestrator complete." -ForegroundColor Green
