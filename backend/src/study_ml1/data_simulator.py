import pandas as pd
import numpy as np
import uuid
import random

def generate_nightmare_urban_data(n_samples=5000):
    np.random.seed(42)
    random.seed(42)
    
    data = []
    weather_options = ['clear', 'rain', 'overcast']
    time_options = ['morning', 'afternoon', 'evening', 'night']
    
    for _ in range(n_samples):
        label_name = random.choice(['street_level', 'underground', 'above'])
        session_id = str(uuid.uuid4())
        window_duration_s = 60.0
        weather = random.choice(weather_options)
        time_of_day = random.choice(time_options)
        city_baseline_pressure = np.random.uniform(990.0, 1018.0)
        
        # Massive base noise on all mobile devices
        hardware_noise_pressure = np.random.normal(0.0, 0.15)
        
        if label_name == 'street_level':
            is_steep_slope = np.random.rand() < 0.40
            pressure_delta_hpa = np.random.normal(0.0, 1.5) if is_steep_slope else np.random.normal(0.0, 0.2)
            pressure_variance = np.random.uniform(0.05, 0.8) if is_steep_slope else np.random.uniform(0.01, 0.15)
            
            has_magnetic_anomaly = np.random.rand() < 0.40
            mag_variance_total = np.random.normal(50.0, 30.0) if has_magnetic_anomaly else np.random.normal(25.0, 15.0)
            mag_distortion_score = np.random.normal(0.5, 0.3)
            
            gnss_signal_drop = np.random.rand() < 0.35
            gnss_accuracy_m = np.random.normal(45.0, 20.0) if gnss_signal_drop else np.random.normal(12.0, 8.0)
            hdop = np.random.normal(8.0, 4.0) if gnss_signal_drop else np.random.normal(2.0, 1.5)
            satellite_count = int(np.random.normal(3, 2)) if gnss_signal_drop else int(np.random.normal(12, 5))
            
        elif label_name == 'underground':
            is_shallow = np.random.rand() < 0.40
            floors_down = np.random.uniform(0.05, 0.5) if is_shallow else np.random.uniform(1.0, 3.5)
            pressure_delta_hpa = floors_down * 0.36 + np.random.normal(0, 0.2)
            pressure_variance = np.random.uniform(0.1, 0.7)
            
            mag_variance_total = np.random.normal(70.0, 25.0)
            mag_distortion_score = np.random.normal(0.7, 0.2)

            gps_survives = np.random.rand() < 0.40
            gnss_signal_drop = False if gps_survives else True
            gnss_accuracy_m = np.random.normal(18.0, 10.0) if gps_survives else np.random.normal(60.0, 20.0)
            hdop = np.random.normal(4.0, 2.0) if gps_survives else np.random.normal(12.0, 3.0)
            satellite_count = int(np.random.normal(8, 4)) if gps_survives else int(np.random.normal(0, 1))
            
        else: # 'above'
            is_open_rooftop = np.random.rand() < 0.50
            floors_up = np.random.uniform(0.5, 4.0)
            pressure_delta_hpa = -(floors_up * 0.36) + np.random.normal(0, 0.2)
            pressure_variance = np.random.uniform(0.1, 0.6)
            
            mag_variance_total = np.random.normal(65.0, 25.0)
            mag_distortion_score = np.random.normal(0.65, 0.25)
            
            gnss_signal_drop = False if is_open_rooftop else True
            gnss_accuracy_m = np.random.normal(10.0, 5.0) if is_open_rooftop else np.random.normal(45.0, 15.0)
            hdop = np.random.normal(2.0, 1.0) if is_open_rooftop else np.random.normal(9.0, 2.5)
            satellite_count = int(np.random.normal(14, 4)) if is_open_rooftop else int(np.random.normal(2, 2))

        pressure_delta_hpa += hardware_noise_pressure
        
        mag_distortion_score = np.clip(mag_distortion_score, 0.0, 1.0)
        satellite_count = max(0, min(int(satellite_count), 24))
        gnss_accuracy_m = max(1.0, gnss_accuracy_m)
        altitude_change_m = round(-pressure_delta_hpa * 8.3, 3)
        pressure_hpa = round(city_baseline_pressure + pressure_delta_hpa, 3)
        
        mag_x = round(np.random.normal(20.0, 15.0), 4)
        mag_y = round(np.random.normal(-10.0, 15.0), 4)
        mag_z = round(np.random.normal(40.0, 15.0), 4)

        data.append([
            session_id, window_duration_s, 
            pressure_hpa, round(pressure_delta_hpa, 4), round(pressure_variance, 6), 
            altitude_change_m, round(city_baseline_pressure, 3),
            mag_x, mag_y, mag_z, round(mag_variance_total, 6), round(mag_distortion_score, 4),
            round(gnss_accuracy_m, 2), round(hdop, 2), satellite_count, gnss_signal_drop,
            weather, time_of_day, label_name
        ])
        
    columns = [
        'session_id', 'window_duration_s', 'pressure_hpa', 'pressure_delta_hpa', 'pressure_variance', 
        'altitude_change_m', 'city_baseline_pressure', 'mag_x', 'mag_y', 'mag_z', 'mag_variance_total', 
        'mag_distortion_score', 'gnss_accuracy_m', 'hdop', 'satellite_count', 'gnss_signal_drop',
        'weather_condition', 'time_of_day', 'label_ground_truth'
    ]
    
    df = pd.DataFrame(data, columns=columns)
    return df

print("Generating new dataset...")
df_simulado = generate_nightmare_urban_data(5000)
df_simulado.to_csv('sensor_payloads_simulated.csv', index=False)
print("Dataset saved!")