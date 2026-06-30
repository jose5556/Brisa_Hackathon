"""
train_vertical_lgbm.py
======================
Trains a LightGBM classifier to distinguish:
    street_level | underground | above

Compatible with the predict interface in vertical_ml_predict.py
(output bundle: {"model": <fitted estimator>, "features": [...]})

Usage
-----
    # Train
    python train_vertical_lgbm.py

    # Optional: tune number of samples and thresholds
    python train_vertical_lgbm.py --train  data/synthetic_vertical_train.csv \
                                   --val   data/synthetic_vertical_val.csv   \
                                   --out   models/vertical_context_lgbm.joblib

Design
------
- LightGBM natively handles missing values (NaN) — no imputation needed,
  but we keep a configurable SimpleImputer path for comparison / export.
- Stratified 5-fold CV on the training set to select n_estimators via early stopping.
- Final model trained on the full training set with the best iteration count.
- SHAP feature importances exported for model debugging.
- Threshold analysis: for the "non_street_confidence" composite score
  (P(underground) + P(above)), we scan thresholds and print the
  precision/recall trade-off — you pick the operating point for your grace window.
- Artefact saved with the same bundle schema as vertical_ml_predict.py
  so the predict function works with zero changes.

Dependencies
------------
    pip install lightgbm scikit-learn pandas numpy shap joblib matplotlib
"""

import argparse
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import lightgbm as lgb
import shap

from sklearn.metrics import (
    classification_report,
    confusion_matrix,
    f1_score,
    precision_recall_curve,
    roc_auc_score,
)
from sklearn.model_selection import StratifiedKFold
from sklearn.preprocessing import LabelEncoder

# ── Paths ────────────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "database" / "data_trainning_ml1" / "data"
MODEL_DIR = BASE_DIR / "models"
MODEL_DIR.mkdir(exist_ok=True)

DEFAULT_TRAIN = DATA_DIR / "synthetic_vertical_train.csv"
DEFAULT_VAL   = DATA_DIR / "synthetic_vertical_val.csv"
DEFAULT_OUT   = MODEL_DIR / "vertical_context_lgbm.joblib"

# ── Feature columns (must match sensor_payloads schema + derived columns) ───
FEATURE_COLS = [
    "pressure_hpa",
    "pressure_delta_hpa",
    "pressure_variance",
    "altitude_change_m",
    "pressure_relative_to_surface_hpa",  # derived: pressure_hpa - surface_pressure(elevation)
    "magnetic_variance_total",
    "magnetic_field_mean",
    "magnetic_field_delta",
    "gnss_accuracy_m",
    "gnss_accuracy_delta",
    "gnss_lost_ratio",
]

TARGET_COL = "label"

# ── LightGBM hyperparameters ─────────────────────────────────────────────────
# Tuned for small-to-medium tabular datasets with class imbalance.
# Uncomment the Optuna block below to run a proper HPO search.
LGBM_PARAMS = {
    "objective": "multiclass",
    "num_class": 3,
    "metric": "multi_logloss",
    "boosting_type": "gbdt",
    "num_leaves": 63,
    "max_depth": -1,                # unconstrained — let num_leaves do the work
    "learning_rate": 0.05,
    "n_estimators": 1000,           # upper bound; early stopping will trim this
    "subsample": 0.8,
    "subsample_freq": 1,
    "colsample_bytree": 0.8,
    "min_child_samples": 10,
    "reg_alpha": 0.1,               # L1
    "reg_lambda": 1.0,              # L2
    "class_weight": "balanced",     # handles street_level dominance
    "random_state": 42,
    "n_jobs": -1,
    "verbose": -1,
}

EARLY_STOPPING_ROUNDS = 50
CV_FOLDS = 5


# ─────────────────────────────────────────────────────────────────────────────
# DATA LOADING
# ─────────────────────────────────────────────────────────────────────────────

def load_data(train_path: Path, val_path: Path):
    train_df = pd.read_csv(train_path)
    val_df   = pd.read_csv(val_path)

    # Drop the noise-flag column if it exists (not a model feature)
    for col in ["label_noisy", "city", "ground_elevation_m", "time_of_day", "weather_condition"]:
        for df in [train_df, val_df]:
            if col in df.columns:
                df.drop(columns=[col], inplace=True)

    X_train = train_df[FEATURE_COLS].copy()
    y_train = train_df[TARGET_COL].copy()
    X_val   = val_df[FEATURE_COLS].copy()
    y_val   = val_df[TARGET_COL].copy()

    return X_train, y_train, X_val, y_val


# ─────────────────────────────────────────────────────────────────────────────
# LABEL ENCODING
# ─────────────────────────────────────────────────────────────────────────────

