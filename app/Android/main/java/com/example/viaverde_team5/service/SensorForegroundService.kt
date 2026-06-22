package com.example.viaverde_team5.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.viaverde_team5.MainActivity
import com.example.viaverde_team5.R
import com.example.viaverde_team5.data.model.SensorWindow
import com.example.viaverde_team5.sensor.SensorCollector
import kotlinx.coroutines.*

private const val TAG             = "SensorForegroundService"
private const val CHANNEL_ID      = "viaverde_sensor_channel"
private const val NOTIFICATION_ID = 1

/**
 * Foreground Service que corre continuamente.
 * Mantém uma janela deslizante dos últimos WINDOW_SIZE_MS milissegundos.
 * A Activity/ViewModel pede getCurrentWindow() quando o utilizador prime o botão.
 */
class SensorForegroundService : Service() {

    // ── Janela deslizante ────────────────────────────────────────────────────
    companion object {
        /** Tamanho da janela deslizante: últimos 30 segundos */
        const val WINDOW_SIZE_MS = 30_000L

        /** Intent actions */
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP  = "ACTION_STOP"
    }

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var collector: SensorCollector

    // Binder para a Activity se ligar directamente ao serviço
    inner class LocalBinder : Binder() {
        fun getService(): SensorForegroundService = this@SensorForegroundService
    }
    private val binder = LocalBinder()

    override fun onBind(intent: Intent?): IBinder = binder

    // ── Ciclo de vida ────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        collector = SensorCollector(this)
        createNotificationChannel()
        Log.d(TAG, "Serviço criado")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCollection()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                startForeground(NOTIFICATION_ID, buildNotification("A monitorizar sensores…"))
                startCollection()
            }
        }
        // START_STICKY → Android reinicia o serviço se o matar por falta de memória
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCollection()
        serviceScope.cancel()
        Log.d(TAG, "Serviço destruído")
    }

    // ── Recolha contínua ─────────────────────────────────────────────────────

    private fun startCollection() {
        collector.startContinuous(windowSizeMs = WINDOW_SIZE_MS)
        Log.d(TAG, "Recolha contínua iniciada (janela = ${WINDOW_SIZE_MS}ms)")
    }

    private fun stopCollection() {
        collector.stopContinuous()
        Log.d(TAG, "Recolha parada")
    }

    /**
     * Devolve um snapshot da janela deslizante actual.
     * Chamado pelo ViewModel quando o utilizador prime o botão.
     */
    fun getCurrentWindow(): SensorWindow = collector.getCurrentWindow()

    // ── Notificação ───────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "ViaVerde Sensor Monitor",
            NotificationManager.IMPORTANCE_LOW   // LOW = sem som, sem popup
        ).apply {
            description = "Monitorização contínua de sensores em background"
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        // Tap na notificação → abre a app
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        // Botão "Parar" na notificação
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, SensorForegroundService::class.java).apply {
                action = ACTION_STOP
            },
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Via Verde")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_delete, "Parar", stopIntent)
            .setOngoing(true)       // não pode ser dispensada pelo utilizador
            .setSilent(true)
            .build()
    }

    fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}