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

@description('Automatically deploy function code after infrastructure provisioning.')
param autoDeployCode bool = true

@description('GitHub repository URL containing the function code.')
param gitHubRepoUrl string = 'https://github.com/stefze/Attivazione-Bolla.git'

@description('GitHub branch to deploy from.')
param gitHubBranch string = 'main'

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------
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
var websiteContributorRoleId          = 'de139f84-1756-47ae-9be6-808fbbe84772'

// Deployment automation
var deploymentIdentityName = 'id-${prefix}-deploy-${resourceToken}'
var deploymentScriptName   = 'deploy-function-code'

// VNet and subnet names
var vnetName                    = 'vnet-${prefix}-${resourceToken}'
var vnetIntegrationSubnetName   = 'snet-vnetintegration'
var privateEndpointSubnetName   = 'snet-privateendpoints'

// Private DNS Zone names
var privateDnsZoneBlobName  = 'privatelink.blob.${environment().suffixes.storage}'
var privateDnsZoneTableName = 'privatelink.table.${environment().suffixes.storage}'
var privateDnsZoneQueueName = 'privatelink.queue.${environment().suffixes.storage}'
var privateDnsZoneFileName  = 'privatelink.file.${environment().suffixes.storage}'

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

resource privateDnsZoneTable 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name:     privateDnsZoneTableName
  location: 'global'
  tags:     tags
}

resource privateDnsZoneTableVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent:   privateDnsZoneTable
  name:     '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork:      { id: vnet.id }
  }
}

resource privateDnsZoneQueue 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name:     privateDnsZoneQueueName
  location: 'global'
  tags:     tags
}

resource privateDnsZoneQueueVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent:   privateDnsZoneQueue
  name:     '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork:      { id: vnet.id }
  }
}

resource privateDnsZoneFile 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name:     privateDnsZoneFileName
  location: 'global'
  tags:     tags
}

resource privateDnsZoneFileVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent:   privateDnsZoneFile
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

resource privateEndpointFuncTable 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name:     'pe-${storageFuncName}-table'
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
          groupIds:             [ 'table' ]
        }
      }
    ]
  }
}

resource privateEndpointFuncTableDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpointFuncTable
  name:   'dnsgroupname'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:              'config'
        properties: {
          privateDnsZoneId: privateDnsZoneTable.id
        }
      }
    ]
  }
}

resource privateEndpointFuncQueue 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name:     'pe-${storageFuncName}-queue'
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
          groupIds:             [ 'queue' ]
        }
      }
    ]
  }
}

resource privateEndpointFuncQueueDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpointFuncQueue
  name:   'dnsgroupname'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:              'config'
        properties: {
          privateDnsZoneId: privateDnsZoneQueue.id
        }
      }
    ]
  }
}

resource privateEndpointFuncFile 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name:     'pe-${storageFuncName}-file'
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
          groupIds:             [ 'file' ]
        }
      }
    ]
  }
}

resource privateEndpointFuncFileDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpointFuncFile
  name:   'dnsgroupname'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:              'config'
        properties: {
          privateDnsZoneId: privateDnsZoneFile.id
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
// Function App — PowerShell 7.4, system-assigned MI
// ---------------------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name:     functionAppName
  location: location
  tags:     union(tags, { 'azd-service-name': 'drreplication' })
  kind:     'functionapp,linux'
  identity: { type: 'SystemAssigned' }
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
  dependsOn: [
    deploymentContainer
    privateEndpointFuncBlob
    privateEndpointFuncTable
    privateEndpointFuncQueue
    privateEndpointFuncFile
    privateEndpointConfigBlob
  ]
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
// Automated Function Code Deployment
// ---------------------------------------------------------------------------

// User-Assigned Managed Identity for deployment script
resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (autoDeployCode) {
  name:     deploymentIdentityName
  location: location
  tags:     tags
}

// Grant deployment identity permission to deploy to Function App
resource rbacDeploymentWebsiteContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (autoDeployCode) {
  scope: functionApp
  name:  guid(functionApp.id, deploymentIdentity.id, websiteContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRoleId)
    principalId:      deploymentIdentity.properties.principalId
    principalType:    'ServicePrincipal'
  }
}

// Deployment script that clones repo and publishes function code
resource deployFunctionCode 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (autoDeployCode) {
  name:     deploymentScriptName
  location: location
  tags:     tags
  kind:     'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion:         '2.59.0'
    retentionInterval:    'PT1H'
    timeout:              'PT30M'
    cleanupPreference:    'OnSuccess'
    environmentVariables: [
      {
        name:  'FUNCTION_APP_NAME'
        value: functionApp.name
      }
      {
        name:  'RESOURCE_GROUP'
        value: resourceGroup().name
      }
      {
        name:  'GITHUB_REPO_URL'
        value: gitHubRepoUrl
      }
      {
        name:  'GITHUB_BRANCH'
        value: gitHubBranch
      }
    ]
    scriptContent: '''
      #!/bin/bash
      set -e
      
      echo "==> Updating package lists..."
      apt-get update
      
      echo "==> Installing Node.js and npm..."
      apt-get install -y nodejs npm
      
      echo "==> Installing Azure Functions Core Tools via npm..."
      npm install -g azure-functions-core-tools@4 --unsafe-perm true
      
      echo "==> Cloning repository: $GITHUB_REPO_URL (branch: $GITHUB_BRANCH)..."
      git clone --depth 1 --branch "$GITHUB_BRANCH" "$GITHUB_REPO_URL" /tmp/repo
      
      echo "==> Logging into Azure..."
      az login --identity
      az account set --subscription "$(az account show --query id -o tsv)"
      
      echo "==> Publishing function code to $FUNCTION_APP_NAME..."
      cd /tmp/repo/DRReplication
      func azure functionapp publish "$FUNCTION_APP_NAME" --powershell
      
      echo "==> Deployment complete!"
      
      # Verify functions deployed
      echo "==> Verifying functions..."
      az functionapp function list --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv
    '''
  }
  dependsOn: [
    rbacDeploymentWebsiteContributor
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output AZURE_LOCATION                        string = location
output AZURE_TENANT_ID                       string = tenant().tenantId
output AZURE_FUNCTION_NAME                   string = functionApp.name
output AZURE_FUNCTION_PRINCIPAL_ID           string = functionApp.identity.principalId
output AZURE_VNET_NAME                       string = vnet.name
output AZURE_VNET_ID                         string = vnet.id
output AZURE_STORAGE_FUNC_NAME               string = storageFunc.name
output AZURE_STORAGE_CONFIG_NAME             string = storageConfig.name
output APPLICATIONINSIGHTS_CONNECTION_STRING string = appInsights.properties.ConnectionString
output CSV_STORAGE_ACCOUNT_NAME              string = storageConfig.name
output CSV_STORAGE_BLOB_ENDPOINT             string = storageConfig.properties.primaryEndpoints.blob
output FUNCTION_APP_URL                      string = 'https://${functionApp.properties.defaultHostName}'
output AUTO_DEPLOY_ENABLED                   bool   = autoDeployCode
output DEPLOYMENT_SCRIPT_STATUS              string = autoDeployCode ? deployFunctionCode.properties.provisioningState : 'Disabled'
