import json
import time
import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from src.vertical_ml_predict import predict_vertical_context
from src.spatial_service import get_spatial_context
from src.spatial_ml_predict import predict_final_decision

log = logging.getLogger(__name__)

DEFAULT_PLATFORM = "ios"
# Valid city codes — must match the city_code ENUM in schema.sql
VALID_CITIES = {"Porto", "Lisboa", "Oeiras", "Espinho"}

def _resolve_city(payload: dict[str, Any]) -> str:
    """
    Extracts and validates the city from the payload.
    Raises ValueError if missing or not in VALID_CITIES.
    FastAPI will surface this as a 422 before it reaches the DB.
    """
    city = payload.get("city")
    if not city:
        raise ValueError(
            "Missing 'city' in payload. "
            f"Expected one of: {sorted(VALID_CITIES)}"
        )
    if city not in VALID_CITIES:
        raise ValueError(
            f"Unknown city '{city}'. "
            f"Expected one of: {sorted(VALID_CITIES)}"
        )
    return city

def get_or_create_dev_user(db: Session, city: str) -> str:
    # Try to find existing user first
    user_id = db.execute(
        text(
            """
            SELECT id
            FROM users
            WHERE city = :city
              AND device_platform = :platform
              AND is_active = TRUE
            ORDER BY created_at
            LIMIT 1
            """
        ),
        {
            "city": city,
            "platform": DEFAULT_PLATFORM,
        },
    ).scalar()

    if user_id is not None:
        return str(user_id)

    # No user found 
    user_id = db.execute(
        text(
            """
            INSERT INTO users (
                city,
                device_platform,
                rgpd_consent_at,
                rgpd_consent_version
            )
            VALUES (
                :city,
                :platform,
                NOW(),
                :consent_version
            )
            ON CONFLICT (city, device_platform) DO UPDATE
                SET updated_at = NOW()
            RETURNING id
            """
        ),
        {
            "city": city,
            "platform": DEFAULT_PLATFORM,
            "consent_version": "dev-v1",
        },
    ).scalar_one()
    
    db.flush()  # Ensure the new user is persisted before returning the ID
    return str(user_id)


def create_parking_session(db: Session, payload: dict[str, Any], user_id: str, city: str) -> str:
    latitude = payload.get("latitude")
    longitude = payload.get("longitude")
    gnss_accuracy = payload.get("gnss_accuracy_m") or payload.get("gnss_accuracy_mean")

    if latitude is not None and longitude is not None:
        session_id = db.execute(
            text(
                """
                INSERT INTO parking_sessions (
                    user_id,
                    city,
                    status,
                    detected_location,
                    location_accuracy_m,
                    device_os_version,
                    app_version
                )
                VALUES (
                    :user_id,
                    CAST(:city AS city_code),
                    'detecting',
                    ST_SetSRID(
                        ST_MakePoint(:longitude, :latitude),
                        4326
                    ),
                    :location_accuracy_m,
                    :device_os_version,
                    :app_version
                )
                RETURNING id
                """
            ),
            {
                "user_id": user_id,
                "city": city,
                "longitude": longitude,
                "latitude": latitude,
                "location_accuracy_m": gnss_accuracy,
                "device_os_version": payload.get("device_os_version"),
                "app_version": payload.get("app_version"),
            },
        ).scalar_one()
    else:
        session_id = db.execute(
            text(
                """
                INSERT INTO parking_sessions (
                    user_id,
                    city,
                    status,
                    location_accuracy_m,
                    device_os_version,
                    app_version
                )
                VALUES (
                    :user_id,
                    CAST(:city AS city_code),
                    'detecting',
                    :location_accuracy_m,
                    :device_os_version,
                    :app_version
                )
                RETURNING id
                """
            ),
            {
                "user_id": user_id,
                "city": city,
                "location_accuracy_m": gnss_accuracy,
                "device_os_version": payload.get("device_os_version"),
                "app_version": payload.get("app_version"),
            },
        ).scalar_one()
    db.flush()
    return str(session_id)


