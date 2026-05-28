package com.example.viaverde_team5.data

import android.content.Context
import android.util.Log
import com.example.viaverde_team5.data.model.SensorPayload
import com.example.viaverde_team5.data.network.RetrofitClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

private const val TAG = "SensorRepository"


sealed class UploadResult {
    object Idle : UploadResult()
    object Loading : UploadResult()
    data class Success(val prediction: String?) : UploadResult()
    data class Error(val message: String) : UploadResult()
}

/**
 * Ponto central de coordenação:
 *  1. Recebe a janela de amostras brutas
 *  2. Extrai as features via FeatureExtractor
 *  3. Envia para o servidor via Retrofit
 *  4. Expõe o resultado como StateFlow (consumido pelo ViewModel)
 */
class SensorRepository(private val context: Context) {

    private val api = RetrofitClient.apiService

    private val _uploadResult = MutableStateFlow<UploadResult>(UploadResult.Idle)
    val uploadResult: StateFlow<UploadResult> = _uploadResult

    /**
     * Guarda o payload numa linha CSV no ficheiro data.txt (armazenamento interno da app).
     * Cada chamada acrescenta uma linha — o ficheiro nunca é apagado automaticamente.
     *
     * Localização no dispositivo:
     *   /data/data/com.example.viaverde_team5/files/data.txt
     *   (acessível via Android Studio > Device Explorer, ou adb pull)
     */

    private fun savePayloadToCsv(payload: SensorPayload) {
        try {
            val file = java.io.File(context.filesDir, "data.txt")

            // Cabeçalho na primeira vez
            if (!file.exists()) {
                file.writeText(
                    "gps_accuracy_mean,gps_accuracy_max,gps_accuracy_delta,gps_lost_ratio," +
                            "wifi_count_mean,wifi_count_delta,wifi_rssi_mean," +
                            "ble_count_mean,ble_count_delta,ble_rssi_mean," +
                            "pressure_delta,pressure_slope," +
                            "stationary_ratio," +
                            "altitude_delta,vertical_change_abs\n"
                )
            }

            val line =
                "${payload.gpsAccuracyMean},${payload.gpsAccuracyMax}," +
                        "${payload.gpsAccuracyDelta},${payload.gpsLostRatio}," +
                        "${payload.wifiCountMean},${payload.wifiCountDelta},${payload.wifiRssiMean}," +
                        "${payload.bleCountMean},${payload.bleCountDelta},${payload.bleRssiMean}," +
                        "${payload.pressureDelta},${payload.pressureSlope}," +
                        "${payload.stationaryRatio}," +
                        "${payload.altitudeDelta},${payload.verticalChangeAbs}\n"

            file.appendText(line)

            Log.d(TAG, "CSV guardado: ${file.absolutePath}")

        } catch (e: Exception) {
            Log.e(TAG, "Erro ao guardar CSV: ${e.message}", e)
        }
    }

    /** Chama em background (coroutine) com a janela já preenchida. */
    suspend fun processAndSend(window: com.example.viaverde_team5.data.model.SensorWindow) {

        _uploadResult.value = UploadResult.Loading

        try {
            val deviceId = getDeviceId()

            val payload: SensorPayload =
                FeatureExtractor.extract(window, deviceId)

            //savePayloadToCsv(payload)

            // ── LOG FORMATADO ─────────────────────────────
            Log.d(
                TAG,
                """
            ========= SENSOR PAYLOAD =========

            GPS
            gps_accuracy_mean = ${payload.gpsAccuracyMean}
            gps_accuracy_max = ${payload.gpsAccuracyMax}
            gps_accuracy_delta = ${payload.gpsAccuracyDelta}
            gps_lost_ratio = ${payload.gpsLostRatio}

            WIFI
            wifi_count_mean = ${payload.wifiCountMean}
            wifi_count_delta = ${payload.wifiCountDelta}
            wifi_rssi_mean = ${payload.wifiRssiMean}

            BLE
            ble_count_mean = ${payload.bleCountMean}
            ble_count_delta = ${payload.bleCountDelta}
            ble_rssi_mean = ${payload.bleRssiMean}

            PRESSURE
            pressure_delta = ${payload.pressureDelta}
            pressure_slope = ${payload.pressureSlope}
            
            ALTITUDE DELTA
            altitude_delta = ${payload.altitudeDelta}
            vertical_change_abs = ${payload.verticalChangeAbs}

            MOVEMENT
            stationary_ratio = ${payload.stationaryRatio}

            ==================================
            """.trimIndent()
            )

            // AQUI ENVIAR PARA SERVIDOR / MODELO
            val response = api.predictVerticalContext(payload)

            if (response.isSuccessful) {
                val body = response.body()

                if (body != null) {
                    val predictionText =
                        "classification = ${body.classification}\n" +
                        "non_street_confidence = ${body.nonStreetConfidence}"

                    Log.d(
                        TAG,
                        """
                    ========= MODEL RESPONSE =========
                    classification = ${body.classification}
                    non_street_confidence = ${body.nonStreetConfidence}
                    ==================================
                    """.trimIndent()
                    )

                    _uploadResult.value =
                        UploadResult.Success(predictionText)
                } else {
                    _uploadResult.value =
                        UploadResult.Error("Resposta vazia do servidor")
                }
            } else {
                val errorBody = response.errorBody()?.string()

                Log.e(
                    TAG,
                    "Erro do servidor: ${response.code()} - $errorBody"
                )

                _uploadResult.value =
                    UploadResult.Error(
                        "Erro do servidor: ${response.code()}"
                    )
            }

        } catch (e: Exception) {

            Log.e(TAG, "Erro ao processar dados: ${e.message}", e)

            _uploadResult.value =
                UploadResult.Error(e.message ?: "Erro desconhecido")
        }
    }

    fun resetState() {
        _uploadResult.value = UploadResult.Idle
    }

    /** Identificador único e estável do dispositivo (não requer permissão especial) */
    private fun getDeviceId(): String {
        val prefs = context.getSharedPreferences("viaverde_prefs", Context.MODE_PRIVATE)
        return prefs.getString("device_id", null) ?: run {
            val id = java.util.UUID.randomUUID().toString()
            prefs.edit().putString("device_id", id).apply()
            id
        }
    }
}