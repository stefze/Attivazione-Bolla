# User-Assigned Managed Identity Setup Guide

This branch uses a **pre-created user-assigned managed identity** instead of system-assigned managed identity. This approach provides more flexibility for permission management and allows the same identity to be reused across multiple resources.

## Prerequisites

Before deploying the DR Replication Function with user-assigned identity, you must:

1. **Create a user-assigned managed identity**
2. **Assign RBAC permissions** to the identity
3. **Provide the identity resource ID** during deployment

---

## Step 1: Create User-Assigned Managed Identity

### Using Azure CLI

```bash
# Variables
IDENTITY_NAME="id-dr-replication"
IDENTITY_RESOURCE_GROUP="rg-dr-identities"
LOCATION="eastus"

# Create resource group for identities (if needed)
az group create --name $IDENTITY_RESOURCE_GROUP --location $LOCATION

# Create user-assigned managed identity
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $IDENTITY_RESOURCE_GROUP \
  --location $LOCATION

# Get the identity resource ID (save this for deployment)
IDENTITY_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $IDENTITY_RESOURCE_GROUP \
  --query id -o tsv)

# Get the principal ID (for RBAC assignments)
PRINCIPAL_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $IDENTITY_RESOURCE_GROUP \
  --query principalId -o tsv)

echo "Identity Resource ID: $IDENTITY_ID"
echo "Principal ID: $PRINCIPAL_ID"
```

### Using Azure Portal

1. Navigate to **Azure Portal** → **Create a resource**
2. Search for "User Assigned Managed Identity"
3. Click **Create**
4. Configure:
   - **Resource Group**: Create or select existing
   - **Region**: Select your region
   - **Name**: `id-dr-replication`
5. Click **Review + Create**
6. After creation, copy the **Resource ID** from the Overview page

---

## Step 2: Assign RBAC Permissions

The user-assigned identity needs permissions in **both** source and target subscriptions. See [RBAC-Requirements.md](RBAC-Requirements.md) for detailed permission requirements.

### Target Subscription (where DR resources will be created)

```bash
# Target subscription
TARGET_SUBSCRIPTION_ID="<YOUR_TARGET_SUBSCRIPTION_ID>"

# 1. Virtual Machine Contributor
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Virtual Machine Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# 2. Disk Snapshot Contributor
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Disk Snapshot Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# 3. Network Reader
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Network Reader" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# 4. Storage Blob Data Contributor (for logging)
# Apply to specific storage account after it's created, or at subscription level
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"
```

### Source Subscription (read-only access to source VMs)

```bash
SOURCE_SUBSCRIPTION_ID="<YOUR_SOURCE_SUBSCRIPTION_ID>"

# Reader role for VM and resource metadata
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Reader" \
  --scope "/subscriptions/$SOURCE_SUBSCRIPTION_ID"

# Disk Backup Reader role for snapshot creation from source disks
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Disk Backup Reader" \
  --scope "/subscriptions/$SOURCE_SUBSCRIPTION_ID"
```

> **Important**: The Disk Backup Reader role is required for Stage B snapshot creation. Without it, the replication will fail with "AuthorizationFailed" when attempting to create snapshots from source disks.

### Verify Role Assignments

```bash
# List all role assignments for the identity
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --all \
  --output table
```

---

## Step 3: Deploy Function App with User-Assigned Identity

### Option A: Using Azure Developer CLI (azd)

1. **Create or update `azure.yaml`** parameter file:

```yaml
# azure.yaml
name: dr-replication
services:
  drreplication:
    project: ./
    language: powershell
    host: function
infra:
  path: ./infra
  parameters:
    userAssignedIdentityId: "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<NAME>"
```

2. **Deploy**:

```bash
azd up
```

### Option B: Using Bicep Directly

```bash
# Variables
RESOURCE_GROUP="rg-dr-function"
LOCATION="eastus"
ENVIRONMENT_NAME="production"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy with user-assigned identity parameter
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file ./infra/main.bicep \
  --parameters environmentName=$ENVIRONMENT_NAME \
  --parameters userAssignedIdentityId="$IDENTITY_ID"
```

### Option C: Using Azure Portal Manual Configuration

If you've deployed the function app already and want to switch to user-assigned identity:

1. Navigate to your Function App in Azure Portal
2. Go to **Settings** → **Identity**
3. Switch to **User assigned** tab
4. Click **+ Add**
5. Select your pre-created user-assigned managed identity
6. Click **Add**
7. Go to **Settings** → **Configuration**
8. Add new application setting:
   - **Name**: `AZURE_CLIENT_ID`
   - **Value**: `<CLIENT_ID_OF_USER_ASSIGNED_IDENTITY>`
9. Save changes and restart the function app

---

