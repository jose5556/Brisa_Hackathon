import json
import time
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from src.vertical_ml_predict import predict_vertical_context
from src.spatial_service import get_spatial_context
from src.spatial_ml_predict import predict_final_decision

DEFAULT_CITY = "OPO"
DEFAULT_PLATFORM = "ios"

def get_or_create_dev_user(db: Session) -> str:
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
            "city": DEFAULT_CITY,
            "platform": DEFAULT_PLATFORM,
        },
    ).scalar()

    if user_id is not None:
        return str(user_id)

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
            RETURNING id
            """
        ),
        {
            "city": DEFAULT_CITY,
            "platform": DEFAULT_PLATFORM,
            "consent_version": "dev-v1",
        },
    ).scalar_one()
    
    db.flush()  # Ensure the new user is persisted before returning the ID
    return str(user_id)


def create_parking_session(db: Session, payload: dict[str, Any], user_id: str) -> str:
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
                "city": DEFAULT_CITY,
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
                "city": DEFAULT_CITY,
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

    window_end = datetime.now(timezone.utc)
    window_start = window_end - timedelta(seconds=duration)

    gnss_lost_ratio = float(payload.get("gnss_lost_ratio", 0.0))

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
                gnss_lost_ratio,

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
                :gnss_lost_ratio,

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
            "gnss_lost_ratio": gnss_lost_ratio,
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

    final_decision = str(ml2_prediction["final_decision"])
    final_confidence = float(ml2_prediction["ml2_charge_confidence"])

    inference_id = db.execute(
        text(
            """
            INSERT INTO inference_logs (
                session_id,
                payload_id,

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
        user_id = get_or_create_dev_user(db)
        session_id = create_parking_session(db, payload, user_id)
        payload_id = create_sensor_payload(db, session_id, payload)

        ml1_prediction = predict_vertical_context(payload)
        ml1_conf = ml1_prediction["non_street_confidence"]

        spatial = get_spatial_context(
            db=db, 
            latitude=payload.get("latitude"), 
            longitude=payload.get("longitude"),
            city=payload.get("city"),
        )

        ml2_prediction = predict_final_decision(
            ml1_confidence=ml1_conf,
            gnss_accuracy_m=payload.get("gnss_accuracy_m", 10.0),
            distance_to_zone_m=spatial["distance_to_zone_m"]
        )

        inference_id = create_inference_log(
            db=db,
            session_id=session_id,
            payload_id=payload_id,
            ml1_prediction=ml1_prediction,
            spatial_data=spatial,
            ml2_prediction=ml2_prediction
        )

        db.commit()

        return {
            "session_id": session_id,
            "payload_id": payload_id,
            "inference_id": inference_id,
            "ml1_classification": ml1_prediction["classification"],
            "ml1_non_street_confidence": ml1_prediction["non_street_confidence"],
            "distance_to_zone_m": spatial["distance_to_zone_m"],
            "final_decision": ml2_prediction["final_decision"],
            "confidence_to_charge": ml2_prediction["ml2_charge_confidence"]
        }

    except Exception:
        db.rollback()
        raise
