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
    Optional path to CSV file in blob storage to filter status (e.g., "prod/production-config.csv")

.PARAMETER Watch
    Continuously poll for status updates every N seconds (default: 30)

.PARAMETER WatchInterval
    Interval in seconds between status checks when using -Watch (default: 30)

.EXAMPLE
    .\Get-DRStatus.ps1 -FunctionUrl "https://<FUNCTION_APP>.azurewebsites.net/api/Get-DRStatus?code=<CODE>"
    
.EXAMPLE
    # Query status for specific CSV file
    .\Get-DRStatus.ps1 -FunctionUrl "https://..." -CsvBlobPath "prod/production-config.csv"
    
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
    
    if ($StatusData.latestInvocation) {
        $inv = $StatusData.latestInvocation
        Write-Host "Latest Invocation:" -ForegroundColor White
        Write-Host "  ID:        $($inv.invocationId)" -ForegroundColor Gray
        Write-Host "  Started:   $($inv.startTime)" -ForegroundColor Gray
        Write-Host "  CSV:       $($inv.csvBlobPath)" -ForegroundColor Gray
        Write-Host ""
    }
    
    if ($StatusData.overallStatus) {
        $status = $StatusData.overallStatus
        $statusColor = Get-StatusColor -Status $status
        Write-Host "Overall Status: " -NoNewline
        Write-Host $status -ForegroundColor $statusColor
        Write-Host ""
    }
    
    if ($StatusData.progress -ne $null) {
        $progressPercent = [math]::Round($StatusData.progress, 2)
        $progressBar = ""
        $barLength = 50
        $filled = [math]::Floor($progressPercent / 100 * $barLength)
        $progressBar = ("█" * $filled).PadRight($barLength, "░")
        
        Write-Host "Progress: " -NoNewline
        Write-Host "[$progressBar] " -NoNewline -ForegroundColor Cyan
        Write-Host "$progressPercent%" -ForegroundColor White
        Write-Host ""
    }
    
    if ($StatusData.completedStages -and $StatusData.completedStages.Count -gt 0) {
        Write-Host "✓ Completed Stages:" -ForegroundColor Green
        foreach ($stage in $StatusData.completedStages) {
            Write-Host "  • $stage" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    if ($StatusData.failedStages -and $StatusData.failedStages.Count -gt 0) {
        Write-Host "✗ Failed Stages:" -ForegroundColor Red
        foreach ($failure in $StatusData.failedStages) {
            Write-Host "  • $failure" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    if ($StatusData.vmsInProgress -and $StatusData.vmsInProgress.Count -gt 0) {
        Write-Host "⟳ VMs In Progress:" -ForegroundColor Yellow
        foreach ($vm in $StatusData.vmsInProgress) {
            Write-Host "  • $vm" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    
    if ($StatusData.summary) {
        Write-Host "Summary:" -ForegroundColor White
        Write-Host "  Total VMs:      $($StatusData.summary.totalVMs)" -ForegroundColor Gray
        Write-Host "  Completed:      $($StatusData.summary.completedVMs)" -ForegroundColor Green
        Write-Host "  Failed:         $($StatusData.summary.failedVMs)" -ForegroundColor Red
        Write-Host "  In Progress:    $($StatusData.summary.inProgressVMs)" -ForegroundColor Yellow
        Write-Host ""
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
