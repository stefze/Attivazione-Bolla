# Architettura di Rete Sicura

## Panoramica

La soluzione DR Replication implementa un'architettura di rete completamente privata che garantisce che:
- Gli Azure Storage Accounts siano accessibili **solo** tramite connessioni private
- L'Azure Function App comunichi con gli storage tramite Private Endpoints all'interno della VNet
- Tutto il traffico sia isolato dalla rete pubblica

## Componenti di Rete

### 1. Virtual Network (VNet)
- **Nome**: `vnet-bolla-{uniqueId}`
- **Address Space**: `10.0.0.0/24` (256 indirizzi IP)

### 2. Subnet

#### Subnet per VNet Integration
- **Nome**: `snet-vnetintegration`
- **Address Range**: `10.0.0.0/26` (64 indirizzi IP)
- **Scopo**: Connessione della Function App alla VNet
- **Delegazione**: Delegata a `Microsoft.Web/serverFarms` per consentire l'integrazione della Function App

#### Subnet per Private Endpoints
- **Nome**: `snet-privateendpoints`
- **Address Range**: `10.0.0.64/26` (64 indirizzi IP)
- **Scopo**: Hosting dei Private Endpoints per gli storage accounts
- **Configurazione**: `privateEndpointNetworkPolicies` disabilitato

## Private Endpoints

### Storage Account per Function Hosting (`stfn*`)
Quattro Private Endpoints per i diversi servizi di storage:
1. **Blob Service** - Per il deployment package e i log della function
2. **Table Service** - Per lo storage delle tabelle (Function runtime)
3. **Queue Service** - Per le code (Function triggers)
4. **File Service** - Per file shares (se necessario)

### Storage Account per Configurazione (`stcfg*`)
Un Private Endpoint per:
1. **Blob Service** - Per i CSV di configurazione (`dr-configs`) e i log per VM (`dr-logs`)

## Private DNS Zones

Le Private DNS Zones garantiscono che i nomi DNS degli storage accounts vengano risolti agli indirizzi IP privati all'interno della VNet:

| Private DNS Zone | Scopo |
|-----------------|-------|
| `privatelink.blob.core.windows.net` | Risoluzione DNS per Blob Service |
| `privatelink.table.core.windows.net` | Risoluzione DNS per Table Service |
| `privatelink.queue.core.windows.net` | Risoluzione DNS per Queue Service |
| `privatelink.file.core.windows.net` | Risoluzione DNS per File Service |

Ogni zona DNS è collegata alla VNet e i Private Endpoints sono associati alle zone DNS tramite **DNS Zone Groups**.

## Sicurezza di Rete

### Restrizioni Storage Account
Entrambi gli storage accounts sono configurati con:
- **Public Network Access**: `Disabled`
- **Network ACLs**: `defaultAction: Deny`
- **Bypass**: `None` (nessuna eccezione per servizi Azure trusted)
- **Allow Shared Key Access**: `false` (solo autenticazione con Managed Identity)

Questo significa che:
- ✅ L'accesso è consentito **solo** tramite Private Endpoints
- ❌ Nessun accesso pubblico da Internet
- ❌ Nessun accesso da altri servizi Azure
- ❌ Nessuna autenticazione con chiavi di accesso

### VNet Integration della Function App
La Function App è configurata con:
- **VNet Integration**: Collegata alla subnet `snet-vnetintegration`
- **Route All Enabled**: `true` - Tutto il traffico in uscita passa attraverso la VNet
- **VNet Content Share Enabled**: `false` - Non necessario per FC1

## Flusso di Traffico