def create_sensor_payload(
    db: Session,
    session_id: str,
    payload: dict[str, Any],
) -> str:
    duration = float(payload.get("window_duration_s", 10.0))

    if payload.get("window_end_at"):
        window_end   = datetime.fromisoformat(str(payload["window_end_at"]).replace("Z", "+00:00"))
        window_start = datetime.fromisoformat(str(payload["window_start_at"]).replace("Z", "+00:00")) \
                       if payload.get("window_start_at") \
                       else window_end - timedelta(seconds=duration)
    else:
        window_end   = datetime.now(timezone.utc)
        window_start = window_end - timedelta(seconds=duration)

    payload_id = db.execute(
        text(
            """
            INSERT INTO sensor_payloads (
                session_id,
                window_start_at,
                window_end_at,
                window_duration_s,

                pressure_hpa,
                pressure_delta_hpa,
                pressure_variance,
                altitude_change_m,

                magnetic_variance_total,
                magnetic_field_mean,
                magnetic_field_delta,

                gnss_accuracy_m,
                gnss_accuracy_delta,

                raw_payload
            )
            VALUES (
                :session_id,
                :window_start_at,
                :window_end_at,
                :window_duration_s,

                :pressure_hpa,
                :pressure_delta_hpa,
                :pressure_variance,
                :altitude_change_m,

                :magnetic_variance_total,
                :magnetic_field_mean,
                :magnetic_field_delta,

                :gnss_accuracy_m,
                :gnss_accuracy_delta,

                CAST(:raw_payload AS jsonb)
            )
            RETURNING id
            """
        ),
        {
            "session_id": session_id,
            "window_start_at": window_start,
            "window_end_at": window_end,
            "window_duration_s": duration,

            "pressure_hpa": payload.get("pressure_hpa"),
            "pressure_delta_hpa": payload.get("pressure_delta"),
            "pressure_variance": payload.get("pressure_variance"),
            "altitude_change_m": payload.get("altitude_delta"),
            
            "magnetic_variance_total": payload.get("magnetic_variance_total"),
            "magnetic_field_mean": payload.get("magnetic_field_mean"),
            "magnetic_field_delta": payload.get("magnetic_field_delta"),
            
            "gnss_accuracy_m": payload.get("gnss_accuracy_m") or payload.get("gnss_accuracy_mean"),
            "gnss_accuracy_delta": payload.get("gnss_accuracy_delta"),
            "raw_payload": json.dumps(payload),
        },
    ).scalar_one()

    db.flush()
    return str(payload_id)


def create_inference_log(
    db: Session,
    session_id: str,
    payload_id: str,
    ml1_prediction: dict[str, Any],
    spatial_data: dict[str, Any],
    ml2_prediction: dict[str, Any]
) -> str:

    ml1_conf = float(ml1_prediction["non_street_confidence"])
    ml1_class = str(ml1_prediction["classification"])
    probs                = ml1_prediction.get("probabilities", {})
    ml1_street_prob      = probs.get("street_level")
    ml1_underground_prob = probs.get("underground")
    ml1_above_prob       = probs.get("above")

    final_decision = str(ml2_prediction["final_decision"])
    final_confidence = float(ml2_prediction["ml2_charge_confidence"])

    inference_id = db.execute(
        text(
            """
            INSERT INTO inference_logs (
                session_id,
                payload_id,

                ml1_street_prob,
                ml1_underground_prob,
                ml1_above_prob,
                ml1_non_street_confidence,
                ml1_classification,

                spatial_in_paid_zone,
                spatial_zone_id,
                spatial_dist_to_road_m,

                ml2_charge_confidence,
                ml2_decision,

                final_decision,
                final_confidence
            )
            VALUES (
                :session_id,
                :payload_id,

                :ml1_street_prob,
                :ml1_underground_prob,
                :ml1_above_prob,
                :ml1_non_street_confidence,
                :ml1_classification,

                :spatial_in_paid_zone,
                CAST(:spatial_zone_id AS UUID),
                :spatial_dist_to_road_m,

                :ml2_charge_confidence,
                CAST(:ml2_decision AS model_decision),

                CAST(:final_decision AS model_decision),
                :final_confidence
            )
            RETURNING id::text
            """
        ),
        {
            "session_id": session_id,
            "payload_id": payload_id,

            "ml1_street_prob": ml1_street_prob,
            "ml1_underground_prob": ml1_underground_prob,
            "ml1_above_prob": ml1_above_prob,
            "ml1_non_street_confidence": ml1_conf,
            "ml1_classification": ml1_class,

            "spatial_in_paid_zone": spatial_data["in_paid_zone"],
            "spatial_zone_id": spatial_data["zone_id"],
            "spatial_dist_to_road_m": spatial_data["distance_to_zone_m"],

            "ml2_charge_confidence": final_confidence,
            "ml2_decision": final_decision,

            "final_decision": final_decision,
            "final_confidence": final_confidence,
        },
    ).scalar_one()

    return str(inference_id)


