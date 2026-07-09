import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// TrajectorySimulator
// ─────────────────────────────────────────────────────────────────────────────
// Gera trajetórias sintéticas de sensores (GPS + barómetro + magnetómetro) para
// testar, FORA do telemóvel, o cálculo de score e as variações (deltas / payload).
//
// Reutiliza EXATAMENTE o mesmo código de produção:
//   • SensorData.swift  (structs + toPayload + deltas)
//   • SensorScore.swift (computeScore)
// Nenhum sensor real é usado — construímos as amostras à mão a 1 Hz.
//
// O resultado NÃO é despejado no terminal: é escrito num ficheiro de report
// (trajectory_report.md). No terminal fica só um resumo por cenário.
//
// Cada cenário valida a Δ de pressão OBTIDA (payload, com ruído) contra a Δ de
// pressão ESPERADA (curva de pressão sem ruído, sobre a mesma janela recortada).
//
// Compilar e correr (a partir de app/IOS/swift):
//   swiftc Tools/TrajectorySimulator.swift \
//          Sources/data/SensorData.swift \
//          Sources/sensor/SensorScore.swift \
//          -o /tmp/brisa-sim && /tmp/brisa-sim
// ─────────────────────────────────────────────────────────────────────────────

// ── PRNG determinístico (reprodutível entre execuções) ───────────────────────
struct RNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// ruído uniforme em [-amp, +amp]
    mutating func noise(_ amp: Double) -> Double {
        let u = Double(next() % 10_000) / 10_000.0   // [0,1)
        return (u * 2 - 1) * amp
    }
}

// ── Uma "fase" da trajetória com valores-alvo por segundo ────────────────────
// Cada campo é interpolado linearmente entre segundos e leva ruído.
struct Phase {
    let name: String
    let durationS: Int
    // Valores no FIM da fase (parte-se do estado atual e interpola-se até aqui).
    let speedMps: Double         // velocidade GPS
    let accuracyM: Double        // precisão GPS (maior = pior)
    let hasSignal: Bool          // sinal GPS presente
    let pressureHpa: Double      // pressão barométrica
    let magUt: Double            // magnitude alvo do campo magnético
    let magJitter: Double        // amplitude de ruído do magnetómetro
    var accJitter: Double = 1.0
}

// ── Resultado do gerador: janela + curva de pressão sem ruído (ground-truth) ──
// A truthPressure guarda, por timestamp, a pressão-alvo interpolada SEM ruído.
// Serve para calcular a Δ de pressão ESPERADA sobre qualquer recorte da janela.
struct SimWindow {
    let window: SensorWindow
    let truthPressure: [Int64: Double]
    // Timestamp (ms) do 1.º segundo de cada fase — para saber o "ground-truth"
    // do instante em que o carro saiu da rua e entrou no estacionamento.
    let phaseBounds: [(name: String, startMs: Int64)]
}

// ── Gera um SimWindow a partir de uma sequência de fases ─────────────────────
func buildWindow(baseMs: Int64, phases: [Phase], seed: UInt64,
                 startLat: Double, startLon: Double) -> SimWindow {
    var rng = RNG(seed: seed)

    var gps:  [GpsReading]      = []
    var pres: [PressureReading] = []
    var mag:  [MagneticReading] = []
    var truth: [Int64: Double]  = [:]   // pressão sem ruído por timestamp

    // Estado inicial = primeiros valores da primeira fase (sem transição).
    var curSpeed = phases.first!.speedMps
    var curAcc   = phases.first!.accuracyM
    var curPress = phases.first!.pressureHpa
    var curMag   = phases.first!.magUt

    var lat = startLat
    var lon = startLon
    var sec: Int64 = 0
    var bounds: [(name: String, startMs: Int64)] = []

    for phase in phases {
        bounds.append((phase.name, baseMs + sec * 1000))   // início desta fase
        let fromSpeed = curSpeed, fromAcc = curAcc, fromPress = curPress, fromMag = curMag
        for i in 1...phase.durationS {
            let f = Double(i) / Double(phase.durationS)   // fração 0→1 dentro da fase

            let speed  = fromSpeed + (phase.speedMps    - fromSpeed) * f
            let acc    = fromAcc   + (phase.accuracyM   - fromAcc)   * f
            let press  = fromPress + (phase.pressureHpa - fromPress) * f
            let magM   = fromMag   + (phase.magUt       - fromMag)   * f

            let t = baseMs + sec * 1000
            sec += 1

            truth[t] = press   // pressão-alvo (sem ruído) neste instante

            // Avança a posição ~ speed metros (grosseiro: 1 grau lat ≈ 111 km).
            lat += (speed / 111_000.0)
            lon += (speed / 88_000.0) * 0.3

            // GPS
            let noisySpeed = max(0, speed + rng.noise(0.4))
            let noisyAcc   = max(1, acc + rng.noise(phase.accJitter))
            gps.append(GpsReading(
                latitude:       lat,
                longitude:      lon,
                accuracyMeters: Float(noisyAcc),
                altitudeMeters: 0,
                speedMps:       phase.hasSignal ? noisySpeed : 0,
                hasSignal:      phase.hasSignal,
                timestampMs:    t
            ))

            // Barómetro
            pres.append(PressureReading(
                hPa: Float(press + rng.noise(0.02)),
                timestampMs: t
            ))

            // Magnetómetro — decompõe a magnitude alvo em componentes + jitter.
            let m = magM + rng.noise(phase.magJitter)
            let comp = m / 1.732   // reparte por x,y,z (√3) para |v| ≈ m
            mag.append(MagneticReading(
                x: comp + rng.noise(phase.magJitter),
                y: comp + rng.noise(phase.magJitter),
                z: comp + rng.noise(phase.magJitter),
                timestampMs: t
            ))
        }
        curSpeed = phase.speedMps; curAcc = phase.accuracyM
        curPress = phase.pressureHpa; curMag = phase.magUt
    }

    return SimWindow(
        window: SensorWindow(gpsReadings: gps, pressureReadings: pres, magneticReadings: mag),
        truthPressure: truth,
        phaseBounds: bounds
    )
}

