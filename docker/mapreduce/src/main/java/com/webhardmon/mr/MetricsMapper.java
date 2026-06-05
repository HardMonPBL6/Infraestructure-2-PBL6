package com.webhardmon.mr;

import org.apache.avro.generic.GenericRecord;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Mapper;

import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Mapper del job de agregacion.
 *
 * Entrada  : (Void, GenericRecord) - Parquet escrito por el bridge Java en HDFS.
 * Salida   : (Text[empresaId|ramGb|stoGb|yyyyMMddHH], MetricsWritable)
 *
 * Lee el esquema real que escribe HdfsParquetWriter:
 *   empresa_id, nombre, ts, cpu_percent, ram_percent, disco_percent,
 *   temperatura, bateria_percent, ram, almacenamiento, procesador, stress_score.
 *
 * El row key combina la empresa, la capacidad de hardware (RAM y almacenamiento
 * en GB enteros) y la ventana horaria. Segmentar por capacidad evita mezclar
 * percentiles de equipos de 8 GB con los de 16 GB en los mismos agregados.
 * Pipe (|, 0x7C) como separador porque esta fuera del rango alfanumerico.
 */
public class MetricsMapper extends Mapper<Void, GenericRecord, Text, MetricsWritable> {

    private static final SimpleDateFormat HOUR_FMT;
    private static final Pattern NUMBER_PATTERN = Pattern.compile("([0-9]+(?:\\.[0-9]+)?)");

    static {
        HOUR_FMT = new SimpleDateFormat("yyyyMMddHH");
        HOUR_FMT.setTimeZone(TimeZone.getTimeZone("UTC"));
    }

    private final Text outKey = new Text();

    @Override
    protected void map(Void key, GenericRecord record, Context context)
            throws IOException, InterruptedException {

        long empresaId = Math.round(getDouble(record, "empresa_id"));
        if (empresaId <= 0) {
            context.getCounter("webhardmon", "registros_sin_empresa_id").increment(1);
            return;
        }

        double ramGbValue = parseGb(record, "ram");
        double stoGbValue = parseGb(record, "almacenamiento");

        // Capacidad de hardware como enteros GB: agrupa equipos del mismo tier.
        long ramGb = Math.round(ramGbValue);
        long stoGb = Math.round(stoGbValue);
        String hour = resolveHour(record);
        outKey.set(empresaId + "|" + ramGb + "|" + stoGb + "|" + hour);

        MetricsWritable metrics = new MetricsWritable(
            getDouble(record, "cpu_percent"),
            getDouble(record, "ram_percent"),
            ramGbValue,
            getDouble(record, "disco_percent"),
            stoGbValue,
            getDouble(record, "bateria_percent"),
            getDouble(record, "temperatura"),
            getDouble(record, "stress_score")
        );

        context.write(outKey, metrics);
    }

    private String resolveHour(GenericRecord record) {
        Object ts = record.get("ts");
        if (ts != null) {
            long epochMs;
            if (ts instanceof Number) {
                epochMs = ((Number) ts).longValue();
            } else {
                String tsStr = ts.toString();
                try {
                    epochMs = Long.parseLong(tsStr);
                } catch (NumberFormatException e) {
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
        return parseNumber(v.toString());
    }

    private static double parseGb(GenericRecord r, String field) {
        Object v = r.get(field);
        if (v == null) return 0.0;
        if (v instanceof Number) return ((Number) v).doubleValue();
        return parseNumber(v.toString());
    }

    private static double parseNumber(String value) {
        Matcher matcher = NUMBER_PATTERN.matcher(value.replace(',', '.'));
        if (!matcher.find()) return 0.0;
        try { return Double.parseDouble(matcher.group(1)); }
        catch (NumberFormatException e) { return 0.0; }
    }
}
