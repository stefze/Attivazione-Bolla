<#
.SYNOPSIS
    Invokes DR Replication asynchronously without blocking the terminal.

.DESCRIPTION
    Starts the DR replication in a background thread job and returns immediately.
    Use Get-Job and Receive-Job to check status and results.

.PARAMETER FunctionUrl
    The Azure Function URL with code (optional, uses default if not specified)

.PARAMETER CsvBlobPath
    Path to the CSV file in blob storage (e.g., "prod/production-config.csv")

.EXAMPLE
    .\Invoke-DRReplicationAsync.ps1 -FunctionUrl "https://<FUNCTION_APP>.azurewebsites.net/api/Invoke-DRReplication?code=<CODE>" -CsvBlobPath "prod/production-config.csv"
    
.EXAMPLE
    # Check job status
    Get-Job
    
.EXAMPLE
    # Get job result
    Receive-Job -Id 1 -Keep
    
.EXAMPLE
    # Remove completed job
    Remove-Job -Id 1
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$FunctionUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$CsvBlobPath
)

# Start job in background
$job = Start-ThreadJob -ArgumentList $FunctionUrl, $CsvBlobPath -ScriptBlock {
    param($Uri, $BlobPath)
    
    $body = @{
        csvBlobPath = $BlobPath
    } | ConvertTo-Json
    
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Uri $Uri `
                                      -Method POST `
                                      -ContentType "application/json" `
                                      -Body $body `
                                      -StatusCodeVariable statusCode `
                                      -SkipHttpErrorCheck
        $stopwatch.Stop()
        
        [PSCustomObject]@{
            Success      = $true
            StatusCode   = $statusCode
            Duration     = $stopwatch.Elapsed.TotalSeconds
            Response     = $response
            Timestamp    = Get-Date
        }
    }
    catch {
        [PSCustomObject]@{
            Success   = $false
            Error     = $_.Exception.Message
            Timestamp = Get-Date
        }
    }
}

Write-Host "✓ DR Replication job started in background" -ForegroundColor Green
Write-Host "  Job ID: $($job.Id)" -ForegroundColor Cyan
Write-Host "  CSV Path: $CsvBlobPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Commands:" -ForegroundColor Yellow
Write-Host "  Get-Job                        # Check job status"
Write-Host "  Receive-Job -Id $($job.Id) -Keep    # View result"
Write-Host "  Remove-Job -Id $($job.Id)           # Clean up when done"
Write-Host ""

return $job
