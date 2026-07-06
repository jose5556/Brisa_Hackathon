import Foundation

// ── SensorPayload ─────────────────────────────────────
struct SensorPayload: Codable {

    // Coordenadas do estacionamento
    let latitude: Double           // latitude onde o veículo parou
    let longitude: Double          // longitude onde o veículo parou
    var city: String?              // nome da cidade (reverse geocoding da última leitura GPS)

    // GPS / GNSS
    let gpsAccuracyMean: Double    // precisão média do GPS durante a janela (metros — menor = melhor)
    let gpsAccuracyDelta: Double   // variação entre melhor e pior precisão (instabilidade do sinal)
    let gpsLostRatio: Double       // % de leituras sem sinal GPS (0.0 = sempre com sinal, 1.0 = sem sinal)

    // Barómetro
    let pressureHpa: Double            // pressão atmosférica final onde o veiculo parou (hPa)
    let pressureDeltaHpa: Double       // diferença entre a pressão inicial - final
    let pressureVariance: Double       // variância da pressão durante a janela
    let altitudeChangeM: Double        // variação de altitude estimada pela fórmula barométrica (metros — negativo = desceu)

    // Magnetómetro
    let magneticFieldMean: Double      // intensidade média do campo magnético (µT — baixa dentro de betão/metal)
    let magneticFieldDelta: Double     // variação entre primeira e última leitura
    let magneticFieldVariance: Double  // variância do campo magnético (alta = ambiente com interferências, ex: garagem)

    // Janela de recolha
    let windowStartAt: String      // timestamp do início da janela de recolha
    let windowEndAt: String        // timestamp do fim da janela de recolha
    let windowDurationS: Double    // duração total da janela em segundo

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case city

        case gpsAccuracyMean            = "gnss_accuracy_mean"
        case gpsAccuracyDelta           = "gnss_accuracy_delta"
        case gpsLostRatio               = "gnss_lost_ratio"

        case pressureHpa                = "pressure_hpa"
        case pressureDeltaHpa           = "pressure_delta"
        case pressureVariance           = "pressure_variance"
        case altitudeChangeM            = "altitude_delta"

        case magneticFieldMean          = "magnetic_field_mean"
        case magneticFieldDelta         = "magnetic_field_delta"
        case magneticFieldVariance      = "magnetic_variance_total"

        case windowStartAt              = "window_start_at"
        case windowEndAt                = "window_end_at"
        case windowDurationS            = "window_duration_s"
    }
}

// ── SensorWindow ──────────────────────────────────────
struct SensorWindow {
    var gpsReadings:      [GpsReading]      = []
    var pressureReadings: [PressureReading] = []
    var magneticReadings: [MagneticReading] = []
}

// ── SensorDeltas ──────────────────────────────────────
// Variação crua de cada sensor entre a leitura mais recente e a leitura
// de há `overMs` atrás. Sem normalização nem pesos — só observação para
// depois calibrar ranges/pesos com dados reais.
// Cada campo é nil quando não há leituras suficientes para o cálculo.
struct SensorDeltas {
    let pressureHpa:  Double?   // Δ pressão (hPa)
    let gpsAccuracyM: Double?   // Δ precisão GPS (m)
    let gpsSpeedMps:  Double?   // Δ velocidade GPS (m/s)
    let magneticUt:   Double?   // Δ magnitude do campo magnético (µT)
}

// ── GpsReading ────────────────────────────────────────
struct GpsReading {
    let latitude:       Double
    let longitude:      Double
    let accuracyMeters: Float
    let altitudeMeters: Double
    let speedMps:       Double
    let hasSignal:      Bool
    let timestampMs:    Int64

    init(
        latitude:       Double,
        longitude:      Double,
        accuracyMeters: Float,
        altitudeMeters: Double,
        speedMps:       Double,
        hasSignal:      Bool,
        timestampMs:    Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.latitude       = latitude
        self.longitude      = longitude
        self.accuracyMeters = accuracyMeters
        self.altitudeMeters = altitudeMeters
        self.speedMps       = speedMps
        self.hasSignal      = hasSignal
        self.timestampMs    = timestampMs
    }
}

// ── PressureReading ───────────────────────────────────
struct PressureReading {
    let hPa:         Float
    let timestampMs: Int64

    init(
        hPa:         Float,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.hPa         = hPa
        self.timestampMs = timestampMs
    }
}

// ── MagneticReading ───────────────────────────────────
struct MagneticReading {
    let x:           Double
    let y:           Double
    let z:           Double
    let magnitude:   Double
    let timestampMs: Int64

    init(
        x:           Double,
        y:           Double,
        z:           Double,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.x         = x
        self.y         = y
        self.z         = z
        self.magnitude = sqrt(x * x + y * y + z * z)
        self.timestampMs = timestampMs
    }
}

// ── Helpers: time_of_day + ISO 8601 ──────────────────
extension Date {

    /// "morning" | "afternoon" | "evening" | "night"
    var timeOfDay: String {
        let hour = Calendar.current.component(.hour, from: self)
        switch hour {
        case 6..<12:  return "morning"
        case 12..<18: return "afternoon"
        case 18..<22: return "evening"
        default:      return "night"
        }
    }

    /// Formata para ISO 8601 com timezone (TIMESTAMPTZ)
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}

// ── SensorWindow → SensorPayload ──────────────────────
extension SensorWindow {

    /// Constrói o payload a partir das amostras brutas da janela.

