#Requires -RunAsAdministrator
# configure-client.ps1 -- configure Windows networking for an mpd-machine VM.
# Idempotent: safe to run multiple times.
#
# What it does:
#   1. Adds a persistent route so Windows reaches the container subnet (10.163.0.0/24)
#      through the VM.
#   2. Adds an NRPT rule so Windows resolves *.mpd.test via dnsmasq inside the VM.
#   3. Fetches the mpd CA certificate from the VM over SCP and imports it into the
#      Windows trusted root store so browsers accept *.mpd.test HTTPS without warnings.
#
# Called automatically by setup.cmd after VM creation or when switching VMs.

param(
    [Parameter(Mandatory)][string]$VmIp,
    [string]$SshUser = $env:USERNAME
)

$ErrorActionPreference = "Stop"

$ContainerSubnet  = "10.163.0.0"
$ContainerPrefix  = "10.163.0.0/24"
$ContainerMask    = "255.255.255.0"
$DnsmasqIp        = "10.163.0.3"
$NrptNamespace    = ".mpd.test"
$CaCertRemote     = "~/Developer/mpd/conf/caroot/rootCA.pem"

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" }
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
    if ($LASTEXITCODE -ne 0) { throw "route add failed" }
    Write-Ok "persistent route added"
}

# ── 2. NRPT rule ─────────────────────────────────────────────────────────────

Write-Step "NRPT rule $NrptNamespace -> $DnsmasqIp"

$existing  = @(Get-DnsClientNrptRule | Where-Object { $_.Namespace -eq $NrptNamespace })
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
& scp -o StrictHostKeyChecking=no -o BatchMode=yes "${SshUser}@${VmIp}:${CaCertRemote}" $TempCert
if ($LASTEXITCODE -ne 0) { throw "scp failed -- is the VM running and reachable at $VmIp?" }

try {
    $newCert    = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $TempCert
    $thumbprint = $newCert.Thumbprint

    $inStore = Get-ChildItem Cert:\LocalMachine\Root |
               Where-Object { $_.Thumbprint -eq $thumbprint }

    if ($inStore) {
        Write-Skip "CA cert (thumbprint $thumbprint)"
    } else {
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
Write-Host "Windows client configured. Open https://mpd.test to reach the portal."
