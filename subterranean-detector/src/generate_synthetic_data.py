import numpy as np
import pandas as pd

def generate_street_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(4, 12),
        "gps_accuracy_max": np.random.uniform(8, 18),
        "gps_accuracy_delta": np.random.uniform(0, 6),
        "gps_lost_ratio": np.random.uniform(0, 0.15),

        "wifi_count_mean": np.random.uniform(8, 25),
        "wifi_count_delta": np.random.uniform(-4, 4),
        "wifi_rssi_mean": np.random.uniform(-75, -45),

        "ble_count_mean": np.random.uniform(2, 12),
        "ble_count_delta": np.random.uniform(-3, 3),
        "ble_rssi_mean": np.random.uniform(-85, -50),

        "pressure_delta": np.random.uniform(-0.15, 0.15),
        "pressure_slope": np.random.uniform(-0.03, 0.03),

        "stationary_ratio": np.random.uniform(0.5, 1.0),
        "label": "street",
    }

def generate_underground_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(20, 90),
        "gps_accuracy_max": np.random.uniform(40, 120),
        "gps_accuracy_delta": np.random.uniform(15, 80),
        "gps_lost_ratio": np.random.uniform(0.35, 1.0),

        "wifi_count_mean": np.random.uniform(0, 10),
        "wifi_count_delta": np.random.uniform(-20, 3),
        "wifi_rssi_mean": np.random.uniform(-90, -60),

        "ble_count_mean": np.random.uniform(0, 8),
        "ble_count_delta": np.random.uniform(-12, 3),
        "ble_rssi_mean": np.random.uniform(-95, -65),

        "pressure_delta": np.random.uniform(0.25, 1.5),
        "pressure_slope": np.random.uniform(0.04, 0.25),

        "stationary_ratio": np.random.uniform(0.4, 1.0),
        "label": "underground",
    }

def generate_ambiguous_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(12, 30),
        "gps_accuracy_max": np.random.uniform(20, 55),
        "gps_accuracy_delta": np.random.uniform(8, 25),
        "gps_lost_ratio": np.random.uniform(0.12, 0.40),

        "wifi_count_mean": np.random.uniform(6, 16),
        "wifi_count_delta": np.random.uniform(-8, 3),
        "wifi_rssi_mean": np.random.uniform(-82, -58),

        "ble_count_mean": np.random.uniform(3, 10),
        "ble_count_delta": np.random.uniform(-6, 2),
        "ble_rssi_mean": np.random.uniform(-88, -60),

        "pressure_delta": np.random.uniform(0.10, 0.40),
        "pressure_slope": np.random.uniform(0.01, 0.08),

        "stationary_ratio": np.random.uniform(0.4, 1.0),
        "label": "ambiguous",
    }


def main():
    samples = []

    for _ in range(500):
        samples.append(generate_street_sample())

    for _ in range(500):
        samples.append(generate_underground_sample())

    for _ in range(500):
    	samples.append(generate_ambiguous_sample())

    df = pd.DataFrame(samples)
    df = df.sample(frac=1, random_state=42)

    df.to_csv("data/synthetic_data.csv", index=False)
    print("Saved data/synthetic_data.csv")


if __name__ == "__main__":
    main()