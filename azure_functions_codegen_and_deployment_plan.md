# Azure Function: DR VM Replication — Deployment Plan

## Status: DRAFT — Awaiting user confirmation

---

## 1. Overview

Convert `Cluster-Bolla_v1.ps1` into an Azure Functions app that reads a CSV from
Azure Blob Storage and replicates multiple VMs to a DR subscription in parallel.

---

## 2. Architecture

| Property | Value |
|----------|-------|
| Runtime | PowerShell 7.4 |
| Hosting Plan | Flex Consumption (FC1) — Linux |
| Trigger | **Single HTTP POST** (function-level auth key) |
| Authentication | System-Assigned Managed Identity |
| Module delivery | `requirements.psd1` managed dependencies (fallback: `setup-modules.ps1`) |

---

## 3. Trigger — HTTP POST

**URL**: `https://<function-app>.azurewebsites.net/api/Invoke-DRReplication?code=<key>`

**Request body (JSON):**
```json
{
  "csvBlobPath": "configurations/production-config.csv",
  "vmParallelThrottle": 3
}
```

| Field | Required | Default | Constraint |
|-------|----------|---------|-----------|
| `csvBlobPath` | Yes | — | Path inside the configured container |
| `vmParallelThrottle` | No | `1` (or `VM_PARALLEL_THROTTLE` env) | 1–10 |

---

## 4. CSV Input Format

Three columns only (auto-derives everything else):

```csv
SourceSubscription,SourceResourceGroup,SourceVmName
Identity,rg-wsfc-2node,vm-node1
Identity,rg-wsfc-2node,vm-node2
Identity,rg-app-servers,vm-app1
```

The `SourceVmName` column is used **directly** — no lowest-suffix auto-discovery.

---

## 5. Target Name Auto-Derivation (all via `-DR` suffix)

| Resource | Derivation |
|----------|-----------|
| Target Subscription | `{SourceSubscription}-DR` |
| Target VM & Snapshot/Disk RG | `{SourceResourceGroup}-DR` |
| Target VNet name | `{DiscoveredSourceVNetName}-DR` |
| Target VNet RG | `{DiscoveredSourceVNetRG}-DR` |
| Disk Encryption Set name | `{DiscoveredSourceDESName}-DR` |
| Disk Encryption Set RG | `{DiscoveredSourceDESRG}-DR` |
| Target Load Balancer RG | `{DiscoveredSourceLBRG}-DR` |

VNet, DES, and LB details are discovered at runtime from the source VM's NIC and disk
configurations (same as original script logic).

---

## 6. Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CSV_STORAGE_CONNECTION__blobServiceUri` | (required) | Managed-identity blob endpoint, e.g. `https://stdrconfig.blob.core.windows.net` |
| `CSV_CONTAINER_NAME` | `dr-configs` | Blob container name |
| `VM_PARALLEL_THROTTLE` | `1` | Default VM-level parallelism (overridden by body) |
| `PARALLEL_THROTTLE` | `6` | Max parallel **disk** ops per VM (1–64) |
| `TAG_PREFIX` | `DR-` | Prefix applied to replicated VM tags |
| `SNAPSHOT_NAME_PREFIX` | `snap-` | Prefix for snapshot names |
| `BACKEND_POOL_NAME_OVERRIDE` | `` | Override LB backend pool name (empty = auto-select) |

---

## 7. File Structure

```
c:\LocalRepo\Attivazione-Bolla-Function\
├── Cluster-Bolla_v1.ps1              (existing — kept for reference)
├── csv-schema.md                      (existing — kept for reference)
├── azure.yaml                         (azd project file)
├── setup-modules.ps1                  (pre-bundle Az modules for FC1/Linux fallback)
│
├── DRReplication/                     ← Function App root
│   ├── host.json
│   ├── local.settings.json
│   ├── profile.ps1                    (module import + managed identity auth)
│   ├── requirements.psd1              (managed dependency declarations)
│   │
│   ├── Modules/
│   │   └── DRCore/
│   │       └── DRCore.psm1            (core replication logic, all stages A–E)
│   │
│   └── Invoke-DRReplication/          (single HTTP trigger function)
│       ├── function.json
│       └── run.ps1
│
└── infra/
    ├── main.bicep                     (Flex Consumption plan, storage, AI, RBAC)
    └── main.parameters.json
```

---

## 8. Parallelism Design

