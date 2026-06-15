import numpy as np
import pandas as pd

""" 
gps_accuracy_mean	-> average GPS accuracy during the time window; higher value means worse location precision
gps_accuracy_max	-> worst GPS accuracy value recorded during the time window
gps_accuracy_delta	-> difference between GPS accuracy at the end and at the start of the window; shows GPS degradation
gps_lost_ratio		-> percentage of the window where GPS was unavailable or invalid

wifi_count_mean		-> average number of visible Wi-Fi networks during the window
wifi_count_delta	-> difference between the number of visible Wi-Fi networks at the end and at the start
wifi_rssi_mean		-> average Wi-Fi signal strength; more negative RSSI means weaker signal

ble_count_mean		-> average number of visible Bluetooth/BLE devices
ble_count_delta		-> difference between the number of visible BLE devices at the end and at the start of the window
ble_rssi_mean		-> average Bluetooth/BLE signal strength; more negative RSSI means weaker signal

pressure_delta		-> difference in atmospheric pressure between the end and the start of the window; helps detect
pressure_slope		-> pressure trend during the window; indicates gradual upward or downward movement

altitude_delta		-> altitude difference between the end and the start of the window
vertical_change_abs	-> absolute vertical movement during the window

stationary_ratio	-> percentage of the window where the user/car was stationary
label 				-> manually assigned ground-truth label: street or underground
"""

def generate_street_level_sample():
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

        "altitude_delta": np.random.uniform(-0.5, 0.5),
        "vertical_change_abs": np.random.uniform(0.0, 0.8),

        "stationary_ratio": np.random.uniform(0.5, 1.0),
        "label": "street_level",
    }

def generate_hilly_street_level_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(8, 25),
        "gps_accuracy_max": np.random.uniform(15, 45),
        "gps_accuracy_delta": np.random.uniform(4, 18),
        "gps_lost_ratio": np.random.uniform(0.02, 0.22),

        "wifi_count_mean": np.random.uniform(10, 28),
        "wifi_count_delta": np.random.uniform(-4, 4),
        "wifi_rssi_mean": np.random.uniform(-78, -50),

        "ble_count_mean": np.random.uniform(3, 14),
        "ble_count_delta": np.random.uniform(-3, 3),
        "ble_rssi_mean": np.random.uniform(-85, -55),

        "pressure_delta": np.random.uniform(-0.8, 0.8),
        "pressure_slope": np.random.uniform(-0.10, 0.10),

        "altitude_delta": np.random.uniform(-6.0, 6.0),
        "vertical_change_abs": np.random.uniform(1.0, 6.0),

        "stationary_ratio": np.random.uniform(0.4, 0.9),
        "label": "street_level",
    }

def generate_bad_gps_street_level_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(12, 35),
        "gps_accuracy_max": np.random.uniform(20, 60),
        "gps_accuracy_delta": np.random.uniform(8, 25),
        "gps_lost_ratio": np.random.uniform(0.10, 0.35),

        "wifi_count_mean": np.random.uniform(8, 25),
        "wifi_count_delta": np.random.uniform(-5, 5),
        "wifi_rssi_mean": np.random.uniform(-80, -50),

        "ble_count_mean": np.random.uniform(3, 12),
        "ble_count_delta": np.random.uniform(-4, 4),
        "ble_rssi_mean": np.random.uniform(-85, -55),

        "pressure_delta": np.random.uniform(-0.10, 0.20),
        "pressure_slope": np.random.uniform(-0.03, 0.04),

        "altitude_delta": np.random.uniform(-1.5, 1.5),
        "vertical_change_abs": np.random.uniform(0.0, 2.0),

        "stationary_ratio": np.random.uniform(0.5, 1.0),
        "label": "street_level",
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

        "altitude_delta": np.random.uniform(-8.0, -1.5),
        "vertical_change_abs": np.random.uniform(1.5, 8.0),

        "stationary_ratio": np.random.uniform(0.4, 1.0),
        "label": "underground",
    }

def generate_weak_underground_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(15, 45),
        "gps_accuracy_max": np.random.uniform(25, 80),
        "gps_accuracy_delta": np.random.uniform(10, 40),
        "gps_lost_ratio": np.random.uniform(0.20, 0.60),

        "wifi_count_mean": np.random.uniform(3, 15),
        "wifi_count_delta": np.random.uniform(-12, 2),
        "wifi_rssi_mean": np.random.uniform(-90, -58),

        "ble_count_mean": np.random.uniform(1, 10),
        "ble_count_delta": np.random.uniform(-8, 2),
        "ble_rssi_mean": np.random.uniform(-95, -60),

        "pressure_delta": np.random.uniform(0.15, 0.70),
        "pressure_slope": np.random.uniform(0.02, 0.12),

        "altitude_delta": np.random.uniform(-4.0, -0.8),
        "vertical_change_abs": np.random.uniform(0.8, 4.0),

        "stationary_ratio": np.random.uniform(0.4, 1.0),
        "label": "underground",
    }

def generate_above_sample():
    return {
        "gps_accuracy_mean": np.random.uniform(12, 45),
        "gps_accuracy_max": np.random.uniform(25, 80),
        "gps_accuracy_delta": np.random.uniform(8, 35),
        "gps_lost_ratio": np.random.uniform(0.10, 0.50),

        "wifi_count_mean": np.random.uniform(3, 18),
        "wifi_count_delta": np.random.uniform(-8, 6),
        "wifi_rssi_mean": np.random.uniform(-88, -55),

        "ble_count_mean": np.random.uniform(1, 12),
        "ble_count_delta": np.random.uniform(-6, 5),
        "ble_rssi_mean": np.random.uniform(-92, -58),

        "pressure_delta": np.random.uniform(-1.5, -0.25),
        "pressure_slope": np.random.uniform(-0.25, -0.04),

        "altitude_delta": np.random.uniform(1.5, 8.0),
        "vertical_change_abs": np.random.uniform(1.5, 8.0),

        "stationary_ratio": np.random.uniform(0.4, 1.0),
        "label": "above",
    }

def main():
    import os

    os.makedirs("data", exist_ok=True)

    samples = []

    for _ in range(350):
        samples.append(generate_street_level_sample())

    for _ in range(300):
        samples.append(generate_bad_gps_street_level_sample())

    for _ in range(350):
        samples.append(generate_hilly_street_level_sample())

    for _ in range(350):
        samples.append(generate_underground_sample())

    for _ in range(250):
        samples.append(generate_weak_underground_sample())

    for _ in range(350):
        samples.append(generate_above_sample())

    df = pd.DataFrame(samples)
    df = df.sample(frac=1, random_state=42)

    df.to_csv("data/synthetic_data.csv", index=False)
    print("Saved data/synthetic_data.csv")


if __name__ == "__main__":
    main()
