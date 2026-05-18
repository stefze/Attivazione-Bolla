# Attivazione Bolla — DR Replication Function

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fstefze%2FAttivazione-Bolla%2Fmain%2Finfra%2Fmain.bicep)

Azure Function (PowerShell 7.4, Flex Consumption) that orchestrates disaster-recovery replication of Azure VMs across subscriptions and resource groups. It reads a CSV configuration from Azure Blob Storage and, for each source VM, performs a full staged replication: snapshots → managed disks → NIC → VM creation → LB backend pool attachment.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Replication Stages](#replication-stages)
- [Project Structure](#project-structure)
- [Infrastructure](#infrastructure)
- [Authentication & RBAC](#authentication--rbac)
- [Key Design Decisions](#key-design-decisions)
- [Environment Variables](#environment-variables)
- [CSV Configuration](#csv-configuration)
- [Parallelism Model](#parallelism-model)
- [Per-VM Blob Logging](#per-vm-blob-logging)
- [Target Resource Naming](#target-resource-naming)
- [Deploying the Function](#deploying-the-function)
- [Invoking the Function](#invoking-the-function)
- [Local Development](#local-development)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
HTTP POST
  ↓
Invoke-DRReplication (Azure Function — FC1/Linux)
  ├── Returns 202 Accepted immediately
  ├── Downloads CSV from Azure Blob Storage (managed identity)
  ├── Parses and validates rows
  └── ForEach-Object -Parallel (VM-level, throttle 1-10)
        ↓  (each runspace re-authenticates with Connect-AzAccount -Identity)
        DRCore.psm1: Invoke-VMReplication
          Stage A: Discover source VM (NIC, VNet, DES, LB, disks, ASGs)
          Stage B: Create snapshots + managed disks in parallel (disk-level throttle 1-64)
          Stage C: Resolve target VNet; check for target ASGs (must be pre-created)
          Stage D: Create target NIC (with preserved source IP) + VM
          Stage E: Attach NIC to LB backend pool
          → Upload per-VM log to dr-logs container
```

---

## Network Security Architecture

The solution implements a **fully private network architecture** with:

- **Virtual Network** (10.0.0.0/24) with two subnets:
  - VNet Integration subnet for Function App connectivity
  - Private Endpoints subnet for storage access
- **Private Endpoints** for all storage accounts (blob, table, queue, file)
- **Private DNS Zones** for automatic DNS resolution to private IPs
- **Network Isolation**: Storage accounts have `publicNetworkAccess: Disabled`
- **Zero Trust**: Only the Function App with Managed Identity can access storage via private network

📖 **Detailed documentation**: See [NETWORK-ARCHITECTURE.md](NETWORK-ARCHITECTURE.md)

---

## Replication Stages

| Stage | Actions |
|-------|---------|
| **A — Discover** | Read source VM: primary NIC, IP config, VNet, subnet, ASGs (optional), backend pool IDs (optional), LB name (optional), OS disk + data disks with DES |
| **B — Snapshots & Disks** | Create snapshot of each disk (or reuse existing); create managed disk in target RG from snapshot; apply target DES |
| **C — Network** | Resolve target VNet/subnet; resolve target ASGs if source has any (must be pre-created in VNet RG) |
| **D — NIC & VM** | Create target NIC (with source private IP preserved as static, ASG bindings if found, LB backend pool if source has one); create or reuse target VM (OS + data disks attached) |
| **E — LB Attachment** | If source VM has a load balancer: retrieve target LB, select backend pool (auto or override), attach target NIC. Otherwise skip. |

---

## Project Structure

```
Attivazione-Bolla-Function/
├── azure.yaml                         # azd project config + postprovision hook
├── setup-modules.ps1                  # Bundles Az modules for FC1 deployment
├── csv-schema.md                      # CSV column reference
├── infra/
│   ├── main.bicep                     # All Azure resources (IaC, resource-group scope)
│   └── main.parameters.json           # azd parameter bindings
└── DRReplication/                     # Function App root (deployed as-is)
    ├── host.json                      # managedDependency: false, extension bundle 4.x
    ├── profile.ps1                    # Connect-AzAccount -Identity on startup
    ├── local.settings.json            # Local dev env vars (not deployed)
    ├── Modules/
    │   ├── DRCore/
    │   │   └── DRCore.psm1            # All replication logic
    │   ├── Az.Accounts/               # Bundled Az modules (run setup-modules.ps1)
    │   ├── Az.Compute/
    │   ├── Az.Network/
    │   ├── Az.Resources/
    │   └── Az.Storage/
    └── Invoke-DRReplication/
        ├── function.json              # HTTP trigger, authLevel: function, POST only
        └── run.ps1                    # Thin orchestrator: CSV download → parallel dispatch
```

---

## Infrastructure

All resources are provisioned in a single resource group via `infra/main.bicep` (resource-group scope). Resource names include a unique token derived from subscription + RG + env name.

| Resource | Name pattern | Purpose |
|----------|-------------|---------|
| Log Analytics Workspace | `log-bolla-{token}` | Backing store for App Insights |
| Application Insights | `appi-bolla-{token}` | Function telemetry |
| Storage — Function hosting | `stfn{token}` | `AzureWebJobsStorage`, deployment package (`deploymentpackage` container) |
| Storage — Config/logs | `stcfg{token}` | `dr-configs` container (CSV), `dr-logs` container (per-VM logs) |
| App Service Plan | `asp-bolla-{token}` | FC1 / Flex Consumption / Linux |
| Function App | `func-bolla-{token}` | PowerShell 7.4, 2 GB instance memory, system-assigned MI |


---

## Authentication & RBAC

The Function App uses a **system-assigned managed identity** for all Azure API calls. No passwords or connection strings are stored anywhere.

### Function hosting storage (stfn…)

| Role | Scope |
|------|-------|
| Storage Blob Data Owner | stfn storage account |
| Storage Blob Data Contributor | stfn storage account |
| Storage Queue Data Contributor | stfn storage account |
| Storage Table Data Contributor | stfn storage account |

### Config/log storage (stcfg…)

| Role | Scope |
|------|-------|
| Storage Blob Data Contributor | stcfg storage account |

This covers both reading the CSV (`dr-configs`) and writing per-VM logs (`dr-logs`).

### Source and target subscriptions (manual grant required)

The managed identity must be granted roles on the subscriptions/resource groups it operates on at runtime. Minimum recommended grants:

| Role | Scope | Why |
|------|-------|-----|
| **Disk Backup Reader** | Source subscription or source RG | Required for cross-subscription snapshot creation. Includes `Microsoft.Compute/disks/beginGetAccess/action` to get SAS URLs from source disks. **Reader role is insufficient.** |
| Contributor | Target VM resource group | Create/update VMs, NICs, disks |
| Contributor | Target snapshot/disk resource group (same as VM RG) | Create snapshots and managed disks |
| Network Contributor | Target VNet resource group | Attach NICs to VNet/subnet |
| Reader | Target DES resource group | Read Disk Encryption Set for encrypted snapshots |
| Reader | Target LB resource group | Read Load Balancer configuration |

**Example: Grant Disk Backup Reader on source subscription**

```bash
# Get function's managed identity principal ID
$principalId = az functionapp identity show `
  --name <FUNCTION_APP_NAME> `
  --resource-group <RESOURCE_GROUP> `
  --query principalId -o tsv

# Assign Disk Backup Reader on source subscription
az role assignment create `
  --assignee $principalId `
  --role "Disk Backup Reader" `
  --scope /subscriptions/<SOURCE_SUBSCRIPTION_ID>
```

---

## Key Design Decisions

### Why Flex Consumption (FC1)?

FC1 is used instead of the legacy Y1 Dynamic Consumption plan because it supports per-instance memory configuration (2 GB here), faster cold starts, and is the recommended plan for new deployments.

### Why managed dependencies are disabled

FC1 on Linux does **not** support `managedDependency.enabled: true` in `host.json`. Enabling it causes the worker to crash on startup. Az modules are pre-bundled in `DRReplication/Modules/` via `setup-modules.ps1` (~27 MB compressed).

### Why `func azure functionapp publish` instead of `azd up`

`azd` does not support PowerShell function packaging. The `azd provision` step handles all infrastructure. Code deployment is done with:

```powershell
cd DRReplication
func azure functionapp publish <FUNCTION_APP_NAME> --powershell
```

The `azure.yaml` `postprovision` hook attempts this automatically, but may return a 403 in some environments — run manually if needed.

### Thread-safe log buffer

`DRCore.psm1` uses a `ConcurrentQueue[string]` (`$script:LogBuffer`) so that `Write-Log` calls are safe within a `ForEach-Object -Parallel` runspace. Each call to `Invoke-VMReplication` resets this buffer at entry. The collected entries are returned in the result object and uploaded to blob storage.

### Per-runspace re-authentication

`ForEach-Object -Parallel` creates isolated runspaces that do not inherit the Az context. Each runspace calls `Connect-AzAccount -Identity` before any Az cmdlet. The identity endpoint is detected via `$env:MSI_SECRET` or `$env:IDENTITY_ENDPOINT` (Linux/FC1 uses the latter).

### Idempotent operations

All creation steps check for an existing resource first (Get → create if absent). Re-running the function against the same CSV is safe; existing snapshots, disks, NICs, and VMs are reused.

**Application Security Groups (ASGs):** ASGs are **not** auto-created. They must be pre-created in the target VNet resource group. If a source VM has ASGs but the corresponding target ASG is not found, a warning is logged and the NIC is created without that ASG binding. If the source VM has no ASGs, ASG resolution is skipped entirely.

**Load Balancers:** If the source VM has no load balancer attachment, Stage E (LB attachment) is skipped entirely. The function only attempts to attach to a target LB if the source VM was attached to one.

---

## Environment Variables

All settings are configured as Function App Application Settings. Variables are grouped below.

### Core settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CSV_STORAGE_CONNECTION__blobServiceUri` | *(set by Bicep)* | Blob service endpoint of the config storage account |
| `CSV_CONTAINER_NAME` | `dr-configs` | Container that holds CSV configuration files |
| `LOG_CONTAINER_NAME` | `dr-logs` | Container where per-VM log files are written |
| `VM_PARALLEL_THROTTLE` | `1` | Default VM-level parallelism (1–10). Overridable per-request in the body |
| `PARALLEL_THROTTLE` | `6` | Disk-level parallelism per VM (1–64) |
| `SNAPSHOT_NAME_PREFIX` | `snap-` | Prefix prepended to snapshot resource names |
| `BACKEND_POOL_NAME_OVERRIDE` | *(empty)* | Force a specific backend pool name on all target LBs. Empty = auto-select from source |

### Per-resource target suffix overrides

All suffix variables are independent. Set each one to define how target resource names are derived from source names.

| Variable | Default | Applies to |
|----------|---------|------------|
| `TARGET_SUBSCRIPTION_SUFFIX` | *(empty)* | Target subscription name |
| `TARGET_RESOURCE_GROUP_SUFFIX` | *(empty)* | Target resource group name |
| `TARGET_VNET_NAME_SUFFIX` | *(empty)* | Target VNet name |
| `TARGET_VNET_RG_SUFFIX` | *(empty)* | Target VNet resource group |
| `TARGET_LB_NAME_SUFFIX` | *(empty)* | Target Load Balancer name |
| `TARGET_LB_RG_SUFFIX` | *(empty)* | Target Load Balancer resource group |
| `TARGET_DES_NAME_SUFFIX` | *(empty)* | Target Disk Encryption Set name |
| `TARGET_DES_RG_SUFFIX` | *(empty)* | Target Disk Encryption Set resource group |
| `TARGET_ASG_NAME_SUFFIX` | *(empty)* | Target Application Security Group names |

**Changing app settings via CLI:**

```bash
az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --settings TARGET_SUBSCRIPTION_SUFFIX="-DR" TARGET_LB_NAME_SUFFIX="-failover"
```

---

## CSV Configuration

CSV files are stored in the `dr-configs` container of the config storage account.

### Required columns

| Column | Description | Example |
|--------|-------------|---------|
| `SourceSubscription` | Source subscription name or GUID | `Identity` |
| `SourceResourceGroup` | Source resource group | `rg-wsfc-2node` |
| `SourceVmName` | Exact name of the source VM | `vm-node1` |

### Sample file

```csv
SourceSubscription,SourceResourceGroup,SourceVmName
Identity,rg-wsfc-2node,vm-node1
Identity,rg-wsfc-2node,vm-node2
Identity,rg-app-servers,vm-app1
```

### Uploading a CSV

```bash
az storage blob upload \
  --account-name <CONFIG_STORAGE_NAME> \
  --container-name dr-configs \
  --name configurations/prod.csv \
  --file ./prod.csv \
  --auth-mode login
```

---

## Parallelism Model

Two independent levels of parallelism are controlled separately.

### VM-level (outer loop)

- Controlled by `vmParallelThrottle` in the HTTP request body (takes precedence) or `VM_PARALLEL_THROTTLE` env var.
- Range: 1–10. Clamped automatically.
- Each VM gets its own PowerShell runspace.

### Disk-level (inner loop, per VM)

- Controlled by `PARALLEL_THROTTLE` env var.
- Range: 1–64. Clamped automatically.
- Controls concurrent snapshot creation and disk creation operations within a single VM replication.

**Guidance:** Start with `vmParallelThrottle=1` and `PARALLEL_THROTTLE=6`. Increase VM-level parallelism only after confirming Azure API throttling is not a concern for your subscription.

---

## Per-VM Blob Logging

After each replication stage (A, B, C, D, E), the collected log lines for that stage are uploaded to the `dr-logs` container as separate text files.

**Blob path format:**

```
{vmName}/{invocationId}-stage{letter}-{description}-{yyyyMMdd}-{HHmm}[-failed].log
```

- **stage{letter}**: A (Discover), B (Snapshots), C (Disks), D (NIC-VM), E (LB-Attach), or X (Failed)
- **description**: Short stage name (Discover, Snapshots, Disks, NIC-VM, LB-Attach, or Failed)
- **timestamp**: Date and time in `yyyyMMdd-HHmm` format (24-hour)
- **-failed suffix**: Appended only to the final failed stage log (stageX) if the VM replication encounters an error

**Examples:**
- `vm-node1/abc123-stageA-Discover-20260517-1430.log` — Stage A discovery logs
- `vm-node1/abc123-stageB-Snapshots-20260517-1431.log` — Stage B snapshot creation logs
- `vm-node1/abc123-stageX-Failed-20260517-1432-failed.log` — Failed replication with error details

This per-stage logging allows you to pinpoint exactly which stage failed and review detailed logs for each phase independently.

**Reading a log:**

```bash
az storage blob download \
  --account-name <CONFIG_STORAGE_NAME> \
  --container-name dr-logs \
  --name "vm-node1/abc123-vm-node1-20260517-143000-000.log" \
  --file ./vm-node1.log \
  --auth-mode login
```

---

## Target Resource Naming

All target resource names are derived at runtime from source names by appending the corresponding suffix variable. Each suffix is independent (no fallback logic).

| Source resource discovered | Target name derivation |
|---------------------------|----------------------|
| Source subscription `Identity` | `Identity` + `TARGET_SUBSCRIPTION_SUFFIX` |
| Source RG `rg-wsfc-2node` | `rg-wsfc-2node` + `TARGET_RESOURCE_GROUP_SUFFIX` |
| VNet `vnet-infra` | `vnet-infra` + `TARGET_VNET_NAME_SUFFIX` |
| VNet RG `rg-infra` | `rg-infra` + `TARGET_VNET_RG_SUFFIX` |
| LB `lb-wsfc` | `lb-wsfc` + `TARGET_LB_NAME_SUFFIX` |
| LB RG `rg-wsfc-2node` | `rg-wsfc-2node` + `TARGET_LB_RG_SUFFIX` |
| DES `des-prod` | `des-prod` + `TARGET_DES_NAME_SUFFIX` |
| DES RG `rg-security` | `rg-security` + `TARGET_DES_RG_SUFFIX` |
| ASG `asg-web` | `asg-web` + `TARGET_ASG_NAME_SUFFIX` (resolved in **VNet RG**, must be pre-created) |

> **Notes:**
> - VM tags are copied as-is from the source VM with no prefix modification.
> - **Source private IP address is always preserved** in the target NIC with static allocation.
> - **ASGs must be manually pre-created** in the target VNet resource group before running replication.

---

## Deploying the Function

### Quick Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fstefze%2FAttivazione-Bolla%2Fmain%2Finfra%2Fmain.bicep)

Click the button above to deploy the infrastructure using Azure Portal's guided wizard. The deployment will create:
- Virtual Network with private networking
- Function App (Flex Consumption, PowerShell 7.4)
- Storage accounts with private endpoints
- Application Insights and Log Analytics workspace
- All necessary RBAC role assignments

After infrastructure deployment, you'll need to:
1. Run `.\setup-modules.ps1` to bundle Az modules
2. Publish function code: `func azure functionapp publish <FUNCTION_APP_NAME> --powershell`
3. Grant RBAC roles on source/target subscriptions

### Manual Deployment

#### Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- PowerShell 7.4+

### Step 1 — Bundle Az modules

Run once before the first deployment (or whenever module versions need updating):

```powershell
.\setup-modules.ps1
```

This saves `Az.Accounts`, `Az.Resources`, `Az.Compute`, `Az.Network`, `Az.Storage` into `DRReplication/Modules/`.

### Step 2 — Provision infrastructure

```powershell
azd auth login
azd provision --no-prompt
```

This creates the resource group, VNet, Private Endpoints, Private DNS Zones, storage accounts, app service plan, and function app. It also configures all application settings and RBAC for the function hosting storage.

> **⏱️ Note**: The first deployment with private networking may take **5-10 minutes** due to Private Endpoint and DNS propagation. If the Function App reports connectivity issues immediately after deployment, wait 2-3 minutes and the connection will stabilize automatically.

This creates the resource group, storage accounts, app service plan, and function app. It also configures all application settings and RBAC for the function hosting storage.

### Step 3 — Publish function code

```powershell
cd DRReplication
func azure functionapp publish <FUNCTION_APP_NAME> --powershell
```

> `azd up` is not used for code deployment because `azd` does not support PowerShell function packaging. The `azure.yaml` `postprovision` hook attempts this automatically but may fail with a 403 in restricted environments — run manually in that case.

### Step 4 — Grant RBAC on DR subscriptions

Manually assign roles to the managed identity on the source and target subscriptions/resource groups (see [Authentication & RBAC](#authentication--rbac)).

### Re-deploying after code changes

```powershell
# Infrastructure changes only:
azd provision --no-prompt

# Code changes only:
cd DRReplication
func azure functionapp publish <FUNCTION_APP_NAME> --powershell

# Both:
azd provision --no-prompt
cd DRReplication
func azure functionapp publish <FUNCTION_APP_NAME> --powershell
```

---

## Invoking the Function

### Request

```
POST https://<FUNCTION_APP_NAME>.azurewebsites.net/api/Invoke-DRReplication?code=<FUNCTION_KEY>
Content-Type: application/json

{
  "csvBlobPath": "configurations/prod.csv"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `csvBlobPath` | Yes | Path within the `dr-configs` container |

### Response codes

The function returns **202 Accepted** immediately after accepting the request. Processing continues asynchronously in the background. Check per-VM logs in the `dr-logs` blob container for detailed results.

| Code | Meaning |
|------|---------|
| `202` | Request accepted, replication started (async) |
| `400` | Bad request (missing `csvBlobPath`, invalid CSV, no valid rows) |
| `500` | Fatal error before processing could start |

### Response body (example)

```json
{
  "message": "DR replication job accepted and started. Check per-VM logs in blob storage for results.",
  "invocationId": "abc123-def456-789",
  "vmCount": 2,
  "startedAt": "2026-05-17T14:00:00.000Z"
}
```

**Monitoring results:** Each VM's processing log is uploaded to the `dr-logs` container as it completes. Blob path format:

```
{vmName}/{invocationId}-{vmName}-{yyyyMMdd-HHmmss-fff}[-failed].log
```

The `-failed` suffix is added for VMs that encounter errors during replication.

### PowerShell example

```powershell
$uri  = "https://<FUNCTION_APP_NAME>.azurewebsites.net/api/Invoke-DRReplication?code=<KEY>"
$body = '{"csvBlobPath":"configurations/prod.csv"}'
$resp = Invoke-RestMethod -Uri $uri -Method POST -ContentType "application/json" -Body $body `
        -StatusCodeVariable status -SkipHttpErrorCheck
Write-Host "Status: $status"
$resp | ConvertTo-Json -Depth 3
# Output: 202, with invocationId and vmCount
# Check dr-logs container for per-stage results as they complete
```

---

## Checking DR Status

### Get-DRStatus Function

The `Get-DRStatus` function checks the status of the most recent DR replication for each VM in a CSV. It reads the per-stage logs from the `dr-logs` container and reports whether each VM succeeded, failed, or is still in progress.

### Request

```
GET/POST https://<FUNCTION_APP_NAME>.azurewebsites.net/api/Get-DRStatus?code=<FUNCTION_KEY>
Content-Type: application/json

{
  "csvBlobPath": "prod/production-config.csv"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `csvBlobPath` | Yes | Path within the `dr-configs` container (same as used for `Invoke-DRReplication`) |

### Response body (example)

```json
{
  "checkedAt": "2026-05-17T20:55:00.000Z",
  "vmCount": 2,
  "results": [
    {
      "vmName": "vm-wsfc-n1",
      "status": "SUCCEEDED",
      "invocationId": "8faadceb-fd98-4c72-ad79-a040faae3ed5",
      "completedStage": "Stage-E"
    },
    {
      "vmName": "vm-wsfc-n2",
      "status": "FAILED",
      "invocationId": "8faadceb-fd98-4c72-ad79-a040faae3ed5",
      "failedStage": "Stage-B"
    }
  ],
  "summary": {
    "succeeded": 1,
    "failed": 1,
    "inProgress": 0,
    "unknown": 0,
    "error": 0
  }
}
```

### Status values

| Status | Meaning |
|--------|---------|
| `SUCCEEDED` | All stages completed successfully (completion marker found in logs) |
| `FAILED` | Replication failed at a specific stage (reported in `failedStage`) |
| `IN_PROGRESS` | Replication started but not yet completed |
| `UNKNOWN` | No logs found for this VM |
| `ERROR` | Error reading logs for this VM |

### PowerShell example

```powershell
$uri  = "https://<FUNCTION_APP_NAME>.azurewebsites.net/api/Get-DRStatus?code=<KEY>"
$body = '{"csvBlobPath":"prod/production-config.csv"}'
$resp = Invoke-RestMethod -Uri $uri -Method POST -ContentType "application/json" -Body $body

Write-Host "`nSummary:"
Write-Host "  Succeeded: $($resp.summary.succeeded)"
Write-Host "  Failed: $($resp.summary.failed)"
Write-Host "  In Progress: $($resp.summary.inProgress)"

Write-Host "`nDetails:"
foreach ($vm in $resp.results) {
    if ($vm.status -eq 'SUCCEEDED') {
        Write-Host "  $($vm.vmName): SUCCEEDED" -ForegroundColor Green
    } elseif ($vm.status -eq 'FAILED') {
        Write-Host "  $($vm.vmName): FAILED at $($vm.failedStage)" -ForegroundColor Red
    } else {
        Write-Host "  $($vm.vmName): $($vm.status)"
    }
}
```

---

## Local Development

1. Install [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite) for local storage emulation.
2. Copy `DRReplication/local.settings.json` and fill in real values for `CSV_STORAGE_CONNECTION__blobServiceUri` pointing to your dev config storage account (the function uses managed identity even locally if you are logged in with `az login`).
3. Run:
   ```powershell
   cd DRReplication
   func start
   ```
4. Post a test request:
   ```powershell
   Invoke-RestMethod -Uri "http://localhost:7071/api/Invoke-DRReplication" `
     -Method POST -ContentType "application/json" `
     -Body '{"csvBlobPath":"configurations/test.csv"}'
   ```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Function crashes on startup | `managedDependency.enabled: true` in host.json | Set to `false`; run `setup-modules.ps1` to bundle modules |
| `LinkedAuthorizationFailed` / `Microsoft.Compute/disks/beginGetAccess/action` | Managed identity has only Reader on source | Grant **Disk Backup Reader** on source subscription — see RBAC section |
| `AuthorizationFailed` | Managed identity lacks RBAC on source/target resource | Grant Disk Backup Reader (source) and Contributor (target) — see RBAC section |
| `Subscription 'X' not found` | MI cannot see the subscription | Add MI as Reader at subscription scope |
| `Could not determine source load balancer name` | Source NIC has no LB backend pool associations | Ensure source NIC is attached to an LB backend pool |
| LB not found in target RG | LB name or RG suffix mismatch | Check `TARGET_LB_NAME_SUFFIX` and `TARGET_LB_RG_SUFFIX` |
| VNet/subnet not found | Target VNet suffix mismatch | Check `TARGET_VNET_NAME_SUFFIX` and `TARGET_VNET_RG_SUFFIX` |
| DES not found | Target DES suffix mismatch | Check `TARGET_DES_NAME_SUFFIX` and `TARGET_DES_RG_SUFFIX` |
| Warning: Target ASG not found | ASG not pre-created in VNet RG | Manually create the ASG in the target VNet resource group before replication. NIC will be created without ASG binding if missing. |
| Source VM has no load balancer | Expected if VM is not load-balanced | Normal operation. Stage E (LB attachment) is automatically skipped. |
| Source VM has no ASGs | Expected if VM doesn't use ASGs | Normal operation. ASG resolution is automatically skipped. |
| `429 / TooManyRequests` | Azure API throttling | Reduce `VM_PARALLEL_THROTTLE` and `PARALLEL_THROTTLE` |
| Blob log not uploaded | Config storage RBAC missing | Ensure MI has `Storage Blob Data Contributor` on `stcfg…` |
| `func azure functionapp publish` returns 403 | Publishing identity issue | Log in with `az login` and retry; or use `func azure functionapp publish --force` |
