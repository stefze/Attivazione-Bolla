using namespace System.Net

param($Request, $TriggerMetadata)

function Write-StatusLog {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-StatusLog "=== DR Status Check Function Started ==="
    
    # Extract CSV blob path from request
    $csvBlobPath = $null
    if ($Request.Method -eq 'POST') {
        $body = $Request.Body
        if ($body -is [string] -and -not [string]::IsNullOrWhiteSpace($body)) {
            $body = $body | ConvertFrom-Json -ErrorAction Stop
        }
        $csvBlobPath = $body.csvBlobPath
    } elseif ($Request.Method -eq 'GET') {
        $csvBlobPath = $Request.Query.csvBlobPath
    }

    if ([string]::IsNullOrWhiteSpace($csvBlobPath)) {
        Write-StatusLog "Missing required parameter: csvBlobPath" 'ERROR'
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = @{ error = "Missing required parameter: csvBlobPath" } | ConvertTo-Json
        })
        return
    }

    Write-StatusLog "CSV blob path: $csvBlobPath"

    # Read environment variables
    $csvStorageUri = $env:CSV_STORAGE_CONNECTION__blobServiceUri
    $csvContainerName = [string]($env:CSV_CONTAINER_NAME ?? 'dr-configs')
    $logContainerName = [string]($env:LOG_CONTAINER_NAME ?? 'dr-logs')
    
    if ([string]::IsNullOrWhiteSpace($csvStorageUri)) {
        Write-StatusLog "CSV_STORAGE_CONNECTION__blobServiceUri not configured" 'ERROR'
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = @{ error = "Storage configuration missing" } | ConvertTo-Json
        })
        return
    }

    # Authenticate
    Write-StatusLog "Authenticating with managed identity..."
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Write-StatusLog "Authentication successful"

    # Parse storage account name from URI
    $storageAccountName = ([uri]$csvStorageUri).Host -replace '\.blob\.core\.windows\.net$', ''
    Write-StatusLog "Storage account: $storageAccountName, Container: $csvContainerName"

    # Download CSV
    Write-StatusLog "Downloading CSV: $csvBlobPath from container $csvContainerName"
    
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
    $tempCsvFile = [System.IO.Path]::Combine($env:TEMP, "status-check-$([guid]::NewGuid()).csv")
    
    Get-AzStorageBlobContent -Container $csvContainerName -Blob $csvBlobPath `
        -Destination $tempCsvFile -Context $ctx -Force -ErrorAction Stop | Out-Null
    
    # Parse CSV
    $vmList = Import-Csv -Path $tempCsvFile -ErrorAction Stop
    Write-StatusLog "Found $($vmList.Count) VMs in CSV"
    Remove-Item -Path $tempCsvFile -Force -ErrorAction SilentlyContinue

    # Check status for each VM
    $results = @()
    
    foreach ($vm in $vmList) {
        $vmName = $vm.SourceVmName
        Write-StatusLog "Checking status for VM: $vmName"
        
        try {
            # List all log blobs for this VM
            $prefix = "$vmName/"
            $blobs = Get-AzStorageBlob -Container $logContainerName -Prefix $prefix -Context $ctx -ErrorAction Stop
            
            if ($blobs.Count -eq 0) {
                Write-StatusLog "No logs found for VM: $vmName" 'WARN'
                $results += @{
                    vmName = $vmName
                    status = 'UNKNOWN'
                    message = 'No logs found'
                }
                continue
            }

            # Parse blob names to find latest invocation
            # Format: {vmName}/{invocationId}-stage{id}-{description}-{yyyyMMdd-HHmm}[-failed].log
            $invocations = @{}
            
            foreach ($blob in $blobs) {
                $blobName = $blob.Name
                # Extract invocationId from blob name
                if ($blobName -match "^$vmName/([a-f0-9\-]+)-stage") {
                    $invocationId = $matches[1]
                    
                    # Extract timestamp from filename (yyyyMMdd-HHmm)
                    if ($blobName -match '(\d{8}-\d{4})') {
                        $timestamp = $matches[1]
                        
                        if (-not $invocations.ContainsKey($invocationId)) {
                            $invocations[$invocationId] = @{
                                timestamp = $timestamp
                                blobs = @()
                            }
                        }
                        
                        $invocations[$invocationId].blobs += $blobName
                    }
                }
            }

            if ($invocations.Count -eq 0) {
                Write-StatusLog "Could not parse logs for VM: $vmName" 'WARN'
                $results += @{
                    vmName = $vmName
                    status = 'UNKNOWN'
                    message = 'Invalid log format'
                }
                continue
            }

            # Get the latest invocation by timestamp
            $latestInvocation = $invocations.GetEnumerator() | 
                Sort-Object { $_.Value.timestamp } -Descending | 
                Select-Object -First 1

            $invocationId = $latestInvocation.Key
            $logBlobs = $latestInvocation.Value.blobs
            
            Write-StatusLog "Latest invocation for $vmName : $invocationId"

            # Check if replication completed successfully (completion marker log exists)
            $completionMarker = $logBlobs | Where-Object { 
                $_ -match "stage-Completed-" -and $_ -notmatch "-failed\.log$" 
            }

            if ($completionMarker) {
                Write-StatusLog "VM $vmName : SUCCEEDED (Completion marker found)"
                $results += @{
                    vmName = $vmName
                    status = 'SUCCEEDED'
                    invocationId = $invocationId
                    completedStage = 'Completed'
                }
            } else {
                # Find which stage failed
                $failedStage = $logBlobs | Where-Object { 
                    $_ -match "-failed\.log$" 
                } | Select-Object -First 1

                if ($failedStage) {
                    # Extract stage from filename (format: stageX-Failed)
                    if ($failedStage -match 'stage([A-E])-') {
                        $stageName = "Stage-$($matches[1])"
                        Write-StatusLog "VM $vmName : FAILED at $stageName"
                        $results += @{
                            vmName = $vmName
                            status = 'FAILED'
                            invocationId = $invocationId
                            failedStage = $stageName
                        }
                    } else {
                        Write-StatusLog "VM $vmName : FAILED (unknown stage)"
                        $results += @{
                            vmName = $vmName
                            status = 'FAILED'
                            invocationId = $invocationId
                            failedStage = 'UNKNOWN'
                        }
                    }
                } else {
                    # No failed stage found, but completion marker not found either
                    Write-StatusLog "VM $vmName : IN_PROGRESS (Completion marker not found)"
                    
                    # Find the highest stage completed
                    $completedStages = $logBlobs | Where-Object { 
                        $_ -match "stage([A-E])-" -and $_ -notmatch "-failed\.log$" 
                    } | ForEach-Object {
                        if ($_ -match 'stage([A-E])-') {
                            $matches[1]
                        }
                    } | Sort-Object -Descending | Select-Object -First 1
                    
                    $results += @{
                        vmName = $vmName
                        status = 'IN_PROGRESS'
                        invocationId = $invocationId
                        lastCompletedStage = if ($completedStages) { "Stage-$completedStages" } else { 'None' }
                    }
                }
            }
        }
        catch {
            Write-StatusLog "Error checking status for VM $vmName : $_" 'ERROR'
            $results += @{
                vmName = $vmName
                status = 'ERROR'
                message = $_.Exception.Message
            }
        }
    }

    # Build response
    $response = @{
        checkedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        vmCount = $vmList.Count
        results = $results
        summary = @{
            succeeded = ($results | Where-Object { $_.status -eq 'SUCCEEDED' }).Count
            failed = ($results | Where-Object { $_.status -eq 'FAILED' }).Count
            inProgress = ($results | Where-Object { $_.status -eq 'IN_PROGRESS' }).Count
            unknown = ($results | Where-Object { $_.status -eq 'UNKNOWN' }).Count
            error = ($results | Where-Object { $_.status -eq 'ERROR' }).Count
        }
    }

    Write-StatusLog "Status check complete. Succeeded: $($response.summary.succeeded), Failed: $($response.summary.failed), In Progress: $($response.summary.inProgress)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($response | ConvertTo-Json -Depth 10)
    })
}
catch {
    Write-StatusLog "Fatal error: $_" 'ERROR'
    Write-StatusLog $_.ScriptStackTrace 'ERROR'
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ 
            error = $_.Exception.Message
            details = $_.ScriptStackTrace
        } | ConvertTo-Json
    })
}
finally {
    Write-StatusLog "=== DR Status Check Function Completed ==="
}
