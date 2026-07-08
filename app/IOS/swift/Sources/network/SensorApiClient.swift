import Foundation

// ── Configuration ─────────────────────────────────────
// O IP do servidor é editável em runtime (ecrã de configuração) e
// guardado em UserDefaults. Exemplos de valores válidos:
//   127.0.0.1        → Emulator / simulator
//   172.20.10.8      → iPhone físico na mesma Wi-Fi do PC
//   100.121.113.91   → default
enum ServerConfig {
    private static let ipKey = "server_ip"

    /// IP usado por defeito quando nada foi configurado.
    static let defaultIP = "100.121.113.91"
    static let port = 8000

    /// IP do servidor persistido em UserDefaults.
    static var ip: String {
        get { UserDefaults.standard.string(forKey: ipKey) ?? defaultIP }
        set { UserDefaults.standard.set(newValue, forKey: ipKey) }
    }

    /// URL base construído a partir do IP configurado (ex: "http://127.0.0.1:8000/").
    static var baseURL: String { "http://\(ip):\(port)/" }

    /// URL base para um IP arbitrário (usado para testar a ligação sem gravar).
    static func baseURL(for ip: String) -> String { "http://\(ip):\(port)/" }
}

// ── Errors ────────────────────────────────────────────
enum SensorApiError: Error, LocalizedError {
    case invalidURL
    case encodingFailed
    case httpError(statusCode: Int)
    case decodingFailed(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:               return "Invalid server URL."
        case .encodingFailed:           return "Failed to encode request payload."
        case .httpError(let code):      return "Server returned HTTP \(code)."
        case .decodingFailed(let e):    return "Failed to decode response: \(e.localizedDescription)"
        case .networkError(let e):      return "Network error: \(e.localizedDescription)"
        }
    }
}

// ── Response model ─────────────────────────────────────
struct PredictionResponse: Decodable, Equatable {
    let sessionId: String
    let payloadId: String
    let inferenceId: String?
    let ml1Classification: String
    let ml1NonStreetConfidence: Double
    let distanceToZoneM: Double?
    let finalDecision: String
    let confidenceToCharge: Double
    let spatialAbortReason: String?

    enum CodingKeys: String, CodingKey {
        case sessionId              = "session_id"
        case payloadId              = "payload_id"
        case inferenceId            = "inference_id"
        case ml1Classification      = "ml1_classification"
        case ml1NonStreetConfidence = "ml1_non_street_confidence"
        case distanceToZoneM        = "distance_to_zone_m"
        case finalDecision          = "final_decision"
        case confidenceToCharge     = "confidence_to_charge"
        case spatialAbortReason     = "spatial_abort_reason"
    }
}

// ── Feedback model ─────────────────────────────────────
// Enviado para /feedback depois de o utilizador validar a decisão
// devolvida por /parking-events/analyze.
enum FeedbackVerdict: String, Codable {
    case correct
    case incorrect
}

struct FeedbackRequest: Encodable {
    let payloadId: String
    let sessionId: String
    let feedback: FeedbackVerdict

    enum CodingKeys: String, CodingKey {
        case payloadId = "payload_id"
        case sessionId = "session_id"
        case feedback
    }
}

// ── Client singleton ───────────────────────────────────
final class SensorApiClient {

    static let shared = SensorApiClient()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 20
        config.timeoutIntervalForResource = 30

        session = URLSession(configuration: config)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    // ── checkDbHealth ──────────────────────────────────
    // Teste rápido: GET /db/health e imprime o retorno no console.
    // Devolve `true` se o endpoint respondeu com um código 2xx.
    // `ipOverride` permite testar um IP sem o gravar em ServerConfig.
    @discardableResult
    func checkDbHealth(ipOverride: String? = nil) async -> Bool {
        let base = ipOverride.map(ServerConfig.baseURL(for:)) ?? ServerConfig.baseURL
        guard let url = URL(string: base + "db/health") else {
            print("[DB Health] URL inválido")
            return false
        }

        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<sem corpo>"
            print("[DB Health] HTTP \(code) → \(body)")
            return (200...299).contains(code)
        } catch {
            print("[DB Health] Erro: \(error.localizedDescription)")
            return false
        }
    }

    // ── predictVerticalContext ─────────────────────────
    func predictVerticalContext(
        payload: SensorPayload
    ) async throws -> PredictionResponse {

        guard let url = URL(string: ServerConfig.baseURL + "parking-events/analyze") else {
            throw SensorApiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            throw SensorApiError.encodingFailed
        }

        #if DEBUG
        if let body = request.httpBody,
           let json = String(data: body, encoding: .utf8) {
            print("[SensorApiClient] → POST /parking-events/analyze\n\(json)")
        }
        #endif

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SensorApiError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            #if DEBUG
            print("[SensorApiClient] ← HTTP \(http.statusCode)")
            if let json = String(data: data, encoding: .utf8) { print(json) }
            #endif

            guard (200...299).contains(http.statusCode) else {
                throw SensorApiError.httpError(statusCode: http.statusCode)
            }
        }

        do {
            return try decoder.decode(PredictionResponse.self, from: data)
        } catch {
            throw SensorApiError.decodingFailed(error)
        }
    }

    // ── sendFeedback ───────────────────────────────────
    // Envia o veredicto do utilizador (correto/incorreto) sobre a decisão de
    // cobrança para POST /feedback. Não devolve corpo — só valida o código HTTP.
    func sendFeedback(
        payloadId: String,
        sessionId: String,
        feedback: FeedbackVerdict
    ) async throws {

        guard let url = URL(string: ServerConfig.baseURL + "feedback") else {
            throw SensorApiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = FeedbackRequest(payloadId: payloadId,
                                   sessionId: sessionId,
                                   feedback: feedback)
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw SensorApiError.encodingFailed
        }

        #if DEBUG
        if let httpBody = request.httpBody,
           let json = String(data: httpBody, encoding: .utf8) {
            print("[SensorApiClient] → POST /feedback\n\(json)")
        }
        #endif

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SensorApiError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            #if DEBUG
            print("[SensorApiClient] ← HTTP \(http.statusCode)")
            if let json = String(data: data, encoding: .utf8) { print(json) }
            #endif

            guard (200...299).contains(http.statusCode) else {
                throw SensorApiError.httpError(statusCode: http.statusCode)
            }
        }
    }
}

// ── Usage example ──────────────────────────────────────
/*
// 1. Acumula leituras durante a janela de observacao (ex: 15 segundos)
var window = SensorWindow()
window.gpsReadings.append(GpsReading(
    latitude: 38.7169, longitude: -9.1395,
    accuracyMeters: 8.0, altitudeMeters: 42.0,
    speedMps: 1.2, hasSignal: true
))
window.pressureReadings.append(PressureReading(hPa: 1012.3))
window.magneticReadings.append(MagneticReading(x: 22.1, y: -14.3, z: 38.5))

// 2. Extrai features e envia
Task {
    guard let payload = FeatureExtractor.extract(window: window) else {
        print("GPS readings insuficientes")
        return
    }
    do {
        let result = try await SensorApiClient.shared.predictVerticalContext(payload: payload)
        print("Classification : \(result.ml1Classification)")
        print("Decision       : \(result.finalDecision)")
        print("Confidence     : \(result.ml1NonStreetConfidence)")
    } catch {
        print("Erro: \(error.localizedDescription)")
    }
}
*/
