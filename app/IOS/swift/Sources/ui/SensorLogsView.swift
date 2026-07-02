import SwiftUI

// ── SensorLogsView ────────────────────────────────────
// Tela de developer logs — acessível via botão DEV no header.
// Mostra o pipeline completo: RAW → FEATURES → PAYLOAD → RESPOSTA.
struct SensorLogsView: View {

    @ObservedObject var viewModel: SensorViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {

                    // ── Barra de estado dos sensores ──
                    sensorsStrip

                    // ── Secção: Score ─────────────────
                    if let score = viewModel.lastScore {
                        let start    = score.bestTimestampMs
                        let allTicks = score.ticks
                        let refMs    = allTicks.last?.timestampMs ?? 0    // t0 = leitura mais recente (botão)
                        let durationS: Double = {
                            if let s = start, let last = allTicks.last { return Double(last.timestampMs - s) / 1000.0 }
                            return viewModel.lastPayload?.windowDurationS ?? 0
                        }()

                        LogSection(title: "SCORE", badge: "\(allTicks.count) leituras\(start == nil ? " · sem gate" : "")") {

                            // Baseline = tick de maior score (início da janela)
                            LogSubSection(title: "BASELINE (maior score)", badge: String(format: "score %.2f", score.bestScore)) {
                                DataRow(key: "best_score",        value: String(format: "%.2f", score.bestScore))
                                DataRow(key: "window_duration_s", value: String(format: "%.1f s", durationS))
                                if let g = viewModel.lastWindow?.gpsReadings.first {
                                    DataRow(key: "gps_acc (m)",     value: String(format: "%.1f", g.accuracyMeters))
                                    DataRow(key: "gps_speed (m/s)", value: String(format: "%.2f", g.speedMps))
                                    DataRow(key: "has_signal",      value: g.hasSignal ? "true" : "false")
                                }
                                if let b = viewModel.lastWindow?.pressureReadings.first {
                                    DataRow(key: "pressure (hPa)",  value: String(format: "%.2f", b.hPa))
                                }
                                if let m = viewModel.lastWindow?.magneticReadings.first {
                                    DataRow(key: "mag (µT)",        value: String(format: "%.2f", m.magnitude))
                                }
                            }

                            // Score total + Δ e pontuação por sensor, de TODAS as leituras
                            LogSubSection(title: "SCORE POR LEITURA", badge: "\(allTicks.count)") {
                                if allTicks.isEmpty {
                                    DataRow(key: "—", value: "sem leituras")
                                } else {
                                    ForEach(Array(allTicks.enumerated()).reversed(), id: \.offset) { _, tick in
                                        ScoreTickRow(tick: tick, refMs: refMs, isBest: tick.timestampMs == start)
                                    }
                                }
                            }
                        }
                    }

                    // ── Secção 1: Janela raw ──────────
                    if let window = viewModel.lastWindow {
                        LogSection(title: "RAW SENSOR WINDOW", badge: "3 sources") {
                            LogSubSection(title: "GPS", badge: "\(window.gpsReadings.count) readings") {
                                if let last = window.gpsReadings.last {
                                    DataRow(key: "latitude",         value: String(format: "%.5f", last.latitude))
                                    DataRow(key: "longitude",        value: String(format: "%.5f", last.longitude))
                                    DataRow(key: "accuracy (m)",     value: String(format: "%.1f", last.accuracyMeters))
                                    DataRow(key: "altitude (m)",     value: String(format: "%.1f", last.altitudeMeters))
                                    DataRow(key: "speed (m/s)",      value: String(format: "%.2f", last.speedMps))
                                    DataRow(key: "has signal",       value: last.hasSignal ? "true" : "false")
                                }
                            }
                            LogSubSection(title: "BAROMETER", badge: "\(window.pressureReadings.count) readings") {
                                if let last = window.pressureReadings.last {
                                    DataRow(key: "pressure (hPa)", value: String(format: "%.2f", last.hPa))
                                }
                            }
                            LogSubSection(title: "MAGNETOMETER", badge: "\(window.magneticReadings.count) readings") {
                                if let last = window.magneticReadings.last {
                                    DataRow(key: "x (µT)", value: String(format: "%.2f", last.x))
                                    DataRow(key: "y (µT)", value: String(format: "%.2f", last.y))
                                    DataRow(key: "z (µT)", value: String(format: "%.2f", last.z))
                                }
                            }
                        }
                    }

                    // ── Secção 2: Features extraídas ──
                    if let p = viewModel.lastPayload {
                        LogSection(title: "FEATURE EXTRACTOR", badge: "11 features") {

                            LogSubSection(title: "GPS", badge: "3 features") {
                                DataRow(key: "gps_accuracy_mean",  value: String(format: "%.2f m", p.gpsAccuracyMean))
                                DataRow(key: "gps_accuracy_delta", value: String(format: "%.2f m", p.gpsAccuracyDelta))
                                DataRow(key: "gps_lost_ratio",     value: String(format: "%.2f", p.gpsLostRatio))
                            }

                            LogSubSection(title: "BAROMETER", badge: "5 features") {
                                DataRow(key: "pressure_hpa",           value: String(format: "%.2f hPa", p.pressureHpa))
                                DataRow(key: "pressure_delta_hpa",     value: String(format: "%.2f hPa", p.pressureDeltaHpa))
                                DataRow(key: "pressure_variance",      value: String(format: "%.4f", p.pressureVariance))
                                DataRow(key: "altitude_change_m",      value: String(format: "%.2f m", p.altitudeChangeM))
                                DataRow(key: "city_baseline_pressure", value: String(format: "%.2f hPa", p.cityBaselinePressure))
                            }

                            LogSubSection(title: "MAGNETOMETER", badge: "3 features") {
                                DataRow(key: "magnetic_field_mean",     value: String(format: "%.2f µT", p.magneticFieldMean))
                                DataRow(key: "magnetic_field_delta",    value: String(format: "%.2f µT", p.magneticFieldDelta))
                                DataRow(key: "magnetic_field_variance", value: String(format: "%.4f", p.magneticFieldVariance))
                            }
                        }

                        // ── Secção 3: Payload enviado ─
                        LogSection(title: "PAYLOAD SENT", badge: p.windowStartAt) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("POST http://\(baseHost)/predict")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .padding(.bottom, 4)

                                JsonBlock(pairs: [
                                    ("latitude",               String(format: "%.5f", p.latitude)),
                                    ("longitude",              String(format: "%.5f", p.longitude)),
                                    ("gps_accuracy_mean",      String(format: "%.2f", p.gpsAccuracyMean)),
                                    ("gps_accuracy_delta",     String(format: "%.2f", p.gpsAccuracyDelta)),
                                    ("gps_lost_ratio",         String(format: "%.2f", p.gpsLostRatio)),
                                    ("pressure_hpa",           String(format: "%.2f", p.pressureHpa)),
                                    ("pressure_delta_hpa",     String(format: "%.2f", p.pressureDeltaHpa)),
                                    ("pressure_variance",      String(format: "%.4f", p.pressureVariance)),
                                    ("altitude_change_m",      String(format: "%.2f", p.altitudeChangeM)),
                                    ("city_baseline_pressure", String(format: "%.2f", p.cityBaselinePressure)),
                                    ("magnetic_field_mean",    String(format: "%.2f", p.magneticFieldMean)),
                                    ("magnetic_field_delta",   String(format: "%.2f", p.magneticFieldDelta)),
                                    ("magnetic_field_variance",String(format: "%.4f", p.magneticFieldVariance)),
                                    ("window_start_at",        "\"\(p.windowStartAt)\""),
                                    ("window_end_at",          "\"\(p.windowEndAt)\""),
                                    ("window_duration_s",      String(format: "%.1f", p.windowDurationS)),
                                ])
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }

                    // ── Secção 4: Resposta do modelo ──
                    if case .success(let classification, let confidence) = viewModel.uploadResult {
                        LogSection(title: "MODEL RESPONSE", badge: "200 OK") {
                            VStack(alignment: .leading, spacing: 6) {
                                DataRow(key: "classification",      value: classification, highlight: true)
                                DataRow(key: "non_street_confidence", value: String(format: "%.2f", confidence))

                                // Barra de confiança
                                HStack(spacing: 8) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.1)).frame(height: 4)
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(confidence > 0.5 ? Color.orange : Color.vvGreen)
                                                .frame(width: geo.size.width * confidence, height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                    Text(String(format: "%.0f%%", confidence * 100))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.gray)
                                        .frame(width: 30, alignment: .trailing)
                                }
                                .padding(.top, 4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }

                    // Mensagem quando ainda não há dados
                    if viewModel.lastPayload == nil {
                        VStack(spacing: 8) {
                            Text("Sem dados ainda")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.gray)
                            Text("Volta à tela principal e carrega em ANALISAR AMBIENTE")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(white: 0.35))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .navigationTitle("SENSOR LOGS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .onAppear  { viewModel.startLiveUpdates() }
        .onDisappear { viewModel.stopLiveUpdates() }
    }

    // ── Strip de sensores activos (atualiza a 1 Hz via liveWindow) ──
    private var sensorsStrip: some View {
        let w       = viewModel.liveWindow
        let lastGps = w.gpsReadings.last
        let lastBar = w.pressureReadings.last
        let lastMag = w.magneticReadings.last

        return VStack(alignment: .leading, spacing: 8) {
            Text("SENSORES ACTIVOS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.27))
                .kerning(1.5)

            HStack(alignment: .top, spacing: 6) {

                // GPS
                RawSensorChip(name: "GPS", active: lastGps?.hasSignal == true) {
                    if let g = lastGps {
                        RawRow(key: "lat", value: String(format: "%.5f", g.latitude))
                        RawRow(key: "lon", value: String(format: "%.5f", g.longitude))
                        RawRow(key: "acc", value: String(format: "%.1fm", g.accuracyMeters))
                        RawRow(key: "alt", value: String(format: "%.1fm", g.altitudeMeters))
                        RawRow(key: "spd", value: String(format: "%.2fm/s", g.speedMps))
                        RawRow(key: "sig", value: g.hasSignal ? "true" : "false")
                    } else {
                        RawRow(key: "—", value: "")
                    }
                }

                // Barometer
                RawSensorChip(name: "BAROMETER", active: lastBar != nil) {
                    if let b = lastBar {
                        RawRow(key: "hPa", value: String(format: "%.2f", b.hPa))
                    } else {
                        RawRow(key: "—", value: "")
                    }
                }

                // Magnetometer
                RawSensorChip(name: "MAGNETOMETER", active: lastMag != nil) {
                    if let m = lastMag {
                        RawRow(key: "x", value: String(format: "%.2fµT", m.x))
                        RawRow(key: "y", value: String(format: "%.2fµT", m.y))
                        RawRow(key: "z", value: String(format: "%.2fµT", m.z))
                    } else {
                        RawRow(key: "—", value: "")
                    }
                }

                // IMU — desativado
                RawSensorChip(name: "IMU", active: false) {
                    RawRow(key: "N/A", value: "")
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.05))
        .overlay(Divider().background(Color(white: 0.1)), alignment: .bottom)
    }

    // Extrai o host do baseURL para mostrar no PAYLOAD SENT
    private var baseHost: String {
        let url = "100.103.161.134:8000"
        return url
    }
}

// ── LogSection ────────────────────────────────────────
// Secção colapsável de nível superior (verde)
struct LogSection<Content: View>: View {
    let title: String
    let badge: String
    @State private var collapsed = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Cabeçalho
            Button(action: { withAnimation { collapsed.toggle() } }) {
                HStack(spacing: 8) {
                    Text(collapsed ? "▶" : "▼")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.vvGreen)
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.vvGreen)
                        .kerning(2)
                    Spacer()
                    Text(badge)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(white: 0.27))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(white: 0.04))
            }

