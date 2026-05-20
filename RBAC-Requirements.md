# RBAC Requirements for DR Replication

This document describes the **minimum Azure RBAC permissions** required for the DR Replication Function to operate successfully.

## Overview

The DR Replication Function uses a **user-assigned managed identity (UAMI)** to perform operations across two Azure subscriptions:
- **Source Subscription**: Read-only access to source VMs and resources
- **Target Subscription**: Create and manage DR resources
- **Function App Resource Group**: Write access to log storage

The UAMI is created separately (e.g. `mi-bolla`) and assigned to the Function App. Its client ID is passed to the function via the `AZURE_CLIENT_ID` app setting — this is required so each Az session connects as the correct identity:

```bash
# Get UAMI principal ID
PRINCIPAL_ID=$(az identity show \
  --name mi-bolla \
  --resource-group <RESOURCE_GROUP> \
  --query principalId -o tsv)
```

> **Note**: RBAC role assignments are **not** created by the Bicep template. All assignments must be created manually before the first run.

---

## 🔐 Deployer Permissions

Different phases of the deployment require different roles on the person (or service principal) doing the deploying:

| Phase | What happens | Required role |
|-------|-------------|---------------|
| **Create UAMI** (`mi-bolla`) | `az identity create` | **Contributor** on the resource group where the UAMI lives |
| **Bicep / `azd provision`** | Creates VNet, storage, Function App, private endpoints | **Contributor** on the function app resource group |
| **Code deploy** (`func azure functionapp publish`) | Uploads function zip to FC1 blob storage | **Contributor** on the function app resource group |
| **Manual RBAC grants** (this document) | `az role assignment create` on source sub, target sub, function RG | **Owner** or **User Access Administrator** on each scope |

> **The Bicep template creates no role assignments.** It only references the UAMI as an `existing` resource. A plain **Contributor** on the resource group is sufficient to run `azd provision`. Owner or UAA is only needed for the separate manual RBAC grant step.



The managed identity needs permissions to create and manage DR infrastructure in the target subscription.

### Recommended: Multiple Built-in Roles

The **simplest and recommended approach** is to assign **four built-in roles** at the **target subscription** scope:

1. **Reader** - read existing resources (DES, resource groups, location lookup)
2. **Virtual Machine Contributor** - create/update VMs and NICs
3. **Disk Snapshot Contributor** - create snapshots and managed disks
4. **Network Contributor** - read and join VNets, subnets, ASGs, and LB backend pools

```bash
# UAMI principal ID (see above)
TARGET_SUBSCRIPTION_ID="<YOUR_TARGET_SUBSCRIPTION_ID>"

# 1. Reader - read existing resources
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Reader" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# 2. Virtual Machine Contributor - create/update VMs and NICs
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Virtual Machine Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# 3. Disk Snapshot Contributor - create snapshots and disks
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Disk Snapshot Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"

# 4. Network Contributor - read and join VNets, subnets, ASGs, LB backend pools
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Network Contributor" \
  --scope "/subscriptions/$TARGET_SUBSCRIPTION_ID"
```

**What Reader provides:**
- ✅ Read Disk Encryption Sets (required to locate the target DES before snapshot creation)
- ✅ Read resource groups and metadata across the target subscription

**What Virtual Machine Contributor provides:**
- ✅ Create/update/delete Virtual Machines
- ✅ Create/update/delete Network Interfaces
- ✅ Join subnets and load balancer backend pools
- ✅ Manage VM boot diagnostics

**What Disk Snapshot Contributor provides:**
- ✅ Create/read/delete Snapshots
- ✅ Create/read/delete Disks
- ✅ Read Disk Encryption Sets

**What Network Contributor provides:**
- ✅ Read Virtual Networks and Subnets
- ✅ Read Application Security Groups
- ✅ Read Load Balancers and backend pools
- ✅ Join subnets (`subnets/join/action`) — required when attaching NICs
- ✅ Join LB backend pools (`backendAddressPools/join/action`) — required for Stage E

> **Why Network Contributor and not Network Reader?** Network Reader provides only read access. The function must also join subnets and LB backend pools, which requires write-level actions (`join/action`) that only Network Contributor (or Virtual Machine Contributor) includes.

**What these roles do NOT provide:**
- ❌ Write to Storage Account (required for logging)

### Storage Blob Data Contributor on Function App Resource Group

The UAMI must be able to write log blobs to the config/log storage account (`stcfg…`). Grant **Storage Blob Data Contributor** at the **function app resource group** scope (which contains both storage accounts):

