#Requires -Version 5.1
<#
.SYNOPSIS
    Converts an exported Azure DevOps Task Group JSON file to a GitHub Actions YAML file.
.DESCRIPTION
    Parses the ADO task group parameters, maps each task step to its GitHub Actions
    equivalent using config, and compiles the result into a Composite Action or Workflow.
.PARAMETER InputFile
    Path to the task group JSON file.
.PARAMETER ConfigFile
    Path to the task-mapping.json config file.
.PARAMETER OutputDir
    Directory path to save the generated YAML.
.PARAMETER OutputMode
    Output mode: 'composite-action' or 'workflow'.
.PARAMETER TemplateDir
    Directory path containing the composite action and workflow templates.
.EXAMPLE
    .\Convert-TaskGroup.ps1 -InputFile "..\output\discovered\test1.json" -OutputMode "composite-action"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "$PSScriptRoot\..\config\task-mapping.json",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "$PSScriptRoot\..\output\migrated",

    [Parameter(Mandatory = $false)]
    [ValidateSet("composite-action", "workflow")]
    [string]$OutputMode = "composite-action",

    [Parameter(Mandatory = $false)]
    [string]$TemplateDir = "$PSScriptRoot\..\templates"
)

# Helper function to indent multiline strings
function Get-IndentedString {
    param(
        [string]$String,
        [int]$Spaces
    )
    if ([string]::IsNullOrEmpty($String)) { return "" }
    $Indent = " " * $Spaces
    $Lines = $String -split "\r?\n"
    $IndentedLines = $Lines | ForEach-Object { "$Indent$_" }
    return [string]::Join("`n", $IndentedLines)
}

# Helper to map variable syntax from ADO to GitHub Actions
function Convert-Variables {
    param(
        [string]$Value,
        [hashtable]$VarMappings
    )
    if ([string]::IsNullOrEmpty($Value)) { return "" }

    # Replace known ADO system variables first
    foreach ($AdoVar in $VarMappings.Keys) {
        $GhVar = $VarMappings[$AdoVar]
        $Value = $Value.Replace($AdoVar, $GhVar)
    }

    # Replace remaining custom variables $(MyVar) -> ${{ vars.MY_VAR }}
    # Match $(VarName) and replace with ${{ vars.VAR_NAME }} (or env / inputs as fallback)
    $Regex = '\$\(([^)]+)\)'
    $Matches = [regex]::Matches($Value, $Regex)
    foreach ($Match in $Matches) {
        $VarName = $Match.Groups[1].Value
        
        # Check if it's a known secret
        if ($VarName -like "*secret*" -or $VarName -like "*password*" -or $VarName -like "*token*" -or $VarName -like "*pat*") {
            $Replacement = '$' + '{{ secrets.' + $VarName + ' }}'
        } else {
            # Map to inputs for composite action if it's in inputs, or else default to vars
            $Replacement = '$' + '{{ inputs.' + $VarName + ' }}'
        }
        $Value = $Value.Replace($Match.Value, $Replacement)
    }

    return $Value
}
Write-Host "[+] Initializing conversion of '$(Split-Path $InputFile -Leaf)'..." -ForegroundColor Cyan

# Resolve Paths
    $InputFile = [System.IO.Path]::GetFullPath($InputFile)
    $ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)
    $OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
    $TemplateDir = [System.IO.Path]::GetFullPath($TemplateDir)

    if (-not (Test-Path $InputFile)) {
        Write-Error "[-] Input file not found: $InputFile"
        return
    }

    if (-not (Test-Path $ConfigFile)) {
        Write-Error "[-] Config file not found: $ConfigFile"
        return
    }

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Load Config
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $Mappings = $Config.mappings
    $Defaults = $Config.defaults
    
    # Convert variable mappings to hashtable
    $VarMappings = @{}
    foreach ($Property in $Config.variable_mapping.PSObject.Properties) {
        $VarMappings[$Property.Name] = $Property.Value
    }
