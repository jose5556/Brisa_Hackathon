import Foundation

// ── SensorRepository ──────────────────────────────────
// Orquestra o fluxo completo:
//   1. Recebe SensorWindow do SensorCollector
//   2. Calcula features via toPayload()
//   3. Envia para o servidor via SensorApiClient

final class SensorRepository {

    // ── buildPayload ──────────────────────────────────────
    // Passo 2: calcula features e constrói o payload.
    // NÃO faz rede para a API de classificação — assim os logs (RAW/FEATURES/
    // PAYLOAD) ficam disponíveis mesmo que o servidor esteja inacessível.
    // O cityBaselinePressure deixa de vir da API meteorológica: é a primeira
    // leitura barométrica da janela (pressão de rua, antes de o veículo parar).
    func buildPayload(window: SensorWindow) async throws -> SensorPayload {

        // ── 1. Garante que há sinal GPS na última leitura ──
        guard let lastGps = window.gpsReadings.last, lastGps.hasSignal else {
            throw SensorRepositoryError.noGpsSignal
        }

        // ── 2. Calcula features + constrói payload ───────
        guard let payload = window.toPayload() else {
            throw SensorRepositoryError.insufficientData
        }

        #if DEBUG
        print("[SensorRepository] Payload pronto — \(payload.windowDurationS)s de janela")
        print("  lat: \(payload.latitude), lon: \(payload.longitude)")
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