// ── Pressão-alvo (sem ruído) mais próxima de um timestamp ────────────────────
// A grelha é a 1 Hz, mas usamos o vizinho mais próximo para ser robusto a
// timestamps que não caiam exatamente numa amostra.
func truthPressureAt(_ truth: [Int64: Double], _ t: Int64) -> Double? {
    if let exact = truth[t] { return exact }
    return truth.min(by: { abs($0.key - t) < abs($1.key - t) })?.value
}

let porto = (lat: 41.1579, lon: -8.6291)   // centro do Porto

// Ciclo de condução urbana realista (~54s): cruzeiro → PARAGEM em semáforo
// (velocidade 0 → o gate desliga) → arranque → curva (abranda) → lomba.
// Pressão fixa (nível da rua) e magnetómetro estável (céu aberto).
let ruaCiclo: [Phase] = [
    // Pressão ~plana (nível da rua): a variação real numa rua é o drift
    // meteorológico, <0.05 hPa em minutos — negligível vs uma rampa (~0.3-0.7 hPa).
    // magJitter moderado (4-5, céu aberto). A dinâmica está na VELOCIDADE:
    // semáforos (para a 0), curva e lomba.
    Phase(name: "Cruzeiro",           durationS: 16, speedMps: 12, accuracyM: 11, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
    Phase(name: "Trava p/ semáforo",  durationS: 6,  speedMps: 0,  accuracyM: 13, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
    Phase(name: "Parado no semáforo", durationS: 10, speedMps: 0,  accuracyM: 14, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
    Phase(name: "Arranca do semáforo",durationS: 6,  speedMps: 13, accuracyM: 12, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
    Phase(name: "Curva (abranda)",    durationS: 5,  speedMps: 5,  accuracyM: 13, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Sai da curva",       durationS: 4,  speedMps: 12, accuracyM: 12, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Lomba (abranda)",    durationS: 3,  speedMps: 3,  accuracyM: 13, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Pós-lomba",          durationS: 4,  speedMps: 11, accuracyM: 12, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
]

// Repete qualquer ciclo de rua até perfazer ~`seconds` de condução.
func repeatCycle(_ cycle: [Phase], _ seconds: Int) -> [Phase] {
    let cycleS = cycle.reduce(0) { $0 + $1.durationS }
    let reps = max(1, seconds / max(1, cycleS))
    return Array(repeating: cycle, count: reps).flatMap { $0 }
}

// Repete o ciclo urbano até perfazer ~`seconds` de condução em rua.
func ruaUrbana(_ seconds: Int) -> [Phase] { repeatCycle(ruaCiclo, seconds) }

// ── Variação de rua 1: AVENIDA / via rápida ──────────────────────────────────
// Fluxo mais livre: cruzeiro alto (~20 m/s), poucas paragens, uma rotunda.
// Pressão plana (nível da rua) e magnetómetro estável (céu aberto).
let ruaAvenidaCiclo: [Phase] = [
    Phase(name: "Cruzeiro rápido",    durationS: 20, speedMps: 20, accuracyM: 9,  hasSignal: true, pressureHpa: 1013.00, magUt: 47, magJitter: 4),
    Phase(name: "Abranda p/ rotunda", durationS: 5,  speedMps: 6,  accuracyM: 11, hasSignal: true, pressureHpa: 1013.00, magUt: 47, magJitter: 4),
    Phase(name: "Rotunda",            durationS: 6,  speedMps: 7,  accuracyM: 12, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Retoma cruzeiro",    durationS: 18, speedMps: 22, accuracyM: 9,  hasSignal: true, pressureHpa: 1013.00, magUt: 47, magJitter: 4),
]
func ruaAvenida(_ seconds: Int) -> [Phase] { repeatCycle(ruaAvenidaCiclo, seconds) }

// ── Variação de rua 2: TRÂNSITO CONGESTIONADO ────────────────────────────────
// Stop-and-go constante: muitas paragens (velocidade 0 → o gate desliga várias
// vezes), avanços curtos. Testa robustez a paragens frequentes que NÃO são o
// estacionamento (não devem ancorar o baseline).
let ruaCongestionadaCiclo: [Phase] = [
    Phase(name: "Anda-para (fila)",   durationS: 4, speedMps: 4, accuracyM: 13, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Parado no trânsito", durationS: 8, speedMps: 0, accuracyM: 15, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Avança 1 carro",     durationS: 3, speedMps: 3, accuracyM: 14, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Parado (semáforo)",  durationS: 9, speedMps: 0, accuracyM: 15, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
    Phase(name: "Pequeno avanço",     durationS: 5, speedMps: 6, accuracyM: 13, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 5),
]
func ruaCongestionada(_ seconds: Int) -> [Phase] { repeatCycle(ruaCongestionadaCiclo, seconds) }

// Cenário A — desce ao piso -1
let scenarioDown1: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 8,  speedMps: 2.0, accuracyM: 25, hasSignal: true,  pressureHpa: 1013.05, magUt: 55, magJitter: 8),
    Phase(name: "Rampa desce → piso -1",  durationS: 20, speedMps: 1.5, accuracyM: 45, hasSignal: true,  pressureHpa: 1013.36, magUt: 40, magJitter: 80),
    Phase(name: "Estacionado (piso -1)",  durationS: 10, speedMps: 0.0, accuracyM: 55, hasSignal: false, pressureHpa: 1013.36, magUt: 38, magJitter: 12),
]

// Cenário B — sobe ao piso 3
let scenarioUp3: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 15, speedMps: 2.0, accuracyM: 20, hasSignal: true, pressureHpa: 1012.95, magUt: 55, magJitter: 8),
    Phase(name: "Rampa sobe → piso 3",    durationS: 45, speedMps: 1.5, accuracyM: 45, hasSignal: true, pressureHpa: 1011.94, magUt: 42, magJitter: 15),
    Phase(name: "Estacionado (piso 3)",   durationS: 10, speedMps: 0.0, accuracyM: 50, hasSignal: true, pressureHpa: 1011.94, magUt: 44, magJitter: 12),
]

// Cenário C — desce fundo ao piso -3 (maior Δ de pressão)
let scenarioDown3: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 8,  speedMps: 2.0, accuracyM: 25, hasSignal: true,  pressureHpa: 1013.05, magUt: 55, magJitter: 8),
    Phase(name: "Rampa desce → piso -3",  durationS: 70, speedMps: 1.3, accuracyM: 50, hasSignal: false, pressureHpa: 1014.06, magUt: 36, magJitter: 18),
    Phase(name: "Estacionado (piso -3)",  durationS: 10, speedMps: 0.0, accuracyM: 60, hasSignal: false, pressureHpa: 1014.06, magUt: 34, magJitter: 14),
]

// Cenário D — sobe ao piso 5 (parque em altura)
let scenarioUp5: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 15, speedMps: 2.0, accuracyM: 20, hasSignal: true, pressureHpa: 1012.90, magUt: 55, magJitter: 8),
    Phase(name: "Rampa sobe → piso 5",    durationS: 75, speedMps: 1.3, accuracyM: 45, hasSignal: true, pressureHpa: 1011.23, magUt: 43, magJitter: 15),
    Phase(name: "Estacionado (piso 5)",   durationS: 10, speedMps: 0.0, accuracyM: 48, hasSignal: true, pressureHpa: 1011.23, magUt: 45, magJitter: 12),
]

