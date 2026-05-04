# ============================================================
#  ADO REST API Helpers
#  Usage: . .\helpers\ado-helpers.ps1
# ============================================================

function Get-AdoAuthHeaders {
    param([Parameter(Mandatory)][string]$Pat)
    $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $base64"; "Content-Type" = "application/json" }
}

function Get-AdoWorkItemIds {
    param([string]$Org, [string]$Project, [string]$AreaPath, [bool]$IncludeClosed = $true, [string]$Pat)
    $closedFilter = ""
    if (-not $IncludeClosed) {
        $closedFilter = "[System.State] <> 'Done' AND [System.State] <> 'Closed' AND [System.State] <> 'Resolved' AND [System.State] <> 'Removed' AND "
    }
    $wiql = @{ query = "SELECT [System.Id] FROM workitems WHERE $closedFilter [System.AreaPath] UNDER '$AreaPath' ORDER BY [System.Id]" } | ConvertTo-Json
    $headers = Get-AdoAuthHeaders -Pat $Pat
    $uri = "https://dev.azure.com/$Org/$Project/_apis/wit/wiql?api-version=7.1"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $wiql
        return $response.workItems | ForEach-Object { $_.id }
    } catch {
        Write-Log -Message "WIQL query failed: $_" -Level "ERROR"
        throw
    }
}

function Get-AdoWorkItemDetails {
    param([string]$Org, [string]$Project, [int]$WorkItemId, [string]$Pat)
    $headers = Get-AdoAuthHeaders -Pat $Pat
    $uri = "https://dev.azure.com/$Org/$Project/_apis/wit/workitems/${WorkItemId}?`$expand=all&api-version=7.1"
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
    } catch {
        Write-Log -Message "Failed to fetch work item $WorkItemId`: $_" -Level "ERROR"
        return $null
    }
}

function Get-AdoWorkItemComments {
    param([string]$Org, [string]$Project, [int]$WorkItemId, [string]$Pat)
    $headers = Get-AdoAuthHeaders -Pat $Pat
    $uri = "https://dev.azure.com/$Org/$Project/_apis/wit/workItems/$WorkItemId/comments?api-version=7.1-preview.4"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        return $response.comments
    } catch {
        Write-Log -Message "Failed to fetch comments for $WorkItemId`: $_" -Level "WARN"
        return @()
    }
}

function Get-AdoWorkItemAttachments {
    param($WorkItemDetails)
    $attachments = @()
    if ($WorkItemDetails.relations) {
        foreach ($rel in $WorkItemDetails.relations) {
            if ($rel.rel -eq "AttachedFile") {
                $attachments += @{ Url = $rel.url; Name = $rel.attributes.name; Comment = $rel.attributes.comment }
            }
        }
    }
    return $attachments
}

function Get-AdoParentId {
    param($WorkItemDetails)
    if ($WorkItemDetails.relations) {
        $parentLink = $WorkItemDetails.relations | Where-Object { $_.rel -eq "System.LinkTypes.Hierarchy-Reverse" }
        if ($parentLink) { return [int](($parentLink.url -split '/')[-1]) }
        
        # Log if we couldn't find the parent but relations exist
        $allRels = ($WorkItemDetails.relations | ForEach-Object { $_.rel }) -join ', '
        Write-Log -Message "  Get-AdoParentId: ADO#$($WorkItemDetails.id) has relations ($allRels) but no Parent link." -Level "DEBUG"
    } else {
        Write-Log -Message "  Get-AdoParentId: No relations property found on ADO#$($WorkItemDetails.id)!" -Level "DEBUG"
    }
    return $null
}

function Get-AdoChildIds {
    param($WorkItemDetails)
    $ids = @()
    if ($WorkItemDetails.relations) {
        $WorkItemDetails.relations | Where-Object { $_.rel -eq "System.LinkTypes.Hierarchy-Forward" } | ForEach-Object {
            $ids += [int](($_.url -split '/')[-1])
        }
    }
    return $ids
}

