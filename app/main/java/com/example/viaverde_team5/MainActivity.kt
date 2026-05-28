package com.example.viaverde_team5

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.viaverde_team5.data.UploadResult
import com.example.viaverde_team5.ui.SensorViewModel
import androidx.compose.foundation.Image


// ── Cores ViaVerde ────────────────────────────────────────────────────────────
val VVGreen      = Color(0xFF2DB022)
val VVGreenDark  = Color(0xFF1F8018)
val VVGreenLight = Color(0xFFE8F5E7)
val VVBackground = Color(0xFFF7F8F7)
val VVCard       = Color(0xFFFFFFFF)
val VVBorder     = Color(0xFFE0EDE0)
val VVText       = Color(0xFF1A1A1A)
val VVMuted      = Color(0xFF888888)

class MainActivity : ComponentActivity() {

    private val viewModel: SensorViewModel by viewModels()

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        // Só inicia o serviço depois de ter as permissões
        if (granted.values.any { it }) {
            viewModel.startAndBindService()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestRequiredPermissions()
        viewModel.startAndBindService()
        setContent {
            ViaVerdeAppTheme {
                ViaVerdeScreen(viewModel = viewModel)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // Liga-se ao serviço sempre que a Activity fica visível
        // Se o serviço ainda não arrancou, startAndBindService trata disso
        viewModel.startAndBindService()
    }

    override fun onStop() {
        super.onStop()
        // Só desliga o bind — o serviço CONTINUA em background
        viewModel.unbindService()
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


// ── Theme ─────────────────────────────────────────────────────────────────────

@Composable
fun ViaVerdeAppTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary   = VVGreen,
            background = VVBackground,
            surface   = VVCard,
        ),
        content = content
    )
}

// ── Ecrã principal ────────────────────────────────────────────────────────────

@Composable
fun ViaVerdeScreen(viewModel: SensorViewModel) {
    val uploadResult by viewModel.uploadResult.collectAsState()
    val isLoading = uploadResult is UploadResult.Loading

    // Animação da barra de progresso durante recolha
    val progressAnim = rememberInfiniteTransition(label = "progress")
    val progressVal by progressAnim.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(30_000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ), label = "progressVal"
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(VVBackground)
    ) {

        // ── Header verde ──────────────────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    Brush.verticalGradient(listOf(VVGreenDark, VVGreen))
                )
                .statusBarsPadding()
                .padding(horizontal = 24.dp, vertical = 28.dp)
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.fillMaxWidth()) {

                // Logo placeholder (substitui por Image(painterResource(R.drawable.logo_viaverde)))
                Box(
                    modifier = Modifier
                        .size(56.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color.White.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Image(
                        painter = painterResource(R.drawable.vv),
                        contentDescription = "Logo ViaVerde",
                        modifier = Modifier.size(56.dp).clip(RoundedCornerShape(14.dp))
                    )
                }

                Spacer(Modifier.height(10.dp))

                Text(
                    text = "VIA VERDE",
                    color = Color.White,
                    fontWeight = FontWeight.Black,
                    fontSize = 26.sp,
                    letterSpacing = 3.sp
                )
                Text(
                    text = "CONTEXT DETECTION",
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 2.sp
                )
            }
        }

        // ── Corpo ─────────────────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 20.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {

            // Card de estado
            StatusCard(uploadResult, if (isLoading) progressVal else 0f)

            // Grid de sensores
            Text("SENSORES ACTIVOS", fontSize = 10.sp, fontWeight = FontWeight.Bold,
                color = VVMuted, letterSpacing = 1.5.sp)

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SensorChip("GPS",      "Localização",  Modifier.weight(1f))
                SensorChip("Wi-Fi",    "Redes",        Modifier.weight(1f))
                SensorChip("BLE",      "Bluetooth",    Modifier.weight(1f))
                SensorChip("Bar.",     "Pressão",      Modifier.weight(1f))
            }

            // Resultado / classificação
            if (uploadResult is UploadResult.Success) {
                ResultCard(uploadResult as UploadResult.Success)
            }

            if (uploadResult is UploadResult.Error) {
                ErrorCard((uploadResult as UploadResult.Error).message)
            }

            Spacer(Modifier.weight(1f))

            // Botão principal
            Button(
                onClick = {
                    if (!isLoading) viewModel.sendCurrentWindow()
                    else viewModel.resetResult()
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = VVGreen,
                    disabledContainerColor = VVGreen.copy(alpha = 0.5f)
                )
            ) {
                if (isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = Color.White
                    )
                    Spacer(Modifier.width(10.dp))
                    Text("Analisando… (30s)", color = Color.White,
                        fontWeight = FontWeight.Bold, fontSize = 15.sp,
                        letterSpacing = 0.5.sp)
                } else {
                    Text("▶  ANALISAR AMBIENTE", color = Color.White,
                        fontWeight = FontWeight.Bold, fontSize = 15.sp,
                        letterSpacing = 1.sp)
                }
            }

            if (uploadResult !is UploadResult.Idle) {
                TextButton(
                    onClick = { viewModel.resetResult() },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Limpar resultado", color = VVMuted, fontSize = 13.sp)
                }
            }
        }
    }
}

