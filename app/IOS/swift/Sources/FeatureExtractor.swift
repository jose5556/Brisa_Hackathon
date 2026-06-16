import Foundation

/// Transforma uma SensorWindow (amostras brutas) num SensorPayload pronto a enviar.
/// Toda a logica de calculo de features esta isolada aqui — facil de testar unitariamente.
enum FeatureExtractor {

    /// Retorna nil se nao houver nenhuma leitura GPS (minimo necessario para o modelo).
    static func extract(window: SensorWindow) -> SensorPayload? {

        // ── GPS ───────────────────────────────────────────────────────────────
        guard !window.gpsReadings.isEmpty else { return nil }

        let lastGps = window.gpsReadings.last!

        // Exclui leituras com accuracy fora de 0-100m (GPS perdido ou muito ruidoso)
        let validGps = window.gpsReadings.filter {
            $0.accuracyMeters >= 0 && $0.accuracyMeters <= 100
        }

        let accuracies = validGps.map { Double($0.accuracyMeters) }

        let gpsAccuracyMean  = accuracies.mean
        let gpsAccuracyMax   = accuracies.max() ?? 0
        let gpsAccuracyDelta = (accuracies.max() ?? 0) - (accuracies.min() ?? 0)

        // Inclui leituras sem sinal no ratio — conta tudo que nao e valido
        let gpsLostRatio: Double = {
            let lost = window.gpsReadings.filter {
                !$0.hasSignal || $0.accuracyMeters < 0 || $0.accuracyMeters > 100
            }.count
            return Double(lost) / Double(window.gpsReadings.count)
        }()

        let speeds = window.gpsReadings.map { $0.speedMps }
        let gpsSpeedMean = speeds.mean
        let gpsSpeedMax  = speeds.max() ?? 0

        // ── Altitude ──────────────────────────────────────────────────────────
        // Filtro mais restritivo para altitude: accuracy < 75m e sinal presente
        // Altitude GPS e mais ruidosa que posicao horizontal, por isso o corte e mais agressivo
        let validAlt  = validGps.filter { $0.hasSignal && $0.accuracyMeters < 75 }
        let altitudes = validAlt.map { $0.altitudeMeters }

        let altitudeDelta: Double = {
            guard altitudes.count >= 2 else { return 0 }
            return (altitudes.last ?? 0) - (altitudes.first ?? 0)
        }()

        // Usa max-min em vez de somar saltos consecutivos — mais robusto ao ruido GPS
        let verticalChangeAbs: Double = {
            guard altitudes.count >= 2 else { return 0 }
            return (altitudes.max() ?? 0) - (altitudes.min() ?? 0)
        }()

        // ── Barometro ─────────────────────────────────────────────────────────
        let pressureDelta: Double
        let pressureSlope: Double

        if window.pressureReadings.count >= 2 {
            let readings = window.pressureReadings
            let t0 = readings.first!.timestampMs

            // Converte timestamps para segundos relativos ao inicio da janela
            let xs = readings.map { Double($0.timestampMs - t0) / 1000.0 }
            let ys = readings.map { Double($0.hPa) }

            // Regressao linear simples (minimos quadrados) — da hPa/s real
            // Mais correto que delta/count porque as leituras podem nao ser uniformes no tempo
            let n     = Double(readings.count)
            let sumX  = xs.reduce(0, +)
            let sumY  = ys.reduce(0, +)
            let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
            let sumX2 = xs.reduce(0) { $0 + $1 * $1 }
            let denom = n * sumX2 - sumX * sumX

            pressureDelta = (ys.last ?? 0) - (ys.first ?? 0)
            pressureSlope = abs(denom) < 1e-9 ? 0 : (n * sumXY - sumX * sumY) / denom
        } else {
            pressureDelta = 0
            pressureSlope = 0
        }

        // ── Movimento (acelerometro) ──────────────────────────────────────────
        let stationaryRatio: Double = {
            guard !window.motionSamples.isEmpty else { return 1.0 }

            // Threshold de 1.5 m/s² tolera o ruido natural do acelerometro em repouso
            // Valores abaixo de ~0.3 sao demasiado restritivos e classificam tudo como movimento
            let threshold: Float = 1.5
            let stationary = window.motionSamples.filter { s in
                let mag = sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az)
                return abs(mag - 9.81) < threshold  // subtrai gravidade
            }.count
            return Double(stationary) / Double(window.motionSamples.count)
        }()

        // ── Magnetometro ──────────────────────────────────────────────────────
        // Util para detetar estruturas metalicas (parques subterraneos, garagens elevadas)
        // que distorcem o campo magnetico local
        let magneticFieldMean: Double
        let magneticFieldMax: Double
        let magneticFieldDelta: Double
        let magneticFieldVariance: Double

        if !window.magneticReadings.isEmpty {
            let magnitudes = window.magneticReadings.map { $0.magnitude }
            magneticFieldMean     = magnitudes.mean
            magneticFieldMax      = magnitudes.max() ?? 0
            magneticFieldDelta    = (magnitudes.last ?? 0) - (magnitudes.first ?? 0)
            magneticFieldVariance = magnitudes.variance
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
            pressureDelta:         pressureDelta,
            pressureSlope:         pressureSlope,
            stationaryRatio:       stationaryRatio,
            altitudeDelta:         altitudeDelta,
            verticalChangeAbs:     verticalChangeAbs,
            magneticFieldMean:     magneticFieldMean,
            magneticFieldMax:      magneticFieldMax,
            magneticFieldDelta:    magneticFieldDelta,
            magneticFieldVariance: magneticFieldVariance
        )
    }
}

// ── Helpers aritmeticos ───────────────────────────────────────────────────────
private extension Array where Element == Double {
    var mean: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
    // Variancia amostral (n-1) para o magnetometro
    var variance: Double {
        guard count > 1 else { return 0 }
        let m = mean
        return map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count - 1)
    }
}
