from fastapi.testclient import TestClient
from src.main import app
from pathlib import Path

client = TestClient(app)

VALID_SAMPLE = {
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
    "stationary_ratio": 0.73,
}

def test_predict_endpoint_returns_prediction():
    response = client.post("/predict", json=VALID_SAMPLE)

    assert response.status_code == 200

    data = response.json()
    assert "classification" in data
    assert "non_street_confidence" in data
    assert isinstance(data["classification"], str)
    assert isinstance(data["non_street_confidence"], float)


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "API is running"}


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_predict_endpoint_returns_prediction():
    response = client.post("/predict", json=VALID_SAMPLE)

    assert response.status_code == 200

    data = response.json()
    assert "classification" in data
    assert "non_street_confidence" in data
    assert isinstance(data["classification"], str)
    assert isinstance(data["non_street_confidence"], float)

def test_predict_endpoint_detects_underground():
    response = client.post("/predict", json=VALID_SAMPLE)

    assert response.status_code == 200

    data = response.json()
    assert data["classification"] == "underground"
    assert data["non_street_confidence"] >= 0.8

""" 
At the moment, if empty payload is sent, ml simply return a default value
so code 200 for now. Protect this code in the future is planned
def test_predict_with_empty_payload_fails():
    response = client.post("/predict", json={})

    assert response.status_code == 500 """

def test_schema_info_contains_expected_tables():
    response = client.get("/db/schema-info")

    assert response.status_code == 200

    data = response.json()
    assert "parking_sessions" in data["tables"]
    assert "sensor_payloads" in data["tables"]
    assert "inference_logs" in data["tables"]

def test_analyze_parking_event_creates_event():
    response = client.post("/parking-events/analyze", json=VALID_SAMPLE)

    assert response.status_code == 200

    data = response.json()
    assert "session_id" in data
    assert "classification" in data
    assert "non_street_confidence" in data

def test_latest_parking_events_returns_list():
    response = client.get("/parking-events/latest")

    assert response.status_code == 200

    data = response.json()
    assert "count" in data
    assert "events" in data
    assert isinstance(data["events"], list)
