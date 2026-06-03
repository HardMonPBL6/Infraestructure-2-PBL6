package com.webhardmon.mr;

import org.apache.hadoop.hbase.client.Put;
import org.apache.hadoop.hbase.io.ImmutableBytesWritable;
import org.apache.hadoop.hbase.mapreduce.TableReducer;
import org.apache.hadoop.hbase.util.Bytes;
import org.apache.hadoop.io.Text;

import java.io.IOException;

/**
 * Reducer del job de agregación.
 *
 * Entrada  : (Text[licencia|ramGb|stoGb|yyyyMMddHH], Iterable<MetricsWritable>)
 * Salida   : Put a la tabla HBase webhardmon_hourly.
 *
 * El row key ya segmenta por tier de hardware (ramGb, stoGb), por lo que todos
 * los registros de un mismo grupo tienen cantidad_ram y cantidad_almacenamiento
 * idénticos — los percentiles de uso% son comparables entre sí.
 *
 * Columnas generadas en la familia "m":
 *
 *   cpu_avg  cpu_min  cpu_max          (uso_procesador %)
 *   ram_avg  ram_min  ram_max          (uso_ram %)
 *   ram_gb                             (cantidad_ram GB — constante en el grupo, copia del key)
 *   sto_avg  sto_min  sto_max          (uso_almacenamiento %)
 *   sto_gb                             (cantidad_almacenamiento GB — constante, copia del key)
 *   bat_avg  bat_min  bat_max          (bateria %)
 *   tmp_avg  tmp_min  tmp_max          (temperatura ºC)
 *   str_avg  str_min  str_max          (stressScore 0-100)
 *   count                              (nº de muestras en la hora)
 *
 * Todos los valores numéricos se almacenan como double en 8 bytes (Bytes.toBytes).
 * count se guarda como long (8 bytes). El row key es el Text del Mapper, UTF-8.
 */
public class MetricsReducer extends TableReducer<Text, MetricsWritable, ImmutableBytesWritable> {

    private static final byte[] CF = Bytes.toBytes("m");

    // Nombres de columna como bytes (constantes para evitar allocaciones en hot path)
    private static final byte[] Q_CPU_AVG = Bytes.toBytes("cpu_avg");
    private static final byte[] Q_CPU_MIN = Bytes.toBytes("cpu_min");
    private static final byte[] Q_CPU_MAX = Bytes.toBytes("cpu_max");
    private static final byte[] Q_RAM_AVG = Bytes.toBytes("ram_avg");
    private static final byte[] Q_RAM_MIN = Bytes.toBytes("ram_min");
    private static final byte[] Q_RAM_MAX = Bytes.toBytes("ram_max");
    private static final byte[] Q_RAM_GB  = Bytes.toBytes("ram_gb");
    private static final byte[] Q_STO_AVG = Bytes.toBytes("sto_avg");
    private static final byte[] Q_STO_MIN = Bytes.toBytes("sto_min");
    private static final byte[] Q_STO_MAX = Bytes.toBytes("sto_max");
    private static final byte[] Q_STO_GB  = Bytes.toBytes("sto_gb");
    private static final byte[] Q_BAT_AVG = Bytes.toBytes("bat_avg");
    private static final byte[] Q_BAT_MIN = Bytes.toBytes("bat_min");
    private static final byte[] Q_BAT_MAX = Bytes.toBytes("bat_max");
    private static final byte[] Q_TMP_AVG = Bytes.toBytes("tmp_avg");
    private static final byte[] Q_TMP_MIN = Bytes.toBytes("tmp_min");
    private static final byte[] Q_TMP_MAX = Bytes.toBytes("tmp_max");
    private static final byte[] Q_STR_AVG = Bytes.toBytes("str_avg");
    private static final byte[] Q_STR_MIN = Bytes.toBytes("str_min");
    private static final byte[] Q_STR_MAX = Bytes.toBytes("str_max");
    private static final byte[] Q_COUNT   = Bytes.toBytes("count");

