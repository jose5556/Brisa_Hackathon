"""
spatial_ml_predict.py
=====================
Inference interface for Model 2 — Spatial Decision Classifier.

Loads the trained LightGBM bundle once at module import time (singleton),
avoiding the cost of reading the .joblib file on every request.

Bundle schema (written by train_spatial_lgbm.py):
    bundle["model"]            — fitted LGBMClassifier
    bundle["features"]         — list[str], feature names in training order
    bundle["classes"]          — ["no_charge", "charge"]
    bundle["charge_threshold"] — optimal threshold from PR curve analysis
    bundle["metrics"]          — val metrics for model_versions table

Called by parking_service.py after:
    1. Model 1 has produced ml1_non_street_confidence
    2. Spatial service has confirmed in_paid_zone=True and distance_to_zone_m
"""

from pathlib import Path
from typing import Optional
import joblib
import pandas as pd
import numpy as np
import logging

log = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parents[1]
MODEL_PATH = BASE_DIR / "models" / "spatial_decision_lgbm.joblib"

# ── Singleton bundle — loaded once at module import ───────────────────────────
# joblib.load reads and deserialises the .joblib file from disk.
# Doing this inside predict_final_decision() would re-read the file on every
# request. With this pattern the file is read once when the FastAPI worker
# starts, and the bundle lives in memory for the lifetime of the process.
_bundle: dict | None = None

def _get_bundle() -> dict:
    global _bundle
    if _bundle is None:
        if not MODEL_PATH.exists():
            raise FileNotFoundError(
                f"Model 2 not found at {MODEL_PATH}. "
                "Run 'make train-spatial' first."
            )
        log.info("Loading Model 2 bundle from %s", MODEL_PATH)
        _bundle = joblib.load(MODEL_PATH)

        # Validate bundle schema
        required_keys = {"model", "features", "classes", "charge_threshold"}
        missing = required_keys - set(_bundle.keys())
        if missing:
            raise ValueError(
                f"Model 2 bundle is missing keys: {missing}. "
                "Re-train with the current train_spatial_lgbm.py."
            )

        log.info(
            "Model 2 loaded — features=%s  threshold=%.3f  val_f1=%.4f",
            _bundle["features"],
            _bundle["charge_threshold"],
            _bundle.get("metrics", {}).get("binary_f1", float("nan")),
        )

    return _bundle


def reload_bundle() -> None:
    """
    Force a reload of the model bundle from disk.
    Call this after deploying a new model version.

    Example (in a FastAPI admin endpoint):
        from src.spatial_ml_predict import reload_bundle
        reload_bundle()
    """
    global _bundle
    _bundle = None
    _get_bundle()
    log.info("Model 2 bundle reloaded.")

def predict_final_decision(
    ml1_confidence: float,
    gnss_accuracy_m: float,
    distance_to_zone_m: float,
    gnss_lost_ratio: Optional[float] = None,
) -> dict:
    bundle           = _get_bundle()
    model            = bundle["model"]
    feature_names    = bundle["features"]
    charge_threshold = bundle["charge_threshold"]

    # Build the feature row using the exact names and order from training.
    # Unknown features fall back to NaN, LightGBM handles NaN natively.
    feature_values = {
        "ml1_non_street_confidence": ml1_confidence,
        "distance_to_zone_m":        distance_to_zone_m,
        "gnss_accuracy_m":           gnss_accuracy_m,
    }

    row = {name: feature_values.get(name, np.nan) for name in feature_names}
    X   = pd.DataFrame([row], columns=feature_names).astype(float)

    # predict_proba returns [[P(no_charge), P(charge)]]
    # classes order is guaranteed by bundle["classes"] = ["no_charge", "charge"]
    charge_prob = float(model.predict_proba(X)[0][1])

    final_decision = "charge" if charge_prob >= charge_threshold else "no_charge"

    log.debug(
        "Model 2 inference — charge_prob=%.4f  threshold=%.3f  decision=%s",
        charge_prob, charge_threshold, final_decision,
    )

    return {
        "final_decision":        final_decision,
        "ml2_charge_confidence": round(charge_prob, 4),
        "charge_threshold":      charge_threshold,
    }