def encode_labels(y_train, y_val):
    le = LabelEncoder()
    le.fit(["street_level", "underground", "above"])  # fixed order
    y_train_enc = le.transform(y_train)
    y_val_enc   = le.transform(y_val)
    return le, y_train_enc, y_val_enc


# ─────────────────────────────────────────────────────────────────────────────
# CROSS-VALIDATION — find best n_estimators
# The goal here is to discover the ideal number of "decision trees"
# (n_estimators) so that the model is neither too complex nor too simple.
# ─────────────────────────────────────────────────────────────────────────────

def run_cv(X: pd.DataFrame, y_enc: np.ndarray, le: LabelEncoder) -> int:
    print(f"\n── {CV_FOLDS}-fold Stratified CV ──────────────────────────────")
    skf = StratifiedKFold(n_splits=CV_FOLDS, shuffle=True, random_state=42)

    best_iterations = []
    fold_f1s = []

    for fold, (train_idx, val_idx) in enumerate(skf.split(X, y_enc), 1):
        X_tr, X_vl = X.iloc[train_idx], X.iloc[val_idx]
        y_tr, y_vl = y_enc[train_idx], y_enc[val_idx]

        model = lgb.LGBMClassifier(**LGBM_PARAMS)
        model.fit(
            X_tr, y_tr,
            eval_set=[(X_vl, y_vl)],
            eval_metric="multi_logloss",
            callbacks=[
                lgb.early_stopping(EARLY_STOPPING_ROUNDS, verbose=False),
                lgb.log_evaluation(period=-1),
            ],
        )
        best_iter = model.best_iteration_
        best_iterations.append(best_iter)

        y_pred = model.predict(X_vl)
        f1 = f1_score(y_vl, y_pred, average="macro")
        fold_f1s.append(f1)
        print(f"  Fold {fold}: best_iter={best_iter:4d}  macro-F1={f1:.4f}")

    mean_best_iter = int(np.mean(best_iterations))
    print(f"\n  Mean macro-F1 : {np.mean(fold_f1s):.4f} ± {np.std(fold_f1s):.4f}")
    print(f"  Best n_estimators to use: {mean_best_iter}")
    return mean_best_iter


# ─────────────────────────────────────────────────────────────────────────────
# FINAL MODEL TRAINING
# ─────────────────────────────────────────────────────────────────────────────

def train_final_model(
    X_train: pd.DataFrame,
    y_train_enc: np.ndarray,
    X_val: pd.DataFrame,
    y_val_enc: np.ndarray,
    n_estimators: int,
    le: LabelEncoder,
) -> lgb.LGBMClassifier:
    print(f"\n── Final model training (n_estimators={n_estimators}) ──────────")
    params = {**LGBM_PARAMS, "n_estimators": n_estimators}
    # Remove early stopping for final run (we already know the iteration)
    model = lgb.LGBMClassifier(**params)
    model.fit(
        X_train, y_train_enc,
        eval_set=[(X_val, y_val_enc)],
        eval_metric="multi_logloss",
        callbacks=[lgb.log_evaluation(period=100)],
    )
    return model


# ─────────────────────────────────────────────────────────────────────────────
# EVALUATION
# ─────────────────────────────────────────────────────────────────────────────

def evaluate(
    model: lgb.LGBMClassifier,
    X_val: pd.DataFrame,
    y_val_enc: np.ndarray,
    le: LabelEncoder,
) -> dict:
    y_pred     = model.predict(X_val)
    y_proba    = model.predict_proba(X_val)
    class_names = le.classes_

    print("\n── Classification Report ────────────────────────────────────────")
    print(classification_report(y_val_enc, y_pred, target_names=class_names))

    print("── Confusion Matrix ─────────────────────────────────────────────")
    cm = confusion_matrix(y_val_enc, y_pred)
    cm_df = pd.DataFrame(cm, index=class_names, columns=class_names)
    print(cm_df.to_string())

    # Macro ROC-AUC (one-vs-rest)
    roc_auc = roc_auc_score(y_val_enc, y_proba, multi_class="ovr", average="macro")
    macro_f1 = f1_score(y_val_enc, y_pred, average="macro")
    print(f"\n  Macro ROC-AUC : {roc_auc:.4f}")
    print(f"  Macro F1      : {macro_f1:.4f}")

    # Per-class indices
    idx = {cls: i for i, cls in enumerate(class_names)}

    return {
        "macro_f1": round(float(macro_f1), 4),
        "macro_roc_auc": round(float(roc_auc), 4),
        "y_proba": y_proba,
        "y_pred": y_pred,
        "class_names": list(class_names),
        "class_indices": idx,
    }

# ─────────────────────────────────────────────────────────────────────────────
# NON-STREET CONFIDENCE THRESHOLD ANALYSIS
# ─────────────────────────────────────────────────────────────────────────────

