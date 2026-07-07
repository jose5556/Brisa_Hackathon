"""
train_spatial_lgbm.py
=====================
Trains a LightGBM binary classifier (Model 2 — Spatial Decision):
    charge | no_charge

Receives the output of Model 1 (ml1_non_street_confidence) fused with
spatial features (distance to paid zone, GNSS quality) to produce the
final billing decision.

Compatible with the predict interface in spatial_ml_predict.py:
    bundle["model"]              — fitted LGBMClassifier
    bundle["features"]           — feature column names (same order as training)
    bundle["classes"]            — ["no_charge", "charge"]
    bundle["charge_threshold"]   — optimal operating threshold from PR curve
    bundle["metrics"]            — val set metrics for the model registry

Usage
-----
    # Train with synthetic data (pipeline smoke-test only)
    python train_spatial_lgbm.py

    # Train with real labelled data
    python train_spatial_lgbm.py --train data/spatial_train.csv \
                                  --val   data/spatial_val.csv   \
                                  --out   models/spatial_decision_lgbm.joblib

WARNING — Synthetic data
------------------------
The synthetic data generated here is ONLY for testing the training pipeline.
It encodes a simplified version of the real-world rule, which means the model
will learn the rule itself rather than the real signal distribution.
Replace with real labelled sessions from collection_sessions before any
production or demo use.

Design
------
- Stratified 5-fold CV with early stopping to find optimal n_estimators.
- Final model trained on the full training split with the best iteration.
- Threshold analysis on the binary charge_confidence score:
    precision/recall curve → pick operating point.
- SHAP feature importances for model debugging.
- Artifact bundle + JSON summary saved for the model_versions registry.
- Predict interface verification run automatically after training.

Dependencies
------------
    pip install lightgbm scikit-learn pandas numpy shap joblib
"""

import argparse
import json
import logging
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

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ── Paths ─────────────────────────────────────────────────────────────────────
BASE_DIR  = Path(__file__).resolve().parent.parent
DATA_DIR  = BASE_DIR / "database" / "data_training_ml2" / "data"
MODEL_DIR = BASE_DIR / "models"
MODEL_DIR.mkdir(exist_ok=True)

DEFAULT_TRAIN = DATA_DIR / "spatial_train.csv"
DEFAULT_VAL   = DATA_DIR / "spatial_val.csv"
DEFAULT_OUT   = MODEL_DIR / "spatial_decision_lgbm.joblib"

# ── Feature columns ────────────────────────────────────────────────────────────
# These must match the keys sent by spatial_ml_predict.py.
# When new sensors are added, extend here AND
# retrain — the bundle stores feature_names so old models stay compatible.
FEATURE_COLS = [
    "ml1_non_street_confidence",  # P(underground) + P(above) from Model 1
    "distance_to_zone_m",         # metres to nearest paid zone boundary (PostGIS)
    "gnss_accuracy_m",            # mean GPS accuracy during 10-s window
    "gnss_lost_ratio",            # fraction of window with no GPS signal (0–1)
    # ── future features (add when collection campaign data is available) ──
    # "magnetic_variance_total",  # magnetometer distortion score
    # "heading_delta_deg",        # rotation before stop (kerb/driveway signal)
    # "kerb_event_detected",      # IMU Z-axis spike (0/1)
]

TARGET_COL = "label"  # "charge" | "no_charge"

# ── LightGBM hyperparameters ───────────────────────────────────────────────────
LGBM_PARAMS = {
    "objective":        "binary",
    "metric":           "binary_logloss",
    "boosting_type":    "gbdt",
    "num_leaves":       31,
    "max_depth":        -1,
    "learning_rate":    0.05,
    "n_estimators":     1000,        # upper bound; early stopping trims this
    "subsample":        0.8,
    "subsample_freq":   1,
    "colsample_bytree": 0.8,
    "min_child_samples": 10,
    "reg_alpha":        0.1,
    "reg_lambda":       1.0,
    # class_weight="balanced" handles the expected imbalance:
    # most real sessions will be "charge" (street) — garages are the minority
    "class_weight":     "balanced",
    "random_state":     42,
    "n_jobs":           -1,
    "verbose":          -1,
}

EARLY_STOPPING_ROUNDS = 50
CV_FOLDS              = 5


# ─────────────────────────────────────────────────────────────────────────────
# SYNTHETIC DATA — pipeline smoke-test only
# ─────────────────────────────────────────────────────────────────────────────

