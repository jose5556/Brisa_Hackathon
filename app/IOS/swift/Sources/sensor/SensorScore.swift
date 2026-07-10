import Foundation

// Passos (alinhados com a especificação):
//   1. Δ de cada sensor vs leitura de ~5 s atrás (rateMs).
//   2. Gate: velocidade > minSpeedMps E GPS com sinal — senão score = 0.
//   3. Normalizar cada Δ pela sua variação típica (σ no próprio buffer,
//      com piso físico por sensor para o ruído de rua não pontuar).
//   4. Deadband (variações ínfimas → 0) e tecto (variações enormes → cap).
//   5. Peso de cada sensor (1× para já).
//   6. Somar as 3 contribuições → score bruto do tick.
//   7. EMA: suaviza com o tick anterior (α = 0.5 → (raw + anterior) / 2).
//   8. (no ViewModel) o baseline do tick de maior score (~10 s antes) vira o início da janela.
//   8b. Validação do pico: fraco ou seguido de cruzeiro de rua retomado
//       (rua, pouca variação) → sem transição → janela curta ancorada no fim.

struct ScoredTick {
    let timestampMs: Int64
    let gated: Bool        // passou o gate de rua (GPS + velocidade)?
    let clean: Bool        // vizinhança sem excesso de gate-off (Passo 2b)?

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

    let recency:       Double   // peso de recência ∈ [0,1] (idade face ao fim)
    let weightedScore: Double   // score × recência — é este que decide o pico
}

struct WindowScore {
    let bestTimestampMs: Int64?    // pico da variação (tick de maior score), nil se nenhum válido
    let windowStartMs: Int64?      // início da janela: baseline comparado com o pico (~rateMs antes)
    let bestScore: Double
    let ticks: [ScoredTick]        // série completa, para logging/calibração
}

extension SensorWindow {

    /// Parâmetros de calibração do score.
    struct ScoreParams {
        var rateMs:      Int64  = 10_000   // janela de variação (Passo 1)
        var minSpeedMps: Double = 0.5     // gate de rua (Passo 2)
        var gateOffWindowMs: Int64  = 7_000   // janela ± à volta do tick
        var maxGateOffFrac:  Double = 0.50     // fração máxima de gate-off tolerada
        var deadband:    Double = 0.3     // em σ: abaixo disto → 0 (Passo 4)
        var cap:         Double = 5.0     // em σ: teto por sensor

        // ── Pisos físicos do σ (Passo 3b) ────────────────────────────────────
        // O σ medido no próprio buffer torna o score relativo: numa rua calma
        // o ruído ínfimo é normalizado como se fosse variação real (σ pequeno
        // → delta/σ grande). O piso dá escala física ao σ: variações abaixo
        // dele são ruído de sensor, não sinal de transição.
        var sigmaFloorAcc:      Double = 2.0    // m
        var sigmaFloorSpeed:    Double = 0.5    // m/s
        var sigmaFloorMag:      Double = 5.0    // µT
        var sigmaFloorPressure: Double = 0.10   // hPa

        // ── Validação do pico (Passo 8b) ─────────────────────────────────────
        // Um pico só é uma transição se for significativo E terminal (o carro
        // estaciona pouco depois). Pico fraco, ou seguido de condução de
        // CRUZEIRO retomada (velocidade de rua — numa rampa de parque nunca se
        // passa de ~2 m/s), é ruído de condução — a janela passa a ser curta,
        // ancorada no fim do buffer.
        var minPeakScore:         Double = 3.0     // wscore mínimo do pico
        var cruiseSpeedMps:       Double = 3.0     // velocidade que só existe em rua
        var maxCruiseAfterPeakMs: Int64  = 20_000  // cruzeiro máximo tolerado após o pico
        var noTransitionWindowMs: Int64  = 20_000  // janela curta quando não há transição
        var baselinePadMs:        Int64  = 2_000   // margem antes da calmaria encontrada
        var weightAcc:      Double = 0.9  // pesos (Passo 5)
        var weightSpeed:    Double = 1.1
        var weightMag:      Double = 0.3
        var weightPressure: Double = 0.7
        var emaAlpha:       Double = 0.5  // suavização (Passo 7)
        var baselineQuietFrac:     Double = 0.3   // fração do score do pico
        var baselineQuietFloor:    Double = 1.5     // piso absoluto do limiar
        var baselineMaxLookbackMs: Int64  = 30_000  // recuo máximo