            Divider().background(Color(white: 0.07))

            if !collapsed {
                content()
            }
        }
        .overlay(Divider().background(Color(white: 0.07)), alignment: .bottom)
    }
}

// ── LogSubSection ─────────────────────────────────────
// Sub-secção colapsável (cinzento)
struct LogSubSection<Content: View>: View {
    let title: String
    let badge: String
    @State private var collapsed = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation { collapsed.toggle() } }) {
                HStack(spacing: 6) {
                    Text(collapsed ? "▶" : "▼")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(white: 0.27))
                        .frame(width: 8)
                    Text(title)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                        .kerning(1.5)
                    Spacer()
                    Text(badge)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Color(white: 0.2))
                }
                .padding(.leading, 24)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
                .background(Color(white: 0.02))
            }

            if !collapsed {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .padding(.leading, 28)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
            }
        }
        .overlay(Divider().background(Color(white: 0.07)), alignment: .bottom)
    }
}

// ── ScoreTickRow ──────────────────────────────────────
// Uma leitura: tempo, score total (raw + ema) e, por sensor, Δ bruto + pontuação.
struct ScoreTickRow: View {
    let tick: ScoredTick
    let refMs: Int64
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(String(format: "t-%.0fs", Double(refMs - tick.timestampMs) / 1000.0))
                    .foregroundColor(isBest ? .vvGreen : Color(white: 0.6))
                if isBest {
                    Text("◄ baseline").foregroundColor(.vvGreen)
                } else if !tick.gated {
                    Text("gate off").foregroundColor(.orange)
                }
                Spacer()
                Text(String(format: "raw %.2f · ema %.2f", tick.rawScore, tick.score))
                    .foregroundColor(isBest ? .vvGreen : Color(white: 0.88))
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))

            sensorLine("acc", tick.dAcc,   "m",   tick.sAcc)
            sensorLine("spd", tick.dSpeed, "m/s", tick.sSpeed)
            sensorLine("mag", tick.dMag,   "µT",  tick.sMag)
            sensorLine("prs", tick.dPress, "hPa", tick.sPress)
        }
        .padding(.vertical, 4)
        .overlay(Divider().background(Color(white: 0.08)), alignment: .bottom)
    }

    // Uma linha de sensor: nome · Δ bruto · pontuação (contributo)
    private func sensorLine(_ name: String, _ delta: Double, _ unit: String, _ scoreVal: Double) -> some View {
        HStack(spacing: 0) {
            Text(name)
                .foregroundColor(Color(white: 0.35))
                .frame(width: 30, alignment: .leading)
            Text(String(format: "Δ%.2f %@", delta, unit))
                .foregroundColor(Color(white: 0.6))
                .frame(width: 96, alignment: .leading)
            Spacer()
            Text(String(format: "%.2f", scoreVal))
                .foregroundColor(scoreVal > 0 ? Color(white: 0.85) : Color(white: 0.3))
        }
        .font(.system(size: 9, design: .monospaced))
    }
}

