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
    @Published var lastPayload: SensorPayload? = nil
    @Published var lastWindow: SensorWindow? = nil
    // Janela ao vivo — atualizada a 1 Hz enquanto a tela de logs estiver aberta
    @Published var liveWindow: SensorWindow = SensorWindow()

    private let collector = SensorCollector()
    private let repository = SensorRepository()
    private var isCollecting = false
    private var liveTimer: Timer? = nil

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
            lastWindow = window

            print("[SensorViewModel] Janela obtida — " +
                  "GPS=\(window.gpsReadings.count) " +
                  "Pressure=\(window.pressureReadings.count) " +
                  "Magnetic=\(window.magneticReadings.count)")

            do {
                // 1. Constrói o payload (meteorologia + features) — SEM rede para a API.
                //    Assim os logs ficam disponíveis mesmo que o servidor esteja inacessível.
                let payload = try await repository.buildPayload(window: window)
                lastPayload = payload

                // 2. Só depois tenta enviar para a API de classificação.
                let response = try await repository.send(payload: payload)
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

    // ── Live window — para a tela de logs ────────────
    // Inicia um timer de 1 Hz que publica o estado atual do buffer.
    // Deve ser chamado no .onAppear da SensorLogsView.
    func startLiveUpdates() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.liveWindow = self.collector.getCurrentWindow()
            }
        }
    }

    // Deve ser chamado no .onDisappear da SensorLogsView.
    func stopLiveUpdates() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    // ── Teste rápido de ligação à BD ──────────────────
    // Chama GET /db/health e imprime o retorno no console.
    func testDbConnection() {
        Task { await SensorApiClient.shared.checkDbHealth() }
    }
}
