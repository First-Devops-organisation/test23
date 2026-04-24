# ============================================================
#  Logging Helper - Structured logging for migration scripts
#  Usage: . .\helpers\logging.ps1
# ============================================================

# --- Global log state ---
$script:LogFile = $null
$script:LogLevel = "INFO"
$script:LogToConsole = $true
$script:LogToFile = $true

<#
.SYNOPSIS
    Initializes the logging system with a log file path.
.PARAMETER LogPath
    Full path to the log file.
.PARAMETER Level
    Minimum log level: DEBUG, INFO, WARN, ERROR
#>
function Initialize-Log {
    param(
        [string]$LogPath,
        [string]$Level = "INFO"
    )
    $dir = Split-Path $LogPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $script:LogFile = $LogPath
    $script:LogLevel = $Level
    # Write header
    $header = "========== Migration Log Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =========="
    Add-Content -Path $script:LogFile -Value $header -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Writes a structured log entry.
.PARAMETER Message
    The log message.
.PARAMETER Level
    Log level: DEBUG, INFO, WARN, ERROR, SUCCESS
.PARAMETER Data
    Optional hashtable of structured data to include.
#>
function Write-Log {
    param(
        [string]$Message = "",
        [ValidateSet("DEBUG","INFO","WARN","ERROR","SUCCESS")]
        [string]$Level = "INFO",
        [hashtable]$Data = @{}
    )

    $levelOrder = @{ "DEBUG"=0; "INFO"=1; "WARN"=2; "ERROR"=3; "SUCCESS"=1 }
    $minLevel = $levelOrder[$script:LogLevel]
    $currentLevel = $levelOrder[$Level]
    if ($currentLevel -lt $minLevel) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"

    if ($Data.Count -gt 0) {
        $dataStr = ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " | "
        $logEntry += " | $dataStr"
    }

    # Console output with colors
    if ($script:LogToConsole) {
        $color = switch ($Level) {
            "DEBUG"   { "DarkGray" }
            "INFO"    { "White" }
            "WARN"    { "Yellow" }
            "ERROR"   { "Red" }
            "SUCCESS" { "Green" }
            default   { "White" }
        }
        $icon = switch ($Level) {
            "DEBUG"   { "  " }
            "INFO"    { "ℹ️" }
            "WARN"    { "⚠️" }
            "ERROR"   { "❌" }
            "SUCCESS" { "✅" }
            default   { "  " }
        }
        Write-Host "$icon $logEntry" -ForegroundColor $color
    }

    # File output
    if ($script:LogToFile -and $script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Writes a section separator for readability.
#>
function Write-LogSection {
    param([string]$Title)
    $separator = "=" * 60
    Write-Host "" 
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
}

<#
.SYNOPSIS
    Writes a progress update (e.g., "Processing 5 of 120").
#>
function Write-LogProgress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$ItemName = "items"
    )
    $pct = if ($Total -gt 0) { [math]::Round(($Current / $Total) * 100, 1) } else { 0 }
    Write-Log -Message "Progress: $Current / $Total $ItemName ($pct%)" -Level "INFO"
}

<#
.SYNOPSIS
    Saves a structured object (hashtable/array) to a JSON report file.
.PARAMETER Data
    The object to serialize.
.PARAMETER ReportPath
    Full path to the JSON file.
#>
function Save-Report {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$ReportPath
    )
    $dir = Split-Path $ReportPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Data | ConvertTo-Json -Depth 20 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log -Message "Report saved: $ReportPath" -Level "SUCCESS"
}

<#
.SYNOPSIS
    Loads a JSON config file and returns the parsed object.
.PARAMETER Path
    Path to the JSON file.
#>
function Read-JsonConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Log -Message "Config file not found: $Path" -Level "ERROR"
        throw "Config file not found: $Path"
    }
    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    return $content | ConvertFrom-Json
}