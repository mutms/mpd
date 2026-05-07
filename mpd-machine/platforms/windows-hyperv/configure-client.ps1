#Requires -RunAsAdministrator
# setup-host.ps1 - Configure Windows host networking for mpd-machine on Hyper-V.
# Idempotent: safe to run multiple times.
#
# What it does:
#   1. Adds a persistent route so Windows can reach the container subnet (10.163.0.0/24)
#      through the VM.
#   2. Adds an NRPT rule so Windows resolves *.mpd.test via the dnsmasq container.
#   3. Fetches the mpd CA certificate from the VM and imports it into the Windows
#      trusted root store so browsers accept *.mpd.test HTTPS without warnings.
#
# Usage (from an elevated PowerShell prompt):
#   powershell -ExecutionPolicy Bypass -File setup-host.ps1 -VmIp 172.19.108.153
#   powershell -ExecutionPolicy Bypass -File setup-host.ps1 -VmIp 172.19.108.153 -SshUser skodak

param(
    [Parameter(Mandatory, HelpMessage="IP address of the mpd-machine VM on the Hyper-V network")]
    [string]$VmIp,

    [string]$SshUser = $env:USERNAME
)

$ErrorActionPreference = "Stop"

$ContainerPrefix  = "10.163.0.0/24"
$ContainerSubnet  = "10.163.0.0"
$ContainerMask    = "255.255.255.0"
$DnsmasqIp        = "10.163.0.3"
$NrptNamespace    = ".mpd.test"
$CaCertRemote     = "~/Developer/mpd/conf/caroot/rootCA.pem"

function Write-Step { param([string]$Text) Write-Host "`n--- $Text" }
function Write-Ok   { param([string]$Text) Write-Host "    ok: $Text" }
function Write-Skip { param([string]$Text) Write-Host "    skip: $Text (already correct)" }

# ── 1. Persistent route ──────────────────────────────────────────────────────

Write-Step "Route $ContainerSubnet/24 via $VmIp"

$correct = Get-NetRoute -DestinationPrefix $ContainerPrefix -ErrorAction SilentlyContinue |
           Where-Object { $_.NextHop -eq $VmIp }

if ($correct) {
    Write-Skip "route $ContainerSubnet/24 -> $VmIp"
} else {
    $stale = Get-NetRoute -DestinationPrefix $ContainerPrefix -ErrorAction SilentlyContinue
    if ($stale) {
        Write-Host "    removing stale route (was via $($stale.NextHop)) ..."
        $stale | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    route add $ContainerSubnet mask $ContainerMask $VmIp -p | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "route add failed"; exit 1 }
    Write-Ok "persistent route added"
}

# ── 2. NRPT rule ─────────────────────────────────────────────────────────────

Write-Step "NRPT rule $NrptNamespace -> $DnsmasqIp"

$existing = @(Get-DnsClientNrptRule | Where-Object { $_.Namespace -eq $NrptNamespace })
$isCorrect = ($existing.Count -eq 1) -and ($existing[0].NameServers -contains $DnsmasqIp)

if ($isCorrect) {
    Write-Skip "NRPT rule $NrptNamespace -> $DnsmasqIp"
} else {
    if ($existing) {
        Write-Host "    removing $($existing.Count) stale NRPT rule(s) ..."
        $existing | Remove-DnsClientNrptRule -Force
    }
    Add-DnsClientNrptRule -Namespace $NrptNamespace -NameServers $DnsmasqIp
    Write-Ok "NRPT rule added"
}

# ── 3. CA certificate ─────────────────────────────────────────────────────────

Write-Step "mpd CA certificate"

$TempCert = Join-Path $env:TEMP "mpd-rootCA.pem"
Write-Host "    fetching from ${SshUser}@${VmIp} ..."
scp "${SshUser}@${VmIp}:${CaCertRemote}" $TempCert
if ($LASTEXITCODE -ne 0) { Write-Error "scp failed - is the VM running and reachable at $VmIp?"; exit 1 }

try {
    $newCert    = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $TempCert
    $thumbprint = $newCert.Thumbprint

    $inStore = Get-ChildItem Cert:\LocalMachine\Root |
               Where-Object { $_.Thumbprint -eq $thumbprint }

    if ($inStore) {
        Write-Skip "CA cert (thumbprint $thumbprint)"
    } else {
        # Remove stale mpd CA certs (same subject, different thumbprint after mpd --uninstall + reinstall)
        $stale = Get-ChildItem Cert:\LocalMachine\Root |
                 Where-Object { $_.Subject -match "mpd\.test local development CA" }
        if ($stale) {
            Write-Host "    removing $($stale.Count) stale CA cert(s) ..."
            $stale | ForEach-Object { Remove-Item "Cert:\LocalMachine\Root\$($_.Thumbprint)" }
        }
        Import-Certificate -FilePath $TempCert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-Ok "CA cert imported (thumbprint $thumbprint)"
    }
} finally {
    Remove-Item $TempCert -Force -ErrorAction SilentlyContinue
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Host networking configured. Open https://mpd.test to reach the portal."