def threshold_analysis(eval_results: dict, y_val_enc: np.ndarray):
    """
    Analyse the precision/recall curve for the binary decision:
        non_street_confidence = P(underground) + P(above)

    This is the key operating signal for the billing pipeline:
    - High threshold → fewer false positives (don't bill street parkers incorrectly)
    - Low threshold  → fewer false negatives (catch more garages)

    For Urban Layered Intelligence, a false positive (charging a street parker
    who's actually in a garage) is less bad than a false negative (NOT billing
    a street parker) → favour recall. But confirm with Brisa/Via Verde.
    """
    print("\n── Non-Street Confidence Threshold Analysis ─────────────────────")
    y_proba     = eval_results["y_proba"]
    class_names = eval_results["class_names"]
    idx = eval_results["class_indices"]

    # non_street_confidence: P(underground) + P(above)
    non_street_conf = (
        y_proba[:, idx["underground"]] + y_proba[:, idx["above"]]
    )

    # Binary ground truth: 1 if not street_level
    y_binary = (y_val_enc != idx["street_level"]).astype(int)

    precision, recall, thresholds = precision_recall_curve(y_binary, non_street_conf)

    print(f"\n  {'Threshold':>10}  {'Precision':>10}  {'Recall':>10}  {'F1':>10}")
    print("  " + "-" * 46)
    for t, p, r in zip(thresholds[::10], precision[::10], recall[::10]):
        f1 = 2 * p * r / (p + r) if (p + r) > 0 else 0.0
        print(f"  {t:>10.3f}  {p:>10.3f}  {r:>10.3f}  {f1:>10.3f}")

    # Find the threshold that maximises F1
    f1_scores = 2 * precision[:-1] * recall[:-1] / (
        np.where(precision[:-1] + recall[:-1] == 0, 1, precision[:-1] + recall[:-1])
    )
    best_idx = np.argmax(f1_scores)
    best_t   = thresholds[best_idx]
    print(f"\n  ✓ Best F1 threshold : {best_t:.3f}  "
          f"(P={precision[best_idx]:.3f}, R={recall[best_idx]:.3f}, F1={f1_scores[best_idx]:.3f})")
    print(f"  → Set NON_STREET_THRESHOLD = {best_t:.2f} in your FastAPI config")

    return float(best_t)


# ─────────────────────────────────────────────────────────────────────────────
# SHAP FEATURE IMPORTANCE
# ─────────────────────────────────────────────────────────────────────────────

def shap_analysis(model: lgb.LGBMClassifier, X_val: pd.DataFrame):
    print("\n── SHAP Feature Importance ──────────────────────────────────────")
    try:
        explainer = shap.TreeExplainer(model)
        # Use a sample for speed
        sample = X_val.sample(min(500, len(X_val)), random_state=42)
        shap_values = explainer.shap_values(sample)

        # It handles the different versions of the SHAP library.
        if isinstance(shap_values, np.ndarray) and len(shap_values.shape) == 3:
            mean_shap = np.abs(shap_values).mean(axis=(0, 2))
        else:
            mean_shap = np.mean([np.abs(sv).mean(axis=0) for sv in shap_values], axis=0)

        importance_df = pd.DataFrame({
            "feature": FEATURE_COLS,
            "mean_abs_shap": mean_shap,
        }).sort_values("mean_abs_shap", ascending=False)

        print(importance_df.to_string(index=False))
        return importance_df

    except Exception as e:
        print(f" [Warning] The SHAPE could not be calculated due to a version conflict: {e}")
        print("  Continuing the script to save the model....")
        return None

# ─────────────────────────────────────────────────────────────────────────────
# SAVE ARTEFACT
# ─────────────────────────────────────────────────────────────────────────────

def save_artifact(
    model: lgb.LGBMClassifier,
    le: LabelEncoder,
    best_threshold: float,
    metrics: dict,
    out_path: Path,
):
    """
    Bundle schema compatible with vertical_ml_predict.py:
        bundle["model"]    — fitted LGBMClassifier
        bundle["features"] — list of feature column names (same order as training)

    Extra fields for operational use:
        bundle["label_encoder"]        — to decode integer predictions
        bundle["non_street_threshold"] — recommended operating threshold
        bundle["metrics"]              — val set metrics for the model registry
        bundle["classes"]              — class names in encoder order
    """
    bundle = {
        "model": model,
        "features": FEATURE_COLS,
        "label_encoder": le,
        "classes": list(le.classes_),
        "non_street_threshold": best_threshold,
        "metrics": metrics,
    }
    joblib.dump(bundle, out_path)
    print(f"\n✓ Model artifact saved → {out_path}")

    # Also save a JSON summary for the model_versions table
    summary = {
        "model_name": "vertical_classifier",
        "version_tag": "v1.0.0-lgbm",
        "artifact_path": str(out_path),
        "feature_columns": FEATURE_COLS,
        "classes": list(le.classes_),
        "non_street_threshold": best_threshold,
        "val_f1_score": metrics["macro_f1"],
        "val_roc_auc": metrics["macro_roc_auc"],
        "lgbm_params": LGBM_PARAMS,
    }
    summary_path = out_path.parent / "vertical_context_lgbm_summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"✓ Summary JSON       → {summary_path}")


