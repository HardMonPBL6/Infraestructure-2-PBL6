#!/usr/bin/env python3
"""
configure_flow.py — Configura el flujo NiFi para WebHardMon vía REST API.

Idempotente: si el process group "WebHardMon-Ingesta" ya existe, termina sin
hacer ningún cambio. Seguro para ejecutar en cada pasada de Ansible.

Flujo que crea:
  HandleHttpRequest (8081)
    → ExecuteScript/Groovy (valida licencia MySQL, enriquece empresa_id+nombre,
                            transforma campos al contrato Avro)
        [success] → PublishKafkaRecord_2_6 (Avro + Schema Registry)
                      [success] → HandleHttpResponse 200
                      [failure] → HandleHttpResponse 500
        [failure] → HandleHttpResponse 401/500

Variables de entorno (todas tienen default para entorno local):
  NIFI_URL             (default: https://127.0.0.1:8443)
  NIFI_USER            (default: admin)
  NIFI_PASS            (default: hardmonNiFiAdmin2026)
  MYSQL_JDBC_URL       (default: jdbc:mysql://mysql:3306/telemetriadb)
  MYSQL_USER           (default: root)
  MYSQL_PASS           (default: root)
  MYSQL_DRIVER_JAR     (default: /opt/nifi/drivers/mysql-connector-j-8.4.0.jar)
  KAFKA_BROKERS        (default: kafka:9092)
  SCHEMA_REGISTRY_URL  (default: http://schema-registry:8085)
"""

import os, sys, time, json
import requests, urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Configuración ─────────────────────────────────────────────────────────────
NIFI_URL         = os.environ.get("NIFI_URL",            "https://127.0.0.1:8443")
NIFI_USER        = os.environ.get("NIFI_USER",           "admin")
NIFI_PASS        = os.environ.get("NIFI_PASS",           "hardmonNiFiAdmin2026")
MYSQL_JDBC_URL   = os.environ.get("MYSQL_JDBC_URL",      "jdbc:mysql://mysql:3306/telemetriadb")
MYSQL_USER       = os.environ.get("MYSQL_USER",          "root")
MYSQL_PASS       = os.environ.get("MYSQL_PASS",          "root")
MYSQL_DRIVER_JAR = os.environ.get("MYSQL_DRIVER_JAR",   "/opt/nifi/drivers/mysql-connector-j-8.4.0.jar")
KAFKA_BROKERS    = os.environ.get("KAFKA_BROKERS",       "kafka:9092")
SR_URL           = os.environ.get("SCHEMA_REGISTRY_URL", "http://schema-registry:8085")

PG_NAME = "WebHardMon-Ingesta"

s = requests.Session()
s.verify = False

