import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ── WeatherResponse ───────────────────────────────────
// Mapeia a resposta da Open-Meteo API
// Docs: https://open-meteo.com/en/docs
private struct OpenMeteoResponse: Decodable {
    let current: CurrentWeather

    struct CurrentWeather: Decodable {
        let surfacePressure: Double     // pressão ao nível da superfície (hPa)
        let weatherCode: Int            // WMO weather code
        let precipitation: Double       // mm na última hora

        enum CodingKeys: String, CodingKey {
            case surfacePressure = "surface_pressure"
            case weatherCode     = "weather_code"
            case precipitation   = "precipitation"
        }
    }
}

// ── WeatherData ───────────────────────────────────────
// O que o resto da app precisa
struct WeatherData {
    let cityBaselinePressure: Double   // pressão absoluta da cidade (hPa)
    let weatherCondition: String       // "clear" | "rain" | "overcast"
}

// ── WeatherService ────────────────────────────────────
final class WeatherService {

    static let shared = WeatherService()
    private init() {}

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// Busca pressão e condição do tempo para as coordenadas dadas.
    /// Usa Open-Meteo — gratuito, sem chave de API.
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {

        // Constrói URL com os campos que precisamos
        // surface_pressure → cityBaselinePressure
        // weather_code     → weatherCondition
        // precipitation    → ajuda a confirmar chuva
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude",         value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "longitude",        value: String(format: "%.5f", longitude)),
            URLQueryItem(name: "current",          value: "surface_pressure,weather_code,precipitation"),
            URLQueryItem(name: "forecast_days",    value: "1"),
        ]

        guard let url = components.url else {
            throw WeatherServiceError.invalidURL
        }

        #if DEBUG
        print("[WeatherService] → GET \(url)")
        #endif

        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self else { return }

                if let error = error {
                    continuation.resume(throwing: WeatherServiceError.networkError(error))
                    return
                }

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.resume(throwing: WeatherServiceError.httpError(statusCode: http.statusCode))
                    return
                }

                guard let data = data else {
                    continuation.resume(throwing: WeatherServiceError.emptyResponse)
                    return
                }

                #if DEBUG
                if let json = String(data: data, encoding: .utf8) {
                    print("[WeatherService] ← \(json)")
                }
                #endif

                do {
                    let meteo = try self.decoder.decode(OpenMeteoResponse.self, from: data)
                    let result = WeatherData(
                        cityBaselinePressure: meteo.current.surfacePressure,
                        weatherCondition:     self.mapWeatherCode(
                                                code:          meteo.current.weatherCode,
                                                precipitation: meteo.current.precipitation
                                              )
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: WeatherServiceError.decodingFailed(error))
                }
            }.resume()
        }
    }

    // ── WMO weather code → "clear" | "rain" | "overcast" ─
    // Referência: https://open-meteo.com/en/docs#weathervariables
    private func mapWeatherCode(code: Int, precipitation: Double) -> String {
        switch code {
        case 0:                     return "clear"       // céu limpo
        case 1, 2:                  return "clear"       // maioritariamente limpo / parcialmente nublado
        case 3:                     return "overcast"    // nublado
        case 45, 48:                return "overcast"    // nevoeiro
        case 51, 53, 55:            return "rain"        // chuvisco
        case 61, 63, 65:            return "rain"        // chuva
        case 71, 73, 75:            return "rain"        // neve (trata como chuva para o modelo)
        case 80, 81, 82:            return "rain"        // aguaceiros
        case 85, 86:                return "rain"        // aguaceiros de neve
        case 95, 96, 99:            return "rain"        // trovoada
        default:
            // fallback por precipitação medida
            return precipitation > 0.1 ? "rain" : "overcast"
        }
    }
}

// ── Erros ─────────────────────────────────────────────
enum WeatherServiceError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int)
    case emptyResponse
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:               return "URL inválido para Open-Meteo."
        case .networkError(let e):      return "Erro de rede: \(e.localizedDescription)"
        case .httpError(let code):      return "Open-Meteo devolveu HTTP \(code)."
        case .emptyResponse:            return "Resposta vazia da API meteorológica."
        case .decodingFailed(let e):    return "Erro ao descodificar resposta: \(e.localizedDescription)"
        }
    }
}