// ── DataRow ───────────────────────────────────────────
struct DataRow: View {
    let key: String
    let value: String
    var highlight: Bool = false

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(highlight ? .vvGreen : Color(white: 0.88))
        }
        .padding(.vertical, 2)
    }
}

// ── JsonBlock ─────────────────────────────────────────
struct JsonBlock: View {
    let pairs: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("{")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.53))

            ForEach(Array(pairs.enumerated()), id: \.offset) { idx, pair in
                HStack(spacing: 0) {
                    Text("  \"\(pair.0)\"")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0.49, green: 0.78, blue: 0.89))
                    Text(": ")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.53))
                    Text("\(pair.1)\(idx < pairs.count - 1 ? "," : "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.88))
                }
            }

            Text("}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.53))
        }
        .padding(10)
        .background(Color(white: 0.04))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.1), lineWidth: 1))
    }
}

// ── RawSensorChip ─────────────────────────────────────
// Chip vertical com nome do sensor e todos os valores brutos
struct RawSensorChip<Content: View>: View {
    let name: String
    let active: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(active ? Color.vvGreen : Color.red)
                    .frame(width: 5, height: 5)
                Text(name)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.53))
            }
            content()
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(active ? Color(red: 0.1, green: 0.16, blue: 0.1) : Color(red: 0.16, green: 0.1, blue: 0.1), lineWidth: 1)
        )
    }
}

// ── RawRow ────────────────────────────────────────────
// Linha chave/valor dentro do RawSensorChip
struct RawRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 2) {
            Text("\(key):")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Color(white: 0.35))
            Text(value)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Color(white: 0.7))
        }
    }
}
