from pathlib import Path
import joblib
import pandas as pd
import numpy as np

BASE_DIR = Path(__file__).resolve().parents[1]
MODEL_PATH = BASE_DIR / "models" / "vertical_context_lgbm.joblib"


def predict_vertical_context(payload: dict) -> dict:
    if not MODEL_PATH.exists():
        raise FileNotFoundError(
            "Model not found. Check if there is a trained model in backend/models."
        )

    bundle = joblib.load(MODEL_PATH)

    model = bundle["model"]
    features = bundle["features"]

    le = bundle["label_encoder"]

    mapping = {
        "pressure_hpa": payload.get("pressure_hpa"),
        "pressure_delta_hpa": payload.get("pressure_delta"),  # curl: pressure_delta
        "pressure_variance": payload.get("pressure_variance"),
        "altitude_change_m": payload.get("altitude_delta"),    # curl: altitude_delta
        "magnetic_variance_total": payload.get("magnetic_variance_total"),
        "magnetic_field_mean": payload.get("magnetic_field_mean"),
        "magnetic_field_delta": payload.get("magnetic_field_delta"),
        "gnss_accuracy_m": payload.get("gnss_accuracy_m") or payload.get("gnss_accuracy_mean"),
        "gnss_accuracy_delta": payload.get("gnss_accuracy_delta"),
        "gnss_lost_ratio": payload.get("gnss_lost_ratio") or payload.get("gps_lost_ratio"), # curl: gnss_lost_ratio
    }

    row = {}

    for feature in features:
        row[feature] = payload.get(feature, np.nan)

    X = pd.DataFrame([row], columns=features)

    X = X.astype(float)

    probabilities = model.predict_proba(X)[0]
    decoded_classes = le.inverse_transform(model.classes_)

    probabilities_by_class = dict(zip(decoded_classes, probabilities))

    underground_score = float(probabilities_by_class.get("underground", 0.0))
    above_score = float(probabilities_by_class.get("above", 0.0))

    non_street_confidence = float(np.round(underground_score + above_score, 2))

    classification = max(
        probabilities_by_class,
        key=probabilities_by_class.get,
    )

    return {
        "non_street_confidence": non_street_confidence,
        "classification": classification,
    }
