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
curl -X POST "http://localhost:8000/parking-events/analyze" \
     -H "Content-Type: application/json" \
     -d '{
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
