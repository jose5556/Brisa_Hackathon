import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from src.vertical_ml_predict import predict_vertical_context


BAD_GPS_STREET_SAMPLE = {
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
    "stationary_ratio": 0.85,
}

WEAK_UNDERGROUND_SAMPLE = {
    "gps_accuracy_mean": 26.0,
    "gps_accuracy_max": 55.0,
    "gps_accuracy_delta": 22.0,
    "gps_lost_ratio": 0.32,
    "wifi_count_mean": 9,
    "wifi_count_delta": -8,
    "wifi_rssi_mean": -79,
    "ble_count_mean": 4,
    "ble_count_delta": -5,
    "ble_rssi_mean": -84,
    "pressure_delta": 0.28,
    "pressure_slope": 0.05,
    "altitude_delta": -1.2,
    "vertical_change_abs": 1.3,
    "stationary_ratio": 0.75,
}


def test_prediction_returns_expected_structure():
    result = predict_vertical_context(BAD_GPS_STREET_SAMPLE)

    assert isinstance(result, dict)
    assert set(result) == {"non_street_confidence", "classification"}
    assert isinstance(result["non_street_confidence"], float)
    assert isinstance(result["classification"], str)


def test_underground_sample_is_detected_as_non_street():
    result = predict_vertical_context(WEAK_UNDERGROUND_SAMPLE)

    assert result["classification"] == "underground"
    assert result["non_street_confidence"] >= 0.9