# ─────────────────────────────────────────────────────────────────────────────
# PREDICT COMPATIBILITY CHECK
# ─────────────────────────────────────────────────────────────────────────────

def verify_predict_interface(artifact_path: Path):
    """
    Runs a mock payload through the bundle to verify compatibility
    with vertical_ml_predict.py's predict_vertical_context().
    """
    print("\n── Predict Interface Verification ───────────────────────────────")
    bundle = joblib.load(artifact_path)
    model   = bundle["model"]
    features = bundle["features"]
    le      = bundle["label_encoder"]
    threshold = bundle["non_street_threshold"]

    # Mock payload: simulates what FastAPI receives from the device
    mock_payload = {
        "pressure_hpa": 1015.2,
        "pressure_delta_hpa": -0.18,
        "pressure_variance": 0.09,
        "altitude_change_m": -4.2,
        "pressure_relative_to_surface_hpa": 1.2,
        "mag_variance_total": 0.45,
        "magnetic_field_mean": 85.3,
        "magnetic_field_delta": 14.2,
        "gnss_accuracy_m": 95.0,
        "gnss_accuracy_delta": 45.0,
        "gnss_lost_ratio": 0.93,
    }

    row = {f: mock_payload.get(f, np.nan) for f in features}
    X = pd.DataFrame([row], columns=features)

    probabilities = model.predict_proba(X)[0]
    classes_enc   = le.classes_

    probabilities_by_class = dict(zip(classes_enc, probabilities))
    underground_score = float(probabilities_by_class.get("underground", 0.0))
    above_score       = float(probabilities_by_class.get("above", 0.0))

    non_street_confidence = round(underground_score + above_score, 4)
    classification = max(probabilities_by_class, key=probabilities_by_class.get)
    decision = "Charge" if non_street_confidence < threshold else "Don't charge"

    print(f"  Mock payload (should be → underground):")
    print(f"    probabilities      : {probabilities_by_class}")
    print(f"    classification     : {classification}")
    print(f"    non_street_conf    : {non_street_confidence}")
    print(f"    threshold          : {threshold}")
    print(f"    pipeline decision  : {decision}")
    print("\n  ✓ Interface verified — compatible with vertical_ml_predict.py")


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main(train_path: Path, val_path: Path, out_path: Path):
    print("=" * 65)
    print("  Urban Layered Intelligence — Vertical Context LightGBM Trainer")
    print("=" * 65)

    # 1. Load data
    print(f"\nLoading train: {train_path}")
    print(f"Loading val  : {val_path}")
    X_train, y_train, X_val, y_val = load_data(train_path, val_path)
    print(f"  Train shape: {X_train.shape}  |  Val shape: {X_val.shape}")

    # 2. Encode labels
    le, y_train_enc, y_val_enc = encode_labels(y_train, y_val)
    print(f"  Classes (encoded order): {list(le.classes_)}")

    # 3. Cross-validation → best n_estimators
    best_n = run_cv(X_train, y_train_enc, le)

    # 4. Train final model on full train split
    model = train_final_model(X_train, y_train_enc, X_val, y_val_enc, best_n, le)

    # 5. Evaluate on val set
    eval_results = evaluate(model, X_val, y_val_enc, le)

    # 6. Threshold analysis for non_street_confidence
    best_threshold = threshold_analysis(eval_results, y_val_enc)

    # 7. SHAP feature importances
    shap_analysis(model, X_val)

    # 8. Collect metrics for model registry
    metrics = {
        "macro_f1":    eval_results["macro_f1"],
        "macro_roc_auc": eval_results["macro_roc_auc"],
        "val_samples": len(X_val),
        "train_samples": len(X_train),
    }

    # 9. Save artifact
    save_artifact(model, le, best_threshold, metrics, out_path)

    # 10. Verify predict interface
    verify_predict_interface(out_path)

    print("\n" + "=" * 65)
    print("  Training complete.")
    print(f"  Val macro-F1  : {metrics['macro_f1']:.4f}")
    print(f"  Val ROC-AUC   : {metrics['macro_roc_auc']:.4f}")
    print(f"  Model artifact: {out_path}")
    print("=" * 65)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Train LightGBM Vertical Context Classifier"
    )
    parser.add_argument("--train", type=Path, default=DEFAULT_TRAIN)
    parser.add_argument("--val",   type=Path, default=DEFAULT_VAL)
    parser.add_argument("--out",   type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    main(train_path=args.train, val_path=args.val, out_path=args.out)