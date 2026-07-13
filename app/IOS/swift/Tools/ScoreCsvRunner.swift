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
// Compilar e correr (ou usar ./Tools/run_csv.sh, que aceita as mesmas flags):
//   swiftc Tools/ScoreCsvRunner.swift \
//          Sources/data/SensorData.swift \
//          Sources/sensor/SensorScore.swift \
//          Sources/network/SensorApiClient.swift \
//          -o /tmp/brisa-csv && /tmp/brisa-csv Tools/data/<ficheiro>.csv
//
// Flags: [--api] [--ip x.x.x.x]
//   --api envia o payload da janela recortada à API e imprime a resposta.
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
    static func main() async {
        // Argumentos: [caminho.csv] [--api] [--ip x.x.x.x]
        let args = CommandLine.arguments
        var path = "Tools/data/above.csv"
        var useApi = false
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--api":
                useApi = true
            case "--ip":
                i += 1
                guard i < args.count else { print("⚠ --ip requer um valor"); exit(1) }
                ServerConfig.ip = args[i]
            default:
                guard !args[i].hasPrefix("--") else {
                    print("⚠ argumento desconhecido: \(args[i])")
                    print("  uso: [caminho.csv] [--api] [--ip x.x.x.x]")
                    exit(1)
                }
                path = args[i]
            }
            i += 1
        }

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

        // ── Envia o payload ao modelo (só com --api) ──────────────────────────
        // Mesma janela que iria para a API em produção: recortada a partir do
        // baseline detetado; sem baseline, cai no fallback (janela completa).
        if useApi {
            let sliced = scoring.windowStartMs.map { window.sliced(fromMs: $0) } ?? window
            guard var payload = sliced.toPayload() else {
                print("\n⚠ Sem payload (janela vazia) — nada enviado à API.")
                return
            }
            // O backend exige `city` (no telemóvel vem do reverse-geocoding do
            // CLGeocoder); nos CSVs não há cidade, por isso usa-se "Porto".
            if payload.city == nil { payload.city = "Porto" }

            print("\n── Payload enviado à API ──")
            print(String(format: "  gnss_accuracy_mean   : %.2f m", payload.gpsAccuracyMean))
            print(String(format: "  gnss_accuracy_delta  : %.2f m", payload.gpsAccuracyDelta))
            print(String(format: "  gnss_lost_ratio      : %.2f", payload.gpsLostRatio))
            print(String(format: "  pressure_hpa (final) : %.2f hPa", payload.pressureHpa))
            print(String(format: "  pressure_delta       : %.3f hPa", payload.pressureDeltaHpa))
            print(String(format: "  altitude_delta       : %.2f m", payload.altitudeChangeM))
            print(String(format: "  magnetic_field_mean  : %.2f µT", payload.magneticFieldMean))
            print(String(format: "  magnetic_field_delta : %.2f µT", payload.magneticFieldDelta))
            print(String(format: "  window_duration_s    : %.0f s", payload.windowDurationS))

            print("\n── Resposta do modelo (POST /parking-events/analyze) ──")
            do {
                let r = try await SensorApiClient.shared.predictVerticalContext(payload: payload)
                print("  ml1_classification    : \(r.ml1Classification)")
                print(String(format: "  non_street_confidence : %.3f", r.ml1NonStreetConfidence))
                print("  final_decision        : \(r.finalDecision)")
                print(String(format: "  confidence_to_charge  : %.3f", r.confidenceToCharge))
                if let reason = r.spatialAbortReason { print("  spatial_abort_reason  : \(reason)") }
            } catch {
                print("  ⚠ falha: \(error.localizedDescription)")
            }
        }
    }
}
