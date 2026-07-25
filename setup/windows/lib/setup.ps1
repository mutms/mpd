#Requires -RunAsAdministrator
# setup.ps1 -- create a new mpd VM or switch the active VM.
# Called by setup.cmd.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Write-Host ""
Write-Host "Tip: if output freezes unexpectedly, you may have clicked the terminal"
Write-Host "     window (Quick Edit Mode). Press Enter or Escape to resume."
Write-Host ""

# ── Prerequisites ─────────────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Hyper-V PowerShell module not found. Enable: Settings > Optional Features > Hyper-V Management Tools, then reboot."
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

# ── WSL ───────────────────────────────────────────────────────────────────────

Write-Step "WSL"

cmd /c "wsl -d Debian -- true >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    throw "WSL2 with a Debian distro is required. Run: wsl --install -d Debian  (then reboot and re-run setup.cmd)"
}
Write-Ok "WSL + Debian available"

Write-Info "Checking WSL tools (openssl, genisoimage, qemu-utils)..."
$wslCommonSh = Convert-ToWSLPath "$PSScriptRoot\common.sh"
Invoke-WSLScript @"
set -euo pipefail
. '$wslCommonSh'
ensure_wsl_deps
"@
Write-Ok "WSL tools ready"

# ── Required tools (winget) ───────────────────────────────────────────────────

Write-Step "Required tools"

$reqTools = @(
    [PSCustomObject]@{
        Id    = 'Microsoft.WindowsTerminal'
        Name  = 'Windows Terminal'
        Check = { [bool](Get-Command wt -ErrorAction SilentlyContinue) }
    }
)

$winget = Get-Command winget -ErrorAction SilentlyContinue

foreach ($tool in $reqTools) {
    if (& $tool.Check) {
        Write-Ok "$($tool.Name) already installed"
        continue
    }
    if (-not $winget) {
        throw "$($tool.Name) is required. Install 'App Installer' from the Microsoft Store to get winget, then re-run setup.cmd."
    }
    Write-Host ""
    $inp = Read-Host "  $($tool.Name) not found -- install via winget? [Y/n]"
    if ($inp -and $inp -notmatch '^[Yy]') {
        throw "$($tool.Name) is required. Install manually: winget install $($tool.Id)"
    }
    winget install --id $tool.Id --accept-package-agreements --accept-source-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not (& $tool.Check)) {
        throw "$($tool.Name) installation failed. Try: winget install $($tool.Id)"
    }
    Write-Ok "$($tool.Name) installed"
}

# ── Host CA ───────────────────────────────────────────────────────────────────

Write-Step "Host CA"

$CaDir = Join-Path $MpdUserDir "ca"
$CaPem = Join-Path $CaDir "rootCA.pem"
$CaKey = Join-Path $CaDir "rootCA-key.pem"

if ((Test-Path $CaPem) -and (Test-Path $CaKey)) {
    # A root generated before per-VM signing CAs asserts pathlen:0 and
    # cannot sign the intermediate every VM now gets. Fail here rather
    # than at the first TLS handshake in the VM.
    $wslCheckPem = Convert-ToWSLPath $CaPem
    $caText = Invoke-WSLScript "openssl x509 -in '$wslCheckPem' -noout -text"
    if ($caText -match 'pathlen:0') {
        throw @"
The host CA at $CaPem asserts pathlen:0 and cannot sign a per-VM
intermediate. It predates per-VM signing CAs.

Remove $CaDir and re-run this script to generate a replacement, then
re-trust the new CA on this host and in any VM that still trusts the old one.
"@
    }
    Write-Ok "Reusing existing host CA ($CaDir)"
} else {
    New-Item -ItemType Directory -Force -Path $CaDir | Out-Null
    Write-Info "Generating host CA via WSL openssl (takes ~30 s)..."
    $wslCaKey = Convert-ToWSLPath $CaKey
    $wslCaPem = Convert-ToWSLPath $CaPem
    Invoke-WSLScript @"
set -euo pipefail
. '$wslCommonSh'
generate_mpd_ca '$wslCaKey' '$wslCaPem'
"@
    Write-Ok "Host CA generated ($CaDir)"
}

# ── Switch ────────────────────────────────────────────────────────────────────

Write-Step "Hyper-V switch"
Ensure-MpdSwitch

# ── SSH key ───────────────────────────────────────────────────────────────────

Write-Step "SSH key"

