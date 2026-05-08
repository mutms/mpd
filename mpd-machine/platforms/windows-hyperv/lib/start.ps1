#Requires -RunAsAdministrator
# start.ps1 -- start the current mpd VM (detected from the persistent route).
# Called by start.cmd.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$octet = Get-CurrentVmOctet
if (-not $octet) {
    Write-Host "No mpd VM configured. Run setup.cmd first."
    exit 1
}

$vmName = "$VmNamePrefix$octet"
$vmIp   = "$SwitchSubnet.$octet"
$vm     = Get-VM -Name $vmName -ErrorAction SilentlyContinue

if (-not $vm) {
    Write-Host "VM '$vmName' not found in Hyper-V. Run setup.cmd to create or reconfigure."
    exit 1
}

if ($vm.State -eq 'Running') {
    Write-Host "$vmName is already running ($vmIp)."
    exit 0
}

Write-Host "Starting $vmName ..."
Start-VM -Name $vmName
Write-Host "Started. SSH: ssh $(Get-VmSshUser -VmName $vmName)@$vmIp"
