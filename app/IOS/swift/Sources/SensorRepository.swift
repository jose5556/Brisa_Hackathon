import Foundation

// Camada fina de repositório — equivalente ao SensorRepository.kt
// Centraliza a lógica de processamento antes de chamar a API.
// Pode ser expandido para persistência local (CoreData / UserDefaults).

final class SensorRepository {

    func processAndSend(window: SensorWindow) async throws -> PredictionResponse {
        guard let payload = window.toPayload() else {
            throw SensorApiError.encodingFailed
        }
        return try await SensorApiClient.shared.predictVerticalContext(payload: payload)
    }
}