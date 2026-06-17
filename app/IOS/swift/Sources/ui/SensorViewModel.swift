import Foundation
import Combine

// Equivalente ao SensorViewModel.kt
// AndroidViewModel      → ObservableObject
// StateFlow             → @Published
// viewModelScope.launch → Task {}
// SensorForegroundService (bound) → SensorCollector direto (iOS não tem Foreground Service da mesma forma)

@MainActor
final class SensorViewModel: ObservableObject {

    @Published var uploadResult: UploadResult = .idle

    private let collector = SensorCollector()
    private let repository = SensorRepository()
    private var isCollecting = false

    // ── Ciclo de vida ─────────────────────────────────
    // Chama no .onAppear da View (equivalente a onStart)
    func startCollecting() {
        collector.startContinuous(windowSizeMs: 30_000)
    }

    // Chama no .onDisappear (equivalente a onStop)
    // O collector continua em background — só paramos se a app fechar
    func stopCollecting() {
        collector.stopContinuous()
    }

    // ── Envio de dados ────────────────────────────────
    // Equivalente a sendCurrentWindow() do Kotlin
    func sendCurrentWindow() {
        guard !isCollecting else { return }
        isCollecting = true
        uploadResult = .loading

        Task {
            defer { isCollecting = false }

            let window = collector.getCurrentWindow()

            print("[SensorViewModel] Janela obtida — " +
                  "GPS=\(window.gpsReadings.count) " +
                  "Pressure=\(window.pressureReadings.count) " +
                  "Motion=\(window.motionSamples.count) " +
                  "Magnetic=\(window.magneticReadings.count)")

            guard let payload = window.toPayload() else {
                uploadResult = .error(message: "GPS insuficiente — aguarda sinal e tenta novamente")
                return
            }

            do {
                let response = try await SensorApiClient.shared.predictVerticalContext(payload: payload)
                uploadResult = .success(
                    classification: response.classification,
                    confidence: response.nonStreetConfidence
                )
            } catch SensorApiError.networkError(let e) {
                uploadResult = .error(message: "Servidor inacessível: \(e.localizedDescription)")
            } catch SensorApiError.httpError(let code) {
                uploadResult = .error(message: "Erro do servidor: HTTP \(code)")
            } catch {
                uploadResult = .error(message: error.localizedDescription)
            }
        }
    }

    func resetResult() {
        uploadResult = .idle
    }
}