package com.example.viaverde_team5.data.model

import com.google.gson.annotations.SerializedName

data class SensorPayload(
    // GPS / GNSS
    @SerializedName("gps_accuracy_mean") val gpsAccuracyMean: Double,
    @SerializedName("gps_accuracy_max") val gpsAccuracyMax: Double,
    @SerializedName("gps_accuracy_delta") val gpsAccuracyDelta: Double,
    @SerializedName("gps_lost_ratio") val gpsLostRatio: Double,

    // Wi-Fi
    @SerializedName("wifi_count_mean") val wifiCountMean: Double,
    @SerializedName("wifi_count_delta") val wifiCountDelta: Double,
    @SerializedName("wifi_rssi_mean") val wifiRssiMean: Double,

    // Bluetooth (BLE)
    @SerializedName("ble_count_mean") val bleCountMean: Double,
    @SerializedName("ble_count_delta") val bleCountDelta: Double,
    @SerializedName("ble_rssi_mean") val bleRssiMean: Double,

    // Barômetro
    @SerializedName("pressure_delta") val pressureDelta: Double,
    @SerializedName("pressure_slope") val pressureSlope: Double,

    // Movimento
    @SerializedName("stationary_ratio") val stationaryRatio: Double,

    // Deltas
    @SerializedName("altitude_delta") val altitudeDelta: Double,
    @SerializedName("vertical_change_abs") val verticalChangeAbs: Double,
    // Label (pode ser enviado como "unknown" até o servidor classificar)
    //@SerializedName("label") val label: String = "unknown",

    // Metadados extras (úteis para debug no servidor)
    //@SerializedName("device_id") val deviceId: String = "",
    //@SerializedName("timestamp_ms") val timestampMs: Long = System.currentTimeMillis()
)

/** Janela de amostras brutas coletadas durante o período de observação */
data class SensorWindow(
    // GPS
    val gpsReadings: MutableList<GpsReading> = mutableListOf(),

    // Wi-Fi
    val wifiScans: MutableList<WifiScan> = mutableListOf(),

    // BLE
    val bleScans: MutableList<BleScan> = mutableListOf(),

    // Pressão
    val pressureReadings: MutableList<PressureReading> = mutableListOf(),

    // Acelerómetro (para stationary_ratio)
    val motionSamples: MutableList<MotionSample> = mutableListOf()
)

data class GpsReading(
    val accuracyMeters: Float,   // getAccuracy()
    val altitudeMeters: Double,
    val hasSignal: Boolean,      // false quando GPS perdido
    val timestampMs: Long = System.currentTimeMillis()
)

data class WifiScan(
    val apCount: Int,            // número de APs visíveis
    val rssiValues: List<Int>,   // RSSI de cada AP
    val timestampMs: Long = System.currentTimeMillis()
)

data class BleScan(
    val deviceCount: Int,        // número de dispositivos BLE
    val rssiValues: List<Int>,   // RSSI de cada dispositivo
    val timestampMs: Long = System.currentTimeMillis()
)

data class PressureReading(
    val hPa: Float,
    val timestampMs: Long = System.currentTimeMillis()
)

data class MotionSample(
    val ax: Float, val ay: Float, val az: Float,
    val timestampMs: Long = System.currentTimeMillis()
)