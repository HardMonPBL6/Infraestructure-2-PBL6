package com.webhardmon.mr;

import org.apache.hadoop.io.Writable;

import java.io.DataInput;
import java.io.DataOutput;
import java.io.IOException;

/**
 * Transporta las metricas numericas de una medicion individual entre Mapper y Reducer.
 *
 * Campos que llegan del Parquet (escritos por el bridge Java -> HDFS):
 *   cpu_percent, ram_percent, ram,
 *   disco_percent, almacenamiento,
 *   bateria_percent, temperatura, stress_score
 *
 * El timestamp se usa en el Mapper para calcular la ventana horaria del row key;
 * no hace falta transportarlo al Reducer (el row key ya lo codifica).
 */
public class MetricsWritable implements Writable {

    private double usoCpu;
    private double usoRam;
    private double cantidadRamGb;
    private double usoAlmacenamiento;
    private double cantidadAlmacenamientoGb;
    private double bateria;
    private double temperatura;
    private double stressScore;

    public MetricsWritable() {}

    public MetricsWritable(double usoCpu, double usoRam, double cantidadRamGb,
                           double usoAlmacenamiento, double cantidadAlmacenamientoGb,
                           double bateria, double temperatura, double stressScore) {
        this.usoCpu = usoCpu;
        this.usoRam = usoRam;
        this.cantidadRamGb = cantidadRamGb;
        this.usoAlmacenamiento = usoAlmacenamiento;
        this.cantidadAlmacenamientoGb = cantidadAlmacenamientoGb;
        this.bateria = bateria;
        this.temperatura = temperatura;
        this.stressScore = stressScore;
    }

    @Override
    public void write(DataOutput out) throws IOException {
        out.writeDouble(usoCpu);
        out.writeDouble(usoRam);
        out.writeDouble(cantidadRamGb);
        out.writeDouble(usoAlmacenamiento);
        out.writeDouble(cantidadAlmacenamientoGb);
        out.writeDouble(bateria);
        out.writeDouble(temperatura);
        out.writeDouble(stressScore);
    }

    @Override
    public void readFields(DataInput in) throws IOException {
        usoCpu = in.readDouble();
        usoRam = in.readDouble();
        cantidadRamGb = in.readDouble();
        usoAlmacenamiento = in.readDouble();
        cantidadAlmacenamientoGb = in.readDouble();
        bateria = in.readDouble();
        temperatura = in.readDouble();
        stressScore = in.readDouble();
    }

    public double getUsoCpu()                    { return usoCpu; }
    public double getUsoRam()                    { return usoRam; }
    public double getCantidadRamGb()             { return cantidadRamGb; }
    public double getUsoAlmacenamiento()         { return usoAlmacenamiento; }
    public double getCantidadAlmacenamientoGb()  { return cantidadAlmacenamientoGb; }
    public double getBateria()                   { return bateria; }
    public double getTemperatura()               { return temperatura; }
    public double getStressScore()               { return stressScore; }
}