function Get-AdoRelatedIds {
    param($WorkItemDetails)
    $ids = @()
    if ($WorkItemDetails.relations) {
        $WorkItemDetails.relations | Where-Object { $_.rel -eq "System.LinkTypes.Related" } | ForEach-Object {
            $ids += [int](($_.url -split '/')[-1])
        }
    }
    return $ids
}

function Save-AdoAttachment {
    param([string]$AttachmentUrl, [string]$FileName, [string]$TempDir, [string]$Pat)
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    $headers = Get-AdoAuthHeaders -Pat $Pat
    $outputPath = Join-Path $TempDir $FileName
    try {
        Invoke-WebRequest -Uri $AttachmentUrl -Headers $headers -OutFile $outputPath
        return $outputPath
    } catch {
        Write-Log -Message "Failed to download attachment $FileName`: $_" -Level "WARN"
        return $null
    }
}

function Save-AdoInlineImage {
    param([string]$ImageUrl, [string]$TempDir, [string]$Pat)
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

    # Determine file extension from URL or fileName param
    $ext = ".png"
    if ($ImageUrl -match 'fileName=([^&]+)') {
        $fn = [System.Uri]::UnescapeDataString($Matches[1])
        if ($fn -match '\.(png|jpg|jpeg|gif|bmp|svg|webp)$') { $ext = ".$($Matches[1])" }
    } elseif ($ImageUrl -match '\.(png|jpg|jpeg|gif|bmp|svg|webp)(\?|$)') {
        $ext = ".$($Matches[1])"
    }

    $fileName = "img_$(Get-Date -Format 'yyyyMMddHHmmssfff')_$([guid]::NewGuid().ToString('N').Substring(0,8))$ext"
    $outputPath = Join-Path $TempDir $fileName

    # Use auth-only headers (NO Content-Type) for binary downloads
    $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    $downloadHeaders = @{ Authorization = "Basic $base64" }

    Write-Log -Message "    Downloading image: $ImageUrl" -Level "DEBUG"

    try {
        Invoke-WebRequest -Uri $ImageUrl -Headers $downloadHeaders -OutFile $outputPath -UseBasicParsing -ErrorAction Stop

        # Verify file was downloaded and has content
        if ((Test-Path $outputPath) -and (Get-Item $outputPath).Length -gt 100) {
            $sizeKB = [math]::Round((Get-Item $outputPath).Length / 1024, 1)
            Write-Log -Message "    Downloaded: $fileName ($sizeKB KB)" -Level "DEBUG"
            return $outputPath
        } else {
            $actualSize = if (Test-Path $outputPath) { (Get-Item $outputPath).Length } else { 0 }
            Write-Log -Message "    Image download too small ($actualSize bytes) - likely HTML error page" -Level "WARN"
            if (Test-Path $outputPath) { Remove-Item $outputPath -Force -ErrorAction SilentlyContinue }
            return $null
        }
    } catch {
        Write-Log -Message "    Failed to download image: $_" -Level "WARN"
        Write-Log -Message "    URL: $ImageUrl" -Level "DEBUG"
        return $null
    }
}

function Tag-AdoWorkItemAsMigrated {
    param([string]$Org, [string]$Project, [int]$WorkItemId, [string]$GitHubIssueUrl, [string]$Pat)
    $headers = Get-AdoAuthHeaders -Pat $Pat
    $headers["Content-Type"] = "application/json-patch+json"
    $details = Get-AdoWorkItemDetails -Org $Org -Project $Project -WorkItemId $WorkItemId -Pat $Pat
    $currentTags = $details.fields.'System.Tags'
    $newTags = if ([string]::IsNullOrEmpty($currentTags)) { "copied-to-github" } else { "copied-to-github; $currentTags" }
    $body = @(
        @{ op = "add"; path = "/fields/System.Tags"; value = $newTags },
        @{ op = "add"; path = "/fields/System.History"; value = "Migrated to GitHub: <a href='$GitHubIssueUrl'>$GitHubIssueUrl</a>" }
    ) | ConvertTo-Json -Depth 10
    $uri = "https://dev.azure.com/$Org/$Project/_apis/wit/workitems/${WorkItemId}?api-version=7.1"
    try { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null }
    catch { Write-Log -Message "Failed to tag work item $WorkItemId`: $_" -Level "WARN" }
}

