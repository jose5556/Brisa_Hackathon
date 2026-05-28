package com.example.viaverde_team5.sensor

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.net.wifi.WifiManager
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.example.viaverde_team5.data.model.*
import com.google.android.gms.location.*
import kotlinx.coroutines.*

private const val TAG = "SensorCollector"

/**
 * Dois modos de operação:
 *
 * 1. CONTÍNUO (Foreground Service):
 *    startContinuous(windowSizeMs) → corre para sempre, mantém janela deslizante
 *    getCurrentWindow()            → snapshot dos últimos windowSizeMs ms
 *    stopContinuous()
 *
 * 2. JANELA ÚNICA (compatibilidade):
 *    startWindow() → stopAndGetWindow()
 */
class SensorCollector(private val context: Context) {

    // ── Buffers deslizantes ──────────────────────────────────────────────────
    private val allGpsReadings      = mutableListOf<GpsReading>()
    private val allWifiScans        = mutableListOf<WifiScan>()
    private val allBleScans         = mutableListOf<BleScan>()
    private val allPressureReadings = mutableListOf<PressureReading>()
    private val allMotionSamples    = mutableListOf<MotionSample>()

    private var windowSizeMs: Long = 30_000L
    private var isRunning = false

    // ── FusedLocationProvider (GPS/GNSS) ─────────────────────────────────────
    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)

    private val locationRequest = LocationRequest.Builder(
        Priority.PRIORITY_HIGH_ACCURACY, 2_000L
    ).setMinUpdateIntervalMillis(1_000L).build()

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.lastLocation?.let { addGpsReading(it) }
        }
        override fun onLocationAvailability(availability: LocationAvailability) {
            if (!availability.isLocationAvailable) {
                synchronized(allGpsReadings) {
                    allGpsReadings.add(
                        GpsReading(
                            accuracyMeters = 999f,
                            altitudeMeters = 0.0,
                            hasSignal      = false
                        )
                    )
                }
            }
        }
    }

    // ── SensorManager (pressão + acelerómetro) ───────────────────────────────
    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val barometerSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private val accelerometerSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val now = System.currentTimeMillis()
            when (event.sensor.type) {
                Sensor.TYPE_PRESSURE ->
                    synchronized(allPressureReadings) {
                        allPressureReadings.add(
                            PressureReading(hPa = event.values[0], timestampMs = now)
                        )
                    }
                Sensor.TYPE_ACCELEROMETER ->
                    synchronized(allMotionSamples) {
                        allMotionSamples.add(
                            MotionSample(
                                ax          = event.values[0],
                                ay          = event.values[1],
                                az          = event.values[2],
                                timestampMs = now
                            )
                        )
                    }
            }
        }
        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    // ── Wi-Fi ────────────────────────────────────────────────────────────────
    private val wifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    // ── BLE ──────────────────────────────────────────────────────────────────
    private val bluetoothAdapter =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager)
            ?.adapter

    private val coroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var wifiJob: Job? = null
    private var bleJob: Job? = null
    private var trimJob: Job? = null

    // ── API pública — modo contínuo ──────────────────────────────────────────

    fun startContinuous(windowSizeMs: Long = 30_000L) {
        if (isRunning) return
        this.windowSizeMs = windowSizeMs
        isRunning = true

        startGps()
        startPressureAndAccelerometer()
        startWifiPolling()
        startBleScanning()
        startTrimJob()

        Log.d(TAG, "Modo contínuo iniciado (janela = ${windowSizeMs}ms)")
    }

    /**
     * Snapshot thread-safe da janela deslizante actual.
     * Chamado pelo ViewModel quando o utilizador prime o botão.
     */
    fun getCurrentWindow(): SensorWindow {
        val cutoff = System.currentTimeMillis() - windowSizeMs
        return SensorWindow(
            gpsReadings      = synchronized(allGpsReadings)      { allGpsReadings.filter      { it.timestampMs >= cutoff }.toMutableList() },
            wifiScans        = synchronized(allWifiScans)        { allWifiScans.filter        { it.timestampMs >= cutoff }.toMutableList() },
            bleScans         = synchronized(allBleScans)         { allBleScans.filter         { it.timestampMs >= cutoff }.toMutableList() },
            pressureReadings = synchronized(allPressureReadings) { allPressureReadings.filter { it.timestampMs >= cutoff }.toMutableList() },
            motionSamples    = synchronized(allMotionSamples)    { allMotionSamples.filter    { it.timestampMs >= cutoff }.toMutableList() }
        )
    }

    fun stopContinuous() {
        if (!isRunning) return
        isRunning = false
        stopGps()
        stopPressureAndAccelerometer()
        wifiJob?.cancel()
        bleJob?.cancel()
        trimJob?.cancel()
        Log.d(TAG, "Modo contínuo parado")
    }

    // ── API pública — modo janela única (compatibilidade) ────────────────────

    fun startWindow() = startContinuous()

    fun stopAndGetWindow(): SensorWindow {
        val window = getCurrentWindow()
        stopContinuous()
        return window
    }

    // ── GPS ──────────────────────────────────────────────────────────────────

    private fun startGps() {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "Permissão de localização não concedida")
            return
        }
        fusedLocationClient.requestLocationUpdates(
            locationRequest, locationCallback, Looper.getMainLooper()
        )
    }

    private fun stopGps() {
        fusedLocationClient.removeLocationUpdates(locationCallback)
    }

    private fun addGpsReading(location: Location) {
        synchronized(allGpsReadings) {
            allGpsReadings.add(
                GpsReading(
                    accuracyMeters = location.accuracy,
                    altitudeMeters = location.altitude,   // ← mantido da tua versão
                    hasSignal      = true,
                    timestampMs    = System.currentTimeMillis()
                )
            )
        }
    }

    // ── Pressão + Acelerómetro ───────────────────────────────────────────────

    private fun startPressureAndAccelerometer() {
        barometerSensor?.let {
            sensorManager.registerListener(sensorListener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        accelerometerSensor?.let {
            sensorManager.registerListener(sensorListener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    private fun stopPressureAndAccelerometer() {
        sensorManager.unregisterListener(sensorListener)
    }

    // ── Wi-Fi ────────────────────────────────────────────────────────────────

    @Suppress("DEPRECATION")
    private fun startWifiPolling() {
        wifiJob = coroutineScope.launch {
            while (isActive) {
                try {
                    val results = wifiManager.scanResults
                    if (results.isNotEmpty()) {
                        synchronized(allWifiScans) {
                            allWifiScans.add(
                                WifiScan(
                                    apCount    = results.size,
                                    rssiValues = results.map { it.level }
                                )
                            )
                        }
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Sem permissão Wi-Fi: ${e.message}")
                }
                delay(5_000L)
            }
        }
    }

    // ── BLE ──────────────────────────────────────────────────────────────────

    private fun startBleScanning() {
        val leScanner = bluetoothAdapter?.bluetoothLeScanner ?: run {
            Log.w(TAG, "BLE não disponível neste dispositivo")
            return
        }

        bleJob = coroutineScope.launch {
            while (isActive) {
                val foundDevices = mutableMapOf<String, Int>()   // address → RSSI

                val callback = object : android.bluetooth.le.ScanCallback() {
                    override fun onScanResult(
                        callbackType: Int,
                        result: android.bluetooth.le.ScanResult
                    ) {
                        foundDevices[result.device.address] = result.rssi
                    }
                }

                try {
                    if (ContextCompat.checkSelfPermission(
                            context, Manifest.permission.BLUETOOTH_SCAN
                        ) == PackageManager.PERMISSION_GRANTED ||
                        android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S
                    ) {
                        leScanner.startScan(callback)
                        delay(4_000L)
                        leScanner.stopScan(callback)

                        if (foundDevices.isNotEmpty()) {
                            synchronized(allBleScans) {
                                allBleScans.add(
                                    BleScan(
                                        deviceCount = foundDevices.size,
                                        rssiValues  = foundDevices.values.toList()
                                    )
                                )
                            }
                        }
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Sem permissão BLE: ${e.message}")
                }

                delay(1_000L)
            }
        }
    }

    // ── Trim periódico ────────────────────────────────────────────────────────

    /** Remove amostras mais antigas que 2x a janela para não crescer infinitamente */
    private fun startTrimJob() {
        trimJob = coroutineScope.launch {
            while (isActive) {
                delay(60_000L)
                val cutoff = System.currentTimeMillis() - (windowSizeMs * 2)
                synchronized(allGpsReadings)      { allGpsReadings.removeAll      { it.timestampMs < cutoff } }
                synchronized(allWifiScans)        { allWifiScans.removeAll        { it.timestampMs < cutoff } }
                synchronized(allBleScans)         { allBleScans.removeAll         { it.timestampMs < cutoff } }
                synchronized(allPressureReadings) { allPressureReadings.removeAll { it.timestampMs < cutoff } }
                synchronized(allMotionSamples)    { allMotionSamples.removeAll    { it.timestampMs < cutoff } }
                Log.d(TAG, "Trim feito — cutoff = $cutoff")
            }
        }
    }
}