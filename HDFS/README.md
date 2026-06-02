# WebHardMon · HDFS sobre LXC en Proxmox — IaC con OpenTofu

Despliegue en **dos fases** para evitar el problema huevo-gallina de OpenTofu
(el provider Docker no puede conectarse a un LXC que se crea en el mismo apply):

```
HDFS/                               ← Fase 1: crea los 3 LXC + instala Docker
  main.tf / variables.tf
  install-docker.sh                 ← script que ejecuta la Fase 1 en cada LXC
  terraform.tfvars.example

HDFS/mnt/user-data/outputs/         ← Fase 2: despliega NameNode + 2 DataNodes
  webhardmon-hdfs/infra/02-hdfs/
    main.tf / variables.tf
    terraform.tfvars.example
```

## Topología resultante

```
pve-local  (10.10.1.15) → LXC 10.10.1.21 → Docker → NameNode
pve-local2 (10.10.1.16) → LXC 10.10.1.22 → Docker → DataNode-0
pve-local3 (10.10.1.17) → LXC 10.10.1.23 → Docker → DataNode-1
                                   Docker Registry: 10.10.1.50:5000
```

> ⚠ La Fase 1 usa una única API Proxmox (`10.10.1.15:8006`) para crear LXC en
> los tres nodos. Esto **requiere que los tres hosts estén en clúster**. Si no
> lo están, hay que aplicar la Fase 1 tres veces cambiando `proxmox_node_0/1/2`
> al mismo nodo en cada pasada.

## Prerrequisitos

- OpenTofu ≥ 1.6.
- Plantilla `debian-13-standard_13.1-2_amd64.tar.zst` descargada en Proxmox.
- Imágenes HDFS subidas al registry (ver más abajo).
- **Backend GCS activo**: ambas fases guardan el estado en GCS
  (`bucket = "webhardmon-tofu-state"`). Crea el bucket antes del primer apply:

  ```powershell
  gcloud storage buckets create gs://webhardmon-tofu-state --location=EU
  ```

  O comenta el bloque `backend "gcs" {}` en cada `main.tf` para usar estado local.
- El provider `bpg/proxmox` de la Fase 1 necesita **SSH al nodo Proxmox** además
  de la API. Asegúrate de que `10.10.1.15` (y `.16`, `.17` si están en clúster)
  son accesibles por SSH con la misma clave privada que usas para los LXC.

## Paso previo · Subir imágenes al registry

Ejecutar desde Windows PowerShell con Docker Desktop abierto:

```powershell
$VER    = "2.0.0-hadoop3.2.1-java8"
$HARBOR = "10.10.1.50:5000"

docker pull bde2020/hadoop-namenode:$VER
docker pull bde2020/hadoop-datanode:$VER

docker tag bde2020/hadoop-namenode:$VER ${HARBOR}/hadoop-namenode:$VER
docker tag bde2020/hadoop-datanode:$VER ${HARBOR}/hadoop-datanode:$VER

docker push ${HARBOR}/hadoop-namenode:$VER
docker push ${HARBOR}/hadoop-datanode:$VER
```

Si Docker Desktop rechaza el push al registry HTTP, añade en
**Docker Desktop → Settings → Docker Engine**:

```json
"insecure-registries": ["10.10.1.50:5000"]
```

## Fase 1 · Crear LXC + instalar Docker

```powershell
cd "C:\Users\ikerb\OneDrive\Escritorio\MU\3-Maila\PBL6\Infraestructura\HDFS"
cp terraform.tfvars.example terraform.tfvars
```

Edita `terraform.tfvars` con tus valores reales. Los que ya sabes:

```hcl
proxmox_api_url          = "https://10.10.1.15:8006/api2/json"
proxmox_api_token_id     = "iker@pam!tofu-token"
proxmox_api_token_secret = "<secreto-nuevo>"   # rota el que se expuso en el chat

proxmox_ssh_user = "root"

proxmox_node_0 = "pve-local"    # confirmar nombre real en la UI de Proxmox
proxmox_node_1 = "pve-local2"
proxmox_node_2 = "pve-local3"

lxc_ostemplate = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
lxc_storage    = "local-lvm"
lxc_gateway    = "10.10.1.1"

# Contenido de tu clave pública (C:/Users/ikerb/.ssh/id_rsa.pub)
ssh_public_key       = "ssh-rsa AAAA..."
ssh_private_key_path = "C:/Users/ikerb/.ssh/id_rsa"

harbor_registry = "10.10.1.50:5000"
```

```powershell
tofu init
tofu plan
tofu apply
```

Verificación tras el apply:

```powershell
ssh -i C:/Users/ikerb/.ssh/id_rsa root@10.10.1.21 "docker version"
ssh -i C:/Users/ikerb/.ssh/id_rsa root@10.10.1.22 "docker version"
ssh -i C:/Users/ikerb/.ssh/id_rsa root@10.10.1.23 "docker version"
```

## Fase 2 · Desplegar HDFS

```powershell
cd "C:\Users\ikerb\OneDrive\Escritorio\MU\3-Maila\PBL6\Infraestructura\HDFS\mnt\user-data\outputs\webhardmon-hdfs\infra\02-hdfs"
cp terraform.tfvars.example terraform.tfvars
```

Edita `terraform.tfvars`:

```hcl
ssh_private_key_path = "C:/Users/ikerb/.ssh/id_rsa"
harbor_registry      = "10.10.1.50:5000"
# El resto de valores por defecto son correctos para tu entorno
```

```powershell
tofu init
tofu plan
tofu apply
```

## Verificar el clúster

```powershell
# UI del NameNode — debe listar 2 DataNodes vivos
# http://10.10.1.21:9870  (pestaña Datanodes)

ssh -i C:/Users/ikerb/.ssh/id_rsa root@10.10.1.21 `
  "docker exec webhardmon-hdfs-namenode hdfs dfsadmin -report"

# Crear carpeta para los Parquet del Java cluster
ssh -i C:/Users/ikerb/.ssh/id_rsa root@10.10.1.21 `
  "docker exec webhardmon-hdfs-namenode hdfs dfs -mkdir -p /data/telemetry"
```

Dominio base. El túnel se expondrá en collector.<domain_name>

domain_name = "hardmon.eus"
