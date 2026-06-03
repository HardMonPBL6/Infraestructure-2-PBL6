# group_vars — patrón para nodos compartidos

Las VMs GCP son **3 nodos spot compartidos por nube** que co-alojan varios
servicios como contenedores. El inventario (generado por OpenTofu) mete cada
nodo en **varios** grupos `[rol]` a la vez. Ansible **fusiona** los group_vars
de todos los grupos a los que pertenece un host, así que:

1. **Todo va namespaced por servicio** (`kafka_*`, `cassandra_*`, `zookeeper_*`…).
   Dos servicios co-alojados nunca comparten un nombre de variable → sin
   colisiones en la fusión. (Precedencia de Ansible entre grupos del mismo nivel
   = orden alfabético del nombre de grupo; al namespacing no nos afecta.)

2. **Presupuesto de RAM fijo.** El nodo más denso (gcp-a `node-02`/`03`:
   Kafka+ZooKeeper+Cassandra+Java en una e2-standard-4 = 16 GB) es la
   restricción. Los heaps están topados para caber con holgura para page cache:

   | Servicio    | Heap   | Nodo más cargado |
   |-------------|--------|------------------|
   | ZooKeeper   | 512 MB | gcp-a ×3         |
   | Kafka       | 2 GB   | gcp-a ×3         |
   | Cassandra   | 4 GB   | gcp-a ×3         |
   | Java/RMI    | 1.5 GB | gcp-a node-02/03 |
   | Schema Registry | 768 MB | gcp-a node-01 (sin Java) |
   | **subtotal**| **~8 GB** | + ~1.5 GB SO + ~6 GB page cache |
   | HBase RS    | 3 GB   | gcp-b ×3         |
   | MySQL (buffer pool) | 2 GB | gcp-b node-02 |

3. **Identidad determinista.** `broker.id`, `myid`, etc. se derivan de la
   posición del host dentro de su grupo (`groups['kafka'].index(...)`). El
   inventario es estable (`node-01/02/03`), así que un nodo borrado por
   preempción (spot + DELETE) se reconstruye con el **mismo** id.

4. **Datos reconstruibles.** Spot+DELETE borra el disco. Nada aquí asume estado
   persistente entre reaprovisionamientos: los despliegues son idempotentes y
   los datos (sintéticos) se regeneran.

Los roles locales (nifi, hdfs, mapreduce, harbor) son de un solo servicio por
host y llevan sus propios group_vars sin estas restricciones de co-ubicación.
