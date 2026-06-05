<#
.SYNOPSIS
  Configura este host Windows como el gateway WireGuard de la nube local (10.0.0.10)
  de WebHardMon, de forma idempotente.

.DESCRIPTION
  La nube local (Proxmox VMs + CTs) vive detras de este Windows, que ya es el router
  de las subredes 10.10.x. Este script lo convierte tambien en el gateway WireGuard
  que une la nube local con las dos nubes GCP:

    1. Genera (o reutiliza) el par de claves del gateway local.
    2. Escribe el tunel wg-local-gw.conf con los dos gateways GCP como peers (sale
       hacia ellos; no necesita port-forward).
    3. Activa el reenvio IP + regla de firewall para que el trafico LAN<->tunel cruce.
    4. Instala el tunel como servicio de Windows (arranca solo al boot).
    5. Inyecta la NUEVA clave publica del gateway en terraform.tfvars.

  Tras ejecutarlo, haz `tofu apply` para que los gateways GCP confien en la nueva
  clave (sus VMs se recrean; las IPs externas reservadas se conservan).

  REQUIERE ejecutarse como Administrador.

.NOTES
  Las IPs externas y claves publicas GCP se leen de terraform.tfvars / `tofu output`.
  Reejecutable: regenera el tunel y el servicio sin duplicar estado.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot       = (Split-Path -Parent $PSScriptRoot),
  [string]$WireGuardDir   = "C:\Program Files\WireGuard",
  [string]$TunnelName     = "wg-local-gw",
  [string]$LocalGwAddress = "10.0.0.10/24",
  # Endpoints GCP (IPs externas estaticas). Si se dejan vacios se leen de `tofu output`.
  [string]$GcpAEndpoint   = "",
  [string]$GcpBEndpoint   = "",
  [int]$WgPort            = 51820
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Este script debe ejecutarse como Administrador (instala servicio, registry y firewall)."
  }
}

function Get-TfvarsValue([string]$tfvars, [string]$key) {
  $line = Select-String -Path $tfvars -Pattern "^\s*$key\s*=" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $line) { return $null }
  if ($line.Line -match '"([^"]*)"') { return $Matches[1] }
  return $null
}

Assert-Admin

$wg        = Join-Path $WireGuardDir "wg.exe"
$wgService = Join-Path $WireGuardDir "wireguard.exe"
if (-not (Test-Path $wg))        { throw "No se encuentra wg.exe en $WireGuardDir. Instala WireGuard for Windows." }
if (-not (Test-Path $wgService)) { throw "No se encuentra wireguard.exe en $WireGuardDir." }

$tfvars = Join-Path $RepoRoot "terraform.tfvars"
if (-not (Test-Path $tfvars)) { throw "No se encuentra terraform.tfvars en $RepoRoot." }

# --- 1. Claves publicas / endpoints de los gateways GCP ----------------------
$gcpAPub = Get-TfvarsValue $tfvars "wg_gcp_a_public_key"
$gcpBPub = Get-TfvarsValue $tfvars "wg_gcp_b_public_key"
if (-not $gcpAPub -or -not $gcpBPub) {
  throw "No pude leer wg_gcp_a_public_key / wg_gcp_b_public_key de terraform.tfvars."
}

if (-not $GcpAEndpoint -or -not $GcpBEndpoint) {
  Write-Host "Leyendo IPs de los gateways de 'tofu output wireguard_gateway_ips'..."
  try {
    $ips = & tofu "-chdir=$RepoRoot" output -json wireguard_gateway_ips 2>$null | ConvertFrom-Json
    if (-not $GcpAEndpoint) { $GcpAEndpoint = $ips.'gcp-a' }
    if (-not $GcpBEndpoint) { $GcpBEndpoint = $ips.'gcp-b' }
  } catch {
    throw "No pude leer los endpoints de 'tofu output'. Pasalos con -GcpAEndpoint / -GcpBEndpoint."
  }
}
Write-Host "GCP-A endpoint: $GcpAEndpoint    GCP-B endpoint: $GcpBEndpoint"

# --- 2. Par de claves del gateway local (reutiliza si ya existe) -------------
$privPath = Join-Path $RepoRoot "local-gw-private.key"   # *.key esta en .gitignore
$pubPath  = Join-Path $RepoRoot "local-gw-public.key"

