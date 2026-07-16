from typing import Any, Literal, Optional

from pydantic import BaseModel, Field
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.orm import Session

from src.database_session_connection import get_db
from src.parking_service import analyze_and_store_parking_event, store_user_feedback

import subprocess


app = FastAPI(
    title="Vertical Context Detector API",
    description="Receives phone sensor features and returns context predictions.",
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
    return {"message": "API is running"}


@app.get("/health")
def health():
    try:
        result = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True,
            text=True,
            check=True,
        )

        return {
            "tailscale_ip": result.stdout.strip(),
        }

    except FileNotFoundError:
        raise HTTPException(
            status_code=500,
            detail="Tailscale command not found on this server",
        )

    except subprocess.CalledProcessError as error:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get Tailscale IP: {error.stderr.strip()}",
        )


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
def predict(payload: dict[str, Any], db: Session = Depends(get_db)):
    try:
        return analyze_and_store_parking_event(db, payload)

    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error))

    except FileNotFoundError as error:
        raise HTTPException(status_code=500, detail=str(error))

    except Exception as error:
        raise HTTPException(
            status_code=500,
            detail=f"Prediction failed: {str(error)}",
        )


@app.post("/parking-events/analyze")
def analyze_parking_event(
    payload: dict[str, Any],
    db: Session = Depends(get_db),
):
    try:
        return analyze_and_store_parking_event(db, payload)

    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error))

    except FileNotFoundError as error:
        raise HTTPException(status_code=500, detail=str(error))

    except Exception as error:
        raise HTTPException(
            status_code=500,
            detail=f"Parking event analysis failed: {str(error)}",
        )

@app.get("/parking-events/latest")
def latest_parking_events(
    limit: int = 10,
    db: Session = Depends(get_db),
):
    rows = db.execute(
        text(
            """
            SELECT
                ps.id AS session_id,
                ps.city,
                ps.status,
                ps.detected_at,
                ps.location_accuracy_m,
                il.ml1_non_street_confidence,
                il.final_decision,
                il.final_confidence,
                tl.model_was_correct AS feedback_correct,
                tl.created_at AS feedback_at,
                CASE
                    WHEN tl.model_was_correct IS TRUE THEN 'correct'
                    WHEN tl.model_was_correct IS FALSE THEN 'incorrect'
                    ELSE NULL
                END AS feedback_verdict
            FROM parking_sessions ps
            LEFT JOIN inference_logs il ON il.session_id = ps.id
            LEFT JOIN LATERAL (
                SELECT model_was_correct, created_at
                FROM training_labels
                WHERE session_id = ps.id
                ORDER BY created_at DESC
                LIMIT 1
            ) tl ON TRUE
            ORDER BY ps.created_at DESC
            LIMIT :limit
            """
        ),
        {"limit": limit},
    ).mappings().all()

    return {
        "count": len(rows),
        "events": [dict(row) for row in rows],
    }

@app.get("/sensor-payloads/latest")
def latest_sensor_payloads(
    limit: int = 10,
    db: Session = Depends(get_db),
):
    rows = db.execute(
        text(
            """
            SELECT
                sp.id AS payload_id,
                sp.session_id,
                ps.user_id,
                ps.city,
                sp.window_start_at,
                sp.window_end_at,
                sp.gnss_accuracy_m,
                sp.gnss_lost_ratio,
                sp.raw_payload
            FROM sensor_payloads sp
            JOIN parking_sessions ps ON ps.id = sp.session_id
            ORDER BY sp.received_at DESC
            LIMIT :limit
            """
        ),
        {"limit": limit},
    ).mappings().all()

    return {
        "count": len(rows),
        "payloads": [dict(row) for row in rows],
    }


@app.get("/parking-events/{session_id}")
def get_parking_event(
    session_id: str,
    db: Session = Depends(get_db),
):
    row = db.execute(
        text(
            """
            SELECT
                ps.id AS session_id,
                ps.city,
                ps.status,
                ps.detected_at,
                ps.location_accuracy_m,
                ST_AsGeoJSON(ps.detected_location)::json AS detected_location,
                sp.raw_payload,
                il.ml1_non_street_confidence,
                il.final_decision,
                il.final_confidence,
                tl.model_was_correct AS feedback_correct,
                tl.created_at AS feedback_at,
                CASE
                    WHEN tl.model_was_correct IS TRUE THEN 'correct'
                    WHEN tl.model_was_correct IS FALSE THEN 'incorrect'
                    ELSE NULL
                END AS feedback_verdict
            FROM parking_sessions ps
            LEFT JOIN sensor_payloads sp ON sp.session_id = ps.id
            LEFT JOIN inference_logs il ON il.session_id = ps.id
            LEFT JOIN LATERAL (
                SELECT model_was_correct, created_at
                FROM training_labels
                WHERE session_id = ps.id
                ORDER BY created_at DESC
                LIMIT 1
            ) tl ON TRUE
            WHERE ps.id = :session_id
            ORDER BY ps.created_at DESC
            LIMIT 1
            """
        ),
        {"session_id": session_id},
    ).mappings().first()

    if row is None:
        raise HTTPException(status_code=404, detail="Parking event not found")

    return dict(row)


class FeedbackRequestBody(BaseModel):
    payload_id: str = Field(..., description="Sensor payload ID associated with the session")
    session_id: str = Field(..., description="Parking session ID")
    ml1_classification: str = Field(..., description="Vertical classification returned by the analysis")
    final_decision: Literal["charge", "no_charge"] = Field(
        ..., description="Final decision returned by the analysis"
    )
    feedback: Literal["correct", "incorrect"] = Field(
        ..., description="User verdict about the final decision"
    )
    raw_timeseries: Optional[list[dict[str, Any]]] = Field(
        default=None, description="Optional array with raw readings"
    )


class FeedbackResponseBody(BaseModel):
    status: str
    session_id: str
    payload_id: str
    feedback: str
    model_was_correct: bool
    training_label_id: str
    raw_timeseries_count: int = 0


@app.post(
    "/feedback",
    response_model=FeedbackResponseBody,
    summary="Store user feedback",
    description=(
        "Receives the user verdict about the model decision and persists "
        "the feedback in parking_sessions and training_labels."
    ),
)
def submit_feedback(
    request: FeedbackRequestBody,
    db: Session = Depends(get_db),
):
    try:
        return store_user_feedback(
            db=db,
            session_id=request.session_id,
            payload_id=request.payload_id,
            ml1_classification=request.ml1_classification,
            final_decision=request.final_decision,
            feedback=request.feedback,
            raw_timeseries=request.raw_timeseries,
        )
    except ValueError as error:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(error))
    except Exception as error:
        db.rollback()
        raise HTTPException(
            status_code=500,
            detail=f"Failed to store feedback: {str(error)}",
        )
