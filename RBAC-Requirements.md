# RBAC Requirements for DR Replication

This document describes the **minimum Azure RBAC permissions** required for the DR Replication Function to operate successfully.

## Overview

The DR Replication Function uses a **system-assigned managed identity** to perform operations across two Azure subscriptions:
- **Source Subscription**: Read-only access to source VMs and resources
- **Target Subscription**: Create and manage DR resources

---

## 🎯 Target/Destination Subscription

The managed identity needs permissions to create and manage DR infrastructure in the target subscription.

### Recommended: Multiple Built-in Roles

The **simplest and recommended approach** is to assign **three built-in roles** at the **target subscription** scope:

1. **Virtual Machine Contributor** - for VMs and NICs (create/update)
2. **Disk Snapshot Contributor** - for snapshots and disks
3. **Network Reader** - for reading VNets, subnets, and ASGs

```bash
# Get the Function App's managed identity principal ID
FUNCTION_APP_NAME="<YOUR_FUNCTION_APP_NAME>"
FUNCTION_RESOURCE_GROUP="<YOUR_FUNCTION_RESOURCE_GROUP>"
PRINCIPAL_ID=$(az functionapp identity show --name $FUNCTION_APP_NAME --resource-group $FUNCTION_RESOURCE_GROUP --query principalId -o tsv)

# Target subscription
TARGET_SUBSCRIPTION_ID="<YOUR_TARGET_SUBSCRIPTION_ID>"

# Assign Virtual Machine Contributor role
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Virtual Machine Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# Assign Disk Snapshot Contributor role (for snapshots and disks)
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Disk Snapshot Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# Assign Network Reader role (for reading VNets, subnets, ASGs)
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Network Reader" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"
```

**What Virtual Machine Contributor provides:**
- ✅ Create/update/delete Virtual Machines
- ✅ Create/update/delete Network Interfaces
- ✅ Join subnets and load balancer backend pools
- ✅ Manage VM boot diagnostics

**What Disk Snapshot Contributor provides:**
- ✅ Create/read/delete Snapshots
- ✅ Create/read/delete Disks
- ✅ Read Disk Encryption Sets

**What Network Reader provides:**
- ✅ Read Virtual Networks and Subnets
- ✅ Read Application Security Groups
- ✅ Read Load Balancers
- ✅ Read NSGs and other network resources

> **Why three roles?** Virtual Machine Contributor can CREATE NICs and JOIN subnets/LB pools, but does NOT include permissions to READ VNets, subnets, or ASGs. Network Reader provides the necessary read access to discover and reference network resources.

**What these roles do NOT provide:**
- ❌ Write to Storage Account (required for logging)

### Additional Storage Permission Required

You must also grant **Storage Blob Data Contributor** to the **log storage account**:

```bash
# Log storage account (in target subscription)
LOG_STORAGE_ACCOUNT_NAME="<YOUR_LOG_STORAGE_ACCOUNT>"
LOG_STORAGE_RESOURCE_GROUP="<YOUR_LOG_RESOURCE_GROUP>"

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

If organizational policy requires **least privilege access** or you want to avoid assigning two separate roles, create a single custom role with only the required permissions:

### Custom Role Definition

```json
{
  "Name": "DR Replication Target Operator",
  "Description": "Minimum permissions for DR replication in target subscription - combines VM, Disk/Snapshot, and Network read operations",
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
    "Microsoft.Network/networkSecurityGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/<YOUR_TARGET_SUBSCRIPTION_ID>"
  ]
}
```

### Create and Assign Custom Role

```bash
# Save the JSON above as dr-target-role.json

# Create custom role
az role definition create --role-definition @dr-target-role.json

# Assign custom role (replaces Virtual Machine Contributor + Disk Snapshot Contributor + Network Reader)
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

## 📖 Source Subscription

The managed identity needs **read-only** access to source resources:

### Recommended: Reader Role