def generate_synthetic_data(n_samples: int = 5000, seed: int = 42) -> pd.DataFrame:
    """
    Generates synthetic data that approximates real-world distributions
    without encoding the exact decision rule as the label.

    Key difference from the original script:
    - Labels are derived from a NOISY combination of signals, not a hard
      threshold rule. This forces the model to learn signal weights rather
      than memorise the rule used to generate labels.
    - Class balance is controlled explicitly (60/40 charge/no_charge).
    - gnss_lost_ratio is added as a feature — it carries real signal in
      environments where GPS degrades (garages, dense urban canyons).

    WARNING: Replace with real data from collection_sessions before demo.
    """
    rng = np.random.default_rng(seed)

    # ── Generate feature distributions per class ──────────────────────────────
    n_charge    = int(n_samples * 0.60)   # street parking (majority)
    n_no_charge = n_samples - n_charge    # garages + free zones

    # "charge" class — typical street parking profile
    charge = pd.DataFrame({
        "ml1_non_street_confidence": rng.beta(1.5, 6,   n_charge),        # low → street
        "distance_to_zone_m":        rng.gamma(1.2, 3,  n_charge),        # close to zone
        "gnss_accuracy_m":           rng.uniform(4, 18, n_charge),        # decent GPS
        "gnss_lost_ratio":           rng.beta(1, 10,    n_charge),        # signal mostly ok
        TARGET_COL: "charge",
    })

    # "no_charge" class — garages / free zones / private driveways
    no_charge = pd.DataFrame({
        "ml1_non_street_confidence": rng.beta(5, 2,    n_no_charge),      # high → garage
        "distance_to_zone_m":        rng.uniform(8, 60, n_no_charge),     # farther from zone
        "gnss_accuracy_m":           rng.uniform(10, 45, n_no_charge),    # degraded GPS
        "gnss_lost_ratio":           rng.beta(3, 4,    n_no_charge),      # signal issues
        TARGET_COL: "no_charge",
    })

    df = pd.concat([charge, no_charge], ignore_index=True).sample(
        frac=1, random_state=seed
    )

    # Clip to realistic bounds
    df["distance_to_zone_m"]        = df["distance_to_zone_m"].clip(0, 100)
    df["gnss_accuracy_m"]           = df["gnss_accuracy_m"].clip(3, 50)
    df["ml1_non_street_confidence"] = df["ml1_non_street_confidence"].clip(0, 1)
    df["gnss_lost_ratio"]           = df["gnss_lost_ratio"].clip(0, 1)

    log.info(
        "Synthetic data generated: %d samples  |  charge=%d  no_charge=%d",
        len(df),
        (df[TARGET_COL] == "charge").sum(),
        (df[TARGET_COL] == "no_charge").sum(),
    )
    return df


# ─────────────────────────────────────────────────────────────────────────────
# DATA LOADING
# ─────────────────────────────────────────────────────────────────────────────

def load_data(
    train_path: Path,
    val_path: Path,
) -> tuple[pd.DataFrame, pd.Series, pd.DataFrame, pd.Series]:
    """Load CSV files. Falls back to synthetic data if files don't exist."""
    if train_path.exists() and val_path.exists():
        log.info("Loading real data: %s / %s", train_path, val_path)
        train_df = pd.read_csv(train_path)
        val_df   = pd.read_csv(val_path)
    else:
        log.warning(
            "Data files not found at %s — using SYNTHETIC data. "
            "Replace with real collection_sessions data before demo.",
            DATA_DIR,
        )
        full_df  = generate_synthetic_data()
        # 80/20 split, stratified
        from sklearn.model_selection import train_test_split
        train_df, val_df = train_test_split(
            full_df, test_size=0.2, random_state=42,
            stratify=full_df[TARGET_COL]
        )

    # Validate that required columns exist
    missing = [c for c in FEATURE_COLS + [TARGET_COL] if c not in train_df.columns]
    if missing:
        raise ValueError(f"Missing columns in training data: {missing}")

    X_train = train_df[FEATURE_COLS].copy()
    y_train = train_df[TARGET_COL].copy()
    X_val   = val_df[FEATURE_COLS].copy()
    y_val   = val_df[TARGET_COL].copy()

    log.info(
        "Train: %d rows  |  Val: %d rows  |  Features: %d",
        len(X_train), len(X_val), len(FEATURE_COLS),
    )
    return X_train, y_train, X_val, y_val


def encode_labels(
    y_train: pd.Series,
    y_val: pd.Series,
) -> tuple[np.ndarray, np.ndarray]:
    """Encode 'charge' → 1, 'no_charge' → 0."""
    valid = {"charge", "no_charge"}
    for name, y in [("train", y_train), ("val", y_val)]:
        unknown = set(y.unique()) - valid
        if unknown:
            raise ValueError(f"Unknown labels in {name} set: {unknown}")

    y_train_enc = (y_train == "charge").astype(int).values
    y_val_enc   = (y_val   == "charge").astype(int).values
    return y_train_enc, y_val_enc


