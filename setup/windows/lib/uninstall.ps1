#Requires -RunAsAdministrator
# uninstall.ps1 -- remove host-level mpd configuration and optionally delete VMs.
# Called by uninstall.cmd.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$vms = @(Get-MpdVMs)

Write-Host ""
Write-Host "This will remove host-level mpd configuration:"
Write-Host "  - Hyper-V switch '$SwitchName' and its NAT rule"
Write-Host "  - Persistent routes to every mpd container subnet"
Write-Host "  - NRPT rules for every mpd zone (*.<NNN>.mpd.test)"
Write-Host "  - mpd CA certificate from the trusted root store"
Write-Host "  - $MpdUserDir (helper scripts, CA, current.env)"
Write-Host "  - 'Host mpd-vm' block from ~/.ssh/config"
Write-Host "  - mpd-vm desktop shortcut"
if ($vms.Count -gt 0) {
    Write-Host ""
    Write-Host "Existing VMs (you will be asked about each one after host cleanup):"
    foreach ($vm in $vms) { Write-Host "  $($vm.Name)  ($($vm.State))" }
}
Write-Host ""
Read-Host "Press Enter to proceed, or Ctrl-C to abort"

# ── Remove NRPT rule ──────────────────────────────────────────────────────────

# Every per-VM zone (".150.mpd.test"), plus the flat ".mpd.test" rule
# from before per-VM zones. Uninstall is machine-wide, so it clears all
# of them rather than one VM's.
$nrpt = Get-DnsClientNrptRule |
        Where-Object { $_.Namespace -match "^\.(\d{3}\.)?$([regex]::Escape($MpdRootDomain))$" }
foreach ($rule in $nrpt) {
    $rule | Remove-DnsClientNrptRule -Force
    Write-Host "NRPT rule $($rule.Namespace) removed."
}

# ── Remove persistent route ───────────────────────────────────────────────────

# Any 10.163.x.0/24 route is an mpd container subnet, whatever the VM id.
$routes = Get-NetRoute -ErrorAction SilentlyContinue |
          Where-Object { $_.DestinationPrefix -match "^$([regex]::Escape($MpdSubnetPrefix))\.\d+\.0/24$" }
foreach ($r in $routes) {
    $r | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Route to $($r.DestinationPrefix) removed."
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

$shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "mpd-vm.lnk"
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