// Cenário E — parque à SUPERFÍCIE (sem mudança de piso → Δ pressão ≈ 0)
// Serve para verificar que uma paragem sem descida não gera Δ de pressão.
let scenarioSurface: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada parque superfície", durationS: 12, speedMps: 2.0, accuracyM: 18, hasSignal: true, pressureHpa: 1013.00, magUt: 50, magJitter: 4),
    Phase(name: "Manobra até ao lugar",      durationS: 20, speedMps: 1.5, accuracyM: 22, hasSignal: true, pressureHpa: 1013.00, magUt: 49, magJitter: 5),
    Phase(name: "Estacionado (superfície)",  durationS: 10, speedMps: 0.0, accuracyM: 20, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
]

// Cenário F — sobe ao piso 2 (subida curta, ~+6 m → ~-0.71 hPa)
let scenarioUp2: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 15, speedMps: 2.0, accuracyM: 20, hasSignal: true, pressureHpa: 1012.95, magUt: 55, magJitter: 8),
    Phase(name: "Rampa sobe → piso 2",    durationS: 35, speedMps: 1.4, accuracyM: 42, hasSignal: true, pressureHpa: 1012.29, magUt: 43, magJitter: 15),
    Phase(name: "Estacionado (piso 2)",   durationS: 10, speedMps: 0.0, accuracyM: 46, hasSignal: true, pressureHpa: 1012.29, magUt: 45, magJitter: 12),
]

