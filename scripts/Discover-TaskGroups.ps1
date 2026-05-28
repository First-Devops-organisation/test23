# discover-task-groups.ps1
param (
    [Parameter(Mandatory=$true)] [string]$Organization,
    [Parameter(Mandatory=$true)] [string]$Project,
    [Parameter(Mandatory=$true)] [string]$PatToken
)

$uri = "https://dev.azure.com/$Organization/$Project/_apis/distributedtask/taskgroups?api-version=7.0"
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f "", $PatToken)))

$headers = @{
    Authorization = ("Basic {0}" -f $base64AuthInfo)
}

Write-Host "Discovering Task Groups in project: $Project..."
$response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

if ($response.value.Count -eq 0) {
    Write-Host "No Task Groups found."
} else {
    Write-Host "Found $($response.value.Count) Task Groups:"
    foreach ($tg in $response.value) {
        Write-Host " - Name: $($tg.name) | ID: $($tg.id) | Version: $($tg.version.major).$($tg.version.minor)"
    }
}