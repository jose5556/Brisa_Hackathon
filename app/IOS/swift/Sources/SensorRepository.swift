import Foundation
import CoreLocation

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

        // ── 1. Última leitura GPS válida ──
        // Prefere a última leitura com sinal; se o sinal se perdeu no fim da
        // janela (túnel/garagem), recua para a última leitura com coordenadas
        // conhecidas em vez de bloquear o envio. Só falha se a janela inteira
        // não tiver nenhuma posição utilizável.
        guard let lastGps = window.gpsReadings.last(where: { $0.hasSignal })
                ?? window.gpsReadings.last(where: { $0.latitude != 0 || $0.longitude != 0 }) else {
            throw SensorRepositoryError.noGpsSignal
        }

        // ── 2. Calcula features + constrói payload ───────
        guard var payload = window.toPayload() else {
            throw SensorRepositoryError.insufficientData
        }

        // ── 3. Reverse geocoding da última leitura GPS ───
        // Best-effort: se falhar (sem rede, sem resultado), city fica nil
        // e o envio prossegue na mesma.
        payload.city = await Self.resolveCity(latitude: lastGps.latitude,
                                              longitude: lastGps.longitude)

        #if DEBUG
        print("[SensorRepository] Payload pronto — \(payload.windowDurationS)s de janela")
        print("  lat: \(payload.latitude), lon: \(payload.longitude)")
        print("  city: \(payload.city ?? "—")")
        print("  pressureHpa: \(payload.pressureHpa) hPa")
        print("  pressureDeltaHpa: \(payload.pressureDeltaHpa) hPa")
        #endif

        return payload
    }

    // ── resolveCity ───────────────────────────────────────
    // Converte coordenadas em nome de cidade via CLGeocoder (reverse geocoding).
    // Assíncrono e depende de rede — por isso é chamado uma única vez, antes do envio.
    private static func resolveCity(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            // locality = cidade; fallbacks para não devolver nil desnecessariamente.
            return placemarks.first?.locality
                ?? placemarks.first?.subAdministrativeArea
                ?? placemarks.first?.administrativeArea
        } catch {
            #if DEBUG
            print("[SensorRepository] reverse geocoding falhou: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // ── send ──────────────────────────────────────────────
    // Passo 4: envia um payload já construído para a API de classificação.
    func send(payload: SensorPayload) async throws -> PredictionResponse {
        return try await SensorApiClient.shared.predictVerticalContext(payload: payload)
    }

    // ── sendFeedback ──────────────────────────────────────
    // Passo 5 (opcional): reencaminha o veredicto do utilizador sobre a decisão
    // de cobrança para a API de feedback.
    func sendFeedback(
        payloadId: String,
        sessionId: String,
        feedback: FeedbackVerdict
    ) async throws {
        try await SensorApiClient.shared.sendFeedback(
            payloadId: payloadId,
            sessionId: sessionId,
            feedback: feedback
        )
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