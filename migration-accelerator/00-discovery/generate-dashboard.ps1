<#
.SYNOPSIS
    Generates an HTML dashboard from the pipeline audit results.
.DESCRIPTION
    Parses the audit_summary.md produced by GitHub Actions Importer and generates
    a comprehensive HTML dashboard with pipeline counts, names, build steps,
    job types, manual tasks, and actions mappings.
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
$lines   = Get-Content $AuditSummaryFile

Write-Host "Audit summary loaded: $($content.Length) characters, $($lines.Count) lines"

# -------------------------------------------------------
# 1. Extract pipeline counts
#    Format: "- Successful: **46 (52%)**"
# -------------------------------------------------------
function Get-AuditCount {
    param([string]$raw, [string]$label)
    # Match: - Label: **N (P%)**  or  - Label: **N**
    $pattern = "(?im)^-\s*${label}:\s*\*\*(\d+)"
    $m = [regex]::Match($raw, $pattern)
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

$success     = Get-AuditCount $content "Successful"
$partial     = Get-AuditCount $content "Partially successful"
$unsupported = Get-AuditCount $content "Unsupported"
$failed      = Get-AuditCount $content "Failed"
$total       = $success + $partial + $unsupported + $failed

# Also extract the total from "Total: **87**"
$totalFromFile = 0
$totalMatch = [regex]::Match($content, "(?im)^Total:\s*\*\*(\d+)\*\*")
if ($totalMatch.Success) { $totalFromFile = [int]$totalMatch.Groups[1].Value }
if ($totalFromFile -gt $total) { $total = $totalFromFile }

Write-Host "Counts => Success:$success  Partial:$partial  Unsupported:$unsupported  Failed:$failed  Total:$total"

# -------------------------------------------------------
# 2. Extract pipeline names from ### sections
#    Format: ### Successful
#            #### YASH-DevOps-Serverless/pipeline-name
# -------------------------------------------------------
function Get-PipelinesInSection {
    param([string]$raw, [string]$sectionName)

    $results = [System.Collections.Generic.List[string]]::new()

    # Find the section: ### SectionName ... until next ### or end
    $pattern = "(?ims)^###\s+${sectionName}\s*\n(.*?)(?=\n###\s|\z)"
    $sectionMatch = [regex]::Match($raw, $pattern)

    if ($sectionMatch.Success) {
        $block = $sectionMatch.Groups[1].Value
        # Extract #### headers as pipeline names
        $headerMatches = [regex]::Matches($block, "(?im)^####\s+(.+)$")
        foreach ($m in $headerMatches) {
            $name = $m.Groups[1].Value.Trim()
            if ($name) { $results.Add($name) }
        }
    }

    return $results
}

$successPipelines     = @(Get-PipelinesInSection $content "Successful")
$partialPipelines     = @(Get-PipelinesInSection $content "Partially successful")
$unsupportedPipelines = @(Get-PipelinesInSection $content "Unsupported")
$failedPipelines      = @(Get-PipelinesInSection $content "Failed")

Write-Host "Pipelines found => Success:$($successPipelines.Count)  Partial:$($partialPipelines.Count)  Unsupported:$($unsupportedPipelines.Count)  Failed:$($failedPipelines.Count)"

# -------------------------------------------------------
# 3. Extract Build Steps
#    Format: "- PowerShell@2: **95**"
# -------------------------------------------------------
function Get-ItemList {
    param([string]$raw, [string]$sectionHeader, [string]$subHeader)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Find section between subHeader and next subheader/section
    $pattern = "(?ims)${subHeader}:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\n\w+[^:]*:\s*\*\*|\n###|\n##|\z)"
    $m = [regex]::Match($raw, $pattern)
    if ($m.Success) {
        $block = $m.Groups[1].Value
        $itemMatches = [regex]::Matches($block, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")
        foreach ($item in $itemMatches) {
            $results.Add([PSCustomObject]@{
                Name  = $item.Groups[1].Value.Trim()
                Count = [int]$item.Groups[2].Value
            })
        }
    }

    return $results
}

# Build steps - extract from the "### Build steps" section
$buildStepsSection = ""
$bsMatch = [regex]::Match($content, "(?ims)###\s+Build steps\s*\n(.*?)(?=\n###\s+Triggers|\n###\s+Successful|\z)")
if ($bsMatch.Success) { $buildStepsSection = $bsMatch.Groups[1].Value }

$knownSteps = [System.Collections.Generic.List[PSCustomObject]]::new()
$unknownSteps = [System.Collections.Generic.List[PSCustomObject]]::new()
$unsupportedSteps = [System.Collections.Generic.List[PSCustomObject]]::new()
$actionsList = [System.Collections.Generic.List[PSCustomObject]]::new()

# Parse Known steps
$knownBlock = [regex]::Match($buildStepsSection, "(?ims)Known:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\nUnknown:|\nUnsupported:|\nActions:|\z)")
if ($knownBlock.Success) {
    foreach ($m in [regex]::Matches($knownBlock.Groups[1].Value, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")) {
        $knownSteps.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
    }
}

# Parse Unknown steps
$unknownBlock = [regex]::Match($buildStepsSection, "(?ims)Unknown:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\nUnsupported:|\nActions:|\z)")
if ($unknownBlock.Success) {
    foreach ($m in [regex]::Matches($unknownBlock.Groups[1].Value, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")) {
        $unknownSteps.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
    }
}

# Parse Unsupported steps
$unsuppBlock = [regex]::Match($buildStepsSection, "(?ims)Unsupported:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\nActions:|\z)")
if ($unsuppBlock.Success) {
    foreach ($m in [regex]::Matches($unsuppBlock.Groups[1].Value, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")) {
        $unsupportedSteps.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
    }
}

# Parse Actions mappings
$actionsBlock = [regex]::Match($buildStepsSection, "(?ims)Actions:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\n###|\z)")
if ($actionsBlock.Success) {
    foreach ($m in [regex]::Matches($actionsBlock.Groups[1].Value, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")) {
        $actionsList.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
    }
}

# Extract totals
$knownTotal = 0; $unknownTotal = 0; $unsuppTotal = 0; $actionsTotal = 0; $buildStepsTotal = 0
$km = [regex]::Match($buildStepsSection, "(?i)Known:\s*\*\*(\d+)"); if ($km.Success) { $knownTotal = [int]$km.Groups[1].Value }
$um = [regex]::Match($buildStepsSection, "(?i)Unknown:\s*\*\*(\d+)"); if ($um.Success) { $unknownTotal = [int]$um.Groups[1].Value }
$us = [regex]::Match($buildStepsSection, "(?i)Unsupported:\s*\*\*(\d+)"); if ($us.Success) { $unsuppTotal = [int]$us.Groups[1].Value }
$am = [regex]::Match($buildStepsSection, "(?i)Actions:\s*\*\*(\d+)"); if ($am.Success) { $actionsTotal = [int]$am.Groups[1].Value }
$bt = [regex]::Match($buildStepsSection, "(?i)Total:\s*\*\*(\d+)"); if ($bt.Success) { $buildStepsTotal = [int]$bt.Groups[1].Value }

Write-Host "Build Steps => Known:$knownTotal Unknown:$unknownTotal Unsupported:$unsuppTotal Actions:$actionsTotal"

# -------------------------------------------------------
# 4. Extract Job Types
# -------------------------------------------------------
$jobTypesSection = ""
$jtMatch = [regex]::Match($content, "(?ims)###\s+Job types\s*\n(.*?)(?=\n###\s+Build|\z)")
if ($jtMatch.Success) { $jobTypesSection = $jtMatch.Groups[1].Value }

$jobTypes = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($m in [regex]::Matches($jobTypesSection, "(?im)^-\s+(\w+):\s*\*\*(\d+)\*\*")) {
    $jobTypes.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
}

# -------------------------------------------------------
# 5. Extract Manual Tasks
# -------------------------------------------------------
$manualSection = ""
$mtMatch = [regex]::Match($content, "(?ims)###\s+Manual tasks\s*\n(.*?)(?=\n###\s+Successful|\n###\s+Partially|\n###\s+Failed|\z)")
if ($mtMatch.Success) { $manualSection = $mtMatch.Groups[1].Value }

$manualTotal = 0
$mtm = [regex]::Match($manualSection, "(?i)Total:\s*\*\*(\d+)"); if ($mtm.Success) { $manualTotal = [int]$mtm.Groups[1].Value }

$secretsList = [System.Collections.Generic.List[PSCustomObject]]::new()
$runnersList = [System.Collections.Generic.List[PSCustomObject]]::new()

$secretsBlock = [regex]::Match($manualSection, "(?ims)Secrets:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\nSelf hosted|\z)")
if ($secretsBlock.Success) {
    foreach ($m in [regex]::Matches($secretsBlock.Groups[1].Value, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")) {
        $secretsList.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
    }
}

$runnersBlock = [regex]::Match($manualSection, "(?ims)Self hosted runners:\s*\*\*\d+[^*]*\*\*\s*\n(.*?)(?=\n###|\z)")
if ($runnersBlock.Success) {
    foreach ($m in [regex]::Matches($runnersBlock.Groups[1].Value, "(?im)^-\s+(.+?):\s*\*\*(\d+)\*\*")) {
        $runnersList.Add([PSCustomObject]@{ Name = $m.Groups[1].Value.Trim(); Count = [int]$m.Groups[2].Value })
    }
}

Write-Host "Manual Tasks => Total:$manualTotal Secrets:$($secretsList.Count) Runners:$($runnersList.Count)"

# -------------------------------------------------------
# HTML helpers
# -------------------------------------------------------
function ConvertTo-PipelineHtml {
    param([string[]]$items, [string]$emptyMsg = "None")
    if (-not $items -or $items.Count -eq 0) {
        return "<p class='empty-msg'>$emptyMsg</p>"
    }
    $lis = $items | ForEach-Object {
        $shortName = ($_ -split '/')[-1]
        "<li><span class='pipe-icon'>⟶</span> <span class='pipe-name' title='$_'>$shortName</span><span class='pipe-full'>$_</span></li>"
    }
    return "<ul class='pipeline-list'>$($lis -join '')</ul>"
}

function ConvertTo-StepTableHtml {
    param([System.Collections.Generic.List[PSCustomObject]]$items, [string]$emptyMsg = "None")
    if (-not $items -or $items.Count -eq 0) {
        return "<p class='empty-msg'>$emptyMsg</p>"
    }
    $rows = $items | ForEach-Object {
        $barWidth = 0
        $maxCount = ($items | Measure-Object -Property Count -Maximum).Maximum
        if ($maxCount -gt 0) { $barWidth = [math]::Round(($_.Count / $maxCount) * 100) }
        "<tr><td class='step-name'>$($_.Name)</td><td class='step-count'>$($_.Count)</td><td class='step-bar'><div class='bar' style='width:${barWidth}%'></div></td></tr>"
    }
    return "<table class='step-table'>$($rows -join '')</table>"
}

$successHtml     = ConvertTo-PipelineHtml $successPipelines     "No fully convertible pipelines"
$partialHtml     = ConvertTo-PipelineHtml $partialPipelines     "No partially convertible pipelines"
$unsupportedHtml = ConvertTo-PipelineHtml $unsupportedPipelines "No unsupported pipelines"
$failedHtml      = ConvertTo-PipelineHtml $failedPipelines      "No failed pipelines"

$knownHtml       = ConvertTo-StepTableHtml $knownSteps       "No known steps"
$unknownHtml     = ConvertTo-StepTableHtml $unknownSteps     "No unknown steps"
$unsuppStepHtml  = ConvertTo-StepTableHtml $unsupportedSteps "No unsupported steps"
$actionsHtml     = ConvertTo-StepTableHtml $actionsList      "No actions mapped"
$jobTypesHtml    = ConvertTo-StepTableHtml $jobTypes         "No job types"
$secretsHtml     = ConvertTo-StepTableHtml $secretsList      "No secrets"
$runnersHtml     = ConvertTo-StepTableHtml $runnersList      "No self-hosted runners"

$readyPct  = if ($total -gt 0) { [math]::Round(($success / $total) * 100) } else { 0 }
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm UTC"

$knownPct     = if ($buildStepsTotal -gt 0) { [math]::Round(($knownTotal / $buildStepsTotal) * 100) } else { 0 }
$unknownPct   = if ($buildStepsTotal -gt 0) { [math]::Round(($unknownTotal / $buildStepsTotal) * 100) } else { 0 }
$unsuppStepPct = if ($buildStepsTotal -gt 0) { [math]::Round(($unsuppTotal / $buildStepsTotal) * 100) } else { 0 }

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
            --blue:      #448aff;
            --blue-bg:   #0a1a3a;
            --purple:    #b388ff;
            --purple-bg: #1a0a2e;
            --cyan:      #00e5ff;
            --cyan-bg:   #002a33;
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
            max-width: 1400px;
            margin: 0 auto;
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

        /* ---------- Section headers ---------- */
        .section-title {
            font-family: var(--display);
            font-size: 18px;
            font-weight: 700;
            color: #fff;
            margin: 36px 0 16px;
            padding-bottom: 8px;
            border-bottom: 1px solid var(--border);
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .section-title .icon { font-size: 20px; }

        /* ---------- Stats row ---------- */
        .stats-row {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-bottom: 12px;
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
        .stat-card.info        { background: var(--blue-bg);     border-color: var(--blue);     color: var(--blue); }
        .stat-card.purple      { background: var(--purple-bg);   border-color: var(--purple);   color: var(--purple); }
        .stat-card.cyan        { background: var(--cyan-bg);     border-color: var(--cyan);     color: var(--cyan); }

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

        /* ---------- Mini stats row ---------- */
        .mini-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
            gap: 12px;
            margin-bottom: 16px;
        }

        .mini-card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 14px 16px;
            text-align: center;
        }

        .mini-card .mini-num {
            font-family: var(--display);
            font-size: 28px;
            font-weight: 800;
            color: #fff;
        }

        .mini-card .mini-label {
            font-size: 10px;
            color: var(--muted);
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-top: 4px;
        }

        .mini-card .mini-pct {
            font-size: 11px;
            color: var(--green);
            margin-top: 2px;
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
            justify-content: space-between;
            gap: 10px;
            padding: 14px 18px;
            border-bottom: 1px solid var(--border);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 1px;
            text-transform: uppercase;
        }

        .list-header .left { display: flex; align-items: center; gap: 10px; }

        .list-header .dot {
            width: 10px; height: 10px;
            border-radius: 50%;
            flex-shrink: 0;
        }

        .list-header .count-badge {
            background: rgba(255,255,255,0.08);
            padding: 3px 10px;
            border-radius: 12px;
            font-size: 11px;
        }

        .list-header.success .dot     { background: var(--green); }
        .list-header.partial .dot     { background: var(--amber); }
        .list-header.unsupported .dot { background: var(--red); }
        .list-header.failed .dot      { background: var(--dark-red); }
        .list-header.info .dot        { background: var(--blue); }
        .list-header.purple .dot      { background: var(--purple); }
        .list-header.cyan .dot        { background: var(--cyan); }

        .list-header.success     { color: var(--green); }
        .list-header.partial     { color: var(--amber); }
        .list-header.unsupported { color: var(--red); }
        .list-header.failed      { color: var(--dark-red); }
        .list-header.info        { color: var(--blue); }
        .list-header.purple      { color: var(--purple); }
        .list-header.cyan        { color: var(--cyan); }

        .list-body {
            padding: 10px 18px;
            max-height: 320px;
            overflow-y: auto;
        }

        .list-body::-webkit-scrollbar { width: 5px; }
        .list-body::-webkit-scrollbar-track { background: transparent; }
        .list-body::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }

        .pipeline-list { list-style: none; }

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

        .pipe-name { font-weight: 700; }
        .pipe-full {
            font-size: 10px;
            color: var(--muted);
            display: block;
            margin-top: 2px;
            word-break: break-all;
        }

        .empty-msg {
            font-size: 12px;
            color: var(--muted);
            font-style: italic;
            padding: 8px 0;
        }

        /* ---------- Step table ---------- */
        .step-table {
            width: 100%;
            border-collapse: collapse;
        }

        .step-table tr { border-bottom: 1px solid var(--border); }
        .step-table tr:last-child { border-bottom: none; }

        .step-table td { padding: 6px 0; font-size: 12px; }

        .step-name {
            color: var(--text);
            max-width: 240px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .step-count {
            text-align: right;
            font-weight: 700;
            color: #fff;
            padding-right: 12px !important;
            width: 50px;
        }

        .step-bar { width: 40%; }
        .step-bar .bar {
            height: 6px;
            border-radius: 3px;
            background: linear-gradient(90deg, var(--blue), var(--cyan));
            min-width: 2px;
            transition: width 0.3s;
        }

        /* ---------- Footer ---------- */
        .footer {
            margin-top: 40px;
            text-align: center;
            font-size: 11px;
            color: var(--muted);
            border-top: 1px solid var(--border);
            padding-top: 20px;
        }

        /* ---------- Collapsible ---------- */
        .collapse-toggle {
            background: none;
            border: 1px solid var(--border);
            color: var(--muted);
            font: inherit;
            font-size: 11px;
            padding: 4px 12px;
            border-radius: 6px;
            cursor: pointer;
            margin-left: auto;
        }
        .collapse-toggle:hover { border-color: var(--text); color: var(--text); }
    </style>
</head>
<body>

    <div class="header">
        <div class="header-left">
            <h1>🚀 Pipeline <span>Migration</span> Dashboard</h1>
            <div class="subtitle">Azure DevOps → GitHub Actions &nbsp;·&nbsp; Generated: $timestamp &nbsp;·&nbsp; YASH-DevOps-Serverless</div>
        </div>
        <div class="badge-ready">$readyPct% Migration Ready</div>
    </div>

    <!-- ============ PIPELINE COUNTS ============ -->
    <div class="section-title"><span class="icon">📊</span> Pipeline Conversion Summary</div>
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

    <!-- ============ JOB TYPES ============ -->
    <div class="mini-stats">
        <div class="mini-card">
            <div class="mini-num">$total</div>
            <div class="mini-label">Total Pipelines</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$($jobTypes | Where-Object Name -eq 'YAML' | ForEach-Object Count)</div>
            <div class="mini-label">YAML Pipelines</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$($jobTypes | Where-Object Name -eq 'designer' | ForEach-Object Count)</div>
            <div class="mini-label">Classic Build</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$($jobTypes | Where-Object Name -eq 'release' | ForEach-Object Count)</div>
            <div class="mini-label">Classic Release</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$buildStepsTotal</div>
            <div class="mini-label">Total Build Steps</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$manualTotal</div>
            <div class="mini-label">Manual Tasks</div>
        </div>
    </div>

    <!-- ============ PIPELINE NAMES ============ -->
    <div class="section-title"><span class="icon">🔗</span> Pipeline Details</div>
    <div class="lists-grid">
        <div class="list-card">
            <div class="list-header success">
                <div class="left"><span class="dot"></span> Fully Convertible</div>
                <span class="count-badge">$($successPipelines.Count)</span>
            </div>
            <div class="list-body">$successHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header partial">
                <div class="left"><span class="dot"></span> Partially Convertible</div>
                <span class="count-badge">$($partialPipelines.Count)</span>
            </div>
            <div class="list-body">$partialHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header unsupported">
                <div class="left"><span class="dot"></span> Unsupported</div>
                <span class="count-badge">$($unsupportedPipelines.Count)</span>
            </div>
            <div class="list-body">$unsupportedHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header failed">
                <div class="left"><span class="dot"></span> Failed</div>
                <span class="count-badge">$($failedPipelines.Count)</span>
            </div>
            <div class="list-body">$failedHtml</div>
        </div>
    </div>

    <!-- ============ BUILD STEPS ============ -->
    <div class="section-title"><span class="icon">🧱</span> Build Steps Analysis</div>
    <div class="mini-stats">
        <div class="mini-card">
            <div class="mini-num">$knownTotal</div>
            <div class="mini-label">Known Steps</div>
            <div class="mini-pct">${knownPct}%</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$unknownTotal</div>
            <div class="mini-label">Unknown Steps</div>
            <div class="mini-pct" style="color:var(--amber)">${unknownPct}%</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$unsuppTotal</div>
            <div class="mini-label">Unsupported Steps</div>
            <div class="mini-pct" style="color:var(--red)">${unsuppStepPct}%</div>
        </div>
        <div class="mini-card">
            <div class="mini-num">$actionsTotal</div>
            <div class="mini-label">Actions Mapped</div>
        </div>
    </div>

    <div class="lists-grid">
        <div class="list-card">
            <div class="list-header success">
                <div class="left"><span class="dot"></span> Known Steps (Auto-Convert)</div>
                <span class="count-badge">$($knownSteps.Count) types</span>
            </div>
            <div class="list-body">$knownHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header partial">
                <div class="left"><span class="dot"></span> Unknown Steps (Need Custom Action)</div>
                <span class="count-badge">$($unknownSteps.Count) types</span>
            </div>
            <div class="list-body">$unknownHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header unsupported">
                <div class="left"><span class="dot"></span> Unsupported Steps</div>
                <span class="count-badge">$($unsupportedSteps.Count) types</span>
            </div>
            <div class="list-body">$unsuppStepHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header info">
                <div class="left"><span class="dot"></span> GitHub Actions Mappings</div>
                <span class="count-badge">$($actionsList.Count) actions</span>
            </div>
            <div class="list-body">$actionsHtml</div>
        </div>
    </div>

    <!-- ============ MANUAL TASKS ============ -->
    <div class="section-title"><span class="icon">🔧</span> Manual Tasks Required</div>
    <div class="lists-grid">
        <div class="list-card">
            <div class="list-header purple">
                <div class="left"><span class="dot"></span> Secrets to Create</div>
                <span class="count-badge">$($secretsList.Count) secrets</span>
            </div>
            <div class="list-body">$secretsHtml</div>
        </div>
        <div class="list-card">
            <div class="list-header cyan">
                <div class="left"><span class="dot"></span> Self-Hosted Runners</div>
                <span class="count-badge">$($runnersList.Count) runners</span>
            </div>
            <div class="list-body">$runnersHtml</div>
        </div>
    </div>

    <div class="footer">
        Total pipelines scanned: $total &nbsp;·&nbsp;
        Build steps analyzed: $buildStepsTotal &nbsp;·&nbsp;
        Manual tasks: $manualTotal &nbsp;·&nbsp;
        Report generated by GitHub Actions Importer v1.3
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