from pathlib import Path
import joblib
import pandas as pd
import numpy as np

BASE_DIR = Path(__file__).resolve().parents[1]
MODEL_PATH = BASE_DIR / "models" / "spatial_decision_lgbm.joblib"

def predict_final_decision(ml1_confidence: float, gnss_accuracy_m: float, distance_to_zone_m: float) -> dict:
    if not MODEL_PATH.exists():
        raise FileNotFoundError("Model 2 not found. Run 'make train-spatial' first.")

    bundle = joblib.load(MODEL_PATH)
    model = bundle["model"]
    features = bundle["features"]

    row = {
        "ml1_non_street_confidence": ml1_confidence,
        "gnss_accuracy_m": gnss_accuracy_m,
        "distance_to_zone_m": distance_to_zone_m
    }

    X = pd.DataFrame([row], columns=features).astype(float)

    # (0 = Don't charge, 1 = Charge)
    probabilities = model.predict_proba(X)[0]
    charge_prob = float(probabilities[1])

    # if the probability of charging is greater than 90%, charge
    final_decision = "Charge" if charge_prob >= 0.90 else "Don't charge"

    return {
        "final_decision": final_decision,
        "ml2_charge_confidence": round(charge_prob, 4)
    }