```bash
SOURCE_SUBSCRIPTION_ID="<YOUR_SOURCE_SUBSCRIPTION_ID>"

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
- `Microsoft.Network/virtualNetworks/read` ← **Network Reader**
- `Microsoft.Network/virtualNetworks/subnets/read` ← **Network Reader**
- `Microsoft.Network/virtualNetworks/subnets/join/action` ← Virtual Machine Contributor
- `Microsoft.Network/applicationSecurityGroups/read` ← **Network Reader**
- `Microsoft.Network/networkInterfaces/read` ← Virtual Machine Contributor
- `Microsoft.Network/networkInterfaces/write` ← Virtual Machine Contributor
- `Microsoft.Network/networkInterfaces/join/action` ← Virtual Machine Contributor
- `Microsoft.Compute/virtualMachines/read` ← Virtual Machine Contributor
- `Microsoft.Compute/virtualMachines/write` ← Virtual Machine Contributor
- `Microsoft.Compute/disks/read` ← Disk Snapshot Contributor

### Stage E: Attach to Load Balancer (Target Subscription)
- `Microsoft.Network/loadBalancers/read` ← **Network Reader**
- `Microsoft.Network/loadBalancers/backendAddressPools/read` ← **Network Reader**
- `Microsoft.Network/loadBalancers/backendAddressPools/join/action` ← Virtual Machine Contributor
- `Microsoft.Network/networkInterfaces/read` ← Virtual Machine Contributor
- `Microsoft.Network/networkInterfaces/write` ← Virtual Machine Contributor

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
$targetSub = "<YOUR_TARGET_SUBSCRIPTION_ID>"
Set-AzContext -SubscriptionId $targetSub
Get-AzDiskEncryptionSet -ResourceGroupName "<YOUR_DES_RESOURCE_GROUP>" -Name "<YOUR_DES_NAME>"

# Test reading VNet
Get-AzVirtualNetwork -ResourceGroupName "<YOUR_VNET_RESOURCE_GROUP>" -Name "<YOUR_VNET_NAME>"

# Test reading storage account (should work if Storage Blob Data Contributor assigned)
$ctx = New-AzStorageContext -StorageAccountName "<YOUR_LOG_STORAGE_ACCOUNT>" -UseConnectedAccount
Get-AzStorageContainer -Context $ctx
```

---

## 🚨 Common Issues and Solutions

### Issue: "AuthorizationFailed" or "ResourceNotFound" when reading VNet/Subnet
**Cause:** Missing `Microsoft.Network/virtualNetworks/read` or `subnets/read` permission  
**Solution:** Ensure **Network Reader** role is assigned (or custom role with network read permissions)

### Issue: "AuthorizationFailed" when reading Application Security Groups
**Cause:** Missing `Microsoft.Network/applicationSecurityGroups/read` permission  
**Solution:** Ensure **Network Reader** role is assigned (or custom role with ASG read)

### Issue: "AuthorizationFailed" during snapshot creation
**Cause:** Missing `Microsoft.Compute/snapshots/write` permission  
**Solution:** Ensure **Disk Snapshot Contributor** role is assigned (or custom role with snapshot write)

### Issue: "AuthorizationFailed" during disk creation
**Cause:** Missing `Microsoft.Compute/disks/write` permission  
**Solution:** Ensure **Disk Snapshot Contributor** role is assigned (or custom role with disk write)

### Issue: "Forbidden" when uploading logs
**Cause:** Missing **Storage Blob Data Contributor** role on log storage account  
**Solution:** Grant Storage Blob Data Contributor at storage account scope

### Issue: "Subscription ID mismatch" errors
**Cause:** Context switching issues (addressed in code with Set-SubscriptionContext)  
**Solution:** Ensure managed identity has permissions in BOTH subscriptions

### Issue: "Failed to attach NIC to backend pool"
**Cause:** Missing `Microsoft.Network/loadBalancers/backendAddressPools/join/action`  
**Solution:** Ensure Virtual Machine Contributor role includes load balancer join action

---

## 📝 Summary

### ⭐ Recommended Minimal Setup

1. **Target Subscription**:
   - Role: **Virtual Machine Contributor** (subscription or resource group scope)
   - Role: **Disk Snapshot Contributor** (subscription or resource group scope)
   - Role: **Network Reader** (subscription or resource group scope)
   - Role: **Storage Blob Data Contributor** (log storage account scope)

2. **Source Subscription**:
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
