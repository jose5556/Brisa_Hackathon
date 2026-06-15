from pathlib import Path
import joblib
import pandas as pd

BASE_DIR = Path(__file__).resolve().parents[1]
MODEL_PATH = BASE_DIR / "models" / "vertical_context_rf.joblib"


def predict_vertical_context(payload: dict) -> dict:
    if not MODEL_PATH.exists():
        raise FileNotFoundError(
            "Model not found. Run: python scripts/train_model.py first"
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
        key=probabilities_by_class.get,
    )

    return {
        "non_street_confidence": non_street_confidence,
        "classification": classification,
    }
