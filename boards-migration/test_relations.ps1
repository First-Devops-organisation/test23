$adoPat = $env:ADO_PAT
if (-not $adoPat) { Write-Host "ADO_PAT NOT SET"; exit 1 }
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$h = @{Authorization="Basic $b64"}
$uri = "https://dev.azure.com/YashTech-DevOps/YASH-DevOps-Serverless/_apis/wit/workitems/4372?`$expand=all&api-version=7.1"
try {
    $r = Invoke-RestMethod -Uri $uri -Headers $h -ErrorAction Stop
    Write-Host "Item: $($r.id)"
    if ($r.relations) {
        Write-Host "Has Relations: $($r.relations.Count)"
    } else {
        Write-Host "No relations found!"
    }
} catch {
    Write-Host "ERROR: $_"
}
