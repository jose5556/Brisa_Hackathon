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
    // Estado do feedback do utilizador sobre a decisão da última análise.
    @Published var feedbackState: FeedbackState = .idle
    @Published var lastPayload: SensorPayload? = nil
    @Published var lastWindow: SensorWindow? = nil
    // Resultado do scoring da última análise — baseline (tick de maior score) + série por tick.
    @Published var lastScore: WindowScore? = nil
    // Janela ao vivo — atualizada a 1 Hz enquanto a tela de logs estiver aberta
    @Published var liveWindow: SensorWindow = SensorWindow()
    // Deltas ao vivo — Δ de cada sensor nos últimos 10s, atualizado a 1 Hz
    @Published var liveDeltas: SensorDeltas? = nil

    // ── Recolha de dados (tela DATA) ──────────────────
    @Published var isDataRecording = false
    @Published var dataTicks: [SensorTick] = []

    private let collector = SensorCollector()
    private let repository = SensorRepository()
    private var isCollecting = false
    private var liveTimer: Timer? = nil
    private var dataStartMs: Int64 = 0
    private var dataTimer: Timer? = nil

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
            if let startMs = scoring.windowStartMs {
                window = buffer.sliced(fromMs: startMs)
                let durS = Double(buffer.gpsReadings.last!.timestampMs - startMs) / 1000.0
                print(String(format: "[Score] pico @%lld score=%.2f → baseline @%lld → janela de %.0fs",
                             scoring.bestTimestampMs ?? startMs, scoring.bestScore, startMs, durS))
            } else {
                window = collector.getCurrentWindow()        // fallback: 30s fixo
                print("[Score] nenhum tick passou o gate — fallback janela 30s")
            }

            await process(window: window)
        }
    }

    func resetResult() {
        uploadResult = .idle
        feedbackState = .idle
    }

    // ── Feedback do utilizador ────────────────────────
    // Envia para /feedback o veredicto (correto/incorreto) sobre a decisão de
    // cobrança da última análise bem-sucedida.
    func sendFeedback(_ verdict: FeedbackVerdict) {
        guard case .success(let response) = uploadResult else { return }
        guard feedbackState != .sending else { return }
        feedbackState = .sending

        Task {
            do {
                try await repository.sendFeedback(
                    payloadId: response.payloadId,
                    sessionId: response.sessionId,
                    ml1Classification: response.ml1Classification,
                    finalDecision: response.finalDecision,
                    feedback: verdict
                )
                feedbackState = .sent(verdict)
            } catch {
                feedbackState = .error(message: error.localizedDescription)
            }
        }
    }

    // ── Recolha de dados (tela DATA) ──────────────────

    func startDataRecording() {
        guard !isDataRecording else { return }
        dataTicks = []
        dataStartMs = collector.currentTimeMs()
        isDataRecording = true

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let window = self.collector.getCurrentWindow()
                let elapsed = Int((self.collector.currentTimeMs() - self.dataStartMs) / 1000)
                let ts = Date().iso8601
                let pressureHpa  = window.pressureReadings.last.map { Double($0.hPa) } ?? 0
                let gpsAccuracyM = window.gpsReadings.last.map { Double($0.accuracyMeters) } ?? 0
                let gpsSpeedMps  = window.gpsReadings.last?.speedMps ?? 0
                let magUt        = window.magneticReadings.last?.magnitude ?? 0
                self.dataTicks.append(SensorTick(
                    elapsedS:     elapsed,
                    timestamp:    ts,
                    pressureHpa:  pressureHpa,
                    gpsAccuracyM: gpsAccuracyM,
                    gpsSpeedMps:  gpsSpeedMps,
                    magUt:        magUt
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dataTimer = timer
    }

    func stopDataRecording() {
        dataTimer?.invalidate(); dataTimer = nil
        isDataRecording = false
    }

    func exportDataCSV() -> URL? {
        guard !dataTicks.isEmpty else { return nil }
        var csv = "elapsed_s,timestamp,pressure_hpa,gps_accuracy_m,gps_speed_mps,mag_ut\n"
        for tick in dataTicks {
            csv += "\(tick.elapsedS),\(tick.timestamp),"
            csv += "\(String(format: "%.2f", tick.pressureHpa)),"
            csv += "\(String(format: "%.2f", tick.gpsAccuracyM)),"
            csv += "\(String(format: "%.2f", tick.gpsSpeedMps)),"
            csv += "\(String(format: "%.2f", tick.magUt))\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brisa_sensor_data_\(Int(Date().timeIntervalSince1970)).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // ── Pipeline comum: payload + envio ───────────────
    private func process(window: SensorWindow) async {
        lastWindow = window
        feedbackState = .idle   // nova análise → limpa feedback anterior

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
            uploadResult = .success(response: response)
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
        let liveTick = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
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
        RunLoop.main.add(liveTick, forMode: .common)
        liveTimer = liveTick
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