## Step 4: Update Infrastructure Storage Connections

The function app requires the user-assigned identity to have access to the storage accounts:

```bash
# Get function hosting storage account name (created by deployment)
STORAGE_FUNC_NAME="stfn<resource-token>"

# Get CSV config storage account name
STORAGE_CONFIG_NAME="stcfg<resource-token>"

# Get storage account resource IDs
STORAGE_FUNC_ID=$(az storage account show \
  --name $STORAGE_FUNC_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

STORAGE_CONFIG_ID=$(az storage account show \
  --name $STORAGE_CONFIG_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Assign Storage Blob Data Contributor (if not already assigned at subscription level)
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Owner" \
  --scope "$STORAGE_FUNC_ID"

az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_CONFIG_ID"
```

---

## Differences from System-Assigned Identity

### Advantages of User-Assigned Identity

1. **Pre-configured Permissions**: RBAC roles can be assigned before deployment
2. **Reusability**: Same identity can be used across multiple function apps
3. **Lifecycle Management**: Identity persists independently of the function app
4. **Centralized Management**: Easier to audit and manage permissions
5. **Cross-Resource Scenarios**: Better support for scenarios requiring shared identity

### What Changed in the Code

1. **Bicep Infrastructure** (`infra/main.bicep`):
   - Added `userAssignedIdentityId` parameter
   - Changed identity type from `SystemAssigned` to `UserAssigned`
   - Updated all RBAC role assignments to use user-assigned identity principal ID
   - Added `AZURE_CLIENT_ID` environment variable

2. **PowerShell Code**:
   - `profile.ps1`: Added `-AccountId $clientId` to `Connect-AzAccount`
   - `DRCore.psm1`: Updated parallel block to use client ID
   - `Get-DRStatus/run.ps1`: Added client ID validation and usage

3. **Authentication**:
   - Now uses: `Connect-AzAccount -Identity -AccountId $env:AZURE_CLIENT_ID`
   - Previously: `Connect-AzAccount -Identity`

---

## Troubleshooting

### Issue: "AZURE_CLIENT_ID environment variable not set"

**Solution**: Ensure the function app configuration includes the `AZURE_CLIENT_ID` setting with the client ID of your user-assigned managed identity.

```bash
# Get client ID
CLIENT_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $IDENTITY_RESOURCE_GROUP \
  --query clientId -o tsv)

# Set in function app
az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group $RESOURCE_GROUP \
  --settings "AZURE_CLIENT_ID=$CLIENT_ID"
```

### Issue: "AuthorizationFailed" errors during replication

**Solution**: Verify RBAC permissions are correctly assigned. See [RBAC-Requirements.md](RBAC-Requirements.md) for complete permission requirements.

```bash
# Check role assignments
az role assignment list --assignee $PRINCIPAL_ID --all --output table
```

### Issue: Function app cannot access storage

**Solution**: Ensure the user-assigned identity has appropriate storage roles:

```bash
# Verify storage role assignments
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID" \
  --query "[?contains(roleDefinitionName, 'Storage')]" \
  --output table
```

### Issue: "Failed to acquire a token" in function logs

**Solution**: 
1. Verify the user-assigned identity is correctly attached to the function app
2. Verify the `AZURE_CLIENT_ID` matches the client ID of the attached identity
3. Restart the function app after configuration changes

---

## Migration from System-Assigned to User-Assigned

If you have an existing deployment using system-assigned identity and want to migrate:

1. **Create user-assigned identity** and assign RBAC permissions (Steps 1-2 above)
2. **Switch to this branch**: `git checkout feature/user-assigned-identity`
3. **Update deployment parameters** to include `userAssignedIdentityId`
4. **Redeploy**: `azd up` or `az deployment group create`
5. **Verify**: Test a small replication to ensure permissions work correctly
6. **(Optional) Clean up**: Remove system-assigned identity if no longer needed

---

## Security Best Practices

1. **Least Privilege**: Only assign the minimum required roles (see [RBAC-Requirements.md](RBAC-Requirements.md))
2. **Scope Restrictions**: Assign roles at the narrowest scope possible (resource group over subscription when feasible)
3. **Regular Audits**: Periodically review role assignments using `az role assignment list`
4. **Separation of Duties**: Use different identities for different environments (dev/test/prod)
5. **Identity Protection**: Store identity resource IDs securely (Key Vault, parameter files with restricted access)

---

## Reference Links

- [Azure Managed Identities Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- [User-Assigned Managed Identities](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-manage-user-assigned-managed-identities)
- [Configure Managed Identity for Azure Functions](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity)
- [Connect-AzAccount with Managed Identity](https://learn.microsoft.com/en-us/powershell/module/az.accounts/connect-azaccount)
