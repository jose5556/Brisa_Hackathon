import pandas as pd
import numpy as np
import lightgbm as lgb
import joblib
from pathlib import Path
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report

# ── Genarating synthetic data(simulation the reality) ──
np.random.seed(42)
n_samples = 5000

# Features
ml1_confidence = np.random.uniform(0.0, 1.0, n_samples) # 0 = street, 1 = underground
gnss_accuracy = np.random.uniform(3.0, 40.0, n_samples) # Error of GPS in meters
distance_to_zone = np.random.uniform(0.0, 50.0, n_samples) # Distance to zone in meters

# Real-world logic to create the ground truth (Target)
labels = []
for conf, acc, dist in zip(ml1_confidence, gnss_accuracy, distance_to_zone):
    # If ML1 says it's not street_level (confidence > 0.54), NEVER charge
    if conf > 0.54:
        labels.append("Don't charge")
    # If it's on the street and exactly within the zone (very small distance)
    elif dist <= (acc * 0.5): # GPS justifies the distance
        labels.append("Charge")
    else:
        labels.append("Don't charge")

df = pd.DataFrame({
    "ml1_non_street_confidence": ml1_confidence,
    "gnss_accuracy_m": gnss_accuracy,
    "distance_to_zone_m": distance_to_zone,
    "label": labels
})

# ── Model Training ──
FEATURE_COLS = ["ml1_non_street_confidence", "gnss_accuracy_m", "distance_to_zone_m"]
X = df[FEATURE_COLS]
y = (df["label"] == "Charge").astype(int) # 1 = charge, 0 = don't charge

X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.2, random_state=42)

model = lgb.LGBMClassifier(n_estimators=100, learning_rate=0.05, max_depth=5, random_state=42, verbose=0)
model.fit(X_train, y_train)

# ── evaluation and saving ──
y_pred = model.predict(X_val)
print("── Classification Report (Model 2) ──")
print(
    classification_report(
        y_val,
        y_pred,
        labels=[0, 1],
        target_names=["Don't charge", "Charge"],
        zero_division=0,
    )
)

# Store the bundle
MODEL_DIR = Path("../models")
MODEL_DIR.mkdir(exist_ok=True)
out_path = MODEL_DIR / "spatial_decision_lgbm.joblib"

bundle = {
    "model": model,
    "features": FEATURE_COLS,
    "classes": ["Don't charge", "Charge"]
}
joblib.dump(bundle, out_path)
print(f"Model 2 saved successfully in {out_path}")