package com.example.viaverde_team5.data

import com.example.viaverde_team5.data.model.*
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Transforma uma SensorWindow (amostras brutas) num SensorPayload pronto a enviar.
 * Toda a lógica de cálculo de features está isolada aqui — fácil de testar unitariamente.
 */
object `FeatureExtractor` {

    fun extract(window: SensorWindow, deviceId: String): SensorPayload {
        return SensorPayload(
            deviceId = deviceId,
            timestampMs = System.currentTimeMillis(),

            // ── GPS ─────────────────────────────────────────────────────────────
            gpsAccuracyMean = window.gpsReadings.meanOf { it.accuracyMeters.toDouble() },
            gpsAccuracyMax  = window.gpsReadings.maxOfOrNull { it.accuracyMeters.toDouble() } ?: 0.0,
            gpsAccuracyDelta = gpsAccuracyDelta(window.gpsReadings),
            gpsLostRatio    = window.gpsReadings.run {
                if (isEmpty()) 1.0
                else count { !it.hasSignal }.toDouble() / size
            },

            // ── Wi-Fi ────────────────────────────────────────────────────────────
            wifiCountMean  = window.wifiScans.meanOf { it.apCount.toDouble() },
            wifiCountDelta = wifiCountDelta(window.wifiScans),
            wifiRssiMean   = window.wifiScans
                .flatMap { it.rssiValues }
                .let { rssiList -> if (rssiList.isEmpty()) 0.0 else rssiList.average() },

            // ── BLE ──────────────────────────────────────────────────────────────
            bleCountMean  = window.bleScans.meanOf { it.deviceCount.toDouble() },
            bleCountDelta = bleCountDelta(window.bleScans),
            bleRssiMean   = window.bleScans
                .flatMap { it.rssiValues }
                .let { rssiList -> if (rssiList.isEmpty()) 0.0 else rssiList.average() },

            // ── Pressão ──────────────────────────────────────────────────────────
            pressureDelta = pressureDelta(window.pressureReadings),
            pressureSlope = pressureSlope(window.pressureReadings),

            // ── Movimento ────────────────────────────────────────────────────────
            stationaryRatio = stationaryRatio(window.motionSamples),

            label = "unknown"
        )
    }

    // ── Helpers privados ─────────────────────────────────────────────────────────

    private fun <T> List<T>.meanOf(selector: (T) -> Double): Double =
        if (isEmpty()) 0.0 else sumOf(selector) / size

    /** Diferença entre a maior e a menor leitura de acurácia na janela */
    private fun gpsAccuracyDelta(readings: List<GpsReading>): Double {
        if (readings.size < 2) return 0.0
        val max = readings.maxOf { it.accuracyMeters }
        val min = readings.minOf { it.accuracyMeters }
        return (max - min).toDouble()
    }

    /** Diferença entre o primeiro e o último scan de contagem Wi-Fi */
    private fun wifiCountDelta(scans: List<WifiScan>): Double {
        if (scans.size < 2) return 0.0
        return (scans.last().apCount - scans.first().apCount).toDouble()
    }

    /** Diferença entre o primeiro e o último scan de contagem BLE */
    private fun bleCountDelta(scans: List<BleScan>): Double {
        if (scans.size < 2) return 0.0
        return (scans.last().deviceCount - scans.first().deviceCount).toDouble()
    }

    /** Diferença absoluta entre pressão máxima e mínima da janela */
    private fun pressureDelta(readings: List<PressureReading>): Double {
        if (readings.size < 2) return 0.0
        val max = readings.maxOf { it.hPa }
        val min = readings.minOf { it.hPa }
        return (max - min).toDouble()
    }

    /**
     * Inclinação (slope) da pressão ao longo do tempo usando regressão linear simples.
     * Unidade: hPa/segundo
     */
    private fun pressureSlope(readings: List<PressureReading>): Double {
        if (readings.size < 2) return 0.0
        val n = readings.size.toDouble()
        val t0 = readings.first().timestampMs
        val xs = readings.map { (it.timestampMs - t0) / 1000.0 }   // segundos
        val ys = readings.map { it.hPa.toDouble() }

        val sumX  = xs.sum()
        val sumY  = ys.sum()
        val sumXY = xs.zip(ys).sumOf { (x, y) -> x * y }
        val sumX2 = xs.sumOf { it * it }

        val denom = n * sumX2 - sumX * sumX
        return if (abs(denom) < 1e-9) 0.0 else (n * sumXY - sumX * sumY) / denom
    }

    /**
     * Rácio de amostras consideradas "paradas".
     * Usa a magnitude da aceleração líquida (sem gravidade) < threshold.
     */
    private fun stationaryRatio(samples: List<MotionSample>, threshold: Float = 1.5f): Double {
        if (samples.isEmpty()) return 1.0
        val stationary = samples.count { s ->
            val net = sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az)
            abs(net - 9.81f) < threshold
        }
        return stationary.toDouble() / samples.size
    }
}