    @Override
    protected void reduce(Text key, Iterable<MetricsWritable> values, Context context)
            throws IOException, InterruptedException {

        // Acumuladores
        double sumCpu = 0, minCpu = Double.MAX_VALUE, maxCpu = -Double.MAX_VALUE;
        double sumRam = 0, minRam = Double.MAX_VALUE, maxRam = -Double.MAX_VALUE;
        double sumRamGb = 0;
        double sumSto = 0, minSto = Double.MAX_VALUE, maxSto = -Double.MAX_VALUE;
        double sumStoGb = 0;
        double sumBat = 0, minBat = Double.MAX_VALUE, maxBat = -Double.MAX_VALUE;
        double sumTmp = 0, minTmp = Double.MAX_VALUE, maxTmp = -Double.MAX_VALUE;
        double sumStr = 0, minStr = Double.MAX_VALUE, maxStr = -Double.MAX_VALUE;
        long count = 0;

        for (MetricsWritable m : values) {
            double cpu = m.getUsoCpu();
            double ram = m.getUsoRam();
            double ramGb = m.getCantidadRamGb();
            double sto = m.getUsoAlmacenamiento();
            double stoGb = m.getCantidadAlmacenamientoGb();
            double bat = m.getBateria();
            double tmp = m.getTemperatura();
            double str = m.getStressScore();

            sumCpu += cpu; if (cpu < minCpu) minCpu = cpu; if (cpu > maxCpu) maxCpu = cpu;
            sumRam += ram; if (ram < minRam) minRam = ram; if (ram > maxRam) maxRam = ram;
            sumRamGb += ramGb;
            sumSto += sto; if (sto < minSto) minSto = sto; if (sto > maxSto) maxSto = sto;
            sumStoGb += stoGb;
            sumBat += bat; if (bat < minBat) minBat = bat; if (bat > maxBat) maxBat = bat;
            sumTmp += tmp; if (tmp < minTmp) minTmp = tmp; if (tmp > maxTmp) maxTmp = tmp;
            sumStr += str; if (str < minStr) minStr = str; if (str > maxStr) maxStr = str;
            count++;
        }

        if (count == 0) return;

        Put put = new Put(Bytes.toBytes(key.toString()));
        addDouble(put, Q_CPU_AVG, sumCpu / count);
        addDouble(put, Q_CPU_MIN, minCpu);
        addDouble(put, Q_CPU_MAX, maxCpu);
        addDouble(put, Q_RAM_AVG, sumRam / count);
        addDouble(put, Q_RAM_MIN, minRam);
        addDouble(put, Q_RAM_MAX, maxRam);
        addDouble(put, Q_RAM_GB,  sumRamGb / count);
        addDouble(put, Q_STO_AVG, sumSto / count);
        addDouble(put, Q_STO_MIN, minSto);
        addDouble(put, Q_STO_MAX, maxSto);
        addDouble(put, Q_STO_GB,  sumStoGb / count);
        addDouble(put, Q_BAT_AVG, sumBat / count);
        addDouble(put, Q_BAT_MIN, minBat);
        addDouble(put, Q_BAT_MAX, maxBat);
        addDouble(put, Q_TMP_AVG, sumTmp / count);
        addDouble(put, Q_TMP_MIN, minTmp);
        addDouble(put, Q_TMP_MAX, maxTmp);
        addDouble(put, Q_STR_AVG, sumStr / count);
        addDouble(put, Q_STR_MIN, minStr);
        addDouble(put, Q_STR_MAX, maxStr);
        put.addColumn(CF, Q_COUNT, Bytes.toBytes(count));

        context.write(new ImmutableBytesWritable(put.getRow()), put);
    }

    private void addDouble(Put put, byte[] qualifier, double value) {
        put.addColumn(CF, qualifier, Bytes.toBytes(value));
    }
}
