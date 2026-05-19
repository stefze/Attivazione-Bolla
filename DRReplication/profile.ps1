# profile.ps1
# Runs once when the Azure Functions host starts.
# Authenticates using the user-assigned managed identity when running in Azure.
# Supports both Windows (MSI_SECRET) and Linux (IDENTITY_ENDPOINT) MI semantics.
# Wrapped in try/catch so that a missing Az.Accounts module (e.g. during the
# initial managed-dependency download on FC1) does not crash the worker.

if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
    try {
        Disable-AzContextAutosave -Scope Process | Out-Null
        
        # Use user-assigned identity with client ID from environment variable
        $clientId = $env:AZURE_CLIENT_ID
        if ([string]::IsNullOrWhiteSpace($clientId)) {
            throw "AZURE_CLIENT_ID environment variable not set for user-assigned managed identity"
        }
        
        Connect-AzAccount -Identity -AccountId $clientId | Out-Null
    }
    catch {
        # Az.Accounts may still be downloading (managed deps first boot).
        # Individual function invocations re-authenticate in each runspace anyway.
        Write-Host "profile.ps1: Connect-AzAccount skipped — $($_.Exception.Message)"
    }
}
