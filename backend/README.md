# Vertical Context Backend

This backend predicts whether a sensor window corresponds to a street-level or non-street context using a trained Random Forest model.

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
make api
```

`make api` starts the server over HTTPS by default. It generates a self-signed development certificate in `certs/`.

The server is available on:

- https://localhost:8000/health
- https://localhost:8000/docs

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

## Example prediction request

Send a POST request to:

```http
POST /predict
```

Example for street level:

```bash
curl -X POST http://localhost:8000/parking-events/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "gps_accuracy_mean": 24.0,
    "gps_accuracy_max": 48.0,
    "gps_accuracy_delta": 18.0,
    "gps_lost_ratio": 0.22,
    "wifi_count_mean": 20,
    "wifi_count_delta": 1,
    "wifi_rssi_mean": -62,
    "ble_count_mean": 9,
    "ble_count_delta": 1,
    "ble_rssi_mean": -68,
    "pressure_delta": 0.05,
    "pressure_slope": 0.01,
    "altitude_delta": 0.4,
    "vertical_change_abs": 0.6,
    "stationary_ratio": 0.85
  }'
```

Example for underground:

```bash
curl -k -X POST http://localhost:8000/parking-events/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "gps_accuracy_mean": 67.4,
    "gps_accuracy_max": 108.2,
    "gps_accuracy_delta": 52.8,
    "gps_lost_ratio": 0.81,
    "wifi_count_mean": 4,
    "wifi_count_delta": -8,
    "wifi_rssi_mean": -78,
    "ble_count_mean": 3,
    "ble_count_delta": -6,
    "ble_rssi_mean": -84,
    "pressure_delta": 0.92,
    "pressure_slope": 0.14,
    "altitude_delta": -5.3,
    "vertical_change_abs": 4.9,
    "stationary_ratio": 0.73
  }'
```

After, you can check the latest model anylises with a GET request:

```http
GET /parking-events/latest
```
