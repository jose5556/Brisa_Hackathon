from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from src.predict import predict_vertical_context

app = FastAPI(
    title="Vertical Context Detector API",
    description="Receives phone sensor features and returns vertical context prediction.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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


@app.get("/")
def root():
    return {
        "message": "Vertical Context Detector API is running"
    }


@app.get("/health")
def health():
    return {
        "status": "ok"
    }

@app.post("/predict")
def predict(payload: SensorWindow):
    try:
        data = payload.model_dump()
        result = predict_vertical_context(data)
        return result

    except FileNotFoundError as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        )

    except Exception as error:
        raise HTTPException(
            status_code=500,
            detail=f"Prediction failed: {str(error)}",
        )