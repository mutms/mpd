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

$VmName = "$VmNamePrefix$VmOctet"
$VmIp   = "$SwitchSubnet.$VmOctet"

# ISO creation uses IMAPI2 COM -- type defined locally to avoid double-Add-Type
# when common.ps1 is also dot-sourced by the calling setup.ps1.
if (-not ([System.Management.Automation.PSTypeName]'IsoStreamHelper').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class IsoStreamHelper {
    public static void WriteToFile(object comStream, string path) {
        IStream stream = (IStream)comStream;
        using (var fs = File.Create(path)) {
            var buf = new byte[65536];
            var pRead = Marshal.AllocHGlobal(4);
            try {
                int n;
                do {
                    stream.Read(buf, buf.Length, pRead);
                    n = Marshal.ReadInt32(pRead);
                    if (n > 0) fs.Write(buf, 0, n);
                } while (n > 0);
            } finally { Marshal.FreeHGlobal(pRead); }
        }
    }
}
"@
}

function New-SeedIso {
    param([string]$SourceDir, [string]$Destination)
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3  # ISO9660 + Joliet
    $fsi.VolumeName = "CIDATA"
    Get-ChildItem $SourceDir -File | ForEach-Object { $fsi.Root.AddTree($_.FullName, $false) }
    $imageResult = $fsi.CreateResultImage()
    [IsoStreamHelper]::WriteToFile($imageResult.ImageStream, $Destination)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($imageResult) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)         | Out-Null
}

# ── 1. qemu-img ───────────────────────────────────────────────────────────────

Write-Step "Checking qemu-img"
Initialize-QemuImg

# ── 2. Download cloud image ───────────────────────────────────────────────────

Write-Step "Preparing Debian Trixie cloud image"

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir  | Out-Null

$CachedArchive = Join-Path $CacheDir $CloudFile
if (Test-Path $CachedArchive) {
    Write-Ok "Using cached: $CloudFile"
} else {
    Write-Info "Downloading $CloudFile (~200 MB)..."
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri "$CloudBase/$CloudFile" -OutFile $CachedArchive
    $ProgressPreference = "Continue"
    Write-Ok "Downloaded"
}

# ── 3. Extract raw image ──────────────────────────────────────────────────────

Write-Info "Extracting raw disk image..."
& tar -xJf $CachedArchive -C $TempDir
if ($LASTEXITCODE -ne 0) { throw "tar extraction failed." }

$RawFile = Get-ChildItem $TempDir -Recurse -Filter "*.raw" | Select-Object -First 1
if (-not $RawFile) {
    throw "Could not find disk image in the archive. Contents: $(Get-ChildItem $TempDir -Recurse | Select-Object -ExpandProperty Name)"
}
Write-Ok "Disk image: $($RawFile.Name)"

# ── 4. Convert raw -> VHDX and resize ────────────────────────────────────────

Write-Step "Converting and resizing disk image"

$VmStorePath = Join-Path (Get-VMHost).VirtualHardDiskPath $VmName
New-Item -ItemType Directory -Force -Path $VmStorePath | Out-Null
$VhdxPath = Join-Path $VmStorePath "$VmName.vhdx"

Write-Info "Converting raw -> VHDX (takes a minute)..."
Invoke-QemuImg convert -f raw -O vhdx -o subformat=dynamic $RawFile.FullName $VhdxPath

Write-Info "Resizing to ${DiskSizeGb} GB..."
Resize-VHD -Path $VhdxPath -SizeBytes ($DiskSizeGb * 1GB)
Write-Ok "VHDX ready: $VhdxPath"

Remove-Item $RawFile.FullName -Force

# ── 5. Cloud-init seed ISO ────────────────────────────────────────────────────

Write-Step "Creating cloud-init configuration"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$CidataDir = Join-Path $TempDir "cidata"
New-Item -ItemType Directory -Force -Path $CidataDir | Out-Null

