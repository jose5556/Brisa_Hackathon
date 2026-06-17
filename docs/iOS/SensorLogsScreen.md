# Sensor Logs Screen

## Overview

The Sensor Logs screen is a developer tool accessible from the main screen via the **DEV** button in the top-right corner of the header. It is not intended for end users — its purpose is to give the development team full visibility into the data pipeline, from raw sensor readings all the way to the model response, without having to open Xcode or read console output.

The screen uses a terminal-style layout: dark background, monospace font, small text, and two levels of collapsible sections so the developer can focus on the exact layer and sensor they care about at any given moment.

---

## How to Access

```
Main Screen
    └── DEV button (top-right of header)
            └── Sensor Logs Screen
                    └── Back button → returns to Main Screen
```

The DEV button is only visible in development builds. In a production build it should be hidden or removed entirely.

---

## Screen Structure

### Active Sensors Strip

At the top of the logs screen, below the live indicator, there is a row of sensor chips showing which sensors are currently collecting data. Each chip shows:

- The sensor name
- How many readings have been accumulated in the current window
- A green dot if the sensor is active, red if unavailable

On iOS, Wi-Fi appears with a red dot and `N/A` because Apple does not allow programmatic Wi-Fi scanning without special entitlements.

---

### Two-Level Collapsible Structure

The screen has two levels of collapsible content:

- **Level 1 — Pipeline sections**: four top-level sections, one per stage of the data pipeline. Tapping a section header opens or closes the entire section.
- **Level 2 — Sensor sub-groups**: inside each section, the content is further divided by sensor type. Each sub-group can be opened or closed independently.

This means the developer can, for example, keep the RAW section open but collapse GPS and Motion and focus only on the Barometer readings, without losing sight of the other sections.

The four sections follow the exact order of the data pipeline:

```
RAW SENSOR WINDOW
    ├── GPS
    ├── BAROMETER
    ├── MOTION
    └── MAGNETOMETER
          ↓
FEATURE EXTRACTOR
    ├── GPS
    ├── BAROMETER
    ├── MOTION
    ├── ALTITUDE
    └── MAGNETOMETER
          ↓
PAYLOAD SENT
          ↓
MODEL RESPONSE
```

---

#### 1. RAW SENSOR WINDOW

Shows the raw arrays accumulated by the `SensorWindow` during the observation period, before any processing. Each sensor source is a collapsible sub-group.

| Sub-group | What is shown |
|---|---|
| GPS | Latitude and longitude of the last reading, plus the full arrays of accuracy (m), altitude (m), and speed (m/s) |
| Barometer | Full array of pressure readings in hPa |
| Motion | Full arrays of accelerometer samples (ax, ay, az) |
| Magnetometer | Full array of magnetic field magnitudes in µT |

This section is useful for verifying that sensors are actually collecting data and that the values are in a reasonable range before any feature calculation happens.

---

#### 2. Feature Extractor

Shows the output of `FeatureExtractor.extract(window:)` — the computed features derived from the raw sensor window. Each feature group is a collapsible sub-group.

| Sub-group | Features |
|---|---|
| GPS | `gps_accuracy_mean`, `gps_accuracy_max`, `gps_accuracy_delta`, `gps_lost_ratio`, `gps_speed_mean`, `gps_speed_max` |
| Barometer | `pressure_delta`, `pressure_slope` (hPa/s via linear regression) |
| Motion | `stationary_ratio` |
| Altitude | `altitude_delta`, `vertical_change_abs` |
| Magnetometer | `magnetic_field_mean`, `magnetic_field_max`, `magnetic_field_delta`, `magnetic_field_variance` |

This section is useful for catching calculation errors — for example, checking that `stationary_ratio` is close to 1.0 when the phone is resting on a table, or that `pressure_slope` is near zero in a stable environment.

---

#### 3. Payload Sent

Shows the exact JSON body that was sent to the backend in the last request, along with the endpoint URL and the timestamp of the call.

```
POST http://172.20.10.8:8000/predict
{
  "gps_accuracy_mean": 6.25,
  "pressure_delta": -0.60,
  ...
}
```

This section is useful for confirming that the serialization is correct — that field names match what the backend expects (snake_case) and that no field is missing or has an unexpected value.

---

#### 4. Model Response

Shows the history of all predictions made during the session, in reverse chronological order. Each entry shows:

- Timestamp of the call
- HTTP status and latency
- `classification` — the predicted context (`street_level`, `underground`, or `above`)
- `non_street_confidence` — a score from 0 to 1, shown as both a number and a visual bar

The color of the classification value changes based on the result:
- `street_level` — green
- `underground` or `above` — orange

The confidence bar fills left to right. A bar close to 0% means the model is confident the car is on a public street. A bar close to 100% means the model is confident the car is not on a public street and billing should be suppressed.

---

## Live Indicator

The top bar shows a pulsing green dot labeled **LIVE** while the sensor service is running and accumulating data, alongside the current timestamp. If the service is stopped the dot disappears.

---

## CLEAR Button

The **CLEAR** button in the top-right of the logs header resets the prediction history in the Model Response section and clears the last payload display. It does not stop the sensor service or discard the current sensor window.

---

## Design Decisions

**Terminal style** — Small monospace font on a dark background allows more information to fit on screen at once, which is more useful for a developer than a polished consumer UI. The green accent color matches the ViaVerde brand while keeping the terminal aesthetic.

**Two-level collapsible structure** — The screen has collapsible sections at the pipeline level and collapsible sub-groups at the sensor level. This lets the developer drill into exactly the sensor and stage they need without scrolling past irrelevant data. In practice, once raw data and feature extraction are confirmed to be working, those sections stay collapsed during field testing and only the Model Response remains open.

**Wi-Fi shown as inactive** — Even though Wi-Fi data is not available on iOS, the chip is shown in the active sensors strip with a red indicator. This makes it immediately clear to anyone reading the logs that the iOS payload is missing those features, which is relevant when comparing results with Android.

**Arrays shown in full** — The raw sensor window shows the complete arrays, not just summary statistics. This is intentional — a developer debugging a bad prediction needs to see the actual values, not just the mean, to spot outliers or gaps in coverage.
