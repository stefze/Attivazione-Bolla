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

@minLength(1)
@maxLength(10)
@description('Prefix for resource names.')
param prefix string = 'bolla'

@minLength(1)
@maxLength(24)
@description('Unique token for resource names. Defaults to hash based on subscription/resource group/environment.')
param resourceToken string = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))

@description('Resource ID of pre-created user-assigned managed identity. Must be in format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{identityName}')
param userAssignedIdentityId string

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------
var tags          = { 'azd-env-name': environmentName }

// Extract user-assigned identity details
var userAssignedIdentityName = last(split(userAssignedIdentityId, '/'))

var logAnalyticsName        = 'log-${prefix}-${resourceToken}'
var appInsightsName         = 'appi-${prefix}-${resourceToken}'
var storageFuncName         = 'stfn${take(resourceToken, 20)}'
var storageConfigName       = 'stcfg${take(resourceToken, 19)}'
var appServicePlanName      = 'asp-${prefix}-${resourceToken}'
var functionAppName         = 'func-${prefix}-${resourceToken}'
var deploymentContainerName = 'deploymentpackage'
var csvContainerName        = 'dr-configs'
var logContainerName        = 'dr-logs'


// VNet and subnet names
var vnetName                    = 'vnet-${prefix}-${resourceToken}'
var vnetIntegrationSubnetName   = 'snet-vnetintegration'
var privateEndpointSubnetName   = 'snet-privateendpoints'

// Private DNS Zone names
var privateDnsZoneBlobName  = 'privatelink.blob.${environment().suffixes.storage}'

// ---------------------------------------------------------------------------
// Virtual Network
// ---------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name:     vnetName
  location: location
  tags:     tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/24' ]
    }
    subnets: [
      {
        name: vnetIntegrationSubnetName
        properties: {
          addressPrefix: '10.0.0.0/26'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: []
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.0.0.64/26'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Private DNS Zones
// ---------------------------------------------------------------------------

resource privateDnsZoneBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name:     privateDnsZoneBlobName
  location: 'global'
  tags:     tags
}

resource privateDnsZoneBlobVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent:   privateDnsZoneBlob
  name:     '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork:      { id: vnet.id }
  }
}


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
    publicNetworkAccess:      'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass:        'None'
      virtualNetworkRules: []
      ipRules: []
    }
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
    publicNetworkAccess:      'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass:        'None'
      virtualNetworkRules: []
      ipRules: []
    }
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
// Private Endpoints — Function Hosting Storage
// ---------------------------------------------------------------------------

resource privateEndpointFuncBlob 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name:     'pe-${storageFuncName}-blob'
  location: location
  tags:     tags
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${privateEndpointSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-connection'
        properties: {
          privateLinkServiceId: storageFunc.id
          groupIds:             [ 'blob' ]
        }
      }
    ]
  }
}

resource privateEndpointFuncBlobDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpointFuncBlob
  name:   'dnsgroupname'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:              'config'
        properties: {
          privateDnsZoneId: privateDnsZoneBlob.id
        }
      }
    ]
  }
}


// ---------------------------------------------------------------------------
// Private Endpoints — Config Storage
// ---------------------------------------------------------------------------

resource privateEndpointConfigBlob 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name:     'pe-${storageConfigName}-blob'
  location: location
  tags:     tags
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${privateEndpointSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-connection'
        properties: {
          privateLinkServiceId: storageConfig.id
          groupIds:             [ 'blob' ]
        }
      }
    ]
  }
}

resource privateEndpointConfigBlobDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpointConfigBlob
  name:   'dnsgroupname'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:              'config'
        properties: {
          privateDnsZoneId: privateDnsZoneBlob.id
        }
      }
    ]
  }
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
// Reference to existing user-assigned managed identity
// ---------------------------------------------------------------------------

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: userAssignedIdentityName
  scope: resourceGroup(split(userAssignedIdentityId, '/')[2], split(userAssignedIdentityId, '/')[4])
}

// ---------------------------------------------------------------------------
// Function App — PowerShell 7.4, user-assigned MI
// ---------------------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name:     functionAppName
  location: location
  tags:     union(tags, { 'azd-service-name': 'drreplication' })
  kind:     'functionapp,linux'
  identity: { 
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    serverFarmId:             appServicePlan.id
    virtualNetworkSubnetId:   '${vnet.id}/subnets/${vnetIntegrationSubnetName}'
    vnetRouteAllEnabled:      true
    vnetContentShareEnabled:  false
    functionAppConfig: {
      deployment: {
        storage: {
          type:  'blobContainer'
          value: '${storageFunc.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: { 
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: userAssignedIdentityId
          }
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
        { name: 'AzureWebJobsStorage__credential',        value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',          value: userAssignedIdentity.properties.clientId }
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
        { name: 'AZURE_CLIENT_ID',                        value: userAssignedIdentity.properties.clientId }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
    privateEndpointFuncBlob
    privateEndpointConfigBlob
  ]
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output AZURE_LOCATION                        string = location
output AZURE_TENANT_ID                       string = tenant().tenantId
output AZURE_FUNCTION_NAME                   string = functionApp.name
output AZURE_FUNCTION_PRINCIPAL_ID           string = userAssignedIdentity.properties.principalId
output AZURE_USER_ASSIGNED_IDENTITY_ID       string = userAssignedIdentityId
output AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID string = userAssignedIdentity.properties.clientId
output AZURE_VNET_NAME                       string = vnet.name
output AZURE_VNET_ID                         string = vnet.id
output AZURE_STORAGE_FUNC_NAME               string = storageFunc.name
output AZURE_STORAGE_CONFIG_NAME             string = storageConfig.name
output APPLICATIONINSIGHTS_CONNECTION_STRING string = appInsights.properties.ConnectionString
output CSV_STORAGE_ACCOUNT_NAME              string = storageConfig.name
output CSV_STORAGE_BLOB_ENDPOINT             string = storageConfig.properties.primaryEndpoints.blob
output FUNCTION_APP_URL                      string = 'https://${functionApp.properties.defaultHostName}'
