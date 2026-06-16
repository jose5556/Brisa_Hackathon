import Foundation

// ── Configuration ─────────────────────────────────────
// Emulator / simulator:
// private let baseURL = "http://127.0.0.1:8000/"
//
// Physical iPhone on same Wi-Fi as your PC:
private let baseURL = "http://172.20.10.8:8000/"

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
struct PredictionResponse: Decodable {
    let nonStreetConfidence: Double
    let classification: String

    enum CodingKeys: String, CodingKey {
        case nonStreetConfidence = "non_street_confidence"
        case classification      = "classification"
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

    // ── predictVerticalContext ─────────────────────────
    func predictVerticalContext(
        payload: SensorPayload
    ) async throws -> PredictionResponse {

        guard let url = URL(string: baseURL + "predict") else {
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
            print("[SensorApiClient] → POST /predict\n\(json)")
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
window.motionSamples.append(MotionSample(ax: 0.02, ay: 0.01, az: 9.81))
window.magneticReadings.append(MagneticReading(x: 22.1, y: -14.3, z: 38.5))

// 2. Extrai features e envia
Task {
    guard let payload = FeatureExtractor.extract(window: window) else {
        print("GPS readings insuficientes")
        return
    }
    do {
        let result = try await SensorApiClient.shared.predictVerticalContext(payload: payload)
        print("Classification : \(result.classification)")
        print("Confidence     : \(result.nonStreetConfidence)")
    } catch {
        print("Erro: \(error.localizedDescription)")
    }
}
*/