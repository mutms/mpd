# common.ps1 -- shared constants and helpers for the windows platform.
# Dot-source this from every lib/*.ps1 script:  . "$PSScriptRoot\common.ps1"

$MpdRepo        = "https://github.com/mutms/mpd.git"
$SwitchName     = "mpd"
$SwitchSubnet   = "10.164.0"
$GwIp           = "10.164.0.1"
$PrefixLen      = 24
$ContainerSubnet = "10.163.0.0/24"
$DnsmasqIp      = "10.163.0.3"
$VmNamePrefix   = "mpd-"
$CloudBase      = "https://cloud.debian.org/images/cloud/trixie/20260501-2465"
$CloudFile      = "debian-13-genericcloud-amd64-20260501-2465.tar.xz"
$CacheDir       = Join-Path $env:LOCALAPPDATA "mpd\cache"
$TempDir        = Join-Path $env:TEMP "mpd-vm-build"
$MpdUserDir     = Join-Path $env:USERPROFILE ".mpd-virt"

# ── Output helpers ────────────────────────────────────────────────────────────

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" }
function Write-Ok   { param([string]$Text) Write-Host "    ok: $Text" }
function Write-Info { param([string]$Text) Write-Host "    $Text" }

# ── VM helpers ────────────────────────────────────────────────────────────────

function Get-MpdVMs {
    # Only match the numeric-suffix flavor (mpd-158 etc.).
    # mpd-sandbox and other non-numeric suffixes belong to other
    # platforms (sandbox) and must not be enumerated here.
    Get-VM -Name "$VmNamePrefix*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$VmNamePrefix\d+$" } |
        Sort-Object Name
}

function Get-CurrentVmOctet {
    $route = Get-NetRoute -DestinationPrefix $ContainerSubnet -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $route) { return $null }
    if ($route.NextHop -match "$([regex]::Escape($SwitchSubnet))\.(\d+)") { return [int]$Matches[1] }
    return $null
}

function Get-VmSshUser {
    param([string]$VmName)
    # Per-VM file written by Write-MpdCurrentEnv -- survives SSH config rewrites on switch.
    $vmEnv = Join-Path $MpdUserDir "$VmName.env"
    if (Test-Path $vmEnv) {
        foreach ($line in Get-Content $vmEnv) {
            if ($line -match '^MPD_VM_USER=(.+)') { return $Matches[1].Trim() }
        }
    }
    $configPath = Join-Path $env:USERPROFILE ".ssh\config"
    if (-not (Test-Path $configPath)) { return $env:USERNAME }
    $inBlock = $false
    foreach ($line in Get-Content $configPath) {
        if ($line -match "^\s*Host\s+.*\b$([regex]::Escape($VmName))\b") { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -match "^\s*Host\s") { break }
            if ($line -match "^\s*User\s+(.+)") { return $Matches[1].Trim() }
        }
    }
    return $env:USERNAME
}

# ── Switch setup ──────────────────────────────────────────────────────────────

