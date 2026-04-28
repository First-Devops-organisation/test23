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

    # Determine file extension from URL
    $ext = ".png"
    if ($ImageUrl -match '\.(png|jpg|jpeg|gif|bmp|svg|webp)(\?|$)') { $ext = ".$($Matches[1])" }

    $fileName = "img_$(Get-Date -Format 'yyyyMMddHHmmssfff')_$([guid]::NewGuid().ToString('N').Substring(0,8))$ext"
    $outputPath = Join-Path $TempDir $fileName
    $headers = Get-AdoAuthHeaders -Pat $Pat

    Write-Log -Message "    Downloading image from ADO: $ImageUrl" -Level "DEBUG"

    try {
        # Use Invoke-WebRequest with explicit options for compatibility
        $response = Invoke-WebRequest -Uri $ImageUrl -Headers $headers -OutFile $outputPath -PassThru -UseBasicParsing
        
        # Verify file was downloaded and has content
        if ((Test-Path $outputPath) -and (Get-Item $outputPath).Length -gt 0) {
            $sizeKB = [math]::Round((Get-Item $outputPath).Length / 1024, 1)
            Write-Log -Message "    Downloaded image: $fileName ($sizeKB KB)" -Level "DEBUG"
            return $outputPath
        } else {
            Write-Log -Message "    Image download produced empty file" -Level "WARN"
            return $null
        }
    } catch {
        Write-Log -Message "    Failed to download inline image: $_" -Level "WARN"
        Write-Log -Message "    URL was: $ImageUrl" -Level "DEBUG"
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

    # Handle inline images - download from ADO, re-upload to GitHub
    # Match both <img src="..."> and <img ... src="..."> patterns (self-closing or not)
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
        # Also check data-filename attribute (ADO uses this)
        $fnMatch = [regex]::Match($imgTag, 'data-filename=["\u0027]([^"\u0027]*)["\u0027]')
        if ($fnMatch.Success -and $alt -eq "image") { $alt = $fnMatch.Groups[1].Value }

        $urlPreview = if ($imgUrl.Length -gt 80) { $imgUrl.Substring(0, 80) + '...' } else { $imgUrl }
        Write-Log -Message "  Image: alt='$alt' url='$urlPreview'" -Level "DEBUG"

        # Skip data URIs - can't re-upload base64 images easily
        if ($imgUrl -match '^data:') {
            Write-Log -Message "  Skipping base64 data URI image" -Level "DEBUG"
            $md = $md.Replace($imgTag, "_[Embedded image: $alt]_")
            continue
        }

        # Fix relative URLs - prepend ADO org URL
        $fullImgUrl = $imgUrl
        if ($imgUrl -match '^/') {
            $fullImgUrl = "https://dev.azure.com/$AdoOrg$imgUrl"
            Write-Log -Message "  Fixed relative URL: $fullImgUrl" -Level "DEBUG"
        }

        # Try to download and re-upload ALL images (not just matching patterns)
        if ($Pat -and $GhPat) {
            Write-Log -Message "  Downloading image: $alt" -Level "INFO"
            $localPath = Save-AdoInlineImage -ImageUrl $fullImgUrl -TempDir $TempDir -Pat $Pat
            if ($localPath -and (Test-Path $localPath)) {
                $ghUrl = Upload-ImageToGitHub -FilePath $localPath -GhOrg $GhOrg -GhRepo $GhRepo -GhPat $GhPat
                if ($ghUrl) {
                    Write-Log -Message "  Image migrated: $alt -> $ghUrl" -Level "SUCCESS"
                    $md = $md.Replace($imgTag, "![$alt]($ghUrl)")
                    Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                    continue
                }
                Remove-Item $localPath -Force -ErrorAction SilentlyContinue
            }
            # Re-upload failed
            Write-Log -Message "  Image migration FAILED for: $alt (URL: $fullImgUrl)" -Level "WARN"
            $md = $md.Replace($imgTag, "_[Image: $alt - could not be migrated from ADO]_")
        } else {
            # No auth - keep original URL
            $md = $md.Replace($imgTag, "![$alt]($fullImgUrl)")
        }
    }

    # HTML tag conversions
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
    return $md.Trim()
}
