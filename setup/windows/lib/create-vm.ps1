#Requires -RunAsAdministrator
# create-vm.ps1 -- provision a Debian Trixie VM end-to-end.
# Called by lib\setup.ps1 after the switch is ready and prompts are answered.
# Does NOT configure Windows networking -- setup.ps1 calls configure-client.ps1
# after this script returns.

param(
    [Parameter(Mandatory)][int]$VmOctet,
    [Parameter(Mandatory)][string]$VmUser,
    [Parameter(Mandatory)][string]$SshPubKey,
    [int]$VmMemoryGb = 8,
    [int]$VmCpuCount = 4,
    [int]$DiskSizeGb = 200
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$VmName      = "$VmNamePrefix$VmOctet"
$VmIp        = "$SwitchSubnet.$VmOctet"
$wslCommonSh = Convert-ToWSLPath "$PSScriptRoot\common.sh"

# ── 2. Download cloud image ───────────────────────────────────────────────────

Write-Step "Preparing Debian Trixie cloud image"

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir  | Out-Null

$CachedImage = Join-Path $CacheDir $CloudImage
if (Test-Path $CachedImage) {
    Write-Ok "Using cached: $CloudImage"
} else {
    Write-Info "Downloading $CloudImage (~420 MB)..."
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri "$CloudBase/$CloudImage" -OutFile $CachedImage
    $ProgressPreference = "Continue"
    Write-Ok "Downloaded"
}

# ── 3. Convert qcow2 -> VHDX and resize ──────────────────────────────────────

Write-Step "Converting and resizing disk image"

$VmStorePath = Join-Path (Get-VMHost).VirtualHardDiskPath $VmName
New-Item -ItemType Directory -Force -Path $VmStorePath | Out-Null
$VhdxPath = Join-Path $VmStorePath "$VmName.vhdx"

Write-Info "Converting qcow2 -> VHDX via WSL qemu-img (takes a minute)..."
$wslImage = Convert-ToWSLPath $CachedImage
$wslVhdx  = Convert-ToWSLPath $VhdxPath
Invoke-WSLScript "qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic '$wslImage' '$wslVhdx'"

Write-Info "Resizing to ${DiskSizeGb} GB..."
Resize-VHD -Path $VhdxPath -SizeBytes ($DiskSizeGb * 1GB)
Write-Ok "VHDX ready: $VhdxPath"

# ── 4. Cloud-init seed ISO ────────────────────────────────────────────────────

Write-Step "Creating cloud-init seed ISO (via WSL genisoimage)"

$SeedIso    = Join-Path $TempDir "seed.iso"
$wslSeedIso = Convert-ToWSLPath $SeedIso
$escapedKey = $SshPubKey -replace "'", "'\''"
Invoke-WSLScript @"
set -euo pipefail
. '$wslCommonSh'
generate_seed_iso '$wslSeedIso' $VmOctet '$VmUser' '$escapedKey'
"@
Write-Ok "Cloud-init seed ISO created"

# ── 6. Create Hyper-V VM ──────────────────────────────────────────────────────

Write-Step "Creating VM '$VmName' in Hyper-V"

New-VM -Name $VmName -MemoryStartupBytes ($VmMemoryGb * 1GB) -Generation 2 `
       -SwitchName $SwitchName -NoVHD | Out-Null
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true `
             -MinimumBytes 4GB `
             -StartupBytes ($VmMemoryGb * 1GB) `
             -MaximumBytes ($VmMemoryGb * 1GB)
Set-VMProcessor -VMName $VmName -Count $VmCpuCount
Set-VM -VMName $VmName -AutomaticStartAction Start -AutomaticStopAction ShutDown `
       -CheckpointType Disabled
Add-VMHardDiskDrive -VMName $VmName -Path $VhdxPath `
       -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0
Add-VMDvdDrive -VMName $VmName -Path $SeedIso `
       -ControllerNumber 0 -ControllerLocation 1
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off

# Boot order: DVD first, then disk -- network adapter excluded to avoid PXE timeout.
$boot     = (Get-VMFirmware -VMName $VmName).BootOrder
$dvdBoot  = @($boot | Where-Object { $_.Device.GetType().Name -match "Dvd" })
$diskBoot = @($boot | Where-Object { $_.Device.GetType().Name -match "HardDisk" })
Set-VMFirmware -VMName $VmName -BootOrder ($dvdBoot + $diskBoot)

Write-Ok "VM created"

# ── 7. Start VM and wait for cloud-init ───────────────────────────────────────

Write-Step "Starting VM (cloud-init runs on first boot -- takes 2-5 minutes)"

Clear-MpdKnownHosts -VmIp $VmIp

Start-VM -Name $VmName
Write-Ok "VM started"

Write-Host ""
Write-Host "Tip: if output freezes, you may have clicked the terminal (Quick Edit Mode)."
Write-Host "     Press Enter or Escape to resume."
Write-Host ""

Write-Info "Waiting for SSH at $VmIp (cloud-init is setting up the VM)..."
Wait-ForSsh -User $VmUser -RemoteHost $VmIp -TimeoutSec 360 -Label "(cloud-init)"
Write-Ok "SSH ready ($VmUser@$VmIp)"

Write-Info "Waiting for cloud-init to finish..."
$start = Get-Date
while (((Get-Date) - $start).TotalSeconds -lt 300) {
    cmd /c "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR `"${VmUser}@${VmIp}`" `"test -f /var/lib/cloud/instance/boot-finished`" >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 5
}
Write-Ok "Cloud-init complete"

