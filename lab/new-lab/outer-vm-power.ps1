param(
    [Parameter(Mandatory)][ValidateSet('start', 'stop')][string]$Action,
    [Parameter(Mandatory)][int]$Vmid,
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
$response = Invoke-RestMethod -SkipCertificateCheck -Method Post `
    -Uri "$ApiBase/nodes/$Node/qemu/$Vmid/status/$Action" `
    -Headers $headers

$upid = $response.data
$escaped = [Uri]::EscapeDataString($upid)
do {
    Start-Sleep -Milliseconds 500
    $status = (Invoke-RestMethod -SkipCertificateCheck -Method Get `
        -Uri "$ApiBase/nodes/$Node/tasks/$escaped/status" `
        -Headers $headers).data
} while ($status.status -ne 'stopped')

if ($status.exitstatus -ne 'OK') {
    throw "Outer PVE task failed: $upid ($($status.exitstatus))"
}
Write-Output "VMID $Vmid $Action completed on $Node"
