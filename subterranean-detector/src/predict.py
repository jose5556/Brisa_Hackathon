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

    if subterranean_score >= 0.75:
        classification = "likely_underground"
    elif subterranean_score >= 0.40:
        classification = "ambiguous"
    else:
        classification = "likely_street"

    return {
        "subterranean_confidence": subterranean_score,
        "classification": classification,
        "probabilities": {
            key: float(value)
            for key, value in probabilities_by_class.items()
        },
    }

if __name__ == "__main__":
    sample = {
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

    result = predict_subterranean(sample)
    print(result)