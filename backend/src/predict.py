from pathlib import Path
import joblib
import pandas as pd

MODEL_PATH = Path("models/vertical_context_rf.joblib")

def predict_vertical_context(payload: dict) -> dict:
    if not MODEL_PATH.exists():
        raise FileNotFoundError(
            "Model not found. Run: python src/train_model.py first"
        )

    bundle = joblib.load(MODEL_PATH)

    model = bundle["model"]
    features = bundle["features"]

    row = {}

    for feature in features:
        row[feature] = payload.get(feature, 0)

    X = pd.DataFrame([row], columns=features)

    probabilities = model.predict_proba(X)[0]
    classes = model.classes_

    probabilities_by_class = dict(zip(classes, probabilities))

    underground_score = float(probabilities_by_class.get("underground", 0.0))
    above_score = float(probabilities_by_class.get("above", 0.0))

    non_street_confidence = underground_score + above_score
    non_street_confidence = round(non_street_confidence, 2)

    classification = max(
        probabilities_by_class,
        key=probabilities_by_class.get
    )

    return {
        "non_street_confidence": non_street_confidence,
        "classification": classification,
    }

if __name__ == "__main__":
    bad_gps_street_sample = {
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

    weak_underground_sample = {
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

    weak_above_sample = {
        "gps_accuracy_mean": 24.0,
        "gps_accuracy_max": 50.0,
        "gps_accuracy_delta": 18.0,
        "gps_lost_ratio": 0.28,

        "wifi_count_mean": 10,
        "wifi_count_delta": -4,
        "wifi_rssi_mean": -76,

        "ble_count_mean": 5,
        "ble_count_delta": -3,
        "ble_rssi_mean": -80,

        "pressure_delta": -0.25,
        "pressure_slope": -0.04,

        "altitude_delta": 1.1,
        "vertical_change_abs": 1.2,

        "stationary_ratio": 0.78,
    }

    hilly_street_sample = {
        "gps_accuracy_mean": 14.0,
        "gps_accuracy_max": 25.0,
        "gps_accuracy_delta": 8.0,
        "gps_lost_ratio": 0.12,

        "wifi_count_mean": 17,
        "wifi_count_delta": 0,
        "wifi_rssi_mean": -65,

        "ble_count_mean": 7,
        "ble_count_delta": 0,
        "ble_rssi_mean": -70,

        "pressure_delta": -0.45,
        "pressure_slope": -0.06,

        "altitude_delta": 3.5,
        "vertical_change_abs": 3.5,

        "stationary_ratio": 0.7,
    }

    noisy_indoor_ground_floor_sample = {
        "gps_accuracy_mean": 32.0,
        "gps_accuracy_max": 70.0,
        "gps_accuracy_delta": 25.0,
        "gps_lost_ratio": 0.4,

        "wifi_count_mean": 22,
        "wifi_count_delta": 3,
        "wifi_rssi_mean": -58,

        "ble_count_mean": 11,
        "ble_count_delta": 2,
        "ble_rssi_mean": -64,

        "pressure_delta": 0.03,
        "pressure_slope": 0.0,

        "altitude_delta": 0.1,
        "vertical_change_abs": 0.3,

        "stationary_ratio": 0.95,
    }

    confusing_multilevel_sample = {
        "gps_accuracy_mean": 28.0,
        "gps_accuracy_max": 60.0,
        "gps_accuracy_delta": 24.0,
        "gps_lost_ratio": 0.35,

        "wifi_count_mean": 8,
        "wifi_count_delta": -5,
        "wifi_rssi_mean": -78,

        "ble_count_mean": 4,
        "ble_count_delta": -4,
        "ble_rssi_mean": -83,

        "pressure_delta": 0.05,
        "pressure_slope": 0.01,

        "altitude_delta": 0.2,
        "vertical_change_abs": 2.5,

        "stationary_ratio": 0.8,
    }

    print("\nBAD GPS STREET TEST:")
    print(predict_vertical_context(bad_gps_street_sample))

    print("\nWEAK UNDERGROUND TEST:")
    print(predict_vertical_context(weak_underground_sample))

    print("\nWEAK ABOVE TEST:")
    print(predict_vertical_context(weak_above_sample))

    print("\nHILLY STREET TEST:")
    print(predict_vertical_context(hilly_street_sample))

    print("\nNOISY INDOOR GROUND FLOOR TEST:")
    print(predict_vertical_context(noisy_indoor_ground_floor_sample))

    print("\nCONFUSING MULTILEVEL TEST:")
    print(predict_vertical_context(confusing_multilevel_sample))

""" 
source venv/bin/activate
uvicorn src.api:app --host 0.0.0.0 --port 8000 --reload 
"""
