import Foundation
import CoreLocation
import CoreMotion

// ── SensorCollector ───────────────────────────────────
// Dois modos de operação:
//
// 1. CONTÍNUO:
//    collector.startContinuous(windowSizeMs: 30_000)
//    collector.getCurrentWindow()
//    collector.stopContinuous()
//
// 2. JANELA ÚNICA:
//    collector.startWindow()
//    collector.stopAndGetWindow()
//
// Sensores activos:
//   GPS        → CLLocationManager
//   Barómetro  → CMAltimeter
//   Magnetómetro → CMMotionManager.magneticField
//
// Comentado (não utilizado por agora):
//   Acelerómetro → allMotionSamples / MotionSample

final class SensorCollector: NSObject {

    // ── Buffers deslizantes ───────────────────────────
    private var allGpsReadings:      [GpsReading]      = []
    private var allPressureReadings: [PressureReading] = []
    private var allMagneticReadings: [MagneticReading] = []
    // private var allMotionSamples: [MotionSample] = []   // acelerómetro — desativado

    private let lock = NSLock()

    private var windowSizeMs: Int64 = 30_000
    private var isRunning = false

    // ── CLLocationManager (GPS) ───────────────────────
    private let locationManager = CLLocationManager()

    // ── CMMotionManager (magnetómetro) ────────────────
    private let motionManager = CMMotionManager()

    // ── CMAltimeter (barómetro) ───────────────────────
    private let altimeter = CMAltimeter()
    private let altimeterQueue = OperationQueue()

    // ── Timer de limpeza ─────────────────────────────
    private var trimTimer: Timer?

