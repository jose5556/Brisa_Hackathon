// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

@main
struct TestRunner {
    static func main() {

        // semáforo para manter o processo vivo até a API responder
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            defer { semaphore.signal() }

            // ── dados fake ────────────────────────────
            var window = SensorWindow()

            window.gpsReadings = [
                GpsReading(
                    latitude: 41.14961,
                    longitude: -8.61099,
                    accuracyMeters: 5,
                    altitudeMeters: 120,
                    speedMps: 0,
                    hasSignal: true
                )
            ]

            window.motionSamples = [
                MotionSample(ax: 0.1, ay: 0.2, az: 9.8)
            ]

            window.pressureReadings = [
                PressureReading(hPa: 1013.0),
                PressureReading(hPa: 1012.5)
            ]

            window.magneticReadings = [
                MagneticReading(x: 22.1, y: -14.3, z: 38.5)
            ]

            // ── extrai features ───────────────────────
            guard let payload = FeatureExtractor.extract(window: window) else {
                print("GPS readings insuficientes")
                return
            }

            print("✅ Payload criado:")
            print("   lat: \(payload.latitude), lon: \(payload.longitude)")
            print("   gpsLostRatio: \(payload.gpsLostRatio)")
            print("   stationaryRatio: \(payload.stationaryRatio)")
            print("   pressureDelta: \(payload.pressureDelta)")
            print()

            // ── chama a API ───────────────────────────
            //do {
            //    let result = try await SensorApiClient.shared.predictVerticalContext(payload: payload)
            //    print("✅ Resposta da API:")
            //    print("   classification      : \(result.classification)")
            //    print("   nonStreetConfidence : \(result.nonStreetConfidence)")
            //} catch SensorApiError.networkError(let e) {
            //    print("❌ Servidor inacessível — confirma que está a correr em 172.20.10.8:8000")
            //    print("   Detalhe: \(e.localizedDescription)")
            //} catch {
            //    print("❌ Erro: \(error.localizedDescription)")
            //}
        }

        semaphore.wait()
    }
}