if (Test-Path $privPath) {
  Write-Host "Reutilizando clave privada existente: $privPath"
  $priv = (Get-Content $privPath -Raw).Trim()
} else {
  Write-Host "Generando nuevo par de claves del gateway local..."
  $priv = (& $wg genkey).Trim()
  Set-Content -Path $privPath -Value $priv -NoNewline -Encoding ascii
}
$pub = (cmd /c "`"$wg`" pubkey < `"$privPath`"").Trim()
Set-Content -Path $pubPath -Value $pub -NoNewline -Encoding ascii
Write-Host "Clave publica del gateway local: $pub"

# --- 3. Escribir el archivo de configuracion del tunel -----------------------
$conf = @"
[Interface]
PrivateKey = $priv
Address = $LocalGwAddress

[Peer]
# GCP-A gateway (node-01)
PublicKey = $gcpAPub
Endpoint = ${GcpAEndpoint}:$WgPort
AllowedIPs = 10.0.0.20/32, 10.20.0.0/16
PersistentKeepalive = 25

[Peer]
# GCP-B gateway (node-01)
PublicKey = $gcpBPub
Endpoint = ${GcpBEndpoint}:$WgPort
AllowedIPs = 10.0.0.30/32, 10.30.0.0/16
PersistentKeepalive = 25
"@

$confPath = Join-Path $RepoRoot "$TunnelName.conf"   # *.conf con claves -> NO commitear
Set-Content -Path $confPath -Value $conf -Encoding ascii
Write-Host "Config del tunel escrita en $confPath"

# --- 4. Reenvio IP + firewall ------------------------------------------------
Write-Host "Activando reenvio IP (IPEnableRouter + forwarding por interfaz)..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
  -Name "IPEnableRouter" -Value 1 -Type DWord
# El servicio RemoteAccess habilita el enrutado sin reiniciar.
try {
  Set-Service -Name RemoteAccess -StartupType Automatic
  Start-Service -Name RemoteAccess -ErrorAction Stop
} catch { Write-Warning "No pude arrancar RemoteAccess: $($_.Exception.Message). El reenvio puede necesitar reinicio." }
# Forwarding a nivel de interfaz (no requiere reinicio).
Get-NetIPInterface -AddressFamily IPv4 | Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue

$fwRule = "WebHardMon-WireGuard-mesh"
# 10.10.0.0/16 = red local Proxmox (necesaria para el tráfico de retorno HDFS→GCP).
$fwAddrs = "10.0.0.0/24","10.10.0.0/16","10.20.0.0/16","10.30.0.0/16"
$existing = Get-NetFirewallRule -DisplayName $fwRule -ErrorAction SilentlyContinue
if (-not $existing) {
  New-NetFirewallRule -DisplayName $fwRule -Direction Inbound -Action Allow `
    -RemoteAddress $fwAddrs -Profile Any | Out-Null
  Write-Host "Regla de firewall '$fwRule' creada."
} else {
  Set-NetFirewallRule -DisplayName $fwRule -RemoteAddress $fwAddrs
  Write-Host "Regla de firewall '$fwRule' actualizada con 10.10.0.0/16."
}

# --- 5. (Re)instalar el tunel como servicio ----------------------------------
$svc = Get-Service -Name "WireGuardTunnel`$$TunnelName" -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "Reinstalando el servicio del tunel..."
  & $wgService /uninstalltunnelservice $TunnelName | Out-Null
  Start-Sleep -Seconds 2
}
& $wgService /installtunnelservice $confPath
Write-Host "Servicio del tunel instalado."

# --- 6. Inyectar la nueva clave publica en terraform.tfvars ------------------
$content = Get-Content $tfvars -Raw
$pattern = '(?m)^(\s*wg_local_gw_public_key\s*=\s*").*(".*)$'
if ($content -match $pattern) {
  $content = [regex]::Replace($content, $pattern, "`${1}$pub`${2}")
  # UTF-8 sin BOM (Set-Content -Encoding utf8 en PS 5.1 mete BOM y rompe HCL).
  [System.IO.File]::WriteAllText($tfvars, $content, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "terraform.tfvars actualizado: wg_local_gw_public_key = $pub"
} else {
  Write-Warning "No encontre wg_local_gw_public_key en terraform.tfvars; anadela manualmente: $pub"
}

# --- 7. Verificacion ---------------------------------------------------------
Start-Sleep -Seconds 3
Write-Host "`n=== wg show ===" -ForegroundColor Cyan
& $wg show
Write-Host @"

Siguiente paso:
  tofu apply    # recrea los gateways GCP para que confien en la nueva clave
                # (las IPs externas reservadas se conservan)
Luego comprueba el handshake con:  wg show
"@ -ForegroundColor Yellow