    // ── Init ──────────────────────────────────────────
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter  = 5   // atualiza a cada 5 metros
    }

    // ─────────────────────────────────────────────────
    // MARK: - API pública — modo contínuo
    // ─────────────────────────────────────────────────

    func startContinuous(windowSizeMs: Int64 = 30_000) {
        guard !isRunning else { return }
        self.windowSizeMs = windowSizeMs
        isRunning = true

        startGps()
        startBarometer()
        startMagnetometer()
        startTrimTimer()

        print("[SensorCollector] Modo contínuo iniciado (janela = \(windowSizeMs)ms)")
    }

    /// Snapshot thread-safe da janela deslizante actual.
    func getCurrentWindow() -> SensorWindow {
        let cutoff = nowMs() - windowSizeMs
        lock.lock()
        defer { lock.unlock() }

        return SensorWindow(
            gpsReadings:      allGpsReadings.filter      { $0.timestampMs >= cutoff },
            pressureReadings: allPressureReadings.filter { $0.timestampMs >= cutoff },
            magneticReadings: allMagneticReadings.filter { $0.timestampMs >= cutoff }
            // motionSamples: allMotionSamples.filter { $0.timestampMs >= cutoff }   // desativado
        )
    }

    func stopContinuous() {
        guard isRunning else { return }
        isRunning = false

        stopGps()
        stopBarometer()
        stopMagnetometer()
        trimTimer?.invalidate()
        trimTimer = nil

        print("[SensorCollector] Modo contínuo parado")
    }

    // ─────────────────────────────────────────────────
    // MARK: - API pública — modo janela única
    // ─────────────────────────────────────────────────

    func startWindow() {
        startContinuous()
    }

    func stopAndGetWindow() -> SensorWindow {
        let window = getCurrentWindow()
        stopContinuous()
        return window
    }

    // ─────────────────────────────────────────────────
    // MARK: - GPS / CLLocationManager
    // ─────────────────────────────────────────────────

    private func startGps() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            print("[SensorCollector] Permissão de localização negada")
        }
    }

    private func stopGps() {
        locationManager.stopUpdatingLocation()
    }

    // ─────────────────────────────────────────────────
    // MARK: - Barómetro / CMAltimeter
    // ─────────────────────────────────────────────────

    private func startBarometer() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("[SensorCollector] Barómetro não disponível neste dispositivo")
            return
        }

        altimeter.startRelativeAltitudeUpdates(to: altimeterQueue) { [weak self] data, error in
            guard let self, let data, error == nil else { return }

            // CMAltimeter devolve pressão em kPa — convertemos para hPa (× 10)
            let hPa = Float(data.pressure.doubleValue * 10.0)

            self.lock.lock()
            self.allPressureReadings.append(PressureReading(hPa: hPa))
            self.lock.unlock()
        }
    }

    private func stopBarometer() {
        altimeter.stopRelativeAltitudeUpdates()
    }

    // ─────────────────────────────────────────────────
    // MARK: - Magnetómetro / CMMotionManager
    // ─────────────────────────────────────────────────
    // Usa deviceMotion para obter o campo magnético calibrado.
    // O acelerómetro está comentado — só guardamos MagneticReading.

    private func startMagnetometer() {
        guard motionManager.isDeviceMotionAvailable else {
            print("[SensorCollector] DeviceMotion não disponível")
            return
        }

        motionManager.deviceMotionUpdateInterval = 0.1   // 10 Hz

        motionManager.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: .main
        ) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }

            let now = self.nowMs()

            // ── Magnetómetro ──────────────────────────
            let mx = motion.magneticField.field.x
            let my = motion.magneticField.field.y
            let mz = motion.magneticField.field.z

            // ── Acelerómetro — desativado ─────────────
            // let ax = Float((motion.userAcceleration.x + motion.gravity.x) * 9.81)
            // let ay = Float((motion.userAcceleration.y + motion.gravity.y) * 9.81)
            // let az = Float((motion.userAcceleration.z + motion.gravity.z) * 9.81)

            self.lock.lock()
            self.allMagneticReadings.append(
                MagneticReading(x: mx, y: my, z: mz, timestampMs: now)
            )
            // self.allMotionSamples.append(
            //     MotionSample(ax: ax, ay: ay, az: az, timestampMs: now)
            // )
            self.lock.unlock()
        }
    }

    private func stopMagnetometer() {
        motionManager.stopDeviceMotionUpdates()
    }

    // ─────────────────────────────────────────────────
    // MARK: - Trim periódico
    // ─────────────────────────────────────────────────
    // Remove amostras mais antigas que 2× a janela.

    private func startTrimTimer() {
        trimTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cutoff = self.nowMs() - (self.windowSizeMs * 2)

            self.lock.lock()
            self.allGpsReadings.removeAll      { $0.timestampMs < cutoff }
            self.allPressureReadings.removeAll { $0.timestampMs < cutoff }
            self.allMagneticReadings.removeAll { $0.timestampMs < cutoff }
            // self.allMotionSamples.removeAll { $0.timestampMs < cutoff }   // desativado
            self.lock.unlock()

            print("[SensorCollector] Trim feito — cutoff = \(cutoff)")
        }
    }

    // ─────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// ─────────────────────────────────────────────────────
// MARK: - CLLocationManagerDelegate
// ─────────────────────────────────────────────────────

extension SensorCollector: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let reading = GpsReading(
            latitude:       location.coordinate.latitude,
            longitude:      location.coordinate.longitude,
            accuracyMeters: Float(location.horizontalAccuracy),
            altitudeMeters: location.altitude,
            speedMps:       max(location.speed, 0),   // speed pode ser -1 se inválido no iOS
            hasSignal:      location.horizontalAccuracy >= 0   // accuracy negativa = sinal inválido
        )

        lock.lock()
        allGpsReadings.append(reading)
        lock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Regista leitura sem sinal quando o GPS falha
        let noSignal = GpsReading(
            latitude:       0,
            longitude:      0,
            accuracyMeters: 999,
            altitudeMeters: 0,
            speedMps:       0,
            hasSignal:      false
        )

        lock.lock()
        allGpsReadings.append(noSignal)
        lock.unlock()

        print("[SensorCollector] GPS erro: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isRunning {
            startGps()   // re-tenta após o utilizador conceder permissão
        }
    }
}