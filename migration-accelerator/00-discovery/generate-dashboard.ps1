<#
.SYNOPSIS
    Generates an HTML dashboard from the pipeline audit results.
.PARAMETER AuditSummaryFile
    Path to the audit_summary.md file
.PARAMETER OutputHtml
    Path for the output HTML file
#>
[CmdletBinding()]
param(
    [string]$AuditSummaryFile = "migration-accelerator/output/pipeline-audit/audit_summary.md",
    [string]$OutputHtml = "migration-accelerator/output/dashboard/index.html"
)

if (!(Test-Path $AuditSummaryFile)) {
    Write-Host "Audit summary not found at: $AuditSummaryFile"
    exit 1
}

$content = Get-Content $AuditSummaryFile -Raw

Write-Host "Audit summary content length: $($content.Length)"
Write-Host "First 500 chars: $($content.Substring(0, [Math]::Min(500, $content.Length)))"

# Extract values with more flexible regex with more flexible regex
$success = ([regex]::Match($content, "(?i)successful.*?(\d+)")).Groups[1].Value
$partial = ([regex]::Match($content, "(?i)partially.*?(\d+)")).Groups[1].Value
$unsupported = ([regex]::Match($content, "(?i)unsupported.*?(\d+)")).Groups[1].Value
$failed = ([regex]::Match($content, "(?i)failed.*?(\d+)")).Groups[1].Value

# Default to 0 if empty
$success = if ($success) { [int]$success } else { 0 }
$partial = if ($partial) { [int]$partial } else { 0 }
$unsupported = if ($unsupported) { [int]$unsupported } else { 0 }
$failed = if ($failed) { [int]$failed } else { 0 }
# Extract pipeline lists
function Get-PipelineList {
    param([string]$sectionName)
    $possibleSections = @("$sectionName", "$sectionName pipelines", "$sectionName conversions")
    foreach ($sec in $possibleSections) {
        $sectionMatch = [regex]::Match($content, "(?is)#+\s*$sec(.*?)(?=#+\s*|$)")
        if ($sectionMatch.Success) {
            Write-Host "Found section '$sec', content length: $($sectionMatch.Groups[1].Value.Length)"
            Write-Host "Section content preview: $($sectionMatch.Groups[1].Value.Substring(0, [Math]::Min(200, $sectionMatch.Groups[1].Value.Length)))"
            $lines = $sectionMatch.Groups[1].Value -split "`n"
            $pipelines = $lines | Where-Object { $_ -match "^-\s*(.+)" } | ForEach-Object { $matches[1].Trim() }
            if ($pipelines.Count -eq 0) {
                # Try table format | pipeline | status |
                $pipelines = $lines | Where-Object { $_ -match "\|\s*([^|]+)\s*\|\s*$sectionName\s*\|" } | ForEach-Object { $matches[1].Trim() }
            }
            if ($pipelines.Count -gt 0) { 
                Write-Host "Found $sec pipelines: $($pipelines.Count)"
                return $pipelines 
            }
        }
    }
    Write-Host "No pipelines found for $sectionName"
    return @()
}

# If no pipelines found for any category, output the full content for debugging
$allPipelines = $successPipelines + $partialPipelines + $unsupportedPipelines + $failedPipelines
if ($allPipelines.Count -eq 0) {
    Write-Host "No pipelines found in any category. Full audit_summary.md content:"
    Write-Host $content
}

$successPipelines = Get-PipelineList "Successful"
$partialPipelines = Get-PipelineList "Partially successful"
$unsupportedPipelines = Get-PipelineList "Unsupported"
$failedPipelines = Get-PipelineList "Failed"

# Helper function to generate HTML list
function Get-HtmlList {
    param([string[]]$pipelines)
    if ($pipelines.Count -eq 0) { return "" }
    $listItems = $pipelines | ForEach-Object { "<li>$_</li>" }
    return "<ul class='pipeline-list'>$($listItems -join '')</ul>"
}

$successList = Get-HtmlList $successPipelines
$partialList = Get-HtmlList $partialPipelines
$unsupportedList = Get-HtmlList $unsupportedPipelines
$failedList = Get-HtmlList $failedPipelines
# Create HTML Dashboard
$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Pipeline Migration Dashboard</title>
    <style>
        body {
            font-family: Arial;
            background: #0f172a;
            color: white;
            text-align: center;
        }
        h1 {
            margin-top: 20px;
        }
        .container {
            display: flex;
            justify-content: center;
            gap: 20px;
            margin-top: 40px;
            flex-wrap: wrap;
        }
        .card {
            padding: 20px;
            border-radius: 12px;
            width: 300px;
            box-shadow: 0px 4px 10px rgba(0,0,0,0.5);
            margin-bottom: 20px;
        }
        .success { background: #16a34a; }
        .partial { background: #f59e0b; }
        .unsupported { background: #dc2626; }
        .failed { background: #7f1d1d; }

        .number {
            font-size: 40px;
            font-weight: bold;
        }

        .label {
            font-size: 18px;
            margin-top: 10px;
        }

        .pipeline-list {
            text-align: left;
            margin-top: 15px;
            max-height: 200px;
            overflow-y: auto;
        }

        .pipeline-list li {
            font-size: 14px;
            margin-bottom: 5px;
        }
    </style>
</head>
<body>

    <h1>🚀 Pipeline Migration Dashboard</h1>

    <div class="container">
        <div class="card success">
            <div class="number">$success</div>
            <div class="label">Fully Convertible</div>
            $successList
        </div>

        <div class="card partial">
            <div class="number">$partial</div>
            <div class="label">Partially Convertible</div>
            $partialList
        </div>

        <div class="card unsupported">
            <div class="number">$unsupported</div>
            <div class="label">Unsupported</div>
            $unsupportedList
        </div>

        <div class="card failed">
            <div class="number">$failed</div>
            <div class="label">Failed</div>
            $failedList
        </div>
    </div>

</body>
</html>
"@

# Ensure output directory exists
$outputDir = Split-Path $OutputHtml -Parent
if (!(Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$html | Out-File -FilePath $OutputHtml -Encoding utf8NoBOM

Write-Host "Dashboard created at: $OutputHtml"