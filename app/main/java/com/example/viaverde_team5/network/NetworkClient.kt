package com.example.viaverde_team5.data.network

import com.example.viaverde_team5.data.model.SensorPayload
import com.google.gson.GsonBuilder
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.Body
import retrofit2.http.POST
import java.util.concurrent.TimeUnit

// ── Constantes de configuração ────────────────────────────────────────────────
// Troca BASE_URL pelo endpoint real quando tiveres o servidor configurado.
private const val BASE_URL = "https://your-server.example.com/"

// ── Interface Retrofit ────────────────────────────────────────────────────────
interface SensorApiService {

    /** Envia uma janela de features já calculadas. */
    @POST("api/sensor-data")
    suspend fun sendSensorData(@Body payload: SensorPayload): Response<ApiResponse>
}

/** Resposta genérica do servidor */
data class ApiResponse(
    val status: String,
    val message: String? = null,
    val prediction: String? = null   // caso o servidor devolva a classificação
)

// ── Singleton Retrofit ────────────────────────────────────────────────────────
object RetrofitClient {

    private val loggingInterceptor = HttpLoggingInterceptor().apply {
        level = HttpLoggingInterceptor.Level.BODY
    }

    private val okHttpClient = OkHttpClient.Builder()
        .addInterceptor(loggingInterceptor)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()

    private val gson = GsonBuilder().serializeNulls().create()

    val apiService: SensorApiService by lazy {
        Retrofit.Builder()
            .baseUrl(BASE_URL)
            .client(okHttpClient)
            .addConverterFactory(GsonConverterFactory.create(gson))
            .build()
            .create(SensorApiService::class.java)
    }
}