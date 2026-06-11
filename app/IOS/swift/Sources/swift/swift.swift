// The Swift Programming Language
// https://docs.swift.org/swift-book

@main
struct swift {
    static func main() {

        let gps = GpsReading(
            latitude: 41.14961,
            longitude: -8.61099,
            accuracyMeters: 5,
            altitudeMeters: 120,
            speedMps: 0,
            hasSignal: true
        )

        let motion = MotionSample(ax: 0.1, ay: 0.2, az: 9.8)

        let window = SensorWindow(
            gpsReadings: [gps],
            motionSamples: [motion]
        )

        print(window.gpsReadings.first?.latitude ?? 0)
    }
}
