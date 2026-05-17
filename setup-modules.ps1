# setup-modules.ps1
# Run this locally to pre-bundle required Az modules before deploying to
# Flex Consumption (Linux), which does not support managed dependencies.
#
# Usage:
#   1. Run this script once from the repo root:
#        .\setup-modules.ps1
#   2. In DRReplication\host.json, change:
#        "managedDependency": { "enabled": false }
#   3. Deploy with: azd up
#
# Note: The bundled modules can be large (~200-300 MB).  Ensure your deployment
# package does not exceed the Azure Functions size limit for FC1 (~1 GB).

$ErrorActionPreference = 'Stop'

$modulesPath = Join-Path $PSScriptRoot 'DRReplication' 'Modules'
New-Item -ItemType Directory -Force -Path $modulesPath | Out-Null

$modules = @(
    'Az.Accounts'
    'Az.Resources'
    'Az.Compute'
    'Az.Network'
    'Az.Storage'
)

Write-Host "Saving Az modules to '$modulesPath'..."
foreach ($mod in $modules) {
    Write-Host "  -> $mod"
    Save-Module -Name $mod -Path $modulesPath -Force -ErrorAction Stop
}

Write-Host ""
Write-Host "Done. Modules saved to '$modulesPath'."
Write-Host "Disable managed dependencies in DRReplication\host.json before deploying."
