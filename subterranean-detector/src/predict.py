from pathlib import Path
import joblib
import pandas as pd


MODEL_PATH = Path("models/subterranean_rf.joblib")


def predict_subterranean(payload: dict) -> dict:
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

    subterranean_score = float(probabilities_by_class.get("underground", 0.0))
    subterranean_score = round(subterranean_score, 2)

    if subterranean_score >= 0.85:
        classification = "likely_underground"
    elif subterranean_score <= 0.25:
        classification = "likely_street_level"
    else:
        classification = "uncertain"

    return {
        "subterranean_confidence": subterranean_score,
        "classification": classification,
    }


if __name__ == "__main__":
    underground_sample = {
        "gps_accuracy_mean": 45.0,
        "gps_accuracy_max": 100.0,
        "gps_accuracy_delta": 55.0,
        "gps_lost_ratio": 0.75,

        "wifi_count_mean": 4,
        "wifi_count_delta": -14,
        "wifi_rssi_mean": -84,

        "ble_count_mean": 2,
        "ble_count_delta": -7,
        "ble_rssi_mean": -88,

        "pressure_delta": 0.9,
        "pressure_slope": 0.12,

        "stationary_ratio": 0.8,
    }

    street_level_sample = {
        "gps_accuracy_mean": 7.0,
        "gps_accuracy_max": 12.0,
        "gps_accuracy_delta": 3.0,
        "gps_lost_ratio": 0.05,

        "wifi_count_mean": 18,
        "wifi_count_delta": 1,
        "wifi_rssi_mean": -60,

        "ble_count_mean": 8,
        "ble_count_delta": 0,
        "ble_rssi_mean": -65,

        "pressure_delta": 0.02,
        "pressure_slope": 0.01,

        "stationary_ratio": 0.9,
    }

    ambiguous_sample = {
        "gps_accuracy_mean": 18.0,
        "gps_accuracy_max": 35.0,
        "gps_accuracy_delta": 15.0,
        "gps_lost_ratio": 0.25,

        "wifi_count_mean": 10,
        "wifi_count_delta": -5,
        "wifi_rssi_mean": -72,

        "ble_count_mean": 5,
        "ble_count_delta": -3,
        "ble_rssi_mean": -78,

        "pressure_delta": 0.22,
        "pressure_slope": 0.04,

        "stationary_ratio": 0.7,
    }

    print("UNDERGROUND TEST:")
    print(predict_subterranean(underground_sample))

    print("\nSTREET_LEVEL TEST:")
    print(predict_subterranean(street_level_sample))

    print("\nAMBIGUOUS TEST:")
    print(predict_subterranean(ambiguous_sample))