# Converts ADO HTML to GitHub Markdown, handling inline images
function Convert-AdoHtmlToMarkdown {
    param([string]$Html, [string]$AdoOrg, [string]$Pat, [string]$TempDir, [string]$GhOrg, [string]$GhRepo, [string]$GhPat)
    if ([string]::IsNullOrEmpty($Html)) { return "" }
    $md = $Html

    # Store images as placeholders to survive Pandoc/HTML parsing safely
    $imgPlaceholders = @{}
    $imgCounter = 0

    # Handle inline images - download from ADO, re-upload to GitHub
    $imgPattern = '<img\s[^>]*?src=["\u0027]([^"\u0027]+)["\u0027][^>]*?/?>'
    $imgMatches = [regex]::Matches($md, $imgPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if ($imgMatches.Count -gt 0) {
        Write-Log -Message "  Found $($imgMatches.Count) inline image(s) to migrate" -Level "INFO"
    }

    foreach ($m in $imgMatches) {
        $imgTag = $m.Value
        $imgUrl = $m.Groups[1].Value
        $altMatch = [regex]::Match($imgTag, 'alt=["\u0027]([^"\u0027]*)["\u0027]')
        $alt = if ($altMatch.Success) { $altMatch.Groups[1].Value } else { "image" }
        $fnMatch = [regex]::Match($imgTag, 'data-filename=["\u0027]([^"\u0027]*)["\u0027]')
        if ($fnMatch.Success -and $alt -eq "image") { $alt = $fnMatch.Groups[1].Value }

        $urlPreview = if ($imgUrl.Length -gt 80) { $imgUrl.Substring(0, 80) + '...' } else { $imgUrl }
        Write-Log -Message "  Image: alt='$alt' url='$urlPreview'" -Level "DEBUG"

        if ($imgUrl -match '^data:') {
            Write-Log -Message "  Skipping base64 data URI image" -Level "DEBUG"
            $placeholder = "@@MIG_IMG_$imgCounter@@"; $imgCounter++
            $imgPlaceholders[$placeholder] = "_[Embedded image: $alt]_"
            $md = $md.Replace($imgTag, $placeholder)
            continue
        }

        $fullImgUrl = $imgUrl
        if ($imgUrl -match '^/') {
            $fullImgUrl = "https://dev.azure.com/$AdoOrg$imgUrl"
        }

        if ($Pat -and $GhPat) {
            Write-Log -Message "  Downloading image: $alt" -Level "INFO"
            $localPath = Save-AdoInlineImage -ImageUrl $fullImgUrl -TempDir $TempDir -Pat $Pat
            if ($localPath -and (Test-Path $localPath)) {
                $ghUrl = Upload-ImageToGitHub -FilePath $localPath -GhOrg $GhOrg -GhRepo $GhRepo -GhPat $GhPat
                if ($ghUrl) {
                    Write-Log -Message "  Image migrated: $alt -> $ghUrl" -Level "SUCCESS"
                    $placeholder = "@@MIG_IMG_$imgCounter@@"; $imgCounter++
                    $imgPlaceholders[$placeholder] = "![$alt]($ghUrl)"
                    $md = $md.Replace($imgTag, $placeholder)
                    Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                    continue
                }
                Remove-Item $localPath -Force -ErrorAction SilentlyContinue
            }
            Write-Log -Message "  Image migration FAILED for: $alt" -Level "WARN"
            $placeholder = "@@MIG_IMG_$imgCounter@@"; $imgCounter++
            $imgPlaceholders[$placeholder] = "_[Image: $alt - could not be migrated from ADO]_"
            $md = $md.Replace($imgTag, $placeholder)
        } else {
            $placeholder = "@@MIG_IMG_$imgCounter@@"; $imgCounter++
            $imgPlaceholders[$placeholder] = "![$alt]($fullImgUrl)"
            $md = $md.Replace($imgTag, $placeholder)
        }
    }

    # Convert HTML to Markdown
    $pandocExe = "pandoc"
    if (-not (Get-Command "pandoc" -ErrorAction SilentlyContinue) -and (Test-Path "C:\Program Files\Pandoc\pandoc.exe")) {
        $pandocExe = "C:\Program Files\Pandoc\pandoc.exe"
    }

    if (Get-Command $pandocExe -ErrorAction SilentlyContinue) {
        Write-Log -Message "  Using Pandoc for HTML to Markdown conversion" -Level "DEBUG"
        $tmpIn = [System.IO.Path]::GetTempFileName() + '.html'
        $tmpOut = [System.IO.Path]::GetTempFileName() + '.md'
        $md | Set-Content -Path $tmpIn -Encoding UTF8
        & $pandocExe -f html -t gfm --wrap=none -o $tmpOut $tmpIn
        if (Test-Path $tmpOut) {
            $md = Get-Content $tmpOut -Raw -Encoding UTF8
            Remove-Item $tmpIn, $tmpOut -Force -ErrorAction SilentlyContinue
        }
    } else {
        # Fallback HTML tag conversions
        $md = $md -replace '<b>|<strong>', '**'; $md = $md -replace '</b>|</strong>', '**'
        $md = $md -replace '<i>|<em>', '_'; $md = $md -replace '</i>|</em>', '_'
        $md = $md -replace '<h1[^>]*>', "`n# "; $md = $md -replace '</h1>', "`n"
        $md = $md -replace '<h2[^>]*>', "`n## "; $md = $md -replace '</h2>', "`n"
        $md = $md -replace '<h3[^>]*>', "`n### "; $md = $md -replace '</h3>', "`n"
        $md = $md -replace '<br\s*/?>', "`n"; $md = $md -replace '<p[^>]*>', "`n"; $md = $md -replace '</p>', "`n"
        $md = $md -replace '<div[^>]*>', "`n"; $md = $md -replace '</div>', ""
        $md = $md -replace '<a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>', '[$2]($1)'
        $md = $md -replace '<li[^>]*>', "- "; $md = $md -replace '</li>', "`n"
        $md = $md -replace '<[^>]+>', ''
        try { $md = [System.Web.HttpUtility]::HtmlDecode($md) } catch { }
        $md = $md -replace "(\r?\n){3,}", "`n`n"
    }

    # Restore image placeholders
    foreach ($p in $imgPlaceholders.Keys) {
        $md = $md.Replace($p, $imgPlaceholders[$p])
    }

    return $md.Trim()
}

# Converts ADO Test Case Steps XML to Markdown table
function Convert-TestStepsToMarkdown {
    param([string]$StepsXml)
    if ([string]::IsNullOrEmpty($StepsXml)) { return "" }

    try {
        [xml]$xml = $StepsXml
        $steps = $xml.steps.step
        if (-not $steps -or $steps.Count -eq 0) { return "" }

        $md = "## Test Steps`n`n"
        $md += "| # | Action | Expected Result |`n"
        $md += "|:--:|--------|----------------|`n"

        $stepNum = 1
        foreach ($step in $steps) {
            # ADO stores steps as parameterizedString elements
            $action = ""
            $expected = ""
            if ($step.parameterizedString) {
                $strings = @($step.parameterizedString)
                if ($strings.Count -ge 1) { $action = $strings[0].InnerText }
                if ($strings.Count -ge 2) { $expected = $strings[1].InnerText }
            }
            # Strip HTML tags from step text
            $action   = $action -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&amp;', '&'
            $expected = $expected -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&amp;', '&'
            # Escape pipe characters for markdown table
            $action   = $action -replace '\|', '\|'
            $expected = $expected -replace '\|', '\|'

            if ($action.Trim()) {
                $md += "| $stepNum | $($action.Trim()) | $($expected.Trim()) |`n"
                $stepNum++
            }
        }
        return $md
    } catch {
        Write-Log -Message "Failed to parse test steps XML: $_" -Level "WARN"
        return "> _Test steps could not be parsed. Raw XML preserved in ADO._`n"
    }
}
