<#
.SYNOPSIS
    Queries DR Replication status from Azure Function.

.DESCRIPTION
    Retrieves the current status of DR replication operations including:
    - Latest invocation information
    - Completed stages
    - Failed stages
    - VMs in progress
    - Overall progress percentage

.PARAMETER FunctionUrl
    The Azure Function URL with code for Get-DRStatus endpoint

.PARAMETER CsvBlobPath
    Optional path to CSV file in blob storage to filter status (e.g., "production-config.csv")

.PARAMETER Watch
    Continuously poll for status updates every N seconds (default: 30)

.PARAMETER WatchInterval
    Interval in seconds between status checks when using -Watch (default: 30)

.EXAMPLE
    .\Get-DRStatus.ps1 -FunctionUrl "https://<FUNCTION_APP>.azurewebsites.net/api/Get-DRStatus?code=<CODE>"
    
.EXAMPLE
    # Query status for specific CSV file
    .\Get-DRStatus.ps1 -FunctionUrl "https://..." -CsvBlobPath "production-config.csv"
    
.EXAMPLE
    # Watch mode - continuous polling every 30 seconds
    .\Get-DRStatus.ps1 -FunctionUrl "https://..." -Watch
    
.EXAMPLE
    # Watch mode with custom interval (every 10 seconds)
    .\Get-DRStatus.ps1 -FunctionUrl "https://..." -Watch -WatchInterval 10
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$FunctionUrl,
    
    [Parameter(Mandatory=$false)]
    [string]$CsvBlobPath,
    
    [Parameter(Mandatory=$false)]
    [switch]$Watch,
    
    [Parameter(Mandatory=$false)]
    [int]$WatchInterval = 30
)

function Get-StatusColor {
    param([string]$Status)
    
    switch ($Status) {
        'Completed' { return 'Green' }
        'Failed'    { return 'Red' }
        'InProgress' { return 'Yellow' }
        default     { return 'Gray' }
    }
}