// Cenário G — rampa CAÓTICA: desce ao piso -2 com GPS errático (accJitter alto,
// precisão a saltar) e magnetómetro extremo (magJitter ~35, típico de espiral de
// betão/metal). Serve para testar se a deteção aguenta ruído severo na rampa.
let scenarioNoisyRamp: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 8,  speedMps: 2.0, accuracyM: 25, hasSignal: true,  pressureHpa: 1013.05, magUt: 55, magJitter: 12, accJitter: 6),
    Phase(name: "Rampa espiral → piso -2", durationS: 55, speedMps: 1.2, accuracyM: 55, hasSignal: false, pressureHpa: 1013.71, magUt: 38, magJitter: 35, accJitter: 20),
    Phase(name: "Estacionado (piso -2)",  durationS: 10, speedMps: 0.0, accuracyM: 60, hasSignal: false, pressureHpa: 1013.71, magUt: 34, magJitter: 25, accJitter: 15),
]

// ═════════════════════════════════════════════════════════════════════════════
// CENÁRIOS EXTRA — variações de rua + superfície + ±1/-2, ruidoso vs não ruidoso
// ═════════════════════════════════════════════════════════════════════════════
// "Ruidoso" = prédio de betão/metal (espiral): magJitter e accJitter altos na
// rampa e no lugar. "Não ruidoso" = estrutura aberta/arejada: jitter baixo.
// Todos usam a regra ~0.33 hPa por piso (descer → Δ +, subir → Δ −).

// Cenário H — SUPERFÍCIE após AVENIDA (rua diferente, Δ pressão ≈ 0)
let scenarioSurfaceAvenida: [Phase] = ruaAvenida(400) + [
    Phase(name: "Entrada parque superfície", durationS: 12, speedMps: 2.0, accuracyM: 18, hasSignal: true, pressureHpa: 1013.00, magUt: 50, magJitter: 4),
    Phase(name: "Manobra até ao lugar",      durationS: 18, speedMps: 1.5, accuracyM: 22, hasSignal: true, pressureHpa: 1013.00, magUt: 49, magJitter: 5),
    Phase(name: "Estacionado (superfície)",  durationS: 10, speedMps: 0.0, accuracyM: 20, hasSignal: true, pressureHpa: 1013.00, magUt: 48, magJitter: 4),
]

// Cenário I — SUPERFÍCIE junto a PRÉDIO RUIDOSO (mag/GPS ruidosos, mas Δp ≈ 0)
// Teste de FALSO POSITIVO: muito ruído magnético/GPS sem mudança de piso NÃO
// deve gerar Δ de pressão nem detetar transição de andar.
let scenarioSurfaceNoisy: [Phase] = ruaCongestionada(400) + [
    Phase(name: "Entrada parque superfície", durationS: 12, speedMps: 2.0, accuracyM: 22, hasSignal: true, pressureHpa: 1013.00, magUt: 52, magJitter: 30, accJitter: 12),
    Phase(name: "Manobra junto ao prédio",   durationS: 20, speedMps: 1.5, accuracyM: 30, hasSignal: true, pressureHpa: 1013.00, magUt: 50, magJitter: 38, accJitter: 15),
    Phase(name: "Estacionado (superfície)",  durationS: 10, speedMps: 0.0, accuracyM: 28, hasSignal: true, pressureHpa: 1013.00, magUt: 49, magJitter: 30, accJitter: 10),
]

// Cenário J — SOBE ao piso +1 (estrutura ABERTA / não ruidosa, ~+3 m → −0.33 hPa)
let scenarioUp1: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 12, speedMps: 2.0, accuracyM: 20, hasSignal: true, pressureHpa: 1012.98, magUt: 52, magJitter: 8),
    Phase(name: "Rampa sobe → piso 1",    durationS: 22, speedMps: 1.5, accuracyM: 38, hasSignal: true, pressureHpa: 1012.65, magUt: 45, magJitter: 12),
    Phase(name: "Estacionado (piso 1)",   durationS: 10, speedMps: 0.0, accuracyM: 40, hasSignal: true, pressureHpa: 1012.65, magUt: 46, magJitter: 10),
]

// Cenário K — SOBE ao piso +1 (prédio RUIDOSO betão/metal), mesma Δp que J
let scenarioUp1Noisy: [Phase] = ruaAvenida(400) + [
    Phase(name: "Entrada estacionamento", durationS: 10, speedMps: 2.0, accuracyM: 24, hasSignal: true,  pressureHpa: 1012.98, magUt: 54, magJitter: 14, accJitter: 8),
    Phase(name: "Rampa sobe → piso 1",    durationS: 24, speedMps: 1.3, accuracyM: 48, hasSignal: false, pressureHpa: 1012.65, magUt: 40, magJitter: 34, accJitter: 18),
    Phase(name: "Estacionado (piso 1)",   durationS: 10, speedMps: 0.0, accuracyM: 52, hasSignal: false, pressureHpa: 1012.65, magUt: 36, magJitter: 26, accJitter: 12),
]

