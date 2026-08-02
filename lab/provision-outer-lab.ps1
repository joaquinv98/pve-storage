param(
    [string]$ApiBase = 'https://192.168.10.100:8006/api2/json',
    [string]$Node = 'hvarres02',
    [string]$TemplateNode = 'hvarres01',
    [string]$Storage = 'Z0-Local',
    [string]$ManagementBridge = 'vlan034',
    [string]$CredentialName = 'Proxmox AR (root)',
    [string]$CredentialHelper = 'D:\Clientes\NeaTech\scripts\zabbix-grafana\Get-Cred.ps1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$lab = @(
    @{
        Vmid = 9401
        Name = 'zfsnvme-target-20260731'
        Template = 9000
        Address = '192.168.34.241'
        Memory = 2048
        Cores = 2
        RootGrow = '+10G'
        ExtraDisk = '32'
        Role = 'target'
    },
    @{
        Vmid = 9402
        Name = 'zfsnvme-pve1-20260731'
        Template = 9006
        Address = '192.168.34.242'
        Memory = 4096
        Cores = 4
        RootGrow = '+20G'
        Role = 'initiator'
    },
    @{
        Vmid = 9403
        Name = 'zfsnvme-pve2-20260731'
        Template = 9006
        Address = '192.168.34.243'
        Memory = 4096
        Cores = 4
        RootGrow = '+20G'
        Role = 'initiator'
    }
)

function Connect-Pve {
    $password = & $CredentialHelper -Nombre $CredentialName
    try {
        $auth = Invoke-RestMethod -SkipCertificateCheck -Method Post `
            -Uri "$ApiBase/access/ticket" `
            -Body @{ username = 'root@pam'; password = $password }
    } finally {
        $password = $null
    }

    return @{
        Cookie = "PVEAuthCookie=$($auth.data.ticket)"
        CSRFPreventionToken = $auth.data.CSRFPreventionToken
    }
}

$headers = Connect-Pve

function Invoke-Pve {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body
    )

    $params = @{
        SkipCertificateCheck = $true
        Method = $Method
        Uri = "$ApiBase/$Path"
        Headers = $headers
    }
    if ($Body) {
        $params.ContentType = 'application/x-www-form-urlencoded'
        $params.Body = $Body
    }
    return Invoke-RestMethod @params
}

