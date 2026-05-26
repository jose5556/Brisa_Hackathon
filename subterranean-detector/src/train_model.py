import joblib
import pandas as pd

from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import classification_report
from sklearn.model_selection import train_test_split


FEATURES = [
    "gps_accuracy_mean",
    "gps_accuracy_max",
    "gps_accuracy_delta",
    "gps_lost_ratio",

    "wifi_count_mean",
    "wifi_count_delta",
    "wifi_rssi_mean",

    "ble_count_mean",
    "ble_count_delta",
    "ble_rssi_mean",

    "pressure_delta",
    "pressure_slope",

    "stationary_ratio",
]


def main():
    df = pd.read_csv("data/synthetic_data.csv")

    X = df[FEATURES]
    y = df["label"]

    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=0.2,
        random_state=42,
        stratify=y,
    )

    model = RandomForestClassifier(
        n_estimators=200,
        max_depth=8,
        random_state=42,
        class_weight="balanced",
    )

    model.fit(X_train, y_train)

    predictions = model.predict(X_test)

    print(classification_report(y_test, predictions))

    joblib.dump(
        {
            "model": model,
            "features": FEATURES,
        },
        "models/subterranean_rf.joblib",
    )

    print("Saved models/subterranean_rf.joblib")


if __name__ == "__main__":
    main()