```
run.ps1
  └─ ForEach-Object -Parallel -ThrottleLimit $vmParallelThrottle
       (one runspace per VM row)
       ├── Import-Module DRCore + Connect-AzAccount -Identity
       └── Invoke-VMReplication
             Stage A  — single-threaded: discover source VM config
             Stage B  — ForEach-Object -Parallel -ThrottleLimit $PARALLEL_THROTTLE
                        (snapshot creation per disk)
             Stage C  — single-threaded: create managed disks from snapshots
             Stage D  — single-threaded: create NIC + VM
             Stage E  — single-threaded: attach NIC to LB backend pool
```

Configurable parameters:
- **VM parallelism**: 1–10 (HTTP body or `VM_PARALLEL_THROTTLE` env var)
- **Disk parallelism**: 1–64 (`PARALLEL_THROTTLE` env var, default 6)

---

## 9. Core Replication Logic (DRCore.psm1)

Adapted from `Cluster-Bolla_v1.ps1` with these changes:

| Original behaviour | New behaviour |
|-------------------|---------------|
| Auto-discovers lowest-suffix VM in RG | Uses `SourceVmName` directly from CSV |
| All target names passed as explicit params | All target names derived with `-DR` suffix |
| Single VM per script invocation | Exported `Invoke-VMReplication` function, callable from parallel |
| Persists JSON config to local file | Returns result object (no file I/O) |
| `Connect-AzAccount -AllowInteractiveLogin` | `Connect-AzAccount -Identity` (managed identity) |

All helper functions retained: `Invoke-WithRetry`, `Write-Log`, `Get-RbacHint`,
`Select-TargetBackendPool`, `Build-TargetTags`, `Ensure-ResourceGroup`, etc.

---

## 10. Infrastructure (infra/main.bicep — AVM-based)

| Resource | Config |
|----------|--------|
| `Microsoft.Web/serverfarms` | FC1 / FlexConsumption / Linux / `reserved: true` |
| `Microsoft.Web/sites` | PowerShell 7.4, system-assigned MI, functionAppConfig with blob deployment storage |
| Storage Account (function) | LRS, used for FC1 deployment package container |
| Storage Account (CSV configs) | LRS, blob container `dr-configs` pre-created |
| Application Insights + Log Analytics | Standard telemetry |
| Role assignment | `Storage Blob Data Reader` on the CSV storage account for the function's managed identity |

> **Note on RBAC for Azure resources:** The managed identity also needs
> `Reader` on source subscriptions and `Contributor` (or scoped roles) on
> target subscriptions/RGs to perform VM replication. These subscriptions are
> customer-owned and cannot be auto-assigned; they must be configured
> manually after deployment.

---

## 11. Managed Dependencies Note

`requirements.psd1` (managed dependencies) is the primary module delivery method
and works on most Azure Functions runtimes.

> ⚠️ **Flex Consumption (Linux)**: If managed dependencies fail at cold start,
> disable them in `host.json` and run `setup-modules.ps1` locally to pre-bundle
> Az modules into `DRReplication/Modules/`. The `setup-modules.ps1` script
> calls `Save-Module` for all required Az modules.

---

## 12. Deployment

```bash
# 1. Login and set environment
azd auth login
azd env new dr-replication-prod

# 2. Deploy infrastructure + function code
azd up

# 3. Post-deployment: manually grant Managed Identity RBAC on source/target subscriptions
```

---

## 13. HTTP Response Format

```json
{
  "startedAt": "2026-05-14T10:00:00Z",
  "completedAt": "2026-05-14T10:45:00Z",
  "vmParallelThrottle": 3,
  "totalVms": 4,
  "succeeded": 3,
  "failed": 1,
  "results": [
    {
      "sourceVmName": "vm-node1",
      "targetVmName": "vm-node1",
      "status": "Succeeded",
      "summary": { ... }
    },
    {
      "sourceVmName": "vm-app1",
      "targetVmName": "vm-app1",
      "status": "Failed",
      "error": "Stage B failed. ..."
    }
  ]
}
```

Failed VMs do not abort the overall run — all rows are attempted.

---

## 14. Decisions Requiring User Input

1. **Azure region** for the function app infrastructure (e.g. `westeurope`)?
2. **CSV storage account** — should the infra create a new one, or point to an existing one?
3. **Function app name prefix** — used to generate unique resource names.