# Load and Parse ADO JSON
    try {
        $Ado = Get-Content $InputFile -Raw | ConvertFrom-Json
    } catch {
        $Err = $_
        Write-Error "[-] Failed to parse JSON file: $Err"
        return
    }

    $TaskGroupName = $Ado.name
    $Version = "$($Ado.version.major).$($Ado.version.minor)"
    Write-Host "[+] Task Group Name: $TaskGroupName (Version: $Version)" -ForegroundColor Yellow

    # Extract Inputs/Parameters
    $InputsList = @()
    if ($Ado.inputs) {
        foreach ($input in $Ado.inputs) {
            $InputsList += [PSCustomObject]@{
                name        = $input.name
                type        = $input.type
                description = $input.label
                default     = $input.defaultValue
                required    = [bool]$input.required
            }
        }
    }

    # 1. Build Inputs block for Composite Action
    $InputsBlockBuilder = [System.Text.StringBuilder]::new()
    foreach ($in in $InputsList) {
        $InputsBlockBuilder.AppendLine("  $($in.name):") | Out-Null
        $InputsBlockBuilder.AppendLine("    description: '$($in.description)'") | Out-Null
        if ($in.default) {
            $InputsBlockBuilder.AppendLine("    default: '$($in.default)'") | Out-Null
        }
        $InputsBlockBuilder.AppendLine("    required: $($in.required.ToString().ToLower())") | Out-Null
    }
    $InputsBlock = $InputsBlockBuilder.ToString().TrimEnd()

    # 2. Build Steps block
    $StepsBlockBuilder = [System.Text.StringBuilder]::new()
    $Warnings = @()

    $StepCount = 1
    if ($Ado.tasks) {
        foreach ($task in $Ado.tasks) {
            $TaskName = $task.task.name
            $VersionSpec = $task.task.versionSpec
            $FullTaskKey = "$TaskName@$VersionSpec"
            
            $DisplayName = $task.displayName
            if ([string]::IsNullOrEmpty($DisplayName)) {
                $DisplayName = "Step ${StepCount}: $TaskName"
            }

            Write-Host "  Step ${StepCount}: $DisplayName ($FullTaskKey)..." -ForegroundColor Cyan

            # Check mapping for task type
            $Mapping = $null
            if ($Mappings.$FullTaskKey) {
                $Mapping = $Mappings.$FullTaskKey
            } elseif ($Mappings.$TaskName) {
                $Mapping = $Mappings.$TaskName
            }

            # Map ADO inputs
            $TaskInputs = @{}
            if ($task.inputs) {
                foreach ($Property in $task.inputs.PSObject.Properties) {
                    $TaskInputs[$Property.Name] = Convert-Variables $Property.Value $VarMappings
                }
            }

            # Handle enabled state
            $StepEnabled = [bool]$task.enabled
            $EnabledPrefix = ""
            if (-not $StepEnabled) {
                $EnabledPrefix = "# DISABLED STEP:`n"
            }

            if ($null -ne $Mapping) {
                if ($Mapping.type -eq "script") {
                    $Shell = $Mapping.shell
                    $Script = ""
                    
                    if ($Mapping.template) {
                        # Fill in the script template with input variables
                        $Script = $Mapping.template
                        foreach ($key in $TaskInputs.Keys) {
                            $Script = $Script.Replace("`${{ inputs.$key }}", $TaskInputs[$key])
                        }
                    } else {
                        # Default scripts inputs mapping
                        $Script = $TaskInputs["script"]
                        if ([string]::IsNullOrEmpty($Script)) { $Script = $TaskInputs["inlineScript"] }
                        if ([string]::IsNullOrEmpty($Script)) { $Script = "echo 'No script content provided'" }
                    }

                    # Format script indentation for multiline
                    $StepBuilder = [System.Text.StringBuilder]::new()
                    $StepBuilder.AppendLine("    - name: '$DisplayName'") | Out-Null
                    $StepBuilder.AppendLine("      shell: $Shell") | Out-Null
                    if ($Script -match "`n") {
                        $StepBuilder.AppendLine("      run: |") | Out-Null
                        $StepBuilder.Append((Get-IndentedString $Script 8)) | Out-Null
                        $StepBuilder.AppendLine() | Out-Null
                    } else {
                        $StepBuilder.AppendLine("      run: $Script") | Out-Null
                    }

                    # Add conditions if present
                    if ($task.condition) {
                        $Cond = Convert-Variables $task.condition $VarMappings
                        $StepBuilder.AppendLine("      if: $Cond") | Out-Null
                    }

                    $StepsBlockBuilder.Append((Get-IndentedString "$EnabledPrefix$($StepBuilder.ToString().TrimEnd())" 4)) | Out-Null
                    $StepsBlockBuilder.AppendLine() | Out-Null

                } elseif ($Mapping.type -eq "action") {
                    $Uses = $Mapping.uses
                    
                    $StepBuilder = [System.Text.StringBuilder]::new()
                    $StepBuilder.AppendLine("    - name: '$DisplayName'") | Out-Null
                    $StepBuilder.AppendLine("      uses: $Uses") | Out-Null

                    # Fill in with parameters
                    $WithBlockBuilder = [System.Text.StringBuilder]::new()
                    
                    # Merge default with mappings from task-mapping config and task inputs
                    $WithParams = @{}
                    if ($Mapping.with) {
                        foreach ($Property in $Mapping.with.PSObject.Properties) {
                            $Val = $Property.Value
                            # Resolve inputs
                            foreach ($key in $TaskInputs.Keys) {
                                $Val = $Val.Replace("`${{ inputs.$key }}", $TaskInputs[$key])
                            }
                            $WithParams[$Property.Name] = $Val
                        }
                    }

                    # Pass through matching inputs
                    foreach ($key in $TaskInputs.Keys) {
                        if (-not $WithParams.ContainsKey($key)) {
                            $WithParams[$key] = $TaskInputs[$key]
                        }
                    }

                    if ($WithParams.Count -gt 0) {
                        $WithBlockBuilder.AppendLine("      with:") | Out-Null
                        foreach ($key in $WithParams.Keys) {
                            $val = $WithParams[$key]
                            if ($val -match "`n") {
                                $WithBlockBuilder.AppendLine("        ${key}: |") | Out-Null
                                $WithBlockBuilder.Append((Get-IndentedString $val 10)) | Out-Null
                                $WithBlockBuilder.AppendLine() | Out-Null
                            } else {
                                $WithBlockBuilder.AppendLine("        ${key}: '$val'") | Out-Null
                            }
                        }
                    }

                    $StepBuilder.Append($WithBlockBuilder.ToString().TrimEnd()) | Out-Null
                    $StepBuilder.AppendLine() | Out-Null

                    # Add conditions if present
                    if ($task.condition) {
                        $Cond = Convert-Variables $task.condition $VarMappings
                        $StepBuilder.AppendLine("      if: $Cond") | Out-Null
                    }

                    $StepsBlockBuilder.Append((Get-IndentedString "$EnabledPrefix$($StepBuilder.ToString().TrimEnd())" 4)) | Out-Null
                    $StepsBlockBuilder.AppendLine() | Out-Null
                }
            } else {
                # Unmapped Task Behavior
                $Behavior = $Defaults.unmapped_behavior
                $Warnings += "Unmapped task type '$FullTaskKey' at step ${StepCount} ($DisplayName)"
                
                if ($Behavior -eq "comment") {
                    $StepBuilder = [System.Text.StringBuilder]::new()
                    $StepBuilder.AppendLine("    - name: '⚠️ UNMAPPED TASK: $DisplayName'") | Out-Null
                    $StepBuilder.AppendLine("      shell: bash") | Out-Null
                    $StepBuilder.AppendLine("      run: |") | Out-Null
                    $StepBuilder.AppendLine("        echo '========================================================================'") | Out-Null
                    $StepBuilder.AppendLine("        echo '⚠️ WARNING: This task could not be automatically mapped to a GitHub Action'") | Out-Null
                    $StepBuilder.AppendLine("        echo 'Task Type: $FullTaskKey'") | Out-Null
                    $StepBuilder.AppendLine("        echo 'Please configure this manually or update your task-mapping.json config.'") | Out-Null
                    $StepBuilder.AppendLine("        echo '========================================================================'") | Out-Null
                    $StepBuilder.AppendLine("        exit 1") | Out-Null
                    
                    $StepsBlockBuilder.Append((Get-IndentedString $StepBuilder.ToString().TrimEnd() 4)) | Out-Null
                    $StepsBlockBuilder.AppendLine() | Out-Null
                } elseif ($Behavior -eq "error") {
                    throw "Task type '$FullTaskKey' is not mapped in task-mapping.json. Aborting conversion due to default.unmapped_behavior setting."
                }
                # skip does nothing
            }

            $StepsBlockBuilder.AppendLine() | Out-Null
            $StepCount++
        }
    }
    $StepsBlock = $StepsBlockBuilder.ToString().TrimEnd()

    # Load Template and Perform Replacements
    $TemplateName = if ($OutputMode -eq "composite-action") { "composite-action.yml" } else { "workflow.yml" }
    $TemplatePath = Join-Path $TemplateDir $TemplateName

    if (-not (Test-Path $TemplatePath)) {
        Write-Error "[-] Template file not found: $TemplatePath"
        return
    }

    $TemplateContent = Get-Content $TemplatePath -Raw
    $TemplateContent = $TemplateContent.Replace("{{TASK_GROUP_NAME}}", $TaskGroupName)
    $TemplateContent = $TemplateContent.Replace("{{VERSION}}", $Version)

    if ($OutputMode -eq "composite-action") {
        $TemplateContent = $TemplateContent.Replace("{{INPUTS_BLOCK}}", $InputsBlock)
        $TemplateContent = $TemplateContent.Replace("{{STEPS_BLOCK}}", $StepsBlock)
    } else {
        # Standalone Workflow placeholders
        $CleanJobName = $TaskGroupName -replace '[^a-zA-Z0-9]', '_'
        $CleanJobName = $CleanJobName.ToLower().Trim('_')

        $TemplateContent = $TemplateContent.Replace("{{WORKFLOW_INPUTS_BLOCK}}", $InputsBlock)
        $TemplateContent = $TemplateContent.Replace("{{JOB_NAME}}", $CleanJobName)
        $TemplateContent = $TemplateContent.Replace("{{RUNNER}}", $Defaults.runner)
        $TemplateContent = $TemplateContent.Replace("{{STEPS_BLOCK}}", $StepsBlock)
    }

    # Save Output file
    $SlugName = $TaskGroupName -replace '[^a-zA-Z0-9_-]', '-'
    $SlugName = $SlugName.ToLower().Trim('-')
    
    $OutputFile = if ($OutputMode -eq "composite-action") {
        Join-Path $OutputDir "$SlugName-action.yml"
    } else {
        Join-Path $OutputDir "$SlugName-workflow.yml"
    }

    $TemplateContent | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "[+] Migrated GitHub Actions file successfully written to $OutputFile" -ForegroundColor Green

    # Output warnings if any
    if ($Warnings.Count -gt 0) {
        Write-Host "`n[!] Conversion Warnings:" -ForegroundColor Yellow
        foreach ($warn in $Warnings) {
            Write-Host "  [WARN] $warn" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # Generate log entry object to return
    $ConversionLog = [PSCustomObject]@{
        taskGroupName = $TaskGroupName
        outputFile    = $OutputFile
        outputMode    = $OutputMode
        warnings      = $Warnings
        status        = if ($Warnings.Count -gt 0) { "Completed with Warnings" } else { "Success" }
    }

    # Return conversion result for pipeline orchestrator
    return $ConversionLog

Write-Host "[+] Conversion complete." -ForegroundColor Green
