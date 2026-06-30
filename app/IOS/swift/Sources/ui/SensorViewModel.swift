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
    // Resultado do scoring da última análise — baseline (tick de maior score) + série por tick.
    @Published var lastScore: WindowScore? = nil
    // Janela ao vivo — atualizada a 1 Hz enquanto a tela de logs estiver aberta
    @Published var liveWindow: SensorWindow = SensorWindow()
    // Deltas ao vivo — Δ de cada sensor nos últimos 10s, atualizado a 1 Hz
    @Published var liveDeltas: SensorDeltas? = nil

    // ── Captura manual (janela dinâmica) ──────────────
    // isManualCapture: true entre "Iniciar" e "Analisar ambiente".
    // manualElapsedS: segundos decorridos desde o "Iniciar" (atualizado a 1 Hz).
    @Published var isManualCapture = false
    @Published var manualElapsedS = 0

    private let collector = SensorCollector()
    private let repository = SensorRepository()
    private var isCollecting = false
    private var liveTimer: Timer? = nil
    private var manualStartMs: Int64 = 0
    private var manualTimer: Timer? = nil

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
    // Janela dinâmica por score: percorre o buffer (até 180s), acha o tick de
    // maior score de transição (GPS acc + speed + magnetómetro) e usa a janela
    // [tick de maior score → agora]. A 1ª leitura dessa janela é a baseline de rua.
    // Se nenhum tick passar o gate, recai na janela fixa de 30s.
    func sendCurrentWindow() {
        guard !isCollecting else { return }
        isCollecting = true
        uploadResult = .loading

        Task {
            defer { isCollecting = false }

            let buffer  = collector.getWindow(sinceMs: 0)   // buffer completo (até 180s)
            let scoring = buffer.computeScore()
            lastScore = scoring

            let window: SensorWindow
            if let startMs = scoring.bestTimestampMs {
                window = buffer.sliced(fromMs: startMs)
                let durS = Double(buffer.gpsReadings.last!.timestampMs - startMs) / 1000.0
                print(String(format: "[Score] melhor tick @%lld score=%.2f → janela de %.0fs",
                             startMs, scoring.bestScore, durS))
            } else {
                window = collector.getCurrentWindow()        // fallback: 30s fixo
                print("[Score] nenhum tick passou o gate — fallback janela 30s")
            }

            await process(window: window)
        }
    }

    // ── Captura manual (janela dinâmica) ──────────────

    /// "Iniciar" — marca o instante de arranque e começa a contar segundos a 1 Hz.
    func startManualCapture() {
        guard !isManualCapture, !isCollecting else { return }
        manualStartMs = collector.currentTimeMs()
        manualElapsedS = 0
        isManualCapture = true
        uploadResult = .idle

        manualTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.manualElapsedS = Int((self.collector.currentTimeMs() - self.manualStartMs) / 1000)
            }
        }
    }

    /// Cancela a captura manual sem analisar.
    func cancelManualCapture() {
        manualTimer?.invalidate(); manualTimer = nil
        isManualCapture = false
        manualElapsedS = 0
    }

    /// "Analisar ambiente" (dinâmico) — fecha a contagem e analisa a janela
    /// recortada desde o "Iniciar" (limitada a 180s pelo collector).
    func analyzeManualWindow() {
        guard isManualCapture, !isCollecting else { return }
        manualTimer?.invalidate(); manualTimer = nil
        isManualCapture = false
        isCollecting = true
        uploadResult = .loading

        let startMs = manualStartMs
        Task {
            defer { isCollecting = false }
            await process(window: collector.getWindow(sinceMs: startMs))
        }
    }

    func resetResult() {
        uploadResult = .idle
    }

    // ── Pipeline comum: payload + envio ───────────────
    private func process(window: SensorWindow) async {
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

    // ── Live window — para a tela de logs ────────────
    // Inicia um timer de 1 Hz que publica o estado atual do buffer.
    // Deve ser chamado no .onAppear da SensorLogsView.
    func startLiveUpdates() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let window = self.collector.getCurrentWindow()
                let deltas = window.deltas(overMs: 10_000)
                self.liveWindow = window
                self.liveDeltas = deltas

                // Log dos Δ (últimos 10s) a 1 Hz
                func fmt(_ v: Double?, _ unit: String) -> String {
                    guard let v else { return "n/a" }
                    return String(format: "%+.2f%@", v, unit)
                }
                print("[Δ 10s] pressure=\(fmt(deltas.pressureHpa, "hPa")) " +
                      "gps_acc=\(fmt(deltas.gpsAccuracyM, "m")) " +
                      "gps_speed=\(fmt(deltas.gpsSpeedMps, "m/s")) " +
                      "mag=\(fmt(deltas.magneticUt, "µT"))")
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