function Show-DRStatus {
    param([object]$StatusData)
    
    Clear-Host
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "   DR REPLICATION STATUS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    if ($CsvBlobPath) {
        Write-Host "Filtering by CSV: " -NoNewline -ForegroundColor DarkGray
        Write-Host $CsvBlobPath -ForegroundColor White
        Write-Host ""
    }
    
    if ($StatusData.checkedAt) {
        Write-Host "Checked At: " -NoNewline -ForegroundColor Gray
        Write-Host $StatusData.checkedAt -ForegroundColor White
        Write-Host ""
    }
    
    if ($StatusData.summary) {
        Write-Host "Summary:" -ForegroundColor White
        Write-Host "  Total VMs:      $($StatusData.vmCount ?? 0)" -ForegroundColor Gray
        Write-Host "  Succeeded:      $($StatusData.summary.succeeded ?? 0)" -ForegroundColor Green
        Write-Host "  Failed:         $($StatusData.summary.failed ?? 0)" -ForegroundColor Red
        Write-Host "  In Progress:    $($StatusData.summary.inProgress ?? 0)" -ForegroundColor Yellow
        Write-Host "  Errors:         $($StatusData.summary.error ?? 0)" -ForegroundColor Red
        Write-Host "  Unknown:        $($StatusData.summary.unknown ?? 0)" -ForegroundColor DarkGray
        Write-Host ""
        
        # Calculate progress
        $total = $StatusData.vmCount ?? 0
        if ($total -gt 0) {
            $completed = ($StatusData.summary.succeeded ?? 0) + ($StatusData.summary.failed ?? 0)
            $progressPercent = [math]::Round(($completed / $total) * 100, 2)
            $progressBar = ""
            $barLength = 50
            $filled = [math]::Floor($progressPercent / 100 * $barLength)
            $progressBar = ("█" * $filled).PadRight($barLength, "░")
            
            Write-Host "Progress: " -NoNewline
            Write-Host "[$progressBar] " -NoNewline -ForegroundColor Cyan
            Write-Host "$progressPercent%" -ForegroundColor White
            Write-Host ""
        }
    }
    
    if ($StatusData.results -and $StatusData.results.Count -gt 0) {
        # Group by status
        $succeeded = $StatusData.results | Where-Object { $_.status -eq 'SUCCEEDED' }
        $failed = $StatusData.results | Where-Object { $_.status -eq 'FAILED' }
        $inProgress = $StatusData.results | Where-Object { $_.status -eq 'IN_PROGRESS' }
        $unknown = $StatusData.results | Where-Object { $_.status -eq 'UNKNOWN' }
        $error = $StatusData.results | Where-Object { $_.status -eq 'ERROR' }
        
        if ($succeeded -and $succeeded.Count -gt 0) {
            Write-Host "✓ Succeeded VMs:" -ForegroundColor Green
            foreach ($vm in $succeeded) {
                $detail = if ($vm.completedStage) { $vm.completedStage } elseif ($vm.message) { $vm.message } else { "All stages completed" }
                Write-Host "  • $($vm.vmName) - $detail" -ForegroundColor Green
            }
            Write-Host ""
        }
        
        if ($failed -and $failed.Count -gt 0) {
            Write-Host "✗ Failed VMs:" -ForegroundColor Red
            foreach ($vm in $failed) {
                $detail = if ($vm.failedStage) { "Failed at: $($vm.failedStage)" } elseif ($vm.message) { $vm.message } else { "No details" }
                Write-Host "  • $($vm.vmName) - $detail" -ForegroundColor Red
            }
            Write-Host ""
        }
        
        if ($inProgress -and $inProgress.Count -gt 0) {
            Write-Host "⟳ VMs In Progress:" -ForegroundColor Yellow
            foreach ($vm in $inProgress) {
                $detail = if ($vm.lastCompletedStage) { "Last completed: $($vm.lastCompletedStage)" } elseif ($vm.message) { $vm.message } else { "Starting..." }
                Write-Host "  • $($vm.vmName) - $detail" -ForegroundColor Yellow
            }
            Write-Host ""
        }
        
        if ($error -and $error.Count -gt 0) {
            Write-Host "⚠ Error Reading Logs:" -ForegroundColor Red
            foreach ($vm in $error) {
                $detail = if ($vm.message) { $vm.message } elseif ($vm.completedStage) { "Stage: $($vm.completedStage)" } else { "Unknown error" }
                Write-Host "  • $($vm.vmName) - $detail" -ForegroundColor Red
            }
            Write-Host ""
        }
        
        if ($unknown -and $unknown.Count -gt 0) {
            Write-Host "? Unknown Status:" -ForegroundColor DarkGray
            foreach ($vm in $unknown) {
                $detail = if ($vm.message) { $vm.message } else { "No information available" }
                Write-Host "  • $($vm.vmName) - $detail" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }
    
    Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "Last Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    
    if ($Watch) {
        Write-Host "Press Ctrl+C to stop watching..." -ForegroundColor DarkYellow
    }
}

function Invoke-StatusQuery {
    # Build URL with optional csvBlobPath parameter
    $uri = $FunctionUrl
    if ($CsvBlobPath) {
        $separator = if ($uri -match '\?') { '&' } else { '?' }
        $uri += "$separator`csvBlobPath=$([System.Uri]::EscapeDataString($CsvBlobPath))"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri `
                                      -Method GET `
                                      -ContentType "application/json" `
                                      -StatusCodeVariable statusCode `
                                      -SkipHttpErrorCheck
        
        if ($statusCode -eq 200) {
            return @{
                Success = $true
                Data = $response
            }
        }
        else {
            return @{
                Success = $false
                Error = "HTTP $statusCode - $($response.error ?? 'Unknown error')"
            }
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

# Main execution
if ($Watch) {
    Write-Host "Starting watch mode (updates every $WatchInterval seconds)..." -ForegroundColor Cyan
    Write-Host ""
    
    while ($true) {
        $result = Invoke-StatusQuery
        
        if ($result.Success) {
            Show-DRStatus -StatusData $result.Data
        }
        else {
            Clear-Host
            Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Host "   ERROR RETRIEVING STATUS" -ForegroundColor Red
            Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Host ""
            Write-Host $result.Error -ForegroundColor Red
            Write-Host ""
            Write-Host "Last Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
            Write-Host "Retrying in $WatchInterval seconds..." -ForegroundColor DarkYellow
        }
        
        Start-Sleep -Seconds $WatchInterval
    }
}
else {
    # Single query mode
    $result = Invoke-StatusQuery
    
    if ($result.Success) {
        Show-DRStatus -StatusData $result.Data
    }
    else {
        Write-Host "Error: $($result.Error)" -ForegroundColor Red
        exit 1
    }
}