// Cenário L — DESCE ao piso -1 (não ruidoso), após TRÂNSITO congestionado
let scenarioDown1Calm: [Phase] = ruaCongestionada(400) + [
    Phase(name: "Entrada estacionamento", durationS: 10, speedMps: 2.0, accuracyM: 22, hasSignal: true, pressureHpa: 1013.05, magUt: 52, magJitter: 8),
    Phase(name: "Rampa desce → piso -1",  durationS: 20, speedMps: 1.5, accuracyM: 40, hasSignal: true, pressureHpa: 1013.36, magUt: 44, magJitter: 12),
    Phase(name: "Estacionado (piso -1)",  durationS: 10, speedMps: 0.0, accuracyM: 44, hasSignal: true, pressureHpa: 1013.36, magUt: 42, magJitter: 10),
]

// Cenário M — DESCE ao piso -1 (prédio RUIDOSO), mesma Δp que L
let scenarioDown1Noisy: [Phase] = ruaUrbana(400) + [
    Phase(name: "Entrada estacionamento", durationS: 8,  speedMps: 2.0, accuracyM: 26, hasSignal: true,  pressureHpa: 1013.05, magUt: 55, magJitter: 14, accJitter: 8),
    Phase(name: "Rampa desce → piso -1",  durationS: 22, speedMps: 1.3, accuracyM: 52, hasSignal: false, pressureHpa: 1013.36, magUt: 38, magJitter: 36, accJitter: 20),
    Phase(name: "Estacionado (piso -1)",  durationS: 10, speedMps: 0.0, accuracyM: 58, hasSignal: false, pressureHpa: 1013.36, magUt: 34, magJitter: 26, accJitter: 14),
]

// Cenário N — DESCE ao piso -2 (não ruidoso / arejado), complementa o G (ruidoso)
let scenarioDown2Calm: [Phase] = ruaAvenida(400) + [
    Phase(name: "Entrada estacionamento", durationS: 10, speedMps: 2.0, accuracyM: 22, hasSignal: true, pressureHpa: 1013.05, magUt: 52, magJitter: 8),
    Phase(name: "Rampa desce → piso -2",  durationS: 40, speedMps: 1.5, accuracyM: 42, hasSignal: true, pressureHpa: 1013.71, magUt: 44, magJitter: 12),
    Phase(name: "Estacionado (piso -2)",  durationS: 10, speedMps: 0.0, accuracyM: 46, hasSignal: true, pressureHpa: 1013.71, magUt: 42, magJitter: 10),
]

