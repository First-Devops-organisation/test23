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

# -------------------------------------------------------
# Extract counts
# -------------------------------------------------------
$success     = if (([regex]::Match($content, "(?i)Successful\s*[:\|]\s*(\d+)")).Success)           { [int]([regex]::Match($content, "(?i)Successful\s*[:\|]\s*(\d+)")).Groups[1].Value }
              elseif (([regex]::Match($content, "(?i)\|\s*Successful\s*\|\s*(\d+)\s*\|")).Success) { [int]([regex]::Match($content, "(?i)\|\s*Successful\s*\|\s*(\d+)\s*\|")).Groups[1].Value }
              else { 0 }

$partial     = if (([regex]::Match($content, "(?i)Partially successful\s*[:\|]\s*(\d+)")).Success) { [int]([regex]::Match($content, "(?i)Partially successful\s*[:\|]\s*(\d+)")).Groups[1].Value }
              elseif (([regex]::Match($content, "(?i)\|\s*Partially successful\s*\|\s*(\d+)\s*\|")).Success) { [int]([regex]::Match($content, "(?i)\|\s*Partially successful\s*\|\s*(\d+)\s*\|")).Groups[1].Value }
              else { 0 }

$unsupported = if (([regex]::Match($content, "(?i)Unsupported\s*[:\|]\s*(\d+)")).Success)          { [int]([regex]::Match($content, "(?i)Unsupported\s*[:\|]\s*(\d+)")).Groups[1].Value }
              elseif (([regex]::Match($content, "(?i)\|\s*Unsupported\s*\|\s*(\d+)\s*\|")).Success){ [int]([regex]::Match($content, "(?i)\|\s*Unsupported\s*\|\s*(\d+)\s*\|")).Groups[1].Value }
              else { 0 }

$failed      = if (([regex]::Match($content, "(?i)Failed\s*[:\|]\s*(\d+)")).Success)               { [int]([regex]::Match($content, "(?i)Failed\s*[:\|]\s*(\d+)")).Groups[1].Value }
              elseif (([regex]::Match($content, "(?i)\|\s*Failed\s*\|\s*(\d+)\s*\|")).Success)     { [int]([regex]::Match($content, "(?i)\|\s*Failed\s*\|\s*(\d+)\s*\|")).Groups[1].Value }
              else { 0 }

Write-Host "Counts => Success:$success  Partial:$partial  Unsupported:$unsupported  Failed:$failed"

# -------------------------------------------------------
# Extract pipeline names
# GitHub Actions Importer audit_summary.md formats:
#   Format A (table):  | pipeline/name | successful |
#   Format B (list):   - pipeline/name (successful)
#   Format C (header): ## Successful\n- pipeline/name
# -------------------------------------------------------
function Get-PipelineNames {
    param(
        [string]$rawContent,
        [string[]]$statusKeywords   # e.g. "successful", "partially successful"
    )

    $results = [System.Collections.Generic.List[string]]::new()

    foreach ($keyword in $statusKeywords) {
        # --- Format A: Markdown table  | name | status |
        $tablePattern = "(?im)^\|\s*([^|]+?)\s*\|\s*$keyword\s*\|"
        $tableMatches = [regex]::Matches($rawContent, $tablePattern)
        foreach ($m in $tableMatches) {
            $name = $m.Groups[1].Value.Trim()
            if ($name -and $name -notmatch "^[-:]+$" -and $name -ne "Pipeline" -and $name -ne "Name") {
                $results.Add($name)
            }
        }

        # --- Format B: list under a section header
        $sectionPattern = "(?is)#+\s*$keyword\s*pipelines?(.*?)(?=\n#+\s|\z)"
        $sectionMatch   = [regex]::Match($rawContent, $sectionPattern)
        if ($sectionMatch.Success) {
            $block = $sectionMatch.Groups[1].Value
            $lines = $block -split "`n"
            foreach ($line in $lines) {
                # bullet: "- some/pipeline"  or  "* some/pipeline"
                if ($line -match "^\s*[-*]\s+(.+)$") {
                    $name = $matches[1].Trim()
                    # strip any trailing parenthetical status
                    $name = $name -replace "\s*\(.*\)\s*$", ""
                    if ($name) { $results.Add($name) }
                }
            }
        }

        # --- Format C: inline "| pipeline | status |" anywhere (status in any column)
        $inlinePattern = "(?im)^\|\s*([^|]+?)\s*\|[^|]*$keyword[^|]*\|"
        $inlineMatches = [regex]::Matches($rawContent, $inlinePattern)
        foreach ($m in $inlineMatches) {
            $name = $m.Groups[1].Value.Trim()
            if ($name -and $name -notmatch "^[-:]+$" -and $name -ne "Pipeline" -and $name -ne "Name") {
                $results.Add($name)
            }
        }
    }

    # Deduplicate while preserving order
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unique = $results | Where-Object { $seen.Add($_) }
    return $unique
}