# ── Groovy: validación + enriquecimiento + transformación de campos ───────────
# Lee X-License-Code del header HTTP, valida contra licencia_lookup en MySQL,
# enriquece con empresa_id + nombre, y mapea todos los campos al contrato Avro
# (fuente de verdad = client/Client.java).
GROOVY_SCRIPT = r"""
import org.apache.nifi.dbcp.DBCPService
import java.nio.charset.StandardCharsets
import java.util.Scanner
import groovy.json.JsonOutput
import groovy.json.JsonSlurper

def ff = session.get()
if (!ff) return

try {
    // 1. Leer cuerpo JSON del colector Go
    def body = ""
    session.read(ff, { ins ->
        body = new Scanner(ins, "UTF-8").useDelimiter("\\A").hasNext() ?
               new Scanner(ins, "UTF-8").useDelimiter("\\A").next() : ""
    } as org.apache.nifi.processor.io.InputStreamCallback)

    if (!body) {
        ff = session.putAttribute(ff, "http.status", "400")
        ff = session.putAttribute(ff, "error", "Empty body")
        session.transfer(ff, REL_FAILURE)
        return
    }

    def json   = new JsonSlurper().parseText(body)

    // X-License-Code puede venir en cabecera con distintas capitalizaciones
    def codigo = ff.getAttribute("X-License-Code") ?:
                 ff.getAttribute("x-license-code") ?:
                 ff.getAttribute("http.headers.X-License-Code") ?: ""

    if (!codigo) {
        ff = session.putAttribute(ff, "http.status", "401")
        ff = session.putAttribute(ff, "error", "Missing X-License-Code header")
        session.transfer(ff, REL_FAILURE)
        return
    }

    // 2. Validar licencia y obtener empresa_id + nombre desde MySQL
    //    (licencia_lookup = vista JOIN licencia→usuario, model relacional)
    def dbcp  = context.getProperty("mysql-pool").asControllerService(DBCPService.class)
    def conn  = dbcp.getConnection()
    def stmt  = conn.prepareStatement(
        "SELECT activa, empresa_id, nombre FROM licencia_lookup WHERE codigo = ?")
    stmt.setString(1, codigo)
    def rs = stmt.executeQuery()

    if (!rs.next() || rs.getInt("activa") != 1) {
        rs.close(); stmt.close(); conn.close()
        ff = session.putAttribute(ff, "http.status", "401")
        ff = session.putAttribute(ff, "error", "License invalid or inactive")
        session.transfer(ff, REL_FAILURE)
        return
    }

    long   empresaId = rs.getLong("empresa_id")
    String nombre    = rs.getString("nombre")
    rs.close(); stmt.close(); conn.close()

    // 3. Transformar campos al contrato Avro (nombres de client/Client.java)
    //    ram_total / disk_total vienen en bytes del colector → convertir a texto
    long ramBytes  = (json.ram_total  as long) ?: 0L
    long diskBytes = (json.disk_total as long) ?: 0L
    long ramGb     = Math.round(ramBytes  / 1_073_741_824.0)
    long diskGb    = Math.round(diskBytes / 1_073_741_824.0)

    def enriched = [
        empresa_id     : empresaId,
        nombre         : nombre,
        ts             : ((json.timestamp as long) ?: 0L) * 1000L,  // seg → ms
        cpu_percent    : (json.cpu_percent    as double) ?: 0.0,
        ram_percent    : (json.ram_percent    as double) ?: 0.0,
        disco_percent  : (json.disk_percent   as double) ?: 0.0,
        temperatura    : json.temp_c,           // nullable
        bateria_percent: json.bateria_percent,  // nullable
        ram            : "${ramGb} GB",
        almacenamiento : "${diskGb} GB",
        procesador     : json.cpu_model         // nullable
    ]

    def outJson = JsonOutput.toJson(enriched)
    ff = session.write(ff, { os ->
        os.write(outJson.getBytes(StandardCharsets.UTF_8))
    } as org.apache.nifi.processor.io.OutputStreamCallback)

    ff = session.putAttribute(ff, "mime.type", "application/json")
    session.transfer(ff, REL_SUCCESS)

} catch (Exception e) {
    log.error("Error procesando telemetría: ${e.message}", e)
    ff = session.putAttribute(ff, "http.status", "500")
    ff = session.putAttribute(ff, "error", e.getMessage())
    session.transfer(ff, REL_FAILURE)
}
"""

# ── Helpers REST ──────────────────────────────────────────────────────────────
def api(method, path, ok=(200, 201), **kwargs):
    r = getattr(s, method)(f"{NIFI_URL}/nifi-api{path}", **kwargs)
    if r.status_code not in ok:
        print(f"  ✗ {method.upper()} {path} → {r.status_code}")
        print(f"    {r.text[:300]}")
        sys.exit(1)
    return r.json() if r.text.strip() else {}

def auth():
    # En modo HTTP (clúster interno sin TLS) NiFi no tiene login: no hay token.
    # Solo pedimos token en modo HTTPS (single-user).
    if NIFI_URL.startswith("http://"):
        print("✓ Modo HTTP (clúster interno sin TLS): sin autenticación por token")
        return
    r = s.post(f"{NIFI_URL}/nifi-api/access/token",
               data={"username": NIFI_USER, "password": NIFI_PASS},
               headers={"Content-Type": "application/x-www-form-urlencoded"})
    if r.status_code != 201:
        print(f"✗ Auth: {r.status_code} {r.text}")
        sys.exit(1)
    s.headers["Authorization"] = f"Bearer {r.text.strip()}"
    print("✓ Autenticado en NiFi")