// ─────────────────────────────────────────────────────────────────────────────
// Reporter — acumula o report em memória e grava num ficheiro no fim.
// ─────────────────────────────────────────────────────────────────────────────
final class Reporter {
    private(set) var text = ""
    func line(_ s: String = "") { text += s + "\n" }
    func write(to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// Resumo de um cenário para o terminal (uma linha).
struct ScenarioResult {
    let title: String
    let expectedDelta: Double   // Δ pressão esperada (sem ruído, mesma janela)
    let obtainedDelta: Double   // Δ pressão obtida (payload, com ruído)
    let passed: Bool            // Δ pressão dentro da tolerância?
    let note: String

    // Ancoragem: segundo real da entrada no parque vs baseline/pico detetados.
    let entrySec: Int?          // ground-truth: saiu da rua / entrou no parque
    let baseSec: Int?           // baseline (início da janela) detetado
    let peakSec: Int?           // pico da variação detetado
    let anchorOk: Bool          // baseline detetado junto à entrada real?
}

// O baseline (início da janela recortada) deve cair JUNTO ao momento real em que
// o carro saiu da rua e entrou no parque. Tolerâncias (s):
//   • até `baselineLeadMaxS` ANTES da entrada → ok (a janela inclui algum "antes",
//     o que ajuda a apanhar a pressão de rua como referência do delta);
//   • até `baselineLagMaxS` DEPOIS → no máximo, senão perde o início da transição.
let baselineLeadMaxS = 10
let baselineLagMaxS  = 5

// ─────────────────────────────────────────────────────────────────────────────
// Execução de um cenário → escreve no report e devolve um resumo.
// ─────────────────────────────────────────────────────────────────────────────
let pressureToleranceHpa = 0.08   // tolerância aceitável entre esperada e obtida

func runScenario(_ title: String, _ phases: [Phase], seed: UInt64,
                 into rep: Reporter) -> ScenarioResult {
    let base: Int64 = 1_700_000_000_000   // epoch ms fixo (reprodutível)
    let sim = buildWindow(baseMs: base, phases: phases, seed: seed,
                          startLat: porto.lat, startLon: porto.lon)
    let window = sim.window
    let truth  = sim.truthPressure

    let line = String(repeating: "═", count: 78)
    rep.line("\n\(line)\n  \(title)\n\(line)")
    rep.line("Amostras: GPS=\(window.gpsReadings.count)  Pressão=\(window.pressureReadings.count)  Mag=\(window.magneticReadings.count)")

    // ── Amostras cruas geradas (para inspecionar realismo dos dados) ──
    dumpRawSamples(window, base: base, into: rep)

    // ── Score por tick ────────────────────────────────
    let scoring = window.computeScore()
    rep.line("\n── Score de transição por tick (só ticks com variação/gate relevante) ──")
    rep.line("   s   gate  clean     dAcc     dSpd     dMag   dPress     raw  score    rec  wscore")
    for tick in scoring.ticks {
        let s = (tick.timestampMs - base) / 1000
        // Mostra ticks com score, o pico, e ticks REJEITADOS pela vizinhança
        // (gated mas !clean) — para se ver o filtro do Passo 2b a atuar.
        if tick.rawScore > 0.01 || tick.timestampMs == scoring.bestTimestampMs
            || (tick.gated && !tick.clean) {
            rep.line(String(format: "%4lld %6@ %6@ %8.2f %8.2f %8.2f %8.3f %7.2f %6.2f  %5.2f %6.2f",
                            s, tick.gated ? "sim" : "não", tick.clean ? "sim" : "NÃO",
                            tick.dAcc, tick.dSpeed, tick.dMag, tick.dPress,
                            tick.rawScore, tick.score, tick.recency, tick.weightedScore))
        }
    }

    // Determina a janela recortada [startTs → endTs].
    let endTs = window.gpsReadings.last!.timestampMs
    let startTs: Int64
    let sliced: SensorWindow

    if let best = scoring.bestTimestampMs, let start = scoring.windowStartMs {
        startTs = start
        rep.line(String(format: "\n➜ PICO da variação @ %llds  (score=%.2f)", (best - base)/1000, scoring.bestScore))
        rep.line(String(format: "➜ INÍCIO da janela  @ %llds  (baseline: recuo do pico até à calmaria)", (start - base)/1000))
        let durS = Double(endTs - start) / 1000.0
        rep.line(String(format: "➜ Janela final: [%llds → %llds] = %.0fs de captura",
                        (start - base)/1000, (endTs - base)/1000, durS))
        sliced = window.sliced(fromMs: start)
    } else {
        startTs = window.gpsReadings.first!.timestampMs
        rep.line("\n⚠ Nenhum tick passou o gate — no telemóvel cairia no fallback (janela completa).")
        sliced = window
    }

    // ── Payload da janela recortada (o que seria enviado à API) ──
    guard let p = sliced.toPayload() else {
        rep.line("\n⚠ Sem payload (janela vazia).")
        return ScenarioResult(title: title, expectedDelta: 0, obtainedDelta: 0,
                              passed: false, note: "sem payload",
                              entrySec: nil, baseSec: nil, peakSec: nil, anchorOk: false)
    }
    printPayload(p, into: rep)

    // ── Validação da pressão: esperada (sem ruído) vs obtida (payload) ──
    // pressureDeltaHpa = pressão_inicial − pressão_final (sobe ao descer → +).
    let obtainedDelta = p.pressureDeltaHpa

    // Esperada sobre a MESMA janela recortada, a partir da curva sem ruído.
    let expInitial = truthPressureAt(truth, startTs) ?? 0
    let expFinal   = truthPressureAt(truth, endTs)   ?? 0
    let expectedDelta = expInitial - expFinal

    // Esperada sobre o cenário completo (contexto: queda total pretendida).
    let fullInitial = truthPressureAt(truth, window.gpsReadings.first!.timestampMs) ?? 0
    let fullDelta   = fullInitial - expFinal

    let errAbs = obtainedDelta - expectedDelta
    let errPct = abs(expectedDelta) > 1e-6 ? errAbs / expectedDelta * 100 : 0
    let passed = abs(errAbs) <= pressureToleranceHpa

    rep.line("\n── Validação da pressão (esperada sem ruído vs obtida no payload) ──")
    rep.line(String(format: "  Δ pressão esperada (janela recortada) : %+8.3f hPa", expectedDelta))
    rep.line(String(format: "  Δ pressão obtida   (payload c/ ruído) : %+8.3f hPa", obtainedDelta))
    rep.line(String(format: "  erro                                  : %+8.3f hPa  (%+.1f%%)", errAbs, errPct))
    rep.line(String(format: "  tolerância                            :  %7.3f hPa  → %@",
                    pressureToleranceHpa, passed ? "PASS ✅" : "FALHOU ❌"))
    rep.line(String(format: "  (contexto) Δ pressão do cenário completo: %+7.3f hPa", fullDelta))
    rep.line(String(format: "  altitude estimada (payload)           : %+8.2f m   (negativo = desceu)", p.altitudeChangeM))

    // ── Ancoragem: onde o baseline DEVERIA estar vs onde ficou ──
    // Ground-truth da transição = [1.ª fase "Entrada…" → 1.ª fase "Estacionado…"].
    // O pico legítimo pode cair em qualquer ponto dessa janela (a rampa dura vários
    // segundos), com uma margem. O pico é `bestTimestampMs`; o baseline é `startTs`.
    let entryMs   = sim.phaseBounds.first { $0.name.hasPrefix("Entrada") }?.startMs
    let parkedMs  = sim.phaseBounds.first { $0.name.hasPrefix("Estacionado") }?.startMs
    let entrySec  = entryMs.map  { Int(($0 - base) / 1000) }
    let parkedSec = parkedMs.map { Int(($0 - base) / 1000) }
    let peakSec   = scoring.bestTimestampMs.map { Int(($0 - base) / 1000) }
    let baseSec   = Int((startTs - base) / 1000)

    rep.line("\n── Ancoragem do baseline (detetado vs transição real no parque) ──")
    if let e = entrySec, let pk = parkedSec {
        rep.line(String(format: "  transição real (entrada→estacionado)  : %5ds → %5ds", e, pk))
    } else if let e = entrySec {
        rep.line(String(format: "  entrada real no parque (ground-truth) : %5ds", e))
    } else {
        rep.line("  transição real (ground-truth)         :   n/d (sem fase 'Entrada')")
    }
    if let pk = peakSec {
        let d = entrySec.map { pk - $0 }
        rep.line(String(format: "  pico da variação detetado             : %5ds%@", pk,
                        d.map { String(format: "   (%+ds vs entrada)", $0) } ?? ""))
    } else {
        rep.line("  pico da variação detetado             :   n/d (nenhum tick passou o gate)")
    }
    let dBase = entrySec.map { baseSec - $0 }
    rep.line(String(format: "  baseline (início da janela) detetado  : %5ds%@", baseSec,
                    dBase.map { String(format: "   (%+ds vs entrada)", $0) } ?? ""))

    // Ancoragem correta = o BASELINE (início da janela) cai junto ao momento real
    // da transição (rua → entrada do parque): entre `lead` antes e `lag` depois.
    let anchorOk: Bool
    if let e = entrySec {
        let lo = e - baselineLeadMaxS
        let hi = e + baselineLagMaxS
        anchorOk = baseSec >= lo && baseSec <= hi
        rep.line(String(format: "  → baseline %+ds vs entrada (ok [%+ds..%+ds])  → %@",
                        baseSec - e, -baselineLeadMaxS, baselineLagMaxS,
                        anchorOk ? "ANCORAGEM OK ✅" : "MAL-ANCORADO ❌"))
    } else {
        anchorOk = false
    }

    return ScenarioResult(title: title, expectedDelta: expectedDelta,
                          obtainedDelta: obtainedDelta, passed: passed,
                          note: passed ? "" : String(format: "erro %+.3f hPa", errAbs),
                          entrySec: entrySec, baseSec: baseSec, peakSec: peakSec, anchorOk: anchorOk)
}

// Despeja as amostras cruas geradas (1 Hz) — o que cada sensor "viu" por segundo.
// GPS, pressão e magnetómetro partilham a mesma grelha temporal (uma amostra/seg),
// por isso alinham-se por índice.
func dumpRawSamples(_ window: SensorWindow, base: Int64, into rep: Reporter) {
    rep.line("\n── Amostras geradas (1 Hz) — dados crus por segundo ──")
    rep.line("   s   speed    acc  sig    press      mag")
    let n = window.gpsReadings.count
    for i in 0..<n {
        let g = window.gpsReadings[i]
        let s = (g.timestampMs - base) / 1000
        let press = i < window.pressureReadings.count ? Double(window.pressureReadings[i].hPa) : 0
        let mag   = i < window.magneticReadings.count ? window.magneticReadings[i].magnitude : 0
        rep.line(String(format: "%4lld %7.2f %6.1f  %3@ %8.2f %8.2f",
                        s, g.speedMps, Double(g.accuracyMeters),
                        g.hasSignal ? "sim" : "não", press, mag))
    }
}

func printPayload(_ p: SensorPayload, into rep: Reporter) {
    rep.line("\n── Payload (features enviadas à API de classificação) ──")
    rep.line(String(format: "  gnss_accuracy_mean   : %.2f m", p.gpsAccuracyMean))
    rep.line(String(format: "  gnss_accuracy_delta  : %.2f m", p.gpsAccuracyDelta))
    rep.line(String(format: "  gnss_lost_ratio      : %.2f  (%.0f%% sem sinal)", p.gpsLostRatio, p.gpsLostRatio*100))
    rep.line(String(format: "  pressure_hpa (final) : %.2f hPa", p.pressureHpa))
    rep.line(String(format: "  pressure_delta       : %.3f hPa  (inicial − final)", p.pressureDeltaHpa))
    rep.line(String(format: "  pressure_variance    : %.4f", p.pressureVariance))
    rep.line(String(format: "  altitude_delta       : %.2f m   (negativo = desceu)", p.altitudeChangeM))
    rep.line(String(format: "  magnetic_field_mean  : %.2f µT", p.magneticFieldMean))
    rep.line(String(format: "  magnetic_field_delta : %.2f µT", p.magneticFieldDelta))
    rep.line(String(format: "  magnetic_variance    : %.2f", p.magneticFieldVariance))
    rep.line(String(format: "  window_duration_s    : %.0f s", p.windowDurationS))
}

// ── Main ─────────────────────────────────────────────────────────────────────
// Usa @main (em vez de código solto no top-level) porque este ficheiro é
// compilado em conjunto com outros — só um main.swift aceitaria statements soltos.
@main
struct TrajectorySimulatorMain {
    static func main() { runAll() }
}

func runAll() {
    let rep = Reporter()
    rep.line("# Trajectory Simulator — Report")
    rep.line("Gerado em: \(Date().iso8601)")
    rep.line("Reutiliza o código de produção (SensorScore.computeScore + SensorWindow.toPayload).")
    rep.line("Δ pressão: 'esperada' = curva sem ruído sobre a janela recortada; 'obtida' = payload com ruído.")

    let results = [
        runScenario("CENÁRIO A — Porto → estacionamento → DESCE ao piso -1", scenarioDown1,   seed: 42,  into: rep),
        runScenario("CENÁRIO B — Porto → estacionamento → SOBE ao piso 3",   scenarioUp3,     seed: 99,  into: rep),
        runScenario("CENÁRIO C — Porto → estacionamento → DESCE ao piso -3", scenarioDown3,   seed: 7,   into: rep),
        runScenario("CENÁRIO D — Porto → estacionamento → SOBE ao piso 5",   scenarioUp5,     seed: 123, into: rep),
        runScenario("CENÁRIO E — Porto → parque à SUPERFÍCIE (sem piso)",    scenarioSurface, seed: 314, into: rep),
        runScenario("CENÁRIO F — Porto → estacionamento → SOBE ao piso 2",   scenarioUp2,     seed: 271, into: rep),
        runScenario("CENÁRIO G — rampa CAÓTICA (GPS errático + mag extremo) → piso -2", scenarioNoisyRamp, seed: 555, into: rep),
        runScenario("CENÁRIO H — Avenida → parque à SUPERFÍCIE (sem piso)",           scenarioSurfaceAvenida, seed: 808, into: rep),
        runScenario("CENÁRIO I — SUPERFÍCIE junto a prédio RUIDOSO (falso positivo?)", scenarioSurfaceNoisy,   seed: 616, into: rep),
        runScenario("CENÁRIO J — SOBE ao piso +1 (estrutura aberta / não ruidosa)",   scenarioUp1,            seed: 111, into: rep),
        runScenario("CENÁRIO K — SOBE ao piso +1 (prédio RUIDOSO betão/metal)",       scenarioUp1Noisy,       seed: 222, into: rep),
        runScenario("CENÁRIO L — Trânsito → DESCE ao piso -1 (não ruidoso)",          scenarioDown1Calm,      seed: 333, into: rep),
        runScenario("CENÁRIO M — DESCE ao piso -1 (prédio RUIDOSO)",                  scenarioDown1Noisy,     seed: 444, into: rep),
        runScenario("CENÁRIO N — Avenida → DESCE ao piso -2 (não ruidoso / arejado)", scenarioDown2Calm,      seed: 666, into: rep),
    ]

    // ── Resumo (no fim do report + no terminal) ──────────────────────────────
    let sep = String(repeating: "═", count: 78)
    func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    rep.line("\n\(sep)\n  RESUMO — Δ pressão + ancoragem do baseline\n\(sep)")
    rep.line("  \(pad("cenário", 52))  esperada   obtida   pressão   entrada baseline  ancoragem")
    for r in results {
        let estado = r.passed ? "PASS ✅" : "FALHOU ❌"
        let ent = r.entrySec.map { "\($0)s" } ?? "n/d"
        let bs  = r.baseSec.map { "\($0)s" } ?? "n/d"
        let anc = r.anchorOk ? "OK ✅" : "ERRADA ❌"
        rep.line(String(format: "  %@  %+8.3f  %+8.3f  %@  %6@  %6@   %@",
                        pad(r.title, 52), r.expectedDelta, r.obtainedDelta,
                        pad(estado, 8), ent, bs, anc))
    }

    // Grava o ficheiro e imprime só o resumo no terminal.
    let reportPath = FileManager.default.currentDirectoryPath + "/trajectory_report.md"
    do {
        try rep.write(to: reportPath)
        print("✔ Report escrito em: \(reportPath)\n")
    } catch {
        print("⚠ Falha a escrever o report (\(error)). A imprimir no terminal:\n")
        print(rep.text)
    }

    print("Resumo — Δ pressão + ancoragem do baseline:")
    let passedCount = results.filter { $0.passed }.count
    let anchoredCount = results.filter { $0.anchorOk }.count
    for r in results {
        let mark = r.passed ? "✅" : "❌"
        let anc  = r.anchorOk ? "ancoragem OK" : "ANCORAGEM ERRADA"
        let ent  = r.entrySec.map { "\($0)s" } ?? "n/d"
        let bs   = r.baseSec.map { "\($0)s" } ?? "n/d"
        print(String(format: "  %@ %@  (Δp esp %+.3f / obt %+.3f hPa | entrada %@ vs baseline %@ → %@)",
                     mark, r.title, r.expectedDelta, r.obtainedDelta, ent, bs, anc))
    }
    print("\n\(passedCount)/\(results.count) cenários com Δ pressão na tolerância (\(pressureToleranceHpa) hPa).")
    print("\(anchoredCount)/\(results.count) cenários com baseline junto à entrada real (−\(baselineLeadMaxS)s..+\(baselineLagMaxS)s).")
}
