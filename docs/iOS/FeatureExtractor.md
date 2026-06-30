# iOS FeatureExtractor

## Overview

`FeatureExtractor` is responsible for transforming raw sensor readings collected during an observation window into a structured `SensorPayload` ready to be sent to the ML backend.

It mirrors the architecture of the Android `FeatureExtractor.kt`, keeping all feature calculation logic isolated from the networking layer (`SensorApiClient`).

```
SensorWindow (raw readings)
        |
        v
FeatureExtractor.extract(window:)
        |
        v
SensorPayload (features in snake_case, ready to POST)
        |
        v
SensorApiClient → POST /predict
        |
        v
PredictionResponse { classification, non_street_confidence }
```

---

## Input — SensorWindow

| Field | Type | Description |
|---|---|---|
| `gpsReadings` | `[GpsReading]` | GPS samples with accuracy, altitude, speed, signal status |
| `pressureReadings` | `[PressureReading]` | Barometer samples in hPa with timestamps |
| `motionSamples` | `[MotionSample]` | Accelerometer samples (ax, ay, az) |
| `magneticReadings` | `[MagneticReading]` | Magnetometer samples (x, y, z) |

---

## Output — SensorPayload features

### GPS

| Feature | Calculation | Notes |
|---|---|---|
| `gps_accuracy_mean` | Mean of accuracy values | Only readings with accuracy 0–100m |
| `gps_accuracy_max` | Max accuracy value | Only readings with accuracy 0–100m |
| `gps_accuracy_delta` | Max − Min accuracy | Spread of accuracy during the window |
| `gps_lost_ratio` | Lost readings / total readings | Counts no-signal and accuracy > 100m as lost |
| `gps_speed_mean` | Mean of speed values (m/s) | All GPS readings |
| `gps_speed_max` | Max speed value (m/s) | All GPS readings |

### Altitude

| Feature | Calculation | Notes |
|---|---|---|
| `altitude_delta` | Last altitude − First altitude | Only readings with signal and accuracy < 75m |
| `vertical_change_abs` | Max altitude − Min altitude | More robust to GPS noise than summing consecutive deltas |

### Barometer

| Feature | Calculation | Notes |
|---|---|---|
| `pressure_delta` | Last hPa − First hPa | Raw pressure change across the window |
| `pressure_slope` | Linear regression slope (hPa/s) | Uses real timestamps — more accurate than delta/count |

### Motion

| Feature | Calculation | Notes |
|---|---|---|
| `stationary_ratio` | Stationary samples / total samples | A sample is stationary if `|magnitude − 9.81| < 1.5 m/s²` |

### Magnetometer

| Feature | Calculation | Notes |
|---|---|---|
| `magnetic_field_mean` | Mean of field magnitudes (µT) | Useful for detecting metal structures (underground, elevated garages) |
| `magnetic_field_max` | Max magnitude | |
| `magnetic_field_delta` | Last − First magnitude | Change across the window |
| `magnetic_field_variance` | Sample variance (n−1) | High variance may indicate moving through a metal structure |

---

## Key design decisions

### GPS filtering
Readings with accuracy outside 0–100m are excluded before calculating GPS features. For altitude specifically, the threshold is tightened to 75m because altitude from GPS is noisier than horizontal position.

### `pressure_slope` — linear regression
The slope is computed using ordinary least squares with real timestamps (converted to seconds). This gives a true hPa/s rate even when readings are not evenly spaced in time.

### `vertical_change_abs` — max minus min
Instead of summing consecutive altitude deltas, we use `max − min`. GPS altitude is noisy, and summing deltas would accumulate noise artificially, making a stationary car appear to have significant vertical movement.

### `stationary_ratio` — threshold of 1.5 m/s²
A sample is considered stationary when the net acceleration (after removing gravity) is below 1.5 m/s². This threshold tolerates the natural noise of a real accelerometer at rest. A threshold of 0.15 m/s² is too strict and would classify most resting samples as moving.

---

## What is not available on iOS

Wi-Fi scanning is blocked by Apple without special entitlements. As a result, the following features from the Android model are not collected on iOS and are absent from the iOS payload:

| Feature | Reason |
|---|---|
| `wifi_count_mean` | `WifiManager` equivalent not available |
| `wifi_count_delta` | Same |
| `wifi_rssi_mean` | Same |
| `ble_count_mean` | Not yet implemented (possible via `CoreBluetooth`) |
| `ble_count_delta` | Same |
| `ble_rssi_mean` | Same |

The ML backend receives these as absent fields. The model will still classify, but with less signal in those dimensions.

---

## Usage example

```swift
var window = SensorWindow()

window.gpsReadings.append(GpsReading(
    latitude: 41.14961, longitude: -8.61099,
    accuracyMeters: 5, altitudeMeters: 120,
    speedMps: 0, hasSignal: true
))
window.pressureReadings.append(PressureReading(hPa: 1013.0))
window.pressureReadings.append(PressureReading(hPa: 1012.5))
window.motionSamples.append(MotionSample(ax: 0.1, ay: 0.2, az: 9.8))
window.magneticReadings.append(MagneticReading(x: 22.1, y: -14.3, z: 38.5))

guard let payload = FeatureExtractor.extract(window: window) else {
    print("No GPS readings available")
    return
}

let result = try await SensorApiClient.shared.predictVerticalContext(payload: payload)
print("Classification: \(result.classification)")
print("Non-street confidence: \(result.nonStreetConfidence)")
```

---

## Comparison with Android FeatureExtractor

| Aspect | Android | iOS |
|---|---|---|
| Location | `FeatureExtractor.kt` (separate object) | `FeatureExtractor.swift` (separate enum) |
| `pressure_slope` | Linear regression with real timestamps | Linear regression with real timestamps |
| `vertical_change_abs` | Max − Min | Max − Min |
| `stationary_ratio` threshold | 1.5 m/s² | 1.5 m/s² |
| GPS accuracy filter | 0–100m | 0–100m |
| Altitude accuracy filter | < 75m + signal | < 75m + signal |
| Wi-Fi features | Collected | Not available |
| BLE features | Collected | Not yet implemented |
| Magnetometer features | Not collected | Collected |