function Wait-PveTask {
    param(
        [Parameter(Mandatory)][string]$Upid,
        [int]$TimeoutSeconds = 1800
    )

    $taskNode = ($Upid -split ':')[1]
    $escaped = [Uri]::EscapeDataString($Upid)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $status = (Invoke-Pve GET "nodes/$taskNode/tasks/$escaped/status").data
        if ($status.status -eq 'stopped') {
            if ($status.exitstatus -ne 'OK') {
                throw "PVE task failed: $Upid ($($status.exitstatus))"
            }
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for PVE task: $Upid"
}

function Assert-LabCapacity {
    $nodes = (Invoke-Pve GET 'nodes').data
    $selected = $nodes | Where-Object node -eq $Node
    if (!$selected -or $selected.status -ne 'online') {
        throw "Node '$Node' is not online"
    }

    $required = ($lab | Measure-Object Memory -Sum).Sum * 1MB
    $available = $selected.maxmem - $selected.mem
    if ($available -lt ($required + 8GB)) {
        throw "Node '$Node' lacks the requested lab RAM plus an 8 GiB safety margin"
    }

    $storage = (Invoke-Pve GET "nodes/$Node/storage").data |
        Where-Object { $_.storage -eq $Storage -and $_.active -eq 1 }
    if (!$storage -or $storage.avail -lt 100GB) {
        throw "Storage '$Storage' on '$Node' is unavailable or has less than 100 GiB free"
    }

    $resources = (Invoke-Pve GET 'cluster/resources?type=vm').data
    foreach ($vm in $lab) {
        $existing = $resources | Where-Object vmid -eq $vm.Vmid
        if ($existing -and $existing.name -ne $vm.Name) {
            throw "VMID $($vm.Vmid) belongs to '$($existing.name)'; refusing to take it over"
        }
    }
}

function Ensure-LabBridge {
    param([Parameter(Mandatory)][string]$Name)

    $network = (Invoke-Pve GET "nodes/$Node/network").data
    $existing = $network | Where-Object iface -eq $Name
    if ($existing) {
        if ($existing.type -ne 'bridge' -or $existing.bridge_ports) {
            throw "Existing interface '$Name' is not an isolated bridge"
        }
        return $false
    }

    Invoke-Pve POST "nodes/$Node/network" @{
        iface = $Name
        type = 'bridge'
        autostart = 1
        bridge_ports = ''
        comments = 'TEMP zfsnvme validation lab; no physical ports'
    } | Out-Null
    return $true
}

function Clone-LabVm {
    param([Parameter(Mandatory)][hashtable]$Vm)

    $existing = (Invoke-Pve GET 'cluster/resources?type=vm').data |
        Where-Object vmid -eq $Vm.Vmid

    if (!$existing) {
        Write-Host "Cloning template $($Vm.Template) to VMID $($Vm.Vmid) on $TemplateNode..."
        $clone = Invoke-Pve POST "nodes/$TemplateNode/qemu/$($Vm.Template)/clone" @{
            newid = $Vm.Vmid
            name = $Vm.Name
            storage = $Storage
            full = 1
            description = "Temporary native ZFS over NVMe/TCP validation lab ($($Vm.Role)); 2026-07-31"
        }
        Wait-PveTask $clone.data
        $existing = [pscustomobject]@{ node = $TemplateNode }
    } else {
        Write-Host "Resuming exact lab VMID $($Vm.Vmid) on $($existing.node)..."
    }

    if ($existing.node -eq $TemplateNode -and $TemplateNode -ne $Node) {
        Write-Host "Migrating stopped VMID $($Vm.Vmid) with local disks to $Node..."
        $migration = Invoke-Pve POST "nodes/$TemplateNode/qemu/$($Vm.Vmid)/migrate" @{
            target = $Node
            online = 0
            'with-local-disks' = 1
            targetstorage = $Storage
        }
        Wait-PveTask $migration.data
    } elseif ($existing.node -ne $Node) {
        throw "Exact lab VMID $($Vm.Vmid) is unexpectedly on '$($existing.node)'"
    }

    $publicKey = (Get-Content 'D:\Clientes\NeaTech\scripts\keys\wsusvin01_neatech.pub' -Raw).Trim()
    $encodedPublicKey = [Uri]::EscapeDataString($publicKey)
    Invoke-Pve PUT "nodes/$Node/qemu/$($Vm.Vmid)/config" @{
        memory = $Vm.Memory
        balloon = 0
        cores = $Vm.Cores
        cpu = 'host'
        machine = 'q35'
        agent = 'enabled=1'
        onboot = 0
        protection = 0
        tags = 'lab;temporary;zfsnvme'
        ciuser = 'sysadmin'
        sshkeys = $encodedPublicKey
        nameserver = '192.168.34.1'
        searchdomain = 'lab.neatech.ar'
        ipconfig0 = "ip=$($Vm.Address)/24,gw=192.168.34.1"
        net0 = "virtio,bridge=$ManagementBridge,firewall=0"
        net1 = 'virtio,bridge=vmbr950,firewall=0'
        net2 = 'virtio,bridge=vmbr951,firewall=0'
        net3 = 'virtio,bridge=vmbr952,firewall=0'
        serial0 = 'socket'
    } | Out-Null

    $resize = Invoke-Pve PUT "nodes/$Node/qemu/$($Vm.Vmid)/resize" @{
        disk = 'scsi0'
        size = $Vm.RootGrow
    }
    if ($resize.data) {
        Wait-PveTask $resize.data
    }

    if ($Vm.ExtraDisk) {
        Invoke-Pve PUT "nodes/$Node/qemu/$($Vm.Vmid)/config" @{
            scsi1 = "$Storage`:$($Vm.ExtraDisk),discard=on,ssd=1"
        } | Out-Null
    }
}

Assert-LabCapacity
$bridge950Changed = Ensure-LabBridge 'vmbr950'
$bridge951Changed = Ensure-LabBridge 'vmbr951'
$bridge952Changed = Ensure-LabBridge 'vmbr952'
$networkChanged = $bridge950Changed -or $bridge951Changed -or $bridge952Changed
if ($networkChanged) {
    Write-Host "Applying additive bridge configuration on $Node..."
    $reload = Invoke-Pve PUT "nodes/$Node/network"
    if ($reload.data) {
        Wait-PveTask $reload.data 300
    }
}

foreach ($vm in $lab) {
    Clone-LabVm $vm
}

foreach ($vm in $lab) {
    Write-Host "Starting VMID $($vm.Vmid)..."
    $start = Invoke-Pve POST "nodes/$Node/qemu/$($vm.Vmid)/status/start"
    if ($start.data) {
        Wait-PveTask $start.data 300
    }
}

Write-Host 'Outer lab provisioned:'
$lab | ForEach-Object {
    [pscustomobject]@{
        vmid = $_.Vmid
        name = $_.Name
        address = $_.Address
        memory_mib = $_.Memory
        role = $_.Role
    }
} | Format-Table -AutoSize