$SshKey = $null
foreach ($candidate in @("$env:USERPROFILE\.ssh\id_ed25519.pub", "$env:USERPROFILE\.ssh\id_rsa.pub")) {
    if (Test-Path $candidate) { $SshKey = $candidate; break }
}

if (-not $SshKey) {
    Write-Host ""
    Write-Host "No SSH key found at ~/.ssh/id_ed25519."
    Write-Host "You need one so the scripts can log into the VM automatically."
    Write-Host ""
    Read-Host "Press Enter to generate ~/.ssh/id_ed25519 now (Ctrl-C to abort)"
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
    & ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519"
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed." }
    $SshKey = "$env:USERPROFILE\.ssh\id_ed25519.pub"
}

$SshPubKey = (Get-Content $SshKey -Raw).Trim()
Write-Ok "SSH key: $SshKey"

# ── VM selection ──────────────────────────────────────────────────────────────

Write-Step "VM selection"

$currentOctet = Get-CurrentVmOctet
$vms = @(Get-MpdVMs)

Write-Host ""
if ($vms.Count -gt 0) {
    Write-Host "Existing mpd VMs:"
    foreach ($vm in $vms) {
        $octet = if ($vm.Name -match "$([regex]::Escape($VmNamePrefix))(\d+)$") { [int]$Matches[1] } else { 0 }
        $tag   = if ($octet -eq $currentOctet) { "  <-- current" } else { "" }
        Write-Host ("  {0,-22} {1}{2}" -f $vm.Name, $vm.State, $tag)
    }
    Write-Host ""
    $defaultOctet = $currentOctet
    # If the route points to an octet that isn't a known mpd VM (stale route),
    # fall back to the Running VM, or the first VM in the list.
    if (-not $defaultOctet -or -not ($vms | Where-Object { $_.Name -eq "$VmNamePrefix$defaultOctet" })) {
        $running  = $vms | Where-Object { $_.State -eq 'Running' } | Select-Object -First 1
        $fallback = if ($running) { $running } else { $vms[0] }
        $defaultOctet = if ($fallback.Name -match "$([regex]::Escape($VmNamePrefix))(\d+)$") { [int]$Matches[1] } else { $null }
    }
    $prompt = if ($defaultOctet) { "Enter VM number [$defaultOctet]" } else { "Enter VM number" }
} else {
    Write-Host "No mpd VMs found yet."
    Write-Host ""
    $defaultOctet = 158
    $prompt = "Enter last IP octet for the new VM [$defaultOctet]"
}

$selectedOctet = $null
while (-not $selectedOctet) {
    $inp = Read-Host $prompt
    if (-not $inp -and $defaultOctet) { $inp = "$defaultOctet" }
    $n = 0
    if ($inp -and [int]::TryParse($inp, [ref]$n) -and $n -ge 2 -and $n -le 254) {
        $selectedOctet = $n
    } else {
        Write-Host "    Please enter a number between 2 and 254."
    }
}

$VmName   = "$VmNamePrefix$selectedOctet"
$VmIp     = "$SwitchSubnet.$selectedOctet"
$vmRecord = $vms | Where-Object { $_.Name -eq $VmName }

