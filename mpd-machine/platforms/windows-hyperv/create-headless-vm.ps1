#Requires -RunAsAdministrator
# create-headless-vm.ps1 - Create a headless Debian Trixie VM on Hyper-V for mpd-machine.
#
# Uses the Debian cloud image - no manual installation required.
# Cloud-init configures the VM automatically on first boot:
#   - Creates a user matching your Windows username with your SSH key
#   - Grows the root partition to fill the disk
#   - Installs git, enables SSH
#
# Prerequisites:
#   - Windows 10/11 Pro or Enterprise with Hyper-V enabled
#   - SSH key at ~/.ssh/id_ed25519 or ~/.ssh/id_rsa  (prompted if missing)
#
# Usage (from an elevated PowerShell prompt):
#   powershell -ExecutionPolicy Bypass -File create-headless-vm.ps1
#   powershell -ExecutionPolicy Bypass -File create-headless-vm.ps1 -VmOctet 158 -DiskSizeGb 200

param(
    [int]$VmOctet    = 158,   # last octet of the VM static IP -- drives VM name + hostname
    [int]$DiskSizeGb = 200,   # disk size in GB; cloud image is ~3 GB, expanded to fill this
    [int]$VmMemoryGb = 8,
    [int]$VmCpuCount = 4
)

$ErrorActionPreference = "Stop"

# ── Constants ────────────────────────────────────────────────────────────────

$MpdRepo    = "https://github.com/mutms/mpd.git"
$SwitchName = "mpd"
$SwitchSubnet = "10.164.0"
$GwIp       = "10.164.0.1"
$PrefixLen  = 24
$CloudBase  = "https://cloud.debian.org/images/cloud/trixie/20260501-2465"
$CloudFile  = "debian-13-genericcloud-amd64-20260501-2465.tar.xz"
$CacheDir   = Join-Path $env:LOCALAPPDATA "mpd\cache"
$TempDir    = Join-Path $env:TEMP "mpd-vm-build"
$MpdUserDir = Join-Path $env:USERPROFILE "mpd"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" }
function Write-Ok   { param([string]$Text) Write-Host "    ok: $Text" }
function Write-Info { param([string]$Text) Write-Host "    $Text" }

function Invoke-QemuImg {
    # Calls qemu-img, routing through WSL and converting paths if needed.
    if ($script:QemuImgViaWsl) {
        $wslArgs = $args | ForEach-Object {
            if ($_ -match '^[A-Za-z]:\\') {
                $fwd = $_ -replace '\\', '/'
                (wsl wslpath -u "$fwd").Trim()
            } else { $_ }
        }
        wsl qemu-img @wslArgs
    } else {
        & qemu-img @args
    }
    if ($LASTEXITCODE -ne 0) { throw "qemu-img failed." }
}

function Invoke-Ssh {
    param([string]$User, [string]$RemoteHost, [string]$Command)
    & ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${User}@${RemoteHost}" $Command
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed on ${RemoteHost}: $Command" }
}