```
┌─────────────────────────────────────────────────────────────┐
│                      Internet / Client                       │
└───────────────────────────────┬─────────────────────────────┘
                                │ HTTPS
                                │ (Public Access Only for Function Invocation)
                                ▼
                    ┌───────────────────────────┐
                    │   Azure Function App      │
                    │   (System-Assigned MI)    │
                    └───────────┬───────────────┘
                                │
                                │ VNet Integration
                                │
            ┌───────────────────▼───────────────────────────┐
            │           Virtual Network (10.0.0.0/24)        │
            │                                                 │
            │  ┌────────────────────────────────────────┐   │
            │  │ snet-vnetintegration (10.0.0.0/26)     │   │
            │  │ • Function App Integrated              │   │
            │  │ • All outbound traffic routes here     │   │
            │  └────────────────────────────────────────┘   │
            │                                                 │
            │                    │                            │
            │                    │ Private Connection         │
            │                    │                            │
            │  ┌────────────────▼───────────────────────┐   │
            │  │ snet-privateendpoints (10.0.0.64/26)   │   │
            │  │                                         │   │
            │  │  • PE: stfn-blob                       │   │
            │  │  • PE: stfn-table                      │   │
            │  │  • PE: stfn-queue                      │   │
            │  │  • PE: stfn-file                       │   │
            │  │  • PE: stcfg-blob                      │   │
            │  │                                         │   │
            │  └─────────────────────────────────────────┘  │
            │                                                 │
            └─────────────────────────────────────────────────┘
                                │
                                │ Private Link
                                │
        ┌───────────────────────┴──────────────────────┐
        │                                               │
        ▼                                               ▼
┌──────────────────┐                    ┌──────────────────────┐
│ Storage Account  │                    │  Storage Account     │
│ stfn* (hosting)  │                    │  stcfg* (config)     │
│                  │                    │                      │
│ • Blob           │                    │  • Blob (dr-configs) │
│ • Table          │                    │  • Blob (dr-logs)    │
│ • Queue          │                    │                      │
│ • File           │                    │                      │
│                  │                    │                      │
│ Public Access:   │                    │  Public Access:      │
│ ❌ DISABLED      │                    │  ❌ DISABLED         │
└──────────────────┘                    └──────────────────────┘
```

## Vantaggi di Sicurezza

1. **Isolamento Completo**: Gli storage accounts non sono esposti a Internet
2. **Zero Trust**: Solo la Function App con Managed Identity può accedere agli storage
3. **Crittografia in Transito**: Tutto il traffico rimane all'interno della rete Azure
4. **Compliance**: Soddisfa requisiti stringenti per la protezione dei dati
5. **Audit Trail**: Tutti gli accessi sono tracciabili tramite Managed Identity

## Considerazioni per il Deployment

### Prima del Deployment
- La configurazione di Private Endpoints richiede qualche minuto per la propagazione DNS
- Durante il primo deployment, potrebbero verificarsi timeout - è normale

### Accesso Locale per Sviluppo
Per accedere agli storage accounts dal proprio computer locale durante lo sviluppo:

1. **Opzione 1**: Aggiungere temporaneamente il proprio IP pubblico alle regole firewall dello storage
```bash
az storage account network-rule add \
  --account-name <STORAGE_ACCOUNT_NAME> \
  --ip-address <YOUR_PUBLIC_IP>
```

2. **Opzione 2**: Usare Azure Bastion o una Jump Box all'interno della VNet

3. **Opzione 3**: Configurare una connessione VPN Site-to-Site o Point-to-Site verso la VNet

### Troubleshooting

**Problema**: La Function App non riesce ad accedere agli storage
- **Verifica**: I Private Endpoints sono stati creati correttamente
- **Verifica**: Le Private DNS Zones sono collegate alla VNet
- **Verifica**: La VNet Integration della Function App è attiva
- **Soluzione**: Riavviare la Function App dopo il deployment iniziale

**Problema**: Impossibile caricare file sugli storage accounts da locale
- **Causa**: Gli storage hanno `publicNetworkAccess: Disabled`
- **Soluzione**: Usare una delle opzioni di accesso locale descritte sopra

## Deployment dell'Infrastruttura di Rete

```powershell
# 1. Provisioning (crea VNet, Private Endpoints, DNS Zones, Storage, Function App)
azd provision --no-prompt

# 2. Attendere qualche minuto per la propagazione DNS
Start-Sleep -Seconds 120

# 3. Deploy del codice della function
cd DRReplication
func azure functionapp publish func-bolla-<uniqueId> --powershell
```

## Monitoraggio

Verificare la connettività privata:

```powershell
# Verificare i Private Endpoints
az network private-endpoint list \
  --resource-group rg-bolla-dr-prod \
  --query "[].{Name:name, Status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" \
  --output table

# Verificare le regole di rete dello storage
az storage account show \
  --name <STORAGE_ACCOUNT_NAME> \
  --query "{PublicAccess:publicNetworkAccess, DefaultAction:networkAcls.defaultAction}" \
  --output table
```

## Riferimenti

- [Azure Private Endpoints](https://learn.microsoft.com/azure/private-link/private-endpoint-overview)
- [VNet Integration per Function Apps](https://learn.microsoft.com/azure/azure-functions/functions-networking-options)
- [Private DNS Zones](https://learn.microsoft.com/azure/dns/private-dns-overview)
- [Storage Account Network Security](https://learn.microsoft.com/azure/storage/common/storage-network-security)
