package com.webhardmon.mr;

import org.apache.avro.generic.GenericRecord;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.conf.Configured;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.HConstants;
import org.apache.hadoop.hbase.client.Connection;
import org.apache.hadoop.hbase.client.ConnectionFactory;
import org.apache.hadoop.hbase.mapreduce.TableMapReduceUtil;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.util.Tool;
import org.apache.hadoop.util.ToolRunner;
import org.apache.parquet.avro.AvroParquetInputFormat;

/**
 * Driver del job MapReduce de agregación de métricas WebHardMon.
 *
 * Flujo Lambda Architecture — capa BATCH:
 *   HDFS (Parquet) → MapReduce → HBase webhardmon_hourly
 *
 * Uso:
 *   hadoop jar webhardmon-mr-1.0.0.jar \
 *     com.webhardmon.mr.MetricsAggregationJob \
 *     <input_hdfs_path>      # p.ej. /data/telemetry
 *     <hbase_table>          # p.ej. webhardmon_hourly
 *     <zk_quorum>            # p.ej. 10.30.1.10,10.30.2.11,10.30.2.12
 *     [zk_port]              # opcional, default 2181
 *
 * El job procesa TODOS los ficheros Parquet bajo input_hdfs_path de forma
 * recursiva. Se puede acotar pasando una subruta con partición de fecha:
 *   /data/telemetry/2024/01/15/14
 */
public class MetricsAggregationJob extends Configured implements Tool {

    public static void main(String[] args) throws Exception {
        int exitCode = ToolRunner.run(HBaseConfiguration.create(), new MetricsAggregationJob(), args);
        System.exit(exitCode);
    }

    @Override
    public int run(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Uso: MetricsAggregationJob <input_path> <hbase_table> <zk_quorum> [zk_port]");
            return 1;
        }

        String inputPath  = args[0];
        String hbaseTable = args[1];
        String zkQuorum   = args[2];
        String zkPort     = args.length > 3 ? args[3] : "2181";

        Configuration conf = getConf();

        // Configurar conexión HBase
        conf.set(HConstants.ZOOKEEPER_QUORUM, zkQuorum);
        conf.set(HConstants.ZOOKEEPER_CLIENT_PORT, zkPort);

        // Verificar conectividad HBase antes de lanzar el job
        try (Connection ignored = ConnectionFactory.createConnection(conf)) {
            System.out.println("[webhardmon-mr] Conexión HBase OK — ZK: " + zkQuorum);
        } catch (Exception e) {
            System.err.println("[webhardmon-mr] ERROR conectando a HBase: " + e.getMessage());
            return 2;
        }

        Job job = Job.getInstance(conf, "webhardmon-metrics-aggregation");
        job.setJarByClass(MetricsAggregationJob.class);

        // ── Input: Parquet en HDFS ──────────────────────────────────────────
        job.setInputFormatClass(AvroParquetInputFormat.class);
        // Lectura genérica: el schema se infiere del fichero Parquet (Avro embebido).
        // No es necesario registrar un schema explícito gracias a AvroParquetInputFormat.
        FileInputFormat.setInputDirRecursive(job, true);
        FileInputFormat.addInputPath(job, new Path(inputPath));

        // ── Mapper ─────────────────────────────────────────────────────────
        job.setMapperClass(MetricsMapper.class);
        job.setMapOutputKeyClass(Text.class);
        job.setMapOutputValueClass(MetricsWritable.class);

        // ── Reducer: TableReducer escribe directamente en HBase ─────────────
        // Número de reducers = 1 por región pre-spliteada (8 por defecto).
        TableMapReduceUtil.initTableReducerJob(
            hbaseTable,
            MetricsReducer.class,
            job
        );
        job.setNumReduceTasks(8);

        System.out.println("[webhardmon-mr] Lanzando job:");
        System.out.println("  Input HDFS : " + inputPath);
        System.out.println("  HBase tabla: " + hbaseTable);
        System.out.println("  ZK quorum  : " + zkQuorum + ":" + zkPort);

        boolean success = job.waitForCompletion(true);
        return success ? 0 : 1;
    }
}