        // ── Peso por recência (Passo 8) ──────────────────────────────────────
        var recencyEnabled:      Bool   = true
        var recencyPlateauStartMs: Int64 = 20_000    // 20 s antes do fim
        var recencyPlateauEndMs:   Int64 = 140_000   // 2 min e 42s antes do fim
        var recencyTauMs:          Double = 50_000   // decaimento além do planalto
        var recencyNearWeight:     Double = 0.5      // peso no instante do fim
    }

    /// Peso de recência de um tick, dado a sua idade
    private static func recencyWeight(ageMs: Int64, _ p: ScoreParams) -> Double {
        guard p.recencyEnabled else { return 1 }
        let age = Double(max(0, ageMs))
        let start = Double(p.recencyPlateauStartMs)
        let end   = Double(p.recencyPlateauEndMs)
        if age < start {
            // Rampa: nearWeight (idade 0) → 1 (idade start).
            let f = start > 0 ? age / start : 1
            return p.recencyNearWeight + (1 - p.recencyNearWeight) * f
        }
        if age <= end { return 1 }
        return exp(-(age - end) / p.recencyTauMs)   // decaimento para o passado
    }

    /// Percorre o buffer e devolve o score por tick + o tick de maior score.
    /// A grelha de ticks são as leituras GPS (~1 Hz), que já trazem velocidade e sinal.
    func computeScore(params: ScoreParams = .init()) -> WindowScore {
        guard !gpsReadings.isEmpty else {
            return WindowScore(bestTimestampMs: nil, windowStartMs: nil, bestScore: 0, ticks: [])
        }

        // ── Passo 1: Δ bruto de cada sensor por leitura ──────
        // Calculado para TODAS as leituras GPS (haja ou não gate), para se poder
        // inspecionar a variação em cada tick. O gate (Passo 2) só decide se a
        // leitura pontua. Magnetómetro e pressão são opcionais (0 se ausentes).
        struct RawTick {
            let t: Int64
            let gated: Bool
            let speed: Double   // velocidade GPS do tick (para o Passo 8b)
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
                speed:  g.speedMps,
                dAcc:   abs(Double(g.accuracyMeters) - accPast),
                dSpeed: abs(g.speedMps - speedPast),
                dMag:   dMag,
                dPress: dPress
            ))
        }

        // ── Passo 2b: vizinhança de gate ──
        // Fração de ticks SEM gate na janela ±gateOffWindowMs à volta de `t`.
        // Percorre os raws (já cronológicos, ~1 Hz); n é pequeno, O(n²) é barato.
        func gateOffFrac(around t: Int64) -> Double {
            let lo = t - params.gateOffWindowMs
            let hi = t + params.gateOffWindowMs
            var total = 0, off = 0
            for r in raws where r.t >= lo && r.t <= hi {
                total += 1
                if !r.gated { off += 1 }
            }
            return total > 0 ? Double(off) / Double(total) : 0
        }
        // "clean" = passou o gate E a vizinhança tem gate-off ≤ limiar.
        // É esta condição — não o gate isolado — que autoriza um tick a pontuar.
        let cleanFlags = raws.map { $0.gated && gateOffFrac(around: $0.t) <= params.maxGateOffFrac }

        // ── Passo 3: σ de cada sensor, medido só sobre os ticks que vão pontuar ──
        // (gated + vizinhança limpa) — assim o ruído do subterrâneo não infla o σ
        // e não abafa as variações legítimas de rua.
        // Passo 3b: o σ nunca desce abaixo do piso físico — num buffer calmo
        // (rua sem transição) é o piso que manda, e o ruído deixa de pontuar.
        let cleanRaws = zip(raws, cleanFlags).filter { $0.1 }.map { $0.0 }
        let sigAcc   = max(Self.std(cleanRaws.map { $0.dAcc }),   params.sigmaFloorAcc)
        let sigSpeed = max(Self.std(cleanRaws.map { $0.dSpeed }), params.sigmaFloorSpeed)
        let sigMag   = max(Self.std(cleanRaws.map { $0.dMag }),   params.sigmaFloorMag)
        let sigPress = max(Self.std(cleanRaws.map { $0.dPress }), params.sigmaFloorPressure)

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

        // Fim do buffer = instante do "Analisar" (referência para a idade/recência).
        let endTs = gpsReadings.last!.timestampMs

        for (idx, r) in raws.enumerated() {   // já em ordem cronológica
            // Só pontua se passou o gate E a vizinhança está limpa (Passo 2b).
            let clean = cleanFlags[idx]

            // Contributo por sensor — 0 se o tick não é "clean".
            let sAcc   = clean ? contrib(r.dAcc,   sigAcc,   params.weightAcc)      : 0
            let sSpeed = clean ? contrib(r.dSpeed, sigSpeed, params.weightSpeed)    : 0
            let sMag   = clean ? contrib(r.dMag,   sigMag,   params.weightMag)      : 0
            let sPress = clean ? contrib(r.dPress, sigPress, params.weightPressure) : 0
            let rawScore = sAcc + sSpeed + sMag + sPress

            ema = params.emaAlpha * rawScore + (1 - params.emaAlpha) * ema

            // Passo 8: pondera o score suavizado pela recência (idade face ao fim).
            let recency = Self.recencyWeight(ageMs: endTs - r.t, params)
            let weighted = ema * recency

            ticks.append(ScoredTick(
                timestampMs: r.t, gated: r.gated, clean: clean,
                dAcc: r.dAcc, dSpeed: r.dSpeed, dMag: r.dMag, dPress: r.dPress,
                sAcc: sAcc, sSpeed: sSpeed, sMag: sMag, sPress: sPress,
                rawScore: rawScore, score: ema,
                recency: recency, weightedScore: weighted
            ))

            // O pico é o tick de rua VÁLIDA E LIMPA com maior score ponderado.
            if clean, weighted > bestScore {
                bestScore = weighted
                bestTs = r.t
            }
        }

        // A janela começa no baseline: recuamos do pico até à última calmaria.
        // Percorremos os ticks para trás a partir do pico e paramos no primeiro
        // tick cujo score < limiar (relativo ao pico + piso absoluto). Esse tick
        // "calmo" é o início da janela — a rua antes da transição. O recuo está
        // limitado a baselineMaxLookbackMs; se nunca encontrarmos calmaria dentro
        // desse limite, o baseline é o tick mais recuado permitido. Clampado à
        // leitura mais antiga do buffer para não apontar para antes dos dados.
        let earliestTs = gpsReadings.first?.timestampMs
        let windowStart: Int64?
        if let bestTs = bestTs,
           let bestIdx = ticks.firstIndex(where: { $0.timestampMs == bestTs }) {
            // Passo 8b: valida se o pico é mesmo uma transição TERMINAL.
            // Depois de entrar num parque o carro nunca volta a andar a
            // velocidade de rua (rampas/manobras ficam ≤ ~2 m/s). Se depois do
            // pico ainda há condução de cruzeiro limpa prolongada, o pico foi
            // ruído a meio da viagem — não transição. (raws e ticks estão
            // alinhados por índice, ~1 Hz.)
            var cruiseAfterMs: Int64 = 0
            for i in (bestIdx + 1)..<raws.count
            where cleanFlags[i] && raws[i].speed >= params.cruiseSpeedMps {
                cruiseAfterMs += 1_000
            }
            let isTransition = bestScore >= params.minPeakScore
                            && cruiseAfterMs <= params.maxCruiseAfterPeakMs
            if !isTransition {
                // Sem transição (rua / pouca variação): janela curta ancorada
                // no fim — apanha só a manobra final de estacionamento.
                windowStart = max(endTs - params.noTransitionWindowMs,
                                  earliestTs ?? endTs - params.noTransitionWindowMs)
            } else {
                let threshold = max(params.baselineQuietFloor,
                                    params.baselineQuietFrac * ticks[bestIdx].score)
                let minTs = bestTs - params.baselineMaxLookbackMs
                var startIdx = bestIdx
                var i = bestIdx - 1
                while i >= 0, ticks[i].timestampMs >= minTs {
                    startIdx = i
                    if ticks[i].score < threshold { break }   // chegámos à calmaria
                    i -= 1
                }
                // Pad: recua uma margem pequena antes da calmaria, para a
                // janela incluir sempre um pouco de rua antes da transição.
                windowStart = max(ticks[startIdx].timestampMs - params.baselinePadMs,
                                  earliestTs ?? ticks[startIdx].timestampMs)
            }
        } else {
            windowStart = nil
        }
        return WindowScore(bestTimestampMs: bestTs, windowStartMs: windowStart, bestScore: bestScore, ticks: ticks)
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