function Ensure-MpdSwitch {
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        Write-Ok "Created Hyper-V switch '$SwitchName'"
    } else {
        Write-Ok "Hyper-V switch '$SwitchName' already exists"
    }

    $hostAddr = Get-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" `
                    -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $hostAddr -or $hostAddr.IPAddress -ne $GwIp) {
        if ($hostAddr) {
            Remove-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" `
                -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        }
        New-NetIPAddress -IPAddress $GwIp -PrefixLength $PrefixLen `
            -InterfaceAlias "vEthernet ($SwitchName)" | Out-Null
        Write-Ok "Host adapter: $GwIp/$PrefixLen"
    } else {
        Write-Ok "Host adapter already at $GwIp/$PrefixLen"
    }

    if (-not (Get-NetNat -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $SwitchName `
            -InternalIPInterfaceAddressPrefix "$SwitchSubnet.0/$PrefixLen" | Out-Null
        Write-Ok "NAT created for $SwitchSubnet.0/$PrefixLen"
    } else {
        Write-Ok "NAT '$SwitchName' already exists"
    }

    Set-NetConnectionProfile -InterfaceAlias "vEthernet ($SwitchName)" `
        -NetworkCategory Private -ErrorAction SilentlyContinue
    Write-Ok "Network profile: Private"
}

# ── WSL helpers ───────────────────────────────────────────────────────────────

# Convert a Windows absolute path to a WSL /mnt/... path.
function Convert-ToWSLPath {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):\\(.*)') {
        return "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')"
    }
    throw "Cannot convert to WSL path: $Path"
}

# Run a bash script in WSL Debian via a temp file. Throws on non-zero exit.
# Use PS @"..."@ heredocs to build multi-line scripts; PS variables expand normally.
function Invoke-WSLScript {
    param([string]$Script)
    $tmp = [System.IO.Path]::GetTempFileName() + ".sh"
    $lf  = $Script -replace "`r`n", "`n" -replace "`r", "`n"
    try {
        [System.IO.File]::WriteAllText($tmp, $lf, [System.Text.UTF8Encoding]::new($false))
        $wslPath = Convert-ToWSLPath $tmp
        wsl -d Debian -u root -- bash -e "$wslPath"
        if ($LASTEXITCODE -ne 0) { throw "WSL script failed." }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ── known_hosts cleanup ───────────────────────────────────────────────────────

function Clear-MpdKnownHosts {
    param([string]$VmIp = "")
    $path = Join-Path $env:USERPROFILE ".ssh\known_hosts"
    if (Test-Path $path) {
        $filtered = Get-Content $path | Where-Object {
            $_ -notmatch "^10\.163\.0\." -and $_ -notmatch "\.mpd\.test"
        }
        [System.IO.File]::WriteAllLines($path, $filtered, [System.Text.UTF8Encoding]::new($false))
    }
    if ($VmIp) { cmd /c "ssh-keygen -R $VmIp >nul 2>&1" }
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

function Invoke-Ssh {
    param([string]$User, [string]$RemoteHost, [string]$Command)
    & ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${User}@${RemoteHost}" $Command
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed on ${RemoteHost}: $Command" }
}

function Send-SshScript {
    # Copies a bash script to the VM via scp and runs it -- avoids all
    # PowerShell stdin/CRLF issues. Use backtick-dollar (`$) for bash
    # variables that must not be expanded by PowerShell.
    param([string]$User, [string]$RemoteHost, [string]$Script)
    $lf  = $Script -replace "`r`n", "`n" -replace "`r", "`n"
    $tmp = [System.IO.Path]::GetTempFileName() + ".sh"
    try {
        [System.IO.File]::WriteAllText($tmp, $lf, [System.Text.UTF8Encoding]::new($false))
        & scp -q -o StrictHostKeyChecking=no -o BatchMode=yes $tmp "${User}@${RemoteHost}:/tmp/_mpd_script.sh"
        if ($LASTEXITCODE -ne 0) { throw "scp failed uploading script to ${RemoteHost}" }
        & ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${User}@${RemoteHost}" `
            "bash -e /tmp/_mpd_script.sh; rm -f /tmp/_mpd_script.sh"
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

# ── SSH config + current-VM state ─────────────────────────────────────────────

# Managed `Host mpd-vm ...` block in ~/.ssh/config is bracketed with
# explicit start/end markers so re-runs are idempotent (the previous comment-
# only delimiter form leaked the `Host mpd-vm` line on every switch).

$SshBlockStart = "# >>> mpd-vm (managed by windows) >>>"
$SshBlockEnd   = "# <<< mpd-vm <<<"

# Strip any existing mpd-vm block (new marker form OR legacy formats
# left over from earlier setup runs). Returns kept lines as a List[string].
function Strip-MpdSshConfigBlock {
    param([string]$Path)
    $kept = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $Path)) { return $kept }
    $inMarker    = $false
    $inHostBlock = $false
    foreach ($line in (Get-Content $Path)) {
        if ($line -eq $SshBlockStart)              { $inMarker = $true; continue }
        if ($inMarker -and $line -eq $SshBlockEnd) { $inMarker = $false; continue }
        if ($inMarker)                             { continue }
        # Legacy `# mpd-vm (...)` standalone comment — drop.
        if ($line -match "^# mpd-vm\b")       { continue }
        # Legacy `Host mpd-vm ...` block — drop start + indented body.
        if ($line -match "^Host\s+mpd-vm\b")  { $inHostBlock = $true; continue }
        if ($inHostBlock) {
            if ($line -match "^\s+")               { continue }
            $inHostBlock = $false
        }
        $kept.Add($line)
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') {
        $kept.RemoveAt($kept.Count - 1)
    }
    return $kept
}

function Set-MpdSshConfig {
    param([string]$VmName, [string]$VmIp, [string]$VmUser)
    $dir  = Join-Path $env:USERPROFILE ".ssh"
    $path = Join-Path $dir "config"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $kept = Strip-MpdSshConfigBlock -Path $path

    $newLines = @(
        $SshBlockStart,
        "Host mpd-vm $VmName",
        "    HostName $VmIp",
        "    User $VmUser",
        "    StrictHostKeyChecking no",
        $SshBlockEnd
    )
    if ($kept.Count -gt 0) {
        $all = @($kept) + @('') + $newLines
    } else {
        $all = $newLines
    }
    [System.IO.File]::WriteAllLines($path, $all, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "SSH config: 'ssh mpd-vm' -> $VmIp ($VmUser)"
}

function Remove-MpdSshConfig {
    $path = Join-Path $env:USERPROFILE ".ssh\config"
    if (-not (Test-Path $path)) { return }
    $kept = Strip-MpdSshConfigBlock -Path $path
    if ($null -eq $kept) { $kept = [System.Collections.Generic.List[string]]::new() }
    [System.IO.File]::WriteAllLines($path, $kept, [System.Text.UTF8Encoding]::new($false))
}

function Write-MpdCurrentEnv {
    param([string]$VmName, [string]$VmIp, [string]$VmUser)
    New-Item -ItemType Directory -Force -Path $MpdUserDir | Out-Null
    $utf8    = [System.Text.UTF8Encoding]::new($false)
    $content = "MPD_VM_NAME=$VmName`nMPD_VM_IP=$VmIp`nMPD_VM_USER=$VmUser`n"

    # Per-VM identity -- lets Get-VmSshUser find the right user after a switch.
    [System.IO.File]::WriteAllText((Join-Path $MpdUserDir "$VmName.env"), $content, $utf8)

    # Current pointer -- overwritten on every create/switch/reverify.
    [System.IO.File]::WriteAllText((Join-Path $MpdUserDir "current.env"), $content, $utf8)

    $sshCmd = Join-Path $MpdUserDir "mpd.cmd"
    if (-not (Test-Path $sshCmd)) {
        [System.IO.File]::WriteAllText($sshCmd, "@echo off`r`nssh mpd-vm`r`n", $utf8)
    }
    Write-Ok "current.env updated ($VmName at $VmIp)"
}
