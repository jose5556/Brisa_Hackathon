import Foundation

// ── Scoring por tick ──────────────────────────────────
// Calcula, sobre um buffer de amostras, um "score de transição" por tick (~1 Hz)
// usando a fusão de 4 sinais: GPS accuracy, GPS speed, magnetómetro e pressão.
// A pressão contribui de forma opcional (0 se o barómetro não tiver leituras),
// para não anular o tick em dispositivos sem barómetro.
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
    let gated: Bool        // passou o gate de rua (GPS + velocidade)?

    // Variação bruta de cada sensor neste tick (unidades físicas).
    let dAcc:   Double     // m
    let dSpeed: Double     // m/s
    let dMag:   Double     // µT
    let dPress: Double     // hPa

    // Pontuação de cada sensor (normalizada × peso; 0 se o gate falhou).
    let sAcc:   Double
    let sSpeed: Double
    let sMag:   Double
    let sPress: Double

    let rawScore: Double   // soma dos 4 contributos (antes da EMA)
    let score:    Double   // score suavizado (EMA)
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
        var weightAcc:      Double = 1.0  // pesos (Passo 5)
        var weightSpeed:    Double = 1.0
        var weightMag:      Double = 1.0
        var weightPressure: Double = 1.0
        var emaAlpha:       Double = 0.5  // suavização (Passo 7)
    }

    /// Percorre o buffer e devolve o score por tick + o tick de maior score.
    /// A grelha de ticks são as leituras GPS (~1 Hz), que já trazem velocidade e sinal.
    func computeScore(params: ScoreParams = .init()) -> WindowScore {
        guard !gpsReadings.isEmpty else {
            return WindowScore(bestTimestampMs: nil, bestScore: 0, ticks: [])
        }

        // ── Passo 1: Δ bruto de cada sensor por leitura ──────
        // Calculado para TODAS as leituras GPS (haja ou não gate), para se poder
        // inspecionar a variação em cada tick. O gate (Passo 2) só decide se a
        // leitura pontua. Magnetómetro e pressão são opcionais (0 se ausentes).
        struct RawTick {
            let t: Int64
            let gated: Bool
            let dAcc: Double; let dSpeed: Double; let dMag: Double; let dPress: Double
        }
        var raws: [RawTick] = []

        for g in gpsReadings {
            let t = g.timestampMs
            let target = t - params.rateMs

            // Âncoras GPS a ~5 s atrás (obrigatórias — sem elas não há variação a medir).
            guard let accPast   = Self.valueAt(gpsReadings, target, { $0.timestampMs }, { Double($0.accuracyMeters) }),
                  let speedPast = Self.valueAt(gpsReadings, target, { $0.timestampMs }, { $0.speedMps })
            else { continue }

            // Magnetómetro e pressão: opcionais — 0 se não houver leituras.
            let magNow    = Self.valueAt(magneticReadings, t,      { $0.timestampMs }, { $0.magnitude })
            let magPast   = Self.valueAt(magneticReadings, target, { $0.timestampMs }, { $0.magnitude })
            let dMag: Double = (magNow != nil && magPast != nil) ? abs(magNow! - magPast!) : 0

            let pressNow  = Self.valueAt(pressureReadings, t,      { $0.timestampMs }, { Double($0.hPa) })
            let pressPast = Self.valueAt(pressureReadings, target, { $0.timestampMs }, { Double($0.hPa) })
            let dPress: Double = (pressNow != nil && pressPast != nil) ? abs(pressNow! - pressPast!) : 0

            // Gate (Passo 2): velocidade mínima + sinal GPS.
            let gated = g.hasSignal && g.speedMps > params.minSpeedMps

            raws.append(RawTick(
                t:      t,
                gated:  gated,
                dAcc:   abs(Double(g.accuracyMeters) - accPast),
                dSpeed: abs(g.speedMps - speedPast),
                dMag:   dMag,
                dPress: dPress
            ))
        }

        // ── Passo 3: σ de cada sensor, medido só sobre os ticks gated ──
        let gatedRaws = raws.filter { $0.gated }
        let sigAcc   = Self.std(gatedRaws.map { $0.dAcc })
        let sigSpeed = Self.std(gatedRaws.map { $0.dSpeed })
        let sigMag   = Self.std(gatedRaws.map { $0.dMag })
        let sigPress = Self.std(gatedRaws.map { $0.dPress })

        // Passos 4+5: normaliza (σ), deadband, tecto e peso.
        func contrib(_ delta: Double, _ sigma: Double, _ weight: Double) -> Double {
            guard sigma > 1e-9 else { return 0 }
            let n = delta / sigma
            guard n >= params.deadband else { return 0 }
            return weight * min(n, params.cap)
        }

        // ── Passos 6+7: pontuação por sensor + soma + EMA ────
        var ema = 0.0
        var bestTs: Int64? = nil
        var bestScore = 0.0
        var ticks: [ScoredTick] = []

        for r in raws {   // já em ordem cronológica
            // Contributo por sensor — 0 se a leitura não passou o gate.
            let sAcc   = r.gated ? contrib(r.dAcc,   sigAcc,   params.weightAcc)      : 0
            let sSpeed = r.gated ? contrib(r.dSpeed, sigSpeed, params.weightSpeed)    : 0
            let sMag   = r.gated ? contrib(r.dMag,   sigMag,   params.weightMag)      : 0
            let sPress = r.gated ? contrib(r.dPress, sigPress, params.weightPressure) : 0
            let rawScore = sAcc + sSpeed + sMag + sPress

            ema = params.emaAlpha * rawScore + (1 - params.emaAlpha) * ema

            ticks.append(ScoredTick(
                timestampMs: r.t, gated: r.gated,
                dAcc: r.dAcc, dSpeed: r.dSpeed, dMag: r.dMag, dPress: r.dPress,
                sAcc: sAcc, sSpeed: sSpeed, sMag: sMag, sPress: sPress,
                rawScore: rawScore, score: ema
            ))

            // O início da janela tem de ser um tick de rua válida.
            if r.gated, ema > bestScore {
                bestScore = ema
                bestTs = r.t
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
