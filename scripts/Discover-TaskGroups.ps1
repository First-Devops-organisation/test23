#Requires -Version 5.1
<#
.SYNOPSIS
    Discover and export all Azure DevOps Task Groups in a project.
.DESCRIPTION
    Uses the Azure DevOps REST API to inventory, retrieve, and save all Task Groups
    to JSON files, generating a comprehensive discovery report.
.PARAMETER Organization
    Azure DevOps Organization name or full URL.
.PARAMETER Project
    Azure DevOps Project name.
.PARAMETER Pat
    Azure DevOps Personal Access Token (PAT).
.PARAMETER OutputDir
    Directory path to save the exported JSON files. Defaults to '..\output\discovered'.
.PARAMETER Filter
    Wildcard name filter for task groups to discover (e.g. '*deploy*'). Defaults to '*'.
.PARAMETER ConfigFile
    Path to the task-mapping.json config file.
.EXAMPLE
    .\Discover-TaskGroups.ps1 -Organization "myorg" -Project "myproject" -Pat "xxxx"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string]$Pat,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "$PSScriptRoot\..\output\discovered",

    [Parameter(Mandatory = $false)]
    [string]$Filter = "*",

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "$PSScriptRoot\..\config\task-mapping.json"
)

Write-Host "[+] Initializing Task Group Discovery..." -ForegroundColor Cyan
    
    # Normalize OutputDir path
    $OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Prepare Base URL
    $BaseUrl = "https://dev.azure.com/$Organization"
    if ($Organization.StartsWith("http", [System.StringComparison]::OrdinalIgnoreCase)) {
        $BaseUrl = $Organization.TrimEnd("/")
    } elseif ($Organization -match "\.visualstudio\.com") {
        $BaseUrl = "https://$($Organization.TrimEnd('/'))"
    }

    # Base API URL
    $ApiUrl = "$BaseUrl/$Project/_apis/distributedtask/taskgroups?api-version=7.1-preview.1"
    
    # Prepare Auth Header
    if ([string]::IsNullOrWhiteSpace($Pat)) {
        Write-Error "[-] PAT (Personal Access Token) is empty or null. Please ensure the pipeline variable ADO_PAT is set and mapped correctly."
        return
    }
    
    $AuthBytes = [System.Text.Encoding]::ASCII.GetBytes(":$Pat")
    $AuthBase64 = [System.Convert]::ToBase64String($AuthBytes)
    $Headers = @{
        "Authorization" = "Basic $AuthBase64"
        "Accept"        = "application/json"
    }

