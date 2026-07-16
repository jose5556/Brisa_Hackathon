import numpy as np
import pandas as pd

# 1. Global settings
np.random.seed(42)  # Ensure reproducibility
hz = 1  # Sampling frequency (1 reading per second)

# Definition of the real geographic points (Latitude, Longitude, Altitude in meters)
waypoints = {
    "Ponte_Luiz_I": (41.1415, -8.6110, 60.0),
    "Rua_da_Picaria_5": (41.1486, -8.6122, 90.0),
    "Silo_Auto_Entrada": (41.1523, -8.6094, 95.0),
    "Silo_Auto_Topo": (41.1523, -8.6094, 116.0),  # ~21 m climb through the ramps
    "Alameda_Entrada": (41.1625, -8.5835, 100.0),
    "Alameda_Subterraneo": (41.1625, -8.5835, 85.0),  # Descent to level -2 or -3
}

# Estimated travel times for each segment (in seconds)
segment_times = [
    180,  # Ponte Luiz I -> Picaria (downtown urban traffic)
    90,  # Picaria -> Silo Auto
    60,  # Climb the Silo Auto ramps to the top floor
    240,  # Silo Auto -> Alameda Shopping (via Gonçalo Cristóvão / VCI)
    45,  # Descent into the underground Alameda parking lot
]

total_seconds = sum(segment_times)
time_vector = np.arange(0, total_seconds, 1 / hz)

# 2. Interpolation of the ideal trajectory (ground truth)
lat_gt, lon_gt, alt_gt = [], [], []


def interpolate_segment(start, end, steps):
    lats = np.linspace(start[0], end[0], steps)
    lons = np.linspace(start[1], end[1], steps)
    alts = np.linspace(start[2], end[2], steps)
    return lats, lons, alts


# Build the path point by point
l1, ln1, a1 = interpolate_segment(
    waypoints["Ponte_Luiz_I"], waypoints["Rua_da_Picaria_5"], segment_times[0]
)
l2, ln2, a2 = interpolate_segment(
    waypoints["Rua_da_Picaria_5"],
    waypoints["Silo_Auto_Entrada"],
    segment_times[1],
)
l3, ln3, a3 = interpolate_segment(
    waypoints["Silo_Auto_Entrada"], waypoints["Silo_Auto_Topo"], segment_times[2]
)
l4, ln4, a4 = interpolate_segment(
    waypoints["Silo_Auto_Topo"], waypoints["Alameda_Entrada"], segment_times[3]
)
l5, ln5, a5 = interpolate_segment(
    waypoints["Alameda_Entrada"],
    waypoints["Alameda_Subterraneo"],
    segment_times[4],
)

lat_gt = np.concatenate([l1, l2, l3, l4, l5])
lon_gt = np.concatenate([ln1, ln2, ln3, ln4, ln5])
alt_gt = np.concatenate([a1, a2, a3, a4, a5])

# 3. Sensor simulation with real physical phenomena
# --- BAROMETER ---
# P = P0 * (1 - 0.00012 * alt). Standard sea-level pressure is ~1013.25 hPa
# The barometer is continuous and works even inside tunnels and buildings.
baro_noise = np.random.normal(0, 0.05, total_seconds)
pressure = 1013.25 - (0.12 * alt_gt) + baro_noise

# --- MAGNETOMETER (X, Y, Z axes in microTesla) ---
# Reference magnetic field in Porto: ~44 uT total (Bx~25, By~-1, Bz~36)
mag_x = 25.0 + np.random.normal(0, 0.5, total_seconds)
mag_y = -1.0 + np.random.normal(0, 0.5, total_seconds)
mag_z = 36.0 + np.random.normal(0, 0.5, total_seconds)

# Add structural magnetic anomalies:
# 1. Ponte Luiz I (massive iron structure at the start: t = 0 to t = 30)
mag_x[0:30] += np.sin(np.linspace(0, 3 * np.pi, 30)) * 25
mag_z[0:30] += np.random.normal(15, 5, 30)

# 2. Silo Auto (reinforced concrete structure and metal pillars: t = 270 to t = 330)
mag_y[270:330] += np.random.normal(8, 3, 60)

# 3. Underground Alameda parking (subterranean Faraday cage: t = 570 until the end)
mag_x[570:] += 12.0 + np.random.normal(0, 2, total_seconds - 570)
mag_z[570:] -= 10.0

# --- GPS / GNSS ---
gps_lat = lat_gt.copy()
gps_lon = lon_gt.copy()
gps_alt = alt_gt.copy()
gps_status = np.ones(total_seconds)  # 1 = full fix, 0 = no signal

# Simulate GPS degradation in an urban environment:
for t in range(total_seconds):
    # Picaria area (narrow streets, urban canyon -> multipath / high noise)
    if 100 < t < 180:
        gps_lat[t] += np.random.normal(0, 0.0001)
        gps_lon[t] += np.random.normal(0, 0.0001)
        gps_alt[t] += np.random.normal(0, 5.0)

    # Inside Silo Auto (signal degrades while climbing, but recovers on the open-air top floor)
    elif 270 <= t < 315:  # While climbing the internal ramps
        gps_status[t] = 0
        gps_lat[t] = np.nan
        gps_lon[t] = np.nan
        gps_alt[t] = np.nan
    elif 315 <= t < 330:  # Reached the top (open sky again)
        gps_status[t] = 1
        gps_lat[t] += np.random.normal(0, 0.00002)  # Good accuracy

    # Underground Alameda parking (complete GNSS signal loss)
    elif t >= 570:
        gps_status[t] = 0
        gps_lat[t] = np.nan
        gps_lon[t] = np.nan
        gps_alt[t] = np.nan

# 4. Create the DataFrame and export to CSV
df = pd.DataFrame(
    {
        "Timestamp_s": time_vector,
        "GroundTruth_Lat": lat_gt,
        "GroundTruth_Lon": lon_gt,
        "GroundTruth_Alt_m": alt_gt,
        "GPS_Status": gps_status,
        "GPS_Lat": gps_lat,
        "GPS_Lon": gps_lon,
        "GPS_Alt_m": gps_alt,
        "Barometer_hPa": pressure,
        "Magnetometer_X_uT": mag_x,
        "Magnetometer_Y_uT": mag_y,
        "Magnetometer_Z_uT": mag_z,
    }
)

df.to_csv("trajectory_OPO_data.csv", index=False)
print("Dataset generated successfully: 'trajectory_OPO_data.csv'")
print(df.tail(10))  # Show the last rows (already inside Alameda)