def root_pg():
    return api("get", "/process-groups/root")["id"]

def find_pg(parent_id, name):
    d = api("get", f"/process-groups/{parent_id}/process-groups")
    for pg in d.get("processGroups", []):
        if pg["component"]["name"] == name:
            return pg["id"]
    return None

def mk_pg(parent_id, name, x=0, y=0):
    d = api("post", f"/process-groups/{parent_id}/process-groups",
            json={"revision": {"version": 0},
                  "component": {"name": name, "position": {"x": x, "y": y}}})
    return d["id"]

def mk_cs(pg_id, svc_type, name, props):
    d = api("post", f"/process-groups/{pg_id}/controller-services",
            json={"revision": {"version": 0},
                  "component": {"type": svc_type, "name": name,
                                "properties": props}})
    print(f"  ✓ CS: {name}")
    return d["id"], d["revision"]["version"]

def enable_cs(svc_id):
    for _ in range(20):
        d = api("get", f"/controller-services/{svc_id}")
        if d["component"]["state"] == "DISABLED":
            break
        time.sleep(1)
    ver = d["revision"]["version"]
    api("put", f"/controller-services/{svc_id}/run-status",
        json={"revision": {"version": ver}, "state": "ENABLED",
              "disconnectedNodeAcknowledged": False})
    for _ in range(20):
        d = api("get", f"/controller-services/{svc_id}")
        if d["component"]["state"] == "ENABLED":
            return
        time.sleep(1)
    print(f"  ⚠ CS {svc_id} no llega a ENABLED (puede tardar)")

def mk_proc(pg_id, ptype, name, props, x, y, auto_term=None):
    d = api("post", f"/process-groups/{pg_id}/processors",
            json={"revision": {"version": 0},
                  "component": {
                      "type": ptype, "name": name,
                      "position": {"x": x, "y": y},
                      "config": {
                          "properties": props,
                          "autoTerminatedRelationships": auto_term or []
                      }}})
    print(f"  ✓ Processor: {name}")
    return d["id"]

def link(pg_id, src, dst, rels):
    api("post", f"/process-groups/{pg_id}/connections",
        json={"revision": {"version": 0},
              "component": {
                  "source":      {"id": src, "type": "PROCESSOR", "groupId": pg_id},
                  "destination": {"id": dst, "type": "PROCESSOR", "groupId": pg_id},
                  "selectedRelationships": rels}})
    print(f"  ✓ {rels}: {src[:8]}…→{dst[:8]}…")

