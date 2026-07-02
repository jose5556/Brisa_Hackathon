import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from src.vertical_ml_predict import predict_vertical_context


BAD_GPS_STREET_SAMPLE = {
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
    "gnss_accuracy_delta": 0.5,
}

WEAK_UNDERGROUND_SAMPLE = {
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
    "gnss_accuracy_delta": 45.0,
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
    assert result["non_street_confidence"] <= 0.2
