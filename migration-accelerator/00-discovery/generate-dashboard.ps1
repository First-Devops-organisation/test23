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

# Extract values
$success = ([regex]::Match($content, "Successful:\s*(\d+)")).Groups[1].Value
$partial = ([regex]::Match($content, "Partially successful:\s*(\d+)")).Groups[1].Value
$unsupported = ([regex]::Match($content, "Unsupported:\s*(\d+)")).Groups[1].Value
$failed = ([regex]::Match($content, "Failed:\s*(\d+)")).Groups[1].Value

# Default to 0 if empty
$success = if ($success) { [int]$success } else { 0 }
$partial = if ($partial) { [int]$partial } else { 0 }
$unsupported = if ($unsupported) { [int]$unsupported } else { 0 }
$failed = if ($failed) { [int]$failed } else { 0 }

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
        }
        .card {
            padding: 20px;
            border-radius: 12px;
            width: 220px;
            box-shadow: 0px 4px 10px rgba(0,0,0,0.5);
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
    </style>
</head>
<body>

    <h1>🚀 Pipeline Migration Dashboard</h1>

    <div class="container">
        <div class="card success">
            <div class="number">$success</div>
            <div class="label">Fully Convertible</div>
        </div>

        <div class="card partial">
            <div class="number">$partial</div>
            <div class="label">Partially Convertible</div>
        </div>

        <div class="card unsupported">
            <div class="number">$unsupported</div>
            <div class="label">Unsupported</div>
        </div>

        <div class="card failed">
            <div class="number">$failed</div>
            <div class="label">Failed</div>
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