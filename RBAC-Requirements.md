# RBAC Requirements for DR Replication

This document describes the **minimum Azure RBAC permissions** required for the DR Replication Function to operate successfully.

## Overview

The DR Replication Function uses a **system-assigned managed identity** to perform operations across two Azure subscriptions:
- **Source Subscription** (Identity): Read-only access to source VMs and resources
- **Target Subscription** (Identity-DR): Create and manage DR resources

---

## 🎯 Target/Destination Subscription (identity-dr)

The managed identity needs permissions to create and manage DR infrastructure in the target subscription.

### Recommended: Virtual Machine Contributor

The **simplest and recommended approach** is to assign the **Virtual Machine Contributor** built-in role at the **target subscription** or **target resource group** scope:

```bash
# Get the Function App's managed identity principal ID
FUNCTION_APP_NAME="func-testdr-final"
PRINCIPAL_ID=$(az functionapp identity show --name $FUNCTION_APP_NAME --resource-group rg-bolla-working --query principalId -o tsv)

# Target subscription
TARGET_SUBSCRIPTION_ID="f255afb5-b435-497a-8def-92f104d8d92a"  # identity-dr

# Assign Virtual Machine Contributor role at subscription scope
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Virtual Machine Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"
```

**What this role provides:**
- ✅ Create/read/update Virtual Machines
- ✅ Create/read/update Network Interfaces
- ✅ Create/read Disks and Snapshots
- ✅ Read Virtual Networks, Subnets, and Application Security Groups
- ✅ Read Load Balancers
- ✅ Manage VM boot diagnostics
- ✅ Read Disk Encryption Sets

**What this role does NOT provide:**
- ❌ Write to Storage Account (required for logging)

### Additional Storage Permission Required

Even with Virtual Machine Contributor, you must separately grant **Storage Blob Data Contributor** to the **log storage account**:

```bash
# Log storage account (in target subscription)
LOG_STORAGE_ACCOUNT_NAME="stlogdr123456"
LOG_STORAGE_RESOURCE_GROUP="rg-bolla-dr-logs"

# Get storage account resource ID
STORAGE_ID=$(az storage account show \
  --name $LOG_STORAGE_ACCOUNT_NAME \
  --resource-group $LOG_STORAGE_RESOURCE_GROUP \
  --subscription $TARGET_SUBSCRIPTION_ID \
  --query id -o tsv)

# Assign Storage Blob Data Contributor for logging
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID"
```

---

## 📋 Alternative: Granular Custom Role (Least Privilege)

If organizational policy requires **least privilege access**, create a custom role with only the required permissions:

### Custom Role Definition

```json
{
  "Name": "DR Replication Target Operator",
  "Description": "Minimum permissions for DR replication in target subscription",
  "Actions": [
    "Microsoft.Compute/disks/read",
    "Microsoft.Compute/disks/write",
    "Microsoft.Compute/disks/delete",
    "Microsoft.Compute/snapshots/read",
    "Microsoft.Compute/snapshots/write",
    "Microsoft.Compute/snapshots/delete",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/write",
    "Microsoft.Compute/diskEncryptionSets/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Network/networkInterfaces/write",
    "Microsoft.Network/networkInterfaces/join/action",
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/applicationSecurityGroups/read",
    "Microsoft.Network/loadBalancers/read",
    "Microsoft.Network/loadBalancers/backendAddressPools/read",
    "Microsoft.Network/loadBalancers/backendAddressPools/join/action",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/f255afb5-b435-497a-8def-92f104d8d92a"
  ]
}
```

### Create and Assign Custom Role

```bash
# Save the JSON above as dr-target-role.json

# Create custom role
az role definition create --role-definition @dr-target-role.json

# Assign custom role
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "DR Replication Target Operator" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# Still need Storage Blob Data Contributor for logs
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID"
```

---

## 📖 Source Subscription (Identity)

The managed identity needs **read-only** access to source resources:

### Recommended: Reader Role

```bash
SOURCE_SUBSCRIPTION_ID="bb410b24-2061-4149-87f6-2545ee91a84c"  # Identity

az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Reader" \
  --scope "/subscriptions/$SOURCE_SUBSCRIPTION_ID"
```

**What this provides:**
- ✅ Read source VMs configuration
- ✅ Read source disks
- ✅ Read source network interfaces
- ✅ Read source load balancers
- ✅ Read all metadata required for replication

---

## 🔍 Operations by Stage

