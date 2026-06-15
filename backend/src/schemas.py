from pydantic import BaseModel


class SensorWindow(BaseModel):
    gps_accuracy_mean: float
    gps_accuracy_max: float
    gps_accuracy_delta: float
    gps_lost_ratio: float

    wifi_count_mean: float
    wifi_count_delta: float
    wifi_rssi_mean: float

    ble_count_mean: float
    ble_count_delta: float
    ble_rssi_mean: float

    pressure_delta: float
    pressure_slope: float

    altitude_delta: float
    vertical_change_abs: float

    stationary_ratio: float
