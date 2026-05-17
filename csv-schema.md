# CSV Configuration Schema

## Overview
The CSV file defines the source VMs and target DR configurations for orchestrated replication. Store this file in Azure Blob Storage for the Function App to access.

## CSV Structure

### Required Columns

| Column Name | Type | Description | Example |
|-------------|------|-------------|---------|
| `SourceSubscription` | string | Source subscription name or ID | `Identity` |
| `SourceResourceGroup` | string | Source resource group containing VMs | `rg-wsfc-2node` |
| `SourceVmName` | string | Source VM name to replicate | `vm-node1` |

### Auto-Derived Target Names

All target resource names are automatically derived by appending the `TARGET_NAME_SUFFIX` (default `-DR`) to discovered source names. Individual resources can be overridden with `TARGET_SUBSCRIPTION` and `TARGET_RESOURCE_GROUP` env vars:

| Target Resource | Derivation Rule | Override Env Var | Example |
|-----------------|-----------------|------------------|---------|
| `TargetSubscription` | `{SourceSubscription}{suffix}` | `TARGET_SUBSCRIPTION` | `Identity-DR` |
| `TargetVmResourceGroup` | `{SourceResourceGroup}{suffix}` | `TARGET_RESOURCE_GROUP` | `rg-wsfc-2node-DR` |
| `TargetSnapshotDiskResourceGroup` | same as VM RG | `TARGET_RESOURCE_GROUP` | `rg-wsfc-2node-DR` |
| `TargetVnetName` | `{DiscoveredSourceVnetName}{suffix}` | — | `vnet-infra-DR` |
| `TargetVnetResourceGroup` | `{DiscoveredSourceVnetRG}{suffix}` | — | `rg-infra-DR` |
| `DiskEncryptionSetName` | `{DiscoveredSourceDESName}{suffix}` | — | `des-prod-DR` |
| `DiskEncryptionSetResourceGroup` | `{DiscoveredSourceDESRG}{suffix}` | — | `rg-security-DR` |
| `TargetLoadBalancerResourceGroup` | `{DiscoveredSourceLBRG}{suffix}` | — | `rg-wsfc-2node-DR` |

**Note:** `TARGET_SUBSCRIPTION` and `TARGET_RESOURCE_GROUP` apply to **all VMs** in a single invocation. VNet, DES, and LB resource groups are always suffix-derived from their respective source names.

## Parallelism Configuration

**Two levels of parallelism are supported:**

### 1. VM-Level Parallelism (Global)
- **Parameter**: `vmParallelThrottle` in HTTP request body
- **Default**: 1 (sequential)
- **Range**: 1-10
- **Controls**: How many VMs are replicated simultaneously
- **Set via**: HTTP POST body or `VM_PARALLEL_THROTTLE` environment variable

**Example HTTP Request:**
```json
{
  "csvBlobPath": "configurations/production-config.csv",
  "vmParallelThrottle": 3
}
```

### 2. Disk-Level Parallelism (Global)
- **Parameter**: `PARALLEL_THROTTLE` environment variable
- **Default**: 6
- **Range**: 1-64
- **Controls**: Snapshot/disk operations within each VM
- **Set via**: Function App environment variable

## Environment Configuration

The following parameters are configured via Function App environment variables (not in CSV):

| Variable | Default | Description |
|----------|---------|-------------|
| `PARALLEL_THROTTLE` | `6` | Max parallel disk operations per VM (1-64) |
| `TAG_PREFIX` | `DR-` | Prefix for target VM tags |
| `SNAPSHOT_NAME_PREFIX` | `snap-` | Prefix for snapshot names |
| `BACKEND_POOL_NAME_OVERRIDE` | `` (empty) | Specific backend pool name (empty for auto-select) |
| `TARGET_NAME_SUFFIX` | `-DR` | Suffix appended to all derived target resource names. Empty = use source name as-is |
| `TARGET_SUBSCRIPTION` | `` (empty) | Override target subscription name for all VMs (ignores suffix derivation for subscription) |
| `TARGET_RESOURCE_GROUP` | `` (empty) | Override target resource group for VM and disk/snapshot resources for all VMs |

**Configure via Azure CLI:**
```bash
az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --settings PARALLEL_THROTTLE=8 TAG_PREFIX='DR-' SNAPSHOT_NAME_PREFIX='snap-'
```

## Sample CSV

**Simplified CSV with only source VM information:**

```csv
SourceSubscription,SourceResourceGroup,SourceVmName
Identity,rg-wsfc-2node,vm-node1
Identity,rg-wsfc-2node,vm-node2
Identity,rg-app-servers,vm-app1
Identity,rg-db-cluster,vm-sql1
```

**What happens for each VM:**
- VM `vm-node1` from `rg-wsfc-2node` → replicated to `rg-wsfc-2node-DR`
- Snapshots/disks created in `rg-wsfc-2node-DR`
- If source VM has a load balancer in `rg-wsfc-2node`, target LB is expected in `rg-wsfc-2node-DR`
- All VNet/subnet/DES resources are auto-discovered from source and `-DR` suffix applied

## Blob Storage Configuration

### Storage Structure
```
container: dr-configs
  └── configurations/
      ├── production-config.csv
      ├── staging-config.csv
      └── test-config.csv
```

### Function App Settings Required
- `CSV_STORAGE_CONNECTION__blobServiceUri`: Blob storage URI (use managed identity)
- `CSV_CONTAINER_NAME`: Container name (default: `dr-configs`)
- `CSV_BLOB_PATH`: Blob path (e.g., `configurations/production-config.csv`)

## Validation Rules

1. **CSV Structure**: Exactly 3 columns required (SourceSubscription, SourceResourceGroup, SourceVmName)
2. **Subscription Resolution**: Both name and ID formats are supported
3. **Resource Group Existence**: Target resource groups will be created if missing
4. **Network Validation**: Target subnet must exist in target VNet with the same name as source subnet
5. **DES Validation**: Disk Encryption Set must exist in target subscription
6. **VM Validation**: Source VM must exist in the specified source resource group
7. **Auto-Derivation**: All target names derived by appending `-DR` suffix to source names
7. **VM Parallelism**: Global `vmParallelThrottle` constrained to 1-10, defaults to 1

## Error Handling

Invalid CSV rows are logged and skipped. The orchestration continues with valid rows.

Common errors:
- Missing required columns → Row skipped
- Invalid subscription → Row skipped with error
- Non-existent DES → Row skipped with error
- Network mismatch → Row skipped with error
