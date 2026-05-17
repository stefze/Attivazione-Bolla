[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SourceSubscription = "Identity",

    [Parameter(Mandatory = $false)]
    [string]$TargetSubscription = "connectivity",

    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroup = "rg-wsfc-2node",

    [Parameter(Mandatory = $false)]
    [string]$TargetSnapshotDiskResourceGroup = "rg-wsfc-2node-dr",

    [Parameter(Mandatory = $false)]
    [string]$TargetVmResourceGroup = "rg-wsfc-2node-dr",

    [Parameter(Mandatory = $false)]
    [string]$DiskEncryptionSetName = "desrrd",

    [Parameter(Mandatory = $false)]
    [string]$DiskEncryptionSetResourceGroup = "rg-infra-dr",

    [Parameter(Mandatory = $false)]
    [string]$TargetVnetName = "vnet-infra",

    [Parameter(Mandatory = $false)]
    [string]$TargetVnetResourceGroup = "rg-infra-dr",

    [Parameter(Mandatory = $false)]
    [string]$TargetLoadBalancerResourceGroup = "rg-wsfc-2node-dr",

    [Parameter(Mandatory = $false)]
    [string]$SnapshotNamePrefix = "snap-",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 64)]
    [int]$ParallelThrottle = 6,

    [Parameter(Mandatory = $false)]
    [string]$TargetVmName,

    [Parameter(Mandatory = $false)]
    [string]$BackendPoolNameOverride,

    [Parameter(Mandatory = $false)]
    [string]$TagPrefix = "",

    [Parameter(Mandatory = $false)]
    [hashtable]$AdditionalTags = @{},

    [Parameter(Mandatory = $false)]
    [string]$PersistConfigPath = ".\source-vm-config.auto.json",

    [Parameter(Mandatory = $false)]
    [switch]$AllowInteractiveLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Summary = [ordered]@{
    SourceVmName             = $null
    TargetVmName             = $null
    SnapshotsCreated         = [System.Collections.Generic.List[string]]::new()
    SnapshotsReused          = [System.Collections.Generic.List[string]]::new()
    DisksCreated             = [System.Collections.Generic.List[string]]::new()
    DisksReused              = [System.Collections.Generic.List[string]]::new()
    NicsCreated              = [System.Collections.Generic.List[string]]::new()
    NicsReused               = [System.Collections.Generic.List[string]]::new()
    VmsCreated               = [System.Collections.Generic.List[string]]::new()
    VmsReused                = [System.Collections.Generic.List[string]]::new()
    BackendPoolAttached      = [System.Collections.Generic.List[string]]::new()
    BackendPoolAlreadyMember = [System.Collections.Generic.List[string]]::new()
    ConfigFilePath           = $PersistConfigPath
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffK"
    Write-Host "$ts [$Level] $Message"
}

function Add-SummaryItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Bucket,
        [Parameter(Mandatory = $true)]
        [string]$Item
    )
    if (-not $script:Summary.Contains($Bucket)) {
        return
    }
    if (-not $script:Summary[$Bucket].Contains($Item)) {
        [void]$script:Summary[$Bucket].Add($Item)
    }
}

function Normalize-Text {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return $Value.Trim().ToLowerInvariant()
}

function Compare-StringArray {
    param(
        [AllowNull()][string[]]$A,
        [AllowNull()][string[]]$B
    )
    $aNorm = @($A | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
    $bNorm = @($B | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)

    if ($aNorm.Count -ne $bNorm.Count) { return $false }
    for ($i = 0; $i -lt $aNorm.Count; $i++) {
        if ($aNorm[$i] -ne $bNorm[$i]) { return $false }
    }
    return $true
}

function Compare-Hashtable {
    param(
        [AllowNull()][hashtable]$A,
        [AllowNull()][hashtable]$B
    )
    if ($null -eq $A) { $A = @{} }
    if ($null -eq $B) { $B = @{} }

    if ($A.Count -ne $B.Count) { return $false }

    foreach ($k in $A.Keys) {
        if (-not $B.ContainsKey($k)) { return $false }
        if ([string]$A[$k] -ne [string]$B[$k]) { return $false }
    }
    return $true
}

function Get-RbacHint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )
    $msg = $Exception.Message
    if ($msg -match "AuthorizationFailed|Forbidden|does not have authorization|insufficient privileges|Access denied") {
        return "RBAC hint: Ensure Source Reader access on source RG/subscription, Contributor or Disk Snapshot Contributor + Disk Contributor on target snapshot/disk RG, Reader on DES RG, Network Contributor on target VNet/NIC/LB RGs, and Virtual Machine Contributor on target VM RG."
    }
    return $null
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [int]$MaxAttempts = 5,

        [int]$InitialDelaySeconds = 2
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $isRetryable = $_.Exception.Message -match "429|TooManyRequests|temporar|timeout|throttl|InternalServerError|Conflict|Gateway|BadRequest"
            if ($attempt -ge $MaxAttempts -or -not $isRetryable) {
                throw "Operation failed: $Operation. Attempt: $attempt. Error: $($_.Exception.Message)"
            }

            $delay = [Math]::Min(30, [int]($InitialDelaySeconds * [Math]::Pow(2, ($attempt - 1))))
            Write-Log "Transient failure in '$Operation'. Retrying in $delay seconds (attempt $attempt/$MaxAttempts)." "WARN"
            Start-Sleep -Seconds $delay
        }
    }
}

function Resolve-Subscription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionIdentifier
    )
    $subs = Invoke-WithRetry -Operation "Get subscriptions" -ScriptBlock { Get-AzSubscription }
    $sub = $subs | Where-Object { $_.Id -eq $SubscriptionIdentifier -or $_.Name -eq $SubscriptionIdentifier } | Select-Object -First 1
    if (-not $sub) {
        throw "Subscription '$SubscriptionIdentifier' not found."
    }
    return $sub
}

function Set-SubscriptionContextSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$FriendlyName
    )
    Invoke-WithRetry -Operation "Set context to $FriendlyName ($SubscriptionId)" -ScriptBlock {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    } | Out-Null
}