def start(proc_id):
    d  = api("get", f"/processors/{proc_id}")
    ver = d["revision"]["version"]
    api("put", f"/processors/{proc_id}/run-status",
        json={"revision": {"version": ver}, "state": "RUNNING",
              "disconnectedNodeAcknowledged": False})

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 55)
    print("  Configurando flujo NiFi — WebHardMon")
    print("=" * 55)

    auth()
    rpg = root_pg()

    # Idempotencia: si el PG ya existe, no hacemos nada
    existing = find_pg(rpg, PG_NAME)
    if existing:
        print(f"\n⚠  Process Group '{PG_NAME}' ya existe ({existing}).")
        print("   Sin cambios (idempotente).")
        sys.exit(0)

    print(f"\n1. Creando Process Group '{PG_NAME}'…")
    pg = mk_pg(rpg, PG_NAME, x=100, y=100)
    print(f"   ID: {pg}")

    # ── Controller Services ────────────────────────────────────────────────
    print("\n2. Controller Services…")

    http_ctx, _ = mk_cs(pg,
        "org.apache.nifi.http.StandardHttpContextMap",
        "HttpContextMap", {})

    dbcp, _ = mk_cs(pg,
        "org.apache.nifi.dbcp.DBCPConnectionPool",
        "MySQL-telemetriadb",
        {"Database Connection URL":      MYSQL_JDBC_URL,
         "Database Driver Class Name":   "com.mysql.cj.jdbc.Driver",
         "Database Driver Location(s)":  MYSQL_DRIVER_JAR,
         "Database User":                MYSQL_USER,
         "Password":                     MYSQL_PASS})

    sr, _ = mk_cs(pg,
        "org.apache.nifi.confluent.schemaregistry.ConfluentSchemaRegistry",
        "SchemaRegistry",
        {"url": SR_URL})

    jreader, _ = mk_cs(pg,
        "org.apache.nifi.json.JsonTreeReader",
        "JsonReader",
        {"schema-access-strategy": "infer-schema"})

    awriter, _ = mk_cs(pg,
        "org.apache.nifi.avro.AvroRecordSetWriter",
        "AvroWriter",
        {"schema-write-strategy":  "confluent-encode",
         "schema-access-strategy": "schema-name",
         "schema-name":            "Telemetry",
         "schema-registry":        sr})

    print("\n3. Habilitando Controller Services…")
    for cs in [http_ctx, dbcp, sr, jreader, awriter]:
        enable_cs(cs)
        print(f"  ✓ {cs[:8]}… habilitado")

    # ── Processors ────────────────────────────────────────────────────────
    print("\n4. Processors…")

    p_listen = mk_proc(pg,
        "org.apache.nifi.processors.standard.HandleHttpRequest",
        "Listen-Telemetry",
        {"Listening Port":   "8081",
         "HTTP Context Map": http_ctx,
         "Allowed Paths":    "/telemetry",
         "Allow GET":        "false",
         "Allow POST":       "true",
         "Allow PUT":        "false",
         "Allow DELETE":     "false"},
        x=400, y=100)

    p_enrich = mk_proc(pg,
        "org.apache.nifi.processors.script.ExecuteScript",
        "Enrich-Validate",
        {"Script Engine": "Groovy",
         "Script Body":   GROOVY_SCRIPT,
         "mysql-pool":    dbcp},       # dynamic prop → controller service ref
        x=400, y=300)

    p_kafka = mk_proc(pg,
        "org.apache.nifi.processors.kafka.pubsub.PublishKafkaRecord_2_6",
        "Publish-Kafka-Avro",
        {"bootstrap.servers": KAFKA_BROKERS,
         "topic":             "telemetry",
         "record-reader":     jreader,
         "record-writer":     awriter,
         "use-transactions":  "false",
         "acks":              "all",
         "compression-type":  "none"},
        x=400, y=500,
        auto_term=["success"])         # éxito → auto-terminate (respuesta ya enviada)

    p_ok = mk_proc(pg,
        "org.apache.nifi.processors.standard.HandleHttpResponse",
        "Response-200",
        {"HTTP Status Code": "200",
         "HTTP Context Map": http_ctx},
        x=700, y=500,
        auto_term=["success"])

    p_err = mk_proc(pg,
        "org.apache.nifi.processors.standard.HandleHttpResponse",
        "Response-Error",
        # Usa el http.status que pone el Groovy (401/500); si está vacío → 500
        {"HTTP Status Code": "${http.status:isEmpty():ifElse('500', ${http.status})}",
         "HTTP Context Map": http_ctx},
        x=100, y=400,
        auto_term=["success"])

    # ── Connections ────────────────────────────────────────────────────────
    print("\n5. Conexiones…")
    link(pg, p_listen,  p_enrich, ["success"])
    link(pg, p_enrich,  p_kafka,  ["success"])
    link(pg, p_enrich,  p_err,    ["failure"])
    link(pg, p_kafka,   p_ok,     ["success"])
    link(pg, p_kafka,   p_err,    ["failure"])

    # ── Arrancar ──────────────────────────────────────────────────────────
    print("\n6. Arrancando processors…")
    for pid in [p_listen, p_enrich, p_kafka, p_ok, p_err]:
        start(pid)
        print(f"  ✓ RUNNING: {pid[:8]}…")

    print(f"\n✅  Flujo '{PG_NAME}' configurado y arrancado.")
    print(f"   Endpoint: POST http://<nifi-host>:8081/telemetry")
    print(f"   Process Group ID: {pg}")


if __name__ == "__main__":
    main()
