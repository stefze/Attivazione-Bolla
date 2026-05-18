using namespace System.Net

param($QueueItem, $TriggerMetadata)

# ══════════════════════════════════════════════════════════════════════════════════
# Process-VMReplication
# Queue-triggered function that processes individual VM DR replication jobs
# ══════════════════════════════════════════════════════════════════════════════════

function Write-FuncLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-FuncLog "Queue trigger activated. Processing VM replication job."
    
    # ── Parse queue message ─────────────────────────────────────────────────────────
    $message = $QueueItem | ConvertFrom-Json -ErrorAction Stop
    Write-FuncLog "Received message for VM: $($message.sourceVmName)"

    # ── Load DRCore module ──────────────────────────────────────────────────────────
    $appRoot = if ($env:FUNCTIONS_APPLICATION_DIRECTORY) {
        $env:FUNCTIONS_APPLICATION_DIRECTORY
    } else {
        Split-Path $PSScriptRoot -Parent
    }
    $drCoreModule = Join-Path $appRoot 'Modules' 'DRCore' 'DRCore.psm1'

    if (-not (Test-Path $drCoreModule)) {
        throw "DRCore module not found at '$drCoreModule'."
    }

    Import-Module $drCoreModule -Force -ErrorAction Stop
    Write-FuncLog "DRCore module loaded successfully."

    # ── Authenticate with Managed Identity ──────────────────────────────────────────
    if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
        Write-FuncLog "Authenticating with Managed Identity..."
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-FuncLog "Authenticated successfully."
    }

    # ── Execute VM Replication ──────────────────────────────────────────────────────
    Write-FuncLog "Starting VM replication for: $($message.sourceVmName)"
    
    $vmResult = Invoke-VMReplication `
        -SourceSubscription           $message.sourceSubscription `
        -SourceResourceGroup          $message.sourceResourceGroup `
        -SourceVmName                 $message.sourceVmName `
        -DiskParallelThrottle         $message.diskParallelThrottle `
        -SnapshotNamePrefix           $message.snapshotNamePrefix `
        -BackendPoolNameOverride      $message.backendPoolNameOverride `
        -TargetSubscriptionSuffix     $message.targetSubscriptionSuffix `
        -TargetResourceGroupSuffix    $message.targetResourceGroupSuffix `
        -TargetVnetNameSuffix         $message.targetVnetNameSuffix `
        -TargetVnetRgSuffix           $message.targetVnetRgSuffix `
        -TargetLbNameSuffix           $message.targetLbNameSuffix `
        -TargetLbRgSuffix             $message.targetLbRgSuffix `
        -TargetDesNameSuffix          $message.targetDesNameSuffix `
        -TargetDesRgSuffix            $message.targetDesRgSuffix `
        -TargetAsgNameSuffix          $message.targetAsgNameSuffix `
        -LogStorageAccountName        $message.logStorageAccountName `
        -LogContainerName             $message.logContainerName `
        -InvocationId                 $message.invocationId

    if ($vmResult.Status -eq 'Success') {
        Write-FuncLog "✓ VM replication completed successfully: $($message.sourceVmName)"
    }
    else {
        Write-FuncLog "✗ VM replication failed: $($message.sourceVmName) - $($vmResult.Error)" 'ERROR'
    }
}
catch {
    Write-FuncLog "Fatal error processing queue message: $($_.Exception.Message)" 'ERROR'
    Write-FuncLog "Stack trace: $($_.ScriptStackTrace)" 'ERROR'
    throw  # Re-throw to trigger queue message retry
}
