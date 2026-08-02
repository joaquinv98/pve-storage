param(
    [string]$ApiBase = 'https://192.168.10.100:8006/api2/json',
    [string]$Node = 'hvarres02',
    [string]$CredentialName = 'Proxmox AR (root)',
    [string]$CredentialHelper = 'D:\Clientes\NeaTech\scripts\zabbix-grafana\Get-Cred.ps1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$password = & $CredentialHelper -Nombre $CredentialName
try {
    $auth = Invoke-RestMethod -SkipCertificateCheck -Method Post `
        -Uri "$ApiBase/access/ticket" `
        -Body @{ username = 'root@pam'; password = $password }
} finally {
    $password = $null
}

$headers = @{
    Cookie = "PVEAuthCookie=$($auth.data.ticket)"
    CSRFPreventionToken = $auth.data.CSRFPreventionToken
}

function Invoke-Pve {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
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
    Invoke-RestMethod @params
}

function Wait-PveTask {
    param([Parameter(Mandatory)][string]$Upid)

    $taskNode = ($Upid -split ':')[1]
    $escaped = [Uri]::EscapeDataString($Upid)
    do {
        $status = (Invoke-Pve GET "nodes/$taskNode/tasks/$escaped/status").data
        if ($status.status -eq 'stopped') {
            if ($status.exitstatus -ne 'OK') {
                throw "PVE task failed: $Upid ($($status.exitstatus))"
            }
            return
        }
        Start-Sleep -Seconds 1
    } while ($true)
}

$network = (Invoke-Pve GET "nodes/$Node/network").data
$bridge = $network | Where-Object iface -eq 'vmbr952'
if (!$bridge) {
    Invoke-Pve POST "nodes/$Node/network" @{
        iface = 'vmbr952'
        type = 'bridge'
        autostart = 1
        bridge_ports = ''
        comments = 'TEMP zfsnvme guest migration network; no physical ports'
    } | Out-Null
    $reload = Invoke-Pve PUT "nodes/$Node/network"
    if ($reload.data) {
        Wait-PveTask $reload.data
    }
} elseif ($bridge.type -ne 'bridge' -or $bridge.bridge_ports) {
    throw 'vmbr952 exists but is not the expected isolated Linux bridge'
}

foreach ($vmid in 9401, 9402, 9403) {
    Invoke-Pve PUT "nodes/$Node/qemu/$vmid/config" @{
        net3 = 'virtio,bridge=vmbr952,firewall=0'
    } | Out-Null
}

Write-Output 'vmbr952 and net3 are configured for VMIDs 9401, 9402, and 9403'