if ($vmRecord) {
    $VmUser = Get-VmSshUser -VmName $VmName

    if ($selectedOctet -eq $currentOctet) {
        # ── Re-verify current VM ─────────────────────────────────────────────
        Write-Step "Re-verifying current VM ($VmName at $VmIp)"

        if ($vmRecord.State -notin @('Running', 'Saved')) {
            Write-Info "VM state is $($vmRecord.State) -- starting..."
        }
        if ($vmRecord.State -ne 'Running') {
            Start-VM -Name $VmName
            Write-Info "Waiting for SSH..."
            Wait-ForSsh -User $VmUser -RemoteHost $VmIp -TimeoutSec 120
            Write-Ok "VM online"
        }

        & "$PSScriptRoot\configure-client.ps1" -VmIp $VmIp -SshUser $VmUser
        Set-MpdSshConfig    -VmName $VmName -VmIp $VmIp -VmUser $VmUser
        Write-MpdCurrentEnv -VmName $VmName -VmIp $VmIp -VmUser $VmUser

    } else {
        # ── Switch to a different VM ─────────────────────────────────────────
        $currentName = if ($currentOctet) { "$VmNamePrefix$currentOctet" } else { "(none)" }
        Write-Host ""
        $inp = Read-Host "Suspend $currentName and switch to $VmName? [Y/n]"
        if ($inp -and $inp -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }

        if ($currentOctet) {
            Write-Step "Suspending $currentName"
            $currentVm = Get-VM -Name "$VmNamePrefix$currentOctet" -ErrorAction SilentlyContinue
            if ($currentVm -and $currentVm.State -eq 'Running') {
                Save-VM -Name "$VmNamePrefix$currentOctet"
                Write-Ok "Suspended"
            } else {
                Write-Ok "Already stopped/saved"
            }
        }

        Clear-MpdKnownHosts -VmIp $VmIp

        Write-Step "Starting $VmName"
        Start-VM -Name $VmName
        Write-Info "Waiting for SSH..."
        Wait-ForSsh -User $VmUser -RemoteHost $VmIp -TimeoutSec 180
        Write-Ok "SSH ready"

        & "$PSScriptRoot\configure-client.ps1" -VmIp $VmIp -SshUser $VmUser
        Set-MpdSshConfig    -VmName $VmName -VmIp $VmIp -VmUser $VmUser
        Write-MpdCurrentEnv -VmName $VmName -VmIp $VmIp -VmUser $VmUser
    }

} else {
    # ── Create new VM ────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "No VM named '$VmName' found -- creating a new one."
    Write-Host ""

    $rawUser     = ($env:USERNAME -split '\\')[-1]
    $VmUserGuess = ($rawUser.ToLower() -replace '[^a-z0-9-]', '')
    if (-not $VmUserGuess) { $VmUserGuess = "dev" }

    $inp = Read-Host "Username on the VM [$VmUserGuess]"
    if ($inp) {
        if ($inp -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Username must start with a letter or digit and contain only a-z, 0-9, hyphens."
        }
        $VmUser = $inp
    } else {
        $VmUser = $VmUserGuess
    }

    $VmMemoryGb = 8
    $inp = Read-Host "Memory in GB [$VmMemoryGb]"
    if ($inp) {
        $n = 0
        if (-not [int]::TryParse($inp, [ref]$n) -or $n -lt 2) { throw "Memory must be >= 2 GB." }
        $VmMemoryGb = $n
    }

    $DiskSizeGb = 200
    $inp = Read-Host "Disk size in GB [$DiskSizeGb]"
    if ($inp) {
        $n = 0
        if (-not [int]::TryParse($inp, [ref]$n) -or $n -lt 8) { throw "Disk size must be >= 8 GB." }
        $DiskSizeGb = $n
    }

    if ($currentOctet) {
        $currentName = "$VmNamePrefix$currentOctet"
        Write-Step "Suspending $currentName"
        $currentVm = Get-VM -Name $currentName -ErrorAction SilentlyContinue
        if ($currentVm -and $currentVm.State -eq 'Running') {
            Save-VM -Name $currentName
            Write-Ok "Suspended"
        } else {
            Write-Ok "Already stopped/saved"
        }
    }

    Write-Host ""
    Write-Host "Creating VM: name=$VmName  IP=$VmIp  user=$VmUser  memory=${VmMemoryGb}GB  disk=${DiskSizeGb}GB"
    Write-Host ""

    & "$PSScriptRoot\create-vm.ps1" `
        -VmOctet    $selectedOctet `
        -VmUser     $VmUser `
        -SshPubKey  $SshPubKey `
        -VmMemoryGb $VmMemoryGb `
        -DiskSizeGb $DiskSizeGb

    & "$PSScriptRoot\configure-client.ps1" -VmIp $VmIp -SshUser $VmUser

    # Pre-warm the demo stack so the user's first `demo moodle ...` is
    # fast (PHP runtime image build + postgres pull are the slow bits).
    # Best-effort: a failure here just means lazy provisioning later.
    Write-Step "Pre-warming demo runtime and database"
    & ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${VmUser}@${VmIp}" 'mpd --runtime-create=php'
    if ($LASTEXITCODE -eq 0) { Write-Ok "PHP runtime built" }
    else                     { Write-Host "    warn: PHP runtime pre-warm failed; demo will provision on first run" }
    & ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${VmUser}@${VmIp}" 'mpd --db-create=postgres:latest'
    if ($LASTEXITCODE -eq 0) { Write-Ok "postgres:latest ready" }
    else                     { Write-Host "    warn: postgres:latest pre-warm failed; demo will provision on first run" }

    Set-MpdSshConfig    -VmName $VmName -VmIp $VmIp -VmUser $VmUser
    Write-MpdCurrentEnv -VmName $VmName -VmIp $VmIp -VmUser $VmUser
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Your mpd-vm is ready!"            -ForegroundColor Green
Write-Host "  Double-click the desktop icon to connect." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
