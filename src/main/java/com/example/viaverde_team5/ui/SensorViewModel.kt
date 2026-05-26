package com.example.viaverde_team5.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.viaverde_team5.data.SensorRepository
import com.example.viaverde_team5.data.UploadResult
import com.example.viaverde_team5.sensor.SensorCollector
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Duração da janela de observação em milissegundos (30 s por defeito) */
private const val WINDOW_DURATION_MS = 30_000L

class SensorViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = SensorRepository(application)
    private val collector  = SensorCollector(application)

    val uploadResult: StateFlow<UploadResult> = repository.uploadResult

    /** Indica se uma recolha está em progresso (para bloquear o botão) */
    private var isCollecting = false

    /**
     * Inicia uma janela de recolha, depois envia os dados.
     * Pode ser chamado directamente por um botão na UI.
     */
    fun collectAndSend() {
        if (isCollecting) return
        isCollecting = true

        viewModelScope.launch {
            collector.startWindow()
            delay(WINDOW_DURATION_MS)
            val window = collector.stopAndGetWindow()
            repository.processAndSend(window)
            isCollecting = false
        }
    }

    fun resetResult() = repository.resetState()
}