function Send-SshScript {
    # Copies a bash script to the VM via scp, runs it, then deletes it.
    # Avoids all PowerShell stdin/CRLF issues. PowerShell variables in the
    # script string are expanded before sending; use backtick-dollar (`$) for
    # bash variables that must survive as literals (e.g. `$HOME, `$USER).
    param([string]$User, [string]$RemoteHost, [string]$Script)
    $lf = $Script -replace "`r`n", "`n" -replace "`r", "`n"
    $tmp = [System.IO.Path]::GetTempFileName() + ".sh"
    try {
        [System.IO.File]::WriteAllText($tmp, $lf, [System.Text.UTF8Encoding]::new($false))
        & scp -o StrictHostKeyChecking=no -o BatchMode=yes $tmp "${User}@${RemoteHost}:/tmp/_mpd_script.sh"
        if ($LASTEXITCODE -ne 0) { throw "scp failed uploading script to ${RemoteHost}" }
        & ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${User}@${RemoteHost}" "bash -e /tmp/_mpd_script.sh; rm -f /tmp/_mpd_script.sh"
        if ($LASTEXITCODE -ne 0) { throw "Remote script failed on ${RemoteHost}" }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForSsh {
    param([string]$User, [string]$RemoteHost, [int]$TimeoutSec = 300, [string]$Label = "")
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        cmd /c "ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR `"${User}@${RemoteHost}`" true >nul 2>&1"
        if ($LASTEXITCODE -eq 0) { return }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed -gt 0 -and $elapsed % 30 -eq 0) {
            Write-Info "Still waiting... (${elapsed}s / ${TimeoutSec}s) $Label"
        }
        Start-Sleep 5
    }
    throw "SSH not available at ${RemoteHost} after ${TimeoutSec}s."
}

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

function New-SeedIso {
    # Creates a cloud-init NoCloud seed ISO using Windows IMAPI2 (no external
    # tools). Volume label must be CIDATA for cloud-init to recognise it.
    param([string]$SourceDir, [string]$Destination)

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3  # ISO9660 + Joliet
    $fsi.VolumeName = "CIDATA"

    Get-ChildItem $SourceDir -File | ForEach-Object {
        $fsi.Root.AddTree($_.FullName, $false)
    }

    $imageResult = $fsi.CreateResultImage()
    [IsoStreamHelper]::WriteToFile($imageResult.ImageStream, $Destination)

    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($imageResult) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)         | Out-Null
}

# ── 1. Prerequisites ─────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Tip: if output freezes unexpectedly, you may have clicked in the terminal"
Write-Host "     window (Quick Edit Mode). Press Enter or Escape to resume."
Write-Host ""

Write-Step "Checking prerequisites"

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Hyper-V PowerShell module not found. Enable it: Settings > Optional Features > Hyper-V Management Tools, then reboot."
}
try { Get-VMHost | Out-Null } catch {
    throw "Hyper-V is not running. Enable it in Windows Features and reboot."
}
Write-Ok "Hyper-V available"

foreach ($tool in @("ssh", "ssh-keygen", "scp")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found. Enable OpenSSH Client: Settings > Optional Features > OpenSSH Client."
    }
}
Write-Ok "SSH tools available"

$script:QemuImgViaWsl = $false
if (Get-Command qemu-img -ErrorAction SilentlyContinue) {
    Write-Ok "qemu-img: $(qemu-img --version | Select-Object -First 1)"
} else {
    $wslCheck = cmd /c "wsl which qemu-img 2>nul"
    if ($LASTEXITCODE -eq 0 -and $wslCheck) {
        $script:QemuImgViaWsl = $true
        Write-Ok "qemu-img: found in WSL ($($wslCheck.Trim()))"
    } else {
        Write-Host ""
        Write-Host "qemu-img is required to convert the disk image to VHDX format."
        Write-Host "It can be installed via: winget install cloudbase.qemu-img"
        Write-Host ""
        $confirm = Read-Host "Install qemu-img now? [Y/n]"
        if ($confirm -and $confirm -notmatch '^[Yy]') {
            throw "qemu-img is required. Install it manually: winget install cloudbase.qemu-img"
        }
        winget install --id cloudbase.qemu-img --accept-package-agreements --accept-source-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) {
            throw "qemu-img install failed. Try manually: winget install cloudbase.qemu-img"
        }
        Write-Ok "qemu-img: $(qemu-img --version | Select-Object -First 1)"
    }
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Ok "Created Hyper-V switch '$SwitchName'"
} else {
    Write-Ok "Hyper-V switch '$SwitchName' already exists"
}

$hostAddr = Get-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -AddressFamily IPv4 -ErrorAction SilentlyContinue
if (-not $hostAddr -or $hostAddr.IPAddress -ne $GwIp) {
    if ($hostAddr) { Remove-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue }
    New-NetIPAddress -IPAddress $GwIp -PrefixLength $PrefixLen -InterfaceAlias "vEthernet ($SwitchName)" | Out-Null
    Write-Ok "Host adapter: $GwIp/$PrefixLen"
} else {
    Write-Ok "Host adapter already at $GwIp/$PrefixLen"
}

if (-not (Get-NetNat -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $SwitchName -InternalIPInterfaceAddressPrefix "$SwitchSubnet.0/$PrefixLen" | Out-Null
    Write-Ok "NAT created for $SwitchSubnet.0/$PrefixLen"
} else {
    Write-Ok "NAT '$SwitchName' already exists"
}

Set-NetConnectionProfile -InterfaceAlias "vEthernet ($SwitchName)" -NetworkCategory Private
Write-Ok "Network profile: Private"

# ── 2. SSH key ───────────────────────────────────────────────────────────────

Write-Step "SSH key"

$SshKey = $null
foreach ($candidate in @("$env:USERPROFILE\.ssh\id_ed25519.pub", "$env:USERPROFILE\.ssh\id_rsa.pub")) {
    if (Test-Path $candidate) { $SshKey = $candidate; break }
}

if (-not $SshKey) {
    Write-Host ""
    Write-Host "No SSH key found at ~/.ssh/id_ed25519."
    Write-Host "You need one so the script can log into the VM automatically."
    Write-Host "You will be asked for a passphrase -- optional but recommended."
    Write-Host ""
    Read-Host "Press Enter to generate ~/.ssh/id_ed25519 now (Ctrl-C to abort)"
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
    & ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519"
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
    $SshKey = "$env:USERPROFILE\.ssh\id_ed25519.pub"
}

$SshPubKey = (Get-Content $SshKey -Raw).Trim()
Write-Ok "SSH key: $SshKey"

# ── 3. VM identity ───────────────────────────────────────────────────────────

Write-Step "VM identity"

# Suggest a username derived from Windows username as a starting point.
$rawUser     = ($env:USERNAME -split '\\')[-1]
$VmUserGuess = ($rawUser.ToLower() -replace '[^a-z0-9-]', '')
if (-not $VmUserGuess) { $VmUserGuess = "dev" }

Write-Host ""
$inp = Read-Host "Username on the VM [$VmUserGuess]"
if ($inp) {
    if ($inp -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Username must start with a letter or digit and contain only a-z, 0-9, hyphens."
    }
    $VmUser = $inp
} else {
    $VmUser = $VmUserGuess
}

$inp = Read-Host "Last IP octet for VM ($SwitchSubnet.NN, also VM name suffix) [$VmOctet]"
if ($inp) {
    $n = 0
    if (-not [int]::TryParse($inp, [ref]$n) -or $n -lt 2 -or $n -gt 254) {
        throw "Octet must be a whole number 2..254."
    }
    $VmOctet = $n
}

$inp = Read-Host "Memory in GB [$VmMemoryGb]"
if ($inp) {
    $n = 0
    if (-not [int]::TryParse($inp, [ref]$n) -or $n -lt 2) {
        throw "Memory must be a whole number >= 2."
    }
    $VmMemoryGb = $n
}

$inp = Read-Host "Disk size in GB (minimum 8) [$DiskSizeGb]"
if ($inp) {
    $n = 0
    if (-not [int]::TryParse($inp, [ref]$n) -or $n -lt 8) {
        throw "Disk size must be a whole number >= 8."
    }
    $DiskSizeGb = $n
}

$VmName = "mpd-machine-$VmOctet"
$VmIp   = "$SwitchSubnet.$VmOctet"

Write-Ok "VM: name=$VmName  IP=$VmIp  user=$VmUser  disk=${DiskSizeGb}GB"

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "VM '$VmName' already exists in Hyper-V. Delete it first or pick a different octet."
}

# ── 4. Download cloud image ──────────────────────────────────────────────────

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

# ── 5. Extract raw image ─────────────────────────────────────────────────────

Write-Info "Extracting raw disk image..."
& tar -xJf $CachedArchive -C $TempDir
if ($LASTEXITCODE -ne 0) { throw "tar extraction failed." }

$RawFile = Get-ChildItem $TempDir -Recurse -Filter "*.raw" | Select-Object -First 1
if (-not $RawFile) { throw "Could not find disk image in the archive. Contents: $(Get-ChildItem $TempDir -Recurse | Select-Object -ExpandProperty Name)" }
Write-Ok "Disk image: $($RawFile.Name)"

# ── 6. Convert raw -> VHDX and resize ────────────────────────────────────────

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

# ── 7. Cloud-init seed ISO ───────────────────────────────────────────────────

Write-Step "Creating cloud-init configuration"

$CidataDir = Join-Path $TempDir "cidata"
New-Item -ItemType Directory -Force -Path $CidataDir | Out-Null

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

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

# ── 8. Create Hyper-V VM ─────────────────────────────────────────────────────

Write-Step "Creating VM '$VmName' in Hyper-V"

New-VM -Name $VmName -MemoryStartupBytes ($VmMemoryGb * 1GB) -Generation 2 `
       -SwitchName $SwitchName -NoVHD | Out-Null
Set-VMProcessor -VMName $VmName -Count $VmCpuCount
Set-VM -VMName $VmName -AutomaticStartAction Start -AutomaticStopAction ShutDown `
       -CheckpointType Disabled
Add-VMHardDiskDrive -VMName $VmName -Path $VhdxPath `
       -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0
Add-VMDvdDrive -VMName $VmName -Path $SeedIso `
       -ControllerNumber 0 -ControllerLocation 1
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off

# Boot order: DVD first (cloud-init), then disk -- network adapter excluded
# to avoid a slow PXE timeout on every boot.
$boot     = (Get-VMFirmware -VMName $VmName).BootOrder
$dvdBoot  = @($boot | Where-Object { $_.Device.GetType().Name -match "Dvd" })
$diskBoot = @($boot | Where-Object { $_.Device.GetType().Name -match "HardDisk" })
Set-VMFirmware -VMName $VmName -BootOrder ($dvdBoot + $diskBoot)

Write-Ok "VM created"

# ── 9. Start VM and wait for cloud-init ──────────────────────────────────────

Write-Step "Starting VM (cloud-init runs on first boot -- takes 2-5 minutes)"

# Clear any stale SSH known-hosts entries from a previous VM at this IP
cmd /c "ssh-keygen -R $VmIp >nul 2>&1"
cmd /c "ssh-keygen -R $VmName >nul 2>&1"

Start-VM -Name $VmName
Write-Ok "VM started"

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

# ── 10. Clone mpd repository ─────────────────────────────────────────────────

Write-Step "Cloning mpd repository in VM"

# Note: backtick-dollar (`$) passes bash variables through PS expansion intact.
Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
if ! command -v git >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends git
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

# ── 11. Write platform identity ───────────────────────────────────────────────

Write-Step "Writing platform identity"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
mkdir -p "`$HOME/Developer/mpd/conf"
cat > "`$HOME/Developer/mpd/conf/platform.env" <<'PLATFORM_EOF'
# mpd platform identity - written by windows-hyperv/create-headless-vm.ps1.
# Lives under conf/ so it survives mpd --uninstall.
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

# ── 12. Detach cloud-init ISO ─────────────────────────────────────────────────

Write-Step "Detaching cloud-init CD (stops VM, removes DVD, restarts)"

# SSH returns non-zero when the server disconnects during shutdown -- ignore it.
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

# ── 13. Install packages and build mpd ───────────────────────────────────────

Write-Step "Installing build prerequisites (swiftlang + dependencies)"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    build-essential pkg-config make swiftlang \
    git curl libnss3-tools
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift not on PATH after install" >&2; exit 1
fi
"@
Write-Ok "Packages installed"

Write-Step "Building mpd binary"

Send-SshScript -User $VmUser -RemoteHost $VmIp -Script @"
set -e
mkdir -p "`$HOME/.local/bin"
marker='# mpd: ~/.local/bin on PATH for user-installed CLIs'
if ! grep -qF "`$marker" "`$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\n[ -d "`$HOME/.local/bin" ] && PATH="`$HOME/.local/bin:`$PATH"\n' "`$marker" >> "`$HOME/.bashrc"
fi
cd "`$HOME/Developer/mpd"
make install
sudo ln -sf "`$HOME/Developer/mpd/bin/mpd" /usr/local/bin/mpd
"@
Write-Ok "mpd built and installed"

# ── 14. Run mpd --setup ───────────────────────────────────────────────────────

Write-Step "Running 'mpd --setup' (CA, podman network, services)"

Invoke-Ssh -User $VmUser -RemoteHost $VmIp -Command "mpd --setup"
Write-Ok "mpd --setup complete"

# ── 15. Configure Windows client ──────────────────────────────────────────────

Write-Step "Configuring Windows client (route, DNS, CA certificate)"

$SetupClient = Join-Path $PSScriptRoot "configure-client.ps1"
if (Test-Path $SetupClient) {
    & powershell -ExecutionPolicy Bypass -File $SetupClient -VmIp $VmIp -SshUser $VmUser
} else {
    Write-Host "    Warning: configure-client.ps1 not found -- run it manually to configure DNS and routing."
}

# ── 16. Create ~/mpd helper scripts ──────────────────────────────────────────

Write-Step "Creating helper scripts in $MpdUserDir"

New-Item -ItemType Directory -Force -Path $MpdUserDir | Out-Null

Set-Content -Path (Join-Path $MpdUserDir "ssh-vm.ps1") -Encoding UTF8 -Value @"
# Open an SSH session to your mpd-machine VM.
ssh ${VmUser}@${VmIp}
"@

Set-Content -Path (Join-Path $MpdUserDir "start-vm.ps1") -Encoding UTF8 -Value @"
#Requires -RunAsAdministrator
# Start the mpd-machine VM.
Start-VM -Name '$VmName'
Write-Host "VM '$VmName' started."
"@

Set-Content -Path (Join-Path $MpdUserDir "stop-vm.ps1") -Encoding UTF8 -Value @"
#Requires -RunAsAdministrator
# Shut down the mpd-machine VM gracefully.
Stop-VM -Name '$VmName' -Force
Write-Host "VM '$VmName' stopped."
"@

$escapedSetupClient = $SetupClient -replace "'", "''"
Set-Content -Path (Join-Path $MpdUserDir "configure-client.ps1") -Encoding UTF8 -Value @"
#Requires -RunAsAdministrator
# Re-run Windows client networking setup (route, DNS, CA cert).
# Run as Administrator if networking stops working after a host reboot.
powershell -ExecutionPolicy Bypass -File '$escapedSetupClient' -VmIp $VmIp -SshUser $VmUser
"@

Write-Ok "Helper scripts created"

# ── 17. SSH config entry ──────────────────────────────────────────────────────

Write-Step "Adding SSH config entry"

$SshConfigDir  = Join-Path $env:USERPROFILE ".ssh"
$SshConfigPath = Join-Path $SshConfigDir "config"
New-Item -ItemType Directory -Force -Path $SshConfigDir | Out-Null

$existingConfig = if (Test-Path $SshConfigPath) { Get-Content $SshConfigPath -Raw } else { "" }
if ($existingConfig -notmatch "Host mpd-machine") {
    $entry = "`n# mpd-machine ($VmName) - added by create-headless-vm.ps1`nHost mpd-machine $VmName`n    HostName $VmIp`n    User $VmUser`n    StrictHostKeyChecking no`n"
    Add-Content -Path $SshConfigPath -Value $entry -Encoding UTF8
    Write-Ok "SSH config updated -- 'ssh mpd-machine' connects to $VmIp"
} else {
    Write-Ok "SSH config entry already present"
}

# ── 18. Desktop shortcut ──────────────────────────────────────────────────────

Write-Step "Creating desktop shortcut"

$WshShell     = New-Object -ComObject WScript.Shell
$ShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "mpd SSH.lnk"
$Shortcut     = $WshShell.CreateShortcut($ShortcutPath)

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
    $Shortcut.TargetPath = $wt.Source
    $Shortcut.Arguments  = "ssh mpd-machine"
} else {
    $Shortcut.TargetPath = "cmd.exe"
    $Shortcut.Arguments  = "/k ssh mpd-machine"
}
$Shortcut.Description = "SSH into mpd-machine ($VmName at $VmIp)"
$Shortcut.Save()
Write-Ok "Desktop shortcut: 'mpd SSH'"

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "VM bootstrap complete."
Write-Host ""
Write-Host "  SSH into VM:    ssh mpd-machine   (or double-click 'mpd SSH' on the Desktop)"
Write-Host "  Portal:         https://mpd.test"
Write-Host "  Helper scripts: $MpdUserDir"
Write-Host ""
Write-Host "The VM is set to start automatically with Windows."
Write-Host "If networking stops working after a host reboot, run as Administrator:"
Write-Host "  $MpdUserDir\configure-client.ps1"
