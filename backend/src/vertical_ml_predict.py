"""
vertical_ml_predict.py
======================
Inference interface for Model 1 — Vertical Context Classifier.

Classifies the parking environment into three vertical categories:
    street_level | underground | above

Produces a combined score called non_street_confidence (0.0–1.0):
    P(underground) + P(above)
    → High value means the vehicle is NOT on a public street → abort billing.

Loads the trained LightGBM bundle once at module import time (singleton),
avoiding the cost of reading the .joblib file on every request.

Bundle schema (written by train_vertical_lgbm.py):
    bundle["model"]                — fitted LGBMClassifier
    bundle["features"]             — list[str], feature names in training order
    bundle["label_encoder"]        — fitted LabelEncoder for class decoding
    bundle["non_street_threshold"] — optimal threshold from PR curve analysis
    bundle["metrics"]              — val metrics for model_versions table

Called by parking_service.py as the first step of the inference pipeline,
before the spatial context lookup and Model 2.
"""
import logging
from pathlib import Path
import joblib
import pandas as pd
import numpy as np

log = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parents[1]
MODEL_PATH = BASE_DIR / "models" / "vertical_context_lgbm.joblib"

_bundle: dict | None = None

def _get_bundle() -> dict:
    global _bundle
    if _bundle is None:
        if not MODEL_PATH.exists():
            raise FileNotFoundError(
                f"Model 1 not found at {MODEL_PATH}. "
                "Run 'make train-vertical' (or 'python train_vertical_lgbm.py') first."
            )
        log.info("Loading Model 1 bundle from %s", MODEL_PATH)
        _bundle = joblib.load(MODEL_PATH)

        # Validate bundle schema, catch mismatches between train and predict
        required_keys = {"model", "features", "label_encoder"}
        missing = required_keys - set(_bundle.keys())
        if missing:
            raise ValueError(
                f"Model 1 bundle is missing keys: {missing}. "
                "Re-train with the current train_vertical_lgbm.py."
            )

        log.info(
            "Model 1 loaded — features=%s  threshold=%.3f  val_f1=%s",
            _bundle["features"],
            _bundle.get("non_street_threshold", 0.5),
            _bundle.get("metrics", {}).get("val_f1_score", "n/a"),
        )

    return _bundle


def reload_bundle() -> None:
    global _bundle
    _bundle = None
    _get_bundle()
    log.info("Model 1 bundle reloaded.")

_PAYLOAD_ALIASES: dict[str, list[str]] = {
    "pressure_delta_hpa":      ["pressure_delta_hpa", "pressure_delta"],
    "altitude_change_m":       ["altitude_change_m",  "altitude_delta"],
    "gnss_accuracy_m":         ["gnss_accuracy_m",    "gnss_accuracy_mean"],
    "magnetic_variance_total": ["magnetic_variance_total"],
    "magnetic_field_mean":     ["magnetic_field_mean"],
    "magnetic_field_delta":    ["magnetic_field_delta"],
    "pressure_hpa":            ["pressure_hpa"],
    "pressure_variance":       ["pressure_variance"],
    "gnss_accuracy_delta":     ["gnss_accuracy_delta"],
    "gnss_lost_ratio":         ["gnss_lost_ratio"],
}

def _extract_features(payload: dict, feature_names: list[str]) -> dict:
    resolved = {}
    for feature in feature_names:
        aliases = _PAYLOAD_ALIASES.get(feature, [feature])
        value   = np.nan
        for alias in aliases:
            candidate = payload.get(alias)
            if candidate is not None:
                value = candidate
                break
        resolved[feature] = value
    return resolved

def predict_vertical_context(payload: dict) -> dict:
    bundle              = _get_bundle()
    model               = bundle["model"]
    feature_names       = bundle["features"]
    label_encoder       = bundle["label_encoder"]
    non_street_threshold = bundle.get("non_street_threshold", 0.5)

    # Build feature row — resolves payload aliases, fills missing with NaN
    row = _extract_features(payload, feature_names)
    X   = pd.DataFrame([row], columns=feature_names).astype(float)

    # Predict probabilities for all three classes
    raw_probs      = model.predict_proba(X)[0]
    decoded_classes = label_encoder.inverse_transform(model.classes_)
    probs_by_class  = dict(zip(decoded_classes, raw_probs.tolist()))

    # non_street_confidence: combined probability of non-street environments
    underground_prob = float(probs_by_class.get("underground", 0.0))
    above_prob       = float(probs_by_class.get("above", 0.0))
    non_street_conf  = round(underground_prob + above_prob, 4)

    classification = max(probs_by_class, key=probs_by_class.get)

    log.debug(
        "Model 1 inference — classification=%s  non_street_confidence=%.4f  "
        "threshold=%.3f  probs=%s",
        classification, non_street_conf, non_street_threshold,
        {k: round(v, 4) for k, v in probs_by_class.items()},
    )

    return {
        "non_street_confidence": non_street_conf,
        "classification":        classification,
        "probabilities":         {k: round(v, 4) for k, v in probs_by_class.items()},
        "non_street_threshold":  non_street_threshold,
    }
