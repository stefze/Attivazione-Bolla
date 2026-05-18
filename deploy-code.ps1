# deploy-code.ps1
# Quick script to deploy function code to Azure Function App
# Run after infrastructure deployment completes

param(
    [Parameter(Mandatory)]
    [string]$FunctionAppName,
    
    [Parameter(Mandatory)]
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'

Write-Host "🚀 Deploying function code to $FunctionAppName..." -ForegroundColor Cyan

# Check if deployment package exists
$packagePath = Join-Path $PSScriptRoot "function-deployment.zip"
if (-not (Test-Path $packagePath)) {
    Write-Host "❌ Deployment package not found at: $packagePath" -ForegroundColor Red
    Write-Host "Download it from: https://github.com/stefze/Attivazione-Bolla/raw/main/function-deployment.zip" -ForegroundColor Yellow
    exit 1
}

Write-Host "📦 Using package: $packagePath" -ForegroundColor Gray

# Deploy using Azure CLI
Write-Host "`n📤 Uploading to Azure..." -ForegroundColor Yellow
az functionapp deployment source config-zip `
    --name $FunctionAppName `
    --resource-group $ResourceGroup `
    --src $packagePath

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✅ Deployment successful!" -ForegroundColor Green
    Write-Host "`n🔍 Verifying functions..." -ForegroundColor Cyan
    
    Start-Sleep -Seconds 5
    
    $functions = az functionapp function list `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --query "[].name" -o tsv
    
    Write-Host "Deployed functions:" -ForegroundColor Green
    $functions | ForEach-Object { Write-Host "  ✓ $_" -ForegroundColor Green }
} else {
    Write-Host "`n❌ Deployment failed!" -ForegroundColor Red
    exit 1
}
