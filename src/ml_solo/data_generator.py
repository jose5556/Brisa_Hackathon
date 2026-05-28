import pandas as pd
import numpy as np

def generate_realistic_data(n_samples=3000):
    np.random.seed(42)
    data = []
    
    for _ in range(n_samples):
        class_label = np.random.choice([0, 1, 2])
        
        # Adding overlapping noise to simulate real-world sensor degradation
        if class_label == 0:  # Street
            baro = np.random.normal(0.0, 0.4) # Increased variance
            # 15% of drivers park head-in without making a parallel parking maneuver
            gyro = np.random.normal(1.8, 1.2) if np.random.rand() < 0.15 else np.random.normal(5.0, 0.8)
            gps_snr = np.random.normal(0.35, 0.15)
            
        elif class_label == 1:  # Surface Garage
            baro = np.random.normal(0.1, 0.4)
            # Some garage entries require sharp 90-degree turns that mimic high gyro
            gyro = np.random.normal(3.5, 0.8) if np.random.rand() < 0.10 else np.random.normal(1.5, 0.5)
            gps_snr = np.random.normal(0.45, 0.15)
            
        else:  # Subterranean
            # Shallow underground parkings might have low baro delta
            baro = np.random.normal(1.8, 0.8) if np.random.rand() < 0.10 else np.random.normal(3.5, 0.5)
            gyro = np.random.normal(3.0, 0.6)
            gps_snr = np.random.normal(0.85, 0.15)
            
        data.append([baro, gyro, gps_snr, class_label])
        
    return pd.DataFrame(data, columns=['baro_delta', 'gyro_energy', 'gps_snr_drop', 'label'])

df = generate_realistic_data()
df.to_csv('parking_data.csv', index=False)
print("Realistic noisy data generated successfully.")