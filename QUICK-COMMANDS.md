# DR Replication Quick Commands

## Setup

```powershell
# Set your function URL with code
$functionUrl = "https://<FUNCTION_APP_NAME>.azurewebsites.net/api/Invoke-DRReplication?code=<FUNCTION_CODE>"
$statusUrl = "https://<FUNCTION_APP_NAME>.azurewebsites.net/api/Get-DRStatus?code=<FUNCTION_CODE>"
```

## Async Invocation (Recommended)

```powershell
# Start DR replication in background (returns immediately)
.\Invoke-DRReplicationAsync.ps1 -FunctionUrl $functionUrl -CsvBlobPath "prod/production-config.csv"

# Check job status
Get-Job

# View result
Receive-Job -Id 1 -Keep

# Clean up
Remove-Job -Id 1
```

## Manual Async Pattern

```powershell
# One-liner async invocation
$job = Start-ThreadJob -ArgumentList $functionUrl -ScriptBlock { 
    param($Uri)
    Invoke-RestMethod -Uri $Uri `
                      -Method POST `
                      -ContentType "application/json" `
                      -Body '{"csvBlobPath":"prod/production-config.csv"}'
}
Write-Host "✓ Job started (ID: $($job.Id))"
```

## Synchronous Invocation

```powershell
# Block until completion (can take several minutes)
$body = '{"csvBlobPath":"prod/production-config.csv"}'
$resp = Invoke-RestMethod -Uri $functionUrl -Method POST -ContentType "application/json" -Body $body
$resp | ConvertTo-Json
```

## Check Replication Status

```powershell
# Single status query (formatted display)
.\Get-DRStatus.ps1 -FunctionUrl $statusUrl

# Query status for specific CSV file
.\Get-DRStatus.ps1 -FunctionUrl $statusUrl -CsvBlobPath "prod/production-config.csv"

# Watch mode - continuous polling every 30 seconds
.\Get-DRStatus.ps1 -FunctionUrl $statusUrl -Watch

# Watch mode for specific CSV with custom interval
.\Get-DRStatus.ps1 -FunctionUrl $statusUrl -CsvBlobPath "prod/production-config.csv" -Watch -WatchInterval 10
```

## Manual Status Check

```powershell
# Get status via REST API
Invoke-RestMethod -Uri $statusUrl | ConvertTo-Json

# Get status for specific VM (deprecated, use Get-DRStatus.ps1)
Invoke-RestMethod -Uri "$statusUrl&vmName=PRDDC001" | ConvertTo-Json
```
