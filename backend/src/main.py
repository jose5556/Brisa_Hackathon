from typing import Any

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.orm import Session

from src.database import get_db
from src.vertical_ml_predict import predict_vertical_context

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
    return {"message": "Vertical Context Detector API is running"}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/db/health")
def db_health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok", "database": "connected"}


@app.get("/db/schema-info")
def db_schema_info(db: Session = Depends(get_db)):
    tables = db.execute(
        text(
            """
            SELECT tablename
            FROM pg_catalog.pg_tables
            WHERE schemaname = 'public'
            ORDER BY tablename
            """
        )
    ).scalars().all()

    return {"status": "ok", "tables": tables}


@app.post("/predict")
def predict(payload: dict[str, Any]):
    try:
        result = predict_vertical_context(payload)
        return result
    except FileNotFoundError as error:
        raise HTTPException(status_code=500, detail=str(error))
    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Prediction failed: {str(error)}")
