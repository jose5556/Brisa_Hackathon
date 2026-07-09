import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ScoreCsvRunner
// ─────────────────────────────────────────────────────────────────────────────
// Corre o cálculo de score de PRODUÇÃO (SensorScore.computeScore) sobre um CSV
// de leituras REAIS exportado pela app (diretório Tools/data), imprime o score
// por segundo e mostra onde o algoritmo colocaria o BASELINE (início da janela)
// e o PICO da variação. Compara com o segundo ESPERADO da transição (última
// linha do CSV: "EXPECTED <n>").
//
// Reutiliza EXATAMENTE o código de produção (SensorData.swift + SensorScore.swift).
//
// Formato do CSV (cabeçalho na 1.ª linha):
//   elapsed_s,timestamp,pressure_hpa,gps_accuracy_m,gps_speed_mps,mag_ut
// Última linha (fora do cabeçalho de dados):
//   EXPECTED <segundo>
//
// Compilar e correr (a partir de app/IOS/swift):
//   swiftc Tools/ScoreCsvRunner.swift \
//          Sources/data/SensorData.swift \
//          Sources/sensor/SensorScore.swift \
//          -o /tmp/brisa-csv && /tmp/brisa-csv Tools/data/<ficheiro>.csv
// ─────────────────────────────────────────────────────────────────────────────

struct ParsedCsv {
    let window: SensorWindow
    let expectedSec: Int?      // segundo da transição esperada (linha EXPECTED)
    let baseMs: Int64          // timestamp do 1.º segundo (referência p/ imprimir "s")
    let rows: Int
}

// Constrói uma leitura magnética a partir da magnitude escalar do CSV.
// MagneticReading calcula |v| = √(x²+y²+z²); pondo x = mag e y=z=0 → |v| = mag.
func magReadingFromMagnitude(_ mag: Double, timestampMs: Int64) -> MagneticReading {
    MagneticReading(x: mag, y: 0, z: 0, timestampMs: timestampMs)
}

func parseCsv(_ path: String) -> ParsedCsv? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write("⚠ Não consegui ler o ficheiro: \(path)\n".data(using: .utf8)!)
        return nil
    }
    let lines = content.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else { return nil }

    var gps:  [GpsReading]      = []
    var pres: [PressureReading] = []
    var mag:  [MagneticReading] = []
    var expectedSec: Int? = nil
    var baseMs: Int64? = nil

    // Base epoch arbitrária (reprodutível) — só interessa a diferença em segundos.
    let epochBase: Int64 = 1_700_000_000_000

    for (i, raw) in lines.enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if i == 0 && line.lowercased().hasPrefix("elapsed_s") { continue }   // cabeçalho

        if line.uppercased().hasPrefix("EXPECTED") {
            let parts = line.split(separator: " ")
            if parts.count >= 2 { expectedSec = Int(parts[1]) }
            continue
        }

        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // elapsed_s, timestamp, pressure_hpa, gps_accuracy_m, gps_speed_mps, mag_ut
        guard cols.count >= 6,
              let elapsed = Double(cols[0]),
              let pressure = Double(cols[2]),
              let acc = Double(cols[3]),
              let speed = Double(cols[4]),
              let magUt = Double(cols[5]) else { continue }

        let t = epochBase + Int64(elapsed * 1000)
        if baseMs == nil { baseMs = t }

        // hasSignal não vem no CSV. Heurística: há sinal quando a precisão GPS é
        // válida (> 0). Nestas capturas paradas a precisão é ~5 m → sinal presente.
        let hasSignal = acc > 0

        gps.append(GpsReading(
            latitude: 0, longitude: 0,
            accuracyMeters: Float(acc), altitudeMeters: 0,
            speedMps: speed, hasSignal: hasSignal, timestampMs: t
        ))
        pres.append(PressureReading(hPa: Float(pressure), timestampMs: t))
        mag.append(magReadingFromMagnitude(magUt, timestampMs: t))
    }

    guard !gps.isEmpty, let base = baseMs else { return nil }
    return ParsedCsv(
        window: SensorWindow(gpsReadings: gps, pressureReadings: pres, magneticReadings: mag),
        expectedSec: expectedSec, baseMs: base, rows: gps.count
    )
}

@main
struct ScoreCsvRunnerMain {
    static func main() {
        let args = CommandLine.arguments
        let path = args.count >= 2
            ? args[1]
            : "Tools/data/brisa_sensor_data_1783611218.csv"

        guard let parsed = parseCsv(path) else {
            print("⚠ Falha a interpretar o CSV.")
            exit(1)
        }
        let base = parsed.baseMs
        let window = parsed.window

        print("# Score sobre dados REAIS — \(path)")
        print("Amostras: \(parsed.rows)  (GPS/pressão/mag a 1 Hz)")
        if let e = parsed.expectedSec {
            print("Transição ESPERADA: segundo \(e)")
        } else {
            print("Transição ESPERADA: (não indicada)")
        }

        let scoring = window.computeScore()

        // ── Tabela por segundo ────────────────────────────────────────────────
        print("\n── Score por segundo ──")
        print("   s   gate  clean     dAcc     dSpd     dMag   dPress     raw  score    rec  wscore")
        for tick in scoring.ticks {
            let s = (tick.timestampMs - base) / 1000
            print(String(format: "%4lld %6@ %6@ %8.2f %8.2f %8.2f %8.3f %7.2f %6.2f  %5.2f %6.2f",
                         s, tick.gated ? "sim" : "não", tick.clean ? "sim" : "NÃO",
                         tick.dAcc, tick.dSpeed, tick.dMag, tick.dPress,
                         tick.rawScore, tick.score, tick.recency, tick.weightedScore))
        }

        // ── Onde o algoritmo colocaria baseline/pico ─────────────────────────
        print("\n── Decisão do algoritmo ──")
        if let best = scoring.bestTimestampMs, let start = scoring.windowStartMs {
            let peakSec = (best  - base) / 1000
            let baseSec = (start - base) / 1000
            print(String(format: "  PICO da variação   : segundo %lld  (wscore=%.2f)", peakSec, scoring.bestScore))
            print(String(format: "  BASELINE (início)  : segundo %lld", baseSec))
            if let e = parsed.expectedSec {
                print(String(format: "  ESPERADO           : segundo %d", e))
                print(String(format: "  desvio baseline    : %+lld s   |   desvio pico: %+lld s",
                             baseSec - Int64(e), peakSec - Int64(e)))
            }
        } else {
            print("  ⚠ Nenhum tick passou o gate (rua) → sem baseline/pico.")
            print("    Todos os scores ficaram a 0. Causa provável: gps_speed_mps = 0")
            print("    em toda a captura, logo o gate `speed > minSpeedMps` nunca ativa.")
        }
    }
}