    func toPayload() -> SensorPayload? {

        guard !gpsReadings.isEmpty else { return nil }

        let windowStart = Date(timeIntervalSince1970: Double(gpsReadings.first!.timestampMs) / 1000)
        let windowEnd   = Date(timeIntervalSince1970: Double(gpsReadings.last!.timestampMs)  / 1000)
        let windowDurationS = windowEnd.timeIntervalSince(windowStart)

        // ── GPS ───────────────────────────────────────
        let lastGps    = gpsReadings.last!
        let accuracies = gpsReadings.map { Double($0.accuracyMeters) }
        let signalLost = gpsReadings.filter { !$0.hasSignal }.count

        let gpsAccuracyMean  = accuracies.mean
        let gpsAccuracyDelta = (accuracies.max() ?? 0) - (accuracies.min() ?? 0)
        let gpsLostRatio     = Double(signalLost) / Double(gpsReadings.count)

        // ── Barómetro ─────────────────────────────────
        // pressureHpa          → última leitura (onde o veículo parou)
        // pressureDeltaHpa     → inicial - final
        let pressureHpa:           Double
        let pressureDeltaHpa:      Double
        let pressureVariance:      Double
        let altitudeChangeM:       Double

        if let first = pressureReadings.first, let last = pressureReadings.last {
            let hPaValues   = pressureReadings.map { Double($0.hPa) }
            let firstPressure = Double(first.hPa)
            let lastPressure  = Double(last.hPa)

            pressureHpa          = lastPressure
            pressureDeltaHpa     = firstPressure - lastPressure
            pressureVariance     = hPaValues.variance
            // Aproximação barométrica: ~8.5m por hPa ao nível do mar.
            // Pressão sobe (desceu) → altitudeChangeM negativo.
            altitudeChangeM      = (firstPressure - lastPressure) * 8.5
        } else {
            pressureHpa          = 0
            pressureDeltaHpa     = 0
            pressureVariance     = 0
            altitudeChangeM      = 0
        }

        // ── Magnetómetro ──────────────────────────────
        let magneticFieldMean:     Double
        let magneticFieldDelta:    Double
        let magneticFieldVariance: Double

        if !magneticReadings.isEmpty {
            let mags = magneticReadings.map { $0.magnitude }
            magneticFieldMean     = mags.mean
            magneticFieldDelta    = (mags.last ?? 0) - (mags.first ?? 0)
            magneticFieldVariance = mags.variance
        } else {
            magneticFieldMean     = 0
            magneticFieldDelta    = 0
            magneticFieldVariance = 0
        }

        return SensorPayload(
            latitude:              lastGps.latitude,
            longitude:             lastGps.longitude,
            city:                  nil,   // preenchido depois via reverse geocoding em buildPayload
            gpsAccuracyMean:       gpsAccuracyMean,
            gpsAccuracyDelta:      gpsAccuracyDelta,
            gpsLostRatio:          gpsLostRatio,
            pressureHpa:           pressureHpa,
            pressureDeltaHpa:      pressureDeltaHpa,
            pressureVariance:      pressureVariance,
            altitudeChangeM:       altitudeChangeM,
            magneticFieldMean:     magneticFieldMean,
            magneticFieldDelta:    magneticFieldDelta,
            magneticFieldVariance: magneticFieldVariance,
            windowStartAt:         windowStart.iso8601,
            windowEndAt:           windowEnd.iso8601,
            windowDurationS:       windowDurationS
        )
    }
}

// ── SensorWindow → SensorDeltas ───────────────────────
extension SensorWindow {

    /// Δ de cada sensor: leitura mais recente menos a leitura de há `overMs` atrás.
    /// A "leitura de há `overMs` atrás" é a amostra cujo timestamp está mais
    /// próximo de (timestamp_mais_recente − overMs).
    func deltas(overMs: Int64 = 10_000) -> SensorDeltas {
        SensorDeltas(
            pressureHpa:  Self.delta(pressureReadings, overMs: overMs,
                                     time: { $0.timestampMs }, value: { Double($0.hPa) }),
            gpsAccuracyM: Self.delta(gpsReadings, overMs: overMs,
                                     time: { $0.timestampMs }, value: { Double($0.accuracyMeters) }),
            gpsSpeedMps:  Self.delta(gpsReadings, overMs: overMs,
                                     time: { $0.timestampMs }, value: { $0.speedMps }),
            magneticUt:   Self.delta(magneticReadings, overMs: overMs,
                                     time: { $0.timestampMs }, value: { $0.magnitude })
        )
    }

    /// Δ genérico: valor da última amostra menos o da amostra-âncora (~overMs antes).
    /// Retorna nil se o buffer estiver vazio ou se âncora e última coincidirem.
    private static func delta<T>(
        _ readings: [T],
        overMs: Int64,
        time:  (T) -> Int64,
        value: (T) -> Double
    ) -> Double? {
        guard let last = readings.last else { return nil }
        let targetMs = time(last) - overMs
        guard let past = readings.min(by: {
            abs(time($0) - targetMs) < abs(time($1) - targetMs)
        }) else { return nil }
        guard time(last) != time(past) else { return nil }
        return value(last) - value(past)
    }
}

// ── Helpers aritméticos ───────────────────────────────
private extension Array where Element == Double {
    var mean: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
    var variance: Double {
        guard count > 1 else { return 0 }
        let m = mean
        return map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count - 1)
    }
}