### Stage A: Discover Source VM (Source Subscription)
- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/disks/read`
- `Microsoft.Network/networkInterfaces/read`
- `Microsoft.Network/loadBalancers/read`

### Stage B: Create Snapshots (Target Subscription)
- `Microsoft.Compute/diskEncryptionSets/read`
- `Microsoft.Compute/snapshots/read`
- `Microsoft.Compute/snapshots/write`
- `Microsoft.Resources/subscriptions/resourceGroups/read`

### Stage C: Create Disks (Target Subscription)
- `Microsoft.Compute/disks/read`
- `Microsoft.Compute/disks/write`
- `Microsoft.Compute/snapshots/read`
- `Microsoft.Compute/diskEncryptionSets/read`

### Stage D: Create NIC and VM (Target Subscription)
- `Microsoft.Network/virtualNetworks/read`
- `Microsoft.Network/virtualNetworks/subnets/read`
- `Microsoft.Network/virtualNetworks/subnets/join/action`
- `Microsoft.Network/applicationSecurityGroups/read`
- `Microsoft.Network/networkInterfaces/read`
- `Microsoft.Network/networkInterfaces/write`
- `Microsoft.Network/networkInterfaces/join/action`
- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/write`
- `Microsoft.Compute/disks/read`

### Stage E: Attach to Load Balancer (Target Subscription)
- `Microsoft.Network/loadBalancers/read`
- `Microsoft.Network/loadBalancers/backendAddressPools/read`
- `Microsoft.Network/loadBalancers/backendAddressPools/join/action`
- `Microsoft.Network/networkInterfaces/read`
- `Microsoft.Network/networkInterfaces/write`

### Logging (All Stages - Target Subscription)
- `Microsoft.Storage/storageAccounts/blobServices/containers/read`
- `Microsoft.Storage/storageAccounts/blobServices/containers/write`
- `Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action`

---

## ✅ Verification Commands

### Check Current Role Assignments

```bash
# List all role assignments for the managed identity
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --all \
  --output table
```

### Test Permissions in Target Subscription

```powershell
# Connect as the managed identity (from within the function or VM)
Connect-AzAccount -Identity

# Test reading a disk encryption set
$targetSub = "f255afb5-b435-497a-8def-92f104d8d92a"
Set-AzContext -SubscriptionId $targetSub
Get-AzDiskEncryptionSet -ResourceGroupName "rg-bolla-dr-prod" -Name "des-target"

# Test reading VNet
Get-AzVirtualNetwork -ResourceGroupName "rg-bolla-dr-network" -Name "vnet-dr"

# Test reading storage account (should work if Storage Blob Data Contributor assigned)
$ctx = New-AzStorageContext -StorageAccountName "stlogdr123456" -UseConnectedAccount
Get-AzStorageContainer -Context $ctx
```

---

## 🚨 Common Issues and Solutions

### Issue: "AuthorizationFailed" during snapshot creation
**Cause:** Missing `Microsoft.Compute/snapshots/write` permission  
**Solution:** Ensure **Virtual Machine Contributor** or custom role with snapshot write is assigned

### Issue: "Forbidden" when uploading logs
**Cause:** Missing **Storage Blob Data Contributor** role on log storage account  
**Solution:** Grant Storage Blob Data Contributor at storage account scope

### Issue: "Subscription ID mismatch" errors
**Cause:** Context switching issues (addressed in code with Set-SubscriptionContext)  
**Solution:** Ensure managed identity has permissions in BOTH subscriptions

### Issue: "Failed to attach NIC to backend pool"
**Cause:** Missing `Microsoft.Network/loadBalancers/backendAddressPools/join/action`  
**Solution:** Ensure Virtual Machine Contributor or custom role includes load balancer join action

---

## 📝 Summary

### ⭐ Recommended Minimal Setup

1. **Target Subscription (identity-dr)**:
   - Role: **Virtual Machine Contributor** (subscription or resource group scope)
   - Role: **Storage Blob Data Contributor** (log storage account scope)

2. **Source Subscription (Identity)**:
   - Role: **Reader** (subscription scope)

### ⚠️ Important Notes

- Resource groups (VM RG, VNet RG, Disk RG) **must pre-exist** in target subscription
- Disk Encryption Set must pre-exist in target subscription
- Application Security Groups must pre-exist if referenced
- The function **does NOT** create resource groups (removed in commit 666e349)
- Managed identity must have access to **both** source and target subscriptions

---

## 🔗 Related Documentation

- [Azure built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles)
- [Virtual Machine Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#virtual-machine-contributor)
- [Storage Blob Data Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#storage-blob-data-contributor)
- [Create Azure custom roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles)