# ── 8. Bootstrap step 20: clone mpd repository ────────────────────────────────
# (Cloud-init already handled the prep step's job: passwordless sudo, SSH
# key, hostname, static IP, IPv6 disable, on a systemd-networkd image — no
# network-stack conversion needed. mpd derives its id from the hostname
# mpd-<NNN>.)

$MpdBranch    = if ($env:MPD_BRANCH) { $env:MPD_BRANCH } else { "main" }
$MpdRepoRaw   = "https://raw.githubusercontent.com/mutms/mpd/$MpdBranch"

Write-Step "Bootstrap 20: install git + clone mpd repo"
Invoke-Ssh -User $VmUser -RemoteHost $VmIp `
    -Command "MPD_BRANCH=$MpdBranch MPD_REPO=$MpdRepo bash <(wget -qO- $MpdRepoRaw/bootstrap/20-git-clone.sh)"
Write-Ok "Repository cloned"

# ── 9. Issue this VM's signing CA, then upload CA material ──────────────────

# The root's private key stays on this host. The VM gets its own
# intermediate, name-constrained to its own DNS zone, which the in-VM `mpd`
# uses to sign service and project certificates. A compromised VM can
# therefore forge names in its own zone and nowhere else — not another VM's
# zone, and not names issued directly under mpd.test.

$VmId = "{0:d3}" -f $VmOctet
Write-Step "Issuing this VM's signing CA (constrained to $VmId.mpd.test)"

$CaPem   = Join-Path $MpdUserDir "ca\rootCA.pem"
$CaKey   = Join-Path $MpdUserDir "ca\rootCA-key.pem"
$VmCaDir = Join-Path $MpdUserDir "$VmId\ca"
$VmCaPem = Join-Path $VmCaDir "vmCA.pem"
$VmCaKey = Join-Path $VmCaDir "vmCA-key.pem"
New-Item -ItemType Directory -Force -Path $VmCaDir | Out-Null

$wslCaPem   = Convert-ToWSLPath $CaPem
$wslCaKey   = Convert-ToWSLPath $CaKey
$wslVmCaPem = Convert-ToWSLPath $VmCaPem
$wslVmCaKey = Convert-ToWSLPath $VmCaKey
Invoke-WSLScript @"
set -euo pipefail
. '$wslCommonSh'
generate_vm_ca '$wslVmCaKey' '$wslVmCaPem' '$wslCaPem' '$wslCaKey' $VmOctet
"@
Write-Ok "VM CA issued ($VmCaPem)"

Write-Step "Uploading CA material to VM"

Invoke-Ssh -User $VmUser -RemoteHost $VmIp -Command "mkdir -p /var/lib/mpd/conf/caroot && chmod 700 /var/lib/mpd/conf/caroot"
# The root's PUBLIC certificate only — the trust anchor. Its private key is
# deliberately absent from these uploads.
& scp -o StrictHostKeyChecking=no -o BatchMode=yes $CaPem "${VmUser}@${VmIp}:/var/lib/mpd/conf/caroot/rootCA.pem"
if ($LASTEXITCODE -ne 0) { throw "scp of root CA cert failed." }
& scp -o StrictHostKeyChecking=no -o BatchMode=yes $VmCaPem "${VmUser}@${VmIp}:/var/lib/mpd/conf/caroot/vmCA.pem"
if ($LASTEXITCODE -ne 0) { throw "scp of VM CA cert failed." }
& scp -o StrictHostKeyChecking=no -o BatchMode=yes $VmCaKey "${VmUser}@${VmIp}:/var/lib/mpd/conf/caroot/vmCA-key.pem"
if ($LASTEXITCODE -ne 0) { throw "scp of VM CA key failed." }
Invoke-Ssh -User $VmUser -RemoteHost $VmIp -Command "chmod 644 /var/lib/mpd/conf/caroot/rootCA.pem /var/lib/mpd/conf/caroot/vmCA.pem && chmod 600 /var/lib/mpd/conf/caroot/vmCA-key.pem && rm -f /var/lib/mpd/conf/caroot/rootCA-key.pem"
Write-Ok "CA material uploaded (root private key NOT copied)"

# ── 11. Detach cloud-init ISO ─────────────────────────────────────────────────

Write-Step "Detaching cloud-init CD (stops VM, removes DVD, restarts)"

try { Invoke-Ssh -User $VmUser -RemoteHost $VmIp -Command "sudo shutdown -h now" } catch {}

$start = Get-Date
while ((Get-VM -Name $VmName).State -ne "Off" -and ((Get-Date) - $start).TotalSeconds -lt 60) {
    Start-Sleep 2
}
if ((Get-VM -Name $VmName).State -ne "Off") { Stop-VM -Name $VmName -Force }

Get-VMDvdDrive -VMName $VmName | Remove-VMDvdDrive
Remove-Item $SeedIso -Force -ErrorAction SilentlyContinue
Write-Ok "Cloud-init CD removed"

Start-VM -Name $VmName
Write-Info "Waiting for VM to restart..."
Wait-ForSsh -User $VmUser -RemoteHost $VmIp -TimeoutSec 120
Write-Ok "VM back online"

# ── 12. Install packages and build mpd ───────────────────────────────────────

Write-Step "Creating swap file (4 GB)"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
if [ ! -f /swapfile ]; then
    sudo fallocate -l 4G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi
"@
Write-Ok "Swap ready"

# Bootstrap steps 40 + 50: apt install set, mpd build.
# Networking (hostname + netplan) is cloud-init's job on this flow, so
# there is no separate networking step to run.

Write-Step "Bootstrap 40: apt install package set"
Invoke-Ssh -User $VmUser -RemoteHost $VmIp `
    -Command "bash /opt/mpd/bootstrap/40-install-software.sh"