function Get-IdSegmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,
        [Parameter(Mandatory = $true)]
        [string]$SegmentName
    )
    $parts = $ResourceId.Trim("/") -split "/"
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        if ($parts[$i].Equals($SegmentName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $parts[$i + 1]
        }
    }
    return $null
}

function Get-LastResourceNameFromId {
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    return ($ResourceId.TrimEnd("/") -split "/")[-1]
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $PropertyName) {
        return $Object.$PropertyName
    }
    return $null
}

function Ensure-ResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Location
    )
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $rg) {
        Write-Log "Resource group '$Name' not found. Creating in location '$Location'."
        $rg = Invoke-WithRetry -Operation "Create resource group $Name" -ScriptBlock {
            New-AzResourceGroup -Name $Name -Location $Location -ErrorAction Stop
        }
    }
    return $rg
}

function Build-TargetTags {
    param(
        [AllowNull()][hashtable]$SourceTags,
        [string]$Prefix,
        [AllowNull()][hashtable]$ExtraTags
    )
    $out = @{}
    if ($SourceTags) {
        foreach ($k in $SourceTags.Keys) {
            $newKey = if ([string]::IsNullOrEmpty($Prefix)) { $k } else { "$Prefix$k" }
            $out[$newKey] = [string]$SourceTags[$k]
        }
    }
    if ($ExtraTags) {
        foreach ($k in $ExtraTags.Keys) {
            $out[$k] = [string]$ExtraTags[$k]
        }
    }
    return $out
}

function Select-TargetBackendPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$LoadBalancer,
        [Parameter(Mandatory = $false)]
        [string[]]$SourceBackendPoolNames,
        [Parameter(Mandatory = $false)]
        [string]$PoolNameOverride
    )

    $pools = @($LoadBalancer.BackendAddressPools)
    if ($pools.Count -eq 0) {
        throw "Load balancer '$($LoadBalancer.Name)' has no backend pools."
    }

    if (-not [string]::IsNullOrWhiteSpace($PoolNameOverride)) {
        $match = $pools | Where-Object { $_.Name -eq $PoolNameOverride } | Select-Object -First 1
        if (-not $match) {
            throw "Backend pool override '$PoolNameOverride' not found. Available pools: $($pools.Name -join ', ')."
        }
        return $match
    }

    if ($SourceBackendPoolNames -and $SourceBackendPoolNames.Count -gt 0) {
        $nameMatches = @()
        foreach ($name in $SourceBackendPoolNames) {
            $matched = $pools | Where-Object { $_.Name -eq $name }
            if ($matched) { $nameMatches += $matched }
        }
        if ($nameMatches.Count -eq 1) {
            return $nameMatches[0]
        }
        if ($nameMatches.Count -gt 1) {
            throw "Ambiguous backend pool selection by source membership. Matches: $($nameMatches.Name -join ', ')."
        }
    }

    if ($pools.Count -eq 1) {
        return $pools[0]
    }

    $strictNamed = @($pools | Where-Object { $_.Name -match "^(?i)(bepool|backendpool)$" })
    if ($strictNamed.Count -eq 1) {
        return $strictNamed[0]
    }
    if ($strictNamed.Count -gt 1) {
        throw "Ambiguous backend pool selection (strict name match). Matches: $($strictNamed.Name -join ', ')."
    }

    $containsNamed = @($pools | Where-Object { $_.Name -match "(?i)(bepool|backendpool)" })
    if ($containsNamed.Count -eq 1) {
        return $containsNamed[0]
    }
    if ($containsNamed.Count -gt 1) {
        throw "Ambiguous backend pool selection (contains name match). Matches: $($containsNamed.Name -join ', ')."
    }

    throw "Unable to select backend pool automatically. Available pools: $($pools.Name -join ', '). Provide -BackendPoolNameOverride."
}

Write-Log "Starting DR replication workflow."

# Preflight checks
try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7+ is required. Detected: $($PSVersionTable.PSVersion)."
    }

    $requiredModules = @("Az.Accounts", "Az.Resources", "Az.Compute", "Az.Network")
    foreach ($m in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw "Required module '$m' is not installed. Install with: Install-Module Az -Scope CurrentUser"
        }
    }

    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
    Import-Module Az.Compute -ErrorAction Stop
    Import-Module Az.Network -ErrorAction Stop

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx) {
        if ($AllowInteractiveLogin.IsPresent) {
            Write-Log "No Azure session found. Attempting Connect-AzAccount."
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        else {
            throw "No Azure session found. Run Connect-AzAccount before execution, or pass -AllowInteractiveLogin."
        }
    }

    Enable-AzContextAutosave -Scope CurrentUser -ErrorAction Stop | Out-Null
    Write-Log "Preflight checks passed."
}
catch {
    $hint = Get-RbacHint -Exception $_.Exception
    if ($hint) { Write-Log $hint "WARN" }
    throw
}

$sourceSub = $null
$targetSub = $null

$sourceVm = $null
$sourceNic = $null
$sourceIpConfig = $null
$sourceBackendPoolNames = @()
$sourceBackendPoolIds = @()
$sourceLoadBalancerName = $null
$diskInfos = @()
$targetVmTags = @{}
$targetLocation = $null
$targetVmNameFinal = $null
$targetSubnetName = $null
$targetSubnet = $null
$des = $null
$snapshotByDiskName = @{}
$targetDisksByName = @{}
$targetNic = $null

# Resolve subscriptions once
try {
    $sourceSub = Resolve-Subscription -SubscriptionIdentifier $SourceSubscription
    $targetSub = Resolve-Subscription -SubscriptionIdentifier $TargetSubscription
    Write-Log "Resolved source subscription '$($sourceSub.Name)' ($($sourceSub.Id))."
    Write-Log "Resolved target subscription '$($targetSub.Name)' ($($targetSub.Id))."
}
catch {
    throw "Subscription resolution failed. $($_.Exception.Message)"
}

