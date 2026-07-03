## Product Overview

These proposed system aims to support an automatic decision on whether to start a parking charge based on confidence.

### 1. Layer 1: Vertical Context Classifier (ML1)
The backend leverages a supervised **LightGBM** model trained to distinguish three vertical contexts: `street_level`, `underground`, and `above`. 

Internally, the model computes the probability for each class. To evaluate the environment, we compute `non_street_confidence` (the sum of `underground` and `above_ground` probabilities) because in both cases the vehicle is not on a normal street-level public road. If this score is close to `0.0`, the system has high certainty that the vehicle is at street level.

### 2. Layer 2: Spatial Context Service (PostGIS)
Simultaneously, the backend triggers a geospatial query using **PostGIS**. By transforming the mobile coordinates into a `GEOGRAPHY` point (SRID 4326), the database intersects the location against real GeoJSON polygons of active tariff zones (`paid_zones`). It outputs:
* `spatial_in_paid_zone`: A boolean indicating if the vehicle is inside a zone.
* `spatial_dist_to_road_m`: The exact distance in meters to the nearest paid zone boundary..

### 3. Layer 3: Charging Decision Model (ML2)
This is the final decision engine. Instead of using rigid hardcoded thresholds, a second **LightGBM** model evaluates the holistic state of the parking event. It takes as input:
* The vertical risk score from Model 1 (`ml1_non_street_confidence`).
* The distance metrics calculated by PostGIS (`spatial_dist_to_road_m`).
* The telemetry quality of the device (`gnss_accuracy_m`).

The ML2 model acts as a financial gatekeeper, outputting a `final_decision` (`charge` or `no_charge`) along with a `confidence_to_charge` metric.

## Data Engineering and Database Schema

All stages of the inference lifecycle are persisted atomically inside a PostgreSQL database to allow complete audibility, performance tracking, and continuous offline retraining.

* **`users`**: Manages developer and production profiles, enforcing strict constraints like `city_code` (e.g., `OPO`, `LIS`) and RGPD consent versioning.
* **`parking_sessions`**: The core entity tracking the lifecycle of a detected stop event.
* **`sensor_payloads`**: Stores the telemetry window separately to prevent index bloat in main tables and allow historical re-processing.
* **`inference_logs`**: Segregates the mathematical opinion of the models (`ml1_classification`, `ml2_charge_confidence`) from the actual billing state (`final_decision`), ensuring clear metrics for Data Scientists.

## Requirements

- Python 3.11+
- Docker Compose for the PostgreSQL/PostGIS database
- A working virtual environment in `backend/venv`
- OpenSSL if you want to run the API over HTTPS locally

## Fastest setup with Makefile

From inside the backend folder:

```bash
make venv
source venv/bin/activate
make install
make up
make db-init
make train
```

## Run the API

From inside the backend folder, use one of these targets:

```bash
make api-http
```

`make api` starts the server over HTTPS by default. It generates a self-signed development certificate in `certs/`.

The server is available on:

- http://localhost:8000/health
- http://localhost:8000/docs

## Run the tests

From inside the backend folder:

```bash
make test
```

## Database helpers

From inside the backend folder:

```bash
make db-test
make db-init
make db-load-maps
make db-reset
make db-shell
```

`make db-init` loads the schema from `database/schema.sql` into the running database.

## If the virtual environment is broken

If `pip` fails with “required file not found”, recreate the environment:

```bash
rm -rf venv
python3 -m venv venv
source venv/bin/activate
python -m pip install -r requirements.txt
```

## Example parking analysis request

Send a POST request to:

```http
POST /parking-events/analyze
```

Example for street level:

```bash
curl -X POST "http://100.121.113.91:8000/parking-events/analyze" \
     -H "Content-Type: application/json" \
     -d '{
       "city":"OPO",
       "latitude": 41.1579,
       "longitude": -8.6291,
       "gps_accuracy_mean": 5.2,
       "device_os_version": "iOS 17.5",
       "app_version": "1.0.0",
       "window_duration_s": 10.0,
       "pressure_delta": -0.02,
       "altitude_delta": 0.1,
       "gnss_lost_ratio": 0.0,
       "pressure_hpa": 1012.5,
       "pressure_variance": 0.01,
       "magnetic_variance_total": 0.05,
       "magnetic_field_mean": 45.2,
       "magnetic_field_delta": 1.2,
       "gnss_accuracy_m": 5.2,
       "gnss_accuracy_delta": 0.5
     }'
```

Example for underground:

```bash
curl -X POST "http://localhost:8000/parking-events/analyze" \
     -H "Content-Type: application/json" \
     -d '{
       "city":"OPO",
       "latitude": 41.1579,
       "longitude": -8.6291,
       "gnss_accuracy_mean": 85.0,
       "device_os_version": "iOS 17.5",
       "app_version": "1.0.0",
       "window_duration_s": 10.0,
       "pressure_delta": -0.22,
       "altitude_delta": -5.5,
       "gnss_lost_ratio": 0.95,
       "pressure_hpa": 1018.2,
       "pressure_variance": 0.12,
       "mag_variance_total": 0.85,
       "magnetic_field_mean": 115.0,
       "magnetic_field_delta": 14.5,
       "gnss_accuracy_m": 85.0,
       "gnss_accuracy_delta": 45.0
     }'
```

After, you can check the latest model anylises with a GET request:

```http
GET /parking-events/latest
```
