from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from src.vertical_ml_predict import predict_vertical_context
from src.schemas import SensorWindow

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