# Stage A: Identify lowest suffix source VM and capture config
try {
    Write-Log "Stage A: Identifying source VM in '$SourceResourceGroup' with the lowest numeric suffix."
    Set-SubscriptionContextSafe -SubscriptionId $sourceSub.Id -FriendlyName $sourceSub.Name

    $sourceRgObj = Get-AzResourceGroup -Name $SourceResourceGroup -ErrorAction Stop
    $allVmsInRg = Invoke-WithRetry -Operation "List VMs in $SourceResourceGroup" -ScriptBlock {
        Get-AzVM -ResourceGroupName $SourceResourceGroup -ErrorAction Stop
    }

    $vmSuffixPattern = '-(?:n)?(?<Suffix>\d+)$'

    $vmCandidates = foreach ($vm in $allVmsInRg) {
        if ($vm.Name -match $vmSuffixPattern) {
            [pscustomobject]@{
                Vm     = $vm
                Name   = $vm.Name
                Suffix = [int]$Matches["Suffix"]
            }
        }
    }

    if (-not $vmCandidates -or $vmCandidates.Count -eq 0) {
        throw "No VM names in '$SourceResourceGroup' matched the required '-<number>' or '-n<number>' suffix pattern."
    }

    $selected = $vmCandidates | Sort-Object Suffix, Name | Select-Object -First 1
    $sourceVm = Invoke-WithRetry -Operation "Get source VM details for $($selected.Name)" -ScriptBlock {
        Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $selected.Name -ErrorAction Stop
    }

    $script:Summary.SourceVmName = $sourceVm.Name
    if ((Normalize-Text $PersistConfigPath) -eq (Normalize-Text ".\source-vm-config.auto.json")) {
        $PersistConfigPath = ".\source-vm-config-$($sourceVm.Name).json"
        $script:Summary.ConfigFilePath = $PersistConfigPath
        Write-Log "PersistConfigPath auto-resolved to '$PersistConfigPath'."
    }
    Write-Log "Selected source VM '$($sourceVm.Name)' with lowest suffix '$($selected.Suffix)'."    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...    # ...existing code...
    function Get-OptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Object,
            [Parameter(Mandatory = $true)]
            [string]$PropertyName
        )
        if ($null -eq $Object) { return $null }
        if ($Object.PSObject.Properties.Name -contains $PropertyName) {
            return $Object.$PropertyName
        }
        return $null
    }
    # ...existing code...

    # Primary NIC
    $nicRef = $sourceVm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary } | Select-Object -First 1
    if ($null -eq $nicRef) {
        $nicRef = $sourceVm.NetworkProfile.NetworkInterfaces | Select-Object -First 1
    }
    if ($null -eq $nicRef) {
        throw "Source VM '$($sourceVm.Name)' has no network interfaces."
    }

    $sourceNicRg = Get-IdSegmentValue -ResourceId $nicRef.Id -SegmentName "resourceGroups"
    $sourceNicName = Get-LastResourceNameFromId -ResourceId $nicRef.Id

    $sourceNic = Invoke-WithRetry -Operation "Get source NIC $sourceNicName" -ScriptBlock {
        Get-AzNetworkInterface -ResourceGroupName $sourceNicRg -Name $sourceNicName -ErrorAction Stop
    }

    $sourceIpConfig = $sourceNic.IpConfigurations | Where-Object { $_.Primary } | Select-Object -First 1
    if ($null -eq $sourceIpConfig) {
        $sourceIpConfig = $sourceNic.IpConfigurations | Select-Object -First 1
    }
    if ($null -eq $sourceIpConfig) {
        throw "Source NIC '$($sourceNic.Name)' has no IP configurations."
    }

    $sourceSubnetId = $sourceIpConfig.Subnet.Id
    $targetSubnetName = Get-IdSegmentValue -ResourceId $sourceSubnetId -SegmentName "subnets"

    if ([string]::IsNullOrWhiteSpace($targetSubnetName)) {
        throw "Could not determine source subnet name from source NIC IP configuration."
    }

    $sourceBackendPoolNames = @()
    $sourceBackendPoolIds = @()
    if ($sourceIpConfig.LoadBalancerBackendAddressPools) {
        $sourceBackendPoolIds = @(
            $sourceIpConfig.LoadBalancerBackendAddressPools |
            ForEach-Object { [string]$_.Id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $sourceBackendPoolNames = @(
            $sourceBackendPoolIds |
            ForEach-Object { Get-LastResourceNameFromId -ResourceId $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $sourceLoadBalancerNames = @(
            $sourceBackendPoolIds |
            ForEach-Object { Get-IdSegmentValue -ResourceId $_ -SegmentName "loadBalancers" } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
        )

        if ($sourceLoadBalancerNames.Count -gt 1) {
            throw "Source NIC is attached to backend pools from multiple load balancers: $($sourceLoadBalancerNames -join ', ')."
        }
        if ($sourceLoadBalancerNames.Count -eq 1) {
            $sourceLoadBalancerName = [string]$sourceLoadBalancerNames[0]
        }
    }

    if ([string]::IsNullOrWhiteSpace($sourceLoadBalancerName)) {
        throw "Could not determine source load balancer name from source NIC backend pool IDs."
    }

    # Disk capture
    $vmDiskControllerType = Get-OptionalPropertyValue -Object $sourceVm.StorageProfile -PropertyName "DiskControllerType"

    $diskList = [System.Collections.Generic.List[object]]::new()

    $osAttach = $sourceVm.StorageProfile.OsDisk
    if ($null -eq $osAttach -or $null -eq $osAttach.ManagedDisk -or [string]::IsNullOrWhiteSpace($osAttach.ManagedDisk.Id)) {
        throw "Source VM '$($sourceVm.Name)' OS disk is not a managed disk."
    }

    $osDiskId = $osAttach.ManagedDisk.Id
    $osDiskRg = Get-IdSegmentValue -ResourceId $osDiskId -SegmentName "resourceGroups"
    $osDiskName = Get-LastResourceNameFromId -ResourceId $osDiskId
    $osDisk = Invoke-WithRetry -Operation "Get OS disk $osDiskName" -ScriptBlock {
        Get-AzDisk -ResourceGroupName $osDiskRg -DiskName $osDiskName -ErrorAction Stop
    }

    $osSharingProfile = Get-OptionalPropertyValue -Object $osDisk -PropertyName "SharingProfile"
    $osOptimizedForFrequentAttach = Get-OptionalPropertyValue -Object $osSharingProfile -PropertyName "OptimizedForFrequentAttach"

    [void]$diskList.Add([pscustomobject]@{
        Name                       = $osDisk.Name
        SourceDiskId               = $osDisk.Id
        Role                       = "OS"
        Lun                        = $null
        Caching                    = [string]$osAttach.Caching
        SkuName                    = [string]$osDisk.Sku.Name
        Tier                       = [string](Get-OptionalPropertyValue -Object $osDisk -PropertyName "Tier")
        Zones                      = @($osDisk.Zones)
        MaxShares                  = [int](Get-OptionalPropertyValue -Object $osDisk -PropertyName "MaxShares")
        SharingProfile             = $osSharingProfile
        OptimizedForFrequentAttach = $osOptimizedForFrequentAttach
        EncryptionType             = [string](Get-OptionalPropertyValue -Object $osDisk.Encryption -PropertyName "Type")
        DiskEncryptionSetId        = [string](Get-OptionalPropertyValue -Object $osDisk.Encryption -PropertyName "DiskEncryptionSetId")
        SecureVMDiskEncryptionSetId = [string](Get-OptionalPropertyValue -Object $osDisk.Encryption -PropertyName "SecureVMDiskEncryptionSetId")
        DiskControllerType         = $vmDiskControllerType
        OsType                     = [string]$osAttach.OsType
        HyperVGeneration           = [string](Get-OptionalPropertyValue -Object $osDisk -PropertyName "HyperVGeneration")
        SourceSnapshotName         = "$SnapshotNamePrefix$($osDisk.Name)"
    })

    $dataAttachDisks = @($sourceVm.StorageProfile.DataDisks | Sort-Object LUN)
    foreach ($dAttach in $dataAttachDisks) {
        if ($null -eq $dAttach.ManagedDisk -or [string]::IsNullOrWhiteSpace($dAttach.ManagedDisk.Id)) {
            throw "Data disk '$($dAttach.Name)' on source VM is not a managed disk."
        }

        $dId = $dAttach.ManagedDisk.Id
        $dRg = Get-IdSegmentValue -ResourceId $dId -SegmentName "resourceGroups"
        $dName = Get-LastResourceNameFromId -ResourceId $dId
        $dDisk = Invoke-WithRetry -Operation "Get data disk $dName" -ScriptBlock {
            Get-AzDisk -ResourceGroupName $dRg -DiskName $dName -ErrorAction Stop
        }

        $dSharingProfile = Get-OptionalPropertyValue -Object $dDisk -PropertyName "SharingProfile"
        $dOptimizedForFrequentAttach = Get-OptionalPropertyValue -Object $dSharingProfile -PropertyName "OptimizedForFrequentAttach"

        [void]$diskList.Add([pscustomobject]@{
            Name                       = $dDisk.Name
            SourceDiskId               = $dDisk.Id
            Role                       = "Data"
            Lun                        = [int]$dAttach.Lun
            Caching                    = [string]$dAttach.Caching
            SkuName                    = [string]$dDisk.Sku.Name
            Tier                       = [string](Get-OptionalPropertyValue -Object $dDisk -PropertyName "Tier")
            Zones                      = @($dDisk.Zones)
            MaxShares                  = [int](Get-OptionalPropertyValue -Object $dDisk -PropertyName "MaxShares")
            SharingProfile             = $dSharingProfile
            OptimizedForFrequentAttach = $dOptimizedForFrequentAttach
            EncryptionType             = [string](Get-OptionalPropertyValue -Object $dDisk.Encryption -PropertyName "Type")
            DiskEncryptionSetId        = [string](Get-OptionalPropertyValue -Object $dDisk.Encryption -PropertyName "DiskEncryptionSetId")
            SecureVMDiskEncryptionSetId = [string](Get-OptionalPropertyValue -Object $dDisk.Encryption -PropertyName "SecureVMDiskEncryptionSetId")
            DiskControllerType         = $vmDiskControllerType
            OsType                     = $null
            HyperVGeneration           = [string](Get-OptionalPropertyValue -Object $dDisk -PropertyName "HyperVGeneration")
            SourceSnapshotName         = "$SnapshotNamePrefix$($dDisk.Name)"
        })
    }

    $diskInfos = @($diskList)

    $targetVmTags = Build-TargetTags -SourceTags $sourceVm.Tags -Prefix $TagPrefix -ExtraTags $AdditionalTags

    $sourceConfig = [ordered]@{
        CapturedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        SourceSubscription = @{
            Name = $sourceSub.Name
            Id   = $sourceSub.Id
        }
        SourceResourceGroup = $SourceResourceGroup
        SourceVm = @{
            Name               = $sourceVm.Name
            VmSize             = $sourceVm.HardwareProfile.VmSize
            Location           = $sourceVm.Location
            Tags               = $sourceVm.Tags
            DiskControllerType = $vmDiskControllerType
        }
        Network = @{
            PrimaryNicName            = $sourceNic.Name
            PrimaryNicResourceGroup   = $sourceNic.ResourceGroupName
            IpConfigurationName       = $sourceIpConfig.Name
            VnetName                  = Get-IdSegmentValue -ResourceId $sourceSubnetId -SegmentName "virtualNetworks"
            SubnetName                = $targetSubnetName
            PrivateIpAddress          = $sourceIpConfig.PrivateIpAddress
            PrivateIpAllocationMethod = $sourceIpConfig.PrivateIpAllocationMethod
            SourceLoadBalancerName    = $sourceLoadBalancerName
            BackendPoolIds            = $sourceBackendPoolIds
            BackendPoolNames          = $sourceBackendPoolNames
        }
        Disks = $diskInfos
    }

    $sourceConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $PersistConfigPath -Encoding utf8
    Write-Log "Source configuration persisted to '$PersistConfigPath'."
}
catch {
    $hint = Get-RbacHint -Exception $_.Exception
    if ($hint) { Write-Log $hint "WARN" }
    throw "Stage A failed. $($_.Exception.Message)"
}

# Stage B: Create encrypted snapshots in target DR RG (parallel)
try {
    Write-Log "Stage B: Creating/reusing DES-encrypted snapshots in target subscription."
    Set-SubscriptionContextSafe -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

    $targetVmRgObj = Get-AzResourceGroup -Name $TargetVmResourceGroup -ErrorAction Stop
    $targetLocation = $targetVmRgObj.Location

    Ensure-ResourceGroup -Name $TargetSnapshotDiskResourceGroup -Location $targetLocation | Out-Null

    $des = Invoke-WithRetry -Operation "Get DES $DiskEncryptionSetName" -ScriptBlock {
        Get-AzDiskEncryptionSet -ResourceGroupName $DiskEncryptionSetResourceGroup -Name $DiskEncryptionSetName -ErrorAction Stop
    }

    if ($null -eq $des) {
        throw "Disk Encryption Set '$DiskEncryptionSetName' was not found in '$DiskEncryptionSetResourceGroup' (target subscription)."
    }

    $snapshotResults = $diskInfos | ForEach-Object -ThrottleLimit $ParallelThrottle -Parallel {
        $ErrorActionPreference = "Stop"
        $disk = $_

        function _norm {
            param([string]$v)
            if ([string]::IsNullOrWhiteSpace($v)) { return "" }
            return $v.Trim().ToLowerInvariant()
        }

        function _arrayEq {
            param([string[]]$a, [string[]]$b)
            $na = @($a | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
            $nb = @($b | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
            if ($na.Count -ne $nb.Count) { return $false }
            for ($i = 0; $i -lt $na.Count; $i++) {
                if ($na[$i] -ne $nb[$i]) { return $false }
            }
            return $true
        }

        function _retry {
            param([scriptblock]$sb, [string]$op)
            $attempt = 0
            while ($true) {
                $attempt++
                try {
                    return & $sb
                }
                catch {
                    $retryable = $_.Exception.Message -match "429|TooManyRequests|temporar|timeout|throttl|InternalServerError|Conflict|Gateway|BadRequest"
                    if ($attempt -ge 5 -or -not $retryable) {
                        throw "[$op] failed after $attempt attempts: $($_.Exception.Message)"
                    }
                    $delay = [Math]::Min(30, [int](2 * [Math]::Pow(2, ($attempt - 1))))
                    Start-Sleep -Seconds $delay
                }
            }
        }

        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.Compute -ErrorAction Stop
        Set-AzContext -SubscriptionId $using:targetSub.Id -ErrorAction Stop | Out-Null

        $snapName = "$using:SnapshotNamePrefix$($disk.Name)"

        $existing = Get-AzSnapshot -ResourceGroupName $using:TargetSnapshotDiskResourceGroup -SnapshotName $snapName -ErrorAction SilentlyContinue
        if ($existing) {
            $okSource = (_norm $existing.CreationData.SourceResourceId) -eq (_norm $disk.SourceDiskId)
            $okDes = (_norm $existing.Encryption.DiskEncryptionSetId) -eq (_norm $using:des.Id)
            $okZones = _arrayEq @($existing.Zones) @($disk.Zones)

            if (-not ($okSource -and $okDes -and $okZones)) {
                throw "Snapshot '$snapName' exists but does not match expected config (source disk, DES, or zones)."
            }

            [pscustomobject]@{
                DiskName     = $disk.Name
                SnapshotName = $snapName
                SnapshotId   = $existing.Id
                Status       = "Reused"
            }
            return
        }

        $cfgArgs = @{
            Location            = $using:targetLocation
            CreateOption        = "Copy"
            SourceResourceId    = $disk.SourceDiskId
            DiskEncryptionSetId = $using:des.Id
        }
        if ($disk.Zones -and $disk.Zones.Count -gt 0) {
            $cfgArgs["Zone"] = @($disk.Zones)
        }

        $cfg = _retry -op "New-AzSnapshotConfig $snapName" -sb { New-AzSnapshotConfig @cfgArgs -ErrorAction Stop }
        $newSnap = _retry -op "New-AzSnapshot $snapName" -sb {
            New-AzSnapshot -ResourceGroupName $using:TargetSnapshotDiskResourceGroup -SnapshotName $snapName -Snapshot $cfg -ErrorAction Stop
        }

        [pscustomobject]@{
            DiskName     = $disk.Name
            SnapshotName = $snapName
            SnapshotId   = $newSnap.Id
            Status       = "Created"
        }
    }

    foreach ($r in $snapshotResults) {
        if ($r.Status -eq "Created") {
            Add-SummaryItem -Bucket "SnapshotsCreated" -Item $r.SnapshotName
        }
        else {
            Add-SummaryItem -Bucket "SnapshotsReused" -Item $r.SnapshotName
        }
        $snapshotByDiskName[$r.DiskName] = Invoke-WithRetry -Operation "Get snapshot $($r.SnapshotName)" -ScriptBlock {
            Get-AzSnapshot -ResourceGroupName $TargetSnapshotDiskResourceGroup -SnapshotName $r.SnapshotName -ErrorAction Stop
        }
    }

    Write-Log "Stage B completed. Snapshot operations finished for $($snapshotResults.Count) disk(s)."
}
catch {
    $hint = Get-RbacHint -Exception $_.Exception
    if ($hint) { Write-Log $hint "WARN" }
    throw "Stage B failed. $($_.Exception.Message)"
}

# Stage C: Create managed disks from snapshots, preserve DES + shared settings
try {
    Write-Log "Stage C: Creating/reusing managed disks from snapshots."

    $supportsTier = (Get-Command New-AzDiskConfig).Parameters.ContainsKey("Tier")
    $supportsMaxShares = (Get-Command New-AzDiskConfig).Parameters.ContainsKey("MaxSharesCount")
    $supportsOptimizedForFrequentAttach = (Get-Command New-AzDiskConfig).Parameters.ContainsKey("OptimizedForFrequentAttach")
    $supportsZone = (Get-Command New-AzDiskConfig).Parameters.ContainsKey("Zone")

    foreach ($disk in $diskInfos) {
        $diskName = $disk.Name
        $snapshot = $snapshotByDiskName[$diskName]
        if ($null -eq $snapshot) {
            throw "Snapshot object not found in memory for disk '$diskName'."
        }

        $existingDisk = Get-AzDisk -ResourceGroupName $TargetSnapshotDiskResourceGroup -DiskName $diskName -ErrorAction SilentlyContinue
        if ($existingDisk) {
            $okSourceSnapshot = (Normalize-Text $existingDisk.CreationData.SourceResourceId) -eq (Normalize-Text $snapshot.Id)
            $okSku = (Normalize-Text $existingDisk.Sku.Name) -eq (Normalize-Text $disk.SkuName)
            $okDes = (Normalize-Text (Get-OptionalPropertyValue -Object $existingDisk.Encryption -PropertyName "DiskEncryptionSetId")) -eq (Normalize-Text $des.Id)
            $okZones = Compare-StringArray -A @($existingDisk.Zones) -B @($disk.Zones)
            $okMaxShares = ([int](Get-OptionalPropertyValue -Object $existingDisk -PropertyName "MaxShares")) -eq ([int]$disk.MaxShares)

            if (-not ($okSourceSnapshot -and $okSku -and $okDes -and $okZones -and $okMaxShares)) {
                throw "Managed disk '$diskName' already exists but configuration does not match expected snapshot/SKU/DES/zones/shared settings."
            }

            $targetDisksByName[$diskName] = $existingDisk
            Add-SummaryItem -Bucket "DisksReused" -Item $diskName
            continue
        }

        $cfgArgs = @{
            Location            = $targetLocation
            CreateOption        = "Copy"
            SourceResourceId    = $snapshot.Id
            SkuName             = $disk.SkuName
            DiskEncryptionSetId = $des.Id
        }

        if ($supportsTier -and -not [string]::IsNullOrWhiteSpace($disk.Tier)) {
            $cfgArgs["Tier"] = $disk.Tier
        }

        if ($supportsZone -and $disk.Zones -and $disk.Zones.Count -gt 0) {
            $cfgArgs["Zone"] = @($disk.Zones)
        }

        if ($supportsMaxShares -and [int]$disk.MaxShares -gt 1) {
            $cfgArgs["MaxSharesCount"] = [int]$disk.MaxShares
        }

        if ($supportsOptimizedForFrequentAttach -and $null -ne $disk.OptimizedForFrequentAttach) {
            $cfgArgs["OptimizedForFrequentAttach"] = [bool]$disk.OptimizedForFrequentAttach
        }

        $diskConfig = Invoke-WithRetry -Operation "New-AzDiskConfig $diskName" -ScriptBlock {
            New-AzDiskConfig @cfgArgs -ErrorAction Stop
        }

        $newDisk = Invoke-WithRetry -Operation "New-AzDisk $diskName" -ScriptBlock {
            New-AzDisk -ResourceGroupName $TargetSnapshotDiskResourceGroup -DiskName $diskName -Disk $diskConfig -ErrorAction Stop
        }

        $targetDisksByName[$diskName] = $newDisk
        Add-SummaryItem -Bucket "DisksCreated" -Item $diskName
    }

    Write-Log "Stage C completed. Managed disk operations finished for $($diskInfos.Count) disk(s)."
}
catch {
    $hint = Get-RbacHint -Exception $_.Exception
    if ($hint) { Write-Log $hint "WARN" }
    throw "Stage C failed. $($_.Exception.Message)"
}

# Stage D: Create VM + replicate networking
try {
    Write-Log "Stage D: Creating/reusing target NIC and VM in target subscription."
    Set-SubscriptionContextSafe -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

    $targetVnet = Invoke-WithRetry -Operation "Get target vNet $TargetVnetName" -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $TargetVnetResourceGroup -Name $TargetVnetName -ErrorAction Stop
    }

    $targetSubnet = $targetVnet.Subnets | Where-Object { $_.Name -eq $targetSubnetName } | Select-Object -First 1
    if ($null -eq $targetSubnet) {
        $subnetList = @($targetVnet.Subnets | ForEach-Object { $_.Name }) -join ", "
        throw "Subnet '$targetSubnetName' (from source VM) does not exist in target vNet '$TargetVnetName'. Available: $subnetList."
    }

    $targetVmNameFinal = [string]$sourceVm.Name
    if (-not [string]::IsNullOrWhiteSpace($TargetVmName) -and (Normalize-Text $TargetVmName) -ne (Normalize-Text $sourceVm.Name)) {
        Write-Log "TargetVmName '$TargetVmName' ignored. Target VM name is enforced to source VM name '$($sourceVm.Name)'." "WARN"
    }
    $script:Summary.TargetVmName = $targetVmNameFinal
    $targetNicName = "$targetVmNameFinal-nic"

    # Ensure NIC
    $sourcePrivateIpMethod = [string]$sourceIpConfig.PrivateIpAllocationMethod
    $sourcePrivateIp = [string]$sourceIpConfig.PrivateIpAddress
    $sourceIpConfigName = [string]$sourceIpConfig.Name

    $targetNic = Get-AzNetworkInterface -ResourceGroupName $TargetVmResourceGroup -Name $targetNicName -ErrorAction SilentlyContinue
    if ($null -eq $targetNic) {
        $ipConfig = $null
        if ((Normalize-Text $sourcePrivateIpMethod) -eq "static") {
            if ([string]::IsNullOrWhiteSpace($sourcePrivateIp)) {
                throw "Source NIC allocation is static but private IP is empty."
            }
            $ipConfig = New-AzNetworkInterfaceIpConfig -Name $sourceIpConfigName -SubnetId $targetSubnet.Id -PrivateIpAddress $sourcePrivateIp -Primary -ErrorAction Stop
        }
        else {
            $ipConfig = New-AzNetworkInterfaceIpConfig -Name $sourceIpConfigName -SubnetId $targetSubnet.Id -Primary -ErrorAction Stop
        }

        $targetNic = Invoke-WithRetry -Operation "Create NIC $targetNicName" -ScriptBlock {
            New-AzNetworkInterface -ResourceGroupName $TargetVmResourceGroup -Location $targetLocation -Name $targetNicName -IpConfiguration $ipConfig -Tag $targetVmTags -ErrorAction Stop
        }
        Add-SummaryItem -Bucket "NicsCreated" -Item $targetNicName
        Write-Log "Created NIC '$targetNicName'."
    }
    else {
        $nicIpCfg = $targetNic.IpConfigurations | Where-Object { $_.Name -eq $sourceIpConfigName } | Select-Object -First 1
        if ($null -eq $nicIpCfg) {
            $nicIpCfg = $targetNic.IpConfigurations | Select-Object -First 1
            Write-Log "NIC '$targetNicName' does not contain IP config '$sourceIpConfigName'. Using '$($nicIpCfg.Name)' as mapping." "WARN"
        }

        if ((Normalize-Text $nicIpCfg.Subnet.Id) -ne (Normalize-Text $targetSubnet.Id)) {
            throw "Existing NIC '$targetNicName' is on subnet '$($nicIpCfg.Subnet.Id)' but expected '$($targetSubnet.Id)'."
        }

        if ((Normalize-Text $sourcePrivateIpMethod) -eq "static") {
            if ((Normalize-Text $nicIpCfg.PrivateIpAllocationMethod) -ne "static") {
                throw "Existing NIC '$targetNicName' IP allocation method is '$($nicIpCfg.PrivateIpAllocationMethod)' but expected 'Static'."
            }
            if ((Normalize-Text $nicIpCfg.PrivateIpAddress) -ne (Normalize-Text $sourcePrivateIp)) {
                throw "Existing NIC '$targetNicName' private IP '$($nicIpCfg.PrivateIpAddress)' does not match expected '$sourcePrivateIp'."
            }
        }
        else {
            if ((Normalize-Text $nicIpCfg.PrivateIpAllocationMethod) -ne "dynamic") {
                throw "Existing NIC '$targetNicName' IP allocation method is '$($nicIpCfg.PrivateIpAllocationMethod)' but expected 'Dynamic'."
            }
        }

        Add-SummaryItem -Bucket "NicsReused" -Item $targetNicName
        Write-Log "Reused NIC '$targetNicName' with matching configuration."
    }

    # Validate required disks for VM
    $osDiskInfo = $diskInfos | Where-Object { $_.Role -eq "OS" } | Select-Object -First 1
    if ($null -eq $osDiskInfo) {
        throw "Could not identify OS disk in captured source configuration."
    }

    $targetOsDisk = $targetDisksByName[$osDiskInfo.Name]
    if ($null -eq $targetOsDisk) {
        throw "Target OS disk '$($osDiskInfo.Name)' not found."
    }

    # Ensure VM
    $existingVm = Get-AzVM -ResourceGroupName $TargetVmResourceGroup -Name $targetVmNameFinal -ErrorAction SilentlyContinue
    if ($existingVm) {
        $expectedVmSize = [string]$sourceVm.HardwareProfile.VmSize
        if ((Normalize-Text $existingVm.HardwareProfile.VmSize) -ne (Normalize-Text $expectedVmSize)) {
            throw "Existing VM '$targetVmNameFinal' VM size '$($existingVm.HardwareProfile.VmSize)' does not match expected '$expectedVmSize'."
        }

        $existingOsDiskId = Normalize-Text $existingVm.StorageProfile.OsDisk.ManagedDisk.Id
        if ($existingOsDiskId -ne (Normalize-Text $targetOsDisk.Id)) {
            throw "Existing VM '$targetVmNameFinal' OS disk mismatch."
        }

        $expectedDataDisks = @($diskInfos | Where-Object { $_.Role -eq "Data" } | Sort-Object Lun)
        $actualDataDisks = @($existingVm.StorageProfile.DataDisks | Sort-Object Lun)

        if ($expectedDataDisks.Count -ne $actualDataDisks.Count) {
            throw "Existing VM '$targetVmNameFinal' data disk count mismatch."
        }

        foreach ($expectedData in $expectedDataDisks) {
            $actual = $actualDataDisks | Where-Object { [int]$_.Lun -eq [int]$expectedData.Lun } | Select-Object -First 1
            if ($null -eq $actual) {
                throw "Existing VM '$targetVmNameFinal' missing expected LUN '$($expectedData.Lun)'."
            }

            $expectedDiskId = Normalize-Text $targetDisksByName[$expectedData.Name].Id
            $actualDiskId = Normalize-Text $actual.ManagedDisk.Id
            if ($expectedDiskId -ne $actualDiskId) {
                throw "Existing VM '$targetVmNameFinal' data disk mismatch at LUN '$($expectedData.Lun)'."
            }
        }

        $expectedNicId = Normalize-Text $targetNic.Id
        $vmNicIds = @($existingVm.NetworkProfile.NetworkInterfaces | ForEach-Object { Normalize-Text $_.Id })
        if (-not ($vmNicIds -contains $expectedNicId)) {
            throw "Existing VM '$targetVmNameFinal' is not attached to expected NIC '$targetNicName'."
        }

        $existingVmTags = if ($existingVm.Tags) { $existingVm.Tags } else { @{} }
        if (-not (Compare-Hashtable -A $existingVmTags -B $targetVmTags)) {
            throw "Existing VM '$targetVmNameFinal' tags do not match expected merged/prefixed source tags."
        }

        Add-SummaryItem -Bucket "VmsReused" -Item $targetVmNameFinal
        Write-Log "Reused VM '$targetVmNameFinal' with matching configuration."
    }
    else {
        $vmConfig = New-AzVMConfig -VMName $targetVmNameFinal -VMSize $sourceVm.HardwareProfile.VmSize -ErrorAction Stop
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $targetNic.Id -Primary -ErrorAction Stop

        $osType = Normalize-Text $osDiskInfo.OsType
        if ($osType -eq "windows") {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name $targetOsDisk.Name -ManagedDiskId $targetOsDisk.Id -CreateOption Attach -Windows -Caching $osDiskInfo.Caching -ErrorAction Stop
        }
        elseif ($osType -eq "linux") {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name $targetOsDisk.Name -ManagedDiskId $targetOsDisk.Id -CreateOption Attach -Linux -Caching $osDiskInfo.Caching -ErrorAction Stop
        }
        else {
            throw "Unsupported or unknown source OS type '$($osDiskInfo.OsType)'."
        }

        $dataDisksOrdered = @($diskInfos | Where-Object { $_.Role -eq "Data" } | Sort-Object Lun)
        foreach ($d in $dataDisksOrdered) {
            $managedDataDisk = $targetDisksByName[$d.Name]
            if ($null -eq $managedDataDisk) {
                throw "Target data disk '$($d.Name)' not found."
            }

            $vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $managedDataDisk.Name -ManagedDiskId $managedDataDisk.Id -Lun ([int]$d.Lun) -Caching $d.Caching -CreateOption Attach -ErrorAction Stop
        }

        # Enable boot diagnostics and let Azure use managed storage.
        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable -ResourceGroupName $TargetVmResourceGroup -ErrorAction Stop

        Invoke-WithRetry -Operation "Create VM $targetVmNameFinal" -ScriptBlock {
            New-AzVM -ResourceGroupName $TargetVmResourceGroup -Location $targetLocation -VM $vmConfig -Tag $targetVmTags -ErrorAction Stop | Out-Null
        } | Out-Null

        Add-SummaryItem -Bucket "VmsCreated" -Item $targetVmNameFinal
        Write-Log "Created VM '$targetVmNameFinal'."
    }
}
catch {
    $hint = Get-RbacHint -Exception $_.Exception
    if ($hint) { Write-Log $hint "WARN" }
    throw "Stage D failed. $($_.Exception.Message)"
}

# Stage E: Attach NIC IP config to LB backend pool
try {
    Write-Log "Stage E: Attaching NIC to target load balancer backend pool."
    Set-SubscriptionContextSafe -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

    if ([string]::IsNullOrWhiteSpace($sourceLoadBalancerName)) {
        throw "Source load balancer name is not available from captured source configuration."
    }

    $lb = Invoke-WithRetry -Operation "Get load balancer $sourceLoadBalancerName" -ScriptBlock {
        Get-AzLoadBalancer -ResourceGroupName $TargetLoadBalancerResourceGroup -Name $sourceLoadBalancerName -ErrorAction Stop
    }

    $selectedPool = Select-TargetBackendPool -LoadBalancer $lb -SourceBackendPoolNames $sourceBackendPoolNames -PoolNameOverride $BackendPoolNameOverride
    Write-Log "Selected backend pool '$($selectedPool.Name)'."

    $targetNic = Invoke-WithRetry -Operation "Refresh target NIC $($targetNic.Name)" -ScriptBlock {
        Get-AzNetworkInterface -ResourceGroupName $TargetVmResourceGroup -Name $targetNic.Name -ErrorAction Stop
    }

    $desiredIpConfigName = [string]$sourceIpConfig.Name
    $nicIpCfgForLb = $targetNic.IpConfigurations | Where-Object { $_.Name -eq $desiredIpConfigName } | Select-Object -First 1
    if ($null -eq $nicIpCfgForLb) {
        $nicIpCfgForLb = $targetNic.IpConfigurations | Select-Object -First 1
        Write-Log "Using NIC IP config '$($nicIpCfgForLb.Name)' for LB association (source IP config name not found)." "WARN"
    }

    $currentPoolIds = @($nicIpCfgForLb.LoadBalancerBackendAddressPools | ForEach-Object { Normalize-Text $_.Id })
    if ($currentPoolIds -contains (Normalize-Text $selectedPool.Id)) {
        Add-SummaryItem -Bucket "BackendPoolAlreadyMember" -Item "$($targetNic.Name)/$($nicIpCfgForLb.Name)->$($selectedPool.Name)"
        Write-Log "NIC IP configuration is already a member of backend pool '$($selectedPool.Name)'."
    }
    else {
        if ($null -eq $nicIpCfgForLb.LoadBalancerBackendAddressPools) {
            $nicIpCfgForLb.LoadBalancerBackendAddressPools = @()
        }

        $nicIpCfgForLb.LoadBalancerBackendAddressPools += $selectedPool

        Invoke-WithRetry -Operation "Update NIC backend pool association" -ScriptBlock {
            Set-AzNetworkInterface -NetworkInterface $targetNic -ErrorAction Stop | Out-Null
        } | Out-Null

        $verifyNic = Get-AzNetworkInterface -ResourceGroupName $TargetVmResourceGroup -Name $targetNic.Name -ErrorAction Stop
        $verifyIpCfg = $verifyNic.IpConfigurations | Where-Object { $_.Name -eq $nicIpCfgForLb.Name } | Select-Object -First 1
        $verifyPoolIds = @($verifyIpCfg.LoadBalancerBackendAddressPools | ForEach-Object { Normalize-Text $_.Id })

        if (-not ($verifyPoolIds -contains (Normalize-Text $selectedPool.Id))) {
            throw "LB backend pool association verification failed for NIC '$($verifyNic.Name)' and pool '$($selectedPool.Name)'."
        }

        Add-SummaryItem -Bucket "BackendPoolAttached" -Item "$($verifyNic.Name)/$($verifyIpCfg.Name)->$($selectedPool.Name)"
        Write-Log "Attached NIC '$($verifyNic.Name)' IP config '$($verifyIpCfg.Name)' to backend pool '$($selectedPool.Name)'."
    }
}
catch {
    $hint = Get-RbacHint -Exception $_.Exception
    if ($hint) { Write-Log $hint "WARN" }
    throw "Stage E failed. $($_.Exception.Message)"
}

Write-Log "Workflow completed successfully."
Write-Host ""
Write-Log "Summary:"
Write-Log "Source VM: $($script:Summary.SourceVmName)"
Write-Log "Target VM: $($script:Summary.TargetVmName)"
Write-Log "Config persisted: $($script:Summary.ConfigFilePath)"
Write-Log "Snapshots created: $(@($script:Summary.SnapshotsCreated) -join ', ')"
Write-Log "Snapshots reused: $(@($script:Summary.SnapshotsReused) -join ', ')"
Write-Log "Disks created: $(@($script:Summary.DisksCreated) -join ', ')"
Write-Log "Disks reused: $(@($script:Summary.DisksReused) -join ', ')"
Write-Log "NICs created: $(@($script:Summary.NicsCreated) -join ', ')"
Write-Log "NICs reused: $(@($script:Summary.NicsReused) -join ', ')"
Write-Log "VMs created: $(@($script:Summary.VmsCreated) -join ', ')"
Write-Log "VMs reused: $(@($script:Summary.VmsReused) -join ', ')"
Write-Log "LB associations created: $(@($script:Summary.BackendPoolAttached) -join ', ')"
Write-Log "LB associations already present: $(@($script:Summary.BackendPoolAlreadyMember) -join ', ')"