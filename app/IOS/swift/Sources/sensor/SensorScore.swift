import Foundation

// ── Scoring por tick ──────────────────────────────────
// Calcula, sobre um buffer de amostras, um "score de transição" por tick (~1 Hz)
// usando a fusão de 3 sinais: GPS accuracy, GPS speed e magnetómetro.
// O barómetro NÃO entra no score — fica reservado para a feature de piso.
//
// O tick de score mais alto marca o INÍCIO da janela de captura: é o momento,
// ainda em rua válida, em que os sensores mais variaram. A janela vai daí até
// ao instante do "Analisar" (última leitura do buffer).
//
// Passos (alinhados com a especificação):
//   1. Δ de cada sensor vs leitura de ~5 s atrás (rateMs).
//   2. Gate: velocidade > minSpeedMps E GPS com sinal — senão score = 0.
//   3. Normalizar cada Δ pela sua variação típica (σ no próprio buffer).
//   4. Deadband (variações ínfimas → 0) e tecto (variações enormes → cap).
//   5. Peso de cada sensor (1× para já).
//   6. Somar as 3 contribuições → score bruto do tick.
//   7. EMA: suaviza com o tick anterior (α = 0.5 → (raw + anterior) / 2).
//   8. (no ViewModel) o tick de maior score vira o início da janela.

struct ScoredTick {
    let timestampMs: Int64
    let score: Double      // score suavizado (EMA) deste tick
    let gated: Bool        // passou o gate de rua (GPS + velocidade)?
}

struct WindowScore {
    let bestTimestampMs: Int64?    // início da janela (tick de maior score), nil se nenhum válido
    let bestScore: Double
    let ticks: [ScoredTick]        // série completa, para logging/calibração
}

extension SensorWindow {

    /// Parâmetros de calibração do score. Valores iniciais — a rever com dados de campo.
    struct ScoreParams {
        var rateMs:      Int64  = 5_000   // janela de variação (Passo 1)
        var minSpeedMps: Double = 2.5     // gate de rua (Passo 2)
        var deadband:    Double = 0.5     // em σ: abaixo disto → 0 (Passo 4)
        var cap:         Double = 3.0     // em σ: tecto por sensor (Passo 4)
        var weightAcc:   Double = 1.0     // pesos (Passo 5)
        var weightSpeed: Double = 1.0
        var weightMag:   Double = 1.0
        var emaAlpha:    Double = 0.5     // suavização (Passo 7)
    }

    /// Percorre o buffer e devolve o score por tick + o tick de maior score.
    /// A grelha de ticks são as leituras GPS (~1 Hz), que já trazem velocidade e sinal.
    func computeScore(params: ScoreParams = .init()) -> WindowScore {
        guard !gpsReadings.isEmpty else {
            return WindowScore(bestTimestampMs: nil, bestScore: 0, ticks: [])
        }

        // ── Passo 1+2: Δ bruto por tick gated ────────────────
        // Para cada leitura GPS válida (gate + 5 s de história), guarda |Δ| de cada sensor.
        struct RawTick { let t: Int64; let dAcc: Double; let dSpeed: Double; let dMag: Double }
        var raws: [Int64: RawTick] = [:]   // só ticks gated+calculáveis

        for g in gpsReadings {
            let t = g.timestampMs
            let target = t - params.rateMs

            // Gate (Passo 2): velocidade mínima + sinal GPS.
            guard g.hasSignal, g.speedMps > params.minSpeedMps else { continue }

            // Âncoras a ~5 s atrás. Se a âncora coincidir com agora, não há história suficiente.
            guard let accPast   = Self.valueAt(gpsReadings, target, { $0.timestampMs }, { Double($0.accuracyMeters) }),
                  let speedPast = Self.valueAt(gpsReadings, target, { $0.timestampMs }, { $0.speedMps }),
                  let magNow    = Self.valueAt(magneticReadings, t,      { $0.timestampMs }, { $0.magnitude }),
                  let magPast   = Self.valueAt(magneticReadings, target, { $0.timestampMs }, { $0.magnitude })
            else { continue }

            // Variações brutas, sempre positivas (Passo 1).
            raws[t] = RawTick(
                t:      t,
                dAcc:   abs(Double(g.accuracyMeters) - accPast),
                dSpeed: abs(g.speedMps - speedPast),
                dMag:   abs(magNow - magPast)
            )
        }

        // ── Passo 3: σ de cada sensor sobre os ticks gated ───
        let sigAcc   = Self.std(raws.values.map { $0.dAcc })
        let sigSpeed = Self.std(raws.values.map { $0.dSpeed })
        let sigMag   = Self.std(raws.values.map { $0.dMag })

        // Passos 4+5: normaliza (σ), deadband, tecto e peso.
        func contrib(_ delta: Double, _ sigma: Double, _ weight: Double) -> Double {
            guard sigma > 1e-9 else { return 0 }
            let n = delta / sigma
            guard n >= params.deadband else { return 0 }
            return weight * min(n, params.cap)
        }

        // ── Passos 6+7: soma + EMA, percorrendo a grelha em ordem ──
        var ema = 0.0
        var bestTs: Int64? = nil
        var bestScore = 0.0
        var ticks: [ScoredTick] = []

        for g in gpsReadings {
            let t = g.timestampMs
            let raw: Double
            let gated: Bool
            if let r = raws[t] {
                raw = contrib(r.dAcc,   sigAcc,   params.weightAcc)
                    + contrib(r.dSpeed, sigSpeed, params.weightSpeed)
                    + contrib(r.dMag,   sigMag,   params.weightMag)
                gated = true
            } else {
                raw = 0          // gate falhou ou sem história → score 0 (Passo 2)
                gated = false
            }

            ema = params.emaAlpha * raw + (1 - params.emaAlpha) * ema
            ticks.append(ScoredTick(timestampMs: t, score: ema, gated: gated))

            // O início da janela tem de ser um tick de rua válida.
            if gated, ema > bestScore {
                bestScore = ema
                bestTs = t
            }
        }

        return WindowScore(bestTimestampMs: bestTs, bestScore: bestScore, ticks: ticks)
    }

    /// Recorta o buffer a partir de `fromMs` (inclusive) — usado para a janela [pico → agora].
    func sliced(fromMs: Int64) -> SensorWindow {
        SensorWindow(
            gpsReadings:      gpsReadings.filter      { $0.timestampMs >= fromMs },
            pressureReadings: pressureReadings.filter { $0.timestampMs >= fromMs },
            magneticReadings: magneticReadings.filter { $0.timestampMs >= fromMs }
        )
    }

    // ── Helpers ───────────────────────────────────────────

    /// Valor da amostra cujo timestamp está mais próximo de `targetMs`. nil se vazio.
    private static func valueAt<T>(
        _ readings: [T],
        _ targetMs: Int64,
        _ time:  (T) -> Int64,
        _ value: (T) -> Double
    ) -> Double? {
        guard let nearest = readings.min(by: {
            abs(time($0) - targetMs) < abs(time($1) - targetMs)
        }) else { return nil }
        return value(nearest)
    }

    /// Desvio-padrão amostral. 0 se houver menos de 2 valores.
    private static func std(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = xs.reduce(0, +) / Double(xs.count)
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)
        return v.squareRoot()
    }
}