Write-Ok "Packages installed"

Write-Step "Bootstrap 50: build mpd binary"
Invoke-Ssh -User $VmUser -RemoteHost $VmIp `
    -Command "bash /opt/mpd/bootstrap/50-build.sh"
Write-Ok "mpd binary built"
Write-Ok "Bootstrap complete"

# ── 13. Run mpd --vm-setup ───────────────────────────────────────────────────────

Write-Step "Running 'mpd --vm-setup'"

Invoke-Ssh -User $VmUser -RemoteHost $VmIp -Command "mpd --vm-setup"
Write-Ok "mpd --vm-setup complete"

# ── 14. Login banner ──────────────────────────────────────────────────────────

Write-Step "Setting login banner"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
sudo cp /opt/mpd/assets/vm/motd /etc/motd
"@
Write-Ok "Login banner set"

# ── 15. Helper scripts in %USERPROFILE%\.mpd-virt\ ─────────────────────────

Write-Step "Creating helper scripts in $MpdUserDir"

New-Item -ItemType Directory -Force -Path $MpdUserDir | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

[System.IO.File]::WriteAllText((Join-Path $MpdUserDir "mpd.cmd"),
    "@echo off`r`nssh mpd-vm`r`n", $utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $MpdUserDir "start-vm.ps1"), @"
#Requires -RunAsAdministrator
Start-VM -Name '$VmName'
Write-Host "VM '$VmName' started."
"@, $utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $MpdUserDir "stop-vm.ps1"), @"
#Requires -RunAsAdministrator
Save-VM -Name '$VmName'
Write-Host "VM '$VmName' suspended."
"@, $utf8NoBom)

Write-Ok "Helper scripts created"

# ── 16. Desktop shortcut ──────────────────────────────────────────────────────

Write-Step "Creating desktop shortcut"

$WshShell     = New-Object -ComObject WScript.Shell
$ShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "mpd-vm.lnk"
$Shortcut     = $WshShell.CreateShortcut($ShortcutPath)
$sshMpdCmd    = Join-Path $MpdUserDir "mpd.cmd"

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
    $Shortcut.TargetPath = $wt.Source
    $Shortcut.Arguments  = "cmd /k `"$sshMpdCmd`""
} else {
    $Shortcut.TargetPath = "cmd.exe"
    $Shortcut.Arguments  = "/k `"$sshMpdCmd`""
}
$Shortcut.Description = "SSH into the current mpd-vm"
$Shortcut.Save()
Write-Ok "Desktop shortcut: 'mpd-vm'"

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "VM '$VmName' provisioned."
Write-Host "  IP   : $VmIp"
Write-Host "  User : $VmUser"
Write-Host ""
