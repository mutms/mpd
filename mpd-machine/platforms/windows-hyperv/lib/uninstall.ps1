#Requires -RunAsAdministrator
# uninstall.ps1 -- delete all mpd VMs and remove the mpd switch, NAT, and networking rules.
# Called by uninstall.cmd.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$vms = @(Get-MpdVMs)

Write-Host ""
Write-Host "This will permanently DELETE the following VMs and remove the mpd switch:"
Write-Host ""
if ($vms.Count -eq 0) {
    Write-Host "  (no mpd-machine-NN VMs found)"
} else {
    foreach ($vm in $vms) { Write-Host "  $($vm.Name)  ($($vm.State))" }
}
Write-Host ""
Write-Host "It will also remove:"
Write-Host "  - Hyper-V switch '$SwitchName' and its NAT rule"
Write-Host "  - Persistent route to the container subnet"
Write-Host "  - NRPT rule for *.mpd.test"
Write-Host "  - mpd CA certificate from the trusted root store"
Write-Host "  - $MpdUserDir (helper scripts, current.env, mpd-machine.cmd)
  - 'Host mpd-machine' block from ~/.ssh/config"
Write-Host ""
$confirm = Read-Host "Type YES to confirm"
if ($confirm -ne "YES") { Write-Host "Aborted."; exit 0 }

# ── Stop and delete VMs ───────────────────────────────────────────────────────

foreach ($vm in $vms) {
    if ($vm.State -ne 'Off') {
        Write-Host "Stopping $($vm.Name) ..."
        Stop-VM -Name $vm.Name -TurnOff -Force
    }
    Write-Host "Deleting $($vm.Name) ..."
    $storePath = Join-Path (Get-VMHost).VirtualHardDiskPath $vm.Name
    Remove-VM -Name $vm.Name -Force
    if (Test-Path $storePath) { Remove-Item $storePath -Recurse -Force }
}

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

$certs = Get-ChildItem Cert:\LocalMachine\Root |
         Where-Object { $_.Subject -match "mpd\.test local development CA" }
if ($certs) {
    $certs | ForEach-Object { Remove-Item "Cert:\LocalMachine\Root\$($_.Thumbprint)" }
    Write-Host "mpd CA certificate removed."
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

$sshConfig = "$env:USERPROFILE\.ssh\config"
if (Test-Path $sshConfig) {
    $lines      = Get-Content $sshConfig
    $filtered   = [System.Collections.Generic.List[string]]::new()
    $inBlock    = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*Host\s+mpd-machine\s*$') { $inBlock = $true; continue }
        if ($inBlock -and $line -match '^\s*Host\s+') { $inBlock = $false }
        if (-not $inBlock) { $filtered.Add($line) }
    }
    [System.IO.File]::WriteAllLines($sshConfig, $filtered)
    Write-Host "SSH config entry removed."
}

# ── Remove desktop shortcut ───────────────────────────────────────────────────

$shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "mpd-machine.lnk"
if (Test-Path $shortcut) {
    Remove-Item $shortcut -Force
    Write-Host "Desktop shortcut removed."
}

Write-Host ""
Write-Host "Uninstall complete."
