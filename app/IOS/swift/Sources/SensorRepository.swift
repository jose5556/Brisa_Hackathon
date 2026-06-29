import Foundation

// ── SensorRepository ──────────────────────────────────
// Orquestra o fluxo completo:
//   1. Recebe SensorWindow do SensorCollector
//   2. Busca dados meteorológicos via WeatherService (coordenadas do GPS)
//   3. Calcula features via toPayload()
//   4. Envia para o servidor via SensorApiClient

final class SensorRepository {

    // ── buildPayload ──────────────────────────────────────
    // Passos 1-3: busca meteorologia, calcula features e constrói o payload.
    // NÃO faz rede para a API de classificação — assim os logs (RAW/FEATURES/
    // PAYLOAD) ficam disponíveis mesmo que o servidor esteja inacessível.
    func buildPayload(window: SensorWindow) async throws -> SensorPayload {

        // ── 1. Extrai coordenadas da última leitura GPS ──
        guard let lastGps = window.gpsReadings.last, lastGps.hasSignal else {
            throw SensorRepositoryError.noGpsSignal
        }

        // ── 2. Busca dados meteorológicos ────────────────
        // Corre em paralelo com o cálculo de features para não bloquear
        let weatherData: WeatherData
        do {
            weatherData = try await WeatherService.shared.fetch(
                latitude:  lastGps.latitude,
                longitude: lastGps.longitude
            )
            print("[SensorRepository] Tempo: \(weatherData.weatherCondition) " +
                  "| Pressão baseline: \(weatherData.cityBaselinePressure) hPa")
        } catch {
            // Se a API meteorológica falhar, usa valores neutros e continua
            // — não queremos bloquear o envio por causa do tempo
            print("[SensorRepository] ⚠ WeatherService falhou: \(error.localizedDescription) — usando defaults")
            weatherData = WeatherData(
                cityBaselinePressure: 1013.25,   // pressão padrão ao nível do mar
                weatherCondition:     "clear"
            )
        }

        // ── 3. Calcula features + constrói payload ───────
        guard let payload = window.toPayload(
            cityBaselinePressure: weatherData.cityBaselinePressure,
            weatherCondition:     weatherData.weatherCondition
        ) else {
            throw SensorRepositoryError.insufficientData
        }

        #if DEBUG
        print("[SensorRepository] Payload pronto — \(payload.windowDurationS)s de janela")
        print("  lat: \(payload.latitude), lon: \(payload.longitude)")
        print("  weatherCondition: \(payload.weatherCondition)")
        print("  cityBaselinePressure: \(payload.cityBaselinePressure) hPa")
        print("  pressureHpa: \(payload.pressureHpa) hPa")
        print("  pressureDeltaHpa: \(payload.pressureDeltaHpa) hPa")
        #endif

        return payload
    }

    // ── send ──────────────────────────────────────────────
    // Passo 4: envia um payload já construído para a API de classificação.
    func send(payload: SensorPayload) async throws -> PredictionResponse {
        return try await SensorApiClient.shared.predictVerticalContext(payload: payload)
    }
}

// ── Erros ─────────────────────────────────────────────
enum SensorRepositoryError: Error, LocalizedError {
    case noGpsSignal
    case insufficientData

    var errorDescription: String? {
        switch self {
        case .noGpsSignal:       return "Sem sinal GPS — aguarda e tenta novamente."
        case .insufficientData:  return "Dados insuficientes para classificar — aguarda mais alguns segundos."
        }
    }
}