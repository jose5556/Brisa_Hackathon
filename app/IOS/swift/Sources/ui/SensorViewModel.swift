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
                  "Magnetic=\(window.magneticReadings.count)")

            do {
                // O repository busca a meteorologia, calcula as features e envia para a API
                let response = try await repository.processAndSend(window: window)
                uploadResult = .success(
                    classification: response.classification,
                    confidence: response.nonStreetConfidence
                )
            } catch SensorApiError.networkError(let e) {
                uploadResult = .error(message: "Servidor inacessível: \(e.localizedDescription)")
            } catch SensorApiError.httpError(let code) {
                uploadResult = .error(message: "Erro do servidor: HTTP \(code)")
            } catch let e as SensorRepositoryError {
                uploadResult = .error(message: e.localizedDescription)
            } catch {
                uploadResult = .error(message: error.localizedDescription)
            }
        }
    }

    func resetResult() {
        uploadResult = .idle
    }
}