# ─────────────────────────────────────────────────────────────────────────────
# CROSS-VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

def run_cv(X: pd.DataFrame, y_enc: np.ndarray) -> int:
    """
    Stratified k-fold CV with early stopping.
    Returns the mean best n_estimators across folds.
    """
    log.info("── %d-fold Stratified CV ──", CV_FOLDS)
    skf = StratifiedKFold(n_splits=CV_FOLDS, shuffle=True, random_state=42)

    best_iterations = []
    fold_f1s        = []

    for fold, (train_idx, val_idx) in enumerate(skf.split(X, y_enc), 1):
        X_tr, X_vl = X.iloc[train_idx], X.iloc[val_idx]
        y_tr, y_vl = y_enc[train_idx],  y_enc[val_idx]

        model = lgb.LGBMClassifier(**LGBM_PARAMS)
        model.fit(
            X_tr, y_tr,
            eval_set=[(X_vl, y_vl)],
            callbacks=[
                lgb.early_stopping(EARLY_STOPPING_ROUNDS, verbose=False),
                lgb.log_evaluation(period=-1),
            ],
        )

        best_iter = model.best_iteration_
        best_iterations.append(best_iter)

        y_pred = model.predict(X_vl)
        f1     = f1_score(y_vl, y_pred, zero_division=0)
        fold_f1s.append(f1)
        log.info("  Fold %d: best_iter=%4d  F1=%.4f", fold, best_iter, f1)

    mean_best_iter = int(np.mean(best_iterations))
    log.info(
        "  Mean F1: %.4f ± %.4f  |  Best n_estimators: %d",
        np.mean(fold_f1s), np.std(fold_f1s), mean_best_iter,
    )
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
) -> lgb.LGBMClassifier:
    log.info("── Final model training (n_estimators=%d) ──", n_estimators)
    params = {**LGBM_PARAMS, "n_estimators": n_estimators}
    model  = lgb.LGBMClassifier(**params)
    model.fit(
        X_train, y_train_enc,
        eval_set=[(X_val, y_val_enc)],
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
) -> dict:
    y_pred  = model.predict(X_val)
    y_proba = model.predict_proba(X_val)[:, 1]  # P(charge)

    log.info("── Classification Report ──")
    print(classification_report(
        y_val_enc, y_pred,
        target_names=["no_charge", "charge"],
        zero_division=0,
    ))

    log.info("── Confusion Matrix ──")
    cm = confusion_matrix(y_val_enc, y_pred)
    cm_df = pd.DataFrame(
        cm,
        index=["actual: no_charge", "actual: charge"],
        columns=["pred: no_charge", "pred: charge"],
    )
    print(cm_df.to_string())

    binary_f1 = f1_score(y_val_enc, y_pred, zero_division=0)
    roc_auc   = roc_auc_score(y_val_enc, y_proba)
    log.info("  Binary F1 : %.4f", binary_f1)
    log.info("  ROC-AUC   : %.4f", roc_auc)

    return {
        "binary_f1":  round(float(binary_f1), 4),
        "roc_auc":    round(float(roc_auc), 4),
        "y_proba":    y_proba,
        "y_pred":     y_pred,
    }


# ─────────────────────────────────────────────────────────────────────────────
# THRESHOLD ANALYSIS
# ─────────────────────────────────────────────────────────────────────────────