```bash
FUNCTION_APP_RESOURCE_GROUP="<YOUR_FUNCTION_RG>"  # e.g. rg-bolla-umi

# Get resource group resource ID
FUNCTION_RG_ID=$(az group show \
  --name $FUNCTION_APP_RESOURCE_GROUP \
  --query id -o tsv)

# Assign Storage Blob Data Contributor on the function app resource group
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope "$FUNCTION_RG_ID"
```

This covers both the hosting storage account (`stfn…`) and the config/log storage account (`stcfg…`) in a single assignment.

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

# Assign custom role (replaces Reader + Virtual Machine Contributor + Disk Snapshot Contributor + Network Contributor)
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

The managed identity needs **read access** to source resources and **disk backup access** to create snapshots:

### Recommended: Reader + Disk Backup Reader Roles

```bash
SOURCE_SUBSCRIPTION_ID="<YOUR_SOURCE_SUBSCRIPTION_ID>"

# 1. Reader role - read VM metadata, disks, NICs, load balancers
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Reader" \
  --scope "/subscriptions/$SOURCE_SUBSCRIPTION_ID"

# 2. Disk Backup Reader - required for snapshot creation from source disks
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Disk Backup Reader" \
  --scope "/subscriptions/$SOURCE_SUBSCRIPTION_ID"
```

**What Reader provides:**
- ✅ Read source VMs configuration
- ✅ Read source disks metadata
- ✅ Read source network interfaces
- ✅ Read source load balancers
- ✅ Read all metadata required for replication

**What Disk Backup Reader provides:**
- ✅ `Microsoft.Compute/disks/beginGetAccess/action` - Required to create snapshots from source disks
- ✅ Enables Stage B snapshot creation from source subscription disks

> **Important**: Without Disk Backup Reader, snapshot creation in Stage B will fail with "AuthorizationFailed" when attempting to copy from source disks.

---

## 🔍 Operations by Stage

### Stage A: Discover Source VM (Source Subscription)
- `Microsoft.Compute/virtualMachines/read` ← Reader
- `Microsoft.Compute/disks/read` ← Reader
- `Microsoft.Network/networkInterfaces/read` ← Reader
- `Microsoft.Network/loadBalancers/read` ← Reader

### Stage B: Create Snapshots (Cross-Subscription Operation)
**Source Subscription:**
- `Microsoft.Compute/disks/beginGetAccess/action` ← **Disk Backup Reader** (required to copy from source disks)

**Target Subscription:**
- `Microsoft.Compute/diskEncryptionSets/read` ← Disk Snapshot Contributor
- `Microsoft.Compute/snapshots/read` ← Disk Snapshot Contributor
- `Microsoft.Compute/snapshots/write` ← Disk Snapshot Contributor
- `Microsoft.Resources/subscriptions/resourceGroups/read` ← Disk Snapshot Contributor

### Stage C: Create Disks (Target Subscription)
- `Microsoft.Compute/disks/read`
- `Microsoft.Compute/disks/write`
- `Microsoft.Compute/snapshots/read`
- `Microsoft.Compute/diskEncryptionSets/read`

### Stage D: Create NIC and VM (Target Subscription)
- `Microsoft.Network/virtualNetworks/read` ← **Network Contributor**
- `Microsoft.Network/virtualNetworks/subnets/read` ← **Network Contributor**
- `Microsoft.Network/virtualNetworks/subnets/join/action` ← **Network Contributor**
- `Microsoft.Network/applicationSecurityGroups/read` ← **Network Contributor**
- `Microsoft.Network/networkInterfaces/read` ← Virtual Machine Contributor
- `Microsoft.Network/networkInterfaces/write` ← Virtual Machine Contributor
- `Microsoft.Network/networkInterfaces/join/action` ← Virtual Machine Contributor
- `Microsoft.Compute/virtualMachines/read` ← Virtual Machine Contributor
- `Microsoft.Compute/virtualMachines/write` ← Virtual Machine Contributor
- `Microsoft.Compute/disks/read` ← Disk Snapshot Contributor

### Stage E: Attach to Load Balancer (Target Subscription)
- `Microsoft.Network/loadBalancers/read` ← **Network Contributor**
- `Microsoft.Network/loadBalancers/backendAddressPools/read` ← **Network Contributor**
- `Microsoft.Network/loadBalancers/backendAddressPools/join/action` ← **Network Contributor**
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
# Connect as the UAMI (from within the function or a test VM with the identity assigned)
$clientId = "<UAMI_CLIENT_ID>"  # AZURE_CLIENT_ID app setting value
Connect-AzAccount -Identity -AccountId $clientId

