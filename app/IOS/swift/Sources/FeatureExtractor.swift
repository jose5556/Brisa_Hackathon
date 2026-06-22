import Foundation

/// Transforma uma SensorWindow (amostras brutas) num SensorPayload pronto a enviar.
///
/// A lógica de cálculo de features vive em `SensorWindow.toPayload(...)` (ver SensorData.swift),
/// que é a única fonte de verdade. Este extractor é apenas um wrapper conveniente
/// para quem prefira a chamada `FeatureExtractor.extract(window:)`.
enum FeatureExtractor {

    /// Retorna nil se não houver nenhuma leitura GPS (mínimo necessário para o modelo).
    ///
    /// - Parameters:
    ///   - window: janela de amostras recolhidas pelos sensores.
    ///   - cityBaselinePressure: pressão de referência da cidade (via WeatherService). 0 se indisponível.
    ///   - weatherCondition: condição meteorológica ("clear" | "rain" | "overcast").
    static func extract(
        window: SensorWindow,
        cityBaselinePressure: Double = 0,
        weatherCondition: String = "clear"
    ) -> SensorPayload? {
        window.toPayload(
            cityBaselinePressure: cityBaselinePressure,
            weatherCondition:     weatherCondition
        )
    }
}
