import Foundation

struct SensorPayload: Codable {

    // Coordenadas do estacionamento
    let latitude: Double
    let longitude: Double

    // GPS / GNSS
    let gpsAccuracyMean: Double
    let gpsAccuracyMax: Double
    let gpsAccuracyDelta: Double
    let gpsLostRatio: Double

    // Velocidade
    let gpsSpeedMean: Double
    let gpsSpeedMax: Double

    // Barómetro
    let pressureDelta: Double
    let pressureSlope: Double

    // Movimento
    let stationaryRatio: Double

    // Altitude
    let altitudeDelta: Double
    let verticalChangeAbs: Double

    // Magnetómetro
    let magneticFieldMean: Double
    let magneticFieldMax: Double
    let magneticFieldDelta: Double
    let magneticFieldVariance: Double

    enum CodingKeys: String, CodingKey {

        case latitude
        case longitude

        case gpsAccuracyMean = "gps_accuracy_mean"
        case gpsAccuracyMax = "gps_accuracy_max"
        case gpsAccuracyDelta = "gps_accuracy_delta"
        case gpsLostRatio = "gps_lost_ratio"

        case gpsSpeedMean = "gps_speed_mean"
        case gpsSpeedMax = "gps_speed_max"

        case pressureDelta = "pressure_delta"
        case pressureSlope = "pressure_slope"

        case stationaryRatio = "stationary_ratio"

        case altitudeDelta = "altitude_delta"
        case verticalChangeAbs = "vertical_change_abs"

        case magneticFieldMean = "magnetic_field_mean"
        case magneticFieldMax = "magnetic_field_max"
        case magneticFieldDelta = "magnetic_field_delta"
        case magneticFieldVariance = "magnetic_field_variance"
    }
}

// 
struct SensorWindow {

    var gpsReadings: [GpsReading] = []

    var pressureReadings: [PressureReading] = []

    var motionSamples: [MotionSample] = []

    var magneticReadings: [MagneticReading] = []
}


// Dados Uteis do gps.
struct GpsReading {

    let latitude: Double

    let longitude: Double

    let accuracyMeters: Float

    let altitudeMeters: Double

    let speedMps: Double

    let hasSignal: Bool

    let timestampMs: Int64

    init(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Float,
        altitudeMeters: Double,
        speedMps: Double,
        hasSignal: Bool,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.altitudeMeters = altitudeMeters
        self.speedMps = speedMps
        self.hasSignal = hasSignal
        self.timestampMs = timestampMs
    }
}

// Barómetro
struct PressureReading {

    let hPa: Float

    let timestampMs: Int64

    init(
        hPa: Float,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.hPa = hPa
        self.timestampMs = timestampMs
    }
}

struct MotionSample {

    let ax: Float

    let ay: Float

    let az: Float

    let timestampMs: Int64

    init(
        ax: Float,
        ay: Float,
        az: Float,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.ax = ax
        self.ay = ay
        self.az = az
        self.timestampMs = timestampMs
    }
}


struct MagneticReading {

    let x: Double

    let y: Double

    let z: Double

    let magnitude: Double

    let timestampMs: Int64

    init(
        x: Double,
        y: Double,
        z: Double,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {

        self.x = x
        self.y = y
        self.z = z

        self.magnitude = sqrt(
            x * x +
            y * y +
            z * z
        )

        self.timestampMs = timestampMs
    }
}