def analyze_and_store_parking_event(
    db: Session,
    payload: dict[str, Any],
) -> dict[str, Any]:
    try:
        city = _resolve_city(payload)
        user_id = get_or_create_dev_user(db, city)
        session_id = create_parking_session(db, payload, user_id, city)
        payload_id = create_sensor_payload(db, session_id, payload)

        ml1_prediction = predict_vertical_context(payload)
        ml1_conf = ml1_prediction["non_street_confidence"]

        spatial = get_spatial_context(
            db=db, 
            latitude=payload.get("latitude"), 
            longitude=payload.get("longitude"),
            city=city,
        )

        if spatial["in_paid_zone"] is None:
            log.warning(
                "Spatial lookup returned None for session %s (reason: %s). "
                "Aborting pipeline — no_charge.",
                session_id, spatial.get("reason"),
            )
            update_session_status(db, session_id, "no_charge")
            db.commit()
            return {
                "session_id":                session_id,
                "payload_id":                payload_id,
                "inference_id":              None,
                "ml1_classification":        ml1_prediction["classification"],
                "ml1_non_street_confidence": ml1_conf,
                "spatial_abort_reason":      spatial.get("reason"),
                "final_decision":            "no_charge",
                "confidence_to_charge":      0.0,
            }

        ml2_prediction = predict_final_decision(
            ml1_confidence=ml1_conf,
            gnss_accuracy_m=payload.get("gnss_accuracy_m", 10.0),
            distance_to_zone_m=float(spatial["distance_to_zone_m"])
        )

        inference_id = create_inference_log(
            db=db,
            session_id=session_id,
            payload_id=payload_id,
            ml1_prediction=ml1_prediction,
            spatial_data=spatial,
            ml2_prediction=ml2_prediction
        )

        update_session_status(db, session_id, ml2_prediction["final_decision"])

        db.commit()

        return {
            "session_id": session_id,
            "payload_id": payload_id,
            "inference_id": inference_id,
            "ml1_classification": ml1_prediction["classification"],
            "ml1_non_street_confidence": ml1_prediction["non_street_confidence"],
            "distance_to_zone_m": float(spatial["distance_to_zone_m"]),
            "final_decision": ml2_prediction["final_decision"],
            "confidence_to_charge": ml2_prediction["ml2_charge_confidence"]
        }
    
    except ValueError as exc:
        log.warning("Payload validation error: %s", exc)
        raise

    except Exception:
        db.rollback()
        log.exception("Parking event analysis failed.")
        raise

def update_session_status(
    db: Session,
    session_id: str,
    final_decision: str,
) -> None:
    """
    Updates the session status after the pipeline completes.

    'charge'    → 'pending_confirm'  (push will be sent)
    'no_charge' → 'auto_aborted'     (pipeline aborted before push)

    Without this update, the dashboard shows all sessions as 'detecting'
    forever — making it impossible to filter active from completed sessions.
    """
    new_status = (
        "pending_confirm" if final_decision == "charge" else "auto_aborted"
    )
    db.execute(
        text("""
            UPDATE parking_sessions
            SET status     = CAST(:status AS session_status),
                updated_at = NOW()
            WHERE id = :session_id
        """),
        {"status": new_status, "session_id": session_id},
    )
    db.flush()
