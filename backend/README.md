# Vertical Context Backend

This backend predicts whether a sensor window corresponds to a street-level or non-street context using a trained Random Forest model.

## Requirements

- Python 3.11+
- Docker Compose (for the PostgreSQL database)
- A working virtual environment in `backend/venv`

## Fastest setup with Makefile

From the project root:

```bash
make -C backend venv
make -C backend install
make -C backend up
make -C backend train
```

From inside the backend folder:

```bash
make venv
make install
make up
make train
```

## Run the API

From the backend folder, use the Makefile target:

```bash
make api
```

If you are at the project root instead, use:

```bash
make -C backend api
```

This starts the FastAPI server on:

- http://localhost:8000/health
- http://localhost:8000/docs

If you prefer to run it manually, use:

```bash
PYTHONPATH=/home/cereais/workspace/seame/Hackathon/Brisa_Hackathon/backend \
/home/cereais/workspace/seame/Hackathon/Brisa_Hackathon/backend/venv/bin/python -m uvicorn src.main:app --host 127.0.0.1 --port 8000
```

## Run the tests

From the backend folder:

```bash
make test
```

From the project root:

```bash
make -C backend test
```

## Test the database connection

```bash
make db-test
```

## If the virtual environment is broken

If `pip` fails with “required file not found”, recreate the environment:

```bash
cd backend
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

with a JSON body like this:

```json
{
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
}
```
