package com.webhardmon.mr;

import org.apache.avro.generic.GenericRecord;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Mapper;

import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.TimeZone;

/**
 * Mapper del job de agregación.
 *
 * Entrada  : (Void, GenericRecord) — Parquet escrito por el bridge Java en HDFS.
 * Salida   : (Text[licencia|ramGb|stoGb|yyyyMMddHH], MetricsWritable)
 *
 * El row key combina la licencia, la capacidad de hardware (RAM y almacenamiento
 * en GB enteros) y la ventana horaria. Segmentar por capacidad evita mezclar
 * percentiles de portátiles de 8 GB con los de 16 GB en los mismos agregados.
 * Pipe (|, 0x7C) como separador porque está fuera del rango alfanumérico.
 *
 * Extracción del timestamp:
 *   1. Campo "timestamp" en el registro (epoch ms como long o como string ISO).
 *   2. Si no existe o es nulo → usa el tiempo de proceso (hora actual).
 */
public class MetricsMapper extends Mapper<Void, GenericRecord, Text, MetricsWritable> {

    private static final SimpleDateFormat HOUR_FMT;

    static {
        HOUR_FMT = new SimpleDateFormat("yyyyMMddHH");
        HOUR_FMT.setTimeZone(TimeZone.getTimeZone("UTC"));
    }

    private final Text outKey = new Text();

    @Override
    protected void map(Void key, GenericRecord record, Context context)
            throws IOException, InterruptedException {

        String licencia = getString(record, "licencia");
        if (licencia == null || licencia.isEmpty()) {
            context.getCounter("webhardmon", "registros_sin_licencia").increment(1);
            return;
        }

        // Capacidad de hardware como enteros GB — agrupa portátiles del mismo tier.
        long ramGb = Math.round(getDouble(record, "cantidad_ram"));
        long stoGb = Math.round(getDouble(record, "cantidad_almacenamiento"));
        String hour = resolveHour(record);
        outKey.set(licencia + "|" + ramGb + "|" + stoGb + "|" + hour);

        MetricsWritable metrics = new MetricsWritable(
            getDouble(record, "uso_procesador"),
            getDouble(record, "uso_ram"),
            getDouble(record, "cantidad_ram"),
            getDouble(record, "uso_almacenamiento"),
            getDouble(record, "cantidad_almacenamiento"),
            getDouble(record, "bateria"),
            getDouble(record, "temperatura"),
            getDouble(record, "stressScore")
        );

        context.write(outKey, metrics);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private String resolveHour(GenericRecord record) {
        Object ts = record.get("timestamp");
        if (ts != null) {
            long epochMs;
            if (ts instanceof Long) {
                epochMs = (Long) ts;
            } else {
                // Intenta parsear si viene como string ISO o epoch string
                String tsStr = ts.toString();
                try {
                    epochMs = Long.parseLong(tsStr);
                } catch (NumberFormatException e) {
                    // Fallback: hora actual
                    epochMs = System.currentTimeMillis();
                }
            }
            return HOUR_FMT.format(new Date(epochMs));
        }
        return HOUR_FMT.format(new Date(System.currentTimeMillis()));
    }

    private static double getDouble(GenericRecord r, String field) {
        Object v = r.get(field);
        if (v == null) return 0.0;
        if (v instanceof Number) return ((Number) v).doubleValue();
        try { return Double.parseDouble(v.toString()); }
        catch (NumberFormatException e) { return 0.0; }
    }

    private static String getString(GenericRecord r, String field) {
        Object v = r.get(field);
        return v == null ? null : v.toString();
    }
}