def threshold_analysis(y_proba: np.ndarray, y_val_enc: np.ndarray) -> float:
    """
    Analyse precision/recall trade-off for the charge_confidence score.

    For AutoPark, the cost asymmetry is:
      False positive  → charging someone in a private garage → HIGH cost
                        (user complaint, legal exposure, trust damage)
      False negative  → not charging a legitimate street parker → LOW cost
                        (revenue loss, but no harm to user)

    Therefore: MAXIMISE PRECISION (minimise false positives).
    The threshold should be high enough that when we charge, we are almost
    certain it is a legitimate street parking session.

    Operating recommendation: threshold ≥ 0.85 for shadow mode.
    Confirm with Brisa/Via Verde before lowering for production.
    """
    log.info("── Charge Confidence Threshold Analysis ──")

    precision, recall, thresholds = precision_recall_curve(y_val_enc, y_proba)

    print(f"\n  {'Threshold':>10}  {'Precision':>10}  {'Recall':>10}  {'F1':>10}")
    print("  " + "-" * 46)
    for t, p, r in zip(thresholds[::max(1, len(thresholds) // 20)],
                        precision[::max(1, len(thresholds) // 20)],
                        recall[::max(1, len(thresholds) // 20)]):
        f1 = 2 * p * r / (p + r) if (p + r) > 0 else 0.0
        print(f"  {t:>10.3f}  {p:>10.3f}  {r:>10.3f}  {f1:>10.3f}")

    # Best threshold by F1
    f1_scores = np.where(
        (precision[:-1] + recall[:-1]) > 0,
        2 * precision[:-1] * recall[:-1] / (precision[:-1] + recall[:-1]),
        0.0,
    )
    best_idx = int(np.argmax(f1_scores))
    best_t   = float(thresholds[best_idx])

    # High-precision threshold: first point where precision ≥ 0.95
    high_precision_mask = precision[:-1] >= 0.95
    if high_precision_mask.any():
        hp_idx = int(np.argmax(high_precision_mask))
        hp_t   = float(thresholds[hp_idx])
        log.info(
            "  High-precision threshold (P≥0.95): %.3f  (Recall=%.3f)",
            hp_t, recall[hp_idx],
        )
    else:
        hp_t = best_t
        log.warning("  Precision never reaches 0.95 — using best-F1 threshold")

    log.info(
        "  Best F1 threshold : %.3f  (P=%.3f, R=%.3f, F1=%.3f)",
        best_t, precision[best_idx], recall[best_idx], f1_scores[best_idx],
    )
    log.info(
        "  → Recommended for shadow mode: charge_threshold = %.2f",
        hp_t,
    )
    log.info(
        "  → Set SPATIAL_CHARGE_THRESHOLD = %.2f in your FastAPI config",
        hp_t,
    )
    return hp_t


# ─────────────────────────────────────────────────────────────────────────────
# SHAP FEATURE IMPORTANCE
# ─────────────────────────────────────────────────────────────────────────────

def shap_analysis(model: lgb.LGBMClassifier, X_val: pd.DataFrame) -> None:
    log.info("── SHAP Feature Importance ──")
    try:
        explainer  = shap.TreeExplainer(model)
        sample     = X_val.sample(min(500, len(X_val)), random_state=42)
        shap_vals  = explainer.shap_values(sample)

        # shap_values for binary LightGBM is a single 2-D array
        if isinstance(shap_vals, list):
            shap_vals = shap_vals[1]  # positive class

        importance_df = pd.DataFrame({
            "feature":       FEATURE_COLS,
            "mean_abs_shap": np.abs(shap_vals).mean(axis=0),
        }).sort_values("mean_abs_shap", ascending=False)

        print(importance_df.to_string(index=False))

    except Exception as exc:
        log.warning("SHAP could not be calculated: %s — continuing.", exc)


# ─────────────────────────────────────────────────────────────────────────────
# SAVE ARTIFACT
# ─────────────────────────────────────────────────────────────────────────────

def save_artifact(
    model: lgb.LGBMClassifier,
    charge_threshold: float,
    metrics: dict,
    out_path: Path,
) -> None:
    """
    Bundle schema — must match spatial_ml_predict.py expectations:
        bundle["model"]            — fitted LGBMClassifier
        bundle["features"]         — list[str], same order as training
        bundle["classes"]          — ["no_charge", "charge"]
        bundle["charge_threshold"] — recommended operating threshold
        bundle["metrics"]          — val metrics for model_versions table
    """
    bundle = {
        "model":            model,
        "features":         FEATURE_COLS,
        "classes":          ["no_charge", "charge"],
        "charge_threshold": charge_threshold,
        "metrics":          metrics,
    }
    joblib.dump(bundle, out_path)
    log.info("Model artifact saved → %s", out_path)

    # JSON summary for automatic insert into model_versions table
    summary = {
        "model_name":       "spatial_classifier",
        "version_tag":      "v1.0.0-lgbm",
        "artifact_path":    str(out_path),
        "feature_names":    FEATURE_COLS,
        "classes":          ["no_charge", "charge"],
        "charge_threshold": charge_threshold,
        "val_f1_score":     metrics["binary_f1"],
        "val_roc_auc":      metrics["roc_auc"],
        "val_samples":      metrics["val_samples"],
        "train_samples":    metrics["train_samples"],
        "lgbm_params":      LGBM_PARAMS,
        "data_source":      metrics.get("data_source", "synthetic"),
    }
    summary_path = out_path.parent / "spatial_decision_lgbm_summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    log.info("Summary JSON saved → %s", summary_path)


# ─────────────────────────────────────────────────────────────────────────────
# PREDICT INTERFACE VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────

def verify_predict_interface(artifact_path: Path) -> None:
    """
    Loads the saved bundle and runs two mock payloads to verify compatibility
    with spatial_ml_predict.py.

    Case A: clear street parking → should predict "charge"
    Case B: clear garage profile  → should predict "no_charge"
    """
    log.info("── Predict Interface Verification ──")
    bundle    = joblib.load(artifact_path)
    model     = bundle["model"]
    features  = bundle["features"]
    threshold = bundle["charge_threshold"]

    cases = [
        {
            "label": "Case A — Street parking (expect: charge)",
            "payload": {
                "ml1_non_street_confidence": 0.08,  # Model 1: clearly street
                "distance_to_zone_m":        2.5,   # inside paid zone
                "gnss_accuracy_m":           8.0,   # good GPS
                "gnss_lost_ratio":           0.02,  # signal stable
            },
            "expected": "charge",
        },
        {
            "label": "Case B — Garage profile (expect: no_charge)",
            "payload": {
                "ml1_non_street_confidence": 0.82,  # Model 1: clearly not street
                "distance_to_zone_m":        35.0,  # far from zone
                "gnss_accuracy_m":           38.0,  # degraded GPS
                "gnss_lost_ratio":           0.60,  # signal lost often
            },
            "expected": "no_charge",
        },
    ]

    all_passed = True
    for case in cases:
        row   = {f: case["payload"].get(f, np.nan) for f in features}
        X     = pd.DataFrame([row], columns=features).astype(float)
        proba = float(model.predict_proba(X)[0][1])  # P(charge)
        decision = "charge" if proba >= threshold else "no_charge"
        passed   = "✓" if decision == case["expected"] else "✗"
        if decision != case["expected"]:
            all_passed = False
        log.info(
            "  %s  %s | charge_confidence=%.4f | threshold=%.2f | decision=%s",
            passed, case["label"], proba, threshold, decision,
        )

    if all_passed:
        log.info("  All cases passed — compatible with spatial_ml_predict.py")
    else:
        log.warning(
            "  One or more cases failed. This is expected with synthetic data. "
            "Re-run after training on real collection_sessions data."
        )


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main(train_path: Path, val_path: Path, out_path: Path) -> None:
    print("=" * 65)
    print("  Urban Layered Intelligence — Spatial Decision LightGBM Trainer")
    print("=" * 65)

    # 1. Load data (real or synthetic fallback)
    X_train, y_train, X_val, y_val = load_data(train_path, val_path)

    data_source = "real" if train_path.exists() else "synthetic"

    # 2. Encode labels
    y_train_enc, y_val_enc = encode_labels(y_train, y_val)

    # 3. CV → best n_estimators
    best_n = run_cv(X_train, y_train_enc)

    # 4. Train final model
    model = train_final_model(X_train, y_train_enc, X_val, y_val_enc, best_n)

    # 5. Evaluate
    eval_results = evaluate(model, X_val, y_val_enc)

    # 6. Threshold analysis
    charge_threshold = threshold_analysis(eval_results["y_proba"], y_val_enc)

    # 7. SHAP
    shap_analysis(model, X_val)

    # 8. Collect metrics
    metrics = {
        "binary_f1":    eval_results["binary_f1"],
        "roc_auc":      eval_results["roc_auc"],
        "val_samples":  len(X_val),
        "train_samples": len(X_train),
        "data_source":  data_source,
    }

    # 9. Save artifact + summary JSON
    save_artifact(model, charge_threshold, metrics, out_path)

    # 10. Verify predict interface
    verify_predict_interface(out_path)

    print("\n" + "=" * 65)
    print("  Training complete.")
    print(f"  Val F1              : {metrics['binary_f1']:.4f}")
    print(f"  Val ROC-AUC         : {metrics['roc_auc']:.4f}")
    print(f"  Charge threshold    : {charge_threshold:.3f}")
    print(f"  Data source         : {data_source}")
    print(f"  Model artifact      : {out_path}")
    print("=" * 65)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Train LightGBM Spatial Decision Classifier (Model 2)"
    )
    parser.add_argument("--train", type=Path, default=DEFAULT_TRAIN,
                        help="Path to training CSV (default: synthetic fallback)")
    parser.add_argument("--val",   type=Path, default=DEFAULT_VAL,
                        help="Path to validation CSV (default: synthetic fallback)")
    parser.add_argument("--out",   type=Path, default=DEFAULT_OUT,
                        help="Output path for .joblib artifact")
    args = parser.parse_args()

    main(train_path=args.train, val_path=args.val, out_path=args.out)