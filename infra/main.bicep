// infra/main.bicep
// Resource-group scoped deployment.
// azd creates the resource group automatically (named rg-<AZURE_ENV_NAME> by default).

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@minLength(1)
@maxLength(64)
@description('Environment name — drives unique resource names.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var prefix        = 'bolla'
var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))
var tags          = { 'azd-env-name': environmentName }

var logAnalyticsName        = 'log-${prefix}-${resourceToken}'
var appInsightsName         = 'appi-${prefix}-${resourceToken}'
var storageFuncName         = 'stfn${take(resourceToken, 20)}'
var storageConfigName       = 'stcfg${take(resourceToken, 19)}'
var appServicePlanName      = 'asp-${prefix}-${resourceToken}'
var functionAppName         = 'func-${prefix}-${resourceToken}'
var deploymentContainerName = 'deploymentpackage'
var csvContainerName        = 'dr-configs'
var logContainerName        = 'dr-logs'

var storageBlobDataOwnerRoleId        = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId  = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var storageBlobDataReaderRoleId       = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// ---------------------------------------------------------------------------
// Log Analytics
// ---------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name:     logAnalyticsName
  location: location
  tags:     tags
  properties: {
    sku:             { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Application Insights
// ---------------------------------------------------------------------------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name:     appInsightsName
  location: location
  tags:     tags
  kind:     'web'
  properties: {
    Application_Type:    'web'
    WorkspaceResourceId: logAnalytics.id
    DisableLocalAuth:    true
    IngestionMode:       'LogAnalytics'
  }
}

// ---------------------------------------------------------------------------
// Storage — function hosting
// ---------------------------------------------------------------------------

resource storageFunc 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name:     storageFuncName
  location: location
  tags:     tags
  kind:     'StorageV2'
  sku:      { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess:    false
    allowSharedKeyAccess:     false
    minimumTlsVersion:        'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

resource storageFuncBlobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageFunc
  name:   'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageFuncBlobSvc
  name:   deploymentContainerName
  properties: { publicAccess: 'None' }
}

// ---------------------------------------------------------------------------
// Storage — CSV config blobs
// ---------------------------------------------------------------------------

resource storageConfig 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name:     storageConfigName
  location: location
  tags:     tags
  kind:     'StorageV2'
  sku:      { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess:    false
    allowSharedKeyAccess:     false
    minimumTlsVersion:        'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

resource storageConfigBlobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageConfig
  name:   'default'
}

resource csvContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageConfigBlobSvc
  name:   csvContainerName
  properties: { publicAccess: 'None' }
}

resource logContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageConfigBlobSvc
  name:   logContainerName
  properties: { publicAccess: 'None' }
}

// ---------------------------------------------------------------------------
// App Service Plan — FC1 / Flex Consumption / Linux
// ---------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name:     appServicePlanName
  location: location
  tags:     tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

// ---------------------------------------------------------------------------
// Function App — PowerShell 7.4, system-assigned MI
// ---------------------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name:     functionAppName
  location: location
  tags:     union(tags, { 'azd-service-name': 'drreplication' })
  kind:     'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    functionAppConfig: {
      deployment: {
        storage: {
          type:  'blobContainer'
          value: '${storageFunc.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB:     2048
        maximumInstanceCount: 100
      }
      runtime: {
        name:    'powershell'
        version: '7.4'
      }
    }
    siteConfig: {
      alwaysOn: false
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: appInsights.properties.ConnectionString }
        { name: 'AzureWebJobsStorage__blobServiceUri',    value: storageFunc.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri',   value: storageFunc.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri',   value: storageFunc.properties.primaryEndpoints.table }
        { name: 'AzureWebJobsStorage__credential',        value: 'managedidentity' }
        { name: 'CSV_STORAGE_CONNECTION__blobServiceUri', value: storageConfig.properties.primaryEndpoints.blob }
        { name: 'CSV_CONTAINER_NAME',                     value: csvContainerName }
        { name: 'VM_PARALLEL_THROTTLE',                   value: '1' }
        { name: 'PARALLEL_THROTTLE',                      value: '6' }
        { name: 'SNAPSHOT_NAME_PREFIX',                   value: 'snap-' }
        { name: 'BACKEND_POOL_NAME_OVERRIDE',             value: '' }
        { name: 'LOG_CONTAINER_NAME',                     value: logContainerName }
        { name: 'TARGET_SUBSCRIPTION_SUFFIX',             value: '' }
        { name: 'TARGET_RESOURCE_GROUP_SUFFIX',           value: '' }
        { name: 'TARGET_VNET_NAME_SUFFIX',                value: '' }
        { name: 'TARGET_VNET_RG_SUFFIX',                  value: '' }
        { name: 'TARGET_LB_NAME_SUFFIX',                  value: '' }
        { name: 'TARGET_LB_RG_SUFFIX',                    value: '' }
        { name: 'TARGET_DES_NAME_SUFFIX',                 value: '' }
        { name: 'TARGET_DES_RG_SUFFIX',                   value: '' }
        { name: 'TARGET_ASG_NAME_SUFFIX',                 value: '' }
      ]
    }
  }
  dependsOn: [ deploymentContainer ]
}

// ---------------------------------------------------------------------------
// RBAC — function hosting storage
// ---------------------------------------------------------------------------

resource rbacFuncBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageFunc
  name:  guid(storageFunc.id, functionApp.id, storageBlobDataOwnerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId:      functionApp.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

resource rbacFuncBlobContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageFunc
  name:  guid(storageFunc.id, functionApp.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId:      functionApp.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

resource rbacFuncQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageFunc
  name:  guid(storageFunc.id, functionApp.id, storageQueueDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId:      functionApp.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

resource rbacFuncTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageFunc
  name:  guid(storageFunc.id, functionApp.id, storageTableDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId:      functionApp.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// RBAC — CSV config storage (read CSV + write logs)
// ---------------------------------------------------------------------------

resource rbacConfigBlobContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageConfig
  name:  guid(storageConfig.id, functionApp.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId:      functionApp.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output AZURE_LOCATION                        string = location
output AZURE_TENANT_ID                       string = tenant().tenantId
output AZURE_FUNCTION_NAME                   string = functionApp.name
output AZURE_FUNCTION_PRINCIPAL_ID           string = functionApp.identity.principalId
output APPLICATIONINSIGHTS_CONNECTION_STRING string = appInsights.properties.ConnectionString
output CSV_STORAGE_ACCOUNT_NAME              string = storageConfig.name
output CSV_STORAGE_BLOB_ENDPOINT             string = storageConfig.properties.primaryEndpoints.blob
output FUNCTION_APP_URL                      string = 'https://${functionApp.properties.defaultHostName}'
