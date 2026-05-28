package com.example.viaverde_team5.ui

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.viaverde_team5.data.SensorRepository
import com.example.viaverde_team5.data.UploadResult
import com.example.viaverde_team5.service.SensorForegroundService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

private const val TAG = "SensorViewModel"

class SensorViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = SensorRepository(application)
    val uploadResult: StateFlow<UploadResult> = repository.uploadResult

    // ── Estado do serviço ────────────────────────────────────────────────────

    private val _serviceRunning = MutableStateFlow(false)
    val serviceRunning: StateFlow<Boolean> = _serviceRunning.asStateFlow()

    private var boundService: SensorForegroundService? = null

    /** Indica se um envio está em progresso (para bloquear o botão) */
    private var isCollecting = false

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            boundService = (binder as SensorForegroundService.LocalBinder).getService()
            _serviceRunning.value = true
            Log.d(TAG, "Serviço ligado")
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            boundService = null
            _serviceRunning.value = false
            Log.d(TAG, "Serviço desligado")
        }
    }

    // ── Controlo do serviço ──────────────────────────────────────────────────

    /** Chama na Activity.onStart() */
    fun startAndBindService() {
        val app = getApplication<Application>()
        val intent = Intent(app, SensorForegroundService::class.java).apply {
            action = SensorForegroundService.ACTION_START
        }
        app.startForegroundService(intent)
        app.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        Log.d(TAG, "startAndBindService chamado")
    }

    /** Chama na Activity.onStop() — só desliga o bind, o serviço continua */
    fun unbindService() {
        try {
            getApplication<Application>().unbindService(serviceConnection)
        } catch (e: Exception) {
            Log.w(TAG, "unbindService: ${e.message}")
        }
        boundService = null
    }

    /** Para completamente o serviço (botão "Parar" na UI, se existir) */
    fun stopService() {
        val app = getApplication<Application>()
        app.stopService(Intent(app, SensorForegroundService::class.java))
        _serviceRunning.value = false
    }

    // ── Envio de dados ───────────────────────────────────────────────────────

    /**
     * Pega na janela deslizante actual e envia para o servidor.
     * Instantâneo — os dados já estão recolhidos em background pelo serviço.
     * O serviço NÃO é interrompido.
     */
    fun sendCurrentWindow() {
        if (isCollecting) return
        isCollecting = true

        val service = boundService
        if (service == null) {
            Log.w(TAG, "Serviço não está ligado ainda")
            isCollecting = false
            return
        }

        viewModelScope.launch {
            try {
                val window = service.getCurrentWindow()
                Log.d(TAG, "Janela obtida — GPS=${window.gpsReadings.size} " +
                        "WiFi=${window.wifiScans.size} " +
                        "BLE=${window.bleScans.size} " +
                        "Pressure=${window.pressureReadings.size} " +
                        "Motion=${window.motionSamples.size}")
                repository.processAndSend(window)
            } catch (e: Exception) {
                Log.e(TAG, "Erro no envio: ${e.message}", e)
            } finally {
                isCollecting = false
            }
        }
    }

    fun resetResult() = repository.resetState()

    override fun onCleared() {
        super.onCleared()
        unbindService()
    }
}