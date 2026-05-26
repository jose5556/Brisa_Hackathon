package com.example.viaverde_team5

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.example.viaverde_team5.data.UploadResult
import com.example.viaverde_team5.ui.SensorViewModel
import com.example.viaverde_team5.ui.theme.ViaVerdeTeam5Theme

class MainActivity : ComponentActivity() {

    private val viewModel: SensorViewModel by viewModels()

    // ── Pedido de permissões ──────────────────────────────────────────────────
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* Permissões concedidas/negadas – a coleta trata SecurityException internamente */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestRequiredPermissions()

        setContent {
            ViaVerdeTeam5Theme {
                Scaffold(modifier = Modifier.fillMaxSize()) { padding ->
                    SensorScreen(
                        viewModel = viewModel,
                        modifier  = Modifier.padding(padding)
                    )
                }
            }
        }
    }

    private fun requestRequiredPermissions() {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.CHANGE_WIFI_STATE,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions += listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions += Manifest.permission.POST_NOTIFICATIONS
        }
        permissionLauncher.launch(permissions.toTypedArray())
    }
}

// ── Ecrã principal ────────────────────────────────────────────────────────────

@Composable
fun SensorScreen(viewModel: SensorViewModel, modifier: Modifier = Modifier) {
    val uploadResult by viewModel.uploadResult.collectAsState()

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "ViaVerde – Sensor Collector",
            style = MaterialTheme.typography.headlineMedium,
            textAlign = TextAlign.Center
        )

        Spacer(Modifier.height(32.dp))

        // ── Status ─────────────────────────────────────────────────────────
        StatusCard(uploadResult)

        Spacer(Modifier.height(32.dp))

        // ── Botão principal ────────────────────────────────────────────────
        Button(
            onClick = { viewModel.collectAndSend() },
            enabled = uploadResult !is UploadResult.Loading,
            modifier = Modifier.fillMaxWidth()
        ) {
            if (uploadResult is UploadResult.Loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary
                )
                Spacer(Modifier.width(8.dp))
                Text("A recolher dados… (30 s)")
            } else {
                Text("Iniciar recolha e envio")
            }
        }

        if (uploadResult !is UploadResult.Idle) {
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = { viewModel.resetResult() }) {
                Text("Limpar resultado")
            }
        }
    }
}

@Composable
private fun StatusCard(result: UploadResult) {
    val (text, containerColor) = when (result) {
        is UploadResult.Idle    -> "Pronto para recolher." to MaterialTheme.colorScheme.surfaceVariant
        is UploadResult.Loading -> "A recolher sensores e a enviar dados…" to MaterialTheme.colorScheme.surfaceVariant
        is UploadResult.Success -> {
            val msg = if (result.prediction != null)
                "✅ Enviado com sucesso!\nClassificação: ${result.prediction}"
            else
                "✅ Enviado com sucesso!"
            msg to MaterialTheme.colorScheme.primaryContainer
        }
        is UploadResult.Error   ->
            "❌ Erro: ${result.message}" to MaterialTheme.colorScheme.errorContainer
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = containerColor)
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodyMedium
        )
    }
}