$successPipelines     = @(Get-PipelineNames $content @("successful"))
$partialPipelines     = @(Get-PipelineNames $content @("partially successful", "partial"))
$unsupportedPipelines = @(Get-PipelineNames $content @("unsupported"))
$failedPipelines      = @(Get-PipelineNames $content @("failed"))

Write-Host "Pipelines found => Success:$($successPipelines.Count)  Partial:$($partialPipelines.Count)  Unsupported:$($unsupportedPipelines.Count)  Failed:$($failedPipelines.Count)"

# Debug: if nothing found, dump the raw content
if (($successPipelines.Count + $partialPipelines.Count + $unsupportedPipelines.Count + $failedPipelines.Count) -eq 0) {
    Write-Host "WARNING: No pipeline names found. Raw audit_summary.md content:"
    Write-Host $content
}

# -------------------------------------------------------
# HTML helpers
# -------------------------------------------------------
function ConvertTo-HtmlList {
    param([string[]]$items, [string]$emptyMsg = "No pipelines found")
    if (-not $items -or $items.Count -eq 0) {
        return "<p class='empty-msg'>$emptyMsg</p>"
    }
    $lis = $items | ForEach-Object { "<li><span class='pipe-icon'>⟶</span> $_</li>" }
    return "<ul class='pipeline-list'>$($lis -join '')</ul>"
}

$successHtml     = ConvertTo-HtmlList $successPipelines     "No fully convertible pipelines"
$partialHtml     = ConvertTo-HtmlList $partialPipelines     "No partially convertible pipelines"
$unsupportedHtml = ConvertTo-HtmlList $unsupportedPipelines "No unsupported pipelines"
$failedHtml      = ConvertTo-HtmlList $failedPipelines      "No failed pipelines"

$total           = $success + $partial + $unsupported + $failed
$readyPct        = if ($total -gt 0) { [math]::Round(($success / $total) * 100) } else { 0 }
$timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm UTC"