Write-Host "[+] Querying ADO API: GET $ApiUrl" -ForegroundColor Yellow
    
    $Response = $null
    $MaxRetries = 3
    $RetryCount = 0
    $DelaySeconds = 2

    while ($RetryCount -lt $MaxRetries) {
        try {
            $Response = Invoke-RestMethod -Uri $ApiUrl -Headers $Headers -Method Get -ContentType "application/json"
            break
        } catch {
            $RetryCount++
            $ErrorMessage = $_.Exception.Message
            if ($_.Exception.Response) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
                if ($StatusCode -eq 401) {
                    Write-Error "[-] Authentication Failed: Please check your ADO PAT."
                    return
                }
                $ErrorMessage = "HTTP $StatusCode - $ErrorMessage"
            }
            Write-Host "[-] Request failed: $ErrorMessage. Retrying ($RetryCount/$MaxRetries) in $DelaySeconds seconds..." -ForegroundColor Red
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds *= 2
        }
    }

    $AttemptsMade = $RetryCount + 1
    if ($null -eq $Response) {
        Write-Error "[-] Failed to fetch Task Groups after $AttemptsMade attempts. Response was null."
        return
    }
    
    if (-not $Response.PSObject.Properties.Match('value').Count) {
        Write-Host "[-] API did not return expected JSON structure. Received instead:" -ForegroundColor Red
        # Print a snippet of what we actually received (e.g. an HTML sign-in page if auth failed)
        $ResponseString = $Response | Out-String
        if ($ResponseString.Length -gt 500) { $ResponseString = $ResponseString.Substring(0, 500) + "..." }
        Write-Host $ResponseString -ForegroundColor Gray
        Write-Error "[-] Failed to fetch Task Groups (Invalid Response Type)."
        return
    }

    $TaskGroups = $Response.value
    $TotalCount = $Response.count
    Write-Host "[+] Found $TotalCount total Task Group(s) in project." -ForegroundColor Green

    # Filter Task Groups by name
    $FilteredGroups = $TaskGroups | Where-Object { $_.name -like $Filter }
    $FilteredCount = ($FilteredGroups | Measure-Object).Count
    Write-Host "[+] $FilteredCount Task Group(s) matched filter '$Filter'." -ForegroundColor Green

    $DiscoveredGroups = @()
    $AllTaskTypesUsed = @{}

    # Load mapping config if available to calculate unmapped tasks
    $MappedTypes = @{}
    if (Test-Path $ConfigFile) {
        try {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($Config.mappings) {
                foreach ($Property in $Config.mappings.PSObject.Properties) {
                    $MappedTypes[$Property.Name] = $true
                }
            }
        } catch {
            Write-Warning "Failed to parse task-mapping.json: $_"
        }
    }

    foreach ($tg in $FilteredGroups) {
        $Slug = $tg.name -replace '[^a-zA-Z0-9_-]', '-'
        $Slug = $Slug.ToLower().Trim('-')
        
        $FileName = "$Slug.json"
        $FilePath = Join-Path $OutputDir $FileName

        # Export raw task group JSON
        $tgJson = $tg | ConvertTo-Json -Depth 100
        $tgJson | Set-Content -Path $FilePath -Encoding UTF8

        Write-Host "  [OK] Exported: $($tg.name) -> $FileName" -ForegroundColor Cyan

        # Collect metadata for discovery report
        $TaskCount = if ($tg.tasks) { ($tg.tasks | Measure-Object).Count } else { 0 }
        
        $DiscoveredGroups += [PSCustomObject]@{
            name      = $tg.name
            id        = $tg.id
            version   = "$($tg.version.major).$($tg.version.minor)"
            taskCount = $TaskCount
            file      = $FileName
        }

        # Inventory the tasks inside this group
        if ($tg.tasks) {
            foreach ($task in $tg.tasks) {
                $TaskName = $task.task.name
                $VersionSpec = $task.task.versionSpec
                $FullTaskType = "$TaskName@$VersionSpec"
                
                $AllTaskTypesUsed[$FullTaskType] = $true
                $AllTaskTypesUsed[$TaskName] = $true # Unversioned
            }
        }
    }

    # Find unmapped task types
    $UnmappedTaskTypes = @()
    foreach ($type in $AllTaskTypesUsed.Keys) {
        if (-not $MappedTypes.ContainsKey($type)) {
            $UnmappedTaskTypes += $type
        }
    }

    # Generate discovery report
    $ReportPath = Join-Path $OutputDir "..\discovery-report.json"
    $ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
    
    $Report = [PSCustomObject]@{
        discoveredAt      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        organization      = $OrgName
        project           = $Project
        totalTaskGroups   = $FilteredCount
        taskGroups        = $DiscoveredGroups
        allTaskTypesUsed  = [string[]]($AllTaskTypesUsed.Keys | Sort-Object)
        unmappedTaskTypes = [string[]]($UnmappedTaskTypes | Sort-Object)
    }

    $Report | ConvertTo-Json -Depth 100 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host "[+] Discovery Report written to $ReportPath" -ForegroundColor Green

    # Output colorful console summary table
    Write-Host "`n================ DISCOVERED TASK GROUPS ================" -ForegroundColor Magenta
    Write-Host ("{0,-30} | {1,-10} | {2,-10} | {3,-30}" -f "Name", "Version", "Task Count", "Export File")
    Write-Host "--------------------------------------------------------------------------------"
    foreach ($g in $DiscoveredGroups) {
        Write-Host ("{0,-30} | {1,-10} | {2,-10} | {3,-30}" -f $g.name, $g.version, $g.taskCount, $g.file)
    }
    Write-Host "========================================================`n" -ForegroundColor Magenta

Write-Host "[+] Discovery complete." -ForegroundColor Green
