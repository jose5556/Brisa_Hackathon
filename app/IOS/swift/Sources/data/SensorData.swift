import Foundation

// ── SensorPayload ─────────────────────────────────────
struct SensorPayload: Codable {

    // Coordenadas do estacionamento
    let latitude: Double           // latitude onde o veículo parou
    let longitude: Double          // longitude onde o veículo parou

    // GPS / GNSS
    let gpsAccuracyMean: Double    // precisão média do GPS durante a janela (metros — menor = melhor)
    let gpsAccuracyMax: Double     // pior precisão registada (metros — valor alto indica sinal fraco)
    let gpsAccuracyDelta: Double   // variação entre melhor e pior precisão (instabilidade do sinal)
    let gpsLostRatio: Double       // % de leituras sem sinal GPS (0.0 = sempre com sinal, 1.0 = sem sinal)

    // Velocidade
    let gpsSpeedMean: Double       // velocidade média durante a janela (m/s)
    let gpsSpeedMax: Double        // velocidade máxima registada (m/s — alta indica que ainda estava em movimento)

    // Barómetro
    let pressureHpa: Double            // pressão atmosférica absoluta média da janela (hPa)
    let pressureDeltaHpa: Double       // diferença entre a pressão medida e o baseline da cidade (detecta mudança de piso)
    let pressureVariance: Double       // variância da pressão durante a janela (alta = descida/subida de rampa)
    let altitudeChangeM: Double        // variação de altitude estimada pela fórmula barométrica (metros — negativo = desceu)
    let cityBaselinePressure: Double   // pressão de referência da cidade naquele momento (via API meteorológica)

    // Altitude
    let altitudeDelta: Double          // diferença de altitude GPS entre início e fim da janela (metros)
    let verticalChangeAbs: Double      // soma de todas as variações verticais absolutas (detecta rampas e pisos)

    // Magnetómetro
    let magneticFieldMean: Double      // intensidade média do campo magnético (µT — baixa dentro de betão/metal)
    let magneticFieldMax: Double       // intensidade máxima registada (µT)
    let magneticFieldDelta: Double     // variação entre primeira e última leitura (detecta entrada em estrutura metálica)
    let magneticFieldVariance: Double  // variância do campo magnético (alta = ambiente com interferências, ex: garagem)

    // Condição do tempo
    let weatherCondition: String   // estado do tempo: "clear" | "rain" | "overcast" (via API meteorológica)
    let timeOfDay: String          // período do dia: "morning" | "afternoon" | "evening" | "night"

    // Janela de recolha
    let windowStartAt: String      // timestamp do início da janela de recolha
    let windowEndAt: String        // timestamp do fim da janela de recolha
    let windowDurationS: Double    // duração total da janela em segundo

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude

        case gpsAccuracyMean            = "gps_accuracy_mean"
        case gpsAccuracyMax             = "gps_accuracy_max"
        case gpsAccuracyDelta           = "gps_accuracy_delta"
        case gpsLostRatio               = "gps_lost_ratio"

        case gpsSpeedMean               = "gps_speed_mean"
        case gpsSpeedMax                = "gps_speed_max"

        case pressureHpa                = "pressure_hpa"
        case pressureDeltaHpa           = "pressure_delta_hpa"
        case pressureVariance           = "pressure_variance"
        case altitudeChangeM            = "altitude_change_m"
        case cityBaselinePressure       = "city_baseline_pressure"

        case altitudeDelta              = "altitude_delta"
        case verticalChangeAbs          = "vertical_change_abs"

        case magneticFieldMean          = "magnetic_field_mean"
        case magneticFieldMax           = "magnetic_field_max"
        case magneticFieldDelta         = "magnetic_field_delta"
        case magneticFieldVariance      = "magnetic_field_variance"

        case weatherCondition           = "weather_condition"
        case timeOfDay                  = "time_of_day"

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

