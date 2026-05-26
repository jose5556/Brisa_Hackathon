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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val TAG = "SensorCollector"

/**
 * Responsável pela coleta de todos os sensores durante uma janela de tempo.
 *
 * Uso:
 *   val collector = SensorCollector(context)
 *   collector.startWindow()
 *   delay(WINDOW_DURATION_MS)
 *   val window = collector.stopAndGetWindow()
 */
class SensorCollector(private val context: Context) {

    // ── Janela activa ────────────────────────────────────────────────────────
    private var window = SensorWindow()

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
                window.gpsReadings.add(GpsReading(accuracyMeters = 999f, hasSignal = false))
            }
        }
    }

    // ── SensorManager (pressão + acelerómetro) ───────────────────────────────
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val barometerSensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private val accelerometerSensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            when (event.sensor.type) {
                Sensor.TYPE_PRESSURE ->
                    window.pressureReadings.add(PressureReading(hPa = event.values[0]))
                Sensor.TYPE_ACCELEROMETER ->
                    window.motionSamples.add(
                        MotionSample(
                            ax = event.values[0],
                            ay = event.values[1],
                            az = event.values[2]
                        )
                    )
            }
        }
        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    // ── Wi-Fi ────────────────────────────────────────────────────────────────
    private val wifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    private var wifiJob: Job? = null
    private val coroutineScope = CoroutineScope(Dispatchers.IO)

    // ── BLE ──────────────────────────────────────────────────────────────────
    private val bluetoothAdapter =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager)
            ?.adapter

    private var bleJob: Job? = null

    // ── Controlo da janela ───────────────────────────────────────────────────

    /** Começa a recolha de dados. Chama antes de esperar pela duração da janela. */
    fun startWindow() {
        window = SensorWindow()   // reinicia

        startGps()
        startPressureAndAccelerometer()
        startWifiPolling()
        startBleScanning()
    }

    /** Para a recolha e devolve a janela preenchida. */
    fun stopAndGetWindow(): SensorWindow {
        stopGps()
        stopPressureAndAccelerometer()
        wifiJob?.cancel()
        bleJob?.cancel()
        return window
    }

    // ── GPS ──────────────────────────────────────────────────────────────────

    private fun startGps() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED) {
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
        window.gpsReadings.add(
            GpsReading(
                accuracyMeters = location.accuracy,
                hasSignal = true
            )
        )
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
                        val rssiList = results.map { it.level }
                        window.wifiScans.add(WifiScan(apCount = results.size, rssiValues = rssiList))
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Sem permissão Wi-Fi: ${e.message}")
                }
                delay(5_000L)   // scan a cada 5 s
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
                        delay(4_000L)                // scan durante 4 s
                        leScanner.stopScan(callback)

                        if (foundDevices.isNotEmpty()) {
                            window.bleScans.add(
                                BleScan(
                                    deviceCount = foundDevices.size,
                                    rssiValues  = foundDevices.values.toList()
                                )
                            )
                        }
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Sem permissão BLE: ${e.message}")
                }

                delay(1_000L)   // pausa entre ciclos de scan
            }
        }
    }
}