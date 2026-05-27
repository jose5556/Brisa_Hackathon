package com.example.viaverde_team5.data.network

import com.example.viaverde_team5.data.model.SensorPayload
import com.google.gson.GsonBuilder
import com.google.gson.annotations.SerializedName
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.Body
import retrofit2.http.POST
import java.util.concurrent.TimeUnit

// Emulator Android:
// private const val BASE_URL = "http://10.0.2.2:8000/"

// Physical phone on same Wi-Fi as your PC:
private const val BASE_URL = "http://10.21.220.182:8000/"

/** Envia uma janela de features já calculadas. */
interface SensorApiService {
    @POST("predict")
    suspend fun predictVerticalContext(
        @Body payload: SensorPayload
    ): Response<PredictionResponse>
}

// ── Singleton Retrofit ─────────────────────────────────
data class PredictionResponse(
    @SerializedName("non_street_confidence")
    val nonStreetConfidence: Double,

    @SerializedName("classification")
    val classification: String
)

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