[System.IO.File]::WriteAllText((Join-Path $CidataDir "meta-data"), @"
instance-id: $VmName
local-hostname: $VmName
"@, $utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $CidataDir "user-data"), @"
#cloud-config
users:
  - name: $VmUser
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $SshPubKey

ssh_pwauth: false
"@, $utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $CidataDir "network-config"), @"
version: 2
ethernets:
  ethernet0:
    match:
      name: "eth*"
    set-name: eth0
    addresses:
      - ${VmIp}/${PrefixLen}
    routes:
      - to: default
        via: $GwIp
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
"@, $utf8NoBom)

$SeedIso = Join-Path $TempDir "seed.iso"
New-SeedIso -SourceDir $CidataDir -Destination $SeedIso
Remove-Item $CidataDir -Recurse -Force
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

# ── 8. Clone mpd repository ───────────────────────────────────────────────────

Write-Step "Cloning mpd repository in VM"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
if ! command -v git >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        git curl libnss3-tools hyperv-daemons
fi
mkdir -p "`$HOME/Developer"
mkdir -p "`$HOME/.ssh"
chmod 700 "`$HOME/.ssh"
if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan github.com >> "`$HOME/.ssh/known_hosts"
fi
chmod 600 "`$HOME/.ssh/known_hosts"
git clone $MpdRepo "`$HOME/Developer/mpd"
"@
Write-Ok "Repository cloned"

# ── 9. Write platform identity ────────────────────────────────────────────────

Write-Step "Writing platform identity"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
mkdir -p "`$HOME/Developer/mpd/conf"
cat > "`$HOME/Developer/mpd/conf/platform.env" <<'PLATFORM_EOF'
# mpd platform identity - written by windows-hyperv/lib/create-vm.ps1.
MPD_PLATFORM=windows-hyperv
MPD_CLIENT_OS=windows
MPD_VM_IP=$VmIp
MPD_NETWORK_MODE=static
MPD_NETWORK_PREFIX=$PrefixLen
MPD_NETWORK_GATEWAY=$GwIp
PLATFORM_EOF
chmod 0644 "`$HOME/Developer/mpd/conf/platform.env"
"@
Write-Ok "Platform identity recorded"

# ── 10. Detach cloud-init ISO ─────────────────────────────────────────────────

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

# ── 11. Install packages and build mpd ───────────────────────────────────────

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

Write-Step "Installing build prerequisites (swiftlang + dependencies)"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    build-essential pkg-config make swiftlang
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift not on PATH after install" >&2; exit 1
fi
"@
Write-Ok "Packages installed"

Write-Step "Building mpd binary"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
mkdir -p "`$HOME/.local/bin"
marker='# mpd: ~/.local/bin on PATH'
if ! grep -qF "`$marker" "`$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\n[ -d "`$HOME/.local/bin" ] && PATH="`$HOME/.local/bin:`$PATH"\n' "`$marker" >> "`$HOME/.bashrc"
fi
cd "`$HOME/Developer/mpd"
make install
sudo ln -sf "`$HOME/Developer/mpd/bin/mpd" /usr/local/bin/mpd
"@
Write-Ok "mpd built and installed"

# ── 12. Run mpd --setup ───────────────────────────────────────────────────────

Write-Step "Running 'mpd --setup'"

Invoke-Ssh -User $VmUser -RemoteHost $VmIp -Command "mpd --setup"
Write-Ok "mpd --setup complete"

# ── 13. Auto-start on VM boot ─────────────────────────────────────────────────

Write-Step "Enabling mpd auto-start on VM boot"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
sudo loginctl enable-linger "`$(id -un)"
mkdir -p "`$HOME/.config/systemd/user"
cat > "`$HOME/.config/systemd/user/mpd-autostart.service" << 'UNIT_EOF'
[Unit]
Description=mpd autostart
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mpd --start
RemainAfterExit=yes

[Install]
WantedBy=default.target
UNIT_EOF
systemctl --user daemon-reload
systemctl --user enable mpd-autostart.service
"@
Write-Ok "mpd will start automatically on VM boot"

# ── 14. Login banner ──────────────────────────────────────────────────────────

Write-Step "Setting login banner"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
sudo cp "`$HOME/Developer/mpd/assets/machine/motd" /etc/motd
"@
Write-Ok "Login banner set"

# ── 15. Helper scripts in %USERPROFILE%\mpd\ ─────────────────────────────────

Write-Step "Creating helper scripts in $MpdUserDir"

New-Item -ItemType Directory -Force -Path $MpdUserDir | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

[System.IO.File]::WriteAllText((Join-Path $MpdUserDir "mpd-machine.cmd"),
    "@echo off`r`nssh mpd-machine`r`n", $utf8NoBom)

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
$ShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "mpd-machine.lnk"
$Shortcut     = $WshShell.CreateShortcut($ShortcutPath)
$sshMpdCmd    = Join-Path $MpdUserDir "mpd-machine.cmd"

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
    $Shortcut.TargetPath = $wt.Source
    $Shortcut.Arguments  = "cmd /k `"$sshMpdCmd`""
} else {
    $Shortcut.TargetPath = "cmd.exe"
    $Shortcut.Arguments  = "/k `"$sshMpdCmd`""
}
$Shortcut.Description = "SSH into the current mpd-machine"
$Shortcut.Save()
Write-Ok "Desktop shortcut: 'mpd-machine'"

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "VM '$VmName' provisioned."
Write-Host "  IP   : $VmIp"
Write-Host "  User : $VmUser"
Write-Host ""
