#Requires -RunAsAdministrator
# uninstall.ps1 -- remove host-level mpd configuration and optionally delete VMs.
# Called by uninstall.cmd.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$vms = @(Get-MpdVMs)

Write-Host ""
Write-Host "This will remove host-level mpd configuration:"
Write-Host "  - Hyper-V switch '$SwitchName' and its NAT rule"
Write-Host "  - Persistent route to the container subnet"
Write-Host "  - NRPT rule for *.mpd.test"
Write-Host "  - mpd CA certificate from the trusted root store"
Write-Host "  - $MpdUserDir (helper scripts, CA, current.env)"
Write-Host "  - 'Host mpd-machine' block from ~/.ssh/config"
Write-Host "  - mpd-machine desktop shortcut"
if ($vms.Count -gt 0) {
    Write-Host ""
    Write-Host "Existing VMs (you will be asked about each one after host cleanup):"
    foreach ($vm in $vms) { Write-Host "  $($vm.Name)  ($($vm.State))" }
}
Write-Host ""
Read-Host "Press Enter to proceed, or Ctrl-C to abort"

# ── Remove NRPT rule ──────────────────────────────────────────────────────────

$nrpt = Get-DnsClientNrptRule | Where-Object { $_.Namespace -eq ".mpd.test" }
if ($nrpt) {
    $nrpt | Remove-DnsClientNrptRule -Force
    Write-Host "NRPT rule removed."
}

# ── Remove persistent route ───────────────────────────────────────────────────

$route = Get-NetRoute -DestinationPrefix $ContainerSubnet -ErrorAction SilentlyContinue
if ($route) {
    $route | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Container subnet route removed."
}

# ── Remove CA certificate ─────────────────────────────────────────────────────

$caSha1Path = Join-Path $MpdUserDir "ca.sha1"
$tracked    = $false
if (Test-Path $caSha1Path) {
    $thumbprint = (Get-Content $caSha1Path -Raw).Trim()
    if ($thumbprint) {
        $cert = Get-ChildItem Cert:\LocalMachine\Root |
                Where-Object { $_.Thumbprint -eq $thumbprint }
        if ($cert) {
            Remove-Item "Cert:\LocalMachine\Root\$thumbprint" -ErrorAction SilentlyContinue
            Write-Host "mpd CA certificate removed (thumbprint $thumbprint)."
            $tracked = $true
        }
    }
}
$stale = Get-ChildItem Cert:\LocalMachine\Root |
         Where-Object { $_.Subject -match "mpd\.test local development CA" }
if ($stale) {
    $stale | ForEach-Object { Remove-Item "Cert:\LocalMachine\Root\$($_.Thumbprint)" -ErrorAction SilentlyContinue }
    if ($tracked) {
        Write-Host "$($stale.Count) stale mpd CA certificate(s) also removed."
    } else {
        Write-Host "mpd CA certificate(s) removed."
    }
}

# ── Stop all VMs (required before switch can be removed) ─────────────────────

foreach ($vm in @(Get-MpdVMs)) {
    if ($vm.State -notin @('Off', 'Saved')) {
        Write-Host "Stopping $($vm.Name) ..."
        Stop-VM -Name $vm.Name -TurnOff -Force
    }
}

# ── Remove switch, NAT, IP ────────────────────────────────────────────────────

$nat = Get-NetNat -Name $SwitchName -ErrorAction SilentlyContinue
if ($nat) {
    Remove-NetNat -Name $SwitchName -Confirm:$false
    Write-Host "NAT '$SwitchName' removed."
}

$ip = Get-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
if ($ip) {
    Remove-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -Confirm:$false -ErrorAction SilentlyContinue
}

$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($sw) {
    Remove-VMSwitch -Name $SwitchName -Force
    Write-Host "Switch '$SwitchName' removed."
}

# ── Remove user state directory ───────────────────────────────────────────────

if (Test-Path $MpdUserDir) {
    Remove-Item $MpdUserDir -Recurse -Force
    Write-Host "Removed $MpdUserDir."
}

# ── Remove SSH config entry ───────────────────────────────────────────────────

if (Test-Path "$env:USERPROFILE\.ssh\config") {
    Remove-MpdSshConfig
    Write-Host "SSH config entry removed."
}

# ── Remove desktop shortcut ───────────────────────────────────────────────────

$shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "mpd-machine.lnk"
if (Test-Path $shortcut) {
    Remove-Item $shortcut -Force
    Write-Host "Desktop shortcut removed."
}

# ── Per-VM deletion ───────────────────────────────────────────────────────────

if ($vms.Count -gt 0) {
    Write-Host ""
    Write-Host "VM deletion (default: keep):"
    Write-Host ""
    foreach ($vm in $vms) {
        $inp = Read-Host "  Delete $($vm.Name)  ($($vm.State))? [y/N]"
        if ($inp -match '^[Yy]$') {
            if ($vm.State -ne 'Off') {
                Write-Host "    Stopping $($vm.Name) ..."
                Stop-VM -Name $vm.Name -TurnOff -Force
            }
            Write-Host "    Deleting $($vm.Name) ..."
            $storePath = Join-Path (Get-VMHost).VirtualHardDiskPath $vm.Name
            Remove-VM -Name $vm.Name -Force
            if (Test-Path $storePath) { Remove-Item $storePath -Recurse -Force }
            Write-Host "    Deleted."
        } else {
            Write-Host "    Kept $($vm.Name)."
        }
    }
}

Write-Host ""
Write-Host "Uninstall complete."
