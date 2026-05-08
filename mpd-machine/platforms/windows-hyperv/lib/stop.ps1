#Requires -RunAsAdministrator
# stop.ps1 -- suspend all running mpd VMs (Save-VM preserves state instantly).
# Called by stop.cmd.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$vms = @(Get-MpdVMs | Where-Object { $_.State -notin @('Off', 'Saved') })

if ($vms.Count -eq 0) {
    Write-Host "No mpd VMs are running."
    exit 0
}

foreach ($vm in $vms) {
    Write-Host "Suspending $($vm.Name) ..."
    Save-VM -Name $vm.Name
    Write-Host "  Suspended."
}
