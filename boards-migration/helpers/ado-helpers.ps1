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
    $fileName = "img_$(Get-Date -Format 'yyyyMMddHHmmssfff')_$([guid]::NewGuid().ToString('N').Substring(0,8)).png"
    $outputPath = Join-Path $TempDir $fileName
    $headers = Get-AdoAuthHeaders -Pat $Pat
    try {
        Invoke-WebRequest -Uri $ImageUrl -Headers $headers -OutFile $outputPath
        return $outputPath
    } catch {
        Write-Log -Message "Failed to download inline image: $_" -Level "WARN"
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
    $imgMatches = [regex]::Matches($md, '<img[^>]+src="([^"]+)"[^>]*/?\x3e')
    foreach ($m in $imgMatches) {
        $imgTag = $m.Value
        $imgUrl = $m.Groups[1].Value
        $altMatch = [regex]::Match($imgTag, 'alt="([^"]*)"')
        $alt = if ($altMatch.Success) { $altMatch.Groups[1].Value } else { "image" }

        # Try to re-upload any ADO-hosted image
        if ($Pat -and $GhPat -and $imgUrl -match "dev\.azure\.com|visualstudio\.com|vstfs|_apis/wit|_apis/resources") {
            Write-Log -Message "  Re-uploading inline image: $alt" -Level "DEBUG"
            $localPath = Save-AdoInlineImage -ImageUrl $imgUrl -TempDir $TempDir -Pat $Pat
            if ($localPath -and (Test-Path $localPath)) {
                $ghUrl = Upload-ImageToGitHub -FilePath $localPath -GhOrg $GhOrg -GhRepo $GhRepo -GhPat $GhPat
                if ($ghUrl) {
                    $md = $md.Replace($imgTag, "![$alt]($ghUrl)")
                    Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                    continue
                }
                Remove-Item $localPath -Force -ErrorAction SilentlyContinue
            }
            # Image re-upload failed - add note instead of broken 404 link
            Write-Log -Message "  Image re-upload failed for: $alt" -Level "WARN"
            $md = $md.Replace($imgTag, "_[Image: $alt - could not be migrated from ADO]_")
        } else {
            # External image URL - keep as-is
            $md = $md.Replace($imgTag, "![$alt]($imgUrl)")
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