# Test reading a disk encryption set
$targetSub = "<YOUR_TARGET_SUBSCRIPTION_ID>"
Set-AzContext -SubscriptionId $targetSub
Get-AzDiskEncryptionSet -ResourceGroupName "<YOUR_DES_RESOURCE_GROUP>" -Name "<YOUR_DES_NAME>"

# Test reading VNet
Get-AzVirtualNetwork -ResourceGroupName "<YOUR_VNET_RESOURCE_GROUP>" -Name "<YOUR_VNET_NAME>"
```

### Test Permissions in Source Subscription

```powershell
# Switch to source subscription
$sourceSub = "<YOUR_SOURCE_SUBSCRIPTION_ID>"
Set-AzContext -SubscriptionId $sourceSub

# Test Reader permissions - read VM and disk metadata
Get-AzVM -ResourceGroupName "<SOURCE_RESOURCE_GROUP>" -Name "<SOURCE_VM_NAME>"
$sourceDisk = Get-AzDisk -ResourceGroupName "<SOURCE_RESOURCE_GROUP>" -Name "<SOURCE_DISK_NAME>"

# Test Disk Backup Reader permissions - grant snapshot access
# This is the critical permission needed for Stage B snapshot creation
$snapConfig = New-AzSnapshotConfig -SourceResourceId $sourceDisk.Id -Location $sourceDisk.Location -CreateOption Copy
# If the above commands succeed without AuthorizationFailed, permissions are correctly configured
```

---

## 🚨 Common Issues and Solutions

### Issue: "AuthorizationFailed" or "ResourceNotFound" when reading VNet/Subnet
**Cause:** Missing `Microsoft.Network/virtualNetworks/read` or `subnets/read` permission  
**Solution:** Ensure **Network Contributor** role is assigned (or custom role with network read permissions)

### Issue: "AuthorizationFailed" when creating snapshots from source disks
**Cause:** Missing `Microsoft.Compute/disks/beginGetAccess/action` permission in source subscription  
**Solution:** Ensure **Disk Backup Reader** role is assigned in the source subscription

### Issue: "AuthorizationFailed" when reading Application Security Groups
**Cause:** Missing `Microsoft.Network/applicationSecurityGroups/read` permission  
**Solution:** Ensure **Network Contributor** role is assigned (or custom role with ASG read)

### Issue: "AuthorizationFailed" during snapshot creation
**Cause:** Missing `Microsoft.Compute/snapshots/write` permission  
**Solution:** Ensure **Disk Snapshot Contributor** role is assigned (or custom role with snapshot write)

### Issue: "AuthorizationFailed" during disk creation
**Cause:** Missing `Microsoft.Compute/disks/write` permission  
**Solution:** Ensure **Disk Snapshot Contributor** role is assigned (or custom role with disk write)

### Issue: "Forbidden" when uploading logs
**Cause:** Missing **Storage Blob Data Contributor** role on the function app resource group  
**Solution:** Grant Storage Blob Data Contributor at the function app resource group scope

### Issue: "Subscription ID mismatch" errors
**Cause:** Context switching issues (addressed in code with Set-SubscriptionContext)  
**Solution:** Ensure managed identity has permissions in BOTH subscriptions

### Issue: "Failed to attach NIC to backend pool"
**Cause:** Missing `Microsoft.Network/loadBalancers/backendAddressPools/join/action`  
**Solution:** Ensure Virtual Machine Contributor role includes load balancer join action

---

## 📝 Summary

### ⭐ Recommended Minimal Setup

1. **Source Subscription**:
   - Role: **Reader** (subscription scope)
   - Role: **Disk Backup Reader** (subscription scope) — required for snapshot creation from source disks

2. **Target Subscription**:
   - Role: **Reader** (subscription scope)
   - Role: **Virtual Machine Contributor** (subscription scope)
   - Role: **Disk Snapshot Contributor** (subscription scope)
   - Role: **Network Contributor** (subscription scope)

3. **Function App Resource Group** (e.g. `rg-bolla-umi`):
   - Role: **Storage Blob Data Contributor** — covers both the hosting storage (`stfn…`) and config/log storage (`stcfg…`)

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
