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
# Valid city codes - must match city_code enum in database/schema/schema.sql
VALID_CITIES = {
    "Porto",
    "Lisboa",
    "Oeiras",
    "Espinho",
    "Vila Nova de Gaia",
    "Matosinhos",
    "Maia",
    "Arouca",
}
CITY_ALIASES = {city.casefold(): city for city in VALID_CITIES}

# Pipeline abort reason codes, stored in inference_logs and returned in the
# API response so the developer dashboard can filter by abort type.
VERTICAL_ABORT = "vertical_abort"   # Model 1: underground or above_ground
SPATIAL_ABORT  = "spatial_abort"    # street_level but outside paid zone
NO_CHARGE      = "no_charge"        # Model 2: charge_confidence below threshold
CHARGE         = "charge"           # All checks passed, initiate billing

def _resolve_city(payload: dict[str, Any]) -> tuple[str, bool]:
    raw = payload.get("city")
    if not raw or not str(raw).strip():
        raise ValueError(
            "Missing 'city' in payload. "
            "Send the city name as received from CLGeocoder, "
            "e.g. 'Porto', 'Vila Nova de Gaia', 'Viana do Castelo'."
        )
    normalized_city = " ".join(str(raw).strip().split())
    canonical_city = CITY_ALIASES.get(normalized_city.casefold())
    if canonical_city:
        return canonical_city, True

    # Unsupported city names should not fail the endpoint.
    # They are treated as "no map available", returning no_charge.
    return normalized_city, False


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
                    :city,
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
                    :city,
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
        city, is_supported_city = _resolve_city(payload)
        if not is_supported_city:
            log.info(
                "SPATIAL_ABORT unsupported city without map city=%s",
                city,
            )
            return {
                "session_id": None,
                "payload_id": None,
                "inference_id": None,
                "abort_code": SPATIAL_ABORT,
                "spatial_reason": "unsupported_city_no_map",
                "distance_to_zone_m": None,
                "final_decision": NO_CHARGE,
                "confidence_to_charge": 0.0,
            }

        user_id = get_or_create_dev_user(db, city)
        session_id = create_parking_session(db, payload, user_id, city)
        payload_id = create_sensor_payload(db, session_id, payload)

        ml1_prediction = predict_vertical_context(payload)
        ml1_conf = ml1_prediction["non_street_confidence"]
        ml1_class      = ml1_prediction["classification"]

        if ml1_class in ("underground", "above"):
            log.info(
                "VERTICAL_ABORT session=%s classification=%s confidence=%.4f",
                session_id, ml1_class, ml1_conf,
            )
            update_session_status(db, session_id, VERTICAL_ABORT)
            db.commit()
            return {
                "session_id":                session_id,
                "payload_id":                payload_id,
                "inference_id":              None,
                "abort_code":                VERTICAL_ABORT,
                "ml1_classification":        ml1_class,
                "ml1_non_street_confidence": ml1_conf,
                "final_decision":            NO_CHARGE,
                "confidence_to_charge":      0.0,
            }

        spatial = get_spatial_context(
            db=db, 
            latitude=payload.get("latitude"), 
            longitude=payload.get("longitude"),
            city=city,
        )

        if not spatial["in_paid_zone"]:
            # Covers both False (outside zone) and None (lookup failed)
            reason = spatial.get("reason") or "outside_paid_zone"
            log.info(
                "SPATIAL_ABORT session=%s reason=%s distance=%.1f m",
                session_id, reason,
                spatial["distance_to_zone_m"] or -1,
            )
            update_session_status(db, session_id, SPATIAL_ABORT)
            db.commit()
            return {
                "session_id":                session_id,
                "payload_id":                payload_id,
                "inference_id":              None,
                "abort_code":                SPATIAL_ABORT,
                "ml1_classification":        ml1_class,
                "ml1_non_street_confidence": ml1_conf,
                "spatial_reason":            reason,
                "distance_to_zone_m":        spatial["distance_to_zone_m"],
                "final_decision":            NO_CHARGE,
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
        db.rollback()
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


def store_user_feedback(
    db: Session,
    session_id: str,
    payload_id: str,
    feedback: str,
) -> dict[str, Any]:

    normalized_feedback = str(feedback).strip().lower()
    if normalized_feedback not in {"correct", "incorrect"}:
        raise ValueError("Invalid feedback. Expected 'correct' or 'incorrect'.")

    relation_exists = db.execute(
        text(
            """
            SELECT 1
            FROM sensor_payloads
            WHERE id = :payload_id
              AND session_id = :session_id
            LIMIT 1
            """
        ),
        {
            "payload_id": payload_id,
            "session_id": session_id,
        },
    ).scalar()

    if relation_exists is None:
        raise ValueError("Payload/session relation not found.")

    inference_id = db.execute(
        text(
            """
            SELECT id::text
            FROM inference_logs
            WHERE session_id = :session_id
              AND payload_id = :payload_id
            ORDER BY id DESC
            LIMIT 1
            """
        ),
        {
            "session_id": session_id,
            "payload_id": payload_id,
        },
    ).scalar()

    model_was_correct = normalized_feedback == "correct"
    session_status = "confirmed" if model_was_correct else "cancelled"

    db.execute(
        text(
            """
            UPDATE parking_sessions
            SET user_label = :user_label,
                status = CAST(:status AS session_status),
                user_responded_at = NOW(),
                updated_at = NOW()
            WHERE id = :session_id
            """
        ),
        {
            "session_id": session_id,
            "user_label": model_was_correct,
            "status": session_status,
        },
    )

    training_label_id = db.execute(
        text(
            """
            INSERT INTO training_labels (
                session_id,
                inference_log_id,
                location_type,
                label_confidence,
                label_source,
                model_was_correct,
                created_at
            )
            VALUES (
                :session_id,
                CAST(:inference_log_id AS UUID),
                CAST('unknown' AS location_type),
                :label_confidence,
                :label_source,
                :model_was_correct,
                NOW()
            )
            RETURNING id::text
            """
        ),
        {
            "session_id": session_id,
            "inference_log_id": inference_id,
            "label_confidence": 1.0,
            "label_source": "user_confirm" if model_was_correct else "user_cancel",
            "model_was_correct": model_was_correct,
        },
    ).scalar_one()

    db.commit()
    return {
        "status": "ok",
        "session_id": session_id,
        "payload_id": payload_id,
        "feedback": normalized_feedback,
        "model_was_correct": model_was_correct,
        "training_label_id": training_label_id,
    }