    /// cityBaselinePressure: passa o valor obtido da API meteorológica (ex: Open-Meteo).
    /// weatherCondition: passa o valor obtido da API meteorológica.
    /// Se não tiveres ainda a integração meteorológica, passa 0 e "clear" como placeholder.
    func toPayload(
        cityBaselinePressure: Double = 0,
        weatherCondition: String = "clear"
    ) -> SensorPayload? {

        guard !gpsReadings.isEmpty else { return nil }

        let windowStart = Date(timeIntervalSince1970: Double(gpsReadings.first!.timestampMs) / 1000)
        let windowEnd   = Date(timeIntervalSince1970: Double(gpsReadings.last!.timestampMs)  / 1000)
        let windowDurationS = windowEnd.timeIntervalSince(windowStart)

        // ── GPS ───────────────────────────────────────
        let lastGps    = gpsReadings.last!
        let accuracies = gpsReadings.map { Double($0.accuracyMeters) }
        let speeds     = gpsReadings.map { $0.speedMps }
        let altitudes  = gpsReadings.map { $0.altitudeMeters }
        let signalLost = gpsReadings.filter { !$0.hasSignal }.count

        let gpsAccuracyMean  = accuracies.mean
        let gpsAccuracyMax   = accuracies.max() ?? 0
        let gpsAccuracyDelta = (accuracies.max() ?? 0) - (accuracies.min() ?? 0)
        let gpsLostRatio     = Double(signalLost) / Double(gpsReadings.count)
        let gpsSpeedMean     = speeds.mean
        let gpsSpeedMax      = speeds.max() ?? 0

        // ── Altitude ──────────────────────────────────
        let altitudeDelta     = (altitudes.last ?? 0) - (altitudes.first ?? 0)
        let verticalChangeAbs = zip(altitudes, altitudes.dropFirst())
            .map { abs($1 - $0) }.reduce(0, +)

        // ── Barómetro ─────────────────────────────────
        let pressureHpa:      Double
        let pressureDeltaHpa: Double
        let pressureVariance: Double
        let altitudeChangeM:  Double

        if pressureReadings.count >= 2 {
            let hPaValues = pressureReadings.map { Double($0.hPa) }
            let pressureDelta = (hPaValues.last ?? 0) - (hPaValues.first ?? 0)
            pressureHpa      = hPaValues.mean
            // Diferença entre a pressão medida e o baseline da cidade (detecta mudança de piso)
            pressureDeltaHpa = pressureHpa - cityBaselinePressure
            pressureVariance = hPaValues.variance
            // Aproximação barométrica: ~8.5m por hPa ao nível do mar
            altitudeChangeM  = -pressureDelta * 8.5
        } else {
            pressureHpa      = pressureReadings.first.map { Double($0.hPa) } ?? 0
            pressureDeltaHpa = 0
            pressureVariance = 0
            altitudeChangeM  = 0
        }

        // ── Magnetómetro ──────────────────────────────
        let magneticFieldMean:     Double
        let magneticFieldMax:      Double
        let magneticFieldDelta:    Double
        let magneticFieldVariance: Double

        if !magneticReadings.isEmpty {
            let mags = magneticReadings.map { $0.magnitude }
            magneticFieldMean     = mags.mean
            magneticFieldMax      = mags.max() ?? 0
            magneticFieldDelta    = (mags.last ?? 0) - (mags.first ?? 0)
            magneticFieldVariance = mags.variance
        } else {
            magneticFieldMean     = 0
            magneticFieldMax      = 0
            magneticFieldDelta    = 0
            magneticFieldVariance = 0
        }

        return SensorPayload(
            latitude:              lastGps.latitude,
            longitude:             lastGps.longitude,
            gpsAccuracyMean:       gpsAccuracyMean,
            gpsAccuracyMax:        gpsAccuracyMax,
            gpsAccuracyDelta:      gpsAccuracyDelta,
            gpsLostRatio:          gpsLostRatio,
            gpsSpeedMean:          gpsSpeedMean,
            gpsSpeedMax:           gpsSpeedMax,
            pressureHpa:           pressureHpa,
            pressureDeltaHpa:      pressureDeltaHpa,
            pressureVariance:      pressureVariance,
            altitudeChangeM:       altitudeChangeM,
            cityBaselinePressure:  cityBaselinePressure,
            altitudeDelta:         altitudeDelta,
            verticalChangeAbs:     verticalChangeAbs,
            magneticFieldMean:     magneticFieldMean,
            magneticFieldMax:      magneticFieldMax,
            magneticFieldDelta:    magneticFieldDelta,
            magneticFieldVariance: magneticFieldVariance,
            weatherCondition:      weatherCondition,
            timeOfDay:             windowEnd.timeOfDay,
            windowStartAt:         windowStart.iso8601,
            windowEndAt:           windowEnd.iso8601,
            windowDurationS:       windowDurationS
        )
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