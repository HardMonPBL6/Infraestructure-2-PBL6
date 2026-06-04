<#
.SYNOPSIS
  Wrapper de Windows para docker/build-and-push.sh: lee los IDs de proyecto de
  terraform.tfvars, fija las variables de entorno y lanza el script via WSL.

.DESCRIPTION
  Paso 2 del despliegue. Requiere Docker accesible desde WSL (Docker Desktop con
  integracion WSL, o docker instalado en la distro). Para el registro Harbor local
  (HTTP) anade "insecure-registries": ["10.10.1.50:5000"] en Docker Desktop.

.EXAMPLE
  .\docker\build-and-push.ps1 -ImageTag 1.0
  .\docker\build-and-push.ps1 cassandra nifi        # solo algunos servicios
#>
[CmdletBinding()]
param(
  [string]$RepoRoot   = (Split-Path -Parent $PSScriptRoot),
  [string]$ImageTag   = "1.0",
  [string]$HarborHost = "10.10.1.50:5000",
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Services = @()
)
$ErrorActionPreference = "Stop"

function Get-TfvarsValue([string]$tfvars, [string]$key) {
  $line = Select-String -Path $tfvars -Pattern "^\s*$key\s*=" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($line -and $line.Line -match '"([^"]*)"') { return $Matches[1] }
  return $null
}

$tfvars = Join-Path $RepoRoot "terraform.tfvars"
$gcpA = Get-TfvarsValue $tfvars "gcp_a_project_id"
$gcpB = Get-TfvarsValue $tfvars "gcp_b_project_id"
if (-not $gcpA -or -not $gcpB) { throw "No pude leer gcp_a_project_id / gcp_b_project_id de $tfvars." }

$dockerWin = Join-Path $RepoRoot "docker"
$dockerWsl = (& wsl wslpath -a ("'" + $dockerWin + "'")).Trim()
$svcArgs   = ($Services -join " ")

$cmd = "cd '$dockerWsl' && " +
       "GCP_A_PROJECT='$gcpA' GCP_B_PROJECT='$gcpB' HARBOR_HOST='$HarborHost' IMAGE_TAG='$ImageTag' " +
       "./build-and-push.sh $svcArgs"

Write-Host "Ejecutando en WSL: $cmd" -ForegroundColor Cyan
& wsl -e bash -lc $cmd