# -------------------------------------------------------
# HTML Dashboard
# -------------------------------------------------------
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>Pipeline Migration Dashboard</title>
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Syne:wght@600;800&display=swap" rel="stylesheet"/>
    <style>
        :root {
            --bg:        #060c14;
            --surface:   #0d1a2a;
            --border:    #1a2d44;
            --text:      #cde4f8;
            --muted:     #5a7a99;
            --green:     #00e676;
            --green-bg:  #003318;
            --amber:     #ffb300;
            --amber-bg:  #2a1e00;
            --red:       #ff5252;
            --red-bg:    #2a0a0a;
            --dark-red:  #ff1744;
            --dark-red-bg: #1a0000;
            --radius:    14px;
            --mono:      'JetBrains Mono', monospace;
            --display:   'Syne', sans-serif;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            background: var(--bg);
            color: var(--text);
            font-family: var(--mono);
            min-height: 100vh;
            padding: 32px 24px 48px;
        }

        /* ---------- Header ---------- */
        .header {
            display: flex;
            align-items: flex-end;
            justify-content: space-between;
            margin-bottom: 36px;
            border-bottom: 1px solid var(--border);
            padding-bottom: 20px;
            flex-wrap: wrap;
            gap: 12px;
        }

        .header-left h1 {
            font-family: var(--display);
            font-size: 28px;
            font-weight: 800;
            letter-spacing: -0.5px;
            color: #fff;
        }

        .header-left h1 span { color: var(--green); }

        .header-left .subtitle {
            font-size: 12px;
            color: var(--muted);
            margin-top: 4px;
        }

        .badge-ready {
            background: var(--green-bg);
            border: 1px solid var(--green);
            color: var(--green);
            font-family: var(--display);
            font-size: 22px;
            font-weight: 800;
            padding: 8px 20px;
            border-radius: 8px;
            white-space: nowrap;
        }

        /* ---------- Stats row ---------- */
        .stats-row {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-bottom: 32px;
        }

        @media (max-width: 900px) { .stats-row { grid-template-columns: repeat(2, 1fr); } }
        @media (max-width: 480px) { .stats-row { grid-template-columns: 1fr; } }

        .stat-card {
            border-radius: var(--radius);
            padding: 22px 20px;
            border: 1px solid transparent;
            position: relative;
            overflow: hidden;
            transition: transform .2s;
        }
        .stat-card:hover { transform: translateY(-3px); }

        .stat-card::before {
            content: '';
            position: absolute;
            inset: 0;
            opacity: .06;
            background: radial-gradient(ellipse at top left, currentColor, transparent 70%);
        }

        .stat-card.success     { background: var(--green-bg);    border-color: var(--green);    color: var(--green); }
        .stat-card.partial     { background: var(--amber-bg);    border-color: var(--amber);    color: var(--amber); }
        .stat-card.unsupported { background: var(--red-bg);      border-color: var(--red);      color: var(--red); }
        .stat-card.failed      { background: var(--dark-red-bg); border-color: var(--dark-red); color: var(--dark-red); }

        .stat-number {
            font-family: var(--display);
            font-size: 52px;
            font-weight: 800;
            line-height: 1;
        }

        .stat-label {
            font-size: 11px;
            letter-spacing: 1.5px;
            text-transform: uppercase;
            margin-top: 6px;
            opacity: .85;
        }

        /* ---------- Pipeline lists ---------- */
        .lists-grid {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 16px;
        }

        @media (max-width: 700px) { .lists-grid { grid-template-columns: 1fr; } }

        .list-card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            overflow: hidden;
        }

        .list-header {
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 14px 18px;
            border-bottom: 1px solid var(--border);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 1px;
            text-transform: uppercase;
        }

        .list-header .dot {
            width: 10px; height: 10px;
            border-radius: 50%;
            flex-shrink: 0;
        }

        .list-header.success .dot     { background: var(--green); }
        .list-header.partial .dot     { background: var(--amber); }
        .list-header.unsupported .dot { background: var(--red); }
        .list-header.failed .dot      { background: var(--dark-red); }

        .list-header.success     { color: var(--green); }
        .list-header.partial     { color: var(--amber); }
        .list-header.unsupported { color: var(--red); }
        .list-header.failed      { color: var(--dark-red); }

        .list-body {
            padding: 14px 18px;
            max-height: 260px;
            overflow-y: auto;
        }

        .list-body::-webkit-scrollbar { width: 5px; }
        .list-body::-webkit-scrollbar-track { background: transparent; }
        .list-body::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }

        .pipeline-list {
            list-style: none;
        }

        .pipeline-list li {
            display: flex;
            align-items: flex-start;
            gap: 8px;
            padding: 7px 0;
            font-size: 13px;
            color: var(--text);
            border-bottom: 1px solid var(--border);
        }

        .pipeline-list li:last-child { border-bottom: none; }

        .pipe-icon {
            color: var(--muted);
            flex-shrink: 0;
            font-size: 11px;
            margin-top: 2px;
        }

        .empty-msg {
            font-size: 12px;
            color: var(--muted);
            font-style: italic;
            padding: 8px 0;
        }

        /* ---------- Footer ---------- */
        .footer {
            margin-top: 32px;
            text-align: center;
            font-size: 11px;
            color: var(--muted);
        }
    </style>
</head>
<body>

    <div class="header">
        <div class="header-left">
            <h1>🚀 Pipeline <span>Migration</span> Dashboard</h1>
            <div class="subtitle">Azure DevOps → GitHub Actions &nbsp;·&nbsp; Generated: $timestamp</div>
        </div>
        <div class="badge-ready">$readyPct% Migration Ready</div>
    </div>

    <!-- Counts -->
    <div class="stats-row">
        <div class="stat-card success">
            <div class="stat-number">$success</div>
            <div class="stat-label">Fully Convertible</div>
        </div>
        <div class="stat-card partial">
            <div class="stat-number">$partial</div>
            <div class="stat-label">Partially Convertible</div>
        </div>
        <div class="stat-card unsupported">
            <div class="stat-number">$unsupported</div>
            <div class="stat-label">Unsupported</div>
        </div>
        <div class="stat-card failed">
            <div class="stat-number">$failed</div>
            <div class="stat-label">Failed</div>
        </div>
    </div>

    <!-- Pipeline name lists -->
    <div class="lists-grid">
        <div class="list-card">
            <div class="list-header success"><span class="dot"></span> Fully Convertible Pipelines</div>
            <div class="list-body">$successHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header partial"><span class="dot"></span> Partially Convertible Pipelines</div>
            <div class="list-body">$partialHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header unsupported"><span class="dot"></span> Unsupported Pipelines</div>
            <div class="list-body">$unsupportedHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header failed"><span class="dot"></span> Failed Pipelines</div>
            <div class="list-body">$failedHtml</div>
        </div>
    </div>

    <div class="footer">Total pipelines scanned: $total &nbsp;·&nbsp; Report generated by GitHub Actions Importer</div>

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