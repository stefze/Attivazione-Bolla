# requirements.psd1
# Managed dependency declarations for Azure Functions PowerShell.
#
# NOTE: On Flex Consumption (Linux), managed dependencies may not work at cold start.
# If you encounter module import errors, disable managed dependencies in host.json
# ("managedDependency": { "enabled": false }) and run setup-modules.ps1 in the
# repo root to pre-bundle all required modules into DRReplication/Modules/.

@{
    'Az.Accounts'  = '3.*'
    'Az.Resources' = '7.*'
    'Az.Compute'   = '8.*'
    'Az.Network'   = '7.*'
    'Az.Storage'   = '7.*'
}
