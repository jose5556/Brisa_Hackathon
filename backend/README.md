# Vertical Context Backend

This backend predicts whether a sensor window corresponds to a street-level or non-street context using a trained Random Forest model.

## Requirements

- Python 3.11+
- A virtual environment in `backend/venv`

## Setup

1. Go to the backend folder:
   ```bash
   cd backend
   ```

2. Create and activate a virtual environment:
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   ```

3. Install the dependencies:
   ```bash
   python -m pip install -r requirements.txt
   ```

## Train the model

Run this once before using predictions:

```bash
python scripts/train_model.py
```

This saves the model to:

```text
backend/models/vertical_context_rf.joblib
```

## Run the API

Start the FastAPI server with:

```bash
uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload
```

You can then open:

- http://localhost:8000/health
- http://localhost:8000/docs

## Run the tests

Run the prediction tests with:

```bash
python -m pytest ../tests/test_vertical_ml_predict.py
```

If the virtual environment is broken and `pip` fails with “required file not found”, remove it and recreate it:

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
