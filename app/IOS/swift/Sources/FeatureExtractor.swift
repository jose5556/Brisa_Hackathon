import Foundation

/// Transforma uma SensorWindow (amostras brutas) num SensorPayload pronto a enviar.
///
/// A lógica de cálculo de features vive em `SensorWindow.toPayload(...)` (ver SensorData.swift),
/// que é a única fonte de verdade. Este extractor é apenas um wrapper conveniente
/// para quem prefira a chamada `FeatureExtractor.extract(window:)`.
enum FeatureExtractor {

    /// Retorna nil se não houver nenhuma leitura GPS (mínimo necessário para o modelo).
    ///
    /// - Parameter window: janela de amostras recolhidas pelos sensores.
    static func extract(window: SensorWindow) -> SensorPayload? {
        window.toPayload()
    }
}