// ── Componentes ───────────────────────────────────────────────────────────────

@Composable
fun StatusCard(result: UploadResult, progress: Float) {
    val (label, text, tagColor, tagText) = when (result) {
        is UploadResult.Idle    -> Quadruple("ESTADO", "Pronto para recolher dados", VVGreen, "Idle")
        is UploadResult.Loading -> Quadruple("A RECOLHER", "A capturar sensores…", Color(0xFFE65100), "Em curso")
        is UploadResult.Success -> Quadruple("CONCLUÍDO", "Dados enviados com sucesso", VVGreen, "OK")
        is UploadResult.Error   -> Quadruple("ERRO", "Falha no envio", Color(0xFFB00020), "Erro")
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = VVCard),
        border = androidx.compose.foundation.BorderStroke(1.dp, VVBorder)
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()) {
                Text(label, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                    color = VVGreen, letterSpacing = 1.5.sp)
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(tagColor.copy(alpha = 0.12f))
                        .padding(horizontal = 10.dp, vertical = 3.dp)
                ) {
                    Text(tagText, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                        color = tagColor, letterSpacing = 0.5.sp)
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(text, fontSize = 14.sp, color = VVText, fontWeight = FontWeight.Medium)

            if (result is UploadResult.Loading) {
                Spacer(Modifier.height(10.dp))
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(2.dp)),
                    color = VVGreen,
                    trackColor = VVGreenLight
                )
            }
        }
    }
}

@Composable
fun SensorChip(name: String, label: String, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = VVCard),
        border = androidx.compose.foundation.BorderStroke(1.dp, VVBorder)
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(VVGreen)
            )
            Spacer(Modifier.height(6.dp))
            Text(name, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = VVText,
                textAlign = TextAlign.Center)
            Text(label, fontSize = 9.sp, color = VVMuted, textAlign = TextAlign.Center,
                letterSpacing = 0.3.sp)
        }
    }
}

@Composable
fun ResultCard(result: UploadResult.Success) {
    val prediction = result.prediction ?: "—"
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = VVCard),
        border = androidx.compose.foundation.BorderStroke(1.dp, VVBorder)
    ) {
        Column(Modifier.padding(16.dp)) {
            Text("ÚLTIMA CLASSIFICAÇÃO", fontSize = 10.sp, fontWeight = FontWeight.Bold,
                color = VVMuted, letterSpacing = 1.5.sp)
            Spacer(Modifier.height(8.dp))
            Text(prediction, fontSize = 22.sp, fontWeight = FontWeight.Black, color = VVText)
        }
    }
}

@Composable
fun ErrorCard(message: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFFFFF0F0)),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFFFCDD2))
    ) {
        Text("⚠ $message", modifier = Modifier.padding(14.dp),
            fontSize = 13.sp, color = Color(0xFFB00020))
    }
}

// Util
data class Quadruple<A,B,C,D>(val first: A, val second: B, val third: C, val fourth: D)