import json
import time
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from src.vertical_ml_predict import predict_vertical_context


DEFAULT_CITY = "OPO"
DEFAULT_PLATFORM = "android"


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

    return str(user_id)


def create_parking_session(db: Session, payload: dict[str, Any], user_id: str) -> str:
    latitude = payload.get("latitude")
    longitude = payload.get("longitude")
    gps_accuracy = payload.get("gps_accuracy_mean")

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
                "location_accuracy_m": gps_accuracy,
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
                "location_accuracy_m": gps_accuracy,
                "device_os_version": payload.get("device_os_version"),
                "app_version": payload.get("app_version"),
            },
        ).scalar_one()

    return str(session_id)


def create_sensor_payload(
    db: Session,
    session_id: str,
    payload: dict[str, Any],
) -> str:
    duration = float(payload.get("window_duration_s", 10.0))

    window_end = datetime.now(timezone.utc)
    window_start = window_end - timedelta(seconds=duration)

    gps_lost_ratio = float(payload.get("gps_lost_ratio", 0.0))
    gnss_signal_drop = gps_lost_ratio > 0.2

    payload_id = db.execute(
        text(
            """
            INSERT INTO sensor_payloads (
                session_id,
                window_start_at,
                window_end_at,
                window_duration_s,

                pressure_delta_hpa,
                altitude_change_m,

                gnss_accuracy_m,
                gnss_signal_drop,

                raw_payload
            )
            VALUES (
                :session_id,
                :window_start_at,
                :window_end_at,
                :window_duration_s,

                :pressure_delta_hpa,
                :altitude_change_m,

                :gnss_accuracy_m,
                :gnss_signal_drop,

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

            "pressure_delta_hpa": payload.get("pressure_delta"),
            "altitude_change_m": payload.get("altitude_delta"),

            "gnss_accuracy_m": payload.get("gps_accuracy_mean"),
            "gnss_signal_drop": gnss_signal_drop,

            "raw_payload": json.dumps(payload),
        },
    ).scalar_one()

    return str(payload_id)


def create_inference_log(
    db: Session,
    session_id: str,
    payload_id: str,
    prediction: dict[str, Any],
) -> str:
    non_street_confidence = prediction["non_street_confidence"]

    if non_street_confidence <= 0.25:
        final_decision = "charge"
    else:
        final_decision = "uncertain"

    inference_id = db.execute(
        text(
            """
            INSERT INTO inference_logs (
                session_id,
                payload_id,

                ml1_non_street_confidence,
                ml1_decision,

                final_decision,
                final_confidence
            )
            VALUES (
                :session_id,
                :payload_id,

                :ml1_non_street_confidence,
                :ml1_decision,

                :final_decision,
                :final_confidence
            )
            RETURNING id
            """
        ),
        {
            "session_id": session_id,
            "payload_id": payload_id,

            "ml1_non_street_confidence": non_street_confidence,
            "ml1_decision": final_decision,

            "final_decision": final_decision,
            "final_confidence": non_street_confidence,
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

        start = time.perf_counter()
        prediction = predict_vertical_context(payload)

        inference_id = create_inference_log(
            db=db,
            session_id=session_id,
            payload_id=payload_id,
            prediction=prediction,
        )

        db.commit()

        return {
            "session_id": session_id,
            "payload_id": payload_id,
            "inference_id": inference_id,
            "non_street_confidence": prediction["non_street_confidence"],
            "classification": prediction["classification"],
        }

    except Exception:
        db.rollback()
        raise
