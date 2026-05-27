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

    /** Chama em background (coroutine) com a janela já preenchida. */
    suspend fun processAndSend(window: com.example.viaverde_team5.data.model.SensorWindow) {
        _uploadResult.value = UploadResult.Loading
        try {
            val deviceId = getDeviceId()
            val payload: SensorPayload = FeatureExtractor.extract(window, deviceId)

            Log.d(TAG, "Payload pronto: $payload")

            val response = api.sendSensorData(payload)
            if (response.isSuccessful) {
                val prediction = response.body()?.prediction
                Log.d(TAG, "Upload OK – prediction=$prediction")
                _uploadResult.value = UploadResult.Success(prediction)
            } else {
                val err = "HTTP ${response.code()}: ${response.errorBody()?.string()}"
                Log.e(TAG, err)
                _uploadResult.value = UploadResult.Error(err)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Erro ao enviar dados: ${e.message}", e)
            _uploadResult.value = UploadResult.Error(e.message ?: "Erro desconhecido")
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